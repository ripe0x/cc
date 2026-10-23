// Hand-written subset of src/interfaces/ICore.sol, IControllerV1.sol, IControllerV2.sol,
// IPhase2BalanceTreasury.sol and ISeaportBasicAdapter.sol: the views and actions web/ and keeper/ call,
// the events the feed decodes and the custom errors a simulation decodes.

import { parseAbi } from "viem";

export const coreAbi = parseAbi([
  // views
  "function COIN() view returns (address)",
  "function controller() view returns (address)",
  "function balanceModule() view returns (address)",
  "function balanceToken() view returns (address)",
  "function ethRate() view returns (uint256)",
  "function ethPrice() view returns (uint256)",
  "function bidOf(uint256 id) view returns (uint256)",
  "function bidForScore(uint256 score) view returns (uint256)",
  "function ethPerPoint() view returns (uint256)",
  "function balanceBidForScore(uint256 score) view returns (uint256)",
  "function balanceRate() view returns (uint256)",
  "function sharedRate() view returns (uint256)",
  "function balanceBidOf(uint256 id) view returns (uint256)",
  "function floorRate() view returns (uint256)",
  "function RATE_START() view returns (uint256)",
  "function rateAtCheckpoint() view returns (uint256)",
  "function checkpointTime() view returns (uint64)",
  "function lastFillTime() view returns (uint64)",
  "function climbMultiplier() view returns (uint256)",
  "function spendState() view returns (uint64 bucket, uint128 budget, uint128 spent)",
  "function ethPot() view returns (uint256)",
  "function reserve() view returns (uint256)",
  "function ethToBuyback() view returns (uint256)",
  "function ethRedeemBurn() view returns (uint256)",
  "function payee() view returns (address)",
  "function artist() view returns (address)",
  "function creditCostToPotBps() view returns (uint16)",
  "function payeeOn() view returns (bool)",
  "function pileSize() view returns (uint256)",
  "function pilePage(uint256 startAfter, uint256 n) view returns (uint256[] ids)",
  "function creditInfo(uint256 id) view returns (bool inPile, uint256 cost, uint64 acquiredAt)",
  "function heldStatements() view returns (uint256[] sids)",
  "function statementInfo(uint256 sid) view returns (bool held, uint256 cost, uint64 composedAt)",
  "function statementAge(uint256 sid) view returns (uint256)",
  "function ratingOf(uint256 sid) view returns (uint256)",
  "function composerOf(uint256 sid) view returns (address)",
  "function settings() view returns ((uint16 dropPer100PointsBps, uint16 dropFloorBps, uint16 climbPerMinBps, uint16 ceilBps, uint16 idleLoosenBps, uint16 saleFloorBps, uint16 saleToBuybackBps, uint16 recoveryClimbPerMinBps, uint16 recoveryGapBps, uint32 peakHalfLife, uint16 buybackDelay, bool redeemOn, bool balanceBidOn, uint16 redeemSlippageBps, uint16 balanceBidMarginBps, uint16 redeemBurnBps, uint128 buybackSlice, uint64 keeperFee, uint48 keeperMaxBaseFee, uint64 rateCap, uint64 callerFee, uint48 callerMaxBaseFee, uint16 feeToRedeemBurnBps, uint24 payeePpm, uint32 pointsPerPage, uint96 swapFeeCc, uint16 saleToArtistBps, uint16 saleToOperatorBps, uint16 climbMultiplierCapBps, uint16 spendCapBps, uint32 bucketSeconds, uint32 balanceBidCapBps, uint32 idleStepSeconds, uint32 sniperSeconds, uint64 reserveWei, uint32 returnLockSeconds, bool valueModeOn, uint16 buyToArtistBps, uint16 balanceDiscountBps))",
  "function paused() view returns (bool)",
  "function retired() view returns (bool)",
  "function chosenComposeOn() view returns (bool)",
  "function minCcToChoose() view returns (uint96)",
  // actions
  "function sellForEth(uint256[] ids, uint256 minOut)",
  "function sellForBalance(uint256[] ids, uint256 minOut)",
  "function sellForBalance(uint256[] ids, uint256 minOut, address expectedToken)",
  "function swapCredit(uint256 inId, uint256 outId)",
  "function compose()",
  "function compose(uint8 format)",
  "function composeChosen(uint256[80] ids, uint8 format)",
  "function setHeldFormat(uint256 sid, uint8 format)",
  "function redeemStatement(uint256 sid)",
  "function refreshReference()",
  "function buyback()",
  "function book()",
  "function setArtist(address to)",
  "function lastBuybackBlock() view returns (uint256)",
  "function buyListing(address adapter, uint256 id, bytes params)",
  "function collectEscrow()",
  "function ESCROW() view returns (address)",
  "function FACTORY() view returns (address)",
  "function owner() view returns (address)",
  "function allowedAdapter(address adapter) view returns (bool)",
  // errors of the Core and the controller (src/interfaces/ICore.sol, IControllerV1.sol) and the listing adapters
  "error AboveBid()",
  "error AdapterNotAllowed()",
  "error AlreadyOwned()",
  "error BadController()",
  "error BadCost()",
  "error BadFormat()",
  "error BadModule()",
  "error BadQuote()",
  "error BadRate()",
  "error BadSender()",
  "error BadSetting(bytes32 field)",
  "error BadStatement()",
  "error BadSwap()",
  "error BalanceBidOff()",
  "error BelowFloor()",
  "error BelowMinCc()",
  "error CallFailed()",
  "error ChosenComposeOff()",
  "error CreditSaleOff()",
  "error Empty()",
  "error ForbiddenTarget()",
  "error Held()",
  "error InPile()",
  "error InWindow(uint256 id)",
  "error NoBalanceModule()",
  "error NoCredit()",
  "error NoQuote()",
  "error NotEligible()",
  "error NotForSale()",
  "error NotHeld()",
  "error NotInPile(uint256 id)",
  "error NotOwner()",
  "error NotReady()",
  "error NothingBought()",
  "error NothingToBuy()",
  "error Paused()",
  "error PotTooSmall()",
  "error RedeemOff()",
  "error SpendCapReached(uint256 spent, uint256 cost, uint256 budget)",
  "error Reentrancy()",
  "error Reentrant()",
  "error Retired()",
  "error ReturnLocked(uint256 id, uint256 until)",
  "error SliceTooSmall()",
  "error Slippage()",
  "error BalanceTokenChanged()",
  "error TooSoon()",
  "error Underpaid()",
  "error UseFund()",
  "error ZeroAmount()",
  "error ZeroId()",
  "error NotNative()",
  "error RecipientNotAllowed(address recipient)",
  "error RestrictedOrder()",
  "error WrongAmount()",
  "error WrongId()",
  "error WrongToken()",
  "error ZeroPrice()",
]);

export const controllerAbi = parseAbi([
  // views
  "function priceOf(uint256 sid) view returns (uint256 price)",
  "function referenceOf(uint256 sid) view returns (uint256)",
  "function atFloor(uint256 sid) view returns (bool)",
  "function creditPrice(uint256 id) view returns (uint256 price)",
  "function creditSaleOn() view returns (bool)",
  "function balancePoolKeySet() view returns (bool)",
  "function balancePoolKey() view returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)",
  "function creditWindow() view returns (uint32)",
  "function pastWindow(uint64 acquiredAt) view returns (bool)",
  "function nextPage() view returns (bool ready, uint256[80] ids, uint8 format)",
  "function pointRate() view returns (uint256)",
  "function valueOf(uint256 points) view returns (uint256)",
  "function markupBps() view returns (uint16)",
  "function startCapBps() view returns (uint32)",
  "function decayHours() view returns (uint16)",
  "function anchorBps() view returns (uint32)",
  "function startBps() view returns (uint256)",
  "function creditSpreadBps() view returns (uint16)",
  "function floorMultBps() view returns (uint256)",
  "function creditStartBps() view returns (uint32)",
  // the protected price (decision 148): the rate limited reference of the balance token, the pool spot it follows, the
  // reference price settings, and the value of one point at the protected buy (false) or sale (true) price
  "function referencePrice() view returns (uint256)",
  "function referenceTime() view returns (uint40)",
  "function spotPrice() view returns (uint256 spot, bool ok)",
  "function quote() view returns (uint32 referenceRateBpsPerHour, uint16 referenceStepBps, uint16 tolBps, uint32 referenceMaxStale, uint32 referenceMinSeconds, uint128 minLiquidity)",
  "function valuePerPoint(bool forSale) view returns (uint256 value, bool ok)",
  // actions
  "function buy(uint256 sid) payable",
  "function buyCredit(uint256 id) payable",
  "function buyCredits(uint256[] ids) payable",
  "function refreshReference()",
  // ControllerV2 (src/interfaces/IControllerV2.sol): the statement ask is a persistent multiple of the reference and a
  // statement is redeemable once its age reaches the delay. V2 has no startBps() and no Sale or anchor setters;
  // markupBps, decayHours, startCapBps, anchorBps and ageEligibilityOn remain as derived read only values. Reads of
  // the views below fail on a V1 controller, and startBps fails on V2, so every caller reads them with allowFailure
  "function statementSalesEnabled() view returns (bool)",
  "function statementSaleMultiplierBps() view returns (uint32)",
  "function statementRedeemDelaySeconds() view returns (uint32)",
  "error NoQuote()",
  "error StatementSalesOff()",
]);

// ControllerV3 (src/ControllerV3.sol) adds three jobs the keeper drives, all unpaid and callable by anyone: the fill
// hint sync that keeps the value-mode idle loosening known, and the CC price reference for later redeemers. V2 and V1
// have none of these, so the keeper reads idleSince() tolerantly to detect V3 and leaves the doors inert otherwise.
// A keeper-only export kept apart from controllerAbi so the web worker can extend that abi without colliding here.
export const controllerV3Abi = parseAbi([
  // the newest pile acquisition time and whether it is known; `known` false means the hint is stale and the idle
  // loosening reads zero until syncFill moves the hint to the pile tail
  "function idleSince() view returns (uint256 t, bool known)",
  "function syncFill() returns (bool)",
  // the CC price reference on the native eth / CC pool, for later redeemers; meaningful only once ccPoolKeySet is true
  "function ccPoolKeySet() view returns (bool)",
  "function ccReferencePrice() view returns (uint256)",
  "function ccReferenceTime() view returns (uint40)",
  "function ccQuote() view returns (uint32 rateBpsPerHour, uint16 stepBps, uint32 maxStale, uint32 minSeconds, uint32 avgSeconds, uint128 minLiquidity)",
  "function refreshCcReference() returns (bool)",
]);

// The phase 2 balance module (src/interfaces/IPhase2BalanceTreasury.sol): the views the web claim panel and the keeper
// read, the two public actions, the events the indexer projects and the custom errors a simulation decodes.
export const treasuryAbi = parseAbi([
  // views
  "function quoteRedemption(uint256 ccIn) view returns (uint256 balanceOut, uint256 reserve, uint256 supply, uint64 epoch, bool executable)",
  "function claimReserve() view returns (uint256)",
  "function totalOwed() view returns (uint256)",
  "function owed(address a) view returns (uint256)",
  "function custody() view returns (uint256)",
  "function working() view returns (uint256)",
  "function freeWorking() view returns (uint256)",
  "function available() view returns (uint256)",
  "function solvent() view returns (bool)",
  "function conversionReady() view returns (bool)",
  "function transfersReady() view returns (bool)",
  "function selected() view returns (bool)",
  // the gate of CC burns: the module is selected and not migrated, whatever the Core's retirement. added after the
  // first interface generation, so it is read tolerant with selected() as the fallback
  "function selectedForClaims() view returns (bool)",
  "function configEpoch() view returns (uint64)",
  "function redemptionPolicy() view returns (address)",
  "function redemptionFeeBps() view returns (uint16)",
  "function conversionToClaimBps() view returns (uint16)",
  "function minimumWorkingBalance() view returns (uint256)",
  "function ccRedemptionEnabled() view returns (bool)",
  "function workingPaymentsEnabled() view returns (bool)",
  "function conversionEnabled() view returns (bool)",
  "function migrated() view returns (bool)",
  "function balanceToken() view returns (address)",
  "function ccToken() view returns (address)",
  "function core() view returns (address)",
  "function predecessor() view returns (address)",
  "function unitPerPoint() view returns (uint256)",
  "function owner() view returns (address)",
  // actions open to the public
  "function redeemCC(uint256 ccIn, address recipient, uint256 minBalanceOut, uint256 deadline, uint64 expectedConfigEpoch) returns (uint256 balanceOut)",
  "function claim(address to) returns (uint256 amount)",
  // events (src/adapters/Phase2BalanceTreasury.sol)
  "event StatementConverted(uint256 indexed statementId, uint256 received, uint256 allocated, uint16 contributionBps, uint256 claimReserve)",
  "event PaymentAccrued(address indexed to, uint256 amount)",
  "event OwedClaimed(address indexed to, uint256 amount)",
  "event CCRedeemed(address indexed burner, address indexed recipient, uint256 ccIn, uint256 balanceOut, uint256 claimReserve, uint256 ccSupply, uint64 configEpoch)",
  "event SwitchesSet(bool conversionEnabled, bool workingPaymentsEnabled, bool ccRedemptionEnabled)",
  "event ConversionToClaimBpsSet(uint16 bps)",
  "event RedemptionFeeSet(uint16 bps, uint64 configEpoch)",
  "event MinimumWorkingBalanceSet(uint256 amount)",
  "event RedemptionPolicySet(address indexed policy, uint64 configEpoch)",
  "event ClaimsFunded(address indexed from, uint256 amount, uint256 claimReserve)",
  "event ClaimsAllocated(uint256 amount, uint256 claimReserve)",
  "event ClaimsReturned(uint256 amount, uint256 claimReserve, uint64 configEpoch)",
  "event WorkingWithdrawn(address indexed to, uint256 amount)",
  "event TokenRescued(address indexed token, address indexed to, uint256 amount)",
  "event TreasuryMigrated(address indexed successor, uint256 moved, uint256 claimsImported, uint64 configEpoch)",
  "event MigrationReceived(address indexed predecessor, uint256 claimsImported, uint256 claimReserve, uint64 configEpoch)",
  // errors
  "error BadPolicy()",
  "error BadSetting(bytes32 field)",
  "error BurnMismatch()",
  "error ConversionOff()",
  "error Expired()",
  "error Insolvent()",
  "error InsufficientAvailable()",
  "error InsufficientClaims()",
  "error InsufficientWorking()",
  "error InvalidAmount()",
  "error InvalidConfiguration()",
  "error InvalidRecipient()",
  "error InvalidSuccessor()",
  "error Migrated()",
  "error NotHeld()",
  "error OnlyCore()",
  "error OnlyOwner()",
  "error OnlyPredecessor()",
  "error ProtectedAsset()",
  "error RedeemedBelowRating()",
  "error RedemptionEnabled()",
  "error RedemptionOff()",
  "error Reentrant()",
  "error ShortPayment()",
  "error Slippage()",
  "error StaleEpoch()",
  "error SwitchesOn()",
  "error ZeroAmount()",
  "error ZeroSupply()",
]);

// The first redemption policy (src/adapters/ProRataRedemptionPolicy.sol): its version string and its pure quote.
export const redemptionPolicyAbi = parseAbi([
  "function VERSION() view returns (string)",
  "function isRedemptionPolicy() view returns (bool)",
  "function quote(uint256 ccIn, uint256 claimReserve, uint256 ccSupply, uint256 feeBps) view returns (uint256 out)",
]);

// Credits: the holdings read, the owner read and the Core approval.
export const creditsAbi = parseAbi([
  "function ownerOf(uint256 id) view returns (address)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed id)",
  "function tokensOf(address owner) view returns (uint256[])",
  "function isApprovedForAll(address owner, address operator) view returns (bool)",
  "function setApprovalForAll(address operator, bool approved)",
]);

// Statements: the mint counter and the owner of a statement.
export const statementsAbi = parseAbi([
  "function supply() view returns (uint256)",
  "function ownerOf(uint256 id) view returns (address)",
]);

export const erc20Abi = parseAbi([
  "function balanceOf(address a) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function totalSupply() view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);

// Swap path: Chainlink ETH/USD, v4 StateView (pool slot0), v4 Quoter (declared
// view so viem eth_calls it), Universal Router and Permit2 (the router's ERC20 allowance).
export const chainlinkAbi = parseAbi([
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);
export const stateViewAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
]);
// The hook's per-pool skim config and pool info, and the MEV module's current skim (decays after launch).
export const hookAbi = parseAbi([
  "function skimConfig(bytes32 poolId) view returns ((uint24 baselineSkimBps, uint16 bountyBps, address bountyRecipient, address protocolRecipient, uint24 referralBps))",
  "function poolInfo(bytes32 poolId) view returns ((uint16 version, bool restricted, uint40 createdAt, address launcher, address token, address locker, address mevModule, address extension))",
]);
export const mevAbi = parseAbi(["function currentSkimBps(bytes32 poolId) view returns (uint24 skimBps, bool active)"]);
export const quoterAbi = parseAbi([
  "function quoteExactInputSingle(((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) view returns (uint256 amountOut, uint256 gasEstimate)",
]);
export const universalRouterAbi = parseAbi(["function execute(bytes commands, bytes[] inputs, uint256 deadline) payable"]);
export const permit2Abi = parseAbi([
  "function allowance(address owner, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
  "function approve(address token, address spender, uint160 amount, uint48 expiration)",
]);

export const tokenUriAbi = parseAbi(["function tokenURI(uint256 id) view returns (string)"]);

// Events of the Core and the controller.
export const engineEventsAbi = parseAbi([
  // Core
  "event CreditBought(uint256 indexed id, address indexed from, uint256 cost, uint256 toArtist)",
  "event EthRateFill(uint256 spent, uint256 rate, uint256 pot)",
  "event ValueRateFill(uint256 spent, uint256 rateBps, uint256 pot)",
  "event BalanceFill(uint256 paid, uint256 toArtist, uint256 available)",
  "event ListingBought(uint256 indexed id, address indexed adapter, address indexed caller, uint256 cost, uint256 paid, uint256 rate, uint256 toArtist)",
  "event CreditAdopted(uint256 indexed id, uint256 cost)",
  "event CreditSwapped(uint256 indexed inId, uint256 indexed outId, address indexed caller, uint256 fee)",
  "event Composed(uint256 indexed sid, uint256[80] ids, uint8 format, uint256 cost, uint256 price, address indexed caller)",
  "event HeldFormatSet(uint256 indexed sid, uint8 format, address indexed caller)",
  "event StatementSoldTo(uint256 indexed sid, address indexed buyer, uint256 price, uint256 toBuyback, uint256 toArtist, uint256 toOperator)",
  "event CreditSold(uint256 indexed id, address indexed buyer, uint256 price, uint256 toArtist, uint256 toOperator)",
  "event StatementRedeemed(uint256 indexed sid, uint256 received)",
  "event Buyback(address indexed caller, uint256 amountIn, uint256 paid)",
  "event FeesAdded(uint256 amount, uint256 toPayee)",
  "event Funded(address indexed from, uint256 amount)",
  "event SettingsSet((uint16 dropPer100PointsBps, uint16 dropFloorBps, uint16 climbPerMinBps, uint16 ceilBps, uint16 idleLoosenBps, uint16 saleFloorBps, uint16 saleToBuybackBps, uint16 recoveryClimbPerMinBps, uint16 recoveryGapBps, uint32 peakHalfLife, uint16 buybackDelay, bool redeemOn, bool balanceBidOn, uint16 redeemSlippageBps, uint16 balanceBidMarginBps, uint16 redeemBurnBps, uint128 buybackSlice, uint64 keeperFee, uint48 keeperMaxBaseFee, uint64 rateCap, uint64 callerFee, uint48 callerMaxBaseFee, uint16 feeToRedeemBurnBps, uint24 payeePpm, uint32 pointsPerPage, uint96 swapFeeCc, uint16 saleToArtistBps, uint16 saleToOperatorBps, uint16 climbMultiplierCapBps, uint16 spendCapBps, uint32 bucketSeconds, uint32 balanceBidCapBps, uint32 idleStepSeconds, uint32 sniperSeconds, uint64 reserveWei, uint32 returnLockSeconds, bool valueModeOn, uint16 buyToArtistBps, uint16 balanceDiscountBps) settings)",
  "event PausedSet(bool paused)",
  "event PayeeSet(address indexed payee)",
  "event ArtistSet(address indexed artist)",
  "event ControllerSet(address controller)",
  "event BalanceModuleSet(address balanceModule, address balanceToken, uint256 unitPerPoint)",
  // ControllerV1
  "event Bought(uint256 indexed sid, address indexed buyer, uint256 price)",
  "event AnchorMoved(uint256 indexed sid, uint256 saleBps, uint32 anchorBps)",
  // ControllerV2 (the Bought event is shared)
  "event StatementSalesSet(bool enabled)",
  "event StatementSaleMultiplierSet(uint32 multiplierBps)",
  "event StatementRedeemDelaySet(uint32 delaySeconds)",
]);

// The coin burn is Transfer(core, address(0), amount); the balance token paid to a seller is Transfer(core, seller, amount).
export const transferEventAbi = parseAbi(["event Transfer(address indexed from, address indexed to, uint256 value)"]);

// keeper reads: the listing adapters, the CreditStrategy, Seaport 1.6 order status, the fee escrow, the factory launch
// record (DeploymentInfoV2, src/interfaces/ArtCoinsV2.sol)
export const listingAdapterAbi = parseAbi([
  "function price(uint256 id, bytes params) view returns (address target, uint256 value, bytes data, address offerer)",
  "function allowedRecipient(address a) view returns (bool)",
]);
export const creditStrategyAbi = parseAbi(["function nftForSale(uint256 id) view returns (uint256)"]);
export const seaportAbi = parseAbi([
  "function getOrderStatus(bytes32 orderHash) view returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize)",
]);
export const escrowAbi = parseAbi(["function balances(address feeOwner, address token) view returns (uint256)"]);
export const factoryAbi = parseAbi([
  "function deploymentInfo(address token) view returns ((address token, address hook, address locker, address mevModule, address escrow, bytes32 poolId, bytes32 configHash, uint16 version, uint40 launchedAt, bool restricted, address[] extensions))",
]);
// The Splits v2 push split (0xSplits/splits-contracts-monorepo, src/splitters/push/PushSplit.sol and
// src/libraries/SplitV2.sol): the keeper's distributeSplit door calls `distribute` with the split's stored
// configuration, the token (the zero address for ETH) and itself as the distributor, which earns
// `distributionIncentive / 1e6` of the amount. The split keeps only the hash of its configuration, so the keeper's
// SPLIT_RECIPIENTS, SPLIT_ALLOCATIONS, SPLIT_TOTAL_ALLOCATION and SPLIT_DISTRIBUTION_INCENTIVE must match it exactly or
// the call reverts InvalidSplit. Caveat: check the deployed split's version against this ABI before enabling the door.
// A Splits v1 SplitMain split (`distributeETH(address, address[], uint32[], uint32, address)` on the shared SplitMain)
// and a v2 pull split have different interfaces and must not be configured here.
export const splitV2Abi = parseAbi([
  "struct Split { address[] recipients; uint256[] allocations; uint256 totalAllocation; uint16 distributionIncentive; }",
  "function distribute(Split split, address token, address distributor)",
  "function splitHash() view returns (bytes32)",
  "function paused() view returns (bool)",
  "event SplitDistributed(address indexed token, address indexed distributor, uint256 amount)",
  "error InvalidSplit()",
  "error Paused()",
]);
// the traitsOf mask bit mapping (bit 0 C, 1 M, 2 Y, 3 K) was checked against the local fork: the decoded masks match
// the Credits tokenURI "Colors" trait for ids 1 to 8.
export const scoreAbi = parseAbi([
  "function scoreOf(bytes21 seed, uint64 paidAt) view returns (uint256)",
  "function traitsOf(bytes21 seed, uint64 paidAt) view returns (uint256 mask, uint256 active, uint256 occupied, uint256 eights, uint256 band)",
]);
export const seedAbi = parseAbi(["function seedOf(uint256 id) view returns (bytes21)", "function timestampOf(uint256 id) view returns (uint64)"]);
export const multicallAbi = parseAbi(["function getEthBalance(address a) view returns (uint256)", "function getBlockNumber() view returns (uint256)"]);
export const moduleAbi = parseAbi(["function unitPerPoint() view returns (uint256)", "function available() view returns (uint256)"]);

// ---- treasury v2 and redeemer 1 (phase 3, web/) ------------------------------------------------------------------
// The Core's balance module after the phase 3 migration (out/BalanceTreasuryV2.sol). A separate export so the phase 2
// treasuryAbi above keeps working against the live v1 treasury: the web reads core.balanceModule() and detects v2 by
// probing bidBpsNow() (a view v1 does not have). Only the surface web/ reads: the $BALANCE bid (quoteCredit/sellCredit
// with bidBpsNow/bidBudget), redeemer 1 (redeemers/proRataRedeemer/redeemCC) and the receipt events and errors.
export const treasuryV2Abi = parseAbi([
  // $BALANCE bid (the treasury's own bid, separate from the Core's balanceBidOf 80% exchange)
  "function quoteCredit(uint256 id) view returns (uint256 paid, uint256 toArtist)",
  "function sellCredit(uint256[] ids, uint256 minOut) returns (uint256 total)",
  "function bidEnabled() view returns (bool)",
  "function bidBpsNow() view returns (uint256)",
  "function bidBudget() view returns (uint256)",
  "function available() view returns (uint256)",
  "function working() view returns (uint256)",
  "function conversionToClaimBps() view returns (uint16)",
  "function paused() view returns (bool)",
  // pluggable CC burn; redeemer 1 is proRataRedeemer()
  "function proRataRedeemer() view returns (address)",
  "function redeemers(address redeemer) view returns ((bool registered, bool on, uint16 shareBps, uint64 epoch, uint40 activeAt, uint40 periodStart, uint128 perCall, uint128 perPeriod, uint128 lifetime, uint128 periodUsed, uint128 lifetimeUsed, uint256 bucket, uint256 totalIn, uint256 totalOut))",
  "function redeemCC(address redeemer, uint256 ccIn, address recipient, uint256 minOut, uint256 deadline, uint64 expectedEpoch, bytes data) returns (uint256 amount, uint256 claimId)",
  // shared module views
  "function unitPerPoint() view returns (uint256)",
  "function balanceToken() view returns (address)",
  "function ccToken() view returns (address)",
  "function core() view returns (address)",
  "function selected() view returns (bool)",
  "function migrated() view returns (bool)",
  // receipts the web decodes
  "event BidFill(address indexed seller, uint256 credits, uint256 paid, uint256 toArtist, uint256 bidBudget)",
  "event CCRedeemed(address indexed redeemer, address indexed burner, address indexed recipient, uint256 ccIn, uint256 amount, uint8 mode, uint32 duration, uint256 claimId, uint64 epoch)",
  // errors a simulation decodes
  "error BidOff()",
  "error BidUnpriced()",
  "error Paused()",
  "error ReturnLocked(uint256 id)",
  "error NotInPile(uint256 id)",
  "error NotOwner(uint256 id)",
  "error Slippage()",
  "error StaleEpoch()",
  "error RedemptionOff()",
  "error InsufficientBucket()",
  "error OverCap()",
  "error Expired()",
  "error BurnMismatch()",
  "error Insolvent()",
  "error UnknownRedeemer()",
  "error ZeroAmount()",
]);

// redeemer 1 (out/ProRataRedeemer.sol): its fee only. the quote is pure (web/lib/v2.ts proRataV2Quote) and equals the
// treasury payout floor(ccIn * bucket / ccSupply) less feeBps.
export const redeemerV2Abi = parseAbi(["function feeBps() view returns (uint16)"]);

export const strategyAbi = parseAbi([
  "event NFTBoughtByProtocol(uint256 indexed tokenId, uint256 purchasePrice, uint256 listPrice)",
  "event NFTSoldByProtocol(uint256 indexed tokenId, uint256 price, address buyer)",
  "function nftForSale(uint256 id) view returns (uint256)",
]);

export const seaportAdapterAbi = parseAbi(["function allowedRecipient(address recipient) view returns (bool)"]);

// Seaport BasicOrderParameters (src/interfaces/ISeaport.sol), the `params` of SeaportBasicAdapter.
export const basicOrderParameters = [
  {
    type: "tuple",
    components: [
      { name: "considerationToken", type: "address" },
      { name: "considerationIdentifier", type: "uint256" },
      { name: "considerationAmount", type: "uint256" },
      { name: "offerer", type: "address" },
      { name: "zone", type: "address" },
      { name: "offerToken", type: "address" },
      { name: "offerIdentifier", type: "uint256" },
      { name: "offerAmount", type: "uint256" },
      { name: "basicOrderType", type: "uint8" },
      { name: "startTime", type: "uint256" },
      { name: "endTime", type: "uint256" },
      { name: "zoneHash", type: "bytes32" },
      { name: "salt", type: "uint256" },
      { name: "offererConduitKey", type: "bytes32" },
      { name: "fulfillerConduitKey", type: "bytes32" },
      { name: "totalOriginalAdditionalRecipients", type: "uint256" },
      {
        name: "additionalRecipients",
        type: "tuple[]",
        components: [
          { name: "amount", type: "uint256" },
          { name: "recipient", type: "address" },
        ],
      },
      { name: "signature", type: "bytes" },
    ],
  },
] as const;
