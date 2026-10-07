// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {Lane, Sale, Settings, IStatements} from "../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../src/interfaces/AuctionHouse.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {SellingController, ReentrantBuyer, RefundRefuser} from "./attackers/SaleAttackers.sol";

/// the sale controller on the live fork: the asking price curve, the hard floor of the core, a controller that cannot
/// price, the auction path and the buy only path through `sellTo`, the mode flips, the controller's own settings.
/// real Core, ControllerV1, house, Statements. the doubles are the scripted and the attacker controllers only
abstract contract SaleBase is Fixture {
    uint256 internal constant H = 1 hours;

    function _cost(uint256 sid) internal view returns (uint256 cost) {
        (,, cost,) = core.statementInfo(sid);
    }

    function _listedAt(uint256 sid) internal view returns (uint64 at) {
        (,,, at) = core.statementInfo(sid);
    }

    /// the controller curve alone, below the hard floor too. `priceOf` is never below the hard floor
    function _raw(uint256 sid) internal view returns (uint256) {
        return ctl.statementPrice(sid, _cost(sid), _listedAt(sid));
    }

    /// moves the clock to `secs` after the statement was listed
    function _age(uint256 sid, uint256 secs) internal {
        vm.warp(_listedAt(sid) + secs);
    }

    function _buyOnly(bool on) internal {
        vm.prank(owner);
        ctl.setBuyOnly(on);
    }

    function _saleSettings(uint16 start, uint16 step, uint32 every, uint16 floor_) internal {
        // the order keeps every intermediate state inside the bounds
        vm.startPrank(owner);
        if (start >= ctl.startBps()) ctl.setStartBps(start);
        ctl.setFloorBps(floor_);
        ctl.setStartBps(start);
        ctl.setStepBps(step);
        ctl.setStepEvery(every);
        vm.stopPrank();
    }

    function _floorBps(uint16 bps) internal {
        Settings memory s = core.settings();
        s.saleFloorBps = bps;
        _setSettings(s);
    }

    function _buybackBps(uint16 bps) internal {
        Settings memory s = core.settings();
        s.saleToBuybackBps = bps;
        _setSettings(s);
    }

    /// a second statement, composed and listed after the first. returns its id
    function _another() internal returns (uint256 sid) {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
    }

    function _pay(address who, uint256 sid, uint256 value) internal {
        vm.deal(who, who.balance + value);
        vm.prank(who);
        ctl.buy{value: value}(sid);
    }

    function _pages(uint256[] memory ids) internal pure returns (uint256[80] memory p) {
        for (uint256 i; i < 80; ++i) {
            p[i] = ids[i];
        }
    }

    function _held(uint256 sid) internal view returns (bool found) {
        uint256[] memory h = core.heldStatements();
        for (uint256 i; i < h.length; ++i) {
            if (h[i] == sid) return true;
        }
    }

    function _recordedBook() internal view returns (uint256 pot, uint256 bb, uint256 bal) {
        return (core.ethPot(), core.ethToBuyback(), address(core).balance);
    }
}

contract SaleCurveTest is SaleBase {
    /// the launch table: 110 percent at hour 0, one point per 3 hours, 75 percent at hour 105 and held after
    function test_curve_exactTimesAtLaunchSettings() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        uint256[9] memory t = [uint256(0), 3 * H - 1, 3 * H, 30 * H, 104 * H, 105 * H - 1, 105 * H, 106 * H, 1000 * H];
        uint256[9] memory bps = [uint256(11_000), 11_000, 10_900, 10_000, 7_600, 7_600, 7_500, 7_500, 7_500];
        for (uint256 i; i < t.length; ++i) {
            _age(sid, t[i]);
            assertEq(ctl.priceOf(sid), cost * bps[i] / 10_000, "ask");
            assertEq(ctl.statementPrice(sid, cost, _listedAt(sid)), cost * bps[i] / 10_000, "controller price");
        }
    }

    /// 110 at hour 0, 109 at 3, 100 at 30, 75 at 105 and held, written as the owner stated them
    function test_curve_ownerStatedPoints() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        assertEq(ctl.priceOf(sid), cost * 110 / 100);
        _age(sid, 3 * H);
        assertEq(ctl.priceOf(sid), cost * 109 / 100);
        _age(sid, 30 * H);
        assertEq(ctl.priceOf(sid), cost * 100 / 100);
        _age(sid, 105 * H);
        assertEq(ctl.priceOf(sid), cost * 75 / 100);
        _age(sid, 5000 * H);
        assertEq(ctl.priceOf(sid), cost * 75 / 100);
    }

    /// the house reserve follows the curve at each reprice, down to the hard floor and no further
    function test_curve_repriceFollowsTheAskDownToTheFloor() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        assertEq(_live(sid).reserve, cost * 11_000 / 10_000);
        uint256[4] memory t = [uint256(3 * H), 30 * H, 105 * H, 400 * H];
        uint256[4] memory bps = [uint256(10_900), 10_000, 7_500, 7_500];
        for (uint256 i; i < t.length; ++i) {
            _age(sid, t[i]);
            vm.expectEmit(address(core));
            emit Core.StatementRepriced(sid, cost * bps[i] / 10_000);
            core.repriceStatement(sid);
            assertEq(_live(sid).reserve, cost * bps[i] / 10_000, "reserve");
            assertEq(house.getAuction(_live(sid).auctionId).reservePrice, cost * bps[i] / 10_000, "house reserve");
        }
    }

    /// other step settings, all at once: start 200, 2.5 points an hour, floor 50 (below the core floor of 75)
    function test_curve_otherStepSettings() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _saleSettings(20_000, 250, 1 hours, 5_000);
        uint256[6] memory t = [uint256(0), 1 * H - 1, 1 * H, 10 * H, 59 * H, 60 * H];
        uint256[6] memory bps = [uint256(20_000), 20_000, 19_750, 17_500, 5_250, 5_000];
        for (uint256 i; i < t.length; ++i) {
            _age(sid, t[i]);
            assertEq(_raw(sid), cost * bps[i] / 10_000, "ask");
            assertEq(ctl.priceOf(sid), cost * (bps[i] > 7_500 ? bps[i] : 7_500) / 10_000, "quote floored");
        }
        _age(sid, 4000 * H);
        assertEq(_raw(sid), cost * 5_000 / 10_000, "held at the controller floor");
        assertEq(ctl.priceOf(sid), cost * 7_500 / 10_000, "the quote is the hard floor");
    }

    /// the controller's floor below the core's hard floor: the curve goes below, the quote and the reserve do not
    function test_curve_controllerFloorBelowTheHardFloorIsLiftedOnTheReserve() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _saleSettings(11_000, 100, 3 hours, 5_000);
        _age(sid, 200 * H);
        assertEq(_raw(sid), cost * 5_000 / 10_000, "the curve is at the controller floor");
        assertEq(ctl.priceOf(sid), cost * 7_500 / 10_000, "the quote is the hard floor");
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 7_500 / 10_000, "the reserve is the hard floor");
    }

    /// no decay at all, a minute per step, and the largest step
    function test_curve_stepBoundaries() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _saleSettings(11_000, 0, 3 hours, 7_500);
        _age(sid, 1000 * H);
        assertEq(_raw(sid), cost * 11_000 / 10_000, "a zero step never decays");
        _saleSettings(11_000, 4_000, 1 minutes, 1_000);
        _age(sid, 59);
        assertEq(_raw(sid), cost * 11_000 / 10_000);
        _age(sid, 60);
        assertEq(_raw(sid), cost * 7_000 / 10_000, "one step of 4000 bps");
        _age(sid, 120);
        assertEq(_raw(sid), cost * 3_000 / 10_000, "two steps");
        _age(sid, 180);
        assertEq(_raw(sid), cost * 1_000 / 10_000, "three steps would go below zero: the floor holds");
        assertEq(ctl.priceOf(sid), cost * 7_500 / 10_000, "the quote never goes under the hard floor");
        _age(sid, 10_000 days);
        assertEq(_raw(sid), cost * 1_000 / 10_000, "a huge age does not overflow");
        _saleSettings(11_000, 4_000, 30 days, 1_000);
        _age(sid, 30 days - 1);
        assertEq(_raw(sid), cost * 11_000 / 10_000);
        _age(sid, 30 days);
        assertEq(_raw(sid), cost * 7_000 / 10_000);
    }

    /// start equal to the floor is a flat price. start below the floor cannot be set, and a floor above the start
    function test_curve_startAtTheFloorIsFlat() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _saleSettings(9_000, 100, 3 hours, 9_000);
        _age(sid, 0);
        assertEq(ctl.priceOf(sid), cost * 9_000 / 10_000);
        _age(sid, 500 * H);
        assertEq(ctl.priceOf(sid), cost * 9_000 / 10_000);
    }

    function test_curve_startBelowFloorAndFloorAboveStartRevert() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ControllerV1.BadSetting.selector, bytes32("startBps")));
        ctl.setStartBps(7_499);
        vm.expectRevert(abi.encodeWithSelector(ControllerV1.BadSetting.selector, bytes32("floorBps")));
        ctl.setFloorBps(11_001);
        ctl.setStartBps(7_500);
        vm.expectRevert(abi.encodeWithSelector(ControllerV1.BadSetting.selector, bytes32("floorBps")));
        ctl.setFloorBps(7_501);
        vm.stopPrank();
        // a controller built with a start below its floor is refused
        vm.expectRevert(abi.encodeWithSelector(ControllerV1.BadSetting.selector, bytes32("floorBps")));
        new ControllerV1(address(core), Sale({buyOnly: false, startBps: 5_000, stepBps: 100, stepEvery: 3 hours, floorBps: 7_500}));
    }

    /// the whole table again with the mode flipped: buy only keeps the house reserve at the start price while the
    /// ask in `priceOf` still falls
    function test_curve_buyOnlyKeepsTheReserveAtTheStartAndTheAskFalls() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _buyOnly(true);
        _age(sid, 60 * H);
        assertEq(ctl.priceOf(sid), cost * 9_000 / 10_000, "the ask falls");
        assertEq(ctl.statementPrice(sid, cost, _listedAt(sid)), cost * 11_000 / 10_000, "the reserve price does not");
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 11_000 / 10_000);
    }

    function test_curve_priceOfRefusesWhatIsNotForSale() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        vm.expectRevert(ControllerV1.NotForSale.selector);
        ctl.priceOf(sid + 100);
        // an exit lane statement is never for sale
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        core.composeExit();
        uint256 xs = STATEMENTS.supply();
        vm.expectRevert(ControllerV1.NotForSale.selector);
        ctl.priceOf(xs);
    }
}

contract SaleFloorTest is SaleBase {
    ScriptedController internal sc;

    /// installs a scripted controller that asks `bps` of cost and is ready to compose the whole eth pile
    function _scripted(uint256 bps, bool ready) internal returns (ScriptedController s) {
        s = new ScriptedController();
        s.setPriceBps(bps);
        if (ready) {
            uint256[] memory page = core.pilePage(Lane.Eth, 0, 80);
            s.setPage(Lane.Eth, true, _pages(page), 0);
        }
        _setController(address(s));
    }

    function test_floor_beatsAHigherCoreFloorAtListing() public {
        _floorBps(12_000);
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        assertEq(_live(sid).reserve, cost * 12_000 / 10_000, "the hard floor lifts the 110 percent ask");
        assertEq(_live(sid).reserve, _reserveFor(cost));
        assertEq(_raw(sid), cost * 11_000 / 10_000, "the controller still asks less");
        assertEq(ctl.priceOf(sid), cost * 12_000 / 10_000, "the quote is lifted to the hard floor");
    }

    function test_floor_beatsALowerControllerPriceAtListingAndReprice() public {
        _fillEthPile(80);
        sc = _scripted(5_000, true);
        vm.fee(composeBasefee);
        uint256 supply = STATEMENTS.supply();
        vm.prank(keeper);
        core.compose();
        uint256 sid = supply + 1;
        uint256 cost = _cost(sid);
        assertEq(_live(sid).reserve, cost * 7_500 / 10_000, "listed at the floor, the controller said 50 percent");
        // above the floor the controller wins, a raised floor wins again, a lowered floor gives way again
        sc.setPriceBps(9_000);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 9_000 / 10_000);
        _floorBps(20_000);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 20_000 / 10_000);
        _floorBps(1_000);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 9_000 / 10_000);
        sc.setPriceBps(0);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 1_000 / 10_000, "a zero answer is the floor");
    }

    function test_floor_aHugeControllerPriceIsTakenAndNoBidReachesIt() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        sc = _scripted(10_000_000, false);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 1000, "the reserve is the controller price, a thousand times the cost");
        address b = address(0xB1D1);
        vm.deal(b, 10 ether);
        uint256 aid = _live(sid).auctionId;
        vm.prank(b);
        vm.expectRevert(IAuctionHouse.BidBelowReserve.selector);
        house.createBid{value: cost * 2}(aid);
    }

    // ------------------------------------------------------------------ a controller that cannot price

    function _brokenModes(uint256 m, ScriptedController s) internal {
        if (m == 0) s.setRevertPrice(true);
        else if (m == 1) s.setBurnPrice(true);
        else s.setShortPrice(true);
    }

    function test_broken_composeRevertsAndKeepsEverything() public {
        for (uint256 m; m < 3; ++m) {
            uint256 snap = vm.snapshotState();
            _fillEthPile(80);
            sc = _scripted(11_000, true);
            _brokenModes(m, sc);
            vm.fee(composeBasefee);
            uint256 supply = STATEMENTS.supply();
            uint256 pot = core.ethPot();
            vm.prank(keeper);
            vm.expectRevert(Core.BadPrice.selector);
            core.compose();
            assertEq(STATEMENTS.supply(), supply, "nothing minted");
            assertEq(core.pileSize(Lane.Eth), 80, "the pile is whole");
            assertEq(core.ethPot(), pot, "no reimbursement paid");
            assertEq(core.heldStatements().length, 0);
            // the same controller, repaired, composes
            sc.setRevertPrice(false);
            sc.setBurnPrice(false);
            sc.setShortPrice(false);
            vm.prank(keeper);
            core.compose();
            assertEq(_live(supply + 1).reserve, _cost(supply + 1) * 11_000 / 10_000);
            vm.revertToState(snap);
        }
    }

    function test_broken_repriceRevertsAndKeepsTheStoredReserve() public {
        for (uint256 m; m < 3; ++m) {
            uint256 snap = vm.snapshotState();
            uint256 sid = _composeOnce().sid;
            uint256 reserve = _live(sid).reserve;
            sc = _scripted(9_000, false);
            _brokenModes(m, sc);
            _age(sid, 30 * H);
            vm.expectRevert(Core.BadPrice.selector);
            core.repriceStatement(sid);
            assertEq(_live(sid).reserve, reserve, "the stored reserve stays");
            assertEq(house.getAuction(_live(sid).auctionId).reservePrice, reserve);
            sc.setRevertPrice(false);
            sc.setBurnPrice(false);
            sc.setShortPrice(false);
            core.repriceStatement(sid);
            assertEq(_live(sid).reserve, _cost(sid) * 9_000 / 10_000);
            vm.revertToState(snap);
        }
    }

    function test_broken_aControllerWithNoCodeCannotPriceEither() public {
        uint256 sid = _composeOnce().sid;
        uint256 reserve = _live(sid).reserve;
        _setController(address(0xBEEF));
        vm.expectRevert(Core.BadPrice.selector);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, reserve);
    }

    function test_broken_buyAndSellStayOpenWhilePricingIsBroken() public {
        // a controller that cannot price does not freeze a bid that already sits on the house
        uint256 sid = _composeOnce().sid;
        _bid(address(0xB1D1), sid, _live(sid).reserve);
        sc = _scripted(9_000, false);
        sc.setRevertPrice(true);
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(0xB1D1));
        _collectSales();
        _solvent();
    }

    // ------------------------------------------------------------------ reprice with a live bid

    /// coded behaviour: a reprice of a listing with a bid reverts HasBid. it is not a no op
    function test_reprice_withALiveBidRevertsAndKeepsTheReserve() public {
        uint256 sid = _composeOnce().sid;
        uint256 reserve = _live(sid).reserve;
        _bid(address(0xB1D1), sid, reserve);
        _age(sid, 6 * H);
        vm.expectRevert(Core.HasBid.selector);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, reserve);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Bid));
        // also when the controller is broken: the bid is checked first
        sc = _scripted(9_000, false);
        sc.setRevertPrice(true);
        vm.expectRevert(Core.HasBid.selector);
        core.repriceStatement(sid);
        // and after the auction ended and before it is settled
        _bid(address(0xB1D2), sid, reserve * 106 / 100);
        Live memory l = _live(sid);
        vm.warp(l.endTime);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Ended));
        vm.expectRevert(Core.HasBid.selector);
        core.repriceStatement(sid);
        // after the sale: the record is stale, not listed
        vm.prank(address(0xE4D));
        house.endAuction{gas: END_GAS}(l.auctionId);
        vm.expectRevert(Core.NotListed.selector);
        core.repriceStatement(sid);
    }

    function test_reprice_isPermissionlessAndRefusesWhatIsNotListed() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _age(sid, 6 * H);
        vm.prank(address(0x5757));
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, _cost(sid) * 10_800 / 10_000);
        vm.expectRevert(Core.NotListed.selector);
        core.repriceStatement(sid + 77);
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        core.composeExit();
        uint256 xs = STATEMENTS.supply();
        vm.expectRevert(Core.NotListed.selector);
        core.repriceStatement(xs);
    }
}

contract SaleAuctionTest is SaleBase {
    /// reprice at hour 30, first bid at that price on the real house, outbid by five percent, end, collect. the pot
    /// split is exact at the given saleToBuybackBps
    function _auctionPath(uint16 bps) internal {
        _buybackBps(bps);
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 30 * H);
        core.repriceStatement(sid);
        uint256 reserve = _live(sid).reserve;
        assertEq(reserve, cost, "hour 30 asks 100 percent");
        uint256 aid = _live(sid).auctionId;

        address b1 = address(0xB1D1);
        address b2 = address(0xB1D2);
        vm.deal(b1, reserve);
        vm.prank(b1);
        vm.expectRevert(IAuctionHouse.BidBelowReserve.selector);
        house.createBid{value: reserve - 1}(aid);
        _bid(b1, sid, reserve);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Bid));
        uint256 min2 = reserve + reserve * 500 / 10_000;
        vm.deal(b2, min2);
        vm.prank(b2);
        vm.expectRevert(IAuctionHouse.BidBelowMinimum.selector);
        house.createBid{value: min2 - 1}(aid);
        uint256 b1Before = b1.balance;
        _bid(b2, sid, min2);
        assertEq(b1.balance - b1Before, reserve, "the first bidder is refunded in the same call");
        assertEq(_live(sid).bid, min2);

        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), b2, "the winner holds the statement");
        uint256 owed = _owedByHouse();
        assertEq(owed, min2, "the house fee is zero: the core is owed the winning bid");
        assertEq(core.ethPot(), pot0, "owed eth is not in the pot until collected");
        assertEq(address(core).balance, bal0);
        assertTrue(_held(sid), "the record is stale until synced");
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Sold));

        vm.expectEmit(address(core));
        emit Core.SalesCollected(min2, min2 * bps / 10_000);
        _collectSales();
        assertEq(address(core).balance - bal0, min2, "the balance rose by the winning bid");
        assertEq(core.ethToBuyback() - bb0, min2 * bps / 10_000, "buyback share");
        assertEq(core.ethPot() - pot0, min2 - min2 * bps / 10_000, "pot share");
        assertEq(_owedByHouse(), 0);
        _solvent();

        core.syncStatement(sid);
        assertFalse(_held(sid));
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.None));
        // a second collect books nothing more
        (pot0, bb0, bal0) = _recordedBook();
        core.collectSales();
        (uint256 pot1, uint256 bb1, uint256 bal1) = _recordedBook();
        assertEq(pot1, pot0);
        assertEq(bb1, bb0);
        assertEq(bal1, bal0);
    }

    function test_auction_pathSplitAtZero() public {
        _auctionPath(0);
    }

    function test_auction_pathSplitAtHalf() public {
        _auctionPath(5_000);
    }

    function test_auction_pathSplitAtAll() public {
        _auctionPath(10_000);
    }

    function test_auction_pathSplitAtAnOddShare() public {
        _auctionPath(3_333);
    }

    /// a bid below the old ask but above the repriced one opens the auction: the reprice is what a first bidder needs
    function test_auction_repriceLowersTheBarForTheFirstBid() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 60 * H);
        uint256 aid = _live(sid).auctionId;
        address b = address(0xB1D1);
        vm.deal(b, 10 ether);
        vm.prank(b);
        vm.expectRevert(IAuctionHouse.BidBelowReserve.selector);
        house.createBid{value: cost}(aid);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 9_000 / 10_000);
        _bid(b, sid, cost * 9_000 / 10_000);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Bid));
    }

    /// the reserve of an auction that already has a bid stays: later decay does not touch it
    function test_auction_aBidFreezesTheReserveWhileTheAskKeepsFalling() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _bid(address(0xB1D1), sid, _live(sid).reserve);
        _age(sid, 12 * H);
        assertEq(ctl.priceOf(sid), cost * 10_600 / 10_000);
        assertEq(_live(sid).reserve, cost * 11_000 / 10_000);
        vm.expectRevert(Core.HasBid.selector);
        core.repriceStatement(sid);
    }

    /// no bid, no sale: the statement waits on the house and nothing is booked
    function test_auction_noBidMeansNoSaleAndNoBooking() public {
        uint256 sid = _composeOnce().sid;
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        _age(sid, 400 * H);
        core.collectSales();
        (uint256 pot1, uint256 bb1, uint256 bal1) = _recordedBook();
        assertEq(pot1, pot0);
        assertEq(bb1, bb0);
        assertEq(bal1, bal0);
        assertEq(STATEMENTS.ownerOf(sid), address(house));
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Listed));
    }
}

contract SaleBuyOnlyTest is SaleBase {
    address internal buyer = address(0xB0B);

    function _buyAt(uint256 age) internal returns (uint256 sid, uint256 price) {
        sid = _composeOnce().sid;
        _buyOnly(true);
        _age(sid, age);
        price = ctl.priceOf(sid);
    }

    function test_buy_exactPriceSplitAndOwnership() public {
        uint16[3] memory shares = [uint16(0), 5_000, 10_000];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            _buybackBps(shares[i]);
            (uint256 sid, uint256 price) = _buyAt(40 * H);
            assertEq(price, _cost(sid) * 9_700 / 10_000, "13 steps down: 97 percent");
            (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
            uint256 n = core.heldStatements().length;
            uint256 aid = _live(sid).auctionId;
            vm.expectEmit(address(core));
            emit Core.StatementSoldTo(sid, buyer, price);
            vm.expectEmit(address(ctl));
            emit ControllerV1.Bought(sid, buyer, price);
            _pay(buyer, sid, price);
            assertEq(buyer.balance, 0, "exact payment, nothing back");
            assertEq(STATEMENTS.ownerOf(sid), buyer);
            assertEq(address(core).balance - bal0, price);
            assertEq(core.ethToBuyback() - bb0, price * shares[i] / 10_000);
            assertEq(core.ethPot() - pot0, price - price * shares[i] / 10_000);
            assertEq(address(ctl).balance, 0, "the controller holds nothing");
            (bool exists,) = house.getAuctionFor(address(STATEMENTS), sid);
            assertFalse(exists, "the house has no auction");
            assertEq(house.getAuction(aid).tokenOwner, address(0), "the old auction is gone");
            (bool held,,,) = core.statementInfo(sid);
            assertFalse(held, "the core record is cleared");
            assertEq(core.heldStatements().length, n - 1);
            assertFalse(_held(sid));
            assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.None));
            assertEq(_owedByHouse(), 0, "the house owes nothing");
            _solvent();
            vm.revertToState(snap);
        }
    }

    function test_buy_refundsTheExcess() public {
        (uint256 sid, uint256 price) = _buyAt(0);
        _pay(buyer, sid, price + 3 ether);
        assertEq(buyer.balance, 3 ether, "the excess came back");
        assertEq(address(ctl).balance, 0);
    }

    function test_buy_underpayRevertsAndChangesNothing() public {
        (uint256 sid, uint256 price) = _buyAt(0);
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        vm.deal(buyer, price);
        vm.prank(buyer);
        vm.expectRevert(ControllerV1.Underpaid.selector);
        ctl.buy{value: price - 1}(sid);
        vm.prank(buyer);
        vm.expectRevert(ControllerV1.Underpaid.selector);
        ctl.buy(sid);
        (uint256 pot1, uint256 bb1, uint256 bal1) = _recordedBook();
        assertEq(pot1, pot0);
        assertEq(bb1, bb0);
        assertEq(bal1, bal0);
        assertEq(STATEMENTS.ownerOf(sid), address(house));
    }

    /// the price is read at the call: a buyer who pays the ask of an hour ago pays less than the ask now and gets it
    /// when the ask fell, and is refused when the ask rose (a settings change)
    function test_buy_paysTheAskOfTheBlock() public {
        (uint256 sid, uint256 price) = _buyAt(10 * H);
        assertEq(price, _cost(sid) * 10_700 / 10_000);
        _saleSettings(12_000, 100, 3 hours, 7_500);
        uint256 now_ = ctl.priceOf(sid);
        assertEq(now_, _cost(sid) * 11_700 / 10_000, "a raised start lifts the ask at once");
        vm.deal(buyer, price);
        vm.prank(buyer);
        vm.expectRevert(ControllerV1.Underpaid.selector);
        ctl.buy{value: price}(sid);
        _pay(buyer, sid, now_);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }

    function test_buy_atTheFloorAndBelowTheHardFloor() public {
        (uint256 sid, uint256 price) = _buyAt(200 * H);
        uint256 cost = _cost(sid);
        assertEq(price, cost * 7_500 / 10_000, "the ask at its floor equals the hard floor: allowed");
        // the controller floor falls below the hard floor: the quote and the payment are lifted to the hard floor
        // (review S-1, fixed), so the buy still clears at exactly the hard floor
        _saleSettings(11_000, 100, 3 hours, 5_000);
        assertEq(ctl.floorBps(), 5_000);
        assertEq(ctl.priceOf(sid), cost * 7_500 / 10_000, "the quote is the hard floor");
        _pay(buyer, sid, cost * 7_500 / 10_000);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
        assertFalse(_held(sid));
    }

    function test_buy_revertsInAuctionMode() public {
        uint256 sid = _composeOnce().sid;
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        vm.expectRevert(ControllerV1.NotBuyOnly.selector);
        ctl.buy{value: 100 ether}(sid);
        _buyOnly(true);
        _buyOnly(false);
        vm.prank(buyer);
        vm.expectRevert(ControllerV1.NotBuyOnly.selector);
        ctl.buy{value: 100 ether}(sid);
    }

    function test_buy_withALiveBidRevertsAndTheBidderKeepsTheAuction() public {
        (uint256 sid,) = _buyAt(0);
        address bidder = address(0xB1D1);
        uint256 reserve = _live(sid).reserve;
        _bid(bidder, sid, reserve);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        vm.expectRevert(Core.HasBid.selector);
        ctl.buy{value: 100 ether}(sid);
        assertEq(buyer.balance, 100 ether);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Bid));
        assertEq(_live(sid).bid, reserve);
        assertEq(house.getAuction(_live(sid).auctionId).bidder, bidder);
        // even a price far above the reserve does not buy it out of the auction
        _age(sid, 1 * H);
        vm.prank(buyer);
        vm.expectRevert(Core.HasBid.selector);
        ctl.buy{value: 100 ether}(sid);
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), bidder, "the bidder wins the statement");
        _collectSales();
        _solvent();
    }

    function test_buy_aSecondBuyAndUnknownAndExitLaneRevert() public {
        _enterPhase2();
        (uint256 sid, uint256 price) = _buyAt(0);
        _pay(buyer, sid, price);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        vm.expectRevert(ControllerV1.NotForSale.selector);
        ctl.buy{value: 100 ether}(sid);
        vm.prank(buyer);
        vm.expectRevert(ControllerV1.NotForSale.selector);
        ctl.buy{value: 100 ether}(sid + 500);
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        core.composeExit();
        uint256 xs = STATEMENTS.supply();
        vm.prank(buyer);
        vm.expectRevert(ControllerV1.NotForSale.selector);
        ctl.buy{value: 100 ether}(xs);
    }

    /// the compaction of the held list: selling the first statement moves the last into its slot, and the moved
    /// statement still sells, exits and reports right
    function test_buy_theHeldListStaysRightAfterASaleOutOfTheMiddle() public {
        uint256 a = _composeOnce().sid;
        uint256 b = _another();
        uint256 c = _another();
        _buyOnly(true);
        uint256[] memory before_ = core.heldStatements();
        assertEq(before_.length, 3);
        _pay(buyer, a, ctl.priceOf(a));
        uint256[] memory after_ = core.heldStatements();
        assertEq(after_.length, 2);
        assertFalse(_held(a));
        assertTrue(_held(b));
        assertTrue(_held(c));
        (bool hb,, uint256 cb,) = core.statementInfo(b);
        (bool hc,, uint256 cc,) = core.statementInfo(c);
        assertTrue(hb && hc && cb != 0 && cc != 0);
        _pay(address(0xB0B2), c, ctl.priceOf(c));
        assertEq(core.heldStatements().length, 1);
        assertEq(core.heldStatements()[0], b);
        _pay(address(0xB0B3), b, ctl.priceOf(b));
        assertEq(core.heldStatements().length, 0);
        _solvent();
    }
}

contract SaleModeFlipTest is SaleBase {
    /// the owner flips to buy only with listings in every state: a live bid keeps its auction, an old listing is sold at
    /// its decayed ask and a new listing opens at the start price
    function test_flip_toBuyOnlyWithABidWithNoBidAndANewListing() public {
        uint256 a = _composeOnce().sid;
        address bidder = address(0xB1D1);
        _bid(bidder, a, _live(a).reserve);
        _buyOnly(true);
        vm.deal(address(0xB0B), 100 ether);
        vm.prank(address(0xB0B));
        vm.expectRevert(Core.HasBid.selector);
        ctl.buy{value: 100 ether}(a);
        _endAuction(a);
        assertEq(STATEMENTS.ownerOf(a), bidder, "the auction ran on after the flip");
        _collectSales();

        // a listing without a bid, aged. the house reserve is whatever it was until a reprice, and a reprice in buy only
        // mode puts it back at the start price, it does not follow the ask down
        uint256 b = _another();
        uint256 cost = _cost(b);
        _age(b, 60 * H);
        assertEq(_live(b).reserve, cost * 11_000 / 10_000);
        assertEq(ctl.priceOf(b), cost * 9_000 / 10_000);
        core.repriceStatement(b);
        assertEq(_live(b).reserve, cost * 11_000 / 10_000, "buy only reprices to the start price");
        address buyer = address(0xB0B2);
        _pay(buyer, b, ctl.priceOf(b));
        assertEq(STATEMENTS.ownerOf(b), buyer);

        // a new listing in buy only mode opens at the start price and sells at it
        uint256 c = _another();
        assertEq(_live(c).reserve, _cost(c) * 11_000 / 10_000);
        assertEq(ctl.priceOf(c), _cost(c) * 11_000 / 10_000);
        _pay(address(0xB0B3), c, ctl.priceOf(c));
        assertEq(STATEMENTS.ownerOf(c), address(0xB0B3));
        _solvent();
    }

    /// back to auction mode: the old listing keeps its reserve until a reprice, then falls to the ask, and a bid at
    /// the ask opens the auction. `buy` is shut again
    function test_flip_backToAuctionWithAnAgedListing() public {
        _buyOnly(true);
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 60 * H);
        _buyOnly(false);
        assertEq(_live(sid).reserve, cost * 11_000 / 10_000);
        vm.deal(address(0xB0B), 100 ether);
        vm.prank(address(0xB0B));
        vm.expectRevert(ControllerV1.NotBuyOnly.selector);
        ctl.buy{value: 100 ether}(sid);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 9_000 / 10_000);
        _bid(address(0xB1D1), sid, cost * 9_000 / 10_000);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Bid));
    }

    /// a listing repriced down in auction mode, then the flip: its reserve walks back UP to the start price at the
    /// next reprice, while `buy` still sells at the decayed ask
    function test_flip_repricedListingWalksBackUpInBuyOnly() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 30 * H);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost);
        _buyOnly(true);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 11_000 / 10_000, "the reserve went up");
        assertEq(ctl.priceOf(sid), cost, "the ask is still 100 percent");
        _pay(address(0xB0B), sid, cost);
        assertEq(STATEMENTS.ownerOf(sid), address(0xB0B));
    }

    function test_flip_onlyTheOwnerFlips() public {
        vm.prank(address(0x5757));
        vm.expectRevert(ControllerV1.OnlyOwner.selector);
        ctl.setBuyOnly(true);
        vm.prank(owner);
        vm.expectEmit(address(ctl));
        emit ControllerV1.BuyOnlySet(true);
        ctl.setBuyOnly(true);
        assertTrue(ctl.buyOnly());
    }
}

contract SaleSellToTest is SaleBase {
    SellingController internal sc;
    address internal buyer = address(0xB0B);

    function _install() internal {
        sc = new SellingController(core);
        _setController(address(sc));
    }

    function _floorOf(uint256 sid) internal view returns (uint256) {
        return _cost(sid) * core.settings().saleFloorBps / 10_000;
    }

    function test_sellTo_onlyTheCurrentController() public {
        uint256 sid = _composeOnce().sid;
        vm.deal(address(this), 100 ether);
        vm.expectRevert(Core.OnlyController.selector);
        core.sellTo{value: 10 ether}(sid, buyer);
        vm.prank(owner);
        vm.deal(owner, 100 ether);
        vm.expectRevert(Core.OnlyController.selector);
        core.sellTo{value: 10 ether}(sid, buyer);
        // the first controller has no way to call it except `buy`, and after it is replaced `buy` fails too
        _buyOnly(true);
        _install();
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        vm.expectRevert(Core.OnlyController.selector);
        ctl.buy{value: 100 ether}(sid);
        vm.deal(address(sc), 100 ether);
        sc.sell{value: _floorOf(sid)}(sid, buyer);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }

    function test_sellTo_belowTheHardFloorRevertsAtTheFloorClears() public {
        uint256 sid = _composeOnce().sid;
        _install();
        uint256 floor = _floorOf(sid);
        vm.expectRevert(Core.BelowFloor.selector);
        sc.sell{value: floor - 1}(sid, buyer);
        vm.expectRevert(Core.BelowFloor.selector);
        sc.sell{value: 0}(sid, buyer);
        assertEq(STATEMENTS.ownerOf(sid), address(house));
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        uint256 scBal = address(sc).balance;
        vm.expectEmit(address(core));
        emit Core.StatementSoldTo(sid, buyer, floor);
        sc.sell{value: floor}(sid, buyer);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
        assertEq(address(core).balance - bal0, floor);
        assertEq(core.ethToBuyback() - bb0, floor * 5_000 / 10_000);
        assertEq(core.ethPot() - pot0, floor - floor * 5_000 / 10_000);
        assertEq(address(sc).balance, scBal, "the controller keeps nothing");
        _solvent();
    }

    /// a raised hard floor binds the controller's sale at once, a lowered one frees it
    function test_sellTo_followsTheHardFloorSetting() public {
        uint256 sid = _composeOnce().sid;
        _install();
        uint256 cost = _cost(sid);
        _floorBps(30_000);
        vm.expectRevert(Core.BelowFloor.selector);
        sc.sell{value: cost * 29_999 / 10_000}(sid, buyer);
        vm.expectRevert(Core.BelowFloor.selector);
        sc.sell{value: cost * 3 - 1}(sid, buyer);
        _floorBps(1_000);
        sc.sell{value: cost / 10}(sid, buyer);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }

    /// the whole payment is booked, an overpayment included: the core has no refund logic
    function test_sellTo_booksEverythingItIsPaid() public {
        uint256 sid = _composeOnce().sid;
        _install();
        uint256 pay = _floorOf(sid) * 5;
        _buybackBps(2_500);
        (uint256 pot0, uint256 bb0,) = _recordedBook();
        sc.sell{value: pay}(sid, buyer);
        assertEq(core.ethToBuyback() - bb0, pay * 2_500 / 10_000);
        assertEq(core.ethPot() - pot0, pay - pay * 2_500 / 10_000);
    }

    function test_sellTo_exitLaneUnknownAndNotListedRevert() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        core.composeExit();
        uint256 xs = STATEMENTS.supply();
        _install();
        vm.expectRevert(Core.NotListed.selector);
        sc.sell{value: 100 ether}(xs, buyer);
        vm.expectRevert(Core.NotListed.selector);
        sc.sell{value: 100 ether}(sid + 1000, buyer);
        assertEq(STATEMENTS.ownerOf(xs), address(core), "the exit lane statement stays");
        // a statement that was sold and not synced: the record is stale and the house has no auction
        _bid(address(0xB1D1), sid, _live(sid).reserve);
        _endAuction(sid);
        vm.expectRevert(Core.NotListed.selector);
        sc.sell{value: 100 ether}(sid, buyer);
    }

    function test_sellTo_aLiveBidAlwaysWins() public {
        uint256 sid = _composeOnce().sid;
        _install();
        address bidder = address(0xB1D1);
        _bid(bidder, sid, _live(sid).reserve);
        vm.expectRevert(Core.HasBid.selector);
        sc.sell{value: 1000 ether}(sid, buyer);
        _bid(address(0xB1D2), sid, _live(sid).bid * 106 / 100);
        Live memory l = _live(sid);
        vm.warp(l.endTime);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Ended));
        vm.expectRevert(Core.HasBid.selector);
        sc.sell{value: 1000 ether}(sid, buyer);
        vm.prank(address(0xE4D));
        house.endAuction{gas: END_GAS}(l.auctionId);
        assertEq(STATEMENTS.ownerOf(sid), address(0xB1D2));
    }

    function test_sellTo_aSecondSaleOfTheSameStatementInOneTransactionFails() public {
        uint256 sid = _composeOnce().sid;
        _install();
        uint256 floor = _floorOf(sid);
        sc.sellTwice{value: floor * 2}(sid, buyer, floor, floor);
        assertFalse(sc.lastOk());
        assertEq(bytes4(sc.lastWhy()), Core.NotListed.selector);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }

    function test_sellTo_toTheZeroAddressRevertsAndToAContractWorks() public {
        uint256 sid = _composeOnce().sid;
        _install();
        uint256 floor = _floorOf(sid);
        vm.expectRevert();
        sc.sell{value: floor}(sid, address(0));
        assertEq(STATEMENTS.ownerOf(sid), address(house));
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Listed));
        // a buyer without a receiver hook still gets it: the core uses a plain transfer
        sc.sell{value: floor}(sid, address(ctl));
        assertEq(STATEMENTS.ownerOf(sid), address(ctl));
    }

    /// the owner key can sell every statement at the floor through its own controller: the documented trust, and the
    /// only way a statement leaves. the eth goes to the pots and the owner gains nothing
    function test_sellTo_aControllerSellingAtTheFloorMovesEthOnlyIntoThePots() public {
        uint256 a = _composeOnce().sid;
        uint256 b = _another();
        _install();
        uint256 ownerEth = owner.balance;
        uint256 total = _floorOf(a) + _floorOf(b);
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        sc.sell{value: _floorOf(a)}(a, address(sc));
        sc.sell{value: _floorOf(b)}(b, address(sc));
        assertEq(address(core).balance - bal0, total);
        assertEq((core.ethPot() - pot0) + (core.ethToBuyback() - bb0), total);
        assertEq(owner.balance, ownerEth);
        assertEq(core.heldStatements().length, 0);
        _solvent();
    }

    // ------------------------------------------------------------------ reentrancy

    function test_reenter_theBuyersRefundCannotReachAnyDoorTwice() public {
        uint256 a = _composeOnce().sid;
        uint256 b = _another();
        _buyOnly(true);
        ReentrantBuyer rb = new ReentrantBuyer(ctl, core);
        rb.setOther(b, a);
        uint256 price = ctl.priceOf(a);
        (uint256 pot0, uint256 bb0,) = _recordedBook();
        vm.deal(address(this), price + 2 ether);
        uint256 pre = address(rb).balance;
        rb.buy{value: price + 2 ether}(a);
        assertEq(STATEMENTS.ownerOf(a), address(rb), "the buy went through");
        assertEq(address(rb).balance - pre, 2 ether, "and the refund landed");
        assertEq(rb.reentries(), 1);
        assertTrue(rb.buyBlocked(), "a second buy from the refund is refused");
        assertEq(rb.buySel(), ControllerV1.Reentrant.selector);
        assertTrue(rb.sellBlocked(), "sellTo is the controller's alone");
        assertTrue(rb.repriceBlocked(), "the sold statement is not listed any more");
        assertEq(rb.repriceSel(), Core.NotListed.selector);
        assertTrue(rb.exitBlocked());
        assertEq(STATEMENTS.ownerOf(b), address(house), "the other statement is untouched");
        assertEq(core.ethPot() - pot0 + core.ethToBuyback() - bb0, price, "booked exactly once");
        _solvent();
    }

    function test_reenter_aBuyerThatRefusesTheRefundCanOnlyPayExactly() public {
        uint256 sid = _composeOnce().sid;
        _buyOnly(true);
        RefundRefuser rr = new RefundRefuser(ctl);
        uint256 price = ctl.priceOf(sid);
        vm.deal(address(rr), price + 1 ether);
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        vm.expectRevert();
        rr.buy{value: price + 1 ether}(sid);
        (uint256 pot1, uint256 bb1, uint256 bal1) = _recordedBook();
        assertEq(pot1, pot0);
        assertEq(bb1, bb0);
        assertEq(bal1, bal0);
        assertEq(STATEMENTS.ownerOf(sid), address(house), "the failed buy changed nothing");
        rr.buy{value: price}(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(rr));
    }
}

contract SaleRelistTest is SaleBase {
    address internal alice = address(0xA11CE);

    /// a sale whose delivery to the winner fails on the house. the real Statements never refuses a transfer, so the
    /// refusal is made by a mocked revert of exactly this transfer (the house is real, the unwind is real)
    function _failedDelivery() internal returns (uint256 sid, uint256 aid, uint256 price) {
        sid = _composeOnce().sid;
        Live memory l = _live(sid);
        price = l.reserve;
        aid = l.auctionId;
        _bid(alice, sid, price);
        vm.mockCallRevert(
            address(STATEMENTS),
            abi.encodeWithSelector(IStatements.transferFrom.selector, address(house), alice, sid),
            "cannot receive"
        );
        _endAuction(sid);
        assertTrue(house.pendingDelivery(aid), "deferred");
    }

    /// the relist after an unwound sale is a fresh listing: the clock restarts, the price is the start price of the
    /// controller (not the decayed one of the old listing), and the exit wait starts over
    function test_relist_unwoundSaleRestartsTheClockAndThePrice() public {
        _enterPhase2();
        (uint256 sid, uint256 aid,) = _failedDelivery();
        uint64 first = _listedAt(sid);
        uint256 cost = _cost(sid);
        _warp(30 days + 1);
        house.unwindStuckLot{gas: END_GAS}(aid);
        vm.clearMockedCalls();
        assertEq(ctl.statementPrice(sid, cost, first), cost * 7_500 / 10_000, "the old listing would ask the floor");
        core.syncStatement(sid);
        assertEq(_listedAt(sid), block.timestamp, "the clock restarted");
        assertEq(_live(sid).reserve, cost * 11_000 / 10_000, "the relist is priced at age zero");
        assertEq(ctl.priceOf(sid), cost * 11_000 / 10_000);
        assertEq(_live(sid).auctionId, aid + 1);
        // the exit wait counts from the relist
        _warp(105 hours - 1);
        vm.expectRevert(Core.TooEarly.selector);
        core.exitStatement(sid);
        _warp(1);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    /// the relist of a returned statement never needs the controller (review S-4, fixed): a broken one makes the sync
    /// list at the hard floor, and a repaired controller prices it again at the next reprice
    function test_relist_aBrokenControllerListsAtTheHardFloor() public {
        (uint256 sid, uint256 aid,) = _failedDelivery();
        _warp(30 days + 1);
        house.unwindStuckLot{gas: END_GAS}(aid);
        vm.clearMockedCalls();
        ScriptedController sc = new ScriptedController();
        sc.setRevertPrice(true);
        _setController(address(sc));
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Returned));
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        core.syncStatement(sid);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Listed));
        assertEq(_live(sid).reserve, _cost(sid) * core.settings().saleFloorBps / 10_000, "listed at the hard floor");
        vm.expectRevert(Core.BadPrice.selector);
        core.repriceStatement(sid);
        sc.setRevertPrice(false);
        sc.setPriceBps(20_000);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, _cost(sid) * 2, "a repaired controller prices it again");
    }

    /// the overprint relist: the base keeps its id, sums the cost, restarts the clock and lists at the start price of
    /// the summed cost
    function test_relist_overprintRestartsTheBaseClock() public {
        _enterPhase2();
        uint256 a = _composeOnce().sid;
        uint256 b = _another();
        ScriptedController sc = new ScriptedController();
        sc.setOverprint(true, a, b);
        _setController(address(sc));
        uint256 sum = _cost(a) + _cost(b);
        uint64 first = _listedAt(a);
        vm.warp(uint256(first) + 100 hours);
        vm.prank(keeper);
        core.overprint();
        assertEq(_cost(a), sum, "the cost is summed");
        assertEq(_listedAt(a), block.timestamp, "the base clock restarted");
        assertEq(_live(a).reserve, sum * 11_000 / 10_000, "listed at age zero on the summed cost");
        (bool held,,,) = core.statementInfo(b);
        assertFalse(held, "the top is gone");
        // the base was listed 100 hours ago but may not exit for 105 hours from the relist
        _warp(104 hours);
        vm.expectRevert(Core.TooEarly.selector);
        core.exitStatement(a);
        _warp(1 hours);
        core.exitStatement(a);
        assertEq(STATEMENTS.ownerOf(a), address(mod));
    }
}

contract SaleSettingsTest is SaleBase {
    function _fresh() internal view returns (Sale memory) {
        return Sale({
            buyOnly: lc.sale.buyOnly,
            startBps: lc.sale.startBps,
            stepBps: lc.sale.stepBps,
            stepEvery: lc.sale.stepEvery,
            floorBps: lc.sale.floorBps
        });
    }

    function _bad(bytes32 field) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ControllerV1.BadSetting.selector, field);
    }

    function test_settings_boundsOfEverySetter() public {
        vm.startPrank(owner);
        // startBps 1_000 to 40_000 and not below the floor
        ctl.setFloorBps(1_000);
        ctl.setStartBps(1_000);
        vm.expectRevert(_bad("startBps"));
        ctl.setStartBps(999);
        ctl.setStartBps(40_000);
        vm.expectRevert(_bad("startBps"));
        ctl.setStartBps(40_001);
        // stepBps 0 to 5_000
        ctl.setStepBps(0);
        ctl.setStepBps(5_000);
        vm.expectRevert(_bad("stepBps"));
        ctl.setStepBps(5_001);
        // stepEvery 1 minute to 30 days
        vm.expectRevert(_bad("stepEvery"));
        ctl.setStepEvery(59);
        ctl.setStepEvery(60);
        ctl.setStepEvery(30 days);
        vm.expectRevert(_bad("stepEvery"));
        ctl.setStepEvery(30 days + 1);
        // floorBps 1_000 to startBps
        vm.expectRevert(_bad("floorBps"));
        ctl.setFloorBps(999);
        ctl.setFloorBps(40_000);
        vm.expectRevert(_bad("floorBps"));
        ctl.setFloorBps(40_001);
        // the start cannot fall below the floor now
        vm.expectRevert(_bad("startBps"));
        ctl.setStartBps(39_999);
        vm.stopPrank();
        assertEq(ctl.startBps(), 40_000);
        assertEq(ctl.floorBps(), 40_000);
        assertEq(ctl.stepBps(), 5_000);
        assertEq(ctl.stepEvery(), 30 days);
    }

    function test_settings_eventsAndValues() public {
        vm.startPrank(owner);
        vm.expectEmit(address(ctl));
        emit ControllerV1.StartBpsSet(12_000);
        ctl.setStartBps(12_000);
        vm.expectEmit(address(ctl));
        emit ControllerV1.StepBpsSet(150);
        ctl.setStepBps(150);
        vm.expectEmit(address(ctl));
        emit ControllerV1.StepEverySet(2 hours);
        ctl.setStepEvery(2 hours);
        vm.expectEmit(address(ctl));
        emit ControllerV1.FloorBpsSet(8_000);
        ctl.setFloorBps(8_000);
        vm.expectEmit(address(ctl));
        emit ControllerV1.BuyOnlySet(true);
        ctl.setBuyOnly(true);
        vm.stopPrank();
        assertEq(ctl.startBps(), 12_000);
        assertEq(ctl.stepBps(), 150);
        assertEq(ctl.stepEvery(), 2 hours);
        assertEq(ctl.floorBps(), 8_000);
        assertTrue(ctl.buyOnly());
    }

    /// only the live owner of the core: not the deployer, not a keeper, not the controller itself
    function test_settings_onlyTheCoreOwner() public {
        address[4] memory who = [deployer, keeper, address(ctl), address(0x5757)];
        for (uint256 i; i < who.length; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(ControllerV1.OnlyOwner.selector);
            ctl.setBuyOnly(true);
            vm.expectRevert(ControllerV1.OnlyOwner.selector);
            ctl.setStartBps(12_000);
            vm.expectRevert(ControllerV1.OnlyOwner.selector);
            ctl.setStepBps(150);
            vm.expectRevert(ControllerV1.OnlyOwner.selector);
            ctl.setStepEvery(2 hours);
            vm.expectRevert(ControllerV1.OnlyOwner.selector);
            ctl.setFloorBps(8_000);
            vm.stopPrank();
        }
        assertEq(ctl.startBps(), 11_000);
        assertFalse(ctl.buyOnly());
    }

    function test_settings_constructorBounds() public {
        Sale memory s = _fresh();
        s.startBps = 999;
        vm.expectRevert(_bad("startBps"));
        new ControllerV1(address(core), s);
        s = _fresh();
        s.startBps = 40_001;
        vm.expectRevert(_bad("startBps"));
        new ControllerV1(address(core), s);
        s = _fresh();
        s.stepBps = 5_001;
        vm.expectRevert(_bad("stepBps"));
        new ControllerV1(address(core), s);
        s = _fresh();
        s.stepEvery = 59;
        vm.expectRevert(_bad("stepEvery"));
        new ControllerV1(address(core), s);
        s = _fresh();
        s.stepEvery = 30 days + 1;
        vm.expectRevert(_bad("stepEvery"));
        new ControllerV1(address(core), s);
        s = _fresh();
        s.floorBps = 999;
        vm.expectRevert(_bad("floorBps"));
        new ControllerV1(address(core), s);
        s = _fresh();
        s.floorBps = s.startBps + 1;
        vm.expectRevert(_bad("floorBps"));
        new ControllerV1(address(core), s);
        s = _fresh();
        s.buyOnly = true;
        ControllerV1 c = new ControllerV1(address(core), s);
        assertTrue(c.buyOnly());
    }

    /// a controller the owner installs later is governed by the same live owner
    function test_settings_aNewControllerFollowsTheSameOwner() public {
        ControllerV1 c2 = new ControllerV1(address(core), lc.sale);
        _setController(address(c2));
        vm.prank(owner);
        c2.setBuyOnly(true);
        assertTrue(c2.buyOnly());
        vm.prank(address(0x5757));
        vm.expectRevert(ControllerV1.OnlyOwner.selector);
        c2.setStepBps(1);
    }
}
