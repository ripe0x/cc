// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// stands in for the fee router: every call reverts, eth included. attacker side double, not a v2 contract
contract RevertingRouter {
    uint256 public calls;

    fallback() external payable {
        revert("router down");
    }

    receive() external payable {
        revert("router down");
    }
}
