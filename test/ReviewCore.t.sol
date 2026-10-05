// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Core} from "../src/Core.sol";
import {MockExitToken} from "./mocks/MockExitToken.sol";
import {MockExitModule} from "./mocks/MockExitModule.sol";
import {Lane, Mainnet} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";

/// proofs of concept for docs/REVIEW-core.md. every test passes and shows the bad outcome.
contract ReviewCoreTest is Fixture {
    address internal rseller;

    function setUp() public override {
        super.setUp();
        rseller = _user("rseller");
    }

    // ------------------------------------------------------------------ R3 unitPerPoint is fixed at set time

    /// R3 regression: the module lowers its own unit before the exit. the core requires the unit it stored when the
    /// module was set, so the underpaid exit reverts and the statement stays
    function test_FIXED_loweredUnitCannotTakeStatementForDust() public {
        _enterPhase2();
        Composed memory c = _composeOnce();
        vm.warp(c.at + 72 hours);

        mod.setUnitPerPoint(1);
        vm.expectRevert(Core.Underpaid.selector);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core), "the statement never left");
        assertEq(core.unitPerPoint(), UNIT, "the stored unit did not move");
        _solvent();
    }

    /// R3 regression: the module raises its unit. the bid still pays at the stored unit, so a junk credit gets the
    /// fair price
    function test_FIXED_raisedUnitCannotDrainBidPot() public {
        _enterPhase2();
        Composed memory c = _composeOnce();
        vm.warp(c.at + 72 hours);
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

    // ------------------------------------------------------------------ R2 pool key lp fee

    /// phase 2 setup with a chosen lp fee in the pool key and a sane limit. executes the module and the key actions
    function _phase2Key(uint24 lpFee) internal {
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), UNIT);
        (address a0, address a1) =
            address(xt) < address(coin) ? (address(xt), address(coin)) : (address(coin), address(xt));
        xKey = PoolKey({
            currency0: Currency.wrap(a0),
            currency1: Currency.wrap(a1),
            fee: lpFee,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        uint160 limit = _band();
        vm.startPrank(owner);
        core.queue(Core.Action.SetExitModule, abi.encode(address(mod)));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(xKey, limit));
        vm.warp(block.timestamp + 7 days);
        core.execute(Core.Action.SetExitModule, abi.encode(address(mod)));
        if (lpFee != 0) vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(xKey, limit));
        vm.stopPrank();
    }

    /// about 10 percent from the one to one start, in the direction the core sells
    function _band() internal view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(address(xt) < address(coin) ? int24(-1000) : int24(1000));
    }

    /// R2 regression: a 100 percent lp fee in the pool key is rejected when the action executes, so the owner
    /// cannot route buyback slices into its own position
    function test_FIXED_poolKeyLpFeeIsRejected() public {
        _phase2Key(1_000_000);
        assertEq(core.exitPoolId(), bytes32(0), "no pool key was stored");
    }

    // ------------------------------------------------------------------ R1 exit buyback price protection

    function _statementIntoBuyback() internal returns (uint256 queued) {
        Composed memory c = _composeOnce();
        vm.warp(c.at + 72 hours);
        core.exitStatement(c.sid);
        queued = core.xToBuyback();
        assertGt(queued, 0);
    }

    /// R1 regression: nobody owns the exit pool, and an account puts dust of coin in a far range. the fixed limit
    /// stops the swap long before that range, nothing is bought, the call reverts and the pot is untouched
    function test_FIXED_dustLiquidityBeyondTheLimitCannotTakeTheSlice() public {
        address thief = _user("thief");
        _phase2Key(0);
        PM.initialize(xKey, SQRT_PRICE_1_1);
        uint256 queued = _statementIntoBuyback();

        _buyCoin(thief, 1 ether);
        vm.startPrank(thief);
        coin.approve(address(lp), type(uint256).max);
        (int24 lo, int24 hi) = _exitIs0() ? (int24(-190_020), int24(-184_020)) : (int24(184_020), int24(190_020));
        lp.modify(xKey, lo, hi, int256(1e15));
        vm.stopPrank();

        uint256 coreX = xt.balanceOf(address(core));
        vm.roll(block.number + 30);
        vm.prank(keeper);
        vm.expectRevert(Core.NothingBought.selector);
        core.buybackExit();
        assertEq(xt.balanceOf(address(core)), coreX);
        assertEq(core.xToBuyback(), queued, "the unspent slice never left the buyback pot");
        assertEq(xt.balanceOf(thief), 0);
    }

    /// R1 regression: dust liquidity placed inside the band is bought, and only that. the swap stops at the limit,
    /// the unspent part of the slice returns to xToBuyback, and the pot stays fully booked
    function test_FIXED_dustLiquidityInsideTheBandOnlyTakesDust() public {
        address thief = _user("thief");
        _phase2Key(0);
        PM.initialize(xKey, SQRT_PRICE_1_1);
        uint256 queued = _statementIntoBuyback();

        _buyCoin(thief, 1 ether);
        vm.startPrank(thief);
        coin.approve(address(lp), type(uint256).max);
        (int24 lo, int24 hi) = _exitIs0() ? (int24(-780), int24(-720)) : (int24(720), int24(780));
        lp.modify(xKey, lo, hi, int256(1e15));
        vm.stopPrank();

        uint256 coreX = xt.balanceOf(address(core));
        uint256 deadBefore = coin.balanceOf(DEAD);
        vm.roll(block.number + 30);
        vm.prank(keeper);
        core.buybackExit();
        uint256 spent = coreX - xt.balanceOf(address(core));
        assertGt(coin.balanceOf(DEAD) - deadBefore, 0, "the dust was bought");
        assertLt(spent, 1e14, "only dust worth of exit token was spent");
        assertGt(core.xToBuyback(), queued - 1e14, "the rest of the slice is back in the pot");
        assertLe(xt.balanceOf(keeper), spent / 100, "the tip is scaled to what was spent");
        assertEq(xt.balanceOf(address(core)), core.xPot() + core.xToBuyback(), "nothing is left unbooked");
        _solvent();
    }

    // ------------------------------------------------------------------ exit buyback fee and partial fills

    /// seeds the exit pool at one to one with two sided liquidity over [-6000, 6000], from an lp that buys the coin.
    /// `liq` zero means deep, three times the lp's coin
    function _seedExitPool(uint256 liq) internal {
        address lper = _user("lper2");
        uint256 coinBal = _buyCoin(lper, 20 ether);
        if (liq == 0) liq = coinBal * 3;
        xt.mint(lper, 1e30);
        vm.startPrank(lper);
        coin.approve(address(lp), type(uint256).max);
        xt.approve(address(lp), type(uint256).max);
        lp.modify(xKey, -6000, 6000, int256(liq));
        vm.stopPrank();
    }

    /// a full fill: the swap amount is 90 percent of slice less tip, the hook fee is exactly 10 percent of the gross
    /// spent, and the core spends no more than the slice less tip. the whole slice is booked
    function test_exitBuyback_feeIsTenPercentOfTheGrossSpent() public {
        _phase2Key(0);
        PM.initialize(xKey, SQRT_PRICE_1_1);
        _seedExitPool(0);
        uint256 queued = _statementIntoBuyback();
        uint256 slice = 20 * core.AVG_SCORE() * UNIT;
        if (queued < slice) slice = queued;

        uint256 coreX = xt.balanceOf(address(core));
        uint256 claims0 = _hookClaims();
        uint256 deadBefore = coin.balanceOf(DEAD);
        vm.roll(block.number + 30);
        vm.prank(keeper);
        core.buybackExit();
        uint256 tip = xt.balanceOf(keeper);
        uint256 spent = coreX - xt.balanceOf(address(core)) - tip;
        uint256 fee = _hookClaims() - claims0;

        uint256 tip0 = slice * 50 / 10_000;
        uint256 swapIn = (slice - tip0) * 9000 / 10_000;
        assertEq(fee, swapIn * 1000 / 9000, "fee on the gross spent");
        assertEq(spent, swapIn + fee, "spent is swap amount plus fee");
        assertApproxEqAbs(fee * 10_000 / spent, 1000, 1, "exactly 10 percent of the gross");
        assertLe(spent, slice - tip0, "never more than the slice less tip");
        assertEq(tip, tip0 * spent / (slice - tip0), "tip scaled to the spend");
        assertEq(core.xToBuyback(), queued - spent - tip, "the counter holds the rest");
        assertGt(coin.balanceOf(DEAD) - deadBefore, 0);
        assertEq(xt.allowance(address(core), address(hook)), 0, "the fee approval is revoked");
        _solvent();
    }

    /// a partial fill at the limit: the swap stops at the limit price, the hook fee is 10 percent of what was
    /// actually spent, the tip is scaled to the spend, and the unspent part returns to xToBuyback
    function test_exitBuyback_partialFillAtTheLimit() public {
        _phase2Key(0);
        PM.initialize(xKey, SQRT_PRICE_1_1);
        _seedExitPool(4e18);
        uint256 queued = _statementIntoBuyback();
        uint256 slice = 20 * core.AVG_SCORE() * UNIT;
        if (queued < slice) slice = queued;

        uint256 coreX = xt.balanceOf(address(core));
        uint256 claims0 = _hookClaims();
        vm.roll(block.number + 30);
        vm.prank(keeper);
        core.buybackExit();
        uint256 tip = xt.balanceOf(keeper);
        uint256 spent = coreX - xt.balanceOf(address(core)) - tip;
        uint256 fee = _hookClaims() - claims0;

        (uint160 price,,,) = StateLibrary.getSlot0(PM, PoolId.wrap(core.exitPoolId()));
        assertEq(price, core.exitSqrtPriceLimit(), "the swap stopped at the limit");
        uint256 tip0 = slice * 50 / 10_000;
        assertLt(spent, (slice - tip0) / 2, "a partial fill");
        assertGt(spent, 0);
        assertApproxEqAbs(fee * 10_000 / spent, 1000, 1, "10 percent of what was spent");
        assertEq(tip, tip0 * spent / (slice - tip0), "tip scaled to the spend");
        assertEq(core.xToBuyback(), queued - spent - tip, "unspent input and tip went back to the counter");
        assertEq(xt.balanceOf(address(core)), core.xPot() + core.xToBuyback() + 0, "nothing left unbooked");
        _solvent();
    }

    /// a price already beyond the limit stalls the buyback with a clear error and books nothing
    function test_exitBuyback_priceBeyondLimitReverts() public {
        _phase2Key(0);
        PM.initialize(xKey, SQRT_PRICE_1_1);
        _seedExitPool(0);
        uint256 queued = _statementIntoBuyback();
        // push the pool past the limit in the direction the core sells, with a big buy of coin by exit token
        _buyCoinWithExit(_user("pusher"), 2e26);
        (uint160 price,,,) = StateLibrary.getSlot0(PM, PoolId.wrap(core.exitPoolId()));
        bool beyond = _exitIs0() ? price <= core.exitSqrtPriceLimit() : price >= core.exitSqrtPriceLimit();
        assertTrue(beyond, "the pool is past the limit");
        vm.roll(block.number + 30);
        vm.expectRevert(Core.PriceBeyondLimit.selector);
        core.buybackExit();
        assertEq(core.xToBuyback(), queued);
    }

    // ------------------------------------------------------------------ R4 nothing bought, nothing booked

    /// R4 regression: the exit pool is initialized with no liquidity. `buybackExit` reverts, books nothing, tips
    /// nobody, and skim finds nothing to move into the bid pot
    function test_FIXED_emptyExitPoolBuybackRevertsAndBooksNothing() public {
        _phase2Key(0);
        PM.initialize(xKey, SQRT_PRICE_1_1);
        uint256 queued = _statementIntoBuyback();
        uint256 potBefore = core.xPot();

        vm.roll(block.number + 30);
        vm.prank(keeper);
        vm.expectRevert(Core.NothingBought.selector);
        core.buybackExit();
        assertEq(core.xToBuyback(), queued, "nothing was booked as spent");
        assertEq(xt.balanceOf(keeper), 0, "no tip");

        core.skim();
        assertEq(core.xPot(), potBefore, "nothing moved into the bid pot");
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
        address attacker = _user("attacker");
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
        _fundPot(100 ether);
        uint256 pot = core.ethPot();
        vm.warp(block.timestamp + 3650 days);
        uint256 g = gasleft();
        uint256 r = core.ethRate();
        g -= gasleft();
        assertEq(r, pot * 10_000 / core.AVG_SCORE(), "clamped at the funded threshold");
        assertLt(g, 400_000, "gas of the read");
        emit log_named_uint("gas of a ten year read", g);
        // a checkpointing call after the gap still works
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(core).call{value: 0}("");
        assertTrue(ok);
        core.skim();
    }
}
