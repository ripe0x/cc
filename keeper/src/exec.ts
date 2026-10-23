// The executor: one call at a time. Each decided call is simulated (eth_estimateGas from the keeper, which runs the
// call) at the pending block with the transaction's fee fields, rechecked against the profit rule at measured gas, and
// checked against the day's budget. It is then signed and sent through private relays in order. The receipt is awaited
// before anything else is sent.
// A dry run stops after the recheck and logs the call it would send.

import {
  createPublicClient,
  encodeFunctionData,
  http,
  keccak256,
  type Address,
  type Hex,
  type PrivateKeyAccount,
  type PublicClient,
} from "viem";
import { controllerAbi, controllerV3Abi, coreAbi, splitV2Abi } from "@cc/engine/abis";
import { revertName, txError } from "@cc/engine/errors";
import type { Config } from "./config.ts";
import { recheck, type Intended, type Listing, type Policy, type State } from "./decide.ts";
import { utcDay, type Breaker, type Ledger, type PendingStore, type PendingTx } from "./ledger.ts";
import { alert } from "./alert.ts";
import { log, txUrl } from "./log.ts";

export type Signer = { address: Address; account?: PrivateKeyAccount; impersonate?: boolean };

export type Outcome =
  | { kind: "sent"; hash: Hex; status: "success" | "reverted"; spent: bigint; received: bigint; listingKey?: string }
  | { kind: "reconciled"; hash: Hex; status: "success" | "reverted"; spent: bigint; received: bigint; listingKey?: string }
  | { kind: "dry"; gas: bigint }
  | { kind: "skipped"; reason: string }
  | { kind: "failed"; reason: string; listingFault?: boolean };

// gas limit = measured gas * 1.25, as web/lib/tx.ts sends
const GAS_BUFFER_BPS = 12_500n;
// These decoded buyListing failures depend on this order's parameters or Seaport fulfillment.
const ORDER_FAULTS = new Set(["WrongToken", "WrongId", "WrongAmount", "NotNative", "ZeroPrice", "RestrictedOrder", "RecipientNotAllowed", "NoCredit", "AlreadyOwned"]);

export class Executor {
  private client: PublicClient;
  private cfg: Config;
  private policy: Policy;
  private signer: Signer;
  private ledger: Ledger;
  private breaker: Breaker;
  private pending: PendingStore;
  constructor(
    client: PublicClient,
    cfg: Config,
    policy: Policy,
    signer: Signer,
    ledger: Ledger,
    breaker: Breaker,
    pending: PendingStore,
  ) {
    this.client = client;
    this.cfg = cfg;
    this.policy = policy;
    this.signer = signer;
    this.ledger = ledger;
    this.breaker = breaker;
    this.pending = pending;
  }

  private data(c: Intended): Hex {
    // ControllerV3's syncFill and refreshCcReference live in the keeper-only V3 abi; the Core's own refreshReference and
    // the other controller calls stay in controllerAbi
    const v3 = c.functionName === "syncFill" || c.functionName === "refreshCcReference";
    const abi = c.target === "controller" ? (v3 ? controllerV3Abi : controllerAbi) : c.target === "split" ? splitV2Abi : coreAbi;
    return encodeFunctionData({ abi, functionName: c.functionName as any, args: c.args as any });
  }

  // the contract a decided call goes to: the controller, the configured split, or the Core. exported through `run`
  // for the test of the selection; a split call without a configured split is refused before any simulation
  target(c: Intended, s: Pick<State, "controller">): Address | undefined {
    if (c.target === "controller") return s.controller;
    if (c.target === "split") return this.policy.split?.address;
    return this.cfg.record.core;
  }

  hasPending() { return !!this.pending.current; }

  // runs one decided call: returns what happened. never sends while another transaction of the keeper is pending
  async run(c: Intended, s: State, listing?: Listing): Promise<Outcome> {
    if (this.pending.current) return { kind: "skipped", reason: `transaction ${this.pending.current.hash} still unresolved` };
    const chainId = this.cfg.record.chainId;
    if (this.breaker.paused(c.door)) return { kind: "skipped", reason: `door paused by the breaker until ${new Date(this.breaker.pausedUntil(c.door)!).toISOString()}` };
    const to = this.target(c, s);
    if (!to) return { kind: "failed", reason: "no split configured for the distributeSplit call" };
    const data = this.data(c);
    const pol = this.policy.doors[c.door];
    const fee = { maxFeePerGas: pol.maxBaseFee + pol.tip, maxPriorityFeePerGas: pol.tip };

    // A fee above the refundable ceiling makes a paid call loss-making and the signed transaction may not land.
    let pendingBaseFee: bigint;
    try {
      pendingBaseFee = (await this.client.getBlock({ blockTag: "pending" })).baseFeePerGas ?? s.baseFee;
    } catch (e) {
      return { kind: "failed", reason: `pending block read failed: ${txError(e)}` };
    }
    if (pendingBaseFee > pol.maxBaseFee) return { kind: "skipped", reason: `pending base fee ${pendingBaseFee} above the door ceiling ${pol.maxBaseFee}` };

    // Simulate the fee-bearing call at pending, where gasprice-dependent offerers see the transaction's actual terms.
    let gasUsed: bigint;
    try {
      gasUsed = await this.client.estimateGas({ account: this.signer.address, to, data, blockTag: "pending", ...fee });
    } catch (e) {
      // the purchase budget refills with the next bucket: a wait, not a listing fault
      if (revertName(e) === "SpendCapReached") return { kind: "skipped", reason: "SpendCapReached: waiting for the next bucket" };
      const name = revertName(e);
      // Only a decoded order fault can suppress this listing. Transport and fee failures remain retryable.
      const listingFault = c.door === "buyListing" && !!name && ORDER_FAULTS.has(name);
      return { kind: "failed", reason: `simulation reverted: ${name ?? txError(e)}`, listingFault };
    }

    try {
      pendingBaseFee = (await this.client.getBlock({ blockTag: "pending" })).baseFeePerGas ?? pendingBaseFee;
    } catch (e) {
      return { kind: "failed", reason: `pending block recheck failed: ${txError(e)}` };
    }
    if (pendingBaseFee > pol.maxBaseFee) return { kind: "skipped", reason: `pending base fee ${pendingBaseFee} above the door ceiling ${pol.maxBaseFee}` };
    const gasNow = { baseFee: pendingBaseFee };
    const r = recheck(c, s, listing, gasUsed, gasNow, this.policy);
    if (!r.ok) return { kind: "skipped", reason: `after simulation: payment ${r.payment} under cost ${r.cost} plus margin at ${gasUsed} gas` };

    if (this.cfg.dryRun) {
      log("info", "dry run: would send", {
        door: c.door,
        to,
        fn: c.functionName,
        args: c.args,
        gas: gasUsed,
        payment: r.payment,
        cost: r.cost,
        ...c.note,
      });
      return { kind: "dry", gas: gasUsed };
    }

    const tx = {
      to,
      data,
      gas: (gasUsed * GAS_BUFFER_BPS + 9_999n) / 10_000n,
      ...fee,
    };
    // Reserve the whole gas limit at the signed fee ceiling; the receipt records only what was actually spent.
    const maxSpend = tx.gas * tx.maxFeePerGas;
    if (!this.ledger.allows(maxSpend)) {
      void alert(this.cfg.alertWebhook, "budget", "daily budget exhausted, paid doors wait for the next UTC day", { remaining: this.ledger.remaining(), cost: maxSpend });
      return { kind: "skipped", reason: "daily budget exhausted" };
    }
    const before = await this.client.getBalance({ address: this.signer.address });
    let hash: Hex;
    try {
      hash = await this.send(tx, chainId, c.door, before, c.door === "buyListing" && listing ? `${listing.venue}:${listing.id}` : undefined);
    } catch (e) {
      const unresolved = this.pending.get();
      if (unresolved) void alert(this.cfg.alertWebhook, "pending", "keeper transaction acceptance is uncertain; later sends are blocked until its receipt is accounted", { hash: unresolved.hash, nonce: unresolved.nonce, door: c.door });
      const tripped = this.breaker.fail(c.door);
      if (tripped) void alert(this.cfg.alertWebhook, `breaker:${c.door}`, `${c.door} paused after repeated send failures`, { error: txError(e) });
      return { kind: "failed", reason: `send failed: ${txError(e)}` };
    }
    log("info", "sent", { door: c.door, fn: c.functionName, args: c.args, hash, url: txUrl(hash, chainId), gasLimit: tx.gas, ...c.note });

    const receipt = await this.waitReceipt(hash);
    if (!receipt) {
      void alert(this.cfg.alertWebhook, "pending", "keeper transaction has no receipt yet; later sends are blocked until its receipt is accounted", { hash, nonce: this.pending.get()?.nonce, door: c.door });
      const tripped = this.breaker.fail(c.door);
      if (tripped) void alert(this.cfg.alertWebhook, `breaker:${c.door}`, `${c.door} paused: receipts never came`, { hash, url: txUrl(hash, chainId) });
      return { kind: "failed", reason: `no receipt within ${this.cfg.receiptTimeoutSec} s` };
    }
    return this.accountReceipt(this.pending.current!, receipt, "sent");
  }

  // A missing receipt is unresolved. In particular, a timed-out relay request can have accepted the raw transaction.
  async reconcile(): Promise<Outcome | undefined> {
    const tx = this.pending.current;
    if (!tx) return undefined;
    if (tx.chainId !== this.cfg.record.chainId || tx.address.toLowerCase() !== this.signer.address.toLowerCase()) {
      return { kind: "failed", reason: "pending transaction belongs to another chain or signer" };
    }
    let receipt;
    try { receipt = await this.client.getTransactionReceipt({ hash: tx.hash }); }
    catch { return { kind: "skipped", reason: `transaction ${tx.hash} still unresolved` }; }
    if (!receipt) return { kind: "skipped", reason: `transaction ${tx.hash} still unresolved` };
    return this.accountReceipt(tx, receipt, "reconciled");
  }

  private async accountReceipt(tx: PendingTx, receipt: Awaited<ReturnType<PublicClient["getTransactionReceipt"]>>, kind: "sent" | "reconciled"): Promise<Outcome> {
    const { hash, door, before, chainId } = tx;
    const spent = receipt.gasUsed * receipt.effectiveGasPrice;
    let after: bigint | undefined;
    let balanceError: string | undefined;
    try {
      after = await this.client.getBalance({ address: this.signer.address, blockNumber: receipt.blockNumber });
    } catch (e) {
      balanceError = txError(e);
    }
    // A failed historical balance read cannot erase confirmed gas spend. Count no refund without evidence.
    const received = after !== undefined && after + spent > before ? after + spent - before : 0n;
    const fields = { door, hash, url: txUrl(hash, chainId), block: receipt.blockNumber, gasUsed: receipt.gasUsed, spent, received, net: received - spent };
    try {
      if (!tx.ledgerDay) { tx = { ...tx, ledgerDay: utcDay(Date.now()) }; this.pending.save(tx); }
      this.ledger.record(spent, received, hash, tx.ledgerDay);
      // Persist the listing wait before releasing the pending send gate; a restart must not retry it immediately.
      if (door === "buyListing" && receipt.status === "reverted" && tx.listingKey) {
        this.pending.recordListingRevert(tx.listingKey, hash);
      }
      this.pending.clear();
    } catch (e) {
      log("error", "receipt accounting failed", { ...fields, error: txError(e) });
      if (this.breaker.fail(door)) void alert(this.cfg.alertWebhook, `breaker:${door}`, `${door} paused after receipt accounting failed`, fields);
      return { kind: "failed", reason: `receipt accounting failed: ${txError(e)}` };
    }
    // refreshReference now calls the controller directly and is unpaid, so it joins collectEscrow, book and
    // distributeSplit outside the paid-door underpaid check
    const paidDoor = door === "buyListing" || door === "buyback" || door === "compose" || door === "redeemStatement";
    if (balanceError) {
      log("error", "receipt balance read failed", { ...fields, error: balanceError });
      if (this.breaker.fail(door)) void alert(this.cfg.alertWebhook, `breaker:${door}`, `${door} paused after confirmed receipt could not be accounted`, fields);
    } else if (receipt.status === "success" && (!paidDoor || received >= spent + this.policy.margin)) {
      this.breaker.ok(door);
      log("info", "confirmed", fields);
    } else if (receipt.status === "success") {
      log("error", "paid door underpaid", fields);
      if (this.breaker.fail(door)) void alert(this.cfg.alertWebhook, `breaker:${door}`, `${door} paused after repeated underpaid receipts`, fields);
    } else {
      log("error", "reverted on chain", fields);
      if (this.breaker.fail(door)) void alert(this.cfg.alertWebhook, `breaker:${door}`, `${door} paused after repeated on chain reverts`, fields);
    }
    if (after !== undefined && after < this.cfg.lowBalance) void alert(this.cfg.alertWebhook, "balance", "keeper balance low, top up", { balance: after, address: this.signer.address });
    return { kind, hash, status: receipt.status, spent, received, ...(tx.listingKey ? { listingKey: tx.listingKey } : {}) };
  }

  // a signed transaction goes to each relay in order until one accepts it; without relays (a local node) to the read
  // node. An impersonated account sends unsigned through eth_sendTransaction on a local node; its hash cannot be
  // persisted before the RPC accepts it, so a lost local response requires manual nonce reconciliation.
  private async send(tx: { to: Address; data: Hex; gas: bigint; maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }, chainId: number, door: Intended["door"], before: bigint, listingKey?: string): Promise<Hex> {
    const hex = (v: bigint) => `0x${v.toString(16)}`;
    if (this.signer.impersonate) {
      const nonce = await this.client.getTransactionCount({ address: this.signer.address, blockTag: "pending" });
      const hash = (await this.client.request({
        method: "eth_sendTransaction" as any,
        params: [{ from: this.signer.address, to: tx.to, data: tx.data, gas: hex(tx.gas), maxFeePerGas: hex(tx.maxFeePerGas), maxPriorityFeePerGas: hex(tx.maxPriorityFeePerGas) }] as any,
      })) as Hex;
      this.pending.save({ hash, nonce, chainId, address: this.signer.address, door, before, listingKey });
      return hash;
    }
    const account = this.signer.account!;
    const nonce = await this.client.getTransactionCount({ address: account.address, blockTag: "pending" });
    const raw = await account.signTransaction({ type: "eip1559", chainId, nonce, ...tx });
    const expected = keccak256(raw);
    this.pending.save({ hash: expected, nonce, chainId, address: account.address, door, before, listingKey });
    const relays = this.cfg.relayUrls;
    if (relays.length === 0) {
      const hash = (await this.client.request({ method: "eth_sendRawTransaction", params: [raw] })) as Hex;
      if (hash.toLowerCase() !== expected.toLowerCase()) throw new Error("RPC returned a different transaction hash");
      return hash;
    }
    let last: unknown;
    for (const url of relays) {
      try {
        const relay = createPublicClient({ transport: http(url, { timeout: 15_000, retryCount: 0 }) });
        const hash = (await relay.request({ method: "eth_sendRawTransaction", params: [raw] })) as Hex;
        if (hash.toLowerCase() !== expected.toLowerCase()) throw new Error("relay returned a different transaction hash");
        if (url !== relays[0]) log("warn", "relay fallback took the transaction", { relay: new URL(url).host });
        return hash;
      } catch (e) {
        last = e;
        log("warn", "relay refused", { relay: new URL(url).host, error: txError(e) });
      }
    }
    throw last;
  }

  private async waitReceipt(hash: Hex) {
    const end = Date.now() + this.cfg.receiptTimeoutSec * 1000;
    while (Date.now() < end) {
      try {
        const r = await this.client.getTransactionReceipt({ hash });
        if (r) return r;
      } catch {}
      await new Promise((res) => setTimeout(res, 2_000));
    }
    return undefined;
  }
}
