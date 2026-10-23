// The keeper's decisions: pure functions of the chain state read at one block, the candidate listings and the gas
// state. Every gate restates a Core rule (src/Core.sol) so a call that would revert or pay less than its own cost is
// never simulated, and the simulation stays the final check. Payments are evaluated at the worst base fee the
// transaction can land at, `min(baseFee * 9 / 8, door maxBaseFee)`: the gas refund of a paid door tracks the base fee
// up to its setting's ceiling, so the worst case is the highest base fee.

import { zeroAddress, type Address, type Hex } from "viem";
import type { Door, DoorPolicy, SplitConfig } from "./config.ts";

// the private gas constants of the Core (src/Core.sol 224 to 236), restated
export const COMPOSE_GAS = 13_700_000n;
export const REDEEM_GAS = 1_500_000n;
export const BUYBACK_GAS = 600_000n;
export const BUYLISTING_GAS = 1_500_000n;

// gas guesses used before a simulation measures the call (docs/INTEGRATION.md section 12, rounded up)
export const GAS_GUESS: { [d in Door]: bigint } = {
  buyListing: 520_000n,
  buyback: 300_000n,
  compose: 9_000_000n,
  collectEscrow: 120_000n,
  book: 100_000n,
  redeemStatement: 1_500_000n,
  refreshReference: 60_000n,
  // syncFill walks the pile from the hint to the tail; after a single purchase that is a short walk. refreshCcReference
  // mirrors refreshReference. both are measured by the simulation; these only decide whether the pre-sim cost cap passes
  syncFill: 120_000n,
  refreshCcReference: 80_000n,
  // a Splits v2 push distribute to two recipients: the hash check, the incentive and two transfers (ETH or ERC20),
  // each with a warehouse deposit fallback. a guess until the simulation measures it
  distributeSplit: 150_000n,
};

export interface Settings {
  buybackSlice: bigint;
  buybackDelay: number;
  keeperFee: bigint;
  keeperMaxBaseFee: bigint;
  callerFee: bigint;
  callerMaxBaseFee: bigint;
  redeemOn: boolean;
  // the ETH purchase budget: spendCapBps 10,000 disables it; a bucket lasts bucketSeconds
  spendCapBps: number;
  bucketSeconds: number;
  // the artist royalty on every purchase, bps of the price, paid on top from the pot (decision 163)
  buyToArtistBps: number;
}

// the state the decisions read, all from one block
export interface State {
  core: Address;
  blockNumber: bigint;
  timestamp: bigint;
  baseFee: bigint;
  settings: Settings;
  // Core.spendState() at the block: the bucket id, its budget and the wei spent in it
  spend: { bucket: bigint; budget: bigint; spent: bigint };
  ethPot: bigint;
  // ethPot plus the pot share of the unbooked income that the door's own `_book` adds first
  potWithPending: bigint;
  // Core.reserve(): the eth the pot keeps for processing. the caller payments still pay from the whole pot
  reserve: bigint;
  // potWithPending less the reserve: the most a buyListing may spend (the clamp of Core.ethRate after the book)
  potRoom: bigint;
  pendingIncome: bigint;
  // timestamp of the last book the keeper sent, 0 until it sends one
  lastBookAt: bigint;
  ethToBuyback: bigint;
  payeeOn: boolean;
  paused: boolean;
  retired: boolean;
  lastBuybackBlock: bigint;
  sniperSeconds: bigint;
  // DeploymentInfoV2.launchedAt of the coin, 0 while the launch is not recorded
  launchedAt: bigint;
  escrowBalance: bigint;
  pageReady: boolean;
  balanceModule: Address;
  // the phase 2 treasury's conversionReady() (IPhase2BalanceTreasury.sol): the conversion switch, the selection,
  // the finalized upstream retirement and the registered renderer, all of which Core.redeemStatement needs before the
  // module's redeem can succeed. undefined when the module has no such view (StatementBalanceModule), which reads
  // as ready so that path is unchanged
  conversionReady?: boolean;
  // ControllerV2.statementRedeemDelaySeconds(): the age a statement needs before atFloor(sid) is true. logged only;
  // atFloor stays the decision. undefined on a controller without the view (V1)
  statementRedeemDelaySeconds?: number;
  // the held statements with controller.atFloor(sid) true
  atFloor: bigint[];
  // the value switch: the controller, the Core's valueModeOn, whether the protected value quote is unusable now,
  // the controller reference, quote controls, and the spot read at the pinned block. An unusable quote makes the Core
  // ETH bid zero. A refresh pays only when the controller
  // sees a nonzero spot and a nonzero integer move at inclusion
  controller: Address;
  valueModeOn: boolean;
  noQuote: boolean;
  referencePrice: bigint;
  referenceTime: bigint;
  referenceMaxStale: bigint;
  referenceMinSeconds: bigint;
  referenceRateBpsPerHour: bigint;
  referenceStepBps: bigint;
  spot: bigint;
  // ControllerV3 (src/ControllerV3.sol), all read tolerantly from the controller: isV3 is set only when idleSince()
  // answers, so the two V3 doors stay inert against ControllerV2 or V1. idleKnown is idleSince().known; when false the
  // value-mode idle loosening reads zero until syncFill moves the hint to the pile tail. lastSyncFillBlock is the block
  // the keeper last sent a syncFill, carried in so the door fires at most once per block. The cc* fields are the CC
  // price reference for later redeemers, meaningful only once ccPoolKeySet is true.
  isV3: boolean;
  idleKnown: boolean;
  lastSyncFillBlock: bigint;
  ccPoolKeySet: boolean;
  ccReferencePrice: bigint;
  ccReferenceTime: bigint;
  ccMaxStale: bigint;
  ccMinSeconds: bigint;
  ccRateBpsPerHour: bigint;
  ccStepBps: bigint;
  // Core.balanceToken() at the block: the token of the split's BALANCE leg, zero while no module is bound
  balanceToken: Address;
  // the split's ETH and balance token holdings at the block, read only while the distributeSplit door is configured;
  // undefined when not read or when the read failed, which skips the leg with a reason
  splitEth?: bigint;
  splitBalance?: bigint;
}

export interface Listing {
  venue: "seaport" | "strategy";
  adapter: Address;
  id: bigint;
  // the `value` the adapter quotes, what the Core pays the venue
  price: bigint;
  // core.bidOf(id) at the state's block
  bid: bigint;
  params: Hex;
  // false when the order is cancelled, filled, or its offerer no longer holds the credit
  valid: boolean;
  why?: string;
}

export interface Gas {
  baseFee: bigint;
}

export interface Intended {
  door: Door;
  functionName: "buyListing" | "buyback" | "compose" | "collectEscrow" | "book" | "redeemStatement" | "refreshReference" | "syncFill" | "refreshCcReference" | "distribute";
  // the contract the call goes to: the Core by default (every Core door, including the refreshReference door that
  // forwards to the controller); "split" is the artist and operator split of the distributeSplit door
  target?: "controller" | "split";
  args: readonly unknown[];
  // the gas the decision assumed; the executor replaces it with the simulation's measure and calls `recheck`
  gas: bigint;
  // the payment the Core sends at `gas`, at the worst base fee
  payment: bigint;
  cost: bigint;
  key: string;
  note?: { [k: string]: unknown };
}

export interface Skip {
  door: Door;
  reason: string;
  key?: string;
}

export interface Policy {
  doors: { [d in Door]: DoorPolicy };
  doorsOn: Set<Door>;
  margin: bigint;
  listingDelaySec: number;
  // a latched Core is booked when the pending income exceeds bookMinWei and the keeper's last book is older than bookMinSec
  bookMinWei: bigint;
  bookMinSec: number;
  // the refreshReference door: driftBps is the spot-to-reference gap (bps) that counts as drift, persistSec how long
  // that drift must persist before a refresh, maxCostEth the ceiling on the keeper's own gas for the unpaid call
  refresh: { driftBps: number; persistSec: number; maxCostEth: bigint };
  // the distributeSplit door's split and the distributor the call names (the keeper address); undefined leaves the door off
  split?: SplitPolicy;
}

export interface SplitPolicy extends SplitConfig {
  distributor: Address;
}

const min = (...v: bigint[]) => v.reduce((a, b) => (b < a ? b : a));

// the base fee the transaction is priced at: the next block's base fee rises at most 1/8, and the transaction is never
// included above the door's ceiling (maxFeePerGas = maxBaseFee + tip)
export function worstBaseFee(gas: Gas, p: DoorPolicy): bigint {
  return min((gas.baseFee * 9n + 7n) / 8n, p.maxBaseFee);
}

// the keeper's own cost of a call: its gas at the worst base fee plus its tip
export function ownCost(gasUsed: bigint, gas: Gas, p: DoorPolicy): bigint {
  return gasUsed * (worstBaseFee(gas, p) + p.tip);
}

// the profit rule of every paid door: Core payment >= own gas x (base fee + tip) + margin
export function profitable(payment: bigint, cost: bigint, margin: bigint): boolean {
  return payment >= cost + margin;
}

// Core.buyListing: min(min(counted, BUYLISTING_GAS) * min(basefee, keeperMaxBaseFee) + keeperFee, bid - price,
// room - price - royalty), where the room is the pot read after the door's book less the reserve (Core.room) and the
// royalty is buyToArtistBps of the price, paid to the artist on top (decision 163). a listing whose price plus
// royalty passes the room reverts PotTooSmall
export function listingPayment(s: State, l: Listing, gasUsed: bigint, b: bigint): bigint {
  const royalty = (l.price * BigInt(s.settings.buyToArtistBps)) / 10_000n;
  if (l.price > l.bid || l.price + royalty > s.potRoom) return 0n;
  const refund = min(gasUsed, BUYLISTING_GAS) * min(b, s.settings.keeperMaxBaseFee) + s.settings.keeperFee;
  return min(refund, l.bid - l.price, s.potRoom - l.price - royalty);
}

// Core.buyback guards and payment at base fee `b`. the swap budget is `slice - maxPay`; the fee is scaled by the eth
// spent over `buybackSlice - maxPay`, with spent taken as the whole budget (an exact in swap without a price limit)
export function buybackQuote(s: State, nextBlock: bigint, gasUsed: bigint, b: bigint) {
  const cfg = s.settings;
  if (s.ethToBuyback === 0n) return { ok: false as const, reason: "NothingToBuy: ethToBuyback is 0" };
  const open = s.lastBuybackBlock + BigInt(cfg.buybackDelay);
  if (nextBlock < open) return { ok: false as const, reason: `TooSoon: open at block ${open}` };
  const slice = min(s.ethToBuyback, cfg.buybackSlice);
  const rate = min(b, cfg.keeperMaxBaseFee);
  const maxPay = BUYBACK_GAS * rate + cfg.keeperFee;
  if (slice < 2n * maxPay) return { ok: false as const, reason: `SliceTooSmall: slice ${slice} under 2 * maxPay ${maxPay}` };
  const spent = slice - maxPay;
  const fee = min(cfg.keeperFee, (cfg.keeperFee * spent) / (cfg.buybackSlice - maxPay));
  const payment = min(gasUsed, BUYBACK_GAS) * rate + fee;
  return { ok: true as const, slice, maxPay, payment };
}

// Core._payCaller for compose and redeemStatement: nothing when both caller settings are 0, else
// min(counted, cap) * min(basefee, callerMaxBaseFee) + callerFee, at most ethPot
export function callerPayment(s: State, gasUsed: bigint, cap: bigint, b: bigint): bigint {
  const cfg = s.settings;
  if (cfg.callerFee === 0n && cfg.callerMaxBaseFee === 0n) return 0n;
  return min(min(gasUsed, cap) * min(b, cfg.callerMaxBaseFee) + cfg.callerFee, s.potWithPending);
}

// Core.spend: the first purchase of a bucket always passes; a later one reverts SpendCapReached when the bucket's spent
// total plus its cost (price plus keeper payment) exceeds the budget. returns the time the next bucket starts when blocked
export function spendBlocked(s: State, cost: bigint): bigint | undefined {
  const { budget, spent, bucket } = s.spend;
  if (s.settings.spendCapBps === 10_000 || spent === 0n || spent + cost <= budget) return undefined;
  return (bucket + 1n) * BigInt(s.settings.bucketSeconds);
}

// whether a book now latches the payee share: Core._book returns before the latch when the income is 0, and the latch
// needs block.timestamp >= launchedAt + settings.sniperSeconds
export function bookLatches(s: State): { ok: boolean; reason: string } {
  if (s.payeeOn) return { ok: false, reason: "payee share already latched" };
  if (s.launchedAt === 0n) return { ok: false, reason: "launch not recorded by the factory" };
  const end = s.launchedAt + s.sniperSeconds;
  if (s.timestamp < end) return { ok: false, reason: `anti sniper window ends at ${end}` };
  if (s.pendingIncome === 0n) return { ok: false, reason: "no unbooked income, a book would not latch" };
  return { ok: true, reason: "window over, income pending, payee share not latched" };
}

// whether a book now moves pending income into the booked pots once the payee share is latched: the income exceeds
// `bookMinWei` and the keeper's last book is more than `bookMinSec` old
export function bookFollowsIncome(s: State, p: Pick<Policy, "bookMinWei" | "bookMinSec">): { ok: boolean; reason: string } {
  if (s.pendingIncome <= p.bookMinWei) return { ok: false, reason: `pending income ${s.pendingIncome} not above ${p.bookMinWei}` };
  if (s.timestamp - s.lastBookAt <= BigInt(p.bookMinSec)) return { ok: false, reason: `last book under ${p.bookMinSec} seconds ago` };
  return { ok: true, reason: "income pending above the book minimum" };
}

export const listingKey = (l: Pick<Listing, "venue" | "id" | "price">) => `${l.venue}:${l.id}:${l.price}`;

// the first time each listing key was seen sweepable: kept for keys still sweepable, set to `now` for new ones,
// dropped for the rest, so a listing that leaves the sweepable set restarts its delay
export function observe(seen: ReadonlyMap<string, bigint>, sweepable: string[], now: bigint): Map<string, bigint> {
  const next = new Map<string, bigint>();
  for (const k of sweepable) next.set(k, seen.get(k) ?? now);
  return next;
}

// the reserved `seen` key the refreshReference door keeps its drift observation under, so a transient spike has to
// persist across ticks before it triggers a refresh. it never collides with a listing key (venue:id:price)
export const REFRESH_DRIFT_KEY = "refresh:driftSince";

// whether the controller reference needs a direct, unpaid refresh now, plus the drift observation to carry to the next
// tick (undefined resets it). the keeper calls the controller's own refreshReference(), not the Core's paid door, so
// the protocol pot pays nothing; the door runs only when it is really needed. the gates, in order: value mode on, a
// reference set and usable (referenceMaxStale nonzero), a readable pool spot; the live spot has drifted off the
// reference by more than driftBps; that drift has persisted at least persistSec (first seen on an earlier tick, reset
// the moment it falls back under the threshold); and a refresh would actually move the reference this tick
// (referenceMinSeconds since the last sample and a nonzero integer move). the controller also no-ops a second refresh
// in one block, but its lastRefreshBlock is private and so unreadable; the referenceMinSeconds gate stands in for it,
// since a same-block refresh set referenceTime to now and leaves elapsed at zero
export function refreshReferenceNeeded(
  s: State,
  r: Pick<Policy["refresh"], "driftBps" | "persistSec">,
  seen: ReadonlyMap<string, bigint>,
): { ok: boolean; reason: string; driftSince?: bigint } {
  if (!s.valueModeOn) return { ok: false, reason: "value mode off" };
  if (s.referencePrice === 0n) return { ok: false, reason: "no reference: the balance pool key is not set" };
  if (s.referenceMaxStale === 0n) return { ok: false, reason: "referenceMaxStale is 0, the reference is never usable" };
  if (s.spot === 0n) return { ok: false, reason: "pool spot is unavailable" };
  const diff = s.spot > s.referencePrice ? s.spot - s.referencePrice : s.referencePrice - s.spot;
  const driftBps = (diff * 10_000n) / s.referencePrice;
  if (driftBps <= BigInt(r.driftBps)) return { ok: false, reason: `drift ${driftBps} bps at or under REFRESH_DRIFT_BPS ${r.driftBps}` };
  const since = seen.get(REFRESH_DRIFT_KEY) ?? s.timestamp;
  const persisted = s.timestamp - since;
  if (persisted < BigInt(r.persistSec)) return { ok: false, reason: `drift ${driftBps} bps seen ${persisted} s, needs REFRESH_PERSIST_SEC ${r.persistSec} s`, driftSince: since };
  const elapsed = s.timestamp - s.referenceTime;
  if (elapsed < s.referenceMinSeconds) return { ok: false, reason: `reference sampled at ${s.referenceTime}, next refresh at ${s.referenceTime + s.referenceMinSeconds}`, driftSince: since };
  const move = (s.referenceRateBpsPerHour * elapsed) / 3_600n;
  if (move === 0n || s.referenceStepBps === 0n) return { ok: false, reason: "reference move rounds to zero", driftSince: since };
  return { ok: true, reason: `drift ${driftBps} bps persisted ${persisted} s`, driftSince: since };
}

// whether the keeper should call ControllerV3's unpaid syncFill() now. a purchase in value mode leaves the fill hint
// stale (idleSince().known false), which makes the idle loosening of the ETH bid read zero; syncFill moves the hint to
// the pile tail so the loosening is known again. the gates mirror decision 273's reference refresh: V3 only (idleSince
// answers), value mode only, and at most once per block (lastSyncFillBlock, set when the keeper sent one; syncFill has
// no on-chain per-block guard of its own, unlike the two refresh calls). the cost cap and the door ceiling are applied
// by the caller, the same unpaid-door door policy and REFRESH_MAX_COST_ETH the reference refresh uses
export function syncFillNeeded(s: State): { ok: boolean; reason: string } {
  if (!s.isV3) return { ok: false, reason: "not ControllerV3: idleSince() did not answer" };
  if (!s.valueModeOn) return { ok: false, reason: "value mode off" };
  if (s.idleKnown) return { ok: false, reason: "the fill hint is known, the loosening is not lost" };
  if (s.lastSyncFillBlock === s.blockNumber) return { ok: false, reason: "a syncFill already went this block" };
  return { ok: true, reason: "the fill hint is unknown, the idle loosening reads zero" };
}

// whether the keeper should call ControllerV3's unpaid refreshCcReference() now. the CC reference has no pool spot view
// (ccPrice() exposes the reference, not the spot), so this takes the smaller change decision 273 allows: it drops the
// spot-drift gate and refreshes when the reference has gone stale and a refresh would move it, keeping the rest of the
// rule. gates in order: V3 only, value mode on (the same rule as the balance reference), the CC pool key set, a CC
// reference set and usable (maxStale nonzero), the reference past maxStale so a later redeemer's ccPrice() reads
// unusable (the "only when needed" stand-in for drift), referenceMinSeconds elapsed since the sample (the contract
// requires it and also no-ops a second refresh in one block), and a nonzero integer move this tick. the cost cap and
// the ceiling are applied by the caller. known ceiling of this shortcut: when the pool is thin or emptied the on-chain
// call no-ops, so the keeper can send one wasted (capped, once-per-block on chain) refresh; reading pool liquidity to
// close that is deferred until a redeemer actually consumes the CC reference
// ponytail: staleness trigger, not spot drift; add the slot0 read if a live redeemer needs the tighter gate
export function refreshCcReferenceNeeded(s: State): { ok: boolean; reason: string } {
  if (!s.isV3) return { ok: false, reason: "not ControllerV3: idleSince() did not answer" };
  if (!s.valueModeOn) return { ok: false, reason: "value mode off" };
  if (!s.ccPoolKeySet) return { ok: false, reason: "the CC pool key is not set" };
  if (s.ccReferencePrice === 0n) return { ok: false, reason: "no CC reference set" };
  if (s.ccMaxStale === 0n) return { ok: false, reason: "ccMaxStale is 0, the CC reference is never usable" };
  const elapsed = s.timestamp - s.ccReferenceTime;
  if (elapsed <= s.ccMaxStale) return { ok: false, reason: `CC reference ${elapsed} s old, still within ccMaxStale ${s.ccMaxStale} s` };
  if (elapsed < s.ccMinSeconds) return { ok: false, reason: `CC reference sampled at ${s.ccReferenceTime}, next refresh at ${s.ccReferenceTime + s.ccMinSeconds}` };
  const move = (s.ccRateBpsPerHour * elapsed) / 3_600n;
  if (move === 0n || s.ccStepBps === 0n) return { ok: false, reason: "CC reference move rounds to zero" };
  return { ok: true, reason: `CC reference ${elapsed} s old, past ccMaxStale ${s.ccMaxStale} s` };
}

// the legs of the artist and operator split that are due: ETH when the split holds at least minEth, the balance token
// when the BALANCE leg is on (minBalance set), the Core has a balance token and the split holds at least minBalance.
// a leg whose balance was not read is skipped with its reason rather than guessed
export function splitLegs(s: State, split: SplitConfig): { due: { token: Address; amount: bigint; leg: "eth" | "balance" }[]; skips: string[] } {
  const due: { token: Address; amount: bigint; leg: "eth" | "balance" }[] = [];
  const skips: string[] = [];
  if (s.splitEth === undefined) skips.push("split ETH balance not read");
  else if (s.splitEth < split.minEth) skips.push(`split ETH ${s.splitEth} under SPLIT_MIN_ETH ${split.minEth}`);
  else due.push({ token: zeroAddress, amount: s.splitEth, leg: "eth" });
  if (split.minBalance !== undefined) {
    if (s.balanceToken === zeroAddress) skips.push("no balance token bound, the BALANCE leg waits");
    else if (s.splitBalance === undefined) skips.push("split BALANCE balance not read");
    else if (s.splitBalance < split.minBalance) skips.push(`split BALANCE ${s.splitBalance} under SPLIT_MIN_BALANCE ${split.minBalance}`);
    else due.push({ token: s.balanceToken, amount: s.splitBalance, leg: "balance" });
  }
  return { due, skips };
}

// every call the keeper would make at this state, in priority order: buyListing (best gap first), buyback, compose,
// collectEscrow, book, redeemStatement, refreshReference, distributeSplit. returns the updated listing observation map
export function decide(
  s: State,
  listings: Listing[],
  gas: Gas,
  p: Policy,
  seen: ReadonlyMap<string, bigint>,
): { calls: Intended[]; skips: Skip[]; seen: Map<string, bigint> } {
  const calls: Intended[] = [];
  const skips: Skip[] = [];
  const blockedByPause = (d: Door) => d === "buyListing" || d === "buyback" || d === "compose";
  const on = (d: Door) => p.doorsOn.has(d) && !(s.paused && blockedByPause(d));
  // A pause stops acquisitions, composition and buybacks. Bookkeeping, escrow collection, reference refresh and
  // redemption remain callable by the Core, so the keeper can continue those jobs.
  if (s.paused) {
    for (const d of p.doorsOn) if (blockedByPause(d)) skips.push({ door: d, reason: "Paused: the Core is paused" });
  }
  const ceiling = (d: Door) => {
    if (gas.baseFee > p.doors[d].maxBaseFee) {
      skips.push({ door: d, reason: `base fee ${gas.baseFee} above the door ceiling ${p.doors[d].maxBaseFee}` });
      return false;
    }
    return true;
  };

  // 1. buyListing
  const sweepable: { l: Listing; key: string; payment: bigint; cost: bigint }[] = [];
  // `noQuote` reports an unusable protected quote; the pinned Core bid for each listing is zero then, so a sweep
  // cannot pass the listing's price check. The quote flag itself is informational here.
  if (on("buyListing") && !s.retired && s.potRoom === 0n) {
    skips.push({ door: "buyListing", reason: `ReserveHeld: the pot ${s.potWithPending} is at or under the reserve ${s.reserve}, acquisitions wait for fees` });
  } else if (on("buyListing") && !s.retired && ceiling("buyListing")) {
    const pol = p.doors.buyListing;
    const b = worstBaseFee(gas, pol);
    for (const l of listings) {
      const key = listingKey(l);
      if (!l.valid) {
        skips.push({ door: "buyListing", key, reason: l.why ?? "order not fillable" });
        continue;
      }
      if (l.price > l.bid) continue;
      // the pot pays the price plus its artist royalty, so the room bounds price + royalty (Core.buyListing, decision 163)
      const royalty = (l.price * BigInt(s.settings.buyToArtistBps)) / 10_000n;
      if (l.price + royalty > s.potRoom) {
        skips.push({ door: "buyListing", key, reason: "PotTooSmall: price plus its artist royalty above ethPot less the reserve" });
        continue;
      }
      const payment = listingPayment(s, l, GAS_GUESS.buyListing, b);
      const cost = ownCost(GAS_GUESS.buyListing, gas, pol);
      if (!profitable(payment, cost, p.margin)) {
        skips.push({ door: "buyListing", key, reason: `unprofitable: payment ${payment} under cost ${cost} plus margin` });
        continue;
      }
      const waitUntil = spendBlocked(s, l.price + royalty + payment);
      if (waitUntil !== undefined) {
        skips.push({ door: "buyListing", key, reason: `SpendCapReached: bucket budget ${s.spend.budget} has ${s.spend.spent} spent, next bucket at ${waitUntil}` });
        continue;
      }
      sweepable.push({ l, key, payment, cost });
    }
  }
  const nextSeen = observe(seen, sweepable.map((x) => x.key), s.timestamp);
  sweepable
    .sort((x, y) => (y.l.bid - y.l.price > x.l.bid - x.l.price ? 1 : y.l.bid - y.l.price < x.l.bid - x.l.price ? -1 : 0))
    .forEach(({ l, key, payment, cost }) => {
      const age = s.timestamp - nextSeen.get(key)!;
      if (age < BigInt(p.listingDelaySec)) {
        skips.push({ door: "buyListing", key, reason: `listing seen ${age} s ago, delay ${p.listingDelaySec} s` });
        return;
      }
      calls.push({
        door: "buyListing",
        functionName: "buyListing",
        args: [l.adapter, l.id, l.params],
        gas: GAS_GUESS.buyListing,
        payment,
        cost,
        key,
        note: { venue: l.venue, id: l.id, price: l.price, bid: l.bid, gap: l.bid - l.price, ageSec: age },
      });
    });

  // 2. buyback
  if (on("buyback") && ceiling("buyback")) {
    const pol = p.doors.buyback;
    const q = buybackQuote(s, s.blockNumber + 1n, GAS_GUESS.buyback, worstBaseFee(gas, pol));
    if (!q.ok) skips.push({ door: "buyback", reason: q.reason });
    else {
      const cost = ownCost(GAS_GUESS.buyback, gas, pol);
      if (!profitable(q.payment, cost, p.margin)) skips.push({ door: "buyback", reason: `unprofitable: payment ${q.payment} under cost ${cost} plus margin` });
      else calls.push({ door: "buyback", functionName: "buyback", args: [], gas: GAS_GUESS.buyback, payment: q.payment, cost, key: "buyback", note: { slice: q.slice, maxPay: q.maxPay } });
    }
  }

  // 3. compose
  if (on("compose") && !s.pageReady) skips.push({ door: "compose", reason: "NotReady: nextPage not ready" });
  else if (on("compose") && !s.retired && ceiling("compose")) {
    const pol = p.doors.compose;
    const payment = callerPayment(s, GAS_GUESS.compose, COMPOSE_GAS, worstBaseFee(gas, pol));
    const cost = ownCost(GAS_GUESS.compose, gas, pol);
    if (!profitable(payment, cost, p.margin)) skips.push({ door: "compose", reason: `unprofitable: payment ${payment} under cost ${cost} plus margin` });
    else calls.push({ door: "compose", functionName: "compose", args: [], gas: GAS_GUESS.compose, payment, cost, key: "compose" });
  }

  // 4. collectEscrow: unpaid; books the escrow credit (a partial buyback fill refund) into the pot when it is worth
  // at least the gas that moves it
  if (on("collectEscrow") && s.escrowBalance > 0n && ceiling("collectEscrow")) {
    const cost = ownCost(GAS_GUESS.collectEscrow, gas, p.doors.collectEscrow);
    if (s.escrowBalance < cost) skips.push({ door: "collectEscrow", reason: `escrow ${s.escrowBalance} under the gas cost ${cost}` });
    else calls.push({ door: "collectEscrow", functionName: "collectEscrow", args: [], gas: GAS_GUESS.collectEscrow, payment: 0n, cost, key: "collectEscrow", note: { escrow: s.escrowBalance } });
  }

  // 5. book: unpaid; the book that latches the payee share, then the book that follows pending income once latched
  if (on("book")) {
    const r = s.payeeOn ? bookFollowsIncome(s, p) : bookLatches(s);
    if (!r.ok) skips.push({ door: "book", reason: r.reason });
    else if (ceiling("book")) {
      const cost = ownCost(GAS_GUESS.book, gas, p.doors.book);
      calls.push({ door: "book", functionName: "book", args: [], gas: GAS_GUESS.book, payment: 0n, cost, key: "book", note: { income: s.pendingIncome } });
    }
  }

  // 6. redeemStatement: reverts NoBalanceModule until a module is set, so it is skipped (one log per tick, no simulation)
  // until then. A phase 2 treasury whose conversionReady() is false reverts ConversionOff (or the upstream token refuses
  // the withdrawal), so the door is skipped until the treasury reports ready; a module without the view is treated as ready
  if (on("redeemStatement") && s.atFloor.length > 0) {
    const pol = p.doors.redeemStatement;
    if (/^0x0{40}$/i.test(s.balanceModule)) skips.push({ door: "redeemStatement", reason: "no balance module bound" });
    else if (!s.settings.redeemOn) skips.push({ door: "redeemStatement", reason: "RedeemOff" });
    else if (s.conversionReady === false) skips.push({ door: "redeemStatement", reason: "conversion not ready" });
    else if (ceiling("redeemStatement")) {
      for (const sid of s.atFloor) {
        const payment = callerPayment(s, GAS_GUESS.redeemStatement, REDEEM_GAS, worstBaseFee(gas, pol));
        const cost = ownCost(GAS_GUESS.redeemStatement, gas, pol);
        const key = `redeem:${sid}`;
        if (!profitable(payment, cost, p.margin)) {
          skips.push({ door: "redeemStatement", key, reason: `unprofitable: payment ${payment} under cost ${cost} plus margin` });
        } else {
          calls.push({ door: "redeemStatement", functionName: "redeemStatement", args: [sid], gas: GAS_GUESS.redeemStatement, payment, cost, key, note: { sid } });
        }
      }
    }
  }

  // 7. refreshReference: a direct, unpaid call to the controller's own refreshReference(), so the protocol pot pays
  // nothing. it runs only when the reference has drifted off the pool spot beyond REFRESH_DRIFT_BPS, that drift has
  // persisted REFRESH_PERSIST_SEC, a refresh would move it, and the keeper's own gas is at or under REFRESH_MAX_COST_ETH.
  // the drift observation is carried in `nextSeen` under a reserved key so it survives to the next tick and is dropped
  // the moment the drift resets. a controller without the reference views (ControllerV1 before a pool key, or an older
  // one) reads referencePrice 0 and skips here. being unpaid, the door uses the cost cap instead of the profit rule
  if (on("refreshReference")) {
    const need = refreshReferenceNeeded(s, p.refresh, seen);
    if (need.driftSince !== undefined) nextSeen.set(REFRESH_DRIFT_KEY, need.driftSince);
    if (!need.ok) skips.push({ door: "refreshReference", reason: need.reason });
    else if (ceiling("refreshReference")) {
      const pol = p.doors.refreshReference;
      const cost = ownCost(GAS_GUESS.refreshReference, gas, pol);
      if (cost > p.refresh.maxCostEth) {
        skips.push({ door: "refreshReference", reason: `gas over cap: own cost ${cost} over REFRESH_MAX_COST_ETH ${p.refresh.maxCostEth}` });
      } else {
        calls.push({ door: "refreshReference", functionName: "refreshReference", target: "controller", args: [], gas: GAS_GUESS.refreshReference, payment: 0n, cost, key: "refreshReference", note: { controller: s.controller, drift: need.reason, referenceTime: s.referenceTime, referencePrice: s.referencePrice, spot: s.spot } });
      }
    }
  }

  // 7b. syncFill: a direct, unpaid call to ControllerV3's syncFill(), under the same door policy and cost cap as the
  // reference refresh. it keeps the value-mode idle loosening known after a purchase. inert on ControllerV2 and V1
  if (on("syncFill")) {
    const need = syncFillNeeded(s);
    if (!need.ok) skips.push({ door: "syncFill", reason: need.reason });
    else if (ceiling("syncFill")) {
      const pol = p.doors.syncFill;
      const cost = ownCost(GAS_GUESS.syncFill, gas, pol);
      if (cost > p.refresh.maxCostEth) {
        skips.push({ door: "syncFill", reason: `gas over cap: own cost ${cost} over REFRESH_MAX_COST_ETH ${p.refresh.maxCostEth}` });
      } else {
        calls.push({ door: "syncFill", functionName: "syncFill", target: "controller", args: [], gas: GAS_GUESS.syncFill, payment: 0n, cost, key: "syncFill", note: { controller: s.controller } });
      }
    }
  }

  // 7c. refreshCcReference: a direct, unpaid call to ControllerV3's refreshCcReference(), under the same door policy and
  // cost cap. it keeps the CC price reference fresh for later redeemers, triggered on staleness (see the predicate).
  // inert on ControllerV2 and V1 (and while the CC pool key is unset)
  if (on("refreshCcReference")) {
    const need = refreshCcReferenceNeeded(s);
    if (!need.ok) skips.push({ door: "refreshCcReference", reason: need.reason });
    else if (ceiling("refreshCcReference")) {
      const pol = p.doors.refreshCcReference;
      const cost = ownCost(GAS_GUESS.refreshCcReference, gas, pol);
      if (cost > p.refresh.maxCostEth) {
        skips.push({ door: "refreshCcReference", reason: `gas over cap: own cost ${cost} over REFRESH_MAX_COST_ETH ${p.refresh.maxCostEth}` });
      } else {
        calls.push({ door: "refreshCcReference", functionName: "refreshCcReference", target: "controller", args: [], gas: GAS_GUESS.refreshCcReference, payment: 0n, cost, key: "refreshCcReference", note: { controller: s.controller, ccReferenceTime: s.ccReferenceTime, ccReferencePrice: s.ccReferencePrice, reason: need.reason } });
      }
    }
  }

  // 8. distributeSplit: the owner's own money (the artist and operator cut) moving from the split to its recipients, so
  // it is not profit gated: the split's distribution incentive, if any, pays the keeper as distributor, otherwise the
  // keeper pays the gas. gated on the balance thresholds and the door's base fee ceiling; the cost is logged
  if (on("distributeSplit")) {
    if (!p.split) skips.push({ door: "distributeSplit", reason: "no split configured" });
    else {
      const legs = splitLegs(s, p.split);
      for (const reason of legs.skips) skips.push({ door: "distributeSplit", reason });
      if (legs.due.length > 0 && ceiling("distributeSplit")) {
        const split = p.split;
        const cost = ownCost(GAS_GUESS.distributeSplit, gas, p.doors.distributeSplit);
        const config = { recipients: split.recipients, allocations: split.allocations, totalAllocation: split.totalAllocation, distributionIncentive: split.distributionIncentive };
        for (const leg of legs.due) {
          calls.push({
            door: "distributeSplit",
            functionName: "distribute",
            target: "split",
            args: [config, leg.token, split.distributor],
            gas: GAS_GUESS.distributeSplit,
            payment: 0n,
            cost,
            key: `distributeSplit:${leg.leg}`,
            note: { split: split.address, token: leg.token, amount: leg.amount, distributor: split.distributor, incentive: split.distributionIncentive },
          });
        }
      }
    }
  }

  return { calls, skips, seen: nextSeen };
}

// the payment and cost of a decided call at the gas its simulation measured, and whether it still clears the rule.
// unpaid doors pass when the measured cost is what the decision allowed for
export function recheck(c: Intended, s: State, listing: Listing | undefined, gasUsed: bigint, gas: Gas, p: Policy) {
  const pol = p.doors[c.door];
  const b = worstBaseFee(gas, pol);
  const cost = ownCost(gasUsed, gas, pol);
  let payment = 0n;
  switch (c.door) {
    case "buyListing":
      payment = listing ? listingPayment(s, listing, gasUsed, b) : 0n;
      break;
    case "buyback": {
      const q = buybackQuote(s, s.blockNumber + 1n, gasUsed, b);
      payment = q.ok ? q.payment : 0n;
      break;
    }
    case "compose":
      payment = callerPayment(s, gasUsed, COMPOSE_GAS, b);
      break;
    case "redeemStatement":
      payment = callerPayment(s, gasUsed, REDEEM_GAS, b);
      break;
    case "refreshReference":
    case "syncFill":
    case "refreshCcReference":
      // unpaid, direct to the controller: it clears while the measured gas keeps the keeper's own cost at or under the cap
      return { ok: cost <= p.refresh.maxCostEth, payment: 0n, cost };
    case "collectEscrow":
      return { ok: s.escrowBalance >= cost, payment, cost };
    case "book":
      return { ok: true, payment, cost };
    case "distributeSplit":
      // the owner's own money moving; the measured cost is logged, never a gate
      return { ok: true, payment, cost };
  }
  // compose and redeemStatement are paid through the caller fee: they go only when the Core pays at least the cost
  return { ok: profitable(payment, cost, p.margin), payment, cost };
}
