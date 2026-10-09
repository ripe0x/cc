// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane} from "../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../src/interfaces/AuctionHouse.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";

/// `setSuccessor`, `lockSuccessor` and `migrate` of the Core on the fork: the real Core, Credits, Statements, house and
/// pool, the stand in exit module and token, and `MigrationSink` as the successor
contract MigrateTest is Fixture {
    MigrationSink internal sink;
    address internal stranger = address(0x5757);

    /// the statements of `_world`: listed without a bid, listed with a live bid, sold with the record not settled, and
    /// held by the core on the exit lane
    struct World {
        uint256 listed;
        uint256 bidOn;
        uint256 sold;
        uint256 exitLane;
    }

    function setUp() public override {
        super.setUp();
        sink = new MigrationSink();
    }

    function _setSuccessor() internal {
        vm.prank(owner);
        core.setSuccessor(address(sink));
    }

    function _migrate(uint256 maxCredits) internal {
        vm.prank(owner);
        core.migrate(maxCredits);
    }

    function _listedStatement() internal returns (uint256 sid) {
        _fillEthPile(80);
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = supply + 1;
    }

    function _exitLaneStatement() internal returns (uint256 sid) {
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 1_000_000_000e18);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        uint256 supply = STATEMENTS.supply();
        core.composeExit();
        sid = supply + 1;
    }

    /// pots in both currencies, piles in both lanes, and one statement of each kind
    function _world() internal returns (World memory w) {
        _enterPhase2();
        _fundPot(3 ether);
        // the first eth lane statement exits, which fills the exit pots
        _fillExitBuyback();
        w.listed = _listedStatement();
        w.bidOn = _listedStatement();
        _bid(address(0xB1D), w.bidOn, _live(w.bidOn).reserve);
        w.sold = _listedStatement();
        _bid(address(0xB2D), w.sold, _live(w.sold).reserve);
        _endAuction(w.sold);
        // the proceeds of the sale are booked: half to the pot, half to the coin buyback pot
        _collectSales();
        w.exitLane = _exitLaneStatement();
        // credits left in both piles
        _fillEthPile(7);
        uint256[] memory ids = _credits(seller, 5);
        vm.prank(seller);
        core.sellForExitToken(ids);
    }

    function _heldCount() internal view returns (uint256) {
        return core.heldStatements().length;
    }

    // ------------------------------------------------------------------ the owner doors

    function test_OK_setSuccessorTakesACodeAddressOrZero() public {
        assertEq(core.successor(), address(0), "no successor at launch");
        assertFalse(core.successorLocked(), "unlocked at launch");
        vm.expectEmit(false, false, false, true, address(core));
        emit ICore.SuccessorSet(address(sink));
        _setSuccessor();
        assertEq(core.successor(), address(sink));
        vm.prank(owner);
        core.setSuccessor(address(0));
        assertEq(core.successor(), address(0));
        vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, address(0xE0A)));
        vm.prank(owner);
        core.setSuccessor(address(0xE0A));
    }

    function test_REVERT_migrateNeedsASuccessor() public {
        vm.expectRevert(ICore.NoSuccessor.selector);
        _migrate(10);
    }

    function test_OK_theLockClosesSetSuccessorAndKeepsMigrate() public {
        _setSuccessor();
        vm.expectEmit(false, false, false, true, address(core));
        emit ICore.SuccessorLocked();
        vm.prank(owner);
        core.lockSuccessor();
        assertTrue(core.successorLocked());
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("successor")));
        vm.prank(owner);
        core.setSuccessor(address(0));
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("successor")));
        vm.prank(owner);
        core.setSuccessor(address(sink));
        assertEq(core.successor(), address(sink), "the locked successor changed");
        _fundPot(1 ether);
        uint256 total = core.ethPot() + core.ethToBuyback();
        _migrate(10);
        assertEq(sink.ethReceived(), total, "migrate stopped working after the lock");
    }

    function test_OK_aLockWithAZeroSuccessorDisablesMigrateForGood() public {
        vm.prank(owner);
        core.lockSuccessor();
        assertTrue(core.successorLocked());
        assertEq(core.successor(), address(0));
        vm.expectRevert(ICore.NoSuccessor.selector);
        _migrate(10);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("successor")));
        vm.prank(owner);
        core.setSuccessor(address(sink));
        vm.expectRevert(ICore.NoSuccessor.selector);
        _migrate(10);
    }

    function test_REVERT_onlyTheOwner() public {
        _setSuccessor();
        vm.startPrank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setSuccessor(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.lockSuccessor();
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.migrate(10);
        vm.stopPrank();
        // the keeper and the creator have no power either
        vm.prank(keeper);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.migrate(10);
        assertFalse(core.successorLocked());
        assertEq(core.successor(), address(sink));
    }

    // ------------------------------------------------------------------ a full migration

    /// the record, house state and holder of a statement, as one hash
    function _fingerprint(uint256 sid) internal view returns (bytes32) {
        (bool held, Lane lane, uint256 cost, uint64 clockStart) = core.statementInfo(sid);
        return keccak256(abi.encode(held, lane, cost, clockStart, _live(sid), STATEMENTS.ownerOf(sid)));
    }

    function test_OK_potsAndCreditsMove() public {
        _world();
        _setSuccessor();

        uint256 pot = core.ethPot();
        uint256 buyback = core.ethToBuyback();
        uint256 xPot = core.xPot();
        uint256 xBuyback = core.xToBuyback();
        assertTrue(pot > 0 && buyback > 0 && xPot > 0 && xBuyback > 0, "setup: every pot holds something");
        uint256[] memory ethIds = core.pilePage(Lane.Eth, 0, 100);
        uint256[] memory exitIds = core.pilePage(Lane.Exit, 0, 100);
        assertEq(ethIds.length, 7, "setup: eth pile");
        assertEq(exitIds.length, 5, "setup: exit pile");
        uint256 balance = address(core).balance;
        uint256 xBalance = xt.balanceOf(address(core));
        uint256 coinBalance = coin.balanceOf(address(core));

        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), pot + buyback, xPot + xBuyback, 12);
        _migrate(1000);

        // eth: the sink got the trackers, the trackers are zero, the rest of the balance stays
        assertEq(sink.ethReceived(), pot + buyback, "the sink did not get the eth pots");
        assertEq(sink.sends(), 1, "one plain call");
        assertEq(core.ethPot(), 0, "ethPot");
        assertEq(core.ethToBuyback(), 0, "ethToBuyback");
        assertEq(address(core).balance, balance - pot - buyback, "the core balance");
        // exit token
        assertEq(xt.balanceOf(address(sink)), xPot + xBuyback, "the sink did not get the exit token");
        assertEq(core.xPot(), 0, "xPot");
        assertEq(core.xToBuyback(), 0, "xToBuyback");
        assertEq(xt.balanceOf(address(core)), xBalance - xPot - xBuyback, "the core exit token balance");
        // the coin stays
        assertEq(coin.balanceOf(address(core)), coinBalance, "the coin moved");
        // credits
        for (uint256 i; i < ethIds.length; ++i) {
            assertEq(CREDITS.ownerOf(ethIds[i]), address(sink), "an eth lane credit did not move");
            (bool inPile,,,) = core.creditInfo(ethIds[i]);
            assertFalse(inPile, "a moved credit is still in the pile");
            assertEq(core.pileNext(ethIds[i]), 0, "a moved credit still points to a next one");
        }
        for (uint256 i; i < exitIds.length; ++i) {
            assertEq(CREDITS.ownerOf(exitIds[i]), address(sink), "an exit lane credit did not move");
            (bool inPile,,,) = core.creditInfo(exitIds[i]);
            assertFalse(inPile, "a moved credit is still in the pile");
        }
        assertEq(core.pileSize(Lane.Eth), 0, "eth pile size");
        assertEq(core.pileSize(Lane.Exit), 0, "exit pile size");
        assertEq(core.pileHead(Lane.Eth), 0, "eth pile head");
        assertEq(core.pileHead(Lane.Exit), 0, "exit pile head");
        _solvent();
    }

    function test_OK_everyHeldStatementStaysAsItWas() public {
        World memory w = _world();
        _setSuccessor();
        uint256[4] memory sids = [w.listed, w.bidOn, w.sold, w.exitLane];
        bytes32[4] memory before;
        for (uint256 i; i < 4; ++i) {
            before[i] = _fingerprint(sids[i]);
        }
        uint256[] memory heldBefore = core.heldStatements();
        assertEq(heldBefore.length, 4, "setup: four statements on the books");
        _migrate(1000);
        for (uint256 i; i < 4; ++i) {
            assertEq(_fingerprint(sids[i]), before[i], "a statement changed");
        }
        uint256[] memory heldAfter = core.heldStatements();
        assertEq(heldAfter.length, heldBefore.length, "the held list changed");
        for (uint256 i; i < heldAfter.length; ++i) {
            assertEq(heldAfter[i], heldBefore[i], "the held order changed");
        }
        assertEq(STATEMENTS.ownerOf(w.listed), address(house), "the listing left the house");
        assertEq(STATEMENTS.ownerOf(w.exitLane), address(core), "the exit lane statement left the core");
        assertEq(STATEMENTS.ownerOf(w.sold), address(0xB2D), "the winner lost the statement");
        assertEq(STATEMENTS.balanceOf(address(sink)), 0, "a statement reached the successor");
    }

    function test_OK_theOldEngineSellsOutItsStatementsAndASecondMigrateMovesTheProceeds() public {
        World memory w = _world();
        _setSuccessor();
        _migrate(1000);
        uint256 ethBefore = sink.ethReceived();
        uint256 xBefore = xt.balanceOf(address(sink));
        // the auction with a bid ends and the sale settles
        _endAuction(w.bidOn);
        core.syncStatement(w.bidOn);
        core.syncStatement(w.sold);
        assertEq(_heldCount(), 2, "two statements left on the books");
        // a listing without a bid exits to the exit token
        vm.warp(block.timestamp + core.settings().exitAfter);
        // the pots are empty after the migration: the exit reimbursement of the caller clamps at the pot
        assertEq(core.ethPot(), 0, "setup: the eth pot is empty");
        vm.fee(composeBasefee);
        vm.txGasPrice(composeBasefee);
        uint256 callerBalance = address(this).balance;
        core.exitStatement(w.listed);
        core.exitStatement(w.exitLane);
        assertEq(core.ethPot(), 0, "the exit took eth from an empty pot");
        assertEq(address(this).balance, callerBalance, "the caller was repaid from an empty pot");
        assertEq(_heldCount(), 0, "the exits left nothing on the books");
        assertGt(core.xPot() + core.xToBuyback(), 0, "the exit did not fill the exit pots");
        // the proceeds of the sales are booked by collectSales and move in the next call
        _collectSales();
        uint256 booked = core.ethPot() + core.ethToBuyback();
        uint256 xBooked = core.xPot() + core.xToBuyback();
        assertGt(booked, 0, "the proceeds were booked");
        _migrate(1000);
        assertEq(sink.ethReceived(), ethBefore + booked, "the second call did not move the new eth");
        assertEq(xt.balanceOf(address(sink)), xBefore + xBooked, "the second call did not move the new exit token");
        assertEq(core.ethPot() + core.ethToBuyback(), 0, "pots are zero again");
        assertEq(core.xPot() + core.xToBuyback(), 0, "exit pots are zero again");
        assertEq(STATEMENTS.balanceOf(address(sink)), 0, "a statement reached the successor");
        // a call with nothing left to move does nothing
        uint256 sends = sink.sends();
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), 0, 0, 0);
        _migrate(1000);
        assertEq(sink.sends(), sends, "an empty call sent eth");
        _solvent();
    }

    function test_OK_sellToAfterAMigrationBooksTheProceeds() public {
        uint256 sid = _listedStatement();
        _setSuccessor();
        _migrate(1000);
        assertEq(core.ethPot() + core.ethToBuyback(), 0, "setup: the pots are empty");
        vm.prank(owner);
        ctl.setBuyOnly(true);
        uint256 price = ctl.priceOf(sid);
        vm.deal(address(0xB1D), price);
        vm.prank(address(0xB1D));
        ctl.buy{value: price}(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(0xB1D), "the buyer does not hold the statement");
        assertGt(core.ethPot(), 0, "the proceeds were not booked to the pot");
        assertGt(core.ethToBuyback(), 0, "the proceeds were not booked to the buyback pot");
        _solvent();
    }

    function test_OK_buybackAfterAMigrationCollectsWaitingSalesFirst() public {
        _fundPot(1 ether);
        _setSuccessor();
        _migrate(1000);
        assertEq(core.ethToBuyback(), 0, "setup: the buyback pot is empty");
        assertEq(_owedByHouse(), 0, "setup: no sale proceeds wait in the house");
        vm.roll(block.number + 200);
        vm.expectRevert(ICore.NothingToBuy.selector);
        core.buyback();
        // a sale ends and its proceeds wait in the house: the buyback collects them and spends the buyback share
        uint256 sid = _listedStatement();
        _bid(address(0xB1D), sid, _live(sid).reserve);
        _endAuction(sid);
        assertGt(_owedByHouse(), 0, "setup: the sale proceeds are uncollected");
        vm.roll(block.number + 200);
        core.buyback();
        assertEq(_owedByHouse(), 0, "the buyback left the proceeds in the house");
        assertGt(core.ethPot(), 0, "the pot share of the sale was not booked");
    }

    function test_OK_aListingWithoutABidStaysListedAndSells() public {
        uint256 sid = _listedStatement();
        bytes32 before = _fingerprint(sid);
        _setSuccessor();
        _migrate(10);
        assertEq(_fingerprint(sid), before, "the listing changed");
        assertEq(STATEMENTS.ownerOf(sid), address(house), "the statement left the house");
        _bid(address(0xB1D), sid, _live(sid).reserve);
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(0xB1D), "the bidder did not win");
        _collectSales();
        assertGt(core.ethPot() + core.ethToBuyback(), 0, "the sale was not booked");
    }

    function test_OK_batchesOfOneMoveOneCreditPerPileAtATime() public {
        _world();
        _setSuccessor();
        uint256 pot = core.ethPot() + core.ethToBuyback();
        uint256 eth0 = core.pileSize(Lane.Eth);
        uint256 exit0 = core.pileSize(Lane.Exit);
        uint256 held = _heldCount();
        _migrate(1);
        // eth and exit token are not batched: one call moves all of them
        assertEq(sink.ethReceived(), pot, "the first call moves all of the eth");
        assertEq(core.xPot() + core.xToBuyback(), 0, "the first call moves all of the exit token");
        assertEq(core.pileSize(Lane.Eth), eth0 - 1, "one eth credit per call");
        assertEq(core.pileSize(Lane.Exit), exit0 - 1, "one exit credit per call");
        assertEq(CREDITS.balanceOf(address(sink)), 2, "one credit per pile reached the successor");
        // a call drains the rest of the piles one by one
        uint256 calls = 1;
        while (core.pileSize(Lane.Eth) != 0 || core.pileSize(Lane.Exit) != 0) {
            _migrate(1);
            ++calls;
            assertLe(calls, eth0, "too many calls");
        }
        assertEq(calls, eth0, "the larger pile sets the number of calls");
        assertEq(CREDITS.balanceOf(address(core)), 0, "credits left in the core");
        assertEq(CREDITS.balanceOf(address(sink)), eth0 + exit0, "the successor holds every credit");
        assertEq(_heldCount(), held, "the statements changed");
    }

    function test_OK_aZeroBatchMovesOnlyThePots() public {
        _world();
        _setSuccessor();
        uint256 eth = core.ethPot() + core.ethToBuyback();
        uint256 x = core.xPot() + core.xToBuyback();
        uint256 held = _heldCount();
        uint256 ethPile = core.pileSize(Lane.Eth);
        uint256 exitPile = core.pileSize(Lane.Exit);
        _migrate(0);
        assertEq(sink.ethReceived(), eth);
        assertEq(xt.balanceOf(address(sink)), x);
        assertEq(core.pileSize(Lane.Eth), ethPile, "credits moved with a zero batch");
        assertEq(core.pileSize(Lane.Exit), exitPile, "credits moved with a zero batch");
        assertEq(_heldCount(), held, "statements changed with a zero batch");
    }

    function test_OK_forcedEthAboveTheTrackersStays() public {
        _fundPot(1 ether);
        _setSuccessor();
        uint256 tracked = core.ethPot() + core.ethToBuyback();
        vm.deal(address(core), address(core).balance + 1 ether);
        uint256 balance = address(core).balance;
        _migrate(10);
        assertEq(sink.ethReceived(), tracked);
        assertEq(address(core).balance, balance - tracked, "the forced eth moved");
        // skim books it, and the next call moves it
        core.skim();
        assertGe(core.ethPot(), 1 ether - 1, "skim did not book the forced eth");
        _migrate(10);
        assertGe(sink.ethReceived(), tracked + 1 ether - 1, "the booked eth did not move");
    }

    // ------------------------------------------------------------------ a successor that misbehaves

    function test_REVERT_aSuccessorThatRefusesEthLeavesEverythingInPlace() public {
        _world();
        _setSuccessor();
        sink.setRefuse(true);
        uint256 pot = core.ethPot();
        uint256 held = _heldCount();
        uint256 ethPile = core.pileSize(Lane.Eth);
        uint256 x = core.xPot();
        vm.expectRevert(ICore.CallFailed.selector);
        _migrate(100);
        assertEq(core.ethPot(), pot, "pot changed");
        assertEq(core.xPot(), x, "exit pot changed");
        assertEq(core.pileSize(Lane.Eth), ethPile, "pile changed");
        assertEq(_heldCount(), held, "statements changed");
        // the owner points at another successor
        MigrationSink other = new MigrationSink();
        vm.prank(owner);
        core.setSuccessor(address(other));
        _migrate(100);
        assertGt(other.ethReceived(), 0);
    }

    function test_OK_aSuccessorThatCallsBackIsRefused() public {
        _fundPot(1 ether);
        // the successor is the owner and tries to run `migrate` again from its `receive`
        vm.prank(owner);
        core.transferOwnership(address(sink));
        sink.exec(address(core), abi.encodeCall(ICore.acceptOwnership, ()));
        sink.exec(address(core), abi.encodeCall(ICore.setSuccessor, (address(sink))));
        sink.setCall(address(core), abi.encodeCall(ICore.migrate, (10)));
        uint256 total = core.ethPot() + core.ethToBuyback();
        (bool ok,) = sink.exec(address(core), abi.encodeCall(ICore.migrate, (10)));
        assertTrue(ok, "the outer migrate failed");
        assertTrue(sink.called(), "the sink did not call back");
        assertFalse(sink.calledOk(), "the nested migrate went through");
        assertEq(bytes4(sink.calledOut()), bytes4(0xab143c06), "not the reentrancy error");
        assertEq(sink.ethReceived(), total);
    }

    // ------------------------------------------------------------------ the engine afterwards

    function test_OK_theEngineKeepsWorkingAfterAMigration() public {
        _world();
        _setSuccessor();
        _migrate(1000);
        assertEq(core.ethPot(), 0);
        // fees arrive and are booked
        _buyCoin(funder, 3 ether);
        assertGt(core.ethPot(), 0, "fees were not booked after a migration");
        // credits are bought again, piles grow, a statement composes
        _fillEthPile(80);
        assertEq(core.pileSize(Lane.Eth), 80, "the eth pile");
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.ownerOf(supply + 1), address(house), "the composed statement is not on the house");
        // a sale on the house books proceeds again, and the coin buyback runs on its share
        uint256 sold = _listedStatement();
        _bid(address(0xB3D), sold, _live(sold).reserve);
        _endAuction(sold);
        _collectSales();
        assertGt(core.ethToBuyback(), 0, "the buyback share was not booked");
        vm.roll(block.number + 200);
        core.buyback();
        // what arrived after the first call moves in the next one
        uint256 before = sink.ethReceived();
        uint256 booked = core.ethPot() + core.ethToBuyback();
        _migrate(1000);
        assertEq(sink.ethReceived(), before + booked, "the new eth did not move");
        _solvent();
    }

    // ------------------------------------------------------------------ the successor address

    function test_REVERT_theSuccessorIsNotPartOfTheEngine() public {
        _enterPhase2();
        address[8] memory bad = [
            address(core),
            address(house),
            address(feeRouter),
            address(coin),
            address(CREDITS),
            address(STATEMENTS),
            address(mod),
            address(xt)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ICore.BadSuccessor.selector, bad[i]));
            vm.prank(owner);
            core.setSuccessor(bad[i]);
        }
        assertEq(core.successor(), address(0), "a refused address was stored");
    }

    // ------------------------------------------------------------------ the hourly window

    function _word(uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(address(core), bytes32(slot)));
    }

    function test_OK_aSellAfterAMigrationOpensANewWindow() public {
        _fundPot(3 ether);
        uint256[] memory first = _credits(seller, 2);
        vm.prank(seller);
        core.sellForEth(first);
        assertGt(_word(12), 0, "setup: the window has a pot");
        assertGt(_word(13), 0, "setup: the window has spending");
        _setSuccessor();
        _migrate(10);
        assertEq(_word(11) >> 128, 0, "windowStart");
        assertEq(_word(12), 0, "windowPot");
        assertEq(_word(13), 0, "windowSpent");
        // fees refill the pot and a sale in the same hour spends against the pot it finds
        _fundPot(1 ether);
        uint256 pot = core.ethPot();
        uint256[] memory second = _credits(seller, 1);
        uint256 price = core.ceilingOf(second[0]);
        vm.prank(seller);
        core.sellForEth(second);
        assertEq(_word(12), pot, "the new window opens on the new pot");
        assertEq(_word(13), price, "the new window spent the sale");
        assertEq(_word(11) >> 128, block.timestamp, "the new window starts now");
    }

    // ------------------------------------------------------------------ gas

    function _gasOf(uint256 maxCredits) internal returns (uint256 used) {
        vm.prank(owner);
        uint256 g = gasleft();
        core.migrate(maxCredits);
        used = g - gasleft();
    }

    function test_GAS_migrateEightyCreditsPerPile() public {
        _enterPhase2();
        _fundPot(2 ether);
        _fillEthPile(80);
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 1_000_000_000e18);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        assertEq(core.pileSize(Lane.Eth), 80, "setup: eighty eth lane credits");
        assertEq(core.pileSize(Lane.Exit), 80, "setup: eighty exit lane credits");
        _setSuccessor();
        uint256 snap = vm.snapshotState();

        uint256 pots = _gasOf(0);
        vm.revertToState(snap);
        uint256 credits40 = _gasOf(40);
        vm.revertToState(snap);
        uint256 credits80 = _gasOf(80);
        emit log_named_uint("gas: migrate(0), the pots only", pots);
        emit log_named_uint("gas: migrate(40), 40 credits per pile", credits40);
        emit log_named_uint("gas: migrate(80), 80 credits per pile", credits80);
        uint256 perCredit = (credits80 - credits40) / 80;
        emit log_named_uint("gas per credit", perCredit);
        emit log_named_uint("largest maxCredits under 16777216", (16_777_216 - pots) / (2 * perCredit));
        assertLt(credits80, 16_777_216, "80 credits per pile fit the transaction cap");
    }
}
