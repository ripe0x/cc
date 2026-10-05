// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Core} from "../src/Core.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {Lane, ICredits, ICreditScore, ICreditStrategy, IStatements, Mainnet} from "../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockExitToken} from "./mocks/MockExitToken.sol";
import {MockExitModule} from "./mocks/MockExitModule.sol";
import {HostileTarget} from "./mocks/HostileTarget.sol";
import {MockController} from "./mocks/MockController.sol";
import {MockSeller} from "./mocks/MockSeller.sol";
import {MockHook} from "./mocks/MockHook.sol";
import {CreditIds} from "./utils/CreditIds.sol";

/// shared fixture. a real mainnet fork for Credits, CreditScore and Statements, a core deployed directly
/// with a plain erc20 as the coin and a test address as the hook.
abstract contract CoreBase is Test {
    using stdStorage for StdStorage;

    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;
    uint256 internal constant LISTED_A = 35377;
    uint256 internal constant LISTED_B = 28352;

    Core internal core;
    ControllerV1 internal ctl;
    MockExitToken internal coin;
    address internal hook;
    address internal owner;
    address internal alice;
    address internal keeper;
    uint256 internal cursor;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        // labels are namespaced because common labels are delegated accounts on mainnet and sweep eth.
        hook = _makeHook();
        owner = makeAddr("creditsengine.owner");
        alice = makeAddr("creditsengine.alice");
        keeper = makeAddr("creditsengine.keeper");
        assertEq(owner.code.length + alice.code.length + keeper.code.length, 0);
        coin = new MockExitToken("COIN", "COIN");
        (core, ctl) = _deploy(hook);
    }

    function _makeHook() internal virtual returns (address) {
        return makeAddr("creditsengine.hook");
    }

    function _deploy(address hook_) internal returns (Core c, ControllerV1 k) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        k = new ControllerV1(predicted);
        c = new Core(owner, address(coin), hook_, address(k));
        assertEq(address(c), predicted);
    }

    function _fund(uint256 amount) internal {
        vm.deal(hook, hook.balance + amount);
        vm.prank(hook);
        core.addFees{value: amount}();
    }

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }

    /// hands n credits from the strategy to `to` and approves the core. skips the three listed ids.
    function _creditsTo(address to, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        uint256 got;
        while (got < n) {
            uint256 id = CreditIds.at(cursor++);
            if (id == LISTED_A || id == LISTED_B || id == 18683) continue;
            vm.prank(STRATEGY);
            CREDITS.transferFrom(STRATEGY, to, id);
            ids[got++] = id;
        }
        vm.prank(to);
        CREDITS.setApprovalForAll(address(core), true);
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _timelock(Core.Action action, bytes memory data) internal {
        vm.startPrank(owner);
        core.queue(action, data);
        _warp(7 days);
        core.execute(action, data);
        vm.stopPrank();
    }

    function _setController(address c) internal {
        _timelock(Core.Action.SetController, abi.encode(c));
    }

    function _setModule(uint256 unit) internal returns (MockExitToken xt, MockExitModule mod) {
        xt = new MockExitToken("EXIT", "EXIT");
        mod = new MockExitModule(address(xt), unit);
        _timelock(Core.Action.SetExitModule, abi.encode(address(mod)));
    }

    function _allow(address target) internal {
        _timelock(Core.Action.AddTarget, abi.encode(target));
    }

    function _dropped(uint256 r, uint256 x, uint256 p) internal pure returns (uint256) {
        return r - r * 1000 * x / (10_000 * p);
    }

    function _solvent() internal view {
        assertLe(core.ethPot() + core.ethToBuyback(), address(core).balance, "eth pots exceed balance");
        address t = core.exitToken();
        if (t != address(0)) {
            assertLe(core.xPot() + core.xToBuyback(), MockExitToken(t).balanceOf(address(core)), "exit pots exceed");
        }
    }

    function _selector(bytes memory data) internal pure returns (bytes4 s) {
        assembly {
            s := mload(add(data, 32))
        }
    }
}

contract CoreUnitTest is CoreBase {
    using stdStorage for StdStorage;
    using FixedPointMathLib for uint256;

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
        assertEq(core.TIMELOCK(), 7 days);
        assertEq(core.OVERPRINT_CAP_PER_DAY(), 8);
    }

    function test_constructorState() public view {
        assertEq(core.OWNER(), owner);
        assertEq(core.COIN(), address(coin));
        assertEq(core.HOOK(), hook);
        assertEq(core.controller(), address(ctl));
        assertTrue(core.allowedTarget(Mainnet.SEAPORT));
        assertTrue(core.allowedTarget(Mainnet.CREDIT_STRATEGY));
        assertTrue(CREDITS.isApprovedForAll(address(core), address(STATEMENTS)));
        assertEq(core.ethRate(), 4e12);
        assertEq(core.lastFillTime(), block.timestamp);
        assertFalse(core.funded());
        assertEq(core.exitToken(), address(0));
        assertEq(core.exitPoolId(), bytes32(0));
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(Core.ZeroAddress.selector);
        new Core(address(0), address(coin), hook, address(ctl));
        vm.expectRevert(Core.ZeroAddress.selector);
        new Core(owner, address(0), hook, address(ctl));
        vm.expectRevert(Core.ZeroAddress.selector);
        new Core(owner, address(coin), address(0), address(ctl));
        vm.expectRevert(Core.ZeroAddress.selector);
        new Core(owner, address(coin), hook, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                           fee intake and skim
    //////////////////////////////////////////////////////////////*/

    function test_addFees_hookOnly() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Core.OnlyHook.selector);
        core.addFees{value: 1 ether}();

        vm.expectRevert(Core.OnlyHook.selector);
        core.addExitFees(1);

        _fund(1 ether);
        assertEq(core.ethPot(), 1 ether);
        _solvent();
    }

    function test_receiveBooksNothing_skimBooksExcess() public {
        _fund(1 ether);
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        (bool ok,) = address(core).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(core.ethPot(), 1 ether);
        assertEq(address(core).balance, 3 ether);

        core.skim();
        assertEq(core.ethPot(), 3 ether);
        core.skim();
        assertEq(core.ethPot(), 3 ether);
        _solvent();
    }

    function test_skim_neverBooksBuybackPot() public {
        _fund(1 ether);
        stdstore.target(address(core)).sig("ethToBuyback()").checked_write(uint256(0.5 ether));
        vm.deal(address(core), 1.5 ether);
        core.skim();
        assertEq(core.ethPot(), 1 ether);
        assertEq(core.ethToBuyback(), 0.5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                               rate climb
    //////////////////////////////////////////////////////////////*/

    function test_rate_unfundedNeverClimbs() public {
        assertEq(core.ethRate(), 4e12);
        _warp(1000 hours);
        assertEq(core.ethRate(), 4e12);

        // one avg credit costs 1.732e15 at the start rate. a smaller pot is unfunded.
        _fund(1.7e15);
        assertFalse(core.funded());
        _warp(1000 hours);
        assertEq(core.ethRate(), 4e12);

        _fund(1e16);
        assertTrue(core.funded());
        assertEq(core.ethRate(), 4e12, "no retroactive climb");
        // the wait since deploy is long, so the tier is the fastest one.
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
        assertEq(core.lastFillTime(), block.timestamp - 30 hours);
        _warp(52 hours);
        assertApproxEqRel(core.ethRate(), 45_207_946_718_638, 1e9, "same curve as without the checkpoint");
    }

    function test_rate_fundedClamp() public {
        _fund(0.002 ether);
        assertTrue(core.funded());
        _warp(10 hours);
        assertApproxEqRel(core.ethRate(), 4_418_488_501_644, 1e9);
        _warp(100 hours);
        uint256 pot = 0.002 ether;
        uint256 cap = pot * 1e4 / 4_330_000;
        assertEq(cap, 4_618_937_644_341);
        assertEq(core.ethRate(), cap, "stops at the exact point the pot buys one average credit");
        _warp(10_000 hours);
        assertEq(core.ethRate(), cap);
        // at the clamp the pot still affords exactly one average credit.
        assertGe(core.ethPot() * 1e4, 4_330_000 * core.ethRate());

        // more fees lift the clamp and the climb resumes from the checkpoint.
        _fund(0.002 ether);
        assertEq(core.rateAtCheckpoint(), cap);
        _warp(1 hours);
        assertApproxEqRel(core.ethRate(), cap * 108 / 100, 1e9, "tier 8 percent after a long wait");
    }

    function test_rate_goesUnfundedAfterPotDrops() public {
        _fund(0.002 ether);
        _warp(100 hours);
        uint256 cap = core.ethRate();
        _fund(1);
        assertEq(core.rateAtCheckpoint(), cap);
        // shrink the pot below one average credit and let the next checkpoint see it.
        stdstore.target(address(core)).sig("ethPot()").checked_write(uint256(1e15));
        _fund(1);
        assertEq(core.rateAtCheckpoint(), cap, "no climb applied under the smaller pot");
        assertFalse(core.funded());
        _warp(500 hours);
        assertEq(core.ethRate(), cap, "never rises while unfunded");
    }

    function test_rate_dropAndClockResetOnFill() public {
        _fund(10 ether);
        _warp(30 hours);
        uint256 id = _creditsTo(alice, 1)[0];
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
        uint256[] memory ids = _creditsTo(alice, 3);
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
        uint256[] memory ids = _creditsTo(alice, 14);
        uint256 pot0 = 0.05 ether;
        uint256 cap = pot0 * 2000 / 10_000;
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
        uint256[] memory ids = _creditsTo(alice, 14);
        vm.prank(alice);
        vm.expectRevert(Core.HourlyCap.selector);
        core.sellForEth(ids);
    }

    /*//////////////////////////////////////////////////////////////
                              sell door
    //////////////////////////////////////////////////////////////*/

    function test_sellForEth_minOut() public {
        _fund(10 ether);
        uint256 id = _creditsTo(alice, 1)[0];
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
        uint256[] memory ids = _creditsTo(alice, 1);
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
        address bob = makeAddr("creditsengine.bob");
        uint256 id = CreditIds.at(500);
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, bob, id);
        vm.prank(bob);
        vm.expectRevert();
        core.sellForEth(_one(id));
    }

    function test_sellForEth_cannotSellACreditTheCoreOwns() public {
        _fund(10 ether);
        uint256 id = _creditsTo(alice, 1)[0];
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
        MockController mock = new MockController();
        _setController(address(mock));
        _fund(10 ether);
        uint256 id = _creditsTo(alice, 1)[0];
        uint256 base = core.scoreOf(id) * core.ethRate() / 1e4;
        assertEq(core.ceilingOf(id), base);

        mock.setWants(id, 1000);
        assertEq(core.ceilingOf(id), base * 11_000 / 10_000);
        mock.setWants(id, 2500);
        assertEq(core.ceilingOf(id), base * 12_500 / 10_000);
        mock.setWants(id, 60_000);
        assertEq(core.ceilingOf(id), base * 12_500 / 10_000, "clamped to the bonus cap");

        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(_one(id));
        assertEq(alice.balance - before, base * 12_500 / 10_000);
    }

    function test_controller_revertingOrOversizedOrGreedyWantsDoesNotBlockDoors() public {
        MockController mock = new MockController();
        _setController(address(mock));
        _fund(10 ether);
        uint256[] memory ids = _creditsTo(alice, 4);
        uint256 base = core.scoreOf(ids[0]) * core.ethRate() / 1e4;

        mock.setRevertWants(true);
        assertEq(core.ceilingOf(ids[0]), base, "revert counts as zero");

        mock.setRevertWants(false);
        mock.setRawWants(true);
        assertEq(core.ceilingOf(ids[0]), base * 12_500 / 10_000, "oversized word clamps");

        mock.setRawWants(false);
        mock.setBurnWants(true);
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

    function _listingBytes(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeCall(ICreditStrategy.sellTargetNFT, (id));
    }

    /// funds the pot and warps hour by hour until the ceiling clears the listing price of id.
    function _warpUntilCeilingClears(uint256 id, uint256 price) internal {
        _fund(10 ether);
        for (uint256 i; i < 300; ++i) {
            if (core.ceilingOf(id) >= price) return;
            _warp(1 hours);
        }
        revert("ceiling never cleared");
    }

    function test_buyListing_aboveCeilingReverts() public {
        _fund(10 ether);
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertGt(price, core.ceilingOf(LISTED_A), "start rate is far below the listing");
        vm.prank(keeper);
        vm.expectRevert(Core.AboveCeiling.selector);
        core.buyListing(price, _listingBytes(LISTED_A), LISTED_A, STRATEGY);
    }

    function test_buyListing_tipIsTenthOfSavingsWhenSmall() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertEq(price, 0.036 ether);
        _warpUntilCeilingClears(LISTED_A, price);

        uint256 ceiling = core.ceilingOf(LISTED_A);
        uint256 rate = core.ethRate();
        uint256 tip = (ceiling - price) * 1000 / 10_000;
        assertLt(tip, price * 200 / 10_000, "savings bound branch");
        assertGt(tip, 0);

        uint256 pot = core.ethPot();
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        core.buyListing(price, _listingBytes(LISTED_A), LISTED_A, STRATEGY);

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
        _warpUntilCeilingClears(LISTED_A, price);
        _warp(30 hours);
        uint256 ceiling = core.ceilingOf(LISTED_A);
        assertGt((ceiling - price) * 1000 / 10_000, price * 200 / 10_000);

        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        core.buyListing(price, _listingBytes(LISTED_A), LISTED_A, STRATEGY);
        assertEq(keeper.balance - keeperBefore, price * 200 / 10_000);
        (,, uint256 cost,) = core.creditInfo(LISTED_A);
        assertEq(cost, price + price * 200 / 10_000);
        _solvent();
    }

    function test_buyListing_failedCallRevertsOnlyThatBuy() public {
        uint256 priceA = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        uint256 priceB = ICreditStrategy(STRATEGY).nftForSale(LISTED_B);
        _warpUntilCeilingClears(LISTED_A, priceA);
        for (uint256 i; i < 300 && core.ceilingOf(LISTED_B) < priceB; ++i) {
            _warp(1 hours);
        }
        uint256 pot = core.ethPot();
        uint256 rate = core.ethRate();

        // wrong value, the strategy reverts.
        vm.prank(keeper);
        vm.expectRevert(Core.CallFailed.selector);
        core.buyListing(priceA - 1, _listingBytes(LISTED_A), LISTED_A, STRATEGY);

        // wrong calldata, the strategy reverts.
        vm.prank(keeper);
        vm.expectRevert(Core.CallFailed.selector);
        core.buyListing(priceA, _listingBytes(LISTED_B), LISTED_A, STRATEGY);

        // asked for one id but the call delivers another.
        vm.prank(keeper);
        vm.expectRevert(Core.NoCredit.selector);
        core.buyListing(priceB, _listingBytes(LISTED_B), LISTED_A, STRATEGY);

        assertEq(core.ethPot(), pot);
        assertEq(core.ethRate(), rate);
        assertEq(core.pileSize(Lane.Eth), 0);

        // an unrelated buy still goes through.
        vm.prank(keeper);
        core.buyListing(priceB, _listingBytes(LISTED_B), LISTED_B, STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_B), address(core));
        assertEq(core.pileSize(Lane.Eth), 1);

        // the core never buys a credit it already owns.
        vm.prank(keeper);
        vm.expectRevert(Core.AlreadyOwned.selector);
        core.buyListing(priceB, _listingBytes(LISTED_B), LISTED_B, STRATEGY);
        _solvent();
    }

    function test_buyListing_targetGuards() public {
        _fund(10 ether);
        vm.startPrank(keeper);
        vm.expectRevert(Core.TargetNotAllowed.selector);
        core.buyListing(1, "", LISTED_A, address(0xABCD));
        vm.expectRevert(Core.TargetNotAllowed.selector);
        core.buyListing(1, "", LISTED_A, address(CREDITS));
        vm.expectRevert(Core.TargetNotAllowed.selector);
        core.buyListing(1, "", LISTED_A, address(core));
        vm.expectRevert(Core.ZeroId.selector);
        core.buyListing(1, "", 0, STRATEGY);
        vm.stopPrank();
    }

    function test_buyListing_hourlyCapAndPotChecks() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _fund(10 ether);
        for (uint256 i; i < 300 && core.ceilingOf(LISTED_A) < price; ++i) {
            _warp(1 hours);
        }
        // shrink the window by asking for more than a fifth of the pot.
        stdstore.target(address(core)).sig("ethPot()").checked_write(price * 3);
        vm.prank(keeper);
        vm.expectRevert(Core.HourlyCap.selector);
        core.buyListing(price, _listingBytes(LISTED_A), LISTED_A, STRATEGY);

        stdstore.target(address(core)).sig("ethPot()").checked_write(price - 1);
        vm.prank(keeper);
        vm.expectRevert(Core.PotTooSmall.selector);
        core.buyListing(price, _listingBytes(LISTED_A), LISTED_A, STRATEGY);
    }

    /*//////////////////////////////////////////////////////////////
                       buyListing: hostile and mock targets
    //////////////////////////////////////////////////////////////*/

    function test_buyListing_hostileTargetThatKeepsEthReverts() public {
        HostileTarget hostile = new HostileTarget();
        _allow(address(hostile));
        _fund(10 ether);
        uint256 before = address(core).balance;
        vm.prank(keeper);
        vm.expectRevert(Core.NoCredit.selector);
        core.buyListing(1 gwei, "", LISTED_A, address(hostile));
        assertEq(address(core).balance, before);
        assertEq(address(hostile).balance, 0);
        assertEq(core.ethPot(), 10 ether);
    }

    function _seller(uint256 id) internal returns (MockSeller s) {
        s = new MockSeller();
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(s), id);
        _allow(address(s));
    }

    function test_buyListing_refundIsNotBooked() public {
        uint256 id = CreditIds.at(630);
        MockSeller s = _seller(id);
        _fund(10 ether);
        uint256 ceiling = core.ceilingOf(id);
        uint256 value = ceiling * 3 / 4;
        uint256 refund = value / 3;
        s.setRefund(refund);
        uint256 cost = value - refund;
        uint256 tip = ((ceiling - cost) * 1000 / 10_000).min(cost * 200 / 10_000);
        uint256 excessBefore = address(core).balance - core.ethPot() - core.ethToBuyback();

        vm.prank(keeper);
        core.buyListing(value, abi.encodeCall(MockSeller.fill, (id, value)), id, address(s));

        (,, uint256 booked,) = core.creditInfo(id);
        assertEq(booked, cost + tip, "cost is net of the refund");
        assertEq(core.ethPot(), 10 ether - cost - tip);
        assertEq(address(core).balance - core.ethPot() - core.ethToBuyback(), excessBefore, "refund booked nowhere");
        _solvent();

        // skim sees nothing extra.
        uint256 pot = core.ethPot();
        core.skim();
        assertEq(core.ethPot(), pot);
    }

    function test_buyListing_zeroNetCostReverts() public {
        uint256 id = CreditIds.at(631);
        MockSeller s = _seller(id);
        _fund(10 ether);
        uint256 value = core.ceilingOf(id) / 2;
        s.setRefund(value);
        vm.prank(keeper);
        vm.expectRevert(Core.BadCost.selector);
        core.buyListing(value, abi.encodeCall(MockSeller.fill, (id, value)), id, address(s));
    }

    function test_buyListing_busyWhileMeasuring() public {
        MockSeller feeder = new MockSeller();
        MockSeller s = new MockSeller();
        (Core c2,) = _deploy(address(feeder));
        uint256 id = CreditIds.at(632);
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(s), id);
        vm.deal(address(feeder), 20 ether);
        feeder.feed(address(c2), 10 ether);

        vm.startPrank(owner);
        c2.queue(Core.Action.AddTarget, abi.encode(address(s)));
        vm.warp(block.timestamp + 7 days);
        c2.execute(Core.Action.AddTarget, abi.encode(address(s)));
        vm.stopPrank();

        // the target makes the hook call addFees while the core is measuring its balance.
        s.setFee(address(feeder), address(c2), 1);
        vm.prank(keeper);
        vm.expectRevert(Core.CallFailed.selector);
        c2.buyListing(1e12, abi.encodeCall(MockSeller.fill, (id, 1e12)), id, address(s));

        // without the callback the same buy works, so the revert came from the busy flag.
        s.setFee(address(0), address(0), 0);
        vm.prank(keeper);
        c2.buyListing(1e12, abi.encodeCall(MockSeller.fill, (id, 1e12)), id, address(s));
        assertEq(CREDITS.ownerOf(id), address(c2));
    }

    /// the tip can never make a self listing beat the plain sell door.
    /// forge-config: default.fuzz.runs = 16
    function testFuzz_selfDealingTipNeverPays(uint256 priceSeed, uint256 warpHours) public {
        warpHours = bound(warpHours, 0, 200);
        uint256 id = CreditIds.at(633);
        MockSeller s = _seller(id);
        _fund(10 ether);
        _warp(warpHours * 1 hours);
        uint256 ceiling = core.ceilingOf(id);
        uint256 price = bound(priceSeed, 1, ceiling.min(1 ether));

        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        core.buyListing(price, abi.encodeCall(MockSeller.fill, (id, price)), id, address(s));
        uint256 tip = keeper.balance - keeperBefore;

        assertLe(tip, price * 200 / 10_000, "tip within two percent of cost");
        assertLe(price + tip, ceiling, "never more than the sell door pays");
        if (price < ceiling) assertLt(price + tip, ceiling);
        assertEq(address(s).balance, price, "the listing contract kept the price");
        _solvent();
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
        address newCtl = address(new MockController());
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

    function test_timelock_setControllerRejectsZero() public {
        vm.startPrank(owner);
        core.queue(Core.Action.SetController, abi.encode(address(0)));
        _warp(7 days);
        vm.expectRevert(Core.ZeroAddress.selector);
        core.execute(Core.Action.SetController, abi.encode(address(0)));
        vm.stopPrank();
    }

    function test_timelock_freezeRemovesControllerPowerForever() public {
        _setController(address(new MockController()));
        _timelock(Core.Action.Freeze, "");
        assertTrue(core.frozen());

        vm.prank(owner);
        vm.expectRevert(Core.Frozen.selector);
        core.queue(Core.Action.SetController, abi.encode(address(ctl)));

        // an action queued before the freeze cannot execute after it.
        // (queue it through a fresh core to show the execute guard.)
        Core c2;
        (c2,) = _deploy(hook);
        vm.startPrank(owner);
        c2.queue(Core.Action.SetController, abi.encode(address(ctl)));
        c2.queue(Core.Action.Freeze, "");
        _warp(7 days);
        c2.execute(Core.Action.Freeze, "");
        vm.expectRevert(Core.Frozen.selector);
        c2.execute(Core.Action.SetController, abi.encode(address(ctl)));
        vm.stopPrank();

        // the other powers survive the freeze.
        HostileTarget t = new HostileTarget();
        _allow(address(t));
        assertTrue(core.allowedTarget(address(t)));
    }

    function test_timelock_exitModuleOnce() public {
        (MockExitToken xt, MockExitModule mod) = _setModule(1e10);
        assertEq(core.exitModule(), address(mod));
        assertEq(core.exitToken(), address(xt));
        assertEq(core.xRate(), 6000);

        MockExitModule other = new MockExitModule(address(xt), 1e10);
        vm.startPrank(owner);
        core.queue(Core.Action.SetExitModule, abi.encode(address(other)));
        _warp(7 days);
        vm.expectRevert(Core.AlreadySet.selector);
        core.execute(Core.Action.SetExitModule, abi.encode(address(other)));
        vm.stopPrank();
    }

    function test_timelock_exitModuleValidation() public {
        vm.startPrank(owner);
        // no code
        core.queue(Core.Action.SetExitModule, abi.encode(address(0x1234)));
        // exit token is the coin
        MockExitModule coinModule = new MockExitModule(address(coin), 1e10);
        core.queue(Core.Action.SetExitModule, abi.encode(address(coinModule)));
        // exit token has no code
        MockExitModule ghost = new MockExitModule(address(0x5678), 1e10);
        core.queue(Core.Action.SetExitModule, abi.encode(address(ghost)));
        _warp(7 days);
        vm.expectRevert(Core.BadModule.selector);
        core.execute(Core.Action.SetExitModule, abi.encode(address(0x1234)));
        vm.expectRevert(Core.BadModule.selector);
        core.execute(Core.Action.SetExitModule, abi.encode(address(coinModule)));
        vm.expectRevert(Core.BadModule.selector);
        core.execute(Core.Action.SetExitModule, abi.encode(address(ghost)));
        vm.stopPrank();
        assertEq(core.exitModule(), address(0));
    }

    function _key(address a, address b, address hooks) internal pure returns (PoolKey memory k) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 60, IHooks(hooks));
    }

    uint160 internal constant LIM = TickMath.MIN_SQRT_PRICE + 1;

    function test_timelock_exitPoolKeyOnce() public {
        PoolKey memory early = _key(address(coin), address(0x7777), hook);
        vm.startPrank(owner);
        core.queue(Core.Action.SetExitPoolKey, abi.encode(early, LIM));
        _warp(7 days);
        vm.expectRevert(Core.NoExitModule.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(early, LIM));
        vm.stopPrank();

        (MockExitToken xt,) = _setModule(1e10);

        PoolKey memory wrongHook = _key(address(coin), address(xt), address(0x1));
        PoolKey memory wrongPair = _key(address(coin), address(0x8888), hook);
        PoolKey memory unsorted = _key(address(coin), address(xt), hook);
        (unsorted.currency0, unsorted.currency1) = (unsorted.currency1, unsorted.currency0);
        PoolKey memory good = _key(address(coin), address(xt), hook);
        PoolKey memory lpFee = _key(address(coin), address(xt), hook);
        lpFee.fee = 3000;
        PoolKey memory spacing = _key(address(coin), address(xt), hook);
        spacing.tickSpacing = 10;

        vm.startPrank(owner);
        core.queue(Core.Action.SetExitPoolKey, abi.encode(wrongHook, LIM));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(wrongPair, LIM));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(unsorted, LIM));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(good, LIM));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(lpFee, LIM));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(spacing, LIM));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(good, uint160(TickMath.MIN_SQRT_PRICE)));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(good, uint160(TickMath.MAX_SQRT_PRICE)));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(good, uint160(0)));
        _warp(7 days);
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(wrongHook, LIM));
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(wrongPair, LIM));
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(unsorted, LIM));
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(lpFee, LIM));
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(spacing, LIM));
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(good, uint160(TickMath.MIN_SQRT_PRICE)));
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(good, uint160(TickMath.MAX_SQRT_PRICE)));
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(good, uint160(0)));
        assertEq(core.exitPoolId(), bytes32(0));
        core.execute(Core.Action.SetExitPoolKey, abi.encode(good, LIM));
        vm.stopPrank();

        assertEq(core.exitPoolId(), keccak256(abi.encode(good)));

        PoolKey memory second = _key(address(coin), address(xt), hook);
        second.fee = 500;
        vm.startPrank(owner);
        core.queue(Core.Action.SetExitPoolKey, abi.encode(second, LIM));
        _warp(7 days);
        vm.expectRevert(Core.AlreadySet.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(second, LIM));
        vm.stopPrank();
    }

    function test_timelock_targets() public {
        address[7] memory forbidden = [
            address(CREDITS), address(STATEMENTS), address(core), address(coin), hook, Mainnet.POOL_MANAGER, address(0)
        ];
        vm.startPrank(owner);
        for (uint256 i; i < 7; ++i) {
            core.queue(Core.Action.AddTarget, abi.encode(forbidden[i]));
        }
        _warp(7 days);
        for (uint256 i; i < 7; ++i) {
            vm.expectRevert(Core.ForbiddenTarget.selector);
            core.execute(Core.Action.AddTarget, abi.encode(forbidden[i]));
        }
        vm.stopPrank();

        // the exit module and the exit token are forbidden once they exist.
        (MockExitToken xt, MockExitModule mod) = _setModule(1e10);
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
        MockExitToken xt = new MockExitToken("X", "X");
        MockExitModule mod = new MockExitModule(address(xt), 1e10);
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
        uint256[] memory a = _creditsTo(alice, 3);
        uint256[] memory b = _creditsTo(alice, 2);
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

    function _page(uint256 first, uint256 fill) internal pure returns (uint256[80] memory ids) {
        for (uint256 i; i < 80; ++i) {
            ids[i] = fill;
        }
        ids[0] = first;
    }

    function test_compose_notReady() public {
        vm.expectRevert(Core.NotReady.selector);
        core.compose();
        vm.expectRevert(Core.NotReady.selector);
        core.composeExit();

        _fund(10 ether);
        uint256[] memory ids = _creditsTo(alice, 79);
        vm.prank(alice);
        core.sellForEth(ids);
        vm.expectRevert(Core.NotReady.selector);
        core.compose();
    }

    function test_compose_controllerCannotNameBadPages() public {
        MockController mock = new MockController();
        _setController(address(mock));
        _fund(10 ether);
        uint256[] memory ids = _creditsTo(alice, 2);
        vm.prank(alice);
        core.sellForEth(ids);

        // an id that is in no pile
        mock.setPage(Lane.Eth, true, _page(ids[0], 777_777), 0);
        vm.expectRevert(abi.encodeWithSelector(Core.NotInPile.selector, 777_777));
        core.compose();

        // a duplicate: the second occurrence is no longer in the pile
        mock.setPage(Lane.Eth, true, _page(ids[0], ids[0]), 0);
        vm.expectRevert(abi.encodeWithSelector(Core.NotInPile.selector, ids[0]));
        core.compose();

        // a credit of the other lane
        mock.setPage(Lane.Exit, true, _page(ids[0], ids[1]), 0);
        vm.expectRevert(abi.encodeWithSelector(Core.NotInPile.selector, ids[0]));
        core.composeExit();

        // id zero is the null sentinel and is never in a pile
        mock.setPage(Lane.Eth, true, _page(0, 0), 0);
        vm.expectRevert(abi.encodeWithSelector(Core.NotInPile.selector, 0));
        core.compose();

        // bad format
        mock.setPage(Lane.Eth, true, _page(ids[0], ids[1]), 8);
        vm.expectRevert(Core.BadFormat.selector);
        core.compose();

        // not ready and a reverting controller
        mock.setPage(Lane.Eth, false, _page(ids[0], ids[1]), 0);
        vm.expectRevert(Core.NotReady.selector);
        core.compose();
        mock.setRevertPage(true);
        vm.expectRevert(Core.NotReady.selector);
        core.compose();

        // a reverting controller blocks nothing else
        uint256[] memory more = _creditsTo(alice, 1);
        vm.prank(alice);
        core.sellForEth(more);
        assertEq(core.pileSize(Lane.Eth), 3);
    }

    function test_compose_pullsFromTheMiddleAndKeepsTheListIntact() public {
        MockController mock = new MockController();
        _setController(address(mock));
        _fund(20 ether);
        uint256[] memory ids = _creditsTo(alice, 85);
        vm.prank(alice);
        core.sellForEth(ids);
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
        // a page in a different order than the pile is fine.
        (page[0], page[79]) = (page[79], page[0]);
        mock.setPage(Lane.Eth, true, page, 7);
        vm.prank(keeper);
        core.compose();

        assertEq(core.pileSize(Lane.Eth), 5);
        assertEq(core.pileHead(Lane.Eth), ids[0]);
        uint256[] memory rest = core.pilePage(Lane.Eth, 0, 10);
        assertEq(rest.length, 5);
        for (uint256 j; j < 5; ++j) {
            assertEq(rest[j], ids[left[j]]);
        }
        assertEq(core.pileNext(ids[84]), 0);

        // a new arrival lands behind the old tail.
        uint256[] memory more = _creditsTo(alice, 1);
        vm.prank(alice);
        core.sellForEth(more);
        assertEq(core.pileNext(ids[84]), more[0]);
        assertEq(core.pileSize(Lane.Eth), 6);
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                           statements and buybacks
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
        vm.prank(hook);
        vm.expectRevert(Core.NoExitModule.selector);
        core.addExitFees(1);
        core.skim();
    }

    function test_overprint_notReadyWithV1() public {
        vm.expectRevert(Core.NotReady.selector);
        core.overprint();
    }

    function test_buyback_guards() public {
        vm.expectRevert(Core.NothingToBuy.selector);
        core.buyback();
        vm.expectRevert(Core.Dormant.selector);
        core.buybackExit();

        stdstore.target(address(core)).sig("ethToBuyback()").checked_write(uint256(1 ether));
        vm.deal(address(core), 1 ether);
        stdstore.target(address(core)).sig("lastBuybackBlock()").checked_write(block.number);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 24);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();

        // after the delay the swap is attempted. there is no pool in this test so it fails inside the pool manager,
        // and the pot and the delay bookkeeping roll back with it.
        vm.roll(block.number + 1);
        vm.expectRevert();
        core.buyback();
        assertEq(core.ethToBuyback(), 1 ether);
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
        uint256[] memory ids = _creditsTo(alice, 6);
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

/// a buyer that cannot receive statements.
contract DeafBuyer {
    function buy(Core c, uint256 sid) external payable {
        c.buyStatement{value: msg.value}(sid);
    }

    receive() external payable {}
}

/// tries to re enter the core while it receives the statement.
contract ReentrantBuyer {
    Core internal core;

    constructor(Core c) {
        core = c;
    }

    function buy(uint256 sid) external payable {
        core.buyStatement{value: address(this).balance}(sid);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        core.skim();
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

contract CoreComposedTest is CoreBase {
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    uint256 internal constant UNIT = 1e10;

    MockExitToken internal xt;
    MockExitModule internal mod;
    uint256 internal sid;
    uint256 internal supplyBefore;
    uint256 internal sumCost;
    uint256 internal reimb;
    uint256 internal potBefore;
    uint256 internal composedAt;
    uint256[] internal pageIds;

    function _makeHook() internal override returns (address) {
        return address(new MockHook());
    }

    function setUp() public override {
        super.setUp();
        (xt, mod) = _setModule(UNIT);
        _fund(20 ether);
        vm.fee(2 gwei);
        supplyBefore = STATEMENTS.supply();
        pageIds = _creditsTo(alice, 80);
        vm.prank(alice);
        core.sellForEth(pageIds);
        for (uint256 i; i < 80; ++i) {
            (,, uint256 c,) = core.creditInfo(pageIds[i]);
            sumCost += c;
        }
        potBefore = core.ethPot();
        uint256 balBefore = keeper.balance;
        composedAt = block.timestamp;
        vm.prank(keeper);
        core.compose();
        reimb = keeper.balance - balBefore;
        sid = supplyBefore + 1;
    }

    /// sells 80 fresh credits and composes them. returns the new statement id.
    function _freshStatement() internal returns (uint256 id) {
        uint256 before = STATEMENTS.supply();
        uint256[] memory ids = _creditsTo(alice, 80);
        vm.prank(alice);
        core.sellForEth(ids);
        vm.prank(keeper);
        core.compose();
        id = before + 1;
    }

    function _sumScores(uint256[] memory ids) internal view returns (uint256 t) {
        for (uint256 i; i < ids.length; ++i) {
            t += core.scoreOf(ids[i]);
        }
    }

    function _held() internal view returns (uint256[] memory) {
        return core.heldStatements();
    }

    /*//////////////////////////////////////////////////////////////
                                 compose
    //////////////////////////////////////////////////////////////*/

    function test_compose_statementIdCostBasisAndPiles() public view {
        assertEq(sid, supplyBefore + 1);
        assertEq(STATEMENTS.supply(), sid);
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        assertEq(STATEMENTS.creditsOf(sid), 80);
        assertEq(STATEMENTS.creditScoreOf(sid), _sumScores(pageIds));

        (bool held, Lane lane, uint256 cost, uint64 clockStart) = core.statementInfo(sid);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(cost, sumCost + reimb, "cost basis is the credits plus the gas refund");
        assertEq(clockStart, composedAt);

        assertEq(core.pileSize(Lane.Eth), 0);
        assertEq(core.pileHead(Lane.Eth), 0);
        for (uint256 i; i < 80; ++i) {
            (bool inPile,,,) = core.creditInfo(pageIds[i]);
            assertFalse(inPile);
        }
        assertEq(CREDITS.balanceOf(address(core)), 0, "the credits were burned into the statement");
        uint256[] memory h = _held();
        assertEq(h.length, 1);
        assertEq(h[0], sid);
        assertEq(core.ethPot(), potBefore - reimb);
        _solvent();
    }

    function test_compose_gasReimbursementCappedAtFivePercent() public view {
        assertGt(reimb, 0);
        assertEq(reimb, sumCost * 500 / 10_000, "2 gwei is far above the cap so the cap binds exactly");
    }

    function test_compose_gasReimbursementTracksGasWhenUncapped() public {
        uint256[] memory ids = _creditsTo(alice, 80);
        vm.prank(alice);
        core.sellForEth(ids);
        uint256 pot = core.ethPot();
        uint256 snap = vm.snapshotState();

        // 1 wei basefee: the refund is gas used times 1.1, far below the cap.
        vm.fee(1);
        uint256 before = keeper.balance;
        uint256 supply = STATEMENTS.supply();
        vm.prank(keeper);
        core.compose();
        uint256 low = keeper.balance - before;
        assertGt(low, 5_000_000 * 11 / 10, "at least the gas of the compose call");
        assertLt(low, 12_000_000 * 11 / 10, "and not wildly more");
        (,, uint256 cost,) = core.statementInfo(supply + 1);
        assertEq(core.ethPot(), pot - low);
        assertGt(cost, low);

        vm.revertToState(snap);
        // no basefee, no refund, and the cost basis is only the credits.
        vm.fee(0);
        before = keeper.balance;
        supply = STATEMENTS.supply();
        vm.prank(keeper);
        core.compose();
        assertEq(keeper.balance, before);
        (,, cost,) = core.statementInfo(supply + 1);
        assertEq(core.ethPot(), pot);
        assertGt(cost, 0);

        vm.revertToState(snap);
        // the refund never exceeds the pot either.
        stdstore.target(address(core)).sig("ethPot()").checked_write(uint256(7));
        vm.fee(1000 gwei);
        before = keeper.balance;
        vm.prank(keeper);
        core.compose();
        assertEq(keeper.balance - before, 7, "limited by the pot");
        assertEq(core.ethPot(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 auction
    //////////////////////////////////////////////////////////////*/

    function _expectedPrice(uint256 cost, uint256 elapsed) internal pure returns (uint256) {
        uint256 L = 72 hours;
        return cost.mulDivUp(40_000 * L - 28_000 * elapsed.min(L), L * 10_000);
    }

    function test_auction_priceCurve() public {
        (,, uint256 cost,) = core.statementInfo(sid);
        assertEq(core.priceOf(sid), cost * 4, "opens at 4x");
        _warp(18 hours);
        assertEq(core.priceOf(sid), cost.mulDivUp(33_000, 10_000), "3.3x a quarter of the way down");
        _warp(18 hours);
        assertEq(core.priceOf(sid), cost.mulDivUp(26_000, 10_000), "2.6x half way");
        _warp(36 hours);
        assertEq(core.priceOf(sid), cost.mulDivUp(12_000, 10_000), "1.2x at the end");
        assertGe(core.priceOf(sid) * 10, cost * 12);
        _warp(5000 hours);
        assertEq(core.priceOf(sid), cost.mulDivUp(12_000, 10_000), "flat at the floor");
    }

    /// invariant 3: no statement is priced below 1.2 times its cost or above 4 times.
    /// forge-config: default.fuzz.runs = 32
    function testFuzz_auction_priceBounds(uint256 dt) public {
        (,, uint256 cost,) = core.statementInfo(sid);
        dt = bound(dt, 0, 400 hours);
        _warp(dt);
        uint256 p = core.priceOf(sid);
        assertEq(p, _expectedPrice(cost, dt));
        assertGe(p * 10, cost * 12);
        assertLe(p, cost * 4);
    }

    function test_buyStatement_splitRefundAndTransfer() public {
        _warp(20 hours);
        uint256 price = core.priceOf(sid);
        address buyer = makeAddr("creditsengine.buyer");
        vm.deal(buyer, price + 1 ether);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();

        vm.prank(buyer);
        vm.expectRevert(Core.Underpaid.selector);
        core.buyStatement{value: price - 1}(sid);

        vm.prank(buyer);
        core.buyStatement{value: price + 1 ether}(sid);

        assertEq(buyer.balance, 1 ether, "excess came back");
        assertEq(STATEMENTS.ownerOf(sid), buyer);
        uint256 half = price * 5000 / 10_000;
        assertEq(core.ethToBuyback(), bb + half);
        assertEq(core.ethPot(), pot + price - half);
        assertEq(_held().length, 0);
        (bool held,,,) = core.statementInfo(sid);
        assertFalse(held);
        _solvent();

        vm.expectRevert(Core.NotForSale.selector);
        core.priceOf(sid);
        vm.prank(buyer);
        vm.expectRevert(Core.NotForSale.selector);
        core.buyStatement{value: price}(sid);
    }

    function test_buyStatement_exactPaymentAtTheFloorAndOddSplit() public {
        _warp(100 hours);
        uint256 price = core.priceOf(sid);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        vm.deal(alice, price);
        vm.prank(alice);
        core.buyStatement{value: price}(sid);
        assertEq(alice.balance, 0);
        // the odd wei stays in the pot.
        assertEq(core.ethToBuyback() - bb, price / 2);
        assertEq(core.ethPot() - pot, price - price / 2);
        _solvent();
    }

    function test_buyStatement_contractBuyerWithoutReceiverReverts() public {
        DeafBuyer buyer = new DeafBuyer();
        uint256 price = core.priceOf(sid);
        vm.deal(address(buyer), price);
        vm.expectRevert();
        buyer.buy(core, sid);
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        assertEq(_held().length, 1);
    }

    /*//////////////////////////////////////////////////////////////
                              exit path
    //////////////////////////////////////////////////////////////*/

    function test_exit_guards() public {
        vm.expectRevert(Core.NotHeld.selector);
        core.exitStatement(sid + 100);
        vm.expectRevert(Core.AuctionRunning.selector);
        core.exitStatement(sid);
        _warp(72 hours - 1);
        vm.expectRevert(Core.AuctionRunning.selector);
        core.exitStatement(sid);
        _warp(1);
        core.exitStatement(sid);
        vm.expectRevert(Core.NotHeld.selector);
        core.exitStatement(sid);
    }

    function test_exit_splitsEthLaneStatement() public {
        _warp(72 hours);
        uint256 rating = STATEMENTS.creditScoreOf(sid);
        uint256 out = rating * UNIT;
        core.exitStatement(sid);

        assertEq(STATEMENTS.ownerOf(sid), address(mod), "the module keeps the statement");
        assertEq(xt.balanceOf(address(core)), out);
        assertEq(core.xToBuyback(), out * 5000 / 10_000);
        assertEq(core.xPot(), out - out * 5000 / 10_000);
        assertEq(_held().length, 0);
        (bool held,,,) = core.statementInfo(sid);
        assertFalse(held);
        assertEq(core.xRate(), 6000);
        _solvent();
    }

    function test_exit_moduleThatUnderpaysReverts() public {
        _warp(72 hours);
        mod.setShortfallBps(1);
        vm.expectRevert(Core.Underpaid.selector);
        core.exitStatement(sid);
        mod.setShortfallBps(5000);
        vm.expectRevert(Core.Underpaid.selector);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "the statement never left");
        assertEq(_held().length, 1);

        mod.setShortfallBps(0);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    /// R3 regression: the unit is fixed when the module is set. a module that pays by a lower unit later is refused
    /// by the stored one, and one that pays more is simply paid
    function test_exit_unitIsFixedAtSetTime() public {
        assertEq(core.unitPerPoint(), UNIT);
        _warp(72 hours);
        mod.setUnitPerPoint(0);
        vm.expectRevert(Core.Underpaid.selector);
        core.exitStatement(sid);

        mod.setUnitPerPoint(3e10);
        uint256 out = STATEMENTS.creditScoreOf(sid) * 3e10;
        core.exitStatement(sid);
        assertEq(xt.balanceOf(address(core)), out);
        assertEq(core.unitPerPoint(), UNIT, "the stored unit did not follow the module");
    }

    /// R3 regression: whatever the module reports later changes nothing. fee intake, the rate, the bid and the
    /// buyback slice all use the stored unit
    function test_exit_laterModuleUnitsChangeNothing() public {
        uint256 pot = _exitSplitState();
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
            vm.prank(hook);
            core.addExitFees(1e18);
            xt.mint(address(core), 1e18);
            core.skim();
            assertEq(core.xRate(), 6100, "the rate follows the stored unit");
            _solvent();
        }
        assertEq(core.xPot(), pot + 4e18);

        uint256[] memory ids = _creditsTo(alice, 1);
        uint256 price = core.scoreOf(ids[0]) * core.xRate() * UNIT / 10_000;
        vm.prank(alice);
        core.sellForExitToken(ids);
        assertEq(xt.balanceOf(alice), price, "paid at the stored unit");
        _solvent();
    }

    /// R3: a module whose unit is zero, above uint128, or unreadable is refused when it is set
    function test_exit_setModuleRefusesBadUnits() public {
        uint256[4] memory units = [uint256(0), uint256(type(uint128).max) + 1, type(uint256).max, 1e10];
        for (uint256 i; i < units.length; ++i) {
            MockExitModule m = new MockExitModule(address(new MockExitToken("X", "X")), units[i]);
            if (i == 3) m.setRevertUnit(true);
            Core fresh = new Core(owner, address(coin), hook, address(ctl));
            vm.startPrank(owner);
            fresh.queue(Core.Action.SetExitModule, abi.encode(address(m)));
            _warp(7 days);
            vm.expectRevert(Core.BadModule.selector);
            fresh.execute(Core.Action.SetExitModule, abi.encode(address(m)));
            vm.stopPrank();
            assertEq(fresh.exitModule(), address(0));
        }
    }

    function test_exit_refusesFeeCallbackMidExit() public {
        _warp(72 hours);
        mod.setFeeder(hook);
        vm.expectRevert(Core.Busy.selector);
        core.exitStatement(sid);
    }

    function test_exit_statementStaysBuyableAtFloorUntilExited() public {
        _warp(200 hours);
        uint256 price = core.priceOf(sid);
        vm.deal(alice, price);
        vm.prank(alice);
        core.buyStatement{value: price}(sid);
        vm.expectRevert(Core.NotHeld.selector);
        core.exitStatement(sid);
    }

    /*//////////////////////////////////////////////////////////////
                              exit token bid
    //////////////////////////////////////////////////////////////*/

    function _exitSplitState() internal returns (uint256 pot) {
        _warp(72 hours);
        core.exitStatement(sid);
        pot = core.xPot();
    }

    function test_xBid_rateClimbsAndDropsPerCredit() public {
        uint256 pot = _exitSplitState();
        _warp(10 hours);
        assertEq(core.xRate(), 7000, "one point (100 bps) an hour while funded");

        uint256[] memory ids = _creditsTo(alice, 3);
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

    function test_xBid_capAndAffordabilityClamp() public {
        _exitSplitState();
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
        _exitSplitState();
        xt.mint(address(core), 1_000_000e18);
        core.skim();
        for (uint256 b; b < 2; ++b) {
            uint256[] memory ids = _creditsTo(alice, 80);
            vm.prank(alice);
            core.sellForExitToken(ids);
        }
        assertEq(core.xRate(), 3000, "160 credits at 0.2 point each hit the floor and stop");
        _solvent();
    }

    function test_xBid_guards() public {
        _exitSplitState();
        uint256[] memory ids = _creditsTo(alice, 1);
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

    function test_xFees_addExitFeesAndSkim() public {
        _exitSplitState();
        uint256 pot = core.xPot();
        vm.prank(hook);
        vm.expectRevert(Core.Unfunded.selector);
        core.addExitFees(1);

        xt.mint(address(core), 5e18);
        vm.prank(hook);
        core.addExitFees(5e18);
        assertEq(core.xPot(), pot + 5e18);
        vm.prank(hook);
        vm.expectRevert(Core.Unfunded.selector);
        core.addExitFees(1);

        // a plain transfer is booked only by skim.
        xt.mint(address(core), 3e18);
        assertEq(core.xPot(), pot + 5e18);
        core.skim();
        assertEq(core.xPot(), pot + 8e18);
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                         exit lane compose and exit
    //////////////////////////////////////////////////////////////*/

    function test_exitLane_composeThenImmediateExit() public {
        _exitSplitState();
        xt.mint(address(core), 100e18);
        core.skim();

        uint256[] memory ids = _creditsTo(alice, 80);
        vm.prank(alice);
        core.sellForExitToken(ids);
        assertEq(core.pileSize(Lane.Exit), 80);
        uint256 sumExit;
        for (uint256 i; i < 80; ++i) {
            (,, uint256 c,) = core.creditInfo(ids[i]);
            sumExit += c;
        }

        uint256 potBefore_ = core.ethPot();
        uint256 balBefore = keeper.balance;
        uint256 supply = STATEMENTS.supply();
        vm.prank(keeper);
        core.composeExit();
        uint256 sidX = supply + 1;
        uint256 paid = keeper.balance - balBefore;

        assertEq(STATEMENTS.ownerOf(sidX), address(core));
        (bool held, Lane lane, uint256 cost,) = core.statementInfo(sidX);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Exit));
        assertEq(cost, sumExit, "exit token cost basis, no refund added");
        assertEq(core.pileSize(Lane.Exit), 0);
        assertEq(core.ethPot(), potBefore_ - paid);
        assertLe(paid, 80 * 4_330_000 * core.ethRate() / 1e4 * 500 / 10_000, "notional cap");
        assertGt(paid, 0);

        vm.expectRevert(Core.NotForSale.selector);
        core.priceOf(sidX);
        vm.expectRevert(Core.NotForSale.selector);
        core.buyStatement(sidX);

        // no auction in the exit lane, so it exits at once and everything returns to the bid pot.
        uint256 xPotBefore = core.xPot();
        uint256 xbbBefore = core.xToBuyback();
        uint256 out = STATEMENTS.creditScoreOf(sidX) * UNIT;
        core.exitStatement(sidX);
        assertEq(core.xPot(), xPotBefore + out);
        assertEq(core.xToBuyback(), xbbBefore);
        assertEq(STATEMENTS.ownerOf(sidX), address(mod));
        _solvent();
    }

    /*//////////////////////////////////////////////////////////////
                         pile integrity and reentrancy
    //////////////////////////////////////////////////////////////*/

    function test_reentrancyThroughStatementReceiverReverts() public {
        ReentrantBuyer buyer = new ReentrantBuyer(core);
        uint256 price = core.priceOf(sid);
        vm.deal(address(buyer), price);
        vm.expectRevert();
        buyer.buy(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        assertEq(_held().length, 1);
    }

    /*//////////////////////////////////////////////////////////////
                                overprint
    //////////////////////////////////////////////////////////////*/

    function test_overprint_mergesAndRestartsClock() public {
        uint256 sid2 = _freshStatement();
        MockController mock = new MockController();
        _setController(address(mock));
        _warp(10 hours);
        mock.setOverprint(true, sid, sid2);

        (,, uint256 c1,) = core.statementInfo(sid);
        (,, uint256 c2,) = core.statementInfo(sid2);
        uint256 r1 = STATEMENTS.creditScoreOf(sid);
        uint256 r2 = STATEMENTS.creditScoreOf(sid2);

        core.overprint();

        (bool held, Lane lane, uint256 cost, uint64 clockStart) = core.statementInfo(sid);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(cost, c1 + c2, "cost bases are summed");
        assertEq(clockStart, block.timestamp, "the auction restarts");
        assertEq(STATEMENTS.creditScoreOf(sid), r1 + r2);
        assertEq(STATEMENTS.overprintsOf(sid), 1);
        (bool held2,,,) = core.statementInfo(sid2);
        assertFalse(held2);
        uint256[] memory h = _held();
        assertEq(h.length, 1);
        assertEq(h[0], sid);
        assertEq(core.priceOf(sid), (c1 + c2) * 4);
        assertEq(core.overprintCount(), 1);

        // the top is gone from circulation.
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();
    }

    function test_overprint_guards() public {
        MockController mock = new MockController();
        _setController(address(mock));

        vm.expectRevert(Core.NotReady.selector);
        core.overprint();

        mock.setOverprint(true, sid, sid);
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();

        mock.setOverprint(true, sid, sid + 50);
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();

        mock.setOverprint(true, sid + 50, sid);
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();

        // a statement of the exit lane cannot be merged into an eth lane one.
        xt.mint(address(core), 100e18);
        core.skim();
        uint256 supply = STATEMENTS.supply();
        uint256[] memory ids = _creditsTo(alice, 80);
        vm.prank(alice);
        core.sellForExitToken(ids);
        uint256[80] memory page;
        for (uint256 i; i < 80; ++i) {
            page[i] = ids[i];
        }
        mock.setPage(Lane.Exit, true, page, 0);
        vm.prank(keeper);
        core.composeExit();
        mock.setOverprint(true, sid, supply + 1);
        vm.expectRevert(Core.BadOverprint.selector);
        core.overprint();

        mock.setRevertPage(true);
        mock.setOverprint(false, sid, supply + 1);
        vm.expectRevert(Core.NotReady.selector);
        core.overprint();
    }

    function test_overprint_dailyCap() public {
        uint256 sid2 = _freshStatement();
        uint256 sid3 = _freshStatement();
        MockController mock = new MockController();
        _setController(address(mock));

        mock.setOverprint(true, sid, sid2);
        core.overprint();
        assertEq(core.overprintCount(), 1);

        // pretend the day's budget is spent.
        stdstore.target(address(core)).sig("overprintCount()").checked_write(uint256(8));
        mock.setOverprint(true, sid, sid3);
        vm.expectRevert(Core.DailyCap.selector);
        core.overprint();

        // the budget resets with the next utc day.
        _warp(1 days);
        core.overprint();
        assertEq(core.overprintCount(), 1);
        assertEq(STATEMENTS.overprintsOf(sid), 2);
        _solvent();
    }
}
