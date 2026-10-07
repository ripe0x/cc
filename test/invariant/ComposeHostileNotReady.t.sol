// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Core} from "../../src/Core.sol";
import {InvariantsHostileController} from "./InvariantsPhase2.t.sol";

/// regression for a deep run failure of invariant 11 ("unexpected revert in compose, selector NotReady") in the
/// hostile controller suite, shrunk to sellForEth, controllerSeed(21838), compose.
/// the page the fuzz controller answers is ready and valid when asked from outside the core's frame (the handler's
/// pre check: 385,590 gas, under the core's 500,000 cap). inside the core's frame the controller first runs its
/// state changing attacks, and each one that halts a static frame burns the 300,000 gas it was given, so the same
/// read runs out of gas at the cap and the core, which treats any failed read as not ready, reverts NotReady. that
/// is the documented behaviour and a model gap of the handler, not a core fault: the handler now expects NotReady
/// from a hostile controller in force. the inherited invariants run at the smallest size, the suites cover them.
/// forge-config: default.invariant.runs = 1
/// forge-config: default.invariant.depth = 1
contract ComposeHostileNotReadyTest is InvariantsHostileController {
    function test_hostileControllerBurningTheReadGasIsNotReady() public {
        vm.prank(0x64c47B8c7F8a9C08964bA4927A7fc74cd741B7F7);
        handler.sellForEth(5000, 7919, 433460492, 1800);
        vm.prank(0xe0Bf4A77d29dE3232F61956C0C51825F0b8855b8);
        handler.controllerSeed(21838);

        // from outside the core: ready, with a full page, inside the cap
        uint256 g = gasleft();
        (bool ok, bytes memory out) =
            address(fuzz).staticcall{gas: 500_000}(abi.encodeWithSignature("nextPage(uint8)", uint8(0)));
        uint256 used = g - gasleft();
        assertTrue(ok, "pre check read failed");
        assertEq(out.length, 82 * 32, "pre check read short");
        assertEq(abi.decode(out, (uint256)), 1, "pre check not ready");
        assertLt(used, 500_000, "pre check read used the whole cap");

        // from the core: the same read runs out of gas at the cap, so the core answers NotReady
        vm.expectRevert(Core.NotReady.selector);
        core.compose();

        vm.prank(0x64c47B8c7F8a9C08964bA4927A7fc74cd741B7F7);
        handler.compose(
            151194505320660825313762882061979352658830774236078, 5859136430993920867971248072759558274831961277
        );
        invariant_11_noUnexpectedReverts();
    }
}
