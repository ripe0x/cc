import type { Hex } from "viem";
import { zeroAddress } from "viem";

import { treasuryAbi } from "../abis/Phase2BalanceTreasury";
import { treasuryV2Abi } from "../abis/BalanceTreasuryV2";
import { controllerAbi } from "../abis/ControllerV1";
import { controllerV2Abi } from "../abis/ControllerV2";
import { coreAbi } from "../abis/Core";
import { parseAbi } from "viem";
import { creditScoreAbi, creditsAbi, moduleAbi, multicall3Abi, MULTICALL3, CREDIT_SCORE, statementsAbi } from "../abis/external";

const tokenReadAbi = parseAbi(["function balanceOf(address) view returns (uint256)", "function totalSupply() view returns (uint256)"]);
import { COLLECTIONS, CORE_ADDRESS, CORE_DEPLOY_BLOCK } from "../ponder.config";
import { credit, engine, engineSnapshot, statement } from "../ponder.schema";
import { lc, toJson, type At, type Ctx } from "./shared";
import { parseTokenUri } from "./lib/tokenuri";
import { snapshotOnce } from "./lib/snapshot-gate";

const core = { address: CORE_ADDRESS, abi: coreAbi } as const;
const mc = { multicallAddress: MULTICALL3 } as const;

type Settings = {
  saleToArtistBps: number;
  saleToOperatorBps: number;
  saleToBuybackBps: number;
  feeToRedeemBurnBps: number;
  payeePpm: number;
  buyToArtistBps: number;
  balanceDiscountBps: number;
};

/** Typed copies of the Settings fields the handlers and the web read; the full struct is stored as json. */
export const settingsColumns = (s: Settings) => ({
  settings: toJson(s),
  saleToArtistBps: Number(s.saleToArtistBps),
  saleToOperatorBps: Number(s.saleToOperatorBps),
  saleToBuybackBps: Number(s.saleToBuybackBps),
  feeToRedeemBurnBps: Number(s.feeToRedeemBurnBps),
  payeePpm: Number(s.payeePpm),
  buyToArtistBps: Number(s.buyToArtistBps),
  balanceDiscountBps: Number(s.balanceDiscountBps),
});

/**
 * The engine row. Values the Core constructor sets emit no event, so the first Core event reads them at its
 * block. Returns the row.
 */
export async function ensureEngine(ctx: Ctx) {
  const found = await ctx.db.find(engine, { id: CORE_ADDRESS });
  if (found) return found;
  const [owner, payee, artist, coin, costToPot, chosen, minCc, settings] = await ctx.client.multicall({
    ...mc,
    allowFailure: false,
    contracts: [
      { ...core, functionName: "owner" },
      { ...core, functionName: "payee" },
      { ...core, functionName: "artist" },
      { ...core, functionName: "COIN" },
      { ...core, functionName: "creditCostToPotBps" },
      { ...core, functionName: "chosenComposeOn" },
      { ...core, functionName: "minCcToChoose" },
      { ...core, functionName: "settings" },
    ],
  });
  return ctx.db.insert(engine).values({
    id: CORE_ADDRESS,
    core: CORE_ADDRESS,
    owner: lc(owner),
    payee: lc(payee),
    artist: lc(artist),
    coin: lc(coin),
    creditCostToPotBps: Number(costToPot),
    chosenComposeOn: chosen,
    minCcToChoose: minCc,
    ...settingsColumns(settings),
    deployBlock: CORE_DEPLOY_BLOCK,
  });
}

/**
 * One Multicall3 at the event block: pots, rates, Core ETH balance, pile size, flags and the module's available
 * balance. Writes engine_snapshot and the latest-snapshot columns of the engine row. The DB gate follows Ponder
 * rollbacks and retries, so a failed or orphaned write never marks a block complete in process memory.
 */
export async function snapshot(ctx: Ctx, block: { number: bigint; timestamp: bigint }) {
  await snapshotOnce(block.number, (n) => ctx.db.find(engineSnapshot, { blockNumber: n }), () => snapshotBlock(ctx, block));
}

async function snapshotBlock(ctx: Ctx, block: { number: bigint; timestamp: bigint }) {
  const e = await ensureEngine(ctx);
  const module = e.balanceModule && e.balanceModule !== zeroAddress ? (e.balanceModule as Hex) : null;
  const token = module && e.balanceToken && e.balanceToken !== zeroAddress ? (e.balanceToken as Hex) : null;
  const ctl = e.controller && e.controller !== zeroAddress ? (e.controller as Hex) : null;
  // phase 2 reads, all allowed to fail; positions follow the eleven fixed calls
  const p2 = [
    ctl ? { address: ctl, abi: controllerV2Abi, functionName: "valuePerPoint", args: [false] } : null,
    ctl ? { address: ctl, abi: controllerV2Abi, functionName: "valuePerPoint", args: [true] } : null,
    ctl ? { address: ctl, abi: controllerV2Abi, functionName: "referencePrice" } : null,
    ctl ? { address: ctl, abi: controllerV2Abi, functionName: "spotPrice" } : null,
    token ? { address: token, abi: tokenReadAbi, functionName: "balanceOf", args: [module] } : null,
    module ? { address: module, abi: treasuryAbi, functionName: "working" } : null,
    module ? { address: module, abi: treasuryAbi, functionName: "claimReserve" } : null,
    e.coin ? { address: e.coin as Hex, abi: tokenReadAbi, functionName: "totalSupply" } : null,
  ];
  const r = await ctx.client.multicall({
    ...mc,
    allowFailure: true,
    contracts: ([
      { ...core, functionName: "ethPot" },
      { ...core, functionName: "ethToBuyback" },
      { ...core, functionName: "ethRedeemBurn" },
      { ...core, functionName: "ethRate" },
      { ...core, functionName: "floorRate" },
      { ...core, functionName: "balanceRate" },
      { address: MULTICALL3, abi: multicall3Abi, functionName: "getEthBalance", args: [CORE_ADDRESS] },
      { ...core, functionName: "pileSize" },
      { ...core, functionName: "payeeOn" },
      { ...core, functionName: "paused" },
      module ? { address: module, abi: moduleAbi, functionName: "available" } : { address: MULTICALL3, abi: multicall3Abi, functionName: "getEthBalance", args: [CORE_ADDRESS] },
      ...p2.map((c) => c ?? { address: MULTICALL3, abi: multicall3Abi, functionName: "getEthBalance", args: [CORE_ADDRESS] }),
    ] as readonly unknown[]) as readonly { address: Hex; abi: typeof coreAbi; functionName: "ethPot" }[],
  });
  const need = <T>(i: number): T => {
    const x = r[i];
    if (x.status !== "success") throw new Error(`snapshot call ${i} failed at block ${block.number}: ${x.error}`);
    return x.result as T;
  };
  const row = {
    ethPot: need<bigint>(0),
    ethToBuyback: need<bigint>(1),
    ethRedeemBurn: need<bigint>(2),
    // An unusable value quote reads as a zero ETH bid. A failed RPC read also records zero without stopping
    // snapshots of the remaining state; call success and quote status are distinct at this boundary.
    ethRate: r[3].status === "success" ? (r[3].result as bigint) : 0n,
    floorRate: need<bigint>(4),
    balanceRate: need<bigint>(5),
    coreEthBalance: need<bigint>(6),
    pileSize: need<bigint>(7),
    payeeOn: need<boolean>(8),
    paused: need<boolean>(9),
    balanceAvailable: module && r[10]?.status === "success" ? (r[10].result as bigint) : null,
    balanceToken: module ? (e.balanceToken as Hex) : null,
  };
  // a slot with no contract (null in p2) was padded with a harmless read; it records null
  const opt = (i: number): bigint | null => {
    if (!p2[i]) return null;
    const x = r[11 + i];
    if (x?.status !== "success") return null;
    const v = x.result as bigint | readonly [bigint, boolean];
    return typeof v === "bigint" ? v : v[1] ? v[0] : null;
  };
  const phase2 = {
    valueBuy: opt(0), valueSell: opt(1), referencePrice: opt(2), spotPrice: opt(3),
    treasuryBalance: opt(4), treasuryWorking: opt(5), claimReserve: opt(6), ccSupply: opt(7),
  };
  await ctx.db
    .insert(engineSnapshot)
    .values({ blockNumber: block.number, blockTimestamp: block.timestamp, ...row, ...phase2 })
    .onConflictDoUpdate(() => ({ blockTimestamp: block.timestamp, ...row, ...phase2 }));
  const { paused: _p, balanceToken: _bt, ...latest } = row;
  await ctx.db.update(engine, { id: CORE_ADDRESS }).set({ ...latest, snapshotBlock: block.number });
}

/**
 * Credit rows for `ids`, creating the missing ones. Fixed facts are immutable per id: seed, paid time, score and
 * traits are read once at the latest block (no archive state), in three Multicall3 calls for all missing ids.
 * tokenURI and ownerOf are read at the event block; tokenURI is null when the read reverts (a composed credit is
 * burned). `ownerHint` is the owner known from the event. Only bounded peer groups raise the subcall-calldata
 * batch size; other callers keep Viem's default splitting.
 */
export async function ensureCredits(ctx: Ctx, ids: readonly bigint[], ownerHint?: Hex | null, batchSize?: number) {
  const rows = new Map<bigint, typeof credit.$inferSelect>();
  const missing: bigint[] = [];
  for (const id of ids) {
    const found = await ctx.db.find(credit, { id });
    if (found) rows.set(id, found);
    else missing.push(id);
  }
  if (missing.length === 0) return rows;
  const c = { address: COLLECTIONS.credits, abi: creditsAbi } as const;
  const facts = await ctx.client.multicall({
    ...mc,
    batchSize,
    cache: "immutable",
    allowFailure: false,
    contracts: missing.flatMap((id) => [
      { ...c, functionName: "seedOf", args: [id] },
      { ...c, functionName: "timestampOf", args: [id] },
    ] as const),
  });
  const scored = await ctx.client.multicall({
    ...mc,
    batchSize,
    cache: "immutable",
    allowFailure: false,
    contracts: missing.flatMap((_, i) => {
      const args = [facts[2 * i], facts[2 * i + 1]] as [Hex, bigint];
      return [
        { address: CREDIT_SCORE, abi: creditScoreAbi, functionName: "scoreOf", args },
        { address: CREDIT_SCORE, abi: creditScoreAbi, functionName: "traitsOf", args },
      ] as const;
    }),
  });
  const live = await ctx.client.multicall({
    ...mc,
    batchSize,
    allowFailure: true,
    contracts: missing.flatMap((id) => [
      { ...c, functionName: "tokenURI", args: [id] },
      { ...c, functionName: "ownerOf", args: [id] },
    ] as const),
  });
  for (let i = 0; i < missing.length; i++) {
    const [mask, active, occupied, eights, band] = scored[2 * i + 1] as readonly bigint[];
    const score = scored[2 * i] as bigint;
    const uri = live[2 * i];
    const owner = live[2 * i + 1];
    const row = await ctx.db.insert(credit).values({
      id: missing[i],
      seed: facts[2 * i] as Hex,
      paidAt: facts[2 * i + 1] as bigint,
      score,
      rating: (Number(score) / 10_000).toString(),
      mask: Number(mask),
      active: Number(active),
      occupied: Number(occupied),
      eights: Number(eights),
      band: Number(band),
      owner: ownerHint ?? (owner.status === "success" ? lc(owner.result as string) : null),
      state: "outside",
      tokenUri: uri.status === "success" ? (uri.result as string) : null,
    });
    rows.set(missing[i], row);
  }
  return rows;
}

export async function ensureCredit(ctx: Ctx, id: bigint, ownerHint?: Hex | null) {
  return (await ensureCredits(ctx, [id], ownerHint)).get(id)!;
}

/**
 * The statement row, state `outside` until the Core composes it. Rating is immutable and read at the latest
 * block. Format and tokenURI are read at the event block.
 */
export async function ensureStatement(ctx: Ctx, id: bigint, ownerHint?: Hex | null) {
  const found = await ctx.db.find(statement, { id });
  if (found) return found;
  const s = { address: COLLECTIONS.statements, abi: statementsAbi } as const;
  const [rating] = await ctx.client.multicall({
    ...mc,
    cache: "immutable",
    allowFailure: false,
    contracts: [{ ...s, functionName: "creditScoreOf", args: [id] }],
  });
  const [format, uri, owner] = await ctx.client.multicall({
    ...mc,
    allowFailure: true,
    contracts: [
      { ...s, functionName: "formatOf", args: [id] },
      { ...s, functionName: "tokenURI", args: [id] },
      { ...s, functionName: "ownerOf", args: [id] },
    ],
  });
  const tokenUri = uri.status === "success" ? uri.result : null;
  return ctx.db.insert(statement).values({
    id,
    state: "outside",
    owner: ownerHint ?? (owner.status === "success" ? lc(owner.result) : null),
    rating,
    format: format.status === "success" ? Number(format.result) : null,
    tokenUri,
    formatName: tokenUri ? (parseTokenUri(tokenUri)?.attributes.Format ?? null) : null,
  });
}

/** Re-reads a statement's format and tokenURI at the event block (after HeldFormatSet). */
export async function refreshStatementArt(ctx: Ctx, id: bigint) {
  const uri = await ctx.client.readContract({ address: COLLECTIONS.statements, abi: statementsAbi, functionName: "tokenURI", args: [id] });
  return { tokenUri: uri, formatName: parseTokenUri(uri)?.attributes.Format ?? null };
}

/**
 * The balance module's state at its BalanceModuleSet block, read at that block (the pattern of readController): a
 * module is discovered by the factory at its selection, so its constructor and preselection events are not replayed;
 * this read seeds the row they would have written. The version is detected by a v2-only view (proRataRedeemer): a
 * BalanceTreasuryV2 (phase 3) takes the v2 path, a Phase2BalanceTreasury the phase 2 path, and a StatementBalanceModule
 * answers neither and returns null, leaving the row at its defaults.
 */
export async function readTreasury(ctx: Ctx, address: Hex) {
  const [probe] = await ctx.client.multicall({
    ...mc,
    allowFailure: true,
    contracts: [{ address, abi: treasuryV2Abi, functionName: "proRataRedeemer" }],
  });
  if (probe.status === "success") return readTreasuryV2(ctx, address);
  const t = { address, abi: treasuryAbi } as const;
  const r = await ctx.client.multicall({
    ...mc,
    allowFailure: true,
    contracts: [
      { ...t, functionName: "claimReserve" },
      { ...t, functionName: "totalOwed" },
      { ...t, functionName: "configEpoch" },
      { ...t, functionName: "redemptionPolicy" },
      { ...t, functionName: "conversionToClaimBps" },
      { ...t, functionName: "redemptionFeeBps" },
      { ...t, functionName: "conversionEnabled" },
      { ...t, functionName: "workingPaymentsEnabled" },
      { ...t, functionName: "ccRedemptionEnabled" },
      { ...t, functionName: "minimumWorkingBalance" },
      { ...t, functionName: "migrated" },
    ],
  });
  const ok = <T,>(i: number): T | null => (r[i].status === "success" ? (r[i].result as T) : null);
  const big = (i: number) => { const v = ok<bigint | number>(i); return v === null ? null : BigInt(v); };
  const num = (i: number) => { const v = ok<bigint | number>(i); return v === null ? null : Number(v); };
  if (r[0].status !== "success") return null;
  return {
    version: "phase2",
    claimReserve: big(0),
    totalOwed: big(1) ?? 0n,
    configEpoch: big(2),
    policy: ok<Hex>(3) ? (ok<Hex>(3)!.toLowerCase() as Hex) : null,
    conversionToClaimBps: num(4),
    redemptionFeeBps: num(5),
    conversionEnabled: ok<boolean>(6),
    workingPaymentsEnabled: ok<boolean>(7),
    ccRedemptionEnabled: ok<boolean>(8),
    minimumWorkingBalance: big(9),
    migrated: ok<boolean>(10) ?? false,
  };
}

/** The phase 3 treasury's state at its BalanceModuleSet block. The v2 third switch is the bid, not CC redemption. */
async function readTreasuryV2(ctx: Ctx, address: Hex) {
  const t = { address, abi: treasuryV2Abi } as const;
  const r = await ctx.client.multicall({
    ...mc,
    allowFailure: true,
    contracts: [
      { ...t, functionName: "proRataRedeemer" },
      { ...t, functionName: "cushion" },
      { ...t, functionName: "bidBudget" },
      { ...t, functionName: "bidShareBps" },
      { ...t, functionName: "totalShareBps" },
      { ...t, functionName: "conversionToClaimBps" },
      { ...t, functionName: "conversionEnabled" },
      { ...t, functionName: "workingPaymentsEnabled" },
      { ...t, functionName: "bidEnabled" },
      { ...t, functionName: "paused" },
      { ...t, functionName: "totalOwed" },
      { ...t, functionName: "migrated" },
    ],
  });
  const ok = <T,>(i: number): T | null => (r[i].status === "success" ? (r[i].result as T) : null);
  const big = (i: number) => { const v = ok<bigint | number>(i); return v === null ? null : BigInt(v); };
  const num = (i: number) => { const v = ok<bigint | number>(i); return v === null ? null : Number(v); };
  return {
    version: "v2",
    proRataRedeemer: ok<Hex>(0) ? (ok<Hex>(0)!.toLowerCase() as Hex) : null,
    cushion: big(1),
    bidBudget: big(2),
    bidShareBps: num(3),
    totalShareBps: num(4),
    conversionToClaimBps: num(5),
    conversionEnabled: ok<boolean>(6),
    workingPaymentsEnabled: ok<boolean>(7),
    bidEnabled: ok<boolean>(8),
    paused: ok<boolean>(9),
    totalOwed: big(10) ?? 0n,
    migrated: ok<boolean>(11) ?? false,
  };
}

export async function readController(ctx: Ctx, address: Hex) {
  const k = { address, abi: controllerAbi } as const;
  const v2 = { address, abi: controllerV2Abi } as const;
  // tolerant reads: ControllerV2 has no anchorHalfLife, anchorMinCost or storedAnchorBps (its anchorBps is a derived
  // read only value) and ControllerV1 has none of the statement sale views, so a failing read leaves its column null
  const [markupBps, startCapBps, decayHours, anchorHalfLife, anchorMinCost, saleOn, window, spreadBps, startBps, anchorBps, poolSet, poolKey, ageEligibilityOn, salesOn, saleMult, redeemDelay] =
    await ctx.client.multicall({
      ...mc,
      allowFailure: true,
      contracts: [
        { ...k, functionName: "markupBps" },
        { ...k, functionName: "startCapBps" },
        { ...k, functionName: "decayHours" },
        { ...k, functionName: "anchorHalfLife" },
        { ...k, functionName: "anchorMinCost" },
        { ...k, functionName: "creditSaleOn" },
        { ...k, functionName: "creditWindow" },
        { ...k, functionName: "creditSpreadBps" },
        { ...k, functionName: "creditStartBps" },
        { ...k, functionName: "storedAnchorBps" },
        { ...k, functionName: "balancePoolKeySet" },
        { ...k, functionName: "balancePoolKey" },
        { ...k, functionName: "ageEligibilityOn" },
        { ...v2, functionName: "statementSalesEnabled" },
        { ...v2, functionName: "statementSaleMultiplierBps" },
        { ...v2, functionName: "statementRedeemDelaySeconds" },
      ],
    });
  const ok = <T,>(r: { status: string; result?: unknown }): T | null => (r.status === "success" ? (r.result as T) : null);
  const num = (r: { status: string; result?: unknown }) => {
    const v = ok<bigint | number>(r);
    return v === null ? null : Number(v);
  };
  const big = (r: { status: string; result?: unknown }) => {
    const v = ok<bigint | number>(r);
    return v === null ? null : BigInt(v);
  };
  const key = ok<readonly [Hex, Hex, number, number, Hex]>(poolKey);
  // a V2 controller without storedAnchorBps answers anchorBps (the derived value) for the same column
  const anchor = anchorBps.status === "success"
    ? big(anchorBps)
    : big((await ctx.client.multicall({ ...mc, allowFailure: true, contracts: [{ ...k, functionName: "anchorBps" }] }))[0]);
  return {
    markupBps: num(markupBps),
    startCapBps: big(startCapBps),
    decayHours: num(decayHours),
    anchorHalfLife: big(anchorHalfLife),
    anchorMinCost: ok<bigint>(anchorMinCost),
    saleOn: ok<boolean>(saleOn),
    ageEligibilityOn: ok<boolean>(ageEligibilityOn),
    window: big(window),
    spreadBps: num(spreadBps),
    startBps: big(startBps),
    anchorBps: anchor,
    balancePoolSet: ok<boolean>(poolSet) ?? false,
    balanceCurrency0: key ? lc(key[0]) : null,
    balanceCurrency1: key ? lc(key[1]) : null,
    balanceFee: key ? Number(key[2]) : null,
    balanceTickSpacing: key ? Number(key[3]) : null,
    balanceHooks: key ? lc(key[4]) : null,
    statementSalesEnabled: ok<boolean>(salesOn),
    statementSaleMultiplierBps: big(saleMult),
    statementRedeemDelaySeconds: big(redeemDelay),
    ...(await readQuote(ctx, address)),
  };
}

/** The protected price state of a controller at the event block; a controller without it leaves the columns null. */
async function readQuote(ctx: Ctx, address: Hex) {
  const k = { address, abi: controllerAbi } as const;
  const [quote, referencePrice, referenceTime] = await ctx.client.multicall({
    ...mc,
    allowFailure: true,
    contracts: [
      { ...k, functionName: "quote" },
      { ...k, functionName: "referencePrice" },
      { ...k, functionName: "referenceTime" },
    ],
  });
  const q = quote.status === "success" ? (quote.result as readonly [number, number, number, number, number, bigint]) : null;
  return {
    referenceRateBpsPerHour: q ? BigInt(q[0]) : null,
    referenceStepBps: q ? Number(q[1]) : null,
    referenceTolBps: q ? Number(q[2]) : null,
    referenceMaxStale: q ? BigInt(q[3]) : null,
    referenceMinSeconds: q ? BigInt(q[4]) : null,
    referenceMinLiquidity: q ? q[5] : null,
    referencePrice: referencePrice.status === "success" ? (referencePrice.result as bigint) : null,
    referenceTime: referenceTime.status === "success" ? BigInt(referenceTime.result as number) : null,
  };
}

export type { At };
