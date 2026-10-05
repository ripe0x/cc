// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICoreFees} from "../../src/interfaces/Interfaces.sol";

/// stands in for the fee hook in unit tests. it only forwards what it is told to.
contract MockHook {
    /// forwards eth into addFees.
    function feedEth(address core) external payable {
        ICoreFees(core).addFees{value: msg.value}();
    }

    /// calls addExitFees without moving any token.
    function feedExit(address core, uint256 amount) external {
        ICoreFees(core).addExitFees(amount);
    }

    receive() external payable {}
}
