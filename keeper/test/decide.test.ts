// promise: every keeper gate restates its Core rule at the boundary, so the keeper never sends a call that reverts on a
// gate it can read, nor a paid call that pays it less than its own gas plus the margin
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseEther, parseGwei, zeroAddress, type Address } from "viem";
import {
  bookLatches,
  BUYBACK_GAS,
  buybackQuote,
  callerPayment,
  decide,
  GAS_GUESS,
  listingKey,
  listingPayment,
  observe,
  refreshReferenceNeeded,
  refreshCcReferenceNeeded,
  syncFillNeeded,
  REFRESH_DRIFT_KEY,
  recheck,
  worstBaseFee,
  type Listing,
  type Policy,
  type State,
} from "../src/decide.ts";
import { DOORS, type Door } from "../src/config.ts";
import { candidatesOrEmpty } from "../src/main.ts";

const CORE = "0x00000000000000000000000000000000000000c0" as Address;
const SEAPORT_ADAPTER = "0x00000000000000000000000000000000000000a1" as Address;

// launch values of script/config/mainnet.json (decisions 119 and 138)
function state(over: Partial<State> = {}): State {
  return {
    core: CORE,
    blockNumber: 1_000n,
    timestamp: 10_000n,
    baseFee: parseGwei("1"),
    settings: {
      buybackSlice: parseEther("0.5"),
      buybackDelay: 25,
      keeperFee: parseEther("0.0003"),
      keeperMaxBaseFee: parseGwei("5"),
      callerFee: parseEther("0.0003"),
      callerMaxBaseFee: parseGwei("3"),
      redeemOn: true,
      spendCapBps: 100,
      bucketSeconds: 60,
      buyToArtistBps: 250,
    },
    spend: { bucket: 166n, budget: parseEther("0.1"), spent: 0n },
    ethPot: parseEther("10"),
    potWithPending: parseEther("10"),
    reserve: parseEther("0.1"),
    potRoom: parseEther("9.9"),
    pendingIncome: 0n,
    lastBookAt: 0n,
    ethToBuyback: 0n,
    payeeOn: true,
    paused: false,
    retired: false,
    lastBuybackBlock: 0n,
    sniperSeconds: 1_800n,
    launchedAt: 1n,
    escrowBalance: 0n,
    pageReady: false,
    balanceModule: zeroAddress,
    atFloor: [],
    controller: "0x00000000000000000000000000000000000000c1" as Address,
    valueModeOn: false,
    noQuote: false,
    referencePrice: 0n,
    referenceTime: 0n,
    referenceMaxStale: 0n,
    referenceMinSeconds: 600n,
    referenceRateBpsPerHour: 100n,
    referenceStepBps: 100n,
    spot: parseEther("0.49"),
    // ControllerV3 defaults: not V3, so the two V3 doors are inert unless a test opts in
    isV3: false,
    idleKnown: true,
    lastSyncFillBlock: 0n,
    ccPoolKeySet: false,
    ccReferencePrice: 0n,
    ccReferenceTime: 0n,
    ccMaxStale: 0n,
    ccMinSeconds: 0n,
    ccRateBpsPerHour: 0n,
    ccStepBps: 0n,
    balanceToken: zeroAddress,
    ...over,
  };
}

function policy(over: Partial<{ [d in Door]: { maxBaseFee: bigint; tip: bigint } }> = {}, delay = 120): Policy {
  const doors = {} as Policy["doors"];
  for (const d of DOORS) doors[d] = { maxBaseFee: d === "buyListing" || d === "buyback" ? parseGwei("5") : parseGwei("3"), tip: parseGwei(d === "compose" ? "0.02" : "0.05") };
  return { doors: { ...doors, ...over }, doorsOn: new Set(DOORS), margin: parseEther("0.00005"), listingDelaySec: delay, bookMinWei: parseEther("0.01"), bookMinSec: 600, refresh: { driftBps: 300, persistSec: 600, maxCostEth: parseEther("0.00005") } };
}

const gas = (g: string) => ({ baseFee: parseGwei(g) });
const doorsOf = (r: ReturnType<typeof decide>) => r.calls.map((c) => c.door);
const reason = (r: ReturnType<typeof decide>, d: Door) => r.skips.filter((s) => s.door === d).map((s) => s.reason).join(" | ");

// promise: a listing-source failure cannot suppress a profitable independent buyback decision
test("listing discovery failure leaves other keeper doors available", async () => {
  const listings = await candidatesOrEmpty({ candidates: async () => { throw new Error("listing rpc unavailable"); } }, {} as any, 1_000n);
  assert.deepEqual(listings, []);
  const d = decide(state({ ethToBuyback: parseEther("1") }), listings, gas("1"), policy(), new Map());
  assert.ok(d.calls.some((c) => c.door === "buyback"));
  assert.ok(d.calls.every((c) => c.door !== "buyListing"));
});

// ------------------------------------------------------------------ buyback

test("buyback: the delay opens at lastBuybackBlock + buybackDelay, the next block included", () => {
  const p = policy();
  // the next block is blockNumber + 1; open = 975 + 25 = 1000 < 1001, and 977 + 25 = 1002 > 1001
  const open = decide(state({ ethToBuyback: parseEther("1"), lastBuybackBlock: 976n }), [], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(open), ["buyback"]);
  const shut = decide(state({ ethToBuyback: parseEther("1"), lastBuybackBlock: 977n }), [], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(shut), []);
  assert.match(reason(shut, "buyback"), /TooSoon: open at block 1002/);
});

test("buyback: a slice under 2 * maxPay is SliceTooSmall, at 2 * maxPay the Core takes it", () => {
  const p = policy();
  const g = gas("1");
  const b = worstBaseFee(g, p.doors.buyback);
  const maxPay = BUYBACK_GAS * b + parseEther("0.0003");
  assert.equal(buybackQuote(state({ ethToBuyback: 2n * maxPay }), 2_000n, 270_000n, b).ok, true);
  const under = decide(state({ ethToBuyback: 2n * maxPay - 1n }), [], g, p, new Map());
  assert.deepEqual(doorsOf(under), []);
  assert.match(reason(under, "buyback"), /SliceTooSmall/);
});

test("buyback: a slice near 2 * maxPay scales the fee to almost nothing, so the keeper's tip is a loss and it waits", () => {
  const p = policy();
  const g = gas("1");
  const maxPay = BUYBACK_GAS * worstBaseFee(g, p.doors.buyback) + parseEther("0.0003");
  const at = decide(state({ ethToBuyback: 2n * maxPay }), [], g, p, new Map());
  assert.deepEqual(doorsOf(at), []);
  assert.match(reason(at, "buyback"), /unprofitable/);
});

test("buyback: an empty pot is NothingToBuy", () => {
  const r = decide(state({ ethToBuyback: 0n }), [], gas("1"), policy(), new Map());
  assert.match(reason(r, "buyback"), /NothingToBuy/);
});

test("buyback: the fee is scaled by spent over buybackSlice - maxPay, and the full slice pays the whole fee", () => {
  const s = state({ ethToBuyback: parseEther("0.5") });
  const full = buybackQuote(s, 2_000n, 270_000n, parseGwei("1"));
  assert.ok(full.ok);
  assert.equal(full.payment, 270_000n * parseGwei("1") + parseEther("0.0003"));
  const half = buybackQuote({ ...s, ethToBuyback: parseEther("0.25") }, 2_000n, 270_000n, parseGwei("1"));
  assert.ok(half.ok);
  const maxPay = BUYBACK_GAS * parseGwei("1") + parseEther("0.0003");
  const fee = (parseEther("0.0003") * (parseEther("0.25") - maxPay)) / (parseEther("0.5") - maxPay);
  assert.equal(half.payment, 270_000n * parseGwei("1") + fee);
});

// ------------------------------------------------------------------ the 5 gwei cap

test("cap: a base fee above the door ceiling skips the door, at the ceiling it runs", () => {
  const s = state({ ethToBuyback: parseEther("1") });
  assert.deepEqual(doorsOf(decide(s, [], gas("5"), policy(), new Map())), ["buyback"]);
  const over = decide(s, [], { baseFee: parseGwei("5") + 1n }, policy(), new Map());
  assert.deepEqual(doorsOf(over), []);
  assert.match(reason(over, "buyback"), /above the door ceiling/);
});

test("cap: above keeperMaxBaseFee the refund stops at 5 gwei and the paid door loses, so it is skipped", () => {
  // the owner lets the keeper send at 10 gwei; the Core still refunds at 5 gwei
  const p = policy({ buyback: { maxBaseFee: parseGwei("10"), tip: parseGwei("0.05") } });
  const r = decide(state({ ethToBuyback: parseEther("1") }), [], gas("6"), p, new Map());
  assert.deepEqual(doorsOf(r), []);
  assert.match(reason(r, "buyback"), /unprofitable/);
});

test("cap: the worst base fee is the next block's 9/8 rise, bounded by the door ceiling", () => {
  const p = policy().doors.buyback;
  assert.equal(worstBaseFee(gas("4"), p), parseGwei("4.5"));
  assert.equal(worstBaseFee(gas("4.8"), p), parseGwei("5"));
});

// ------------------------------------------------------------------ listings

function listing(over: Partial<Listing> = {}): Listing {
  return { venue: "seaport", adapter: SEAPORT_ADAPTER, id: 7n, price: parseEther("0.01"), bid: parseEther("0.012"), params: "0x1234", valid: true, ...over };
}

test("listing: swept only after it has been sweepable for the listing delay (decision 137)", () => {
  const p = policy({}, 120);
  const l = listing();
  const t0 = decide(state({ timestamp: 1_000n }), [l], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(t0), []);
  assert.match(reason(t0, "buyListing"), /seen 0 s ago, delay 120 s/);
  const t1 = decide(state({ timestamp: 1_119n }), [l], gas("1"), p, t0.seen);
  assert.deepEqual(doorsOf(t1), []);
  const t2 = decide(state({ timestamp: 1_120n }), [l], gas("1"), p, t1.seen);
  assert.deepEqual(doorsOf(t2), ["buyListing"]);
  assert.deepEqual(t2.calls[0].args, [SEAPORT_ADAPTER, 7n, "0x1234"]);
  const immediate = decide(state({ timestamp: 1_000n }), [l], gas("1"), policy({}, 0), new Map());
  assert.deepEqual(doorsOf(immediate), ["buyListing"]);
  assert.equal(immediate.calls[0].note?.ageSec, 0n);
});

test("listing: a listing that leaves the sweepable set restarts its delay; a new price is a new listing", () => {
  const seen = observe(new Map([[listingKey(listing()), 1_000n]]), [], 1_100n);
  assert.equal(seen.size, 0);
  const again = observe(new Map([[listingKey(listing()), 1_000n]]), [listingKey(listing({ price: parseEther("0.011") }))], 1_100n);
  assert.deepEqual([...again.values()], [1_100n]);
});

test("listing: the payment is min(gas refund + keeperFee, bid - price, ethPot - price); a small gap is unprofitable", () => {
  const p = policy({}, 0);
  // a gap of 0.0001 eth caps the payment under the cost of ~520k gas at 1.125 gwei plus the tip
  const thin = listing({ price: parseEther("0.0119") });
  const r = decide(state(), [thin], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(r), []);
  assert.match(reason(r, "buyListing"), /unprofitable: payment 100000000000000/);
  // the pot cap: a pot just above the price
  const pot = decide(state({ potRoom: parseEther("0.0101") }), [listing()], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(pot), []);
});

test("listing: above the bid or the pot, or not fillable, it is not swept", () => {
  const p = policy({}, 0);
  assert.deepEqual(doorsOf(decide(state(), [listing({ price: parseEther("0.013") })], gas("1"), p, new Map())), []);
  const potShort = decide(state({ potRoom: parseEther("0.005") }), [listing()], gas("1"), p, new Map());
  assert.match(reason(potShort, "buyListing"), /PotTooSmall/);
  const cancelled = decide(state(), [listing({ valid: false, why: "order cancelled" })], gas("1"), p, new Map());
  assert.match(reason(cancelled, "buyListing"), /order cancelled/);
});

// promise: the keeper sweeps only within the pot less the reserve: a listing the whole pot covers but the room does not is
// skipped, a pot at the reserve skips every listing with the reserve reason, and the caller payments still read the whole pot
test("listing: the reserve bounds the sweep, not the processing", () => {
  const p = policy({}, 0);
  const atReserve = decide(state({ potWithPending: parseEther("0.1"), potRoom: 0n, pageReady: true }), [listing()], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(atReserve).filter((d) => d === "buyListing"), []);
  assert.match(reason(atReserve, "buyListing"), /ReserveHeld/);
  assert.ok(doorsOf(atReserve).includes("compose"), "compose still pays from the whole pot");
  const covered = decide(state({ potWithPending: parseEther("0.11"), potRoom: parseEther("0.005") }), [listing()], gas("1"), p, new Map());
  assert.match(reason(covered, "buyListing"), /PotTooSmall: price plus its artist royalty above ethPot less the reserve/);
});

// promise: the artist royalty on a listing rides on top: listingPayment refuses a listing whose price plus royalty
// passes the room, and the room caps the keeper payment at room - price - royalty (decision 163)
test("listing: the artist royalty is part of the room bound and the payment cap", () => {
  const s = state();
  const l = listing(); // price 0.01, bid 0.012; royalty 250 bps is 0.00025
  const royalty = (l.price * 250n) / 10_000n;
  // price plus royalty just over the room: no payment
  const tight = { ...s, potRoom: l.price + royalty - 1n };
  assert.equal(listingPayment(tight, l, GAS_GUESS.buyListing, parseGwei("1")), 0n);
  // the room less price less royalty is the binding cap, below the gap and the gas refund
  const capped = { ...s, potRoom: l.price + royalty + 10n ** 13n };
  assert.equal(listingPayment(capped, l, GAS_GUESS.buyListing, parseGwei("1")), 10n ** 13n);
});

// promise: a zero Core bid during a protected quote outage prevents the keeper from buying a listing
test("listing: in value mode an unusable quote gives no ETH sweep", () => {
  const p = policy({}, 0);
  const degraded = decide(state({ valueModeOn: true, noQuote: true, pageReady: true }), [{ ...listing(), bid: 0n }], gas("1"), p, new Map());
  assert.ok(!doorsOf(degraded).includes("buyListing"), "the Core's zero bid cannot cover the listing price");
  const live = decide(state({ valueModeOn: true, noQuote: false }), [listing()], gas("1"), p, new Map());
  assert.ok(doorsOf(live).includes("buyListing"), "a usable quote sweeps the same way");
});

// ------------------------------------------------------------------ refreshReference
// the door now calls the controller's own refreshReference() directly (unpaid), only when the reference has drifted
// off the pool spot, that drift has persisted, a refresh would move it, and the keeper's own gas stays under the cap.
// value mode on, a usable reference and a 4 percent drift (400 bps > the 300 bps default). referenceTime 1 keeps the
// sample old, so referenceMinSeconds is satisfied and the integer move is nonzero
const refreshBase = {
  valueModeOn: true,
  referencePrice: parseEther("0.49"),
  referenceTime: 1n,
  referenceMaxStale: 7_200n,
  referenceMinSeconds: 600n,
  referenceRateBpsPerHour: 1_200n,
  referenceStepBps: 200n,
};
const DRIFT_SPOT = parseEther("0.5096"); // 0.49 * 1.04, a 400 bps drift off the reference

// promise: a stable market, and a fresh drift seen only once, do not spend gas on an unpaid refresh
test("refreshReference: a stable market makes no call, a 4 percent drift seen once makes no call", () => {
  const p = policy();
  const stable = decide(state({ ...refreshBase, timestamp: 10_000n, spot: parseEther("0.49") }), [], gas("0.5"), p, new Map());
  assert.deepEqual(doorsOf(stable), []);
  assert.match(reason(stable, "refreshReference"), /at or under REFRESH_DRIFT_BPS/);
  assert.equal(stable.seen.has(REFRESH_DRIFT_KEY), false, "no drift, nothing tracked");

  const once = decide(state({ ...refreshBase, timestamp: 10_000n, spot: DRIFT_SPOT }), [], gas("0.5"), p, new Map());
  assert.deepEqual(doorsOf(once), []);
  assert.match(reason(once, "refreshReference"), /needs REFRESH_PERSIST_SEC/);
  assert.equal(once.seen.get(REFRESH_DRIFT_KEY), 10_000n, "the first drift observation is carried to the next tick");
});

// promise: the same drift seen twice at least REFRESH_PERSIST_SEC apart sends one unpaid call to the controller
test("refreshReference: a drift seen twice 600 s apart makes one call to the controller", () => {
  const p = policy();
  const first = decide(state({ ...refreshBase, timestamp: 10_000n, spot: DRIFT_SPOT }), [], gas("0.5"), p, new Map());
  assert.deepEqual(doorsOf(first), []);
  const second = decide(state({ ...refreshBase, timestamp: 10_600n, spot: DRIFT_SPOT }), [], gas("0.5"), p, first.seen);
  assert.deepEqual(doorsOf(second), ["refreshReference"]);
  const c = second.calls[0];
  assert.equal(c.target, "controller", "the call goes to the controller, not the Core");
  assert.equal(c.payment, 0n, "the direct controller refresh is unpaid");
  assert.equal(c.functionName, "refreshReference");
  assert.equal(recheck(c, state({ ...refreshBase, timestamp: 10_600n, spot: DRIFT_SPOT }), undefined, GAS_GUESS.refreshReference, gas("0.5"), p).ok, true, "the measured gas clears the cost cap");
  assert.equal(recheck(c, state({ ...refreshBase, timestamp: 10_600n, spot: DRIFT_SPOT }), undefined, GAS_GUESS.refreshReference, gas("1"), p).ok, false, "a dearer measured gas skips");
});

// promise: a persisted drift still waits while a refresh would not move the reference, and while value mode is off
test("refreshReference: a call within referenceMinSeconds is skipped, and value mode off skips", () => {
  const seeded = new Map([[REFRESH_DRIFT_KEY, 1n]]);
  const soon = decide(state({ ...refreshBase, referenceTime: 10_000n, timestamp: 10_300n, spot: DRIFT_SPOT }), [], gas("0.5"), policy(), seeded);
  assert.deepEqual(doorsOf(soon), []);
  assert.match(reason(soon, "refreshReference"), /next refresh at 10600/);

  const off = decide(state({ ...refreshBase, valueModeOn: false, timestamp: 10_600n, spot: DRIFT_SPOT }), [], gas("0.5"), policy(), seeded);
  assert.deepEqual(doorsOf(off), []);
  assert.match(reason(off, "refreshReference"), /value mode off/);
  assert.equal(refreshReferenceNeeded(state({ ...refreshBase, valueModeOn: false }), policy().refresh, new Map()).ok, false);
});

// promise: the unpaid door still waits when the keeper's own gas would exceed REFRESH_MAX_COST_ETH
test("refreshReference: gas over the cap skips", () => {
  const seeded = new Map([[REFRESH_DRIFT_KEY, 1n]]);
  // gas 1 gwei stays under the 3 gwei door ceiling but puts the 60k-gas own cost (0.0000705 ETH) over the 0.00005 cap
  const dear = decide(state({ ...refreshBase, timestamp: 10_600n, spot: DRIFT_SPOT }), [], gas("1"), policy(), seeded);
  assert.deepEqual(doorsOf(dear), []);
  assert.match(reason(dear, "refreshReference"), /gas over cap/);
});

// promise: the refreshReference rewrite leaves the other doors' decisions untouched
test("refreshReference: other doors are unchanged", () => {
  const buyback = decide(state({ ethToBuyback: parseEther("1"), lastBuybackBlock: 976n }), [], gas("1"), policy(), new Map());
  assert.deepEqual(doorsOf(buyback), ["buyback"]);
  assert.equal(buyback.calls[0].functionName, "buyback");
  assert.equal(buyback.calls[0].target, undefined, "still the Core door");
});

// ------------------------------------------------------------------ ControllerV3: syncFill
// a value-mode purchase leaves the fill hint unknown (idleSince().known false), which zeroes the idle loosening until
// syncFill moves the hint to the pile tail. the keeper calls the controller's syncFill() directly, unpaid, V3 only,
// value mode only, at most once per block, under the reference-refresh cost cap.
const v3Idle = { isV3: true, valueModeOn: true, idleKnown: false };

// promise: syncFill fires only on ControllerV3, in value mode, when the fill hint is unknown, and goes unpaid to the controller
test("syncFill: an unknown hint in value mode on V3 makes one unpaid controller call", () => {
  const p = policy();
  // 0.2 gwei keeps the 120k-gas guess under the 0.00005 ETH cap
  const r = decide(state({ ...v3Idle }), [], gas("0.2"), p, new Map());
  assert.deepEqual(doorsOf(r), ["syncFill"]);
  const c = r.calls[0];
  assert.equal(c.target, "controller", "the call goes to the controller");
  assert.equal(c.functionName, "syncFill");
  assert.equal(c.payment, 0n, "syncFill is unpaid");
  assert.equal(recheck(c, state({ ...v3Idle }), undefined, GAS_GUESS.syncFill, gas("0.3"), p).ok, true, "cheap measured gas clears the cap");
  assert.equal(recheck(c, state({ ...v3Idle }), undefined, GAS_GUESS.syncFill, gas("1"), p).ok, false, "a dearer measured gas skips");
});

// promise: syncFill waits off V3, outside value mode, when the hint is known, and once it has already gone this block
test("syncFill: the gates skip a known hint, value mode off, a non-V3 controller, and a second call in one block", () => {
  const p = policy();
  assert.match(reason(decide(state({ ...v3Idle, idleKnown: true }), [], gas("0.5"), p, new Map()), "syncFill"), /hint is known/);
  assert.match(reason(decide(state({ ...v3Idle, valueModeOn: false }), [], gas("0.5"), p, new Map()), "syncFill"), /value mode off/);
  assert.match(reason(decide(state({ ...v3Idle, isV3: false }), [], gas("0.5"), p, new Map()), "syncFill"), /not ControllerV3/);
  const sameBlock = decide(state({ ...v3Idle, blockNumber: 1_000n, lastSyncFillBlock: 1_000n }), [], gas("0.5"), p, new Map());
  assert.deepEqual(doorsOf(sameBlock), []);
  assert.match(reason(sameBlock, "syncFill"), /already went this block/);
  // the predicate alone: not V3 is refused even with an unknown hint in value mode
  assert.equal(syncFillNeeded(state({ valueModeOn: true, idleKnown: false, isV3: false })).ok, false);
});

// promise: the unpaid syncFill still waits when the keeper's own gas would exceed REFRESH_MAX_COST_ETH
test("syncFill: gas over the cap skips", () => {
  // the 120k-gas guess at 1 gwei is over the 0.00005 ETH cap
  const dear = decide(state({ ...v3Idle }), [], gas("1"), policy(), new Map());
  assert.deepEqual(doorsOf(dear), []);
  assert.match(reason(dear, "syncFill"), /gas over cap/);
});

// ------------------------------------------------------------------ ControllerV3: refreshCcReference
// the CC reference has no pool spot view, so the keeper refreshes it on staleness rather than spot drift: V3, value
// mode, the CC pool key set, a reference set and usable, the reference past ccMaxStale, ccMinSeconds elapsed and a
// nonzero integer move. ccReferenceTime 1 keeps the sample old; timestamp 10_000 puts it well past a 600 s maxStale.
const v3Cc = {
  isV3: true,
  valueModeOn: true,
  ccPoolKeySet: true,
  ccReferencePrice: parseEther("0.0004"),
  ccReferenceTime: 1n,
  ccMaxStale: 600n,
  ccMinSeconds: 300n,
  ccRateBpsPerHour: 1_200n,
  ccStepBps: 200n,
};

// promise: a stale CC reference that a refresh would move makes one unpaid controller call to refreshCcReference
test("refreshCcReference: a stale reference on V3 makes one unpaid controller call", () => {
  const p = policy();
  // 0.3 gwei keeps the 80k-gas guess under the 0.00005 ETH cap
  const r = decide(state({ ...v3Cc, timestamp: 10_000n }), [], gas("0.3"), p, new Map());
  assert.deepEqual(doorsOf(r), ["refreshCcReference"]);
  const c = r.calls[0];
  assert.equal(c.target, "controller", "the call goes to the controller");
  assert.equal(c.functionName, "refreshCcReference");
  assert.equal(c.payment, 0n, "refreshCcReference is unpaid");
  assert.equal(recheck(c, state({ ...v3Cc, timestamp: 10_000n }), undefined, GAS_GUESS.refreshCcReference, gas("0.3"), p).ok, true, "cheap measured gas clears the cap");
});

// promise: the CC refresh waits while the reference is fresh, the pool key is unset, off V3, or the move rounds to zero
test("refreshCcReference: the gates skip a fresh reference, an unset pool key, a non-V3 controller, and a zero move", () => {
  const p = policy();
  // within ccMaxStale: 300 s old against a 600 s maxStale
  assert.match(reason(decide(state({ ...v3Cc, ccReferenceTime: 10_000n, timestamp: 10_300n }), [], gas("0.5"), p, new Map()), "refreshCcReference"), /still within ccMaxStale/);
  assert.match(reason(decide(state({ ...v3Cc, ccPoolKeySet: false, timestamp: 10_000n }), [], gas("0.5"), p, new Map()), "refreshCcReference"), /CC pool key is not set/);
  assert.match(reason(decide(state({ ...v3Cc, isV3: false, timestamp: 10_000n }), [], gas("0.5"), p, new Map()), "refreshCcReference"), /not ControllerV3/);
  // a zero rate makes the integer move round to zero even when stale
  assert.match(reason(decide(state({ ...v3Cc, ccRateBpsPerHour: 0n, timestamp: 10_000n }), [], gas("0.5"), p, new Map()), "refreshCcReference"), /move rounds to zero/);
  assert.equal(refreshCcReferenceNeeded(state({ ...v3Cc, valueModeOn: false, timestamp: 10_000n })).ok, false, "value mode off is refused");
});

test("listing: the best gap goes first (Activity.s.sol rule), and every sweep precedes the buyback", () => {
  const p = policy({}, 0);
  const a = listing({ id: 1n, price: parseEther("0.010") });
  const b = listing({ id: 2n, price: parseEther("0.008") });
  const r = decide(state({ ethToBuyback: parseEther("1") }), [a, b], gas("1"), p, new Map());
  assert.deepEqual(r.calls.map((c) => c.key), [listingKey(b), listingKey(a), "buyback"]);
});

test("listing: nothing is swept after migrate (Retired)", () => {
  assert.deepEqual(doorsOf(decide(state({ retired: true }), [listing()], gas("1"), policy({}, 0), new Map())), []);
});

// ------------------------------------------------------------------ compose and redeem (decision 138)

test("compose: paid at the launch values under 3 gwei, skipped above, unpaid settings never compose", () => {
  const s = state({ pageReady: true });
  assert.deepEqual(doorsOf(decide(s, [], gas("1"), policy(), new Map())), ["compose"]);
  // at 2.9 gwei the worst base fee passes 3 gwei, where the refund stops
  const high = decide(s, [], gas("2.9"), policy({ compose: { maxBaseFee: parseGwei("5"), tip: parseGwei("0.05") } }), new Map());
  assert.deepEqual(doorsOf(high), []);
  assert.match(reason(high, "compose"), /unprofitable/);
  const unpaid = decide({ ...s, settings: { ...s.settings, callerFee: 0n, callerMaxBaseFee: 0n } }, [], gas("1"), policy(), new Map());
  assert.deepEqual(doorsOf(unpaid), []);
  assert.equal(callerPayment({ ...s, settings: { ...s.settings, callerFee: 0n, callerMaxBaseFee: 0n } }, 8_000_000n, 13_700_000n, parseGwei("1")), 0n);
});

test("compose: not ready is NotReady", () => {
  assert.match(reason(decide(state(), [], gas("1"), policy(), new Map()), "compose"), /NotReady/);
});

test("redeem: skipped without simulation while no balance module is set; considered once one is", () => {
  const none = decide(state({ atFloor: [3n] }), [], gas("1"), policy(), new Map());
  assert.equal(none.calls.length, 0);
  assert.equal(none.skips.filter((k) => k.door === "redeemStatement").length, 1);
  assert.equal(reason(none, "redeemStatement"), "no balance module bound");
  const live = decide(state({ atFloor: [3n], balanceModule: "0x00000000000000000000000000000000000000b0" }), [], gas("1"), policy(), new Map());
  assert.equal(live.calls[0].door, "redeemStatement");
  assert.deepEqual(live.calls[0].args, [3n]);
  const off = decide(state({ atFloor: [3n], balanceModule: "0x00000000000000000000000000000000000000b0", settings: { ...state().settings, redeemOn: false } }), [], gas("1"), policy(), new Map());
  assert.match(reason(off, "redeemStatement"), /RedeemOff/);
});

// promise: a phase 2 treasury whose conversionReady() is false reverts ConversionOff on redeemStatement, so the door
// is skipped without a simulation until it reads true; a module without the view (undefined) keeps the existing path
test("redeem: a treasury that is not conversion ready skips; a module without the view is ready", () => {
  const module = "0x00000000000000000000000000000000000000b0" as Address;
  const notReady = decide(state({ atFloor: [3n, 4n], balanceModule: module, conversionReady: false }), [], gas("1"), policy(), new Map());
  assert.equal(notReady.calls.length, 0);
  assert.equal(notReady.skips.filter((k) => k.door === "redeemStatement").length, 1);
  assert.equal(reason(notReady, "redeemStatement"), "conversion not ready");
  const ready = decide(state({ atFloor: [3n], balanceModule: module, conversionReady: true }), [], gas("1"), policy(), new Map());
  assert.deepEqual(doorsOf(ready), ["redeemStatement"]);
  const legacy = decide(state({ atFloor: [3n], balanceModule: module, conversionReady: undefined }), [], gas("1"), policy(), new Map());
  assert.deepEqual(doorsOf(legacy), ["redeemStatement"]);
  // the other guards keep their precedence: no module and RedeemOff are reported before the conversion gate
  const off = decide(state({ atFloor: [3n], balanceModule: module, conversionReady: false, settings: { ...state().settings, redeemOn: false } }), [], gas("1"), policy(), new Map());
  assert.match(reason(off, "redeemStatement"), /RedeemOff/);
  // the delay read is informational: it never changes the decision
  const delayed = decide(state({ atFloor: [3n], balanceModule: module, conversionReady: true, statementRedeemDelaySeconds: 3_600 }), [], gas("1"), policy(), new Map());
  assert.deepEqual(doorsOf(delayed), ["redeemStatement"]);
});

// ------------------------------------------------------------------ book and escrow

test("book: only when the window is over, the payee share is not latched and income is pending", () => {
  const base = { payeeOn: false, launchedAt: 1_000n, sniperSeconds: 1_800n, pendingIncome: 1n };
  assert.equal(bookLatches(state({ ...base, timestamp: 2_799n })).ok, false);
  assert.equal(bookLatches(state({ ...base, timestamp: 2_800n })).ok, true);
  assert.match(bookLatches(state({ ...base, timestamp: 2_800n, pendingIncome: 0n })).reason, /no unbooked income/);
  assert.match(bookLatches(state({ ...base, timestamp: 2_800n, payeeOn: true })).reason, /already latched/);
  assert.match(bookLatches(state({ ...base, timestamp: 2_800n, launchedAt: 0n })).reason, /not recorded/);
  assert.deepEqual(doorsOf(decide(state({ ...base, timestamp: 2_800n }), [], gas("1"), policy(), new Map())), ["book"]);
});

test("escrow: collected when it holds more than the gas that moves it", () => {
  const cost = GAS_GUESS.collectEscrow * (worstBaseFee(gas("1"), policy().doors.collectEscrow) + parseGwei("0.05"));
  assert.deepEqual(doorsOf(decide(state({ escrowBalance: cost }), [], gas("1"), policy(), new Map())), ["collectEscrow"]);
  const small = decide(state({ escrowBalance: cost - 1n }), [], gas("1"), policy(), new Map());
  assert.match(reason(small, "collectEscrow"), /under the gas cost/);
});

// ------------------------------------------------------------------ recheck at the simulated gas

test("recheck: a paid door that measured more gas than its guess is rechecked at the measure", () => {
  const s = state({ ethToBuyback: parseEther("1") });
  const p = policy();
  const c = decide(s, [], gas("1"), p, new Map()).calls[0];
  assert.equal(recheck(c, s, undefined, 270_000n, gas("1"), p).ok, true);
  // gas above BUYBACK_GAS is not refunded: at 2,000,000 gas the payment stops at 600,000 gas
  assert.equal(recheck(c, s, undefined, 2_000_000n, gas("1"), p).ok, false);
});

test("doors off by config are never decided", () => {
  const p = { ...policy(), doorsOn: new Set<Door>(["book"]) };
  assert.deepEqual(doorsOf(decide(state({ ethToBuyback: parseEther("1"), pageReady: true }), [listing()], gas("1"), p, new Map())), []);
});

test("listing: a bucket whose budget cannot take the price plus the keeper payment waits for the next bucket", () => {
  const p = policy({}, 0);
  const l = listing();
  // the first purchase of a bucket always passes, whatever the budget
  const first = decide(state({ spend: { bucket: 166n, budget: 1n, spent: 0n } }), [l], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(first), ["buyListing"]);
  // spent 0.095 + price 0.01 + payment is over the 0.1 budget: skipped with the time the bucket ends
  const over = decide(state({ spend: { bucket: 166n, budget: parseEther("0.1"), spent: parseEther("0.095") } }), [l], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(over), []);
  assert.match(reason(over, "buyListing"), /SpendCapReached: .* next bucket at 10020/);
  // a budget that takes the price and the payment passes
  const fits = decide(state({ spend: { bucket: 166n, budget: parseEther("0.2"), spent: parseEther("0.095") } }), [l], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(fits), ["buyListing"]);
  // spendCapBps 10,000 disables the budget
  const off = decide(state({ settings: { ...state().settings, spendCapBps: 10_000 }, spend: { bucket: 166n, budget: 1n, spent: parseEther("5") } }), [l], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(off), ["buyListing"]);
});

test("paused: acquisition, buyback and compose wait while permitted maintenance keeps running", () => {
  // promise: an owner pause cannot waste keeper gas on blocked doors or strand fees, escrow and reference upkeep.
  const s = state({
    paused: true, pageReady: true, ethToBuyback: parseEther("1"), escrowBalance: parseEther("1"),
    pendingIncome: parseEther("0.02"), atFloor: [3n],
    balanceModule: "0x00000000000000000000000000000000000000b0",
    referencePrice: parseEther("1"), referenceTime: 1n, referenceMaxStale: 1_000n,
  });
  const r = decide(s, [listing()], gas("1"), policy({}, 0), new Map([["stale-listing", 1n]]));
  for (const d of ["buyListing", "buyback", "compose"] as const) assert.match(reason(r, d), /Paused/);
  // refreshReference is no longer pause-blocked, but its own value-mode gate keeps it off here (value mode is off)
  assert.deepEqual(doorsOf(r), ["collectEscrow", "book", "redeemStatement"]);
  assert.match(reason(r, "refreshReference"), /value mode off/);
  assert.equal(r.seen.size, 0, "the listing delay restarts after a pause");
});

// ------------------------------------------------------------------ cold-start gaps from the fixture audit

// a stalled launch: the payee share latched on the first post-window book, the pot is 0 and fee income is pending. a
// door's own `_book` would fold the pending income into the pot and lift the bid, but no paid door clears (the pot is 0
// so every listing is PotTooSmall and the bid cannot rise), and `decide` books only while `!payeeOn`. so the keeper
// sends nothing and the bid stays stalled. the audit asks the decision layer to book here; it does not today.
// KEEPER FINDING: bookLatches returns "already latched" once payeeOn, so the latched/pot-0/pending state never books.
test("book: payee latched, pot 0, income pending — the decision layer still books", () => {
  const s = state({ payeeOn: true, ethPot: 0n, potWithPending: 0n, pendingIncome: parseEther("0.2"), launchedAt: 1_000n, sniperSeconds: 1_800n, timestamp: 3_000n });
  assert.deepEqual(doorsOf(decide(s, [], gas("1"), policy(), new Map())), ["book"]);
});

test("book: latched, the keeper books above BOOK_MIN_ETH once the last book is older than BOOK_MIN_SEC", () => {
  const at = (over: Partial<State>) => doorsOf(decide(state({ payeeOn: true, timestamp: 10_000n, ...over }), [], gas("1"), policy(), new Map()));
  assert.deepEqual(at({ pendingIncome: parseEther("0.0101"), lastBookAt: 9_399n }), ["book"]);
  assert.deepEqual(at({ pendingIncome: parseEther("0.01") }), [], "income at the minimum does not book");
  assert.deepEqual(at({ pendingIncome: parseEther("0.2"), lastBookAt: 9_400n }), [], "a book 600 seconds old does not repeat");
});

// the keeper's listing bid is `core.bidOf(id)` read on chain (src/listings.ts), which the Core derives as
// `ethRate * score / RATE_SCORE`. this takes the bid from that derivation rather than a literal, and shows the sweep
// turns on exactly where the derived bid covers the price.
test("listing: the bid comes from a bidOf derivation (ethRate scaled by score), not a literal", () => {
  const p = policy({}, 0);
  const RATE_SCORE = 1_000_000n; // the per-100-points scale core.bidOf and src/listings.ts divide by
  const ethRate = parseEther("0.002"); // wei per 100 points
  const score = 6_000_000n; // the credit's score, 600 points
  const bidOf = (ethRate * score) / RATE_SCORE; // core.bidOf(id)
  assert.equal(bidOf, parseEther("0.012"), "the derivation reproduces the on-chain bid");
  // a listing under the derived bid sweeps, one above it does not
  const under = decide(state(), [listing({ bid: bidOf, price: parseEther("0.01") })], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(under), ["buyListing"]);
  assert.deepEqual(under.calls[0].args, [SEAPORT_ADAPTER, 7n, "0x1234"]);
  const over = decide(state(), [listing({ bid: bidOf, price: bidOf + 1n })], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(over), []);
});
