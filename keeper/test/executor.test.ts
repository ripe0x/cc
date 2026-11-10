// promise: the keeper simulates the fee-bearing pending call, refuses a pending base fee above its ceiling, and treats an unpaid paid door as a breaker failure
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseEther, parseGwei, keccak256, encodeFunctionData, parseTransaction } from "viem";
import { controllerV3Abi } from "@cc/engine/abis";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { mkdtempSync, mkdirSync, rmdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadConfig, type Deployment } from "../src/config.ts";
import { Executor } from "../src/exec.ts";
import { Breaker, Ledger, PendingStore, utcDay } from "../src/ledger.ts";
import { decide, type Intended, type Listing, type Policy, type State } from "../src/decide.ts";
import { listingCooldown } from "../src/main.ts";

const keeper = "0x00000000000000000000000000000000000000f1";
const rec: Deployment = {
  chainId: 31337, core: "0x00000000000000000000000000000000000000c0",
  controller: "0x00000000000000000000000000000000000000c1",
  seaportAdapter: "0x00000000000000000000000000000000000000a1",
  strategyAdapter: "0x00000000000000000000000000000000000000a2",
};
const cfg = loadConfig({ RECORD: "x", RPC_URLS: "http://127.0.0.1:8545", IMPERSONATE: keeper }, () => rec);
const policy: Policy = {
  doors: cfg.doors, doorsOn: cfg.doorsOn, margin: cfg.margin, listingDelaySec: cfg.listingDelaySec,
  bookMinWei: cfg.bookMinWei, bookMinSec: cfg.bookMinSec,
  // a high cost cap so the executor-mechanics tests exercise the send path; the drift gate lives in decide, not here
  refresh: { ...cfg.refresh, maxCostEth: parseEther("1") },
  floor: { poster: keeper, tolBps: cfg.floor.tolBps },
};
const call: Intended = {
  door: "refreshReference", functionName: "refreshReference", args: [], gas: 60_000n,
  payment: 0n, cost: 0n, key: "refreshReference",
};
// a paid door (compose) for the underpaid-breaker path, which refreshReference no longer exercises now that it is unpaid
const paidCall: Intended = {
  door: "compose", functionName: "compose", args: [], gas: 60_000n,
  payment: parseEther("0.0003"), cost: 0n, key: "compose",
};
const state = {
  controller: rec.controller, core: rec.core, blockNumber: 1n, baseFee: parseGwei("1"),
  potWithPending: parseEther("1"), settings: { callerFee: parseEther("0.0003"), callerMaxBaseFee: parseGwei("3") },
} as State;

test("executor: a pending base fee above the door ceiling skips before simulation", async () => {
  let simulated = false;
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("3.1") }),
    estimateGas: async () => { simulated = true; return 60_000n; },
  };
  const exec = new Executor(client, cfg, policy, { address: keeper }, new Ledger(undefined, cfg.dailyBudget), new Breaker(1, 60), new PendingStore());
  const out = await exec.run(call, state);
  assert.deepEqual(out, { kind: "skipped", reason: `pending base fee ${parseGwei("3.1")} above the door ceiling ${parseGwei("3")}` });
  assert.equal(simulated, false);
});

// promise: daily budget covers the signed gas limit at maxFeePerGas, even when the pending estimate is cheaper
test("executor: budget refuses one wei below maximum authorized gas and accepts the exact bound", async () => {
  const gasUsed = 60_000n;
  const gasLimit = 75_000n;
  const maxSpend = gasLimit * (cfg.doors.refreshReference.maxBaseFee + cfg.doors.refreshReference.tip);
  let sends = 0;
  let balanceReads = 0;
  const before = parseEther("1");
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => gasUsed,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => { balanceReads++; return blockNumber ? before - gasUsed * parseGwei("1") : before; },
    getTransactionCount: async () => 0,
    request: async () => { sends++; return "0x" + "55".repeat(32); },
    getTransactionReceipt: async () => ({ status: "success", gasUsed, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const belowCfg = { ...cfg, dailyBudget: maxSpend - 1n };
  const below = new Executor(client, belowCfg, policy, { address: keeper, impersonate: true }, new Ledger(undefined, belowCfg.dailyBudget), new Breaker(2, 60), new PendingStore());
  assert.deepEqual(await below.run(call, state), { kind: "skipped", reason: "daily budget exhausted" });
  assert.equal(sends, 0);
  assert.equal(balanceReads, 0);
  const exactCfg = { ...cfg, dailyBudget: maxSpend };
  const exact = new Executor(client, exactCfg, policy, { address: keeper, impersonate: true }, new Ledger(undefined, exactCfg.dailyBudget), new Breaker(2, 60), new PendingStore());
  assert.equal((await exact.run(call, state)).kind, "sent");
  assert.equal(sends, 1);
  assert.equal(maxSpend, 228_750_000_000_000n);
});

// promise: only a decoded order fault may suppress a listing; an RPC failure leaves it retryable
test("executor: listing faults exclude transport and estimate failures", async () => {
  const listingCall: Intended = { ...call, door: "buyListing", functionName: "buyListing", args: [rec.seaportAdapter, 42n, "0x"], key: "buyListing:42" };
  let failure: unknown = Object.assign(new Error("RPC unavailable"), { shortMessage: "RPC unavailable" });
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => { throw failure; },
  };
  const exec = new Executor(client, cfg, policy, { address: keeper }, new Ledger(undefined, cfg.dailyBudget), new Breaker(1, 60), new PendingStore());
  const transport = await exec.run(listingCall, state);
  assert.equal(transport.kind, "failed");
  if (transport.kind === "failed") assert.equal(transport.listingFault, false);
  failure = { data: { errorName: "CallFailed" } };
  const generic = await exec.run(listingCall, state);
  assert.equal(generic.kind, "failed");
  if (generic.kind === "failed") assert.equal(generic.listingFault, false);
  failure = { data: { errorName: "NoCredit" } };
  const order = await exec.run(listingCall, state);
  assert.equal(order.kind, "failed");
  if (order.kind === "failed") {
    assert.equal(order.listingFault, true);
    assert.deepEqual(listingCooldown(order, { venue: "seaport", id: 42n } as Listing), { key: "seaport:42", seconds: 300 });
  }
});

const listing: Listing = {
  venue: "seaport", adapter: rec.seaportAdapter, id: 42n, price: parseEther("0.001"),
  bid: parseEther("0.002"), params: "0x", valid: true,
};
const listingCall: Intended = {
  door: "buyListing", functionName: "buyListing", args: [listing.adapter, listing.id, listing.params],
  gas: 60_000n, payment: 0n, cost: 0n, key: "seaport:42:1000000000000000",
};
const listingState = {
  ...state, timestamp: 10_000n, potRoom: parseEther("1"), pendingIncome: parseEther("1"),
  payeeOn: true, lastBookAt: 0n, paused: false, retired: false,
  settings: { ...state.settings, keeperFee: parseEther("0.0003"), keeperMaxBaseFee: parseGwei("5"), buyToArtistBps: 250 },
} as State;

// promise: an included buyListing revert receives the hour cooldown while independent bookkeeping remains eligible
test("executor: confirmed reverted listing receipt cools that listing for one hour", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-listing-confirmed-"));
  const clock = 1_000_000_000;
  const spent = 60_000n * parseGwei("1");
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => blockNumber ? parseEther("1") - spent : parseEther("1"),
    getTransactionCount: async () => 0,
    request: async () => "0x" + "66".repeat(32),
    getTransactionReceipt: async () => ({ status: "reverted", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const exec = new Executor(client, cfg, policy, { address: keeper, impersonate: true }, new Ledger(dir, cfg.dailyBudget), new Breaker(2, 60), new PendingStore(dir, () => clock));
  const out = await exec.run(listingCall, listingState, listing);
  assert.equal(out.kind, "sent");
  if (out.kind !== "sent") return;
  assert.equal(out.status, "reverted");
  assert.deepEqual(listingCooldown(out, listing), { key: "seaport:42", seconds: 3_600 });
  assert.equal(new PendingStore(dir).current, undefined);
  assert.equal(new PendingStore(dir).cooldownUntil("seaport:42"), clock + 3_600_000, "receipt accounting persisted the wait before a new tick");
  const bookPolicy = { ...policy, doorsOn: new Set(["buyListing", "book"] as const) } as Policy;
  const next = decide(listingState, [], { baseFee: parseGwei("1") }, bookPolicy, new Map());
  assert.deepEqual(next.calls.map((c) => c.door), ["book"], "the listing cooldown does not block an independent door");
});

// promise: a receipt found after restart retains its listing identity and receives the same hour cooldown
test("executor: reconciled reverted listing receipt keeps its cooldown identity across restart", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-listing-pending-"));
  const clock = 1_000_000_000;
  const account = privateKeyToAccount(generatePrivateKey());
  const localCfg = { ...cfg, receiptTimeoutSec: 0, stateDir: dir };
  const spent = 60_000n * parseGwei("1");
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => blockNumber ? parseEther("1") - spent : parseEther("1"),
    getTransactionCount: async () => 7,
    request: async ({ params }: { params: string[] }) => keccak256(params[0] as `0x${string}`),
    getTransactionReceipt: async () => ({ status: "reverted", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const first = new Executor(client, localCfg, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(2, 60), new PendingStore(dir, () => clock));
  assert.equal((await first.run(listingCall, listingState, listing)).kind, "failed", "the first receipt poll timed out");
  assert.equal(new PendingStore(dir).current?.listingKey, "seaport:42");
  const restarted = new Executor(client, localCfg, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(2, 60), new PendingStore(dir, () => clock));
  const out = await restarted.reconcile();
  assert.equal(out?.kind, "reconciled");
  if (out?.kind !== "reconciled") return;
  assert.equal(out.status, "reverted");
  assert.deepEqual(listingCooldown(out), { key: "seaport:42", seconds: 3_600 });
  assert.equal(new PendingStore(dir).current, undefined, "receipt accounting cleared the pending marker");
  assert.equal(new PendingStore(dir).cooldownUntil("seaport:42"), clock + 3_600_000, "the wait survives a second restart after receipt reconciliation");
  assert.equal(new Ledger(dir, cfg.dailyBudget).snapshot().spent, spent);
});

// promise: a crash after the cooldown write but before pending clear cannot reset the wait or double count gas
test("executor: repeated receipt accounting keeps the original listing expiry", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-listing-clear-"));
  const account = privateKeyToAccount(generatePrivateKey());
  const localCfg = { ...cfg, receiptTimeoutSec: 0, stateDir: dir };
  const spent = 60_000n * parseGwei("1");
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => blockNumber ? parseEther("1") - spent : parseEther("1"),
    getTransactionCount: async () => 7,
    request: async ({ params }: { params: string[] }) => keccak256(params[0] as `0x${string}`),
    getTransactionReceipt: async () => ({ status: "reverted", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const original = new PendingStore(dir, () => 1_000_000_000);
  const first = new Executor(client, localCfg, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(2, 60), original);
  assert.equal((await first.run(listingCall, listingState, listing)).kind, "failed");
  original.clear = () => { throw new Error("interrupted before pending clear"); };
  assert.equal((await first.reconcile())?.kind, "failed");
  assert.equal(new PendingStore(dir).cooldownUntil("seaport:42"), 1_003_600_000);
  assert.ok(new PendingStore(dir).current, "the pending receipt remains available for retry");
  const restarted = new Executor(client, localCfg, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(2, 60), new PendingStore(dir, () => 1_000_060_000));
  assert.equal((await restarted.reconcile())?.kind, "reconciled");
  assert.equal(new PendingStore(dir).cooldownUntil("seaport:42"), 1_003_600_000, "reconciliation cannot extend the first wait");
  assert.equal(new PendingStore(dir).current, undefined);
  assert.equal(new Ledger(dir, cfg.dailyBudget).snapshot().spent, spent, "the same receipt is charged once");
});

test("executor: a fee-bearing pending simulation that receives no caller payment trips the breaker", async () => {
  const before = parseEther("1");
  const spent = 60_000n * parseGwei("1");
  const gasArgs: any[] = [];
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async (args: unknown) => { gasArgs.push(args); return 60_000n; },
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => blockNumber ? before - spent : before,
    request: async () => "0x" + "11".repeat(32),
    getTransactionCount: async () => 0,
    getTransactionReceipt: async () => ({ status: "success", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const breaker = new Breaker(1, 60);
  const exec = new Executor(client, cfg, policy, { address: keeper, impersonate: true }, new Ledger(undefined, cfg.dailyBudget), breaker, new PendingStore());
  const out = await exec.run(paidCall, state);
  assert.equal(out.kind, "sent");
  if (out.kind === "sent") assert.equal(out.received, 0n);
  assert.equal(breaker.paused("compose"), true);
  assert.equal(gasArgs.length, 1);
  assert.equal(gasArgs[0].blockTag, "pending");
  assert.equal(gasArgs[0].maxFeePerGas, cfg.doors.compose.maxBaseFee + cfg.doors.compose.tip);
  assert.equal(gasArgs[0].maxPriorityFeePerGas, cfg.doors.compose.tip);
});

// promise: a confirmed receipt spends daily budget even when the historical balance read fails
test("executor: a failed receipt-block balance read records gas and trips the breaker", async () => {
  const spent = 60_000n * parseGwei("1");
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => {
      if (blockNumber) throw new Error("historical balance unavailable");
      return parseEther("1");
    },
    request: async () => "0x" + "22".repeat(32),
    getTransactionCount: async () => 0,
    getTransactionReceipt: async () => ({ status: "success", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const ledger = new Ledger(undefined, cfg.dailyBudget);
  const breaker = new Breaker(1, 60);
  const exec = new Executor(client, cfg, policy, { address: keeper, impersonate: true }, ledger, breaker, new PendingStore());
  const out = await exec.run(call, state);
  assert.equal(out.kind, "sent");
  if (out.kind === "sent") assert.deepEqual([out.spent, out.received], [spent, 0n]);
  assert.equal(ledger.snapshot().spent, spent);
  assert.equal(ledger.remaining(), cfg.dailyBudget - spent);
  assert.equal(breaker.paused("refreshReference"), true);
});

// promise: an accepted or uncertain raw transaction keeps its nonce reserved across restart until receipt accounting completes
test("executor: a timed-out signed send blocks the next send and reconciles after restart", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-pending-"));
  const account = privateKeyToAccount(generatePrivateKey());
  const localCfg = { ...cfg, receiptTimeoutSec: 0, stateDir: dir };
  let sends = 0;
  let mined = false;
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => blockNumber ? parseEther("1") - 60_000n * parseGwei("1") : parseEther("1"),
    getTransactionCount: async () => 7,
    request: async ({ params }: { params: string[] }) => {
      sends++;
      const expected = keccak256(params[0] as `0x${string}`);
      assert.equal(new PendingStore(dir).current?.hash, expected, "durable pending marker precedes relay submission");
      return expected;
    },
    getTransactionReceipt: async () => { if (!mined) throw new Error("not found"); return { status: "success", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }; },
  };
  const pending = new PendingStore(dir);
  const exec = new Executor(client, localCfg, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(2, 60), pending);
  const first = await exec.run(call, state);
  assert.equal(first.kind, "failed");
  assert.equal(sends, 1);
  assert.equal(new PendingStore(dir).current?.nonce, 7);
  assert.equal((await exec.run(call, state)).kind, "skipped");
  assert.equal(sends, 1);
  const restarted = new Executor(client, localCfg, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(2, 60), new PendingStore(dir));
  assert.equal((await restarted.reconcile())?.kind, "skipped");
  mined = true;
  assert.equal((await restarted.reconcile())?.kind, "reconciled");
  assert.equal(new PendingStore(dir).current, undefined);
  assert.equal(new Ledger(dir, cfg.dailyBudget).snapshot().txs, 1);
});

// promise: a relay transport error cannot release a signed nonce whose acceptance is unknown
test("executor: uncertain relay response leaves the signed transaction pending", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-relay-uncertain-"));
  const account = privateKeyToAccount(generatePrivateKey());
  let sends = 0;
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async () => parseEther("1"),
    getTransactionCount: async () => 4,
    request: async () => { sends++; throw new Error("relay transport lost response"); },
  };
  const exec = new Executor(client, { ...cfg, stateDir: dir }, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(2, 60), new PendingStore(dir));
  assert.equal((await exec.run(call, state)).kind, "failed");
  assert.equal(new PendingStore(dir).current?.nonce, 4);
  assert.equal((await exec.run(call, state)).kind, "skipped");
  assert.equal(sends, 1);
});

// promise: a confirmed receipt never clears its pending marker or daily gas liability when ledger persistence fails
test("executor: receipt accounting failure retains pending and breaker, then records once", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-ledger-fail-"));
  const ledger = new Ledger(dir, cfg.dailyBudget);
  const blocked = join(dir, `ledger-${utcDay(Date.now())}.json`);
  const pending = new PendingStore(dir);
  const breaker = new Breaker(1, 60);
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => blockNumber ? parseEther("1") - 60_000n * parseGwei("1") : parseEther("1"),
    getTransactionCount: async () => 0,
    request: async () => { mkdirSync(blocked); return "0x" + "44".repeat(32); },
    getTransactionReceipt: async () => ({ status: "success", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const exec = new Executor(client, cfg, policy, { address: keeper, impersonate: true }, ledger, breaker, pending);
  assert.equal((await exec.run(call, state)).kind, "failed");
  assert.equal(breaker.paused("refreshReference"), true);
  assert.ok(pending.current);
  rmdirSync(blocked);
  assert.equal((await exec.reconcile())?.kind, "reconciled");
  assert.equal(ledger.snapshot().txs, 1);
  assert.equal(pending.current, undefined);
});

// promise: the postMarketFloor call goes through the executor's send path end to end: simulated at pending, rechecked
// as an unpaid door under the cost cap, encoded against the V3 abi to the controller, and sent (SEC-01 of the phase 3
// audit: the door was missing from recheck's unpaid branch and never sent)
test("executor: postMarketFloor is rechecked as an unpaid door and sent to the controller", async () => {
  const gasUsed = 60_000n;
  let sentTo: string | undefined;
  let sentData: string | undefined;
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("0.3") }),
    estimateGas: async ({ to, data }: { to: string; data: string }) => { sentTo = to; sentData = data; return gasUsed; },
    getBalance: async () => parseEther("1"),
    getTransactionCount: async () => 0,
    request: async () => "0x" + "66".repeat(32),
    getTransactionReceipt: async () => ({ status: "success", gasUsed, effectiveGasPrice: parseGwei("0.3"), blockNumber: 2n }),
  };
  const floorCall: Intended = {
    door: "postMarketFloor", functionName: "postMarketFloor", target: "controller", args: [8_700_000_000_000_000n], gas: gasUsed,
    payment: 0n, cost: 0n, key: "postMarketFloor",
  };
  const exec = new Executor(client, cfg, policy, { address: keeper, impersonate: true }, new Ledger(undefined, cfg.dailyBudget), new Breaker(2, 60), new PendingStore());
  const out = await exec.run(floorCall, state);
  assert.equal(out.kind, "sent", String((out as { reason?: string }).reason ?? out.kind));
  assert.equal(sentTo?.toLowerCase(), rec.controller.toLowerCase(), "the call goes to the controller");
  assert.equal(sentData?.slice(0, 10), encodeFunctionData({ abi: controllerV3Abi, functionName: "postMarketFloor", args: [8_700_000_000_000_000n] }).slice(0, 10), "encoded with the V3 abi");
});

// a client for the self-cancel tests: the door transaction never gets a receipt; `cancelMined` releases the cancel's
function stuckClient(o: { nonce: number; latest: () => number; finalized?: () => number; cancelMined: () => boolean; originalMined?: () => boolean; strictFails?: () => boolean; sent: string[] }) {
  return {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async () => parseEther("1"),
    getTransactionCount: async ({ blockTag }: { blockTag?: string }) =>
      blockTag === "latest" ? o.latest() : blockTag === "finalized" ? (o.finalized ?? o.latest)() : o.nonce,
    request: async ({ method, params }: { method: string; params: string[] }) => {
      if (method === "eth_getTransactionReceipt") { if (o.strictFails?.()) throw new Error("rpc down"); return receipt(params[0]); }
      o.sent.push(params[0]);
      return keccak256(params[0] as `0x${string}`);
    },
    getTransactionReceipt: async ({ hash }: { hash: string }) => receipt(hash),
  } as any;
  function receipt(hash: string) {
    const isCancel = o.sent.length > 1 && hash === keccak256(o.sent[o.sent.length - 1] as `0x${string}`);
    if (isCancel ? o.cancelMined() : o.originalMined?.()) return { status: "success", gasUsed: 21_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 3n };
    return null;
  }
}

// promise: a dropped transaction is replaced by a same-nonce zero-value self-transfer whose receipt releases the keeper
test("executor: a transaction with no receipt is cancelled at its nonce and the cancel is accounted", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-cancel-"));
  const account = privateKeyToAccount(generatePrivateKey());
  const localCfg = { ...cfg, receiptTimeoutSec: 0, cancelAfterSec: 0, stateDir: dir };
  let mined = false;
  const sent: string[] = [];
  const client = stuckClient({ nonce: 9, latest: () => (mined ? 10 : 9), cancelMined: () => mined, sent });
  const exec = new Executor(client, localCfg, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(5, 60), new PendingStore(dir));
  assert.equal((await exec.run(call, state)).kind, "failed");
  const out = await exec.reconcile();
  assert.equal(out?.kind, "skipped");
  assert.equal(sent.length, 2);
  const cancel = parseTransaction(sent[1] as `0x${string}`);
  assert.equal(cancel.nonce, 9);
  assert.equal(cancel.to?.toLowerCase(), account.address.toLowerCase());
  assert.equal(cancel.value ?? 0n, 0n);
  assert.equal(cancel.data ?? "0x", "0x");
  assert.equal(cancel.gas, 21_000n);
  assert.equal(new PendingStore(dir).current?.cancel, keccak256(sent[1] as `0x${string}`));
  // a later tick rebroadcasts the identical bytes rather than signing a second distinct transaction
  await exec.reconcile();
  assert.equal(sent[2], sent[1]);
  mined = true;
  const done = await exec.reconcile();
  assert.equal(done?.kind, "reconciled");
  assert.equal(new PendingStore(dir).current, undefined);
  assert.equal(new Ledger(dir, cfg.dailyBudget).snapshot().spent, 21_000n * parseGwei("1"));
  assert.equal((await exec.reconcile()), undefined);
});

// promise: the original transaction landing after a cancel was signed is accounted as itself, not as the cancel
test("executor: an original that lands after the cancel is the one accounted", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-cancel-race-"));
  const account = privateKeyToAccount(generatePrivateKey());
  const localCfg = { ...cfg, receiptTimeoutSec: 0, cancelAfterSec: 0, stateDir: dir };
  let landed = false;
  const sent: string[] = [];
  const client = stuckClient({ nonce: 3, latest: () => (landed ? 4 : 3), cancelMined: () => false, originalMined: () => landed, sent });
  const exec = new Executor(client, localCfg, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(5, 60), new PendingStore(dir));
  await exec.run(call, state);
  await exec.reconcile();
  assert.equal(sent.length, 2);
  landed = true;
  const out = await exec.reconcile();
  assert.equal(out?.kind, "reconciled");
  if (out?.kind === "reconciled") assert.equal(out.hash, keccak256(sent[0] as `0x${string}`));
  assert.equal(new PendingStore(dir).current, undefined);
});

// promise: a marker written before sentAt existed is not cancelled on the first tick after an upgrade
test("executor: a marker without sentAt starts its cancel clock instead of cancelling at once", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-cancel-legacy-"));
  const account = privateKeyToAccount(generatePrivateKey());
  const legacy = new PendingStore(dir);
  legacy.save({ hash: `0x${"ab".repeat(32)}`, nonce: 5, chainId: rec.chainId, address: account.address, door: "book", before: parseEther("1") });
  const sent: string[] = [];
  const client = stuckClient({ nonce: 5, latest: () => 5, cancelMined: () => false, sent });
  const exec = new Executor(client, { ...cfg, cancelAfterSec: 600, stateDir: dir }, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(5, 60), new PendingStore(dir));
  assert.equal((await exec.reconcile())?.kind, "skipped");
  assert.equal(sent.length, 0);
  assert.equal(typeof new PendingStore(dir).current?.sentAt, "number");
});

// promise: a nonce used by a transaction the keeper cannot see releases the marker only once that nonce is final
test("executor: an externally used nonce releases the marker only at finality", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-cancel-external-"));
  const account = privateKeyToAccount(generatePrivateKey());
  let finalized = 6;
  let rpcDown = false;
  const sent: string[] = [];
  const client = stuckClient({ nonce: 6, latest: () => 7, finalized: () => finalized, cancelMined: () => false, strictFails: () => rpcDown, sent });
  const exec = new Executor(client, { ...cfg, receiptTimeoutSec: 0, cancelAfterSec: 0, stateDir: dir }, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(5, 60), new PendingStore(dir));
  await exec.run(call, state);
  assert.match(((await exec.reconcile()) as any).reason, /waiting for finality/);
  assert.equal(sent.length, 1, "no cancel is signed for a nonce already used");
  finalized = 7;
  // a failed receipt read is not absence: the marker stays until the RPC answers null
  rpcDown = true;
  assert.equal((await exec.reconcile())?.kind, "skipped");
  assert.notEqual(new PendingStore(dir).current, undefined);
  rpcDown = false;
  assert.equal((await exec.reconcile())?.kind, "failed");
  assert.equal(new PendingStore(dir).current, undefined);
});
