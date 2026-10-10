// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane, Settings, Mainnet, IStatements} from "../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../src/interfaces/AuctionHouse.sol";

/// @notice independent review of the Core against the live pnd auction house (docs/REVIEW-flow-house.md)
contract ReviewFlowHouseTest is Fixture {
    address internal alice = makeAddr("fh_alice");
    address internal bob = makeAddr("fh_bob");

    // ------------------------------------------------------------------ measurements

    function test_measure_composeAndDeliveryGas() public {
        Composed memory c = _composeOnce();
        emit log_named_uint("compose gas as the caller saw it", c.gasUsed);
        emit log_named_uint("block gas limit", block.gaslimit);
        // listing gas on its own: cancel and list again as the core
        vm.startPrank(address(core));
        house.cancelAuction(_live(c.sid).auctionId);
        uint256 g = gasleft();
        house.createAuction(c.sid, address(STATEMENTS), 24 hours, 1 ether, 0);
        emit log_named_uint("createAuction gas (warm-ish)", g - gasleft());
        vm.stopPrank();
    }

    function test_measure_deliveryGasOfTheRealStatements() public {
        (uint256 sid,) = _sellStatement(alice);
        assertEq(STATEMENTS.ownerOf(sid), alice);
        // transfer gas of a statement from a contract holder to a fresh account
        vm.prank(alice);
        uint256 g = gasleft();
        STATEMENTS.transferFrom(alice, bob, sid);
        emit log_named_uint("Statements.transferFrom gas", g - gasleft());
    }

    // ------------------------------------------------------------------ helpers

    /// @dev a second statement, composed on top of the first
    function _composeSecond() internal returns (uint256 sid2) {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        sid2 = STATEMENTS.supply() + 1;
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.ownerOf(sid2), address(house));
    }

    function test_probe_strangerCannotOverprintTheCoresStatements() public {
        uint256 a = _composeOnce().sid;
        uint256 b = _composeSecond();
        // both sit in the house, owned by the house
        vm.prank(bob);
        vm.expectRevert();
        STATEMENTS.overprint(a, b);
        // cancel both as the core (what an exit or overprint does) and try again while the core holds them
        vm.startPrank(address(core));
        house.cancelAuction(_live(a).auctionId);
        house.cancelAuction(_live(b).auctionId);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert();
        STATEMENTS.overprint(a, b);
        assertEq(STATEMENTS.ownerOf(b), address(core));
    }

    function test_probe_strangerCannotComposeTheCoresCredits() public {
        _fillEthPile(80);
        uint256[] memory page = core.pilePage(Lane.Eth, 0, 80);
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        vm.prank(bob);
        vm.expectRevert();
        STATEMENTS.compose(ids, 0);
    }

    // ------------------------------------------------------------------ FH-1 a record that can never be cleared

    /// @dev FIXED. the buyer of a sold statement parks it in the house with a plain transfer. the auction is gone and
    /// the house holds the token. `syncStatement` used to revert for ever on this (a phantom record in
    /// `heldStatements`). now the holder is not the core, so the statement clears as sold, like any other sale
    function test_FIXED_FH1_soldStatementParkedInTheHouseClearsAsSold() public {
        (uint256 sid,) = _sellStatement(alice);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Sold));
        uint256 auctionId = _live(sid).auctionId;
        vm.prank(alice);
        STATEMENTS.transferFrom(alice, address(house), sid);
        assertEq(STATEMENTS.ownerOf(sid), address(house));

        vm.expectEmit(address(core));
        emit ICore.StatementSold(sid, auctionId, address(house));
        core.syncStatement(sid);
        (bool held,,,) = core.statementInfo(sid);
        assertFalse(held, "the record is cleared");
        assertEq(core.heldStatements().length, 0, "no phantom entry");
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.None));
        // the record is gone, so an exit or a reprice say so, and a second sync has nothing to do
        _enterPhase2();
        vm.expectRevert(ICore.NotHeld.selector);
        core.exitStatement(sid);
        vm.expectRevert(ICore.NotListed.selector);
        core.repriceStatement(sid);
        vm.expectRevert(ICore.NotListed.selector);
        core.syncStatement(sid);
    }

    // ------------------------------------------------------------------ FH-2 a raised reserve does not reach old listings

    /// @dev DOCUMENTED (operating rule in docs/DEPLOY.md: reprice open listings in the same batch). raising `saleFloorBps` changes nothing on the house. every listing stays biddable at its old reserve until
    /// somebody reprices it, and a bidder who sees the settings change can buy at the old price in the same block
    function test_DOCUMENTED_FH2_raisedReserveDoesNotProtectOldListings() public {
        Composed memory c = _composeOnce();
        (,, uint256 cost,) = core.statementInfo(c.sid);
        uint256 oldReserve = _live(c.sid).reserve;
        Settings memory st = core.settings();
        st.saleFloorBps = 30_000;
        _setSettings(st);
        assertGt(_reserveFor(cost), oldReserve * 2 - 1, "the floor now sits far above the old reserve");
        assertEq(_live(c.sid).reserve, oldReserve, "the listing did not move");

        _bid(alice, c.sid, oldReserve);
        assertEq(uint256(_live(c.sid).status), uint256(ICore.StatementStatus.Bid));
        vm.expectRevert(ICore.HasBid.selector);
        core.repriceStatement(c.sid);
        _endAuction(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), alice);
        assertEq(_owedByHouse(), oldReserve, "sold at the old reserve, below the reserve the owner set");
    }

    // ------------------------------------------------------------------ state machine checks

    /// @dev a sold statement that comes back before anybody synced is relisted at the old cost and the current
    /// reserve. the proceeds of the first sale are collected once and the second sale pays again: nothing doubles
    function test_state_soldThenReturnedBeforeSyncRelistsAndBooksEachSaleOnce() public {
        (uint256 sid, uint256 price) = _sellStatement(alice);
        (,, uint256 cost,) = core.statementInfo(sid);
        vm.prank(alice);
        STATEMENTS.transferFrom(alice, address(core), sid);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Returned));
        _warp(1 days);
        core.syncStatement(sid);
        Live memory l = _live(sid);
        assertEq(uint256(l.status), uint256(ICore.StatementStatus.Listed));
        assertEq(l.reserve, _reserveFor(cost), "old cost, current reserve");
        uint256 potBefore = core.ethPot() + core.ethToBuyback();
        assertEq(_collectSales(), price);
        assertEq(core.ethPot() + core.ethToBuyback(), potBefore + price, "first sale booked once");
        _bid(bob, sid, l.reserve);
        _endAuction(sid);
        assertEq(_collectSales(), l.reserve);
        assertEq(STATEMENTS.ownerOf(sid), bob);
        core.syncStatement(sid);
        assertEq(core.heldStatements().length, 0);
        _solvent();
    }

    /// @dev nobody but the core can touch the house admin surface, and the core has no call that reaches it
    function test_state_houseAdminIsUnreachable() public {
        uint256 sid = _composeOnce().sid;
        uint256 aid = _live(sid).auctionId;
        vm.startPrank(bob);
        vm.expectRevert();
        house.cancelAuction(aid);
        vm.expectRevert();
        house.setAuctionReservePrice(aid, 1);
        vm.expectRevert();
        IHouseExtra(address(house)).setAuctionFundsRecipient(aid, payable(bob));
        vm.expectRevert();
        IHouseExtra(address(house)).recoverStuckERC721(address(STATEMENTS), sid, bob);
        vm.expectRevert();
        house.createAuction(sid, address(STATEMENTS), 1 hours, 1, 0);
        vm.stopPrank();
        // the allowlist refuses the house and its factory even for the owner
        address[2] memory t = [address(house), Mainnet.AUCTION_FACTORY];
        for (uint256 i; i < 2; ++i) {
            vm.prank(owner);
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addTarget(t[i]);
        }
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(
            0, abi.encodeCall(IHouseExtra.recoverStuckERC721, (address(STATEMENTS), sid, bob)), 1, address(house)
        );
    }

    /// @dev a listing keeps the duration it was made with, and a reprice never touches the exit clock
    function test_state_durationAndClockStayWithTheOldListing() public {
        Composed memory c = _composeOnce();
        Settings memory st = core.settings();
        st.auctionDuration = 7 days;
        st.saleFloorBps = 12_000;
        _setSettings(st);
        _warp(1 days);
        core.repriceStatement(c.sid);
        (,,, uint64 listedAt) = core.statementInfo(c.sid);
        assertEq(listedAt, c.at, "reprice does not move the clock");
        assertEq(_auctionOf(c.sid).duration, 24 hours, "the old duration stays");
        vm.expectRevert(ICore.AuctionLive.selector);
        core.syncStatement(c.sid);
    }

    /// @dev eth pushed to the core by a refund of somebody else is a plain donation: `skim` books it all to the pot,
    /// and it never changes what `collectSales` books
    function test_state_aDonationFromTheHouseIsNotProceeds() public {
        (, uint256 price) = _sellStatement(alice);
        // bob is outbid with a contract that cannot receive, so the house owes him, then he sends it to the core
        uint256 sid2 = _composeSecond();
        DeafHolder deaf = new DeafHolder();
        _bid(address(deaf), sid2, _live(sid2).reserve);
        _bid(bob, sid2, _live(sid2).reserve * 106 / 100);
        uint256 owedDeaf = house.pendingRefunds(address(deaf));
        assertGt(owedDeaf, 0);
        deaf.pullTo(house, address(core));
        uint256 potBefore = core.ethPot();
        uint256 buyBefore = core.ethToBuyback();
        assertEq(_collectSales(), price, "proceeds are what the core was owed");
        assertEq(core.ethPot() + core.ethToBuyback(), potBefore + buyBefore + price, "the donation is not in there");
        core.skim();
        assertEq(
            core.ethPot() + core.ethToBuyback(), potBefore + buyBefore + price + owedDeaf, "skim books the donation"
        );
    }
}

contract DeafHolder {
    receive() external payable {
        revert("no");
    }

    function pullTo(IAuctionHouse h, address to) external {
        h.withdrawRefundTo(payable(to));
    }
}

interface IHouseExtra {
    function setAuctionFundsRecipient(uint256 id, address payable to) external;
    function recoverStuckERC721(address token, uint256 id, address to) external;
}
