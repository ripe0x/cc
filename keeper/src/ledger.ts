// The daily budget ledger and the revert loop breaker. The ledger counts, per UTC day, the gas the keeper's wallet
// spent and the payments the Core sent it; the budget caps the net loss (spent minus received). A send is allowed only
// when its own gross cost fits the remaining budget, as if it were not paid. The ledger is a JSON file per day under
// STATE_DIR; it holds amounts and hashes only.

import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import type { Door } from "./config.ts";

export interface Day {
  day: string;
  spent: bigint;
  received: bigint;
  txs: number;
  last?: string;
}

export const utcDay = (ms: number) => new Date(ms).toISOString().slice(0, 10);

export function atomicJson(path: string, value: unknown) {
  const temp = `${path}.${randomUUID()}.tmp`;
  try {
    const fd = openSync(temp, "wx", 0o600);
    try { writeFileSync(fd, JSON.stringify(value) + "\n"); fsyncSync(fd); }
    finally { closeSync(fd); }
    renameSync(temp, path);
    const dir = openSync(dirname(path), "r");
    try { fsyncSync(dir); }
    finally { closeSync(dir); }
  } catch (e) {
    try { unlinkSync(temp); } catch {}
    throw e;
  }
}

function missing(e: unknown) {
  return (e as NodeJS.ErrnoException).code === "ENOENT";
}

export class Ledger {
  private d: Day;
  private dir: string | undefined;
  private budget: bigint;
  private now: () => number;
  constructor(
    dir: string | undefined,
    budget: bigint,
    now: () => number = Date.now,
  ) {
    this.dir = dir;
    this.budget = budget;
    this.now = now;
    this.d = this.load(utcDay(this.now()));
  }

  private path(day: string) {
    return this.dir ? join(this.dir, `ledger-${day}.json`) : undefined;
  }

  private load(day: string): Day {
    const p = this.path(day);
    if (!p) return { day, spent: 0n, received: 0n, txs: 0 };
    let raw: string;
    try { raw = readFileSync(p, "utf8"); }
    catch (e) {
      if (missing(e)) return { day, spent: 0n, received: 0n, txs: 0 };
      throw e;
    }
    const j = JSON.parse(raw);
    if (j?.day !== day || typeof j.spent !== "string" || !/^\d+$/.test(j.spent) ||
        typeof j.received !== "string" || !/^\d+$/.test(j.received) ||
        !Number.isSafeInteger(j.txs) || j.txs < 0 ||
        (j.last !== undefined && (typeof j.last !== "string" || !/^0x[0-9a-fA-F]+$/.test(j.last)))) {
      throw new Error(`invalid keeper ledger: ${p}`);
    }
    return { day, spent: BigInt(j.spent), received: BigInt(j.received), txs: j.txs, last: j.last };
  }

  private today(): Day {
    const day = utcDay(this.now());
    if (this.dir || this.d.day !== day) this.d = this.load(day);
    return this.d;
  }

  // the net loss still allowed today
  remaining(): bigint {
    const d = this.today();
    const net = d.spent - d.received;
    return this.budget > net ? this.budget - net : 0n;
  }

  allows(cost: bigint): boolean {
    return cost <= this.remaining();
  }

  record(spent: bigint, received: bigint, hash: string, day = utcDay(this.now())) {
    if (spent < 0n || received < 0n) throw new Error("negative keeper ledger entry");
    const d = day === utcDay(this.now()) ? this.today() : this.load(day);
    if (d.last === hash) return;
    const next = { ...d, spent: d.spent + spent, received: d.received + received, txs: d.txs + 1, last: hash };
    const p = this.path(d.day);
    if (p) {
      mkdirSync(this.dir!, { recursive: true });
      atomicJson(p, { ...next, spent: next.spent.toString(), received: next.received.toString() });
    }
    if (day === this.d.day) this.d = next;
  }

  snapshot(): Day {
    return { ...this.today() };
  }
}

export interface PendingTx {
  hash: `0x${string}`;
  nonce: number;
  chainId: number;
  address: `0x${string}`;
  door: Door;
  before: bigint;
  ledgerDay?: string;
  listingKey?: string; // venue:id of a buyListing; survives receipt reconciliation after restart
  sentAt?: number; // ms when the marker was written; a marker from before this field starts its clock at the next reconcile
  cancel?: `0x${string}`; // the same-nonce self-transfer signed to replace this transaction, written before broadcast
  cancelAt?: number; // ms when that self-transfer was last broadcast
}

// A signed transaction remains unresolved until a receipt is accounted, even if a relay request or receipt poll fails.
// Only one keeper process may use a signer and state directory; this file is not a cross-process lock.
export class PendingStore {
  private path?: string;
  private cooldownPath?: string;
  private cooldowns = new Map<string, { hash: string; until: number }>();
  private now: () => number;
  current?: PendingTx;
  get() { return this.current; }
  constructor(dir?: string, now: () => number = Date.now) {
    this.now = now;
    this.path = dir ? join(dir, "pending.json") : undefined;
    this.cooldownPath = dir ? join(dir, "listing-cooldowns.json") : undefined;
    if (this.cooldownPath) {
      let raw: string | undefined;
      try { raw = readFileSync(this.cooldownPath, "utf8"); }
      catch (e) { if (!missing(e)) throw e; }
      if (raw !== undefined) {
        const j = JSON.parse(raw);
        if (!j || typeof j !== "object" || Array.isArray(j)) throw new Error(`invalid keeper listing cooldowns: ${this.cooldownPath}`);
        for (const [key, entry] of Object.entries(j)) {
          const v = entry as { hash?: unknown; until?: unknown };
          if (!/^(strategy|seaport):\d+$/.test(key) || !v || typeof v !== "object" ||
              typeof v.hash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(v.hash) ||
              !Number.isSafeInteger(v.until) || (v.until as number) < 0) {
            throw new Error(`invalid keeper listing cooldowns: ${this.cooldownPath}`);
          }
          this.cooldowns.set(key, { hash: v.hash, until: v.until as number });
        }
      }
    }
    if (!this.path) return;
    let raw: string;
    try { raw = readFileSync(this.path, "utf8"); }
    catch (e) { if (missing(e)) return; throw e; }
    const j = JSON.parse(raw);
    if (!/^0x[0-9a-fA-F]{64}$/.test(j?.hash) || !Number.isSafeInteger(j.nonce) || j.nonce < 0 ||
        !Number.isSafeInteger(j.chainId) || j.chainId <= 0 || !/^0x[0-9a-fA-F]{40}$/.test(j.address) ||
        typeof j.door !== "string" || !/^\d+$/.test(j.before) ||
        (j.ledgerDay !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(j.ledgerDay)) ||
        (j.listingKey !== undefined && (j.door !== "buyListing" || !/^(strategy|seaport):\d+$/.test(j.listingKey))) ||
        (j.sentAt !== undefined && (!Number.isSafeInteger(j.sentAt) || j.sentAt < 0)) ||
        (j.cancel !== undefined && !/^0x[0-9a-fA-F]{64}$/.test(j.cancel)) ||
        (j.cancelAt !== undefined && (!Number.isSafeInteger(j.cancelAt) || j.cancelAt < 0))) {
      throw new Error(`invalid keeper pending transaction: ${this.path}`);
    }
    this.current = { ...j, before: BigInt(j.before) };
  }

  cooldownUntil(key: string): number { return this.cooldowns.get(key)?.until ?? 0; }

  // A reverted listing's hour begins at receipt accounting. Reconciliation of the same hash keeps its first expiry.
  recordListingRevert(key: string, hash: string): number {
    if (!/^(strategy|seaport):\d+$/.test(key) || !/^0x[0-9a-fA-F]{64}$/.test(hash)) {
      throw new Error("invalid keeper listing cooldown");
    }
    const previous = this.cooldowns.get(key);
    if (previous?.hash.toLowerCase() === hash.toLowerCase()) return previous.until;
    const until = this.now() + 3_600_000;
    const next = new Map(this.cooldowns);
    next.set(key, { hash, until });
    if (this.cooldownPath) {
      mkdirSync(dirname(this.cooldownPath), { recursive: true });
      atomicJson(this.cooldownPath, Object.fromEntries(next));
    }
    this.cooldowns = next;
    return until;
  }

  save(tx: PendingTx) {
    if (this.current && this.current.hash !== tx.hash) throw new Error("keeper transaction still unresolved");
    // Keep the in-memory gate closed even if durable persistence fails partway through.
    this.current = tx;
    if (this.path) {
      mkdirSync(dirname(this.path), { recursive: true });
      atomicJson(this.path, { ...tx, before: tx.before.toString() });
    }
  }

  clear() {
    if (this.path) unlinkSync(this.path);
    this.current = undefined;
  }
}

// counts consecutive failures of a door (a sent transaction that reverted, a send no relay took, a receipt that never
// came); at `threshold` the door pauses for `pauseSec` and the breaker reports a trip once. a success resets the count
export class Breaker {
  private fails = new Map<Door, number>();
  private until = new Map<Door, number>();
  private threshold: number;
  private pauseSec: number;
  private now: () => number;
  constructor(
    threshold: number,
    pauseSec: number,
    now: () => number = Date.now,
  ) {
    this.threshold = threshold;
    this.pauseSec = pauseSec;
    this.now = now;
  }

  paused(d: Door): boolean {
    return (this.until.get(d) ?? 0) > this.now();
  }

  pausedUntil(d: Door): number | undefined {
    return this.paused(d) ? this.until.get(d) : undefined;
  }

  // true when this failure trips the breaker
  fail(d: Door): boolean {
    const n = (this.fails.get(d) ?? 0) + 1;
    this.fails.set(d, n);
    if (n >= this.threshold) {
      this.fails.set(d, 0);
      this.until.set(d, this.now() + this.pauseSec * 1000);
      return true;
    }
    return false;
  }

  ok(d: Door) {
    this.fails.set(d, 0);
  }
}
