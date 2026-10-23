import { index, onchainEnum, onchainTable, type PgColumnsBuilders } from "ponder";

// Conventions: addresses are lowercase hex, amounts are bigint base units (wei for ETH, 18 decimals for $CC,
// balance token units for $BALANCE). Every row written from an event carries blockNumber, blockTimestamp,
// txHash and logIndex. docs/INDEXER.md section 6 is the contract for these tables.

export const creditState = onchainEnum("credit_state", ["outside", "held", "composed", "sold", "swapped_out", "migrated"]);
export const acquiredHow = onchainEnum("acquired_how", ["eth_bid", "balance_bid", "listing", "adopted", "swap_in"]);
export const statementState = onchainEnum("statement_state", ["outside", "held", "sold", "redeemed"]);
export const composeMode = onchainEnum("compose_mode", ["default", "chosen"]);
export const activityKind = onchainEnum("activity_kind", [
  "credit_bought",
  "credit_adopted",
  "listing_bought",
  "credit_swapped",
  "composed",
  "restyled",
  "statement_sold",
  "credit_sold",
  "redeemed",
  "buyback",
  "fees_added",
  "funded",
  "escrow_collected",
]);

/** Every decoded event of every indexed address. Typed tables are projections of it. args holds bigints as strings. */
export const log = onchainTable(
  "log",
  (t) => ({
    id: t.text().primaryKey(), // txHash:logIndex
    address: t.hex().notNull(),
    contract: t.text().notNull(), // core, controller, treasury, coin, credits, statements, strategy
    event: t.text().notNull(),
    args: t.json().notNull(),
    txFrom: t.hex(), // the transaction's sender: the caller of events that do not name one (a conversion, a refresh)
    blockNumber: t.bigint().notNull(),
    blockTimestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    byEvent: index().on(table.contract, table.event, table.blockNumber),
  }),
);

/** Facts shared by ordered handlers in one transaction. Ponder rolls this row back with the event that wrote it. */
export const transactionFact = onchainTable("transaction_fact", (t) => ({
  id: t.hex().primaryKey(), // transaction hash
  ethFillPending: t.boolean().notNull().default(false),
  balanceBuyId: t.bigint(),
  balanceBuyActivityId: t.text(),
  coreBurn: t.bigint().notNull().default(0n),
}));

/**
 * One row per Core. Address and flag columns follow the matching setter event. Values read at the first Core
 * event (constructor values emit no event) are creditCostToPotBps, chosenComposeOn, minCcToChoose, artist,
 * owner, payee, coin. The latest snapshot columns mirror the newest engine_snapshot row.
 */
export const engine = onchainTable("engine", (t) => ({
  id: t.hex().primaryKey(), // core address
  core: t.hex().notNull(),
  controller: t.hex(),
  coin: t.hex(),
  balanceModule: t.hex(),
  balanceToken: t.hex(),
  owner: t.hex(),
  pendingOwner: t.hex(),
  payee: t.hex(),
  artist: t.hex(),
  successor: t.hex(),
  paused: t.boolean().notNull().default(false),
  retired: t.boolean().notNull().default(false),
  controllerLocked: t.boolean().notNull().default(false),
  balanceModuleLocked: t.boolean().notNull().default(false),
  adaptersLocked: t.boolean().notNull().default(false),
  successorLocked: t.boolean().notNull().default(false),
  chosenComposeOn: t.boolean().notNull().default(false),
  payeeOn: t.boolean().notNull().default(false),
  settings: t.json(), // full Settings struct, bigints as strings
  saleToArtistBps: t.integer(),
  saleToOperatorBps: t.integer(),
  saleToBuybackBps: t.integer(),
  feeToRedeemBurnBps: t.integer(),
  payeePpm: t.integer(),
  buyToArtistBps: t.integer(), // the artist royalty on every purchase, bps of the amount paid (decision 163)
  balanceDiscountBps: t.integer(), // the balance bid's discount to par, bps (decision 164)
  creditCostToPotBps: t.integer(),
  minCcToChoose: t.bigint(),
  lastBuybackBlock: t.bigint(),
  ethPot: t.bigint(),
  ethToBuyback: t.bigint(),
  ethRedeemBurn: t.bigint(),
  ethRate: t.bigint(),
  floorRate: t.bigint(),
  balanceRate: t.bigint(),
  coreEthBalance: t.bigint(),
  balanceAvailable: t.bigint(),
  pileSize: t.bigint(),
  snapshotBlock: t.bigint(),
  pileSeq: t.bigint().notNull().default(0n), // last assigned credit.pileOrder
  deployBlock: t.bigint().notNull(),
}));

/** One row per snapshot block: every block with an engine event, plus every 300th block. */
export const engineSnapshot = onchainTable("engine_snapshot", (t) => ({
  blockNumber: t.bigint().primaryKey(),
  blockTimestamp: t.bigint().notNull(),
  ethPot: t.bigint().notNull(),
  ethToBuyback: t.bigint().notNull(),
  ethRedeemBurn: t.bigint().notNull(),
  ethRate: t.bigint().notNull(),
  floorRate: t.bigint().notNull(),
  balanceRate: t.bigint().notNull(),
  coreEthBalance: t.bigint().notNull(),
  balanceAvailable: t.bigint(),
  balanceToken: t.hex(), // the token balanceAvailable is denominated in at this block; changes at BalanceModuleSet
  pileSize: t.bigint().notNull(),
  payeeOn: t.boolean().notNull(),
  paused: t.boolean().notNull(),
  // phase 2, null where the read fails or the contract lacks it (ControllerV1, no module): value mode's protected
  // ETH value per point for the bid (buy) and the sale (sell), the controller's stored reference and live pool spot
  // (wei per 1e18 BALANCE units), the module's BALANCE holding, working funds and claim reserve, and the $CC supply
  valueBuy: t.bigint(),
  valueSell: t.bigint(),
  referencePrice: t.bigint(),
  spotPrice: t.bigint(),
  treasuryBalance: t.bigint(),
  treasuryWorking: t.bigint(),
  claimReserve: t.bigint(),
  ccSupply: t.bigint(),
}));

/** One row per setter, lock or ownership event. before and after hold the changed values as json. */
export const settingChange = onchainTable(
  "setting_change",
  (t) => ({
    id: t.text().primaryKey(), // txHash:logIndex
    source: t.text().notNull(), // core or controller
    name: t.text().notNull(), // event name
    before: t.json(),
    after: t.json(),
    blockNumber: t.bigint().notNull(),
    blockTimestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({ byName: index().on(table.name, table.blockNumber) }),
);

/** One row per controller named by ControllerSet. Parameters are read at its ControllerSet block and follow its setter events. */
export const controller = onchainTable("controller", (t) => ({
  id: t.hex().primaryKey(), // controller address
  setBlock: t.bigint().notNull(),
  active: t.boolean().notNull(),
  markupBps: t.integer(),
  startCapBps: t.bigint(),
  decayHours: t.integer(),
  anchorHalfLife: t.bigint(),
  anchorMinCost: t.bigint(),
  saleOn: t.boolean(),
  ageEligibilityOn: t.boolean(),
  window: t.bigint(),
  spreadBps: t.integer(),
  startBps: t.bigint(),
  anchorBps: t.bigint(), // stored value, decays with anchorHalfLife from anchorBlock
  anchorBlock: t.bigint(),
  balancePoolSet: t.boolean().notNull().default(false),
  balanceCurrency0: t.hex(),
  balanceCurrency1: t.hex(),
  balanceFee: t.integer(),
  balanceTickSpacing: t.integer(),
  balanceHooks: t.hex(),
  // the reference price (decision 148): the reference price settings (QuoteSet) and the reference of the balance token
  // with the pool spot it moved toward, wei per 1e18 base units, at the last ReferenceRefreshed
  referenceRateBpsPerHour: t.bigint(),
  referenceStepBps: t.integer(),
  referenceTolBps: t.integer(),
  referenceMaxStale: t.bigint(),
  referenceMinSeconds: t.bigint(),
  referenceMinLiquidity: t.bigint(),
  referencePrice: t.bigint(),
  referenceSpot: t.bigint(),
  referenceTime: t.bigint(),
  // ControllerV2 statement sale terms (StatementSalesSet, StatementSaleMultiplierSet, StatementRedeemDelaySet), read
  // at ControllerSet and following the setter events; null on a V1 controller
  statementSalesEnabled: t.boolean(),
  statementSaleMultiplierBps: t.bigint(),
  statementRedeemDelaySeconds: t.bigint(),
}));

// ---- phase 2 treasury (src/adapters/Phase2BalanceTreasury.sol) ---------------------------------------------------

export const treasuryEventKind = onchainEnum("treasury_event_kind", [
  "statement_converted", // StatementConverted: amount received, detail allocated/toProRata and contributionBps
  "cc_redeemed", // CCRedeemed, a public burn: ccIn, balanceOut, actor the burner; v2 also carries redeemer, mode, claimId
  "claims_funded", // ClaimsFunded (phase 2): an owner transfer into the claim reserve: amount, actor the funder
  "claims_allocated", // ClaimsAllocated (phase 2): an owner reclassification of working funds as backing: amount
  "claims_returned", // ClaimsReturned (phase 2): an owner reduction of backing while redemption is off: amount, configEpoch
  "working_withdrawn", // WorkingWithdrawn, an owner withdrawal of free working funds: amount, actor the recipient
  "policy_set", // RedemptionPolicySet (phase 2): policy, configEpoch
  "fee_set", // RedemptionFeeSet (phase 2): bps, configEpoch
  "switches_set", // SwitchesSet: detail the three switches (phase 2 ccRedemption; v2 bid)
  "contribution_set", // ConversionToClaimBpsSet: bps
  "minimum_working_set", // MinimumWorkingBalanceSet (phase 2): amount
  "payment_accrued", // PaymentAccrued, a short or failed working payment recorded as debt: amount, actor the payee
  "owed_claimed", // OwedClaimed: amount, actor the payee
  "migrated_out", // TreasuryMigrated (phase 2): amount moved, detail claimsImported, actor the successor, configEpoch
  "migration_received", // MigrationReceived: amount claimsImported, actor the predecessor; v2 detail custody
  // phase 3 (BalanceTreasuryV2)
  "bid_fill", // BidFill: a $BALANCE bid call. amount the seller payout, detail credits/toArtist/bidBudget, actor the seller
  "swept", // Swept: surplus moved into the bid budget and redeemer buckets. detail surplus/toBid/toBuckets
  "allocated", // Allocated: owner surplus into a redeemer's bucket. redeemer, amount
  "unallocated", // Unallocated: owner surplus out of a redeemer's bucket. redeemer, amount
  "redeemer_registered", // RedeemerRegistered: redeemer, detail activeAt
  "redeemer_caps_set", // RedeemerCapsSet: redeemer, configEpoch, detail perCall/perPeriod/lifetime
  "redeemer_switched", // RedeemerSwitched: redeemer, detail on
  "shares_set", // SharesSet: redeemer, bps the redeemer's share, detail bidShareBps/totalShareBps
  "claim_released", // ClaimReleased: a vesting or deferred claim paid out. amount, recipient, detail claimId
  "cushion_set", // CushionSet: amount the reserved cushion
  "paused_set", // PausedSet (v2): detail paused
  "bid_set", // BidSet (v2): detail the bid parameters tuple
]);

/**
 * One row per treasury event, the projection of the treasury's `log` rows. Public redemptions (cc_redeemed) and the
 * owner's reserve changes (claims_funded, claims_allocated, claims_returned, working_withdrawn) are separate kinds.
 * claimReserve is the reserve after the event where the event carries it. amount is in balance token base units.
 */
export const treasuryEvent = onchainTable(
  "treasury_event",
  (t) => ({
    id: t.text().primaryKey(), // txHash:logIndex
    treasury: t.hex().notNull(),
    kind: treasuryEventKind("kind").notNull(),
    ccIn: t.bigint(), // CC burned, 18 decimals
    balanceOut: t.bigint(), // balance token paid to the burn's recipient
    claimReserve: t.bigint(),
    ccSupply: t.bigint(), // CC total supply after the burn
    configEpoch: t.bigint(),
    amount: t.bigint(),
    bps: t.integer(),
    actor: t.hex(), // burner, funder, recipient, payee, successor or predecessor per kind
    recipient: t.hex(), // cc_redeemed: where the balance token went
    redeemer: t.hex(), // phase 3 redeemer-scoped events (allocated, unallocated, redeemer_*, shares_set, cc_redeemed)
    policy: t.hex(),
    statementId: t.bigint(),
    detail: t.json(), // the remaining event fields, bigints as strings
    blockNumber: t.bigint().notNull(),
    blockTimestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    byTreasury: index().on(table.treasury, table.blockNumber),
    byKind: index().on(table.kind, table.blockNumber),
    byActor: index().on(table.actor),
    byRedeemer: index().on(table.redeemer),
  }),
);

/**
 * One row per treasury named by BalanceModuleSet, written from events only (no latest-state read). A column is null
 * until an event after the treasury's registration carries it: the constructor's RedemptionPolicySet and any event
 * before BalanceModuleSet are not indexed, so policy and configEpoch fill at the next policy, fee, claim return or
 * migration event. The web reads the live values through the treasury (docs/INDEXER.md section 9.6).
 */
export const treasuryState = onchainTable("treasury_state", (t) => ({
  id: t.hex().primaryKey(), // treasury address
  version: t.text(), // "phase2", "v2" or null (a StatementBalanceModule), detected at BalanceModuleSet
  balanceToken: t.hex().notNull(), // BalanceModuleSet.balanceToken
  setBlock: t.bigint().notNull(),
  active: t.boolean().notNull(), // the Core's current module
  claimReserve: t.bigint(), // phase 2: the latest event-carried reserve; 0 after TreasuryMigrated. v2 has per-redeemer buckets
  totalOwed: t.bigint().notNull().default(0n), // PaymentAccrued less OwedClaimed since registration
  configEpoch: t.bigint(),
  policy: t.hex(), // phase 2 only
  conversionToClaimBps: t.integer(),
  redemptionFeeBps: t.integer(), // phase 2 only (v2's fee lives in the ProRataRedeemer)
  conversionEnabled: t.boolean(),
  workingPaymentsEnabled: t.boolean(),
  ccRedemptionEnabled: t.boolean(), // phase 2 SwitchesSet third switch; null on v2
  bidEnabled: t.boolean(), // v2 SwitchesSet third switch; null on phase 2
  paused: t.boolean(), // v2 PausedSet
  minimumWorkingBalance: t.bigint(), // phase 2 only
  migrated: t.boolean().notNull().default(false),
  successor: t.hex(),
  // phase 3 (BalanceTreasuryV2) state and earmarks; the web reads the current working, committed and per-redeemer
  // bucket balances live (docs/INDEXER.md section 9.6), these are the event-carried values and cumulative totals
  proRataRedeemer: t.hex(), // the shipped redeemer 1 (read at registration)
  cushion: t.bigint(), // CushionSet: working funds reserved for the Core's 80% exchange
  bidBudget: t.bigint(), // the $BALANCE bid budget, from BidFill (after-value) and Swept.toBid
  bidShareBps: t.integer(), // SharesSet: the bid's share of a sweep
  totalShareBps: t.integer(), // SharesSet: the sum of the bid and redeemer shares
  // running totals since registration
  convertedTotal: t.bigint().notNull().default(0n), // StatementConverted.received
  contributedTotal: t.bigint().notNull().default(0n), // StatementConverted allocated (phase 2) / toProRata (v2)
  conversions: t.bigint().notNull().default(0n),
  redeemedCcTotal: t.bigint().notNull().default(0n), // CCRedeemed.ccIn
  paidBalanceTotal: t.bigint().notNull().default(0n), // CCRedeemed balanceOut (phase 2) / amount (v2)
  redemptions: t.bigint().notNull().default(0n),
  ownerFundedTotal: t.bigint().notNull().default(0n), // ClaimsFunded.amount (phase 2)
  ownerAllocatedTotal: t.bigint().notNull().default(0n), // ClaimsAllocated.amount (phase 2)
  ownerReturnedTotal: t.bigint().notNull().default(0n), // ClaimsReturned.amount (phase 2)
  ownerWithdrawnTotal: t.bigint().notNull().default(0n), // WorkingWithdrawn.amount
  accruedTotal: t.bigint().notNull().default(0n), // PaymentAccrued.amount
  claimedTotal: t.bigint().notNull().default(0n), // OwedClaimed.amount
  // phase 3 bid and sweep totals
  bidInTotal: t.bigint().notNull().default(0n), // Swept.toBid, cumulative funding into the bid budget
  bidOutTotal: t.bigint().notNull().default(0n), // BidFill paid plus toArtist, cumulative paid out of the bid budget
  bidFills: t.bigint().notNull().default(0n), // BidFill count
  bidCreditsTotal: t.bigint().notNull().default(0n), // BidFill.credits, credits bought by the bid
  sweptSurplusTotal: t.bigint().notNull().default(0n), // Swept.surplus
  bucketsFundedTotal: t.bigint().notNull().default(0n), // Swept.toBuckets
  allocatedTotal: t.bigint().notNull().default(0n), // Allocated.amount, owner surplus into buckets
  unallocatedTotal: t.bigint().notNull().default(0n), // Unallocated.amount
  claimReleasedTotal: t.bigint().notNull().default(0n), // ClaimReleased.amount
  lastEventBlock: t.bigint(),
}));

/**
 * One row per redeemer the phase 3 treasury (BalanceTreasuryV2) has registered. The registry, switch, caps and
 * share are projected from events; the current bucket balance and the live cumulative in/out come from the chain
 * (treasury.redeemers(address): bucket, totalIn, totalOut) because a sweep funds buckets in a lump by share with no
 * per-redeemer breakdown in the event (docs/INDEXER.md section 9.6). The running totals here are the event-derived
 * redemption and allocation history. A redeemer is scoped to its treasury (a later treasury re-registers its own).
 * Redeemer 2 (MarketRedeemer) also projects its `premiumBps` / `premiumEpoch` here from its own PremiumSet event.
 */
export const redeemer = onchainTable(
  "redeemer",
  (t) => ({
    id: t.text().primaryKey(), // treasury:redeemer
    treasury: t.hex().notNull(),
    redeemer: t.hex().notNull(),
    registered: t.boolean().notNull().default(false),
    on: t.boolean().notNull().default(false), // the switch, off by default
    activeAt: t.bigint(), // RedeemerRegistered.activeAt, the earliest draw time
    epoch: t.bigint(), // RedeemerCapsSet.epoch, the caps configuration epoch
    shareBps: t.integer(), // SharesSet: this redeemer's share of a sweep
    perCall: t.bigint(), // RedeemerCapsSet caps
    perPeriod: t.bigint(),
    lifetime: t.bigint(),
    premiumBps: t.integer(), // redeemer 2 (MarketRedeemer) only: PremiumSet.premiumBps, the spread over the market rate
    premiumEpoch: t.bigint(), // redeemer 2 only: PremiumSet.configEpoch, the premium's epoch (distinct from the caps `epoch`)
    redeemedCcTotal: t.bigint().notNull().default(0n), // CCRedeemed.ccIn to this redeemer
    paidBalanceTotal: t.bigint().notNull().default(0n), // CCRedeemed.amount through this redeemer
    redemptions: t.bigint().notNull().default(0n),
    allocatedTotal: t.bigint().notNull().default(0n), // Allocated.amount into this redeemer's bucket
    unallocatedTotal: t.bigint().notNull().default(0n), // Unallocated.amount
    claimReleasedTotal: t.bigint().notNull().default(0n), // ClaimReleased.amount for claims this redeemer created
    firstBlock: t.bigint().notNull(),
    lastEventBlock: t.bigint().notNull(),
  }),
  (table) => ({ byTreasury: index().on(table.treasury) }),
);

/**
 * One row per Credits token id. Fixed facts (seed to tokenUri) are read once, at the latest block, when the id is
 * first seen. owner follows the Credits Transfer log. pileOrder is non-null exactly while state = held.
 */
export const credit = onchainTable(
  "credit",
  (t) => ({
    id: t.bigint().primaryKey(),
    seed: t.hex().notNull(),
    paidAt: t.bigint().notNull(),
    score: t.bigint().notNull(), // ten-thousandths of a point
    rating: t.text().notNull(), // score / 10000 as a decimal string
    mask: t.integer().notNull(), // bit0 C, bit1 M, bit2 Y, bit3 K; a set bit is a printed plate
    active: t.integer().notNull(),
    occupied: t.integer().notNull(),
    eights: t.integer().notNull(),
    band: t.integer().notNull(),
    owner: t.hex(),
    state: creditState("state").notNull(),
    costBasis: t.bigint(),
    acquiredAt: t.bigint(),
    acquiredBlock: t.bigint(),
    acquiredTx: t.hex(),
    acquiredHow: acquiredHow("acquired_how"),
    seller: t.hex(),
    royalty: t.bigint(), // artist amount assigned at acquisition; BALANCE royalties may be claimable module debt
    balancePaid: t.bigint(), // BalanceFill.paid, the seller's payout in balancePaidToken's base units
    balancePaidToken: t.hex(), // the balance token active at the sale; changes at BalanceModuleSet
    pileOrder: t.bigint(), // insertion sequence; a swap-in takes the out credit's value
    statementId: t.bigint(),
    pagePosition: t.integer(),
    salePrice: t.bigint(),
    buyer: t.hex(),
    toArtist: t.bigint(),
    toOperator: t.bigint(),
    toPot: t.bigint(),
    toBuyback: t.bigint(),
    costToPotBps: t.integer(),
    tokenUri: t.text(),
  }),
  (table) => ({
    byOwner: index().on(table.owner),
    byState: index().on(table.state, table.pileOrder),
  }),
);

/** One row per Statements token id. state = outside until the Core composes it. */
export const statement = onchainTable(
  "statement",
  (t) => ({
    id: t.bigint().primaryKey(),
    state: statementState("state").notNull(),
    owner: t.hex(),
    composedAt: t.bigint(),
    composedBlock: t.bigint(),
    composeTx: t.hex(),
    composer: t.hex(),
    mode: composeMode("mode"), // null for a compose through another contract
    cost: t.bigint(),
    composePrice: t.bigint(),
    rating: t.bigint(), // Statements.creditScoreOf, ten-thousandths of a point
    format: t.integer(),
    salePrice: t.bigint(),
    buyer: t.hex(),
    toBuyback: t.bigint(),
    toArtist: t.bigint(),
    toOperator: t.bigint(),
    toPot: t.bigint(),
    redeemedReceived: t.bigint(),
    tokenUri: t.text(), // refreshed after HeldFormatSet
    formatName: t.text(), // Format trait of the token metadata
  }),
  (table) => ({ byState: index().on(table.state), byOwner: index().on(table.owner) }),
);

/** The 80 credits of a composed statement, position 0..79 in pile order. */
export const statementCredit = onchainTable("statement_credit", (t) => ({
  id: t.text().primaryKey(), // statementId:position
  statementId: t.bigint().notNull(),
  position: t.integer().notNull(),
  creditId: t.bigint().notNull(),
}), (table) => ({ byStatement: index().on(table.statementId), byCredit: index().on(table.creditId) }));

export const statementFormat = onchainTable("statement_format", (t) => ({
  id: t.text().primaryKey(), // txHash:logIndex
  statementId: t.bigint().notNull(),
  from: t.integer().notNull(),
  to: t.integer().notNull(),
  caller: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  blockTimestamp: t.bigint().notNull(),
  txHash: t.hex().notNull(),
  logIndex: t.integer().notNull(),
}), (table) => ({ byStatement: index().on(table.statementId) }));

export const anchorMove = onchainTable("anchor_move", (t) => ({
  id: t.text().primaryKey(), // txHash:logIndex
  controller: t.hex().notNull(),
  statementId: t.bigint().notNull(),
  saleBps: t.bigint().notNull(),
  anchorBps: t.bigint().notNull(),
  blockNumber: t.bigint().notNull(),
  blockTimestamp: t.bigint().notNull(),
  txHash: t.hex().notNull(),
  logIndex: t.integer().notNull(),
}), (table) => ({ byStatement: index().on(table.statementId) }));

/**
 * The ledger: one row per user-visible event. amount is ETH wei unless the kind says otherwise.
 * amount2 per kind: credit_bought balance token paid (balance bid) or 0; listing_bought keeper payment;
 * credit_swapped $CC fee; composed listed price; statement_sold toBuyback; credit_sold toPot;
 * redeemed none (amount is the balance token received); buyback $CC burned; fees_added toPayee; others none.
 * account per kind: seller, adapter caller, swap caller, composer, buyer, buyer, none, keeper, none, funder.
 */
export const activity = onchainTable(
  "activity",
  (t) => ({
    id: t.text().primaryKey(), // txHash:logIndex
    kind: activityKind("kind").notNull(),
    creditId: t.bigint(),
    otherCreditId: t.bigint(), // credit_swapped: the credit that left the pile
    statementId: t.bigint(),
    account: t.hex(),
    amount: t.bigint(),
    amount2: t.bigint(),
    balanceToken: t.hex(), // event-time currency for balance purchases and redemption
    blockNumber: t.bigint().notNull(),
    blockTimestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    byKind: index().on(table.kind, table.blockNumber),
    byAccount: index().on(table.account),
    byCredit: index().on(table.creditId),
    byStatement: index().on(table.statementId),
    byOrder: index().on(table.blockNumber, table.logIndex),
  }),
);

const counters = (t: PgColumnsBuilders) => ({
  creditsBought: t.bigint().notNull().default(0n), // credit_bought plus listing_bought plus credit_adopted
  creditsEth: t.bigint().notNull().default(0n),
  creditsBalance: t.bigint().notNull().default(0n),
  creditsListing: t.bigint().notNull().default(0n),
  creditsAdopted: t.bigint().notNull().default(0n),
  creditsSwapped: t.bigint().notNull().default(0n),
  composed: t.bigint().notNull().default(0n),
  restyled: t.bigint().notNull().default(0n),
  statementsSold: t.bigint().notNull().default(0n),
  creditsSold: t.bigint().notNull().default(0n),
  redeemed: t.bigint().notNull().default(0n),
  buybacks: t.bigint().notNull().default(0n),
  ethIntoCredits: t.bigint().notNull().default(0n), // sum of EthRateFill.spent
  feesBooked: t.bigint().notNull().default(0n),
  toPayee: t.bigint().notNull().default(0n),
  toArtist: t.bigint().notNull().default(0n), // the artist cut of sales, wei
  toArtistBuys: t.bigint().notNull().default(0n), // ETH purchase royalties; BALANCE royalties are in balanceCommittedByToken
  toOperator: t.bigint().notNull().default(0n),
  ccBurned: t.bigint().notNull().default(0n), // Core buyback burns plus CreditSwapped.fee
  ethToBuybackSpent: t.bigint().notNull().default(0n), // sum of Buyback.amountIn
  balanceCommittedByToken: t.json().$type<Record<string, string>>().notNull().default({}), // seller payout plus Core-requested artist amount, raw units keyed by token
});

/** Singleton per Core. */
export const stats = onchainTable("stats", (t) => ({ id: t.hex().primaryKey(), ...counters(t) }));

/** The same counters per hour bucket (blockTimestamp / 3600). */
export const statsHourly = onchainTable("stats_hourly", (t) => ({ hour: t.bigint().primaryKey(), ...counters(t) }));

/** Reconciliation result every 300 blocks (docs/INDEXER.md section 8.4). */
export const parity = onchainTable("parity", (t) => ({
  blockNumber: t.bigint().primaryKey(),
  blockTimestamp: t.bigint().notNull(),
  ok: t.boolean().notNull(),
  pileSizeOk: t.boolean().notNull(),
  heldStatementsOk: t.boolean().notNull(),
  pileFirstPageOk: t.boolean().notNull(),
  ethPotOk: t.boolean().notNull(),
  detail: t.json().notNull(), // chain and indexed values compared
}));

/**
 * One row per Credits id the CreditStrategy has listed. active follows NFTBoughtByProtocol (true, listPrice set),
 * NFTSoldByProtocol and a Credits Transfer out of the strategy (false). A price change emits no event; consumers
 * re-read nftForSale(id) for the rows they use.
 */
export const strategyListing = onchainTable(
  "strategy_listing",
  (t) => ({
    id: t.bigint().primaryKey(), // credit id
    listPrice: t.bigint().notNull(), // wei, from the latest NFTBoughtByProtocol
    active: t.boolean().notNull(),
    boughtBlock: t.bigint().notNull(),
    boughtAt: t.bigint().notNull(),
    soldBlock: t.bigint(),
    soldAt: t.bigint(),
    buyer: t.hex(), // NFTSoldByProtocol.buyer; the recipient of the Transfer when that event is absent
  }),
  (table) => ({ byActive: index().on(table.active, table.listPrice) }),
);
