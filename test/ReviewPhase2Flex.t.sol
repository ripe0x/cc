// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {CoreLib} from "../src/lib/CoreLib.sol";
import {SettingsStore} from "../src/lib/SettingsStore.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";
import {Lane, Settings, Mainnet, IExitModule, IStatements} from "../src/interfaces/Interfaces.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";

/// @notice a module that tries to reenter the core from every callback the core gives it
contract ReenteringModule is IExitModule {
    address public exitToken;
    uint256 public unit;
    address public core;
    uint256 public attempts;
    uint256 public succeeded;
    bool public skimInside;

    constructor(address token, uint256 unit_, address core_) {
        exitToken = token;
        unit = unit_;
        core = core_;
    }

    function unitPerPoint() external view returns (uint256) {
        return unit;
    }

    function _try(bytes memory data) private {
        ++attempts;
        (bool ok,) = core.call(data);
        if (ok) ++succeeded;
    }

    /// every non view door of the core, called from inside a callback
    function _poke() internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        (skimInside,) = core.call(abi.encodeWithSignature("skim()"));
        _try(abi.encodeWithSignature("skim()"));
        _try(abi.encodeWithSignature("composeExit()"));
        _try(abi.encodeWithSignature("compose()"));
        _try(abi.encodeWithSignature("collectSales()"));
        _try(abi.encodeWithSignature("overprint()"));
        _try(abi.encodeWithSignature("buyback()"));
        _try(abi.encodeWithSignature("buybackExit(uint256)", type(uint256).max));
        _try(abi.encodeWithSignature("sellForEth(uint256[])", ids));
        _try(abi.encodeWithSignature("sellForExitToken(uint256[])", ids));
        _try(abi.encodeWithSignature("exitStatement(uint256)", 1));
        _try(abi.encodeWithSignature("syncStatement(uint256)", 1));
        _try(abi.encodeWithSignature("repriceStatement(uint256)", 1));
        _try(abi.encodeWithSignature("buyListing(uint256,bytes,uint256,address)", 0, "", 1, address(this)));
        _try(abi.encodeWithSignature("setXRate(uint256)", 5_000));
        _try(abi.encodeWithSignature("execute(uint8,bytes)", 1, abi.encode(address(this))));
    }

    /// the same skim from outside any callback, the control
    function skimOutside() external returns (bool ok) {
        (ok,) = core.call(abi.encodeWithSignature("skim()"));
    }

    function exit(uint256 sid) external returns (uint256 out) {
        _poke();
        uint256 rating = IStatements(Mainnet.STATEMENTS).creditScoreOf(sid);
        out = rating * unit;
        MockExitToken(exitToken).mint(msg.sender, out);
    }
}

/// @notice a module whose exitToken report and unit can change after it was set
contract FlipModule is IExitModule {
    address public exitToken;
    uint256 public unit;

    constructor(address token, uint256 unit_) {
        exitToken = token;
        unit = unit_;
    }

    function setToken(address t) external {
        exitToken = t;
    }

    function setUnit(uint256 u) external {
        unit = u;
    }

    function unitPerPoint() external view returns (uint256) {
        return unit;
    }

    function exit(uint256 sid) external returns (uint256 out) {
        out = IStatements(Mainnet.STATEMENTS).creditScoreOf(sid) * unit;
        MockExitToken(exitToken).mint(msg.sender, out);
    }
}

/// @notice writes every settings field at the max of its type through the compiler layout, to read the raw words
contract PackHarness {
    function maxAll() external {
        Settings storage s = SettingsStore.load();
        s.flatBps = type(uint16).max;
        s.avgScore = type(uint32).max;
        s.climbBaseBps = type(uint16).max;
        s.climbDoubleEvery = type(uint32).max;
        s.climbMaxBps = type(uint16).max;
        s.dropBps = type(uint16).max;
        s.spendCapBps = type(uint16).max;
        s.bonusCapBps = type(uint16).max;
        s.tipSavingsBps = type(uint16).max;
        s.tipCapBps = type(uint16).max;
        s.reimburseBps = type(uint16).max;
        s.reimburseCapBps = type(uint16).max;
        s.reserveBps = type(uint16).max;
        s.auctionDuration = type(uint32).max;
        s.exitAfter = type(uint32).max;
        s.saleToBuybackBps = type(uint16).max;
        s.exitToBuybackBps = type(uint16).max;
        s.buybackSlice = type(uint128).max;
        s.buybackDelay = type(uint16).max;
        s.keeperTipBps = type(uint16).max;
        s.xRateCap = type(uint16).max;
        s.xRateFloor = type(uint16).max;
        s.xRateClimbPerHour = type(uint16).max;
        s.xRateDropPerCredit = type(uint16).max;
        s.xAuctionHalfLife = type(uint32).max;
        s.exitSliceCredits = type(uint16).max;
        s.rateCap = type(uint64).max;
        s.exitLaneToBuybackBps = type(uint16).max;
    }

    function onlyLane() external {
        SettingsStore.load().exitLaneToBuybackBps = type(uint16).max;
    }

    function words() external view returns (uint256 a, uint256 b, uint256 c) {
        bytes32 slot = SettingsStore.SLOT;
        assembly {
            a := sload(slot)
            b := sload(add(slot, 1))
            c := sload(add(slot, 2))
        }
    }
}

/// @notice independent review of commit a970943 (docs/REVIEW-phase2flex.md). test_FINDING_ tests pass today and assert
/// the behavior the review reports as a finding. test_OK_ tests confirm a property that holds
contract ReviewPhase2FlexTest is Fixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant AVG = 4_330_000;

    // ------------------------------------------------------------------ helpers

    function _mod(uint256 unit) internal returns (MockExitModule) {
        return new MockExitModule(address(xt), unit);
    }

    function _queue(address m) internal returns (bytes memory data, uint256 eta) {
        data = abi.encode(m);
        vm.prank(owner);
        core.queue(Core.Action.SetExitModule, data);
        eta = block.timestamp + 7 days;
    }

    function _exec(bytes memory data) internal {
        vm.prank(owner);
        core.execute(Core.Action.SetExitModule, data);
    }

    function _replace(address m) internal {
        (bytes memory d, uint256 eta) = _queue(m);
        vm.warp(eta);
        _exec(d);
    }

    function _full(uint256 unit) internal view returns (uint256) {
        return uint256(core.settings().exitSliceCredits) * core.settings().avgScore * unit;
    }

    function _potX(uint256 amount) internal {
        xt.mint(address(core), amount);
        core.skim();
    }

    function _xFunded() internal view returns (bool) {
        return (uint256(vm.load(address(core), bytes32(uint256(14)))) >> 64) & 0xff != 0;
    }

    function _xRateAtCp() internal view returns (uint256) {
        return uint256(vm.load(address(core), bytes32(uint256(13))));
    }

    /// @dev owner edit of two settings in one call
    function _edit(uint16 exitBps, uint16 laneBps, uint32 half) internal {
        Settings memory s = core.settings();
        s.exitToBuybackBps = exitBps;
        s.exitLaneToBuybackBps = laneBps;
        s.xAuctionHalfLife = half;
        _setSettings(s);
    }

    /// @dev a taker burns coin for every slice until the exit buyback pot is empty. returns the coin paid and the
    /// exit token received. the coin is conjured, the price is what is under test
    function _drain() internal returns (uint256 paid, uint256 got) {
        address taker = _user("drainer");
        vm.prank(taker);
        coin.approve(address(core), type(uint256).max);
        for (uint256 i; i < 64 && core.xToBuyback() != 0; ++i) {
            (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
            deal(address(coin), taker, coinIn);
            vm.prank(taker);
            core.buybackExit(coinIn);
            paid += coinIn;
            got += slice;
        }
        assertEq(core.xToBuyback(), 0, "drained");
    }

    /// @dev phase 2 with every exit proceed going to the buyback pot, a slow half life, one statement exited, and a
    /// replacement to `unit` queued. returns the data to execute and leaves the clock at the end of the timelock
    function _setupDrain(uint256 unit) internal returns (bytes memory data) {
        _enterPhase2();
        _edit(10_000, 0, 30 days);
        _fillExitBuyback();
        assertGt(core.xToBuyback(), 0);
        address next = address(_mod(unit));
        uint256 eta;
        (data, eta) = _queue(next);
        vm.warp(eta);
    }

    function _coin() internal view returns (uint256 c) {
        (, c) = core.exitAuctionQuote();
    }

    // ------------------------------------------------------------------ slice size against the price

    /// FINDING RP-1: the price per exit token is kept across a set but the slice follows the unit, and the price
    /// doubles per fill. after a unit rise the whole pot goes in fewer, bigger fills, so draining it costs less per exit
    /// token than the moment before. a buyer can queue behind the public timelock and take it in the block of the set
    function test_FINDING_unitRiseDrainsThePotCheaperPerExitToken() public {
        bytes memory data = _setupDrain(1e12);
        uint256 snap = vm.snapshotState();
        (uint256 paid0, uint256 got0) = _drain();
        vm.revertToState(snap);
        _exec(data);
        (uint256 paid1, uint256 got1) = _drain();
        assertEq(got0, got1, "the same exit token leaves the pot");
        uint256 avg0 = paid0 * 1e18 / got0;
        uint256 avg1 = paid1 * 1e18 / got1;
        emit log_named_uint("avg coin per exit token before, wad", avg0);
        emit log_named_uint("avg coin per exit token after a 100x unit rise, wad", avg1);
        emit log_named_uint("saving in percent", (avg0 - avg1) * 100 / avg0);
        assertLt(avg1, avg0, "cheaper per exit token for the same pot");
    }

    /// FINDING RP-1b: a unit fall shrinks the slice at the same price per exit token, so one full slice costs less coin
    /// by the same factor as the unit fell, while each exit token now stands for more points
    function test_FINDING_unitFallCutsTheCoinCostOfAFullSlice() public {
        bytes memory data = _setupDrain(1e9);
        (, uint256 coinBefore) = core.exitAuctionQuote();
        (uint256 sliceBefore,) = core.exitAuctionQuote();
        assertEq(sliceBefore, _full(UNIT).min(core.xToBuyback()));
        _exec(data);
        (uint256 sliceAfter, uint256 coinAfter) = core.exitAuctionQuote();
        emit log_named_uint("coin for a slice before", coinBefore);
        emit log_named_uint("coin for a slice after a 10x unit fall", coinAfter);
        assertEq(sliceAfter, _full(1e9).min(core.xToBuyback()));
        assertApproxEqRel(coinAfter * 10, coinBefore, 1e15, "a slice costs a tenth of the coin");
    }

    // ------------------------------------------------------------------ the stored start price only ratchets up

    /// FINDING RP-2: with nothing for sale the start price is max(new, stored). a mistaken low unit raises it and a later
    /// repair to the right unit cannot bring it back. the next injection anchors at the poisoned price
    function test_FINDING_startPriceRatchetKeepsAMistakenLowUnit() public {
        _enterPhase2();
        uint256 good = core.xStartPrice();
        _replace(address(_mod(1)));
        uint256 poisoned = core.xStartPrice();
        _replace(address(_mod(UNIT)));
        assertEq(core.unitPerPoint(), UNIT, "repaired");
        assertEq(core.xStartPrice(), poisoned, "start price still the poisoned one");
        assertEq(core.xStartPrice() / good, 1e10, "ten orders too high");
        emit log_named_uint("halvings to come back (x100)", FixedPointMathLib.log2(core.xStartPrice() / good) * 100);
        // the first injection anchors at the poisoned price, a full slice asks 1e10 times the coin supply
        _fillExitBuyback();
        assertEq(core.xStartPrice(), poisoned, "anchored at the poisoned price");
        (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
        assertEq(slice, _full(UNIT).min(core.xToBuyback()));
        assertGt(coinIn, core.SUPPLY() * 1e9, "a slice costs billions of times the whole coin supply");
        // 33 halvings: 7 days at the 6 hour half life is not enough, 9 days is
        _warp(7 days);
        assertGt(_coin(), core.SUPPLY(), "after 7 days still above the supply");
        emit log_named_uint("7 days: slice cost as multiple of the coin supply", _coin() / core.SUPPLY());
        _warp(2 days);
        assertLt(_coin(), core.SUPPLY(), "after 9 days it is inside the supply, not yet sane");
    }

    // ------------------------------------------------------------------ targets after a replacement

    /// FINDING RP-3: an allowed target flag set while an address was not yet the module stays set while it is the module
    /// (blocked at call time) and is live again the moment a later set replaces it
    function test_FINDING_dormantAllowedTargetRevivesWhenTheModuleIsReplaced() public {
        _enterPhase2();
        MockExitModule b = _mod(UNIT);
        _allow(address(b));
        assertTrue(core.allowedTarget(address(b)), "added while it was not the module");
        _replace(address(b));
        uint256 id = _credits(seller, 1)[0];
        bytes memory data = abi.encodeCall(MockExitModule.setUnitPerPoint, (7));
        vm.expectRevert(Core.TargetNotAllowed.selector);
        core.buyListing(0, data, id, address(b));
        _replace(address(_mod(UNIT)));
        // no longer the module: the stale flag is back in force, the call reaches b and only the credit check stops it
        vm.expectRevert(Core.NoCredit.selector);
        core.buyListing(0, data, id, address(b));
        assertEq(b.currentUnit(), UNIT, "reverted, so nothing changed");
    }

    function test_OK_forbiddenSetsAfterAReplacement() public {
        _enterPhase2();
        MockExitModule a = mod;
        MockExitModule b = _mod(UNIT);
        _replace(address(b));
        // the old module may be added again, the new module and the exit token may not
        _timelock(Core.Action.AddTarget, abi.encode(address(a)));
        assertTrue(core.allowedTarget(address(a)));
        vm.startPrank(owner);
        core.queue(Core.Action.AddTarget, abi.encode(address(b)));
        core.queue(Core.Action.AddTarget, abi.encode(address(xt)));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(Core.ForbiddenTarget.selector);
        core.execute(Core.Action.AddTarget, abi.encode(address(b)));
        vm.expectRevert(Core.ForbiddenTarget.selector);
        core.execute(Core.Action.AddTarget, abi.encode(address(xt)));
        vm.stopPrank();
        // a as target pulls nothing: exit on it mints to the core in the stand in, then the credit check unwinds it
        uint256 id = _credits(seller, 1)[0];
        uint256 bal = xt.balanceOf(address(core));
        vm.expectRevert(Core.NoCredit.selector);
        core.buyListing(0, abi.encodeCall(MockExitModule.exit, (1)), id, address(a));
        assertEq(xt.balanceOf(address(core)), bal, "nothing kept");
        // the exit token and the new module are blocked at call time even when flagged before
        assertFalse(core.allowedTarget(address(xt)));
    }

    /// the module must not be a stack member, in a replacement as in the first set
    function test_OK_replacementStillRefusesStackMembersAndNonContracts() public {
        _enterPhase2();
        (bytes memory d, uint256 eta) = _queue(address(coin));
        vm.warp(eta);
        vm.expectRevert();
        _exec(d);
        (d, eta) = _queue(address(0xdead));
        vm.warp(eta);
        vm.expectRevert(Core.BadModule.selector);
        _exec(d);
    }

    // ------------------------------------------------------------------ the bounds of the opening price on a set

    /// INFO RP-4: the opening price floor of the first set also blocks a later unit rise even when the stored price is
    /// high and nothing would break: the repair of a huge unit is refused with BadModule
    function test_FINDING_hugeUnitRepairRefusedByOpeningPriceFloor() public {
        _enterPhase2();
        _fillExitBuyback();
        assertGt(core.xToBuyback(), 0);
        uint256 ceiling = core.SUPPLY() * 1e18 / 1e12 / _full(1);
        emit log_named_uint("highest unit the floor allows", ceiling);
        (bytes memory d, uint256 eta) = _queue(address(_mod(ceiling + 1)));
        vm.warp(eta);
        vm.expectRevert(Core.BadModule.selector);
        _exec(d);
        // the same unit is fine as long as the floor holds
        _replace(address(_mod(ceiling)));
        assertEq(core.unitPerPoint(), ceiling);
    }

    // ------------------------------------------------------------------ hostile and shifting modules

    /// OK: a new module that calls every door of the core from inside `exit` is refused each time by the guard, and the
    /// exit books exactly what arrived. the module hooks `exitToken` and `unitPerPoint` are static calls: no state
    /// change is possible there at all
    function test_OK_hostileModuleCannotReenterAnyDoor() public {
        _enterPhase2();
        ReenteringModule rm = new ReenteringModule(address(xt), UNIT, address(core));
        _replace(address(rm));
        assertTrue(rm.skimOutside(), "control: the same skim works outside a callback");
        uint256 sid = _composeOnce().sid;
        _warp(72 hours);
        uint256 before = xt.balanceOf(address(core));
        core.exitStatement(sid);
        assertGt(rm.attempts(), 14, "tried every door");
        assertEq(rm.succeeded(), 0, "none got through");
        assertFalse(rm.skimInside(), "the guard refused skim inside the callback");
        assertEq(core.xPot() + core.xToBuyback(), xt.balanceOf(address(core)) - before);
        _solvent();
    }

    /// OK: a module that reports another exit token after it was set cannot move the core's token. its exits come
    /// back Underpaid, the same address cannot be set again, a good module replaces it and the pots stay solvent
    function test_OK_moduleThatChangesItsReportedTokenOnlyBricksItself() public {
        _enterPhase2();
        FlipModule fm = new FlipModule(address(xt), UNIT);
        _replace(address(fm));
        MockExitToken other = new MockExitToken("O", "O");
        fm.setToken(address(other));
        assertEq(core.exitToken(), address(xt), "the core kept its own copy");
        uint256 sid = _composeOnce().sid;
        _warp(72 hours);
        vm.expectRevert(Core.Underpaid.selector);
        core.exitStatement(sid);
        (bytes memory d, uint256 eta) = _queue(address(fm));
        vm.warp(eta);
        vm.expectRevert(Core.ExitTokenChanged.selector);
        _exec(d);
        // a unit change reported later is ignored until a set reads it
        fm.setToken(address(xt));
        fm.setUnit(5 * UNIT);
        assertEq(core.unitPerPoint(), UNIT);
        _replace(address(_mod(UNIT)));
        core.exitStatement(sid);
        _solvent();
    }

    // ------------------------------------------------------------------ selling across a set

    /// OK: a seller in the block of the set is paid with one unit and one rate, never a mix. before the set the old
    /// unit, after it the new unit at the rate that was checkpointed, and `minOut` in exit token units is what protects
    /// a seller who quoted the old unit from the drop
    function test_OK_sellInTheBlockOfTheSetUsesOneUnitAndMinOutProtectsAFall() public {
        _enterPhase2();
        _potX(5e19);
        uint256[] memory ids = _credits(seller, 3);
        (bytes memory d, uint256 eta) = _queue(address(_mod(UNIT / 10)));
        vm.warp(eta);
        uint256 rate = core.xRate();
        uint256 s0 = core.scoreOf(ids[0]);
        uint256 quoteOld = s0 * rate * UNIT / 10_000;
        // the sell that lands after the set with a floor from the old quote
        _exec(d);
        assertEq(core.xRate(), rate, "same rate right after the set");
        vm.prank(seller);
        vm.expectRevert(Core.Slippage.selector);
        core.sellForExitToken(_one(ids[0]), quoteOld);
        // without a floor the seller takes what the new unit pays
        uint256 b = xt.balanceOf(seller);
        vm.prank(seller);
        core.sellForExitToken(_one(ids[1]));
        uint256 got = xt.balanceOf(seller) - b;
        assertEq(got, core.scoreOf(ids[1]) * rate * (UNIT / 10) / 10_000, "new unit at the checkpointed rate");
        assertLe(got * 10, quoteOld * core.scoreOf(ids[1]) / s0 + 10, "a tenth of the old quote");
        _solvent();
    }

    /// OK: across a set the exit rate is continuous, credited under the old unit, and the funded flag always equals its
    /// definition under the new unit, for a rise and a fall of the unit, the rate at the floor, in the middle and at the
    /// cap, a pot that carries the bid and a pot that does not
    function test_OK_rateCheckpointAcrossAUnitChangeMatrix() public {
        _enterPhase2();
        Settings memory st = core.settings();
        uint256[3] memory rates = [uint256(st.xRateFloor), (uint256(st.xRateFloor) + st.xRateCap) / 2, st.xRateCap];
        uint256[2] memory pots = [uint256(1e17), 1e24];
        uint256[2] memory units = [UNIT * 1000, UNIT / 1000];
        uint256 base = vm.snapshotState();
        for (uint256 a; a < 3; ++a) {
            for (uint256 b; b < 2; ++b) {
                for (uint256 c; c < 2; ++c) {
                    vm.revertToState(base);
                    base = vm.snapshotState();
                    _potX(pots[b]);
                    vm.prank(owner);
                    core.setXRate(rates[a]);
                    (bytes memory d, uint256 eta) = _queue(address(_mod(units[c])));
                    vm.warp(eta);
                    uint256 before = core.xRate();
                    _exec(d);
                    assertEq(core.xRate(), before, "continuous in the block of the set");
                    assertEq(_xRateAtCp(), before);
                    bool want = core.xPot() * 1e4 >= AVG * before * units[c];
                    assertEq(_xFunded(), want, "funded flag follows its definition under the new unit");
                    _warp(30 days);
                    uint256 later = core.xRate();
                    uint256 cap = uint256(st.xRateCap).min(core.xPot() * 1e4 / (AVG * units[c]));
                    assertLe(later, before.max(cap), "never climbs past the cap of the new unit");
                    assertGe(later, before, "never falls from time alone");
                    if (!want) assertEq(later, before, "unfunded: flat");
                }
            }
        }
    }

    /// FINDING RP-5 (operational): the exit bid keeps paying the old unit for the whole 7 day window. after a unit fall
    /// (each exit token now stands for more points) a seller who sells in the window is paid ten times what the new unit
    /// pays, and the statement composed from those credits exits for a tenth: the pot loses the difference
    function test_FINDING_bidPaysTheOldUnitUntilTheSetBlockSoAFallIsFrontRunnable() public {
        _enterPhase2();
        _potX(5e19);
        (bytes memory d, uint256 eta) = _queue(address(_mod(UNIT / 10)));
        // inside the window: 80 credits sold at the old unit
        uint256[] memory ids = _credits(seller, 80);
        vm.warp(eta - 1);
        uint256 b0 = xt.balanceOf(seller);
        vm.prank(seller);
        core.sellForExitToken(ids);
        uint256 paid = xt.balanceOf(seller) - b0;
        vm.warp(eta);
        _exec(d);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.composeExit();
        uint256 sid = STATEMENTS.supply();
        uint256 xb = xt.balanceOf(address(core));
        core.exitStatement(sid);
        uint256 returned = xt.balanceOf(address(core)) - xb;
        emit log_named_uint("paid to the seller at the old unit", paid);
        emit log_named_uint("returned by the exit at the new unit", returned);
        assertGt(paid, returned * 8, "paid about ten times what the statement returns");
        assertLt(core.xPot() + core.xToBuyback(), 5e19, "the pot is net down");
        _solvent();
    }

    // ------------------------------------------------------------------ the exit lane share

    function _exitLane() internal returns (uint256 sid, uint256 reimb) {
        uint256[] memory ids = _credits(seller, 80);
        _potX(5e19);
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        uint256 k = keeper.balance;
        vm.prank(keeper);
        core.composeExit();
        reimb = keeper.balance - k;
        sid = STATEMENTS.supply();
    }

    /// OK: at 10_000 the bid pot never refills from the exit lane, nothing divides by zero, the bid runs dry with a
    /// plain PotTooSmall, composeExit repays the same gas as at 0, and every unit of the exit goes to the buyback pot
    function test_OK_exitLaneShareAtMaxIsHarmless() public {
        _enterPhase2();
        uint256 snap = vm.snapshotState();
        (, uint256 reimb0) = _exitLane();
        vm.revertToState(snap);
        _edit(5_000, 10_000, 6 hours);
        (uint256 sid, uint256 reimb1) = _exitLane();
        assertEq(reimb1, reimb0, "the eth reimbursement does not depend on the share");
        uint256 pot = core.xPot();
        uint256 xb = xt.balanceOf(address(core));
        core.exitStatement(sid);
        uint256 got = xt.balanceOf(address(core)) - xb;
        assertEq(core.xPot(), pot, "the bid pot is not refilled");
        assertEq(core.xToBuyback(), got, "all of it to the buyback");
        // run the bid dry: views never revert, the next sale fails cleanly
        core.xRate();
        core.exitAuctionPrice();
        uint256[] memory more = _credits(seller, 1);
        vm.startPrank(owner);
        core.setXRate(core.settings().xRateCap);
        vm.stopPrank();
        _solvent();
        vm.prank(seller);
        core.sellForExitToken(more);
        for (uint256 i; i < 40 && core.xPot() > 1e6; ++i) {
            uint256[] memory x = _credits(seller, 1);
            vm.prank(seller);
            try core.sellForExitToken(x) {} catch {
                break;
            }
        }
        uint256[] memory last = _credits(seller, 1);
        vm.prank(seller);
        try core.sellForExitToken(last) {} catch (bytes memory err) {
            assertEq(bytes4(err), Core.PotTooSmall.selector);
        }
        _solvent();
    }

    /// OK: the share is read at the exit, not at the compose. a statement composed at 0 and exited at 10_000 goes whole
    /// to the buyback and the other way round, and the eth lane ignores the setting
    function test_OK_exitLaneShareChangedBetweenComposeAndExit() public {
        _enterPhase2();
        (uint256 sid,) = _exitLane();
        _edit(5_000, 10_000, 6 hours);
        uint256 pot = core.xPot();
        uint256 b = xt.balanceOf(address(core));
        core.exitStatement(sid);
        uint256 got = xt.balanceOf(address(core)) - b;
        assertEq(core.xToBuyback(), got);
        assertEq(core.xPot(), pot);
        _solvent();
    }

    /// OK: solvency and no unbooked value around the first set and a replacement. a gift before the first set is booked
    /// by skim, and after every step the pots equal the balance
    function test_OK_nothingUnbookedAroundSets() public {
        xt = new MockExitToken("Exit Token", "XT");
        xt.mint(address(core), 1e18);
        mod = new MockExitModule(address(xt), UNIT);
        _timelock(Core.Action.SetExitModule, abi.encode(address(mod)));
        assertEq(core.xPot(), 0);
        core.skim();
        assertEq(core.xPot(), 1e18, "the early gift is booked after the first set");
        xt.mint(address(core), 7);
        _replace(address(_mod(3 * UNIT)));
        core.skim();
        assertEq(core.xPot() + core.xToBuyback(), xt.balanceOf(address(core)));
        uint256 sid = _composeOnce().sid;
        _warp(72 hours);
        xt.mint(address(core), 5);
        core.exitStatement(sid);
        core.skim();
        assertEq(core.xPot() + core.xToBuyback(), xt.balanceOf(address(core)), "everything booked");
        _replace(address(_mod(UNIT)));
        assertEq(core.xPot() + core.xToBuyback(), xt.balanceOf(address(core)), "a set moves nothing");
    }

    /// OK: with nothing for sale the price after a set is never below the price before, for a rise, a fall and the
    /// same unit, and the stored start is the price while the clock is stopped
    function test_OK_emptyBuybackPotPriceNeverFallsAcrossASet() public {
        _enterPhase2();
        uint256[3] memory units = [UNIT * 7, UNIT / 7, UNIT];
        for (uint256 i; i < 3; ++i) {
            uint256 p = core.exitAuctionPrice();
            _replace(address(_mod(units[i])));
            assertGe(core.exitAuctionPrice(), p);
            assertEq(core.exitAuctionPrice(), core.xStartPrice());
        }
    }

    // ------------------------------------------------------------------ packing and bounds

    function _maxStruct() internal pure returns (Settings memory m) {
        m.flatBps = type(uint16).max;
        m.avgScore = type(uint32).max;
        m.climbBaseBps = type(uint16).max;
        m.climbDoubleEvery = type(uint32).max;
        m.climbMaxBps = type(uint16).max;
        m.dropBps = type(uint16).max;
        m.spendCapBps = type(uint16).max;
        m.bonusCapBps = type(uint16).max;
        m.tipSavingsBps = type(uint16).max;
        m.tipCapBps = type(uint16).max;
        m.reimburseBps = type(uint16).max;
        m.reimburseCapBps = type(uint16).max;
        m.reserveBps = type(uint16).max;
        m.auctionDuration = type(uint32).max;
        m.exitAfter = type(uint32).max;
        m.saleToBuybackBps = type(uint16).max;
        m.exitToBuybackBps = type(uint16).max;
        m.buybackSlice = type(uint128).max;
        m.buybackDelay = type(uint16).max;
        m.keeperTipBps = type(uint16).max;
        m.xRateCap = type(uint16).max;
        m.xRateFloor = type(uint16).max;
        m.xRateClimbPerHour = type(uint16).max;
        m.xRateDropPerCredit = type(uint16).max;
        m.xAuctionHalfLife = type(uint32).max;
        m.exitSliceCredits = type(uint16).max;
        m.rateCap = type(uint64).max;
        m.exitLaneToBuybackBps = type(uint16).max;
    }

    /// OK: with every field at the max of its TYPE (past the bounds, so a stray bit would show) the compiler layout and
    /// the library's decode agree, the new field sits alone at bits 176 to 191 of the third word, and a write to it
    /// touches nothing else
    function test_OK_packingEveryFieldAtTypeMaxRoundTrips() public {
        PackHarness h = new PackHarness();
        h.maxAll();
        (uint256 a, uint256 b, uint256 c) = h.words();
        assertEq(a, (1 << 240) - 1, "word 0");
        assertEq(b, type(uint256).max, "word 1");
        assertEq(c, (1 << 192) - 1, "word 2: 176 bits of neighbors then the 16 bit share");
        bytes32 slot = SettingsStore.SLOT;
        vm.store(address(core), slot, bytes32(a));
        vm.store(address(core), bytes32(uint256(slot) + 1), bytes32(b));
        vm.store(address(core), bytes32(uint256(slot) + 2), bytes32(c));
        assertEq(keccak256(abi.encode(core.settings())), keccak256(abi.encode(_maxStruct())), "decode(encode(x)) == x");
        PackHarness g = new PackHarness();
        g.onlyLane();
        (a, b, c) = g.words();
        assertEq(a, 0);
        assertEq(b, 0);
        assertEq(c, uint256(type(uint16).max) << 176, "the share alone");
        Settings memory u = CoreLib.unpack(a, b, c);
        assertEq(u.exitLaneToBuybackBps, type(uint16).max);
        assertEq(u.rateCap, 0);
        assertEq(u.exitSliceCredits, 0);
    }

    function test_OK_exitLaneShareBounds() public {
        Settings memory s = core.settings();
        s.exitLaneToBuybackBps = 10_001;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CoreLib.BadSetting.selector, bytes32("exitLaneToBuybackBps")));
        core.setSettings(s);
        s.exitLaneToBuybackBps = 10_000;
        _setSettings(s);
        assertEq(core.settings().exitLaneToBuybackBps, 10_000);
        assertEq(SettingsBounds.firstViolation(s), bytes32(0));
        s.exitLaneToBuybackBps = 0;
        _setSettings(s);
        assertEq(core.settings().exitLaneToBuybackBps, 0);
        // the field sits last in the check order: an earlier violation is reported first
        s.exitLaneToBuybackBps = 10_001;
        s.flatBps = 10_001;
        assertEq(SettingsBounds.firstViolation(s), bytes32("flatBps"));
    }

    /// INFO RP-6: a unit rise does not clamp the exit rate to what the pot carries under the new unit. the rate stays
    /// where it was, flat, and every credit the pot cannot pay reverts PotTooSmall until the owner lowers the rate
    function test_FINDING_unitRiseLeavesTheRateAbovePotAndFlat() public {
        _enterPhase2();
        _potX(2e19);
        (bytes memory d, uint256 eta) = _queue(address(_mod(UNIT * 1000)));
        vm.warp(eta);
        uint256 rate = core.xRate();
        assertGt(rate, 6_000, "climbed during the timelock under the old unit");
        _exec(d);
        assertEq(core.xRate(), rate, "not clamped");
        assertFalse(_xFunded());
        _warp(30 days);
        assertEq(core.xRate(), rate, "and flat, it does not recover by itself");
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(Core.PotTooSmall.selector);
        core.sellForExitToken(ids);
        // the owner lowers it at once
        uint256 floor = core.settings().xRateFloor;
        vm.prank(owner);
        core.setXRate(floor);
        _solvent();
    }

    /// OK: the way out of RP-2 exists and is instant: with something for sale, a short half life re-anchors at the price
    /// now and brings the poisoned price down 36 halvings in 6 hours
    function test_OK_poisonedStartCanBeWorkedOffWithAShortHalfLife() public {
        _enterPhase2();
        _replace(address(_mod(1)));
        _replace(address(_mod(UNIT)));
        _fillExitBuyback();
        assertGt(_coin(), core.SUPPLY() * 1e9);
        _edit(5_000, 0, 10 minutes);
        _warp(6 hours);
        assertLt(_coin(), core.SUPPLY(), "usable again after 6 hours");
    }
}
