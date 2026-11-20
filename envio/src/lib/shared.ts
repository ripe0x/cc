import type { EvmOnEventContext } from "envio";
import type { Hex } from "viem";
import { CORE } from "./constants";
import { blank } from "./blank";
import { addTokenCommitment } from "./balance-history";
import { viemArgs } from "./args";

export type Ctx = EvmOnEventContext;

/** Block and transaction fields every handler selects. */
export const FIELDS = { transaction: ["hash", "from"], block: ["timestamp"] } as const;

/** Chain position of the event being handled, in the shape the original's `event` has. */
export type At = {
  block: { number: bigint; timestamp: bigint };
  transaction: { hash: Hex; from?: Hex };
  log: { logIndex: number; address: Hex };
};

type RawEvent = {
  srcAddress: string;
  logIndex: number;
  block: { number: number; timestamp: number };
  transaction: { hash: string; from?: string | undefined };
};

export const lc = (a: string): Hex => a.toLowerCase() as Hex;

export const at = (e: RawEvent): At => ({
  block: { number: BigInt(e.block.number), timestamp: BigInt(e.block.timestamp) },
  transaction: { hash: lc(e.transaction.hash), from: e.transaction.from ? lc(e.transaction.from) : undefined },
  log: { logIndex: e.logIndex, address: lc(e.srcAddress) },
});

/** Bigints become decimal strings so a value fits a json column. */
export const toJson = (v: unknown) =>
  JSON.parse(JSON.stringify(v ?? null, (_k, x) => (typeof x === "bigint" ? x.toString() : x))) as never;

export const idOf = (e: At) => `${e.transaction.hash}:${e.log.logIndex}`;

export const posOf = (e: At) => ({
  blockNumber: e.block.number,
  blockTimestamp: e.block.timestamp,
  txHash: e.transaction.hash,
  logIndex: e.log.logIndex,
});

/** Entities are immutable: read, merge a patch (undefined clears a column), write. */
export async function patch<T extends { id: string }>(
  store: { get(id: string): Promise<T | undefined>; set(e: T): void },
  id: string,
  p: Partial<T> | ((row: T) => Partial<T>),
  what = "row",
): Promise<T> {
  const cur = await store.get(id);
  if (!cur) throw new Error(`${what} ${id} not found`);
  const next = { ...cur, ...(typeof p === "function" ? p(cur) : p) };
  store.set(next);
  return next;
}

/** Writes the `log` row of an event. Every handler calls it first. */
export function record(
  ctx: Ctx,
  e: At,
  args: unknown,
  contract: "core" | "controller" | "treasury" | "creditBid" | "coin" | "credits" | "statements" | "strategy",
  event: string,
) {
  ctx.Log.set({
    ...blank.log,
    id: idOf(e),
    address: lc(e.log.address),
    contract,
    event,
    args: toJson(viemArgs(contract[0]!.toUpperCase() + contract.slice(1), event, (args ?? {}) as object)),
    txFrom: e.transaction.from ? lc(e.transaction.from) : undefined,
    ...posOf(e),
  });
}

type ActivityKind = import("envio").Activity["kind"];

export function act(
  ctx: Ctx,
  e: At,
  row: {
    kind: ActivityKind;
    creditId?: bigint;
    otherCreditId?: bigint;
    statementId?: bigint;
    account?: Hex;
    amount?: bigint;
    amount2?: bigint;
    balanceToken?: string | null;
  },
) {
  ctx.Activity.set({
    ...blank.activity,
    id: idOf(e),
    ...row,
    balanceToken: row.balanceToken ?? undefined,
    ...posOf(e),
  });
}

export type CounterKey = Exclude<keyof typeof blank.stats, "balanceCommittedByToken">;

/** Adds `delta` to the singleton stats row and to the stats row of the event's hour. */
export async function bump(ctx: Ctx, e: At, delta: Partial<Record<CounterKey, bigint>>) {
  const add = <R extends Record<string, unknown>>(row: R): R => ({
    ...row,
    ...Object.fromEntries(Object.entries(delta).map(([k, v]) => [k, (row[k] as bigint) + (v as bigint)])),
  });
  const total = (await ctx.Stats.get(CORE)) ?? { ...blank.stats, id: CORE };
  ctx.Stats.set(add(total));
  const hour = e.block.timestamp / 3600n;
  const h = (await ctx.StatsHourly.get(hour.toString())) ?? { ...blank.statsHourly, id: hour.toString(), hour };
  ctx.StatsHourly.set(add(h));
}

/** Seller payouts plus artist obligations from BalanceFill, in separate token units. Artist debt is included. */
export async function bumpBalanceCommitted(ctx: Ctx, e: At, token: string, committed: bigint) {
  const total = (await ctx.Stats.get(CORE)) ?? { ...blank.stats, id: CORE };
  ctx.Stats.set({ ...total, balanceCommittedByToken: addTokenCommitment(total.balanceCommittedByToken as Record<string, string>, token, committed) });
  const hour = e.block.timestamp / 3600n;
  const h = (await ctx.StatsHourly.get(hour.toString())) ?? { ...blank.statsHourly, id: hour.toString(), hour };
  ctx.StatsHourly.set({ ...h, balanceCommittedByToken: addTokenCommitment(h.balanceCommittedByToken as Record<string, string>, token, committed) });
}
