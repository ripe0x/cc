// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane, Settings, Mainnet} from "../src/interfaces/Interfaces.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";

/// @notice phase 2 flexibility (docs/FLOW.md section 8) on the real stack: the exit module is replaceable under the
/// 7 day timelock, the unit is read again on every set, and the exit lane has its own buyback share. the only doubles
/// are the two exit stand ins
contract Phase2FlexTest is Fixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant AVG = 4_330_000;

    // ------------------------------------------------------------------ helpers

    function _mod(uint256 unit) internal returns (MockExitModule) {
        return new MockExitModule(address(xt), unit);
    }

    /// @dev the owner sets the module at once
    function _replace(address m) internal {
        _setExitModule(m);
    }

    function _owner(Settings memory s) internal {
        vm.prank(owner);
        core.setSettings(s);
    }

    function _lane(uint16 bps) internal {
        Settings memory s = core.settings();
        s.exitLaneToBuybackBps = bps;
        _owner(s);
    }

    /// @dev storage of the exit rate (Core slots 13 and 14, see `forge inspect Core storage-layout`)
    function _xRateAtCp() internal view returns (uint256) {
        return uint256(vm.load(address(core), bytes32(uint256(14))));
    }

    function _xCpTime() internal view returns (uint64) {
        return uint64(uint256(vm.load(address(core), bytes32(uint256(15)))));
    }

    function _xFunded() internal view returns (bool) {
        return (uint256(vm.load(address(core), bytes32(uint256(15)))) >> 64) & 0xff != 0;
    }

    function _full(uint256 unit) internal view returns (uint256) {
        return uint256(core.settings().exitSliceCredits) * core.settings().avgScore * unit;
    }

    /// @dev books `amount` of the exit token into the exit bid pot through the real `skim` door
    function _potX(uint256 amount) internal {
        xt.mint(address(core), amount);
        core.skim();
    }

    /// @dev an exit lane statement: the seller sells 80 credits into the exit bid, the core composes them
    function _exitLaneStatement() internal returns (uint256 sid) {
        uint256[] memory ids = _credits(seller, 80);
        _potX(5e19);
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.composeExit();
        sid = STATEMENTS.supply();
    }

    // ------------------------------------------------------------------ replace

    function test_replace_newModuleSameTokenTakesEffectAtOnce() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        address fresh = address(_mod(2e10));
        vm.expectEmit(address(core));
        emit ICore.ExitModuleSet(fresh, address(xt), 2e10);
        _replace(fresh);
        assertEq(core.exitModule(), fresh);
        assertEq(core.exitToken(), address(xt));
        assertEq(core.unitPerPoint(), 2e10);

        // the exit goes through the new module and pays by the new unit
        _warp(105 hours);
        uint256 rating = STATEMENTS.creditScoreOf(sid);
        uint256 before = xt.balanceOf(address(core));
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), fresh, "in the new module");
        assertEq(xt.balanceOf(address(core)) - before, rating * 2e10, "paid by the new unit");
        assertEq(core.xPot() + core.xToBuyback(), rating * 2e10);
        _solvent();
    }

    function test_replace_pilesPotsHeldAndTargetsAreUntouched() public {
        _enterPhase2();
        _composeOnce();
        _potX(3e19);
        _fillEthPile(5);
        MockExitModule m2 = _mod(3e10);
        address t = address(0xA11CE);
        _allow(t);
        uint256 xPot = core.xPot();
        uint256 xb = core.xToBuyback();
        uint256 ep = core.ethPot();
        uint256 eb = core.ethToBuyback();
        uint256 pile = core.pileSize(Lane.Eth);
        uint256 held = core.heldStatements().length;
        _replace(address(m2));
        assertEq(core.xPot(), xPot);
        assertEq(core.xToBuyback(), xb);
        assertEq(core.ethPot(), ep);
        assertEq(core.ethToBuyback(), eb);
        assertEq(core.pileSize(Lane.Eth), pile);
        assertEq(core.heldStatements().length, held);
        assertTrue(core.allowedTarget(t), "the allowed targets are untouched");
        _solvent();
    }

    function test_replace_sameAddressUpdatesTheUnit() public {
        _enterPhase2();
        mod.setUnitPerPoint(3e10);
        // the module changed its answer, the core keeps the unit it read until the set runs
        assertEq(core.unitPerPoint(), UNIT);
        vm.expectEmit(address(core));
        emit ICore.ExitModuleSet(address(mod), address(xt), 3e10);
        _replace(address(mod));
        assertEq(core.exitModule(), address(mod));
        assertEq(core.unitPerPoint(), 3e10, "a unit change takes effect at once");
        // and the same address can be set again, and again
        mod.setUnitPerPoint(4e9);
        _replace(address(mod));
        assertEq(core.unitPerPoint(), 4e9);
    }

    function test_replace_differentExitTokenReverts() public {
        _enterPhase2();
        MockExitModule alien = new MockExitModule(address(new MockExitToken("Other", "OTH")), UNIT);
        vm.prank(owner);
        vm.expectRevert(ICore.ExitTokenChanged.selector);
        core.setExitModule(address(alien));
        assertEq(core.exitModule(), address(mod));
        assertEq(core.exitToken(), address(xt));
    }

    function test_replace_firstSetStillTakesAnyTokenAndUnit() public {
        // before any module the token is free: the first set behaves as it always did
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), 7e9);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.exitStatement(1);
        _replace(address(mod));
        assertEq(core.exitToken(), address(xt));
        assertEq(core.unitPerPoint(), 7e9);
        assertEq(core.xStartTime(), block.timestamp);
        assertEq(core.xStartPrice(), core.SUPPLY() * 1e18 / _full(7e9));
        assertEq(core.xRate(), 6000);
    }

    function test_replace_everyTimeAtOnceAndOnlyTheOwner() public {
        _enterPhase2();
        _replace(address(_mod(2e10)));
        MockExitModule m3 = _mod(5e9);
        _replace(address(m3));
        assertEq(core.exitModule(), address(m3));
        assertEq(core.unitPerPoint(), 5e9);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setExitModule(address(mod));
    }

    function test_replace_twoSetsInARowBothApply() public {
        _enterPhase2();
        MockExitModule a = _mod(2e10);
        MockExitModule b = _mod(4e9);
        _replace(address(a));
        assertEq(core.exitModule(), address(a));
        assertEq(core.unitPerPoint(), 2e10);
        _replace(address(b));
        assertEq(core.exitModule(), address(b));
        assertEq(core.unitPerPoint(), 4e9);
        assertEq(core.exitToken(), address(xt));
    }

    function test_replace_sameValidityChecksAsTheFirstSet() public {
        _enterPhase2();
        address[4] memory bad = [
            address(0x1234), // no code
            address(_mod(0)), // unit zero
            address(_mod(uint256(type(uint128).max) + 1)), // unit too wide
            address(_mod(1e26)) // the opening price would sit below 1e12
        ];
        MockExitModule gone = _mod(1e10);
        gone.setRevertUnit(true); // the unit read fails
        vm.startPrank(owner);
        for (uint256 i; i < 4; ++i) {
            vm.expectRevert(ICore.BadModule.selector);
            core.setExitModule(bad[i]);
        }
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(gone));
        vm.stopPrank();
        assertEq(core.exitModule(), address(mod), "every refusal left the state alone");
        assertEq(core.unitPerPoint(), UNIT);
    }

    function test_replace_oldModuleIsNoLongerForbiddenAndTheNewOneIs() public {
        _enterPhase2();
        // while it is the module it cannot be a target
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(mod));
        MockExitModule m2 = _mod(2e10);
        _replace(address(m2));
        // the old module may be named a target now, the new one may not
        _allow(address(mod));
        assertTrue(core.allowedTarget(address(mod)));
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(m2));
        // the exit token stays forbidden
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(xt));
    }

    // ------------------------------------------------------------------ the unit is the new one

    /// @dev the module stored unit 2e10, and pays 75 percent of it: that is 1.5e10 per point, above the old unit 1e10
    /// and below the new one. the check must read the new unit and refuse
    function test_unit_underpaidChecksTheNewUnitNotTheOld() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        MockExitModule m2 = _mod(2e10);
        _replace(address(m2));
        m2.setShortfallBps(2_500);
        _warp(105 hours);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(sid);
        // paying the new unit in full passes
        m2.setShortfallBps(0);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(m2));
    }

    /// @dev the other way: the new unit is lower than the old one, and a payment at the new unit is enough
    function test_unit_lowerNewUnitIsEnough() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        MockExitModule m2 = _mod(4e9);
        _replace(address(m2));
        _warp(core.settings().exitAfter);
        uint256 rating = STATEMENTS.creditScoreOf(sid);
        uint256 before = xt.balanceOf(address(core));
        core.exitStatement(sid);
        assertEq(xt.balanceOf(address(core)) - before, rating * 4e9, "paid 4e9 per point, less than the old unit");
        _solvent();
    }

    /// @dev the bid for credits pays by the new unit too
    function test_unit_exitBidPaysByTheNewUnit() public {
        _enterPhase2();
        _potX(1e20);
        _replace(address(_mod(4e10)));
        uint256[] memory ids = _credits(seller, 1);
        uint256 score = core.scoreOf(ids[0]);
        uint256 r = core.xRate();
        uint256 before = xt.balanceOf(seller);
        vm.prank(seller);
        core.sellForExitToken(ids);
        assertEq(xt.balanceOf(seller) - before, score * r * 4e10 / 10_000);
        _solvent();
    }

    // ------------------------------------------------------------------ exit rate across a unit change

    /// @dev xPot is 2e19. the exit rate is set to 3000 ten hours before the set, so it climbs 100 per hour. under
    /// the old unit 1e10 the cap is min(9700, 2e19 * 1e4 / (4_330_000 * 1e10)) = 4619 and the rate at the set is
    /// 3000 + 10 * 100 = 4000. under the new unit 1e14 the cap would be 2e23 / (4_330_000 * 1e14) = 461, below the
    /// rate: a checkpoint taken after the unit changed would freeze the rate at 3000 and lose the climb
    function test_rate_checkpointedUnderTheOldUnit() public {
        _enterPhase2();
        _potX(2e19);
        assertTrue(_xFunded());
        MockExitModule m2 = _mod(1e14);
        vm.prank(owner);
        core.setXRate(3_000);
        assertEq(_xRateAtCp(), 3_000);
        uint256 eta = block.timestamp + 10 hours;
        vm.warp(eta);
        assertEq(core.xRate(), 4_000, "ten hours of climb under the old unit");
        _replace(address(m2));
        assertEq(_xRateAtCp(), 4_000, "credited at the old unit, none lost to the new cap");
        assertEq(uint256(_xCpTime()), eta, "the clock restarts at the set");
        assertEq(core.xRate(), 4_000);
        // funded is resynced under the new unit: 2e23 < 4_330_000 * 4000 * 1e14 = 1.732e24
        assertFalse(_xFunded(), "the pot cannot carry one average credit at 4000 under 1e14");
        _warp(10 hours);
        assertEq(core.xRate(), 4_000, "unfunded: no climb");
        _solvent();
    }

    /// @dev the other direction: the unit falls, the pot that could not carry the bid now can, and the climb resumes
    function test_rate_fundedIsResyncedWhenTheUnitFalls() public {
        _enterPhase2();
        _potX(2e16);
        // 2e16 * 1e4 = 2e20 < 4_330_000 * 6000 * 1e10 = 2.598e20: underfunded at the start
        assertFalse(_xFunded());
        assertEq(core.xRate(), 6_000);
        _replace(address(_mod(5e9)));
        // 2e20 >= 4_330_000 * 6000 * 5e9 = 1.299e20, and the cap is 2e20 / (4_330_000 * 5e9) = 9237
        assertTrue(_xFunded());
        assertEq(_xRateAtCp(), 6_000);
        _warp(10 hours);
        assertEq(core.xRate(), 7_000, "climbs 100 per hour again");
    }

    /// @dev the same address set again with a changed unit is resynced the same way. the rate climbed to its cap
    /// 9700 over a week under the old unit and that is what is credited
    function test_rate_sameAddressSetResyncs() public {
        _enterPhase2();
        _potX(1e20);
        assertTrue(_xFunded());
        mod.setUnitPerPoint(1e14);
        _warp(7 days);
        _replace(address(mod));
        assertEq(_xRateAtCp(), 9_700, "7 days of climb credited under the old unit");
        // 1e24 < 4_330_000 * 9700 * 1e14 = 4.2e24
        assertFalse(_xFunded());
    }

    // ------------------------------------------------------------------ the exit auction across a set

    /// @dev the price is coin per exit token and does not depend on the unit. a set with something for sale keeps the
    /// running price and clock: not lower than the moment before, in the same block, for a higher or a lower unit and
    /// for the same address
    function _priceAcrossSet(uint256 newUnit, bool sameAddress) internal {
        _enterPhase2();
        _fillExitBuyback();
        assertGt(core.xToBuyback(), 0);
        _warp(3 hours);
        MockExitModule next = sameAddress ? mod : _mod(newUnit);
        if (sameAddress) mod.setUnitPerPoint(newUnit);
        uint256 price = core.exitAuctionPrice();
        uint256 start = core.xStartPrice();
        uint64 at = core.xStartTime();
        uint256 xb = core.xToBuyback();
        assertLt(price, start, "the price has been running down");
        _replace(address(next));
        assertEq(core.unitPerPoint(), newUnit);
        assertGe(core.exitAuctionPrice(), price, "never cheaper right after a set");
        assertEq(core.exitAuctionPrice(), price, "the same price in the same block");
        assertEq(core.xStartPrice(), start, "start price kept");
        assertEq(core.xStartTime(), at, "clock kept");
        assertEq(core.xToBuyback(), xb);
        // the slice follows the new unit, the price per exit token does not
        (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
        assertEq(slice, xb.min(_full(newUnit)));
        assertEq(coinIn, slice.mulDivUp(price, 1e18));
        _solvent();
        // and the clock goes on from the old anchor
        _warp(6 hours);
        assertLt(core.exitAuctionPrice(), price);
    }

    function test_auction_priceKeptWhenTheUnitRises() public {
        _priceAcrossSet(5e10, false);
    }

    function test_auction_priceKeptWhenTheUnitFalls() public {
        _priceAcrossSet(2e9, false);
    }

    function test_auction_priceKeptWhenTheSameAddressIsSetAgain() public {
        _priceAcrossSet(3e10, true);
    }

    /// @dev a buyback fill right after a set runs at the quoted price and takes the new slice
    function test_auction_fillAfterASetUsesTheNewSlice() public {
        _enterPhase2();
        _fillExitBuyback();
        _replace(address(_mod(1e9)));
        // the exit auction price falls with time: let it run so one coin purchase covers the quote
        _warp(7 days);
        uint256 xb = core.xToBuyback();
        (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
        assertEq(slice, xb.min(_full(1e9)));
        assertLt(slice, xb, "the smaller unit makes the slice smaller than the pot");
        address taker = _user("taker");
        _buyCoin(taker, 1 ether);
        vm.startPrank(taker);
        coin.approve(address(core), type(uint256).max);
        uint256 coinBefore = coin.balanceOf(taker);
        core.buybackExit(coinIn);
        vm.stopPrank();
        assertEq(xt.balanceOf(taker), slice);
        assertEq(coinBefore - coin.balanceOf(taker), coinIn);
        assertEq(core.xToBuyback(), xb - slice);
        _solvent();
    }

    /// @dev a later set never touches the stored start price or the clock, with or without something for sale: the
    /// price is coin per exit token, the unit only changes the slice
    function test_auction_laterSetNeverTouchesStartPriceOrClock() public {
        _enterPhase2();
        uint256 start0 = core.SUPPLY() * 1e18 / _full(UNIT);
        uint64 at0 = core.xStartTime();
        assertEq(core.xStartPrice(), start0);
        uint256[3] memory units = [uint256(4e10), 1e9, UNIT];
        for (uint256 i; i < 3; ++i) {
            _replace(address(_mod(units[i])));
            assertEq(core.xStartPrice(), start0, "start price untouched");
            assertEq(core.xStartTime(), at0, "clock untouched");
            assertEq(core.exitAuctionPrice(), start0, "stopped clock, the start is the price");
        }
    }

    /// @dev the first set may be preceded by a dormant allowed target flag of the module: the set clears it
    function test_replace_dormantTargetFlagIsClearedByTheSet() public {
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), UNIT);
        _allow(address(mod));
        assertTrue(core.allowedTarget(address(mod)));
        _replace(address(mod));
        assertFalse(core.allowedTarget(address(mod)), "cleared by the first set");
        MockExitModule m2 = _mod(2e10);
        _allow(address(m2));
        _replace(address(m2));
        assertFalse(core.allowedTarget(address(m2)), "cleared by a later set");
        _replace(address(mod));
        assertFalse(core.allowedTarget(address(m2)), "and it does not come back");
    }

    // ------------------------------------------------------------------ exit lane buyback share

    function test_lane_launchValueIsZero() public view {
        assertEq(core.settings().exitLaneToBuybackBps, 0);
        assertEq(Mainnet.defaultSettings().exitLaneToBuybackBps, 0);
    }

    /// @dev one exit lane exit with the setting at `bps`: exact pot arithmetic
    function _laneSplit(uint16 bps) internal {
        _enterPhase2();
        _lane(bps);
        uint256 sid = _exitLaneStatement();
        uint256 rating = STATEMENTS.creditScoreOf(sid);
        uint256 got = rating * UNIT;
        uint256 pot = core.xPot();
        uint256 xb = core.xToBuyback();
        uint256 bal = xt.balanceOf(address(core));
        vm.expectEmit(address(core));
        emit ICore.StatementExited(sid, Lane.Exit, got);
        core.exitStatement(sid);
        uint256 toBuyback = got * bps / 10_000;
        assertEq(xt.balanceOf(address(core)) - bal, got, "paid rating times the unit");
        assertEq(core.xToBuyback(), xb + toBuyback, "the share goes to the buyback");
        assertEq(core.xPot(), pot + got - toBuyback, "the rest goes to the exit bid pot");
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
        _solvent();
    }

    function test_lane_splitZeroAllToTheBidPot() public {
        _laneSplit(0);
    }

    function test_lane_splitHalf() public {
        _laneSplit(5_000);
    }

    function test_lane_splitAllToTheBuyback() public {
        _laneSplit(10_000);
    }

    function test_lane_splitOddShareRoundsDown() public {
        _laneSplit(3_333);
    }

    /// @dev the eth lane uses its own setting, whatever the exit lane one says
    function test_lane_ethLaneIgnoresTheExitLaneSetting() public {
        _enterPhase2();
        Settings memory s = core.settings();
        s.exitToBuybackBps = 2_000;
        s.exitLaneToBuybackBps = 10_000;
        _owner(s);
        uint256 sid = _composeOnce().sid;
        _warp(105 hours);
        uint256 got = STATEMENTS.creditScoreOf(sid) * UNIT;
        core.exitStatement(sid);
        assertEq(core.xToBuyback(), got * 2_000 / 10_000);
        assertEq(core.xPot(), got - got * 2_000 / 10_000);
        _solvent();
    }

    /// @dev the exit auction re anchors for an exit lane injection the way it does for an eth lane one: the price now,
    /// at least a quarter of the start, and the clock restarts
    function _anchor(uint16 bps, uint256 wait) internal returns (uint256 start, uint256 priceBefore) {
        _enterPhase2();
        _fillExitBuyback();
        uint256 sid = _exitLaneStatement();
        _lane(bps);
        _warp(wait);
        start = core.xStartPrice();
        priceBefore = core.exitAuctionPrice();
        uint64 at = core.xStartTime();
        core.exitStatement(sid);
        if (bps == 0) {
            assertEq(core.xStartPrice(), start, "nothing injected, nothing re anchored");
            assertEq(core.xStartTime(), at);
            assertEq(core.exitAuctionPrice(), priceBefore);
        } else {
            assertEq(core.xStartTime(), block.timestamp, "the clock restarts");
            assertEq(core.exitAuctionPrice(), core.xStartPrice(), "no elapsed time yet");
        }
        _solvent();
    }

    function test_lane_reanchorsAtThePriceNow() public {
        (uint256 start, uint256 priceBefore) = _anchor(5_000, 6 hours);
        assertLt(priceBefore, start);
        assertGt(priceBefore, start / 4);
        assertEq(core.xStartPrice(), priceBefore, "anchored at the decayed price");
    }

    function test_lane_reanchorFloorsAtAQuarterOfTheStart() public {
        (uint256 start, uint256 priceBefore) = _anchor(10_000, 24 hours);
        assertLt(priceBefore, start / 4, "four half lives: below a quarter");
        assertEq(core.xStartPrice(), start / 4, "floored");
    }

    function test_lane_zeroShareLeavesTheAuctionRunning() public {
        _anchor(0, 6 hours);
    }

    /// @dev with an empty buyback pot the injection anchors at the stored start price
    function test_lane_injectionIntoAnEmptyBuybackPot() public {
        _enterPhase2();
        _lane(10_000);
        uint256 start = core.xStartPrice();
        uint256 sid = _exitLaneStatement();
        _warp(2 days);
        core.exitStatement(sid);
        assertEq(core.xStartPrice(), start, "an empty pot has no running clock");
        assertEq(core.xStartTime(), block.timestamp);
        assertEq(core.xToBuyback(), STATEMENTS.creditScoreOf(sid) * UNIT);
    }

    // ------------------------------------------------------------------ bounds of the setting

    function test_bounds_exitLaneToBuybackBps() public {
        Settings memory s = core.settings();
        s.exitLaneToBuybackBps = 10_001;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("exitLaneToBuybackBps")));
        core.setSettings(s);
        s.exitLaneToBuybackBps = type(uint16).max;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("exitLaneToBuybackBps")));
        core.setSettings(s);
        uint16[3] memory ok = [uint16(0), 10_000, 4_321];
        for (uint256 i; i < 3; ++i) {
            s.exitLaneToBuybackBps = ok[i];
            vm.expectEmit(address(core));
            emit ICore.SettingsSet(s);
            _owner(s);
            assertEq(core.settings().exitLaneToBuybackBps, ok[i]);
            assertEq(keccak256(abi.encode(core.settings())), keccak256(abi.encode(s)), "the other fields are intact");
        }
        vm.expectRevert();
        core.setSettings(s);
    }

    // ------------------------------------------------------------------ solvency through all of it

    /// @dev exits in both lanes, three module sets (new module, same address with a new unit, another new module),
    /// settings changes and a fill: the pots never exceed the exit token the core holds, and the exit token is the one
    function test_solvency_potsStayBackedThroughReplacementsAndSplits() public {
        _enterPhase2();
        Settings memory s = core.settings();
        s.exitLaneToBuybackBps = 4_000;
        _owner(s);
        uint256 sid = _composeOnce().sid;
        _solvent();
        uint256 lane = _exitLaneStatement();
        _solvent();
        core.exitStatement(lane);
        _solvent();

        MockExitModule m2 = _mod(3e10);
        _replace(address(m2));
        _solvent();
        _warp(105 hours);
        core.exitStatement(sid);
        _solvent();

        m2.setUnitPerPoint(7e9);
        _replace(address(m2));
        _solvent();
        s.exitLaneToBuybackBps = 10_000;
        _owner(s);
        uint256 lane2 = _exitLaneStatement();
        core.exitStatement(lane2);
        _solvent();

        MockExitModule m3 = _mod(2e10);
        _replace(address(m3));
        _solvent();
        s.exitLaneToBuybackBps = 0;
        _owner(s);
        uint256 lane3 = _exitLaneStatement();
        core.exitStatement(lane3);
        _solvent();
        assertEq(core.exitToken(), address(xt));
        assertEq(STATEMENTS.ownerOf(lane3), address(m3));
        assertEq(STATEMENTS.ownerOf(lane2), address(m2));
        assertEq(STATEMENTS.ownerOf(lane), address(mod));
        assertEq(STATEMENTS.ownerOf(sid), address(m2));
        assertEq(core.xPot() + core.xToBuyback(), xt.balanceOf(address(core)), "every unit is booked");
    }
}
