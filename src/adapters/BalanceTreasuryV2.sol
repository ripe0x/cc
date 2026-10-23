// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {
    IBalanceModule,
    IRedeemer,
    ICreditScore,
    ICredits,
    Mainnet,
    Settings,
    BalanceBid,
    CommittedPayout,
    RedeemerState,
    RATE_SCORE,
    POINT_UNIT
} from "../interfaces/Interfaces.sol";

/// the InterfaceAuctionWithdrawals surface this treasury reads
interface IV2BalanceToken {
    function statements() external view returns (address);
    function SCORE_TO_TOKEN() external view returns (uint256);
    function decimals() external view returns (uint8);
    function ready() external view returns (bool);
    function totalRetired() external view returns (uint256);
    function launchRetirement() external view returns (uint256);
    function quote(uint256 id) external view returns (uint256);
    function withdraw(uint256 id, uint256 expectedAmount) external returns (uint256);
}

interface IV2Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IV2Statements {
    function approve(address to, uint256 id) external;
    function creditScoreOf(uint256 id) external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
}

interface IV2Credits {
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}

interface IV2Core {
    function owner() external view returns (address);
    function COIN() external view returns (address);
    function retired() external view returns (bool);
    function balanceModule() external view returns (address);
    function controller() external view returns (address);
    function artist() external view returns (address);
    function settings() external view returns (Settings memory);
    function ethPrice() external view returns (uint256);
    function creditInfo(uint256 id) external view returns (bool inPile, uint256 cost, uint64 acquiredAt);
    function adopt(uint256[] calldata ids) external;
}

/// the ControllerV3 views the bid reads
interface IV2Controller {
    function valuePerPoint(bool forSale) external view returns (uint256 value, bool ok);
    function creditSoldAt(uint256 id) external view returns (uint64);
    function floorMultBps() external view returns (uint256);
}

interface IV2Coin {
    function totalSupply() external view returns (uint256);
    function burnFrom(address account, uint256 amount) external;
}

/// treasury v2, the balance module and the custodian of the balance token. the Core faces the v1 surface unchanged
/// (`unitPerPoint` 1e14, `available`, `pay`, `redeem`). custody `B` is split into earmarks and working funds:
///
///   D = totalOwed, recorded unpaid payments; G = bidBudget, the balance bid's funds; K = totalBuckets, the redeemer
///   buckets; L = totalCommitted, vesting and deferred payouts; W = B - D - G - K - L, working funds
///
/// the rule is B >= D + G + K + L. the Core's exchange pays from W (`available()`). `cushion` is the part of W kept for
/// the Core's exchange: `sweep`, allocation and withdrawal take only `surplus()`, W above the cushion. no earmark pays
/// from another: the bid pays from G, a redeemer from its own bucket, a committed payout from L. every committed payout
/// is reserved in full when it is created. the owner is the Core's owner and manages the backing: it can pause, return
/// a switched off redeemer's bucket or the bid budget to working funds and withdraw the surplus
contract BalanceTreasuryV2 is IBalanceModule {
    address public immutable core;
    address public immutable override balanceToken;
    /// the Core's coin, the token redemptions burn
    address public immutable ccToken;
    /// the treasury `receiveMigration` accepts from, zero for none
    address public immutable predecessor;
    /// redeemer 1, registered at deployment: the conversion contribution and a migrated claim reserve fill its bucket
    address public immutable proRataRedeemer;
    uint256 public constant override unitPerPoint = 1e14;

    uint256 private constant BPS = 10_000;
    /// gas kept back from a payment transfer so an unpaid amount can still be recorded: two storage writes and an event
    uint256 private constant ACCRUE_RESERVE = 60_000;
    /// the period of the per-period caps of the bid and the redeemers
    uint256 private constant PERIOD = 1 days;
    /// a newly registered redeemer draws nothing before this delay
    uint256 private constant NEW_REDEEMER_DELAY = 1 days;
    uint256 private constant MAX_REDEEMERS = 8;
    uint256 private constant MAX_DURATION = 4 * 365 days;
    /// transient reentrancy lock slot, keccak256("BalanceTreasuryV2.lock") less one
    uint256 private constant LOCK_SLOT = 0xacad7041682364bcd8282b25bcb22caf85f0b515f60f41b113151841b24681ad;

    error InvalidConfiguration();
    error OnlyCore();
    error OnlyOwner();
    error OnlyPredecessor();
    error Reentrant();
    error Paused();
    error ConversionOff();
    error BidOff();
    error BidUnpriced();
    error ReturnLocked(uint256 id);
    error NotInPile(uint256 id);
    error NotOwner(uint256 id);
    error RedemptionOff();
    error NotHeld();
    error RedeemedBelowRating();
    error InsufficientAvailable();
    error InsufficientSurplus();
    error InsufficientBucket();
    error OverCap();
    error BadSetting(bytes32 field);
    error BadPayout();
    error UnknownRedeemer();
    error ZeroAmount();
    error InvalidAmount();
    error InvalidRecipient();
    error Expired();
    error StaleEpoch();
    error Slippage();
    error BurnMismatch();
    error ShortPayment();
    error RedeemerOn();
    error Insolvent();
    error ProtectedAsset();
    error NothingDue();

    event StatementConverted(uint256 indexed statementId, uint256 received, uint256 toProRata, uint16 contributionBps);
    event PaymentAccrued(address indexed to, uint256 amount);
    event OwedClaimed(address indexed to, uint256 amount);
    event CreditSold(
        uint256 indexed id, address indexed seller, uint256 score, uint256 paid, uint256 toArtist, uint256 bidBps
    );
    event BidFill(address indexed seller, uint256 credits, uint256 paid, uint256 toArtist, uint256 bidBudget);
    event Swept(uint256 surplus, uint256 toBid, uint256 toBuckets);
    event Allocated(address indexed redeemer, uint256 amount);
    event Unallocated(address indexed redeemer, uint256 amount);
    event RedeemerRegistered(address indexed redeemer, uint40 activeAt);
    event RedeemerCapsSet(address indexed redeemer, uint128 perCall, uint128 perPeriod, uint128 lifetime, uint64 epoch);
    event RedeemerSwitched(address indexed redeemer, bool on);
    event SharesSet(address indexed redeemer, uint16 shareBps, uint16 bidShareBps, uint16 totalShareBps);
    event CCRedeemed(
        address indexed redeemer,
        address indexed burner,
        address indexed recipient,
        uint256 ccIn,
        uint256 amount,
        uint8 mode,
        uint32 duration,
        uint256 claimId,
        uint64 epoch
    );
    event ClaimReleased(uint256 indexed claimId, address indexed recipient, uint256 amount);
    event SwitchesSet(bool conversionEnabled, bool workingPaymentsEnabled, bool bidEnabled);
    event PausedSet(bool paused);
    event CushionSet(uint256 cushion);
    event ConversionToClaimBpsSet(uint16 bps);
    event BidSet(BalanceBid bid);
    event WorkingWithdrawn(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event MigrationReceived(address indexed predecessor, uint256 claimsImported, uint256 custody);

    mapping(address => uint256) public owed;
    uint256 public totalOwed;
    uint256 public bidBudget;
    uint256 public totalBuckets;
    uint256 public totalCommitted;
    /// working funds kept for the Core's exchange
    uint256 public cushion;
    /// cumulative inflow and outflow of the bid budget
    uint256 public bidIn;
    uint256 public bidOut;

    /// share of each measured conversion receipt added to the pro-rata redeemer's bucket, bps
    uint16 public conversionToClaimBps;
    /// share of each sweep added to the bid budget, bps. with the redeemer shares at most 10,000 in all
    uint16 public bidShareBps;
    uint16 public totalShareBps;
    bool public conversionEnabled;
    bool public workingPaymentsEnabled;
    bool public bidEnabled;
    bool public paused;

    BalanceBid public bid;
    /// the bid price at the last fill or setting, bps of par, and its time
    uint16 public bidAnchorBps;
    uint40 public bidAnchorTime;
    uint40 public bidPeriodStart;
    uint128 public bidPeriodUsed;

    mapping(address => RedeemerState) internal _redeemers;
    address[] public redeemerList;
    CommittedPayout[] private _claims;

    constructor(
        address core_,
        address balanceToken_,
        address proRataRedeemer_,
        uint128 proRataPerPeriod,
        address predecessor_
    ) {
        if (core_.code.length == 0 || balanceToken_.code.length == 0) revert InvalidConfiguration();
        IV2BalanceToken token = IV2BalanceToken(balanceToken_);
        if (
            token.statements() != Mainnet.STATEMENTS || token.SCORE_TO_TOKEN() != unitPerPoint || token.decimals() != 18
        ) revert InvalidConfiguration();
        address coin = IV2Core(core_).COIN();
        if (coin.code.length == 0) revert InvalidConfiguration();
        if (predecessor_ != address(0) && predecessor_.code.length == 0) revert InvalidConfiguration();
        core = core_;
        balanceToken = balanceToken_;
        ccToken = coin;
        predecessor = predecessor_;
        proRataRedeemer = proRataRedeemer_;
        conversionToClaimBps = 1_000;
        _register(proRataRedeemer_, type(uint128).max, proRataPerPeriod, type(uint128).max);
    }

    modifier onlyCore() {
        if (msg.sender != core) revert OnlyCore();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert OnlyOwner();
        _;
    }

    /// one transient lock over every mutation and outflow, so the Core's two sequential `pay` calls of one sale both
    /// pass while a token, artwork or redeemer callback cannot enter a second outflow
    modifier nonReentrant() {
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(LOCK_SLOT)
        }
        if (locked != 0) revert Reentrant();
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 0)
        }
    }

    modifier notPaused() {
        if (paused) revert Paused();
        _;
    }

    // ------------------------------------------------------------------ views

    /// the Core's current owner, read at each use so an ownership handover carries over
    function owner() public view returns (address) {
        return IV2Core(core).owner();
    }

    /// `B`, the balance token held here
    function custody() public view returns (uint256) {
        return SafeTransferLib.balanceOf(balanceToken, address(this));
    }

    /// D + G + K + L
    function earmarked() public view returns (uint256) {
        return totalOwed + bidBudget + totalBuckets + totalCommitted;
    }

    /// `W`, custody less every earmark, floored at zero
    function working() public view returns (uint256) {
        uint256 bal = custody();
        uint256 e = earmarked();
        return bal > e ? bal - e : 0;
    }

    /// working funds above the cushion: what `sweep`, allocation and withdrawal may take
    function surplus() public view returns (uint256) {
        uint256 w = working();
        return w > cushion ? w - cushion : 0;
    }

    function solvent() public view returns (bool) {
        return custody() >= earmarked();
    }

    /// this treasury is the bound Core's module and the Core has not retired: the gate of conversions, working
    /// payments and the bid, which need the Core
    function selected() public view returns (bool) {
        return IV2Core(core).balanceModule() == address(this) && !IV2Core(core).retired();
    }

    /// this treasury is the bound Core's module: the gate of redemptions, which need no Core interaction, so a retired
    /// Core does not strand the buckets. a module replacement closes them
    function selectedForClaims() public view returns (bool) {
        return IV2Core(core).balanceModule() == address(this);
    }

    function retirementFinalized() public view returns (bool) {
        IV2BalanceToken token = IV2BalanceToken(balanceToken);
        uint256 retired = token.totalRetired();
        return retired != 0 && retired == token.launchRetirement();
    }

    /// a statement conversion can run: the switch, the selection, finalized retirement and the registered renderer
    function conversionReady() public view returns (bool) {
        return conversionEnabled && selected() && retirementFinalized() && IV2BalanceToken(balanceToken).ready();
    }

    /// the balance token the Core's exchange may pay out: working funds while working payments are on and this
    /// treasury is selected, else zero. never reverts, so `setBalanceModule` can probe it before selection
    function available() public view override returns (uint256) {
        if (!workingPaymentsEnabled || !selected()) return 0;
        return working();
    }

    /// false: this treasury has no `migrateTo`. read by the v1 `migrateTo` handshake
    function migrated() external pure returns (bool) {
        return false;
    }

    /// whether any redeemer is on. read by the v1 `migrateTo` handshake, which requires false
    function ccRedemptionEnabled() public view returns (bool) {
        for (uint256 i; i < redeemerList.length; ++i) {
            if (_redeemers[redeemerList[i]].on) return true;
        }
        return false;
    }

    function redeemers(address redeemer) external view returns (RedeemerState memory) {
        return _redeemers[redeemer];
    }

    function redeemerCount() external view returns (uint256) {
        return redeemerList.length;
    }

    function claimCount() external view returns (uint256) {
        return _claims.length;
    }

    /// committed payout `claimId` (1 based) and the amount `release` would pay now
    function claimOf(uint256 claimId) external view returns (CommittedPayout memory c, uint256 due) {
        c = _claims[claimId - 1];
        due = _vested(c) - c.released;
    }

    /// the bid price now, bps of par: the anchor climbed `climbBps` per full step, inside [floorBps, capBps]
    function bidBpsNow() public view returns (uint256 x) {
        BalanceBid memory b = bid;
        x = bidAnchorBps;
        if (b.stepSeconds != 0) x += (block.timestamp - bidAnchorTime) / b.stepSeconds * b.climbBps;
        if (x > b.capBps) x = b.capBps;
        if (x < b.floorBps) x = b.floorBps;
    }

    /// `bidBpsNow()` below the controller's credit floor multiplier, read at each fill: the Core's `balanceBidCapBps`
    /// can fall after `setBid`, and a credit the engine resells after its return lock must stay worth more at the
    /// engine than here
    function _fillBps() private view returns (uint256 bps) {
        bps = bidBpsNow();
        uint256 floorMult = IV2Controller(IV2Core(core).controller()).floorMultBps();
        if (bps >= floorMult) bps = floorMult - 1;
    }

    /// what `sellCredit([id])` would pay the seller and the artist now, zero when the bid could not price or fund it.
    /// the return lock, the caps and the holder are checked only by the fill
    function quoteCredit(uint256 id) external view returns (uint256 paid, uint256 toArtist) {
        if (paused || !bidEnabled || !selected()) return (0, 0);
        (bool ok, uint256 ethPrice, uint256 vSell) = _ethTerms();
        if (!ok) return (0, 0);
        paid = _price(_scoreOf(id), _fillBps(), ethPrice, vSell, bid.overEthBps);
        toArtist = paid * IV2Core(core).settings().buyToArtistBps / BPS;
        if (paid + toArtist > bidBudget) return (0, 0);
    }

    // ------------------------------------------------------------------ the Core's module calls

    /// the Core transfers custody first. approval is limited to this statement and consumed by the withdrawal. the receipt
    /// is measured and must be at least the statement's rating times `unitPerPoint`; `conversionToClaimBps` of it fills
    /// the pro-rata redeemer's bucket and every token stays here, so the Core's receipt check reads the whole amount
    function redeem(uint256 statementId) external override onlyCore nonReentrant returns (uint256 out) {
        if (!conversionEnabled || !selected()) revert ConversionOff();
        IV2BalanceToken token = IV2BalanceToken(balanceToken);
        IV2Statements statements = IV2Statements(Mainnet.STATEMENTS);
        if (statements.ownerOf(statementId) != address(this)) revert NotHeld();
        uint256 required = statements.creditScoreOf(statementId) * unitPerPoint;
        uint256 expected = token.quote(statementId);
        statements.approve(balanceToken, statementId);
        uint256 before = custody();
        token.withdraw(statementId, expected);
        out = custody() - before;
        if (out < required) revert RedeemedBelowRating();
        uint16 bps = conversionToClaimBps;
        uint256 toProRata = out * bps / BPS;
        if (toProRata != 0) _fill(_redeemers[proRataRedeemer], toProRata);
        emit StatementConverted(statementId, out, toProRata, bps);
    }

    /// pays at most `available()`, working funds only, with the v1 accrual: a transfer that fails, runs out of gas or
    /// moves less than `amount` records exactly the undelivered part in `owed[to]`. the Core checks the seller's
    /// receipt itself and bounds the artist call
    function pay(address to, uint256 amount) external override onlyCore nonReentrant {
        if (amount > available()) revert InsufficientAvailable();
        _payOrAccrue(to, amount);
    }

    /// pays `owed[to]` to `to` with all gas. anyone may call, whatever the switches
    function claim(address to) external nonReentrant returns (uint256 amount) {
        amount = owed[to];
        owed[to] = 0;
        totalOwed -= amount;
        if (amount != 0) {
            SafeTransferLib.safeTransfer(balanceToken, to, amount);
            emit OwedClaimed(to, amount);
        }
    }

    // ------------------------------------------------------------------ the balance bid

    /// sells the caller's credits `ids` to the balance bid. each credit is paid `bidBps` of par, capped at its eth
    /// terms, and the artist `buyToArtistBps` of that on top, all from the bid budget. the credits go to the Core and are
    /// adopted into its pile in the same call. a credit this controller sold inside the Core's return lock is refused, so
    /// a credit bought from the engine's resale cannot come straight back through adoption. the caller has approved this
    /// treasury on Credits
    function sellCredit(uint256[] calldata ids, uint256 minOut)
        external
        nonReentrant
        notPaused
        returns (uint256 total)
    {
        if (!bidEnabled || !selected()) revert BidOff();
        if (ids.length == 0) revert InvalidAmount();
        IV2Core c = IV2Core(core);
        (bool ok, uint256 ethPrice, uint256 vSell) = _ethTerms();
        if (!ok) revert BidUnpriced();
        Settings memory cfg = c.settings();
        IV2Controller ctrl = IV2Controller(c.controller());
        BalanceBid memory b = bid;
        uint256 bps = _fillBps();
        uint256 artistTotal;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (IV2Credits(Mainnet.CREDITS).ownerOf(id) != msg.sender) revert NotOwner(id);
            uint256 soldAt = ctrl.creditSoldAt(id);
            if (soldAt != 0 && block.timestamp < soldAt + cfg.returnLockSeconds) revert ReturnLocked(id);
            uint256 score = _scoreOf(id);
            uint256 paid = _price(score, bps, ethPrice, vSell, b.overEthBps);
            if (paid == 0) revert ZeroAmount();
            uint256 toArtist = paid * cfg.buyToArtistBps / BPS;
            total += paid;
            artistTotal += toArtist;
            emit CreditSold(id, msg.sender, score, paid, toArtist, bps);
            uint256 drop = uint256(b.dropPer100PointsBps) * score / RATE_SCORE;
            bps = bps > b.floorBps + drop ? bps - drop : b.floorBps;
            IV2Credits(Mainnet.CREDITS).transferFrom(msg.sender, core, id);
        }
        if (total < minOut) revert Slippage();
        uint256 out = total + artistTotal;
        if (out > b.maxPerCall) revert OverCap();
        if (block.timestamp >= uint256(bidPeriodStart) + PERIOD) {
            bidPeriodStart = uint40(block.timestamp);
            bidPeriodUsed = 0;
        }
        if (uint256(bidPeriodUsed) + out > b.maxPerPeriod) revert OverCap();
        if (out > bidBudget) revert InsufficientBucket();
        bidPeriodUsed += uint128(out);
        bidBudget -= out;
        bidOut += out;
        // forge-lint: disable-next-line(unsafe-typecast)
        bidAnchorBps = uint16(bps);
        bidAnchorTime = uint40(block.timestamp);

        c.adopt(ids);
        for (uint256 i; i < ids.length; ++i) {
            (bool inPile,,) = c.creditInfo(ids[i]);
            if (!inPile) revert NotInPile(ids[i]);
        }
        _transferExact(msg.sender, total);
        if (artistTotal != 0) _payOrAccrue(c.artist(), artistTotal);
        emit BidFill(msg.sender, ids.length, total, artistTotal, bidBudget);
    }

    /// the eth terms of the bid: the Core's eth price per 100 points and the controller's value of one point at the
    /// protected sale price. false on a zero price or an unusable quote, which pauses the bid
    function _ethTerms() private view returns (bool ok, uint256 ethPrice, uint256 vSell) {
        ethPrice = IV2Core(core).ethPrice();
        (vSell, ok) = IV2Controller(IV2Core(core).controller()).valuePerPoint(true);
        ok = ok && ethPrice != 0 && vSell != 0;
    }

    /// `score * unitPerPoint * bps / 10_000`, at most the balance token worth `ethPrice * score / RATE_SCORE * (10_000 +
    /// overEthBps) / 10_000` wei at the protected sale price (`vSell` wei per `POINT_UNIT * unitPerPoint` base units)
    function _price(uint256 score, uint256 bps, uint256 ethPrice, uint256 vSell, uint256 overEthBps)
        private
        pure
        returns (uint256 paid)
    {
        paid = score * unitPerPoint * bps / BPS;
        uint256 ethCap = FixedPointMathLib.fullMulDiv(ethPrice * score, BPS + overEthBps, RATE_SCORE * BPS);
        uint256 cap = FixedPointMathLib.fullMulDiv(ethCap, POINT_UNIT * unitPerPoint, vSell);
        if (cap < paid) paid = cap;
    }

    function _scoreOf(uint256 id) private view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE)
            .scoreOf(ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id));
    }

    // ------------------------------------------------------------------ funding

    /// moves the surplus (working funds above the cushion) into the bid budget and the redeemer buckets in the owner's
    /// shares; the unshared rest stays working. anyone may call
    function sweep() external nonReentrant notPaused returns (uint256 moved) {
        uint256 s = surplus();
        if (s == 0) return 0;
        uint256 toBid = s * bidShareBps / BPS;
        if (toBid != 0) {
            bidBudget += toBid;
            bidIn += toBid;
        }
        uint256 toBuckets;
        for (uint256 i; i < redeemerList.length; ++i) {
            RedeemerState storage r = _redeemers[redeemerList[i]];
            uint256 x = s * r.shareBps / BPS;
            if (x != 0) {
                _fill(r, x);
                toBuckets += x;
            }
        }
        moved = toBid + toBuckets;
        emit Swept(s, toBid, toBuckets);
    }

    function _fill(RedeemerState storage r, uint256 x) private {
        r.bucket += x;
        r.totalIn += x;
        totalBuckets += x;
    }

    // ------------------------------------------------------------------ redemption

    /// burns `ccIn` of the caller's CC through `redeemer` and pays `recipient` the redeemer's quote from its own
    /// bucket: at once, or as a committed payout reserved in full now and released by `release`. the treasury checks
    /// only the burn, the bucket, the caps, the recipient and the caller's pinned epoch. the caller has approved this
    /// treasury on the coin for `burnFrom`. returns the payout and the claim id (zero for an immediate payout)
    function redeemCC(
        address redeemer,
        uint256 ccIn,
        address recipient,
        uint256 minOut,
        uint256 deadline,
        uint64 expectedEpoch,
        bytes calldata data
    ) external nonReentrant notPaused returns (uint256 amount, uint256 claimId) {
        if (block.timestamp > deadline) revert Expired();
        RedeemerState storage r = _redeemers[redeemer];
        if (!r.on || block.timestamp < r.activeAt || !selectedForClaims()) revert RedemptionOff();
        if (expectedEpoch != r.epoch) revert StaleEpoch();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        uint256 supply = IV2Coin(ccToken).totalSupply();
        if (ccIn == 0 || ccIn > supply) revert InvalidAmount();
        uint8 mode;
        uint32 duration;
        (amount, mode, duration) = IRedeemer(redeemer).quote(msg.sender, ccIn, r.bucket, supply, data);
        if (amount == 0) revert ZeroAmount();
        if (amount < minOut) revert Slippage();
        if (amount > r.bucket) revert InsufficientBucket();
        if (mode > 2 || (mode != 0 && (duration == 0 || duration > MAX_DURATION))) revert BadPayout();
        _useCaps(r, amount);
        r.bucket -= amount;
        r.totalOut += amount;
        totalBuckets -= amount;

        IV2Coin(ccToken).burnFrom(msg.sender, ccIn);
        if (IV2Coin(ccToken).totalSupply() != supply - ccIn) revert BurnMismatch();
        if (mode == 0) {
            _transferExact(recipient, amount);
        } else {
            totalCommitted += amount;
            _claims.push(
                CommittedPayout({
                    recipient: recipient,
                    redeemer: redeemer,
                    start: uint40(block.timestamp),
                    end: uint40(block.timestamp + duration),
                    linear: mode == 1,
                    amount: uint128(amount),
                    released: 0
                })
            );
            claimId = _claims.length;
        }
        emit CCRedeemed(redeemer, msg.sender, recipient, ccIn, amount, mode, duration, claimId, r.epoch);
    }

    function _useCaps(RedeemerState storage r, uint256 amount) private {
        if (amount > r.perCall) revert OverCap();
        if (block.timestamp >= uint256(r.periodStart) + PERIOD) {
            r.periodStart = uint40(block.timestamp);
            r.periodUsed = 0;
        }
        if (uint256(r.periodUsed) + amount > r.perPeriod) revert OverCap();
        if (uint256(r.lifetimeUsed) + amount > r.lifetime) revert OverCap();
        r.periodUsed += uint128(amount);
        r.lifetimeUsed += uint128(amount);
    }

    /// pays the vested, unreleased part of committed payout `claimId` to its recipient. anyone may call, whatever the
    /// switches and the pause
    function release(uint256 claimId) external nonReentrant returns (uint256 out) {
        CommittedPayout storage c = _claims[claimId - 1];
        out = _vested(c) - c.released;
        if (out == 0) revert NothingDue();
        c.released += uint128(out);
        totalCommitted -= out;
        SafeTransferLib.safeTransfer(balanceToken, c.recipient, out);
        emit ClaimReleased(claimId, c.recipient, out);
    }

    function _vested(CommittedPayout memory c) private view returns (uint256) {
        if (block.timestamp >= c.end) return c.amount;
        if (!c.linear || block.timestamp <= c.start) return 0;
        return uint256(c.amount) * (block.timestamp - c.start) / (c.end - c.start);
    }

    // ------------------------------------------------------------------ payments

    /// transfers `amount` with all gas but `ACCRUE_RESERVE` and records the undelivered part in `owed[to]`
    function _payOrAccrue(address to, uint256 amount) private {
        uint256 before = custody();
        uint256 g = gasleft();
        if (g > ACCRUE_RESERVE) {
            (bool sent,) = balanceToken.call{gas: g - ACCRUE_RESERVE}(abi.encodeCall(IV2Transfer.transfer, (to, amount)));
            sent;
        }
        uint256 afterBal = custody();
        uint256 delivered = before > afterBal ? before - afterBal : 0;
        if (delivered < amount) {
            uint256 short = amount - delivered;
            owed[to] += short;
            totalOwed += short;
            emit PaymentAccrued(to, short);
        }
    }

    /// transfers `amount` to `to` and requires both the recipient's receipt and custody's fall to equal it
    function _transferExact(address to, uint256 amount) private {
        uint256 before = custody();
        uint256 held = SafeTransferLib.balanceOf(balanceToken, to);
        SafeTransferLib.safeTransfer(balanceToken, to, amount);
        if (SafeTransferLib.balanceOf(balanceToken, to) < held + amount || custody() + amount != before) {
            revert ShortPayment();
        }
    }

    // ------------------------------------------------------------------ owner

    function setSwitches(bool conversion, bool workingPayments, bool bidOn) external onlyOwner {
        conversionEnabled = conversion;
        workingPaymentsEnabled = workingPayments;
        bidEnabled = bidOn;
        emit SwitchesSet(conversion, workingPayments, bidOn);
    }

    /// stops the bid, redemptions and sweeps. the Core's calls, `claim` and `release` keep running
    function setPaused(bool on) external onlyOwner {
        paused = on;
        emit PausedSet(on);
    }

    function setCushion(uint256 v) external onlyOwner {
        cushion = v;
        emit CushionSet(v);
    }

    /// 0 to 10,000. applies to later conversions only
    function setConversionToClaimBps(uint16 v) external onlyOwner {
        if (v > BPS) revert BadSetting("conversionToClaimBps");
        conversionToClaimBps = v;
        emit ConversionToClaimBpsSet(v);
    }

    /// sets the bid and restarts its price at `floorBps`. the cap is at most par and must stay below the controller's
    /// credit floor multiplier, so a credit the engine resells after its return lock is still worth more at the engine
    /// than here
    function setBid(BalanceBid calldata v) external onlyOwner {
        // par is the ceiling: a credit bought above par loses BALANCE on conversion
        if (v.floorBps > v.capBps || v.capBps == 0 || v.capBps > BPS) revert BadSetting("bidBand");
        if (v.climbBps != 0 && v.stepSeconds == 0) revert BadSetting("bidStep");
        if (v.capBps >= IV2Controller(IV2Core(core).controller()).floorMultBps()) revert BadSetting("bidCap");
        bid = v;
        bidAnchorBps = v.floorBps;
        bidAnchorTime = uint40(block.timestamp);
        emit BidSet(v);
    }

    /// the sweep share of the bid budget, bps
    function setBidShare(uint16 v) external onlyOwner {
        _setShares(address(0), v);
    }

    /// the sweep share of a registered redeemer's bucket, bps
    function setRedeemerShare(address redeemer, uint16 v) external onlyOwner {
        if (!_redeemers[redeemer].registered) revert UnknownRedeemer();
        _setShares(redeemer, v);
    }

    function _setShares(address redeemer, uint16 v) private {
        uint256 old = redeemer == address(0) ? bidShareBps : _redeemers[redeemer].shareBps;
        uint256 total = totalShareBps - old + v;
        if (total > BPS) revert BadSetting("shares");
        if (redeemer == address(0)) bidShareBps = v;
        else _redeemers[redeemer].shareBps = v;
        // forge-lint: disable-next-line(unsafe-typecast)
        totalShareBps = uint16(total);
        emit SharesSet(redeemer, redeemer == address(0) ? 0 : v, bidShareBps, uint16(total));
    }

    /// registers a redeemer, switched off, drawing nothing for `NEW_REDEEMER_DELAY`, with a nonzero per-period cap
    function registerRedeemer(address redeemer, uint128 perCall, uint128 perPeriod, uint128 lifetime)
        external
        onlyOwner
    {
        _register(redeemer, perCall, perPeriod, lifetime);
    }

    function _register(address redeemer, uint128 perCall, uint128 perPeriod, uint128 lifetime) private {
        if (redeemer.code.length == 0 || _redeemers[redeemer].registered || redeemerList.length == MAX_REDEEMERS) {
            revert BadSetting("redeemer");
        }
        RedeemerState storage r = _redeemers[redeemer];
        r.registered = true;
        r.activeAt = uint40(block.timestamp + NEW_REDEEMER_DELAY);
        redeemerList.push(redeemer);
        emit RedeemerRegistered(redeemer, r.activeAt);
        _setCaps(r, redeemer, perCall, perPeriod, lifetime);
    }

    /// a redeemer's caps. the per-period cap is never zero; the epoch advances
    function setRedeemerCaps(address redeemer, uint128 perCall, uint128 perPeriod, uint128 lifetime)
        external
        onlyOwner
    {
        RedeemerState storage r = _redeemers[redeemer];
        if (!r.registered) revert UnknownRedeemer();
        _setCaps(r, redeemer, perCall, perPeriod, lifetime);
    }

    function _setCaps(RedeemerState storage r, address redeemer, uint128 perCall, uint128 perPeriod, uint128 lifetime)
        private
    {
        if (perPeriod == 0) revert BadSetting("perPeriod");
        r.perCall = perCall;
        r.perPeriod = perPeriod;
        r.lifetime = lifetime;
        ++r.epoch;
        emit RedeemerCapsSet(redeemer, perCall, perPeriod, lifetime, r.epoch);
    }

    function setRedeemerOn(address redeemer, bool on) external onlyOwner {
        RedeemerState storage r = _redeemers[redeemer];
        if (!r.registered) revert UnknownRedeemer();
        r.on = on;
        emit RedeemerSwitched(redeemer, on);
    }

    /// moves `amount` of the surplus into the bid budget (`redeemer` zero) or a registered redeemer's bucket
    function allocate(address redeemer, uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0 || amount > surplus()) revert InsufficientSurplus();
        if (redeemer == address(0)) {
            bidBudget += amount;
            bidIn += amount;
        } else {
            RedeemerState storage r = _redeemers[redeemer];
            if (!r.registered) revert UnknownRedeemer();
            _fill(r, amount);
        }
        emit Allocated(redeemer, amount);
    }

    /// returns `amount` of the bid budget (`redeemer` zero) or of a switched off redeemer's bucket to working funds.
    /// a bucket return advances the redeemer's epoch so a pinned quote cannot execute against the smaller bucket
    function unallocate(address redeemer, uint256 amount) external onlyOwner nonReentrant {
        if (redeemer == address(0)) {
            if (amount == 0 || amount > bidBudget) revert InsufficientBucket();
            bidBudget -= amount;
            bidOut += amount;
        } else {
            RedeemerState storage r = _redeemers[redeemer];
            if (!r.registered) revert UnknownRedeemer();
            if (r.on) revert RedeemerOn();
            if (amount == 0 || amount > r.bucket) revert InsufficientBucket();
            r.bucket -= amount;
            r.totalOut += amount;
            totalBuckets -= amount;
            ++r.epoch;
        }
        emit Unallocated(redeemer, amount);
    }

    /// sends `amount` of the surplus to `to`. never an earmark or the cushion
    function withdrawWorking(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (amount == 0 || amount > surplus()) revert InsufficientSurplus();
        SafeTransferLib.safeTransfer(balanceToken, to, amount);
        emit WorkingWithdrawn(to, amount);
    }

    /// moves an unrelated erc20 out. never the balance token, the coin, Credits or Statements
    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == balanceToken || token == ccToken || token == Mainnet.STATEMENTS || token == Mainnet.CREDITS) {
            revert ProtectedAsset();
        }
        if (to == address(0)) revert InvalidRecipient();
        SafeTransferLib.safeTransfer(token, to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ------------------------------------------------------------------ migration from v1

    /// the successor side of the v1 `migrateTo`: the custody has already landed; `claimAmount`, the v1 claim reserve,
    /// fills the pro-rata redeemer's bucket once custody covers it with every existing earmark
    function receiveMigration(uint256 claimAmount) external nonReentrant {
        if (predecessor == address(0) || msg.sender != predecessor) revert OnlyPredecessor();
        if (custody() < earmarked() + claimAmount) revert Insolvent();
        RedeemerState storage r = _redeemers[proRataRedeemer];
        _fill(r, claimAmount);
        ++r.epoch;
        emit MigrationReceived(msg.sender, claimAmount, custody());
    }
}
