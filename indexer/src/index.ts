import { ponder } from "ponder:registry";
import { zeroAddress, type Hex } from "viem";

import { COLLECTIONS, CORE_ADDRESS, MARKET_REDEEMER, STRATEGY_ADDRESS } from "../ponder.config";
import {
  activity,
  anchorMove,
  controller,
  credit,
  engine,
  settingChange,
  statement,
  redeemer,
  statementCredit,
  statementFormat,
  strategyListing,
  transactionFact,
  treasuryEvent,
  treasuryState,
} from "../ponder.schema";
import { ensureCredit, ensureCredits, ensureEngine, ensureStatement, readController, readTreasury, refreshStatementArt, settingsColumns, snapshot } from "./chain";
import { composeModeOf } from "./lib/mode";
import { CREDIT_TRANSFER_TOPIC, hydrateCreditPeers } from "./lib/credit-peers";
import { creditSaleSplit, statementPot } from "./lib/split";
import { migratedOutPatch, migrationReceivedPatch } from "./lib/migration";
import { act, bump, bumpBalanceCommitted, idOf, lc, posOf, record, toJson, type At, type Ctx } from "./shared";

// Ordered events in one transaction share transactionFact rows so retries and chain rollbacks restore the facts.

// ---- shared steps ---------------------------------------------------------------------------------------------

/** Every Core event: log row, engine row, one snapshot per block. */
async function coreEvent(ctx: Ctx, e: At & { args?: unknown; log: { logIndex: number; address: Hex } }, name: string) {
  await record(ctx, e, "core", name);
  await snapshot(ctx, e.block);
}

/** Applies `patch` to the engine row and records the changed values before and after. */
async function setting(ctx: Ctx, e: At, name: string, patch: Partial<typeof engine.$inferInsert>) {
  const cur = await ensureEngine(ctx);
  const before = Object.fromEntries(Object.keys(patch).map((k) => [k, (cur as Record<string, unknown>)[k] ?? null]));
  await ctx.db.update(engine, { id: CORE_ADDRESS }).set(patch);
  await ctx.db
    .insert(settingChange)
    .values({ id: idOf(e), source: "core", name, before: toJson(before), after: toJson(patch), ...posOf(e) })
    .onConflictDoNothing();
}

/** Setting events whose value has no engine column. */
async function settingValue(ctx: Ctx, e: At, source: "core" | "controller", name: string, before: unknown, after: unknown) {
  await ctx.db
    .insert(settingChange)
    .values({ id: idOf(e), source, name, before: toJson(before ?? null), after: toJson(after), ...posOf(e) })
    .onConflictDoNothing();
}

/** A credit enters the pile at the next pile position. Fields of an earlier stay in the engine are cleared. */
async function enterPile(
  ctx: Ctx,
  e: At,
  id: bigint,
  how: typeof credit.$inferInsert.acquiredHow,
  cost: bigint,
  seller: Hex | null,
  royalty: bigint | null = null,
) {
  await ensureCredit(ctx, id);
  const eng = await ctx.db
    .update(engine, { id: CORE_ADDRESS })
    .set((row) => ({ pileSeq: row.pileSeq + 1n }));
  await ctx.db.update(credit, { id }).set({
    state: "held",
    costBasis: cost,
    acquiredAt: e.block.timestamp,
    acquiredBlock: e.block.number,
    acquiredTx: e.transaction.hash,
    acquiredHow: how,
    seller,
    royalty,
    balancePaid: null,
    pileOrder: eng.pileSeq,
    statementId: null,
    pagePosition: null,
    salePrice: null,
    buyer: null,
    toArtist: null,
    toOperator: null,
    toPot: null,
    toBuyback: null,
    costToPotBps: null,
  });
}

// ---- Core: credits in ----------------------------------------------------------------------------------------

ponder.on("Core:EthRateFill", async ({ event, context }) => {
  await coreEvent(context, event, "EthRateFill");
  await context.db.insert(transactionFact).values({ id: event.transaction.hash, ethFillPending: true }).onConflictDoUpdate({ ethFillPending: true });
  await bump(context, event, { ethIntoCredits: event.args.spent });
});

// value mode (decision 148): an eth fill drops the shared balance instance and logs ValueRateFill in place of EthRateFill
ponder.on("Core:ValueRateFill", async ({ event, context }) => {
  await coreEvent(context, event, "ValueRateFill");
  await context.db.insert(transactionFact).values({ id: event.transaction.hash, ethFillPending: true }).onConflictDoUpdate({ ethFillPending: true });
  await bump(context, event, { ethIntoCredits: event.args.spent });
});

ponder.on("Core:CreditBought", async ({ event, context }) => {
  await coreEvent(context, event, "CreditBought");
  // cost is the pile cost basis (eth bid: the price plus the artist royalty; balance bid: the eth floor basis);
  // toArtist is the royalty in the route's currency (decision 163)
  const { id, from, cost, toArtist } = event.args;
  const fact = await context.db.find(transactionFact, { id: event.transaction.hash });
  const how = fact?.ethFillPending ? "eth_bid" : "balance_bid";
  // the same fields on insert and on conflict: a balance-bid sale has no earlier event in its tx, so the insert is
  // the path that must mark it for the BalanceFill that follows
  const buy = {
    ethFillPending: false,
    balanceBuyId: how === "balance_bid" ? id : null,
    balanceBuyActivityId: how === "balance_bid" ? idOf(event) : null,
  };
  await context.db.insert(transactionFact).values({ id: event.transaction.hash, ...buy }).onConflictDoUpdate(buy);
  await enterPile(context, event, id, how, cost, lc(from), how === "eth_bid" ? toArtist : null);
  await act(context, event, { kind: "credit_bought", creditId: id, account: lc(from), amount: cost, amount2: 0n });
  await bump(context, event, {
    creditsBought: 1n,
    ...(how === "eth_bid" ? { creditsEth: 1n, toArtistBuys: toArtist } : { creditsBalance: 1n }),
  });
});

ponder.on("Core:BalanceFill", async ({ event, context }) => {
  await coreEvent(context, event, "BalanceFill");
  // paid reaches the seller; toArtist is requested from the module, which may record debt instead of transferring.
  const { paid, toArtist } = event.args;
  // This column follows earlier BalanceModuleSet logs, never a latest-state RPC read.
  const { balanceToken } = await ensureEngine(context);
  const fact = await context.db.find(transactionFact, { id: event.transaction.hash });
  if (fact?.balanceBuyId != null && fact.balanceBuyActivityId != null) {
    await context.db
      .update(credit, { id: fact.balanceBuyId })
      .set({ balancePaid: paid, balancePaidToken: balanceToken, royalty: toArtist });
    await context.db.update(activity, { id: fact.balanceBuyActivityId }).set({ amount2: paid, balanceToken });
  }
  if (fact) await context.db.update(transactionFact, { id: event.transaction.hash }).set({ balanceBuyId: null, balanceBuyActivityId: null });
  if (balanceToken) {
    await bumpBalanceCommitted(context, event, balanceToken, paid + toArtist);
  } else {
    console.error(
      `BalanceFill at ${event.transaction.hash} paid ${paid} while engine.balanceToken is null; the commitment is credited to no token`,
    );
  }
});

ponder.on("Core:ListingBought", async ({ event, context }) => {
  await coreEvent(context, event, "ListingBought");
  // cost is the listing price, paid the keeper payment, toArtist the royalty on the price (decision 163); the pile
  // cost basis is the three summed
  const { id, caller, cost, paid, toArtist } = event.args;
  const fact = await context.db.find(transactionFact, { id: event.transaction.hash });
  if (fact) await context.db.update(transactionFact, { id: event.transaction.hash }).set({ ethFillPending: false });
  await enterPile(context, event, id, "listing", cost + toArtist + paid, null, toArtist);
  await act(context, event, {
    kind: "listing_bought",
    creditId: id,
    account: lc(caller),
    amount: cost + toArtist + paid,
    amount2: paid,
  });
  await bump(context, event, { creditsBought: 1n, creditsListing: 1n, toArtistBuys: toArtist });
});

ponder.on("Core:CreditAdopted", async ({ event, context }) => {
  await coreEvent(context, event, "CreditAdopted");
  const { id, cost } = event.args;
  await enterPile(context, event, id, "adopted", cost, null);
  await act(context, event, { kind: "credit_adopted", creditId: id, amount: cost });
  await bump(context, event, { creditsBought: 1n, creditsAdopted: 1n });
});

// The in credit takes the out credit's pile position, cost basis and acquisition time. The event omits them.
ponder.on("Core:CreditSwapped", async ({ event, context }) => {
  await coreEvent(context, event, "CreditSwapped");
  const { inId, outId, caller, fee } = event.args;
  const out = await ensureCredit(context, outId);
  await ensureCredit(context, inId);
  await context.db.update(credit, { id: inId }).set({
    state: "held",
    costBasis: out.costBasis,
    acquiredAt: out.acquiredAt,
    acquiredBlock: event.block.number,
    acquiredTx: event.transaction.hash,
    acquiredHow: "swap_in",
    seller: lc(caller),
    balancePaid: null,
    pileOrder: out.pileOrder,
  });
  await context.db.update(credit, { id: outId }).set({ state: "swapped_out", pileOrder: null });
  await act(context, event, { kind: "credit_swapped", creditId: inId, otherCreditId: outId, account: lc(caller), amount2: fee });
  await bump(context, event, { creditsSwapped: 1n, ccBurned: fee });
});

// ---- Core: credits out, statements --------------------------------------------------------------------------

ponder.on("Core:Composed", async ({ event, context }) => {
  await coreEvent(context, event, "Composed");
  const { sid, ids, format, cost, price, caller } = event.args;
  await ensureStatement(context, sid);
  const mode = composeModeOf(event.transaction.to, CORE_ADDRESS, event.transaction.input);
  await context.db.update(statement, { id: sid }).set({
    state: "held",
    composedAt: event.block.timestamp,
    composedBlock: event.block.number,
    composeTx: event.transaction.hash,
    composer: lc(caller),
    mode,
    cost,
    composePrice: price,
    format,
  });
  await ensureCredits(context, ids);
  for (let i = 0; i < ids.length; i++) {
    await context.db.update(credit, { id: ids[i] }).set({ state: "composed", statementId: sid, pagePosition: i, pileOrder: null });
    await context.db
      .insert(statementCredit)
      .values({ id: `${sid}:${i}`, statementId: sid, position: i, creditId: ids[i] })
      .onConflictDoNothing();
  }
  await act(context, event, { kind: "composed", statementId: sid, account: lc(caller), amount: cost, amount2: price });
  await bump(context, event, { composed: 1n });
});

ponder.on("Core:HeldFormatSet", async ({ event, context }) => {
  await coreEvent(context, event, "HeldFormatSet");
  const { sid, format, caller } = event.args;
  const cur = await ensureStatement(context, sid);
  const art = await refreshStatementArt(context, sid);
  await context.db
    .insert(statementFormat)
    .values({ id: idOf(event), statementId: sid, from: cur.format ?? format, to: format, caller: lc(caller), ...posOf(event) })
    .onConflictDoNothing();
  await context.db.update(statement, { id: sid }).set({ format, ...art });
  await act(context, event, { kind: "restyled", statementId: sid, account: lc(caller) });
  await bump(context, event, { restyled: 1n });
});

ponder.on("Core:StatementSoldTo", async ({ event, context }) => {
  await coreEvent(context, event, "StatementSoldTo");
  const { sid, buyer, price, toBuyback, toArtist, toOperator } = event.args;
  await ensureStatement(context, sid);
  await context.db.update(statement, { id: sid }).set({
    state: "sold",
    salePrice: price,
    buyer: lc(buyer),
    toBuyback,
    toArtist,
    toOperator,
    toPot: statementPot(price, toArtist, toOperator, toBuyback),
  });
  await act(context, event, { kind: "statement_sold", statementId: sid, account: lc(buyer), amount: price, amount2: toBuyback });
  await bump(context, event, { statementsSold: 1n, toArtist, toOperator });
});

ponder.on("Core:CreditSold", async ({ event, context }) => {
  await coreEvent(context, event, "CreditSold");
  const { id, buyer, price, toArtist, toOperator } = event.args;
  const c = await ensureCredit(context, id);
  const eng = await ensureEngine(context);
  const bps = eng.creditCostToPotBps ?? 0;
  const split = creditSaleSplit(price, c.costBasis ?? 0n, toArtist, toOperator, BigInt(bps));
  await context.db.update(credit, { id }).set({
    state: "sold",
    pileOrder: null,
    salePrice: price,
    buyer: lc(buyer),
    toArtist,
    toOperator,
    toPot: split.toPot,
    toBuyback: split.toBuyback,
    costToPotBps: bps,
  });
  await act(context, event, { kind: "credit_sold", creditId: id, account: lc(buyer), amount: price, amount2: split.toPot });
  await bump(context, event, { creditsSold: 1n, toArtist, toOperator });
});

ponder.on("Core:StatementRedeemed", async ({ event, context }) => {
  await coreEvent(context, event, "StatementRedeemed");
  const { sid, received } = event.args;
  const { balanceToken } = await ensureEngine(context);
  await ensureStatement(context, sid);
  await context.db.update(statement, { id: sid }).set({ state: "redeemed", redeemedReceived: received });
  await act(context, event, { kind: "redeemed", statementId: sid, amount: received, balanceToken });
  await bump(context, event, { redeemed: 1n });
});

// ---- Core: money ----------------------------------------------------------------------------------------------

ponder.on("Core:Buyback", async ({ event, context }) => {
  await coreEvent(context, event, "Buyback");
  const { caller, amountIn } = event.args;
  const fact = await context.db.find(transactionFact, { id: event.transaction.hash });
  const burned = fact?.coreBurn ?? 0n;
  if (fact) await context.db.update(transactionFact, { id: event.transaction.hash }).set({ coreBurn: 0n });
  await context.db.update(engine, { id: CORE_ADDRESS }).set({ lastBuybackBlock: event.block.number });
  await act(context, event, { kind: "buyback", account: lc(caller), amount: amountIn, amount2: burned });
  await bump(context, event, { buybacks: 1n, ethToBuybackSpent: amountIn });
});

ponder.on("Core:FeesAdded", async ({ event, context }) => {
  await coreEvent(context, event, "FeesAdded");
  const { amount, toPayee } = event.args;
  await act(context, event, { kind: "fees_added", amount, amount2: toPayee });
  await bump(context, event, { feesBooked: amount, toPayee });
});

ponder.on("Core:Funded", async ({ event, context }) => {
  await coreEvent(context, event, "Funded");
  await act(context, event, { kind: "funded", account: lc(event.args.from), amount: event.args.amount });
});

ponder.on("Core:EscrowCollected", async ({ event, context }) => {
  await coreEvent(context, event, "EscrowCollected");
  await act(context, event, { kind: "escrow_collected", amount: event.args.amount });
});

// ---- Core: settings, authority ---------------------------------------------------------------------------------

ponder.on("Core:SettingsSet", async ({ event, context }) => {
  await coreEvent(context, event, "SettingsSet");
  await setting(context, event, "SettingsSet", settingsColumns(event.args.settings));
});

ponder.on("Core:RateSet", async ({ event, context }) => {
  await coreEvent(context, event, "RateSet");
  const cur = await ensureEngine(context);
  await settingValue(context, event, "core", "RateSet", { ethRate: cur.ethRate }, { rate: event.args.rate });
});

ponder.on("Core:BalanceRateSet", async ({ event, context }) => {
  await coreEvent(context, event, "BalanceRateSet");
  // BalanceRateSet reports value mode's shared instance reset to the floor, not the posted balance bid rate: the
  // balance bid is 10_000 - balanceDiscountBps and lives in the balanceRate column, sourced from SettingsSet and the
  // snapshot read (decision 164). record this under a separate shared-rate key so it does not conflate with that column
  await settingValue(context, event, "core", "BalanceRateSet", null, { sharedRateBps: Number(event.args.rateBps) });
});

ponder.on("Core:CreditCostToPotBpsSet", async ({ event, context }) => {
  await coreEvent(context, event, "CreditCostToPotBpsSet");
  await setting(context, event, "CreditCostToPotBpsSet", { creditCostToPotBps: Number(event.args.bps) });
});

ponder.on("Core:ChosenComposeOnSet", async ({ event, context }) => {
  await coreEvent(context, event, "ChosenComposeOnSet");
  await setting(context, event, "ChosenComposeOnSet", { chosenComposeOn: event.args.on });
});

ponder.on("Core:MinCcToChooseSet", async ({ event, context }) => {
  await coreEvent(context, event, "MinCcToChooseSet");
  await setting(context, event, "MinCcToChooseSet", { minCcToChoose: event.args.min });
});

ponder.on("Core:PausedSet", async ({ event, context }) => {
  await coreEvent(context, event, "PausedSet");
  await setting(context, event, "PausedSet", { paused: event.args.paused });
});

ponder.on("Core:PayeeSet", async ({ event, context }) => {
  await coreEvent(context, event, "PayeeSet");
  await setting(context, event, "PayeeSet", { payee: lc(event.args.payee) });
});

ponder.on("Core:ArtistSet", async ({ event, context }) => {
  await coreEvent(context, event, "ArtistSet");
  await setting(context, event, "ArtistSet", { artist: lc(event.args.artist) });
});

ponder.on("Core:BalanceModuleSet", async ({ event, context }) => {
  await coreEvent(context, event, "BalanceModuleSet");
  const { balanceModule, balanceToken, unitPerPoint } = event.args;
  const addr = lc(balanceModule);
  const cur = await ensureEngine(context);
  if (cur.balanceModule && cur.balanceModule !== addr) await context.db.update(treasuryState, { id: cur.balanceModule }).set({ active: false });
  // the treasury_state row of every module, written from events only; a StatementBalanceModule stays at its defaults
  if (addr !== zeroAddress) {
    // the ledger at the selection block seeds the row: the factory discovers the treasury here, so its constructor and
    // preselection events (a policy set, early funding, settings) are not replayed; a StatementBalanceModule answers
    // none and keeps the defaults
    const seeded = (await readTreasury(context, addr as Hex)) ?? {};
    await context.db
      .insert(treasuryState)
      .values({ id: addr, balanceToken: lc(balanceToken), setBlock: event.block.number, active: true, ...seeded })
      .onConflictDoUpdate({ active: true, ...seeded });
  }
  await setting(context, event, "BalanceModuleSet", { balanceModule: addr, balanceToken: lc(balanceToken) });
  await settingValue(context, event, "core", "BalanceModuleSet.unitPerPoint", null, { unitPerPoint });
});

ponder.on("Core:AdapterSet", async ({ event, context }) => {
  await coreEvent(context, event, "AdapterSet");
  await settingValue(context, event, "core", "AdapterSet", null, { adapter: lc(event.args.adapter), allowed: event.args.allowed });
});

ponder.on("Core:ControllerSet", async ({ event, context }) => {
  await coreEvent(context, event, "ControllerSet");
  const addr = lc(event.args.controller);
  const cur = await ensureEngine(context);
  if (cur.controller && cur.controller !== addr) await context.db.update(controller, { id: cur.controller }).set({ active: false });
  const params = await readController(context, addr);
  await context.db
    .insert(controller)
    .values({ id: addr, setBlock: event.block.number, active: true, anchorBlock: event.block.number, ...params })
    .onConflictDoUpdate(() => ({ setBlock: event.block.number, active: true, anchorBlock: event.block.number, ...params }));
  await setting(context, event, "ControllerSet", { controller: addr });
});

ponder.on("Core:ControllerLocked", async ({ event, context }) => {
  await coreEvent(context, event, "ControllerLocked");
  await setting(context, event, "ControllerLocked", { controllerLocked: true });
});
ponder.on("Core:BalanceModuleLocked", async ({ event, context }) => {
  await coreEvent(context, event, "BalanceModuleLocked");
  await setting(context, event, "BalanceModuleLocked", { balanceModuleLocked: true });
});
ponder.on("Core:AdaptersLocked", async ({ event, context }) => {
  await coreEvent(context, event, "AdaptersLocked");
  await setting(context, event, "AdaptersLocked", { adaptersLocked: true });
});
ponder.on("Core:SuccessorLocked", async ({ event, context }) => {
  await coreEvent(context, event, "SuccessorLocked");
  await setting(context, event, "SuccessorLocked", { successorLocked: true });
});
ponder.on("Core:SuccessorSet", async ({ event, context }) => {
  await coreEvent(context, event, "SuccessorSet");
  await setting(context, event, "SuccessorSet", { successor: lc(event.args.successor) });
});
ponder.on("Core:EngineRetired", async ({ event, context }) => {
  await coreEvent(context, event, "EngineRetired");
  await setting(context, event, "EngineRetired", { retired: true });
});
ponder.on("Core:OwnershipTransferStarted", async ({ event, context }) => {
  await coreEvent(context, event, "OwnershipTransferStarted");
  await setting(context, event, "OwnershipTransferStarted", { pendingOwner: lc(event.args.pending) });
});
ponder.on("Core:OwnershipTransferred", async ({ event, context }) => {
  await coreEvent(context, event, "OwnershipTransferred");
  await setting(context, event, "OwnershipTransferred", { owner: lc(event.args.to), pendingOwner: null });
});

// Events logged without a projection. Pot and buyback balances come from the snapshot.
for (const name of ["RedeemBurnReleased", "CoinRescued", "NftRescued", "TokenRescued", "Migrated"] as const) {
  ponder.on(`Core:${name}`, async ({ event, context }) => {
    await coreEvent(context, event, name);
    await settingValue(context, event, "core", name, null, event.args);
  });
}

// ---- Controller ------------------------------------------------------------------------------------------------

async function controllerSetting(ctx: Ctx, e: At & { log: { logIndex: number; address: Hex } }, name: string, patch: Partial<typeof controller.$inferInsert>) {
  const id = lc(e.log.address);
  const cur = await ctx.db.find(controller, { id });
  if (!cur) throw new Error(`${name} from controller ${id} before its ControllerSet`);
  const before = Object.fromEntries(Object.keys(patch).map((k) => [k, (cur as Record<string, unknown>)[k] ?? null]));
  await ctx.db.update(controller, { id }).set(patch);
  await settingValue(ctx, e, "controller", name, before, patch);
}

ponder.on("Controller:Bought", async ({ event, context }) => {
  await record(context, event, "controller", "Bought");
});

ponder.on("Controller:AnchorMoved", async ({ event, context }) => {
  await record(context, event, "controller", "AnchorMoved");
  const { sid, saleBps, anchorBps } = event.args;
  await context.db
    .insert(anchorMove)
    .values({ id: idOf(event), controller: lc(event.log.address), statementId: sid, saleBps, anchorBps: BigInt(anchorBps), ...posOf(event) })
    .onConflictDoNothing();
  await context.db
    .update(controller, { id: lc(event.log.address) })
    .set({ anchorBps: BigInt(anchorBps), anchorBlock: event.block.number });
});

ponder.on("Controller:SaleSet", async ({ event, context }) => {
  await record(context, event, "controller", "SaleSet");
  const s = event.args.sale;
  await controllerSetting(context, event, "SaleSet", {
    markupBps: Number(s.markupBps),
    startCapBps: BigInt(s.startCapBps),
    decayHours: Number(s.decayHours),
    anchorHalfLife: BigInt(s.anchorHalfLife),
    anchorMinCost: s.anchorMinCost,
  });
});

ponder.on("Controller:CreditSaleSet", async ({ event, context }) => {
  await record(context, event, "controller", "CreditSaleSet");
  const c = event.args.credit;
  await controllerSetting(context, event, "CreditSaleSet", {
    saleOn: c.saleOn,
    window: BigInt(c.window),
    spreadBps: Number(c.spreadBps),
    startBps: BigInt(c.startBps),
  });
});

ponder.on("Controller:AgeEligibilitySet", async ({ event, context }) => {
  await record(context, event, "controller", "AgeEligibilitySet");
  await controllerSetting(context, event, "AgeEligibilitySet", { ageEligibilityOn: event.args.on });
});

ponder.on("Controller:AnchorBpsSet", async ({ event, context }) => {
  await record(context, event, "controller", "AnchorBpsSet");
  await controllerSetting(context, event, "AnchorBpsSet", { anchorBps: BigInt(event.args.anchorBps), anchorBlock: event.block.number });
});

ponder.on("Controller:BalancePoolKeySet", async ({ event, context }) => {
  await record(context, event, "controller", "BalancePoolKeySet");
  const a = event.args;
  await controllerSetting(context, event, "BalancePoolKeySet", {
    balancePoolSet: true,
    balanceCurrency0: lc(a.currency0),
    balanceCurrency1: lc(a.currency1),
    balanceFee: Number(a.fee),
    balanceTickSpacing: Number(a.tickSpacing),
    balanceHooks: lc(a.hooks),
  });
});

// the protected price (decision 148): the quote settings and the rate limited reference of the balance token
ponder.on("Controller:QuoteSet", async ({ event, context }) => {
  await record(context, event, "controller", "QuoteSet");
  const q = event.args.quote;
  await controllerSetting(context, event, "QuoteSet", {
    referenceRateBpsPerHour: BigInt(q.referenceRateBpsPerHour),
    referenceStepBps: Number(q.referenceStepBps),
    referenceTolBps: Number(q.tolBps),
    referenceMaxStale: BigInt(q.referenceMaxStale),
    referenceMinSeconds: BigInt(q.referenceMinSeconds),
    referenceMinLiquidity: q.minLiquidity,
  });
});

ponder.on("Controller:ReferenceRefreshed", async ({ event, context }) => {
  await record(context, event, "controller", "ReferenceRefreshed");
  const id = lc(event.log.address);
  if (!(await context.db.find(controller, { id }))) throw new Error(`ReferenceRefreshed from controller ${id} before its ControllerSet`);
  await context.db.update(controller, { id }).set({ referencePrice: event.args.referencePrice, referenceSpot: event.args.spot, referenceTime: event.block.timestamp });
});

// ControllerV2 statement sale terms (src/interfaces/IControllerV2.sol): the sale switch, the persistent ask multiple
// and the age after which a statement is redeemable (atFloor)
ponder.on("Controller:StatementSalesSet", async ({ event, context }) => {
  await record(context, event, "controller", "StatementSalesSet");
  await controllerSetting(context, event, "StatementSalesSet", { statementSalesEnabled: event.args.enabled });
});

ponder.on("Controller:StatementSaleMultiplierSet", async ({ event, context }) => {
  await record(context, event, "controller", "StatementSaleMultiplierSet");
  await controllerSetting(context, event, "StatementSaleMultiplierSet", { statementSaleMultiplierBps: BigInt(event.args.multiplierBps) });
});

ponder.on("Controller:StatementRedeemDelaySet", async ({ event, context }) => {
  await record(context, event, "controller", "StatementRedeemDelaySet");
  await controllerSetting(context, event, "StatementRedeemDelaySet", { statementRedeemDelaySeconds: BigInt(event.args.delaySeconds) });
});

// ControllerV3 (src/ControllerV3.sol): the idle-loosening premium and the CC price reference (pool key, quote
// settings) are recorded as controller setting history; the fill sync pointer, recorded resales and CC reference
// refreshes are operational, recorded to the log only. No page consumes these as indexed state yet: the web reads
// the live V3 views (resale price, CC reference). Every ControllerV1 and V2 event above still indexes for a V3.
for (const name of ["IdleLooseningSet", "CcPoolKeySet", "CcQuoteSet"] as const) {
  ponder.on(`Controller:${name}`, async ({ event, context }) => {
    await record(context, event, "controller", name);
    await settingValue(context, event, "controller", name, null, event.args);
  });
}
for (const name of ["FillSynced", "CreditSoldRecorded", "CcReferenceRefreshed"] as const) {
  ponder.on(`Controller:${name}`, async ({ event, context }) => {
    await record(context, event, "controller", name);
  });
}

// ---- treasury: phase 2 (Phase2BalanceTreasury) and phase 3 (BalanceTreasuryV2) ----------------------------------
// One factory source (the balance module named by BalanceModuleSet) decodes both ABIs, so phase 2 and phase 3 events
// share these handlers. Events the two versions emit with the same signature and meaning (PaymentAccrued, OwedClaimed,
// WorkingWithdrawn, TokenRescued, ConversionToClaimBpsSet) have one handler. SwitchesSet shares a signature but its
// third switch differs (phase 2 CC redemption, v2 the bid), so it branches on treasury_state.version. CCRedeemed,
// StatementConverted and MigrationReceived differ in signature, so each version has its own handler by full signature.

type TreasuryRow = typeof treasuryEvent.$inferInsert;
type TreasuryStateRow = typeof treasuryState.$inferInsert;
type StateTotalKey = "convertedTotal" | "contributedTotal" | "conversions" | "redeemedCcTotal" | "paidBalanceTotal" | "redemptions" | "ownerFundedTotal" | "ownerAllocatedTotal" | "ownerReturnedTotal" | "ownerWithdrawnTotal" | "accruedTotal" | "claimedTotal" | "totalOwed" | "bidInTotal" | "bidOutTotal" | "bidFills" | "bidCreditsTotal" | "sweptSurplusTotal" | "bucketsFundedTotal" | "allocatedTotal" | "unallocatedTotal" | "claimReleasedTotal";

/**
 * Every treasury event: the log row, the treasury_event row and the treasury_state patch, with the running totals
 * added. State comes from the event's own fields only; nothing is read from the chain. A treasury that emits before
 * its BalanceModuleSet (none can, as the factory registers it there) would fail loudly here.
 */
async function treasuryEventRow(
  ctx: Ctx,
  e: At & { args?: unknown; log: { logIndex: number; address: Hex } },
  name: string,
  row: Pick<TreasuryRow, "kind"> & Partial<Omit<TreasuryRow, "id" | "treasury" | "kind" | "blockNumber" | "blockTimestamp" | "txHash" | "logIndex">>,
  patch: Partial<Omit<TreasuryStateRow, "id" | "balanceToken" | "setBlock" | "active">> = {},
  totals: Partial<Record<StateTotalKey, bigint>> = {},
) {
  await record(ctx, e, "treasury", name);
  const id = lc(e.log.address);
  await ctx.db.insert(treasuryEvent).values({ id: idOf(e), treasury: id, ...row, ...posOf(e) }).onConflictDoNothing();
  const cur = await ctx.db.find(treasuryState, { id });
  if (!cur) throw new Error(`${name} from treasury ${id} before its BalanceModuleSet`);
  const added = Object.fromEntries(Object.entries(totals).map(([k, v]) => [k, (cur as unknown as Record<string, bigint>)[k] + v]));
  await ctx.db.update(treasuryState, { id }).set({ ...patch, ...added, lastEventBlock: e.block.number });
}

type RedeemerRow = typeof redeemer.$inferInsert;
type RedeemerTotalKey = "redeemedCcTotal" | "paidBalanceTotal" | "redemptions" | "allocatedTotal" | "unallocatedTotal" | "claimReleasedTotal";

/** Upserts the per-redeemer registry row (phase 3), adding the running totals. The redeemer is scoped to its treasury. */
async function bumpRedeemer(
  ctx: Ctx,
  e: At & { log: { address: Hex } },
  redeemerAddr: Hex,
  patch: Partial<Omit<RedeemerRow, "id" | "treasury" | "redeemer" | "firstBlock" | "lastEventBlock">> = {},
  totals: Partial<Record<RedeemerTotalKey, bigint>> = {},
) {
  const treasury = lc(e.log.address);
  const id = `${treasury}:${redeemerAddr}`;
  const cur = await ctx.db.find(redeemer, { id });
  if (!cur) {
    await ctx.db.insert(redeemer).values({ id, treasury, redeemer: redeemerAddr, firstBlock: e.block.number, lastEventBlock: e.block.number, ...patch, ...totals });
    return;
  }
  const added = Object.fromEntries(Object.entries(totals).map(([k, v]) => [k, (cur as unknown as Record<string, bigint>)[k] + v]));
  await ctx.db.update(redeemer, { id }).set({ ...patch, ...added, lastEventBlock: e.block.number });
}

// phase 2: allocated is the amount sent to the claim reserve; claimReserve is the reserve after the conversion
ponder.on("Treasury:StatementConverted(uint256 indexed statementId, uint256 received, uint256 allocated, uint16 contributionBps, uint256 claimReserve)", async ({ event, context }) => {
  const { statementId, received, allocated, contributionBps, claimReserve } = event.args;
  await treasuryEventRow(
    context, event, "StatementConverted",
    { kind: "statement_converted", statementId, amount: received, claimReserve, bps: Number(contributionBps), detail: toJson({ allocated }) },
    { claimReserve },
    { convertedTotal: received, contributedTotal: allocated, conversions: 1n },
  );
});

// v2: toProRata is the amount contributed to the pro-rata redeemer's bucket; there is no single claim reserve
ponder.on("Treasury:StatementConverted(uint256 indexed statementId, uint256 received, uint256 toProRata, uint16 contributionBps)", async ({ event, context }) => {
  const { statementId, received, toProRata, contributionBps } = event.args;
  await treasuryEventRow(
    context, event, "StatementConverted",
    { kind: "statement_converted", statementId, amount: received, bps: Number(contributionBps), detail: toJson({ toProRata }) },
    {},
    { convertedTotal: received, contributedTotal: toProRata, conversions: 1n },
  );
});

ponder.on("Treasury:PaymentAccrued", async ({ event, context }) => {
  const { to, amount } = event.args;
  await treasuryEventRow(context, event, "PaymentAccrued", { kind: "payment_accrued", amount, actor: lc(to) }, {}, { accruedTotal: amount, totalOwed: amount });
});

ponder.on("Treasury:OwedClaimed", async ({ event, context }) => {
  const { to, amount } = event.args;
  await treasuryEventRow(context, event, "OwedClaimed", { kind: "owed_claimed", amount, actor: lc(to) }, {}, { claimedTotal: amount, totalOwed: -amount });
});

// phase 2 public redemption: the burner's CC for a share of the claim reserve. the reserve and the supply are after the burn
ponder.on("Treasury:CCRedeemed(address indexed burner, address indexed recipient, uint256 ccIn, uint256 balanceOut, uint256 claimReserve, uint256 ccSupply, uint64 configEpoch)", async ({ event, context }) => {
  const { burner, recipient, ccIn, balanceOut, claimReserve, ccSupply, configEpoch } = event.args;
  await treasuryEventRow(
    context, event, "CCRedeemed",
    { kind: "cc_redeemed", ccIn, balanceOut, claimReserve, ccSupply, configEpoch: BigInt(configEpoch), actor: lc(burner), recipient: lc(recipient) },
    { claimReserve, configEpoch: BigInt(configEpoch) },
    { redeemedCcTotal: ccIn, paidBalanceTotal: balanceOut, redemptions: 1n },
  );
});

// v2 public redemption through a registered redeemer: ccIn burned, amount paid, mode immediate/linear/deferred with a
// claimId for a held claim. the redeemer draws from its own bucket; the current bucket is a live read (section 9.6)
ponder.on("Treasury:CCRedeemed(address indexed redeemer, address indexed burner, address indexed recipient, uint256 ccIn, uint256 amount, uint8 mode, uint32 duration, uint256 claimId, uint64 epoch)", async ({ event, context }) => {
  const { redeemer: redeemerAddr, burner, recipient, ccIn, amount, mode, duration, claimId, epoch } = event.args;
  const r = lc(redeemerAddr);
  await treasuryEventRow(
    context, event, "CCRedeemed",
    { kind: "cc_redeemed", ccIn, balanceOut: amount, configEpoch: BigInt(epoch), actor: lc(burner), recipient: lc(recipient), redeemer: r, detail: toJson({ mode: Number(mode), duration: Number(duration), claimId }) },
    {},
    { redeemedCcTotal: ccIn, paidBalanceTotal: amount, redemptions: 1n },
  );
  await bumpRedeemer(context, event, r, {}, { redeemedCcTotal: ccIn, paidBalanceTotal: amount, redemptions: 1n });
});

// phase 2 switches are conversion, working payments and CC redemption; v2's third switch is the bid. one signature,
// so the meaning of the third flag follows the module version recorded at BalanceModuleSet.
ponder.on("Treasury:SwitchesSet", async ({ event, context }) => {
  const { conversionEnabled, workingPaymentsEnabled } = event.args;
  const third = (event.args as { ccRedemptionEnabled: boolean }).ccRedemptionEnabled;
  const cur = await context.db.find(treasuryState, { id: lc(event.log.address) });
  const thirdPatch = cur?.version === "v2" ? { bidEnabled: third } : { ccRedemptionEnabled: third };
  await treasuryEventRow(
    context, event, "SwitchesSet",
    { kind: "switches_set", detail: toJson({ conversionEnabled, workingPaymentsEnabled, third }) },
    { conversionEnabled, workingPaymentsEnabled, ...thirdPatch },
  );
});

ponder.on("Treasury:ConversionToClaimBpsSet", async ({ event, context }) => {
  const bps = Number(event.args.bps);
  await treasuryEventRow(context, event, "ConversionToClaimBpsSet", { kind: "contribution_set", bps }, { conversionToClaimBps: bps });
});

ponder.on("Treasury:RedemptionFeeSet", async ({ event, context }) => {
  const bps = Number(event.args.bps);
  const configEpoch = BigInt(event.args.configEpoch);
  await treasuryEventRow(context, event, "RedemptionFeeSet", { kind: "fee_set", bps, configEpoch }, { redemptionFeeBps: bps, configEpoch });
});

ponder.on("Treasury:MinimumWorkingBalanceSet", async ({ event, context }) => {
  const { amount } = event.args;
  await treasuryEventRow(context, event, "MinimumWorkingBalanceSet", { kind: "minimum_working_set", amount }, { minimumWorkingBalance: amount });
});

// a policy replacement turns CC redemption off; the treasury emits SwitchesSet in the same transaction
ponder.on("Treasury:RedemptionPolicySet", async ({ event, context }) => {
  const policy = lc(event.args.policy);
  const configEpoch = BigInt(event.args.configEpoch);
  await treasuryEventRow(context, event, "RedemptionPolicySet", { kind: "policy_set", policy, configEpoch }, { policy, configEpoch });
});

// the owner's reserve changes, kept apart from public redemptions
ponder.on("Treasury:ClaimsFunded", async ({ event, context }) => {
  const { from, amount, claimReserve } = event.args;
  await treasuryEventRow(context, event, "ClaimsFunded", { kind: "claims_funded", amount, claimReserve, actor: lc(from) }, { claimReserve }, { ownerFundedTotal: amount });
});

ponder.on("Treasury:ClaimsAllocated", async ({ event, context }) => {
  const { amount, claimReserve } = event.args;
  await treasuryEventRow(context, event, "ClaimsAllocated", { kind: "claims_allocated", amount, claimReserve }, { claimReserve }, { ownerAllocatedTotal: amount });
});

ponder.on("Treasury:ClaimsReturned", async ({ event, context }) => {
  const { amount, claimReserve } = event.args;
  const configEpoch = BigInt(event.args.configEpoch);
  await treasuryEventRow(context, event, "ClaimsReturned", { kind: "claims_returned", amount, claimReserve, configEpoch }, { claimReserve, configEpoch }, { ownerReturnedTotal: amount });
});

ponder.on("Treasury:WorkingWithdrawn", async ({ event, context }) => {
  const { to, amount } = event.args;
  await treasuryEventRow(context, event, "WorkingWithdrawn", { kind: "working_withdrawn", amount, actor: lc(to) }, {}, { ownerWithdrawnTotal: amount });
});

ponder.on("Treasury:TreasuryMigrated", async ({ event, context }) => {
  const { successor, moved, claimsImported } = event.args;
  const configEpoch = BigInt(event.args.configEpoch);
  await treasuryEventRow(
    context, event, "TreasuryMigrated",
    { kind: "migrated_out", amount: moved, claimReserve: 0n, configEpoch, actor: lc(successor), detail: toJson({ claimsImported }) },
    migratedOutPatch(successor, configEpoch),
  );
});

// phase 2: the destination's reserve becomes the event's figure (its own plus the import) at the given epoch
ponder.on("Treasury:MigrationReceived(address indexed predecessor, uint256 claimsImported, uint256 claimReserve, uint64 configEpoch)", async ({ event, context }) => {
  const { predecessor, claimsImported, claimReserve } = event.args;
  const configEpoch = BigInt(event.args.configEpoch);
  await treasuryEventRow(
    context, event, "MigrationReceived",
    { kind: "migration_received", amount: claimsImported, claimReserve, configEpoch, actor: lc(predecessor) },
    migrationReceivedPatch(claimReserve, configEpoch),
  );
});

// v2: the predecessor's balance arrives into custody; v2 has per-redeemer buckets, not a single reserve or epoch here
ponder.on("Treasury:MigrationReceived(address indexed predecessor, uint256 claimsImported, uint256 custody)", async ({ event, context }) => {
  const { predecessor, claimsImported, custody } = event.args;
  await treasuryEventRow(
    context, event, "MigrationReceived",
    { kind: "migration_received", amount: claimsImported, actor: lc(predecessor), detail: toJson({ custody }) },
  );
});

// ---- treasury: phase 3 only (BalanceTreasuryV2) -----------------------------------------------------------------

// a $BALANCE bid call: the seller's Credits bought for paid (artist royalty on top), bidBudget the budget after the fill
ponder.on("Treasury:BidFill", async ({ event, context }) => {
  const { seller, credits, paid, toArtist, bidBudget } = event.args;
  await treasuryEventRow(
    context, event, "BidFill",
    { kind: "bid_fill", amount: paid, actor: lc(seller), detail: toJson({ credits, toArtist, bidBudget }) },
    { bidBudget },
    { bidOutTotal: paid + toArtist, bidFills: 1n, bidCreditsTotal: credits },
  );
});

// one credit bought by the bid; recorded to the log for per-credit score and bidBps, aggregated by BidFill above
ponder.on("Treasury:CreditSold", async ({ event, context }) => {
  await record(context, event, "treasury", "CreditSold");
});

// surplus working funds moved into the bid budget and the redeemer buckets in the owner's shares. BidFill carries the
// authoritative budget after a fill; between fills a sweep adds toBid to the last known budget.
ponder.on("Treasury:Swept", async ({ event, context }) => {
  const { surplus, toBid, toBuckets } = event.args;
  const cur = await context.db.find(treasuryState, { id: lc(event.log.address) });
  await treasuryEventRow(
    context, event, "Swept",
    { kind: "swept", amount: surplus, detail: toJson({ toBid, toBuckets }) },
    { bidBudget: (cur?.bidBudget ?? 0n) + toBid },
    { bidInTotal: toBid, sweptSurplusTotal: surplus, bucketsFundedTotal: toBuckets },
  );
});

// owner surplus moved into (Allocated) or out of (Unallocated) a redeemer's bucket
ponder.on("Treasury:Allocated", async ({ event, context }) => {
  const { redeemer: r, amount } = event.args;
  const addr = lc(r);
  await treasuryEventRow(context, event, "Allocated", { kind: "allocated", amount, redeemer: addr }, {}, { allocatedTotal: amount });
  await bumpRedeemer(context, event, addr, {}, { allocatedTotal: amount });
});

ponder.on("Treasury:Unallocated", async ({ event, context }) => {
  const { redeemer: r, amount } = event.args;
  const addr = lc(r);
  await treasuryEventRow(context, event, "Unallocated", { kind: "unallocated", amount, redeemer: addr }, {}, { unallocatedTotal: amount });
  await bumpRedeemer(context, event, addr, {}, { unallocatedTotal: amount });
});

ponder.on("Treasury:RedeemerRegistered", async ({ event, context }) => {
  const { redeemer: r, activeAt } = event.args;
  const addr = lc(r);
  await treasuryEventRow(context, event, "RedeemerRegistered", { kind: "redeemer_registered", redeemer: addr, detail: toJson({ activeAt }) });
  await bumpRedeemer(context, event, addr, { registered: true, activeAt: BigInt(activeAt) });
});

ponder.on("Treasury:RedeemerCapsSet", async ({ event, context }) => {
  const { redeemer: r, perCall, perPeriod, lifetime, epoch } = event.args;
  const addr = lc(r);
  await treasuryEventRow(context, event, "RedeemerCapsSet", { kind: "redeemer_caps_set", redeemer: addr, configEpoch: BigInt(epoch), detail: toJson({ perCall, perPeriod, lifetime }) });
  await bumpRedeemer(context, event, addr, { perCall, perPeriod, lifetime, epoch: BigInt(epoch) });
});

ponder.on("Treasury:RedeemerSwitched", async ({ event, context }) => {
  const { redeemer: r, on } = event.args;
  const addr = lc(r);
  await treasuryEventRow(context, event, "RedeemerSwitched", { kind: "redeemer_switched", redeemer: addr, detail: toJson({ on }) });
  await bumpRedeemer(context, event, addr, { on });
});

// a redeemer's share of a sweep, plus the bid's share and the running total (treasury-wide)
ponder.on("Treasury:SharesSet", async ({ event, context }) => {
  const { redeemer: r, shareBps, bidShareBps, totalShareBps } = event.args;
  const addr = lc(r);
  await treasuryEventRow(
    context, event, "SharesSet",
    { kind: "shares_set", redeemer: addr, bps: Number(shareBps), detail: toJson({ bidShareBps, totalShareBps }) },
    { bidShareBps: Number(bidShareBps), totalShareBps: Number(totalShareBps) },
  );
  await bumpRedeemer(context, event, addr, { shareBps: Number(shareBps) });
});

// Redeemer 2 (MarketRedeemer, a static source, ponder.config.ts) sets its premium; PremiumSet also fires at
// construction, before the treasury registers it. The premium and epoch land on the same `treasury:redeemer` row the
// treasury's RedeemerRegistered writes, so this upserts (creating the row if it arrives first). The row's treasury is
// taken from the deployment record because PremiumSet is emitted by the redeemer, not the treasury. Registered only
// when MARKET_REDEEMER is configured; otherwise the source indexes nothing (ponder.config.ts).
if (MARKET_REDEEMER) {
  const { address: marketAddr, treasury: marketTreasury } = MARKET_REDEEMER;
  const marketRowId = `${marketTreasury}:${marketAddr}`;
  ponder.on("MarketRedeemer:PremiumSet", async ({ event, context }) => {
    const patch = { premiumBps: Number(event.args.premiumBps), premiumEpoch: BigInt(event.args.configEpoch) };
    const cur = await context.db.find(redeemer, { id: marketRowId });
    if (!cur) {
      await context.db.insert(redeemer).values({
        id: marketRowId, treasury: marketTreasury, redeemer: marketAddr,
        firstBlock: event.block.number, lastEventBlock: event.block.number, ...patch,
      });
      return;
    }
    await context.db.update(redeemer, { id: marketRowId }).set({ ...patch, lastEventBlock: event.block.number });
  });
}

// a vesting or deferred claim paid out to its recipient; the claim was created in full at redemption time
ponder.on("Treasury:ClaimReleased", async ({ event, context }) => {
  const { claimId, recipient, amount } = event.args;
  await treasuryEventRow(
    context, event, "ClaimReleased",
    { kind: "claim_released", amount, recipient: lc(recipient), detail: toJson({ claimId }) },
    {},
    { claimReleasedTotal: amount },
  );
});

ponder.on("Treasury:CushionSet", async ({ event, context }) => {
  const { cushion } = event.args;
  await treasuryEventRow(context, event, "CushionSet", { kind: "cushion_set", amount: cushion }, { cushion });
});

ponder.on("Treasury:PausedSet", async ({ event, context }) => {
  const { paused } = event.args;
  await treasuryEventRow(context, event, "PausedSet", { kind: "paused_set", detail: toJson({ paused }) }, { paused });
});

ponder.on("Treasury:BidSet", async ({ event, context }) => {
  await treasuryEventRow(context, event, "BidSet", { kind: "bid_set", detail: toJson(event.args.bid) });
});

ponder.on("Treasury:TokenRescued", async ({ event, context }) => {
  await record(context, event, "treasury", "TokenRescued");
});

// ---- tokens ----------------------------------------------------------------------------------------------------

// Coin burns. A burn by the Core is a buyback burn. Swap fee burns are counted from CreditSwapped.fee.
ponder.on("Coin:Transfer", async ({ event, context }) => {
  await record(context, event, "coin", "Transfer");
  if (lc(event.args.from) === CORE_ADDRESS) {
    await context.db.insert(transactionFact).values({ id: event.transaction.hash, coreBurn: event.args.value })
      .onConflictDoUpdate((row) => ({ coreBurn: row.coreBurn + event.args.value }));
    await bump(context, event, { ccBurned: event.args.value });
  }
});

// Owner follows every Transfer. A transfer from the Core to the successor moves a held credit out of the pile
// (Core.migrate emits Migrated without the ids).
ponder.on("Credits:Transfer", async ({ event, context }) => {
  await record(context, event, "credits", "Transfer");
  const { from, to, id } = event.args;
  if (!await context.db.find(credit, { id })) {
    const logs = await context.client.request({
      method: "eth_getLogs",
      params: [{ address: COLLECTIONS.credits, blockHash: event.block.hash, topics: [CREDIT_TRANSFER_TOPIC] }],
    });
    await hydrateCreditPeers(logs, id, { address: COLLECTIONS.credits, blockHash: event.block.hash },
      (ids) => ensureCredits(context, ids, undefined, 16_384));
  }
  const c = await ensureCredit(context, id, lc(to));
  const patch: Partial<typeof credit.$inferInsert> = { owner: lc(to) };
  if (c.state === "held" && lc(from) === CORE_ADDRESS) {
    const eng = await context.db.find(engine, { id: CORE_ADDRESS });
    if (eng?.successor && eng.successor !== zeroAddress && eng.successor === lc(to)) {
      patch.state = "migrated";
      patch.pileOrder = null;
    }
  }
  await context.db.update(credit, { id }).set(patch);
  // a Credits Transfer out of the strategy ends its listing
  if (lc(from) === STRATEGY_ADDRESS) await endListing(context, event, id, lc(to));
});

// ---- CreditStrategy listings -------------------------------------------------------------------------------------

async function endListing(ctx: Ctx, e: At, id: bigint, buyer: Hex) {
  const row = await ctx.db.find(strategyListing, { id });
  if (!row?.active) return;
  await ctx.db.update(strategyListing, { id }).set({ active: false, soldBlock: e.block.number, soldAt: e.block.timestamp, buyer });
}

ponder.on("Strategy:NFTBoughtByProtocol", async ({ event, context }) => {
  await record(context, event, "strategy", "NFTBoughtByProtocol");
  const row = { listPrice: event.args.listPrice, active: true, boughtBlock: event.block.number, boughtAt: event.block.timestamp, soldBlock: null, soldAt: null, buyer: null };
  await context.db.insert(strategyListing).values({ id: event.args.tokenId, ...row }).onConflictDoUpdate(row);
});

ponder.on("Strategy:NFTSoldByProtocol", async ({ event, context }) => {
  await record(context, event, "strategy", "NFTSoldByProtocol");
  const { tokenId, buyer } = event.args;
  const row = await context.db.find(strategyListing, { id: tokenId });
  if (!row) return;
  await context.db.update(strategyListing, { id: tokenId }).set({ active: false, soldBlock: event.block.number, soldAt: event.block.timestamp, buyer: lc(buyer) });
});

ponder.on("Statements:Transfer", async ({ event, context }) => {
  await record(context, event, "statements", "Transfer");
  const { to, id } = event.args;
  await ensureStatement(context, id, lc(to));
  await context.db.update(statement, { id }).set({ owner: lc(to) });
});
