// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {Lane, Mainnet, Econ} from "../src/interfaces/Interfaces.sol";
import {econ} from "./Econ.t.sol";
import {GateBase} from "./Gate.t.sol";

/// @notice independent review of the economics options commit (docs/REVIEW-econ.md). the proofs and the fuzz
/// and differential tests. everything runs on the real stack of the Fixture
abstract contract ReviewEconBase is Fixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant LEN = 72 hours;

    /// reference price, written from the spec text and not from the Core code: linear between the two multiples
    /// in integer bps seconds, rounded up
    function _refPrice(uint256 cost, uint256 startX, uint256 floorX, uint256 elapsed) internal pure returns (uint256) {
        uint256 e = elapsed > LEN ? LEN : elapsed;
        uint256 num = cost * (startX * LEN - (startX - floorX) * e);
        uint256 den = LEN * 10_000;
        return (num + den - 1) / den;
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

/// @notice the price curve under the default, the recommended and two extreme dial sets
abstract contract PriceCurve is ReviewEconBase {
    using FixedPointMathLib for uint256;

    function _dials() internal pure virtual returns (uint256 s, uint256 f, uint256 d, uint256 g);

    function _econ() internal pure override returns (Econ memory) {
        (uint256 s, uint256 f, uint256 d, uint256 g) = _dials();
        return econ(s, f, d, g);
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_priceEqualsTheReferenceAndIsMonotonic(uint256 t1, uint256 t2) public {
        (uint256 s, uint256 f,,) = _dials();
        (uint256 sid, uint256 cost) = _composeOne();
        uint256 t0 = vm.getBlockTimestamp();
        assertEq(core.priceOf(sid), _refPrice(cost, s, f, 0), "ref at t0");
        assertEq(core.priceOf(sid), cost.mulDivUp(s, 10_000), "t0 is cost times the start multiple, rounded up");
        t1 = bound(t1, 0, 200 hours);
        t2 = bound(t2, t1, 400 hours);
        vm.warp(t0 + t1);
        uint256 p1 = core.priceOf(sid);
        assertEq(p1, _refPrice(cost, s, f, t1), "ref at t1");
        vm.warp(t0 + t2);
        uint256 p2 = core.priceOf(sid);
        assertEq(p2, _refPrice(cost, s, f, t2), "ref at t2");
        assertLe(p2, p1, "never rises");
        assertGe(p2 * 10_000, cost * f, "never below the floor");
        vm.warp(t0 + LEN);
        assertEq(core.priceOf(sid), cost.mulDivUp(f, 10_000), "exact at the auction length");
        vm.warp(t0 + LEN - 1);
        assertGe(core.priceOf(sid), cost.mulDivUp(f, 10_000));
    }

    /// the sale splits the price exactly and the pot plus the buyback pot receive the whole price
    function test_saleSplitHoldsAtTheFloor() public {
        (uint256 sid,) = _composeOne();
        vm.warp(block.timestamp + 90 hours);
        uint256 price = core.priceOf(sid);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        address b = _user("buyer");
        vm.deal(b, price);
        vm.prank(b);
        core.buyStatement{value: price}(sid);
        assertEq(core.ethPot() - pot + core.ethToBuyback() - bb, price);
        _solvent();
    }
}

contract PriceDefault is PriceCurve {
    function _dials() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (40_000, 12_000, 1_000, 0);
    }
}

contract PriceRecommended is PriceCurve {
    function _dials() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (20_000, 8_000, 2_000, 20);
    }
}

contract PriceLowBounds is PriceCurve {
    function _dials() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (15_000, 6_000, 4_000, 5);
    }
}

contract PriceNarrow is PriceCurve {
    /// the closest start and floor the bounds allow
    function _dials() internal pure override returns (uint256, uint256, uint256, uint256) {
        return (15_000, 12_000, 1_000, 200);
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
        if (lane == Lane.Exit && (mode == 1 || mode == 3)) startAfter = 0;
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

/// @notice differential against the commit before the economics options. the numbers below were produced by running
/// the same scenario (zero basefee, so no gas metered reimbursement) on the previous commit with its constants, and
/// the default dials must reproduce them exactly. with a nonzero basefee the pot and the statement cost differ by
/// the reimbursement of the extra gas of the counter writes, see finding E-8
contract DefaultsReproduceThePreviousCommit is ReviewEconBase {
    function test_scenarioMatchesTheGoldenNumbers() public {
        _skipSniperWindow();
        _fillEthPile(80);
        assertEq(core.ethRate(), 3928495393967, "a");
        _warp(7 hours);
        assertEq(core.ethRate(), 4211878792461, "b");
        _fillEthPile(10);
        assertEq(core.ethRate(), 4202593257024, "c");
        assertEq(core.ethPot(), 510504760432588151);
        _warp(40 hours);
        assertEq(core.ethRate(), 7325429251793, "d");
        _fillEthPile(80);
        assertEq(core.ethRate(), 7194490860661, "e");
        assertEq(core.ethPot(), 1007745693518155009);
        vm.fee(0);
        uint256 sid = STATEMENTS.supply() + 1;
        vm.prank(keeper);
        core.compose();
        (,, uint256 cost,) = core.statementInfo(sid);
        assertEq(cost, 103308502102358303, "cost");
        assertEq(core.priceOf(sid), 413234008409433212, "4x");
        _warp(11 hours);
        assertEq(core.priceOf(sid), 369040926954535494);
        _warp(11 hours * 6);
        assertEq(core.priceOf(sid), 123970202522829964, "1.2x");
        _warp(11 hours);
        assertEq(core.ethRate(), 129031988222434, "f");
        uint256 price = core.priceOf(sid);
        address b = _user("buyer");
        vm.deal(b, price);
        vm.prank(b);
        core.buyStatement{value: price}(sid);
        assertEq(core.ethPot(), 1069730794779569991, "g pot");
        assertEq(core.ethToBuyback(), 61985101261414982, "g buyback");
        _warp(100 hours);
        assertEq(core.ethRate(), 494101983731902, "h");
        _fillEthPile(5);
        assertEq(core.ethRate(), 485410881821068, "i");
    }
}

/// @notice gate proofs under the recommended dials with the gate at 5 (the fixture has too few real credits for 20)
contract GateProofs is GateBase {
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    function _econ() internal pure override returns (Econ memory) {
        return econ(20_000, 8_000, 2_000, GATE);
    }

    /// closes the bid with the climb at its first tier, then lets fees grow the pot while it is closed
    function _closeAndGrowPot(uint256 days_, uint256 potTarget) internal returns (uint256 sid, uint256 r0) {
        sid = _composeNext();
        assertTrue(_gated());
        r0 = core.rateAtCheckpoint();
        _warp(days_ * 1 days);
        _fundPot(potTarget);
    }

    /// E-3: the stored rate is honoured at reopening against a pot grown while the bid was closed. the first hour can
    /// take 20 percent of the grown pot and the rate falls by only DROP_BPS times the fraction spent. the fixture pot
    /// is set to a size the 640 real credits can exhaust, as if fees had grown it to 0.8 eth while the bid was closed
    function test_POC_staleBidAfterTheGateAgainstAGrownPot() public {
        (uint256 sid, uint256 r0) = _closeAndGrowPot(20, core.ethPot());
        assertEq(core.ethRate(), r0, "frozen for 20 days");
        stdstore.target(address(core)).sig("ethPot()").checked_write(uint256(0.8 ether));
        _buy(sid);
        assertFalse(_gated());
        uint256 potAtOpen = core.ethPot();
        uint256 paid;
        uint256 n;
        while (n < 190) {
            uint256[] memory ids = _credits(seller, 1);
            uint256 c = core.ceilingOf(ids[0]);
            if (paid + c > potAtOpen * 2000 / 10_000) break;
            vm.prank(seller);
            core.sellForEth(ids);
            paid += c;
            ++n;
        }
        // the window is spent to within one credit of 20 percent of the pot and the rate barely moved
        assertGe(paid * 10_000, potAtOpen * 1900);
        uint256 r1 = core.ethRate();
        assertLe(r1, r0);
        assertGe(r1 * 100, r0 * 95, "20 percent of the pot spent, the rate fell by less than 5 percent");
        emit log_named_uint("credits sold in the first window", n);
        emit log_named_uint("pot at reopening (wei)", potAtOpen);
        emit log_named_uint("paid in the first window (wei)", paid);
        emit log_named_uint("rate after, per 10000 of the frozen rate", r1 * 10_000 / r0);
    }

    /// E-4: one purchase of a statement reopens the bid, and the buyer can sell a full page into it and compose the
    /// page in the same transaction, which closes the bid again. the next honest seller finds it closed. the bid is
    /// a one slot race per statement sold
    function test_POC_reopenBackrunMonopoly() public {
        uint256 sid = _composeNext();
        assertTrue(_gated());
        address attacker = _user("backrunner");
        address honest = _user("honest seller");
        uint256[] memory mine = _credits(attacker, 80);
        uint256[] memory theirs = _credits(honest, 1);
        _fundPot(core.ethPot() + 1 ether);
        _warp(1 hours + 1);
        uint256 price = core.priceOf(sid);
        vm.deal(attacker, price);
        uint256 before = attacker.balance;
        vm.startPrank(attacker);
        core.buyStatement{value: price}(sid);
        assertFalse(_gated(), "the sale reopened the bid");
        core.sellForEth(mine);
        vm.fee(composeBasefee);
        core.compose();
        vm.stopPrank();
        assertTrue(_gated(), "the same transaction closed it again");
        assertGt(attacker.balance + price, before, "the page sold for eth");
        vm.prank(honest);
        vm.expectRevert(Core.GateClosed.selector);
        core.sellForEth(theirs);
    }

    /// E-2: the climb tier at reopening. the fill clock ran through the closed days, so the first hours after the
    /// reopening climb at the top tier (800 bps an hour) although the bid was not open to be filled. the numbers
    /// are printed against the first tier (100 bps), which is what a reset of `lastFillTime` would give
    function test_POC_reopenClimbsAtTheTopTier() public {
        (uint256 sid, uint256 r0) = _closeAndGrowPot(5, core.ethPot());
        _buy(sid);
        assertFalse(_gated());
        assertEq(core.rateAtCheckpoint(), r0);
        assertGt(block.timestamp - core.lastFillTime(), 3 days, "the fill clock kept running");
        uint256 t0 = vm.getBlockTimestamp();
        uint256[4] memory hrs = [uint256(1), 3, 6, 12];
        for (uint256 i; i < 4; ++i) {
            vm.warp(t0 + hrs[i] * 1 hours);
            uint256 top = core.ethRate();
            uint256 first = _climbed(r0, 100, hrs[i] * 1 hours);
            assertEq(top, _climbed(r0, 800, hrs[i] * 1 hours), "top tier from the first second");
            emit log_named_uint(
                string.concat("rate after ", vm.toString(hrs[i]), "h, bps of frozen rate"), top * 10_000 / r0
            );
            emit log_named_uint("  with the first tier instead", first * 10_000 / r0);
        }
    }

    /// E-5: phase 1 has no exit module and the controller never overprints, so once the gate is closed only a
    /// statement purchase reopens it. with no buyer the engine stalls for good: the pot only grows, the buyback pot
    /// is fed by nothing, and sales stay reverted. nothing a keeper can do changes it
    function test_POC_phase1StallWithNoStatementBuyer() public {
        _composeNext();
        assertTrue(_gated());
        uint256 bb = core.ethToBuyback();
        uint256 pot = core.ethPot();
        for (uint256 i; i < 6; ++i) {
            _warp(60 days);
            _buyCoin(funder, 0.2 ether);
        }
        assertGt(core.ethPot(), pot, "fees keep landing in the pot");
        assertEq(core.ethToBuyback(), bb, "nothing feeds the buyback pot");
        assertEq(core.exitModule(), address(0));
        _expectClosed();
        uint256[] memory held = core.heldStatements();
        for (uint256 i; i < held.length; ++i) {
            vm.expectRevert(Core.NoExitModule.selector);
            core.exitStatement(held[i]);
        }
        vm.expectRevert(Core.NotReady.selector);
        core.overprint();
        // every held statement sits at the floor, 0.8x of its cost, and one purchase reopens the bid
        (,, uint256 cost,) = core.statementInfo(held[0]);
        assertEq(core.priceOf(held[0]), cost.mulDivUp(8_000, 10_000));
        _buy(held[0]);
        assertFalse(_gated());
    }

    /// E-6: the reimbursement is paid at compose and is part of the cost the statement then sells against. the cap
    /// is 5 percent of the page cost whatever the floor is, and the keeper is paid 110 percent of gas at most, so the
    /// sale below cost adds no farm. at the floor the pot gets back 0.4 of the cost and the buyback pot 0.4
    function test_POC_reimbursementCapAndTheFloorSale() public {
        composeBasefee = 400 gwei;
        uint256 before = keeper.balance;
        uint256 potBefore = core.ethPot();
        uint256 sid = _composeNext();
        uint256 reimb = keeper.balance - before;
        (,, uint256 cost,) = core.statementInfo(sid);
        uint256 pageCost = cost - reimb;
        assertEq(reimb, pageCost * 500 / 10_000, "capped at 5 percent of the page cost");
        assertGe(potBefore, 0);
        _warp(100 hours);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        uint256 price = core.priceOf(sid);
        assertEq(price, cost.mulDivUp(8_000, 10_000));
        _buy(sid);
        uint256 toPot = core.ethPot() - pot;
        assertEq(toPot, price - price * 5000 / 10_000);
        assertEq(core.ethToBuyback() - bb, price * 5000 / 10_000);
        // the engine paid pageCost + reimb for it and got back 0.8 of that, half of it to the buyback
        emit log_named_uint("reimbursement, bps of page cost", reimb * 10_000 / pageCost);
        emit log_named_uint("pot gets back, bps of cost", toPot * 10_000 / cost);
    }

    /// a statement sent to the core from outside is accepted by the receiver hook and never counted: it is not in the
    /// held list, cannot be sold, exited or overprinted, and the counter and the gate do not move
    function test_statementSentFromOutsideIsNotCounted() public {
        uint256 sid = _composeNext();
        assertTrue(_gated());
        _warp(1 hours + 1);
        address a = _user("outsider");
        uint256 price = core.priceOf(sid);
        vm.deal(a, price);
        vm.startPrank(a);
        core.buyStatement{value: price}(sid);
        assertEq(core.ethHeld(), GATE - 1);
        STATEMENTS.safeTransferFrom(a, address(core), sid);
        vm.stopPrank();
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        assertEq(core.ethHeld(), GATE - 1, "not counted");
        assertEq(_countEth(), GATE - 1);
        vm.expectRevert(Core.NotForSale.selector);
        core.priceOf(sid);
        _enterPhase2();
        vm.expectRevert(Core.NotHeld.selector);
        core.exitStatement(sid);
        assertEq(core.ethHeld(), GATE - 1);
    }

    /// the same arithmetic over hours, no new fees: fraction of the pot gone and the rate left when the market is
    /// 40 percent under the frozen rate. every hour spends 20 percent of the then pot and the rate drops 4 percent
    function test_POC_staleBidProjection() public pure {
        uint256 pot = 1e18;
        uint256 rate = 1e18;
        uint256 overpay;
        for (uint256 h = 1; h <= 8; ++h) {
            uint256 spend = pot * 2000 / 10_000;
            overpay += spend * (rate - 6e17) / rate;
            pot -= spend;
            rate -= rate * 2000 * spend / (10_000 * (pot + spend));
        }
        // after eight hours about 83 percent of the pot is gone and the rate is still 72 percent of the frozen one,
        // above the 60 percent market. the credits sold were worth less than the eth paid by the overpay below
        assertApproxEqAbs(pot, 0.8e18 ** 8 / 1e18 ** 7, 1);
        assertGt(rate, 7e17);
        assertGt(overpay, 0.1e18);
    }
}

/// @notice the deploy path with the recommended file: the whole `deploySystem` including its postflight runs with
/// the dials of the file, the hash covers each of the four values, and a config without them does not load
contract RecommendedDeployPath is ReviewEconBase {
    function _econ() internal view override returns (Econ memory e) {
        e = loadConfig("script/config/mainnet.recommended.json").econ;
    }

    function test_deployedCoreCarriesTheFile() public view {
        assertEq(core.AUCTION_START_X(), 20_000);
        assertEq(core.AUCTION_FLOOR_X(), 8_000);
        assertEq(core.DROP_BPS(), 2_000);
        assertEq(core.INVENTORY_GATE(), 20);
        assertEq(core.ethHeld(), 0);
    }

    function test_hashCoversEachDial() public {
        bytes32 h = configHash(lc);
        Econ memory e = lc.econ;
        lc.econ.auctionStartX = e.auctionStartX + 1;
        assertTrue(configHash(lc) != h, "start");
        lc.econ = e;
        lc.econ.auctionFloorX = e.auctionFloorX + 1;
        assertTrue(configHash(lc) != h, "floor");
        lc.econ = e;
        lc.econ.dropBps = e.dropBps + 1;
        assertTrue(configHash(lc) != h, "drop");
        lc.econ = e;
        lc.econ.inventoryGate = e.inventoryGate + 1;
        assertTrue(configHash(lc) != h, "gate");
        lc.econ = e;
        assertEq(configHash(lc), h);
    }

    function test_aConfigWithoutTheDialsDoesNotLoad() public {
        vm.expectRevert();
        this.parse("{}");
    }

    function parse(string memory j) external view returns (LaunchConfig memory) {
        return parseConfig(j);
    }
}

/// @notice a model of the rate written independently of the Core loop: the climb is credited for exactly the time
/// the core was open and funded, tier by tier from the fill clock, and never past the clamp. the fuzz drives warps,
/// fee intake, composes (closing the bid) and statement purchases (reopening it) and compares after every step
contract RateModelFuzz is GateBase {
    uint256 internal mRate;
    uint256 internal mTime;
    uint256[] internal script;
    uint256 internal crossings;

    function _advance(uint256 to, bool open) internal {
        if (open) {
            uint256 cap = core.ethPot() * 2000 / core.AVG_SCORE();
            uint256 last = core.lastFillTime();
            uint256 t = mTime;
            while (t < to && mRate < cap) {
                uint256 k = (t - last) / 1 days;
                uint256 bps = k >= 3 ? 800 : 100 << k;
                uint256 end = to < last + (k + 1) * 1 days ? to : last + (k + 1) * 1 days;
                mRate = _climbed(mRate, bps, end - t);
                t = end;
            }
            if (mRate > cap && cap > 0 && core.rateAtCheckpoint() <= cap) mRate = cap;
        }
        mTime = to;
    }

    /// forge-config: default.fuzz.runs = 40
    function testFuzz_rateMatchesTheModel(uint256 seed) public {
        _run(seed);
    }

    /// a fixed walk that closes and reopens the bid three times, so the fuzz is known to cross the gate
    function test_modelAcrossThreeCrossings() public {
        uint256[12] memory ops = [uint256(0), 2, 0, 1, 3, 0, 2, 0, 3, 2, 0, 3];
        for (uint256 i; i < ops.length; ++i) {
            script.push(ops[i]);
        }
        _run(1);
        assertGe(crossings, 5, "closed and reopened");
    }

    function _run(uint256 seed) internal {
        _fillEthPile(80);
        mRate = core.rateAtCheckpoint();
        mTime = core.checkpointTime();
        uint256 composes;
        for (uint256 step; step < 14; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = script.length != 0 ? script[step % script.length] : seed % 4;
            bool wasGated = _gated();
            bool open = core.funded() && !_gated();
            uint256 now_ = vm.getBlockTimestamp();
            if (op == 0) {
                uint256 dt = 1 + (seed >> 8) % 3 days;
                vm.warp(now_ + dt);
                now_ += dt;
            } else if (op == 1) {
                _advance(now_, open);
                _buyCoin(funder, 0.05 ether);
            } else if (op == 2 && !_gated() && composes < 3) {
                ++composes;
                // the sales that fill the pile are fills, the model is synced to the core after them
                uint256 size = core.pileSize(Lane.Eth);
                if (size < 80) _fillEthPile(80 - size);
                mRate = core.rateAtCheckpoint();
                mTime = core.checkpointTime();
                now_ = vm.getBlockTimestamp();
                open = core.funded() && !_gated();
                _advance(now_, open);
                _composeNext();
            } else if (core.ethHeld() > 0) {
                uint256[] memory h = core.heldStatements();
                _advance(now_, open);
                _buy(h[(seed >> 16) % h.length]);
            }
            if (wasGated != _gated()) ++crossings;
            // the model is only compared in the state the core reports now, at the current time
            uint256 at = vm.getBlockTimestamp();
            bool openNow = core.funded() && !_gated();
            // the rate view at `at` equals the checkpointed rate climbed over the open time since the checkpoint
            _advance(at, openNow && at != mTime);
            assertApproxEqRel(core.ethRate(), mRate, 1e12, "rate equals the model");
            // a closed bid never moves between two reads
            if (_gated()) {
                uint256 r = core.ethRate();
                vm.warp(at + 2 days);
                assertEq(core.ethRate(), r, "gated, no climb");
                vm.warp(at);
            }
        }
    }
}

/// @notice DROP_BPS at both ends of its bounds: repeated fills in one block follow the formula exactly, round the
/// drop down, and the rate stays positive
abstract contract DropDials is ReviewEconBase {
    function _drop() internal pure virtual returns (uint256);

    function _econ() internal pure override returns (Econ memory) {
        return econ(40_000, 12_000, _drop(), 0);
    }

    function test_manyFillsInOneBlockFollowTheFormula() public {
        _skipSniperWindow();
        _fundPot(0.4 ether);
        uint256 r = core.ethRate();
        uint256 p = core.ethPot();
        uint256[] memory ids = _credits(seller, 40);
        uint256 p0 = p;
        for (uint256 i; i < ids.length; ++i) {
            uint256 x = core.ceilingOf(ids[i]);
            uint256 want = r - r * _drop() * x / (10_000 * p);
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
            assertEq(core.rateAtCheckpoint(), want, "drop formula, rounded down");
            r = want;
            p -= x;
            assertEq(core.ethPot(), p);
        }
        assertGt(r, 0);
        emit log_named_uint("share of the pot spent, bps", (p0 - p) * 10_000 / p0);
        emit log_named_uint("rate left, wei per point", r);
    }
}

contract DropAtTheFloorOfTheBounds is DropDials {
    function _drop() internal pure override returns (uint256) {
        return 1_000;
    }
}

contract DropAtTheCeilingOfTheBounds is DropDials {
    function _drop() internal pure override returns (uint256) {
        return 4_000;
    }
}
