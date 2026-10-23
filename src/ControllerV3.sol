// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {
    CreditSale,
    Quote,
    IdleLoosening,
    CcQuote,
    Settings,
    IController,
    ICoreViews,
    ICoreSale,
    ICreditScore,
    ICredits,
    IBalanceModule,
    Mainnet,
    RATE_SCORE,
    POINT_UNIT
} from "./interfaces/Interfaces.sol";
import {CreditBounds} from "./lib/CreditBounds.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// the phase 2 sale policy and oldest-first composition pages; settings follow the Core's live owner. three changes from
/// ControllerV1, everything else carried over unchanged:
///
/// 1. the protected price takes the worse of the prior block sample and the live spot for each side (issue 113):
///    `P_buy = min(sample, live, reference + tol)`, `P_sell = max(sample, live, reference - tol)`, and the live pool
///    liquidity must hold `minLiquidity` as well as both samples. a persistent pool move can no longer leave an early
///    Credit ask below a later bid, and a same block move only worsens the mover's own side
/// 2. a held statement asks `max(the Core's cost floor, reference * statementSaleMultiplierBps / 10_000)`. the
///    multiplier is persistent until the owner edits it; there is no decay, anchor or start cap. sales can be switched off
///    while redemption eligibility continues
/// 3. redemption eligibility is age only: a held statement older than `statementRedeemDelaySeconds` outside pauses
///
/// mode-off references include cost and `floorRate`; value-mode references use the protected sale value without cost.
/// the legacy views `markupBps`, `decayHours`, `startCapBps`, `anchorBps` and `ageEligibilityOn` are derived from the
/// new settings for existing readers and have no setters
///
/// ControllerV3 is ControllerV2 with three additions for treasury v2 (docs/specs/PHASE3.md):
///
/// 4. idle loosening: while nothing is bought, `valuePerPoint(false)` rises by `idle.bps` per `idle.stepSeconds` up to
///    `idle.capBps`, and returns to par on the next purchase. the Core's `lastFillTime()` is the mode-off instance's
///    clock and does not move on a value mode fill, so "bought" is read from the pile: the newest pile credit's
///    acquisition time, found through `fillHint`. any purchase door (eth, balance, adoption) appends to the pile tail, so
///    a purchase makes the hint stale and the loosening reads zero until `syncFill` moves the hint to the new tail.
///    a stale or unknown tail always reads zero. a tail credit this controller sells before any sync still advances
///    `lastFillSeen`. a tail composed before any sync is older than `creditWindow`, so its own idle time already
///    reaches the cap whenever `idle.bps * creditWindow / idle.stepSeconds >= idle.capBps` (1,200 against 700 at the
///    shipped settings); below that the loosening can read up to the cap early
/// 5. every credit this controller sells records `creditSoldAt`, so treasury v2's bid refuses a credit inside the Core's
///    return lock (the Core's own lock does not cover `adopt`)
/// 6. a CC price reference on the native eth / CC pool for redeemers: an average toward the spot over
///    `ccQuote.avgSeconds`, moved at most `rateBpsPerHour` and `stepBps`, unusable when stale or thin, and the pool spot
///    sampled at the two latest refreshes, so `ccPriorSample` is always a prior block's spot (redeemer 2 reads both, and
///    `balancePriorSample`, the same view of the balance token pool's samples)
interface ICoinOf {
    function COIN() external view returns (address);
}

contract ControllerV3 is IController {
    using StateLibrary for IPoolManager;

    uint256 private constant PAGE = 80;
    uint256 private constant BPS = 10_000;
    uint256 private constant MIN_CREDIT_SPREAD_BPS = 200;
    /// bounds pool-key seeding independently of the executable quote tolerance
    uint256 private constant POOL_SEED_MAX_DEVIATION_BPS = 450;
    /// gas of the controller's read of the balance module's `unitPerPoint()`. the Core allows `atFloor` 400,000 gas in all
    uint256 private constant UNIT_GAS = 50_000;

    error OnlyOwner();
    error BadSetting(bytes32 field);
    error NotForSale();
    error Underpaid();
    error Reentrant();
    /// a credit sale door was called while the credit sale window is off
    error CreditSaleOff();
    /// `buy` was called while statement sales are off
    error StatementSalesOff();
    /// a value mode price was read while the quote is unusable
    error NoQuote();

    event CreditSaleSet(CreditSale credit);
    event StatementSalesSet(bool enabled);
    event StatementSaleMultiplierSet(uint32 multiplierBps);
    event StatementRedeemDelaySet(uint32 delaySeconds);
    event Bought(uint256 indexed sid, address indexed buyer, uint256 price);
    event BalancePoolKeySet(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
    event QuoteSet(Quote quote);
    /// a refresh of the reference price: the reference after it and the spot it moved toward, wei per 1e18 base units
    event ReferenceRefreshed(uint256 referencePrice, uint256 spot);
    event IdleLooseningSet(IdleLoosening idle);
    /// the fill hint moved to the pile tail `tail`, acquired at `acquiredAt`
    event FillSynced(uint256 indexed tail, uint64 acquiredAt);
    event CreditSoldRecorded(uint256 indexed id, address indexed buyer, uint256 price);
    event CcPoolKeySet(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
    event CcQuoteSet(CcQuote quote);
    /// a refresh of the CC reference, wei per 1e18 CC base units
    event CcReferenceRefreshed(uint256 referencePrice, uint256 spot);

    ICoreViews public immutable CORE;

    /// whether `buy` sells held statements. deployment value false
    bool public statementSalesEnabled;
    /// the ask over the reference, bps. 10_000 to uint32.max; the Core's cost floor still applies under it
    uint32 public statementSaleMultiplierBps;
    /// seconds a held statement ages outside pauses before it is eligible for redemption. 0 to uint32.max
    uint32 public statementRedeemDelaySeconds;
    bool private _busy;
    /// whether the balance token pool key is set. deployment value false
    bool public balancePoolKeySet;
    /// the uniswap v4 pool of the balance token against native eth, used to price the redeemable value floor. native eth
    /// is `currency0` (the zero address) and the balance token is `currency1`, the only order a native eth pool sorts to
    PoolKey public balancePoolKey;

    /// whether pile credits are for sale from their acquisition time and compose waits for a credit's window to pass
    bool public creditSaleOn;
    /// seconds a credit's price falls over before it rests at the floor, and the time a credit must sit before compose
    /// may take it. 1 to uint32.max seconds
    uint32 public creditWindow;
    /// the sale spread over the bid's hard cap, bps: the credit floor multiplier is `(10_000 + creditSpreadBps)` of
    /// the Core's `balanceBidCapBps`. at least 200 bps, and enough to close the quote tolerance band
    uint16 public creditSpreadBps;
    /// the credit sale start price over the floor, bps. 10_000 to uint32.max
    uint32 public creditStartBps;

    /// the reference price settings (decision 148)
    Quote public quote;
    /// the reference price of the balance token, wei per 1e18 base units, 0 until the pool key is set
    uint256 public referencePrice;
    /// the sample time of `referencePrice`: the moment the stored reference was sampled from the spot
    uint40 public referenceTime;
    /// the pool spot sampled at the two most recent refreshes, newest in `spotSampleA`, wei per 1e18 base units
    uint256 private spotSampleA;
    uint256 private spotSampleB;
    /// the pool liquidity sampled at the two most recent refreshes, newest in `liqSampleA`
    uint128 private liqSampleA;
    uint128 private liqSampleB;
    /// the block of the last reference refresh. a refresh runs at most once per block
    uint48 private lastRefreshBlock;

    IdleLoosening public idle;
    /// a pile credit at or near the tail, moved by `syncFill`. a hint that left the pile or is not the tail reads as an
    /// unknown purchase time
    uint256 public fillHint;
    /// the latest acquisition time `syncFill` has seen at the pile tail. read only while the pile is empty
    uint64 public lastFillSeen;
    /// when this controller sold pile credit `id`, zero for a credit it never sold
    mapping(uint256 => uint64) public creditSoldAt;

    /// the native eth / CC pool of the CC reference: native eth as `currency0`, the Core's coin as `currency1`
    PoolKey public ccPoolKey;
    bool public ccPoolKeySet;
    CcQuote public ccQuote;
    /// the CC reference, wei per 1e18 CC base units, and its sample time
    uint256 public ccReferencePrice;
    uint40 public ccReferenceTime;
    uint48 private ccLastRefreshBlock;
    /// the CC pool spot sampled at the two most recent refreshes (or the seed), newest in `ccSpotSampleA`
    uint256 private ccSpotSampleA;
    uint256 private ccSpotSampleB;

    constructor(
        address core,
        CreditSale memory credit,
        Quote memory quote_,
        uint32 statementSaleMultiplierBps_,
        uint32 statementRedeemDelaySeconds_,
        IdleLoosening memory idle_
    ) {
        CORE = ICoreViews(core);
        _setCredit(credit);
        _setQuote(quote_);
        _setStatementSaleMultiplier(statementSaleMultiplierBps_);
        _setStatementRedeemDelay(statementRedeemDelaySeconds_);
        _setIdle(idle_);
        // a first hint, so a deployment into a live pile starts with a known tail
        if (core.code.length != 0) syncFill();
    }

    modifier onlyOwner() {
        if (msg.sender != ICoreSale(address(CORE)).owner()) revert OnlyOwner();
        _;
    }

    // ------------------------------------------------------------------ statement sale settings, owner, at once

    /// turns statement sales on or off. redemption eligibility is unaffected
    function setStatementSales(bool enabled) external onlyOwner {
        statementSalesEnabled = enabled;
        emit StatementSalesSet(enabled);
    }

    /// 10_000 to uint32.max. applies to every held statement at once and does not decay
    function setStatementSaleMultiplierBps(uint32 v) external onlyOwner {
        _setStatementSaleMultiplier(v);
    }

    function _setStatementSaleMultiplier(uint32 v) private {
        if (v < BPS) revert BadSetting("statementSaleMultiplierBps");
        statementSaleMultiplierBps = v;
        emit StatementSaleMultiplierSet(v);
    }

    /// 0 to uint32.max seconds. applies to every held statement at once, against its already recorded age
    function setStatementRedeemDelaySeconds(uint32 v) external onlyOwner {
        _setStatementRedeemDelay(v);
    }

    function _setStatementRedeemDelay(uint32 v) private {
        statementRedeemDelaySeconds = v;
        emit StatementRedeemDelaySet(v);
    }

    // ------------------------------------------------------------------ legacy views, no setters

    /// the multiplier clamped to uint16, for readers of the V1 `markupBps`
    function markupBps() external view returns (uint16) {
        uint32 m = statementSaleMultiplierBps;
        return m > type(uint16).max ? type(uint16).max : uint16(m);
    }

    /// the redemption delay in whole hours rounded up, for readers of the V1 `decayHours`
    function decayHours() external view returns (uint16) {
        uint256 h = (uint256(statementRedeemDelaySeconds) + 1 hours - 1) / 1 hours;
        return h > type(uint16).max ? type(uint16).max : uint16(h);
    }

    /// the multiplier, for readers of the V1 `startCapBps`: the ask never exceeds it
    function startCapBps() external view returns (uint32) {
        return statementSaleMultiplierBps;
    }

    /// 10_000: there is no anchor
    function anchorBps() external pure returns (uint32) {
        return uint32(BPS);
    }

    /// true: eligibility is age only
    function ageEligibilityOn() external pure returns (bool) {
        return true;
    }

    // ------------------------------------------------------------------ the pool key and the quote settings

    /// sets the native eth / balance token pool the reference follows. no price reads the pool until value mode is on.
    /// `currency0` must be native eth (the zero address) and `currency1` the core's current balance token. the pool must
    /// be initialized. the reference is seeded from the live spot, and the owner passes `expectedSpot` (wei per 1e18
    /// base units): a live spot more than 4.5 percent from it reverts. effective at once
    function setBalancePoolKey(PoolKey calldata key, uint256 expectedSpot) external onlyOwner {
        address token = CORE.balanceToken();
        if (token == address(0)) revert BadSetting("balanceToken");
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 != address(0) || c1 != token) revert BadSetting("balancePoolKey");
        (uint160 sqrtPriceX96,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert BadSetting("balancePoolKey");
        balancePoolKey = key;
        balancePoolKeySet = true;
        emit BalancePoolKeySet(c0, c1, key.fee, key.tickSpacing, address(key.hooks));
        (uint256 spot,) = _spot();
        uint256 band = expectedSpot * POOL_SEED_MAX_DEVIATION_BPS / BPS;
        if (spot < expectedSpot - band || spot > expectedSpot + band) revert BadSetting("spot");
        uint128 liq = _sampleLiq();
        spotSampleA = spot;
        spotSampleB = spot;
        liqSampleA = liq;
        liqSampleB = liq;
        // forge-lint: disable-next-line(unsafe-typecast)
        lastRefreshBlock = uint48(block.number);
        _setRef(spot, spot);
    }

    /// the pool liquidity of the balance token pool now
    function _sampleLiq() private view returns (uint128) {
        return IPoolManager(Mainnet.POOL_MANAGER).getLiquidity(balancePoolKey.toId());
    }

    /// sets the reference price settings at once. `referenceStepBps` 0 to 10_000, `tolBps` 0 to 9_999
    function setQuote(Quote calldata v) external onlyOwner {
        _setQuote(v);
    }

    function _setQuote(Quote memory v) private {
        if (v.referenceStepBps > BPS) revert BadSetting("referenceStepBps");
        if (v.tolBps >= BPS) revert BadSetting("tolBps");
        // the rate, the step and the staleness are all set or all zero
        bool anyRef = v.referenceRateBpsPerHour != 0 || v.referenceStepBps != 0 || v.referenceMaxStale != 0;
        bool allRef = v.referenceRateBpsPerHour != 0 && v.referenceStepBps != 0 && v.referenceMaxStale != 0;
        if (anyRef && !allRef) revert BadSetting("referenceTriple");
        // a usable quote needs a positive liquidity threshold, or an emptied pool would still price
        if (allRef && v.minLiquidity == 0) revert BadSetting("minLiquidity");
        _checkLoopClosure(v.tolBps, creditSpreadBps, idle.capBps);
        // the reference band widened by the step stays inside value mode's shared instance margin. the Core read is
        // skipped while the Core has no code yet (constructor order)
        if (address(CORE).code.length != 0) {
            uint256 margin = ICoreSale(address(CORE)).settings().balanceBidMarginBps;
            if ((BPS + v.referenceStepBps) * (BPS + v.tolBps) * (BPS - margin) >= BPS * BPS * BPS) {
                revert BadSetting("referenceBand");
            }
        }
        quote = v;
        emit QuoteSet(v);
    }

    /// the sale spread (bps over the bid cap) must cover the worst round trip through the reference band and the idle
    /// loosening: with a buy at the band top `(10_000 + tol)` raised by the loosening cap and a sale floor at the band
    /// bottom `(10_000 - tol)`, the ask clears the bid only when `(10_000 + spread) >= (10_000 + tol) * (10_000 + cap) /
    /// (10_000 - tol)`. a 200 bps floor remains at zero tolerance
    function _checkLoopClosure(uint256 tol, uint256 spread, uint256 cap) private pure {
        uint256 num = (BPS + tol) * (BPS + cap);
        uint256 den = BPS - tol;
        uint256 req = (num + den - 1) / den - BPS;
        if (req < MIN_CREDIT_SPREAD_BPS) req = MIN_CREDIT_SPREAD_BPS;
        if (spread < req) revert BadSetting("creditSpreadBps");
    }

    // ------------------------------------------------------------------ idle loosening

    /// sets the idle loosening at once. `stepSeconds` at least 1; `capBps` inside the credit loop closure
    function setIdleLoosening(IdleLoosening calldata v) external onlyOwner {
        _setIdle(v);
    }

    function _setIdle(IdleLoosening memory v) private {
        if (v.stepSeconds == 0) revert BadSetting("idleStepSeconds");
        if (v.bps > v.capBps) revert BadSetting("idleBps");
        _checkLoopClosure(quote.tolBps, creditSpreadBps, v.capBps);
        idle = v;
        emit IdleLooseningSet(v);
    }

    /// the newest pile acquisition time and whether it is known: the hint's time while the hint is the pile tail, the
    /// last synced time while the pile is empty, else unknown
    function idleSince() public view returns (uint256 t, bool known) {
        uint256 hint = fillHint;
        if (hint != 0) {
            (bool inPile,, uint64 at) = CORE.creditInfo(hint);
            if (inPile) {
                if (CORE.pilePage(hint, 1).length != 0) return (0, false);
                return (at > lastFillSeen ? at : lastFillSeen, true);
            }
        }
        if (CORE.pileSize() == 0) return (lastFillSeen, true);
        return (0, false);
    }

    /// the idle loosening now, bps: `idle.bps` per full step since `idleSince`, at most `idle.capBps`; zero while the
    /// purchase time is unknown
    function idleLoosenBps() public view returns (uint256 b) {
        IdleLoosening memory l = idle;
        if (l.bps == 0) return 0;
        (uint256 t, bool known) = idleSince();
        if (!known || block.timestamp <= t) return 0;
        b = (block.timestamp - t) / l.stepSeconds * l.bps;
        if (b > l.capBps) b = l.capBps;
    }

    /// moves `fillHint` to the pile tail and records its acquisition time. anyone may call; the caller pays the walk. a
    /// hint can only be moved to the true tail, so no caller can raise the loosening above what the pile shows
    function syncFill() public returns (bool) {
        uint256 n = CORE.pileSize();
        if (n == 0) return false;
        uint256 start = fillHint;
        if (start != 0) {
            (bool inPile,,) = CORE.creditInfo(start);
            if (!inPile) start = 0;
        }
        uint256[] memory ids = CORE.pilePage(start, n);
        uint256 tail = ids.length == 0 ? start : ids[ids.length - 1];
        (,, uint64 at) = CORE.creditInfo(tail);
        fillHint = tail;
        if (at > lastFillSeen) lastFillSeen = at;
        emit FillSynced(tail, at);
        return true;
    }

    // ------------------------------------------------------------------ the protected price

    /// moves the reference toward the pool spot by at most
    /// `min(referenceRateBpsPerHour * elapsed / 3600, referenceStepBps)` bps of the reference. anyone may call; the sale
    /// doors call it first. no move with no reference, with `referenceMaxStale` zero (mode off), before
    /// `referenceMinSeconds` has passed since the last sample, or on a zero spot. a move that floors to zero leaves the
    /// sample time unchanged. returns true when it updated the reference
    function refreshReference() public returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint48(block.number) == lastRefreshBlock) return false;
        uint256 ref = referencePrice;
        if (ref == 0) return false;
        Quote memory q = quote;
        if (q.referenceMaxStale == 0) return false;
        uint256 elapsed = block.timestamp - referenceTime;
        if (elapsed < q.referenceMinSeconds) return false;
        (uint256 spot, bool ok) = _spot();
        if (!ok || spot == 0) return false;
        uint256 move = uint256(q.referenceRateBpsPerHour) * elapsed / 1 hours;
        if (move > q.referenceStepBps) move = q.referenceStepBps;
        if (move == 0) return false;
        uint256 hi = ref * (BPS + move) / BPS;
        uint256 lo = ref * (BPS - move) / BPS;
        spotSampleB = spotSampleA;
        liqSampleB = liqSampleA;
        spotSampleA = spot;
        liqSampleA = _sampleLiq();
        // forge-lint: disable-next-line(unsafe-typecast)
        lastRefreshBlock = uint48(block.number);
        _setRef(spot > hi ? hi : spot < lo ? lo : spot, spot);
        return true;
    }

    function _setRef(uint256 ref, uint256 spot) private {
        referencePrice = ref;
        // forge-lint: disable-next-line(unsafe-typecast)
        referenceTime = uint40(block.timestamp);
        emit ReferenceRefreshed(ref, spot);
    }

    /// the balance token pool spot sampled by a refresh in a prior block, wei per 1e18 base units: the previous sample
    /// when the latest was taken this block, the sample `_protected` reads, so a swap and a refresh in the caller's own
    /// block cannot set it. zero before the pool key is set
    function balancePriorSample() external view returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(block.number) == lastRefreshBlock ? spotSampleB : spotSampleA;
    }

    /// @notice the pool spot of the balance token, wei per 1e18 base units. false as in `_spot`
    function spotPrice() external view returns (uint256 spot, bool ok) {
        return _spot();
    }

    /// the buy price, the sale price and the unit, wei per 1e18 base units and base units per score unit, and whether
    /// the reference price is usable. the band is centred on the reference; each side is clamped to the worse of the
    /// prior block sample and the live spot, so a same block pool move cannot improve the mover's side and a persistent
    /// move reaches the ask at once. the quote is usable with a reference set, the sample at most `referenceMaxStale`
    /// old, the live liquidity and both recent samples at least `minLiquidity`, a priced live spot, a balance module set
    /// and a unit read. with `project` true the views and the sale doors run the read-only equivalent of
    /// `refreshReference` first, so a view read in the same block as a sale door's refresh equals the price the door
    /// charges. the Core's eth bid and the balance cap read it with `project` false
    function _protected(bool project) private view returns (uint256 pBuy, uint256 pSell, uint256 unit, bool ok) {
        Quote memory q = quote;
        uint256 ref = referencePrice;
        if (ref == 0 || q.referenceMaxStale == 0) return (0, 0, 0, false);
        (uint256 live, bool priced) = _spot();
        if (!priced || live == 0) return (0, 0, 0, false);
        uint256 t = referenceTime;
        uint256 sA = spotSampleA;
        uint256 sB = spotSampleB;
        uint256 lA = liqSampleA;
        uint256 lB = liqSampleB;
        uint128 liveLiq = _sampleLiq();
        // forge-lint: disable-next-line(unsafe-typecast)
        bool aThisBlock = uint48(block.number) == lastRefreshBlock;
        if (project && !aThisBlock && block.timestamp - t >= q.referenceMinSeconds) {
            uint256 move = uint256(q.referenceRateBpsPerHour) * (block.timestamp - t) / 1 hours;
            if (move > q.referenceStepBps) move = q.referenceStepBps;
            if (move != 0) {
                uint256 hi = ref * (BPS + move) / BPS;
                uint256 lo = ref * (BPS - move) / BPS;
                ref = live > hi ? hi : live < lo ? lo : live;
                sB = sA;
                lB = lA;
                sA = live;
                lA = liveLiq;
                t = block.timestamp;
                aThisBlock = true;
            }
        }
        if (block.timestamp - t > q.referenceMaxStale) return (0, 0, 0, false);
        if (liveLiq == 0 || lA < q.minLiquidity || lB < q.minLiquidity || liveLiq < q.minLiquidity) {
            return (0, 0, 0, false);
        }
        // the sampled spot is a prior block's: the previous one when the latest was taken this block
        uint256 sampled = aThisBlock ? sB : sA;
        address module = CORE.balanceModule();
        if (module == address(0)) return (0, 0, 0, false);
        (unit, ok) = _liveUnit(module);
        if (!ok) return (0, 0, 0, false);
        uint256 up = ref * (BPS + q.tolBps) / BPS;
        uint256 down = ref * (BPS - q.tolBps) / BPS;
        uint256 lowSpot = sampled < live ? sampled : live;
        uint256 highSpot = sampled > live ? sampled : live;
        pBuy = lowSpot < up ? lowSpot : up;
        pSell = highSpot > down ? highSpot : down;
    }

    /// the wei value of one point at the protected price, see `IController.valuePerPoint`
    function valuePerPoint(bool forSale) external view returns (uint256 value, bool ok) {
        uint256 pBuy;
        uint256 pSell;
        uint256 unit;
        (pBuy, pSell, unit, ok) = _protected(false);
        if (!ok) return (0, false);
        value = forSale
            ? FullMath.mulDivRoundingUp(POINT_UNIT * unit, pSell, 1e18)
            : FullMath.mulDiv(POINT_UNIT * unit, pBuy * (BPS + idleLoosenBps()), 1e18 * BPS);
    }

    /// the `posted` balance payout for a credit of `score` stored units lowered to its value mode cap, balance base
    /// units: the smaller of `posted` and the value rate bid for the score valued in tokens at the protected sale price
    /// per token. while the reference is unusable no cap can be computed, so the answer is `(0, true)`: a zero payout,
    /// which the balance fill and the payout view treat as unavailable
    function balanceClampFor(uint256 score, uint256 posted) external view returns (uint256 paid, bool ok) {
        uint256 pSell;
        (, pSell,, ok) = _protected(false);
        if (!ok || pSell == 0) return (0, true);
        uint256 cap = FullMath.mulDiv(FullMath.mulDiv(CORE.ethPrice(), score, RATE_SCORE), 1e18, pSell);
        paid = posted < cap ? posted : cap;
        ok = true;
    }

    /// the Core's settings, read once per door and threaded through the pricing path
    function _cfg() private view returns (Settings memory) {
        return ICoreSale(address(CORE)).settings();
    }

    // ------------------------------------------------------------------ credit sale settings, owner, at once

    /// sets the credit sale settings at once. `window` 1 to uint32.max seconds, `spreadBps` 200 to uint16.max,
    /// `startBps` 10_000 to uint32.max
    function setCredit(CreditSale calldata v) external onlyOwner {
        _setCredit(v);
        emit CreditSaleSet(v);
    }

    function _setCredit(CreditSale memory v) private {
        if (!CreditBounds.windowOk(v.window)) revert BadSetting("creditWindow");
        if (!CreditBounds.startBpsOk(v.startBps)) revert BadSetting("creditStartBps");
        _checkLoopClosure(quote.tolBps, v.spreadBps, idle.capBps);
        creditSaleOn = v.saleOn;
        creditWindow = v.window;
        creditSpreadBps = v.spreadBps;
        creditStartBps = v.startBps;
    }

    // ------------------------------------------------------------------ pricing and sale

    /// wei per score unit: `core.floorRate()` over `RATE_SCORE` (100 points in score units), rounded down
    function pointRate() public view returns (uint256) {
        return CORE.floorRate() / RATE_SCORE;
    }

    /// the value in wei of `points` score units: `floorRate * points / RATE_SCORE` with value mode off, independent of
    /// the balance pool key. in value mode it is `points * unitPerPoint` base units at the protected sale price, rounded
    /// up, and reverts `NoQuote` while the quote is unusable
    function valueOf(uint256 points) public view returns (uint256) {
        return _valueOf(points, _cfg());
    }

    function _valueOf(uint256 points, Settings memory cfg) private view returns (uint256) {
        if (cfg.valueModeOn) {
            (, uint256 pSell, uint256 unit, bool ok) = _protected(true);
            if (!ok) revert NoQuote();
            return FullMath.mulDivRoundingUp(points * unit, pSell, 1e18);
        }
        return FullMath.mulDiv(CORE.floorRate(), points, RATE_SCORE);
    }

    /// statement reference, wei: `max(cost, valueOf(rating))` in mode off; `valueOf(rating) * floorMultBps() /
    /// 10_000` in value mode. reverts `NotForSale` for a statement the core does not hold
    function referenceOf(uint256 sid) public view returns (uint256) {
        (bool held, uint256 cost,) = CORE.statementInfo(sid);
        if (!held) revert NotForSale();
        return _reference(cost, CORE.ratingOf(sid), _cfg());
    }

    function _reference(uint256 cost, uint256 rating, Settings memory cfg) private view returns (uint256) {
        uint256 value = _valueOf(rating, cfg);
        if (cfg.valueModeOn) return value * _floorMult(cfg) / BPS;
        return value > cost ? value : cost;
    }

    /// the statement ask, at least the Core's cost floor in both modes. answers while sales are off and while paused; a
    /// sale then reverts here or in the Core
    function priceOf(uint256 sid) public view returns (uint256 price) {
        (price,) = _quote(sid, _cfg());
    }

    /// redemption eligibility for a held statement: its age outside pauses is at least `statementRedeemDelaySeconds`.
    /// false for a statement the core does not hold. sales off does not affect it
    function atFloor(uint256 sid) external view returns (bool) {
        (bool held,,) = CORE.statementInfo(sid);
        if (!held) return false;
        return CORE.statementAge(sid) >= statementRedeemDelaySeconds;
    }

    /// buys a statement at the ask. reverts `StatementSalesOff` while sales are off. the excess of `msg.value` is
    /// refunded to the caller last
    function buy(uint256 sid) external payable {
        if (!statementSalesEnabled) revert StatementSalesOff();
        if (_busy) revert Reentrant();
        _busy = true;
        refreshReference();
        (uint256 price,) = _quote(sid, _cfg());
        if (msg.value < price) revert Underpaid();
        ICoreSale(address(CORE)).sellTo{value: price}(sid, msg.sender);
        emit Bought(sid, msg.sender, price);
        if (msg.value > price) SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
        _busy = false;
    }

    // ------------------------------------------------------------------ credit sale window

    /// the sale price of pile credit `id` now, wei. the floor is the larger of the credit's cost and `valueOf` of its
    /// score, times `floorMultBps()`; in value mode `valueOf` alone, the cost term dropped. the floor is at least
    /// `saleFloorBps` of the cost, the Core's floor of `sellCreditTo`. the start is the floor times `creditStartBps`.
    /// the price falls in a straight line from the start at the acquisition time to the floor at the acquisition time
    /// plus `creditWindow`, and rests at the floor after. reverts `NotForSale` for a credit not in the pile
    function creditPrice(uint256 id) public view returns (uint256 price) {
        return _creditPrice(id, _cfg());
    }

    function _creditPrice(uint256 id, Settings memory cfg) private view returns (uint256 price) {
        (bool inPile, uint256 cost, uint64 acquiredAt) = CORE.creditInfo(id);
        if (!inPile) revert NotForSale();
        uint256 hi = _valueOf(_scoreOf(id), cfg);
        if (cost > hi && !cfg.valueModeOn) hi = cost;
        uint256 floor = hi * _floorMult(cfg) / BPS;
        uint256 coreFloor = cost * cfg.saleFloorBps / BPS;
        if (floor < coreFloor) floor = coreFloor;
        uint256 start = floor * creditStartBps / BPS;
        uint256 age = block.timestamp - acquiredAt;
        if (age >= creditWindow) return floor;
        price = start - (start - floor) * age / creditWindow;
    }

    /// the credit floor multiplier now, bps: `(10_000 + creditSpreadBps) * balanceBidCapBps / 10_000` with the Core's cap
    /// read live, at least 10_000
    function floorMultBps() public view returns (uint256) {
        return _floorMult(_cfg());
    }

    function _floorMult(Settings memory cfg) private view returns (uint256) {
        uint256 m = (BPS + creditSpreadBps) * cfg.balanceBidCapBps / BPS;
        return m < BPS ? BPS : m;
    }

    /// the credit score of `id` from the credit score contract, the score source of every Core door
    function _scoreOf(uint256 id) private view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE)
            .scoreOf(ICredits(Mainnet.CREDITS).seedOf(id), ICredits(Mainnet.CREDITS).timestampOf(id));
    }

    /// true when credit acquired at `acquiredAt` may be composed: always while the sale is off, otherwise once
    /// `creditWindow` has passed since its acquisition
    function pastWindow(uint64 acquiredAt) public view returns (bool) {
        if (!creditSaleOn) return true;
        return uint256(acquiredAt) + creditWindow <= block.timestamp;
    }

    /// pays the sale price of credit `id`, gets the credit at once, and refunds the excess of `msg.value` last. reverts
    /// `CreditSaleOff` while the sale is off and, through the core, `Paused` while sales are paused
    function buyCredit(uint256 id) external payable {
        if (!creditSaleOn) revert CreditSaleOff();
        if (_busy) revert Reentrant();
        _busy = true;
        refreshReference();
        uint256 price = _creditPrice(id, _cfg());
        if (msg.value < price) revert Underpaid();
        (,, uint64 acquiredAt) = CORE.creditInfo(id);
        ICoreSale(address(CORE)).sellCreditTo{value: price}(id, msg.sender);
        _recordSale(id, price, acquiredAt);
        if (msg.value > price) SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
        _busy = false;
    }

    /// pays the sale prices of `ids` in order, gets the credits, and refunds the excess last
    function buyCredits(uint256[] calldata ids) external payable {
        if (!creditSaleOn) revert CreditSaleOff();
        if (_busy) revert Reentrant();
        _busy = true;
        refreshReference();
        Settings memory cfg = _cfg();
        uint256 n = ids.length;
        uint256 spent;
        for (uint256 i; i < n; ++i) {
            uint256 price = _creditPrice(ids[i], cfg);
            spent += price;
            if (msg.value < spent) revert Underpaid();
            (,, uint64 acquiredAt) = CORE.creditInfo(ids[i]);
            ICoreSale(address(CORE)).sellCreditTo{value: price}(ids[i], msg.sender);
            _recordSale(ids[i], price, acquiredAt);
        }
        if (msg.value > spent) SafeTransferLib.safeTransferETH(msg.sender, msg.value - spent);
        _busy = false;
    }

    function _recordSale(uint256 id, uint256 price, uint64 acquiredAt) private {
        // a sold tail leaves the pile: its purchase time is kept so the loosening cannot restart from an older credit
        if (acquiredAt > lastFillSeen) lastFillSeen = acquiredAt;
        // forge-lint: disable-next-line(unsafe-typecast)
        creditSoldAt[id] = uint64(block.timestamp);
        emit CreditSoldRecorded(id, msg.sender, price);
    }

    /// the statement ask and cost: `max(cost * saleFloorBps / 10_000, ceil(reference * multiplier / 10_000))`
    function _quote(uint256 sid, Settings memory cfg) private view returns (uint256 price, uint256 cost) {
        bool held;
        (held, cost,) = CORE.statementInfo(sid);
        if (!held) revert NotForSale();
        uint256 ref = _reference(cost, CORE.ratingOf(sid), cfg);
        price = FullMath.mulDivRoundingUp(ref, statementSaleMultiplierBps, BPS);
        uint256 coreFloor = cost * cfg.saleFloorBps / BPS;
        if (price < coreFloor) price = coreFloor;
    }

    /// the module's `unitPerPoint()` read with at most `UNIT_GAS`. `ok` is false, and the unit reads 0, on a revert, an
    /// answer shorter than 32 bytes, a zero unit or a unit above `type(uint128).max`
    function _liveUnit(address module) private view returns (uint256 unit, bool ok) {
        bytes4 sel = IBalanceModule.unitPerPoint.selector;
        assembly ("memory-safe") {
            mstore(0, sel)
            ok := staticcall(UNIT_GAS, module, 0, 4, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            unit := mload(0)
        }
        if (!ok || unit == 0 || unit > type(uint128).max) return (0, false);
    }

    /// live pool spot, wei per 1e18 balance base units. unusable without the current token's pool key or a nonzero
    /// sqrt price
    function _spot() private view returns (uint256 spot, bool ok) {
        if (!balancePoolKeySet) return (0, false);
        if (Currency.unwrap(balancePoolKey.currency1) != CORE.balanceToken()) return (0, false);
        return _spotOf(balancePoolKey);
    }

    /// the spot of `currency1` in native eth of an initialized pool, wei per 1e18 base units; false at a zero sqrt price
    function _spotOf(PoolKey memory key) private view returns (uint256 spot, bool ok) {
        (uint160 sqrtPriceX96,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(key.toId());
        if (sqrtPriceX96 == 0) return (0, false);
        uint256 q = FixedPoint96.Q96;
        uint256 p = sqrtPriceX96;
        return ((1e18 * q / p) * q / p, true);
    }

    // ------------------------------------------------------------------ the CC reference

    /// sets the native eth / CC pool of the CC reference and seeds the reference from its live spot, which must be
    /// within 4.5 percent of `expectedSpot`. `currency0` must be native eth and `currency1` the Core's coin
    function setCcPoolKey(PoolKey calldata key, uint256 expectedSpot) external onlyOwner {
        if (Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != ICoinOf(address(CORE)).COIN())
        {
            revert BadSetting("ccPoolKey");
        }
        (uint256 spot, bool ok) = _spotOf(key);
        uint256 band = expectedSpot * POOL_SEED_MAX_DEVIATION_BPS / BPS;
        if (!ok || spot < expectedSpot - band || spot > expectedSpot + band) revert BadSetting("ccSpot");
        ccPoolKey = key;
        ccPoolKeySet = true;
        emit CcPoolKeySet(address(0), Currency.unwrap(key.currency1), key.fee, key.tickSpacing, address(key.hooks));
        ccSpotSampleA = spot;
        ccSpotSampleB = spot;
        _setCcRef(spot, spot);
    }

    /// sets the CC reference settings at once. `stepBps` 0 to 10_000, `avgSeconds` at least 1
    function setCcQuote(CcQuote calldata v) external onlyOwner {
        if (v.stepBps > BPS) revert BadSetting("ccStepBps");
        if (v.avgSeconds == 0) revert BadSetting("ccAvgSeconds");
        // a usable reference needs a positive liquidity threshold, or an emptied pool would still price
        if (v.maxStale != 0 && v.minLiquidity == 0) revert BadSetting("ccMinLiquidity");
        ccQuote = v;
        emit CcQuoteSet(v);
    }

    /// moves the CC reference `min(elapsed, avgSeconds) / avgSeconds` of the way to the live spot, clipped to
    /// `min(rateBpsPerHour * elapsed / 3600, stepBps)` bps of the reference. anyone may call. no move more than once per
    /// block, before `minSeconds`, without a reference, on a zero spot or under `minLiquidity`; true when it moved
    function refreshCcReference() external returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint48(block.number) == ccLastRefreshBlock) return false;
        uint256 ref = ccReferencePrice;
        if (ref == 0) return false;
        CcQuote memory q = ccQuote;
        uint256 elapsed = block.timestamp - ccReferenceTime;
        if (elapsed < q.minSeconds || q.avgSeconds == 0) return false;
        if (IPoolManager(Mainnet.POOL_MANAGER).getLiquidity(ccPoolKey.toId()) < q.minLiquidity) return false;
        (uint256 spot, bool ok) = _spotOf(ccPoolKey);
        if (!ok || spot == 0) return false;
        uint256 move = uint256(q.rateBpsPerHour) * elapsed / 1 hours;
        if (move > q.stepBps) move = q.stepBps;
        if (move == 0) return false;
        uint256 w = elapsed < q.avgSeconds ? elapsed : q.avgSeconds;
        uint256 target = spot > ref ? ref + (spot - ref) * w / q.avgSeconds : ref - (ref - spot) * w / q.avgSeconds;
        uint256 hi = ref * (BPS + move) / BPS;
        uint256 lo = ref * (BPS - move) / BPS;
        // forge-lint: disable-next-line(unsafe-typecast)
        ccLastRefreshBlock = uint48(block.number);
        ccSpotSampleB = ccSpotSampleA;
        ccSpotSampleA = spot;
        _setCcRef(target > hi ? hi : target < lo ? lo : target, spot);
        return true;
    }

    function _setCcRef(uint256 ref, uint256 spot) private {
        ccReferencePrice = ref;
        // forge-lint: disable-next-line(unsafe-typecast)
        ccReferenceTime = uint40(block.timestamp);
        emit CcReferenceRefreshed(ref, spot);
    }

    /// the CC pool spot sampled by a refresh in a prior block, wei per 1e18 CC base units: the previous sample when the
    /// latest was taken this block, so a swap and a refresh in the caller's own block cannot set it. it is as old as the
    /// latest refresh; a refresh moves it even where the reference's step bound holds the reference back
    function ccPriorSample() external view returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(block.number) == ccLastRefreshBlock ? ccSpotSampleB : ccSpotSampleA;
    }

    /// the CC reference, wei per 1e18 CC base units, and whether it is usable: set, at most `maxStale` old and the live
    /// pool liquidity at least `minLiquidity`. a later redeemer pauses on `ok` false
    function ccPrice() external view returns (uint256 price, bool ok) {
        price = ccReferencePrice;
        CcQuote memory q = ccQuote;
        if (price == 0 || q.maxStale == 0 || block.timestamp - ccReferenceTime > q.maxStale) return (0, false);
        if (IPoolManager(Mainnet.POOL_MANAGER).getLiquidity(ccPoolKey.toId()) < q.minLiquidity) return (0, false);
        ok = true;
    }

    // ------------------------------------------------------------------ credit picking

    /// ready when the pile holds a full page. the page is the 80 oldest credits. while the credit sale is on the page
    /// is ready only once the newest of its 80 credits is past its window
    function nextPage() external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        if (CORE.pileSize() < PAGE) return (false, ids, 0);
        uint256[] memory page = CORE.pilePage(0, PAGE);
        if (creditSaleOn) {
            (,, uint64 acquiredAt) = CORE.creditInfo(page[PAGE - 1]);
            if (!pastWindow(acquiredAt)) return (false, ids, 0);
        }
        for (uint256 i; i < PAGE; ++i) {
            ids[i] = page[i];
        }
        return (true, ids, 0);
    }
}
