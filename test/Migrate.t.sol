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

    function _migrate(uint256 maxCredits, uint256 maxStatements) internal {
        vm.prank(owner);
        core.migrate(maxCredits, maxStatements);
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
        _migrate(10, 10);
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
        _migrate(10, 10);
        assertEq(sink.ethReceived(), total, "migrate stopped working after the lock");
    }

    function test_OK_aLockWithAZeroSuccessorDisablesMigrateForGood() public {
        vm.prank(owner);
        core.lockSuccessor();
        assertTrue(core.successorLocked());
        assertEq(core.successor(), address(0));
        vm.expectRevert(ICore.NoSuccessor.selector);
        _migrate(10, 10);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("successor")));
        vm.prank(owner);
        core.setSuccessor(address(sink));
        vm.expectRevert(ICore.NoSuccessor.selector);
        _migrate(10, 10);
    }

    function test_REVERT_onlyTheOwner() public {
        _setSuccessor();
        vm.startPrank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setSuccessor(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.lockSuccessor();
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.migrate(10, 10);
        vm.stopPrank();
        // the keeper and the creator have no power either
        vm.prank(keeper);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.migrate(10, 10);
        assertFalse(core.successorLocked());
        assertEq(core.successor(), address(sink));
    }

    // ------------------------------------------------------------------ a full migration

    function test_OK_everythingMovesExceptWhatCannot() public {
        World memory w = _world();
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
        assertEq(_heldCount(), 4, "setup: four statements on the books");
        uint256 balance = address(core).balance;
        uint256 xBalance = xt.balanceOf(address(core));
        uint256 coinBalance = coin.balanceOf(address(core));

        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), pot + buyback, 12, 2, xPot + xBuyback, 2);
        _migrate(1000, 1000);

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
        // statements: the listed one and the exit lane one moved, the one with a bid and the unsettled sale stayed
        assertEq(STATEMENTS.ownerOf(w.listed), address(sink), "the listed statement did not move");
        assertEq(STATEMENTS.ownerOf(w.exitLane), address(sink), "the exit lane statement did not move");
        (bool held,,,) = core.statementInfo(w.listed);
        assertFalse(held, "a moved statement is still on the books");
        (held,,,) = core.statementInfo(w.exitLane);
        assertFalse(held, "a moved statement is still on the books");
        assertEq(STATEMENTS.ownerOf(w.bidOn), address(house), "the statement with a bid left the house");
        ICore.StatementStatus st = _live(w.bidOn).status;
        assertTrue(
            st == ICore.StatementStatus.Bid || st == ICore.StatementStatus.Ended, "the auction with a bid was disturbed"
        );
        assertEq(house.getAuction(_live(w.bidOn).auctionId).bidder, address(0xB1D), "the bid was disturbed");
        assertEq(STATEMENTS.ownerOf(w.sold), address(0xB2D), "the winner lost the statement");
        (held,,,) = core.statementInfo(w.sold);
        assertTrue(held, "the stale record of the sale was cleared by the migration");
        (held,,,) = core.statementInfo(w.bidOn);
        assertTrue(held, "the record of the statement with a bid was cleared");
        assertEq(_heldCount(), 2, "two statements stay on the books");
        _solvent();
    }

    function test_OK_aSecondCallFinishesWhatTheFirstLeft() public {
        World memory w = _world();
        _setSuccessor();
        _migrate(1000, 1000);
        // the sale settles and the bid statement ends: both are now plain sales, the books are cleared by sync
        _endAuction(w.bidOn);
        core.syncStatement(w.bidOn);
        core.syncStatement(w.sold);
        assertEq(_heldCount(), 0, "nothing left on the books");
        uint256 ethBefore = sink.ethReceived();
        // the proceeds of the two sales are booked by collectSales and move in the next call
        _collectSales();
        uint256 booked = core.ethPot() + core.ethToBuyback();
        assertGt(booked, 0, "the proceeds were booked");
        _migrate(1000, 1000);
        assertEq(sink.ethReceived(), ethBefore + booked, "the second call did not move the new eth");
        assertEq(core.ethPot() + core.ethToBuyback(), 0, "pots are zero again");
        // a call with nothing left to move does nothing
        uint256 sends = sink.sends();
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), 0, 0, 0, 0, 0);
        _migrate(1000, 1000);
        assertEq(sink.sends(), sends, "an empty call sent eth");
    }

    function test_OK_batchesOfOneMoveOneAtATime() public {
        World memory w = _world();
        _setSuccessor();
        uint256 pot = core.ethPot() + core.ethToBuyback();
        uint256 eth0 = core.pileSize(Lane.Eth);
        uint256 exit0 = core.pileSize(Lane.Exit);
        _migrate(1, 1);
        // eth and exit token are not batched: one call moves all of them
        assertEq(sink.ethReceived(), pot, "the first call moves all of the eth");
        assertEq(core.xPot() + core.xToBuyback(), 0, "the first call moves all of the exit token");
        assertEq(core.pileSize(Lane.Eth), eth0 - 1, "one eth credit per call");
        assertEq(core.pileSize(Lane.Exit), exit0 - 1, "one exit credit per call");
        // the scan starts at the end of the held list: the exit lane statement is the last one composed
        assertEq(STATEMENTS.ownerOf(w.exitLane), address(sink), "one statement per call");
        assertEq(_heldCount(), 3, "one statement moved");
        // the scan stops after one skipped statement, so a batch of one never gets past the sold one at the end of the
        // list. a batch larger than the skipped statements reaches the listed one
        _migrate(1, 1);
        assertEq(_heldCount(), 3, "the scan stopped at the first skipped statement");
        _migrate(1, 3);
        assertEq(STATEMENTS.ownerOf(w.listed), address(sink), "the second call moves the next movable statement");
        assertEq(_heldCount(), 2, "two statements stay");
        assertEq(core.pileSize(Lane.Eth), eth0 - 3);
        // a call drains the rest of the piles one by one
        uint256 calls = 3;
        while (core.pileSize(Lane.Eth) != 0 || core.pileSize(Lane.Exit) != 0) {
            _migrate(1, 1);
            ++calls;
            assertLe(calls, eth0 + 1, "too many calls");
        }
        assertEq(calls, eth0, "the larger pile sets the number of calls");
        assertEq(CREDITS.balanceOf(address(core)), 0, "credits left in the core");
        assertEq(_heldCount(), 2, "the skipped statements stay");
    }

    function test_OK_aLiveBidIsSkippedAndCounted() public {
        uint256 sid = _listedStatement();
        _bid(address(0xB1D), sid, _live(sid).reserve);
        _setSuccessor();
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), core.ethPot() + core.ethToBuyback(), 0, 0, 0, 1);
        _migrate(10, 10);
        assertEq(STATEMENTS.ownerOf(sid), address(house), "the statement left the house");
        ICore.StatementStatus st = _live(sid).status;
        assertEq(uint256(st), uint256(ICore.StatementStatus.Bid), "the bid is gone");
        // the auction still runs to its end and sells
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(0xB1D), "the bidder did not win");
    }

    function test_OK_aListingWithoutABidIsTakenBackAndMoved() public {
        uint256 sid = _listedStatement();
        (, uint256 auctionId,,,) = core.statementStatus(sid);
        _setSuccessor();
        _migrate(0, 10);
        assertEq(STATEMENTS.ownerOf(sid), address(sink), "the statement did not reach the successor");
        (bool exists,) = house.getAuctionFor(address(STATEMENTS), sid);
        assertFalse(exists, "the house still has an auction for it");
        assertEq(house.getAuction(auctionId).tokenOwner, address(0), "the auction record is not gone");
        assertEq(_heldCount(), 0);
    }

    function test_OK_aZeroBatchMovesOnlyTheEthAndTheExitToken() public {
        _world();
        _setSuccessor();
        uint256 eth = core.ethPot() + core.ethToBuyback();
        uint256 held = _heldCount();
        uint256 ethPile = core.pileSize(Lane.Eth);
        _migrate(0, 0);
        assertEq(sink.ethReceived(), eth);
        assertEq(core.pileSize(Lane.Eth), ethPile, "credits moved with a zero batch");
        assertEq(_heldCount(), held, "statements moved with a zero batch");
    }

    function test_OK_forcedEthAboveTheTrackersStays() public {
        _fundPot(1 ether);
        _setSuccessor();
        uint256 tracked = core.ethPot() + core.ethToBuyback();
        vm.deal(address(core), address(core).balance + 1 ether);
        uint256 balance = address(core).balance;
        _migrate(10, 10);
        assertEq(sink.ethReceived(), tracked);
        assertEq(address(core).balance, balance - tracked, "the forced eth moved");
        // skim books it, and the next call moves it
        core.skim();
        assertGe(core.ethPot(), 1 ether - 1, "skim did not book the forced eth");
        _migrate(10, 10);
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
        _migrate(100, 100);
        assertEq(core.ethPot(), pot, "pot changed");
        assertEq(core.xPot(), x, "exit pot changed");
        assertEq(core.pileSize(Lane.Eth), ethPile, "pile changed");
        assertEq(_heldCount(), held, "statements changed");
        // the owner points at another successor
        MigrationSink other = new MigrationSink();
        vm.prank(owner);
        core.setSuccessor(address(other));
        _migrate(100, 100);
        assertGt(other.ethReceived(), 0);
    }

    function test_OK_aSuccessorThatCallsBackIsRefused() public {
        _fundPot(1 ether);
        // the successor is the owner and tries to run `migrate` again from its `receive`
        vm.prank(owner);
        core.transferOwnership(address(sink));
        sink.exec(address(core), abi.encodeCall(ICore.acceptOwnership, ()));
        sink.exec(address(core), abi.encodeCall(ICore.setSuccessor, (address(sink))));
        sink.setCall(address(core), abi.encodeCall(ICore.migrate, (10, 10)));
        uint256 total = core.ethPot() + core.ethToBuyback();
        (bool ok,) = sink.exec(address(core), abi.encodeCall(ICore.migrate, (10, 10)));
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
        _migrate(1000, 1000);
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
        _migrate(1000, 1000);
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

    // ------------------------------------------------------------------ the statement scan

    function test_OK_aSoldStatementWithAnUnsettledRecordIsSkipped() public {
        (uint256 sid,) = _sellStatement(address(0xB1D));
        _setSuccessor();
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), core.ethPot() + core.ethToBuyback(), 0, 0, 0, 1);
        _migrate(10, 10);
        (bool held,,,) = core.statementInfo(sid);
        assertTrue(held, "the record of the sale was cleared");
        assertEq(STATEMENTS.ownerOf(sid), address(0xB1D), "the winner lost the statement");
        assertEq(_heldCount(), 1);
    }

    /// the fork holds credits for about six statements, so six listed statements with bids stand for the many
    function test_OK_theScanStopsAfterMaxStatementsSkipped() public {
        uint256 n = 6;
        for (uint256 i; i < n; ++i) {
            uint256 sid = _listedStatement();
            _bid(address(uint160(0xB000 + i)), sid, _live(sid).reserve);
        }
        assertEq(_heldCount(), n, "setup: six statements");
        _setSuccessor();
        // two skipped statements end the scan: two reads of the house, not six
        vm.expectCall(address(house), abi.encodeWithSelector(IAuctionHouse.getAuction.selector), 2);
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), core.ethPot() + core.ethToBuyback(), 0, 0, 0, 2);
        _migrate(0, 2);
        assertEq(_heldCount(), n, "nothing moved");
    }

    function test_OK_aBatchLargerThanTheSkippedStatementsReachesTheOnesBehindThem() public {
        uint256 movable = _listedStatement();
        uint256 sid = _listedStatement();
        _bid(address(0xB1D), sid, _live(sid).reserve);
        _setSuccessor();
        // one skipped statement at the end, then the movable one
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), core.ethPot() + core.ethToBuyback(), 0, 1, 0, 1);
        _migrate(0, 2);
        assertEq(STATEMENTS.ownerOf(movable), address(sink));
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
        _migrate(10, 10);
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

    function _gasOf(uint256 maxCredits, uint256 maxStatements) internal returns (uint256 used) {
        vm.prank(owner);
        uint256 g = gasleft();
        core.migrate(maxCredits, maxStatements);
        used = g - gasleft();
    }

    function test_GAS_migrateEightyCreditsAndFiveStatements() public {
        _fundPot(2 ether);
        for (uint256 i; i < 5; ++i) {
            _listedStatement();
        }
        _fillEthPile(80);
        assertEq(_heldCount(), 5, "setup: five statements");
        assertEq(core.pileSize(Lane.Eth), 80, "setup: eighty credits");
        _setSuccessor();
        uint256 snap = vm.snapshotState();

        uint256 eth = _gasOf(0, 0);
        vm.revertToState(snap);
        uint256 credits40 = _gasOf(40, 0);
        vm.revertToState(snap);
        uint256 credits80 = _gasOf(80, 0);
        vm.revertToState(snap);
        uint256 statements1 = _gasOf(0, 1);
        vm.revertToState(snap);
        uint256 statements5 = _gasOf(0, 5);
        vm.revertToState(snap);
        uint256 both = _gasOf(80, 5);
        emit log_named_uint("gas: migrate(0,0), the eth pots only", eth);
        emit log_named_uint("gas: migrate(40,0)", credits40);
        emit log_named_uint("gas: migrate(80,0)", credits80);
        emit log_named_uint("gas: migrate(0,1)", statements1);
        emit log_named_uint("gas: migrate(0,5)", statements5);
        emit log_named_uint("gas: migrate(80,5)", both);
        uint256 perCredit = (credits80 - credits40) / 40;
        uint256 perStatement = (statements5 - statements1) / 4;
        emit log_named_uint("gas per credit", perCredit);
        emit log_named_uint("gas per statement", perStatement);
        emit log_named_uint("largest maxCredits for one lane under 16777216", (16_777_216 - eth) / perCredit);
        assertLt(both, 16_777_216, "80 credits and 5 statements fit the transaction cap");
    }
}
