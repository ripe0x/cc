// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CCBarsSale, ICoreForBarsSale, IBarsForSale} from "../src/adapters/CCBarsSale.sol";
import {CCBarsVault} from "../src/adapters/CCBarsVault.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {BarsSale} from "../script/BarsSale.s.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Phase3} from "../script/Phase3.s.sol";
import {IBalanceTreasuryV2} from "../src/interfaces/IBalanceTreasuryV2.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";

interface ICoreView {
    function owner() external view returns (address);
    function controller() external view returns (address);
    function ethPot() external view returns (uint256);
    function book() external;
}

interface IControllerPrice {
    function referencePrice() external view returns (uint256);
    function spotPrice() external view returns (uint256, bool);
    function balancePoolKey() external view returns (Currency, Currency, uint24, int24, IHooks);
}

interface IErc20 {
    function balanceOf(address who) external view returns (uint256);
    function approve(address to, uint256 amount) external returns (bool);
}

interface IControllerV2Time {
    function referenceTime() external view returns (uint40);
}

interface IErc721Bal {
    function balanceOf(address owner) external view returns (uint256);
}

interface IBarsMeltAll {
    function meltBatch(uint256[] calldata ids) external returns (uint256 total);
}

/// a buyer whose refund tries to buy again, recording how the inner buy failed
contract ReentrantBuyer {
    CCBarsSale internal immutable sale;
    uint256[] internal ids;
    uint256[] internal second;
    bytes public innerError;

    constructor(CCBarsSale sale_, uint256 id, uint256 other) {
        sale = sale_;
        ids.push(id);
        second.push(other);
    }

    function go() external payable {
        sale.buy{value: msg.value}(ids);
    }

    receive() external payable {
        if (innerError.length != 0) return;
        try sale.buy{value: msg.value}(second) {
            innerError = hex"01";
        } catch (bytes memory err) {
            innerError = err;
        }
    }
}

/// the live Core, controller, BALANCE pool, Bars and CC Bars vault on a pinned mainnet fork; only the sale is new
contract CCBarsSaleTest is Test {
    uint256 internal constant FORK_BLOCK = 26494300;

    BarsSale internal script;
    CCBarsSale internal sale;
    ICoreView internal core;
    address internal owner;
    address internal buyer;
    uint256[] internal held;
    uint256 internal vaultLeftover;
    address internal constant BALANCE = 0x3620540c994433D7B4a628C46d2ED5F92572eA07;
    address internal constant BARS = 0x7d9EdeA03dD97361c3e21389B95bc327e22752aE;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), FORK_BLOCK);
        // buyers' ETH accounting below assumes no gas cost
        vm.txGasPrice(0);
        vm.fee(0);
        script = new BarsSale();
        core = ICoreView(script.CORE());
        owner = core.owner();
        assertEq(script.barsOf(script.VAULT()).length, 63, "the vault's 63 Bars at the pin");
        vaultLeftover = IErc20(BALANCE).balanceOf(script.VAULT());
        assertEq(vaultLeftover, 541.789275702 ether, "the vault's unreturned BALANCE at the pin");
        IPhase2BalanceTreasury v1 = IPhase2BalanceTreasury(CCBarsVault(script.VAULT()).treasury());
        uint256 custody0 = v1.custody();
        sale = script.execute(owner);
        assertEq(v1.custody(), custody0 + vaultLeftover, "the leftover reached the v1 treasury");
        held = script.barsOf(address(sale));
        buyer = makeAddr("buyer");
        vm.deal(buyer, 100 ether);
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _key() internal view returns (PoolKey memory k) {
        (k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks) =
            IControllerPrice(core.controller()).balancePoolKey();
    }

    /// Bar `id`'s ask at multiplier `bps`, computed here from the live controller views, independent of the sale's code
    function _ask(uint256 id, uint256 bps) internal view returns (uint256) {
        IControllerPrice c = IControllerPrice(core.controller());
        uint256 ref = c.referencePrice();
        (uint256 spot,) = c.spotPrice();
        uint256 px = spot > ref ? spot : ref;
        return FixedPointMathLib.mulDivUp(FixedPointMathLib.mulDivUp(id * 1 ether, px, 1e18), bps, 10_000);
    }

    // promise: the owner command moves every vault Bar into the sale, starts each Bar's fall, switches sales on, and
    // a rerun sends nothing new
    function test_scriptMovesEveryBarAndResumes() public {
        assertEq(held.length, 63);
        // the vault's mints interleaved with other minters: the 63 Bars it holds are every wei it spent, none missing
        uint256 sum;
        for (uint256 i; i < held.length; ++i) {
            sum += held[i] * 1 ether;
            assertEq(sale.arrivedAt(held[i]), block.timestamp, "each Bar's fall starts at its arrival");
        }
        assertEq(sum, CCBarsVault(script.VAULT()).spent(), "the sale holds every Bar the vault bought");
        assertEq(script.barsOf(script.VAULT()).length, 0);
        assertEq(IErc20(BALANCE).balanceOf(script.VAULT()), 0, "the vault's leftover went back");
        assertTrue(sale.on());
        assertEq(sale.startBps(), 40_000);
        assertEq(sale.floorBps(), 15_000);
        assertEq(sale.window(), 14 days);
        assertEq(address(sale), script.saleAddress());
        script.execute(owner);
        assertEq(script.barsOf(address(sale)).length, 63, "rerun changed nothing");
    }

    // promise: a Bar asks its BALANCE value times a multiplier falling from 4x to 1.5x over 14 days from its arrival,
    // and every wei paid reaches the Core's pot
    function test_fallingSaleFundsThePot() public {
        uint256 id = held[0];
        uint256 ask = sale.priceOf(id);
        assertEq(ask, _ask(id, 40_000));
        console.log("Bar", id);
        console.log("ask at arrival wei", ask);

        core.book();
        uint256 pot0 = core.ethPot();
        vm.prank(buyer);
        uint256 paid = sale.buy{value: 1 ether}(_one(id));
        assertEq(paid, ask);
        assertEq(core.ethPot(), pot0 + ask, "pot got the price");
        assertEq(buyer.balance, 100 ether - ask, "excess refunded");
        assertEq(address(sale).balance, 0);
        assertEq(IBarsForSale(BARS).ownerOf(id), buyer);
        vm.expectRevert(abi.encodeWithSelector(CCBarsSale.NotForSale.selector, id));
        sale.priceOf(id);

        // half way: 2.75x. absolute warps: the test reads block.timestamp once
        uint256 t0 = sale.arrivedAt(held[1]);
        vm.warp(t0 + 7 days);
        assertEq(sale.multiplierOf(held[1]), 27_500);
        uint256[] memory two = new uint256[](2);
        two[0] = held[1];
        two[1] = held[2];
        uint256 due = _ask(held[1], 27_500) + _ask(held[2], 27_500);
        core.book();
        pot0 = core.ethPot();
        vm.prank(buyer);
        paid = sale.buy{value: due}(two);
        assertEq(paid, due);
        assertEq(core.ethPot(), pot0 + due);

        // past the window: the floor, 1.5x
        vm.warp(t0 + 14 days);
        assertEq(sale.multiplierOf(held[3]), 15_000);
        uint256 floorAsk = _ask(held[3], 15_000);
        assertEq(sale.priceOf(held[3]), floorAsk);
        vm.prank(buyer);
        vm.expectRevert(CCBarsSale.Underpaid.selector);
        sale.buy{value: floorAsk - 1}(_one(held[3]));
    }

    // promise: the ask follows the BALANCE price with no owner action: a rise lifts it the same block, and a spot pushed
    // under the reference leaves the ask at the reference
    function test_askFollowsTheBalancePrice() public {
        uint256 id = held[0];
        uint256 before = sale.priceOf(id);

        uint256 snap = vm.snapshotState();
        TestSwapRouter router = new TestSwapRouter();
        address whale = makeAddr("whale");
        vm.deal(whale, 10 ether);
        vm.prank(whale);
        router.swap{value: 10 ether}(_key(), true, -int256(10 ether), whale);
        uint256 lifted = sale.priceOf(id);
        assertEq(lifted, _ask(id, 40_000));
        assertGt(lifted, before * 2, "a 10 ETH buy into a 12 ETH pool more than doubles the ask");
        console.log("ask before", before);
        console.log("ask after the lift", lifted);
        vm.revertToState(snap);

        router = new TestSwapRouter();
        IPhase2BalanceTreasury treasury = IPhase2BalanceTreasury(CCBarsVault(script.VAULT()).treasury());
        vm.prank(owner);
        treasury.withdrawWorking(whale, 100_000 ether);
        uint256 ref = IControllerPrice(core.controller()).referencePrice();
        vm.startPrank(whale);
        IErc20(BALANCE).approve(address(router), 100_000 ether);
        router.swap(_key(), false, -int256(100_000 ether), whale);
        vm.stopPrank();
        (uint256 spot,) = IControllerPrice(core.controller()).spotPrice();
        assertLt(spot, ref, "the dump leaves the spot under the reference");
        assertEq(
            sale.priceOf(id),
            FixedPointMathLib.mulDivUp(FixedPointMathLib.mulDivUp(id * 1 ether, ref, 1e18), 40_000, 10_000)
        );
    }

    // promise: the owner alone edits the multipliers, never below 1x; each Bar keeps its own arrival clock, and a Bar
    // that comes back starts a new fall
    function test_ownerEditsTheMultipliers() public {
        uint256 id = held[0];
        uint256 t0 = sale.arrivedAt(id);
        vm.startPrank(owner);
        sale.setSale(10_000, 10_000, 1);
        assertEq(sale.priceOf(id), _ask(id, 10_000), "a 1x floor sells at the BALANCE value");
        vm.expectRevert(CCBarsSale.BadSetting.selector);
        sale.setSale(10_000, 9_999, 1);
        vm.expectRevert(CCBarsSale.BadSetting.selector);
        sale.setSale(19_999, 20_000, 1);
        vm.expectRevert(CCBarsSale.BadSetting.selector);
        sale.setSale(20_000, 20_000, 0);
        sale.setSale(30_000, 20_000, 10 days);
        vm.stopPrank();
        assertEq(sale.arrivedAt(id), t0, "a setting change keeps the arrival");
        vm.warp(t0 + 5 days);
        assertEq(sale.multiplierOf(id), 25_000);

        // out and back: the Bar's fall restarts at its return
        vm.prank(owner);
        sale.transferBars(owner, _one(id));
        vm.prank(owner);
        IBarsForSale(BARS).safeTransferFrom(owner, address(sale), id);
        assertEq(sale.arrivedAt(id), t0 + 5 days);
        assertEq(sale.multiplierOf(id), 30_000);

        // out and back by plain transfer: moving it out cleared the arrival and a plain return records none, so the Bar
        // is not for sale until the owner starts its clock with a transfer to the sale itself
        vm.prank(owner);
        sale.transferBars(owner, _one(id));
        assertEq(sale.arrivedAt(id), 0, "moving a Bar out clears its arrival");
        vm.prank(owner);
        IBarsForSale(BARS).transferFrom(owner, address(sale), id);
        vm.expectRevert(abi.encodeWithSelector(CCBarsSale.NotForSale.selector, id));
        sale.priceOf(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CCBarsSale.NotForSale.selector, id));
        sale.buy{value: 1 ether}(_one(id));
        vm.prank(owner);
        sale.transferBars(address(sale), _one(id));
        assertEq(sale.arrivedAt(id), t0 + 5 days);
        assertEq(sale.priceOf(id), _ask(id, 30_000), "the clock starts at the start multiplier");

        address eve = makeAddr("eve");
        vm.startPrank(eve);
        vm.expectRevert(CCBarsSale.OnlyOwner.selector);
        sale.setSale(20_000, 20_000, 1);
        vm.expectRevert(CCBarsSale.OnlyOwner.selector);
        sale.setOn(false);
        vm.expectRevert(CCBarsSale.OnlyOwner.selector);
        sale.transferBars(eve, _one(id));
        vm.stopPrank();
    }

    // promise: the whole inventory sells in one buy for exactly the sum of the asks into the pot, and the buyer's
    // melts release the 187,455 BALANCE inside
    function test_fullInventoryBuyThenMelt() public {
        uint256 due;
        for (uint256 i; i < held.length; ++i) due += _ask(held[i], 40_000);
        console.log("63 Bars at 4x, wei", due);
        assertEq(due, 5_113_446_618_908_231_520, "4 x 187,455 BALANCE at the pinned reference");
        core.book();
        uint256 pot0 = core.ethPot();
        vm.deal(buyer, due);
        vm.prank(buyer);
        assertEq(sale.buy{value: due}(held), due);
        assertEq(core.ethPot(), pot0 + due);
        assertEq(script.barsOf(address(sale)).length, 0);

        uint256 got;
        for (uint256 i; i < held.length; i += 10) {
            uint256 k = held.length - i < 10 ? held.length - i : 10;
            uint256[] memory batch = new uint256[](k);
            for (uint256 j; j < k; ++j) batch[j] = held[i + j];
            vm.prank(buyer);
            got += IBarsMeltAll(BARS).meltBatch(batch);
        }
        assertEq(got, 187_455 ether, "the BALANCE the vault paid for these Bars");
        assertEq(IErc20(BALANCE).balanceOf(buyer), 187_455 ether);
    }

    // promise: no sale while the controller's own protected quote is unusable, the gate of the Core's Credit sales
    function test_saleStopsWhenTheProtectedQuoteIsUnusable() public {
        // the live reference lifetime is 4,294,967,295 seconds; one second past it the controller's quote is stale
        IControllerV2 c = IControllerV2(core.controller());
        (,,, uint32 maxStale,,) = c.quote();
        (, bool usable) = c.valuePerPoint(true);
        assertTrue(usable, "usable at the pin");
        vm.warp(uint256(IControllerV2Time(address(c)).referenceTime()) + maxStale + 1);
        (, usable) = c.valuePerPoint(true);
        assertFalse(usable, "stale past the reference lifetime");
        vm.expectRevert(CCBarsSale.NoQuote.selector);
        sale.priceOf(held[0]);
        vm.prank(buyer);
        vm.expectRevert(CCBarsSale.NoQuote.selector);
        sale.buy{value: 1 ether}(_one(held[0]));
    }

    // promise: off means no sale; Bars not held here, other ERC721s and a re-entering refund are refused
    function test_guards() public {
        vm.prank(owner);
        sale.setOn(false);
        vm.prank(buyer);
        vm.expectRevert(CCBarsSale.SaleOff.selector);
        sale.buy{value: 1 ether}(_one(held[0]));
        vm.prank(owner);
        sale.setOn(true);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CCBarsSale.NotForSale.selector, 2935));
        sale.buy{value: 1 ether}(_one(2935));

        vm.expectRevert(CCBarsSale.OnlyBars.selector);
        sale.onERC721Received(buyer, buyer, 1, "");

        // the refund re-enters: the inner buy fails on the guard, the outer buy completes for one Bar only
        ReentrantBuyer r = new ReentrantBuyer(sale, held[0], held[1]);
        uint256 ask = sale.priceOf(held[0]);
        vm.deal(address(this), 1 ether);
        r.go{value: 1 ether}();
        assertEq(r.innerError(), abi.encodeWithSelector(CCBarsSale.Reentrant.selector), "the guard stopped the re-entry");
        assertEq(IBarsForSale(BARS).ownerOf(held[0]), address(r));
        assertEq(IBarsForSale(BARS).ownerOf(held[1]), address(sale), "the second Bar never moved");
        assertEq(address(r).balance, 1 ether - ask, "the refund arrived");
    }

    // promise: melting from the sale pays every released wei to the Core's balance module of the moment, and only the
    // owner melts
    function test_meltPaysTheCurrentModule() public {
        address module = ICoreForBarsSale(address(core)).balanceModule();
        assertEq(module, CCBarsVault(script.VAULT()).treasury(), "the v1 treasury is the module at the pin");
        uint256[] memory ids = new uint256[](10);
        uint256 sum;
        for (uint256 i; i < 10; ++i) {
            ids[i] = held[i];
            sum += held[i] * 1 ether;
        }
        vm.prank(makeAddr("eve"));
        vm.expectRevert(CCBarsSale.OnlyOwner.selector);
        sale.meltBars(ids);

        // 1 BALANCE sent to the sale directly goes to the module with the melt
        IPhase2BalanceTreasury treasury = IPhase2BalanceTreasury(module);
        vm.prank(owner);
        treasury.withdrawWorking(address(sale), 1 ether);
        uint256 custody0 = treasury.custody();
        uint256 free0 = treasury.freeWorking();
        vm.prank(owner);
        uint256 got = sale.meltBars(ids);
        assertEq(got, sum + 1 ether, "each Bar released its number in BALANCE, plus the stray");
        assertEq(treasury.custody(), custody0 + sum + 1 ether, "every melted wei in the module");
        assertEq(treasury.freeWorking(), free0 + sum + 1 ether, "as working funds");
        assertEq(IErc20(BALANCE).balanceOf(address(sale)), 0);
        assertEq(script.barsOf(address(sale)).length, 53);
    }
}

/// the sale across the pending phase 3 migration, run by the production Phase3 script on the same pinned fork
contract CCBarsSalePhase3Test is Test {
    uint256 internal constant FORK_BLOCK = 26494300;
    address internal constant BALANCE = 0x3620540c994433D7B4a628C46d2ED5F92572eA07;
    address internal constant BARS = 0x7d9EdeA03dD97361c3e21389B95bc327e22752aE;

    BarsSale internal script;
    Phase3 internal p3;
    ICoreView internal core;
    address internal owner;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), FORK_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);
        script = new BarsSale();
        p3 = new Phase3();
        core = ICoreView(script.CORE());
        owner = core.owner();
    }

    function _phase3() internal returns (Phase3.Deployed memory d) {
        d = p3.deploy(address(core), p3.params(), false);
        p3.migrate(address(core), d, p3.params(), false);
        assertEq(ICoreForBarsSale(address(core)).balanceModule(), d.treasury, "the module is v2");
        assertEq(core.controller(), d.controller, "the controller is V3");
    }

    // promise: a sale run before phase 3 keeps working after it: V3 prices the Bars, a buy funds the same Core's pot,
    // and a melt pays v2, not the migrated v1
    function test_saleThenPhase3MeltsIntoV2() public {
        CCBarsSale sale = script.execute(owner);
        uint256[] memory held = script.barsOf(address(sale));
        Phase3.Deployed memory d = _phase3();
        IBalanceTreasuryV2 v2 = IBalanceTreasuryV2(d.treasury);
        IPhase2BalanceTreasury v1 = IPhase2BalanceTreasury(CCBarsVault(script.VAULT()).treasury());

        uint256 ref = IControllerPrice(d.controller).referencePrice();
        (uint256 spot,) = IControllerPrice(d.controller).spotPrice();
        uint256 px = spot > ref ? spot : ref;
        uint256 ask = sale.priceOf(held[0]);
        assertEq(ask, FixedPointMathLib.mulDivUp(FixedPointMathLib.mulDivUp(held[0] * 1 ether, px, 1e18), 40_000, 10_000));
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1 ether);
        core.book();
        uint256 pot0 = core.ethPot();
        vm.prank(buyer);
        sale.buy{value: ask}(_ids(held[0]));
        assertEq(core.ethPot(), pot0 + ask, "the pot got the price under V3");

        uint256[] memory ids = new uint256[](10);
        uint256 sum;
        for (uint256 i; i < 10; ++i) {
            ids[i] = held[i + 1];
            sum += ids[i] * 1 ether;
        }
        uint256 custody2 = v2.custody();
        uint256 working2 = v2.working();
        uint256 custody1 = v1.custody();
        vm.prank(owner);
        assertEq(sale.meltBars(ids), sum);
        assertEq(v2.custody(), custody2 + sum, "every melted wei in v2");
        assertEq(v2.working(), working2 + sum, "as v2 working funds");
        assertEq(v1.custody(), custody1, "nothing to the migrated v1");
    }

    // promise: with the vault's leftover unreturned, the script stops before any send once phase 3 has run, and the
    // documented recovery (return to v1, withdraw to v2) lets it finish with the vault empty
    function test_scriptStopsAfterPhase3UntilTheLeftoverIsRecovered() public {
        Phase3.Deployed memory d = _phase3();
        uint256 leftover = IErc20(BALANCE).balanceOf(script.VAULT());
        assertEq(leftover, 541.789275702 ether);
        vm.expectRevert(bytes("the module is no longer v1: return the vault's BALANCE by hand first"));
        script.execute(owner);
        assertEq(script.saleAddress().code.length, 0, "nothing sent");

        IPhase2BalanceTreasury v1 = IPhase2BalanceTreasury(CCBarsVault(script.VAULT()).treasury());
        uint256 custody2 = IBalanceTreasuryV2(d.treasury).custody();
        vm.startPrank(owner);
        CCBarsVault(script.VAULT()).returnBalance();
        v1.withdrawWorking(d.treasury, leftover);
        vm.stopPrank();
        assertEq(IBalanceTreasuryV2(d.treasury).custody(), custody2 + leftover, "the leftover reached v2");

        CCBarsSale sale = script.execute(owner);
        assertEq(script.barsOf(address(sale)).length, 63);
        assertEq(IErc20(BALANCE).balanceOf(script.VAULT()), 0);
    }

    // promise: a Bar outside the scanned range in the vault stops the script before any send; after the owner moves
    // it out, the run finishes with the Bars contract counting zero in the vault
    function test_scriptStopsOnABarOutsideTheScan() public {
        uint256 stray = 2934;
        address holder = IBarsForSale(BARS).ownerOf(stray);
        address vault = script.VAULT();
        vm.prank(holder);
        IBarsForSale(BARS).safeTransferFrom(holder, vault, stray);
        vm.expectRevert(bytes("the vault holds Bars outside the scan: move them by hand"));
        script.execute(owner);
        assertEq(script.saleAddress().code.length, 0, "nothing sent");
        vm.prank(owner);
        CCBarsVault(vault).transferBars(owner, _ids(stray));
        script.execute(owner);
        assertEq(IErc721Bal(BARS).balanceOf(script.VAULT()), 0);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
