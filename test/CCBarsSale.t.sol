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

/// a buyer whose refund re-enters the sale
contract ReentrantBuyer {
    CCBarsSale internal immutable sale;
    uint256[] internal ids;

    constructor(CCBarsSale sale_, uint256 id) {
        sale = sale_;
        ids.push(id);
    }

    function go() external payable {
        sale.buy{value: msg.value}(ids);
    }

    receive() external payable {
        sale.buy{value: msg.value}(ids);
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

        ReentrantBuyer r = new ReentrantBuyer(sale, held[0]);
        vm.deal(address(this), 2 ether);
        vm.expectRevert();
        r.go{value: 1 ether}();
        assertEq(IBarsForSale(BARS).ownerOf(held[0]), address(sale), "the reverted buy moved nothing");
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

        IPhase2BalanceTreasury treasury = IPhase2BalanceTreasury(module);
        uint256 custody0 = treasury.custody();
        uint256 free0 = treasury.freeWorking();
        vm.prank(owner);
        uint256 got = sale.meltBars(ids);
        assertEq(got, sum, "each Bar released its number in BALANCE");
        assertEq(treasury.custody(), custody0 + sum, "every melted wei in the module");
        assertEq(treasury.freeWorking(), free0 + sum, "as working funds");
        assertEq(IErc20(BALANCE).balanceOf(address(sale)), 0);
        assertEq(script.barsOf(address(sale)).length, 53);
    }
}
