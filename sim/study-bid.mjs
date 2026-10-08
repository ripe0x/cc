// bid rule study: rules x parameters x markets at one minute steps over 90 days, same seeds for every rule.
// usage: node study-bid.mjs [--seeds 1,2,3] [--step 60] [--days 90] [--out results/bid-rule-study.csv]
// writes one csv row per (rule, params, market), metrics averaged over seeds, maxima taken over seeds
import fs from 'node:fs';
import os from 'node:os';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { simulate, summary, W } from './engine.js';

const arg = (k, d) => { const i = process.argv.indexOf('--' + k); return i > 0 ? process.argv[i + 1] : d; };
// a worker thread does not inherit process.argv, so the main thread passes the settings in workerData
const cfg = isMainThread ? { seeds: arg('seeds', '1,2,3').split(',').map(Number), step: +arg('step', 60), days: +arg('days', 90) } : workerData.cfg;
const SEEDS = cfg.seeds, STEP = cfg.step, DAYS = cfg.days;
const OUT = new URL(arg('out', 'results/bid-rule-study.csv'), import.meta.url).pathname;

// rateStart as a share of the 0.0089 eth market price of a credit over 433 average points
const rateAt = (share) => (share * 0.0089 * W) / 433;

// markets: pricePath and seller supply. thin is the flat path with a quarter of the seller arrivals
const MARKETS = {
  flat: { pricePath: 'flat' },
  falling: { pricePath: 'falling' },
  rising: { pricePath: 'rising' },
  thin: { pricePath: 'flat', offersPerHour: 150 * 0.25 },
  whipsaw: { pricePath: 'whipsaw' },
};

// rules. the built rule at 75 percent (as built) and 100 percent; the two new rules open at 100 percent
export function rules() {
  const out = [];
  for (const open of [75, 100]) out.push({ rule: 'built', params: `open=${open}`, over: { bidRule: 'built', rateStart: rateAt(open / 100) } });
  for (const dropTo of [80, 90, 95]) for (const climb of [0.5, 1, 2]) {
    out.push({ rule: 'dropToLast', params: `open=100;dropToPct=${dropTo};climbPerMin=${climb}`, over: { bidRule: 'dropToLast', rateStart: rateAt(1), dropToPct: dropTo, climbPerMin: climb } });
  }
  for (const drop of [0.25, 0.5, 1]) for (const climb of [0.5, 1, 2]) for (const ceil of [110, 125, 150]) {
    out.push({ rule: 'stepped', params: `open=100;dropToPct=80;dropPerCreditPct=${drop};climbPerMin=${climb};ceilPct=${ceil}`, over: { bidRule: 'stepped', rateStart: rateAt(1), dropToPct: 80, dropPerCreditPct: drop, climbPerMin: climb, ceilPct: ceil } });
  }
  return out;
}

export const COLS = ['rule', 'params', 'market', 'credits_day1', 'credits_day3', 'credits_day7', 'credits_day30', 'credits_day90', 'paid_vs_market',
  'statements_created_day90', 'eth_to_burn_day90', 'max_bid_over_market', 'idle_hours_max', 'max_paid_over_market', 'throttler_credits_day90'];

function runOne(job) {
  const rows = SEEDS.map((seed) => {
    const r = simulate(Object.assign({ days: DAYS, stepSec: STEP, seed }, MARKETS[job.market], job.over));
    const s = summary(r, DAYS);
    return {
      credits_day1: r.at(1).credits, credits_day3: r.at(3).credits, credits_day7: r.at(7).credits, credits_day30: r.at(30).credits, credits_day90: r.at(DAYS).credits,
      paid_vs_market: r.stats.costVsMarket, statements_created_day90: s.statements, eth_to_burn_day90: s.burnEth,
      max_bid_over_market: r.stats.rateMaxBidRatio, idle_hours_max: r.stats.idleHoursMax, max_paid_over_market: r.stats.maxPaidRatio, throttler_credits_day90: r.T.throttled,
    };
  });
  const out = { rule: job.rule, params: job.params, market: job.market };
  for (const k of COLS.slice(3)) {
    const v = rows.map((x) => x[k]);
    out[k] = k.startsWith('max_') || k === 'idle_hours_max' ? Math.max(...v) : v.reduce((a, b) => a + b, 0) / v.length;
  }
  return out;
}

if (!isMainThread) {
  for (const job of workerData.jobs) parentPort.postMessage(runOne(job));
} else {
  const fmt = (x) => (typeof x === 'number' ? +x.toPrecision(5) : x);
  if (process.argv.includes('--day1')) {
    // one representative setting per rule, falling market, first 24 hours at minute steps, seed 1
    const pick = [['built', 'open=75'], ['built', 'open=100'], ['dropToLast', 'open=100;dropToPct=80;climbPerMin=1'], ['dropToLast', 'open=100;dropToPct=95;climbPerMin=1'],
      ['dropToLast', 'open=100;dropToPct=95;climbPerMin=2'],
      ['stepped', 'open=100;dropToPct=80;dropPerCreditPct=1;climbPerMin=1;ceilPct=110'], ['stepped', 'open=100;dropToPct=80;dropPerCreditPct=0.5;climbPerMin=0.5;ceilPct=125']];
    const lines = ['rule,params,hour,credits_in_hour,avg_paid_vs_market_in_hour,bid_over_market_at_hour_end,market_vs_start_at_hour_end,pot_eth_at_hour_end'];
    for (const [rule, params] of pick) {
      const job = rules().find((r) => r.rule === rule && r.params === params);
      const r = simulate(Object.assign({ days: 2, stepSec: STEP, seed: SEEDS[0] }, MARKETS.falling, job.over)), S = r.S;
      for (let h = 1; h <= 24; h++) {
        const dc = S.cumCost[h] - S.cumCost[h - 1], dm = S.cumMkt[h] - S.cumMkt[h - 1];
        lines.push([rule, params, h, S.credits[h] - S.credits[h - 1], dm > 0 ? fmt(dc / dm) : '', fmt(S.bidRatio[h]), fmt(S.mktPerCredit[h] / r.params.priceP0), fmt(S.pot[h])].join(','));
      }
    }
    fs.writeFileSync(new URL('./results/bid-rule-falling-day1.csv', import.meta.url).pathname, lines.join('\n') + '\n');
    console.log('wrote falling day1,', lines.length - 1, 'rows');
    process.exit(0);
  }
  const jobs = [];
  const rows = [];
  let PROBE = false;
  // second pass, added to the existing csv: --add throttle|sens|decay (rows with the group's suffix in params are replaced)
  const group = arg('add', null);
  const GROUPS = {
    // the throttler seller on the settings named in --pick "rule|params,rule|params"
    throttle: (r) => ({ suffix: ';throttler=1', over: { throttler: true } }),
    // sensitivity: sellers never ask below 0.8 of the market price
    sens: () => ({ suffix: ';askFloor=0.8', over: { askFloor: 0.8 } }),
    // stepped with the ceiling headroom halving every 6 hours since the last fill
    decay: () => ({ suffix: ';ceilDecayHours=6', over: { ceilDecayHours: 6 } }),
  };
  if (group) {
    const g = GROUPS[group]({}), keep = new Set(arg('pick', '').split(','));
    const [head, ...lines] = fs.readFileSync(OUT, 'utf8').trim().split('\n');
    for (const l of lines) {
      if (l.includes(g.suffix)) continue;
      const f = l.split(','), o = {};
      COLS.forEach((c, i) => { o[c] = i < 3 ? f[i] : +f[i]; });
      rows.push(o);
    }
    for (const r of rules()) if (keep.has(r.rule + '|' + r.params)) for (const market of Object.keys(MARKETS)) {
      jobs.push({ market, rule: r.rule, params: r.params + g.suffix, over: Object.assign({}, r.over, g.over) });
    }
  } else if (process.argv.includes('--probe')) {
    // targeted probes, written to results/bid-rule-probes.csv: the throttler where the lowest asks are 0.8 of market, and a funded clamp of N credits
    const base = (rule, params) => rules().find((r) => r.rule === rule && r.params === params);
    const dl80 = base('dropToLast', 'open=100;dropToPct=80;climbPerMin=1'), dl95 = base('dropToLast', 'open=100;dropToPct=95;climbPerMin=1');
    const st = base('stepped', 'open=100;dropToPct=80;dropPerCreditPct=1;climbPerMin=1;ceilPct=110'), bt = base('built', 'open=100');
    const add = (r, tag, over, markets) => { for (const market of markets) jobs.push({ market, rule: r.rule, params: r.params + ';' + tag, over: Object.assign({}, r.over, over) }); };
    for (const r of [dl80, dl95, st, bt]) {
      add(r, 'askFloor=0.8', { askFloor: 0.8 }, ['flat']);
      add(r, 'askFloor=0.8;throttler=1;throttleFrac=0.8', { askFloor: 0.8, throttler: true, throttleFrac: 0.8 }, ['flat']);
    }
    for (const n of [5, 20, 80]) add(st, 'clampCredits=' + n, { clampCredits: n }, ['flat', 'falling', 'rising']);
    PROBE = true;
  } else for (const r of rules()) for (const market of Object.keys(MARKETS)) jobs.push(Object.assign({ market }, r));
  const nW = Math.max(1, Math.min(os.availableParallelism() - 2, jobs.length));
  const slices = Array.from({ length: nW }, () => []);
  jobs.sort((a, b) => (b.rule === 'stepped') - (a.rule === 'stepped')); // slow rule first
  jobs.forEach((j, i) => slices[i % nW].push(j));
  let live = nW;
  console.log(`${jobs.length} configurations x ${SEEDS.length} seeds, step ${STEP} s, ${DAYS} days, ${nW} workers`);
  for (const sl of slices) {
    const w = new Worker(new URL(import.meta.url), { workerData: { jobs: sl, cfg } });
    w.on('message', (m) => { rows.push(m); if (rows.length % 20 === 0) console.log(rows.length + '/' + jobs.length); });
    w.on('error', (e) => { console.error(e); process.exit(1); });
    w.on('exit', () => {
      if (--live) return;
      const order = (r) => [r.rule, r.params, r.market].join('|');
      rows.sort((a, b) => (order(a) < order(b) ? -1 : 1));
      const csv = [COLS.join(',')].concat(rows.map((r) => COLS.map((c) => { const v = fmt(r[c]); return /[,"]/.test(String(v)) ? `"${v}"` : v; }).join(','))).join('\n') + '\n';
      fs.mkdirSync(new URL('./results/', import.meta.url).pathname, { recursive: true });
      const out = PROBE ? new URL('./results/bid-rule-probes.csv', import.meta.url).pathname : OUT;
      fs.writeFileSync(out, csv);
      console.log('wrote', out, rows.length, 'rows');
    });
  }
}
