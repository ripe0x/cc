// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Lane, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {ProbeTarget} from "./attackers/ProbeTarget.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";

/// the owner of the core after the timelock was removed: every former queued action is one immediate call with its
/// validity rules, three one way locks, a two step handover. real Core, real stack, the stand in exit module and
/// token, the scripted controller
abstract contract OwnerBase is Fixture {
    MockExitToken internal spareToken;
    MockExitModule internal spareMod;
    address internal stranger = address(0x5757);
    address internal heir = address(0xEE11);

    function setUp() public virtual override {
        super.setUp();
        spareToken = new MockExitToken("Spare Token", "SPT");
        spareMod = new MockExitModule(address(spareToken), UNIT);
        vm.deal(heir, 10 ether);
    }

    /// built from its artifact so no test contract embeds its creation code
    function _scripted() internal returns (ScriptedController) {
        return ScriptedController(deployCode("ScriptedController.sol:ScriptedController"));
    }

    // ------------------------------------------------------------------ the six doors, as a table

    uint256 internal constant D_CONTROLLER = 0;
    uint256 internal constant D_MODULE = 1;
    uint256 internal constant D_TARGETS = 2;
    uint256 internal constant D_SETTINGS = 3;
    uint256 internal constant D_RATE = 4;
    uint256 internal constant D_XRATE = 5;
    uint256 internal constant D_REMOVE = 6;
    uint256 internal constant D_HANDOVER = 7;
    uint256 internal constant N_DOORS = 8;

    function _doorData(uint256 i) internal returns (bytes memory) {
        if (i == D_CONTROLLER) return abi.encodeCall(ICore.setController, (address(_scripted())));
        if (i == D_MODULE) {
            address token = core.exitToken() == address(0) ? address(spareToken) : core.exitToken();
            return abi.encodeCall(ICore.setExitModule, (address(new MockExitModule(token, UNIT))));
        }
        if (i == D_TARGETS) {
            return abi.encodeCall(ICore.addTarget, (address(uint160(0xA0000 + block.number + gasleft() % 97))));
        }
        if (i == D_SETTINGS) return abi.encodeCall(ICore.setSettings, (core.settings()));
        if (i == D_RATE) return abi.encodeCall(ICore.setRate, (core.rateAtCheckpoint()));
        if (i == D_XRATE) return abi.encodeCall(ICore.setXRate, (core.xRate()));
        if (i == D_REMOVE) return abi.encodeCall(ICore.removeTarget, (address(0xDEAD1)));
        return abi.encodeCall(ICore.transferOwnership, (address(0)));
    }

    /// calls door `i` as `who`
    function _call(uint256 i, address who) internal returns (bool ok, bytes memory out) {
        bytes memory data = _doorData(i);
        vm.prank(who);
        (ok, out) = address(core).call(data);
    }

    function _sel(bytes memory out) internal pure returns (bytes4 s) {
        if (out.length >= 4) s = bytes4(out);
    }

    /// every door but `except` opens for `who`
    function _openExcept(uint256 except, address who) internal {
        for (uint256 i; i < N_DOORS; ++i) {
            if (i == except) continue;
            (bool ok, bytes memory out) = _call(i, who);
            assertTrue(ok, string.concat("door ", vm.toString(i), " is shut: ", vm.toString(_sel(out))));
        }
    }

    function _allShutFor(address who) internal {
        for (uint256 i; i < N_DOORS; ++i) {
            (bool ok, bytes memory out) = _call(i, who);
            assertFalse(ok, string.concat("door ", vm.toString(i), " is open"));
            assertEq(_sel(out), ICore.OnlyOwner.selector, "not the owner error");
        }
        vm.prank(who);
        (bool ok2, bytes memory out2) = address(core).call(abi.encodeCall(ICore.lockController, ()));
        assertTrue(!ok2 && _sel(out2) == ICore.OnlyOwner.selector);
        vm.prank(who);
        (ok2, out2) = address(core).call(abi.encodeCall(ICore.lockExitModule, ()));
        assertTrue(!ok2 && _sel(out2) == ICore.OnlyOwner.selector);
        vm.prank(who);
        (ok2, out2) = address(core).call(abi.encodeCall(ICore.lockTargets, ()));
        assertTrue(!ok2 && _sel(out2) == ICore.OnlyOwner.selector);
    }
}

contract OwnerFormerQueueTest is OwnerBase {
    // ------------------------------------------------------------------ setController

    function test_controller_takesEffectInTheSameBlock() public {
        uint256[] memory ids = _credits(seller, 1);
        uint256 base = core.ceilingOf(ids[0]);
        ScriptedController sc = _scripted();
        sc.setWants(ids[0], 1_000);
        uint256 t = block.timestamp;
        uint256 n = block.number;
        vm.expectEmit(address(core));
        emit ICore.ControllerSet(address(sc));
        _setController(address(sc));
        assertEq(core.controller(), address(sc));
        assertEq(block.timestamp, t);
        assertEq(block.number, n);
        assertApproxEqAbs(core.ceilingOf(ids[0]), base * 11_000 / 10_000, 2, "the new bonus applies at once");
        sc.setWants(ids[0], 0);
        assertEq(core.ceilingOf(ids[0]), base, "and the controller is read live");
    }

    function test_controller_zeroRevertsAndStrangerRevertsAndASecondSetWorks() public {
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setController(address(0));
        vm.prank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setController(address(0x1234));
        _setController(address(0x1234));
        _setController(address(ctl));
        assertEq(core.controller(), address(ctl));
    }

    /// compose runs under the new controller in the same block it was set
    function test_controller_composeUsesTheNewControllerAtOnce() public {
        _fillEthPile(80);
        ScriptedController sc = _scripted();
        uint256[] memory page = core.pilePage(Lane.Eth, 0, 80);
        uint256[80] memory p;
        for (uint256 i; i < 80; ++i) {
            p[i] = page[i];
        }
        sc.setPage(Lane.Eth, true, p, 0);
        sc.setPriceBps(13_000);
        _setController(address(sc));
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        (,, uint256 cost,) = core.statementInfo(sid);
        assertEq(_live(sid).reserve, cost * 13_000 / 10_000, "listed at the new controller price");
    }

    // ------------------------------------------------------------------ setExitModule

    function test_module_firstSetTakesEffectInTheSameBlock() public {
        vm.expectEmit(address(core));
        emit ICore.ExitModuleSet(address(spareMod), address(spareToken), UNIT);
        _setExitModule(address(spareMod));
        assertEq(core.exitModule(), address(spareMod));
        assertEq(core.exitToken(), address(spareToken));
        assertEq(core.unitPerPoint(), UNIT);
        assertEq(core.xStartTime(), block.timestamp, "the exit auction opens now");
        assertGt(core.xStartPrice(), 0);
        // the exit side is live in the same block
        uint256[] memory ids = _credits(seller, 1);
        spareToken.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        assertEq(CREDITS.ownerOf(ids[0]), address(core));
    }

    function test_module_validityRulesAreIntact() public {
        vm.startPrank(owner);
        // no code
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(0xBEEF));
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(0));
        // a token without code
        MockExitModule m = new MockExitModule(address(0xBEEF), UNIT);
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(m));
        // a forbidden token: the coin, the credits
        m = new MockExitModule(address(coin), UNIT);
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(m));
        m = new MockExitModule(address(CREDITS), UNIT);
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(m));
        // a zero unit, a unit above uint128, a unit read that reverts, a unit the opening price cannot carry
        m = new MockExitModule(address(spareToken), 0);
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(m));
        m = new MockExitModule(address(spareToken), uint256(type(uint128).max) + 1);
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(m));
        m = new MockExitModule(address(spareToken), UNIT);
        m.setRevertUnit(true);
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(m));
        m = new MockExitModule(address(spareToken), 1e28);
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(m));
        vm.stopPrank();
        assertEq(core.exitModule(), address(0), "every refused set changed nothing");
        assertEq(core.exitToken(), address(0));
        assertEq(core.unitPerPoint(), 0);
        vm.prank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setExitModule(address(spareMod));
    }

    function test_module_replaceKeepsTheTokenAndReadsTheUnitAgain() public {
        _setExitModule(address(spareMod));
        MockExitModule second = new MockExitModule(address(spareToken), 3e10);
        _setExitModule(address(second));
        assertEq(core.exitModule(), address(second));
        assertEq(core.unitPerPoint(), 3e10, "the unit of the new module");
        // the same module again after its unit changed
        second.setUnitPerPoint(4e10);
        _setExitModule(address(second));
        assertEq(core.unitPerPoint(), 4e10, "the unit is read again");
        // another exit token is refused
        MockExitModule other = new MockExitModule(address(new MockExitToken("Other", "OTH")), UNIT);
        vm.prank(owner);
        vm.expectRevert(ICore.ExitTokenChanged.selector);
        core.setExitModule(address(other));
        assertEq(core.exitModule(), address(second));
        assertEq(core.unitPerPoint(), 4e10);
    }

    // ------------------------------------------------------------------ addTarget

    function test_target_addTakesEffectInTheSameBlock() public {
        address t = address(0xA11E);
        uint256 id = 35377;
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(0, "", id, t);
        vm.expectEmit(address(core));
        emit ICore.TargetAdded(t);
        _allow(t);
        assertTrue(core.allowedTarget(t));
        // the same call now passes the allow list and fails further in
        vm.expectRevert(ICore.NoCredit.selector);
        core.buyListing(0, "", id, t);
        vm.expectEmit(address(core));
        emit ICore.TargetRemoved(t);
        vm.prank(owner);
        core.removeTarget(t);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(0, "", id, t);
    }

    function test_target_forbiddenAddressesAreRefused() public {
        address[15] memory bad = [
            address(CREDITS),
            address(STATEMENTS),
            address(core),
            address(coin),
            core.HOOK(),
            core.FEE_SOURCE(),
            address(PM),
            core.FACTORY(),
            core.LOCKER(),
            core.ESCROW(),
            address(house),
            core.AUCTION_FACTORY(),
            Mainnet.PERMIT2,
            Mainnet.POSITION_MANAGER,
            Mainnet.UNIVERSAL_ROUTER
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addTarget(bad[i]);
            assertFalse(core.allowedTarget(bad[i]));
        }
        // the exit module and the exit token join the list once set, and a flag set earlier on the module is cleared
        address early = address(spareMod);
        _allow(early);
        assertTrue(core.allowedTarget(early));
        _setExitModule(early);
        assertFalse(core.allowedTarget(early), "the module set cleared the old flag");
        vm.startPrank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(early);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(spareToken));
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.addTarget(address(0xA11E));
    }

    function test_target_removeIsImmediateAndHarmlessForUnknown() public {
        _allow(address(0xA11E));
        vm.startPrank(owner);
        core.removeTarget(address(0xA11E));
        core.removeTarget(address(0xA11E));
        core.removeTarget(address(0x1));
        vm.stopPrank();
        assertFalse(core.allowedTarget(address(0xA11E)));
        // the launch targets are removable too
        assertTrue(core.allowedTarget(Mainnet.SEAPORT));
        vm.prank(owner);
        core.removeTarget(Mainnet.SEAPORT);
        assertFalse(core.allowedTarget(Mainnet.SEAPORT));
    }

    // ------------------------------------------------------------------ the queue is gone

    function test_queue_noQueueNoDelayNoCancelNoFreezeNoImmutableOwner() public {
        string[8] memory sigs = [
            "queue(uint8,bytes)",
            "execute(uint8,bytes)",
            "cancel(uint8,bytes)",
            "TIMELOCK()",
            "OWNER()",
            "frozen()",
            "queuedEta(bytes32)",
            "renounceOwnership()"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(core).call(abi.encodeWithSignature(sigs[i], uint8(0), bytes("")));
            assertFalse(ok, sigs[i]);
        }
    }
}

contract OwnerLocksTest is OwnerBase {
    function _lockedErr(bytes32 what) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ICore.Locked.selector, what);
    }

    function test_lockController_blocksOnlyTheControllerSetterForever() public {
        assertFalse(core.controllerLocked());
        vm.expectEmit(address(core));
        emit ICore.ControllerLocked();
        vm.prank(owner);
        core.lockController();
        assertTrue(core.controllerLocked());
        assertFalse(core.exitModuleLocked());
        assertFalse(core.targetsLocked());
        address c = core.controller();
        vm.prank(owner);
        vm.expectRevert(_lockedErr("controller"));
        core.setController(address(0x1234));
        // the order of the checks: locked first, even for the zero address
        vm.prank(owner);
        vm.expectRevert(_lockedErr("controller"));
        core.setController(address(0));
        _warp(1000 days);
        vm.prank(owner);
        vm.expectRevert(_lockedErr("controller"));
        core.setController(c);
        assertEq(core.controller(), c);
        // every other door is open, and the controller's own sale settings stay adjustable
        _openExcept(D_CONTROLLER, owner);
        vm.startPrank(owner);
        ctl.setBuyOnly(true);
        ctl.setStartBps(12_000);
        ctl.setStepBps(10);
        ctl.setStepEvery(1 hours);
        ctl.setFloorBps(8_000);
        vm.stopPrank();
        assertTrue(core.controllerLocked());
    }

    function test_lockExitModule_revertsWhileUnset() public {
        vm.prank(owner);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.lockExitModule();
        assertFalse(core.exitModuleLocked());
        // phase 2 can still be entered afterwards
        _setExitModule(address(spareMod));
        vm.prank(owner);
        core.lockExitModule();
        assertTrue(core.exitModuleLocked());
    }

    function test_lockExitModule_blocksOnlyTheModuleSetterAndTheUnitStaysFixed() public {
        _enterPhase2();
        vm.expectEmit(address(core));
        emit ICore.ExitModuleLocked();
        vm.prank(owner);
        core.lockExitModule();
        assertTrue(core.exitModuleLocked());
        assertFalse(core.controllerLocked());
        assertFalse(core.targetsLocked());
        address m = core.exitModule();
        mod.setUnitPerPoint(9e10);
        vm.startPrank(owner);
        vm.expectRevert(_lockedErr("exitModule"));
        core.setExitModule(address(spareMod));
        // the same module again, which is how the unit is updated: also locked
        vm.expectRevert(_lockedErr("exitModule"));
        core.setExitModule(m);
        // a module that would be refused anyway is refused as locked first
        vm.expectRevert(_lockedErr("exitModule"));
        core.setExitModule(address(0xBEEF));
        vm.stopPrank();
        assertEq(core.exitModule(), m);
        assertEq(core.unitPerPoint(), UNIT, "the unit cannot be updated any more");
        _openExcept(D_MODULE, owner);
    }

    function test_lockTargets_blocksAddButNotRemoveAndKeepsTheOldOnes() public {
        address kept = address(0xA11E);
        _allow(kept);
        vm.expectEmit(address(core));
        emit ICore.TargetsLocked();
        vm.prank(owner);
        core.lockTargets();
        assertTrue(core.targetsLocked());
        assertFalse(core.controllerLocked());
        assertFalse(core.exitModuleLocked());
        assertTrue(core.allowedTarget(kept), "an allowed target stays allowed");
        vm.startPrank(owner);
        vm.expectRevert(_lockedErr("targets"));
        core.addTarget(address(0xA11F));
        // the order of the checks: locked first, also for a forbidden address
        vm.expectRevert(_lockedErr("targets"));
        core.addTarget(address(core));
        core.removeTarget(kept);
        vm.stopPrank();
        assertFalse(core.allowedTarget(kept));
        vm.prank(owner);
        vm.expectRevert(_lockedErr("targets"));
        core.addTarget(kept);
        _openExcept(D_TARGETS, owner);
    }

    function test_locks_areIndependentAndOneWayAndRepeatable() public {
        _enterPhase2();
        vm.startPrank(owner);
        core.lockController();
        core.lockController();
        core.lockExitModule();
        core.lockExitModule();
        core.lockTargets();
        core.lockTargets();
        vm.stopPrank();
        assertTrue(core.controllerLocked() && core.exitModuleLocked() && core.targetsLocked());
        // with all three locked everything else works: settings, rates, removing targets, the handover
        for (uint256 i; i < N_DOORS; ++i) {
            if (i == D_CONTROLLER || i == D_MODULE || i == D_TARGETS) continue;
            (bool ok,) = _call(i, owner);
            assertTrue(ok, "an unlocked door is shut");
        }
        // and the three locked ones stay shut for the owner and for the next owner
        vm.prank(owner);
        core.transferOwnership(heir);
        vm.prank(heir);
        core.acceptOwnership();
        for (uint256 i; i < 3; ++i) {
            (bool ok, bytes memory out) = _call(i, heir);
            assertFalse(ok);
            assertEq(_sel(out), ICore.Locked.selector);
        }
        // nothing can unlock: there is no function for it
        (bool u,) = address(core).call(abi.encodeWithSignature("unlockController()"));
        assertFalse(u);
    }

    function test_locks_onlyTheOwnerLocks() public {
        _enterPhase2();
        _allShutFor(stranger);
        _allShutFor(deployer);
        _allShutFor(address(ctl));
        assertFalse(core.controllerLocked() || core.exitModuleLocked() || core.targetsLocked());
    }

    /// a locked controller cannot be swapped, so a controller that goes bad stays: the sale and compose revert, the
    /// doors that do not depend on pricing stay open
    function test_locks_aLockedControllerStaysEvenWhenItBreaks() public {
        ScriptedController sc = _scripted();
        _setController(address(sc));
        vm.prank(owner);
        core.lockController();
        sc.setRevertPrice(true);
        vm.prank(owner);
        vm.expectRevert(_lockedErr("controller"));
        core.setController(address(ctl));
        assertEq(core.controller(), address(sc));
    }
}

contract OwnerHandoverTest is OwnerBase {
    function test_handover_twoStepsAndOnlyThePendingOwnerAccepts() public {
        assertEq(core.owner(), owner);
        assertEq(core.pendingOwner(), address(0));
        vm.expectEmit(address(core));
        emit ICore.OwnershipTransferStarted(owner, heir);
        vm.prank(owner);
        core.transferOwnership(heir);
        assertEq(core.pendingOwner(), heir);
        assertEq(core.owner(), owner, "the owner does not move on the first step");
        // the owner keeps every power and the heir has none until it accepts
        _allShutFor(heir);
        // nobody else can accept: a stranger, the old owner, the deployer
        address[3] memory no = [stranger, owner, deployer];
        for (uint256 i; i < no.length; ++i) {
            vm.prank(no[i]);
            vm.expectRevert(ICore.OnlyPendingOwner.selector);
            core.acceptOwnership();
        }
        vm.expectEmit(address(core));
        emit ICore.OwnershipTransferred(owner, heir);
        vm.prank(heir);
        core.acceptOwnership();
        assertEq(core.owner(), heir);
        assertEq(core.pendingOwner(), address(0), "pending is cleared");
        // a second accept finds nothing pending
        vm.prank(heir);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
    }

    function test_handover_theOldOwnerLosesEveryPowerAndTheNewOneHasEvery() public {
        _enterPhase2();
        vm.prank(owner);
        core.transferOwnership(heir);
        vm.prank(heir);
        core.acceptOwnership();
        _allShutFor(owner);
        // the controller's sale settings follow the live owner
        vm.startPrank(owner);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setBuyOnly(true);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setStartBps(12_000);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setStepBps(1);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setStepEvery(2 hours);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setFloorBps(8_000);
        vm.stopPrank();
        // the new owner has every door
        _openExcept(N_DOORS, heir);
        vm.startPrank(heir);
        ctl.setBuyOnly(true);
        ctl.setStartBps(12_000);
        ctl.setStepBps(1);
        ctl.setStepEvery(2 hours);
        ctl.setFloorBps(8_000);
        core.lockController();
        core.lockExitModule();
        core.lockTargets();
        vm.stopPrank();
        assertTrue(ctl.buyOnly());
        assertTrue(core.controllerLocked() && core.exitModuleLocked() && core.targetsLocked());
    }

    /// the new owner can hand over again, and the chain of owners never has two at once
    function test_handover_aChainOfOwners() public {
        address[3] memory chain = [address(0xAA01), address(0xAA02), address(0xAA03)];
        address cur = owner;
        for (uint256 i; i < 3; ++i) {
            vm.prank(cur);
            core.transferOwnership(chain[i]);
            vm.prank(chain[i]);
            core.acceptOwnership();
            assertEq(core.owner(), chain[i]);
            _allShutFor(cur);
            cur = chain[i];
        }
        _openExcept(N_DOORS, cur);
    }

    function test_handover_zeroClearsPendingAndANewNameReplacesIt() public {
        vm.startPrank(owner);
        core.transferOwnership(heir);
        vm.expectEmit(address(core));
        emit ICore.OwnershipTransferStarted(owner, address(0));
        core.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(core.pendingOwner(), address(0));
        vm.prank(heir);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        // naming a second heir replaces the first
        vm.startPrank(owner);
        core.transferOwnership(heir);
        core.transferOwnership(address(0xEE12));
        vm.stopPrank();
        vm.prank(heir);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        vm.prank(address(0xEE12));
        core.acceptOwnership();
        assertEq(core.owner(), address(0xEE12));
    }

    function test_handover_ownerCannotBeZeroedAndThereIsNoRenounce() public {
        vm.prank(owner);
        core.transferOwnership(address(0));
        assertEq(core.owner(), owner);
        (bool ok,) = address(core).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok);
        (ok,) = address(core).call(abi.encodeWithSignature("renounce()"));
        assertFalse(ok);
        assertEq(core.owner(), owner);
    }

    function test_handover_theOldOwnerCannotCancelAfterTheAcceptAndAStrangerCannotStart() public {
        vm.prank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.transferOwnership(stranger);
        vm.prank(owner);
        core.transferOwnership(heir);
        vm.prank(heir);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.transferOwnership(owner);
        assertEq(core.owner(), heir);
        assertEq(core.pendingOwner(), address(0));
    }

    /// a handover to a contract and to the same owner both work
    function test_handover_toAContractAndToItself() public {
        address c = address(ctl);
        vm.prank(owner);
        core.transferOwnership(c);
        vm.prank(c);
        core.acceptOwnership();
        assertEq(core.owner(), c);
        vm.prank(c);
        core.transferOwnership(c);
        vm.prank(c);
        core.acceptOwnership();
        assertEq(core.owner(), c);
        assertEq(core.pendingOwner(), address(0));
    }

    /// while nothing is pending the pending owner is the zero address, and a call from it must not pass
    /// `acceptOwnership` (review S-9, fixed): the owner stays
    function test_handover_zeroAddressAcceptWhileNothingPendingReverts() public {
        assertEq(core.pendingOwner(), address(0));
        vm.prank(address(0));
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        assertEq(core.owner(), owner);
    }

    /// the assets: no owner call, of any owner, moves eth, credits, statements or the coin out of the core
    function test_handover_noOwnerDoorMovesAnAsset() public {
        uint256 sid = _composeOnce().sid;
        _enterPhase2();
        _fundPot(1 ether);
        vm.prank(owner);
        core.transferOwnership(heir);
        vm.prank(heir);
        core.acceptOwnership();
        uint256 bal = address(core).balance;
        uint256 credits = CREDITS.balanceOf(address(core));
        uint256 pot = core.ethPot();
        uint256 heirEth = heir.balance;
        _openExcept(N_DOORS, heir);
        vm.startPrank(heir);
        core.lockController();
        core.lockTargets();
        vm.stopPrank();
        assertEq(address(core).balance, bal);
        assertEq(CREDITS.balanceOf(address(core)), credits);
        assertEq(core.ethPot(), pot);
        assertEq(heir.balance, heirEth);
        assertEq(STATEMENTS.ownerOf(sid), address(house));
        assertEq(STATEMENTS.balanceOf(heir), 0);
        assertEq(coin.balanceOf(heir), 0);
    }
}
