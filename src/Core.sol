// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibTransient} from "solady/utils/LibTransient.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {
    Lane,
    IController,
    IExitModule,
    ICoreFees,
    ICoreViews,
    ICredits,
    ICreditScore,
    IStatements,
    Mainnet
} from "./interfaces/Interfaces.sol";

/// custody and every rule of the credits engine. the only mutable slots are the ones the owner can
/// reach through the timelock: the controller, the exit module, the exit pool key and the target list.
/// credits and statements sent to the core outside its doors are not tracked and stay in the core.
contract Core is ICoreFees, ICoreViews, IUnlockCallback, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using LibTransient for LibTransient.TBool;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    enum Action {
        SetController,
        SetExitModule,
        SetExitPoolKey,
        AddTarget,
        Freeze
    }

    struct Pile {
        uint256 head;
        uint256 tail;
        uint256 size;
    }

    struct Credit {
        uint256 cost;
        uint256 prev;
        uint256 next;
        uint64 acquiredAt;
        Lane lane;
        bool inPile;
    }

    struct Statement {
        uint256 cost;
        uint64 clockStart;
        uint64 slot;
        Lane lane;
        bool held;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyOwner();
    error OnlyHook();
    error OnlyPoolManager();
    error BadSender();
    error Busy();
    error ZeroAddress();
    error ZeroId();
    error ZeroAmount();
    error Empty();
    error NotOwner();
    error NotHeld();
    error NotInPile(uint256 id);
    error NotReady();
    error BadFormat();
    error BadStatement();
    error BadOverprint();
    error BadCost();
    error BadModule();
    error BadKey();
    error BadSwap();
    error TargetNotAllowed();
    error ForbiddenTarget();
    error AlreadyOwned();
    error CallFailed();
    error NoCredit();
    error PotTooSmall();
    error AboveCeiling();
    error HourlyCap();
    error Slippage();
    error Underpaid();
    error NotForSale();
    error AuctionRunning();
    error NoExitModule();
    error Frozen();
    error AlreadySet();
    error AlreadyQueued();
    error NotQueued();
    error TooEarly();
    error NothingToBuy();
    error NothingBought();
    error PriceBeyondLimit();
    error TooSoon();
    error DailyCap();
    error Unfunded();
    error Dormant();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeesAdded(uint256 amount);
    event ExitFeesAdded(uint256 amount);
    event Skimmed(uint256 eth, uint256 exitToken);
    event CreditBought(uint256 indexed id, address indexed from, Lane lane, uint256 cost);
    event ListingBought(
        uint256 indexed id, address indexed target, address indexed caller, uint256 cost, uint256 tip, uint256 rate
    );
    event EthRateFill(uint256 spent, uint256 rate, uint256 pot);
    event ExitRateFill(uint256 rate, uint256 pot);
    event Composed(
        uint256 indexed sid, Lane lane, uint8 format, uint256 cost, uint256 reimbursement, address indexed caller
    );
    event StatementSold(uint256 indexed sid, address indexed buyer, uint256 price);
    event StatementExited(uint256 indexed sid, Lane lane, uint256 received);
    event Overprinted(uint256 indexed baseId, uint256 indexed topId, uint256 cost);
    event Buyback(address indexed caller, uint256 amountIn, uint256 tip);
    event ExitBuyback(address indexed caller, uint256 amountIn, uint256 tip);
    event Queued(bytes32 indexed id, Action action, bytes data, uint256 eta);
    event Executed(bytes32 indexed id, Action action);
    event Cancelled(bytes32 indexed id, Action action);
    event ControllerSet(address controller);
    event ExitModuleSet(address exitModule, address exitToken, uint256 unitPerPoint);
    event ExitPoolKeySet(bytes32 poolId, PoolKey key, uint160 sqrtPriceLimitX96);
    event TargetAdded(address target);
    event TargetRemoved(address target);
    event FrozenSet();

    /*//////////////////////////////////////////////////////////////
                              PARAMETERS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint256 public constant FEE_BPS = 1000;
    uint256 public constant CREATOR_BPS = 50;
    uint256 public constant AVG_SCORE = 4_330_000;
    /// wei per whole point
    uint256 public constant RATE_START = 4e12;
    uint256 public constant CLIMB_BASE_BPS_PER_HOUR = 100;
    uint256 public constant CLIMB_DOUBLE_EVERY = 24 hours;
    uint256 public constant CLIMB_MAX_BPS_PER_HOUR = 800;
    uint256 public constant DROP_BPS = 1000;
    uint256 public constant SPEND_CAP_BPS_PER_HOUR = 2000;
    uint256 public constant BONUS_CAP_BPS = 2500;
    uint256 public constant TIP_SAVINGS_BPS = 1000;
    uint256 public constant TIP_CAP_BPS = 200;
    /// bps of cost, 4x
    uint256 public constant AUCTION_START_X = 40_000;
    /// bps of cost, 1.2x
    uint256 public constant AUCTION_FLOOR_X = 12_000;
    uint256 public constant AUCTION_LENGTH = 72 hours;
    /// bps of sale proceeds that go to the coin buyback
    uint256 public constant SALE_SPLIT = 5000;
    /// bps of exit token from an unsold statement that goes to the coin buyback
    uint256 public constant EXIT_SPLIT = 5000;
    uint256 public constant BUYBACK_SLICE = 1 ether;
    uint256 public constant BUYBACK_DELAY = 25;
    uint256 public constant KEEPER_TIP_BPS = 50;
    /// exit token bid, bps of score
    uint256 public constant XRATE_START = 6000;
    uint256 public constant XRATE_CAP = 9700;
    uint256 public constant XRATE_FLOOR = 3000;
    /// bps of score per hour
    uint256 public constant XRATE_CLIMB_PER_HOUR = 100;
    /// bps of score per credit bought
    uint256 public constant XRATE_DROP_PER_CREDIT = 20;
    uint256 public constant TIMELOCK = 7 days;
    uint256 public constant OVERPRINT_CAP_PER_DAY = 8;

    uint256 private constant BPS = 10_000;
    uint256 private constant SPEND_WINDOW = 1 hours;
    uint256 private constant PAGE = 80;
    uint256 private constant MAX_FORMAT = 7;
    uint256 private constant COMPOSE_OVERHEAD_GAS = 50_000;
    uint256 private constant REIMBURSE_BPS = 11_000;
    uint256 private constant REIMBURSE_CAP_BPS = 500;
    uint256 private constant EXIT_SLICE_CREDITS = 20;
    uint256 private constant READ_GAS = 200_000;
    int24 private constant LAUNCH_TICK_SPACING = 60;
    address private constant DEAD = Mainnet.DEAD;
    bytes32 private constant MEASURING_SLOT = keccak256("core.measuring");

    ICredits private constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements private constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    IPoolManager private constant MANAGER = IPoolManager(Mainnet.POOL_MANAGER);

    address public immutable OWNER;
    address public immutable COIN;
    address public immutable HOOK;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    address public controller;
    bool public frozen;
    address public exitModule;
    address public exitToken;
    bytes32 public exitPoolId;
    PoolKey private _exitPoolKey;
    mapping(address => bool) public allowedTarget;
    mapping(bytes32 => uint256) public queuedEta;

    uint256 public ethPot;
    uint256 public ethToBuyback;
    uint256 public xPot;
    uint256 public xToBuyback;

    uint256 public rateAtCheckpoint;
    uint64 public checkpointTime;
    uint64 public lastFillTime;
    bool public funded;

    uint64 windowStart;
    uint256 windowPot;
    uint256 windowSpent;

    uint256 xRateAtCheckpoint;
    uint64 xCheckpointTime;
    bool xFunded;

    uint256 public lastBuybackBlock;
    uint256 lastExitBuybackBlock;

    uint256 public overprintDay;
    uint256 public overprintCount;

    mapping(Lane => Pile) private _piles;
    mapping(uint256 => Credit) private _credits;
    mapping(uint256 => Statement) private _statements;
    uint256[] private _heldIds;

    /// exit token base units per one unit of 1e4 scaled score, read once from the module when it is set
    uint256 public unitPerPoint;
    /// the worst sqrt price the exit buyback will ever accept, fixed with the exit pool key
    uint160 public exitSqrtPriceLimit;

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert OnlyOwner();
        _;
    }

    constructor(address owner_, address coin_, address hook_, address controller_) {
        if (owner_ == address(0) || coin_ == address(0) || hook_ == address(0) || controller_ == address(0)) {
            revert ZeroAddress();
        }
        OWNER = owner_;
        COIN = coin_;
        HOOK = hook_;
        controller = controller_;
        allowedTarget[Mainnet.SEAPORT] = true;
        allowedTarget[Mainnet.CREDIT_STRATEGY] = true;
        rateAtCheckpoint = RATE_START;
        checkpointTime = uint64(block.timestamp);
        lastFillTime = uint64(block.timestamp);
        xRateAtCheckpoint = XRATE_START;
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        emit ControllerSet(controller_);
        emit TargetAdded(Mainnet.SEAPORT);
        emit TargetAdded(Mainnet.CREDIT_STRATEGY);
    }

    /// accepts eth and books nothing. refunds from a purchase land here. skim books the rest.
    receive() external payable {}

    /// accepts statements and credits from their own contracts only.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(STATEMENTS) && msg.sender != address(CREDITS)) revert BadSender();
        return this.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                              FEE INTAKE
    //////////////////////////////////////////////////////////////*/

    /// hook only. adds the eth sent to the buying pot. not guarded because the hook calls it during a buyback.
    function addFees() external payable {
        if (msg.sender != HOOK) revert OnlyHook();
        if (_measuring().get()) revert Busy();
        _checkpoint();
        ethPot += msg.value;
        _syncFunded();
        emit FeesAdded(msg.value);
    }

    /// hook only. adds exit token the hook already transferred to the exit token bid pot.
    function addExitFees(uint256 amount) external {
        if (msg.sender != HOOK) revert OnlyHook();
        if (_measuring().get()) revert Busy();
        address token = exitToken;
        if (token == address(0)) revert NoExitModule();
        if (SafeTransferLib.balanceOf(token, address(this)) < xPot + xToBuyback + amount) revert Unfunded();
        _xCheckpoint();
        xPot += amount;
        _syncXFunded();
        emit ExitFeesAdded(amount);
    }

    /// books any eth or exit token held above the recorded pots into the buying pots. anyone may call.
    function skim() external nonReentrant {
        uint256 eth = address(this).balance.zeroFloorSub(ethPot + ethToBuyback);
        if (eth != 0) {
            _checkpoint();
            ethPot += eth;
            _syncFunded();
        }
        uint256 x;
        address token = exitToken;
        if (token != address(0)) {
            x = SafeTransferLib.balanceOf(token, address(this)).zeroFloorSub(xPot + xToBuyback);
            if (x != 0) {
                _xCheckpoint();
                xPot += x;
                _syncXFunded();
            }
        }
        emit Skimmed(eth, x);
    }

    /*//////////////////////////////////////////////////////////////
                               ETH RATE
    //////////////////////////////////////////////////////////////*/

    /// wei per whole point right now, climbed lazily from the checkpoint and clamped at the funded threshold.
    function ethRate() public view returns (uint256 r) {
        r = rateAtCheckpoint;
        if (!funded) return r;
        uint256 cap = ethPot * BPS / AVG_SCORE;
        if (cap <= r) return r;
        uint256 last = lastFillTime;
        uint256 t = checkpointTime;
        while (t < block.timestamp && r < cap) {
            uint256 k = (t - last) / CLIMB_DOUBLE_EVERY;
            uint256 bps = (CLIMB_BASE_BPS_PER_HOUR << k.min(16)).min(CLIMB_MAX_BPS_PER_HOUR);
            uint256 end = block.timestamp.min(last + (k + 1) * CLIMB_DOUBLE_EVERY);
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 factor = FixedPointMathLib.powWad(int256(1e18 + bps * 1e14), int256((end - t) * 1e18 / 1 hours));
            // forge-lint: disable-next-line(unsafe-typecast)
            r = r * uint256(factor) / 1e18;
            t = end;
        }
        return r.min(cap);
    }

    /// the most wei the core pays for credit id right now, bonus included.
    function ceilingOf(uint256 id) external view returns (uint256) {
        return _ceiling(id, ethRate());
    }

    function _checkpoint() private {
        rateAtCheckpoint = ethRate();
        checkpointTime = uint64(block.timestamp);
    }

    function _syncFunded() private {
        funded = ethPot * BPS >= AVG_SCORE * rateAtCheckpoint;
    }

    function _ceiling(uint256 id, uint256 rate) private view returns (uint256) {
        return scoreOf(id) * rate * (BPS + _bonus(id)) / (BPS * 1e4);
    }

    /// checkpoints, then books a spend of x from the pot: hourly cap, rate drop, fill time, funded flag.
    function _spend(uint256 x) private {
        _checkpoint();
        uint256 p = ethPot;
        if (x == 0) revert ZeroAmount();
        if (x > p) revert PotTooSmall();
        _requireRoom(x);
        windowSpent += x;
        uint256 r = rateAtCheckpoint;
        r -= r * DROP_BPS * x / (BPS * p);
        rateAtCheckpoint = r;
        lastFillTime = uint64(block.timestamp);
        ethPot = p - x;
        _syncFunded();
        emit EthRateFill(x, r, p - x);
    }

    function _requireRoom(uint256 x) private {
        if (block.timestamp >= windowStart + SPEND_WINDOW) {
            windowStart = uint64(block.timestamp);
            windowPot = ethPot;
            windowSpent = 0;
        }
        if (windowSpent + x > windowPot * SPEND_CAP_BPS_PER_HOUR / BPS) revert HourlyCap();
    }

    /*//////////////////////////////////////////////////////////////
                              EXIT RATE
    //////////////////////////////////////////////////////////////*/

    /// exit token bid in bps of score right now.
    function xRate() public view returns (uint256 r) {
        r = xRateAtCheckpoint;
        if (!xFunded) return r;
        uint256 cap = XRATE_CAP.min(xPot * BPS / (AVG_SCORE * unitPerPoint));
        if (cap <= r) return r;
        return (r + XRATE_CLIMB_PER_HOUR * (block.timestamp - xCheckpointTime) / 1 hours).min(cap);
    }

    function _xCheckpoint() private {
        xRateAtCheckpoint = xRate();
        xCheckpointTime = uint64(block.timestamp);
    }

    function _syncXFunded() private {
        xFunded = xPot * BPS >= AVG_SCORE * xRateAtCheckpoint * unitPerPoint;
    }

    /*//////////////////////////////////////////////////////////////
                           CONTROLLER READS
    //////////////////////////////////////////////////////////////*/

    /// bounded read of a module. any failure or short answer returns false and a long answer is cut off.
    function _ask(address module, bytes memory input, uint256 gasCap, uint256 outLen)
        private
        view
        returns (bool ok, bytes memory out)
    {
        out = new bytes(outLen);
        assembly ("memory-safe") {
            ok := staticcall(gasCap, module, add(input, 0x20), mload(input), add(out, 0x20), outLen)
            ok := and(ok, iszero(lt(returndatasize(), outLen)))
        }
    }

    function _bonus(uint256 id) private view returns (uint256 b) {
        (bool ok, bytes memory out) = _ask(controller, abi.encodeCall(IController.wants, (id)), READ_GAS, 32);
        if (!ok) return 0;
        b = abi.decode(out, (uint256)).min(BONUS_CAP_BPS);
    }

    function _nextPage(Lane lane) private view returns (bool ready, uint256[80] memory ids, uint256 format) {
        (bool ok, bytes memory out) =
            _ask(controller, abi.encodeCall(IController.nextPage, (lane)), gasleft(), (PAGE + 2) * 32);
        if (!ok) return (false, ids, 0);
        uint256 flag;
        (flag, ids, format) = abi.decode(out, (uint256, uint256[80], uint256));
        ready = flag == 1;
    }

    /*//////////////////////////////////////////////////////////////
                                PILES
    //////////////////////////////////////////////////////////////*/

    function _push(Lane lane, uint256 id, uint256 cost) private {
        Pile storage p = _piles[lane];
        uint256 tail = p.tail;
        Credit storage c = _credits[id];
        c.cost = cost;
        c.prev = tail;
        c.next = 0;
        c.acquiredAt = uint64(block.timestamp);
        c.lane = lane;
        c.inPile = true;
        if (tail == 0) p.head = id;
        else _credits[tail].next = id;
        p.tail = id;
        p.size += 1;
    }

    function _pull(Lane lane, uint256 id) private returns (uint256 cost) {
        Credit storage c = _credits[id];
        if (!c.inPile || c.lane != lane) revert NotInPile(id);
        Pile storage p = _piles[lane];
        uint256 prev = c.prev;
        uint256 next = c.next;
        if (prev == 0) p.head = next;
        else _credits[prev].next = next;
        if (next == 0) p.tail = prev;
        else _credits[next].prev = prev;
        p.size -= 1;
        cost = c.cost;
        delete _credits[id];
    }

    /*//////////////////////////////////////////////////////////////
                                 DOORS
    //////////////////////////////////////////////////////////////*/

    /// sell credits into the eth bid at the current ceiling. caller must have approved the core.
    function sellForEth(uint256[] calldata ids) external nonReentrant {
        _sellForEth(ids, 0);
    }

    /// same as sellForEth with a floor on the total paid, for protection against a rate drop in the same block.
    function sellForEth(uint256[] calldata ids, uint256 minOut) external nonReentrant {
        _sellForEth(ids, minOut);
    }

    function _sellForEth(uint256[] calldata ids, uint256 minOut) private {
        if (ids.length == 0) revert Empty();
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = _owned(ids[i]);
            uint256 price = _ceiling(id, ethRate());
            _spend(price);
            _push(Lane.Eth, id, price);
            CREDITS.transferFrom(msg.sender, address(this), id);
            total += price;
            emit CreditBought(id, msg.sender, Lane.Eth, price);
        }
        if (total < minOut) revert Slippage();
        SafeTransferLib.safeTransferETH(msg.sender, total);
    }

    /// buy credit id through an allowed target. the caller supplies the complete calldata and earns a tip from the savings.
    function buyListing(uint256 value, bytes calldata data, uint256 id, address target) external nonReentrant {
        if (!allowedTarget[target] || _forbidden(target)) revert TargetNotAllowed();
        if (id == 0) revert ZeroId();
        if (CREDITS.ownerOf(id) == address(this)) revert AlreadyOwned();
        _checkpoint();
        uint256 ceiling = _ceiling(id, rateAtCheckpoint);
        if (value > ethPot) revert PotTooSmall();
        if (value > ceiling) revert AboveCeiling();
        _requireRoom(value);

        uint256 ethBefore = address(this).balance;
        uint256 creditsBefore = CREDITS.balanceOf(address(this));
        _measuring().set(true);
        (bool ok,) = target.call{value: value}(data);
        _measuring().set(false);
        if (!ok) revert CallFailed();
        if (CREDITS.balanceOf(address(this)) != creditsBefore + 1 || CREDITS.ownerOf(id) != address(this)) {
            revert NoCredit();
        }
        uint256 ethAfter = address(this).balance;
        if (ethAfter >= ethBefore) revert BadCost();
        uint256 cost = ethBefore - ethAfter;
        if (cost > value) revert BadCost();

        uint256 tip = (TIP_SAVINGS_BPS * (ceiling - cost) / BPS).min(TIP_CAP_BPS * cost / BPS);
        _spend(cost + tip);
        _push(Lane.Eth, id, cost + tip);
        emit ListingBought(id, target, msg.sender, cost, tip, rateAtCheckpoint);
        if (tip != 0) SafeTransferLib.safeTransferETH(msg.sender, tip);
    }

    /// sell credits into the exit token bid. phase 2 only.
    function sellForExitToken(uint256[] calldata ids) external nonReentrant {
        _sellForExitToken(ids, 0);
    }

    /// same as sellForExitToken with a floor on the total paid.
    function sellForExitToken(uint256[] calldata ids, uint256 minOut) external nonReentrant {
        _sellForExitToken(ids, minOut);
    }

    function _sellForExitToken(uint256[] calldata ids, uint256 minOut) private {
        if (ids.length == 0) revert Empty();
        if (exitModule == address(0)) revert NoExitModule();
        uint256 unit = unitPerPoint;
        _xCheckpoint();
        uint256 r = xRateAtCheckpoint;
        uint256 pot = xPot;
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = _owned(ids[i]);
            uint256 price = scoreOf(id) * r * unit / BPS;
            if (price == 0) revert ZeroAmount();
            if (price > pot) revert PotTooSmall();
            pot -= price;
            total += price;
            r = r.zeroFloorSub(XRATE_DROP_PER_CREDIT).max(XRATE_FLOOR);
            _push(Lane.Exit, id, price);
            CREDITS.transferFrom(msg.sender, address(this), id);
            emit CreditBought(id, msg.sender, Lane.Exit, price);
        }
        xPot = pot;
        xRateAtCheckpoint = r;
        _syncXFunded();
        emit ExitRateFill(r, pot);
        if (total < minOut) revert Slippage();
        SafeTransferLib.safeTransfer(exitToken, msg.sender, total);
    }

    /// checks that the caller owns credit id, which must not be the zero sentinel.
    function _owned(uint256 id) private view returns (uint256) {
        if (id == 0) revert ZeroId();
        if (CREDITS.ownerOf(id) != msg.sender) revert NotOwner();
        return id;
    }

    function _forbidden(address t) private view returns (bool) {
        return t == address(CREDITS) || t == address(STATEMENTS) || t == address(this) || t == COIN || t == HOOK
            || t == address(MANAGER) || t == exitModule || t == exitToken;
    }

    function _measuring() private pure returns (LibTransient.TBool storage) {
        return LibTransient.tBool(MEASURING_SLOT);
    }

    /*//////////////////////////////////////////////////////////////
                               COMPOSING
    //////////////////////////////////////////////////////////////*/

    /// composes the controller's page of eth lane credits into a statement. anyone may call and is repaid gas.
    function compose() external nonReentrant {
        _compose(Lane.Eth);
    }

    /// composes the controller's page of exit lane credits into a statement. anyone may call and is repaid gas.
    function composeExit() external nonReentrant {
        _compose(Lane.Exit);
    }

    function _compose(Lane lane) private {
        uint256 gasStart = gasleft();
        (bool ready, uint256[80] memory ids, uint256 format) = _nextPage(lane);
        if (!ready) revert NotReady();
        if (format > MAX_FORMAT) revert BadFormat();
        uint256 cost;
        for (uint256 i; i < PAGE; ++i) {
            uint256 id = ids[i];
            cost += _pull(lane, id);
            if (CREDITS.ownerOf(id) != address(this)) revert NotHeld();
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 sid = STATEMENTS.compose(ids, uint8(format));
        if (sid != STATEMENTS.supply() || STATEMENTS.ownerOf(sid) != address(this) || STATEMENTS.creditsOf(sid) != PAGE)
        {
            revert BadStatement();
        }

        uint256 cap = lane == Lane.Eth ? cost : PAGE * AVG_SCORE * ethRate() / 1e4;
        uint256 gasUsed = gasStart - gasleft() + COMPOSE_OVERHEAD_GAS;
        uint256 reimbursement =
            (gasUsed * block.basefee * REIMBURSE_BPS / BPS).min(cap * REIMBURSE_CAP_BPS / BPS).min(ethPot);
        if (reimbursement != 0) {
            _checkpoint();
            ethPot -= reimbursement;
            _syncFunded();
            if (lane == Lane.Eth) cost += reimbursement;
        }
        _heldIds.push(sid);
        _statements[sid] = Statement({
            cost: cost, clockStart: uint64(block.timestamp), slot: uint64(_heldIds.length - 1), lane: lane, held: true
        });
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Composed(sid, lane, uint8(format), cost, reimbursement, msg.sender);
        if (reimbursement != 0) SafeTransferLib.safeTransferETH(msg.sender, reimbursement);
    }

    /// forgets a held statement and compacts the held list.
    function _unhold(uint256 sid) private {
        uint256 slot = _statements[sid].slot;
        uint256 last = _heldIds[_heldIds.length - 1];
        _heldIds[slot] = last;
        // forge-lint: disable-next-line(unsafe-typecast)
        _statements[last].slot = uint64(slot);
        _heldIds.pop();
        delete _statements[sid];
    }

    /*//////////////////////////////////////////////////////////////
                               AUCTION
    //////////////////////////////////////////////////////////////*/

    /// current auction price of an eth lane statement. falls linearly from 4x to 1.2x of cost over the auction length.
    function priceOf(uint256 sid) public view returns (uint256) {
        Statement storage s = _statements[sid];
        if (!s.held || s.lane != Lane.Eth) revert NotForSale();
        uint256 elapsed = (block.timestamp - s.clockStart).min(AUCTION_LENGTH);
        uint256 factor = AUCTION_START_X * AUCTION_LENGTH - (AUCTION_START_X - AUCTION_FLOOR_X) * elapsed;
        return s.cost.mulDivUp(factor, AUCTION_LENGTH * BPS);
    }

    /// buy an eth lane statement at the current price. the excess is refunded.
    function buyStatement(uint256 sid) external payable nonReentrant {
        uint256 price = priceOf(sid);
        if (msg.value < price) revert Underpaid();
        _unhold(sid);
        uint256 toBuyback = price * SALE_SPLIT / BPS;
        ethToBuyback += toBuyback;
        _checkpoint();
        ethPot += price - toBuyback;
        _syncFunded();
        emit StatementSold(sid, msg.sender, price);
        STATEMENTS.safeTransferFrom(address(this), msg.sender, sid);
        if (msg.value > price) SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
    }

    /*//////////////////////////////////////////////////////////////
                                 EXIT
    //////////////////////////////////////////////////////////////*/

    /// hands a statement to the exit module once its auction has run its length, or at once in the exit lane.
    function exitStatement(uint256 sid) external nonReentrant {
        address module = exitModule;
        if (module == address(0)) revert NoExitModule();
        Statement memory s = _statements[sid];
        if (!s.held) revert NotHeld();
        if (s.lane == Lane.Eth && block.timestamp < s.clockStart + AUCTION_LENGTH) revert AuctionRunning();
        address token = exitToken;
        uint256 required = STATEMENTS.creditScoreOf(sid) * unitPerPoint;
        _unhold(sid);

        uint256 balanceBefore = SafeTransferLib.balanceOf(token, address(this));
        _measuring().set(true);
        STATEMENTS.transferFrom(address(this), module, sid);
        IExitModule(module).exit(sid);
        _measuring().set(false);
        uint256 balanceAfter = SafeTransferLib.balanceOf(token, address(this));
        if (balanceAfter < balanceBefore + required) revert Underpaid();
        uint256 received = balanceAfter - balanceBefore;

        uint256 toBuyback = s.lane == Lane.Eth ? received * EXIT_SPLIT / BPS : 0;
        _xCheckpoint();
        xToBuyback += toBuyback;
        xPot += received - toBuyback;
        _syncXFunded();
        emit StatementExited(sid, s.lane, received);
    }

    /// merges two statements the controller names, within the daily cap. the base keeps its id and restarts its clock.
    function overprint() external nonReentrant {
        (bool ok, bytes memory out) = _ask(controller, abi.encodeCall(IController.nextOverprint, ()), gasleft(), 96);
        if (!ok) revert NotReady();
        (uint256 flag, uint256 baseId, uint256 topId) = abi.decode(out, (uint256, uint256, uint256));
        if (flag != 1) revert NotReady();
        Statement storage base = _statements[baseId];
        Statement storage top = _statements[topId];
        if (baseId == topId || !base.held || !top.held || base.lane != top.lane) revert BadOverprint();
        uint256 day = block.timestamp / 1 days;
        if (day != overprintDay) {
            overprintDay = day;
            overprintCount = 0;
        }
        if (overprintCount >= OVERPRINT_CAP_PER_DAY) revert DailyCap();
        overprintCount += 1;

        uint256 expected = STATEMENTS.creditScoreOf(baseId) + STATEMENTS.creditScoreOf(topId);
        uint256 cost = base.cost + top.cost;
        base.cost = cost;
        base.clockStart = uint64(block.timestamp);
        _unhold(topId);
        STATEMENTS.overprint(baseId, topId);
        if (STATEMENTS.creditScoreOf(baseId) != expected) revert BadStatement();
        emit Overprinted(baseId, topId, cost);
    }

    /*//////////////////////////////////////////////////////////////
                               BUYBACKS
    //////////////////////////////////////////////////////////////*/

    /// swaps up to one slice of the eth buyback pot for coin and sends it to the dead address. tips the caller.
    function buyback() external nonReentrant {
        uint256 pool = ethToBuyback;
        if (pool == 0) revert NothingToBuy();
        if (block.number < lastBuybackBlock + BUYBACK_DELAY) revert TooSoon();
        uint256 slice = pool.min(BUYBACK_SLICE);
        ethToBuyback = pool - slice;
        lastBuybackBlock = block.number;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(COIN),
            fee: 0,
            tickSpacing: LAUNCH_TICK_SPACING,
            hooks: IHooks(HOOK)
        });
        (uint256 spent, uint256 tip) = _swapSlice(key, true, slice, TickMath.MIN_SQRT_PRICE + 1, false);
        ethToBuyback += slice - spent - tip;
        emit Buyback(msg.sender, spent, tip);
        if (tip != 0) SafeTransferLib.safeTransferETH(msg.sender, tip);
    }

    /// same as buyback for the exit token pot through the coin and exit token pool, never past the fixed price
    /// limit. whatever the pool does not take at or inside the limit stays in the exit token buyback pot.
    function buybackExit() external nonReentrant {
        if (exitPoolId == bytes32(0)) revert Dormant();
        uint256 pool = xToBuyback;
        if (pool == 0) revert NothingToBuy();
        if (block.number < lastExitBuybackBlock + BUYBACK_DELAY) revert TooSoon();
        uint256 slice = pool.min(EXIT_SLICE_CREDITS * AVG_SCORE * unitPerPoint);
        xToBuyback = pool - slice;
        lastExitBuybackBlock = block.number;
        address token = exitToken;
        PoolKey memory key = _exitPoolKey;
        bool zeroForOne = Currency.unwrap(key.currency0) == token;
        uint160 limit = exitSqrtPriceLimit;
        (uint160 price,,,) = StateLibrary.getSlot0(MANAGER, PoolId.wrap(exitPoolId));
        if (zeroForOne ? price <= limit : price >= limit) revert PriceBeyondLimit();
        (uint256 spent, uint256 tip) = _swapSlice(key, zeroForOne, slice, limit, true);
        xToBuyback += slice - spent - tip;
        emit ExitBuyback(msg.sender, spent, tip);
        if (tip != 0) SafeTransferLib.safeTransfer(token, msg.sender, tip);
    }

    /// runs one buyback swap. the keeper tip is sized on the full slice and scaled down when the fill is partial.
    /// in the exit pool the hook takes its fee on what the swap actually spent, so the swap amount is cut to leave
    /// room for it and the hook may pull at most that room from the core. returns the input spent, fee included,
    /// and the tip owed. reverts when no coin was bought.
    function _swapSlice(PoolKey memory key, bool zeroForOne, uint256 slice, uint160 limit, bool exitPool)
        private
        returns (uint256 spent, uint256 tip)
    {
        uint256 tip0 = slice * KEEPER_TIP_BPS / BPS;
        uint256 budget = slice - tip0;
        uint256 swapIn = exitPool ? budget * (BPS - FEE_BPS) / BPS : budget;
        uint256 bought;
        (spent, bought) = abi.decode(
            MANAGER.unlock(abi.encode(key, zeroForOne, swapIn, limit, budget - swapIn, exitPool)), (uint256, uint256)
        );
        if (bought == 0) revert NothingBought();
        tip = tip0 * spent / budget;
    }

    /// pool manager callback. swaps exact in up to the price limit and delivers the coin to the dead address.
    /// returns the input spent and the coin bought. in the exit pool the hook is allowed to pull its fee from the
    /// core while the swap runs, and the spend is what the core balance actually lost.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(MANAGER)) revert OnlyPoolManager();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit, uint256 feeRoom, bool exitPool) =
            abi.decode(data, (PoolKey, bool, uint256, uint160, uint256, bool));
        (Currency cIn, Currency cOut) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        address tokenIn = Currency.unwrap(cIn);
        uint256 balanceBefore;
        if (exitPool) {
            balanceBefore = SafeTransferLib.balanceOf(tokenIn, address(this));
            SafeTransferLib.safeApprove(tokenIn, HOOK, feeRoom);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        BalanceDelta d = MANAGER.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        (int128 inDelta, int128 outDelta) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        if (inDelta > 0 || outDelta < 0) revert BadSwap();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-inDelta));
        if (owed > amountIn) revert BadSwap();
        if (tokenIn == address(0)) {
            MANAGER.settle{value: owed}();
        } else {
            MANAGER.sync(cIn);
            SafeTransferLib.safeTransfer(tokenIn, address(MANAGER), owed);
            MANAGER.settle();
        }
        uint256 spent = owed;
        if (exitPool) {
            SafeTransferLib.safeApprove(tokenIn, HOOK, 0);
            spent = balanceBefore - SafeTransferLib.balanceOf(tokenIn, address(this));
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 bought = uint256(uint128(outDelta));
        MANAGER.take(cOut, DEAD, bought);
        return abi.encode(spent, bought);
    }

    /*//////////////////////////////////////////////////////////////
                                OWNER
    //////////////////////////////////////////////////////////////*/

    /// queues an owner action. it can execute after the timelock.
    function queue(Action action, bytes calldata data) external onlyOwner {
        if (action == Action.SetController && frozen) revert Frozen();
        bytes32 id = keccak256(abi.encode(action, data));
        if (queuedEta[id] != 0) revert AlreadyQueued();
        uint256 eta = block.timestamp + TIMELOCK;
        queuedEta[id] = eta;
        emit Queued(id, action, data, eta);
    }

    /// cancels a queued owner action.
    function cancel(Action action, bytes calldata data) external onlyOwner {
        bytes32 id = keccak256(abi.encode(action, data));
        if (queuedEta[id] == 0) revert NotQueued();
        delete queuedEta[id];
        emit Cancelled(id, action);
    }

    /// executes a queued owner action once its timelock has passed.
    function execute(Action action, bytes calldata data) external onlyOwner nonReentrant {
        bytes32 id = keccak256(abi.encode(action, data));
        uint256 eta = queuedEta[id];
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert TooEarly();
        delete queuedEta[id];
        if (action == Action.SetController) {
            if (frozen) revert Frozen();
            address c = abi.decode(data, (address));
            if (c == address(0)) revert ZeroAddress();
            controller = c;
            emit ControllerSet(c);
        } else if (action == Action.SetExitModule) {
            _setExitModule(abi.decode(data, (address)));
        } else if (action == Action.SetExitPoolKey) {
            (PoolKey memory k, uint160 limit) = abi.decode(data, (PoolKey, uint160));
            _setExitPoolKey(k, limit);
        } else if (action == Action.AddTarget) {
            address t = abi.decode(data, (address));
            if (_forbidden(t)) revert ForbiddenTarget();
            allowedTarget[t] = true;
            emit TargetAdded(t);
        } else {
            frozen = true;
            emit FrozenSet();
        }
        emit Executed(id, action);
    }

    /// removes an allowed target at once.
    function removeTarget(address target) external onlyOwner {
        allowedTarget[target] = false;
        emit TargetRemoved(target);
    }

    function _setExitModule(address module) private {
        if (exitModule != address(0)) revert AlreadySet();
        if (module.code.length == 0) revert BadModule();
        address token = IExitModule(module).exitToken();
        if (token.code.length == 0 || _forbidden(module) || _forbidden(token)) revert BadModule();
        (bool ok, bytes memory out) = _ask(module, abi.encodeCall(IExitModule.unitPerPoint, ()), READ_GAS, 32);
        uint256 unit = ok ? abi.decode(out, (uint256)) : 0;
        if (unit == 0 || unit > type(uint128).max) revert BadModule();
        exitModule = module;
        exitToken = token;
        unitPerPoint = unit;
        xCheckpointTime = uint64(block.timestamp);
        emit ExitModuleSet(module, token, unit);
    }

    function _setExitPoolKey(PoolKey memory k, uint160 limit) private {
        if (exitModule == address(0)) revert NoExitModule();
        if (exitPoolId != bytes32(0)) revert AlreadySet();
        address c0 = Currency.unwrap(k.currency0);
        address c1 = Currency.unwrap(k.currency1);
        bool pair = (c0 == COIN && c1 == exitToken) || (c0 == exitToken && c1 == COIN);
        if (address(k.hooks) != HOOK || c0 >= c1 || !pair) revert BadKey();
        if (k.fee != 0 || k.tickSpacing != LAUNCH_TICK_SPACING) revert BadKey();
        if (limit <= TickMath.MIN_SQRT_PRICE || limit >= TickMath.MAX_SQRT_PRICE) revert BadKey();
        _exitPoolKey = k;
        exitSqrtPriceLimit = limit;
        bytes32 poolId = keccak256(abi.encode(k));
        exitPoolId = poolId;
        emit ExitPoolKeySet(poolId, k, limit);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// score of a credit in 1e4 scale, read from the score contract.
    function scoreOf(uint256 id) public view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    /// number of credits in a lane pile.
    function pileSize(Lane lane) external view returns (uint256) {
        return _piles[lane].size;
    }

    /// oldest credit in a lane pile, zero if empty.
    function pileHead(Lane lane) external view returns (uint256) {
        return _piles[lane].head;
    }

    /// the credit after id in its pile, zero at the end.
    function pileNext(uint256 id) external view returns (uint256) {
        return _credits[id].next;
    }

    /// up to n credit ids of a lane pile, oldest first, after startAfter. zero starts at the head.
    function pilePage(Lane lane, uint256 startAfter, uint256 n) external view returns (uint256[] memory ids) {
        uint256 first = startAfter == 0 ? _piles[lane].head : _credits[startAfter].next;
        uint256 count;
        for (uint256 id = first; id != 0 && count < n; id = _credits[id].next) {
            ++count;
        }
        ids = new uint256[](count);
        uint256 cursor = first;
        for (uint256 i; i < count; ++i) {
            ids[i] = cursor;
            cursor = _credits[cursor].next;
        }
    }

    /// pile membership, lane, cost basis and arrival time of a credit.
    function creditInfo(uint256 id) external view returns (bool inPile, Lane lane, uint256 cost, uint64 acquiredAt) {
        Credit storage c = _credits[id];
        return (c.inPile, c.lane, c.cost, c.acquiredAt);
    }

    /// whether the core holds a statement for sale or exit, with its lane, cost basis and auction clock start.
    function statementInfo(uint256 sid) external view returns (bool held, Lane lane, uint256 cost, uint64 clockStart) {
        Statement storage s = _statements[sid];
        return (s.held, s.lane, s.cost, s.clockStart);
    }

    /// every statement the core holds for sale or exit.
    function heldStatements() external view returns (uint256[] memory sids) {
        return _heldIds;
    }
}
