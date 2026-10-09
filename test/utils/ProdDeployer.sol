// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LaunchConfig} from "../../script/LaunchConfig.sol";
import {SystemDeployer} from "../../script/SystemDeployer.sol";
import {Prod} from "./Prod.sol";

/// @notice the test side of `NewProd`: the controller and the core are created from their via_ir artifacts, so no test
/// contract imports the production sources or embeds their creation code
abstract contract ProdDeployer is SystemDeployer {
    function _newRouter(address owner_) internal virtual override returns (address) {
        return address(Prod.newRouter(owner_));
    }

    function _newController(address core_, LaunchConfig memory c) internal virtual override returns (address) {
        return address(Prod.newController(core_, c.sale));
    }

    function _newLens(address core_) internal virtual override returns (address) {
        return Prod.newLens(core_, LENS_SALT, CREATE2_DEPLOYER);
    }

    function _newCore(address owner_, address coin_, address controller_, LaunchConfig memory c)
        internal
        virtual
        override
        returns (address)
    {
        return address(Prod.newCore(owner_, coin_, controller_, c.stack, c.rateStart, c.settings));
    }
}
