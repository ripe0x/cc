// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {Lane, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";

/// @notice independent review of the economics (docs/REVIEW-econ.md), on the real stack, after the flow rework. what
/// survives: the `pilePage` fuzz against a reference walk, exact numbers at the launch settings (they replace the
/// golden test of the old defaults), the reimbursement cap with the sale at the reserve, a statement sent to the core
/// from outside, and a model of the rate written independently of the Core loop. the dutch price curve, the gate
/// proofs and the recommended config file belong to things that no longer exist
abstract contract ReviewEconBase is Fixture {
    using FixedPointMathLib for uint256;

    /// @dev the eth rate after `secs` of climb at `bps` an hour from `r`, the closed form
    function _climbed(uint256 r, uint256 bps, uint256 secs) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return r.mulWad(uint256(FixedPointMathLib.powWad(int256(1e18 + bps * 1e14), int256(secs * 1e18 / 1 hours))));
    }

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

/// @notice exact numbers at the launch settings (flat bid, 20 percent hourly cap, drop 20 percent, climb 1 percent an
/// hour doubling every day up to 8 percent, average credit 4.33M). the pot is booked by donation so every number is a
/// closed form. these replace the golden test of the defaults of the old Econ: the numbers are of the new rules
contract LaunchSettingsExactNumbers is ReviewEconBase {
    function test_scenarioAtTheLaunchSettings() public {
        vm.deal(address(core), 10 ether);
        core.skim();
        assertEq(core.ethPot(), 10 ether);
        assertEq(core.ethRate(), 4e12);
        assertTrue(core.funded());
        // seven hours at 1 percent an hour from the opening rate, 4e12 * 1.01^7
        _warp(7 hours);
        assertEq(core.ethRate(), 4_288_541_408_428);
        // three credits of three different scores sell in one call at the flat price: 4.33e6 * rate / 1e4, and the
        // rate drops by 20 percent of the share of the pot spent after each
        uint256[] memory ids = _credits(seller, 3);
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        assertEq(seller.balance - before, 5_570_608_388_644_001, "the three prices paid");
        uint256[3] memory prices = [uint256(1_856_938_429_849_324), 1_856_869_465_443_106, 1_856_800_493_351_571];
        for (uint256 i; i < 3; ++i) {
            (,, uint256 cost,) = core.creditInfo(ids[i]);
            assertEq(cost, prices[i], "cost basis is the flat price");
        }
        assertEq(core.rateAtCheckpoint(), 4_288_063_541_738);
        assertEq(core.ethPot(), 9_994_429_391_611_355_999);
        assertEq(core.lastFillTime(), block.timestamp);
        // forty hours later: 24 hours at 1 percent, then 16 hours at 2 percent
        _warp(40 hours);
        assertEq(core.ethRate(), 7_474_410_246_507);
        // the funded clamp of the hourly cap is 20 percent of the pot over 4.33M, 4.6e15, far above the rate cap of
        // 8 * rateStart, so after a long climb the rate sits at the rate cap
        _warp(10_000 hours);
        assertEq(core.ethRate(), 123_200_000_000_000);
        assertGt(core.ethPot() * 2000 / 4_330_000, core.ethRate());
        _solvent();
    }
}

/// @notice the reimbursement cap and the sale at the reserve, and the statement that arrives from outside
contract ReserveSaleAndOutsiders is ReviewEconBase {
    /// E-6: the reimbursement is paid at compose and is part of the cost the statement then lists against. the cap is
    /// 5 percent of the page cost whatever the reserve is, and the keeper is paid 110 percent of gas at most, so the
    /// sale under cost adds no farm. at the reserve the pot gets back 0.45 of the cost and the buyback pot 0.45
    function test_POC_reimbursementCapAndTheReserveSale() public {
        composeBasefee = 400 gwei;
        uint256 before = keeper.balance;
        (uint256 sid, uint256 cost) = _composeOne();
        uint256 reimb = keeper.balance - before;
        uint256 pageCost = cost - reimb;
        assertEq(reimb, pageCost * 500 / 10_000, "capped at 5 percent of the page cost");
        uint256 reserve = _live(sid).reserve;
        assertEq(reserve, cost * 11_000 / 10_000, "the reserve is the 110 percent opening ask of the cost with the reimbursement in it");

        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        _bid(funder, sid, reserve);
        _endAuction(sid);
        assertEq(_collectSales(), reserve);
        uint256 toBuyback = reserve * 5_000 / 10_000;
        assertEq(core.ethToBuyback() - bb, toBuyback);
        assertEq(core.ethPot() - pot, reserve - toBuyback);
        assertGt(reserve, cost, "sold above cost at the opening ask");
        // the engine paid pageCost + reimb for it and got back 1.1 of that, half of it to the buyback
        emit log_named_uint("reimbursement, bps of page cost", reimb * 10_000 / pageCost);
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
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.None));
        vm.expectRevert(Core.NotListed.selector);
        core.syncStatement(sid);
        vm.expectRevert(Core.NotListed.selector);
        core.repriceStatement(sid);
        _enterPhase2();
        vm.expectRevert(Core.NotHeld.selector);
        core.exitStatement(sid);
        ScriptedController sc = new ScriptedController();
        _setController(address(sc));
        sc.setOverprint(true, sid + 1_000, sid);
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();
        sc.setOverprint(true, sid, sid + 1_000);
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();
        _solvent();

        // sent back before the record is settled: the record is still live and the statement returned
        vm.revertToState(snap);
        _bid(a, sid, reserve);
        _endAuction(sid);
        vm.prank(a);
        STATEMENTS.safeTransferFrom(a, address(core), sid);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Returned));
        core.syncStatement(sid);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Listed));
        assertEq(STATEMENTS.ownerOf(sid), address(house));
        assertEq(core.heldStatements().length, 1);
        assertEq(_live(sid).reserve, _reserveFor(_costOf(sid)), "back on the house at the current reserve");
        assertEq(_collectSales(), reserve, "the proceeds of the first sale are still the core's");
    }

    function _costOf(uint256 sid) internal view returns (uint256 cost) {
        (,, cost,) = core.statementInfo(sid);
    }
}

/// @notice a model of the rate written independently of the Core loop: the climb is credited tier by tier from the
/// fill clock for exactly the time the pot could afford an average credit, and never past the clamp, and a fill drops
/// the rate by the spec formula. the fuzz drives warps, fees, donations, fills and changes of the settings and compares
/// after every step
contract RateModelFuzz is ReviewEconBase {
    uint256 internal mRate;
    uint256 internal mTime;
    uint256 internal mLast;
    bool internal mFunded;

    function setUp() public override {
        super.setUp();
        mRate = core.rateAtCheckpoint();
        mTime = core.checkpointTime();
        mLast = core.lastFillTime();
    }

    /// the model rate at `to`, from its checkpoint, under the settings now
    function _modelAt(uint256 to) internal view returns (uint256 r) {
        r = mRate;
        if (!mFunded) return r;
        Settings memory s = core.settings();
        uint256 cap = core.ethPot() * s.spendCapBps / s.avgScore;
        if (cap > s.rateCap) cap = s.rateCap;
        uint256 t = mTime;
        while (t < to && r < cap) {
            uint256 k = t > mLast ? (t - mLast) / s.climbDoubleEvery : 0;
            uint256 bps = k >= 16 ? s.climbMaxBps : uint256(s.climbBaseBps) << k;
            if (bps > s.climbMaxBps) bps = s.climbMaxBps;
            uint256 end = mLast + (k + 1) * uint256(s.climbDoubleEvery);
            if (end > to || k >= 11) end = to;
            r = _climbed(r, bps, end - t);
            t = end;
        }
        if (r > cap) r = cap;
    }

    /// a checkpoint of the model at now, before an op that changes the pot, the settings or the fill clock
    function _checkpoint() internal {
        mRate = _modelAt(block.timestamp);
        mTime = block.timestamp;
    }

    function _syncFunded() internal {
        Settings memory s = core.settings();
        mFunded = core.ethPot() * s.spendCapBps >= uint256(s.avgScore) * mRate;
    }

    function _sell(uint256 seed) internal {
        uint256[] memory ids = _credits(seller, 1);
        _checkpoint();
        uint256 pot = core.ethPot();
        uint256 before = seller.balance;
        vm.prank(seller);
        try core.sellForEth(ids) {
            uint256 x = seller.balance - before;
            mRate = mRate - mRate * core.settings().dropBps * x / (10_000 * pot);
            mLast = block.timestamp;
            _syncFunded();
        } catch {}
        seed;
    }

    function _settingsOp(uint256 seed) internal {
        _checkpoint();
        Settings memory s = core.settings();
        // forge-lint: disable-start(unsafe-typecast)
        s.climbBaseBps = uint16(seed % 1_001);
        s.climbMaxBps = uint16(uint256(s.climbBaseBps) + (seed >> 12) % (2_001 - s.climbBaseBps));
        s.climbDoubleEvery = uint32(1 hours + (seed >> 24) % 10 days);
        s.avgScore = uint32(800_000 + (seed >> 48) % 5_200_001);
        s.spendCapBps = uint16(100 + (seed >> 72) % 4_901);
        s.dropBps = uint16(500 + (seed >> 96) % 4_501);
        s.rateCap = uint64(1e13 + (seed >> 120) % (1e15 - 1e13 + 1));
        // forge-lint: disable-end(unsafe-typecast)
        _setSettings(s);
        // a lower rate cap pulls the rate down to it at the checkpoint
        if (mRate > s.rateCap) mRate = s.rateCap;
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
                assertEq(core.ethRate(), r, "unfunded, no climb");
                vm.warp(block.timestamp - 2 days);
            }
        }
    }

    /// a fixed walk through the tiers, a fill and a change of the doubling, so the fuzz is known to reach them
    function test_modelAcrossTheTiersAFillAndAChange() public {
        _skipSniperWindow();
        uint256[10] memory ops = [uint256(3), 0, 4, 0, 5, 0, 4, 1, 3, 0];
        for (uint256 i; i < ops.length; ++i) {
            uint256 seed = (uint256(keccak256(abi.encode("walk", i))) / 6) * 6 + ops[i];
            _step(seed);
            assertApproxEqRel(core.ethRate(), _modelAt(block.timestamp), 1e10, "rate equals the model");
        }
        assertTrue(core.funded(), "the walk ended funded");
        assertTrue(core.ethRate() != 4e12, "and the rate moved");
    }
}
