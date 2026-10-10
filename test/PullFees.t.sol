// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {CoreBase} from "./CoreUnit.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {Lane, ICreditStrategy} from "../src/interfaces/Interfaces.sol";
import {RefusingEngine, GasBurnerEngine} from "./attackers/FlushEngines.sol";
import {RevertingRouter} from "./attackers/RevertingRouter.sol";
import {GasBurningPayee, ContractSeller} from "./attackers/GasBurners.sol";

/// the Core pulls the fee router's balance at the start of its eth pot entry points (`sellForEth`, `buyListing`,
/// `compose`). real pool, real router, real credits. the router is loaded with `vm.deal`, which is the state a swap
/// leaves it in
contract PullFeesTest is CoreBase {
    uint256 internal constant LOAD = 1 ether;

    function setUp() public override {
        super.setUp();
        // the first flush at the split start turns the split on, so later flushes pay the payee as in steady state. a small
        // amount keeps the pot small
        _skipToSplitStart();
        vm.deal(address(feeRouter), 1 gwei);
        _flush();
        assertTrue(feeRouter.splitOn(), "split on");
        assertEq(address(feeRouter).balance, 0);
    }

    struct Parts {
        uint256 shared;
        uint256 toBuyback;
        uint256 toPot;
    }

    /// what `flush` does with `amount` now: payee shares, the engine part and its split into buyback and pot
    function _parts(uint256 amount) internal view returns (Parts memory x) {
        (, uint32[] memory ppm) = feeRouter.payees();
        for (uint256 i; i < ppm.length; ++i) {
            x.shared += amount * ppm[i] / 1_000_000;
        }
        uint256 toEngine = amount - x.shared;
        x.toBuyback = toEngine * core.settings().feeToBuybackBps / 10_000;
        x.toPot = toEngine - x.toBuyback;
    }

    function _payeeBalance() internal view returns (uint256) {
        (address[] memory who,) = feeRouter.payees();
        return who[0].balance;
    }

    function _load() internal {
        vm.deal(address(feeRouter), LOAD);
    }

    // ------------------------------------------------------------------ sellForEth

    struct Sold {
        uint256 got;
        uint256 pot;
        uint256 buyback;
    }

    /// sells `ids` as alice. returns what alice received, the pot and the buyback pot after
    function _sell(uint256[] memory ids) internal returns (Sold memory r) {
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(ids);
        r = Sold(alice.balance - before, core.ethPot(), core.ethToBuyback());
    }

    /// the router is flushed before the price is read: the seller is paid from the enlarged pot at the checkpointed
    /// price, the payee and the seller get their parts, the rest is booked. the outcome equals a keeper flush followed
    /// by the sale
    function test_sellPullsTheRouterBeforeThePriceIsRead() public {
        uint256[] memory ids = _credits(alice, 1);
        _fund(0.001 ether);
        uint256 snap = vm.snapshotState();

        // control: nothing in the router
        Sold memory empty = _sell(ids);
        vm.revertToState(snap);

        // a keeper flushes first, then the sale
        _load();
        _flush();
        Sold memory keeperFlush = _sell(ids);
        vm.revertToState(snap);

        // the sale pulls
        _load();
        Parts memory x = _parts(LOAD);
        uint256 payeeBefore = _payeeBalance();
        uint256 buybackBefore = core.ethToBuyback();
        Sold memory pulled = _sell(ids);

        assertEq(address(feeRouter).balance, 0, "router emptied");
        assertEq(_payeeBalance() - payeeBefore, x.shared, "payee share");
        assertEq(pulled.buyback - buybackBefore, x.toBuyback, "buyback part booked");
        assertEq(pulled.got, keeperFlush.got, "the seller is paid what a keeper flush then a sale pays");
        assertEq(pulled.pot, keeperFlush.pot, "same pot");
        assertEq(pulled.buyback, keeperFlush.buyback, "same buyback pot");
        assertGt(pulled.got, empty.got, "the enlarged pot lifts the clamped price");
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
    }

    /// the caller of the Core receives the sale price: the flush output goes to the payees and the Core
    function test_sellPaysTheCallerOnlyThePrice() public {
        uint256[] memory ids = _credits(alice, 1);
        _fund(1 ether);
        _load();
        uint256 flusherBefore = flusher.balance;
        uint256 keeperBefore = keeper.balance;
        uint256 before = alice.balance;
        vm.recordLogs();
        vm.prank(alice);
        core.sellForEth(ids);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 sold;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ICore.CreditBought.selector) {
                (, sold) = abi.decode(logs[i].data, (uint8, uint256));
            }
        }
        assertEq(alice.balance - before, sold, "the seller gets the price");
        assertEq(flusher.balance, flusherBefore);
        assertEq(keeper.balance, keeperBefore);
    }

    /// an empty router costs the sale nothing but the call: no Flushed event and no FeesAdded
    function test_sellWithAnEmptyRouterBooksNoFees() public {
        uint256[] memory ids = _credits(alice, 1);
        _fund(1 ether);
        vm.recordLogs();
        vm.prank(alice);
        core.sellForEth(ids);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IFeeRouter.Flushed.selector, "no flush");
            assertTrue(logs[i].topics[0] != ICore.FeesAdded.selector, "no fees");
        }
    }

    /// gas of one credit sale for an empty router and for 1 eth in it. printed, pinned within a tolerance
    function test_gasOfThePullOnOneCredit() public {
        uint256[] memory ids = _credits(alice, 2);
        _fund(2 ether);
        uint256 snap = vm.snapshotState();
        uint256[] memory one = new uint256[](1);
        one[0] = ids[0];

        uint256 g = gasleft();
        vm.prank(alice);
        core.sellForEth(one);
        uint256 empty = g - gasleft();
        vm.revertToState(snap);

        _load();
        g = gasleft();
        vm.prank(alice);
        core.sellForEth(one);
        uint256 loaded = g - gasleft();
        emit log_named_uint("gas sellForEth 1 credit, router empty", empty);
        emit log_named_uint("gas sellForEth 1 credit, router 1 eth", loaded);
        // the figures of docs/FLOW.md 10.8
        assertApproxEqAbs(empty, 394_372, 5_000, "gas, router empty");
        assertApproxEqAbs(loaded - empty, 61_195, 5_000, "gas of the flush");
        assertEq(address(feeRouter).balance, 0);
    }

    /// gas of one call of a pulling door, from the same state with an empty router and with `LOAD` in it. printed
    function _doorGas(string memory name, address who, bytes memory data) internal returns (uint256 empty, uint256 loaded) {
        uint256 snap = vm.snapshotState();
        vm.prank(who);
        uint256 g = gasleft();
        (bool ok,) = address(core).call(data);
        empty = g - gasleft();
        assertTrue(ok, "door, router empty");
        vm.revertToState(snap);
        _load();
        vm.prank(who);
        g = gasleft();
        (ok,) = address(core).call(data);
        loaded = g - gasleft();
        assertTrue(ok, "door, router loaded");
        assertEq(address(feeRouter).balance, 0, "the door pulled");
        emit log_named_uint(string.concat("gas ", name, ", router empty"), empty);
        emit log_named_uint(string.concat("gas ", name, ", router 1 eth"), loaded);
    }

    function test_gasOfThePullPerDoor_sellForEth() public {
        uint256[] memory ids = _credits(alice, 1);
        _fund(1 ether);
        _doorGas("sellForEth", alice, abi.encodeWithSignature("sellForEth(uint256[])", ids));
    }

    function test_gasOfThePullPerDoor_buyListing() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _fund(10 ether);
        _warpUntilCeiling(LISTED_A, price);
        _doorGas("buyListing", keeper, abi.encodeCall(core.buyListing, (price, _listing(LISTED_A), LISTED_A, STRATEGY)));
    }

    function test_gasOfThePullPerDoor_compose() public {
        uint256 size = core.pileSize(Lane.Eth);
        if (size < 80) _fillEthPile(80 - size);
        vm.fee(composeBasefee);
        _doorGas("compose", keeper, abi.encodeCall(core.compose, ()));
    }

    function test_gasOfThePullPerDoor_composeExit() public {
        _enterPhase2();
        _fillExitBuyback();
        xt.mint(address(core), 100e18);
        core.skim();
        uint256[] memory ids = _credits(alice, 80);
        vm.prank(alice);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        _doorGas("composeExit", keeper, abi.encodeCall(core.composeExit, ()));
    }

    function test_gasOfThePullPerDoor_adopt() public {
        uint256[] memory ids = _credits(alice, 1);
        vm.prank(alice);
        CREDITS.transferFrom(alice, address(core), ids[0]);
        _doorGas("adopt", alice, abi.encodeCall(core.adopt, (ids)));
    }

    // ------------------------------------------------------------------ buyListing

    /// reads the cost and tip of the `ListingBought` event
    function _listingBought(Vm.Log[] memory logs) internal pure returns (uint256 cost, uint256 tip) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ICore.ListingBought.selector) {
                (cost, tip,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
    }

    /// the pull comes before the measured window: the measured cost is the listing price and the cost basis is not
    /// understated by the flushed amount
    function test_buyListingPullsOutsideTheMeasuredWindow() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _fund(10 ether);
        _warpUntilCeiling(LISTED_A, price);
        _load();
        Parts memory x = _parts(LOAD);
        uint256 pot = core.ethPot();
        uint256 buyback = core.ethToBuyback();
        uint256 payeeBefore = _payeeBalance();
        uint256 keeperBefore = keeper.balance;

        vm.recordLogs();
        vm.prank(keeper);
        core.buyListing(price, _listing(LISTED_A), LISTED_A, STRATEGY);
        (uint256 cost, uint256 buyTip) = _listingBought(vm.getRecordedLogs());

        assertEq(cost, price, "the measured cost is the listing price");
        assertEq(address(feeRouter).balance, 0, "router emptied");
        assertEq(_payeeBalance() - payeeBefore, x.shared, "payee share");
        assertEq(keeper.balance - keeperBefore, buyTip, "the buy tip to the buyer");
        assertEq(core.ethToBuyback() - buyback, x.toBuyback);
        assertEq(core.ethPot(), pot + x.toPot - price - buyTip, "the pot took the fees and paid the purchase");
        (,, uint256 basis,) = core.creditInfo(LISTED_A);
        assertEq(basis, price + buyTip, "cost basis is price plus tip");
    }

    // ------------------------------------------------------------------ compose

    function test_composePullsAndPaysTheCallerNothing() public {
        uint256 size = core.pileSize(Lane.Eth);
        if (size < 80) _fillEthPile(80 - size);
        vm.fee(composeBasefee);
        _load();
        Parts memory x = _parts(LOAD);
        uint256 pot = core.ethPot();
        uint256 buyback = core.ethToBuyback();
        uint256 payeeBefore = _payeeBalance();
        uint256 keeperBefore = keeper.balance;
        uint256 supply = STATEMENTS.supply();

        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.supply(), supply + 1, "composed");
        assertEq(address(feeRouter).balance, 0, "router emptied");
        assertEq(_payeeBalance() - payeeBefore, x.shared, "payee share");
        assertEq(core.ethToBuyback() - buyback, x.toBuyback);
        assertEq(keeper.balance, keeperBefore, "no gas repayment to the caller");
        assertEq(core.ethPot(), pot + x.toPot, "the pot took the fees");
    }

    // ------------------------------------------------------------------ a router that fails

    /// a router that reverts on every call does not block the door
    function test_aRevertingRouterDoesNotBlockTheDoor() public {
        address src = core.FEE_SOURCE();
        vm.etch(src, address(new RevertingRouter()).code);
        uint256[] memory ids = _credits(alice, 1);
        _fund(1 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(ids);
        assertGt(alice.balance, before, "paid");
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
    }

    /// a router address without code is a call that does nothing
    function test_aRouterWithoutCodeDoesNotBlockTheDoor() public {
        vm.etch(core.FEE_SOURCE(), "");
        uint256[] memory ids = _credits(alice, 1);
        _fund(1 ether);
        uint256 pot = core.ethPot();
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(ids);
        uint256 paid = alice.balance - before;
        assertGt(paid, 0, "paid");
        assertEq(core.ethPot(), pot - paid, "the pot paid exactly the price");
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "balance equals the pots");
    }

    /// the real router with an engine that refuses the eth: the flush fails whole, the door still works and the fees
    /// stay in the router
    function test_aRouterWhoseEngineRefusesLeavesTheFeesAndTheDoorWorks() public {
        RefusingEngine bad = new RefusingEngine();
        vm.prank(feeRouter.owner());
        feeRouter.setEngine(address(bad));
        _load();
        uint256[] memory ids = _credits(alice, 1);
        _fund(1 ether);
        uint256 pot = core.ethPot();
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(ids);
        assertGt(alice.balance, before, "paid");
        assertEq(address(feeRouter).balance, LOAD, "fees wait in the router");
        assertLt(core.ethPot(), pot, "the pot paid the sale");
    }

    /// an engine that burns all the gas it is given costs the door at most the pull gas: the door still completes
    function test_anEngineThatBurnsGasDoesNotBlockTheDoor() public {
        GasBurnerEngine burner = new GasBurnerEngine();
        vm.prank(feeRouter.owner());
        feeRouter.setEngine(address(burner));
        _load();
        uint256[] memory ids = _credits(alice, 1);
        _fund(1 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth{gas: 3_000_000}(ids);
        assertGt(alice.balance, before, "paid");
        assertEq(address(feeRouter).balance, LOAD, "fees wait in the router");
    }

    /// the most expensive flush: the split just turned on, four payees that burn all the gas they are given (each is
    /// credited as owed after 100,000 gas). printed and
    /// bounded, the door that pulls it still completes
    function test_worstCaseFlushGasAndTheDoorCompletes() public {
        address[] memory who = new address[](4);
        uint32[] memory ppm = new uint32[](4);
        for (uint256 i; i < 4; ++i) {
            who[i] = address(new GasBurningPayee());
            ppm[i] = 50_000;
        }
        vm.prank(feeRouter.owner());
        feeRouter.setPayees(who, ppm);
        ContractSeller caller = new ContractSeller(address(core));
        uint256[] memory ids = _credits(address(caller), 1);
        _fund(1 ether);
        _load();
        uint256 snap = vm.snapshotState();

        uint256 g = gasleft();
        feeRouter.flush();
        uint256 flushGas = g - gasleft();
        emit log_named_uint("worst case flush gas", flushGas);
        assertLe(flushGas, 800_000, "worst case flush gas");
        assertGt(flushGas, 600_000, "the burning paths ran");
        assertEq(address(feeRouter).balance, feeRouter.totalOwed(), "the burned shares are owed");
        vm.revertToState(snap);

        caller.sell(ids);
        assertGt(address(caller).balance, 0, "the sale paid the caller");
        assertEq(address(feeRouter).balance, feeRouter.totalOwed(), "pulled, burned shares owed");
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "fees booked");
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
    }

    /// a keeper `flush` delivers the fees, and the door that follows finds an empty router
    function test_aKeeperFlushStillWorks() public {
        _load();
        uint256 toCore = _flush();
        assertGt(toCore, 0, "the keeper path delivers");
        uint256[] memory ids = _credits(alice, 1);
        _fund(1 ether);
        vm.prank(alice);
        core.sellForEth(ids);
        assertEq(address(feeRouter).balance, 0);
    }
}
