// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane, Settings} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";

/// regressions and attack tests for docs/REVIEW-core.md, on the real stack. the exit token buyback is the dutch
/// auction inside the core (unchanged by the flow rework, its half life and slice are settings now), so its attacks
/// are written against that: nobody gets exit token for less coin than the
/// quote, nothing but the clock lowers the price, a fill never takes more than `xToBuyback`, and every fill restarts
/// the price at max(2 * clearing, previous start / 4)
contract ReviewCoreTest is Fixture {
    using FixedPointMathLib for uint256;

    address internal rseller;
    address internal taker;
    address internal attacker;

    function setUp() public virtual override {
        super.setUp();
        rseller = _user("rseller");
        taker = _user("taker");
        attacker = _user("attacker");
    }

    // ------------------------------------------------------------------ R3 unitPerPoint is fixed at set time

    /// R3 regression: the module lowers its own unit before the exit. the core requires the unit it stored when the
    /// module was set, so the underpaid exit reverts and the statement stays
    function test_FIXED_loweredUnitCannotTakeStatementForDust() public {
        _enterPhase2();
        Composed memory c = _composeOnce();
        vm.warp(c.at + 105 hours);

        mod.setUnitPerPoint(1);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(house), "the statement never left: its listing is intact");
        assertEq(uint256(_live(c.sid).status), uint256(ICore.StatementStatus.Listed));
        assertEq(core.unitPerPoint(), UNIT, "the stored unit did not move");
        _solvent();
    }

    /// R3 regression: the module raises its unit. the bid still pays at the stored unit, so a junk credit gets the
    /// fair price
    function test_FIXED_raisedUnitCannotDrainBidPot() public {
        _enterPhase2();
        Composed memory c = _composeOnce();
        vm.warp(c.at + 105 hours);
        core.exitStatement(c.sid);
        uint256 pot = core.xPot();
        assertGt(pot, 0);

        uint256[] memory ids = _credits(rseller, 1);
        uint256 fair = core.scoreOf(ids[0]) * core.xRate() * UNIT / 10_000;
        mod.setUnitPerPoint(UNIT * 100);
        vm.prank(rseller);
        core.sellForExitToken(ids);

        assertEq(xt.balanceOf(rseller), fair, "paid the fair price at the stored unit");
        assertLt(xt.balanceOf(rseller) * 2, pot, "far less than half of the pot");
        _solvent();
    }

    // ------------------------------------------------------------------ R1 the exit token buyback is a dutch auction

    /// @dev phase 2 with two statements exited, so `xToBuyback` holds about four full slices. the auction clock
    /// started at the first exit
    function _auction() internal returns (uint256 sid1, uint256 sid2) {
        _enterPhase2();
        _skipSniperWindow();
        Composed memory c = _composeOnce();
        sid1 = c.sid;
        _fillEthPile(80);
        vm.prank(keeper);
        core.compose();
        sid2 = STATEMENTS.supply();
        vm.warp(block.timestamp + core.settings().exitAfter + 2 hours);
        core.exitStatement(sid1);
        core.exitStatement(sid2);
        assertGt(core.xToBuyback(), 3 * _fullSlice(), "about four slices for sale");
    }

    function _fullSlice() internal view returns (uint256) {
        Settings memory s = core.settings();
        return uint256(s.exitSliceCredits) * s.avgScore * UNIT;
    }

    /// @dev `who` buys coin in the real pool and approves the core
    function _equip(address who, uint256 ethIn) internal {
        _buyCoin(who, ethIn);
        vm.prank(who);
        coin.approve(address(core), type(uint256).max);
    }

    /// @dev lets the clock run until a fill costs at most `1 / share` of what `who` holds
    function _waitUntilCheap(address who, uint256 share) internal returns (uint256 slice, uint256 coinIn) {
        for (uint256 i; i < 2000; ++i) {
            (slice, coinIn) = core.exitAuctionQuote();
            if (coinIn * share <= coin.balanceOf(who)) return (slice, coinIn);
            vm.warp(block.timestamp + 1 hours);
        }
        revert("never cheap");
    }

    /// @dev the least coin that pays for `slice` at `price`: the rounding is up
    function _ceilCost(uint256 slice, uint256 price) internal pure returns (uint256) {
        return (slice * price + 1e18 - 1) / 1e18;
    }

    /// R1 attack: nobody gets exit token for less coin than the quoted price. a cap below the quote reverts, the
    /// coin burned is exactly the rounded up quote, the payer is always the caller, and an approval of someone else
    /// is no help. this holds for fills at any time, checked over a spread of delays
    function test_attack_noExitTokenForLessCoinThanTheQuote() public {
        _auction();
        _equip(attacker, 30 ether);
        address victim = _user("victim");
        _equip(victim, 30 ether);
        (uint256 slice, uint256 coinIn) = _waitUntilCheap(attacker, 8);

        // a cap one wei short of the quote, a missing approval and a stranger without coin all fail
        vm.prank(attacker);
        vm.expectRevert(ICore.Slippage.selector);
        core.buybackExit(coinIn - 1);
        address stranger = _user("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        core.buybackExit(type(uint256).max);
        // the victim's approval of the core does not let the attacker spend the victim's coin: only the caller pays
        uint256 victimCoin = coin.balanceOf(victim);
        uint256 supply0 = coin.totalSupply();
        uint256 held = coin.balanceOf(attacker);
        uint256 price = core.exitAuctionPrice();
        vm.prank(attacker);
        core.buybackExit(coinIn);
        assertEq(coin.balanceOf(victim), victimCoin, "the victim paid nothing");
        assertEq(held - coin.balanceOf(attacker), coinIn, "the attacker paid the quote");
        assertEq(supply0 - coin.totalSupply(), coinIn, "and it was burned");
        assertEq(coinIn, _ceilCost(slice, price), "the quote is the rounded up price of the slice");
        assertGe(coinIn * 1e18, slice * price, "never below the price");
        assertLt((coinIn - 1) * 1e18, slice * price, "and not a wei more than needed");
        assertEq(xt.balanceOf(attacker), slice);

        // later fills at other delays keep the same rule
        uint256[4] memory delays = [uint256(0), 1 minutes, 37 minutes, 5 hours];
        for (uint256 i; i < delays.length; ++i) {
            vm.warp(block.timestamp + delays[i]);
            (slice, coinIn) = core.exitAuctionQuote();
            price = core.exitAuctionPrice();
            if (slice == 0 || coinIn > coin.balanceOf(attacker)) break;
            supply0 = coin.totalSupply();
            vm.prank(attacker);
            core.buybackExit(coinIn);
            assertGe((supply0 - coin.totalSupply()) * 1e18, slice * price, "burned at least the price of the slice");
            assertEq(supply0 - coin.totalSupply(), _ceilCost(slice, price));
        }
        _solvent();
    }

    /// R1 attack: nothing but the clock lowers the price. a hostile actor runs every other door in the same block,
    /// the price and its start stay put, and later the price equals the plain halving of the stored start price. an exit into a non empty pot re anchors
    function test_attack_nothingButTheClockLowersThePrice() public {
        (, uint256 sid2) = _auction();
        _fillEthPile(80);
        vm.prank(keeper);
        core.compose();
        uint256 sid3 = sid2 + 1;
        vm.warp(block.timestamp + 5 hours);
        uint256 price = core.exitAuctionPrice();
        uint256 startPrice = core.xStartPrice();
        uint64 startTime = core.xStartTime();
        assertLt(price, startPrice);

        // the doors a hostile actor can reach without paying: donations and skim of both assets, sales into both bids,
        // the exit of another statement into a pot that is not empty
        vm.deal(attacker, 5 ether);
        vm.prank(attacker);
        (bool ok,) = address(core).call{value: 5 ether}("");
        assertTrue(ok);
        xt.mint(address(core), 1000e18);
        core.skim();
        uint256[] memory ids = _credits(attacker, 3);
        vm.startPrank(attacker);
        core.sellForExitToken(_one(ids[0]));
        core.sellForEth(_one(ids[1]));
        vm.stopPrank();
        assertEq(core.exitAuctionPrice(), price, "same block, same price");
        assertEq(core.xStartPrice(), startPrice);
        assertEq(core.xStartTime(), startTime, "the clock was not restarted by the doors");
        _solvent();

        // exiting another statement while the pot is not empty adds supply and re anchors the curve at
        // max(price now, start / 4), restarting the clock
        vm.warp(core.settings().exitAfter + block.timestamp);
        uint256 pricePlain = core.exitAuctionPrice();
        uint256 slices = core.xToBuyback();
        core.exitStatement(sid3);
        assertGt(core.xToBuyback(), slices, "more for sale");
        uint256 anchored = pricePlain.max(startPrice / 4);
        assertEq(core.xStartPrice(), anchored, "re anchored at the price now, floored at a quarter");
        assertEq(core.exitAuctionPrice(), anchored, "and the new funds start a fresh clock");
        assertEq(core.xStartTime(), block.timestamp);

        // the price is the halving of the stored start price, to the wei on whole half lives
        startPrice = anchored;
        startTime = core.xStartTime();
        uint256 hl = core.settings().xAuctionHalfLife;
        uint256 halvings = (block.timestamp - startTime) / hl;
        vm.warp(startTime + (halvings + 1) * hl);
        assertEq(core.exitAuctionPrice(), startPrice >> (halvings + 1));
    }

    /// R1 attack: fills cannot exceed `xToBuyback`. the buyers together take exactly what was queued, never a unit of
    /// the bid pot, whatever was donated, and an empty buyback refuses even with a full bid pot
    function test_attack_fillsCannotExceedXToBuyback() public {
        _auction();
        // a donation of exit token lands in the bid pot, not in the buyback
        xt.mint(address(core), 500e18);
        core.skim();
        uint256 queued = core.xToBuyback();
        uint256 bidPot = core.xPot();
        assertGt(bidPot, 500e18);
        _equip(attacker, 40 ether);

        uint256 taken;
        for (uint256 i; i < 10 && core.xToBuyback() != 0; ++i) {
            (uint256 slice, uint256 coinIn) = _waitUntilCheap(attacker, 1);
            assertLe(slice, core.xToBuyback(), "a slice is never more than the pot");
            assertLe(slice, _fullSlice(), "nor more than 20 average credits");
            vm.prank(attacker);
            core.buybackExit(coinIn);
            taken += slice;
        }
        assertEq(core.xToBuyback(), 0, "drained");
        assertEq(taken, queued, "exactly what was queued");
        assertEq(xt.balanceOf(attacker), queued);
        assertEq(core.xPot(), bidPot, "the bid pot was never touched");
        assertEq(xt.balanceOf(address(core)), bidPot, "and is still backed");

        vm.warp(block.timestamp + 1000 hours);
        vm.prank(attacker);
        vm.expectRevert(ICore.NothingToBuy.selector);
        core.buybackExit(type(uint256).max);
        (uint256 s, uint256 c) = core.exitAuctionQuote();
        assertEq(s, 0);
        assertEq(c, 0);
        _solvent();
    }

    /// R1 attack: a fill restarts the price at max(2 * clearing, previous start / 4). two fills in one block: the
    /// first restarts by that rule, the second clears at that restart and doubles it
    function test_attack_repeatedFillsRestartByTheRule() public {
        _auction();
        _equip(attacker, 40 ether);
        _waitUntilCheap(attacker, 12);
        uint256 p = core.exitAuctionPrice();
        uint256 startBefore = core.xStartPrice();
        uint256[2] memory paid;
        uint256[2] memory prices;
        for (uint256 i; i < 2; ++i) {
            (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
            prices[i] = core.exitAuctionPrice();
            uint256 before = coin.balanceOf(attacker);
            uint256 startNow = core.xStartPrice();
            vm.prank(attacker);
            core.buybackExit(coinIn);
            paid[i] = before - coin.balanceOf(attacker);
            assertEq(paid[i], _ceilCost(slice, prices[i]));
            assertEq(core.xStartPrice(), (2 * prices[i]).max(startNow / 4), "max(2 * clearing, start / 4)");
            assertEq(core.xStartTime(), block.timestamp);
        }
        assertEq(prices[0], p);
        assertEq(prices[1], (2 * p).max(startBefore / 4));
        // the restart never makes the next fill cheaper than a quarter of the last start
        assertGe(prices[1], startBefore / 4);
        // and the restarted price decays again at the same rate
        vm.warp(block.timestamp + 6 hours);
        assertEq(core.exitAuctionPrice(), prices[1]);
        _solvent();
    }

    /// R1 documented decay: the price can reach zero, and only by waiting. the halvings run out after as many half
    /// lives as the start price has bits (about 540 hours), one half life earlier it is still one wei per unit and the
    /// fill still costs coin. the one who waits that long takes the slice for nothing, but the next price restarts at a
    /// quarter of the start just played, so the rest of the queue is not cheap
    function test_attack_decayToZeroNeedsWaitingAndRestartsAtAQuarter() public {
        _auction();
        _equip(attacker, 40 ether);
        uint256 start = core.xStartPrice();
        uint64 t0 = core.xStartTime();
        uint256 hl = core.settings().xAuctionHalfLife;
        uint256 bits;
        for (uint256 v = start; v != 0; v >>= 1) {
            ++bits;
        }
        assertGt(bits, 80, "a start price of about 2^90, so about 90 half lives of waiting");
        assertLt(bits, 128);

        vm.warp(t0 + (bits - 1) * hl);
        assertEq(core.exitAuctionPrice(), 1, "one wei per unit a half life before the end");
        (, uint256 coinIn) = core.exitAuctionQuote();
        assertGt(coinIn, 0, "the rounding up keeps a fill from being free until the price is zero");

        vm.warp(t0 + bits * hl);
        assertEq(core.exitAuctionPrice(), 0);
        uint256 supply = coin.totalSupply();
        (uint256 slice,) = core.exitAuctionQuote();
        vm.prank(attacker);
        core.buybackExit(0);
        assertEq(xt.balanceOf(attacker), slice, "the patient one got the slice for nothing");
        assertEq(coin.totalSupply(), supply);

        // the next slice is quoted from a quarter of the start just played: a quarter of the opening cost
        assertEq(core.xStartPrice(), start / 4);
        (slice, coinIn) = core.exitAuctionQuote();
        assertEq(coinIn, slice.mulDivUp(start / 4, 1e18));
        assertGt(coinIn, 1e26, "a quarter of the whole supply for a full slice, not dust");
        vm.prank(attacker);
        vm.expectRevert(ICore.Slippage.selector);
        core.buybackExit(coinIn - 1);
        // the whole queue cannot be taken for dust: every further slice needs its own decay, see
        // test_drainingSlicesAtDustNeedsSeparateDecays in Fees.t.sol
        assertGt(core.xToBuyback(), 0);
        _solvent();
    }

    /// the slice and the half life are settings: the next quote takes the slice of the new setting, the price at the
    /// moment of the change is kept and then halves at the new half life, and a fill burns the quoted coin
    function test_attack_sliceSizeAndHalfLifeAreSettings() public {
        _auction();
        Settings memory s = core.settings();
        s.exitSliceCredits = 5;
        s.xAuctionHalfLife = 2 hours;
        _setSettings(s);
        (uint256 slice,) = core.exitAuctionQuote();
        assertEq(slice, 5 * s.avgScore * UNIT, "five average credits");
        uint256 price = core.exitAuctionPrice();
        vm.warp(block.timestamp + 2 hours);
        assertEq(core.exitAuctionPrice(), price >> 1, "halves at the new half life");
        vm.warp(block.timestamp + 4 hours);
        assertEq(core.exitAuctionPrice(), price >> 3);

        _equip(attacker, 30 ether);
        uint256 coinIn;
        (slice, coinIn) = _waitUntilCheap(attacker, 8);
        assertEq(slice, 5 * s.avgScore * UNIT);
        uint256 supply = coin.totalSupply();
        vm.prank(attacker);
        core.buybackExit(coinIn);
        assertEq(xt.balanceOf(attacker), slice);
        assertEq(supply - coin.totalSupply(), coinIn);
        _solvent();
    }

    // ------------------------------------------------------------------ attempts that held

    /// the core approved Statements for all its credits. a third party cannot use that approval.
    function test_held_thirdPartyCannotComposeCoreCredits() public {
        _fillEthPile(80);
        uint256[80] memory ids;
        uint256[] memory page = core.pilePage(Lane.Eth, 0, 80);
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        vm.startPrank(attacker);
        vm.expectRevert();
        STATEMENTS.compose(ids, 0);
        (bool ok,) = address(STATEMENTS)
            .call(abi.encodeWithSignature("compose(uint256[80],uint8,address)", ids, uint8(0), attacker));
        assertFalse(ok, "the three argument compose pulled core credits");
        vm.stopPrank();
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
    }

    /// ten years without a checkpoint, funded. the climb stops at the funded threshold and the read is cheap.
    function test_held_tenYearGapRateRead() public {
        _skipSniperWindow();
        _fundPot(5 ether);
        uint256 pot = core.ethPot();
        vm.warp(block.timestamp + 3650 days);
        uint256 g = gasleft();
        uint256 r = core.ethRate();
        g -= gasleft();
        uint256 clamp = pot * 2000 / core.settings().avgScore;
        uint256 cap = core.settings().rateCap;
        assertEq(r, clamp < cap ? clamp : cap, "clamped at the funded threshold or the rate cap");
        assertLt(g, 400_000, "gas of the read");
        emit log_named_uint("gas of a ten year read", g);
        // a checkpointing call after the gap still works
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok);
        core.skim();
        assertEq(core.ethPot(), pot + 1 ether);
    }
}
