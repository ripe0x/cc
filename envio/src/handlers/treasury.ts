// Port of the treasury handlers: phase 2 (Phase2BalanceTreasury) and phase 3 (BalanceTreasuryV2). One factory source
// (the balance module named by Core.BalanceModuleSet) decodes both ABIs, so both versions share these handlers.
// Events the two versions emit with the same signature have one handler; the five that differ in signature are
// registered under a suffix (…Phase2, …V2, see config.yaml).
//
// Not ported: the CreditBid and MarketRedeemer sources. The original configures them only when a phase 3 deployment
// record exists, and deployments/ has none for chain 1.
import { indexer, type Redeemer, type TreasuryEvent, type TreasuryState } from "envio";
import { blank } from "../lib/blank";
import { migratedOutPatch, migrationReceivedPatch } from "../lib/migration";
import { at, FIELDS, idOf, lc, posOf, record, toJson, type At, type Ctx } from "../lib/shared";
import type { Hex } from "viem";

type StateTotalKey = "convertedTotal" | "contributedTotal" | "conversions" | "redeemedCcTotal" | "paidBalanceTotal" | "redemptions" | "ownerFundedTotal" | "ownerAllocatedTotal" | "ownerReturnedTotal" | "ownerWithdrawnTotal" | "accruedTotal" | "claimedTotal" | "totalOwed" | "bidInTotal" | "bidOutTotal" | "bidFills" | "bidCreditsTotal" | "sweptSurplusTotal" | "bucketsFundedTotal" | "allocatedTotal" | "unallocatedTotal" | "claimReleasedTotal";
type RedeemerTotalKey = "redeemedCcTotal" | "paidBalanceTotal" | "redemptions" | "allocatedTotal" | "unallocatedTotal" | "claimReleasedTotal";

/**
 * Every treasury event: the log row, the treasury_event row and the treasury_state patch, with the running totals
 * added. State comes from the event's own fields only; nothing is read from the chain.
 */
async function treasuryEventRow(
  ctx: Ctx,
  e: At,
  args: unknown,
  name: string,
  row: Pick<TreasuryEvent, "kind"> & Partial<Omit<TreasuryEvent, "id" | "treasury" | "kind" | "blockNumber" | "blockTimestamp" | "txHash" | "logIndex">>,
  p: Partial<Omit<TreasuryState, "id" | "balanceToken" | "setBlock" | "active">> = {},
  totals: Partial<Record<StateTotalKey, bigint>> = {},
) {
  record(ctx, e, args, "treasury", name);
  const id = lc(e.log.address);
  ctx.TreasuryEvent.set({ ...blank.treasuryEvent, id: idOf(e), treasury: id, ...row, ...posOf(e) });
  const cur = await ctx.TreasuryState.get(id);
  if (!cur) throw new Error(`${name} from treasury ${id} before its BalanceModuleSet`);
  const added = Object.fromEntries(Object.entries(totals).map(([k, v]) => [k, (cur as unknown as Record<string, bigint>)[k]! + v]));
  ctx.TreasuryState.set({ ...cur, ...p, ...added, lastEventBlock: e.block.number });
}

/** Upserts the per-redeemer registry row (phase 3), adding the running totals. The redeemer is scoped to its treasury. */
async function bumpRedeemer(
  ctx: Ctx,
  e: At,
  redeemerAddr: Hex,
  p: Partial<Omit<Redeemer, "id" | "treasury" | "redeemer" | "firstBlock" | "lastEventBlock">> = {},
  totals: Partial<Record<RedeemerTotalKey, bigint>> = {},
) {
  const treasury = lc(e.log.address);
  const id = `${treasury}:${redeemerAddr}`;
  const cur = await ctx.Redeemer.get(id);
  if (!cur) {
    ctx.Redeemer.set({ ...blank.redeemer, id, treasury, redeemer: redeemerAddr, firstBlock: e.block.number, lastEventBlock: e.block.number, ...p, ...totals });
    return;
  }
  const added = Object.fromEntries(Object.entries(totals).map(([k, v]) => [k, (cur as unknown as Record<string, bigint>)[k]! + v]));
  ctx.Redeemer.set({ ...cur, ...p, ...added, lastEventBlock: e.block.number });
}

const T = <E extends string>(event: E) => ({ contract: "Treasury" as const, event, fields: FIELDS });

// phase 2: allocated is the amount sent to the claim reserve; claimReserve is the reserve after the conversion
indexer.onEvent(T("StatementConvertedPhase2"), async ({ event, context }) => {
  const e = at(event);
  const { statementId, received, allocated, contributionBps, claimReserve } = event.params;
  await treasuryEventRow(context, e, event.params, "StatementConverted",
    { kind: "statement_converted", statementId, amount: received, claimReserve, bps: Number(contributionBps), detail: toJson({ allocated }) },
    { claimReserve },
    { convertedTotal: received, contributedTotal: allocated, conversions: 1n });
});

// v2: toProRata is the amount contributed to the pro-rata redeemer's bucket; there is no single claim reserve
indexer.onEvent(T("StatementConvertedV2"), async ({ event, context }) => {
  const e = at(event);
  const { statementId, received, toProRata, contributionBps } = event.params;
  await treasuryEventRow(context, e, event.params, "StatementConverted",
    { kind: "statement_converted", statementId, amount: received, bps: Number(contributionBps), detail: toJson({ toProRata }) },
    {},
    { convertedTotal: received, contributedTotal: toProRata, conversions: 1n });
});

indexer.onEvent(T("PaymentAccrued"), async ({ event, context }) => {
  const { to, amount } = event.params;
  await treasuryEventRow(context, at(event), event.params, "PaymentAccrued", { kind: "payment_accrued", amount, actor: lc(to) }, {}, { accruedTotal: amount, totalOwed: amount });
});

indexer.onEvent(T("OwedClaimed"), async ({ event, context }) => {
  const { to, amount } = event.params;
  await treasuryEventRow(context, at(event), event.params, "OwedClaimed", { kind: "owed_claimed", amount, actor: lc(to) }, {}, { claimedTotal: amount, totalOwed: -amount });
});

// phase 2 public redemption: the burner's CC for a share of the claim reserve. the reserve and the supply are after the burn
indexer.onEvent(T("CCRedeemedPhase2"), async ({ event, context }) => {
  const { burner, recipient, ccIn, balanceOut, claimReserve, ccSupply, configEpoch } = event.params;
  await treasuryEventRow(context, at(event), event.params, "CCRedeemed",
    { kind: "cc_redeemed", ccIn, balanceOut, claimReserve, ccSupply, configEpoch: BigInt(configEpoch), actor: lc(burner), recipient: lc(recipient) },
    { claimReserve, configEpoch: BigInt(configEpoch) },
    { redeemedCcTotal: ccIn, paidBalanceTotal: balanceOut, redemptions: 1n });
});

// v2 public redemption through a registered redeemer: ccIn burned, amount paid, mode immediate/linear/deferred with a
// claimId for a held claim. the redeemer draws from its own bucket; the current bucket is a live read
indexer.onEvent(T("CCRedeemedV2"), async ({ event, context }) => {
  const e = at(event);
  const { redeemer: redeemerAddr, burner, recipient, ccIn, amount, mode, duration, claimId, epoch } = event.params;
  const r = lc(redeemerAddr);
  await treasuryEventRow(context, e, event.params, "CCRedeemed",
    { kind: "cc_redeemed", ccIn, balanceOut: amount, configEpoch: BigInt(epoch), actor: lc(burner), recipient: lc(recipient), redeemer: r, detail: toJson({ mode: Number(mode), duration: Number(duration), claimId }) },
    {},
    { redeemedCcTotal: ccIn, paidBalanceTotal: amount, redemptions: 1n });
  await bumpRedeemer(context, e, r, {}, { redeemedCcTotal: ccIn, paidBalanceTotal: amount, redemptions: 1n });
});

// phase 2 switches: conversion, working payments and CC redemption
indexer.onEvent(T("SwitchesSetPhase2"), async ({ event, context }) => {
  const { conversionEnabled, workingPaymentsEnabled, ccRedemptionEnabled } = event.params;
  await treasuryEventRow(context, at(event), event.params, "SwitchesSet",
    { kind: "switches_set", detail: toJson({ conversionEnabled, workingPaymentsEnabled, ccRedemptionEnabled }) },
    { conversionEnabled, workingPaymentsEnabled, ccRedemptionEnabled });
});

// v2 switches: conversion and working payments; redemption and the bid are spender switches (SpenderSwitched)
indexer.onEvent(T("SwitchesSetV2"), async ({ event, context }) => {
  const { conversionEnabled, workingPaymentsEnabled } = event.params;
  await treasuryEventRow(context, at(event), event.params, "SwitchesSet",
    { kind: "switches_set", detail: toJson({ conversionEnabled, workingPaymentsEnabled }) },
    { conversionEnabled, workingPaymentsEnabled });
});

indexer.onEvent(T("ConversionToClaimBpsSet"), async ({ event, context }) => {
  const bps = Number(event.params.bps);
  await treasuryEventRow(context, at(event), event.params, "ConversionToClaimBpsSet", { kind: "contribution_set", bps }, { conversionToClaimBps: bps });
});

indexer.onEvent(T("RedemptionFeeSet"), async ({ event, context }) => {
  const bps = Number(event.params.bps);
  const configEpoch = BigInt(event.params.configEpoch);
  await treasuryEventRow(context, at(event), event.params, "RedemptionFeeSet", { kind: "fee_set", bps, configEpoch }, { redemptionFeeBps: bps, configEpoch });
});

indexer.onEvent(T("MinimumWorkingBalanceSet"), async ({ event, context }) => {
  const { amount } = event.params;
  await treasuryEventRow(context, at(event), event.params, "MinimumWorkingBalanceSet", { kind: "minimum_working_set", amount }, { minimumWorkingBalance: amount });
});

// a policy replacement turns CC redemption off; the treasury emits SwitchesSet in the same transaction
indexer.onEvent(T("RedemptionPolicySet"), async ({ event, context }) => {
  const policy = lc(event.params.policy);
  const configEpoch = BigInt(event.params.configEpoch);
  await treasuryEventRow(context, at(event), event.params, "RedemptionPolicySet", { kind: "policy_set", policy, configEpoch }, { policy, configEpoch });
});

// the owner's reserve changes, kept apart from public redemptions
indexer.onEvent(T("ClaimsFunded"), async ({ event, context }) => {
  const { from, amount, claimReserve } = event.params;
  await treasuryEventRow(context, at(event), event.params, "ClaimsFunded", { kind: "claims_funded", amount, claimReserve, actor: lc(from) }, { claimReserve }, { ownerFundedTotal: amount });
});

indexer.onEvent(T("ClaimsAllocated"), async ({ event, context }) => {
  const { amount, claimReserve } = event.params;
  await treasuryEventRow(context, at(event), event.params, "ClaimsAllocated", { kind: "claims_allocated", amount, claimReserve }, { claimReserve }, { ownerAllocatedTotal: amount });
});

indexer.onEvent(T("ClaimsReturned"), async ({ event, context }) => {
  const { amount, claimReserve } = event.params;
  const configEpoch = BigInt(event.params.configEpoch);
  await treasuryEventRow(context, at(event), event.params, "ClaimsReturned", { kind: "claims_returned", amount, claimReserve, configEpoch }, { claimReserve, configEpoch }, { ownerReturnedTotal: amount });
});

indexer.onEvent(T("WorkingWithdrawn"), async ({ event, context }) => {
  const { to, amount } = event.params;
  await treasuryEventRow(context, at(event), event.params, "WorkingWithdrawn", { kind: "working_withdrawn", amount, actor: lc(to) }, {}, { ownerWithdrawnTotal: amount });
});

indexer.onEvent(T("TreasuryMigratedPhase2"), async ({ event, context }) => {
  const { successor, moved, claimsImported } = event.params;
  const configEpoch = BigInt(event.params.configEpoch);
  await treasuryEventRow(context, at(event), event.params, "TreasuryMigrated",
    { kind: "migrated_out", amount: moved, claimReserve: 0n, configEpoch, actor: lc(successor), detail: toJson({ claimsImported }) },
    migratedOutPatch(successor, configEpoch) as never);
});

// v2 `migrateTo` (the last resort): custody less the debt and the committed payouts moves; the pro-rata bucket is
// exported as the successor's claim import. v2 keeps no treasury wide epoch, so the stored one is carried
indexer.onEvent(T("TreasuryMigratedV2"), async ({ event, context }) => {
  const e = at(event);
  const { successor, moved, claimsExported } = event.params;
  const cur = await context.TreasuryState.get(lc(e.log.address));
  const configEpoch = cur?.configEpoch ?? 0n;
  await treasuryEventRow(context, e, event.params, "TreasuryMigrated",
    { kind: "migrated_out", amount: moved, claimReserve: 0n, configEpoch, actor: lc(successor), detail: toJson({ claimsExported }) },
    migratedOutPatch(successor, configEpoch) as never);
});

// phase 2: the destination's reserve becomes the event's figure (its own plus the import) at the given epoch
indexer.onEvent(T("MigrationReceivedPhase2"), async ({ event, context }) => {
  const { predecessor, claimsImported, claimReserve } = event.params;
  const configEpoch = BigInt(event.params.configEpoch);
  await treasuryEventRow(context, at(event), event.params, "MigrationReceived",
    { kind: "migration_received", amount: claimsImported, claimReserve, configEpoch, actor: lc(predecessor) },
    migrationReceivedPatch(claimReserve, configEpoch) as never);
});

// v2: the predecessor's balance arrives into custody; v2 has per-redeemer buckets, not a single reserve or epoch here
indexer.onEvent(T("MigrationReceivedV2"), async ({ event, context }) => {
  const { predecessor, claimsImported, custody } = event.params;
  await treasuryEventRow(context, at(event), event.params, "MigrationReceived",
    { kind: "migration_received", amount: claimsImported, actor: lc(predecessor), detail: toJson({ custody }) });
});

// ---- phase 3 only (BalanceTreasuryV2) --------------------------------------------------------------------------------

// surplus working funds moved into the spender buckets in the owner's shares. the per spender split is not in the event
indexer.onEvent(T("Swept"), async ({ event, context }) => {
  const { surplus, toBuckets } = event.params;
  await treasuryEventRow(context, at(event), event.params, "Swept",
    { kind: "swept", amount: surplus, detail: toJson({ toBuckets }) }, {},
    { sweptSurplusTotal: surplus, bucketsFundedTotal: toBuckets });
});

// a module spender paid from its own bucket; bucket is the spender's bucket after the draw
indexer.onEvent(T("Drawn"), async ({ event, context }) => {
  const e = at(event);
  const { spender, to, amount, accrued, bucket } = event.params;
  const addr = lc(spender);
  await treasuryEventRow(context, e, event.params, "Drawn", { kind: "drawn", amount, actor: lc(to), redeemer: addr, detail: toJson({ accrued, bucket }) });
  await bumpRedeemer(context, e, addr, {}, { paidBalanceTotal: amount });
});

// owner surplus moved into (Allocated) or out of (Unallocated) a spender's bucket
indexer.onEvent(T("Allocated"), async ({ event, context }) => {
  const e = at(event);
  const { spender: r, amount } = event.params;
  const addr = lc(r);
  await treasuryEventRow(context, e, event.params, "Allocated", { kind: "allocated", amount, redeemer: addr }, {}, { allocatedTotal: amount });
  await bumpRedeemer(context, e, addr, {}, { allocatedTotal: amount });
});

indexer.onEvent(T("Unallocated"), async ({ event, context }) => {
  const e = at(event);
  const { spender: r, amount } = event.params;
  const addr = lc(r);
  await treasuryEventRow(context, e, event.params, "Unallocated", { kind: "unallocated", amount, redeemer: addr }, {}, { unallocatedTotal: amount });
  await bumpRedeemer(context, e, addr, {}, { unallocatedTotal: amount });
});

indexer.onEvent(T("SpenderRegistered"), async ({ event, context }) => {
  const e = at(event);
  const { spender: r, activeAt } = event.params;
  const addr = lc(r);
  await treasuryEventRow(context, e, event.params, "SpenderRegistered", { kind: "redeemer_registered", redeemer: addr, detail: toJson({ activeAt }) });
  await bumpRedeemer(context, e, addr, { registered: true, activeAt: BigInt(activeAt) });
});

indexer.onEvent(T("SpenderCapsSet"), async ({ event, context }) => {
  const e = at(event);
  const { spender: r, perCall, perPeriod, lifetime, epoch } = event.params;
  const addr = lc(r);
  await treasuryEventRow(context, e, event.params, "SpenderCapsSet", { kind: "redeemer_caps_set", redeemer: addr, configEpoch: BigInt(epoch), detail: toJson({ perCall, perPeriod, lifetime }) });
  await bumpRedeemer(context, e, addr, { perCall, perPeriod, lifetime, epoch: BigInt(epoch) });
});

indexer.onEvent(T("SpenderSwitched"), async ({ event, context }) => {
  const e = at(event);
  const { spender: r, on } = event.params;
  const addr = lc(r);
  await treasuryEventRow(context, e, event.params, "SpenderSwitched", { kind: "redeemer_switched", redeemer: addr, detail: toJson({ on }) });
  await bumpRedeemer(context, e, addr, { on });
});

// a spender's share of a sweep and the running total (treasury-wide)
indexer.onEvent(T("SharesSet"), async ({ event, context }) => {
  const e = at(event);
  const { spender: r, shareBps, totalShareBps } = event.params;
  const addr = lc(r);
  await treasuryEventRow(context, e, event.params, "SharesSet",
    { kind: "shares_set", redeemer: addr, bps: Number(shareBps), detail: toJson({ totalShareBps }) },
    { totalShareBps: Number(totalShareBps) });
  await bumpRedeemer(context, e, addr, { shareBps: Number(shareBps) });
});

// a vesting or deferred claim paid out to its recipient; the claim was created in full at redemption time
indexer.onEvent(T("ClaimReleased"), async ({ event, context }) => {
  const { claimId, recipient, amount } = event.params;
  await treasuryEventRow(context, at(event), event.params, "ClaimReleased",
    { kind: "claim_released", amount, recipient: lc(recipient), detail: toJson({ claimId }) }, {},
    { claimReleasedTotal: amount });
});

indexer.onEvent(T("CushionSet"), async ({ event, context }) => {
  const { cushion } = event.params;
  await treasuryEventRow(context, at(event), event.params, "CushionSet", { kind: "cushion_set", amount: cushion }, { cushion });
});

indexer.onEvent(T("PausedSet"), async ({ event, context }) => {
  const { paused } = event.params;
  await treasuryEventRow(context, at(event), event.params, "PausedSet", { kind: "paused_set", detail: toJson({ paused }) }, { paused });
});

indexer.onEvent(T("TokenRescued"), async ({ event, context }) => {
  record(context, at(event), event.params, "treasury", "TokenRescued");
});
