// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {IFeeRouter} from "../../src/interfaces/IFeeRouter.sol";
import {ICoreLens} from "../../src/interfaces/ICoreLens.sol";
import {Stack, Settings, Sale} from "../../src/interfaces/Interfaces.sol";

/// @notice creates the production contracts from their via_ir artifacts. the tests never import the production sources
/// (that would pull them onto the via_ir compiler profile), so `new Core(...)` becomes `Prod.newCore(...)`. a revert
/// of the constructor reaches the caller with its own revert data, so `vm.expectRevert` works as with `new`
library Prod {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function newCore(
        address owner,
        address coin,
        address controller,
        Stack memory stack,
        uint256 rateStart,
        Settings memory settings
    ) internal returns (ICore) {
        bytes memory args = abi.encode(owner, coin, controller, stack, rateStart, settings);
        return ICore(payable(vm.deployCode("Core.sol:Core", args)));
    }

    function newController(address core, Sale memory sale) internal returns (IControllerV1) {
        return IControllerV1(vm.deployCode("ControllerV1.sol:ControllerV1", abi.encode(core, sale)));
    }

    function newRouter(address owner) internal returns (IFeeRouter) {
        return IFeeRouter(payable(vm.deployCode("FeeRouter.sol:FeeRouter", abi.encode(owner))));
    }

    function newLens(address core) internal returns (ICoreLens) {
        return ICoreLens(vm.deployCode("CoreLens.sol:CoreLens", abi.encode(core)));
    }
}
