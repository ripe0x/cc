// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "../utils/Fixture.sol";
import {Settings} from "../../src/interfaces/Interfaces.sol";
import {ScriptedController} from "../attackers/ScriptedController.sol";

/// @notice audit finding A02: the constructor arguments postflight prints for etherscan verification came from live
/// storage (`controller()`, `settings()`, `owner()`), which the owner can change, so they drifted from the creation
/// transaction. they are now built from the signed launch config and the first controller only
contract PostflightInputsTest is Fixture {
    /// @dev the arguments the creation transaction of the fixture core carried
    function _creation() internal view returns (bytes memory) {
        return abi.encode(owner, address(coin), address(ctl), lc.stack, lc.rateStart, lc.settings);
    }

    /// @dev what the printed arguments were before the fix: every mutable member read from the live core
    function _oldLiveArgs() internal view returns (bytes memory) {
        return abi.encode(core.owner(), address(coin), core.controller(), lc.stack, core.RATE_START(), core.settings());
    }

    function test_FIXED_A02_verifyInputsDoNotChangeAfterSettingsOrControllerChange() public {
        (address first, bool found) = firstController(address(core), deployer);
        assertTrue(found, "the deployer finds the first controller");
        assertEq(first, address(ctl));
        bytes memory before_ = coreConstructorArgs(core, lc, first);
        assertEq(before_, _creation(), "equal to the creation arguments");
        assertEq(before_, _oldLiveArgs(), "the old way agrees until something changes");

        // the owner changes the settings, the controller and hands the owner role over
        Settings memory s = core.settings();
        s.saleFloorBps = 8_000;
        s.buybackSlice = 2 ether;
        _setSettings(s);
        _setController(address(new ScriptedController()));
        address next = _user("next owner");
        vm.prank(owner);
        core.transferOwnership(next);
        vm.prank(next);
        core.acceptOwnership();
        assertEq(core.owner(), next);

        (address again, bool foundAgain) = firstController(address(core), deployer);
        assertTrue(foundAgain);
        assertEq(again, address(ctl), "the first controller does not move with setController");
        bytes memory after_ = coreConstructorArgs(core, lc, again);
        assertEq(after_, before_, "the printed constructor arguments did not change");
        assertEq(after_, _creation());
        assertTrue(keccak256(_oldLiveArgs()) != keccak256(before_), "the live values drifted, the old print would too");
        // the print itself runs against the changed core
        printVerifyInputs(core, lc, deployer);
    }

    /// without the deployer or FIRST_CONTROLLER the first controller is not known and nothing is guessed from live storage
    function test_FIXED_A02_withoutTheDeployerTheFirstControllerIsNotGuessed() public {
        (address first, bool found) = firstController(address(core), address(0));
        assertFalse(found);
        assertEq(first, address(0));
        (first, found) = firstController(address(core), _user("some other deployer"));
        assertFalse(found, "another address never created this core");
        printVerifyInputs(core, lc, address(0));
    }
}
