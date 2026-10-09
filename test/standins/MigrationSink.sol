// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// test double for a successor of the Core. it takes eth and records it. it can refuse eth, and it can call back into
/// the Core from its `receive`, to show that a migration cannot be re entered
contract MigrationSink {
    uint256 public ethReceived;
    uint256 public sends;
    bool public refuse;
    address public callTarget;
    bytes public callData;
    bool public called;
    bool public calledOk;
    bytes public calledOut;

    receive() external payable {
        if (refuse) revert("sink refuses");
        ethReceived += msg.value;
        ++sends;
        if (callTarget != address(0)) {
            called = true;
            (calledOk, calledOut) = callTarget.call(callData);
        }
    }

    /// calls `target` as the sink, for a sink that is the owner of the Core
    function exec(address target, bytes calldata data) external returns (bool ok, bytes memory out) {
        (ok, out) = target.call(data);
    }

    function setRefuse(bool on) external {
        refuse = on;
    }

    function setCall(address target, bytes calldata data) external {
        callTarget = target;
        callData = data;
    }
}
