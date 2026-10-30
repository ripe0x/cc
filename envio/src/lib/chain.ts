import type { Controller, Credit, Engine, Statement, TreasuryState } from "envio";
import type { Hex } from "viem";
import { ZERO, CORE, CORE_DEPLOY_BLOCK } from "./constants";
import { blank } from "./blank";
import { controllerParams, coreInitial, creditRead, snapshotReads, statementArt, statementRead, treasuryParams, unpack, type Snapshot } from "./reads";
import { lc, toJson, type At, type Ctx } from "./shared";
import { parseTokenUri } from "./tokenuri";

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
export async function ensureEngine(ctx: Ctx, block: bigint): Promise<Engine> {
  const found = await ctx.Engine.get(CORE);
  if (found) return found;
  const r = unpack<{ owner: string; payee: string; artist: string; coin: string; costToPot: bigint | number; chosen: boolean; minCc: bigint; settings: Settings }>(
    await ctx.effect(coreInitial, { block: Number(block) }),
  );
  const row: Engine = {
    ...blank.engine,
    id: CORE,
    core: CORE,
    owner: lc(r.owner),
    payee: lc(r.payee),
    artist: lc(r.artist),
    coin: lc(r.coin),
    creditCostToPotBps: Number(r.costToPot),
    chosenComposeOn: r.chosen,
    minCcToChoose: r.minCc,
    ...settingsColumns(r.settings),
    deployBlock: CORE_DEPLOY_BLOCK,
  };
  ctx.Engine.set(row);
  return row;
}

/**
 * One Multicall3 at the event block: pots, rates, Core ETH balance, pile size, flags and the module's available
 * balance. Writes engine_snapshot and the latest-snapshot columns of the engine row. The persisted row marks a block
 * done, so a block with several engine events is read once.
 */
export async function snapshot(ctx: Ctx, block: { number: bigint; timestamp: bigint }) {
  if (await ctx.EngineSnapshot.get(block.number.toString())) return;
  const e = await ensureEngine(ctx, block.number);
  const module = e.balanceModule && e.balanceModule !== ZERO ? e.balanceModule : "";
  const token = module && e.balanceToken && e.balanceToken !== ZERO ? e.balanceToken : "";
  const ctl = e.controller && e.controller !== ZERO ? e.controller : "";
  const r = unpack<Snapshot>(
    await ctx.effect(snapshotReads, { block: Number(block.number), module, token, controller: ctl, coin: e.coin ?? "" }),
  );
  ctx.EngineSnapshot.set({
    ...blank.engineSnapshot,
    id: block.number.toString(),
    blockNumber: block.number,
    blockTimestamp: block.timestamp,
    ethPot: r.ethPot,
    ethToBuyback: r.ethToBuyback,
    ethRedeemBurn: r.ethRedeemBurn,
    ethRate: r.ethRate,
    floorRate: r.floorRate,
    balanceRate: r.balanceRate,
    coreEthBalance: r.coreEthBalance,
    balanceAvailable: module ? (r.balanceAvailable ?? undefined) : undefined,
    balanceToken: module ? (e.balanceToken as Hex) : undefined,
    pileSize: r.pileSize,
    payeeOn: r.payeeOn,
    paused: r.paused,
    valueBuy: r.valueBuy ?? undefined,
    valueSell: r.valueSell ?? undefined,
    referencePrice: r.referencePrice ?? undefined,
    spotPrice: r.spotPrice ?? undefined,
    treasuryBalance: r.treasuryBalance ?? undefined,
    treasuryWorking: r.treasuryWorking ?? undefined,
    claimReserve: r.claimReserve ?? undefined,
    ccSupply: r.ccSupply ?? undefined,
  });
  ctx.Engine.set({
    ...e,
    ethPot: r.ethPot,
    ethToBuyback: r.ethToBuyback,
    ethRedeemBurn: r.ethRedeemBurn,
    ethRate: r.ethRate,
    floorRate: r.floorRate,
    balanceRate: r.balanceRate,
    coreEthBalance: r.coreEthBalance,
    pileSize: r.pileSize,
    payeeOn: r.payeeOn,
    balanceAvailable: module ? (r.balanceAvailable ?? undefined) : undefined,
    snapshotBlock: block.number,
  });
}

/**
 * Credit rows for `ids`, creating the missing ones. Fixed facts (seed, paid time, score, traits), tokenURI and
 * ownerOf are read at the event block; tokenURI is null when the read reverts. `ownerHint` is the owner known from
 * the event.
 */
export async function ensureCredits(ctx: Ctx, e: At, ids: readonly bigint[], ownerHint?: Hex | null) {
  const rows = new Map<bigint, Credit>();
  const missing: bigint[] = [];
  for (const id of ids) {
    const found = await ctx.Credit.get(id.toString());
    if (found) rows.set(id, found);
    else if (!missing.includes(id)) missing.push(id);
  }
  if (missing.length === 0) return rows;
  const reads = await Promise.all(missing.map((id) => ctx.effect(creditRead, { id, block: Number(e.block.number) })));
  missing.forEach((id, i) => {
    const f = reads[i]!;
    const row: Credit = {
      ...blank.credit,
      id: id.toString(),
      seed: f.seed,
      paidAt: f.paidAt,
      score: f.score,
      rating: (Number(f.score) / 10_000).toString(),
      mask: f.mask,
      active: f.active,
      occupied: f.occupied,
      eights: f.eights,
      band: f.band,
      owner: ownerHint ?? (f.owner ? lc(f.owner) : undefined),
      state: "outside",
      tokenUri: f.tokenUri ?? undefined,
    };
    ctx.Credit.set(row);
    rows.set(id, row);
  });
  return rows;
}

export async function ensureCredit(ctx: Ctx, e: At, id: bigint, ownerHint?: Hex | null) {
  return (await ensureCredits(ctx, e, [id], ownerHint)).get(id)!;
}

/** The statement row, state `outside` until the Core composes it. Rating, format and tokenURI are read at the event block. */
export async function ensureStatement(ctx: Ctx, e: At, id: bigint, ownerHint?: Hex | null): Promise<Statement> {
  const found = await ctx.Statement.get(id.toString());
  if (found) return found;
  const r = await ctx.effect(statementRead, { id, block: Number(e.block.number) });
  const row: Statement = {
    ...blank.statement,
    id: id.toString(),
    state: "outside",
    owner: ownerHint ?? (r.owner ? lc(r.owner) : undefined),
    rating: r.rating,
    format: r.format ?? undefined,
    tokenUri: r.tokenUri ?? undefined,
    formatName: r.tokenUri ? (parseTokenUri(r.tokenUri)?.attributes.Format ?? undefined) : undefined,
  };
  ctx.Statement.set(row);
  return row;
}

/** Re-reads a statement's tokenURI at the event block (after HeldFormatSet). */
export async function refreshStatementArt(ctx: Ctx, e: At, id: bigint) {
  const uri = await ctx.effect(statementArt, { id, block: Number(e.block.number) });
  return { tokenUri: uri, formatName: parseTokenUri(uri)?.attributes.Format ?? undefined };
}

/** Column values read from the chain: null becomes undefined, which clears a nullable column. */
const undef = <T extends object>(o: T) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, v === null ? undefined : v]));

export async function readTreasury(ctx: Ctx, e: At, address: Hex): Promise<Partial<TreasuryState> | null> {
  const r = unpack<Record<string, unknown> | null>(await ctx.effect(treasuryParams, { block: Number(e.block.number), address }));
  return r === null ? null : (undef(r) as Partial<TreasuryState>);
}

export async function readController(ctx: Ctx, e: At, address: Hex): Promise<Partial<Controller>> {
  return undef(unpack<Record<string, unknown>>(await ctx.effect(controllerParams, { block: Number(e.block.number), address }))) as Partial<Controller>;
}
