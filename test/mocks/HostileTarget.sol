// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// takes eth and returns nothing.
contract HostileTarget {
    fallback() external payable {}
}
