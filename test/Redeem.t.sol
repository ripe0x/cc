// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Lane, Settings} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {SellingController, HostileModule, RepaidCaller} from "./attackers/SaleAttackers.sol";

/// phase 2 redemption: when an eth lane statement may be exited, what stops it, and the reimbursement of the caller's
/// gas from the eth pot. real Core, house, Statements. the stand in module and token, and the attacker modules
abstract contract RedeemBase is Fixture {
    using stdStorage for StdStorage;

    /// the most gas of an exit the reimbursement counts (a private constant of the core, restated here)
    uint256 internal constant EXIT_GAS = 1_500_000;
    uint256 internal constant NOTIONAL_COUNT = 80;
    HostileModule internal hm;

    function _cost(uint256 sid) internal view returns (uint256 cost) {
        (,, cost,) = core.statementInfo(sid);
    }

    function _listedAt(uint256 sid) internal view returns (uint64 at) {
        (,,, at) = core.statementInfo(sid);
    }

    /// phase 2 with a module that can burn gas and call out, same exit token as the stand in
    function _phase2Hostile() internal {
        _enterPhase2();
        hm = new HostileModule(address(xt), UNIT);
        _setExitModule(address(hm));
    }

    /// an exit lane statement: the seller sells 80 credits into the exit bid and the core composes them
    function _exitLaneStatement() internal returns (uint256 sid) {
        if (core.ethPot() < 1 ether) _fundPot(1 ether);
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.composeExit();
        sid = STATEMENTS.supply();
    }

    function _another() internal returns (uint256 sid) {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
    }

    function _setPot(uint256 v) internal {
        stdstore.target(address(core)).sig("ethPot()").checked_write(v);
        assertEq(core.ethPot(), v);
    }

    /// exits `sid` as the keeper at `basefee` and returns what the keeper was repaid and what the pot lost
    function _exit(uint256 sid, uint256 basefee) internal returns (uint256 repaid, uint256 potLost) {
        vm.fee(basefee);
        uint256 pot = core.ethPot();
        uint256 bal = keeper.balance;
        uint256 bb = core.ethToBuyback();
        vm.prank(keeper);
        core.exitStatement(sid);
        repaid = keeper.balance - bal;
        potLost = pot - core.ethPot();
        assertEq(core.ethToBuyback(), bb, "the buyback pot is not touched");
    }

    function _notionalCap() internal view returns (uint256) {
        Settings memory s = core.settings();
        uint256 base = NOTIONAL_COUNT * uint256(s.avgScore) * core.RATE_START() / 1e4;
        return base * s.reimburseCapBps / 10_000;
    }

    function _ethCap(uint256 sid) internal view returns (uint256) {
        return _cost(sid) * core.settings().reimburseCapBps / 10_000;
    }

    function _gasPart(uint256 gasCounted, uint256 basefee) internal view returns (uint256) {
        return gasCounted * basefee * core.settings().reimburseBps / 10_000;
    }
}

contract RedeemTimingTest is RedeemBase {
    function test_timing_revertsBeforeExitAfterAndWorksAtIt() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint64 at = _listedAt(sid);
        uint256 wait = core.settings().exitAfter;
        assertEq(wait, 105 hours);
        vm.warp(uint256(at));
        vm.expectRevert(ICore.TooEarly.selector);
        core.exitStatement(sid);
        vm.warp(uint256(at) + wait - 1);
        vm.expectRevert(ICore.TooEarly.selector);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(house), "still listed after the refused tries");
        vm.warp(uint256(at) + wait);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
        (bool held,,,) = core.statementInfo(sid);
        assertFalse(held);
        assertEq(core.xPot() + core.xToBuyback(), STATEMENTS.creditScoreOf(sid) * UNIT);
        _solvent();
    }

    function test_timing_exitAfterIsReadLive() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint64 at = _listedAt(sid);
        Settings memory s = core.settings();
        s.exitAfter = 365 days;
        _setSettings(s);
        vm.warp(uint256(at) + 200 days);
        vm.expectRevert(ICore.TooEarly.selector);
        core.exitStatement(sid);
        s.exitAfter = 1 hours;
        _setSettings(s);
        vm.warp(uint256(at) + 1 hours - 1);
        vm.expectRevert(ICore.TooEarly.selector);
        core.exitStatement(sid);
        vm.warp(uint256(at) + 1 hours);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    function test_timing_exitLaneIsImmediate() public {
        _enterPhase2();
        uint256 sid = _exitLaneStatement();
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    function test_timing_noModuleNotHeldAndUnknown() public {
        uint256 sid = _composeOnce().sid;
        _warp(105 hours);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.exitStatement(sid);
        _enterPhase2();
        vm.expectRevert(ICore.NotHeld.selector);
        core.exitStatement(sid + 99);
        vm.expectRevert(ICore.NotHeld.selector);
        core.exitStatement(0);
    }

    /// a bid before the exit wait ends makes the exit revert, and so does every later state until the sale is settled
    function test_timing_aBidFirstMakesTheExitRevert() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint64 at = _listedAt(sid);
        vm.warp(uint256(at) + 100 hours);
        address bidder = address(0xB1D1);
        _bid(bidder, sid, _live(sid).reserve);
        vm.warp(uint256(at) + 105 hours);
        uint256 pot = core.ethPot();
        uint256 bal = keeper.balance;
        vm.fee(composeBasefee);
        vm.prank(keeper);
        vm.expectRevert(ICore.HasBid.selector);
        core.exitStatement(sid);
        assertEq(core.ethPot(), pot, "nothing repaid");
        assertEq(keeper.balance, bal);
        // the auction has run its 24 hours: ended, not settled
        vm.warp(uint256(at) + 125 hours);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Ended));
        vm.expectRevert(ICore.HasBid.selector);
        core.exitStatement(sid);
        // settled: the record is stale, then gone
        _endAuction(sid);
        vm.expectRevert(ICore.NotListed.selector);
        core.exitStatement(sid);
        core.syncStatement(sid);
        vm.expectRevert(ICore.NotHeld.selector);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), bidder);
    }

    function test_timing_aBidAfterTheWaitAlsoRevertsAndTheBidderKeepsTheAuction() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _warp(105 hours);
        _bid(address(0xB1D1), sid, _live(sid).reserve);
        vm.expectRevert(ICore.HasBid.selector);
        core.exitStatement(sid);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Bid));
    }

    function test_timing_aBuyOnlySaleFirstMakesTheExitRevert() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        vm.prank(owner);
        ctl.setBuyOnly(true);
        _warp(105 hours);
        uint256 price = ctl.priceOf(sid);
        vm.deal(address(0xB0B), price);
        vm.prank(address(0xB0B));
        ctl.buy{value: price}(sid);
        vm.expectRevert(ICore.NotHeld.selector);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(0xB0B));
    }

    function test_timing_aSellToSaleFirstMakesTheExitRevert() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        SellingController sc = new SellingController(core);
        _setController(address(sc));
        uint256 floor = _cost(sid) * 7_500 / 10_000;
        sc.sell{value: floor}(sid, address(0xB0B));
        _warp(105 hours);
        vm.expectRevert(ICore.NotHeld.selector);
        core.exitStatement(sid);
    }

    /// redemption never depends on the controller: a broken one, a missing one, a locked one
    function test_timing_independentOfTheController() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        ScriptedController sc = new ScriptedController();
        sc.setRevertPrice(true);
        sc.setRevertPage(true);
        sc.setRevertWants(true);
        _setController(address(sc));
        vm.prank(owner);
        core.lockController();
        _warp(105 hours);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    /// a module that pays less than rating times unit is refused: nothing moves and nothing is repaid
    function test_timing_anUnderpayingModuleRevertsEverything() public {
        _phase2Hostile();
        uint256 sid = _composeOnce().sid;
        _warp(105 hours);
        hm.setPayBps(9_999);
        uint256 pot = core.ethPot();
        uint256 xpot = core.xPot();
        uint256 bal = keeper.balance;
        vm.prank(keeper);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(sid);
        assertEq(core.ethPot(), pot);
        assertEq(core.xPot(), xpot);
        assertEq(keeper.balance, bal);
        assertEq(STATEMENTS.ownerOf(sid), address(house), "the listing is whole");
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Listed));
        hm.setPayBps(10_000);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(hm));
    }
}

contract RedeemRepayTest is RedeemBase {
    uint256 internal constant LOW = 0.2 gwei;
    uint256 internal constant HIGH = 100 gwei;

    function _ethStatementReady() internal returns (uint256 sid) {
        _phase2Hostile();
        sid = _composeOnce().sid;
        _warp(105 hours);
    }

    /// eth lane, a module that burns more than the count allows: the count is capped at EXIT_GAS, so the repayment
    /// is exactly EXIT_GAS * basefee * reimburseBps
    function test_repay_ethLaneGasCountIsCappedExactly() public {
        uint256 sid = _ethStatementReady();
        hm.setBurn(4_000_000);
        uint256 cap = _ethCap(sid);
        uint256 want = _gasPart(EXIT_GAS, LOW);
        assertEq(want, 240_000_000_000_000, "1.5M gas at 0.2 gwei and 80 percent");
        assertLt(want, cap, "the cost cap does not bind here");
        (uint256 repaid, uint256 potLost) = _exit(sid, LOW);
        assertEq(repaid, want);
        assertEq(potLost, want, "paid from the pot, to the wei");
        _solvent();
    }

    function test_repay_ethLaneCostCapBindsExactly() public {
        uint256 sid = _ethStatementReady();
        hm.setBurn(4_000_000);
        uint256 cap = _ethCap(sid);
        assertGt(_gasPart(EXIT_GAS, HIGH), cap);
        uint256 cost = _cost(sid);
        (uint256 repaid, uint256 potLost) = _exit(sid, HIGH);
        assertEq(repaid, cap, "reimburseCapBps of the statement cost");
        assertEq(repaid, cost * 500 / 10_000);
        assertEq(potLost, cap);
    }

    function test_repay_ethLanePotBindsExactly() public {
        uint256 sid = _ethStatementReady();
        hm.setBurn(4_000_000);
        _setPot(1e12);
        (uint256 repaid, uint256 potLost) = _exit(sid, HIGH);
        assertEq(repaid, 1e12, "the whole pot");
        assertEq(potLost, 1e12);
        assertEq(core.ethPot(), 0);
        assertEq(core.funded(), false);
    }

    function test_repay_zeroPotPaysZeroAndDoesNotRevert() public {
        uint256 sid = _ethStatementReady();
        _setPot(0);
        (uint256 repaid,) = _exit(sid, HIGH);
        assertEq(repaid, 0);
        assertEq(STATEMENTS.ownerOf(sid), address(hm), "the exit went through");
        assertEq(core.ethPot(), 0);
    }

    function test_repay_exitLaneUsesTheNotionalCap() public {
        _phase2Hostile();
        uint256 sid = _exitLaneStatement();
        hm.setBurn(4_000_000);
        uint256 cap = _notionalCap();
        assertEq(cap, uint256(80) * core.settings().avgScore * 4e12 / 1e4 * 500 / 10_000);
        assertGt(_gasPart(EXIT_GAS, HIGH), cap);
        (uint256 repaid, uint256 potLost) = _exit(sid, HIGH);
        assertEq(repaid, cap, "a page at the opening rate and the average score, reimburseCapBps of it");
        assertEq(potLost, cap);
    }

    function test_repay_exitLaneGasCountIsCappedExactly() public {
        _phase2Hostile();
        uint256 sid = _exitLaneStatement();
        hm.setBurn(4_000_000);
        uint256 want = _gasPart(EXIT_GAS, LOW);
        assertLt(want, _notionalCap());
        (uint256 repaid, uint256 potLost) = _exit(sid, LOW);
        assertEq(repaid, want);
        assertEq(potLost, want);
    }

    function test_repay_exitLanePotBindsAndZeroPotPaysZero() public {
        _phase2Hostile();
        uint256 sid = _exitLaneStatement();
        uint256 sid2 = _exitLaneStatement();
        _setPot(7_777);
        (uint256 repaid,) = _exit(sid, HIGH);
        assertEq(repaid, 7_777);
        assertEq(core.ethPot(), 0);
        (repaid,) = _exit(sid2, HIGH);
        assertEq(repaid, 0);
        assertEq(STATEMENTS.ownerOf(sid2), address(hm));
    }

    /// the natural regime: the counted gas is what the exit used plus the fixed overhead, at most EXIT_GAS. with the
    /// ratio at 100 percent the repayment is counted gas times basefee, so the count can be read back
    function _natural(uint256 sid) internal {
        Settings memory s = core.settings();
        s.reimburseBps = 10_000;
        _setSettings(s);
        uint256 basefee = 1 gwei;
        vm.fee(basefee);
        uint256 bal = keeper.balance;
        uint256 g0 = gasleft();
        vm.prank(keeper);
        core.exitStatement(sid);
        uint256 used = g0 - gasleft();
        uint256 repaid = keeper.balance - bal;
        assertEq(repaid % basefee, 0);
        uint256 counted = repaid / basefee;
        assertGt(counted, 50_000, "the overhead and the work");
        assertLe(counted, EXIT_GAS);
        // the meter is gross gas and the caller pays net of the EIP-3529 refund (up to 20 percent of the gross), so at
        // the launch share of 80 percent the repayment is at most the net gas of the call plus the 50_000 overhead
        assertLe(counted * 8_000 / 10_000, used + 50_000, "never more than the caller's own net gas plus the overhead");
        assertGe(counted + 150_000, used, "and not far below it: the caller's gas is what is repaid");
    }

    function test_repay_naturalCountEthLane() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _warp(105 hours);
        _natural(sid);
    }

    function test_repay_naturalCountExitLane() public {
        _enterPhase2();
        _natural(_exitLaneStatement());
    }

    /// never above the cap or the pot, for any basefee, with a module that burns as much as it likes
    function test_repay_neverAboveTheCapWithAGasBurningModule() public {
        uint256[8] memory fees = [uint256(0), 1, 1e6, 1e9, 1e10, 1e11, 1e12, 1e15];
        for (uint256 lane; lane < 2; ++lane) {
            for (uint256 i; i < fees.length; ++i) {
                uint256 snap = vm.snapshotState();
                _phase2Hostile();
                uint256 sid;
                uint256 cap;
                if (lane == 0) {
                    sid = _composeOnce().sid;
                    _warp(105 hours);
                    cap = _ethCap(sid);
                } else {
                    sid = _exitLaneStatement();
                    cap = _notionalCap();
                }
                hm.setBurn(20_000_000);
                uint256 pot = core.ethPot();
                uint256 want = _gasPart(EXIT_GAS, fees[i]);
                if (want > cap) want = cap;
                if (want > pot) want = pot;
                (uint256 repaid, uint256 potLost) = _exit(sid, fees[i]);
                assertEq(repaid, want, "min of the gas part, the cost cap and the pot");
                assertLe(repaid, cap);
                assertLe(repaid, pot);
                assertEq(potLost, repaid);
                _solvent();
                vm.revertToState(snap);
            }
        }
    }

    function test_repay_zeroRatioAndZeroCapPayNothing() public {
        uint256 sid = _ethStatementReady();
        Settings memory s = core.settings();
        s.reimburseBps = 0;
        _setSettings(s);
        (uint256 repaid,) = _exit(sid, HIGH);
        assertEq(repaid, 0);
        uint256 b = _another();
        s.reimburseBps = 15_000;
        s.reimburseCapBps = 0;
        _setSettings(s);
        _warp(105 hours);
        (repaid,) = _exit(b, HIGH);
        assertEq(repaid, 0, "a zero cost cap pays nothing");
        assertEq(STATEMENTS.ownerOf(b), address(hm));
    }

    function test_repay_nothingIsAddedToTheBooksOnlyThePotPays() public {
        uint256 sid = _ethStatementReady();
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        uint256 bal = address(core).balance;
        uint256 xp = core.xPot();
        uint256 xb = core.xToBuyback();
        uint256 owed = STATEMENTS.creditScoreOf(sid) * UNIT;
        (uint256 repaid,) = _exit(sid, LOW);
        assertGt(repaid, 0);
        assertEq(core.ethPot(), pot - repaid);
        assertEq(core.ethToBuyback(), bb);
        assertEq(address(core).balance, bal - repaid, "the balance fell by the repayment only");
        uint256 toBb = owed * core.settings().exitToBuybackBps / 10_000;
        assertEq(core.xToBuyback() - xb, toBb);
        assertEq(core.xPot() - xp, owed - toBb);
        // the funded flag follows the pot
        Settings memory s = core.settings();
        assertEq(core.funded(), core.ethPot() * s.spendCapBps >= uint256(s.avgScore) * core.rateAtCheckpoint());
    }

    // ------------------------------------------------------------------ reentrancy

    /// the repayment is paid after all state is final: a caller that re enters from its receive finds every door shut
    function test_reenter_theRepaidCallerFindsEveryDoorShut() public {
        _enterPhase2();
        uint256 a = _composeOnce().sid;
        uint256 b = _another();
        RepaidCaller rc = new RepaidCaller(core);
        _warp(105 hours);
        vm.fee(LOW);
        uint256 pot = core.ethPot();
        uint256 bal = address(rc).balance;
        rc.exit(a, b);
        assertEq(rc.hits(), 1, "it was repaid once");
        assertEq(rc.blocked(), 9, "all nine doors refused it");
        assertEq(rc.ok(), 0);
        assertGt(address(rc).balance - bal, 0);
        assertEq(core.ethPot(), pot - rc.repaid(), "the pot paid it once");
        assertEq(STATEMENTS.ownerOf(a), address(mod));
        assertEq(STATEMENTS.ownerOf(b), address(house), "the other statement is untouched");
        _solvent();
    }

    /// a module that calls the core while the core is inside the exit
    function test_reenter_aHostileModuleCannotUseAnyDoorMidExit() public {
        bytes4 guard = bytes4(0xab143c06);
        for (uint256 k; k < 8; ++k) {
            uint256 snap = vm.snapshotState();
            _phase2Hostile();
            uint256 a = _composeOnce().sid;
            uint256 b = _another();
            SellingController sc = new SellingController(core);
            _setController(address(sc));
            bytes memory data;
            address target = address(core);
            if (k == 0) data = abi.encodeCall(ICore.compose, ());
            else if (k == 1) data = abi.encodeCall(ICore.skim, ());
            else if (k == 2) data = abi.encodeCall(ICore.collectSales, ());
            else if (k == 3) data = abi.encodeCall(ICore.exitStatement, (b));
            else if (k == 4) data = abi.encodeCall(ICore.repriceStatement, (b));
            else if (k == 5) data = abi.encodeCall(ICore.syncStatement, (b));
            else if (k == 6) data = abi.encodeCall(ICore.buyback, ());
            else {
                target = address(sc);
                data = abi.encodeCall(SellingController.sell, (b, address(hm)));
            }
            hm.setCall(target, data);
            _warp(105 hours);
            vm.prank(keeper);
            core.exitStatement(a);
            assertTrue(hm.called());
            assertFalse(hm.calledOk(), "the call mid exit failed");
            assertEq(bytes4(hm.calledOut()), guard, "with the reentrancy guard");
            assertEq(STATEMENTS.ownerOf(a), address(hm));
            assertEq(STATEMENTS.ownerOf(b), address(house));
            _solvent();
            vm.revertToState(snap);
        }
    }
}
