// credits engine economic simulator. plain es module, no dependencies, runs in node 22 and in a browser.
// core rules are ported from src/Core.sol. units: eth for pots and prices, wei per whole point for the rate,
// seconds for time, whole coins for coin amounts. exitModule and exitToken are the only names for phase 2.

export const W = 1e18;
export const BPS = 10000;

// every engine constant, with the Core's names
export const CORE_PARAMS = {
  SUPPLY: 1e9,
  FEE_BPS: 1000,
  CREATOR_BPS: 50,
  AVG_SCORE: 4330000, // 1e4 scale, 433 points
  CLIMB_BASE_BPS_PER_HOUR: 100,
  CLIMB_DOUBLE_EVERY: 24 * 3600,
  CLIMB_MAX_BPS_PER_HOUR: 800,
  DROP_BPS: 1000,
  SPEND_CAP_BPS_PER_HOUR: 2000,
  BONUS_CAP_BPS: 2500,
  TIP_SAVINGS_BPS: 1000,
  TIP_CAP_BPS: 200,
  AUCTION_START_X: 40000,
  AUCTION_FLOOR_X: 12000,
  AUCTION_LENGTH: 72 * 3600,
  SALE_SPLIT: 5000,
  EXIT_SPLIT: 5000,
  BUYBACK_SLICE: 1,
  BUYBACK_DELAY: 25, // blocks, 12 s each
  KEEPER_TIP_BPS: 50,
  XRATE_START: 6000,
  XRATE_CAP: 9700,
  XRATE_FLOOR: 3000,
  XRATE_CLIMB_PER_HOUR: 100,
  XRATE_DROP_PER_CREDIT: 20,
  XAUCTION_HALF_LIFE: 6 * 3600,
  EXIT_SLICE_CREDITS: 20,
  REIMBURSE_BPS: 11000,
  REIMBURSE_CAP_BPS: 500,
  COMPOSE_OVERHEAD_GAS: 50000,
  PAGE: 80,
};

// launch config (script/config/mainnet.json) and simulator inputs
export const SIM_DEFAULTS = {
  seed: 7,
  days: 90,
  rateStart: 4e12,
  inventoryGate: 0, // design change under test: stop buying while this many statements are unsold, 0 is the Core
  bidMode: 'perPoint', // 'perPoint' is the Core, 'flat' is a counterfactual that pays avg score for every credit
  fundedRule: 'new', // 'new' = 20 percent of the pot affords one average credit, 'old' = the pot affords one
  baselineSkimBps: 10000, // of 100000
  bountyBps: 9500, // of the skim, to the engine
  sniperStartBps: 90000,
  sniperEndBps: 10000,
  sniperSeconds: 1800,
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
  // phase 2 (exitModule and exitToken)
  phase2Day: null,
  xp: 2.5e-5, // eth value of the exitToken paid per point of rating
  takerThreshold: 0.15,
  exitMinRatio: 0, // exit only when rating * xp is at least this times the floor price
  keeperBuyback: true,
};

export const DEFAULTS = Object.assign({}, CORE_PARAMS, SIM_DEFAULTS);

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
export class Core {
  constructor(p, t0 = 0) {
    this.p = p;
    this.ethPot = 0; this.ethToBuyback = 0; this.xPot = 0; this.xToBuyback = 0;
    this.rateAtCheckpoint = p.rateStart; this.checkpointTime = t0; this.lastFillTime = t0; this.funded = false;
    this.windowStart = -1e12; this.windowPot = 0; this.windowSpent = 0;
    this.xRateAtCheckpoint = p.XRATE_START; this.xCheckpointTime = t0; this.xFunded = false;
    this.xp = 0; this.moduleSet = false; this.xStartPrice = 0; this.xStartTime = 0;
    this.lastBuybackTime = -1e12;
    this.capHits = 0; this.clampTime = 0; this.gated = false; // gated: a proposed design change, no buying and no climb while unsold inventory is high
  }
  // the climb stops where 20 percent of the pot no longer buys one average credit (new rule); the old rule has no clamp
  clamp() {
    const p = this.p;
    if (p.fundedRule === 'old') return Infinity;
    return (this.ethPot * W * p.SPEND_CAP_BPS_PER_HOUR) / p.AVG_SCORE;
  }
  ethRate(now) {
    const p = this.p;
    let r = this.rateAtCheckpoint;
    if (!this.funded || this.gated) return r;
    const cap = this.clamp();
    if (cap <= r) return r;
    const last = this.lastFillTime;
    let t = this.checkpointTime;
    while (t < now && r < cap) {
      const k = Math.floor((t - last) / p.CLIMB_DOUBLE_EVERY);
      const bps = Math.min(p.CLIMB_BASE_BPS_PER_HOUR * Math.pow(2, Math.min(k, 16)), p.CLIMB_MAX_BPS_PER_HOUR);
      const end = Math.min(now, last + (k + 1) * p.CLIMB_DOUBLE_EVERY);
      r *= Math.pow(1 + bps / BPS, (end - t) / 3600);
      t = end;
    }
    return Math.min(r, cap);
  }
  checkpoint(now) { this.rateAtCheckpoint = this.ethRate(now); this.checkpointTime = now; }
  setGate(g, now) { if (g !== this.gated) { this.checkpoint(now); this.gated = g; } }
  syncFunded() {
    const p = this.p;
    if (p.fundedRule === 'old') this.funded = this.ethPot * W >= (p.AVG_SCORE * this.rateAtCheckpoint) / 1e4;
    else this.funded = this.ethPot * W * p.SPEND_CAP_BPS_PER_HOUR >= p.AVG_SCORE * this.rateAtCheckpoint;
  }
  // fixed window cap. returns the window state it would use, without committing
  room(x, now) {
    const p = this.p;
    let ws = this.windowStart, wp = this.windowPot, wsp = this.windowSpent;
    if (now >= ws + 3600) { ws = now; wp = this.ethPot; wsp = 0; }
    return { ok: wsp + x <= (wp * p.SPEND_CAP_BPS_PER_HOUR) / BPS + 1e-18, ws, wp, wsp };
  }
  // _spend: checkpoint, hourly cap, drop on fill. false means the Core would revert
  spend(x, now) {
    const p = this.p;
    this.checkpoint(now);
    const pot = this.ethPot;
    if (!(x > 0) || x > pot + 1e-18) return false;
    const rm = this.room(x, now);
    if (!rm.ok) { this.capHits++; return false; }
    this.windowStart = rm.ws; this.windowPot = rm.wp; this.windowSpent = rm.wsp + x;
    let r = this.rateAtCheckpoint;
    r -= (r * p.DROP_BPS * Math.min(x, pot)) / (BPS * pot);
    this.rateAtCheckpoint = r;
    this.lastFillTime = now;
    this.ethPot = pot - x;
    this.syncFunded();
    return true;
  }
  addFees(amount, now) { // receive(): checkpoint, add, resync
    this.checkpoint(now);
    this.ethPot += amount;
    this.syncFunded();
  }
  ceiling(pts, rate) { return (pts * rate) / W; }
  // door one: sell into the bid at the ceiling. returns the price paid or 0
  sellForEth(pts, now) {
    const price = this.ceiling(pts, this.ethRate(now));
    return this.spend(price, now) ? price : 0;
  }
  // door two: buy a listing at its ask. returns {cost, tip} or null
  buyListing(pts, ask, now) {
    const p = this.p;
    this.checkpoint(now);
    const ceil = this.ceiling(pts, this.rateAtCheckpoint);
    if (ask > this.ethPot || ask > ceil) return null;
    if (!this.room(ask, now).ok) { this.capHits++; return null; }
    const tip = Math.min((p.TIP_SAVINGS_BPS * (ceil - ask)) / BPS, (p.TIP_CAP_BPS * ask) / BPS);
    if (!this.spend(ask + tip, now)) return null;
    return { cost: ask, tip };
  }
  // compose 80 credits. cost is the sum of their costs. returns the statement
  compose(costSum, lane, now, gasPriceGwei) {
    const p = this.p;
    const gasEth = ((p.composeGas + p.COMPOSE_OVERHEAD_GAS) * gasPriceGwei * 1e-9 * p.REIMBURSE_BPS) / BPS;
    let cap;
    if (lane === 'eth') cap = costSum;
    else cap = (p.PAGE * p.AVG_SCORE * this.ethRate(now)) / 1e4 / W;
    const reimb = Math.min(gasEth, (cap * p.REIMBURSE_CAP_BPS) / BPS, this.ethPot);
    let cost = costSum;
    if (reimb > 0) {
      this.checkpoint(now);
      this.ethPot -= reimb;
      this.syncFunded();
      if (lane === 'eth') cost += reimb;
    }
    return { cost, reimb, t0: now, lane };
  }
  priceOf(st, now) {
    const p = this.p;
    const el = Math.min(now - st.t0, p.AUCTION_LENGTH);
    const factor = p.AUCTION_START_X * p.AUCTION_LENGTH - (p.AUCTION_START_X - p.AUCTION_FLOOR_X) * el;
    return (st.cost * factor) / (p.AUCTION_LENGTH * BPS);
  }
  buyStatement(st, now) {
    const p = this.p;
    const price = this.priceOf(st, now);
    const toBuyback = (price * p.SALE_SPLIT) / BPS;
    this.ethToBuyback += toBuyback;
    this.checkpoint(now);
    this.ethPot += price - toBuyback;
    this.syncFunded();
    return { price, toBuyback, toPot: price - toBuyback };
  }

  // ---- phase 2: exitModule pays rating * unitPerPoint of exitToken. pots here hold the eth value of exitToken at xp per point
  setExitModule(now, xp) {
    const p = this.p;
    this.moduleSet = true; this.xp = xp; this.xCheckpointTime = now;
    this.xStartPrice = p.SUPPLY / (p.EXIT_SLICE_CREDITS * (p.AVG_SCORE / 1e4) * xp); // coin per eth of exitToken, asks the whole supply for a full slice
    this.xStartTime = now;
  }
  xRate(now) {
    const p = this.p;
    const r = this.xRateAtCheckpoint;
    if (!this.xFunded) return r;
    const cap = Math.min(p.XRATE_CAP, (this.xPot * BPS) / ((p.AVG_SCORE / 1e4) * this.xp));
    if (cap <= r) return r;
    return Math.min(r + (p.XRATE_CLIMB_PER_HOUR * (now - this.xCheckpointTime)) / 3600, cap);
  }
  xCheckpoint(now) { this.xRateAtCheckpoint = this.xRate(now); this.xCheckpointTime = now; }
  syncXFunded() {
    const p = this.p;
    this.xFunded = this.xPot * BPS >= (p.AVG_SCORE / 1e4) * this.xRateAtCheckpoint * this.xp;
  }
  // price in exitToken value for one credit at the current exit bid (without moving state)
  xPrice(pts, now) { return (pts * this.xRate(now)) / BPS * this.xp; }
  // sellForExitToken: pays pts * xRate of the credit's score in exitToken, drops xRate per credit
  xBuy(pts, now) {
    const p = this.p;
    this.xCheckpoint(now);
    const r = this.xRateAtCheckpoint;
    const price = (pts * r * this.xp) / BPS;
    if (!(price > 0) || price > this.xPot + 1e-18) return 0;
    this.xPot -= price;
    this.xRateAtCheckpoint = Math.max(Math.max(r - p.XRATE_DROP_PER_CREDIT, 0), p.XRATE_FLOOR);
    this.syncXFunded();
    return price;
  }
  exitReady(st, now) {
    return this.moduleSet && (st.lane === 'exit' || now >= st.t0 + this.p.AUCTION_LENGTH);
  }
  // exitStatement: the module hands back rating * unitPerPoint. eth lane splits EXIT_SPLIT, exit lane keeps all
  exitStatement(st, rating, now) {
    const p = this.p;
    const received = rating * this.xp;
    const toBuyback = st.lane === 'eth' ? (received * p.EXIT_SPLIT) / BPS : 0;
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
  // dutch auction: coin per eth of exitToken, halves every XAUCTION_HALF_LIFE, the clock runs only while the pot is not empty
  xAuctionPrice(now) {
    if (this.xToBuyback === 0) return this.xStartPrice;
    const el = now - this.xStartTime;
    if (el / this.p.XAUCTION_HALF_LIFE >= 256) return 0;
    return this.xStartPrice * Math.pow(0.5, el / this.p.XAUCTION_HALF_LIFE);
  }
  xSlice() { return Math.min(this.xToBuyback, this.p.EXIT_SLICE_CREDITS * (this.p.AVG_SCORE / 1e4) * this.xp); }
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
  // buyback(): one slice at most per BUYBACK_DELAY blocks, tip on the slice
  takeBuybackSlice(now) {
    const p = this.p;
    const pool = this.ethToBuyback;
    if (pool <= 1e-15 || now < this.lastBuybackTime + p.BUYBACK_DELAY * 12) return null;
    const slice = Math.min(pool, p.BUYBACK_SLICE);
    this.ethToBuyback = pool - slice;
    this.lastBuybackTime = now;
    const tip = (slice * p.KEEPER_TIP_BPS) / BPS;
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
// share of a swap's notional that lands in the engine's pot: 9.5 of the 10 base points plus all of the anti sniper extra
export function engineFeeFraction(p, f) {
  const base = p.baselineSkimBps / 1e5;
  return base * (p.bountyBps / BPS) + Math.max(0, f - base);
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
export function simulate(userParams = {}) {
  const p = Object.assign({}, DEFAULTS, userParams);
  const rng = mulberry32(p.seed);
  const core = new Core(p, 0);
  const pool = new Pool(p);
  const H = Math.round(p.days * 24);
  const avgPts = p.AVG_SCORE / 1e4;
  const bLate = p.buyShareLate != null ? p.buyShareLate : (p.volPreset === 'sustained17' || p.volPreset === 'sustained50') ? 0.5 : p.volPreset === 'custom' ? 0.49 : 0.46;
  const phase2At = p.phase2Day == null ? Infinity : p.phase2Day * 86400;

  // state
  let book = []; // resting market offers, ordered by descending key (ask multiple per point), smallest last
  let strat = []; // CreditStrategy listings, ordered by descending need (wei per point to clear)
  let holdPool = p.holders;
  const ethPile = [], xPile = [];
  let stmts = []; // eth lane statements held for sale
  let lnM = 0, nextSid = 1;
  const T = { // totals
    fees: 0, feesBuyback: 0, feesTaker: 0, saleGross: 0, saleToPot: 0, saleToBuyback: 0, spent: 0, tips: 0, reimb: 0,
    bought: 0, boughtX: 0, pts: 0, cost: 0, mkt: 0, ask: 0, sumM: 0, composed: 0, composedX: 0, sold: 0, exited: 0, exitedX: 0,
    soldPrice: 0, soldCost: 0, soldPts: 0, buybackSpent: 0, buybackTips: 0, burned: 0, burnedX: 0, bidSpendEth: 0, listBought: 0, stratBought: 0,
    xFills: 0, xCoin: 0, xValue: 0, xGross: 0, xDiscSum: 0, xRecv: 0, xSpent: 0, firstFill: -1, capStepHits: 0, clampSteps: 0,
    capBindSteps: 0, capBindRich: 0, potBindSteps: 0, vol: 0, stCost: 0, stRating: 0, stmtArrivals: 0, stmtMiss: 0, first80cost: 0, first80mkt: 0, first80pts: 0, first80n: 0, first80t: -1,
  };
  const histPts = new Array(10).fill(0), histCost = new Array(10).fill(0);
  const xFillLog = [];
  const S = {}; // series, one entry per hour
  const names = ['pot', 'toBuyback', 'cumFees', 'rate', 'mktPerPoint', 'frontier', 'bidRatio', 'bought', 'avgScoreCum', 'avgScoreDay',
    'costPerCredit', 'mktPerCredit', 'composed', 'sold', 'held', 'heldFloor', 'locked', 'exited', 'buybackSpent', 'burned', 'burnedPct',
    'coinPrice', 'xPot', 'xToBuyback', 'xRate', 'xFills', 'book', 'saleToPot', 'saleToBuyback', 'cumPts', 'cumCost', 'cumMkt', 'xBought', 'xDisc', 'volume', 'poolEth'];
  for (const n of names) S[n] = new Array(H + 1);

  // initial resting book at steady state, and the CreditStrategy inventory
  const flat = p.bidMode === 'flat';
  const newOffer = () => {
    const pts = 80 + 720 * rng();
    const m = Math.exp(p.askSigma * normal(rng));
    const prem = pts >= 790 ? 2.0 : pts >= 740 ? 1.12 : 1.0;
    return { pts, m, prem, key: (m * prem) / (flat ? avgPts : pts), listed: rng() < p.listedShare };
  };
  const nBook0 = Math.round(p.offersPerHour / Math.max(p.bookChurn, 1e-3));
  for (let i = 0; i < nBook0; i++) book.push(newOffer());
  book.sort((a, b) => b.key - a.key);
  if (p.strategyOn) {
    for (const [price, count] of STRAT_LISTINGS) {
      for (let i = 0; i < count; i++) {
        const pts = interp(STRAT_SCORE_Q, rng());
        strat.push({ pts, price, need: (price * W) / (flat ? avgPts : pts) });
      }
    }
    strat.sort((a, b) => b.need - a.need);
  }

  const peff = (t) => pathPrice(p, t) * Math.exp(lnM);
  let stepW = 1, peffNow = 0; // weight of the current step in hours, market price in the step
  let prevRate = p.rateStart, signChanges = 0, lastDir = 0, rateMaxRatio = 0, rateAbsMove = 0, rateMoves = 0;

  // ---- the engine buys: market offers through the bid or a listing, CreditStrategy listings, exit token bid in phase 2
  // a seller whose credit does not fit the hourly cap or the pot waits, and another credit that fits sells instead
  function pickFrom(arr, isStrat, r, xPerPt, Pw, Pe, afford, xAfford) {
    const lim = Math.max(0, arr.length - 400);
    const top = Math.max(r, xPerPt);
    for (let i = arr.length - 1; i >= lim; i--) {
      const it = arr[i];
      const need = isStrat ? it.need : it.key * Pw;
      if (need > top) return null;
      const ethOk = need <= r, xOk = !isStrat && need <= xPerPt;
      const listing = isStrat || it.listed;
      const ep = flat ? avgPts : it.pts;
      const ask = isStrat ? it.price : it.key * ep * Pe;
      const ethFits = ethOk && (listing ? ask * (1 + p.TIP_CAP_BPS / BPS) <= afford : (ep * r) / W <= afford);
      const xFits = xOk && (ep * xPerPt) / W <= xAfford;
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
        const ep = flat ? avgPts : it.pts;
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
      const afford = Math.min(core.ethPot, (rm.wp * p.SPEND_CAP_BPS_PER_HOUR) / BPS - rm.wsp);
      const xAfford = p2 ? core.xPot : 0;
      const roomLeft = (rm.wp * p.SPEND_CAP_BPS_PER_HOUR) / BPS - rm.wsp;
      if (afford <= 1e-15 && xAfford <= 0) { noteBind(r, xPerPt, Pw, roomLeft); break; }
      const a = pickFrom(book, false, r, xPerPt, Pw, Pe, afford, xAfford);
      const b = strat.length ? pickFrom(strat, true, r, 0, Pw, Pe, afford, 0) : null;
      const c = a && b ? (b.need < a.need ? b : a) : a || b;
      if (!c) { noteBind(r, xPerPt, Pw, roomLeft); break; }
      const it = c.it, useS = c.isStrat, ep = flat ? avgPts : it.pts;
      let door = c.ethFits && c.xFits ? (r >= xPerPt ? 'eth' : 'x') : c.ethFits ? 'eth' : 'x';
      let cost = 0, tip = 0, viaListing = false, ok = false;
      if (door === 'x') {
        cost = core.xBuy(ep, now);
        ok = cost > 0;
        if (!ok && c.ethFits) door = 'eth';
      }
      if (door === 'eth') {
        if (c.listing) {
          const res = core.buyListing(ep, c.ask, now);
          if (res) { cost = res.cost; tip = res.tip; ok = true; viaListing = true; }
        } else {
          cost = core.sellForEth(ep, now);
          ok = cost > 0;
        }
      }
      if (!ok) break;
      if (useS) strat.splice(c.i, 1); else book.splice(c.i, 1);
      holdPool -= 1;
      const askEth = c.ask;
      if (door === 'x') {
        T.boughtX++; T.xSpent += cost; xPile.push({ pts: it.pts });
      } else {
        T.bought++; T.pts += it.pts; T.cost += cost + tip; T.mkt += Pe; T.ask += askEth; T.spent += cost + tip; T.tips += tip;
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

  // ---- compose when a lane pile holds 80. the oldest first
  function composeAll(now) {
    while (ethPile.length >= p.PAGE) {
      const page = ethPile.splice(0, p.PAGE);
      let cost = 0, rating = 0;
      for (const c of page) { cost += c.cost; rating += c.pts; }
      const st = core.compose(cost, 'eth', now, p.gasGwei);
      st.rating = rating; st.id = nextSid++;
      T.reimb += st.reimb; T.composed++; T.stCost += st.cost; T.stRating += rating;
      stmts.push(st);
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

  // ---- statement buyers meet the falling price auction
  function statementBuyers(t0, now, Pe) {
    const n = poisson(rng, (stmtArrivalsPerDay(p, now) * (now - t0)) / 86400);
    for (let i = 0; i < n; i++) {
      T.stmtArrivals++;
      const budget = interp(WTP_Q, rng()) * p.wtpMult * p.PAGE * Pe;
      let best = -1, bp = Infinity;
      for (let j = 0; j < stmts.length; j++) {
        const pr = core.priceOf(stmts[j], now);
        if (pr <= budget && pr < bp) { bp = pr; best = j; }
      }
      if (best < 0) { T.stmtMiss++; continue; }
      const st = stmts[best];
      const res = core.buyStatement(st, now);
      stmts.splice(best, 1);
      T.sold++; T.soldPrice += res.price; T.soldCost += st.cost; T.soldPts += st.rating;
      T.saleGross += res.price; T.saleToPot += res.toPot; T.saleToBuyback += res.toBuyback;
    }
  }

  // ---- phase 2: statements past the auction exit through the exitModule
  function exits(now) {
    if (!core.moduleSet) return;
    const keep = [];
    for (const st of stmts) {
      const floor = (st.cost * p.AUCTION_FLOOR_X) / BPS;
      if (core.exitReady(st, now) && st.rating * core.xp >= p.exitMinRatio * floor) {
        const res = core.exitStatement(st, st.rating, now);
        T.exited++; T.xRecv += res.received;
      } else keep.push(st);
    }
    stmts = keep;
  }

  // ---- phase 2 dutch auction: takers fill when the all in discount to the pool price reaches the threshold
  function xAuction(stepStart, now) {
    for (let guard = 0; core.moduleSet && core.xToBuyback > 1e-12 && guard < 500; guard++) {
      const f = skimFraction(p, now), spot = pool.price, g = spot * (1 + f);
      const tStar = core.xStartTime + p.XAUCTION_HALF_LIFE * Math.log2((core.xStartPrice * g) / (1 - p.takerThreshold));
      if (!(tStar <= now)) break;
      const tf = Math.max(tStar, stepStart, core.xStartTime);
      const slice = core.xSlice(), coinIn = slice * core.xAuctionPrice(tf);
      const poolEth = pool.ethForCoin(coinIn);
      if (!isFinite(poolEth)) break;
      core.xFill(tf);
      const gross = poolEth * (1 + f);
      pool.buy(poolEth);
      const fee = poolEth * engineFeeFraction(p, f);
      core.addFees(fee, now);
      T.feesTaker += fee; T.burnedX += coinIn; T.xFills++; T.xCoin += coinIn; T.xValue += slice; T.xGross += gross;
      T.xDiscSum += 1 - gross / slice;
      xFillLog.push([tf / 3600, slice, coinIn, gross, 1 - gross / slice, 1 - (coinIn * spot) / slice]);
    }
  }

  // ---- eth buyback keeper: one slice per BUYBACK_DELAY blocks, coin bought in the pool and burned
  function buybacks(stepStart, now) {
    if (!p.keeperBuyback) return;
    const delay = p.BUYBACK_DELAY * 12;
    let tb = Math.max(stepStart, core.lastBuybackTime + delay), feeBack = 0;
    while (tb <= now && core.ethToBuyback > 1e-15) {
      const info = core.takeBuybackSlice(tb);
      if (!info) break;
      const f = skimFraction(p, tb);
      const notional = info.budget / (1 + f);
      T.burned += pool.buy(notional);
      T.buybackSpent += info.budget; T.buybackTips += info.tip;
      feeBack += notional * engineFeeFraction(p, f);
      tb += delay;
    }
    if (feeBack > 0) { core.addFees(feeBack, now); T.feesBuyback += feeBack; }
  }

  // ---- series snapshot at the end of hour index h
  function record(h, t) {
    const Pe = peff(t), r = core.ethRate(t);
    const held = stmts.length;
    let floorN = 0, locked = 0;
    for (const s of stmts) { if (t - s.t0 >= p.AUCTION_LENGTH) floorN++; locked += s.cost; }
    S.pot[h] = core.ethPot; S.toBuyback[h] = core.ethToBuyback;
    S.cumFees[h] = T.fees + T.feesBuyback + T.feesTaker;
    S.rate[h] = r; S.mktPerPoint[h] = (Pe * W) / 440; S.frontier[h] = Math.min(900, (Pe * W) / r);
    S.bidRatio[h] = (r * 440) / (Pe * W);
    S.bought[h] = T.bought; S.cumPts[h] = T.pts; S.cumCost[h] = T.cost; S.cumMkt[h] = T.mkt;
    S.avgScoreCum[h] = T.bought ? T.pts / T.bought : 0;
    const h24 = Math.max(0, h - 24);
    const dB = T.bought - S.bought[h24], dP = T.pts - S.cumPts[h24];
    S.avgScoreDay[h] = dB > 0 ? dP / dB : (h > 0 ? S.avgScoreDay[h - 1] : 0);
    S.costPerCredit[h] = T.bought ? T.cost / T.bought : 0; S.mktPerCredit[h] = Pe;
    S.composed[h] = T.composed; S.sold[h] = T.sold; S.held[h] = held; S.heldFloor[h] = floorN; S.locked[h] = locked;
    S.exited[h] = T.exited + T.exitedX; S.buybackSpent[h] = T.buybackSpent;
    S.burned[h] = T.burned + T.burnedX; S.burnedPct[h] = ((T.burned + T.burnedX) / p.SUPPLY) * 100;
    S.coinPrice[h] = pool.price; S.xPot[h] = core.xPot; S.xToBuyback[h] = core.xToBuyback;
    S.xRate[h] = core.moduleSet ? core.xRate(t) : 0; S.xFills[h] = T.xFills; S.book[h] = book.length;
    S.saleToPot[h] = T.saleToPot; S.saleToBuyback[h] = T.saleToBuyback; S.xBought[h] = T.boughtX;
    S.volume[h] = T.vol; S.xDisc[h] = T.xFills ? T.xDiscSum / T.xFills : 0; S.poolEth[h] = pool.ethInPool();
  }

  // ---- the main loop. hour 0 runs in 120 s sub steps for the anti sniper window, then hourly
  const steps = [];
  for (let k = 0; k < 30; k++) steps.push([k * 120, (k + 1) * 120]);
  for (let h = 1; h < H; h++) steps.push([h * 3600, (h + 1) * 3600]);
  record(0, 0);
  for (const [t0, t1] of steps) {
    const dt = t1 - t0, mid = (t0 + t1) / 2;
    stepW = dt / 3600;
    // coin market: volume, fees to the pot, price impact on the single position
    const V = stepVolume(p, t0, dt), f = skimFraction(p, mid), b = t0 < 86400 ? p.buyShare0 : bLate;
    const net = b * V - (1 - b) * V; // notional is the pool's own delta, the skim comes on top
    if (net > 0) pool.buy(net); else if (net < 0) pool.sell(-net);
    const fee = V * engineFeeFraction(p, f);
    core.addFees(fee, mid);
    T.fees += fee; T.vol += V;
    if (!core.moduleSet && t1 >= phase2At) core.setExitModule(t1, p.xp);
    // credit market: the engine's own buying lifts the flat price, the lift decays
    lnM *= Math.pow(0.5, dt / (p.impactHalfLifeHours * 3600));
    const Pe = peff(t1), r0 = core.ethRate(t1);
    const xPay = core.moduleSet ? (core.xRate(t1) / BPS) * core.xp * W : 0;
    const boost = Math.pow(Math.max(1, (Math.max(r0, xPay) * 440) / (Pe * W)), p.supplyElast);
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
    // the engine acts
    if (p.inventoryGate > 0) core.setGate(stmts.length + ethPile.length / p.PAGE >= p.inventoryGate, t0);
    const capBefore = core.capHits;
    peffNow = Pe;
    const spentEth = core.gated ? 0 : engineBuys(t1, Pe);
    if (core.capHits > capBefore) T.capStepHits++;
    if (core.funded && core.clamp() < Infinity && core.ethRate(t1) >= core.clamp() * (1 - 1e-9)) T.clampSteps++;
    lnM = Math.min(lnM + (p.impactElast * spentEth) / p.marketDailyEth, Math.log(p.impactCap));
    composeAll(t1);
    statementBuyers(t0, t1, peff(t1));
    exits(t1);
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
    rateMaxRatio = Math.max(rateMaxRatio, (rr * 440) / (peff(t1) * W));
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
    saleOverCost: T.soldCost ? T.soldPrice / T.soldCost : 0,
    stmtArrivals: T.stmtArrivals, stmtMiss: T.stmtMiss,
    xFills: T.xFills, xMedianIntervalH: med(intervals), xMeanDiscount: T.xFills ? T.xDiscSum / T.xFills : 0,
    potCheck: T.fees + T.feesBuyback + T.feesTaker + T.saleToPot - T.spent - T.reimb - core.ethPot,
    buybackCheck: T.saleToBuyback - core.ethToBuyback - T.buybackSpent - T.buybackTips,
    finalRate: core.ethRate(H * 3600), finalPot: core.ethPot,
  };
  return { params: p, H, S, T, stats, at, histPts, histCost, xFillLog, core, pool };
}

// headline numbers at day 30, 60, 90 and the one line verdict
export function headline(res) {
  const rows = [30, 60, 90].filter((d) => d * 24 <= res.H).map((d) => res.at(d));
  const last = res.at(res.H / 24);
  const stuck = last.heldFloor;
  const loops = last.sold >= 0.5 * Math.max(1, last.composed) && last.sold > 10;
  return { rows, last, stuck, loops, burnedPct: last.burnedPct, locked: last.locked };
}
