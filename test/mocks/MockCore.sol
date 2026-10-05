// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ICoreFees} from "../../src/interfaces/Interfaces.sol";

/// @notice stands in for the core in hook and coin tests. it counts the fees it is told about
contract MockCore is ICoreFees {
    /// @notice eth received through addFees
    uint256 public ethFees;
    /// @notice number of addFees calls
    uint256 public ethFeeCalls;
    /// @notice exit token reported through addExitFees
    uint256 public exitFees;
    /// @notice number of addExitFees calls
    uint256 public exitFeeCalls;

    bytes32 public exitPoolId;
    address public exitToken;

    error ExitFeesNotReceived();

    /// @notice sets the exit pool id and the exit token, as the real core does once
    function setExit(bytes32 poolId, address token) external {
        exitPoolId = poolId;
        exitToken = token;
    }

    /// @inheritdoc ICoreFees
    function addFees() external payable {
        ethFees += msg.value;
        ethFeeCalls++;
    }

    /// @inheritdoc ICoreFees
    function addExitFees(uint256 amount) external {
        exitFees += amount;
        exitFeeCalls++;
        if (ERC20(exitToken).balanceOf(address(this)) < exitFees) revert ExitFeesNotReceived();
    }
}
