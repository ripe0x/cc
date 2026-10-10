// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {BidModel} from "./utils/BidModel.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {Lane, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";

/// @notice independent review of the economics (docs/REVIEW-econ.md), on the real stack, after the flow rework. what
/// survives: the `pilePage` fuzz against a reference walk, exact numbers at the launch settings (they replace the
/// golden test of the old defaults), the reimbursement cap with the sale at the reserve, a statement sent to the core
/// from outside, and a model of the rate written independently of the Core loop. the dutch price curve, the gate
/// proofs and the recommended config file belong to things that no longer exist
abstract contract ReviewEconBase is Fixture {
    using FixedPointMathLib for uint256;

    function _composeOne() internal returns (uint256 sid, uint256 cost) {
        _skipSniperWindow();
        sid = STATEMENTS.supply() + 1;
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        (,, cost,) = core.statementInfo(sid);
    }
}

/// @notice `pilePage` was rewritten in the commit. a reference walk over `pileHead` and `pileNext` must agree
contract PilePageEquivalence is ReviewEconBase {
    uint256[] internal pile;

    function setUp() public override {
        super.setUp();
        _skipSniperWindow();
        uint256[] memory ids = _fillEthPile(37);
        for (uint256 i; i < ids.length; ++i) {
            pile.push(ids[i]);
        }
    }

    /// the old behaviour: walk `next` from the start and stop at n or at the end, whatever the lane
    function _ref(Lane lane, uint256 startAfter, uint256 n) internal view returns (uint256[] memory out) {
        uint256 first = startAfter == 0 ? core.pileHead(lane) : core.pileNext(startAfter);
        uint256 c;
        for (uint256 id = first; id != 0 && c < n; id = core.pileNext(id)) {
            ++c;
        }
        out = new uint256[](c);
        c = 0;
        for (uint256 id = first; id != 0 && c < out.length; id = core.pileNext(id)) {
            out[c++] = id;
        }
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_pilePageEqualsTheReference(uint8 laneRaw, uint256 pick, uint256 n, uint256 junk) public view {
        Lane lane = laneRaw % 2 == 0 ? Lane.Eth : Lane.Exit;
        uint256 mode = pick % 4;
        uint256 startAfter = mode == 0 ? 0 : mode == 1 ? pile[(pick >> 8) % pile.length] : mode == 2 ? junk : pile[0];
        // a start id of the other lane is not a valid input, see test_pilePageCrossLaneStartDiffers
        // a junk id can collide with a member of the eth pile, which is the same cross lane input
        if (lane == Lane.Exit && (mode == 1 || mode == 3 || core.pileNext(startAfter) != 0)) startAfter = 0;
        n = (pick >> 40) % 3 == 0 ? n : n % 90;
        uint256[] memory got = core.pilePage(lane, startAfter, n);
        uint256[] memory want = _ref(lane, startAfter, n);
        assertEq(got.length, want.length, "length");
        for (uint256 i; i < got.length; ++i) {
            assertEq(got[i], want[i], "id");
        }
    }

    function test_pilePageEdges() public view {
        assertEq(core.pilePage(Lane.Eth, 0, 0).length, 0, "n zero");
        assertEq(core.pilePage(Lane.Eth, 0, type(uint256).max).length, 37, "huge n is the pile");
        assertEq(core.pilePage(Lane.Eth, pile[36], 5).length, 0, "after the tail");
        assertEq(core.pilePage(Lane.Eth, pile[35], 5).length, 1);
        assertEq(core.pilePage(Lane.Exit, 0, 80).length, 0, "empty lane");
        assertEq(core.pilePage(Lane.Eth, 0, 80).length, 37, "page of 80 over a pile of 37");
    }

    /// the one input the rewrite answers differently: a start id taken from the other lane. the old code walked the
    /// credit chain of that id, the new one cuts at the size of the lane asked about. no valid use is affected
    function test_pilePageCrossLaneStartDiffers() public view {
        assertEq(_ref(Lane.Exit, pile[0], 10).length, 10, "old behaviour walked the eth chain");
        assertEq(core.pilePage(Lane.Exit, pile[0], 10).length, 0, "new behaviour: empty lane, empty page");
    }
}

/// @notice exact numbers at the launch settings (flat bid, hourly cap 100 percent of the pot, drop 0.5 percent per credit with an
/// 80 percent minute floor, climb 0.5 percent a minute, ceiling 125 percent of the rate paid plus 2 percent per 10 idle
/// minutes, clamp at one average credit, average credit 4.33M). the pot is booked by donation so every number is a closed form
contract LaunchSettingsExactNumbers is ReviewEconBase {
    function test_scenarioAtTheLaunchSettings() public {
        vm.deal(address(core), 10 ether);
        core.skim();
        assertEq(core.ethPot(), 10 ether);
        assertEq(core.ethRate(), 4e12);
        // ten minutes at 0.5 percent a minute from the opening rate, 4e12 * 1.005^10
        _warp(10 minutes);
        uint256 r1 = core.ethRate();
        assertApproxEqAbs(r1, 4_204_560_528_163, 10);
        // three credits of three different scores sell in one call at the flat price: 4.33e6 * rate / 1e4, and the
        // rate drops by 0.5 percent after each
        uint256 r2 = r1 * 9_950 / 10_000;
        uint256 r3 = r2 * 9_950 / 10_000;
        uint256[3] memory prices = [4_330_000 * r1 / 1e4, 4_330_000 * r2 / 1e4, 4_330_000 * r3 / 1e4];
        uint256[] memory ids = _credits(seller, 3);
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        assertEq(seller.balance - before, prices[0] + prices[1] + prices[2], "the three prices paid");
        for (uint256 i; i < 3; ++i) {
            (,, uint256 cost,) = core.creditInfo(ids[i]);
            assertEq(cost, prices[i], "cost basis is the flat price");
        }
        assertEq(core.rateAtCheckpoint(), r3 * 9_950 / 10_000);
        assertEq(core.ethPot(), 10 ether - prices[0] - prices[1] - prices[2]);
        assertEq(core.lastFillTime(), block.timestamp);
        (uint256 anchor, uint256 minuteStart,) = _anchor();
        assertEq(anchor, r3, "the rate of the last fill is the anchor");
        assertEq(minuteStart, r1, "the minute started at the first rate paid");
        // forty hours later the climb sits at the ceiling: 125 percent of the anchor loosened by 240 intervals of 2 percent
        _warp(40 hours);
        assertEq(core.ethRate(), r3 * (10_000 + 200 * 240) * 12_500 / 1e8);
        // the funded clamp of the hourly cap is the pot over one credit of 4.33M, above the rate cap, so after a
        // long climb the rate sits at the rate cap
        _warp(10_000 hours);
        assertEq(core.ethRate(), 205_540_000_000_000);
        assertGt(core.ethPot() * core.settings().spendCapBps / 4_330_000, core.ethRate());
        _solvent();
    }
}

/// @notice the reimbursement cap and the sale at the reserve, and the statement that arrives from outside
contract ReserveSaleAndOutsiders is ReviewEconBase {
    /// E-6: a compose pays the caller nothing, so the cost the statement lists against is the page cost. at the
    /// reserve the pot gets back 0.45 of the cost and the buyback pot 0.45
    function test_POC_composeRepaysNothingAndTheReserveSale() public {
        composeBasefee = 400 gwei;
        uint256 before = keeper.balance;
        (uint256 sid, uint256 cost) = _composeOne();
        assertEq(keeper.balance, before, "the compose pays the caller nothing");
        uint256 reserve = _live(sid).reserve;
        assertEq(reserve, cost * 11_000 / 10_000, "the reserve is the 110 percent opening ask of the page cost");

        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        _bid(funder, sid, reserve);
        _endAuction(sid);
        assertEq(_collectSales(), reserve);
        uint256 toBuyback = reserve * 5_000 / 10_000;
        assertEq(core.ethToBuyback() - bb, toBuyback);
        assertEq(core.ethPot() - pot, reserve - toBuyback);
        assertGt(reserve, cost, "sold above cost at the opening ask");
        // the engine paid the page cost for it and got back 1.1 of that, half of it to the buyback
        emit log_named_uint("pot gets back, bps of cost", (core.ethPot() - pot) * 10_000 / cost);
        _solvent();
    }

    /// a statement sent to the core from outside is accepted by the receiver hook and never counted: it is not in the
    /// held list, cannot be listed, repriced, exited or overprinted. sent back before the sale is settled on the
    /// record, it is a returned statement and `syncStatement` lists it again at the current reserve
    function test_statementSentFromOutsideIsNotCounted() public {
        (uint256 sid,) = _composeOne();
        address a = _user("outsider");
        uint256 snap = vm.snapshotState();
        uint256 reserve = _live(sid).reserve;

        // the sale is settled on the record first, then the winner sends the statement back
        _bid(a, sid, reserve);
        _endAuction(sid);
        core.syncStatement(sid);
        assertEq(core.heldStatements().length, 0);
        vm.prank(a);
        STATEMENTS.safeTransferFrom(a, address(core), sid);
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        (bool held,,,) = core.statementInfo(sid);
        assertFalse(held);
        assertEq(core.heldStatements().length, 0, "not counted");
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.None));
        vm.expectRevert(ICore.NotListed.selector);
        core.syncStatement(sid);
        vm.expectRevert(ICore.NotListed.selector);
        core.repriceStatement(sid);
        _enterPhase2();
        vm.expectRevert(ICore.NotHeld.selector);
        core.exitStatement(sid);
        ScriptedController sc = new ScriptedController();
        _setController(address(sc));
        sc.setOverprint(true, sid + 1_000, sid);
        vm.expectRevert(ICore.BadOverprint.selector);
        core.overprint();
        sc.setOverprint(true, sid, sid + 1_000);
        vm.expectRevert(ICore.BadOverprint.selector);
        core.overprint();
        _solvent();

        // sent back before the record is settled: the record is still live and the statement returned
        vm.revertToState(snap);
        _bid(a, sid, reserve);
        _endAuction(sid);
        vm.prank(a);
        STATEMENTS.safeTransferFrom(a, address(core), sid);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Returned));
        core.syncStatement(sid);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Listed));
        assertEq(STATEMENTS.ownerOf(sid), address(house));
        assertEq(core.heldStatements().length, 1);
        assertEq(_live(sid).reserve, _reserveFor(_costOf(sid)), "back on the house at the current reserve");
        assertEq(_collectSales(), reserve, "the proceeds of the first sale are still the core's");
    }

    function _costOf(uint256 sid) internal view returns (uint256 cost) {
        (,, cost,) = core.statementInfo(sid);
    }
}

/// @notice a model of the rate written independently of the Core: the climb compounds per minute from the checkpoint
/// for exactly the time the pot could afford an average credit, stops at the clamp, the rate cap and the ceiling of the
/// loosened anchor, and a fill drops the rate by the spec formula with the minute floor. the fuzz drives warps, fees,
/// donations, fills and changes of the settings and compares after every step
contract RateModelFuzz is ReviewEconBase {
    uint256 internal mRate;
    uint256 internal mTime;
    uint256 internal mLast;
    uint256 internal mAnchor;
    uint256 internal mMinuteStart;
    uint256 internal mBucket;
    bool internal mFunded;

    function setUp() public override {
        super.setUp();
        mRate = core.rateAtCheckpoint();
        mTime = core.checkpointTime();
        mLast = core.lastFillTime();
        mAnchor = core.RATE_START();
    }

    /// the model price state at `to`, from its checkpoint, under the settings now
    function _priceAt(uint256 to) internal view returns (uint256) {
        return BidModel.price(core.settings(), mRate, core.ethPot(), mAnchor, to - mLast, to - mTime);
    }

    /// the model read at `to`: the price state lowered to the clamp while funded
    function _modelAt(uint256 to) internal view returns (uint256) {
        return BidModel.read(core.settings(), core.ethPot(), _priceAt(to));
    }

    /// a checkpoint of the model at now, before an op that changes the pot, the settings or the fill clock. it stores the
    /// price state
    function _checkpoint() internal {
        mRate = _priceAt(block.timestamp);
        mTime = block.timestamp;
    }

    function _syncFunded() internal {
        Settings memory s = core.settings();
        mFunded = core.ethPot() * s.spendCapBps >= uint256(s.avgScore) * mRate;
    }

    function _sell(uint256 seed) internal {
        uint256[] memory ids = _credits(seller, 1);
        _checkpoint();
        uint256 before = seller.balance;
        vm.prank(seller);
        try core.sellForEth(ids) {
            if (block.timestamp / 60 != mBucket) {
                mBucket = block.timestamp / 60;
                mMinuteStart = mRate;
            }
            mAnchor = mRate;
            mRate = BidModel.dropOnce(core.settings(), mRate, mMinuteStart);
            mLast = block.timestamp;
            _syncFunded();
        } catch {}
        seed;
    }

    function _settingsOp(uint256 seed) internal {
        _checkpoint();
        Settings memory s = core.settings();
        // forge-lint: disable-start(unsafe-typecast)
        s.climbPerMinBps = uint16(1 + seed % 1_000);
        s.ceilBps = uint16(10_000 + (seed >> 10) % 20_001);
        s.idleLoosenBps = uint16((seed >> 25) % 2_001);
        s.avgScore = uint32(800_000 + (seed >> 48) % 5_200_001);
        s.spendCapBps = uint16(100 + (seed >> 72) % 4_901);
        s.dropPerCreditBps = uint16(1 + (seed >> 96) % 1_000);
        s.dropFloorBps = uint16(5_000 + (seed >> 108) % 5_001);
        s.rateCap = uint64(1e13 + (seed >> 120) % (1e15 - 1e13 + 1));
        // forge-lint: disable-end(unsafe-typecast)
        _setSettings(s);
        _syncFunded();
    }

    function _step(uint256 seed) internal {
        uint256 op = seed % 6;
        if (op == 0 || op == 1) {
            _warp(bound(seed >> 8, 1 minutes, 4 days));
        } else if (op == 2) {
            _checkpoint();
            _buyCoin(funder, 0.05 ether + (seed >> 8) % 0.3 ether);
            _syncFunded();
        } else if (op == 3) {
            _checkpoint();
            vm.deal(address(core), address(core).balance + 0.05 ether);
            core.skim();
            _syncFunded();
        } else if (op == 4) {
            _sell(seed);
        } else {
            _settingsOp(seed >> 8);
        }
    }

    /// forge-config: default.fuzz.runs = 40
    function testFuzz_rateMatchesTheModel(uint256 seed) public {
        _skipSniperWindow();
        for (uint256 step; step < 14; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            _step(seed);
            assertApproxEqRel(core.ethRate(), _modelAt(block.timestamp), 1e10, "rate equals the model");
            // a rate that was unfunded at the checkpoint holds, whatever the clock
            if (!mFunded) {
                uint256 r = core.ethRate();
                vm.warp(block.timestamp + 2 days);
                assertGe(core.ethRate(), r, "the read does not fall with time");
                assertLe(core.ethRate(), core.rateAtCheckpoint(), "unfunded: no climb above the stored rate");
                vm.warp(block.timestamp - 2 days);
            }
        }
    }

    /// a fixed walk through a climb, a fill and a change of the climb, so the fuzz is known to reach them
    function test_modelAcrossAClimbAFillAndAChange() public {
        _skipSniperWindow();
        uint256[10] memory ops = [uint256(3), 0, 4, 0, 5, 0, 4, 1, 3, 0];
        for (uint256 i; i < ops.length; ++i) {
            uint256 seed = (uint256(keccak256(abi.encode("walk", i))) / 6) * 6 + ops[i];
            _step(seed);
            assertApproxEqRel(core.ethRate(), _modelAt(block.timestamp), 1e10, "rate equals the model");
        }
        assertTrue(core.ethRate() != 4e12, "and the rate moved");
    }
}
