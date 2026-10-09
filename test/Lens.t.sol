// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICoreLens} from "../src/interfaces/ICoreLens.sol";
import {Lane} from "../src/interfaces/Interfaces.sol";

/// `CoreLens` on the fork: the real Core, controller, router, house, Credits and Statements. every field of `snapshot` is
/// compared with the direct reads on a populated system, and the flush split with an actual flush
contract LensTest is Fixture {
    uint256 internal sidListed;
    uint256 internal sidBid;
    uint256 internal sidExit;

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

    /// two listed eth lane statements (one with a live bid), an exit lane statement, credits in both piles, pots in both
    /// currencies and a router that holds fee eth with the split on
    function _populate() internal {
        _enterPhase2();
        _fundPot(3 ether);
        sidListed = _listedStatement();
        sidBid = _listedStatement();
        _bid(address(0xB1D), sidBid, _live(sidBid).reserve);
        sidExit = _exitLaneStatement();
        _fillEthPile(7);
        uint256[] memory ids = _credits(seller, 5);
        vm.prank(seller);
        core.sellForExitToken(ids);
        // the first flush at or after the split start turns the split on, then the router keeps the next fees
        _skipToSplitStart();
        _buyCoin(funder, 2 ether);
        assertTrue(feeRouter.splitOn(), "split on");
        autoFlush = false;
        _buyCoin(funder, 3 ether);
        assertGt(address(feeRouter).balance, 0, "router loaded");
        // eth above the booked pots and sale proceeds waiting in the house
        vm.deal(address(core), address(core).balance + 0.01 ether);
    }

    function _assertStatementViews(ICoreLens.StatementView[] memory v, uint256 offset) internal view {
        uint256[] memory held = core.heldStatements();
        for (uint256 i; i < v.length; ++i) {
            uint256 sid = held[offset + i];
            ICoreLens.StatementView memory s = v[i];
            assertEq(s.id, sid, "id");
            (, Lane lane, uint256 cost, uint64 clockStart) = core.statementInfo(sid);
            assertEq(uint8(s.lane), uint8(lane), "lane");
            assertEq(s.cost, cost, "cost");
            Live memory l = _live(sid);
            assertEq(s.status, uint8(l.status), "status");
            assertEq(s.auctionId, l.auctionId, "auction id");
            assertEq(s.topBid, l.bid, "top bid");
            assertEq(s.endTime, l.endTime, "end time");
            bool listed = l.status == ICore.StatementStatus.Listed || l.status == ICore.StatementStatus.Bid
                || l.status == ICore.StatementStatus.Ended;
            assertEq(s.listed, listed, "listed");
            bool open = l.status == ICore.StatementStatus.Listed;
            assertEq(s.askingPrice, open && lane == Lane.Eth && clockStart != 0 ? ctl.priceOf(sid) : 0, "asking price");
        }
    }

    function test_OK_everyFieldEqualsTheDirectReads() public {
        _populate();
        // the asking price has moved off the start price
        _warp(7 hours);
        ICoreLens.Snapshot memory s = lens.snapshot();

        assertEq(s.ethRate, core.ethRate(), "ethRate");
        assertEq(s.ethPrice, core.ethPrice(), "ethPrice");
        assertGe(s.ethPrice, s.ethRate, "the read is the price state or the clamp below it");
        assertEq(s.averageBid, uint256(core.settings().avgScore) * core.ethRate() / 1e4, "averageBid");
        assertEq(s.hourlyRoom, core.hourlyRoom(), "hourlyRoom");
        assertEq(s.ethPileSize, 7, "eth pile size");
        assertEq(s.ethPileSize, core.pileSize(Lane.Eth));
        assertEq(s.ethPileHead, core.pileHead(Lane.Eth));
        assertEq(s.exitPileSize, 5, "exit pile size");
        assertEq(s.exitPileSize, core.pileSize(Lane.Exit));
        assertEq(s.exitPileHead, core.pileHead(Lane.Exit));
        assertTrue(s.ethPileHead != 0 && s.exitPileHead != 0, "heads");
        assertFalse(s.ethPageReady, "7 credits are not a page");
        assertFalse(s.exitPageReady, "5 credits are not a page");

        assertEq(s.ethPot, core.ethPot(), "ethPot");
        assertEq(s.ethToBuyback, core.ethToBuyback(), "ethToBuyback");
        assertEq(s.xPot, core.xPot(), "xPot");
        assertEq(s.xToBuyback, core.xToBuyback(), "xToBuyback");
        assertTrue(s.ethPot != 0 && s.xPot != 0, "pots populated");
        assertEq(s.unbookedEth, address(core).balance - core.ethPot() - core.ethToBuyback(), "unbookedEth");
        assertGe(s.unbookedEth, 0.01 ether, "unbookedEth carries the extra eth");
        assertEq(s.salesOwed, house.pendingRefunds(address(core)), "salesOwed");

        assertEq(s.routerBalance, address(feeRouter).balance, "routerBalance");
        assertEq(s.routerOwed, feeRouter.totalOwed(), "routerOwed");
        assertEq(s.flushToCore + s.flushToPayees, s.routerBalance - s.routerOwed, "the split adds up");
        assertGt(s.flushToPayees, 0, "payee share");

        assertEq(s.controller, address(ctl), "controller");
        assertEq(s.successor, core.successor(), "successor");
        assertEq(s.controllerLocked, core.controllerLocked());
        assertEq(s.exitModuleLocked, core.exitModuleLocked());
        assertEq(s.targetsLocked, core.targetsLocked());
        assertEq(s.successorLocked, core.successorLocked());

        assertEq(s.statements.length, core.heldStatements().length, "statement count");
        assertEq(s.statements.length, 3, "three statements held");
        _assertStatementViews(s.statements, 0);
        for (uint256 i; i < s.statements.length; ++i) {
            ICoreLens.StatementView memory v = s.statements[i];
            if (v.id == sidListed) {
                assertTrue(v.listed);
                assertEq(v.status, uint8(ICore.StatementStatus.Listed));
                assertGt(v.askingPrice, 0);
                assertEq(v.topBid, 0);
            } else if (v.id == sidBid) {
                assertTrue(v.listed);
                assertEq(v.status, uint8(ICore.StatementStatus.Bid));
                assertGt(v.topBid, 0);
                assertEq(v.askingPrice, 0, "a statement with a bid cannot be bought at the asking price");
            } else {
                assertEq(v.id, sidExit);
                assertEq(uint8(v.lane), uint8(Lane.Exit));
                assertFalse(v.listed);
                assertEq(v.askingPrice, 0);
            }
        }
    }

    function test_OK_theFlushFieldsEqualAnActualFlush() public {
        _populate();
        ICoreLens.Snapshot memory s = lens.snapshot();
        address payee = lc.creatorPayee;
        uint256 coreBefore = address(core).balance;
        uint256 payeeBefore = payee.balance;
        vm.prank(flusher);
        feeRouter.flush();
        assertEq(address(core).balance - coreBefore, s.flushToCore, "to the core");
        assertEq(payee.balance - payeeBefore, s.flushToPayees, "to the payee");
        ICoreLens.Snapshot memory after_ = lens.snapshot();
        assertEq(after_.flushToCore + after_.flushToPayees, 0, "nothing left to flush");
    }

    function test_OK_theFlushFieldsBeforeTheSplit() public {
        // before the split starts every fee eth goes to the core
        autoFlush = false;
        _buyCoin(funder, 3 ether);
        ICoreLens.Snapshot memory s = lens.snapshot();
        assertFalse(feeRouter.splitOn());
        assertEq(s.flushToPayees, 0, "no payee share before the split");
        assertEq(s.flushToCore, address(feeRouter).balance);
        assertEq(s.routerOwed, 0);
    }

    function test_OK_hourlyRoomFollowsTheSpendAndTheWindow() public {
        _fundPot(2 ether);
        _warp(1 hours + 1);
        uint256 pot = core.ethPot();
        uint256 cap = core.settings().spendCapBps;
        assertEq(lens.snapshot().hourlyRoom, pot * cap / 10_000, "a closed window offers the cap on the pot");
        uint256[] memory ids = _credits(seller, 3);
        uint256 before = lens.snapshot().hourlyRoom;
        uint256 balance = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        // the rate falls after each credit, so the payout is read from the seller
        uint256 total = seller.balance - balance;
        // the window opened with the pot before the spend
        assertEq(lens.snapshot().hourlyRoom, pot * cap / 10_000 - total, "room after the spend");
        assertEq(before - lens.snapshot().hourlyRoom, total, "room fell by the payout");
        _warp(1 hours);
        assertEq(lens.snapshot().hourlyRoom, core.ethPot() * cap / 10_000, "a new hour opens on the pot of that moment");
    }

    function test_OK_bidForIsTheCeilingAndTheAverageBidPricesTheAverageScore() public {
        _fundPot(1 ether);
        uint256[] memory ids = _credits(seller, 4);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(lens.bidFor(ids[i]), core.ceilingOf(ids[i]), "bidFor");
        }
        // a seller receives bidFor for a single credit
        uint256 before = seller.balance;
        uint256 quoted = lens.bidFor(ids[0]);
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        assertEq(seller.balance - before, quoted, "the payout equals the quote");
        ICoreLens.Snapshot memory s = lens.snapshot();
        assertEq(s.averageBid, uint256(core.settings().avgScore) * s.ethRate / 1e4);
    }

    function test_OK_aFullPageIsReady() public {
        _fillEthPile(80);
        assertTrue(lens.snapshot().ethPageReady, "80 credits make a page");
        assertFalse(lens.snapshot().exitPageReady);
    }

    function test_OK_statementsPageEqualsTheSnapshotSlices() public {
        _enterPhase2();
        _fundPot(3 ether);
        sidListed = _listedStatement();
        sidBid = _listedStatement();
        ICoreLens.Snapshot memory s = lens.snapshot();
        assertEq(s.statements.length, 2);
        ICoreLens.StatementView[] memory p0 = lens.statementsPage(0, 1);
        ICoreLens.StatementView[] memory p1 = lens.statementsPage(1, 5);
        assertEq(p0.length, 1);
        assertEq(p1.length, 1);
        assertEq(p0[0].id, s.statements[0].id);
        assertEq(p1[0].id, s.statements[1].id);
        assertEq(p1[0].askingPrice, s.statements[1].askingPrice);
        assertEq(lens.statementsPage(2, 5).length, 0, "past the end");
        assertEq(lens.statementsPage(9, type(uint256).max).length, 0, "start past the end");
        assertEq(lens.statementsPage(0, type(uint256).max).length, 2, "a huge count is cut to the list");
        _assertStatementViews(p1, 1);
    }

    /// the cost of `snapshot` per held statement, to size a keeper's call. logged, with a bound
    function test_GAS_snapshotPerStatement() public {
        _enterPhase2();
        _fundPot(3 ether);
        uint256 g = gasleft();
        lens.snapshot();
        uint256 empty = g - gasleft();
        sidListed = _listedStatement();
        sidBid = _listedStatement();
        _bid(address(0xB1D), sidBid, _live(sidBid).reserve);
        g = gasleft();
        lens.snapshot();
        uint256 two = g - gasleft();
        emit log_named_uint("snapshot gas, no statements", empty);
        emit log_named_uint("snapshot gas, two statements", two);
        emit log_named_uint("snapshot gas per statement", (two - empty) / 2);
        assertLt(empty, 300_000, "snapshot without statements");
        assertLt((two - empty) / 2, 80_000, "per statement");
    }

    /// the asking price is nonzero only while a buyer can buy at it: a live auction without a bid
    function test_OK_askingPriceIsZeroUnlessABuyerCanBuyNow() public {
        _fundPot(3 ether);
        // the sale is settled first: ending its auction moves the clock to its end time
        uint256 sold = _listedStatement();
        _bid(address(0xB2D), sold, _live(sold).reserve);
        _endAuction(sold);
        uint256 open = _listedStatement();
        uint256 withBid = _listedStatement();
        _bid(address(0xB1D), withBid, _live(withBid).reserve);
        ICoreLens.StatementView[] memory v = lens.snapshot().statements;
        assertEq(v.length, 3);
        for (uint256 i; i < 3; ++i) {
            if (v[i].id == open) {
                assertEq(v[i].status, uint8(ICore.StatementStatus.Listed));
                assertEq(v[i].askingPrice, ctl.priceOf(open), "open: the controller price");
                assertGt(v[i].askingPrice, 0);
            } else if (v[i].id == withBid) {
                assertEq(v[i].status, uint8(ICore.StatementStatus.Bid));
                assertEq(v[i].askingPrice, 0, "with a bid");
                assertGt(v[i].topBid, 0);
                assertGt(v[i].endTime, 0);
            } else {
                assertEq(v[i].id, sold);
                assertEq(v[i].status, uint8(ICore.StatementStatus.Sold), "sold, record not settled");
                assertFalse(v[i].listed);
                assertEq(v[i].askingPrice, 0, "sold and unsynced");
                // the controller still answers for it: the lens decides
                assertGt(ctl.priceOf(sold), 0);
            }
        }
    }

    /// the lens requires the answer size of `nextPage` that the Core requires, so both agree on a short answer
    function test_OK_aShortNextPageAnswerIsNotReadyForTheLensAndForCompose() public {
        _fillEthPile(80);
        uint256[] memory page = core.pilePage(Lane.Eth, 0, 80);
        assertTrue(lens.snapshot().ethPageReady, "the real controller answers ready");
        vm.mockCall(address(ctl), abi.encodeWithSelector(ctl.nextPage.selector), abi.encode(uint256(1)));
        assertFalse(lens.snapshot().ethPageReady, "one word is a short answer");
        vm.expectRevert(ICore.NotReady.selector);
        vm.prank(keeper);
        core.compose();
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        vm.mockCall(address(ctl), abi.encodeWithSelector(ctl.nextPage.selector), abi.encode(uint256(1), ids, uint256(0)));
        assertTrue(lens.snapshot().ethPageReady, "the full size answer is ready");
        vm.clearMockedCalls();
    }

    function test_OK_thePointersAndTheControllerFollow() public {
        assertEq(lens.CORE(), address(core));
        assertEq(lens.ROUTER(), address(feeRouter));
        assertEq(lens.HOUSE(), address(house));
        assertEq(lens.CREDITS(), address(CREDITS));
        assertEq(lens.STATEMENTS(), address(STATEMENTS));
        assertEq(lens.controller(), address(ctl));
        // a controller replaced by the owner is followed, and one without code does not break the snapshot
        _setController(address(0xC0DE));
        assertEq(lens.controller(), address(0xC0DE));
        ICoreLens.Snapshot memory s = lens.snapshot();
        assertEq(s.controller, address(0xC0DE));
        assertFalse(s.ethPageReady);
    }

    function test_OK_theSnapshotReadsAnEmptySystem() public view {
        ICoreLens.Snapshot memory s = lens.snapshot();
        assertEq(s.ethRate, core.ethRate());
        assertEq(s.statements.length, 0);
        assertEq(s.ethPileSize, 0);
        assertEq(s.ethPileHead, 0);
        assertEq(s.successor, address(0));
    }
}
