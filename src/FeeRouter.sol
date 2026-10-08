// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// the bounty recipient of the pool. the v2 hook pushes fee eth with the 2,300 gas stipend, so `receive` does nothing at
/// all: no write, no read, no call, no log. `flush` forwards the balance: a small tip to the caller, a split to up to four
/// payees once the split has started, the rest to the engine, which books it as fees (docs/FLOW.md 10.2 and 10.6).
/// eth waits here until an engine is set. the router owner can point every future fee at any engine with `setEngine`
/// until `lock`. it never touches what an engine already holds, and it has no token path.
contract FeeRouter {
    uint256 internal constant PPM = 1_000_000;
    uint256 internal constant MAX_PAYEES = 4;
    /// the payees' total share of a flush after the tip, at most. the engine keeps at least the rest
    uint256 internal constant MAX_PAYEE_PPM = 200_000;
    uint256 internal constant MAX_TIP_PPM = 20_000;
    uint256 internal constant MAX_TIP_CAP = 0.05 ether;
    /// gas for the tip send. enough for a wallet or a small receiver, too little to do harm
    uint256 internal constant SEND_GAS = 50_000;
    /// gas for a payee send (docs/FLOW.md 10.7): a payee may be a splitter contract
    uint256 internal constant PAYEE_GAS = 100_000;

    address public owner;
    address public pendingOwner;
    /// where `flush` sends what is left. zero until the owner sets it
    address public engine;
    /// one way: once true every owner setter reverts for good
    bool public locked;
    /// true once the split has started. one way
    bool public splitOn;
    bool private _busy;
    /// timestamp of the first flush that turns the split on, zero means never
    uint64 public splitStart;
    /// the tip of a flush: `min(amount * tipPpm / 1e6, tipCap)`
    uint32 public tipPpm = 5_000;
    uint96 public tipCap = 0.005 ether;
    uint32 public payeePpmTotal;
    /// eth credited to payees whose send failed, still held here. `flush` never forwards it
    uint256 public totalOwed;
    mapping(address => uint256) public owed;

    address[] private _payees;
    uint32[] private _ppm;

    error OnlyOwner();
    error OnlyPendingOwner();
    error ZeroAddress();
    error NoCode(address account);
    error IsLocked();
    error NoEngine();
    error Reentered();
    error FlushFailed();
    error ClaimFailed();
    error NothingOwed();
    error BadPayees();
    error BadTip();
    error SplitIsOn();

    event EngineSet(address indexed previous, address indexed engine);
    event Locked(address indexed engine);
    event Flushed(address indexed engine, uint256 toEngine, uint256 tip, uint256 toPayees);
    event TipFailed(address indexed to, uint256 amount);
    event PayeePaid(address indexed payee, uint256 amount);
    event PayeeOwed(address indexed payee, uint256 amount);
    event Claimed(address indexed payee, uint256 amount);
    event PayeesSet(address[] payees, uint32[] ppm);
    event TipSet(uint32 ppm, uint96 cap);
    event SplitStartSet(uint64 at);
    event SplitStarted(uint256 at);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier unlocked() {
        if (locked) revert IsLocked();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// nothing else may be here: the hook gives this call 2,300 gas
    receive() external payable {}

    /// pays out the balance, except what is owed to payees. anyone may call. reverts while no engine is set (a call to
    /// the zero address would burn the eth) and when the engine call fails. an empty balance is a no op.
    /// the tip comes off the top. before the split starts, and in the one flush that starts it, everything else goes to
    /// the engine, so eth that arrived during the anti sniper window is never shared. after that each payee gets its
    /// parts per million of what is left after the tip and the engine gets the rest
    function flush() external {
        if (_busy) revert Reentered();
        address to = engine;
        if (to == address(0)) revert NoEngine();
        uint256 amount = address(this).balance - totalOwed;
        if (amount == 0) return;
        _busy = true;
        uint256 tip = _tip(amount);
        uint256 rest = amount - tip;
        uint256 shared;
        if (splitOn) {
            shared = _payPayees(rest);
        } else if (splitStart != 0 && block.timestamp >= splitStart) {
            splitOn = true;
            emit SplitStarted(block.timestamp);
        }
        (bool ok,) = to.call{value: rest - shared}("");
        _busy = false;
        if (!ok) revert FlushFailed();
        emit Flushed(to, rest - shared, tip, shared);
    }

    function _tip(uint256 amount) private returns (uint256 tip) {
        tip = amount * tipPpm / PPM;
        if (tip > tipCap) tip = tipCap;
        if (tip == 0) return 0;
        (bool ok,) = msg.sender.call{gas: SEND_GAS, value: tip}("");
        if (!ok) {
            emit TipFailed(msg.sender, tip);
            return 0;
        }
    }

    /// a payee that cannot take its share in `PAYEE_GAS` is credited, never blocks the flush
    function _payPayees(uint256 base) private returns (uint256 paid) {
        uint256 n = _payees.length;
        for (uint256 i; i < n; ++i) {
            address p = _payees[i];
            uint256 share = base * _ppm[i] / PPM;
            if (share == 0) continue;
            paid += share;
            (bool ok,) = p.call{gas: PAYEE_GAS, value: share}("");
            if (ok) {
                emit PayeePaid(p, share);
            } else {
                owed[p] += share;
                totalOwed += share;
                emit PayeeOwed(p, share);
            }
        }
    }

    /// pays what a payee is owed, to the payee, with all gas. anyone may call it for a payee
    function claim(address payee) external {
        if (_busy) revert Reentered();
        uint256 amount = owed[payee];
        if (amount == 0) revert NothingOwed();
        _busy = true;
        owed[payee] = 0;
        totalOwed -= amount;
        (bool ok,) = payee.call{value: amount}("");
        _busy = false;
        if (!ok) revert ClaimFailed();
        emit Claimed(payee, amount);
    }

    function payees() external view returns (address[] memory, uint32[] memory) {
        return (_payees, _ppm);
    }

    // ---------------------------------------------------------------- owner setters, all closed by `lock`

    /// the engine must be a contract
    function setEngine(address engine_) external onlyOwner unlocked {
        if (engine_ == address(0)) revert ZeroAddress();
        if (engine_.code.length == 0) revert NoCode(engine_);
        emit EngineSet(engine, engine_);
        engine = engine_;
    }

    /// replaces the payee list: up to four, each with a nonzero address and share, at most 200,000 ppm in total
    function setPayees(address[] calldata who, uint32[] calldata ppm) external onlyOwner unlocked {
        uint256 n = who.length;
        if (n != ppm.length || n > MAX_PAYEES) revert BadPayees();
        uint256 total;
        for (uint256 i; i < n; ++i) {
            if (who[i] == address(0) || who[i] == address(this) || ppm[i] == 0) revert BadPayees();
            total += ppm[i];
        }
        if (total > MAX_PAYEE_PPM) revert BadPayees();
        _payees = who;
        _ppm = ppm;
        // forge-lint: disable-next-line(unsafe-typecast)
        payeePpmTotal = uint32(total);
        emit PayeesSet(who, ppm);
    }

    function setTip(uint32 ppm, uint96 cap) external onlyOwner unlocked {
        if (ppm > MAX_TIP_PPM || cap > MAX_TIP_CAP) revert BadTip();
        tipPpm = ppm;
        tipCap = cap;
        emit TipSet(ppm, cap);
    }

    /// the time of the first flush that starts the split. zero means never. only while the split is not on
    function setSplitStart(uint64 at) external onlyOwner unlocked {
        if (splitOn) revert SplitIsOn();
        splitStart = at;
        emit SplitStartSet(at);
    }

    /// closes every setter above for good. needs an engine, so a lock can never strand the eth
    function lock() external onlyOwner unlocked {
        if (engine == address(0)) revert NoEngine();
        locked = true;
        emit Locked(engine);
    }

    // ---------------------------------------------------------------- owner handover (never locked)

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
