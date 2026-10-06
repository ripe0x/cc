// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {Lane, ICreditScore, ICreditStrategy, Stack, Mainnet} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {HostileTarget} from "./attackers/HostileTarget.sol";
import {ProbeTarget} from "./attackers/ProbeTarget.sol";
import {DeafBuyer, ReentrantBuyer} from "./attackers/StatementBuyers.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";
import {CreditIds} from "./utils/CreditIds.sol";

/// shared helpers of the core unit suites. everything runs on the real stack of the Fixture: the live coin, hook,
/// pool, Credits, Statements, CreditStrategy and Seaport. a test that needs an exact pot donates eth to the core and
/// calls `skim()`, which is the real path for eth that did not come from the hook
abstract contract CoreBase is Fixture {
    using stdStorage for StdStorage;

    /// @dev the account that sells credits in these suites
    address internal alice;

    function setUp() public virtual override {
        super.setUp();
        alice = seller;
    }

    /// @dev sends `amount` of eth to the core from a plain account and books it with `skim`. the pot is exactly
    /// `amount` higher afterwards
    function _fund(uint256 amount) internal {
        vm.deal(funder, funder.balance + amount);
        vm.prank(funder);
        (bool ok,) = address(core).call{value: amount}("");
        assertTrue(ok, "donation");
        core.skim();
    }

    function _setController(address c) internal {
        _timelock(Core.Action.SetController, abi.encode(c));
    }

    /// @dev the rate after a spend of `x` from a pot of `p`
    function _dropped(uint256 r, uint256 x, uint256 p) internal pure returns (uint256) {
        return r - r * 1000 * x / (10_000 * p);
    }

    function _listing(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeCall(ICreditStrategy.sellTargetNFT, (id));
    }

    function _page(uint256 first, uint256 fill) internal pure returns (uint256[80] memory ids) {
        for (uint256 i; i < 80; ++i) {
            ids[i] = fill;
        }
        ids[0] = first;
    }

    /// @dev puts `n` fresh credits of `who` in the eth pile through the sell door, with the pot topped up first so the
    /// hourly cap never binds
    function _sellN(address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = _credits(who, n);
        _fund(20 ether);
        vm.prank(who);
        core.sellForEth(ids);
    }
}

contract CoreUnitTest is CoreBase {
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    /*//////////////////////////////////////////////////////////////
                              parameters
    //////////////////////////////////////////////////////////////*/

    function test_parameters() public view {
        assertEq(core.SUPPLY(), 1_000_000_000e18);
        assertEq(core.FEE_BPS(), 1000);
        assertEq(core.CREATOR_BPS(), 50);
        assertEq(core.AVG_SCORE(), 4_330_000);
        assertEq(core.RATE_START(), 4e12);
        assertEq(core.CLIMB_BASE_BPS_PER_HOUR(), 100);
        assertEq(core.CLIMB_DOUBLE_EVERY(), 24 hours);
        assertEq(core.CLIMB_MAX_BPS_PER_HOUR(), 800);
        assertEq(core.DROP_BPS(), 1000);
        assertEq(core.SPEND_CAP_BPS_PER_HOUR(), 2000);
        assertEq(core.BONUS_CAP_BPS(), 2500);
        assertEq(core.TIP_SAVINGS_BPS(), 1000);
        assertEq(core.TIP_CAP_BPS(), 200);
        assertEq(core.AUCTION_START_X(), 40_000);
        assertEq(core.AUCTION_FLOOR_X(), 12_000);
        assertEq(core.AUCTION_LENGTH(), 72 hours);
        assertEq(core.SALE_SPLIT(), 5000);
        assertEq(core.EXIT_SPLIT(), 5000);
        assertEq(core.BUYBACK_SLICE(), 1 ether);
        assertEq(core.BUYBACK_DELAY(), 25);
        assertEq(core.KEEPER_TIP_BPS(), 50);
        assertEq(core.XRATE_START(), 6000);
        assertEq(core.XRATE_CAP(), 9700);
        assertEq(core.XRATE_FLOOR(), 3000);
        assertEq(core.XRATE_CLIMB_PER_HOUR(), 100);
        assertEq(core.XRATE_DROP_PER_CREDIT(), 20);
        assertEq(core.XAUCTION_HALF_LIFE(), 6 hours);
        assertEq(core.TIMELOCK(), 7 days);
        assertEq(core.OVERPRINT_CAP_PER_DAY(), 8);
    }

    function test_constructorState() public view {
        assertEq(core.OWNER(), owner);
        assertEq(core.COIN(), address(coin));
        assertEq(core.HOOK(), Mainnet.SKIM_HOOK);
        assertEq(core.controller(), address(ctl));
        assertTrue(core.allowedTarget(Mainnet.SEAPORT));
        assertTrue(core.allowedTarget(Mainnet.CREDIT_STRATEGY));
        assertTrue(CREDITS.isApprovedForAll(address(core), address(STATEMENTS)));
        assertEq(core.ethRate(), 4e12);
        assertEq(core.lastFillTime(), launchTime);
        assertFalse(core.funded());
        assertEq(core.ethPot(), 0);
        assertEq(core.exitModule(), address(0));
        assertEq(core.exitToken(), address(0));
        assertEq(core.unitPerPoint(), 0);
        assertEq(core.xStartPrice(), 0);
        assertFalse(core.frozen());
    }

    function test_constructorRejectsZero() public {
        Stack memory st = lc.stack;
        uint256 r = lc.rateStart;
        vm.expectRevert(Core.ZeroAddress.selector);
        new Core(address(0), address(coin), address(ctl), st, r);
        vm.expectRevert(Core.ZeroAddress.selector);
        new Core(owner, address(0), address(ctl), st, r);
        vm.expectRevert(Core.ZeroAddress.selector);
        new Core(owner, address(coin), address(0), st, r);
        // every address of the stack is required
        for (uint256 i; i < 5; ++i) {
            Stack memory bad =
                Stack(st.poolManager, st.hook, st.tickSpacing, st.poolFee, st.factory, st.locker, st.escrow);
            if (i == 0) bad.poolManager = address(0);
            if (i == 1) bad.hook = address(0);
            if (i == 2) bad.factory = address(0);
            if (i == 3) bad.locker = address(0);
            if (i == 4) bad.escrow = address(0);
            vm.expectRevert(Core.ZeroAddress.selector);
            new Core(owner, address(coin), address(ctl), bad, r);
        }
        Stack memory flat = Stack(st.poolManager, st.hook, 0, st.poolFee, st.factory, st.locker, st.escrow);
        vm.expectRevert(Core.BadStack.selector);
        new Core(owner, address(coin), address(ctl), flat, r);
    }

    /// the opening bid is a deploy input bounded to [1e11, 1e15] wei per whole point
    function test_rateStartBounds() public {
        assertEq(core.RATE_START_MIN(), 1e11);
        assertEq(core.RATE_START_MAX(), 1e15);
        assertEq(core.RATE_START_MIN(), RATE_START_MIN);
        assertEq(core.RATE_START_MAX(), RATE_START_MAX);
        vm.expectRevert(Core.BadRate.selector);
        new Core(owner, address(coin), address(ctl), lc.stack, 1e11 - 1);
        vm.expectRevert(Core.BadRate.selector);
        new Core(owner, address(coin), address(ctl), lc.stack, 1e15 + 1);
        Core lo = new Core(owner, address(coin), address(ctl), lc.stack, 1e11);
        Core hi = new Core(owner, address(coin), address(ctl), lc.stack, 1e15);
        assertEq(lo.RATE_START(), 1e11);
        assertEq(lo.ethRate(), 1e11);
        assertEq(hi.RATE_START(), 1e15);
        assertEq(hi.rateAtCheckpoint(), 1e15);
    }

    /// the stack is stored as given, nothing of it is hardcoded in the core
    function test_stackIsStored() public {
        Stack memory other =
            Stack(address(0x1111), address(0x2222), 60, 3000, address(0x3333), address(0x4444), address(0x5555));
        Core c2 = new Core(owner, address(coin), address(ctl), other, lc.rateStart);
        assertEq(address(c2.MANAGER()), address(0x1111));
        assertEq(c2.HOOK(), address(0x2222));
        assertEq(c2.TICK_SPACING(), 60);
        assertEq(c2.POOL_FEE(), 3000);
        assertEq(c2.FACTORY(), address(0x3333));
        assertEq(c2.LOCKER(), address(0x4444));
        assertEq(c2.ESCROW(), address(0x5555));
        // only the configured hook is booked as fee income
        vm.deal(address(0x2222), 1 ether);
        vm.prank(address(0x2222));
        (bool ok,) = address(c2).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(c2.ethPot(), 1 ether);
        vm.deal(Mainnet.SKIM_HOOK, 1 ether);
        vm.prank(Mainnet.SKIM_HOOK);
        (ok,) = address(c2).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(c2.ethPot(), 1 ether, "the default hook is not special to this core");
    }

    /*//////////////////////////////////////////////////////////////
                           fee intake and skim
    //////////////////////////////////////////////////////////////*/

    /// eth the hook pushes after a real swap is booked at once. eth from anyone else waits for `skim`
    function test_receiveBooksHookEth_skimBooksTheRest() public {
        _skipSniperWindow();
        _buyCoin(funder, 1 ether);
        uint256 pot = core.ethPot();
        assertEq(pot, 0.095 ether, "9.5 points of a 1 eth buy");
        assertEq(address(core).balance, pot);

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        (bool ok,) = address(core).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(core.ethPot(), pot, "a plain send books nothing");
        assertEq(address(core).balance, pot + 2 ether);

        core.skim();
        assertEq(core.ethPot(), pot + 2 ether);
        core.skim();
        assertEq(core.ethPot(), pot + 2 ether, "nothing left to book");
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                               rate climb
    //////////////////////////////////////////////////////////////*/

    function test_rate_unfundedNeverClimbs() public {
        assertEq(core.ethRate(), 4e12);
        _warp(1000 hours);
        assertEq(core.ethRate(), 4e12);

        // one avg credit costs 1.732e15 at the start rate and the hourly cap is 20 percent of the pot, so funded needs
        // a pot of 5 average credits (8.66e15). between 1 and 5 average credits the rate does not climb
        _fund(1.7e15);
        assertFalse(core.funded());
        _warp(1000 hours);
        assertEq(core.ethRate(), 4e12);
        _fund(3e15);
        assertFalse(core.funded(), "about 2.7 average credits");
        _warp(1000 hours);
        assertEq(core.ethRate(), 4e12);
        _fund(3.9e15);
        assertEq(core.ethPot(), 8.6e15);
        assertFalse(core.funded(), "just under 5 average credits");
        _warp(1000 hours);
        assertEq(core.ethRate(), 4e12);

        _fund(1.4e16);
        assertTrue(core.funded());
        assertEq(core.ethRate(), 4e12, "no retroactive climb");
        // the wait since deploy is long, so the tier is the fastest one. the pot is large enough not to clamp
        _warp(10 hours);
        assertApproxEqRel(core.ethRate(), 8_635_699_989_091, 1e9);
    }

    function test_rate_climbTiers() public {
        _fund(10 ether);
        assertTrue(core.funded());
        _warp(1 hours);
        assertApproxEqRel(core.ethRate(), 4_040_000_000_000, 1e9);
        _warp(9 hours);
        assertApproxEqRel(core.ethRate(), 4_418_488_501_644, 1e9, "10h at 1 percent");
        _warp(20 hours);
        assertApproxEqRel(core.ethRate(), 5_719_709_774_456, 1e9, "24h at 1 percent then 6h at 2 percent");
        _warp(52 hours);
        assertApproxEqRel(core.ethRate(), 45_207_946_718_638, 1e9, "tiers 1, 2, 4 percent then 10h at 8 percent");
    }

    function test_rate_checkpointKeepsTierClock() public {
        _fund(10 ether);
        _warp(30 hours);
        uint256 r30 = core.ethRate();
        _fund(1);
        assertEq(core.rateAtCheckpoint(), r30);
        assertEq(core.checkpointTime(), block.timestamp);
        assertEq(core.lastFillTime(), launchTime);
        _warp(52 hours);
        assertApproxEqRel(core.ethRate(), 45_207_946_718_638, 1e9, "same curve as without the checkpoint");
    }

    function test_rate_fundedClamp() public {
        _fund(0.02 ether);
        assertTrue(core.funded());
        _warp(10 hours);
        assertApproxEqRel(core.ethRate(), 4_418_488_501_644, 1e9);
        _warp(100 hours);
        uint256 cap = uint256(0.02 ether) * 2000 / 4_330_000;
        assertEq(cap, 9_237_875_288_683);
        assertEq(core.ethRate(), cap, "stops where the hourly cap no longer buys one average credit");
        _warp(10_000 hours);
        assertEq(core.ethRate(), cap);
        // at the clamp the hourly cap still affords one average credit, and one wei more rate would not.
        assertGe(core.ethPot() * 2000, 4_330_000 * core.ethRate());
        assertLt(core.ethPot() * 2000, 4_330_000 * (core.ethRate() + 1));

        // more fees lift the clamp and the climb resumes from the checkpoint.
        _fund(0.02 ether);
        assertEq(core.rateAtCheckpoint(), cap);
        _warp(1 hours);
        assertApproxEqRel(core.ethRate(), cap * 108 / 100, 1e9, "tier 8 percent after a long wait");
    }

    /// at the clamp an average credit can actually be sold in the same block. 20 percent of the pot buys one average
    /// credit there, so every credit scoring at most the average passes the hourly cap in a fresh window, the rate
    /// drops with the fill, and a credit that would cost more than the cap is refused by it
    function test_rate_atTheClampAnAverageCreditSells() public {
        _fund(0.02 ether);
        _warp(3000 hours);
        uint256 rate = core.ethRate();
        assertEq(rate, uint256(0.02 ether) * 2000 / core.AVG_SCORE(), "at the clamp");
        uint256 hourlyCap = core.ethPot() * 2000 / 10_000;
        // an average credit costs the whole hourly cap, rounded down by the rate
        assertLe(core.AVG_SCORE() * rate / 1e4, hourlyCap);
        assertGt(core.AVG_SCORE() * (rate + 1) / 1e4 + 1, hourlyCap);

        uint256[] memory ids = _credits(alice, 40);
        uint256 sold;
        uint256 refused;
        for (uint256 i; i < ids.length; ++i) {
            uint256 price = core.ceilingOf(ids[i]);
            bool atMostAverage = core.scoreOf(ids[i]) <= core.AVG_SCORE();
            uint256 snap = vm.snapshotState();
            uint256 before = alice.balance;
            vm.prank(alice);
            if (atMostAverage) {
                core.sellForEth(_one(ids[i]));
                assertEq(alice.balance - before, price, "paid the ceiling");
                assertLt(core.rateAtCheckpoint(), rate, "the fill dropped the rate");
                ++sold;
            } else if (price > hourlyCap) {
                vm.expectRevert(Core.HourlyCap.selector);
                core.sellForEth(_one(ids[i]));
                ++refused;
            }
            vm.revertToState(snap);
        }
        assertGt(sold, 0, "some credit at or under the average sold");
        assertGt(refused, 0, "some credit over the average was refused by the cap");
    }

    /// the same clamp when the pot is filled by real swaps: it is measured, not assumed
    function test_rate_fundedClampWithRealFees() public {
        _skipSniperWindow();
        _fundPot(0.01 ether);
        uint256 pot = core.ethPot();
        _warp(2000 hours);
        assertEq(core.ethRate(), pot * 2000 / core.AVG_SCORE(), "clamp at what the hourly cap affords");
    }

    /// the pot shrinks below one average credit while the rate sits at its clamp. the next checkpoint applies no climb
    /// under the smaller pot and the rate never rises again. no real path shrinks the pot without also dropping the
    /// rate, so the pot slot is written directly and the balance is set to match
    function test_rate_goesUnfundedAfterPotDrops() public {
        _fund(0.02 ether);
        _warp(100 hours);
        uint256 cap = core.ethRate();
        _fund(1);
        assertEq(core.rateAtCheckpoint(), cap);
        stdstore.target(address(core)).sig("ethPot()").checked_write(uint256(1e15));
        vm.deal(address(core), 1e15);
        _fund(1);
        assertEq(core.rateAtCheckpoint(), cap, "no climb applied under the smaller pot");
        assertFalse(core.funded());
        _warp(500 hours);
        assertEq(core.ethRate(), cap, "never rises while unfunded");
        _solvent();
    }

    function test_rate_dropAndClockResetOnFill() public {
        _fund(10 ether);
        _warp(30 hours);
        uint256 id = _credits(alice, 1)[0];
        uint256 rate = core.ethRate();
        uint256 price = core.ceilingOf(id);
        assertEq(price, core.scoreOf(id) * rate / 1e4);

        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(id));

        assertEq(alice.balance - before, price);
        assertEq(core.ethPot(), 10 ether - price);
        assertEq(core.rateAtCheckpoint(), _dropped(rate, price, 10 ether));
        assertEq(core.lastFillTime(), block.timestamp);
        assertEq(core.checkpointTime(), block.timestamp);
        assertEq(CREDITS.ownerOf(id), address(core));
        (bool inPile, Lane lane, uint256 cost,) = core.creditInfo(id);
        assertTrue(inPile);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(cost, price);
        assertEq(core.pileSize(Lane.Eth), 1);
        _solvent();

        // the climb restarts at the base tier after a fill.
        uint256 after_ = core.rateAtCheckpoint();
        _warp(1 hours);
        assertApproxEqRel(core.ethRate(), after_ * 101 / 100, 1e9);
    }

    function test_sellForEth_multiDropsPerCredit() public {
        _fund(10 ether);
        uint256[] memory ids = _credits(alice, 3);
        uint256 r = 4e12;
        uint256 p = 10 ether;
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            uint256 price = core.scoreOf(ids[i]) * r / 1e4;
            r = _dropped(r, price, p);
            p -= price;
            total += price;
        }
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(ids);
        assertEq(alice.balance - before, total);
        assertEq(core.rateAtCheckpoint(), r);
        assertEq(core.ethPot(), p);
        assertEq(core.pileSize(Lane.Eth), 3);
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                              hourly cap
    //////////////////////////////////////////////////////////////*/

    function test_hourlyCap_window() public {
        _fund(0.05 ether);
        uint256[] memory ids = _credits(alice, 14);
        uint256 cap = uint256(0.05 ether) * 2000 / 10_000;
        uint256 spent;
        uint256 i;
        for (; i < ids.length; ++i) {
            uint256 price = core.ceilingOf(ids[i]);
            if (spent + price > cap) break;
            vm.prank(alice);
            core.sellForEth(_one(ids[i]));
            spent += price;
        }
        assertLt(i, ids.length, "cap reached");
        assertGt(spent, 0);
        assertLe(spent, cap);

        vm.prank(alice);
        vm.expectRevert(Core.HourlyCap.selector);
        core.sellForEth(_one(ids[i]));

        // the window reopens exactly one hour after it opened.
        _warp(1 hours - 1);
        vm.prank(alice);
        vm.expectRevert(Core.HourlyCap.selector);
        core.sellForEth(_one(ids[i]));
        _warp(1);
        vm.prank(alice);
        core.sellForEth(_one(ids[i]));
        _solvent();
    }

    function test_hourlyCap_countsAllIdsOfOneCall() public {
        _fund(0.05 ether);
        uint256[] memory ids = _credits(alice, 14);
        vm.prank(alice);
        vm.expectRevert(Core.HourlyCap.selector);
        core.sellForEth(ids);
    }

    /*//////////////////////////////////////////////////////////////
                              sell door
    //////////////////////////////////////////////////////////////*/

    function test_sellForEth_minOut() public {
        _fund(10 ether);
        uint256 id = _credits(alice, 1)[0];
        uint256 price = core.ceilingOf(id);

        vm.prank(alice);
        vm.expectRevert(Core.Slippage.selector);
        core.sellForEth(_one(id), price + 1);

        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(id), price);
        assertEq(alice.balance - before, price);
    }

    function test_sellForEth_guards() public {
        uint256[] memory ids = _credits(alice, 1);
        uint256[] memory none = new uint256[](0);

        vm.prank(alice);
        vm.expectRevert(Core.Empty.selector);
        core.sellForEth(none);

        vm.prank(alice);
        vm.expectRevert(Core.ZeroId.selector);
        core.sellForEth(_one(0));

        vm.prank(alice);
        vm.expectRevert(Core.PotTooSmall.selector);
        core.sellForEth(ids);

        _fund(10 ether);
        vm.prank(keeper);
        vm.expectRevert(Core.NotOwner.selector);
        core.sellForEth(ids);

        // not approved
        address bob = _user("bob");
        uint256 id = CreditIds.at(500);
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, bob, id);
        vm.prank(bob);
        vm.expectRevert();
        core.sellForEth(_one(id));
    }

    function test_sellForEth_cannotSellACreditTheCoreOwns() public {
        _fund(10 ether);
        uint256 id = _credits(alice, 1)[0];
        vm.prank(alice);
        core.sellForEth(_one(id));
        vm.prank(alice);
        vm.expectRevert(Core.NotOwner.selector);
        core.sellForEth(_one(id));
    }

    /*//////////////////////////////////////////////////////////////
                         controller is only read
    //////////////////////////////////////////////////////////////*/

    function test_controller_bonusAppliesAndClamps() public {
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));
        _fund(10 ether);
        uint256 id = _credits(alice, 1)[0];
        uint256 base = core.scoreOf(id) * core.ethRate() / 1e4;
        assertEq(core.ceilingOf(id), base);

        scripted.setWants(id, 1000);
        assertEq(core.ceilingOf(id), base * 11_000 / 10_000);
        scripted.setWants(id, 2500);
        assertEq(core.ceilingOf(id), base * 12_500 / 10_000);
        scripted.setWants(id, 60_000);
        assertEq(core.ceilingOf(id), base * 12_500 / 10_000, "clamped to the bonus cap");

        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(id));
        assertEq(alice.balance - before, base * 12_500 / 10_000);
    }

    function test_controller_revertingOrOversizedOrGreedyWantsDoesNotBlockDoors() public {
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));
        _fund(10 ether);
        uint256[] memory ids = _credits(alice, 4);
        uint256 base = core.scoreOf(ids[0]) * core.ethRate() / 1e4;

        scripted.setRevertWants(true);
        assertEq(core.ceilingOf(ids[0]), base, "revert counts as zero");

        scripted.setRevertWants(false);
        scripted.setRawWants(true);
        assertEq(core.ceilingOf(ids[0]), base * 12_500 / 10_000, "oversized word clamps");

        scripted.setRawWants(false);
        scripted.setBurnWants(true);
        uint256 gasBefore = gasleft();
        assertEq(core.ceilingOf(ids[0]), base, "gas burner counts as zero");
        assertLt(gasBefore - gasleft(), 400_000, "bounded gas");

        // the sell door still works with a gas burning controller.
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(ids[0]));
        assertEq(alice.balance - before, base);

        // an empty controller address answers nothing and counts as zero too.
        _setController(address(0xBEEF));
        assertEq(core.ceilingOf(ids[1]), core.scoreOf(ids[1]) * core.ethRate() / 1e4);
        vm.expectRevert(Core.NotReady.selector);
        core.compose();
    }

    /*//////////////////////////////////////////////////////////////
                           buyListing: real strategy
    //////////////////////////////////////////////////////////////*/

    /// funds the pot and warps hour by hour until the ceiling clears the listing price of id.
    function _fundAndClimb(uint256 id, uint256 price) internal {
        _fund(10 ether);
        _warpUntilCeiling(id, price);
    }

    function test_buyListing_aboveCeilingReverts() public {
        _fund(10 ether);
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertGt(price, core.ceilingOf(LISTED_A), "start rate is far below the listing");
        vm.prank(keeper);
        vm.expectRevert(Core.AboveCeiling.selector);
        core.buyListing(price, _listing(LISTED_A), LISTED_A, STRATEGY);
    }

    function test_buyListing_tipIsTenthOfSavingsWhenSmall() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertEq(price, 0.036 ether);
        _fundAndClimb(LISTED_A, price);

        uint256 ceiling = core.ceilingOf(LISTED_A);
        uint256 rate = core.ethRate();
        uint256 tip = (ceiling - price) * 1000 / 10_000;
        assertLt(tip, price * 200 / 10_000, "savings bound branch");
        assertGt(tip, 0);

        uint256 pot = core.ethPot();
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        core.buyListing(price, _listing(LISTED_A), LISTED_A, STRATEGY);

        assertEq(keeper.balance - keeperBefore, tip);
        assertEq(core.ethPot(), pot - price - tip);
        assertEq(core.rateAtCheckpoint(), _dropped(rate, price + tip, pot));
        assertEq(core.lastFillTime(), block.timestamp);
        assertEq(CREDITS.ownerOf(LISTED_A), address(core));
        assertEq(ICreditStrategy(STRATEGY).nftForSale(LISTED_A), 0);
        (bool inPile, Lane lane, uint256 cost,) = core.creditInfo(LISTED_A);
        assertTrue(inPile);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(cost, price + tip, "cost basis includes the tip");
        _solvent();
    }

    function test_buyListing_tipIsCappedAtTwoPercentOfCost() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _fundAndClimb(LISTED_A, price);
        _warp(30 hours);
        uint256 ceiling = core.ceilingOf(LISTED_A);
        assertGt((ceiling - price) * 1000 / 10_000, price * 200 / 10_000);

        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        core.buyListing(price, _listing(LISTED_A), LISTED_A, STRATEGY);
        assertEq(keeper.balance - keeperBefore, price * 200 / 10_000);
        (,, uint256 cost,) = core.creditInfo(LISTED_A);
        assertEq(cost, price + price * 200 / 10_000);
        _solvent();
    }

    function test_buyListing_failedCallRevertsOnlyThatBuy() public {
        uint256 priceA = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        uint256 priceB = ICreditStrategy(STRATEGY).nftForSale(LISTED_B);
        _fundAndClimb(LISTED_A, priceA);
        _warpUntilCeiling(LISTED_B, priceB);
        uint256 pot = core.ethPot();
        uint256 rate = core.ethRate();

        // wrong value, the strategy reverts.
        vm.prank(keeper);
        vm.expectRevert(Core.CallFailed.selector);
        core.buyListing(priceA - 1, _listing(LISTED_A), LISTED_A, STRATEGY);

        // wrong calldata, the strategy reverts.
        vm.prank(keeper);
        vm.expectRevert(Core.CallFailed.selector);
        core.buyListing(priceA, _listing(LISTED_B), LISTED_A, STRATEGY);

        // asked for one id but the call delivers another.
        vm.prank(keeper);
        vm.expectRevert(Core.NoCredit.selector);
        core.buyListing(priceB, _listing(LISTED_B), LISTED_A, STRATEGY);

        assertEq(core.ethPot(), pot);
        assertEq(core.ethRate(), rate);
        assertEq(core.pileSize(Lane.Eth), 0);

        // an unrelated buy still goes through.
        vm.prank(keeper);
        core.buyListing(priceB, _listing(LISTED_B), LISTED_B, STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_B), address(core));
        assertEq(core.pileSize(Lane.Eth), 1);

        // the core never buys a credit it already owns.
        vm.prank(keeper);
        vm.expectRevert(Core.AlreadyOwned.selector);
        core.buyListing(priceB, _listing(LISTED_B), LISTED_B, STRATEGY);
        _solvent();
    }

    /// targets that were never allowed, and every address the core itself refuses, are not callable
    function test_buyListing_targetGuards() public {
        _fund(10 ether);
        address[10] memory refused = [
            address(0xABCD),
            address(CREDITS),
            address(STATEMENTS),
            address(core),
            address(coin),
            Mainnet.SKIM_HOOK,
            Mainnet.POOL_MANAGER,
            Mainnet.ARTCOINS_FACTORY,
            Mainnet.LP_LOCKER,
            Mainnet.FEE_ESCROW
        ];
        vm.startPrank(keeper);
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(Core.TargetNotAllowed.selector);
            core.buyListing(1, "", LISTED_A, refused[i]);
        }
        vm.expectRevert(Core.ZeroId.selector);
        core.buyListing(1, "", 0, STRATEGY);
        vm.stopPrank();
    }

    /// the listing is real but the pot is small: a buy larger than a fifth of the pot hits the hourly cap, and one
    /// larger than the pot fails first with `PotTooSmall`
    function test_buyListing_hourlyCapAndPotChecks() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        // the rate clamps where 20 percent of the pot buys one average credit. credit A scores 1.5 average credits, so a
        // pot of 4 prices clears its price at the clamp (ceiling 1.21 prices) while the hourly cap (0.8 prices) does not
        _fund(price * 4);
        _warpUntilCeiling(LISTED_A, price);
        assertGt(price, core.ethPot() * 2000 / 10_000);
        vm.prank(keeper);
        vm.expectRevert(Core.HourlyCap.selector);
        core.buyListing(price, _listing(LISTED_A), LISTED_A, STRATEGY);

        // a pot of one wei less than the price: the pot check comes before the ceiling and cap checks
        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        vm.expectRevert(Core.PotTooSmall.selector);
        core.buyListing(price * 4 + 1, _listing(LISTED_A), LISTED_A, STRATEGY);

        // with a pot of ten times the price the cap no longer binds, tip included
        _fund(price * 6);
        vm.prank(keeper);
        core.buyListing(price, _listing(LISTED_A), LISTED_A, STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_A), address(core));
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                       buyListing: hostile targets
    //////////////////////////////////////////////////////////////*/

    function test_buyListing_hostileTargetThatKeepsEthReverts() public {
        HostileTarget hostile = new HostileTarget();
        _allow(address(hostile));
        _fund(10 ether);
        uint256 before = address(core).balance;
        uint256 hostileBefore = address(hostile).balance;
        vm.prank(keeper);
        vm.expectRevert(Core.NoCredit.selector);
        core.buyListing(1 gwei, "", LISTED_A, address(hostile));
        assertEq(address(core).balance, before, "core balance");
        assertEq(address(hostile).balance, hostileBefore, "the eth went nowhere");
        assertEq(core.ethPot(), 10 ether, "pot");
    }

    function _probe(uint256 id, uint256 mode) internal returns (ProbeTarget p) {
        p = new ProbeTarget(address(core));
        p.setMode(mode);
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(p), id);
        _allow(address(p));
    }

    /// a target that refunds part of what it was paid: the cost is net of the refund, the refund is booked nowhere
    function test_buyListing_refundIsNotBooked() public {
        uint256 id = CreditIds.at(630);
        ProbeTarget p = _probe(id, 5);
        _fund(10 ether);
        uint256 ceiling = core.ceilingOf(id);
        uint256 value = ceiling * 3 / 4;
        uint256 cost = value - value / 2;
        uint256 tip = ((ceiling - cost) * 1000 / 10_000).min(cost * 200 / 10_000);
        uint256 excessBefore = address(core).balance - core.ethPot() - core.ethToBuyback();
        uint256 listingBefore = address(p).balance;

        vm.prank(keeper);
        core.buyListing(value, abi.encodeCall(ProbeTarget.fill, (id, 0)), id, address(p));

        (,, uint256 booked,) = core.creditInfo(id);
        assertEq(booked, cost + tip, "cost is net of the refund");
        assertEq(core.ethPot(), 10 ether - cost - tip);
        assertEq(address(core).balance - core.ethPot() - core.ethToBuyback(), excessBefore, "refund booked nowhere");
        assertEq(address(p).balance - listingBefore, cost, "the listing kept the net price");
        _solvent();

        // skim sees nothing extra.
        uint256 pot = core.ethPot();
        core.skim();
        assertEq(core.ethPot(), pot);
    }

    /// a target that sends back more than it was paid leaves the core richer: a negative cost is refused
    function test_buyListing_refundAboveValueReverts() public {
        uint256 id = CreditIds.at(631);
        ProbeTarget p = _probe(id, 4);
        vm.deal(address(p), 1);
        _fund(10 ether);
        uint256 value = core.ceilingOf(id) / 2;
        vm.prank(keeper);
        vm.expectRevert(Core.BadCost.selector);
        core.buyListing(value, abi.encodeCall(ProbeTarget.fill, (id, 0)), id, address(p));
    }

    /// reentry from the target into every guarded door fails, and a wrong or doubled delivery reverts the buy
    function test_buyListing_probeModes() public {
        _fund(10 ether);
        for (uint256 m; m <= 8; ++m) {
            uint256 id = CreditIds.at(600 + m);
            ProbeTarget p = _probe(id, m);
            vm.deal(address(p), 1 ether);
            uint256 value = (core.ceilingOf(id) / 2).min(core.ethPot() / 20);
            vm.prank(keeper);
            try core.buyListing(value, abi.encodeCall(ProbeTarget.fill, (id, CreditIds.at(620 + m))), id, address(p)) {
                assertTrue(p.honest(m), "a hostile mode succeeded");
            } catch {
                assertFalse(p.honest(m), "an honest mode failed");
            }
            assertEq(p.reentered(), 0, "a reentry got through");
            if (m == 7 || m == 8) assertGt(p.attempts(), 0, "the target did try");
            _solvent();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                timelock
    //////////////////////////////////////////////////////////////*/

    function test_timelock_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert(Core.OnlyOwner.selector);
        core.queue(Core.Action.Freeze, "");
        vm.prank(alice);
        vm.expectRevert(Core.OnlyOwner.selector);
        core.execute(Core.Action.Freeze, "");
        vm.prank(alice);
        vm.expectRevert(Core.OnlyOwner.selector);
        core.cancel(Core.Action.Freeze, "");
        vm.prank(alice);
        vm.expectRevert(Core.OnlyOwner.selector);
        core.removeTarget(STRATEGY);
    }

    function test_timelock_queueExecuteCancel() public {
        address newCtl = address(new ScriptedController());
        bytes memory data = abi.encode(newCtl);
        bytes32 id = keccak256(abi.encode(Core.Action.SetController, data));

        vm.startPrank(owner);
        vm.expectRevert(Core.NotQueued.selector);
        core.execute(Core.Action.SetController, data);

        vm.expectEmit(true, false, false, true);
        emit Core.Queued(id, Core.Action.SetController, data, block.timestamp + 7 days);
        core.queue(Core.Action.SetController, data);
        assertEq(core.queuedEta(id), block.timestamp + 7 days);

        vm.expectRevert(Core.AlreadyQueued.selector);
        core.queue(Core.Action.SetController, data);

        _warp(7 days - 1);
        vm.expectRevert(Core.TooEarly.selector);
        core.execute(Core.Action.SetController, data);
        _warp(1);
        core.execute(Core.Action.SetController, data);
        assertEq(core.controller(), newCtl);
        assertEq(core.queuedEta(id), 0);

        vm.expectRevert(Core.NotQueued.selector);
        core.execute(Core.Action.SetController, data);

        // cancel
        core.queue(Core.Action.SetController, abi.encode(address(ctl)));
        core.cancel(Core.Action.SetController, abi.encode(address(ctl)));
        _warp(8 days);
        vm.expectRevert(Core.NotQueued.selector);
        core.execute(Core.Action.SetController, abi.encode(address(ctl)));
        vm.expectRevert(Core.NotQueued.selector);
        core.cancel(Core.Action.SetController, abi.encode(address(ctl)));
        vm.stopPrank();
    }

    /// an action is keyed by its kind and its data: the same data under another kind is not queued
    function test_timelock_idCoversTheActionKind() public {
        bytes memory data = abi.encode(address(0x1234));
        vm.startPrank(owner);
        core.queue(Core.Action.SetController, data);
        _warp(7 days);
        vm.expectRevert(Core.NotQueued.selector);
        core.execute(Core.Action.AddTarget, data);
        vm.expectRevert(Core.NotQueued.selector);
        core.execute(Core.Action.SetExitModule, data);
        vm.stopPrank();
    }

    function test_timelock_setControllerRejectsZero() public {
        vm.startPrank(owner);
        core.queue(Core.Action.SetController, abi.encode(address(0)));
        _warp(7 days);
        vm.expectRevert(Core.ZeroAddress.selector);
        core.execute(Core.Action.SetController, abi.encode(address(0)));
        vm.stopPrank();
    }

    function test_timelock_freezeRemovesControllerPowerForever() public {
        _setController(address(new ScriptedController()));
        bytes memory beforeFreeze = abi.encode(address(ctl));
        // an action queued before the freeze cannot execute after it
        vm.prank(owner);
        core.queue(Core.Action.SetController, beforeFreeze);
        _timelock(Core.Action.Freeze, "");
        assertTrue(core.frozen());

        vm.startPrank(owner);
        vm.expectRevert(Core.Frozen.selector);
        core.execute(Core.Action.SetController, beforeFreeze);
        vm.expectRevert(Core.Frozen.selector);
        core.queue(Core.Action.SetController, abi.encode(address(0xBEEF)));
        vm.stopPrank();

        // the other powers survive the freeze.
        HostileTarget t = new HostileTarget();
        _allow(address(t));
        assertTrue(core.allowedTarget(address(t)));
        vm.prank(owner);
        core.removeTarget(address(t));
        assertFalse(core.allowedTarget(address(t)));
    }

    function test_timelock_exitModuleOnce() public {
        _enterPhase2();
        assertEq(core.exitModule(), address(mod));
        assertEq(core.exitToken(), address(xt));
        assertEq(core.unitPerPoint(), UNIT);
        assertEq(core.xRate(), 6000);
        assertEq(core.xStartPrice(), core.SUPPLY() * 1e18 / (20 * core.AVG_SCORE() * UNIT), "opening auction price");
        assertEq(core.xStartTime(), block.timestamp);

        MockExitModule other = new MockExitModule(address(xt), 1e10);
        vm.startPrank(owner);
        core.queue(Core.Action.SetExitModule, abi.encode(address(other)));
        _warp(7 days);
        vm.expectRevert(Core.AlreadySet.selector);
        core.execute(Core.Action.SetExitModule, abi.encode(address(other)));
        vm.stopPrank();
    }

    function test_timelock_exitModuleValidation() public {
        MockExitModule coinModule = new MockExitModule(address(coin), 1e10);
        MockExitModule ghost = new MockExitModule(address(0x5678), 1e10);
        address[7] memory badTokens = [
            Mainnet.SKIM_HOOK,
            Mainnet.POOL_MANAGER,
            Mainnet.ARTCOINS_FACTORY,
            Mainnet.LP_LOCKER,
            Mainnet.FEE_ESCROW,
            address(CREDITS),
            address(STATEMENTS)
        ];
        address[] memory bad = new address[](3 + badTokens.length);
        bad[0] = address(0x1234); // no code
        bad[1] = address(coinModule); // the exit token is the coin
        bad[2] = address(ghost); // the exit token has no code
        for (uint256 i; i < badTokens.length; ++i) {
            bad[3 + i] = address(new MockExitModule(badTokens[i], 1e10));
        }
        vm.startPrank(owner);
        for (uint256 i; i < bad.length; ++i) {
            core.queue(Core.Action.SetExitModule, abi.encode(bad[i]));
        }
        _warp(7 days);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(Core.BadModule.selector);
            core.execute(Core.Action.SetExitModule, abi.encode(bad[i]));
        }
        vm.stopPrank();
        assertEq(core.exitModule(), address(0));
    }

    /// a module whose unit is zero, above uint128, or unreadable is refused when it is set
    function test_timelock_exitModuleRefusesBadUnits() public {
        uint256[4] memory units = [uint256(0), uint256(type(uint128).max) + 1, type(uint256).max, 1e10];
        for (uint256 i; i < units.length; ++i) {
            MockExitModule m = new MockExitModule(address(new MockExitToken("X", "X")), units[i]);
            if (i == 3) m.setRevertUnit(true);
            vm.startPrank(owner);
            core.queue(Core.Action.SetExitModule, abi.encode(address(m)));
            _warp(7 days);
            vm.expectRevert(Core.BadModule.selector);
            core.execute(Core.Action.SetExitModule, abi.encode(address(m)));
            vm.stopPrank();
            assertEq(core.exitModule(), address(0));
        }
    }

    function test_timelock_targets() public {
        address[10] memory forbidden = [
            address(CREDITS),
            address(STATEMENTS),
            address(core),
            address(coin),
            Mainnet.SKIM_HOOK,
            Mainnet.POOL_MANAGER,
            Mainnet.ARTCOINS_FACTORY,
            Mainnet.LP_LOCKER,
            Mainnet.FEE_ESCROW,
            address(0)
        ];
        vm.startPrank(owner);
        for (uint256 i; i < 10; ++i) {
            core.queue(Core.Action.AddTarget, abi.encode(forbidden[i]));
        }
        _warp(7 days);
        for (uint256 i; i < 10; ++i) {
            vm.expectRevert(Core.ForbiddenTarget.selector);
            core.execute(Core.Action.AddTarget, abi.encode(forbidden[i]));
        }
        vm.stopPrank();

        // the exit module and the exit token are forbidden once they exist.
        _enterPhase2();
        vm.startPrank(owner);
        core.queue(Core.Action.AddTarget, abi.encode(address(mod)));
        core.queue(Core.Action.AddTarget, abi.encode(address(xt)));
        _warp(7 days);
        vm.expectRevert(Core.ForbiddenTarget.selector);
        core.execute(Core.Action.AddTarget, abi.encode(address(mod)));
        vm.expectRevert(Core.ForbiddenTarget.selector);
        core.execute(Core.Action.AddTarget, abi.encode(address(xt)));
        vm.stopPrank();
    }

    function test_timelock_removeTargetIsImmediate() public {
        assertTrue(core.allowedTarget(STRATEGY));
        vm.prank(owner);
        core.removeTarget(STRATEGY);
        assertFalse(core.allowedTarget(STRATEGY));
        _fund(10 ether);
        vm.prank(keeper);
        vm.expectRevert(Core.TargetNotAllowed.selector);
        core.buyListing(1, "", LISTED_A, STRATEGY);

        // a target that later becomes the exit module can no longer be called.
        xt = new MockExitToken("X", "X");
        mod = new MockExitModule(address(xt), UNIT);
        _allow(address(mod));
        assertTrue(core.allowedTarget(address(mod)));
        _timelock(Core.Action.SetExitModule, abi.encode(address(mod)));
        vm.prank(keeper);
        vm.expectRevert(Core.TargetNotAllowed.selector);
        core.buyListing(1, "", LISTED_A, address(mod));
    }

    /*//////////////////////////////////////////////////////////////
                                  views
    //////////////////////////////////////////////////////////////*/

    function test_views_pilesAndScores() public {
        _fund(10 ether);
        uint256[] memory a = _credits(alice, 3);
        uint256[] memory b = _credits(alice, 2);
        vm.startPrank(alice);
        core.sellForEth(a);
        _warp(10);
        core.sellForEth(b);
        vm.stopPrank();

        assertEq(core.pileSize(Lane.Eth), 5);
        assertEq(core.pileSize(Lane.Exit), 0);
        assertEq(core.pileHead(Lane.Eth), a[0]);
        assertEq(core.pileHead(Lane.Exit), 0);
        assertEq(core.pileNext(a[0]), a[1]);
        assertEq(core.pileNext(a[2]), b[0]);
        assertEq(core.pileNext(b[1]), 0);

        uint256[] memory all = core.pilePage(Lane.Eth, 0, 10);
        assertEq(all.length, 5);
        assertEq(all[0], a[0]);
        assertEq(all[4], b[1]);
        uint256[] memory page = core.pilePage(Lane.Eth, a[1], 2);
        assertEq(page.length, 2);
        assertEq(page[0], a[2]);
        assertEq(page[1], b[0]);
        assertEq(core.pilePage(Lane.Eth, b[1], 2).length, 0);
        assertEq(core.pilePage(Lane.Eth, 0, 0).length, 0);

        (bool inPile, Lane lane, uint256 cost, uint64 at) = core.creditInfo(b[0]);
        assertTrue(inPile);
        assertEq(uint8(lane), 0);
        assertGt(cost, 0);
        assertEq(at, block.timestamp);
        (inPile,,, at) = core.creditInfo(12345678);
        assertFalse(inPile);
        assertEq(at, 0);

        uint256 direct = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(a[0]), CREDITS.timestampOf(a[0]));
        assertEq(core.scoreOf(a[0]), direct);
        assertGe(direct, 800_000);
        assertLe(direct, 8_000_000);

        assertEq(core.heldStatements().length, 0);
        (bool held,,,) = core.statementInfo(1);
        assertFalse(held);
    }

    /*//////////////////////////////////////////////////////////////
                               compose guards
    //////////////////////////////////////////////////////////////*/

    function test_compose_notReady() public {
        vm.expectRevert(Core.NotReady.selector);
        core.compose();
        vm.expectRevert(Core.NotReady.selector);
        core.composeExit();

        uint256[] memory ids = _sellN(alice, 79);
        assertEq(ids.length, 79);
        vm.expectRevert(Core.NotReady.selector);
        core.compose();
    }

    function test_compose_controllerCannotNameBadPages() public {
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));
        uint256[] memory ids = _sellN(alice, 2);

        // an id that is in no pile
        scripted.setPage(Lane.Eth, true, _page(ids[0], 777_777), 0);
        vm.expectRevert(abi.encodeWithSelector(Core.NotInPile.selector, 777_777));
        core.compose();

        // a duplicate: the second occurrence is no longer in the pile
        scripted.setPage(Lane.Eth, true, _page(ids[0], ids[0]), 0);
        vm.expectRevert(abi.encodeWithSelector(Core.NotInPile.selector, ids[0]));
        core.compose();

        // a credit of the other lane
        scripted.setPage(Lane.Exit, true, _page(ids[0], ids[1]), 0);
        vm.expectRevert(abi.encodeWithSelector(Core.NotInPile.selector, ids[0]));
        core.composeExit();

        // id zero is the null sentinel and is never in a pile
        scripted.setPage(Lane.Eth, true, _page(0, 0), 0);
        vm.expectRevert(abi.encodeWithSelector(Core.NotInPile.selector, 0));
        core.compose();

        // bad format
        scripted.setPage(Lane.Eth, true, _page(ids[0], ids[1]), 8);
        vm.expectRevert(Core.BadFormat.selector);
        core.compose();

        // not ready and a reverting controller
        scripted.setPage(Lane.Eth, false, _page(ids[0], ids[1]), 0);
        vm.expectRevert(Core.NotReady.selector);
        core.compose();
        scripted.setRevertPage(true);
        vm.expectRevert(Core.NotReady.selector);
        core.compose();

        // a reverting controller blocks nothing else
        uint256[] memory more = _credits(alice, 1);
        vm.prank(alice);
        core.sellForEth(more);
        assertEq(core.pileSize(Lane.Eth), 3);
    }

    /// the one compose of this suite with a scripted page: credits from the middle of the pile, in a different
    /// order than the pile, in format 7. the list stays intact around them
    function test_compose_pullsFromTheMiddleAndKeepsTheListIntact() public {
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));
        uint256[] memory ids = _sellN(alice, 85);
        assertEq(core.pileSize(Lane.Eth), 85);

        // leave the first, a few middle ones and the last in the pile.
        uint256[5] memory left = [uint256(0), 17, 40, 63, 84];
        uint256[80] memory page;
        uint256 n;
        for (uint256 i; i < 85; ++i) {
            bool stays;
            for (uint256 j; j < 5; ++j) {
                if (left[j] == i) stays = true;
            }
            if (!stays) page[n++] = ids[i];
        }
        assertEq(n, 80);
        (page[0], page[79]) = (page[79], page[0]);
        scripted.setPage(Lane.Eth, true, page, 7);
        uint256 supply = STATEMENTS.supply();
        vm.expectCall(address(STATEMENTS), abi.encodeWithSelector(STATEMENTS.compose.selector, page, uint8(7)));
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.supply(), supply + 1);

        assertEq(core.pileSize(Lane.Eth), 5);
        assertEq(core.pileHead(Lane.Eth), ids[0]);
        uint256[] memory rest = core.pilePage(Lane.Eth, 0, 10);
        assertEq(rest.length, 5);
        for (uint256 j; j < 5; ++j) {
            assertEq(rest[j], ids[left[j]]);
        }
        assertEq(core.pileNext(ids[84]), 0);

        // a new arrival lands behind the old tail.
        uint256[] memory more = _credits(alice, 1);
        vm.prank(alice);
        core.sellForEth(more);
        assertEq(core.pileNext(ids[84]), more[0]);
        assertEq(core.pileSize(Lane.Eth), 6);
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                         doors that need no module
    //////////////////////////////////////////////////////////////*/

    function test_buyStatement_unknownStatement() public {
        vm.expectRevert(Core.NotForSale.selector);
        core.priceOf(1);
        vm.expectRevert(Core.NotForSale.selector);
        core.buyStatement(1);
        vm.expectRevert(Core.NoExitModule.selector);
        core.exitStatement(1);
    }

    function test_exitDoorsClosedWithoutModule() public {
        vm.prank(alice);
        vm.expectRevert(Core.NoExitModule.selector);
        core.sellForExitToken(_one(1));
        vm.prank(alice);
        vm.expectRevert(Core.NoExitModule.selector);
        core.sellForExitToken(_one(1), 0);
        vm.expectRevert(Core.NoExitModule.selector);
        core.buybackExit(type(uint256).max);
        vm.expectRevert(Core.NotReady.selector);
        core.composeExit();
        core.skim();
        assertEq(core.exitAuctionPrice(), 0);
    }

    function test_overprint_notReadyWithV1() public {
        vm.expectRevert(Core.NotReady.selector);
        core.overprint();
    }

    function test_buyback_guards() public {
        vm.expectRevert(Core.NothingToBuy.selector);
        core.buyback();
        // eth held without being booked into the buyback pot is not for sale to the buyback
        vm.deal(address(core), 1 ether);
        vm.expectRevert(Core.NothingToBuy.selector);
        core.buyback();
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(Core.OnlyPoolManager.selector);
        core.unlockCallback("");
    }

    function test_onERC721Received_senders() public {
        vm.expectRevert(Core.BadSender.selector);
        core.onERC721Received(address(0), address(0), 1, "");
        vm.prank(address(STATEMENTS));
        assertEq(core.onERC721Received(address(0), address(0), 1, ""), core.onERC721Received.selector);
        vm.prank(address(CREDITS));
        assertEq(core.onERC721Received(address(0), address(0), 1, ""), core.onERC721Received.selector);
    }

    /*//////////////////////////////////////////////////////////////
                         rate properties under fuzz
    //////////////////////////////////////////////////////////////*/

    /// invariant 6: the rate never rises in an interval where the pot was unfunded, and it never climbs
    /// past what the pot affords.
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_rateProperties(uint256[6] memory amounts, uint256[6] memory waits, bool[6] memory sells) public {
        uint256[] memory ids = _credits(alice, 6);
        for (uint256 i; i < 6; ++i) {
            uint256 r0 = core.ethRate();
            bool f0 = core.funded();
            _warp(bound(waits[i], 0, 120 hours));
            uint256 r1 = core.ethRate();
            if (!f0) assertEq(r1, r0, "unfunded rate is frozen");
            else assertGe(r1, r0);
            assertLe(r1, r0.max(core.ethPot() * 1e4 / 4_330_000), "never above the funded threshold");

            uint256 amount = bound(amounts[i], 0, 0.05 ether);
            if (amount != 0) _fund(amount);
            if (sells[i]) {
                vm.prank(alice);
                try core.sellForEth(_one(ids[i])) {} catch {}
            }
            _solvent();
        }
    }
}

/// everything that follows a real compose. the stand in exit module is set in `setUp`, the compose itself goes through
/// the real controller and the real Statements contract, once per test
contract CoreComposedTest is CoreBase {
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    function setUp() public virtual override {
        super.setUp();
        _enterPhase2();
    }

    function _held() internal view returns (uint256[] memory) {
        return core.heldStatements();
    }

    /// @dev composes a second statement on top of the state of `_composeOnce`, through whichever controller is set
    function _composeNext() internal returns (uint256 sid) {
        sid = STATEMENTS.supply() + 1;
        _fillEthPile(80);
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.supply(), sid);
    }

    /*//////////////////////////////////////////////////////////////
                                 compose
    //////////////////////////////////////////////////////////////*/

    function test_compose_statementIdCostBasisAndPiles() public {
        Composed memory c = _composeOnce();
        uint256[] memory ids = new uint256[](80);
        for (uint256 i; i < 80; ++i) {
            ids[i] = c.ids[i];
        }
        assertEq(c.sid, c.supplyBefore + 1);
        assertEq(STATEMENTS.supply(), c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core));
        assertEq(STATEMENTS.creditsOf(c.sid), 80);
        assertEq(STATEMENTS.creditScoreOf(c.sid), _sumScores(ids));

        (bool held, Lane lane, uint256 cost, uint64 clockStart) = core.statementInfo(c.sid);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(cost, c.cost + c.reimb, "cost basis is the credits plus the gas refund");
        assertEq(clockStart, c.at);

        assertEq(core.pileSize(Lane.Eth), 0);
        assertEq(core.pileHead(Lane.Eth), 0);
        for (uint256 i; i < 80; ++i) {
            (bool inPile,,,) = core.creditInfo(ids[i]);
            assertFalse(inPile);
        }
        assertEq(CREDITS.balanceOf(address(core)), 0, "the credits were burned into the statement");
        uint256[] memory h = _held();
        assertEq(h.length, 1);
        assertEq(h[0], c.sid);
        assertEq(core.ethPot(), c.potBefore - c.reimb);
        _solvent();
    }

    /// the reimbursement tracks the gas of the call at 1.1 times the basefee, plus the fixed overhead. the part of
    /// the call after the reimbursement is computed (the statement books and the events) is not repaid
    function test_compose_gasReimbursementTracksGas() public {
        Composed memory c = _composeOnce();
        assertGt(c.reimb, 0);
        assertLt(c.reimb, c.cost * 500 / 10_000, "far below the 5 percent cap at this basefee");
        assertLe(c.reimb, (c.gasUsed + 50_000) * composeBasefee * 11_000 / 10_000);
        assertGe(c.reimb, (c.gasUsed - 250_000) * composeBasefee * 11_000 / 10_000);
        assertEq(keeper.balance, c.reimb, "the caller was repaid and nobody else");
    }

    /// the same compose under other basefees and pot sizes, from the state kept right before the first compose
    function test_compose_gasReimbursementCapAndPotLimit() public {
        Composed memory c = _composeOnce();
        uint256 snap = preComposeSnap;
        uint256 pot = c.potBefore;
        uint256 supply = c.supplyBefore;

        // a huge basefee: the refund is capped at 5 percent of the credits' cost, exactly
        vm.revertToState(snap);
        vm.fee(2 gwei);
        vm.prank(keeper);
        core.compose();
        assertEq(keeper.balance, c.cost * 500 / 10_000, "2 gwei is far above the cap so the cap binds exactly");
        (,, uint256 cost,) = core.statementInfo(supply + 1);
        assertEq(cost, c.cost + c.cost * 500 / 10_000);
        assertEq(core.ethPot(), pot - c.cost * 500 / 10_000);

        // no basefee, no refund, and the cost basis is only the credits
        vm.revertToState(snap);
        vm.fee(0);
        vm.prank(keeper);
        core.compose();
        assertEq(keeper.balance, 0);
        (,, cost,) = core.statementInfo(supply + 1);
        assertEq(cost, c.cost);
        assertEq(core.ethPot(), pot);

        // the refund never exceeds the pot either. the pot slot is forced to 7 wei, the balance still covers it
        vm.revertToState(snap);
        stdstore.target(address(core)).sig("ethPot()").checked_write(uint256(7));
        vm.fee(1000 gwei);
        vm.prank(keeper);
        core.compose();
        assertEq(keeper.balance, 7, "limited by the pot");
        assertEq(core.ethPot(), 0);
    }

    /// skim never books the buyback pot: only what the core holds above both pots
    function test_skim_neverBooksBuybackPot() public {
        Composed memory c = _composeOnce();
        uint256 price = core.priceOf(c.sid);
        vm.deal(alice, price);
        vm.prank(alice);
        core.buyStatement{value: price}(c.sid);
        uint256 bb = core.ethToBuyback();
        uint256 pot = core.ethPot();
        assertEq(bb, price * 5000 / 10_000);
        core.skim();
        assertEq(core.ethPot(), pot, "nothing above the pots");
        assertEq(core.ethToBuyback(), bb);
        _fund(1 ether);
        assertEq(core.ethPot(), pot + 1 ether);
        assertEq(core.ethToBuyback(), bb, "the donation went to the pot, not the buyback");
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                                 auction
    //////////////////////////////////////////////////////////////*/

    function _expectedPrice(uint256 cost, uint256 elapsed) internal pure returns (uint256) {
        uint256 len = 72 hours;
        return cost.mulDivUp(40_000 * len - 28_000 * elapsed.min(len), len * 10_000);
    }

    function test_auction_priceCurve() public {
        Composed memory c = _composeOnce();
        (,, uint256 cost,) = core.statementInfo(c.sid);
        assertEq(core.priceOf(c.sid), cost * 4, "opens at 4x");
        _warp(18 hours);
        assertEq(core.priceOf(c.sid), cost.mulDivUp(33_000, 10_000), "3.3x a quarter of the way down");
        _warp(18 hours);
        assertEq(core.priceOf(c.sid), cost.mulDivUp(26_000, 10_000), "2.6x half way");
        _warp(36 hours);
        assertEq(core.priceOf(c.sid), cost.mulDivUp(12_000, 10_000), "1.2x at the end");
        assertGe(core.priceOf(c.sid) * 10, cost * 12);
        _warp(5000 hours);
        assertEq(core.priceOf(c.sid), cost.mulDivUp(12_000, 10_000), "flat at the floor");
    }

    /// invariant 3: no statement is priced below 1.2 times its cost or above 4 times.
    /// forge-config: default.fuzz.runs = 16
    function testFuzz_auction_priceBounds(uint256 dt) public {
        Composed memory c = _composeOnce();
        (,, uint256 cost,) = core.statementInfo(c.sid);
        dt = bound(dt, 0, 400 hours);
        _warp(dt);
        uint256 p = core.priceOf(c.sid);
        assertEq(p, _expectedPrice(cost, dt));
        assertGe(p * 10, cost * 12);
        assertLe(p, cost * 4);
    }

    function test_buyStatement_splitRefundAndTransfer() public {
        Composed memory c = _composeOnce();
        _warp(20 hours);
        uint256 price = core.priceOf(c.sid);
        address buyer = _user("buyer");
        vm.deal(buyer, price + 1 ether);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();

        vm.prank(buyer);
        vm.expectRevert(Core.Underpaid.selector);
        core.buyStatement{value: price - 1}(c.sid);

        vm.prank(buyer);
        core.buyStatement{value: price + 1 ether}(c.sid);

        assertEq(buyer.balance, 1 ether, "excess came back");
        assertEq(STATEMENTS.ownerOf(c.sid), buyer);
        uint256 half = price * 5000 / 10_000;
        assertEq(core.ethToBuyback(), bb + half);
        assertEq(core.ethPot(), pot + price - half);
        assertEq(_held().length, 0);
        (bool held,,,) = core.statementInfo(c.sid);
        assertFalse(held);
        _solvent();

        vm.expectRevert(Core.NotForSale.selector);
        core.priceOf(c.sid);
        vm.prank(buyer);
        vm.expectRevert(Core.NotForSale.selector);
        core.buyStatement{value: price}(c.sid);
    }

    function test_buyStatement_exactPaymentAtTheFloorAndOddSplit() public {
        Composed memory c = _composeOnce();
        _warp(100 hours);
        uint256 price = core.priceOf(c.sid);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        vm.deal(alice, price);
        vm.prank(alice);
        core.buyStatement{value: price}(c.sid);
        assertEq(alice.balance, 0);
        // the odd wei stays in the pot.
        assertEq(core.ethToBuyback() - bb, price / 2);
        assertEq(core.ethPot() - pot, price - price / 2);
        _solvent();
    }

    function test_buyStatement_contractBuyerWithoutReceiverReverts() public {
        Composed memory c = _composeOnce();
        DeafBuyer buyer = new DeafBuyer();
        uint256 price = core.priceOf(c.sid);
        vm.deal(address(buyer), price);
        vm.expectRevert();
        buyer.buy(core, c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core));
        assertEq(_held().length, 1);
    }

    function test_reentrancyThroughStatementReceiverReverts() public {
        Composed memory c = _composeOnce();
        ReentrantBuyer buyer = new ReentrantBuyer(core);
        uint256 price = core.priceOf(c.sid);
        vm.deal(address(buyer), price);
        vm.expectRevert();
        buyer.buy(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core));
        assertEq(_held().length, 1);
    }

    /*//////////////////////////////////////////////////////////////
                              exit path
    //////////////////////////////////////////////////////////////*/

    function test_exit_guards() public {
        Composed memory c = _composeOnce();
        vm.expectRevert(Core.NotHeld.selector);
        core.exitStatement(c.sid + 100);
        vm.expectRevert(Core.AuctionRunning.selector);
        core.exitStatement(c.sid);
        _warp(72 hours - 1);
        vm.expectRevert(Core.AuctionRunning.selector);
        core.exitStatement(c.sid);
        _warp(1);
        core.exitStatement(c.sid);
        vm.expectRevert(Core.NotHeld.selector);
        core.exitStatement(c.sid);
    }

    function test_exit_splitsEthLaneStatement() public {
        Composed memory c = _composeOnce();
        _warp(72 hours);
        uint256 out = STATEMENTS.creditScoreOf(c.sid) * UNIT;
        core.exitStatement(c.sid);

        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "the module keeps the statement");
        assertEq(xt.balanceOf(address(core)), out);
        assertEq(core.xToBuyback(), out * 5000 / 10_000);
        assertEq(core.xPot(), out - out * 5000 / 10_000);
        assertEq(_held().length, 0);
        (bool held,,,) = core.statementInfo(c.sid);
        assertFalse(held);
        assertEq(core.xRate(), 6000);
        assertEq(core.xStartTime(), block.timestamp, "the exit auction clock starts when there is something to sell");
        _solvent();
    }

    function test_exit_moduleThatUnderpaysReverts() public {
        Composed memory c = _composeOnce();
        _warp(72 hours);
        mod.setShortfallBps(1);
        vm.expectRevert(Core.Underpaid.selector);
        core.exitStatement(c.sid);
        mod.setShortfallBps(5000);
        vm.expectRevert(Core.Underpaid.selector);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core), "the statement never left");
        assertEq(_held().length, 1);

        mod.setShortfallBps(0);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod));
    }

    /// the unit is fixed when the module is set. a module that pays by a lower unit later is refused by the stored
    /// one, and one that pays more is simply paid
    function test_exit_unitIsFixedAtSetTime() public {
        Composed memory c = _composeOnce();
        assertEq(core.unitPerPoint(), UNIT);
        _warp(72 hours);
        mod.setUnitPerPoint(0);
        vm.expectRevert(Core.Underpaid.selector);
        core.exitStatement(c.sid);

        mod.setUnitPerPoint(3e10);
        uint256 out = STATEMENTS.creditScoreOf(c.sid) * 3e10;
        core.exitStatement(c.sid);
        assertEq(xt.balanceOf(address(core)), out);
        assertEq(core.unitPerPoint(), UNIT, "the stored unit did not follow the module");
    }

    function test_exit_statementStaysBuyableAtFloorUntilExited() public {
        Composed memory c = _composeOnce();
        _warp(200 hours);
        uint256 price = core.priceOf(c.sid);
        vm.deal(alice, price);
        vm.prank(alice);
        core.buyStatement{value: price}(c.sid);
        vm.expectRevert(Core.NotHeld.selector);
        core.exitStatement(c.sid);
    }

    /*//////////////////////////////////////////////////////////////
                              exit token bid
    //////////////////////////////////////////////////////////////*/

    /// whatever the module reports later changes nothing. fee intake, the rate, the bid and the buyback slice all use
    /// the stored unit
    function test_exit_laterModuleUnitsChangeNothing() public {
        _fillExitBuyback();
        uint256 pot = core.xPot();
        _warp(1 hours);
        assertEq(core.xRate(), 6100);

        for (uint256 round; round < 2; ++round) {
            if (round == 0) {
                mod.setRevertUnit(true);
            } else {
                mod.setRevertUnit(false);
                mod.setUnitPerPoint(type(uint256).max);
            }
            xt.mint(address(core), 1e18);
            core.skim();
            xt.mint(address(core), 1e18);
            core.skim();
            assertEq(core.xRate(), 6100, "the rate follows the stored unit");
            _solvent();
        }
        assertEq(core.xPot(), pot + 4e18);

        uint256[] memory ids = _credits(alice, 1);
        uint256 price = core.scoreOf(ids[0]) * core.xRate() * UNIT / 10_000;
        vm.prank(alice);
        core.sellForExitToken(ids);
        assertEq(xt.balanceOf(alice), price, "paid at the stored unit");
        _solvent();
    }

    function test_xBid_rateClimbsAndDropsPerCredit() public {
        _fillExitBuyback();
        uint256 pot = core.xPot();
        _warp(10 hours);
        assertEq(core.xRate(), 7000, "one point (100 bps) an hour while funded");

        uint256[] memory ids = _credits(alice, 3);
        uint256 r = 7000;
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            total += core.scoreOf(ids[i]) * r * UNIT / 10_000;
            r -= 20;
        }
        vm.prank(alice);
        vm.expectRevert(Core.Slippage.selector);
        core.sellForExitToken(ids, total + 1);

        vm.prank(alice);
        core.sellForExitToken(ids, total);
        assertEq(xt.balanceOf(alice), total);
        assertEq(core.xPot(), pot - total);
        assertEq(core.xRate(), 6940, "0.2 point (20 bps) per credit");
        assertEq(core.pileSize(Lane.Exit), 3);
        assertEq(core.pileSize(Lane.Eth), 0);
        (bool inPile, Lane lane, uint256 cost,) = core.creditInfo(ids[2]);
        assertTrue(inPile);
        assertEq(uint8(lane), uint8(Lane.Exit));
        assertEq(cost, core.scoreOf(ids[2]) * 6960 * UNIT / 10_000, "cost basis in exit token");
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
        _solvent();

        _warp(5 hours);
        assertEq(core.xRate(), 7440);
    }

    /// the pot slot is forced to sizes that real fees cannot hit exactly, the balance of exit token covers it
    function test_xBid_capAndAffordabilityClamp() public {
        _fillExitBuyback();
        _warp(100 hours);
        assertEq(core.xRate(), 9700, "never above the cap");

        // a pot that only affords 70 percent of score stops the climb there.
        uint256 pot = 7000 * 4_330_000 * UNIT / 10_000;
        stdstore.target(address(core)).sig("xPot()").checked_write(pot);
        assertEq(core.xRate(), 7000);

        // below one average credit at the current rate the climb stops and the rate holds.
        stdstore.target(address(core)).sig("xPot()").checked_write(pot / 10);
        assertEq(core.xRate(), 6000);
    }

    function test_xBid_floor() public {
        _fillExitBuyback();
        xt.mint(address(core), 1_000_000e18);
        core.skim();
        for (uint256 b; b < 2; ++b) {
            uint256[] memory ids = _credits(alice, 80);
            vm.prank(alice);
            core.sellForExitToken(ids);
        }
        assertEq(core.xRate(), 3000, "160 credits at 0.2 point each hit the floor and stop");
        _solvent();
    }

    function test_xBid_guards() public {
        _fillExitBuyback();
        uint256[] memory ids = _credits(alice, 1);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(Core.Empty.selector);
        core.sellForExitToken(none);
        vm.prank(alice);
        vm.expectRevert(Core.ZeroId.selector);
        core.sellForExitToken(_one(0));
        vm.prank(keeper);
        vm.expectRevert(Core.NotOwner.selector);
        core.sellForExitToken(ids);

        stdstore.target(address(core)).sig("xPot()").checked_write(uint256(1));
        vm.prank(alice);
        vm.expectRevert(Core.PotTooSmall.selector);
        core.sellForExitToken(ids);
    }

    /// exit token that arrives outside an exit is booked only by `skim`, and never into the buyback pot
    function test_xFees_skimBooksPlainTransfers() public {
        _fillExitBuyback();
        uint256 pot = core.xPot();
        uint256 bb = core.xToBuyback();
        core.skim();
        assertEq(core.xPot(), pot, "nothing above the pots");
        xt.mint(address(core), 3e18);
        assertEq(core.xPot(), pot);
        core.skim();
        assertEq(core.xPot(), pot + 3e18);
        assertEq(core.xToBuyback(), bb);
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                         exit lane compose and exit
    //////////////////////////////////////////////////////////////*/

    function test_exitLane_composeThenImmediateExit() public {
        _fillExitBuyback();
        xt.mint(address(core), 100e18);
        core.skim();

        uint256[] memory ids = _credits(alice, 80);
        vm.prank(alice);
        core.sellForExitToken(ids);
        assertEq(core.pileSize(Lane.Exit), 80);
        uint256 sumExit;
        for (uint256 i; i < 80; ++i) {
            (,, uint256 paidIn,) = core.creditInfo(ids[i]);
            sumExit += paidIn;
        }

        uint256 potBefore = core.ethPot();
        uint256 balBefore = keeper.balance;
        uint256 sidX = STATEMENTS.supply() + 1;
        vm.prank(keeper);
        core.composeExit();
        uint256 paid = keeper.balance - balBefore;

        assertEq(STATEMENTS.ownerOf(sidX), address(core));
        (bool held, Lane lane, uint256 cost,) = core.statementInfo(sidX);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Exit));
        assertEq(cost, sumExit, "exit token cost basis, no refund added");
        assertEq(core.pileSize(Lane.Exit), 0);
        assertEq(core.ethPot(), potBefore - paid);
        assertLe(paid, 80 * 4_330_000 * core.ethRate() / 1e4 * 500 / 10_000, "notional cap");
        assertGt(paid, 0);

        vm.expectRevert(Core.NotForSale.selector);
        core.priceOf(sidX);
        vm.expectRevert(Core.NotForSale.selector);
        core.buyStatement(sidX);

        // no auction in the exit lane, so it exits at once and everything returns to the bid pot, none of it to the
        // buyback, which also keeps its auction clock
        uint256 xPotBefore = core.xPot();
        uint256 xbbBefore = core.xToBuyback();
        uint64 startTime = core.xStartTime();
        uint256 out = STATEMENTS.creditScoreOf(sidX) * UNIT;
        core.exitStatement(sidX);
        assertEq(core.xPot(), xPotBefore + out);
        assertEq(core.xToBuyback(), xbbBefore);
        assertEq(core.xStartTime(), startTime);
        assertEq(STATEMENTS.ownerOf(sidX), address(mod));
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                                overprint
    //////////////////////////////////////////////////////////////*/

    function test_overprint_mergesAndRestartsClock() public {
        Composed memory c = _composeOnce();
        uint256 sid2 = _composeNext();
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));
        _warp(10 hours);
        scripted.setOverprint(true, c.sid, sid2);

        (,, uint256 c1,) = core.statementInfo(c.sid);
        (,, uint256 c2,) = core.statementInfo(sid2);
        uint256 r1 = STATEMENTS.creditScoreOf(c.sid);
        uint256 r2 = STATEMENTS.creditScoreOf(sid2);

        core.overprint();

        (bool held, Lane lane, uint256 cost, uint64 clockStart) = core.statementInfo(c.sid);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(cost, c1 + c2, "cost bases are summed");
        assertEq(clockStart, block.timestamp, "the auction restarts");
        assertEq(STATEMENTS.creditScoreOf(c.sid), r1 + r2);
        assertEq(STATEMENTS.overprintsOf(c.sid), 1);
        (bool held2,,,) = core.statementInfo(sid2);
        assertFalse(held2);
        uint256[] memory h = _held();
        assertEq(h.length, 1);
        assertEq(h[0], c.sid);
        assertEq(core.priceOf(c.sid), (c1 + c2) * 4);
        assertEq(core.overprintCount(), 1);

        // the top is gone from circulation.
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();
    }

    function test_overprint_guards() public {
        Composed memory c = _composeOnce();
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));

        vm.expectRevert(Core.NotReady.selector);
        core.overprint();

        scripted.setOverprint(true, c.sid, c.sid);
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();

        scripted.setOverprint(true, c.sid, c.sid + 50);
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();

        scripted.setOverprint(true, c.sid + 50, c.sid);
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();

        // a statement of the exit lane cannot be merged into an eth lane one.
        xt.mint(address(core), 100e18);
        core.skim();
        uint256 sidX = STATEMENTS.supply() + 1;
        uint256[] memory ids = _credits(alice, 80);
        vm.prank(alice);
        core.sellForExitToken(ids);
        uint256[80] memory page;
        for (uint256 i; i < 80; ++i) {
            page[i] = ids[i];
        }
        scripted.setPage(Lane.Exit, true, page, 0);
        vm.prank(keeper);
        core.composeExit();
        scripted.setOverprint(true, c.sid, sidX);
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();

        scripted.setRevertPage(true);
        scripted.setOverprint(false, c.sid, sidX);
        vm.expectRevert(Core.NotReady.selector);
        core.overprint();
    }

    /// the cap is 8 a day and resets with the utc day. eight real overprints need nine composes, so the counter slot
    /// is forced to the cap after one real overprint
    function test_overprint_dailyCap() public {
        Composed memory c = _composeOnce();
        uint256 sid2 = _composeNext();
        uint256 sid3 = _composeNext();
        ScriptedController scripted = new ScriptedController();
        _setController(address(scripted));

        scripted.setOverprint(true, c.sid, sid2);
        core.overprint();
        assertEq(core.overprintCount(), 1);

        stdstore.target(address(core)).sig("overprintCount()").checked_write(uint256(8));
        scripted.setOverprint(true, c.sid, sid3);
        vm.expectRevert(Core.DailyCap.selector);
        core.overprint();

        // the budget resets with the next utc day.
        _warp(1 days);
        core.overprint();
        assertEq(core.overprintCount(), 1);
        assertEq(STATEMENTS.overprintsOf(c.sid), 2);
        _solvent();
    }
}
