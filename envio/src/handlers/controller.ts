// Port of the Controller handlers (a factory source: every controller named by Core.ControllerSet).
import { indexer, type Controller } from "envio";
import { blank } from "../lib/blank";
import { at, FIELDS, idOf, lc, posOf, record, toJson, type At, type Ctx } from "../lib/shared";
import { viemArgs } from "../lib/args";
import { settingValue } from "./core";

async function controllerSetting(ctx: Ctx, e: At, name: string, p: { [K in keyof Controller]?: Controller[K] | null }) {
  const id = lc(e.log.address);
  const cur = await ctx.Controller.get(id);
  if (!cur) throw new Error(`${name} from controller ${id} before its ControllerSet`);
  const before = Object.fromEntries(Object.keys(p).map((k) => [k, (cur as Record<string, unknown>)[k] ?? null]));
  ctx.Controller.set({ ...cur, ...Object.fromEntries(Object.entries(p).map(([k, v]) => [k, v === null ? undefined : v])) });
  await settingValue(ctx, e, "controller", name, before, p);
}

indexer.onEvent({ contract: "Controller", event: "Bought", fields: FIELDS }, async ({ event, context }) => {
  record(context, at(event), event.params, "controller", "Bought");
});

indexer.onEvent({ contract: "Controller", event: "AnchorMoved", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "controller", "AnchorMoved");
  const { sid, saleBps, anchorBps } = event.params;
  context.AnchorMove.set({ id: idOf(e), controller: lc(event.srcAddress), statementId: sid, saleBps, anchorBps: BigInt(anchorBps), ...posOf(e) });
  const id = lc(event.srcAddress);
  const cur = await context.Controller.get(id);
  if (!cur) throw new Error(`controller ${id} not found`);
  context.Controller.set({ ...cur, anchorBps: BigInt(anchorBps), anchorBlock: e.block.number });
});

indexer.onEvent({ contract: "Controller", event: "SaleSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "controller", "SaleSet");
  const s = event.params.sale;
  await controllerSetting(context, e, "SaleSet", {
    markupBps: Number(s.markupBps),
    startCapBps: BigInt(s.startCapBps),
    decayHours: Number(s.decayHours),
    anchorHalfLife: BigInt(s.anchorHalfLife),
    anchorMinCost: s.anchorMinCost,
  });
});

indexer.onEvent({ contract: "Controller", event: "CreditSaleSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "controller", "CreditSaleSet");
  const c = event.params.credit;
  await controllerSetting(context, e, "CreditSaleSet", {
    saleOn: c.saleOn,
    window: BigInt(c.window),
    spreadBps: Number(c.spreadBps),
    startBps: BigInt(c.startBps),
  });
});

indexer.onEvent({ contract: "Controller", event: "AgeEligibilitySet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "controller", "AgeEligibilitySet");
  await controllerSetting(context, e, "AgeEligibilitySet", { ageEligibilityOn: event.params.on });
});

indexer.onEvent({ contract: "Controller", event: "AnchorBpsSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "controller", "AnchorBpsSet");
  await controllerSetting(context, e, "AnchorBpsSet", { anchorBps: BigInt(event.params.anchorBps), anchorBlock: e.block.number });
});

indexer.onEvent({ contract: "Controller", event: "BalancePoolKeySet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "controller", "BalancePoolKeySet");
  const a = event.params;
  await controllerSetting(context, e, "BalancePoolKeySet", {
    balancePoolSet: true,
    balanceCurrency0: lc(a.currency0),
    balanceCurrency1: lc(a.currency1),
    balanceFee: Number(a.fee),
    balanceTickSpacing: Number(a.tickSpacing),
    balanceHooks: lc(a.hooks),
  });
});

// the protected price (decision 148): the quote settings and the rate limited reference of the balance token
indexer.onEvent({ contract: "Controller", event: "QuoteSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "controller", "QuoteSet");
  const q = event.params.quote;
  await controllerSetting(context, e, "QuoteSet", {
    referenceRateBpsPerHour: BigInt(q.referenceRateBpsPerHour),
    referenceStepBps: Number(q.referenceStepBps),
    referenceTolBps: Number(q.tolBps),
    referenceMaxStale: BigInt(q.referenceMaxStale),
    referenceMinSeconds: BigInt(q.referenceMinSeconds),
    referenceMinLiquidity: q.minLiquidity,
  });
});

indexer.onEvent({ contract: "Controller", event: "ReferenceRefreshed", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "controller", "ReferenceRefreshed");
  const id = lc(event.srcAddress);
  const cur = await context.Controller.get(id);
  if (!cur) throw new Error(`ReferenceRefreshed from controller ${id} before its ControllerSet`);
  context.Controller.set({ ...cur, referencePrice: event.params.referencePrice, referenceSpot: event.params.spot, referenceTime: e.block.timestamp });
});

// ControllerV2 statement sale terms: the sale switch, the persistent ask multiple and the age after which a statement
// is redeemable (atFloor)
indexer.onEvent({ contract: "Controller", event: "StatementSalesSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "controller", "StatementSalesSet");
  await controllerSetting(context, e, "StatementSalesSet", { statementSalesEnabled: event.params.enabled });
});

indexer.onEvent({ contract: "Controller", event: "StatementSaleMultiplierSet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "controller", "StatementSaleMultiplierSet");
  await controllerSetting(context, e, "StatementSaleMultiplierSet", { statementSaleMultiplierBps: BigInt(event.params.multiplierBps) });
});

indexer.onEvent({ contract: "Controller", event: "StatementRedeemDelaySet", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "controller", "StatementRedeemDelaySet");
  await controllerSetting(context, e, "StatementRedeemDelaySet", { statementRedeemDelaySeconds: BigInt(event.params.delaySeconds) });
});

// ControllerV3: the idle-loosening premium and the CC price reference (pool key, quote settings) are recorded as
// controller setting history; the fill sync pointer, recorded resales and CC reference refreshes go to the log only.
for (const name of ["IdleLooseningSet", "CcPoolKeySet", "CcQuoteSet"] as const) {
  indexer.onEvent({ contract: "Controller", event: name, fields: FIELDS }, async ({ event, context }) => {
    const e = at(event);
    record(context, e, event.params, "controller", name);
    await settingValue(context, e, "controller", name, null, viemArgs("Controller", name, event.params));
  });
}
for (const name of ["FillSynced", "CreditSoldRecorded", "CcReferenceRefreshed"] as const) {
  indexer.onEvent({ contract: "Controller", event: name, fields: FIELDS }, async ({ event, context }) => {
    record(context, at(event), event.params, "controller", name);
  });
}

void blank;
void toJson;
