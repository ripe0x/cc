// credits engine economic simulator. plain es module, no dependencies, runs in node 22 and in a browser.
// core rules are ported from src/Core.sol on branch flow. units: eth for pots and prices, wei per whole point for the rate,
// seconds for time, whole coins for coin amounts. exitModule and exitToken are the only names for phase 2.

export const W = 1e18;
export const BPS = 10000;

// the Core's Settings struct, same field names, launch values from script/config/mainnet.json.
// durations in seconds, buybackSlice in eth (the Core holds wei). every one can change mid run through `schedule`
export const SETTINGS = {
  flatBps: 10000, // share of the bid priced flat per credit as avgScore, the rest by the credit's own score
  avgScore: 4330000, // 1e4 scale, 433 points
  climbBaseBps: 100, // per hour
  climbDoubleEvery: 24 * 3600,
  climbMaxBps: 800, // per hour
  dropBps: 2000,
  spendCapBps: 2000, // per hour window
  bonusCapBps: 2500, // the controller pays no bonus, so no effect
  tipSavingsBps: 1000,
  tipCapBps: 200,
  reimburseBps: 11000,
  reimburseCapBps: 500,
  saleFloorBps: 7500, // the hard floor: no sale of a statement below cost * saleFloorBps / 10000, whatever the controller asks
  auctionDuration: 24 * 3600, // runs from the first bid
  exitAfter: 105 * 3600, // an unbid listing may exit through the exitModule after this long
  saleToBuybackBps: 5000, // share of collected sale proceeds to the coin buyback, rest to the pot
  exitToBuybackBps: 5000,
  buybackSlice: 1,
  buybackDelay: 25, // blocks, 12 s each
  keeperTipBps: 50,
  xRateCap: 9700,
  xRateFloor: 3000,
  xRateClimbPerHour: 100,
  xRateDropPerCredit: 20,
  xAuctionHalfLife: 6 * 3600,
  exitSliceCredits: 20,
  rateCap: 123200000000000, // wei per whole point, 8 times rateStart: the eth rate never passes it (climb clamp, setRate)
  exitLaneToBuybackBps: 0, // share of exitToken from exit lane exits to the coin buyback, rest to the exit bid pot
  feeToBuybackBps: 0, // share of swap fee eth booked in receive() that goes to the buyback instead of the pot
};
export const SETTING_KEYS = Object.keys(SETTINGS);
// the controller's own settings (src/ControllerV1.sol), owner settable at once. the asking price of a statement starts at startBps of its cost
// and falls stepBps every stepEvery seconds to floorBps. buyOnly false: a buyer at or above the asking price opens the english auction at that price.
// buyOnly true: that buyer pays the asking price and gets the statement at once
export const CONTROLLER = {
  buyOnly: false,
  startBps: 11000,
  stepBps: 100,
  stepEvery: 3 * 3600,
  floorBps: 7500,
};
export const CONTROLLER_KEYS = Object.keys(CONTROLLER);
// ControllerV1 bounds: the name of the first controller field out of bounds, or null
export function controllerViolation(c) {
  if (typeof c.buyOnly !== 'boolean') return 'buyOnly';
  if (c.startBps < 1000 || c.startBps > 40000) return 'startBps';
  if (c.stepBps < 0 || c.stepBps > 5000) return 'stepBps';
  if (c.stepEvery < 60 || c.stepEvery > 30 * 86400) return 'stepEvery';
  if (c.floorBps < 1000 || c.floorBps > c.startBps) return 'floorBps';
  return null;
}

// src/lib/SettingsBounds.sol: the name of the first field out of bounds, or null
export function firstViolation(s) {
  const h = 3600, d = 86400;
  if (s.flatBps > 10000) return 'flatBps';
  if (s.avgScore < 800000 || s.avgScore > 6000000) return 'avgScore';
  if (s.climbBaseBps > 1000) return 'climbBaseBps';
  if (s.climbDoubleEvery < h || s.climbDoubleEvery > 30 * d) return 'climbDoubleEvery';
  if (s.climbMaxBps < s.climbBaseBps || s.climbMaxBps > 2000) return 'climbMaxBps';
  if (s.dropBps < 500 || s.dropBps > 5000) return 'dropBps';
  if (s.spendCapBps < 100 || s.spendCapBps > 5000) return 'spendCapBps';
  if (s.bonusCapBps > 5000) return 'bonusCapBps';
  if (s.tipSavingsBps > 2500) return 'tipSavingsBps';
  if (s.tipCapBps > 500) return 'tipCapBps';
  if (s.reimburseBps > 15000) return 'reimburseBps';
  if (s.reimburseCapBps > 1000) return 'reimburseCapBps';
  if (s.saleFloorBps < 1000 || s.saleFloorBps > 40000) return 'saleFloorBps';
  if (s.auctionDuration < 6 * h || s.auctionDuration > 30 * d) return 'auctionDuration';
  if (s.exitAfter < h || s.exitAfter > 365 * d) return 'exitAfter';
  if (s.saleToBuybackBps > 10000) return 'saleToBuybackBps';
  if (s.exitToBuybackBps > 10000) return 'exitToBuybackBps';
  if (s.buybackSlice < 0.01 || s.buybackSlice > 2) return 'buybackSlice';
  if (s.buybackDelay < 1 || s.buybackDelay > 7200) return 'buybackDelay';
  if (s.keeperTipBps > 500) return 'keeperTipBps';
  if (s.xRateCap > 10000) return 'xRateCap';
  if (s.xRateFloor > s.xRateCap) return 'xRateFloor';
  if (s.xRateClimbPerHour > 1000) return 'xRateClimbPerHour';
  if (s.xRateDropPerCredit > 1000) return 'xRateDropPerCredit';
  if (s.xAuctionHalfLife < 600 || s.xAuctionHalfLife > 30 * d) return 'xAuctionHalfLife';
  if (s.exitSliceCredits < 1 || s.exitSliceCredits > 1000) return 'exitSliceCredits';
  if (s.rateCap < RATE_MIN || s.rateCap > RATE_MAX) return 'rateCap';
  if (s.exitLaneToBuybackBps > 10000) return 'exitLaneToBuybackBps';
  if (s.feeToBuybackBps > 10000) return 'feeToBuybackBps';
  return null;
}
// the eth rate bounds of setRate, rateStart and rateCap, wei per whole point (Interfaces.sol)
export const RATE_MIN = 1e11, RATE_MAX = 1e15;

// constants of the Core and of the pool that are not settings
export const CORE_PARAMS = {
  SUPPLY: 1e9,
  XRATE_START: 6000,
  PAGE: 80,
  COMPOSE_OVERHEAD_GAS: 50000,
  LIST_GAS: 350000, // the listing on the house, eth lane only
  BID_RAISE_BPS: 500, // the house: a later bid must beat the top bid by 5 percent
  TIME_BUFFER: 15 * 60, // the house: a bid in the last 15 minutes pushes the end to 15 minutes from the bid
};

// launch config (script/config/mainnet.json) and simulator inputs
export const SIM_DEFAULTS = {
  seed: 7,
  days: 90,
  rateStart: 1.54e13, // 75 percent of the market price over avgScore: 0.75 * 0.0089e18 / 433
  fundedRule: 'built', // 'built' = the hourly cap affords one average credit, 'old' = the pot affords one (counterfactual)
  schedule: [], // [{ day, patch }]: owner changes settings on that day. patch may hold any setting and `rate` (setRate, wei per point)
  baselineSkimBps: 6900, // of 100000: 6.9 points of volume (script/config/mainnet.json launch.baselineSkimBps)
  bountyBps: 9000, // of the baseline skim, to the fee router. the other 10 percent is the protocol leg, never the engine's
  sniperStartBps: 90000,
  sniperEndBps: 6900, // falls to the baseline
  sniperSeconds: 1800,
  // the fee router (docs/FLOW.md 10.6, 10.7): a flush pays the caller a tip off the top, then, once the split has started, the
  // payee its parts per million of the rest. everything before the split start goes to the engine. no lp fee, no lp income
  routerTipPpm: 5000, // 0.5 percent. the cap of 0.005 eth a flush is ignored, which makes the tip an upper bound
  routerPayeePpm: 161030, // the one launch payee, 1.0 point of volume at the baseline
  routerSplitStartSec: 2700, // launch time plus the 30 minute window plus the 900 second margin
  startTick: -175000,
  positionUpper: 887200,
  // coin market
  volPreset: 'comparable', // comparable | sustained17 | sustained50 | deadWeek1 | custom
  volScale: 1,
  volDay0: 1557,
  volTail: 17, // custom: eth a day after day one
  volHalfLifeDays: 3, // custom: decay of day one volume to the tail
  h1Share: 0.586, // share of day one volume in the first hour
  sniperVolShare: 0.4, // share of first hour volume inside the 30 minute anti sniper window
  buyShare0: 0.526,
  buyShareLate: null, // null: 0.46 for the comparable and week one presets, 0.5 for sustained presets, 0.49 custom
  // credit market
  pricePath: 'flat', // flat | decline | recovery
  priceP0: 0.0089,
  priceTauDays: 20,
  priceEndMult: null, // decline floor and recovery target as a multiple of p0, default 0.4 and 2.2
  askSigma: 0.27,
  impactElast: 0.12,
  impactHalfLifeHours: 48,
  marketDailyEth: 33,
  impactCap: 3,
  offersPerHour: 150,
  bookChurn: 0.05, // share of resting offers that leave each hour
  supplyElast: 1.5,
  holders: 96800,
  listedShare: 0, // share of market offers that are visible listings the keeper takes at the ask through the listing door
  strategyOn: true,
  gasGwei: 1.5,
  composeGas: 8.3e6,
  // statement buyers
  stmtPerDay: 8,
  stmtDecayDays: 21,
  stmtFloorPerDay: 2,
  wtpMult: 1,
  stmtPick: 'cheapest', // a buyer takes the statement with the lowest asking price that fits its willingness to pay; 'random' picks any one that fits
  buyerWaits: 'no', // 'no': a buyer takes what it can afford now. 'floor': every buyer waits until the asking price has reached its lowest level (pessimistic case)
  keeperCollectHours: 1, // collectSales runs this often
  // phase 2 (exitModule and exitToken)
  phase2Day: null,
  xp: 2.5e-5, // eth value of the exitToken paid per point of rating
  takerThreshold: 0.15,
  exitMinRatio: 0, // a keeper exits only when rating * xp is at least this times the asking price
  keeperBuyback: true,
};

export const DEFAULTS = Object.assign({}, CORE_PARAMS, SETTINGS, CONTROLLER, SIM_DEFAULTS);


// quantiles of statement willingness to pay as a multiple of the parts' market cost (data: p10 .48, p25 .71, p50 .84, p75 1.07, 21 percent at 1.2 or more, max 1.32)
export const WTP_Q = [[0, 0.25], [0.1, 0.48], [0.25, 0.71], [0.5, 0.84], [0.75, 1.07], [0.79, 1.2], [0.9, 1.23], [1, 1.32]];
// credit score deciles of the CreditStrategy inventory and its listing price counts (eth, count)
export const STRAT_SCORE_Q = [[0, 80], [0.1, 130], [0.2, 181], [0.3, 238], [0.4, 296], [0.5, 355], [0.6, 416], [0.7, 480], [0.8, 556], [0.9, 640], [1, 785]];
export const STRAT_LISTINGS = [[0.036, 8726], [0.03, 2790], [0.042, 699], [0.048, 599], [0.018, 135], [0.06, 89], [0.012, 48], [0.024, 30], [0.072, 14], [0.054, 2]];
// comparable coin daily volume fit: 122.6 * exp(-0.286 d) for d >= 1, floor 0.5 eth a day
export const COMPARABLE = { a: 122.6, k: 0.286, floor: 0.5 };

export function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
export function normal(rng) {
  let u = rng();
  if (u < 1e-12) u = 1e-12;
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * rng());
}
export function poisson(rng, lam) {
  if (lam <= 0) return 0;
  if (lam > 60) return Math.max(0, Math.round(lam + Math.sqrt(lam) * normal(rng)));
  const L = Math.exp(-lam);
  let k = 0, p = 1;
  do { k++; p *= rng(); } while (p > L);
  return k - 1;
}
export function interp(table, u) {
  for (let i = 1; i < table.length; i++) {
    if (u <= table[i][0]) {
      const [x0, y0] = table[i - 1], [x1, y1] = table[i];
      return y0 + ((y1 - y0) * (u - x0)) / (x1 - x0);
    }
  }
  return table[table.length - 1][1];
}

// ---------------------------------------------------------------- core port
// the Core's state and rules. pots are in eth, the rate in wei per whole point, time in seconds.
// `this.s` is the Settings struct and is read live by every rule, so `setSettings` takes effect at once.
export class Core {
  constructor(p, t0 = 0) {
    this.p = p;
    this.s = {};
    for (const k of SETTING_KEYS) this.s[k] = p[k];
    this.c = {}; // the controller's settings
    for (const k of CONTROLLER_KEYS) this.c[k] = p[k];
    this.feeToBuyback = 0; // cumulative swap fee eth sent to the buyback pot by feeToBuybackBps
    this.ethPot = 0; this.ethToBuyback = 0; this.xPot = 0; this.xToBuyback = 0;
    this.rateAtCheckpoint = p.rateStart; this.checkpointTime = t0; this.lastFillTime = t0; this.funded = false;
    this.windowStart = -1e12; this.windowPot = 0; this.windowSpent = 0;
    this.xRateAtCheckpoint = Math.max(Math.min(p.XRATE_START, this.s.xRateCap), this.s.xRateFloor); this.xCheckpointTime = t0; this.xFunded = false;
    this.xp = 0; this.moduleSet = false; this.xStartPrice = 0; this.xStartTime = 0;
    this.lastBuybackTime = -1e12;
    this.houseOwed = 0; // sale proceeds credited to the Core in the auction house, not in the pots until collectSales
    this.capHits = 0; this.clampTime = 0;
  }
  // the points a credit is priced as: the flat share as an average credit, the rest by its own score (no controller bonus)
  epts(pts) {
    const f = this.s.flatBps;
    return (f * (this.s.avgScore / 1e4) + (BPS - f) * pts) / BPS;
  }
  // the climb stops where the hourly cap no longer buys one average credit (the funded rule as built) or at rateCap,
  // whichever is lower; the old rule is a counterfactual with no clamp
  clamp() {
    const s = this.s;
    if (this.p.fundedRule === 'old') return Infinity;
    return Math.min((this.ethPot * W * s.spendCapBps) / s.avgScore, s.rateCap);
  }
  ethRate(now) {
    const s = this.s;
    let r = this.rateAtCheckpoint;
    if (!this.funded) return r;
    const cap = this.clamp();
    if (cap <= r || s.climbBaseBps === 0) return r;
    const last = this.lastFillTime;
    let t = this.checkpointTime;
    while (t < now && r < cap) {
      const k = t > last ? Math.floor((t - last) / s.climbDoubleEvery) : 0;
      const bps = Math.min(s.climbBaseBps * Math.pow(2, Math.min(k, 16)), s.climbMaxBps);
      const end = k >= 11 ? now : Math.min(now, last + (k + 1) * s.climbDoubleEvery);
      r *= Math.pow(1 + bps / BPS, (end - t) / 3600);
      t = end;
    }
    return Math.min(r, cap);
  }
  checkpoint(now) { this.rateAtCheckpoint = this.ethRate(now); this.checkpointTime = now; }
  syncFunded() {
    const s = this.s;
    if (this.p.fundedRule === 'old') this.funded = this.ethPot * W >= (s.avgScore * this.rateAtCheckpoint) / 1e4;
    else this.funded = this.ethPot * W * s.spendCapBps >= s.avgScore * this.rateAtCheckpoint;
  }
  // owner: setSettings. validates, checkpoints both rates first, then applies at once. patch.rate is setRate.
  // the patch may also hold controller settings (buyOnly, startBps, stepBps, stepEvery, floorBps): the controller reads them live
  setSettings(patch, now) {
    const rate = patch.rate;
    const next = Object.assign({}, this.s), nextC = Object.assign({}, this.c);
    for (const k of SETTING_KEYS) if (patch[k] !== undefined) next[k] = patch[k];
    for (const k of CONTROLLER_KEYS) if (patch[k] !== undefined) nextC[k] = patch[k];
    const bad = firstViolation(next) || controllerViolation(nextC);
    if (bad) throw new Error('BadSetting ' + bad);
    if (rate !== undefined && !(rate >= RATE_MIN && rate <= RATE_MAX && rate <= next.rateCap)) throw new Error('BadRate');
    this.checkpoint(now); this.xCheckpoint(now);
    const anchor = this.moduleSet && this.xToBuyback > 0, half = this.s.xAuctionHalfLife, price = anchor ? this.xAuctionPrice(now) : 0;
    this.s = next; this.c = nextC;
    if (anchor && next.xAuctionHalfLife !== half) { this.xStartPrice = Math.max(price, 1e-12); this.xStartTime = now; }
    this.xRateAtCheckpoint = Math.max(Math.min(this.xRateAtCheckpoint, next.xRateCap), next.xRateFloor);
    this.rateAtCheckpoint = Math.min(this.rateAtCheckpoint, next.rateCap); // a lower cap pulls the rate down now
    if (rate !== undefined) { this.rateAtCheckpoint = rate; this.checkpointTime = now; }
    this.syncFunded();
    if (this.moduleSet) this.syncXFunded();
  }
  // fixed window cap. returns the window state it would use, without committing
  room(x, now) {
    let ws = this.windowStart, wp = this.windowPot, wsp = this.windowSpent;
    if (now >= ws + 3600) { ws = now; wp = this.ethPot; wsp = 0; }
    return { ok: wsp + x <= (wp * this.s.spendCapBps) / BPS + 1e-18, ws, wp, wsp };
  }
  // _spend: checkpoint, hourly cap, drop on fill. false means the Core would revert
  spend(x, now) {
    this.checkpoint(now);
    const pot = this.ethPot;
    if (!(x > 0) || x > pot + 1e-18) return false;
    const rm = this.room(x, now);
    if (!rm.ok) { this.capHits++; return false; }
    this.windowStart = rm.ws; this.windowPot = rm.wp; this.windowSpent = rm.wsp + x;
    let r = this.rateAtCheckpoint;
    r -= (r * this.s.dropBps * Math.min(x, pot)) / (BPS * pot);
    this.rateAtCheckpoint = r;
    this.lastFillTime = now;
    this.ethPot = pot - x;
    this.syncFunded();
    return true;
  }
  // receive(): swap fee eth from the hook. feeToBuybackBps of it goes to the buyback pot, the rest to the pot (checkpoint first, resync after)
  addFees(amount, now) {
    const toBuyback = (amount * this.s.feeToBuybackBps) / BPS;
    this.feeToBuyback += toBuyback;
    this.ethToBuyback += toBuyback;
    this.checkpoint(now);
    this.ethPot += amount - toBuyback;
    this.syncFunded();
    return { toBuyback, toPot: amount - toBuyback };
  }
  ceiling(pts, rate) { return (this.epts(pts) * rate) / W; }
  // door one: sell into the bid at the ceiling. returns the price paid or 0
  sellForEth(pts, now) {
    const price = this.ceiling(pts, this.ethRate(now));
    return this.spend(price, now) ? price : 0;
  }
  // door two: buy a listing at its ask. returns {cost, tip} or null
  buyListing(pts, ask, now) {
    const s = this.s;
    this.checkpoint(now);
    const ceil = this.ceiling(pts, this.rateAtCheckpoint);
    if (ask > this.ethPot || ask > ceil) return null;
    if (!this.room(ask, now).ok) { this.capHits++; return null; }
    const tip = Math.min((s.tipSavingsBps * (ceil - ask)) / BPS, (s.tipCapBps * ask) / BPS);
    if (!this.spend(ask + tip, now)) return null;
    return { cost: ask, tip };
  }
  // compose 80 credits. cost is the sum of their costs. returns the statement (eth lane: listed at age zero, so at the start price)
  compose(costSum, lane, now, gasPriceGwei) {
    const p = this.p, s = this.s;
    const gas = p.composeGas + p.COMPOSE_OVERHEAD_GAS + (lane === 'eth' ? p.LIST_GAS : 0);
    const gasEth = (gas * gasPriceGwei * 1e-9 * s.reimburseBps) / BPS;
    const cap = lane === 'eth' ? costSum : (p.PAGE * s.avgScore * p.rateStart) / 1e4 / W; // notional at the immutable rateStart, not the live rate (FC-4)
    const reimb = Math.min(gasEth, (cap * s.reimburseCapBps) / BPS, this.ethPot);
    let cost = costSum;
    if (reimb > 0) {
      this.checkpoint(now);
      this.ethPot -= reimb;
      this.syncFunded();
      if (lane === 'eth') cost += reimb;
    }
    const st = { cost, reimb, t0: now, lane, bid: 0, bids: 0, end: 0, bidderWtp: 0 };
    if (lane === 'eth') { st.reserve = this.askingPrice(st, now); st.duration = s.auctionDuration; }
    return st;
  }
  // ControllerV1.statementPrice(sid, cost, listedAt): steps = floor(age / stepEvery), bps = max(startBps - min(steps * stepBps, startBps), floorBps).
  // the price is relative to what the engine PAID (the statement cost), not to the market price of its parts
  statementPrice(cost, listedAt, now) {
    const c = this.c;
    const steps = Math.floor(Math.max(0, now - listedAt) / c.stepEvery);
    const bps = Math.max(c.startBps - Math.min(steps * c.stepBps, c.startBps), c.floorBps);
    return (cost * bps) / BPS;
  }
  // the Core's hard floor: no sale below cost * saleFloorBps / 10000
  floorPrice(st) { return (st.cost * this.s.saleFloorBps) / BPS; }
  // _reserveFor: the price used, never below the hard floor. this is the asking price in either mode
  askingPrice(st, now) { return Math.max(this.statementPrice(st.cost, st.t0, now), this.floorPrice(st)); }
  // the lowest asking price the statement will ever have under the current settings (the curve floor or the hard floor, the higher)
  lowestPrice(st) { return (st.cost * Math.max(this.c.floorBps, this.s.saleFloorBps)) / BPS; }
  // the lowest bid the house accepts now: the asking price (the first bidder reprices the listing to it first), or 5 percent over the top bid
  minBid(st, now) {
    if (!st.bid) return this.askingPrice(st, now);
    return st.bid + Math.max((st.bid * this.p.BID_RAISE_BPS) / BPS, 1e-18);
  }
  // house createBid: the first bid at the asking price starts the timer, later bids beat the top bid by 5 percent,
  // a bid inside the last 15 minutes pushes the end to 15 minutes from the bid. returns false when the house would revert
  bidOn(st, amount, now, wtp) {
    if (st.bid && now >= st.end) return false;
    if (amount < this.minBid(st, now) * (1 - 1e-12)) return false;
    if (!st.bid) { st.end = now + st.duration; st.reserve = this.askingPrice(st, now); st.openedAt = now; }
    st.bid = amount; st.bids++; st.bidderWtp = wtp;
    if (st.end - now < this.p.TIME_BUFFER) st.end = now + this.p.TIME_BUFFER;
    return true;
  }
  // endAuction on a bid auction that ran out: the winner gets the statement, the proceeds are credited to the Core in the house
  settle(st) { this.houseOwed += st.bid; return st.bid; }
  // sale proceeds into the pots: saleToBuybackBps to the buyback, the rest to the pot (checkpoint first, resync after)
  bookSale(amount, now) {
    const toBuyback = (amount * this.s.saleToBuybackBps) / BPS;
    this.ethToBuyback += toBuyback;
    this.checkpoint(now);
    this.ethPot += amount - toBuyback;
    this.syncFunded();
    return { toBuyback, toPot: amount - toBuyback };
  }
  // collectSales: pulls what the house owes and books it
  collectSales(now) {
    const owed = this.houseOwed;
    if (owed <= 0) return null;
    this.houseOwed = 0;
    return Object.assign({ owed }, this.bookSale(owed, now));
  }
  // sellTo (buy only mode, called by the controller): a held, listed statement with no bid is paid for at once. the payment is at least the hard
  // floor, it is booked like sale proceeds right away, nothing waits in the house. returns the booking or null when the Core would revert
  sellTo(st, value, now) {
    if (st.lane !== 'eth' || st.bid || st.sold) return null;
    if (value < this.floorPrice(st) * (1 - 1e-12)) return null;
    st.sold = true; st.soldAt = now;
    return this.bookSale(value, now);
  }

  // ---- phase 2: exitModule pays rating * unitPerPoint of exitToken. pots here hold the eth value of exitToken at xp per point
  setExitModule(now, xp) {
    const p = this.p, s = this.s;
    this.moduleSet = true; this.xp = xp; this.xCheckpointTime = now;
    this.xStartPrice = p.SUPPLY / (s.exitSliceCredits * (s.avgScore / 1e4) * xp); // coin per eth of exitToken, asks the whole supply for a full slice
    this.xStartTime = now;
  }
  xRate(now) {
    const s = this.s;
    const r = this.xRateAtCheckpoint;
    if (!this.xFunded) return r;
    const cap = Math.min(s.xRateCap, (this.xPot * BPS) / ((s.avgScore / 1e4) * this.xp));
    if (cap <= r) return r;
    return Math.min(r + (s.xRateClimbPerHour * (now - this.xCheckpointTime)) / 3600, cap);
  }
  xCheckpoint(now) { this.xRateAtCheckpoint = this.xRate(now); this.xCheckpointTime = now; }
  syncXFunded() {
    const s = this.s;
    this.xFunded = this.xPot * BPS >= (s.avgScore / 1e4) * this.xRateAtCheckpoint * this.xp;
  }
  // price in exitToken value for one credit at the current exit bid (without moving state)
  xPrice(pts, now) { return (pts * this.xRate(now)) / BPS * this.xp; }
  // sellForExitToken: pays pts * xRate of the credit's score in exitToken, drops xRate per credit. the exit bid stays per point
  xBuy(pts, now) {
    const s = this.s;
    this.xCheckpoint(now);
    const r = this.xRateAtCheckpoint;
    const price = (pts * r * this.xp) / BPS;
    if (!(price > 0) || price > this.xPot + 1e-18) return 0;
    this.xPot -= price;
    this.xRateAtCheckpoint = Math.max(Math.max(r - s.xRateDropPerCredit, 0), s.xRateFloor);
    this.syncXFunded();
    return price;
  }
  // exitStatement: a module is set, and an eth lane statement is listed with no bid for exitAfter. the exit lane exits at once
  exitReady(st, now) {
    return this.moduleSet && (st.lane === 'exit' || (!st.bid && now >= st.t0 + this.s.exitAfter));
  }
  // the module hands back rating * unitPerPoint. eth lane splits exitToBuybackBps, exit lane splits exitLaneToBuybackBps (launch 0: keeps all)
  exitStatement(st, rating, now) {
    const s = this.s;
    const received = rating * this.xp;
    const toBuyback = (received * (st.lane === 'eth' ? s.exitToBuybackBps : s.exitLaneToBuybackBps)) / BPS;
    this.xCheckpoint(now);
    if (toBuyback > 0) {
      this.xStartPrice = Math.max(this.xAuctionPrice(now), this.xStartPrice / 4, 1e-12);
      this.xStartTime = now;
    }
    this.xToBuyback += toBuyback;
    this.xPot += received - toBuyback;
    this.syncXFunded();
    return { received, toBuyback, toPot: received - toBuyback };
  }
  // dutch auction: coin per eth of exitToken, halves every xAuctionHalfLife, the clock runs only while the pot is not empty
  xAuctionPrice(now) {
    if (this.xToBuyback === 0) return this.xStartPrice;
    const el = now - this.xStartTime;
    if (el / this.s.xAuctionHalfLife >= 256) return 0;
    return this.xStartPrice * Math.pow(0.5, el / this.s.xAuctionHalfLife);
  }
  xSlice() { return Math.min(this.xToBuyback, this.s.exitSliceCredits * (this.s.avgScore / 1e4) * this.xp); }
  // buybackExit: a taker burns coinIn coin and takes the slice. restart at max(2 * clearing, start / 4)
  xFill(now) {
    const slice = this.xSlice();
    const price = this.xAuctionPrice(now);
    const coinIn = slice * price;
    this.xToBuyback -= slice;
    this.xStartPrice = Math.max(2 * price, this.xStartPrice / 4, 1e-12);
    this.xStartTime = now;
    return { slice, price, coinIn };
  }
  // buyback(): one slice at most per buybackDelay blocks, tip on the slice
  takeBuybackSlice(now) {
    const s = this.s;
    const pool = this.ethToBuyback;
    if (pool <= 1e-15 || now < this.lastBuybackTime + s.buybackDelay * 12) return null;
    const slice = Math.min(pool, s.buybackSlice);
    this.ethToBuyback = pool - slice;
    this.lastBuybackTime = now;
    const tip = (slice * s.keeperTipBps) / BPS;
    return { slice, tip, budget: slice - tip };
  }
}


// ---------------------------------------------------------------- the launch position
// one concentrated liquidity position, whole supply single sided in coin from the start tick up to the max tick.
// price is eth per coin, token0 is the coin. real v4 math: x = L (1/sqrtP - 1/sqrtPb), y = L (sqrtP - sqrtPa)
export class Pool {
  constructor(p) {
    this.sqrtPa = Math.pow(1.0001, p.startTick / 2);
    this.sqrtPb = Math.pow(1.0001, p.positionUpper / 2);
    this.L = p.SUPPLY / (1 / this.sqrtPa - 1 / this.sqrtPb);
    this.sqrtP = this.sqrtPa;
  }
  get price() { return this.sqrtP * this.sqrtP; }
  coinInPool() { return this.L * (1 / this.sqrtP - 1 / this.sqrtPb); }
  ethInPool() { return this.L * (this.sqrtP - this.sqrtPa); }
  // buyers add eth to the pool, coin leaves. returns coin out
  buy(ethIn) {
    if (ethIn <= 0) return 0;
    const s1 = this.sqrtP + ethIn / this.L;
    const out = this.L * (1 / this.sqrtP - 1 / s1);
    this.sqrtP = s1;
    return out;
  }
  // sellers remove up to ethOut from the pool, coin enters. returns {eth, coin} actually moved
  sell(ethOut) {
    const maxOut = this.ethInPool();
    const eth = Math.min(ethOut, maxOut);
    if (eth <= 0) return { eth: 0, coin: 0 };
    const s1 = this.sqrtP - eth / this.L;
    const coin = this.L * (1 / s1 - 1 / this.sqrtP);
    this.sqrtP = s1;
    return { eth, coin };
  }
  // eth into the pool needed to take coinOut coin out, without moving state
  ethForCoin(coinOut) {
    const inv = 1 / this.sqrtP - coinOut / this.L;
    if (inv <= 1 / this.sqrtPb) return Infinity;
    return this.L * (1 / inv - this.sqrtP);
  }
}

// ---------------------------------------------------------------- market models
const comparableDay = (d) => Math.max(COMPARABLE.a * Math.exp(-COMPARABLE.k * d), COMPARABLE.floor);

// swap volume in eth for utc day d of the coin (before volScale)
export function dayVolume(p, d) {
  if (d === 0) return p.volDay0;
  switch (p.volPreset) {
    case 'sustained17': return 17;
    case 'sustained50': return 50;
    case 'deadWeek1': return d < 7 ? comparableDay(d) : 0.2;
    case 'custom': return p.volTail + (80.6 - p.volTail) * Math.pow(0.5, (d - 1) / p.volHalfLifeDays);
    default: return comparableDay(d);
  }
}
// flat median market price of a credit, eth, along the configured path (before the engine's own lift)
export function pathPrice(p, tSec) {
  const d = tSec / 86400;
  const e = Math.exp(-d / p.priceTauDays);
  if (p.pricePath === 'decline') {
    const end = p.priceEndMult == null ? 0.4 : p.priceEndMult;
    return p.priceP0 * (end + (1 - end) * e);
  }
  if (p.pricePath === 'recovery') {
    const end = p.priceEndMult == null ? 2.2 : p.priceEndMult;
    return p.priceP0 * (1 + (end - 1) * (1 - e));
  }
  return p.priceP0;
}
// anti sniper skim as a fraction of notional at time t seconds after launch
export function skimFraction(p, t) {
  const base = p.baselineSkimBps / 1e5;
  if (t >= p.sniperSeconds) return base;
  const f = (p.sniperStartBps - ((p.sniperStartBps - p.sniperEndBps) * t) / p.sniperSeconds) / 1e5;
  return Math.max(base, f);
}
// share of a swap's notional the fee router receives: 90 percent of the baseline skim plus all of the anti sniper extra
export function routerFeeFraction(p, f) {
  const base = p.baselineSkimBps / 1e5;
  return base * (p.bountyBps / BPS) + Math.max(0, f - base);
}
// share of a swap's notional that lands in the engine's pot at t seconds after launch: the router's inflow less the flush tip,
// and after the split start less the payee's parts per million of the rest. 5.18 points at the baseline once the split is on
export function engineFeeFraction(p, f, t) {
  const left = routerFeeFraction(p, f) * (1 - p.routerTipPpm / 1e6);
  return t >= p.routerSplitStartSec ? left * (1 - p.routerPayeePpm / 1e6) : left;
}
// volume in a step [t, t+dt). the first hour runs in 120 s sub steps, 15 of them inside the anti sniper window
export function stepVolume(p, t, dt) {
  const d = Math.floor(t / 86400);
  const dv = dayVolume(p, d) * p.volScale;
  if (d > 0) return (dv * dt) / 86400;
  const h = Math.floor(t / 3600);
  const h1 = dv * p.h1Share;
  if (h === 0) {
    const k = Math.floor(t / 120);
    const nS = Math.round(p.sniperSeconds / 120);
    if (k < nS) {
      let wsum = 0;
      for (let i = 0; i < nS; i++) wsum += 1 - skimFraction(p, i * 120 + 60);
      return (h1 * p.sniperVolShare * (1 - skimFraction(p, k * 120 + 60))) / wsum;
    }
    return (h1 * (1 - p.sniperVolShare)) / (30 - nS);
  }
  let wsum = 0;
  for (let i = 1; i < 24; i++) wsum += Math.exp(-(i - 1) / 5);
  return (((dv * (1 - p.h1Share)) * Math.exp(-(h - 1) / 5)) / wsum) * (dt / 3600);
}
export function stmtArrivalsPerDay(p, tSec) {
  return Math.max(p.stmtFloorPerDay, p.stmtPerDay * Math.pow(0.5, tSec / (p.stmtDecayDays * 86400)));
}
function mergeDesc(a, b) {
  const out = new Array(a.length + b.length);
  let i = 0, j = 0, k = 0;
  while (i < a.length && j < b.length) out[k++] = a[i].key >= b[j].key ? a[i++] : b[j++];
  while (i < a.length) out[k++] = a[i++];
  while (j < b.length) out[k++] = b[j++];
  return out;
}

// ---------------------------------------------------------------- the simulation
// ---------------------------------------------------------------- the simulation
export function simulate(userParams = {}) {
  const p = Object.assign({}, DEFAULTS, userParams);
  const rng = mulberry32(p.seed);
  const core = new Core(p, 0);
  const pool = new Pool(p);
  const H = Math.round(p.days * 24);
  const bLate = p.buyShareLate != null ? p.buyShareLate : (p.volPreset === 'sustained17' || p.volPreset === 'sustained50') ? 0.5 : p.volPreset === 'custom' ? 0.49 : 0.46;
  const phase2At = p.phase2Day == null ? Infinity : p.phase2Day * 86400;
  const sched = (p.schedule || []).map((e) => ({ at: e.day * 86400, patch: e.patch, done: false })).sort((a, b) => a.at - b.at);

  // state
  let book = []; // resting market offers, ordered by descending key (wei per point needed to clear, in units of the market price), smallest last
  let strat = []; // CreditStrategy listings, ordered by descending need (wei per point to clear)
  let holdPool = p.holders;
  const ethPile = [], xPile = [];
  let unbid = []; // eth lane statements listed on the house with no bid
  let live = []; // statements with a bid and a running timer
  let lnM = 0, nextSid = 1;
  const T = { // totals
    fees: 0, feesBuyback: 0, feesTaker: 0, saleGross: 0, saleToPot: 0, saleToBuyback: 0, spent: 0, tips: 0, reimb: 0,
    bought: 0, boughtX: 0, pts: 0, cost: 0, mkt: 0, ask: 0, sumM: 0, composed: 0, composedX: 0, sold: 0, exited: 0, exitedX: 0,
    soldPrice: 0, soldCost: 0, soldPts: 0, soldFloor: 0, soldAge: 0, soldAtFloor: 0, soldInstant: 0, bidsOnSold: 0, contested: 0, rebids: 0, extended: 0, buybackSpent: 0, buybackTips: 0, burned: 0, burnedX: 0,
    listBought: 0, stratBought: 0, xFills: 0, xCoin: 0, xValue: 0, xGross: 0, xDiscSum: 0, xRecv: 0, xSpent: 0, firstFill: -1,
    capStepHits: 0, clampSteps: 0, capBindSteps: 0, capBindRich: 0, potBindSteps: 0, vol: 0, stCost: 0, stRating: 0, stmtArrivals: 0, stmtMiss: 0,
    first80cost: 0, first80mkt: 0, first80pts: 0, first80n: 0, first80t: -1, exitedValue: 0, exitedCost: 0, exitedAge: 0, settingsChanges: 0,
  };
  const histPts = new Array(10).fill(0), histCost = new Array(10).fill(0);
  const xFillLog = [];
  const S = {}; // series, one entry per hour
  const names = ['pot', 'toBuyback', 'cumFees', 'rate', 'mktPerPoint', 'bidRatio', 'bought', 'credits', 'creditsDay', 'avgScoreCum', 'avgScoreDay',
    'costPerCredit', 'mktPerCredit', 'composed', 'sold', 'waiting', 'inAuction', 'pending', 'locked', 'exited', 'buybackSpent', 'burnEth', 'burned', 'burnedPct',
    'coinPrice', 'xPot', 'xToBuyback', 'xRate', 'xFills', 'book', 'saleToPot', 'saleToBuyback', 'feeToBuyback', 'avgSalePct', 'avgSaleAgeH', 'saleGross', 'cumPts', 'cumCost', 'cumMkt', 'xBought', 'xDisc',
    'volume', 'poolEth', 'spent'];
  for (const n of names) S[n] = new Array(H + 1);

  // initial resting book at steady state, and the CreditStrategy inventory. a key is the ask as a multiple of the flat price over the points
  // the engine prices the credit at, so a change of flatBps or avgScore re keys everything
  const newOffer = () => {
    const pts = 80 + 720 * rng();
    const m = Math.exp(p.askSigma * normal(rng));
    const prem = pts >= 790 ? 2.0 : pts >= 740 ? 1.12 : 1.0;
    return { pts, m, prem, key: (m * prem) / core.epts(pts), listed: rng() < p.listedShare };
  };
  const nBook0 = Math.round(p.offersPerHour / Math.max(p.bookChurn, 1e-3));
  for (let i = 0; i < nBook0; i++) book.push(newOffer());
  book.sort((a, b) => b.key - a.key);
  if (p.strategyOn) {
    for (const [price, count] of STRAT_LISTINGS) {
      for (let i = 0; i < count; i++) {
        const pts = interp(STRAT_SCORE_Q, rng());
        strat.push({ pts, price, need: (price * W) / core.epts(pts) });
      }
    }
    strat.sort((a, b) => b.need - a.need);
  }
  const rekey = () => {
    for (const it of book) it.key = (it.m * it.prem) / core.epts(it.pts);
    for (const it of strat) it.need = (it.price * W) / core.epts(it.pts);
    book.sort((a, b) => b.key - a.key); strat.sort((a, b) => b.need - a.need);
  };

  const peff = (t) => pathPrice(p, t) * Math.exp(lnM);
  let stepW = 1, peffNow = 0; // weight of the current step in hours, market price in the step
  let prevRate = p.rateStart, signChanges = 0, lastDir = 0, rateMaxRatio = 0, rateAbsMove = 0, rateMoves = 0;

  // ---- the engine buys: market offers through the bid or a listing, CreditStrategy listings, exitToken bid in phase 2.
  // nothing here looks at unsold statements: the engine never stops buying because statements are unsold.
  // a seller whose credit does not fit the hourly cap or the pot waits, and another credit that fits sells instead
  function pickFrom(arr, isStrat, r, xPerPt, Pw, Pe, afford, xAfford) {
    const lim = Math.max(0, arr.length - 400);
    // the exitToken bid pays by the credit's own score, so with a flat eth bid its need is up to ep/pts (5.4 at most) times the eth need
    const top = Math.max(r, xPerPt * 6);
    for (let i = arr.length - 1; i >= lim; i--) {
      const it = arr[i];
      const need = isStrat ? it.need : it.key * Pw;
      if (need > top) return null;
      const ep = core.epts(it.pts);
      const listing = isStrat || it.listed;
      const ask = isStrat ? it.price : it.m * it.prem * Pe;
      const ethOk = need <= r, xOk = !isStrat && (ask * W) / it.pts <= xPerPt;
      const ethFits = ethOk && (listing ? ask * (1 + core.s.tipCapBps / BPS) <= afford : (ep * r) / W <= afford);
      const xFits = xOk && (it.pts * xPerPt) / W <= xAfford;
      if (ethFits || xFits) return { i, need, ethFits, xFits, isStrat, it, ask, listing };
    }
    return null;
  }
  // a sale that clears the bid but is blocked. cap bound: it would fit the pot but not the hourly cap room. pot bound: it exceeds the pot
  function noteBind(r, xPerPt, Pw, roomLeft) {
    let minPrice = Infinity;
    for (const [arr, isS] of [[book, false], [strat, true]]) {
      for (let i = arr.length - 1, n = 0; i >= 0 && n < 100; i--, n++) {
        const it = arr[i], need = isS ? it.need : it.key * Pw;
        if (need > Math.max(r, isS ? 0 : xPerPt) || (isS && need > r)) break;
        const ep = core.epts(it.pts);
        minPrice = Math.min(minPrice, isS || it.listed ? (isS ? it.price : it.key * ep * peffNow) : (ep * r) / W);
      }
    }
    if (!isFinite(minPrice)) return;
    if (minPrice <= core.ethPot && minPrice > roomLeft) { T.capBindSteps += stepW; if (core.ethPot > 5) T.capBindRich += stepW; }
    else T.potBindSteps += stepW;
  }
  function engineBuys(now, Pe) {
    let spentEth = 0;
    const Pw = Pe * W;
    for (let guard = 0; guard < 200000; guard++) {
      const r = core.ethRate(now);
      const p2 = core.moduleSet;
      const xPerPt = p2 ? (core.xRate(now) / BPS) * core.xp * W : 0;
      const rm = core.room(0, now);
      const roomLeft = (rm.wp * core.s.spendCapBps) / BPS - rm.wsp;
      const afford = Math.min(core.ethPot, roomLeft);
      const xAfford = p2 ? core.xPot : 0;
      if (afford <= 1e-15 && xAfford <= 0) { noteBind(r, xPerPt, Pw, roomLeft); break; }
      const a = pickFrom(book, false, r, xPerPt, Pw, Pe, afford, xAfford);
      const b = strat.length ? pickFrom(strat, true, r, 0, Pw, Pe, afford, 0) : null;
      const c = a && b ? (b.need < a.need ? b : a) : a || b;
      if (!c) { noteBind(r, xPerPt, Pw, roomLeft); break; }
      const it = c.it, useS = c.isStrat, ep = core.epts(it.pts);
      let door = c.ethFits && c.xFits ? (r >= xPerPt ? 'eth' : 'x') : c.ethFits ? 'eth' : 'x';
      let cost = 0, tip = 0, viaListing = false, ok = false;
      if (door === 'x') {
        // the exitToken bid pays by the credit's own score (phase 2 pays by rating)
        cost = core.xBuy(it.pts, now);
        ok = cost > 0;
        if (!ok && c.ethFits) door = 'eth';
      }
      if (door === 'eth') {
        if (c.listing) {
          const res = core.buyListing(it.pts, c.ask, now);
          if (res) { cost = res.cost; tip = res.tip; ok = true; viaListing = true; }
        } else {
          cost = core.sellForEth(it.pts, now);
          ok = cost > 0;
        }
      }
      if (!ok) break;
      if (useS) strat.splice(c.i, 1); else book.splice(c.i, 1);
      holdPool -= 1;
      if (door === 'x') {
        T.boughtX++; T.xSpent += cost; xPile.push({ pts: it.pts });
      } else {
        T.bought++; T.pts += it.pts; T.cost += cost + tip; T.mkt += Pe; T.ask += c.ask; T.spent += cost + tip; T.tips += tip;
        spentEth += cost + tip;
        if (viaListing) T.listBought++;
        if (useS) T.stratBought++;
        else T.sumM += it.m;
        const bin = Math.min(9, Math.floor((it.pts - 80) / 72));
        histPts[bin]++; histCost[bin] += cost + tip;
        ethPile.push({ pts: it.pts, cost: cost + tip });
        if (T.firstFill < 0) T.firstFill = now / 3600;
        if (T.first80n < 80) {
          T.first80n++; T.first80cost += cost + tip; T.first80mkt += Pe; T.first80pts += it.pts;
          if (T.first80n === 80) T.first80t = now / 3600;
        }
      }
    }
    return spentEth;
  }

  // ---- compose when a lane pile holds 80. the oldest first. an eth lane statement is listed at age zero, at the start price
  function composeAll(now) {
    while (ethPile.length >= p.PAGE) {
      const page = ethPile.splice(0, p.PAGE);
      let cost = 0, rating = 0;
      for (const c of page) { cost += c.cost; rating += c.pts; }
      const st = core.compose(cost, 'eth', now, p.gasGwei);
      st.rating = rating; st.id = nextSid++;
      T.reimb += st.reimb; T.composed++; T.stCost += st.cost; T.stRating += rating;
      unbid.push(st);
    }
    while (xPile.length >= p.PAGE && core.moduleSet) {
      const page = xPile.splice(0, p.PAGE);
      let rating = 0;
      for (const c of page) rating += c.pts;
      const st = core.compose(0, 'exit', now, p.gasGwei);
      T.reimb += st.reimb; T.composedX++;
      const res = core.exitStatement(st, rating, now);
      T.exitedX++; T.xRecv += res.received;
    }
  }

  // ---- auctions that ran out are ended: the winner gets the statement and the house credits the proceeds to the Core
  function settleEnded(upTo) {
    if (!live.length) return;
    const keep = [];
    for (const st of live) {
      if (st.end > upTo) { keep.push(st); continue; }
      core.settle(st);
      T.saleGross += st.bid; T.bidsOnSold += st.bids; if (st.bids > 1) T.contested++;
      noteSale(st, st.bid, st.openedAt);
    }
    live = keep;
  }
  // a statement sold at `price` to a buyer who came at `at`: totals for the sale price over cost, the age at the sale and the share at the lowest price
  function noteSale(st, price, at) {
    T.sold++; T.soldPrice += price; T.soldCost += st.cost; T.soldPts += st.rating; T.soldFloor += core.floorPrice(st);
    T.soldAge += at - st.t0;
    if (price <= core.lowestPrice(st) * (1 + 1e-9)) T.soldAtFloor++;
  }
  // ---- statement buyers. a buyer arrives with a willingness to pay that is a multiple of the MARKET cost of 80 credits (80 times the flat market
  // price Pe), while the asking price is a share of what the ENGINE PAID for the statement's parts (the statement cost). the buyer takes
  // the statement with the lowest asking price at or under its willingness to pay (stmtPick random: any one that fits) and does not wait for a
  // lower price (buyerWaits 'floor' is the pessimistic case: it only buys a statement whose asking price has reached its lowest level).
  // auction mode: it opens the english auction at the asking price, later buyers must have a higher willingness to pay and beat the top bid by 5 percent.
  // buy only mode: it pays the asking price and gets the statement at once through sellTo
  function statementBuyers(t0, t1, Pe) {
    const n = poisson(rng, (stmtArrivalsPerDay(p, t1) * (t1 - t0)) / 86400);
    if (!n) return;
    const times = [];
    for (let i = 0; i < n; i++) times.push(t0 + rng() * (t1 - t0));
    times.sort((a, b) => a - b);
    const waits = p.buyerWaits === 'floor';
    for (const ta of times) {
      settleEnded(ta);
      T.stmtArrivals++;
      const wtp = interp(WTP_Q, rng()) * p.wtpMult * p.PAGE * Pe;
      const opts = [];
      for (const st of unbid) {
        const mb = core.askingPrice(st, ta);
        if (mb > wtp * (1 + 1e-12)) continue;
        if (waits && mb > core.lowestPrice(st) * (1 + 1e-9)) continue;
        opts.push({ st, mb, fresh: true });
      }
      if (!waits) for (const st of live) { const mb = core.minBid(st, ta); if (ta < st.end && mb <= wtp && wtp > st.bidderWtp) opts.push({ st, mb, fresh: false }); }
      if (!opts.length) { T.stmtMiss++; continue; }
      let pick = opts[0];
      if (p.stmtPick === 'random') pick = opts[Math.floor(rng() * opts.length)];
      else for (const o of opts) if (o.mb < pick.mb) pick = o;
      if (core.c.buyOnly) {
        const res = core.sellTo(pick.st, pick.mb, ta);
        if (!res) { T.stmtMiss++; continue; }
        unbid.splice(unbid.indexOf(pick.st), 1);
        T.saleGross += pick.mb; T.saleToPot += res.toPot; T.saleToBuyback += res.toBuyback; T.bidsOnSold++; T.soldInstant++;
        noteSale(pick.st, pick.mb, ta);
        continue;
      }
      const wasEnd = pick.st.end;
      if (!core.bidOn(pick.st, pick.mb, ta, wtp)) { T.stmtMiss++; continue; }
      if (pick.fresh) { unbid.splice(unbid.indexOf(pick.st), 1); live.push(pick.st); } else T.rebids++;
      if (pick.st.end > wasEnd && !pick.fresh) T.extended++;
    }
  }

  // ---- phase 2: a keeper exits listings that have had no bid for exitAfter through the exitModule
  function exits(now) {
    if (!core.moduleSet || !unbid.length) return;
    const keep = [];
    for (const st of unbid) {
      if (core.exitReady(st, now) && st.rating * core.xp >= p.exitMinRatio * core.askingPrice(st, now)) {
        const res = core.exitStatement(st, st.rating, now);
        T.exited++; T.xRecv += res.received; T.exitedValue += res.received; T.exitedCost += st.cost; T.exitedAge += now - st.t0;
      } else keep.push(st);
    }
    unbid = keep;
  }
  // collectSales by a keeper: the proceeds move from the house into the pots only here
  function collect(now) {
    const res = core.collectSales(now);
    if (res) { T.saleToPot += res.toPot; T.saleToBuyback += res.toBuyback; }
  }

  // ---- phase 2 dutch auction: takers fill when the all in discount to the pool price reaches the threshold
  function xAuction(stepStart, now) {
    for (let guard = 0; core.moduleSet && core.xToBuyback > 1e-12 && guard < 500; guard++) {
      const f = skimFraction(p, now), spot = pool.price, g = spot * (1 + f);
      const tStar = core.xStartTime + core.s.xAuctionHalfLife * Math.log2((core.xStartPrice * g) / (1 - p.takerThreshold));
      if (!(tStar <= now)) break;
      const tf = Math.max(tStar, stepStart, core.xStartTime);
      const slice = core.xSlice(), coinIn = slice * core.xAuctionPrice(tf);
      const poolEth = pool.ethForCoin(coinIn);
      if (!isFinite(poolEth)) break;
      core.xFill(tf);
      const gross = poolEth * (1 + f);
      pool.buy(poolEth);
      const fee = poolEth * engineFeeFraction(p, f, now);
      core.addFees(fee, now);
      T.feesTaker += fee; T.burnedX += coinIn; T.xFills++; T.xCoin += coinIn; T.xValue += slice; T.xGross += gross;
      T.xDiscSum += 1 - gross / slice;
      xFillLog.push([tf / 3600, slice, coinIn, gross, 1 - gross / slice, 1 - (coinIn * spot) / slice]);
    }
  }

  // ---- eth buyback keeper: one slice per buybackDelay blocks, coin bought in the pool and burned
  function buybacks(stepStart, now) {
    if (!p.keeperBuyback) return;
    const delay = core.s.buybackDelay * 12;
    let tb = Math.max(stepStart, core.lastBuybackTime + delay), feeBack = 0;
    while (tb <= now && core.ethToBuyback > 1e-15) {
      const info = core.takeBuybackSlice(tb);
      if (!info) break;
      const f = skimFraction(p, tb);
      const notional = info.budget / (1 + f);
      T.burned += pool.buy(notional);
      T.buybackSpent += info.budget; T.buybackTips += info.tip;
      feeBack += notional * engineFeeFraction(p, f, tb);
      tb += delay;
    }
    if (feeBack > 0) { core.addFees(feeBack, now); T.feesBuyback += feeBack; }
  }

  // ---- series snapshot at the end of hour index h
  function record(h, t) {
    const Pe = peff(t), r = core.ethRate(t);
    let locked = 0;
    for (const s of unbid) locked += s.cost;
    for (const s of live) locked += s.cost;
    S.pot[h] = core.ethPot; S.toBuyback[h] = core.ethToBuyback;
    S.cumFees[h] = T.fees + T.feesBuyback + T.feesTaker;
    S.rate[h] = r; S.mktPerPoint[h] = (Pe * W) / 440;
    S.bidRatio[h] = (core.epts(440) * r) / (Pe * W);
    S.bought[h] = T.bought; S.cumPts[h] = T.pts; S.cumCost[h] = T.cost; S.cumMkt[h] = T.mkt;
    S.credits[h] = T.bought + T.boughtX;
    S.creditsDay[h] = S.credits[h] - S.credits[Math.max(0, h - 24)];
    S.avgScoreCum[h] = T.bought ? T.pts / T.bought : 0;
    const h24 = Math.max(0, h - 24);
    const dB = T.bought - S.bought[h24], dP = T.pts - S.cumPts[h24];
    S.avgScoreDay[h] = dB > 0 ? dP / dB : (h > 0 ? S.avgScoreDay[h - 1] : 0);
    S.costPerCredit[h] = T.bought ? T.cost / T.bought : 0; S.mktPerCredit[h] = Pe;
    S.composed[h] = T.composed + T.composedX; S.sold[h] = T.sold; S.waiting[h] = unbid.length; S.inAuction[h] = live.length;
    S.pending[h] = core.houseOwed; S.locked[h] = locked;
    S.exited[h] = T.exited + T.exitedX; S.buybackSpent[h] = T.buybackSpent; S.burnEth[h] = T.buybackSpent + T.buybackTips;
    S.burned[h] = T.burned + T.burnedX; S.burnedPct[h] = ((T.burned + T.burnedX) / p.SUPPLY) * 100;
    S.coinPrice[h] = pool.price; S.xPot[h] = core.xPot; S.xToBuyback[h] = core.xToBuyback;
    S.xRate[h] = core.moduleSet ? core.xRate(t) : 0; S.xFills[h] = T.xFills; S.book[h] = book.length;
    S.saleToPot[h] = T.saleToPot; S.saleToBuyback[h] = T.saleToBuyback; S.feeToBuyback[h] = core.feeToBuyback; S.saleGross[h] = T.saleGross;
    S.avgSalePct[h] = T.soldCost ? (T.soldPrice / T.soldCost) * 100 : NaN; S.avgSaleAgeH[h] = T.sold ? T.soldAge / T.sold / 3600 : NaN; S.xBought[h] = T.boughtX;
    S.volume[h] = T.vol; S.xDisc[h] = T.xFills ? T.xDiscSum / T.xFills : 0; S.poolEth[h] = pool.ethInPool();
    S.spent[h] = T.spent;
  }

  // ---- the owner changes settings on a day (schedule), at the start of the step that reaches it
  function applySchedule(t0) {
    for (const e of sched) {
      if (e.done || e.at > t0) continue;
      e.done = true; T.settingsChanges++;
      core.setSettings(e.patch, t0);
      if ('flatBps' in e.patch || 'avgScore' in e.patch) rekey();
    }
  }

  // ---- the main loop. hour 0 runs in 120 s sub steps for the anti sniper window, then hourly
  const steps = [];
  for (let k = 0; k < 30; k++) steps.push([k * 120, (k + 1) * 120]);
  for (let h = 1; h < H; h++) steps.push([h * 3600, (h + 1) * 3600]);
  record(0, 0);
  const collectEvery = Math.max(1, Math.round(p.keeperCollectHours)) * 3600;
  for (const [t0, t1] of steps) {
    const dt = t1 - t0, mid = (t0 + t1) / 2;
    stepW = dt / 3600;
    applySchedule(t0);
    // coin market: volume, fees to the pot, price impact on the single position
    const V = stepVolume(p, t0, dt), f = skimFraction(p, mid), b = t0 < 86400 ? p.buyShare0 : bLate;
    const net = b * V - (1 - b) * V; // notional is the pool's own delta, the skim comes on top
    if (net > 0) pool.buy(net); else if (net < 0) pool.sell(-net);
    const fee = V * engineFeeFraction(p, f, mid);
    core.addFees(fee, mid);
    T.fees += fee; T.vol += V;
    if (!core.moduleSet && t1 >= phase2At) core.setExitModule(t1, p.xp);
    // credit market: the engine's own buying lifts the flat price, the lift decays
    lnM *= Math.pow(0.5, dt / (p.impactHalfLifeHours * 3600));
    const Pe = peff(t1), r0 = core.ethRate(t1);
    const xPay = core.moduleSet ? (core.xRate(t1) / BPS) * core.xp * W : 0;
    const boost = Math.pow(Math.max(1, Math.max(core.epts(440) * r0, xPay * 440) / (Pe * W)), p.supplyElast);
    const nOff = Math.min(poisson(rng, (p.offersPerHour * dt * boost) / 3600), 1500, Math.floor(Math.max(holdPool, 0) * 0.05));
    if (p.bookChurn > 0) {
      const keepP = Math.pow(1 - p.bookChurn, dt / 3600);
      book = book.filter(() => rng() < keepP);
    }
    if (nOff > 0) {
      const add = [];
      for (let i = 0; i < nOff; i++) add.push(newOffer());
      add.sort((x, y) => y.key - x.key);
      book = mergeDesc(book, add);
      if (book.length > 6000) book = book.slice(book.length - 6000); // keep the cheapest to clear
    }
    // the engine acts. there is no inventory gate: unsold statements never close the bid
    const capBefore = core.capHits;
    peffNow = Pe;
    const spentEth = engineBuys(t1, Pe);
    if (core.capHits > capBefore) T.capStepHits++;
    if (core.funded && core.clamp() < Infinity && core.ethRate(t1) >= core.clamp() * (1 - 1e-9)) T.clampSteps++;
    lnM = Math.min(lnM + (p.impactElast * spentEth) / p.marketDailyEth, Math.log(p.impactCap));
    // statements already listed meet buyers during the step, then the engine composes and lists new ones
    statementBuyers(t0, t1, peff(t1));
    settleEnded(t1);
    composeAll(t1);
    exits(t1);
    if (t1 % collectEvery === 0) collect(t1);
    xAuction(t0, t1);
    buybacks(t0, t1);
    // rate path statistics
    const rr = core.ethRate(t1);
    if (T.firstFill >= 0 && dt === 3600) {
      const lc = Math.log(rr / prevRate);
      rateAbsMove += Math.abs(lc); rateMoves++;
      const dir = Math.abs(lc) < 0.002 ? 0 : lc > 0 ? 1 : -1;
      if (dir !== 0) { if (lastDir !== 0 && dir !== lastDir) signChanges++; lastDir = dir; }
    }
    prevRate = rr;
    rateMaxRatio = Math.max(rateMaxRatio, (core.epts(440) * rr) / (peff(t1) * W));
    if (t1 % 3600 === 0) record(t1 / 3600, t1);
  }

  // ---- results
  const at = (d) => {
    const i = Math.min(H, Math.round(d * 24));
    const o = { day: d };
    for (const n of names) o[n] = S[n][i];
    return o;
  };
  const med = (a) => { if (!a.length) return 0; const s = a.slice().sort((x, y) => x - y); return s[s.length >> 1]; };
  const intervals = [];
  for (let i = 1; i < xFillLog.length; i++) intervals.push(xFillLog[i][0] - xFillLog[i - 1][0]);
  const avgPtsBought = T.bought ? T.pts / T.bought : 0;
  const stats = {
    firstFillHour: T.firstFill,
    first80: T.first80n === 80 ? { hours: T.first80t, cost: T.first80cost, market: T.first80mkt, ratio: T.first80cost / T.first80mkt, avgScore: T.first80pts / 80 } : null,
    avgScoreBought: avgPtsBought,
    costVsMarket: T.mkt ? T.cost / T.mkt : 0, // eth paid per credit over the flat market price at the time
    costPerPointVsMarket: T.bought ? (T.cost / T.pts) / (T.mkt / T.bought / 440) : 0,
    costVsAsk: T.ask ? T.cost / T.ask : 0,
    capSteps: T.capBindSteps, capStepsRich: T.capBindRich, potBlockedSteps: T.potBindSteps, clampSteps: T.clampSteps,
    rateMaxBidRatio: rateMaxRatio, rateSignChanges: signChanges, rateMeanAbsMove: rateMoves ? rateAbsMove / rateMoves : 0,
    saleOverCost: T.soldCost ? T.soldPrice / T.soldCost : 0, saleOverFloor: T.soldFloor ? T.soldPrice / T.soldFloor : 0,
    saleAgeHours: T.sold ? T.soldAge / T.sold / 3600 : 0, saleAtFloorShare: T.sold ? T.soldAtFloor / T.sold : 0,
    bidsPerSale: T.sold ? T.bidsOnSold / T.sold : 0, contestedShare: T.sold ? T.contested / T.sold : 0,
    stmtArrivals: T.stmtArrivals, stmtMiss: T.stmtMiss,
    xFills: T.xFills, xMedianIntervalH: med(intervals), xMeanDiscount: T.xFills ? T.xDiscSum / T.xFills : 0,
    potCheck: T.fees + T.feesBuyback + T.feesTaker - core.feeToBuyback + T.saleToPot - T.spent - T.reimb - core.ethPot,
    buybackCheck: T.saleToBuyback + core.feeToBuyback - core.ethToBuyback - T.buybackSpent - T.buybackTips,
    houseCheck: T.saleGross - T.saleToPot - T.saleToBuyback - core.houseOwed,
    finalRate: core.ethRate(H * 3600), finalPot: core.ethPot,
  };
  return { params: p, H, S, T, stats, at, histPts, histCost, xFillLog, core, pool, unbid, live };
}

// the owner's metrics for one run: credits acquired, statements created, sold, eth to buy and burn the coin, statements waiting
// for phase 2, the day the launch pot is spent, and the steady state per day after that (the last 30 days of the run, or the
// days since the pot ran out when that is shorter, at least 10)
export function summary(res, day) {
  const S = res.S, T = res.T, H = res.H;
  const h = Math.min(H, Math.round((day == null ? res.H / 24 : day) * 24));
  let peak = 0, peakH = 0;
  for (let i = 0; i <= Math.min(h, 72); i++) if (S.pot[i] > peak) { peak = S.pot[i]; peakH = i; }
  let gone = null;
  for (let i = peakH + 1; i <= H; i++) if (S.pot[i] < 0.05 * peak) { gone = i / 24; break; }
  const a = res.at(h / 24);
  const out = {
    day: h / 24, credits: a.credits, statements: a.composed, sold: a.sold, burnEth: a.burnEth, burnPct: a.burnedPct, waiting: a.waiting, inAuction: a.inAuction,
    exited: a.exited, potGoneDay: gone, pot: a.pot, locked: a.locked, recycled: a.saleGross, avgSalePct: a.avgSalePct, feeToBurn: a.feeToBuyback, saleToBurn: a.saleToBuyback, pending: a.pending, firstBuyDay: res.stats.firstFillHour < 0 ? null : res.stats.firstFillHour / 24,
  };
  if (gone != null && H / 24 - Math.max(gone, H / 24 - 30) >= 10) {
    const fh = Math.round(Math.max(gone, H / 24 - 30) * 24), span = (H - fh) / 24;
    out.steadyFromDay = fh / 24;
    out.steadyCredits = (S.credits[H] - S.credits[fh]) / span;
    out.steadyStatements = (S.composed[H] - S.composed[fh]) / span;
    out.steadySold = (S.sold[H] - S.sold[fh]) / span;
    out.steadyBurnEth = (S.burnEth[H] - S.burnEth[fh]) / span;
  } else { out.steadyCredits = null; out.steadyStatements = null; out.steadySold = null; out.steadyBurnEth = null; }
  return out;
}
