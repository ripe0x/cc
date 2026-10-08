// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {
    CountingEngine,
    RefusingEngine,
    ReenteringEngine,
    GasBurnerEngine,
    RefusingCaller,
    GatePayee
} from "./attackers/FlushEngines.sol";

/// unit tests of the fee router (docs/FLOW.md 10.2 and 10.6). no fork: the router touches nothing outside itself
/// a payee that does real work on receipt, like a splitter that writes three fresh slots (about 66k gas)
contract WorkingPayee {
    uint256 public a;
    uint256 public b;
    uint256 public c;

    receive() external payable {
        a = 1;
        b = 2;
        c = 3;
    }
}

contract FeeRouterTest is Test {
    IFeeRouter internal r;
    address internal ownerA = makeAddr("router.owner");
    address internal other = makeAddr("router.other");
    CountingEngine internal eng;

    function setUp() public {
        r = IFeeRouter(payable(deployCode("FeeRouter.sol:FeeRouter", abi.encode(ownerA))));
        eng = new CountingEngine();
    }

    receive() external payable {}

    function _set(address e) internal {
        vm.prank(ownerA);
        r.setEngine(e);
    }

    // ------------------------------------------------------------------ receive

    /// the hook pushes with the stipend: a value call with zero gas gives the callee exactly 2,300
    function test_receiveFitsTheStipend() public {
        (bool ok,) = address(r).call{value: 1 ether, gas: 0}("");
        assertTrue(ok, "stipend push failed");
        assertEq(address(r).balance, 1 ether);
    }

    function test_receiveStipendPushWithEngineSetAndLocked() public {
        _set(address(eng));
        vm.prank(ownerA);
        r.lock();
        (bool ok,) = address(r).call{value: 3 ether, gas: 0}("");
        assertTrue(ok);
        assertEq(address(r).balance, 3 ether);
        assertEq(eng.calls(), 0, "a push never forwards");
    }

    function test_receiveWritesNothingAndLogsNothing() public {
        vm.recordLogs();
        vm.record();
        (bool ok,) = address(r).call{value: 1 ether, gas: 0}("");
        assertTrue(ok);
        assertEq(vm.getRecordedLogs().length, 0, "receive logged");
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(r));
        assertEq(reads.length, 0, "receive read storage");
        assertEq(writes.length, 0, "receive wrote storage");
    }

    /// the same with a call that forwards exactly 2,300 gas and no value
    function test_receiveFitsExactly2300Gas() public {
        (bool ok,) = address(r).call{gas: 2300}("");
        assertTrue(ok);
    }

    // ------------------------------------------------------------------ flush

    function _noTip() internal {
        vm.prank(ownerA);
        r.setTip(0, 0);
    }

    function test_flushSendsEverythingAfterTheTip() public {
        _set(address(eng));
        vm.deal(address(r), 1 ether);
        uint256 tip = 1 ether * 5_000 / 1_000_000;
        uint256 before = other.balance;
        vm.expectEmit(true, false, false, true, address(r));
        emit IFeeRouter.Flushed(address(eng), 1 ether - tip, tip, 0);
        vm.prank(other);
        r.flush();
        assertEq(address(r).balance, 0);
        assertEq(address(eng).balance, 1 ether - tip);
        assertEq(other.balance - before, tip, "tip to the caller");
        assertEq(eng.calls(), 1);
    }

    function test_tipIsCapped() public {
        _set(address(eng));
        vm.deal(address(r), 50 ether);
        uint256 before = other.balance;
        vm.prank(other);
        r.flush();
        assertEq(other.balance - before, 0.005 ether, "capped");
        assertEq(address(eng).balance, 50 ether - 0.005 ether);
    }

    function test_noTipFlushSendsAll() public {
        _noTip();
        _set(address(eng));
        vm.deal(address(r), 5 ether);
        vm.prank(other);
        r.flush();
        assertEq(address(eng).balance, 5 ether);
        assertEq(other.balance, 0);
    }

    function test_failedTipIsSkippedNeverARevert() public {
        _set(address(eng));
        RefusingCaller c = new RefusingCaller();
        vm.deal(address(r), 1 ether);
        vm.expectEmit(true, false, false, true, address(r));
        emit IFeeRouter.TipFailed(address(c), 0.005 ether);
        c.go(r);
        assertEq(address(eng).balance, 1 ether, "the tip went to the engine");
    }

    function test_flushRevertsWhileEngineUnset() public {
        vm.deal(address(r), 1 ether);
        vm.expectRevert(IFeeRouter.NoEngine.selector);
        r.flush();
        assertEq(address(r).balance, 1 ether, "eth waits");
    }

    function test_flushRevertsWhileEngineUnsetEvenWhenEmpty() public {
        vm.expectRevert(IFeeRouter.NoEngine.selector);
        r.flush();
    }

    function test_flushRevertsOnAFailingEngine() public {
        RefusingEngine bad = new RefusingEngine();
        _set(address(bad));
        vm.deal(address(r), 1 ether);
        uint256 before = address(this).balance;
        vm.expectRevert(IFeeRouter.FlushFailed.selector);
        r.flush();
        assertEq(address(r).balance, 1 ether, "nothing lost");
        assertEq(address(this).balance, before, "the tip reverted with it");
    }

    function test_flushWithNothingIsANoOp() public {
        _set(address(eng));
        vm.recordLogs();
        r.flush();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(eng.calls(), 0);
    }

    function test_flushForwardsAllGas() public {
        _noTip();
        _set(address(eng));
        vm.deal(address(r), 1 ether);
        r.flush{gas: 200_000}();
        assertEq(eng.received(), 1 ether);
    }

    function test_flushPicksUpForcedEth() public {
        _noTip();
        _set(address(eng));
        // a forced send does not run receive; vm.deal stands for selfdestruct or coinbase credit
        vm.deal(address(r), 7 wei);
        r.flush();
        assertEq(eng.received(), 7 wei);
    }

    function test_reentryDuringFlushCannotDoubleSend() public {
        _noTip();
        ReenteringEngine re = new ReenteringEngine(r);
        _set(address(re));
        vm.deal(address(r), 4 ether);
        r.flush();
        assertTrue(re.nestedDone());
        assertTrue(re.nestedReverted(), "nested flush must revert");
        assertEq(re.received(), 4 ether, "one send");
        assertEq(re.calls(), 1);
        assertEq(address(r).balance, 0);
    }

    function test_flushWorksAgainAfterAReentryAttempt() public {
        _noTip();
        ReenteringEngine re = new ReenteringEngine(r);
        _set(address(re));
        vm.deal(address(r), 1 ether);
        r.flush();
        vm.deal(address(r), 2 ether);
        r.flush();
        assertEq(re.received(), 3 ether);
    }

    // ------------------------------------------------------------------ split

    address internal payeeA = makeAddr("router.payeeA");
    address internal payeeB = makeAddr("router.payeeB");

    function _payees2() internal {
        address[] memory w = new address[](2);
        w[0] = payeeA;
        w[1] = payeeB;
        uint32[] memory p = new uint32[](2);
        p[0] = 80_515;
        p[1] = 80_515;
        vm.prank(ownerA);
        r.setPayees(w, p);
    }

    /// payees, no tip, split start 1 hour out, an engine
    function _splitSetup() internal {
        _noTip();
        _payees2();
        _set(address(eng));
        vm.prank(ownerA);
        r.setSplitStart(uint64(block.timestamp + 1 hours));
    }

    function test_splitStartsOnlyAfterTheWindowAndNeverSharesTheWindow() public {
        _splitSetup();
        vm.deal(address(r), 10 ether);
        r.flush();
        assertEq(eng.received(), 10 ether, "before the start everything goes to the engine");
        assertFalse(r.splitOn());

        // eth that arrived during the window, flushed at the start: still all to the engine, then the split is on
        vm.deal(address(r), 6 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(false, false, false, false, address(r));
        emit IFeeRouter.SplitStarted(block.timestamp);
        r.flush();
        assertEq(eng.received(), 16 ether, "the flush that starts the split shares nothing");
        assertTrue(r.splitOn());
        assertEq(payeeA.balance + payeeB.balance, 0);

        // from now on the payees get their parts per million, the engine the rest
        vm.deal(address(r), 100 ether);
        r.flush();
        assertEq(payeeA.balance, 100 ether * 80_515 / 1e6);
        assertEq(payeeB.balance, 100 ether * 80_515 / 1e6);
        assertEq(eng.received(), 16 ether + 100 ether - 2 * (100 ether * 80_515 / 1e6));
        assertEq(address(r).balance, 0);
    }

    function test_noSplitStartMeansNeverShared() public {
        _noTip();
        _payees2();
        _set(address(eng));
        vm.warp(block.timestamp + 365 days);
        vm.deal(address(r), 10 ether);
        r.flush();
        assertEq(eng.received(), 10 ether);
        assertFalse(r.splitOn());
    }

    function test_FIXED_payeesGetTheirShareOfTheGrossAndTheTipComesOutOfTheEngine() public {
        _payees2();
        _set(address(eng));
        vm.prank(ownerA);
        r.setSplitStart(uint64(block.timestamp));
        r.flush(); // empty: no op, the split is not on yet
        assertFalse(r.splitOn());
        vm.deal(address(r), 1 ether);
        r.flush(); // starts the split
        assertTrue(r.splitOn());
        vm.deal(address(r), 1 ether);
        uint256 engine0 = address(eng).balance;
        r.flush();
        // each payee has exactly its parts per million of the 1 eth inflow, the tip (0.5 percent) is not taken from them
        assertEq(payeeA.balance, 80_515_000_000_000_000);
        assertEq(payeeB.balance, 80_515_000_000_000_000);
        assertEq(address(eng).balance - engine0, 1 ether - 5_000_000_000_000_000 - 2 * 80_515_000_000_000_000);
    }

    function test_setSplitStartOnlyWhileTheSplitIsOff() public {
        _splitSetup();
        vm.warp(block.timestamp + 1 hours);
        vm.deal(address(r), 1 ether);
        r.flush();
        assertTrue(r.splitOn());
        vm.prank(ownerA);
        vm.expectRevert(IFeeRouter.SplitIsOn.selector);
        r.setSplitStart(0);
    }

    function _startSplitNow() internal {
        vm.warp(block.timestamp + 1 hours);
        vm.deal(address(r), 1 wei);
        r.flush();
        assertTrue(r.splitOn());
    }

    function test_aRefusingPayeeNeverBlocksAFlushAndCanClaimLater() public {
        _noTip();
        GatePayee gp = new GatePayee();
        address[] memory w = new address[](2);
        w[0] = address(gp);
        w[1] = payeeB;
        uint32[] memory p = new uint32[](2);
        p[0] = 100_000;
        p[1] = 50_000;
        vm.prank(ownerA);
        r.setPayees(w, p);
        _set(address(eng));
        vm.prank(ownerA);
        r.setSplitStart(uint64(block.timestamp));
        _startSplitNow();

        vm.deal(address(r), 10 ether);
        vm.expectEmit(true, false, false, true, address(r));
        emit IFeeRouter.PayeeOwed(address(gp), 1 ether);
        r.flush();
        assertEq(payeeB.balance, 0.5 ether);
        assertEq(r.owed(address(gp)), 1 ether);
        assertEq(r.totalOwed(), 1 ether);
        assertEq(address(r).balance, 1 ether, "the credit stays in the router");
        assertEq(eng.received(), 1 wei + 8.5 ether);

        // the owed eth is never forwarded by a later flush
        vm.deal(address(r), 1 ether + 2 ether);
        r.flush();
        assertEq(address(r).balance, 1.2 ether);
        assertEq(r.owed(address(gp)), 1.2 ether);

        // a claim fails while the payee refuses, and works for anyone once it takes eth
        vm.expectRevert(IFeeRouter.ClaimFailed.selector);
        r.claim(address(gp));
        gp.setOpen(true);
        vm.prank(other);
        r.claim(address(gp));
        assertEq(address(gp).balance, 1.2 ether);
        assertEq(r.totalOwed(), 0);
        vm.expectRevert(IFeeRouter.NothingOwed.selector);
        r.claim(address(gp));
    }

    /// a payee that burns its gas is capped at 100k and credited, the flush still succeeds
    function test_aGasBurningPayeeIsCappedAndCredited() public {
        _noTip();
        GasBurnerEngine burner = new GasBurnerEngine();
        address[] memory w = new address[](1);
        w[0] = address(burner);
        uint32[] memory p = new uint32[](1);
        p[0] = 200_000;
        vm.prank(ownerA);
        r.setPayees(w, p);
        _set(address(eng));
        vm.prank(ownerA);
        r.setSplitStart(uint64(block.timestamp));
        _startSplitNow();
        vm.deal(address(r), 5 ether);
        uint256 g = gasleft();
        r.flush();
        assertLt(g - gasleft(), 300_000, "the burner did not drain the flush");
        assertEq(r.owed(address(burner)), 1 ether);
        assertEq(eng.received(), 1 wei + 4 ether);
    }

    /// FLOW 10.7: a payee that is a splitter contract doing about 66k gas of work is paid directly, not credited
    function test_aWorkingPayeeContractIsPaidWithinTheGasCap() public {
        _noTip();
        WorkingPayee wp = new WorkingPayee();
        address[] memory w = new address[](1);
        w[0] = address(wp);
        uint32[] memory p = new uint32[](1);
        p[0] = 200_000;
        vm.prank(ownerA);
        r.setPayees(w, p);
        _set(address(eng));
        vm.prank(ownerA);
        r.setSplitStart(uint64(block.timestamp));
        _startSplitNow();
        vm.deal(address(r), 5 ether);
        r.flush();
        assertEq(address(wp).balance, 1 ether, "paid directly");
        assertEq(r.owed(address(wp)), 0, "nothing credited");
    }

    function test_claimIsGuardedAgainstReentryThroughTheEngine() public {
        _noTip();
        ReenteringEngine re = new ReenteringEngine(r);
        _set(address(re));
        vm.deal(address(r), 1 ether);
        r.flush();
        assertTrue(re.nestedReverted());
    }

    // ------------------------------------------------------------------ setters

    function test_setPayeesRules() public {
        address[] memory w = new address[](1);
        w[0] = payeeA;
        uint32[] memory p = new uint32[](1);
        p[0] = 1;
        vm.prank(other);
        vm.expectRevert(IFeeRouter.OnlyOwner.selector);
        r.setPayees(w, p);

        vm.startPrank(ownerA);
        // length mismatch
        vm.expectRevert(IFeeRouter.BadPayees.selector);
        r.setPayees(w, new uint32[](2));
        // zero share
        p[0] = 0;
        vm.expectRevert(IFeeRouter.BadPayees.selector);
        r.setPayees(w, p);
        // zero address and the router itself
        p[0] = 1;
        w[0] = address(0);
        vm.expectRevert(IFeeRouter.BadPayees.selector);
        r.setPayees(w, p);
        w[0] = address(r);
        vm.expectRevert(IFeeRouter.BadPayees.selector);
        r.setPayees(w, p);
        // more than 200,000 ppm in total
        w[0] = payeeA;
        p[0] = 200_001;
        vm.expectRevert(IFeeRouter.BadPayees.selector);
        r.setPayees(w, p);
        // exactly 200,000 is fine, five payees are not
        p[0] = 200_000;
        r.setPayees(w, p);
        assertEq(r.payeePpmTotal(), 200_000);
        address[] memory five = new address[](5);
        uint32[] memory fp = new uint32[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = address(uint160(0x1000 + i));
            fp[i] = 1;
        }
        vm.expectRevert(IFeeRouter.BadPayees.selector);
        r.setPayees(five, fp);
        // an empty list clears
        r.setPayees(new address[](0), new uint32[](0));
        (address[] memory got,) = r.payees();
        assertEq(got.length, 0);
        vm.stopPrank();
    }

    function test_setTipRules() public {
        vm.prank(other);
        vm.expectRevert(IFeeRouter.OnlyOwner.selector);
        r.setTip(1, 1);
        vm.startPrank(ownerA);
        vm.expectRevert(IFeeRouter.BadTip.selector);
        r.setTip(20_001, 0);
        vm.expectRevert(IFeeRouter.BadTip.selector);
        r.setTip(0, 0.05 ether + 1);
        r.setTip(20_000, 0.05 ether);
        vm.stopPrank();
        assertEq(r.tipPpm(), 20_000);
        assertEq(r.tipCap(), 0.05 ether);
    }

    function test_setEngineRules() public {
        vm.prank(other);
        vm.expectRevert(IFeeRouter.OnlyOwner.selector);
        r.setEngine(address(eng));

        vm.startPrank(ownerA);
        vm.expectRevert(IFeeRouter.ZeroAddress.selector);
        r.setEngine(address(0));
        vm.expectRevert(abi.encodeWithSelector(IFeeRouter.NoCode.selector, other));
        r.setEngine(other);

        vm.expectEmit(true, true, false, false, address(r));
        emit IFeeRouter.EngineSet(address(0), address(eng));
        r.setEngine(address(eng));
        CountingEngine second = new CountingEngine();
        vm.expectEmit(true, true, false, false, address(r));
        emit IFeeRouter.EngineSet(address(eng), address(second));
        r.setEngine(address(second));
        vm.stopPrank();
        assertEq(r.engine(), address(second), "many sets until locked");
    }

    function test_lockIsOneWayAndFreezesEverySetter() public {
        vm.prank(ownerA);
        vm.expectRevert(IFeeRouter.NoEngine.selector);
        r.lock();

        _set(address(eng));
        vm.prank(other);
        vm.expectRevert(IFeeRouter.OnlyOwner.selector);
        r.lock();

        vm.expectEmit(true, false, false, false, address(r));
        emit IFeeRouter.Locked(address(eng));
        vm.prank(ownerA);
        r.lock();
        assertTrue(r.locked());

        CountingEngine second = new CountingEngine();
        address[] memory w = new address[](0);
        uint32[] memory p = new uint32[](0);
        vm.startPrank(ownerA);
        vm.expectRevert(IFeeRouter.IsLocked.selector);
        r.setEngine(address(second));
        vm.expectRevert(IFeeRouter.IsLocked.selector);
        r.setPayees(w, p);
        vm.expectRevert(IFeeRouter.IsLocked.selector);
        r.setTip(0, 0);
        vm.expectRevert(IFeeRouter.IsLocked.selector);
        r.setSplitStart(1);
        vm.expectRevert(IFeeRouter.IsLocked.selector);
        r.lock();
        vm.stopPrank();
        assertEq(r.engine(), address(eng));

        // flush still works after the lock, and ownership can still move (it can no longer redirect)
        vm.deal(address(r), 1 ether);
        r.flush();
        assertEq(eng.received(), 1 ether - 0.005 ether);
        vm.prank(ownerA);
        r.transferOwnership(other);
        vm.prank(other);
        r.acceptOwnership();
        vm.prank(other);
        vm.expectRevert(IFeeRouter.IsLocked.selector);
        r.setEngine(address(second));
    }

    // ------------------------------------------------------------------ owner

    function test_twoStepOwner() public {
        assertEq(r.owner(), ownerA);
        vm.prank(other);
        vm.expectRevert(IFeeRouter.OnlyOwner.selector);
        r.transferOwnership(other);

        vm.prank(ownerA);
        r.transferOwnership(other);
        assertEq(r.pendingOwner(), other);
        assertEq(r.owner(), ownerA, "not yet");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IFeeRouter.OnlyPendingOwner.selector);
        r.acceptOwnership();

        vm.expectEmit(true, true, false, false, address(r));
        emit IFeeRouter.OwnershipTransferred(ownerA, other);
        vm.prank(other);
        r.acceptOwnership();
        assertEq(r.owner(), other);
        assertEq(r.pendingOwner(), address(0));

        vm.prank(ownerA);
        vm.expectRevert(IFeeRouter.OnlyOwner.selector);
        r.setEngine(address(eng));
    }

    function test_transferToZeroClearsPending() public {
        vm.startPrank(ownerA);
        r.transferOwnership(other);
        r.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(r.pendingOwner(), address(0));
        vm.prank(other);
        vm.expectRevert(IFeeRouter.OnlyPendingOwner.selector);
        r.acceptOwnership();
    }

    function test_constructorRefusesZeroOwner() public {
        vm.expectRevert(IFeeRouter.ZeroAddress.selector);
        this.deployRouter(address(0));
    }

    function deployRouter(address o) external returns (address) {
        return vm.deployCode("FeeRouter.sol:FeeRouter", abi.encode(o));
    }
}
