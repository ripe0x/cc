// scenario batches. usage: node run.mjs [q1 q2 ...]. writes results/*.json
import fs from 'node:fs';
import { simulate, WTP_Q, interp, W } from './engine.js';

const OUT = new URL('./results/', import.meta.url).pathname;
fs.mkdirSync(OUT, { recursive: true });
const SEEDS5 = [1, 2, 3, 4, 5], SEEDS3 = [1, 2, 3];

// flat numeric metrics of one run
export function metrics(res) {
  const m = {}, S = res.S, T = res.T, st = res.stats, H = res.H;
  for (const d of [30, 60, 90]) {
    if (d * 24 > H) continue;
    const a = res.at(d);
    Object.assign(m, {
      ['fees' + d]: a.cumFees, ['bought' + d]: a.bought, ['composed' + d]: a.composed, ['sold' + d]: a.sold, ['held' + d]: a.held,
      ['floor' + d]: a.heldFloor, ['locked' + d]: a.locked, ['toPot' + d]: a.saleToPot, ['toBB' + d]: a.saleToBuyback,
      ['burnM' + d]: a.burned / 1e6, ['burnPct' + d]: a.burnedPct, ['pot' + d]: a.pot, ['exited' + d]: a.exited,
    });
  }
  // stall diagnostics
  let potGone = NaN, lastBuy = 0, maxGap = 0, gap = 0, stall = 0, over = 0, started = false;
  for (let h = 1; h <= H; h++) {
    if (isNaN(potGone) && S.pot[h] < 1 && S.cumFees[h] > 20 && h > 24) potGone = h / 24;
    const bought = S.bought[h] > S.bought[h - 1];
    if (bought) { started = true; lastBuy = h / 24; gap = 0; } else if (started) { gap++; stall++; maxGap = Math.max(maxGap, gap); }
    if (started && S.bidRatio[h] > 1.5) over++;
  }
  Object.assign(m, {
    potGoneDay: potGone, lastBuyDay: lastBuy, stallHours: stall, maxStallHours: maxGap, hoursBidOver15x: over,
    firstFillHour: st.firstFillHour, costVsMarket: st.costVsMarket, costPerPointVsMarket: st.costPerPointVsMarket, costVsAsk: st.costVsAsk,
    avgScoreBought: st.avgScoreBought, capSteps: st.capSteps, capStepsRich: st.capStepsRich, potBlockedSteps: st.potBlockedSteps, clampSteps: st.clampSteps, rateMaxBidRatio: st.rateMaxBidRatio,
    rateSignChanges: st.rateSignChanges, rateMeanAbsMove: st.rateMeanAbsMove, saleOverCost: st.saleOverCost,
    stmtArrivals: st.stmtArrivals, stmtMiss: st.stmtMiss, xFills: st.xFills, xMedianIntervalH: st.xMedianIntervalH, xMeanDiscount: st.xMeanDiscount,
    boughtX: T.boughtX, exitedX: T.exitedX, burnEthM: T.burned / 1e6, burnXM: T.burnedX / 1e6, tips: T.tips, reimb: T.reimb, spent: T.spent,
    stCost: T.composed ? T.stCost / T.composed : NaN, stRating: T.composed ? T.stRating / T.composed : NaN,
    xPotEnd: res.core.xPot, xToBuybackEnd: res.core.xToBuyback, potEnd: res.core.ethPot, toBuybackEnd: res.core.ethToBuyback,
    recycled: T.spent ? T.saleGross / T.spent : 0, buybackEth: T.buybackSpent + T.buybackTips,
    f80hours: st.first80 ? st.first80.hours : NaN, f80cost: st.first80 ? st.first80.cost : NaN, f80ratio: st.first80 ? st.first80.ratio : NaN,
    f80score: st.first80 ? st.first80.avgScore : NaN, sumM: T.bought ? T.sumM / T.bought : NaN,
    stratBought: T.stratBought, listBought: T.listBought, xValue: T.xValue, xCoinM: T.xCoin / 1e6,
  });
  return m;
}
export function mean(list) {
  const out = {};
  for (const k of Object.keys(list[0])) {
    const v = list.map((o) => o[k]).filter((x) => Number.isFinite(x));
    out[k] = v.length ? v.reduce((a, b) => a + b, 0) / v.length : null;
  }
  return out;
}
// mean over seeds of the metrics of one configuration
export function many(over, seeds = SEEDS3) {
  return mean(seeds.map((s) => metrics(simulate(Object.assign({}, over, { seed: s })))));
}
const r3 = (x) => (x == null || !Number.isFinite(x) ? x : +Number(x).toPrecision(4));
const round = (o) => JSON.parse(JSON.stringify(o, (k, v) => (typeof v === 'number' ? r3(v) : v)));
const write = (name, data) => { fs.writeFileSync(OUT + name + '.json', JSON.stringify(round(data), null, 1)); console.log('wrote', name); };
// share of statement buyers whose willingness to pay multiple is at least x
export function wtpSurvival(x) {
  let lo = 0, hi = 1;
  for (let i = 0; i < 60; i++) { const mid = (lo + hi) / 2; if (interp(WTP_Q, mid) < x) lo = mid; else hi = mid; }
  return 1 - lo;
}
const batches = {};

// ---- q1: does the phase 1 loop turn, per volume preset
batches.q1 = () => {
  const out = { presets: {}, series: {} };
  for (const v of ['comparable', 'sustained17', 'sustained50', 'deadWeek1']) {
    out.presets[v] = many({ volPreset: v }, SEEDS5);
  }
  // daily series of the base case, seed 1
  const r = simulate({ seed: 1 });
  const rows = [];
  for (let d = 0; d <= 90; d += d < 20 ? 1 : 5) {
    const a = r.at(d);
    rows.push({ day: d, pot: a.pot, fees: a.cumFees, bought: a.bought, composed: a.composed, sold: a.sold, floor: a.heldFloor, locked: a.locked, burnPct: a.burnedPct, rate: a.rate, bid: a.bidRatio, mkt: a.mktPerCredit, price: a.coinPrice });
  }
  out.series.comparable = rows;
  out.wtpSurvival = Object.fromEntries([0.6, 0.84, 1.0, 1.2, 1.5, 2, 4].map((x) => [x, wtpSurvival(x)]));
  return out;
};

// ---- q2: the starting rate
batches.q2 = () => {
  const out = { today: [], rule: [] };
  for (const rs of [1e12, 2e12, 3e12, 4e12, 6e12, 8e12, 1e13, 1.5e13, 2e13, 3e13]) {
    out.today.push(Object.assign({ rateStart: rs, m: (rs * 800) / (0.0089 * W) }, many({ rateStart: rs }, SEEDS3)));
  }
  // the rule: rateStart as a multiple m of the rate at which an 800 point credit clears at the flat price (price * 1e18 / 800)
  for (const p0 of [0.0045, 0.0089, 0.018, 0.03]) {
    for (const m of [0.1, 0.2, 0.35, 0.5, 0.75, 1, 1.5, 2.5]) {
      const rs = (m * p0 * W) / 800;
      out.rule.push(Object.assign({ p0, m, rateStart: rs }, many({ priceP0: p0, rateStart: rs }, [1, 2])));
    }
  }
  return out;
};

// ---- q3: per point bid versus the flat market
batches.q3 = () => {
  const out = {};
  out.perPoint = many({}, SEEDS5);
  out.flatBid = many({ bidMode: 'flat' }, SEEDS5);
  out.perPointNoImpact = many({ impactElast: 0 }, SEEDS5);
  out.flatBidNoImpact = many({ impactElast: 0, bidMode: 'flat' }, SEEDS5);
  out.perPointListings = many({ listedShare: 0.5 }, SEEDS5);
  out.perPointDecline = many({ pricePath: 'decline' }, SEEDS5);
  out.flatDecline = many({ pricePath: 'decline', bidMode: 'flat' }, SEEDS5);
  // who sells, by score bin, averaged over seeds
  const bins = new Array(10).fill(0), cost = new Array(10).fill(0);
  let frontier = [];
  for (const s of SEEDS5) {
    const r = simulate({ seed: s });
    r.histPts.forEach((x, i) => { bins[i] += x / 5; cost[i] += r.histCost[i] / 5; });
    if (s === 1) {
      for (const d of [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 20, 30]) {
        const a = r.at(d);
        frontier.push({ day: d, frontier: a.frontier, avgScoreDay: a.avgScoreDay, bid: a.bidRatio, costPerCredit: a.costPerCredit, mkt: a.mktPerCredit });
      }
    }
  }
  out.bins = bins.map((n, i) => ({ lo: 80 + i * 72, hi: 152 + i * 72, credits: n, avgCost: n ? cost[i] / n : 0 }));
  out.frontier = frontier;
  return out;
};

// ---- q4: statement auction parameters
batches.q4 = () => {
  const out = { grid: [], length: [], clearing: [], current: {} };
  for (const start of [4, 3, 2.5, 2, 1.5]) {
    for (const floor of [1.2, 1.0, 0.8, 0.6]) {
      if (floor > start) continue;
      out.grid.push(Object.assign({ start, floor }, many({ AUCTION_START_X: start * 1e4, AUCTION_FLOOR_X: floor * 1e4 }, SEEDS3)));
    }
  }
  for (const hours of [12, 24, 72, 168, 336]) {
    for (const [start, floor] of [[4, 1.2], [2, 0.8]]) {
      out.length.push(Object.assign({ hours, start, floor }, many({ AUCTION_LENGTH: hours * 3600, AUCTION_START_X: start * 1e4, AUCTION_FLOOR_X: floor * 1e4 }, SEEDS3)));
    }
  }
  // share of observed buyers that clear a given floor, by the engine's cost basis as a multiple of the parts' market cost
  for (const c of [0.6, 0.7, 0.8, 0.9, 1.0, 1.2, 1.4, 1.6]) {
    out.clearing.push({ cost: c, floor1_2: wtpSurvival(1.2 * c), floor1_0: wtpSurvival(1.0 * c), floor0_8: wtpSurvival(0.8 * c), floor0_6: wtpSurvival(0.6 * c), start4: wtpSurvival(4 * c) });
  }
  out.current = many({}, SEEDS5);
  out.currentNoImpact = many({ impactElast: 0 }, SEEDS5);
  out.currentFlatBid = many({ bidMode: 'flat' }, SEEDS5);
  return out;
};

// ---- q5: the funded rule
batches.q5 = () => {
  const out = {};
  const scenarios = {
    base: {}, smallPot: { volScale: 0.03 }, tinyPot: { volScale: 0.005, volPreset: 'sustained17' }, recovery: { pricePath: 'recovery' },
    decline: { pricePath: 'decline' }, sustained50: { volPreset: 'sustained50' }, lowStart: { rateStart: 1e12 }, noImpact: { impactElast: 0 },
  };
  for (const [name, o] of Object.entries(scenarios)) {
    out[name] = { new: many(Object.assign({ fundedRule: 'new' }, o), SEEDS3), old: many(Object.assign({ fundedRule: 'old' }, o), SEEDS3) };
  }
  return out;
};

// ---- q6: hourly cap, climb and drop constants
batches.q6 = () => {
  const out = { base: many({}, SEEDS5), sweeps: {} };
  const sweeps = {
    DROP_BPS: [250, 500, 1000, 2000, 4000], CLIMB_BASE_BPS_PER_HOUR: [50, 100, 200, 400], CLIMB_MAX_BPS_PER_HOUR: [200, 400, 800, 1600],
    SPEND_CAP_BPS_PER_HOUR: [500, 1000, 2000, 4000, 10000],
  };
  for (const [k, vals] of Object.entries(sweeps)) out.sweeps[k] = vals.map((v) => Object.assign({ value: v }, many({ [k]: v }, SEEDS3)));
  out.smallPotCap = {};
  for (const cap of [500, 1000, 2000, 5000]) out.smallPotCap[cap] = many({ SPEND_CAP_BPS_PER_HOUR: cap, volScale: 0.03 }, SEEDS3);
  return out;
};

// ---- q7: phase 2
batches.q7 = () => {
  const out = { xp: [], never: [], taker: [], bid: [], base: many({}, SEEDS3) };
  const p2 = { phase2Day: 14 };
  for (const xp of [5e-6, 1e-5, 1.5e-5, 2e-5, 3e-5, 4e-5, 6e-5, 1e-4]) {
    out.xp.push(Object.assign({ xp }, many(Object.assign({ xp }, p2), SEEDS3)));
    out.never.push(Object.assign({ xp }, many(Object.assign({ xp, exitMinRatio: 1e9 }, p2), SEEDS3)));
  }
  for (const th of [0.02, 0.05, 0.1, 0.15, 0.25, 0.4]) {
    out.taker.push(Object.assign({ th }, many(Object.assign({ xp: 3e-5, takerThreshold: th }, p2), SEEDS3)));
  }
  for (const xp of [1e-5, 3e-5]) {
    const r = simulate({ xp, phase2Day: 14, seed: 1 });
    const rows = [];
    for (const d of [14.5, 15, 16, 18, 20, 25, 30, 45, 60, 90]) {
      const a = r.at(d);
      rows.push({ xp, day: d, xRate: a.xRate, xPot: a.xPot, xToBuyback: a.xToBuyback, xBought: a.xBought, exited: a.exited, burnPct: a.burnedPct, xFills: a.xFills, disc: a.xDisc });
    }
    out.bid.push(...rows);
  }
  // first fills of the dutch auction in one run
  const r = simulate({ xp: 3e-5, phase2Day: 14, seed: 1 });
  out.fills = r.xFillLog.slice(0, 12).map(([h, slice, coinIn, gross, disc, spotDisc]) => ({ hour: h, sliceValue: slice, coinIn, ethCost: gross, allInDiscount: disc, spotDiscount: spotDisc }));
  out.fillCount = r.xFillLog.length;
  return out;
};

// ---- q8: sensitivity, low and high values of each input against the base case
batches.q8 = () => {
  const base = many({}, SEEDS5);
  const tests = [
    ['volScale', 0.25, 4], ['priceP0', 0.0045, 0.018], ['pricePath', 'decline', 'recovery'], ['askSigma', 0.15, 0.4], ['impactElast', 0, 0.3],
    ['offersPerHour', 60, 400], ['supplyElast', 0.5, 3], ['bookChurn', 0.02, 0.15], ['stmtPerDay', 3, 20], ['wtpMult', 0.7, 1.3],
    ['buyShareLate', 0.42, 0.52], ['rateStart', 1e12, 2e13], ['AUCTION_START_X', 20000, 40000], ['AUCTION_FLOOR_X', 8000, 12000],
    ['AUCTION_LENGTH', 24 * 3600, 168 * 3600], ['gasGwei', 0.5, 10], ['listedShare', 0, 0.5], ['sniperVolShare', 0.2, 0.6], ['h1Share', 0.45, 0.7],
    ['SPEND_CAP_BPS_PER_HOUR', 1000, 4000], ['DROP_BPS', 500, 2000], ['CLIMB_BASE_BPS_PER_HOUR', 50, 200], ['bidMode', 'flat', 'perPoint'],
  ];
  const out = { base, rows: [] };
  for (const [k, lo, hi] of tests) {
    const a = many({ [k]: lo }, SEEDS3), b = many({ [k]: hi }, SEEDS3);
    out.rows.push({ key: k, lo, hi, loRes: pick(a), hiRes: pick(b) });
  }
  return out;
};
const pick = (m) => ({ burnPct90: m.burnPct90, burnM90: m.burnM90, locked90: m.locked90, sold90: m.sold90, floor90: m.floor90, composed90: m.composed90, toBB90: m.toBB90, costVsMarket: m.costVsMarket });

// ---- q9: recommended combinations against the base case, three volume presets
export const COMBOS = {
  base: {},
  rule: { rateStart: 5.6e12 },
  constants: { rateStart: 5.6e12, AUCTION_START_X: 20000, AUCTION_FLOOR_X: 8000, DROP_BPS: 2000 },
  constantsSlow: { rateStart: 5.6e12, AUCTION_START_X: 20000, AUCTION_FLOOR_X: 8000, DROP_BPS: 2000, CLIMB_BASE_BPS_PER_HOUR: 50 },
  floor06: { rateStart: 5.6e12, AUCTION_START_X: 20000, AUCTION_FLOOR_X: 6000, DROP_BPS: 2000 },
  floor10: { rateStart: 5.6e12, AUCTION_START_X: 20000, AUCTION_FLOOR_X: 10000, DROP_BPS: 2000 },
  flatBid: { rateStart: 5.6e12, AUCTION_START_X: 20000, AUCTION_FLOOR_X: 8000, DROP_BPS: 2000, bidMode: 'flat' },
  flatBidFloor10: { rateStart: 5.6e12, AUCTION_START_X: 20000, AUCTION_FLOOR_X: 10000, DROP_BPS: 2000, bidMode: 'flat' },
  gate20: { rateStart: 5.6e12, inventoryGate: 20 },
  gate20constants: { rateStart: 5.6e12, inventoryGate: 20, AUCTION_START_X: 20000, AUCTION_FLOOR_X: 8000, DROP_BPS: 2000 },
  gate20flat: { rateStart: 5.6e12, inventoryGate: 20, AUCTION_START_X: 20000, AUCTION_FLOOR_X: 8000, DROP_BPS: 2000, bidMode: 'flat' },
  flatBidFloor12: { rateStart: 5.6e12, AUCTION_START_X: 20000, AUCTION_FLOOR_X: 12000, DROP_BPS: 2000, bidMode: 'flat' },
};
batches.q9 = () => {
  const out = {};
  for (const [name, o] of Object.entries(COMBOS)) {
    out[name] = { comparable: many(o, SEEDS5), sustained17: many(Object.assign({ volPreset: 'sustained17' }, o), SEEDS3), recovery: many(Object.assign({ pricePath: 'recovery' }, o), SEEDS3) };
  }
  return out;
};

if (process.argv[1] && process.argv[1].endsWith('run.mjs')) {
  const want = process.argv.slice(2);
  for (const name of want.length ? want : Object.keys(batches)) {
    const t = Date.now();
    write(name, batches[name]());
    console.log(name, ((Date.now() - t) / 1000).toFixed(1) + 's');
  }
}
