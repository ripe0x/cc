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
import {
    Lane,
    IController,
    IExitModule,
    ICoin,
    ICoreViews,
    ICredits,
    ICreditScore,
    IStatements,
    Stack,
    Settings,
    Mainnet
} from "./interfaces/Interfaces.sol";
import {IAuctionHouse, IAuctionFactory} from "./interfaces/AuctionHouse.sol";
import {CoreLib} from "./lib/CoreLib.sol";
import {SettingsBounds} from "./lib/SettingsBounds.sol";
import {SettingsStore} from "./lib/SettingsStore.sol";

/// custody and every rule of the credits engine. the only mutable slots are the ones the owner can
/// reach through the timelock: the controller, the exit module and the target list.
/// credits and statements sent to the core outside its doors are not tracked and stay in the core.
/// the core is the bounty recipient of the live skim hook: its `receive()` books the hook's eth into the pot.
contract Core is ICoreViews, IUnlockCallback, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using LibTransient for LibTransient.TBool;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    enum Action {
        SetController,
        SetExitModule,
        AddTarget,
        Freeze
    }

    /// the live state of a statement the core has a record of. `Sold` and `Returned` are stale records that
    /// `syncStatement` settles. `Ended` is a finished auction with a bid that anyone may settle on the house
    enum StatementStatus {
        None,
        Held,
        Listed,
        Bid,
        Ended,
        Sold,
        Returned
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

    /// `listed` means the record says the statement sits on the house under `auctionId`. the house is the truth, the
    /// record is settled lazily by `syncStatement`. an exit lane statement is held and never listed
    struct Statement {
        uint256 cost;
        uint256 auctionId;
        uint64 listedAt;
        uint64 slot;
        Lane lane;
        bool held;
        bool listed;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyOwner();
    error OnlyPoolManager();
    error BadSender();
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
    error NoExitModule();
    error Frozen();
    error AlreadySet();
    error AlreadyQueued();
    error NotQueued();
    error TooEarly();
    error NothingToBuy();
    error NothingBought();
    error TooSoon();
    error DailyCap();
    error BadRate();
    error BadStack();
    /// a setting is out of its bounds. `field` is its name
    error BadSetting(bytes32 field);
    /// the statement is not listed on the house by the record, or the house has no auction for it. `syncStatement` settles
    error NotListed();
    /// the statement still has a live auction on the house, so there is nothing to settle
    error AuctionLive();
    /// the statement's auction has a bid, so it cannot be cancelled or repriced
    error HasBid();
    /// the house did not take the statement, or an auction is in a state this call does not accept
    error BadAuction();
    /// a stack member that must be a contract has no code
    error NoCode(address who);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeesAdded(uint256 amount);
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
    /// a statement was listed on the house (at compose, after an unwind, after an overprint)
    event StatementListed(uint256 indexed sid, uint256 indexed auctionId, uint256 reserve);
    /// `syncStatement` found the auction gone and the statement with `holder`: the sale cleared, the proceeds are
    /// the house's to pay and `collectSales` books them
    event StatementSold(uint256 indexed sid, uint256 indexed auctionId, address indexed holder);
    event StatementRepriced(uint256 indexed sid, uint256 reserve);
    /// sale proceeds pulled from the house and booked: the part for the coin buyback and the rest for the pot
    event SalesCollected(uint256 amount, uint256 toBuyback);
    event SettingsSet(Settings settings);
    event RateSet(uint256 rate);
    event XRateSet(uint256 rate);
    event StatementExited(uint256 indexed sid, Lane lane, uint256 received);
    event Overprinted(uint256 indexed baseId, uint256 indexed topId, uint256 cost);
    event Buyback(address indexed caller, uint256 amountIn, uint256 tip);
    event ExitBuyback(address indexed caller, uint256 slice, uint256 coinIn);
    event Queued(bytes32 indexed id, Action action, bytes data, uint256 eta);
    event Executed(bytes32 indexed id, Action action);
    event Cancelled(bytes32 indexed id, Action action);
    event ControllerSet(address controller);
    event ExitModuleSet(address exitModule, address exitToken, uint256 unitPerPoint);
    event TargetAdded(address target);
    event TargetRemoved(address target);
    event FrozenSet();

    /*//////////////////////////////////////////////////////////////
                              PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// the coin supply of the launch, which the exit auction opening price reads
    uint256 public constant SUPPLY = 1_000_000_000e18;
    /// the exit rate the state starts at, bps of score. `setXRate` moves it, it is not a setting
    uint256 public constant XRATE_START = 6000;
    uint256 public constant TIMELOCK = 7 days;
    uint256 public constant OVERPRINT_CAP_PER_DAY = 8;

    uint256 private constant BPS = 10_000;
    uint256 private constant SPEND_WINDOW = 1 hours;
    uint256 private constant PAGE = 80;
    uint256 private constant MAX_FORMAT = 7;
    /// gas of the work after the compose that the reimbursement counts, and the listing on the house (eth lane only)
    uint256 private constant COMPOSE_OVERHEAD_GAS = 50_000;
    uint256 private constant LIST_GAS = 350_000;
    uint256 private constant READ_GAS = 200_000;
    address private constant DEAD = Mainnet.DEAD;
    // word positions in the house's auction record
    uint256 private constant W_FIRST = 2;
    uint256 private constant W_AMOUNT = 3;
    uint256 private constant W_RESERVE = 4;
    uint256 private constant W_OWNER = 5;
    uint256 private constant W_END = 7;
    bytes32 private constant MEASURING_SLOT = keccak256("core.measuring");

    ICredits private constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements private constant STATEMENTS = IStatements(Mainnet.STATEMENTS);

    address public immutable OWNER;
    address public immutable COIN;
    /// opening bid, wei per whole point, fixed at deploy
    uint256 public immutable RATE_START;
    /// the pnd auction house factory and the house this core created through it. the core owns the house forever
    address public immutable AUCTION_FACTORY;
    IAuctionHouse public immutable HOUSE;
    /// the artcoins stack this core launched on, fixed at deploy. HOOK is the only sender whose eth is booked as fees
    IPoolManager public immutable MANAGER;
    address public immutable HOOK;
    int24 public immutable TICK_SPACING;
    uint24 public immutable POOL_FEE;
    address public immutable FACTORY;
    address public immutable LOCKER;
    address public immutable ESCROW;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    address public controller;
    bool public frozen;
    address public exitModule;
    address public exitToken;
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

    uint256 public overprintDay;
    uint256 public overprintCount;

    mapping(Lane => Pile) private _piles;
    mapping(uint256 => Credit) private _credits;
    mapping(uint256 => Statement) private _statements;
    uint256[] private _heldIds;

    /// exit token base units per one unit of 1e4 scaled score, read once from the module when it is set
    uint256 public unitPerPoint;
    /// exit token auction: price in coin wei per exit token unit, wad scaled, at `xStartTime`. it halves every
    /// `xAuctionHalfLife`. the clock only runs while `xToBuyback` is not zero
    uint256 public xStartPrice;
    uint64 public xStartTime;

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert OnlyOwner();
        _;
    }

    constructor(
        address owner_,
        address coin_,
        address controller_,
        Stack memory stack_,
        uint256 rateStart_,
        Settings memory settings_
    ) {
        if (owner_ == address(0) || coin_ == address(0) || controller_ == address(0)) {
            revert ZeroAddress();
        }
        if (
            stack_.poolManager == address(0) || stack_.hook == address(0) || stack_.factory == address(0)
                || stack_.locker == address(0) || stack_.escrow == address(0) || stack_.auctionFactory == address(0)
        ) revert ZeroAddress();
        if (stack_.tickSpacing <= 0 || stack_.tickSpacing > 32_767) revert BadStack();
        // the stack members must be contracts. the coin is not deployed yet when the core is created
        if (stack_.poolManager.code.length == 0) revert NoCode(stack_.poolManager);
        if (stack_.hook.code.length == 0) revert NoCode(stack_.hook);
        if (stack_.factory.code.length == 0) revert NoCode(stack_.factory);
        if (stack_.locker.code.length == 0) revert NoCode(stack_.locker);
        if (stack_.escrow.code.length == 0) revert NoCode(stack_.escrow);
        if (stack_.auctionFactory.code.length == 0) revert NoCode(stack_.auctionFactory);
        if (!SettingsBounds.rateInBounds(rateStart_)) revert BadRate();
        OWNER = owner_;
        COIN = coin_;
        RATE_START = rateStart_;
        MANAGER = IPoolManager(stack_.poolManager);
        HOOK = stack_.hook;
        TICK_SPACING = stack_.tickSpacing;
        POOL_FEE = stack_.poolFee;
        FACTORY = stack_.factory;
        LOCKER = stack_.locker;
        ESCROW = stack_.escrow;
        AUCTION_FACTORY = stack_.auctionFactory;
        // the core owns its own house forever, and lets it take statements
        address house = IAuctionFactory(stack_.auctionFactory).createAuctionHouse();
        HOUSE = IAuctionHouse(house);
        STATEMENTS.setApprovalForAll(house, true);
        controller = controller_;
        allowedTarget[Mainnet.SEAPORT] = true;
        allowedTarget[Mainnet.CREDIT_STRATEGY] = true;
        rateAtCheckpoint = rateStart_;
        checkpointTime = uint64(block.timestamp);
        lastFillTime = uint64(block.timestamp);
        xRateAtCheckpoint = uint256(XRATE_START).min(settings_.xRateCap).max(settings_.xRateFloor);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        emit ControllerSet(controller_);
        emit TargetAdded(Mainnet.SEAPORT);
        emit TargetAdded(Mainnet.CREDIT_STRATEGY);
        // validates, stores at the settings slot and logs, by delegatecall into the library
        CoreLib.setSettings(settings_);
    }

    /// accepts eth and never reverts, because the hook pushes its bounty here with all gas and a revert would
    /// brick every swap in the pool. eth from the hook is booked into the pot unless a measurement is in flight.
    /// anything else, refunds from a purchase included, is booked later by `skim`. a measurement in flight books
    /// nothing, so eth arriving then just lowers the measured cost. there is no fallback on purpose: the hook
    /// calls `streamForward` here once the balance reaches 0.01 eth and relies on that call reverting.
    receive() external payable {
        if (msg.sender != HOOK || _measuring().get()) return;
        _checkpoint();
        ethPot += msg.value;
        _syncFunded();
        emit FeesAdded(msg.value);
    }

    /// the skim hook's referral payout target. with the referral cap at zero the hook never calls it. if the token
    /// admin raises the cap it pays referrals here, and the eth is booked later by `skim`, so it can never revert.
    function notify(address) external payable {}

    /// accepts statements and credits from their own contracts only.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(STATEMENTS) && msg.sender != address(CREDITS)) revert BadSender();
        return this.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                              FEE INTAKE
    //////////////////////////////////////////////////////////////*/

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

    /// wei per whole point right now, climbed lazily from the checkpoint. it stops climbing where the hourly cap
    /// (`spendCapBps` of the pot) no longer buys one average credit: `ethPot * spendCap = avgScore * rate`.
    function ethRate() public view returns (uint256 r) {
        r = rateAtCheckpoint;
        if (!funded) return r;
        Settings storage s = _st();
        return CoreLib.climb(
            r,
            ethPot * s.spendCapBps / s.avgScore,
            lastFillTime,
            checkpointTime,
            block.timestamp,
            s.climbBaseBps,
            s.climbMaxBps,
            s.climbDoubleEvery
        );
    }

    /// the most wei the core pays for credit id right now, bonus included.
    function ceilingOf(uint256 id) external view returns (uint256) {
        return _ceiling(id, ethRate());
    }

    function _checkpoint() private {
        rateAtCheckpoint = ethRate();
        checkpointTime = uint64(block.timestamp);
    }

    /// funded means the hourly cap can afford one average credit at the stored rate. the same threshold clamps the climb
    function _syncFunded() private {
        Settings storage s = _st();
        funded = ethPot * s.spendCapBps >= uint256(s.avgScore) * rateAtCheckpoint;
    }

    /// the price of credit id at `rate`: the flat share of the bid prices it as an average credit, the rest by its own
    /// score, then the controller bonus. with a fully flat bid the score contract is not read
    function _ceiling(uint256 id, uint256 rate) private view returns (uint256) {
        Settings storage s = _st();
        uint256 flat = s.flatBps;
        uint256 blend = flat * s.avgScore;
        if (flat != BPS) blend += (BPS - flat) * scoreOf(id);
        return blend * rate * (BPS + _bonus(id, s.bonusCapBps)) / (BPS * BPS * 1e4);
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
        r -= r * _st().dropBps * x / (BPS * p);
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
        if (windowSpent + x > windowPot * _st().spendCapBps / BPS) revert HourlyCap();
    }

    /*//////////////////////////////////////////////////////////////
                              EXIT RATE
    //////////////////////////////////////////////////////////////*/

    /// exit token bid in bps of score right now.
    function xRate() public view returns (uint256 r) {
        r = xRateAtCheckpoint;
        if (!xFunded) return r;
        Settings storage s = _st();
        uint256 cap = uint256(s.xRateCap).min(xPot * BPS / (uint256(s.avgScore) * unitPerPoint));
        if (cap <= r) return r;
        return (r + uint256(s.xRateClimbPerHour) * (block.timestamp - xCheckpointTime) / 1 hours).min(cap);
    }

    function _xCheckpoint() private {
        xRateAtCheckpoint = xRate();
        xCheckpointTime = uint64(block.timestamp);
    }

    function _syncXFunded() private {
        xFunded = xPot * BPS >= uint256(_st().avgScore) * xRateAtCheckpoint * unitPerPoint;
    }

    /*//////////////////////////////////////////////////////////////
                           CONTROLLER READS
    //////////////////////////////////////////////////////////////*/

    /// bounded read of a module. any failure or short answer returns false and a long answer is cut off.
    /// the settings, three packed slots at a fixed location shared with the library
    function _st() private pure returns (Settings storage) {
        return SettingsStore.load();
    }

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

    function _bonus(uint256 id, uint256 cap) private view returns (uint256 b) {
        (bool ok, bytes memory out) = _ask(controller, abi.encodeCall(IController.wants, (id)), READ_GAS, 32);
        if (!ok) return 0;
        b = abi.decode(out, (uint256)).min(cap);
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

        uint256 tip = (uint256(_st().tipSavingsBps) * (ceiling - cost) / BPS).min(uint256(_st().tipCapBps) * cost / BPS);
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
        uint256 drop = _st().xRateDropPerCredit;
        uint256 floor = _st().xRateFloor;
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
            r = r.zeroFloorSub(drop).max(floor);
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
            || t == address(MANAGER) || t == FACTORY || t == LOCKER || t == ESCROW || t == address(HOUSE)
            || t == AUCTION_FACTORY || t == Mainnet.PERMIT2 || t == Mainnet.POSITION_MANAGER
            || t == Mainnet.UNIVERSAL_ROUTER || t == exitModule || t == exitToken;
    }

    function _measuring() private pure returns (LibTransient.TBool storage) {
        return LibTransient.tBool(MEASURING_SLOT);
    }

    /*//////////////////////////////////////////////////////////////
                               COMPOSING
    //////////////////////////////////////////////////////////////*/

    /// composes the controller's page of eth lane credits into a statement. anyone may call and is repaid gas.
    function compose() external nonReentrant {
        _compose();
    }

    /// composes the controller's page of exit lane credits into a statement. anyone may call and is repaid gas.
    function composeExit() external nonReentrant {
        _compose();
    }

    /// one body for both lanes, told apart by the selector of the call, so the code is not duplicated
    function _compose() private {
        uint256 gasStart = gasleft();
        Lane lane = msg.sig == this.composeExit.selector ? Lane.Exit : Lane.Eth;
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

        Settings storage s = _st();
        uint256 cap = lane == Lane.Eth ? cost : PAGE * s.avgScore * ethRate() / 1e4;
        uint256 gasUsed = gasStart - gasleft() + COMPOSE_OVERHEAD_GAS + (lane == Lane.Eth ? LIST_GAS : 0);
        uint256 reimbursement =
            (gasUsed * block.basefee * s.reimburseBps / BPS).min(cap * s.reimburseCapBps / BPS).min(ethPot);
        if (reimbursement != 0) {
            _checkpoint();
            ethPot -= reimbursement;
            _syncFunded();
            if (lane == Lane.Eth) cost += reimbursement;
        }
        _heldIds.push(sid);
        _statements[sid] = Statement({
            cost: cost,
            auctionId: 0,
            listedAt: 0,
            slot: uint64(_heldIds.length - 1),
            lane: lane,
            held: true,
            listed: false
        });
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Composed(sid, lane, uint8(format), cost, reimbursement, msg.sender);
        if (lane == Lane.Eth) _list(sid);
        if (reimbursement != 0) SafeTransferLib.safeTransferETH(msg.sender, reimbursement);
    }

    /// lists a held statement on the house at the reserve of the current settings, from its cost. the house takes the
    /// statement with transferFrom, so there is no callback. an auction id must come back and the house must own it
    function _list(uint256 sid) private {
        Statement storage st = _statements[sid];
        uint256 reserve = st.cost * _st().reserveBps / BPS;
        uint256 id = HOUSE.createAuction(sid, address(STATEMENTS), _st().auctionDuration, reserve, 0);
        st.auctionId = id;
        st.listedAt = uint64(block.timestamp);
        st.listed = true;
        emit StatementListed(sid, id, reserve);
    }

    /// forgets a held statement and compacts the held list.
    function _unhold(uint256 sid) private {
        Statement storage s = _statements[sid];
        uint256 slot = s.slot;
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

    /// pulls the sale proceeds the house owes this core and books them: `saleToBuybackBps` to the coin buyback, the
    /// rest to the pot. permissionless. the core never bids, so everything the house credits to it is sale proceeds.
    /// the eth is booked here exactly once, by the amount the house reported, and `skim` never sees it before: it sits
    /// in the house (not in the balance) until this call moves it and books it in the same transaction
    function collectSales() external nonReentrant {
        _collect(true);
    }

    function _collect(bool strict) private {
        uint256 owed = HOUSE.pendingRefunds(address(this));
        if (owed == 0) return;
        uint256 before = address(this).balance;
        _measuring().set(true);
        (bool ok,) = address(HOUSE).call(abi.encodeCall(IAuctionHouse.withdrawRefund, ()));
        _measuring().set(false);
        if (!ok || address(this).balance < before + owed) {
            // buyback must never be blocked by the house
            if (strict) revert CallFailed();
            return;
        }
        uint256 toBuyback = owed * _st().saleToBuybackBps / BPS;
        ethToBuyback += toBuyback;
        _checkpoint();
        ethPot += owed - toBuyback;
        _syncFunded();
        emit SalesCollected(owed, toBuyback);
    }

    /// settles the record of a listed statement against the house, lazily and permissionlessly. if the auction is gone
    /// and the core does not hold the statement, it was sold: the record is cleared. if the core holds it (a sale
    /// that unwound, or a statement that came back), it is relisted at the reserve of the current settings
    function syncStatement(uint256 sid) external nonReentrant {
        Statement storage st = _statements[sid];
        if (!st.held || !st.listed) revert NotListed();
        if (_auction(st.auctionId)[W_OWNER] != 0) revert AuctionLive();
        address holder = _holderOf(sid);
        if (holder == address(this)) {
            _list(sid);
        } else if (holder == address(HOUSE)) {
            revert BadAuction();
        } else {
            emit StatementSold(sid, st.auctionId, holder);
            _unhold(sid);
        }
    }

    /// sets the reserve of a listing that has no bid to the reserve of the current settings. permissionless, so a
    /// change of `reserveBps` reaches old listings
    function repriceStatement(uint256 sid) external nonReentrant {
        Statement storage st = _statements[sid];
        _requireOpen(st);
        uint256 reserve = st.cost * _st().reserveBps / BPS;
        HOUSE.setAuctionReservePrice(st.auctionId, reserve);
        emit StatementRepriced(sid, reserve);
    }

    /// takes a listed statement back from the house. reverts if the auction has a bid, or is gone
    function _cancel(Statement storage st) private {
        _requireOpen(st);
        HOUSE.cancelAuction(st.auctionId);
        st.listed = false;
    }

    /// the record says listed, the house has the auction, and it has no bid
    function _requireOpen(Statement storage st) private view {
        if (!st.held || !st.listed) revert NotListed();
        uint256[12] memory w = _auction(st.auctionId);
        if (w[W_OWNER] == 0) revert NotListed();
        if (w[W_FIRST] != 0) revert HasBid();
    }

    /// the words of the house's auction record (`IAuctionHouse.Auction`, twelve static words). all zero when it is gone
    function _auction(uint256 id) private view returns (uint256[12] memory w) {
        (bool ok, bytes memory out) = address(HOUSE).staticcall(abi.encodeCall(IAuctionHouse.getAuction, (id)));
        if (!ok || out.length != 384) revert BadAuction();
        w = abi.decode(out, (uint256[12]));
    }

    /// the owner of a statement, or zero when it does not exist (a winner may burn it in an overprint)
    function _holderOf(uint256 sid) private view returns (address who) {
        (bool ok, bytes memory out) = address(STATEMENTS).staticcall(abi.encodeCall(IStatements.ownerOf, (sid)));
        if (ok && out.length == 32) who = abi.decode(out, (address));
    }

    /*//////////////////////////////////////////////////////////////
                                 EXIT
    //////////////////////////////////////////////////////////////*/

    /// hands a statement to the exit module. an eth lane statement must have been listed without a bid for
    /// `exitAfter`, and its listing is cancelled first (this reverts while a bid is live). an exit lane statement
    /// goes at once, it was never listed.
    function exitStatement(uint256 sid) external nonReentrant {
        address module = exitModule;
        if (module == address(0)) revert NoExitModule();
        Statement memory s = _statements[sid];
        if (!s.held) revert NotHeld();
        if (s.lane == Lane.Eth) {
            if (block.timestamp < s.listedAt + _st().exitAfter) revert TooEarly();
            _cancel(_statements[sid]);
        }
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

        uint256 toBuyback = s.lane == Lane.Eth ? received * _st().exitToBuybackBps / BPS : 0;
        _xCheckpoint();
        if (toBuyback != 0) {
            // new funds never inherit a decayed clock: the curve re anchors at the price now, floored at a quarter
            // of the start, and the clock restarts. with an empty pot the price now is the stored start price
            xStartPrice = exitAuctionPrice().max(xStartPrice / 4).max(1);
            xStartTime = uint64(block.timestamp);
        }
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

        // eth lane statements sit on the house: both listings are cancelled first (a bid on either reverts)
        bool eth = base.lane == Lane.Eth;
        if (eth) {
            _cancel(base);
            _cancel(top);
        }
        uint256 expected = STATEMENTS.creditScoreOf(baseId) + STATEMENTS.creditScoreOf(topId);
        uint256 cost = base.cost + top.cost;
        base.cost = cost;
        _unhold(topId);
        STATEMENTS.overprint(baseId, topId);
        if (STATEMENTS.creditScoreOf(baseId) != expected) revert BadStatement();
        emit Overprinted(baseId, topId, cost);
        // the base is listed again with the summed cost
        if (eth) _list(baseId);
    }

    /*//////////////////////////////////////////////////////////////
                               BUYBACKS
    //////////////////////////////////////////////////////////////*/

    /// swaps up to one slice of the eth buyback pot for coin in the canonical pool, then burns the coin on the token
    /// so the total supply falls. tips the caller. the hook's skim on this swap comes back through `receive`.
    function buyback() external nonReentrant {
        // sale proceeds waiting in the house are collected first, so they are never stranded. a house that fails
        // does not block the buyback
        _collect(false);
        uint256 pool = ethToBuyback;
        if (pool == 0) revert NothingToBuy();
        Settings storage s = _st();
        if (block.number < lastBuybackBlock + s.buybackDelay) revert TooSoon();
        uint256 slice = pool.min(s.buybackSlice);
        ethToBuyback = pool - slice;
        lastBuybackBlock = block.number;
        uint256 tip0 = slice * s.keeperTipBps / BPS;
        uint256 budget = slice - tip0;
        (uint256 spent, uint256 bought) = abi.decode(MANAGER.unlock(abi.encode(budget)), (uint256, uint256));
        if (bought == 0) revert NothingBought();
        ICoin(COIN).burn(bought);
        // the tip is sized on the full slice and scaled down when the fill is partial
        uint256 tip = tip0 * spent / budget;
        ethToBuyback += slice - spent - tip;
        emit Buyback(msg.sender, spent, tip);
        if (tip != 0) SafeTransferLib.safeTransferETH(msg.sender, tip);
    }

    /// pool manager callback of `buyback`. swaps exact eth in for coin, which comes to the core. returns the eth
    /// spent, skim included, and the coin bought. the core is exempt from the coin's tax.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(MANAGER)) revert OnlyPoolManager();
        (uint256 owed, uint256 bought) =
            CoreLib.swapIn(address(MANAGER), COIN, POOL_FEE, TICK_SPACING, HOOK, abi.decode(data, (uint256)));
        return abi.encode(owed, bought);
    }

    /// sells one slice of the exit token buyback pot for coin at the dutch auction price and burns the coin it
    /// takes from the caller. the caller must have approved the core for it. phase 2 only.
    function buybackExit(uint256 maxCoinIn) external nonReentrant {
        address token = exitToken;
        if (token == address(0)) revert NoExitModule();
        (uint256 slice, uint256 coinIn, uint256 price) = _exitQuote();
        if (slice == 0) revert NothingToBuy();
        if (coinIn > maxCoinIn) revert Slippage();
        xToBuyback -= slice;
        // never below a quarter of the start just played, never zero
        xStartPrice = (2 * price).max(xStartPrice / 4).max(1);
        xStartTime = uint64(block.timestamp);
        if (coinIn != 0) ICoin(COIN).burnFrom(msg.sender, coinIn);
        SafeTransferLib.safeTransfer(token, msg.sender, slice);
        emit ExitBuyback(msg.sender, slice, coinIn);
    }

    /// the exit token auction price now, coin wei per exit token unit in wad. it halves every 6 hours from the start
    /// price and may reach zero. while nothing is for sale the clock is stopped and this is the start price.
    function exitAuctionPrice() public view returns (uint256) {
        if (xToBuyback == 0) return xStartPrice;
        return CoreLib.decay(xStartPrice, block.timestamp - xStartTime, _st().xAuctionHalfLife);
    }

    /// the exit token slice a fill would take now and the coin it would burn.
    function exitAuctionQuote() external view returns (uint256 slice, uint256 coinIn) {
        (slice, coinIn,) = _exitQuote();
    }

    /// exit token of one full exit buyback slice: `exitSliceCredits` average credits
    function _fullSlice(uint256 unit) private view returns (uint256) {
        return uint256(_st().exitSliceCredits) * _st().avgScore * unit;
    }

    function _exitQuote() private view returns (uint256 slice, uint256 coinIn, uint256 price) {
        slice = xToBuyback.min(_fullSlice(unitPerPoint));
        price = exitAuctionPrice();
        coinIn = slice.mulDivUp(price, 1e18);
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

    /// sets every economic setting at once, effective now. the eth rate and the exit rate are checkpointed first, so no
    /// climb is credited under the wrong numbers, then the call is handed to the library untouched: it checks every
    /// field against its bounds, stores them and logs them. the funded flags are recomputed after, the exit rate is
    /// held inside the new band, and the exit auction is re anchored at its price now when its half life changes
    function setSettings(Settings calldata) external onlyOwner nonReentrant {
        _checkpoint();
        _xCheckpoint();
        Settings storage s = _st();
        bool module = exitModule != address(0);
        bool anchor = module && xToBuyback != 0;
        uint256 half = s.xAuctionHalfLife;
        uint256 price = anchor ? exitAuctionPrice() : 0;
        address lib = address(CoreLib);
        bytes4 sel = CoreLib.setSettings.selector;
        assembly ("memory-safe") {
            // the same arguments under the library's selector (a library names a struct in its signature)
            mstore(0, sel)
            calldatacopy(4, 4, sub(calldatasize(), 4))
            if iszero(delegatecall(gas(), lib, 0, calldatasize(), 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        if (anchor && s.xAuctionHalfLife != half) {
            xStartPrice = price.max(1);
            xStartTime = uint64(block.timestamp);
        }
        xRateAtCheckpoint = xRateAtCheckpoint.min(s.xRateCap).max(s.xRateFloor);
        _syncFunded();
        if (module) _syncXFunded();
    }

    /// resets the eth limit (wei per whole point) to `rate`, within the rate bounds. the climb restarts from it now
    function setRate(uint256 rate) external onlyOwner nonReentrant {
        if (!SettingsBounds.rateInBounds(rate)) revert BadRate();
        rateAtCheckpoint = rate;
        checkpointTime = uint64(block.timestamp);
        _syncFunded();
        emit RateSet(rate);
    }

    /// resets the exit rate (bps of score) to `rate`, within the floor and the cap of the settings
    function setXRate(uint256 rate) external onlyOwner nonReentrant {
        if (rate < _st().xRateFloor || rate > _st().xRateCap) revert BadRate();
        xRateAtCheckpoint = rate;
        xCheckpointTime = uint64(block.timestamp);
        if (exitModule != address(0)) _syncXFunded();
        emit XRateSet(rate);
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
        // the opening price asks the whole coin supply for one full slice
        uint256 start = SUPPLY * 1e18 / _fullSlice(unit);
        // below 1e12 the integer halves to zero within days, and zero hands the slice away
        if (start < 1e12) revert BadModule();
        xStartPrice = start;
        xStartTime = uint64(block.timestamp);
        emit ExitModuleSet(module, token, unit);
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
        // at most the pile size, so a huge n cannot blow up memory. the length is cut to the count found
        ids = new uint256[](n.min(_piles[lane].size));
        uint256 count;
        for (uint256 id = first; id != 0 && count < ids.length; id = _credits[id].next) {
            ids[count++] = id;
        }
        assembly ("memory-safe") {
            mstore(ids, count)
        }
    }

    /// pile membership, lane, cost basis and arrival time of a credit.
    function creditInfo(uint256 id) external view returns (bool inPile, Lane lane, uint256 cost, uint64 acquiredAt) {
        Credit storage c = _credits[id];
        return (c.inPile, c.lane, c.cost, c.acquiredAt);
    }

    /// whether the core holds a statement for sale or exit, with its lane, cost basis and the time it was listed
    /// (zero for an exit lane statement, which is never listed).
    function statementInfo(uint256 sid) external view returns (bool held, Lane lane, uint256 cost, uint64 clockStart) {
        Statement storage s = _statements[sid];
        return (s.held, s.lane, s.cost, s.listedAt);
    }

    /// every setting. the three packed slots go to the library, which unpacks them into the struct, and the answer is
    /// returned as it comes (an abi encoded `Settings`)
    function settings() external view returns (Settings memory) {
        bytes32 slot = SettingsStore.SLOT;
        address lib = address(CoreLib);
        bytes4 sel = CoreLib.unpack.selector;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sel)
            mstore(add(p, 4), sload(slot))
            mstore(add(p, 0x24), sload(add(slot, 1)))
            mstore(add(p, 0x44), sload(add(slot, 2)))
            if iszero(staticcall(gas(), lib, p, 0x64, 0, 0)) { revert(0, 0) }
            returndatacopy(p, 0, returndatasize())
            return(p, returndatasize())
        }
    }

    /// the live status of a statement, read from the house, with its auction id, the reserve, the top bid and the end
    /// time (zero until the first bid). `heldStatements` may include sold statements until `syncStatement` clears them
    function statementStatus(uint256 sid)
        external
        view
        returns (StatementStatus status, uint256 auctionId, uint256 reserve, uint256 bid, uint64 endTime)
    {
        Statement storage st = _statements[sid];
        if (!st.held) return (StatementStatus.None, 0, 0, 0, 0);
        if (!st.listed) return (StatementStatus.Held, 0, 0, 0, 0);
        uint256[12] memory a = _auction(st.auctionId);
        if (a[W_OWNER] == 0) {
            status = _holderOf(sid) == address(this) ? StatementStatus.Returned : StatementStatus.Sold;
            return (status, st.auctionId, 0, 0, 0);
        }
        if (a[W_FIRST] == 0) status = StatementStatus.Listed;
        else status = block.timestamp < a[W_END] ? StatementStatus.Bid : StatementStatus.Ended;
        // forge-lint: disable-next-line(unsafe-typecast)
        return (status, st.auctionId, a[W_RESERVE], a[W_AMOUNT], uint64(a[W_END]));
    }

    /// every statement the core holds for sale or exit.
    function heldStatements() external view returns (uint256[] memory sids) {
        return _heldIds;
    }
}
