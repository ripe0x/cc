// Port of the Core handlers in indexer/src/index.ts, in the same order and with the same row writes.
import { indexer, type Activity, type Credit, type Engine } from "envio";
import { CORE } from "../lib/constants";
import { blank } from "../lib/blank";
import { ensureCredit, ensureCredits, ensureEngine, ensureStatement, readController, readTreasury, refreshStatementArt, settingsColumns, snapshot } from "../lib/chain";
import { viemArgs } from "../lib/args";
import { composeModeOf } from "../lib/mode";
import { creditSaleSplit, statementPot } from "../lib/split";
import { act, at, bump, bumpBalanceCommitted, FIELDS, idOf, lc, patch, posOf, record, toJson, type At, type Ctx } from "../lib/shared";
import { ZERO } from "../lib/constants";
import type { Hex } from "viem";

const COMPOSE_FIELDS = { transaction: ["hash", "from", "to", "input"], block: ["timestamp"] } as const;

/** Every Core event: log row, engine row, one snapshot per block. */
async function coreEvent(ctx: Ctx, e: At, args: unknown, name: string) {
  record(ctx, e, args, "core", name);
  await snapshot(ctx, e.block);
}

type EnginePatch = { [K in keyof Engine]?: Engine[K] | null };
const denull = <T extends object>(o: T) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, v === null ? undefined : v]));

/** Applies `patch` to the engine row and records the changed values before and after. */
async function setting(ctx: Ctx, e: At, name: string, p: EnginePatch) {
  const cur = await ensureEngine(ctx, e.block.number);
  const before = Object.fromEntries(Object.keys(p).map((k) => [k, (cur as Record<string, unknown>)[k] ?? null]));
  ctx.Engine.set({ ...cur, ...denull(p) });
  ctx.SettingChange.set({ ...blank.settingChange, id: idOf(e), source: "core", name, before: toJson(before), after: toJson(p), ...posOf(e) });
}

/** Setting events whose value has no engine column. */
export async function settingValue(ctx: Ctx, e: At, source: "core" | "controller", name: string, before: unknown, after: unknown) {
  // one row per log (the id): a second write for the same log, e.g. BalanceModuleSet.unitPerPoint, keeps the first
  if (await ctx.SettingChange.get(idOf(e))) return;
  ctx.SettingChange.set({ ...blank.settingChange, id: idOf(e), source, name, before: toJson(before ?? null), after: toJson(after), ...posOf(e) });
}

/** A credit enters the pile at the next pile position. Fields of an earlier stay in the engine are cleared. */
async function enterPile(ctx: Ctx, e: At, id: bigint, how: Credit["acquiredHow"], cost: bigint, seller: Hex | null, royalty: bigint | null = null) {
  await ensureCredit(ctx, e, id);
  const eng = await patch(ctx.Engine, CORE, (r) => ({ pileSeq: r.pileSeq + 1n }), "engine");
  await patch(ctx.Credit, id.toString(), {
    state: "held",
    costBasis: cost,
    acquiredAt: e.block.timestamp,
    acquiredBlock: e.block.number,
    acquiredTx: e.transaction.hash,
    acquiredHow: how,
    seller: seller ?? undefined,
    royalty: royalty ?? undefined,
    balancePaid: undefined,
    pileOrder: eng.pileSeq,
    statementId: undefined,
    pagePosition: undefined,
    salePrice: undefined,
    buyer: undefined,
    toArtist: undefined,
    toOperator: undefined,
    toPot: undefined,
    toBuyback: undefined,
    costToPotBps: undefined,
  }, "credit");
}

const fact = (ctx: Ctx, hash: string) => ctx.TransactionFact.get(hash);

// ---- Core: credits in ------------------------------------------------------------------------------------------

indexer.onEvent({ contract: "Core", event: "EthRateFill", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "EthRateFill");
  const cur = await fact(context, e.transaction.hash);
  context.TransactionFact.set({ ...(cur ?? { ...blank.transactionFact, id: e.transaction.hash }), ethFillPending: true });
  await bump(context, e, { ethIntoCredits: event.params.spent });
});

// value mode (decision 148): an eth fill drops the shared balance instance and logs ValueRateFill in place of EthRateFill
indexer.onEvent({ contract: "Core", event: "ValueRateFill", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "ValueRateFill");
  const cur = await fact(context, e.transaction.hash);
  context.TransactionFact.set({ ...(cur ?? { ...blank.transactionFact, id: e.transaction.hash }), ethFillPending: true });
  await bump(context, e, { ethIntoCredits: event.params.spent });
});

indexer.onEvent({ contract: "Core", event: "CreditBought", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "CreditBought");
  // cost is the pile cost basis (eth bid: the price plus the artist royalty; balance bid: the eth floor basis);
  // toArtist is the royalty in the route's currency (decision 163)
  const { id, from, cost, toArtist } = event.params;
  const cur = await fact(context, e.transaction.hash);
  const how = cur?.ethFillPending ? "eth_bid" : "balance_bid";
  // the same fields on insert and on update: a balance-bid sale has no earlier event in its tx, so the insert is
  // the path that must mark it for the BalanceFill that follows
  context.TransactionFact.set({
    ...(cur ?? { ...blank.transactionFact, id: e.transaction.hash }),
    ethFillPending: false,
    balanceBuyId: how === "balance_bid" ? id : undefined,
    balanceBuyActivityId: how === "balance_bid" ? idOf(e) : undefined,
  });
  await enterPile(context, e, id, how, cost, lc(from), how === "eth_bid" ? toArtist : null);
  act(context, e, { kind: "credit_bought", creditId: id, account: lc(from), amount: cost, amount2: 0n });
  await bump(context, e, {
    creditsBought: 1n,
    ...(how === "eth_bid" ? { creditsEth: 1n, toArtistBuys: toArtist } : { creditsBalance: 1n }),
  });
});

indexer.onEvent({ contract: "Core", event: "BalanceFill", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "BalanceFill");
  // paid reaches the seller; toArtist is requested from the module, which may record debt instead of transferring.
  const { paid, toArtist } = event.params;
  // This column follows earlier BalanceModuleSet logs, never a latest-state RPC read.
  const { balanceToken } = await ensureEngine(context, e.block.number);
  const cur = await fact(context, e.transaction.hash);
  if (cur?.balanceBuyId != null && cur.balanceBuyActivityId != null) {
    await patch(context.Credit, cur.balanceBuyId.toString(), { balancePaid: paid, balancePaidToken: balanceToken, royalty: toArtist }, "credit");
    await patch(context.Activity, cur.balanceBuyActivityId, { amount2: paid, balanceToken }, "activity");
  }
  if (cur) context.TransactionFact.set({ ...cur, balanceBuyId: undefined, balanceBuyActivityId: undefined });
  if (balanceToken) {
    await bumpBalanceCommitted(context, e, balanceToken, paid + toArtist);
  } else {
    context.log.error(`BalanceFill at ${e.transaction.hash} paid ${paid} while engine.balanceToken is null; the commitment is credited to no token`);
  }
});

indexer.onEvent({ contract: "Core", event: "ListingBought", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "ListingBought");
  // cost is the listing price, paid the keeper payment, toArtist the royalty on the price (decision 163); the pile
  // cost basis is the three summed
  const { id, caller, cost, paid, toArtist } = event.params;
  const cur = await fact(context, e.transaction.hash);
  if (cur) context.TransactionFact.set({ ...cur, ethFillPending: false });
  await enterPile(context, e, id, "listing", cost + toArtist + paid, null, toArtist);
  act(context, e, { kind: "listing_bought", creditId: id, account: lc(caller), amount: cost + toArtist + paid, amount2: paid });
  await bump(context, e, { creditsBought: 1n, creditsListing: 1n, toArtistBuys: toArtist });
});

indexer.onEvent({ contract: "Core", event: "CreditAdopted", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "CreditAdopted");
  const { id, cost } = event.params;
  await enterPile(context, e, id, "adopted", cost, null);
  act(context, e, { kind: "credit_adopted", creditId: id, amount: cost });
  await bump(context, e, { creditsBought: 1n, creditsAdopted: 1n });
});

// The in credit takes the out credit's pile position, cost basis and acquisition time. The event omits them.
indexer.onEvent({ contract: "Core", event: "CreditSwapped", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "CreditSwapped");
  const { inId, outId, caller, fee } = event.params;
  const out = await ensureCredit(context, e, outId);
  await ensureCredit(context, e, inId);
  await patch(context.Credit, inId.toString(), {
    state: "held",
    costBasis: out.costBasis,
    acquiredAt: out.acquiredAt,
    acquiredBlock: e.block.number,
    acquiredTx: e.transaction.hash,
    acquiredHow: "swap_in",
    seller: lc(caller),
    balancePaid: undefined,
    pileOrder: out.pileOrder,
  }, "credit");
  await patch(context.Credit, outId.toString(), { state: "swapped_out", pileOrder: undefined }, "credit");
  act(context, e, { kind: "credit_swapped", creditId: inId, otherCreditId: outId, account: lc(caller), amount2: fee });
  await bump(context, e, { creditsSwapped: 1n, ccBurned: fee });
});

// ---- Core: credits out, statements -------------------------------------------------------------------------------

indexer.onEvent({ contract: "Core", event: "Composed", fields: COMPOSE_FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "Composed");
  const { sid, ids, format, cost, price, caller } = event.params;
  await ensureStatement(context, e, sid);
  const mode = composeModeOf(event.transaction.to, CORE, event.transaction.input);
  await patch(context.Statement, sid.toString(), {
    state: "held",
    composedAt: e.block.timestamp,
    composedBlock: e.block.number,
    composeTx: e.transaction.hash,
    composer: lc(caller),
    mode: mode ?? undefined,
    cost,
    composePrice: price,
    format: Number(format),
  }, "statement");
  await ensureCredits(context, e, ids);
  for (let i = 0; i < ids.length; i++) {
    await patch(context.Credit, ids[i]!.toString(), { state: "composed", statementId: sid, pagePosition: i, pileOrder: undefined }, "credit");
    context.StatementCredit.set({ id: `${sid}:${i}`, statementId: sid, position: i, creditId: ids[i]! });
  }
  act(context, e, { kind: "composed", statementId: sid, account: lc(caller), amount: cost, amount2: price });
  await bump(context, e, { composed: 1n });
});

indexer.onEvent({ contract: "Core", event: "HeldFormatSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "HeldFormatSet");
  const { sid, format, caller } = event.params;
  const cur = await ensureStatement(context, e, sid);
  const art = await refreshStatementArt(context, e, sid);
  context.StatementFormat.set({
    id: idOf(e), statementId: sid, from: cur.format ?? Number(format), to: Number(format), caller: lc(caller), ...posOf(e),
  });
  await patch(context.Statement, sid.toString(), { format: Number(format), ...art }, "statement");
  act(context, e, { kind: "restyled", statementId: sid, account: lc(caller) });
  await bump(context, e, { restyled: 1n });
});

indexer.onEvent({ contract: "Core", event: "StatementSoldTo", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "StatementSoldTo");
  const { sid, buyer, price, toBuyback, toArtist, toOperator } = event.params;
  await ensureStatement(context, e, sid);
  await patch(context.Statement, sid.toString(), {
    state: "sold",
    salePrice: price,
    buyer: lc(buyer),
    toBuyback,
    toArtist,
    toOperator,
    toPot: statementPot(price, toArtist, toOperator, toBuyback),
  }, "statement");
  act(context, e, { kind: "statement_sold", statementId: sid, account: lc(buyer), amount: price, amount2: toBuyback });
  await bump(context, e, { statementsSold: 1n, toArtist, toOperator });
});

indexer.onEvent({ contract: "Core", event: "CreditSold", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "CreditSold");
  const { id, buyer, price, toArtist, toOperator } = event.params;
  const c = await ensureCredit(context, e, id);
  const eng = await ensureEngine(context, e.block.number);
  const bps = eng.creditCostToPotBps ?? 0;
  const split = creditSaleSplit(price, c.costBasis ?? 0n, toArtist, toOperator, BigInt(bps));
  await patch(context.Credit, id.toString(), {
    state: "sold",
    pileOrder: undefined,
    salePrice: price,
    buyer: lc(buyer),
    toArtist,
    toOperator,
    toPot: split.toPot,
    toBuyback: split.toBuyback,
    costToPotBps: bps,
  }, "credit");
  act(context, e, { kind: "credit_sold", creditId: id, account: lc(buyer), amount: price, amount2: split.toPot });
  await bump(context, e, { creditsSold: 1n, toArtist, toOperator });
});

indexer.onEvent({ contract: "Core", event: "StatementRedeemed", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "StatementRedeemed");
  const { sid, received } = event.params;
  const { balanceToken } = await ensureEngine(context, e.block.number);
  await ensureStatement(context, e, sid);
  await patch(context.Statement, sid.toString(), { state: "redeemed", redeemedReceived: received }, "statement");
  act(context, e, { kind: "redeemed", statementId: sid, amount: received, balanceToken });
  await bump(context, e, { redeemed: 1n });
});

// ---- Core: money ---------------------------------------------------------------------------------------------------

indexer.onEvent({ contract: "Core", event: "Buyback", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "Buyback");
  const { caller, amountIn } = event.params;
  const cur = await fact(context, e.transaction.hash);
  const burned = cur?.coreBurn ?? 0n;
  if (cur) context.TransactionFact.set({ ...cur, coreBurn: 0n });
  await patch(context.Engine, CORE, { lastBuybackBlock: e.block.number }, "engine");
  act(context, e, { kind: "buyback", account: lc(caller), amount: amountIn, amount2: burned });
  await bump(context, e, { buybacks: 1n, ethToBuybackSpent: amountIn });
});

indexer.onEvent({ contract: "Core", event: "FeesAdded", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "FeesAdded");
  const { amount, toPayee } = event.params;
  act(context, e, { kind: "fees_added", amount, amount2: toPayee });
  await bump(context, e, { feesBooked: amount, toPayee });
});

indexer.onEvent({ contract: "Core", event: "Funded", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "Funded");
  act(context, e, { kind: "funded", account: lc(event.params.from), amount: event.params.amount });
});

indexer.onEvent({ contract: "Core", event: "EscrowCollected", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "EscrowCollected");
  act(context, e, { kind: "escrow_collected", amount: event.params.amount });
});

// ---- Core: settings, authority -----------------------------------------------------------------------------------------

indexer.onEvent({ contract: "Core", event: "SettingsSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "SettingsSet");
  await setting(context, e, "SettingsSet", settingsColumns(viemArgs("Core", "SettingsSet", event.params).settings as never));
});

indexer.onEvent({ contract: "Core", event: "RateSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "RateSet");
  const cur = await ensureEngine(context, e.block.number);
  await settingValue(context, e, "core", "RateSet", { ethRate: cur.ethRate }, { rate: event.params.rate });
});

indexer.onEvent({ contract: "Core", event: "BalanceRateSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "BalanceRateSet");
  // BalanceRateSet reports value mode's shared instance reset to the floor, not the posted balance bid rate: the
  // balance bid is 10_000 - balanceDiscountBps and lives in the balanceRate column, sourced from SettingsSet and the
  // snapshot read (decision 164). record this under a separate shared-rate key so it does not conflate with that column
  await settingValue(context, e, "core", "BalanceRateSet", null, { sharedRateBps: Number(event.params.rateBps) });
});

indexer.onEvent({ contract: "Core", event: "CreditCostToPotBpsSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "CreditCostToPotBpsSet");
  await setting(context, e, "CreditCostToPotBpsSet", { creditCostToPotBps: Number(event.params.bps) });
});

indexer.onEvent({ contract: "Core", event: "ChosenComposeOnSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "ChosenComposeOnSet");
  await setting(context, e, "ChosenComposeOnSet", { chosenComposeOn: event.params.on });
});

indexer.onEvent({ contract: "Core", event: "MinCcToChooseSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "MinCcToChooseSet");
  await setting(context, e, "MinCcToChooseSet", { minCcToChoose: event.params.min });
});

indexer.onEvent({ contract: "Core", event: "PausedSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "PausedSet");
  await setting(context, e, "PausedSet", { paused: event.params.paused });
});

indexer.onEvent({ contract: "Core", event: "PayeeSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "PayeeSet");
  await setting(context, e, "PayeeSet", { payee: lc(event.params.payee) });
});

indexer.onEvent({ contract: "Core", event: "ArtistSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "ArtistSet");
  await setting(context, e, "ArtistSet", { artist: lc(event.params.artist) });
});

indexer.onEvent({ contract: "Core", event: "BalanceModuleSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "BalanceModuleSet");
  const { balanceModule, balanceToken, unitPerPoint } = event.params;
  const addr = lc(balanceModule);
  const cur = await ensureEngine(context, e.block.number);
  if (cur.balanceModule && cur.balanceModule !== addr) await patch(context.TreasuryState, cur.balanceModule, { active: false }, "treasury");
  // the treasury_state row of every module, written from events only; a StatementBalanceModule stays at its defaults
  if (addr !== ZERO) {
    // the ledger at the selection block seeds the row: the factory discovers the treasury here, so its constructor and
    // preselection events (a policy set, early funding, settings) are not replayed; a StatementBalanceModule answers
    // none and keeps the defaults
    const seeded = (await readTreasury(context, e, addr)) ?? {};
    const prior = await context.TreasuryState.get(addr);
    context.TreasuryState.set({
      ...(prior ?? { ...blank.treasuryState, id: addr, balanceToken: lc(balanceToken), setBlock: e.block.number }),
      active: true,
      ...seeded,
    } as never);
  }
  await setting(context, e, "BalanceModuleSet", { balanceModule: addr, balanceToken: lc(balanceToken) });
  await settingValue(context, e, "core", "BalanceModuleSet.unitPerPoint", null, { unitPerPoint });
});

indexer.onEvent({ contract: "Core", event: "AdapterSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "AdapterSet");
  await settingValue(context, e, "core", "AdapterSet", null, { adapter: lc(event.params.adapter), allowed: event.params.allowed });
});

indexer.onEvent({ contract: "Core", event: "ControllerSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "ControllerSet");
  const addr = lc(event.params.controller);
  const cur = await ensureEngine(context, e.block.number);
  if (cur.controller && cur.controller !== addr) await patch(context.Controller, cur.controller, { active: false }, "controller");
  const params = await readController(context, e, addr);
  const prior = await context.Controller.get(addr);
  context.Controller.set({
    ...(prior ?? { ...blank.controller, id: addr, setBlock: e.block.number, active: true }),
    setBlock: e.block.number,
    active: true,
    anchorBlock: e.block.number,
    ...params,
  } as never);
  await setting(context, e, "ControllerSet", { controller: addr });
});

indexer.onEvent({ contract: "Core", event: "ControllerLocked", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "ControllerLocked");
  await setting(context, e, "ControllerLocked", { controllerLocked: true });
});
indexer.onEvent({ contract: "Core", event: "BalanceModuleLocked", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "BalanceModuleLocked");
  await setting(context, e, "BalanceModuleLocked", { balanceModuleLocked: true });
});
indexer.onEvent({ contract: "Core", event: "AdaptersLocked", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "AdaptersLocked");
  await setting(context, e, "AdaptersLocked", { adaptersLocked: true });
});
indexer.onEvent({ contract: "Core", event: "SuccessorLocked", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "SuccessorLocked");
  await setting(context, e, "SuccessorLocked", { successorLocked: true });
});
indexer.onEvent({ contract: "Core", event: "SuccessorSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "SuccessorSet");
  await setting(context, e, "SuccessorSet", { successor: lc(event.params.successor) });
});
indexer.onEvent({ contract: "Core", event: "EngineRetired", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "EngineRetired");
  await setting(context, e, "EngineRetired", { retired: true });
});
indexer.onEvent({ contract: "Core", event: "OwnershipTransferStarted", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "OwnershipTransferStarted");
  await setting(context, e, "OwnershipTransferStarted", { pendingOwner: lc(event.params.pending) });
});
indexer.onEvent({ contract: "Core", event: "OwnershipTransferred", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  await coreEvent(context, e, event.params, "OwnershipTransferred");
  await setting(context, e, "OwnershipTransferred", { owner: lc(event.params.to), pendingOwner: null });
});

// Events logged without a projection. Pot and buyback balances come from the snapshot.
for (const name of ["RedeemBurnReleased", "CoinRescued", "NftRescued", "TokenRescued", "Migrated"] as const) {
  indexer.onEvent({ contract: "Core", event: name, fields: FIELDS }, async ({ event, context }) => {
    const e = at(event);
    await coreEvent(context, e, event.params, name);
    await settingValue(context, e, "core", name, null, viemArgs("Core", name, event.params));
  });
}

export type { Activity };
