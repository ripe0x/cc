// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "../utils/Fixture.sol";
import {Core} from "../../src/Core.sol";
import {Settings} from "../../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../../src/interfaces/AuctionHouse.sol";
import {SetSettings, ICoreOwner} from "../../script/SetSettings.s.sol";
import {ScriptedController} from "../attackers/ScriptedController.sol";

/// @dev the script with its environment replaced by fields. `sweep` is the read, reprice, read again loop that runs
/// after `setSettings`, called from a test the way the script calls it from its broadcast
contract FloorProbe is SetSettings {
    address internal core_;

    function configure(address core) external {
        core_ = core;
    }

    function _core() internal view override returns (address) {
        return core_;
    }

    function sweep(uint256 floorBps, uint256[] memory first, bool exec) external returns (Left[] memory) {
        return _sweep(ICoreOwner(core_), floorBps, first, exec);
    }
}

/// @notice audit finding A01: raising `saleFloorBps` is not atomic for an EOA owner. a listing keeps its old reserve until
/// `repriceStatement` runs on it. the Core rule is accepted design. the script closes the snapshot gap (a statement
/// composed after its first read), not the window of a bid at the old reserve
contract FloorRaiseRaceTest is Fixture {
    FloorProbe internal probe;
    address internal bidder;
    uint256 internal constant NEW_FLOOR = 12_000;

    function setUp() public override {
        super.setUp();
        probe = new FloorProbe();
        probe.configure(address(core));
        bidder = _user("a01 bidder");
    }

    function _raise(uint256 bps) internal {
        Settings memory s = core.settings();
        s.saleFloorBps = uint16(bps);
        _setSettings(s);
    }

    function _cost(uint256 sid) internal view returns (uint256 c) {
        (,, c,) = core.statementInfo(sid);
    }

    /// @dev a second statement composed on top of the first
    function _composeAnother() internal returns (uint256 sid) {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
    }

    // ------------------------------------------------------------------ the accepted window

    /// ACCEPTED: the owner (an EOA) sends `setSettings`, and a bid at the old reserve lands before the reprice does. the
    /// reprice then reverts `HasBid` and the statement sells at its old reserve, below the new floor. asserted as it is
    function test_ACCEPTED_A01_bidAtTheOldReserveBeforeRepriceWins() public {
        uint256 sid = _composeOnce().sid;
        uint256 old = _live(sid).reserve;
        assertEq(old, _cost(sid) * 11_000 / 10_000, "a fresh listing sits at 110 percent of cost");
        _raise(NEW_FLOOR);
        assertEq(_live(sid).reserve, old, "the raise did not move the open reserve");

        _bid(bidder, sid, old);
        vm.expectRevert(Core.HasBid.selector);
        core.repriceStatement(sid);

        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), bidder, "sold");
        assertEq(_owedByHouse(), old, "at the old reserve");
        assertLt(old, _cost(sid) * NEW_FLOOR / 10_000, "below the new floor");
    }

    /// the multisig case: `setSettings` and the reprice in one transaction leave no window. a bid at the old reserve
    /// then reverts on the house, and the cheapest bid is the new reserve
    function test_batchedRepriceClosesTheWindowForAListingInTheSnapshot() public {
        uint256 sid = _composeOnce().sid;
        uint256 old = _live(sid).reserve;
        _raise(NEW_FLOOR);
        core.repriceStatement(sid);
        uint256 fresh = _live(sid).reserve;
        assertEq(fresh, _cost(sid) * NEW_FLOOR / 10_000);
        uint256 aid = _live(sid).auctionId;
        vm.deal(bidder, fresh);
        vm.prank(bidder);
        vm.expectRevert(IAuctionHouse.BidBelowReserve.selector);
        house.createBid{value: old}(aid);
        _bid(bidder, sid, fresh);
    }

    /// the raise only matters when the new floor is above a listing's reserve: at launch settings a fresh listing sits at
    /// 110 percent of cost, so a floor of 105 percent needs no reprice and the sweep finds nothing to do
    function test_floorBelowTheListingPriceNeedsNoReprice() public {
        uint256 sid = _composeOnce().sid;
        uint256 old = _live(sid).reserve;
        _raise(10_500);
        SetSettings.Left[] memory left = probe.sweep(10_500, core.heldStatements(), true);
        assertEq(left.length, 0);
        assertEq(_live(sid).reserve, old, "no reprice was needed");
    }

    // ------------------------------------------------------------------ the script's second pass

    /// FIXED: the first read of the script lists statement A. statement B is composed after that read, before
    /// `setSettings` lands. the old script repriced only what it had read, so B kept its old reserve. the second pass
    /// reads `heldStatements()` again after `setSettings` and reprices B
    function test_FIXED_A01_secondPassRepricesAStatementComposedAfterTheFirstRead() public {
        uint256 a = _composeOnce().sid;
        uint256[] memory first = core.heldStatements();
        assertEq(first.length, 1);
        uint256 b = _composeAnother();
        uint256 oldB = _live(b).reserve;

        _raise(NEW_FLOOR);
        // the old script: one reprice per statement of the first read
        for (uint256 i; i < first.length; ++i) {
            core.repriceStatement(first[i]);
        }
        assertEq(_live(a).reserve, _cost(a) * NEW_FLOOR / 10_000, "A was in the snapshot");
        assertEq(_live(b).reserve, oldB, "B was not, it keeps the old reserve");
        assertLt(oldB, _cost(b) * NEW_FLOOR / 10_000);

        // the second pass
        SetSettings.Left[] memory left = probe.sweep(NEW_FLOOR, first, true);
        assertEq(_live(b).reserve, _cost(b) * NEW_FLOOR / 10_000, "B was repriced by the second pass");
        assertEq(_live(a).reserve, _cost(a) * NEW_FLOOR / 10_000);
        assertEq(left.length, 0, "nothing is left below the new floor");
    }

    /// the whole sweep from one read: both listings, none in the first read, are repriced in one pass
    function test_FIXED_A01_sweepFindsEveryOpenListingWithoutAFirstRead() public {
        uint256 a = _composeOnce().sid;
        uint256 b = _composeAnother();
        _raise(NEW_FLOOR);
        SetSettings.Left[] memory left = probe.sweep(NEW_FLOOR, new uint256[](0), true);
        assertEq(left.length, 0);
        assertEq(_live(a).reserve, _cost(a) * NEW_FLOOR / 10_000);
        assertEq(_live(b).reserve, _cost(b) * NEW_FLOOR / 10_000);
    }

    /// the final table: a listing with a bid below the new floor cannot be repriced and is named, one that appeared
    /// after the first read says so. a dry run (`exec` false) names the same and changes nothing
    function test_FIXED_A01_finalTableNamesWhatCannotBeRepriced() public {
        uint256 a = _composeOnce().sid;
        uint256[] memory first = core.heldStatements();
        uint256 b = _composeAnother();
        _bid(bidder, a, _live(a).reserve);
        _bid(bidder, b, _live(b).reserve);
        uint256 c = _composeAnother();
        _raise(NEW_FLOOR);

        uint256 reserveC = _live(c).reserve;
        SetSettings.Left[] memory plan = probe.sweep(NEW_FLOOR, first, false);
        assertEq(_live(c).reserve, reserveC, "a dry run changes nothing");
        assertEq(plan.length, 2, "C will be repriced by the plan, A and B cannot");
        assertEq(plan[0].sid, a);
        assertEq(plan[0].reason, "has a bid below the new floor");
        assertEq(plan[1].sid, b);
        assertEq(plan[1].reason, "has a bid below the new floor, appeared during the run");

        SetSettings.Left[] memory left = probe.sweep(NEW_FLOOR, first, true);
        assertEq(left.length, 2);
        assertEq(_live(c).reserve, _cost(c) * NEW_FLOOR / 10_000, "C was repriced");
        assertEq(left[0].sid, a);
        assertEq(left[1].sid, b);
        assertEq(left[1].bid, _live(b).bid);
    }

    /// a controller that cannot price makes `repriceStatement` revert, so the sweep does not send it and names it
    function test_FIXED_A01_aListingTheControllerCannotPriceIsNamed() public {
        uint256 a = _composeOnce().sid;
        ScriptedController sc = new ScriptedController();
        sc.setRevertPrice(true);
        _setController(address(sc));
        _raise(NEW_FLOOR);
        uint256 old = _live(a).reserve;
        SetSettings.Left[] memory left = probe.sweep(NEW_FLOOR, core.heldStatements(), true);
        assertEq(_live(a).reserve, old);
        assertEq(left.length, 1);
        assertEq(left[0].reason, "controller cannot price it");
    }
}
