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
import {RateStore} from "./lib/RateStore.sol";

/// custody and every rule of the credits engine. the owner sets the controller, the exit module and the target list at
/// once, and can lock each of the three for good (docs/ARCHITECTURE.md).
/// credits and statements sent to the core outside its doors are not tracked and stay in the core.
/// the pool's bounty recipient is the fee router, which flushes the fee eth here: `receive()` books eth from the fee
/// source (the router) into the pot.
contract Core is ICoreViews, IUnlockCallback, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using LibTransient for LibTransient.TBool;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

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
    error Measuring();
    error NoCredit();
    error PotTooSmall();
    error AboveCeiling();
    error HourlyCap();
    error Slippage();
    error Underpaid();
    error NoExitModule();
    error ExitTokenChanged();
    error TooEarly();
    /// the door `what` ("controller", "exitModule" or "targets") was locked for good by the owner
    error Locked(bytes32 what);
    error OnlyController();
    error OnlyPendingOwner();
    /// a sale paid less than the hard floor of the statement
    error BelowFloor();
    /// the controller did not answer `statementPrice` with a word
    error BadPrice();
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
    /// `rescueNft`: the credit is in a pile
    error InPile();
    /// `rescueNft`: the statement is on the books of the core
    error Held();
    /// `rescueNft`: the core is not the holder of the token, or the token is not an ERC721
    error NotHolder();
    /// `migrate` with no successor set
    error NoSuccessor();

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
    /// the controller sold a statement at once: the buyer and the price paid (booked as sale proceeds)
    event StatementSoldTo(uint256 indexed sid, address indexed buyer, uint256 price);
    event OwnershipTransferStarted(address indexed owner, address indexed pending);
    event OwnershipTransferred(address indexed from, address indexed to);
    event ControllerLocked();
    event ExitModuleLocked();
    event TargetsLocked();
    event ControllerSet(address controller);
    event ExitModuleSet(address exitModule, address exitToken, uint256 unitPerPoint);
    event TargetAdded(address target);
    event TargetRemoved(address target);
    event CoinRescued(address indexed to, uint256 amount);
    event NftRescued(address indexed token, uint256 indexed id, address indexed to);
    event SuccessorSet(address successor);
    event SuccessorLocked();
    /// `migrate` moved assets to the successor: eth, credits, statements, exit token, and the statements it skipped
    event Migrated(
        address indexed successor,
        uint256 eth,
        uint256 credits,
        uint256 statements,
        uint256 exitTokens,
        uint256 skippedStatements
    );

    /*//////////////////////////////////////////////////////////////
                              PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// the coin supply of the launch, which the exit auction opening price reads
    uint256 public constant SUPPLY = 1_000_000_000e18;
    /// the exit rate the state starts at, bps of score. `setXRate` moves it, it is not a setting
    uint256 public constant XRATE_START = 6000;
    uint256 public constant OVERPRINT_CAP_PER_DAY = 8;

    uint256 private constant BPS = 10_000;
    uint256 private constant SPEND_WINDOW = 1 hours;
    uint256 private constant PAGE = 80;
    uint256 private constant MAX_FORMAT = 7;
    /// gas of the work after the compose that the reimbursement counts, and the listing on the house (eth lane only)
    uint256 private constant COMPOSE_OVERHEAD_GAS = 50_000;
    uint256 private constant LIST_GAS = 350_000;
    uint256 private constant READ_GAS = 200_000;
    /// the most gas of an exit the redeem reimbursement counts, so a gas burning module cannot inflate it
    uint256 private constant EXIT_GAS = 1_500_000;
    /// gas the controller's `nextPage` may use, in both lanes. a full page of ControllerV1 costs about 73,000 (measured
    /// in test/ReviewFlowCore.t.sol), so this is about 7 times that. a gas burning controller cannot inflate the
    /// compose reimbursement past it
    uint256 private constant PAGE_GAS = 500_000;
    address private constant DEAD = Mainnet.DEAD;
    bytes32 private constant MEASURING_SLOT = keccak256("core.measuring");

    ICredits private constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements private constant STATEMENTS = IStatements(Mainnet.STATEMENTS);

    address public immutable COIN;
    /// opening bid, wei per whole point, fixed at deploy
    uint256 public immutable RATE_START;
    /// the pnd auction house factory and the house this core created through it. the core owns the house forever
    address public immutable AUCTION_FACTORY;
    IAuctionHouse public immutable HOUSE;
    /// the artcoins v2 stack this core launched on, fixed at deploy. FEE_SOURCE (the fee router) is the only sender whose
    /// eth is booked as fees
    IPoolManager public immutable MANAGER;
    address public immutable HOOK;
    address public immutable FEE_SOURCE;
    int24 public immutable TICK_SPACING;
    uint24 public immutable POOL_FEE;
    address public immutable FACTORY;
    address public immutable LOCKER;
    address public immutable ESCROW;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    address public controller;
    /// one way locks of the owner (docs/ARCHITECTURE.md): once set, the door never opens again
    bool public controllerLocked;
    bool public exitModuleLocked;
    bool public targetsLocked;
    address public exitModule;
    address public exitToken;
    mapping(address => bool) public allowedTarget;
    /// the owner and the pending owner of the two step handover
    address public owner;
    address public pendingOwner;

    uint256 public ethPot;
    uint256 public ethToBuyback;
    uint256 public xPot;
    uint256 public xToBuyback;

    uint256 public rateAtCheckpoint;
    uint64 public checkpointTime;
    uint64 public lastFillTime;

    uint64 windowStart;
    uint256 windowPot;
    uint256 windowSpent;

    uint256 xRateAtCheckpoint;
    uint64 xCheckpointTime;
    bool xFunded;

    uint256 public lastBuybackBlock;

    uint256 public overprintDay;
    uint256 public overprintCount;

    mapping(Lane => CoreLib.Pile) private _piles;
    mapping(uint256 => CoreLib.Credit) private _credits;
    mapping(uint256 => CoreLib.Statement) private _statements;
    uint256[] private _heldIds;

    /// exit token base units per one unit of 1e4 scaled score, read once from the module when it is set
    uint256 public unitPerPoint;
    /// exit token auction: price in coin wei per exit token unit, wad scaled, at `xStartTime`. it halves every
    /// `xAuctionHalfLife`. the clock only runs while `xToBuyback` is not zero
    uint256 public xStartPrice;
    uint64 public xStartTime;

    /// the contract `migrate` sends the assets to, and whether `setSuccessor` is closed for good
    address public successor;
    bool public successorLocked;

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() private view {
        if (msg.sender != owner) revert OnlyOwner();
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
                || stack_.feeSource == address(0)
        ) revert ZeroAddress();
        if (stack_.tickSpacing <= 0 || stack_.tickSpacing > 32_767) revert BadStack();
        // the stack members must be contracts. the coin is not deployed yet when the core is created
        if (stack_.poolManager.code.length == 0) revert NoCode(stack_.poolManager);
        if (stack_.hook.code.length == 0) revert NoCode(stack_.hook);
        if (stack_.feeSource.code.length == 0) revert NoCode(stack_.feeSource);
        if (stack_.factory.code.length == 0) revert NoCode(stack_.factory);
        if (stack_.locker.code.length == 0) revert NoCode(stack_.locker);
        if (stack_.escrow.code.length == 0) revert NoCode(stack_.escrow);
        if (stack_.auctionFactory.code.length == 0) revert NoCode(stack_.auctionFactory);
        if (!SettingsBounds.rateInBounds(rateStart_) || rateStart_ > settings_.rateCap) revert BadRate();
        owner = owner_;
        COIN = coin_;
        RATE_START = rateStart_;
        MANAGER = IPoolManager(stack_.poolManager);
        HOOK = stack_.hook;
        FEE_SOURCE = stack_.feeSource;
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
        RateStore.load().lastFillRate = rateStart_;
        xRateAtCheckpoint = uint256(XRATE_START).min(settings_.xRateCap).max(settings_.xRateFloor);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        emit OwnershipTransferred(address(0), owner_);
        emit ControllerSet(controller_);
        emit TargetAdded(Mainnet.SEAPORT);
        emit TargetAdded(Mainnet.CREDIT_STRATEGY);
        // validates, stores at the settings slot and logs, by delegatecall into the library
        CoreLib.setSettings(settings_);
    }

    /// accepts eth from anyone but the fee source and leaves it unbooked (`skim` books it). eth from the fee source (the
    /// router flushing the pool's fee eth) is booked: `feeToBuybackBps` of it to the coin buyback, the rest to the pot.
    /// while a measurement is in flight the fee source REVERTS: a router flush started inside a measured call (by
    /// the seller's callback, say) then fails as a whole and the fees wait in the router. every other sender is
    /// accepted unbooked, so a refund or a sale payout can never fail a call
    receive() external payable {
        if (msg.sender != FEE_SOURCE) return;
        if (_measuring().get()) revert Measuring();
        _checkpoint();
        uint256 toBuyback = msg.value * _st().feeToBuybackBps / BPS;
        if (toBuyback != 0) ethToBuyback += toBuyback;
        ethPot += msg.value - toBuyback;
        emit FeesAdded(msg.value);
    }

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

    /// wei per whole point right now: the price state (`rateAtCheckpoint` climbed lazily, bounded by the ceiling and
    /// `rateCap`) lowered to the clamp `ethPot * spendCapBps / (avgScore * clampCredits)`. the clamp follows the current
    /// pot and is not stored. the hourly room, `windowPot * spendCapBps / BPS - windowSpent`, is a separate check in
    /// `_requireRoom`, and a sell batch that crosses it reverts whole with `HourlyCap`. the math is in `CoreLib.climb`
    function ethRate() public view returns (uint256 read) {
        (, read) = _climb();
    }

    function _climb() private view returns (uint256, uint256) {
        return CoreLib.climb(rateAtCheckpoint, ethPot, lastFillTime, checkpointTime, block.timestamp);
    }

    /// the most wei the core pays for credit id right now, bonus included.
    function ceilingOf(uint256 id) external view returns (uint256) {
        return _ceiling(id, ethRate());
    }

    function _checkpoint() private {
        (rateAtCheckpoint,) = _climb();
        checkpointTime = uint64(block.timestamp);
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

    /// checkpoints, then books a spend of x from the pot: hourly cap, rate drop, fill time.
    function _spend(uint256 x) private {
        _checkpoint();
        uint256 p = ethPot;
        if (x == 0) revert ZeroAmount();
        if (x > p) revert PotTooSmall();
        _requireRoom(x);
        windowSpent += x;
        uint256 r = CoreLib.drop(rateAtCheckpoint, block.timestamp);
        rateAtCheckpoint = r;
        lastFillTime = uint64(block.timestamp);
        ethPot = p - x;
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
        return CoreLib.xRateOf(xRateAtCheckpoint, xFunded, xPot, unitPerPoint, xCheckpointTime, _st());
    }

    function _xCheckpoint() private {
        xRateAtCheckpoint = xRate();
        xCheckpointTime = uint64(block.timestamp);
    }

    function _syncXFunded() private {
        xFunded = CoreLib.xFundedOf(xPot, xRateAtCheckpoint, unitPerPoint, _st());
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
            _ask(controller, abi.encodeCall(IController.nextPage, (lane)), PAGE_GAS, (PAGE + 2) * 32);
        if (!ok) return (false, ids, 0);
        uint256 flag;
        (flag, ids, format) = abi.decode(out, (uint256, uint256[80], uint256));
        ready = flag == 1;
    }

    /*//////////////////////////////////////////////////////////////
                                PILES
    //////////////////////////////////////////////////////////////*/

    function _push(Lane lane, uint256 id, uint256 cost) private {
        CoreLib.push(_piles[lane], _credits, lane, id, cost);
    }

    function _pull(Lane lane, uint256 id) private returns (uint256 cost) {
        CoreLib.Credit storage c = _credits[id];
        if (!c.inPile || c.lane != lane) revert NotInPile(id);
        CoreLib.Pile storage p = _piles[lane];
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

    /// the first action of the eth pot entry points (`sellForEth`, `buyListing`, `compose`, `composeExit`): the fee
    /// router flushes its balance into `receive`, which books it, before any rate read, checkpoint or measurement of the
    /// entry point. the flush tip goes to the caller. a failing router does not fail the entry point (docs/FLOW.md 10.8)
    function _pullFees() private {
        CoreLib.pullFees(FEE_SOURCE, msg.sender);
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
        _pullFees();
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
        _pullFees();
        if (!allowedTarget[target] || _forbidden(target)) revert TargetNotAllowed();
        if (id == 0) revert ZeroId();
        if (CREDITS.ownerOf(id) == address(this)) revert AlreadyOwned();
        _checkpoint();
        uint256 ceiling = _ceiling(id, ethRate());
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

    /// sell credits into the exit token bid. phase 2 only. the body is `CoreLib.sellForExitToken`, called with the
    /// calldata untouched
    function sellForExitToken(uint256[] calldata ids) external nonReentrant {
        _toLib();
    }

    /// same as sellForExitToken with a floor on the total paid.
    function sellForExitToken(uint256[] calldata ids, uint256 minOut) external nonReentrant {
        _toLib();
    }

    /// checks that the caller owns credit id, which must not be the zero sentinel.
    function _owned(uint256 id) private view returns (uint256) {
        if (id == 0) revert ZeroId();
        if (CREDITS.ownerOf(id) != msg.sender) revert NotOwner();
        return id;
    }

    function _forbidden(address t) private view returns (bool) {
        return _forbiddenBase(t) || t == exitModule || t == exitToken;
    }

    /// every forbidden target except the exitModule and the exitToken, which a later set may name again
    function _forbiddenBase(address t) private view returns (bool) {
        return t == address(CREDITS) || t == address(STATEMENTS) || t == address(this) || t == COIN || t == HOOK
            || t == address(MANAGER) || t == FACTORY || t == LOCKER || t == ESCROW || t == FEE_SOURCE || t == address(HOUSE)
            || t == AUCTION_FACTORY || t == Mainnet.PERMIT2 || t == Mainnet.POSITION_MANAGER
            || t == Mainnet.UNIVERSAL_ROUTER;
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
        // the pull runs before `gasStart`, so the gas of the flush is covered by the flush tip only. the flush raises
        // `ethPot`, which can lift the `ethPot` term of the `_repay` cap
        _pullFees();
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

        uint256 reimbursement = _repay(
            gasStart - gasleft() + COMPOSE_OVERHEAD_GAS + (lane == Lane.Eth ? LIST_GAS : 0),
            lane == Lane.Eth ? cost : _notionalCap()
        );
        if (lane == Lane.Eth) cost += reimbursement;
        _heldIds.push(sid);
        _statements[sid] = CoreLib.Statement({
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

    /// the gas reimbursement of a compose or an exit: `reimburseBps` of the gas cost, at most `reimburseCapBps` of `cap`
    /// and of the pot. the pot is debited here, the caller pays it out last
    function _repay(uint256 gasUsed, uint256 cap) private returns (uint256 r) {
        Settings storage s = _st();
        r = (gasUsed * block.basefee * s.reimburseBps / BPS).min(cap * s.reimburseCapBps / BPS).min(ethPot);
        if (r != 0) {
            _checkpoint();
            ethPot -= r;
        }
    }

    /// the cap of an exit lane statement, which has no eth cost basis: a page at the opening rate and the average score
    function _notionalCap() private view returns (uint256) {
        return PAGE * _st().avgScore * RATE_START / 1e4;
    }

    /// the hard floor of a statement sale
    function _floor(uint256 cost) private view returns (uint256) {
        return cost * _st().saleFloorBps / BPS;
    }

    /// the reserve of a listing: the controller's asking price now (from the age of the listing), never below the hard
    /// floor. a controller that fails or answers short makes the caller revert, so a listing is never priced blind,
    /// except on the relist of `syncStatement`, which falls back to the hard floor so redemption never depends on the
    /// controller. told apart by the selector of the call, like `_compose`, so no code is duplicated
    function _reserveFor(uint256 sid) private view returns (uint256) {
        CoreLib.Statement storage st = _statements[sid];
        uint256 cost = st.cost;
        (bool ok, bytes memory out) =
            _ask(controller, abi.encodeCall(IController.statementPrice, (sid, cost, st.listedAt)), READ_GAS, 32);
        if (!ok) {
            if (msg.sig == this.syncStatement.selector) return _floor(cost);
            revert BadPrice();
        }
        return abi.decode(out, (uint256)).max(_floor(cost));
    }

    /// lists a held statement on the house at the controller's price at age zero (floored). the house takes the
    /// statement with transferFrom, so there is no callback. an auction id must come back and the house must own it
    function _list(uint256 sid) private {
        CoreLib.Statement storage st = _statements[sid];
        st.listedAt = uint64(block.timestamp);
        uint256 reserve = _reserveFor(sid);
        uint256 id = HOUSE.createAuction(sid, address(STATEMENTS), _st().auctionDuration, reserve, 0);
        st.auctionId = id;
        st.listed = true;
        emit StatementListed(sid, id, reserve);
    }

    /// forgets a held statement and compacts the held list.
    function _unhold(uint256 sid) private {
        CoreLib.Statement storage s = _statements[sid];
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
        _book(owed);
    }

    /// books sale proceeds: `saleToBuybackBps` to the coin buyback, the rest to the pot
    function _book(uint256 amount) private {
        uint256 toBuyback = amount * _st().saleToBuybackBps / BPS;
        ethToBuyback += toBuyback;
        _checkpoint();
        ethPot += amount - toBuyback;
        emit SalesCollected(amount, toBuyback);
    }

    /// the controller sells a listed eth lane statement at once, for `msg.value` at least the hard floor. a live
    /// auction always wins: the listing is cancelled, which reverts while a bid exists. the payment is booked as sale
    /// proceeds and the statement goes to `buyer`. no refund logic here, the controller refunds its caller
    function sellTo(uint256 sid, address buyer) external payable nonReentrant {
        if (msg.sender != controller) revert OnlyController();
        CoreLib.Statement storage st = _statements[sid];
        if (msg.value < _floor(st.cost)) revert BelowFloor();
        _cancel(st);
        STATEMENTS.transferFrom(address(this), buyer, sid);
        _book(msg.value);
        emit StatementSoldTo(sid, buyer, msg.value);
        _unhold(sid);
    }

    /// settles the record of a listed statement against the house, lazily and permissionlessly. if the auction is gone
    /// and the core does not hold the statement, it was sold: the record is cleared. if the core holds it (a sale
    /// that unwound, or a statement that came back), it is relisted at the reserve of the current settings
    function syncStatement(uint256 sid) external nonReentrant {
        CoreLib.Statement storage st = _statements[sid];
        if (!st.held || !st.listed) revert NotListed();
        if (_auction(st.auctionId)[CoreLib.W_OWNER] != 0) revert AuctionLive();
        address holder = _holderOf(sid);
        if (holder == address(this)) {
            _list(sid);
        } else {
            emit StatementSold(sid, st.auctionId, holder);
            _unhold(sid);
        }
    }

    /// sets the reserve of a listing that has no bid to the controller's asking price now (floored), from the age of
    /// the listing. permissionless: a first bidder calls it before bidding, and a change of the controller or of its
    /// settings or of `saleFloorBps` reaches old listings
    function repriceStatement(uint256 sid) external nonReentrant {
        CoreLib.Statement storage st = _statements[sid];
        _requireOpen(st);
        uint256 reserve = _reserveFor(sid);
        HOUSE.setAuctionReservePrice(st.auctionId, reserve);
        emit StatementRepriced(sid, reserve);
    }

    /// takes a listed statement back from the house. reverts if the auction has a bid, or is gone
    function _cancel(CoreLib.Statement storage st) private {
        _requireOpen(st);
        HOUSE.cancelAuction(st.auctionId);
        st.listed = false;
    }

    /// the record says listed, the house has the auction, and it has no bid
    function _requireOpen(CoreLib.Statement storage st) private view {
        if (!st.held || !st.listed) revert NotListed();
        uint256[12] memory w = _auction(st.auctionId);
        if (w[CoreLib.W_OWNER] == 0) revert NotListed();
        if (w[CoreLib.W_FIRST] != 0) revert HasBid();
    }

    /// the words of the house's auction record (`IAuctionHouse.Auction`, twelve static words). all zero when it is gone
    function _auction(uint256 id) private view returns (uint256[12] memory w) {
        bool ok;
        (ok, w) = CoreLib.auctionWords(address(HOUSE), id);
        if (!ok) revert BadAuction();
    }

    /// the owner of a statement, or zero when it does not exist (a winner may burn it in an overprint)
    function _holderOf(uint256 sid) private view returns (address who) {
        return CoreLib.holderOf(sid);
    }

    /*//////////////////////////////////////////////////////////////
                                 EXIT
    //////////////////////////////////////////////////////////////*/

    /// hands a statement to the exit module. an eth lane statement must have been listed without a bid for
    /// `exitAfter`, and its listing is cancelled first (this reverts while a bid is live). an exit lane statement
    /// goes at once, it was never listed.
    function exitStatement(uint256 sid) external nonReentrant {
        uint256 gasStart = gasleft();
        address module = exitModule;
        if (module == address(0)) revert NoExitModule();
        CoreLib.Statement memory s = _statements[sid];
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

        uint256 toBuyback = received * (s.lane == Lane.Eth ? _st().exitToBuybackBps : _st().exitLaneToBuybackBps) / BPS;
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
        // the caller's gas is repaid from the eth pot like a compose, after all state is final. nothing is added to a
        // cost basis. the gas counted is bounded, so a gas burning module cannot push it past the cap
        uint256 repay = _repay(
            (gasStart - gasleft() + COMPOSE_OVERHEAD_GAS).min(EXIT_GAS), s.lane == Lane.Eth ? s.cost : _notionalCap()
        );
        if (repay != 0) SafeTransferLib.safeTransferETH(msg.sender, repay);
    }

    /// merges two statements the controller names, within the daily cap. the base keeps its id and restarts its clock.
    function overprint() external nonReentrant {
        (bool ok, bytes memory out) = _ask(controller, abi.encodeCall(IController.nextOverprint, ()), gasleft(), 96);
        if (!ok) revert NotReady();
        (uint256 flag, uint256 baseId, uint256 topId) = abi.decode(out, (uint256, uint256, uint256));
        if (flag != 1) revert NotReady();
        CoreLib.Statement storage base = _statements[baseId];
        CoreLib.Statement storage top = _statements[topId];
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
    /// so the total supply falls. tips the caller. the core's own bounty share of the hook's skim on this swap reaches the pot
    /// through the router (`flush`), and a partial fill refund through the escrow (`skim`, after anyone claims it).
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
    /// spent, skim included, and the coin bought. the coin is restricted and the core is on its allowlist.
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

    /// starts the handover of the owner role: `to` becomes the owner when it calls `acceptOwnership`. the zero address
    /// clears a pending handover. there is no renounce
    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(msg.sender, to);
    }

    /// completes the handover, called by the pending owner. the zero caller never passes
    function acceptOwnership() external {
        if (msg.sender == address(0) || msg.sender != pendingOwner) revert OnlyPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        delete pendingOwner;
    }

    /// sets the controller at once. never zero. reverts after `lockController`
    function setController(address c) external onlyOwner {
        if (controllerLocked) revert Locked("controller");
        if (c == address(0)) revert ZeroAddress();
        controller = c;
        emit ControllerSet(c);
    }

    /// sets or replaces the exit module at once (any number of times until `lockExitModule`)
    function setExitModule(address module) external onlyOwner nonReentrant {
        if (exitModuleLocked) revert Locked("exitModule");
        _setExitModule(module);
    }

    /// allows a target of `buyListing` at once. forbidden targets are refused. reverts after `lockTargets`
    function addTarget(address t) external onlyOwner {
        if (targetsLocked) revert Locked("targets");
        if (_forbidden(t)) revert ForbiddenTarget();
        allowedTarget[t] = true;
        emit TargetAdded(t);
    }

    /// the three one way locks. each is irreversible. the settings and the controller's own sale settings stay open
    function lockController() external onlyOwner {
        controllerLocked = true;
        emit ControllerLocked();
    }

    /// reverts while no exit module is set, so phase 2 cannot be locked out by accident
    function lockExitModule() external onlyOwner {
        if (exitModule == address(0)) revert NoExitModule();
        exitModuleLocked = true;
        emit ExitModuleLocked();
    }

    /// after this no target can be added. removing one still works
    function lockTargets() external onlyOwner {
        targetsLocked = true;
        emit TargetsLocked();
    }

    /// sends coin the core holds to `to`. the core holds coin only in passing (the buyback burns what it buys in the same
    /// call), so this reaches only coin that was sent to it, which the allowlist of the restricted coin permits.
    /// coin only: never eth, credits, statements or the exit token. owner only and guarded, both checked by the library,
    /// to which the call is handed untouched (the bytes saved keep the runtime under the size limit). it refuses the
    /// zero address, sends and logs `CoinRescued`
    function rescueCoin(address, uint256) external {
        _toLib();
    }

    /// sends an ERC721 token the core holds to `to` with `transferFrom`: a credit only while it is not in a pile, a
    /// statement only while the core has no record of it, any other ERC721 freely. owner only and guarded, both checked
    /// by the library, to which the call is handed untouched. `ownerOf` of the token must answer with the core, so
    /// the call reaches no ERC20, no coin and no exit token. logs `NftRescued`
    function rescueNft(address, uint256, address) external {
        _toLib();
    }

    /// sets the successor that `migrate` sends the assets to. the zero address means no migration. it must have code.
    /// reverts `Locked("successor")` after `lockSuccessor`. owner only, checked by the library, to which the call is
    /// handed untouched. logs `SuccessorSet`
    function setSuccessor(address) external {
        _toLib();
    }

    /// closes `setSuccessor` for good, one way. allowed while the successor is zero, which disables `migrate` for good.
    /// logs `SuccessorLocked`
    function lockSuccessor() external {
        _toLib();
    }

    /// moves what the core tracks to the successor, in batches: the eth pots, the exit token pots, up to `maxCredits`
    /// credits from the head of each pile and up to `maxStatements` held statements. callable again until nothing is
    /// left. a statement with a live bid on the house, or a sold one not yet settled by `syncStatement`, is skipped and
    /// counted in `Migrated`. owner only and guarded, both checked by the library, to which the call is handed
    /// untouched. reverts `NoSuccessor` while the successor is zero
    function migrate(uint256, uint256) external {
        _toLib();
    }

    /// delegatecalls the library with the calldata of this call, under the selector of this call, and reverts with
    /// whatever it reverts with
    function _toLib() private {
        address lib = address(CoreLib);
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, 0, calldatasize())
            if iszero(delegatecall(gas(), lib, p, calldatasize(), 0, 0)) {
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
    }

    /// removes an allowed target at once.
    function removeTarget(address target) external onlyOwner {
        allowedTarget[target] = false;
        emit TargetRemoved(target);
    }

    /// sets every economic setting at once, effective now. the eth rate and the exit rate are checkpointed first, so no
    /// climb is credited under the wrong numbers, then the call is handed to the library untouched: it checks every
    /// field against its bounds, stores them and logs them. the exit funded flag is recomputed after, the exit rate is
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
            // the same arguments under the library's selector (a library names a struct in its signature), built above
            // the free memory pointer
            let p := mload(0x40)
            mstore(p, sel)
            calldatacopy(add(p, 4), 4, sub(calldatasize(), 4))
            if iszero(delegatecall(gas(), lib, p, calldatasize(), 0, 0)) {
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
        if (anchor && s.xAuctionHalfLife != half) {
            xStartPrice = price.max(1);
            xStartTime = uint64(block.timestamp);
        }
        xRateAtCheckpoint = xRateAtCheckpoint.min(s.xRateCap).max(s.xRateFloor);
        if (module) _syncXFunded();
    }

    /// restates the eth rate (wei per whole point) as `rate`, within the rate bounds. the stored rate and the ceiling
    /// anchor are both `rate`, the fill clock is unchanged. the clamp and the ceiling still bound the rate on read
    function setRate(uint256 rate) external onlyOwner nonReentrant {
        if (!SettingsBounds.rateInBounds(rate) || rate > _st().rateCap) revert BadRate();
        RateStore.load().lastFillRate = rate;
        rateAtCheckpoint = rate;
        checkpointTime = uint64(block.timestamp);
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

    /// sets or replaces the exit module. the exit token never changes once set.
    /// the unit is read again every time, so naming the same module again is how the unit is updated. the exit rate is
    /// checkpointed under the old unit first and the exit funded flag resynced after. a later set never touches the exit
    /// auction price or clock: the price is coin per exit token, the unit only changes the slice. a dormant allowed
    /// target flag of the new module is cleared, so it cannot come back to life when the module is replaced
    function _setExitModule(address module) private {
        address old = exitModule;
        if (module.code.length == 0) revert BadModule();
        address token = IExitModule(module).exitToken();
        if (old != address(0) && token != exitToken) revert ExitTokenChanged();
        if (token.code.length == 0 || _forbiddenBase(module) || _forbiddenBase(token)) revert BadModule();
        (bool ok, bytes memory out) = _ask(module, abi.encodeCall(IExitModule.unitPerPoint, ()), READ_GAS, 32);
        uint256 unit = ok ? abi.decode(out, (uint256)) : 0;
        if (unit == 0 || unit > type(uint128).max) revert BadModule();
        // the climb so far is credited under the old unit
        _xCheckpoint();
        exitModule = module;
        exitToken = token;
        unitPerPoint = unit;
        // the opening price asks the whole coin supply for one full slice
        uint256 start = SUPPLY * 1e18 / _fullSlice(unit);
        // below 1e12 the integer halves to zero within days, and zero hands the slice away
        if (start < 1e12) revert BadModule();
        if (allowedTarget[module]) delete allowedTarget[module];
        if (old == address(0)) {
            xStartPrice = start;
            xStartTime = uint64(block.timestamp);
        } else {
            _syncXFunded();
        }
        emit ExitModuleSet(module, token, unit);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// score of a credit in 1e4 scale, read from the score contract.
    function scoreOf(uint256 id) public view returns (uint256) {
        return CoreLib.scoreOf(id);
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
        CoreLib.Credit storage c = _credits[id];
        return (c.inPile, c.lane, c.cost, c.acquiredAt);
    }

    /// whether the core holds a statement for sale or exit, with its lane, cost basis and the time it was listed
    /// (zero for an exit lane statement, which is never listed).
    function statementInfo(uint256 sid) external view returns (bool held, Lane lane, uint256 cost, uint64 clockStart) {
        CoreLib.Statement storage s = _statements[sid];
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
        CoreLib.Statement storage st = _statements[sid];
        if (!st.held) return (StatementStatus.None, 0, 0, 0, 0);
        if (!st.listed) return (StatementStatus.Held, 0, 0, 0, 0);
        uint256[12] memory a = _auction(st.auctionId);
        if (a[CoreLib.W_OWNER] == 0) {
            status = _holderOf(sid) == address(this) ? StatementStatus.Returned : StatementStatus.Sold;
            return (status, st.auctionId, 0, 0, 0);
        }
        if (a[CoreLib.W_FIRST] == 0) status = StatementStatus.Listed;
        else status = block.timestamp < a[CoreLib.W_END] ? StatementStatus.Bid : StatementStatus.Ended;
        // forge-lint: disable-next-line(unsafe-typecast)
        return (status, st.auctionId, a[CoreLib.W_RESERVE], a[CoreLib.W_AMOUNT], uint64(a[CoreLib.W_END]));
    }

    /// every statement the core holds for sale or exit.
    function heldStatements() external view returns (uint256[] memory sids) {
        return _heldIds;
    }
}
