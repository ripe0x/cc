// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// shared runtime and integration types. generated contract interfaces live beside this file.

interface IController {
    /// the next page to compose. the core uses `ready` and `ids`; the returned `format` is not used, the core picks the
    /// format of a system compose
    function nextPage() external view returns (bool ready, uint256[80] memory ids, uint8 format);
    /// true when statement `sid` is eligible for redemption. with `ageEligibilityOn` false (launch) the curve price
    /// has reached its floor, `saleFloorBps` of the reference; with it on the rule is age only. the age excludes
    /// paused seconds; owner settings and reference changes can still affect eligibility during a pause. the core
    /// reads it to gate the balance side redemption
    function atFloor(uint256 sid) external view returns (bool);
    /// true when a credit acquired at `acquiredAt` may be composed: always while the credit sale is off, otherwise once
    /// the credit window has passed. the core reads it to gate a chosen compose
    function pastWindow(uint64 acquiredAt) external view returns (bool);
    /// the asking price of statement `sid` now. the core reads it once per compose for the `Composed` event, and a
    /// failed read is logged as 0
    function priceOf(uint256 sid) external view returns (uint256);
    /// the wei value of one point (`POINT_UNIT` score units, `POINT_UNIT * unitPerPoint` balance token base units)
    /// at the protected price of the balance token: the buy price `min(spot, reference * (10_000 + tolBps) /
    /// 10_000)` for `forSale` false, rounded down, the sale price `max(spot, reference * (10_000 - tolBps) /
    /// 10_000)` for true, rounded up. `ok` is false, and `value` 0, while the quote is unusable (no pool key or
    /// module, a stale reference, pool liquidity samples under the minimum, a failed unit read). `spot` is the
    /// prior-block refresh sample. the Core reads it with a gas bound and closes its ETH bid at zero on an unusable
    /// answer; the last good rate remains stored for a later switch out of value mode
    function valuePerPoint(bool forSale) external view returns (uint256 value, bool ok);
    /// the `posted` balance payout for a credit of `score` stored units lowered to its value mode cap, balance base
    /// units: the smaller of `posted` and `ethPrice() * score / RATE_SCORE` converted at the protected sale price,
    /// before the ETH pot clamp. an unusable reference returns `(0, true)`, refusing the payout. a failed bounded
    /// controller call or `ok` false also refuses the payout
    function balanceClampFor(uint256 score, uint256 posted) external view returns (uint256 paid, bool ok);
    /// moves the reference toward the pool spot under its cadence, rate and step gates; true when it updated the
    /// reference. the Core's `refreshReference` door forwards to it and pays the caller only when it returns true
    function refreshReference() external returns (bool);
}

interface IBalanceModule {
    function balanceToken() external view returns (address);
    /// balance token base units per stored score unit. a score is in ten-thousandths of a point (a score of 132.4012 is
    /// stored as 1_324_012), so this is base units per ten-thousandth of a point, not per whole point. a statement
    /// redemption owes `rating * unitPerPoint`, where `rating` is the sum of its credits' stored scores. the core and
    /// the controller read it at each use
    function unitPerPoint() external view returns (uint256);
    /// called by the core after it transfers the statement to the module. the proceeds stay in the module
    function redeem(uint256 statementId) external returns (uint256 out);
    /// the balance token the module will pay out for the balance bid. the module may hold more and keep the rest for
    /// other uses. the core checks a sell batch against it and the core's `setBalanceModule` requires it to answer
    function available() external view returns (uint256);
    /// Core-only payment, at most `available()`. the production module reserves transfer shortfalls as claimable
    /// liabilities; the Core independently requires the seller's full immediate receipt
    function pay(address to, uint256 amount) external;
}

/// the replaceable quote of the phase 2 treasury's CC redemption. stateless and holding nothing: the treasury reads it
/// under a bounded static call and refuses any answer above the proportional share `ccIn * claimReserve / ccSupply` it
/// computes itself, so a policy can lower a payout (a fee) and never raise it
interface IRedemptionPolicy {
    /// the balance token paid for burning `ccIn` of a `ccSupply` against `claimReserve` with a fee of `feeBps`
    function quote(uint256 ccIn, uint256 claimReserve, uint256 ccSupply, uint256 feeBps)
        external
        view
        returns (uint256 out);
    /// true. the treasury's policy probe
    function isRedemptionPolicy() external pure returns (bool);
}

/// treasury v2's balance bid. the price is `bidBps` of par (a credit's score times `unitPerPoint`): it climbs `climbBps` per
/// full `stepSeconds` since the last fill and drops `dropPer100PointsBps` per 100 points filled, inside [floorBps,
/// capBps]. each payout is also capped so its eth value at the controller's protected sale price is at most the
/// Core's eth price for the credit plus `overEthBps`. `maxPerCall` and `maxPerPeriod` cap the payouts and royalties
struct BalanceBid {
    uint16 floorBps;
    uint16 capBps;
    uint16 climbBps;
    uint32 stepSeconds;
    uint16 dropPer100PointsBps;
    uint16 overEthBps;
    uint128 maxPerCall;
    uint128 maxPerPeriod;
}

/// a treasury v2 registered redeemer. it draws only from `bucket`, only while `on`, from `activeAt`, at most `perCall` per
/// redemption, `perPeriod` per day and `lifetime` in all. `epoch` advances on every change to its terms here
struct RedeemerState {
    bool registered;
    bool on;
    uint16 shareBps;
    uint64 epoch;
    uint40 activeAt;
    uint40 periodStart;
    uint128 perCall;
    uint128 perPeriod;
    uint128 lifetime;
    uint128 periodUsed;
    uint128 lifetimeUsed;
    uint256 bucket;
    uint256 totalIn;
    uint256 totalOut;
}

/// a treasury v2 committed payout: linear vesting from `start` to `end`, or the whole amount at `end` when not linear
struct CommittedPayout {
    address recipient;
    address redeemer;
    uint40 start;
    uint40 end;
    bool linear;
    uint128 amount;
    uint128 released;
}

/// ControllerV3's idle loosening of the value mode buy price. `bps` per full `stepSeconds` without a purchase, at most `capBps`
struct IdleLoosening {
    uint32 stepSeconds;
    uint16 bps;
    uint16 capBps;
}

/// ControllerV3's CC reference settings. `avgSeconds` is the averaging time: a refresh after `elapsed` seconds moves the
/// reference `min(elapsed, avgSeconds) / avgSeconds` of the way to the spot, then the rate and step bounds clip it
struct CcQuote {
    uint32 rateBpsPerHour;
    uint16 stepBps;
    uint32 maxStale;
    uint32 minSeconds;
    uint32 avgSeconds;
    uint128 minLiquidity;
}

/// a redemption design of treasury v2, registered by the owner. the treasury calls `quote` once per redemption, before
/// it burns `ccIn` of `burner`'s CC, with the redeemer's own `bucket` and the CC supply before the burn. it answers the
/// payout and its mode: 0 immediate, 1 linear vesting over `duration` seconds, 2 claimable after `duration` seconds. the
/// treasury enforces the bucket, the caps, the burn and the recipient; a redeemer can lower a payout and never pay from
/// anything but its own bucket
interface IRedeemer {
    function quote(address burner, uint256 ccIn, uint256 bucket, uint256 ccSupply, bytes calldata data)
        external
        returns (uint256 amount, uint8 mode, uint32 duration);
}

interface ICreditScore {
    /// score of a credit in ten-thousandths of a point, 800_000 to 8_000_000 (80 to 800 points). pure in `seed` and
    /// `paidAt`, which are fixed at mint
    function scoreOf(bytes21 seed, uint64 paidAt) external view returns (uint256);
}

/// the surface controllers rely on. the pile is an insertion ordered linked list, oldest first
interface ICoreViews {
    function pileSize() external view returns (uint256);
    function pilePage(uint256 startAfter, uint256 n) external view returns (uint256[] memory ids); // startAfter 0 starts at head
    function creditInfo(uint256 id) external view returns (bool inPile, uint256 cost, uint64 acquiredAt);
    /// the eth bid rate now, wei per 100 points, the price state lowered to the pot. a credit of score `score` is paid
    /// `ethRate() * score / (100 points in score units)`; `bidForScore` and `bidOf` apply the scaling
    function ethRate() external view returns (uint256);
    /// the eth bid for a score of `score` stored units now, wei: `ethRate() * score / 1_000_000`
    function bidForScore(uint256 score) external view returns (uint256);
    /// the eth bid per point now, wei: `ethRate() / 100`
    function ethPerPoint() external view returns (uint256);
    /// the eth bid for credit `id` now, wei: `bidForScore(scoreOf(id))`
    function bidOf(uint256 id) external view returns (uint256);
    /// the eth price state now, wei per 100 points, before the pot clamp `ethRate` applies. the cost basis of an
    /// adopted credit is this price times its score over 100 points plus the artist purchase royalty, at least 1
    /// wei. in later blocks the climb heads toward the larger pot
    function ethPrice() external view returns (uint256);
    /// max(climbed mode-off ETH instance, its decayed peak), wei per 100 points. mode-off sale references and
    /// balance-acquisition bases scale it by score. value-mode acquisition bases use `ethPrice()`, while value-mode
    /// sale references use protected sale-token value. ETH purchase bids use `ethRate()`
    function floorRate() external view returns (uint256);
    function statementInfo(uint256 sid) external view returns (bool held, uint256 cost, uint64 composedAt);
    /// the seconds a held statement has aged outside every pause. reverts `NotForSale` when the core does not hold it
    function statementAge(uint256 sid) external view returns (uint256);
    /// the stored rating of a statement: the sum of its credits' scores, read from Statements at compose
    function ratingOf(uint256 sid) external view returns (uint256);
    function heldStatements() external view returns (uint256[] memory sids);
    function balanceModule() external view returns (address);
    function balanceToken() external view returns (address);
}

/// what the controller needs of the core beyond the views: the live owner and the two doors that sell custody out, a
/// statement and a pile credit
interface ICoreSale {
    function owner() external view returns (address);
    function settings() external view returns (Settings memory);
    function sellTo(uint256 sid, address buyer) external payable;
    /// controller-only credit sale; `msg.value` must cover `cost * saleFloorBps / 10_000`
    function sellCreditTo(uint256 id, address buyer) external payable;
}

/// the coin calls the core makes. the live token burns from the caller or from an account that approved the caller
interface ICoin {
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

interface ICredits {
    function seedOf(uint256 id) external view returns (bytes21);
    function timestampOf(uint256 id) external view returns (uint64);
    function tokensOf(address owner) external view returns (uint256[] memory);
    function ownerOf(uint256 id) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function approve(address to, uint256 id) external;
    function transferFrom(address from, address to, uint256 id) external;
}

interface IStatements {
    function compose(uint256[80] calldata creditIds, uint8 format) external returns (uint256 statementId);
    function creditsOf(uint256 statementId) external view returns (uint256);
    function setFormat(uint256 statementId, uint8 format) external;
    function formatOf(uint256 statementId) external view returns (uint8);
    /// the statement's rating, the sum of its credits' scores in ten-thousandths of a point
    function creditScoreOf(uint256 statementId) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function supply() external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function transferFrom(address from, address to, uint256 id) external;
    function safeTransferFrom(address from, address to, uint256 id) external;
}

interface ICreditStrategy {
    function nftForSale(uint256 tokenId) external view returns (uint256 price);
    function sellTargetNFT(uint256 tokenId) external payable;
}

// bounds of the Core constructor argument `rateStart` and of `rateCap`, wei per 100 points. one definition for the Core and the scripts
uint256 constant RATE_START_MIN_WEI = 1;
uint256 constant RATE_START_MAX_WEI = type(uint64).max;

// stored score units per point. a credit's score (CreditScore.scoreOf) is its point rating times this
uint256 constant POINT_UNIT = 10_000;
// the stored score units the eth rate is quoted per: 100 points. bidForScore, the per credit drop and the controller
// point rate divide by it
uint256 constant RATE_SCORE = 100 * POINT_UNIT;

// the most gas of a buyback the caller's refund counts, so a gas burning hook cannot inflate it. a buyback counts
// about 267,000 gas. read by the Core and by the `buybackSlice` bound
uint256 constant BUYBACK_GAS = 600_000;

// the most gas of a buyListing the caller's payment counts, so a gas burning target cannot inflate it. the largest
// measured buyListing (CreditStrategy path) is 450,000 to 490,000 gas as a transaction. read by the Core
uint256 constant BUYLISTING_GAS = 1_500_000;

/// every economic setting of the Core. one struct in Core storage, owner settable at once through `setSettings`,
/// bounds in `src/lib/SettingsBounds.sol`. the types are narrow so the whole struct packs into five storage slots
/// (a hot path reads it with a handful of loads). the field order is the slot layout: slot 0 holds the rate and
/// sale fields and the balance mode and bps, slot 1 the buyback and keeper fields, slot 2 the rate cap, caller
/// fields, fee split and `pointsPerPage`, slot 3 `swapFeeCc`, the two sale cuts, `climbMultiplierCapBps`,
/// `spendCapBps`, `bucketSeconds`, `balanceBidCapBps` and `idleStepSeconds`, slot 4 `sniperSeconds`, `reserveWei`,
/// `returnLockSeconds`, `valueModeOn`, `buyToArtistBps` and `balanceDiscountBps`. docs/SPEC.md section 3 has the
/// meaning of every field
struct Settings {
    // slot 0
    /// fall of a bid rate on a fill, bps of the rate before the credit, as `dropPer100PointsBps * score / (100
    /// points in score units)`, bounded at 10_000; applies to the active ETH instance, never the posted balance bid
    uint16 dropPer100PointsBps;
    /// within one bucket the rate falls no lower than this share of the rate at the first fill of that bucket, bps
    uint16 dropFloorBps;
    /// climb of the active ETH instance per minute, bps, compounded
    uint16 climbPerMinBps;
    /// the rate stays at or below this share of the ceiling anchor, bps. the anchor is `max(last fill rate, peak now)`
    uint16 ceilBps;
    /// growth of the ceiling anchor per full idleStepSeconds since the later of the last fill and a funded clock restart,
    /// bps of the anchor in mode-off ETH pricing
    uint16 idleLoosenBps;
    /// the floor of a statement sale, bps of the statement cost in `sellTo` and bps of the controller reference in
    /// the mode-off curve. the Core's cost floor applies in both modes
    uint16 saleFloorBps;
    /// share of a statement sale payment after the artist and operator cuts that goes to the coin buyback, bps
    uint16 saleToBuybackBps;
    /// climb of the eth rate per minute while the price state is below the recovery level
    /// `peak * (10_000 - recoveryGapBps) / 10_000`, bps, compounded. at or above the level the rate climbs
    /// `climbPerMinBps`. at least `climbPerMinBps`
    uint16 recoveryClimbPerMinBps;
    /// the recovery climb applies only while the price state is more than `recoveryGapBps` below the remembered peak,
    /// bps of the peak: below `peak * (10_000 - recoveryGapBps) / 10_000`. at or above that level the climb is
    /// `climbPerMinBps`. 0 makes every fill start the recovery climb
    uint16 recoveryGapBps;
    /// seconds in which the remembered peak halves. the ceiling anchor is `max(last fill rate, peak now)`
    uint32 peakHalfLife;
    /// blocks between two coin buybacks
    uint16 buybackDelay;
    /// whether `redeemStatement` runs
    bool redeemOn;
    /// whether `sellForBalance` runs
    bool balanceBidOn;
    /// a redemption must raise the balance token balance by at least `rating * unitPerPoint * (10_000 - redeemSlippageBps)
    /// / 10_000`, bps
    uint16 redeemSlippageBps;
    /// value mode only: the floor and opening value of the shared eth instance is `10_000 - balanceBidMarginBps`, bps of
    /// par. the posted balance bid does not read it
    uint16 balanceBidMarginBps;
    /// share of `ethRedeemBurn` moved into the coin buyback on each redemption, bps
    uint16 redeemBurnBps;
    // slot 1
    uint128 buybackSlice;
    /// fixed fee paid to the caller of `buyback` and `buyListing`, wei. the `buyback` fee is scaled by the eth spent over
    /// the largest swap budget the `buybackSlice` setting allows, the `buyListing` fee is paid whole
    uint64 keeperFee;
    /// base fee ceiling of the gas refund of `buyback` and `buyListing`, wei
    uint48 keeperMaxBaseFee;
    // slot 2
    /// the most the eth rate can be, wei per 100 points. the price state and the read stay at or below it,
    /// `setRate` refuses above it, and the rate bounds apply to it
    uint64 rateCap;
    /// fixed fee paid to the caller of `compose` and `redeemStatement`, wei, from `ethPot`. zero turns the whole payment
    /// of those doors off when `callerMaxBaseFee` is zero too
    uint64 callerFee;
    /// base fee ceiling of the gas refund of `compose` and `redeemStatement`, wei. zero refunds no gas
    uint48 callerMaxBaseFee;
    /// share of the fee income booked by `_book`, after the payee share, that fills `ethRedeemBurn`, bps. the rest goes to
    /// the pot
    uint16 feeToRedeemBurnBps;
    /// share of the fee income booked by `_book` that is pushed to the payee once the payee share is on, ppm. at most
    /// 1_000_000
    uint24 payeePpm;
    /// the points in one statement page, plain points. the ceiling idle loosening scales with the pages the pot buys:
    /// one page costs `rate * pointsPerPage / 100`. nonzero uint32
    uint32 pointsPerPage;
    // slot 3
    /// coin the caller of `swapCredit` burns to swap a pile credit for one of equal or higher score. base units, uint96
    uint96 swapFeeCc;
    /// share of a statement or credit sale's proceeds pushed to `artist`, taken off the payment before the other
    /// splits, bps; artist and operator together are strictly below 10,000
    uint16 saleToArtistBps;
    /// share of a statement or credit sale's proceeds pushed to the payee as the operator cut, taken off the payment
    /// before the other splits, bps; artist and operator together are strictly below 10,000
    uint16 saleToOperatorBps;
    /// the cap of the pot scaled climb multiplier, bps (10,000 is 1x). the ceiling's idle loosening scales by
    /// `clamp(pot / (rate * pointsPerPage / 100), 1, this / 10,000)`. 10,000 to uint16.max, packed into slot 3 beside the sale cut shares
    uint16 climbMultiplierCapBps;
    /// share of the opening buying pot available per bucket; 10,000 bypasses enforcement
    uint16 spendCapBps;
    /// seconds per shared purchase-budget and bid-drop bucket
    uint32 bucketSeconds;
    /// shared value-mode ETH instance cap, bps of par, at least 10,000. also feeds the sale-floor multiplier in
    /// both modes; the posted balance bid does not read it
    uint32 balanceBidCapBps;
    /// seconds per full ceiling-loosening step; per-minute climb units remain 60 seconds
    uint32 idleStepSeconds;
    /// seconds after token launch before the one-way payee latch may activate
    uint32 sniperSeconds;
    /// the least eth the pot keeps for processing, wei. the reserve is the larger of this and 1.5 times the queued compose
    /// and redeem caller payments; the bids and `ethRate` read `ethPot` less the reserve, the caller payments, the buyback
    /// and the pushes pay from the whole pot
    uint64 reserveWei;
    /// seconds intake doors refuse a credit after `sellCreditTo`, including from a secondary holder; 0 disables the lock
    uint32 returnLockSeconds;
    /// value mode prices the ETH bid from the shared instance and protected buy value; ETH fills drop that
    /// instance. sale references use protected sale value without cost or floor-rate terms; final quotes retain the
    /// Core cost minimum. turning the switch on resets the shared instance to its floor
    bool valueModeOn;
    /// the artist royalty on every engine purchase, bps of the amount the engine pays for a credit, paid on top in the
    /// same currency: the seller receives the bid whole, the artist `pay * this / 10,000`. 0 to 1,000
    uint16 buyToArtistBps;
    /// the BALANCE bid's discount to par, bps: the route pays `score * unitPerPoint * (10,000 - this) / 10,000` per
    /// Credit before the value-mode cap. SettingsBounds requires the discount to cover the purchase royalty and the
    /// accepted redemption shortfall. The upper bound of 9,999 keeps the posted bid above zero before rounding
    uint16 balanceDiscountBps;
}

/// the sale settings of the controller, its constructor argument and the `sale` block of the launch config.
/// bounds are enforced by the controller (docs/SPEC.md section 3). the controller keeps one more value, the anchor, which
/// starts at 10_000
struct Sale {
    /// the start price over the anchor, bps
    uint16 markupBps;
    /// cap of the reference curve's start, bps, before the Core cost-floor clamp. statement reference is `max(cost,
    /// valueOf(rating))` in mode off, or `valueOf(rating) * floorMultBps() / 10_000` in value mode
    uint32 startCapBps;
    /// hours for the reference curve to reach its floor. 1 to uint16.max. a dominating Core cost floor can flatten
    /// the final quote earlier and can exceed the curve's start cap
    uint16 decayHours;
    /// seconds for the part of the anchor above 10_000 to halve
    uint32 anchorHalfLife;
    /// the least statement cost, in wei, whose sale moves the anchor
    uint128 anchorMinCost;
    /// share of the gap toward a qualifying sale that moves the anchor; 0 leaves its clock unchanged
    uint16 anchorMoveBps;
}

/// the credit sale settings of the controller and the rating reference it applies to every sale. set at once by
/// `setCredit`. the fields are the controller half of `Credit`
struct CreditSale {
    /// whether pile credits are for sale from acquisition and compose waits for a credit's window to pass
    bool saleOn;
    /// seconds a credit's price falls over before it rests at the floor, and the time a credit sits before compose may
    /// take it. 1 to uint32.max seconds
    uint32 window;
    /// sale spread, bps. the floor is `max(cost, valueOf(score)) * floorMultBps() / 10_000`, with cost dropped from
    /// the reference in value mode. both modes enforce the Core's `cost * saleFloorBps / 10_000` minimum. at least
    /// 200, and enough to close the tolerance band (at least 203 with `tolBps` 100)
    uint16 spreadBps;
    /// the credit sale start price over the floor, bps. 10_000 to uint32.max
    uint32 startBps;
}

/// the reference price settings of the controller (decision 148), set at once by `setQuote`. the controller keeps a
/// reference price of the balance token that `refreshReference()` and its sale doors move toward the pool spot by at most
/// `min(referenceRateBpsPerHour * elapsed / 3600, referenceStepBps)` bps of the reference per update
struct Quote {
    /// the most the reference moves toward the spot per hour, bps of the reference
    uint32 referenceRateBpsPerHour;
    /// the most one update moves the reference, bps of the reference. 0 to 10_000
    uint16 referenceStepBps;
    /// the band around the reference, using the prior-block refresh sample as `spot`: buys use `min(spot, reference
    /// * (10_000 + tolBps) / 10_000)`, sales use `max(spot, reference * (10_000 - tolBps) / 10_000)`. 0 to 9_999
    uint16 tolBps;
    /// seconds after the last update the reference stays usable. 0 keeps the reference price unusable
    uint32 referenceMaxStale;
    /// least seconds between refreshes; elapsed time must be at least this value, and only one refresh may run per
    /// block
    uint32 referenceMinSeconds;
    /// the least pool liquidity of a usable reference price
    uint128 minLiquidity;
}

/// the credit settings of the launch: the constructor arguments the Core and the controller take for the credit sale
/// window and chosen composition. owner adjustable afterwards, so the launch rules only check
/// bounds (`src/lib/CreditBounds.sol`). the Core reads `costToPotBps`, `chosenComposeOn` and `minCcToChoose`; the
/// controller reads `saleOn`, `window`, `spreadBps` and `startBps`. the point rate basis is the fixed 100 points
struct Credit {
    // core
    /// share of the sold credit's cost booked to the buying pot, bps. the rest of the payment funds the coin buyback.
    /// 0 to 10_000
    uint16 costToPotBps;
    /// whether a caller may name the 80 credits and the format of a compose through `composeChosen`
    bool chosenComposeOn;
    /// least coin balance a caller of `composeChosen` must hold
    uint96 minCcToChoose;
    // controller
    /// whether pile credits are for sale from acquisition and compose waits for a credit's window to pass
    bool saleOn;
    /// seconds a credit's price falls over before it rests at the floor, and the time a credit sits before compose may
    /// take it. 1 to uint32.max seconds
    uint32 window;
    /// the controller's `CreditSale.spreadBps`: at least 200 bps and enough to close the tolerance band
    uint16 spreadBps;
    /// the credit sale start price over the floor, bps. 10_000 to uint32.max
    uint32 startBps;
}

/// the artcoins stack a launch runs on. a deploy input of the Core, so a new artcoins version needs no code change.
/// the members feed the pool key and the forbidden targets
struct Stack {
    address poolManager;
    address hook;
    int24 tickSpacing;
    uint24 poolFee;
    address factory;
    address locker;
    address escrow;
}

library Mainnet {
    address internal constant CREDITS = 0x97630aA70AB14ed9883B41dAfccBc11349723043;
    address internal constant STATEMENTS = 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b;
    /// scores a credit from its seed and paid time. read by every eth door, the balance token bid and `bidOf`, once per
    /// credit
    address internal constant CREDIT_SCORE = 0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7;
    address internal constant CREDIT_STRATEGY = 0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6;
    address internal constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    /// the OpenSea fee recipient of Seaport orders, the launch allowlist entry of `SeaportBasicAdapter`
    address internal constant OPENSEA_FEE_COLLECTOR = 0x0000a26b00c1F0DF003000390027140000fAa719;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    // the artcoins v2 stack addresses are config inputs and not constants: `defaultStack` leaves them zero, the Core
    // refuses a zero member and the deploy script refuses a zero config. script/config/v2-mainnet.json records the live
    // stack, script/config/mainnet.json carries it into the launch config, test/utils/V2Stack.sol reads it for the tests

    /// the dynamic fee flag every artcoins pool uses, and its tick spacing
    uint24 internal constant POOL_FEE = 0x800000;
    int24 internal constant TICK_SPACING = 200;

    /// the launch values of docs/SPEC.md section 3
    function defaultSettings() internal pure returns (Settings memory) {
        return Settings({
            dropPer100PointsBps: 115,
            dropFloorBps: 1,
            climbPerMinBps: 200,
            ceilBps: 11_000,
            idleLoosenBps: 600,
            saleFloorBps: 10_000,
            saleToBuybackBps: 2_500,
            recoveryClimbPerMinBps: 200,
            recoveryGapBps: 1_000,
            peakHalfLife: 21_600,
            buybackDelay: 25,
            redeemOn: true,
            balanceBidOn: false,
            redeemSlippageBps: 200,
            balanceBidMarginBps: 1_000,
            redeemBurnBps: 2_000,
            buybackSlice: 0.5 ether,
            keeperFee: 0.0003 ether,
            keeperMaxBaseFee: 5 gwei,
            rateCap: 13_950_000_000_000_000,
            callerFee: 0.0003 ether,
            callerMaxBaseFee: 3 gwei,
            feeToRedeemBurnBps: 0,
            payeePpm: 0,
            pointsPerPage: 35_200,
            swapFeeCc: 10_000e18,
            saleToArtistBps: 250,
            saleToOperatorBps: 50,
            climbMultiplierCapBps: 40_000,
            spendCapBps: 10_000,
            bucketSeconds: 60,
            balanceBidCapBps: 10_000,
            idleStepSeconds: 600,
            sniperSeconds: 4140,
            reserveWei: 0.1 ether,
            returnLockSeconds: 21_600,
            valueModeOn: false,
            buyToArtistBps: 250,
            balanceDiscountBps: 1_000
        });
    }

    /// the launch sale: the ask starts at 150 percent of the reference (at most 1_000 percent, the start cap) and falls
    /// in a straight line to 100 percent over 4 hours, where it rests. `anchorMoveBps` 0 keeps the anchor at 100 percent,
    /// so no sale moves it; its half life and minimum cost stay set for a later raise
    function defaultSale() internal pure returns (Sale memory) {
        return Sale({
            markupBps: 15_000,
            startCapBps: 100_000,
            decayHours: 4,
            anchorHalfLife: 7 days,
            anchorMinCost: 0.1 ether,
            anchorMoveBps: 0
        });
    }

    /// the launch credit settings: the credit sale is on, its window is 4 hours, the spread is 10 percent over the bid's
    /// hard cap (decision 155; the floor is 110 percent of the reference at the launch cap of 10_000, today's 1.1x; the
    /// value switch keeps 1,000 unless the owner sets a pair compatible with the chosen tolerance), the start is 150
    /// percent of the floor, 80 percent of a sold credit's cost funds the pot, chosen composition is off, and the coin
    /// balance a caller needs to choose a
    /// compose or a held format is 1 coin
    function defaultCredit() internal pure returns (Credit memory) {
        return Credit({
            costToPotBps: 8_000,
            chosenComposeOn: false,
            minCcToChoose: 1e18,
            saleOn: true,
            window: 4 hours,
            spreadBps: 1_000,
            startBps: 15_000
        });
    }

    /// the launch reference price settings: a 100 bps executable band and a 600 second refresh
    /// cadence. the rate, the step, the staleness and the liquidity minimum are owner inputs set once the balance token
    /// pool exists and its depth is known; a `referenceMaxStale` of 0 keeps the reference price unusable, so value mode
    /// makes the controller's value-mode sale prices unusable until they are set
    function defaultQuote() internal pure returns (Quote memory) {
        return Quote({
            referenceRateBpsPerHour: 0,
            referenceStepBps: 0,
            tolBps: 100,
            referenceMaxStale: 0,
            referenceMinSeconds: 600,
            minLiquidity: 0
        });
    }

    /// the default stack: the fixed parts of mainnet. the v2 members (hook, factory, locker, escrow) are zero and are
    /// filled by the config before a launch
    function defaultStack() internal pure returns (Stack memory) {
        return Stack({
            poolManager: POOL_MANAGER,
            hook: address(0),
            tickSpacing: TICK_SPACING,
            poolFee: POOL_FEE,
            factory: address(0),
            locker: address(0),
            escrow: address(0)
        });
    }
}
