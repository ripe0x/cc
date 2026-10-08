// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {Lane} from "../../src/interfaces/Interfaces.sol";
import {InvariantsBase} from "./Invariants.t.sol";

/// @notice the invariant suites of the sale controller and the owner as an adversary. same real system, same invariants as
/// `InvariantsBase` (pots never above balances, every statement in one place, the owner and the controllers never gain)
/// plus 12, 13 and 14: a statement leaves only by an auction or a `sellTo` sale at or above the hard floor, an exit that
/// paid in full or an overprint; locks and handovers never come undone; no call from inside an exit ever goes through.
/// the fuzzer lists reprice then bid, `buy` in buy only mode, the selling controller, the sale settings, mode flips, the
/// owner replacing the controller and the exit module in one go, locks and the handover chain.
/// forge-config: default.invariant.runs = 16
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
abstract contract SaleSuite is InvariantsBase {
    function _saleSuite() internal pure override returns (bool) {
        return false;
    }

    function _saleActions() internal pure override returns (bool) {
        return true;
    }

    /// the base actions as before, then the eight of `HandlerSale`
    function _act(uint256 a, uint256 w, uint256 x, uint256 y, uint256 z) internal override {
        a = a % 40;
        if (a < 32) return super._act(a, w, x, y, z);
        if (a == 32) handler.buyOnlyBuy(w, x, y, z);
        else if (a == 33) handler.ownerSell(w, x, y, z);
        else if (a == 34) handler.repriceBid(w, x, y, z);
        else if (a == 35) handler.saleSettings(w, x);
        else if (a == 36) handler.flipMode(w, x);
        else if (a == 37) handler.hostileOwner(w, x);
        else if (a == 38) handler.lockDoor(w, x);
        else handler.handover(w, x);
    }

    function _owner() internal view returns (address) {
        return handler.owner();
    }

    function _ownerSets(address c) internal {
        vm.prank(_owner());
        core.setController(c);
    }

    function _buyOnly(bool on) internal {
        vm.prank(_owner());
        IControllerV1(address(ctl)).setBuyOnly(on);
    }

    /// the fresh state has two listed statements without a bid (and none sold in the window variant). the sale actions
    /// are driven through them, the owner swaps and locks come last. every one must succeed at least once, and the
    /// violation counters must stay at zero. the base `test_everyActionSucceeds` leaves the sale actions out because it
    /// uses the statements up on the old actions
    /// forge-config: default.gas_limit = 9223372036854775807
    function test_saleActionsEverySucceed() public {
        _ownerSets(address(ctl));
        _buyOnly(true);
        assertTrue(_try(32, 120), "no buy in buy only mode");
        assertTrue(_try(34, 120), "no reprice then bid");
        // credits in, a compose: one more listing for the selling controller
        _try(2, 40);
        _try(2, 40);
        _try(2, 40);
        assertTrue(_try(7, 80), "compose never succeeded");
        _ownerSets(address(handler.selling()));
        assertTrue(_try(33, 160), "no sale through the selling controller");
        _ownerSets(address(ctl));
        assertTrue(_try(35, 20), "no sale setting");
        assertTrue(_try(36, 20), "no mode flip");
        assertTrue(_try(37, 40), "no owner swap");
        assertTrue(_try(39, 160), "no handover");
        assertTrue(_try(38, 160), "no lock");
        assertGt(handler.gSoldTo(), 0, "no statement was sold at once");
        for (uint256 i = 1; i < handler.violationCount(); ++i) {
            assertEq(handler.viol(i), 0, handler.violMsg(i));
        }
        for (uint256 a = 32; a < 40; ++a) {
            assertEq(handler.unexpectedFails(a), 0, handler.actionName(a));
        }
    }

    /// the seeds at the top of the range must not overflow inside a handler action
    function test_saleActionsSurviveMaxSeeds() public {
        uint256 m = type(uint256).max;
        for (uint256 a = 32; a < 40; ++a) {
            _act(a, m, m, m, m);
            _act(a, 0, m, m - 1, m - 2);
        }
        for (uint256 i = 1; i < handler.violationCount(); ++i) {
            assertEq(handler.viol(i), 0, handler.violMsg(i));
        }
    }

    /// the hostile owner path with every sale action in a long fixed sequence of mixed calls: nothing reverts, no violation
    /// forge-config: default.gas_limit = 9223372036854775807
    function testFuzz_saleActionsNeverRevert(uint256 a, uint256 w, uint256 x, uint256 y, uint256 z) public {
        _act(32 + a % 8, w, x, y, z);
        for (uint256 i = 1; i < handler.violationCount(); ++i) {
            assertEq(handler.viol(i), 0, handler.violMsg(i));
        }
    }
}

/// phase 1 after the sniper window, the sale suite
/// forge-config: default.invariant.runs = 16
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsSalePhase1 is SaleSuite {
    function setUp() public virtual override {
        _build(false, false, true, false, "s1");
    }
}

/// phase 2 with the exit module set, the owner swapping module and controller at once, the fuzz controller benign
/// forge-config: default.invariant.runs = 16
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsSalePhase2 is SaleSuite {
    function setUp() public virtual override {
        _build(true, false, true, false, "s2");
    }

    function _ownerWeight() internal pure override returns (uint256) {
        return 2;
    }
}

/// phase 2 under the hostile controller: it fails and answers short, and the owner can swap it away and back
/// forge-config: default.invariant.runs = 16
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsSalePhase2Hostile is SaleSuite {
    function setUp() public virtual override {
        _build(true, true, false, false, "s3");
    }

    function _ownerWeight() internal pure override returns (uint256) {
        return 3;
    }
}

/// the same suites for deep runs: no inline config, skipped unless INVARIANT_DEEP is set
contract InvariantsSalePhase1Deep is InvariantsSalePhase1 {
    function setUp() public override {
        vm.skip(!vm.envOr("INVARIANT_DEEP", false));
        super.setUp();
    }
}

contract InvariantsSalePhase2Deep is InvariantsSalePhase2 {
    function setUp() public override {
        vm.skip(!vm.envOr("INVARIANT_DEEP", false));
        super.setUp();
    }
}
