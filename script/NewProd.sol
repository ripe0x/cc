// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Core} from "../src/Core.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {CoreLens} from "../src/CoreLens.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemDeployer} from "./SystemDeployer.sol";

/// @notice the broadcast creation of the controller and the core with `new`, so `forge script` links `CoreLib` and
/// sends it through the deterministic deployer. only the scripts import this file: it pulls the production sources, so
/// it (and every script that inherits it) compiles on the via_ir profile. tests use `Prod` and `deployCode` instead
abstract contract NewProd is SystemDeployer {
    function _newRouter(address owner) internal virtual override returns (address) {
        return address(new FeeRouter(owner));
    }

    function _newController(address core, LaunchConfig memory c) internal virtual override returns (address) {
        return address(new ControllerV1(core, c.sale));
    }

    function _newLens(address core) internal virtual override returns (address) {
        return address(new CoreLens(core));
    }

    function _newCore(address owner, address coin, address controller, LaunchConfig memory c)
        internal
        virtual
        override
        returns (address)
    {
        return address(new Core(owner, coin, controller, c.stack, c.rateStart, c.settings));
    }
}
