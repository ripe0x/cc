// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// the bounty recipient of the pool and the end recipient of the fee swapper. the v2 hook pushes fee eth with the 2,300
/// gas stipend, so `receive` does nothing at all: no write, no read, no call, no log. `flush` forwards the whole balance
/// to the engine, which books it as fees (docs/FLOW.md 10.2). eth waits here until an engine is set.
/// the router owner can point every future fee at any engine with `setEngine` until `lock`. it never touches what an
/// engine already holds, and it has no token path.
contract FeeRouter {
    address public owner;
    address public pendingOwner;
    /// where `flush` sends the balance. zero until the owner sets it
    address public engine;
    /// one way: once true `setEngine` reverts for good
    bool public locked;
    bool private _flushing;

    error OnlyOwner();
    error OnlyPendingOwner();
    error ZeroAddress();
    error NoCode(address account);
    error IsLocked();
    error NoEngine();
    error Reentered();
    error FlushFailed();

    event EngineSet(address indexed previous, address indexed engine);
    event Locked(address indexed engine);
    event Flushed(address indexed engine, uint256 amount);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// nothing else may be here: the hook gives this call 2,300 gas
    receive() external payable {}

    /// sends the whole balance to the engine with a plain call and all gas. anyone may call. reverts while no engine is
    /// set (a call to the zero address would burn the eth) and when the engine call fails. an empty balance is a no op
    function flush() external {
        if (_flushing) revert Reentered();
        address to = engine;
        if (to == address(0)) revert NoEngine();
        uint256 amount = address(this).balance;
        if (amount == 0) return;
        _flushing = true;
        (bool ok,) = to.call{value: amount}("");
        _flushing = false;
        if (!ok) revert FlushFailed();
        emit Flushed(to, amount);
    }

    /// owner only, until `lock`. the engine must be a contract
    function setEngine(address engine_) external onlyOwner {
        if (locked) revert IsLocked();
        if (engine_ == address(0)) revert ZeroAddress();
        if (engine_.code.length == 0) revert NoCode(engine_);
        emit EngineSet(engine, engine_);
        engine = engine_;
    }

    /// closes `setEngine` for good. needs an engine, so a lock can never strand the eth
    function lock() external onlyOwner {
        if (locked) revert IsLocked();
        if (engine == address(0)) revert NoEngine();
        locked = true;
        emit Locked(engine);
    }

    /// starts the handover. the zero address clears a pending one
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert OnlyPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }
}
