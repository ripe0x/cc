// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Lane, Settings} from "../src/interfaces/Interfaces.sol";

/// the sale controller and the fee share on the live fork: the asking price and its decay, repricing, buy only mode
/// through `sellTo`, the hard floor, the pool fee split and the redeem reimbursement
contract SaleSmokeTest is Fixture {
    function _cost(uint256 sid) internal view returns (uint256 cost) {
        (,, cost,) = core.statementInfo(sid);
    }

    function _buyOnly() internal {
        vm.prank(owner);
        ctl.setBuyOnly(true);
    }

    function test_listing_opens_at_the_start_price_of_the_controller() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        assertEq(_live(sid).reserve, cost * 11_000 / 10_000, "reserve is 110 percent");
        assertEq(ctl.priceOf(sid), cost * 11_000 / 10_000, "ask is 110 percent");
    }

    function test_price_falls_one_point_per_three_hours_to_the_floor() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _warp(3 hours);
        assertEq(ctl.priceOf(sid), cost * 10_900 / 10_000, "one step");
        _warp(30 hours);
        assertEq(ctl.priceOf(sid), cost * 9_900 / 10_000, "eleven steps");
        _warp(72 hours);
        assertEq(ctl.priceOf(sid), cost * 7_500 / 10_000, "at the floor at hour 105");
        _warp(100 hours);
        assertEq(ctl.priceOf(sid), cost * 7_500 / 10_000, "never below the floor");
    }

    function test_reprice_takes_the_current_ask_as_the_house_reserve() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _warp(30 hours);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost, "reserve follows the ask, ten steps down to 100 percent");
        _bid(address(0xB1D), sid, cost);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Bid));
    }

    function test_buy_reverts_in_auction_mode() public {
        uint256 sid = _composeOnce().sid;
        vm.deal(address(0xB0B), 10 ether);
        vm.prank(address(0xB0B));
        vm.expectRevert(IControllerV1.NotBuyOnly.selector);
        ctl.buy{value: 10 ether}(sid);
    }

    function test_buy_only_sells_at_once_and_refunds_the_excess() public {
        uint256 sid = _composeOnce().sid;
        _buyOnly();
        _warp(6 hours);
        uint256 price = ctl.priceOf(sid);
        uint256 potBefore = core.ethPot();
        uint256 bbBefore = core.ethToBuyback();
        address buyer = address(0xB0B);
        vm.deal(buyer, price + 1 ether);
        vm.prank(buyer);
        ctl.buy{value: price + 1 ether}(sid);
        assertEq(STATEMENTS.ownerOf(sid), buyer, "statement delivered");
        assertEq(buyer.balance, 1 ether, "excess refunded");
        uint256 toBuyback = price * core.settings().saleToBuybackBps / 10_000;
        assertEq(core.ethToBuyback() - bbBefore, toBuyback, "buyback share booked");
        assertEq(core.ethPot() - potBefore, price - toBuyback, "rest to the pot");
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.None), "record cleared");
        _solvent();
    }

    function test_buy_with_a_live_bid_reverts_and_the_auction_wins() public {
        uint256 sid = _composeOnce().sid;
        _buyOnly();
        _bid(address(0xB1D), sid, _live(sid).reserve);
        address buyer = address(0xB0B);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        vm.expectRevert(ICore.HasBid.selector);
        ctl.buy{value: 10 ether}(sid);
    }

    function test_buy_below_the_price_reverts() public {
        uint256 sid = _composeOnce().sid;
        _buyOnly();
        uint256 price = ctl.priceOf(sid);
        vm.deal(address(0xB0B), price);
        vm.prank(address(0xB0B));
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy{value: price - 1}(sid);
    }

    function test_sellTo_is_for_the_controller_only() public {
        uint256 sid = _composeOnce().sid;
        vm.deal(address(0xB0B), 10 ether);
        vm.prank(address(0xB0B));
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo{value: 10 ether}(sid, address(0xB0B));
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo{value: 10 ether}(sid, owner);
    }

    function test_the_core_floor_binds_a_lower_controller_price() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _buyOnly();
        Settings memory s = core.settings();
        s.saleFloorBps = 12_000;
        _setSettings(s);
        // the controller still asks 110 percent, the quote and the payment are lifted to the new floor of 120 percent
        address buyer = address(0xB0B);
        uint256 ask = ctl.priceOf(sid);
        assertEq(ask, cost * 12_000 / 10_000, "the quote is the hard floor");
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 12_000 / 10_000, "reserve floored");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        ctl.buy{value: ask}(sid);
        assertEq(STATEMENTS.ownerOf(sid), buyer, "sold at the floor, buy only mode is alive");
    }

    function test_pool_fees_split_by_feeToBuybackBps() public {
        address hook = lc.stack.hook;
        vm.deal(hook, 10 ether);
        uint256 pot = core.ethPot();
        vm.prank(hook);
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(core.ethPot() - pot, 1 ether, "launch value 0: all to the pot");
        assertEq(core.ethToBuyback(), 0);
        Settings memory s = core.settings();
        s.feeToBuybackBps = 4_000;
        _setSettings(s);
        pot = core.ethPot();
        vm.prank(hook);
        (ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(core.ethToBuyback(), 0.4 ether, "forty percent to the buyback");
        assertEq(core.ethPot() - pot, 0.6 ether, "the rest to the pot");
        _solvent();
    }

    function test_redeem_repays_the_caller_gas_from_the_pot() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _warp(core.settings().exitAfter);
        vm.fee(composeBasefee);
        uint256 pot = core.ethPot();
        uint256 before_ = keeper.balance;
        vm.prank(keeper);
        core.exitStatement(sid);
        uint256 got = keeper.balance - before_;
        assertGt(got, 0, "caller repaid");
        assertLe(got, cost * core.settings().reimburseCapBps / 10_000, "capped");
        assertEq(pot - core.ethPot(), got, "paid from the pot");
        _solvent();
    }
}
