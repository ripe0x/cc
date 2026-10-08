// stall study for the stepped bid rule at one minute steps. usage: node study-stalls.mjs --phase 1|2 [--base A|B --loosen 1] [--seeds 1,2,3]
// phase 1: idle loosening of the ceiling anchor against gap up paths and the runaway bid. phase 2: the stall hunt on the chosen setting.
// writes results/bid-rule-stalls.csv (phase 2 keeps the phase 1 rows). stall = the pot affords the cheapest ask and the engine buys nothing for more than 2 hours.
import fs from 'node:fs';
import os from 'node:os';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { simulate, W } from './engine.js';

const arg = (k, d) => { const i = process.argv.indexOf('--' + k); return i > 0 ? process.argv[i + 1] : d; };
const cfg = isMainThread ? { seeds: arg('seeds', '1,2,3').split(',').map(Number), phase: +arg('phase', 1), base: arg('base', 'A'), loosen: +arg('loosen', 1) } : workerData.cfg;
const OUT = new URL('./results/bid-rule-stalls.csv', import.meta.url).pathname;
const COLS = ['scenario', 'setting', 'trigger', 'first_fill_min', 'recover_min', 'credits_24h_after', 'paid_vs_market_24h', 'credits_per_day', 'credits_day90', 'paid_vs_market',
  'max_bid_over_market', 'stall_hours', 'stall_hours_max', 'gap_hours_max', 'rate_cap_hours', 'gate_closed_hours', 'first_stall_start_h',
  'stall_low_clamp_h', 'stall_low_ceiling_h', 'stall_low_ratecap_h', 'stall_low_climbing_h', 'stall_room_h', 'stall_other_h'];

const rateAt = (share, price = 0.0089) => (share * price * W) / 433;
const BASES = { A: { dropPerCreditPct: 1, climbPerMin: 1, ceilPct: 110 }, B: { dropPerCreditPct: 0.5, climbPerMin: 0.5, ceilPct: 125 } };
// stepped settings with the clamp for 20 credits (clampCredits) and idle loosening of L percent per 10 minutes
const stepped = (base, loosen, extra = {}, price = 0.0089) => Object.assign({ bidRule: 'stepped', rateStart: rateAt(1, price), dropToPct: 80, clampCredits: 20, idleLoosenPct: loosen, idleLoosenMin: 10 }, BASES[base], extra);
const label = (base, loosen, clamp = 20) => `stepped ${base} loosen ${loosen}/10min clamp ${clamp}`;

function runSeed(job, seed) {
  const o = Object.assign({ days: job.days, stepSec: 60, seed }, job.over);
  const E = job.event == null ? null : job.event * 3600;
  let first = null, recover = null, prev = 0;
  o.onStep = (t, core, Pe, rate, T) => {
    const n = T.bought + T.boughtX;
    if (E != null && t >= E) {
      if (first == null && n > prev) first = (t - E) / 60;
      if (recover == null && t > E && (core.epts(440) * rate) / (Pe * W) >= 0.9) recover = (t - E) / 60;
    }
    prev = n;
  };
  const r = simulate(o), S = r.S, st = r.stats, H = r.H;
  const m = {
    first_fill_min: first == null ? NaN : first, recover_min: recover == null ? NaN : recover,
    credits_per_day: S.credits[H] / (H / 24), credits_day90: S.credits[H], paid_vs_market: st.costVsMarket, max_bid_over_market: st.rateMaxBidRatio,
    stall_hours: st.stallHours, stall_hours_max: st.stallHoursMax, gap_hours_max: st.gapHoursMax, rate_cap_hours: st.rateCapHours, gate_closed_hours: st.gateClosedHours,
    first_stall_start_h: st.stallRuns.length ? st.stallRuns[0][0] / 3600 : NaN,
  };
  for (const k of ['low_clamp', 'low_ceiling', 'low_ratecap', 'low_climbing', 'room', 'other']) m['stall_' + k + '_h'] = st.stallCauseHours[k === 'low_ratecap' ? 'low_rateCap' : k] || 0;
  if (E != null) {
    const h0 = job.event, h1 = Math.min(H, h0 + 24);
    m.credits_24h_after = S.credits[h1] - S.credits[h0];
    m.paid_vs_market_24h = (S.cumCost[h1] - S.cumCost[h0]) / (S.cumMkt[h1] - S.cumMkt[h0]);
  } else { m.credits_24h_after = NaN; m.paid_vs_market_24h = NaN; }
  return m;
}
function runJob(job) {
  const ms = cfg.seeds.map((s) => runSeed(job, s));
  const out = { scenario: job.scenario, setting: job.setting, trigger: job.trigger };
  for (const k of COLS.slice(3)) {
    const v = ms.map((x) => x[k]).filter((x) => Number.isFinite(x));
    // a metric that is NaN in some seeds (event never happened) is reported as NaN unless all seeds have it
    out[k] = v.length < ms.length ? NaN : /^(max_|stall_hours_max|gap_hours_max)/.test(k) ? Math.max(...v) : v.reduce((a, b) => a + b, 0) / v.length;
  }
  return out;
}

function jobsPhase1() {
  const jobs = [];
  for (const base of ['A', 'B']) for (const L of [0, 0.5, 1, 2]) {
    for (const g of [13, 30, 100, 300]) jobs.push({ scenario: 'a_gap_up', setting: label(base, L), trigger: `market jumps ${g}% at hour 6`, days: 3, event: 6, over: stepped(base, L, { pricePath: 'gap', gapPct: g, gapHour: 6 }) });
    for (const m of ['flat', 'falling']) jobs.push({ scenario: 'runaway_90d', setting: label(base, L), trigger: m + ' market 90 days', days: 90, over: stepped(base, L, { pricePath: m }) });
  }
  return jobs;
}
function jobsPhase2(base, L) {
  const jobs = [];
  const S = label(base, L);
  for (const g of [13, 30, 100, 300]) jobs.push({ scenario: 'a_gap_up', setting: S, trigger: `market jumps ${g}% at hour 6`, days: 3, event: 6, over: stepped(base, L, { pricePath: 'gap', gapPct: g, gapHour: 6 }) });
  for (const loosen of [0, L]) for (const frac of [0.5, 0.3]) {
    jobs.push({ scenario: 'b_cheap_fill', setting: label(base, loosen), trigger: `one forced fill at ${frac}x market at hour 6, then flat`, days: 3, event: 6, over: stepped(base, loosen, { forceFillHour: 6, forceFillFrac: frac }) });
  }
  for (const pot of [0.1, 0.25, 0.5, 1, 2, 5, 10, 20]) for (const N of [1, 5, 20, 80]) {
    jobs.push({ scenario: 'c_small_pot', setting: label(base, L, N), trigger: `pot held at ${pot} eth, market 0.03`, days: 20,
      over: stepped(base, L, { priceP0: 0.03, rateStart: rateAt(1, 0.03), volScale: 0, strategyOn: false, holdPot: pot, clampCredits: N }, 0.03) });
  }
  // the CreditStrategy listings are priced in eth and do not follow the market, so they are switched off to test rateCap; the strategy rows show the effect of leaving them on
  for (const strat of [false, true]) for (const g of [700, 1500, 3000]) {
    jobs.push({ scenario: 'd_rate_cap', setting: S, trigger: `market jumps ${g}% at hour 6 (${1 + g / 100}x), strategy listings ${strat ? 'on' : 'off'}`, days: 5, event: 6, over: stepped(base, L, { pricePath: 'gap', gapPct: g, gapHour: 6, strategyOn: strat }) });
  }
  for (const pot of [5, 20, 50]) for (const bot of [false, true]) {
    jobs.push({ scenario: 'e_cap_bot', setting: S, trigger: `pot held at ${pot} eth, bot drains the hourly cap at each hour start: ${bot}`, days: 5,
      over: stepped(base, L, { volScale: 0, strategyOn: false, holdPot: pot, botDrain: bot }) });
  }
  for (const m of ['flat', 'falling', 'rising', 'thin', 'whipsaw']) {
    jobs.push({ scenario: 'f_markets_90d', setting: S, trigger: m + ' market 90 days', days: 90, over: stepped(base, L, m === 'thin' ? { offersPerHour: 37.5 } : { pricePath: m }) });
  }
  for (const N of [1, 5, 80]) jobs.push({ scenario: 'f_markets_90d', setting: label(base, L, N), trigger: 'flat market 90 days', days: 90, over: stepped(base, L, { clampCredits: N }) });
  return jobs;
}

if (!isMainThread) {
  for (const job of workerData.jobs) parentPort.postMessage(runJob(job));
} else {
  const fmt = (x) => (typeof x === 'number' ? (Number.isFinite(x) ? +x.toPrecision(5) : '') : x);
  const only = arg('only', '');
  const jobs = (cfg.phase === 1 ? jobsPhase1() : jobsPhase2(cfg.base, cfg.loosen)).filter((j) => j.scenario.startsWith(only));
  const rows = [];
  if (cfg.phase >= 2) {
    const mine = new Set(jobs.map((j) => j.scenario));
    const [, ...lines] = fs.readFileSync(OUT, 'utf8').trim().split('\n');
    for (const l of lines) { const sc = l.split(',')[0]; if (!mine.has(sc) || (sc === 'a_gap_up' && !l.includes(label(cfg.base, cfg.loosen)))) rows.push(l); }
  }
  const nW = Math.max(1, Math.min(os.availableParallelism() - 2, jobs.length));
  const slices = Array.from({ length: nW }, () => []);
  jobs.sort((a, b) => b.days - a.days);
  jobs.forEach((j, i) => slices[i % nW].push(j));
  const done = [];
  let live = nW;
  console.log(`${jobs.length} jobs x ${cfg.seeds.length} seeds, ${nW} workers`);
  for (const sl of slices) {
    const w = new Worker(new URL(import.meta.url), { workerData: { jobs: sl, cfg } });
    w.on('message', (m) => { done.push(m); if (done.length % 10 === 0) console.log(done.length + '/' + jobs.length); });
    w.on('error', (e) => { console.error(e); process.exit(1); });
    w.on('exit', () => {
      if (--live) return;
      done.sort((a, b) => ([a.scenario, a.trigger, a.setting].join('|') < [b.scenario, b.trigger, b.setting].join('|') ? -1 : 1));
      const q = (v) => (/[,"]/.test(String(v)) ? `"${v}"` : v);
      const lines = rows.concat(done.map((r) => COLS.map((c) => q(fmt(r[c]))).join(',')));
      fs.writeFileSync(OUT, [COLS.join(',')].concat(lines).join('\n') + '\n');
      console.log('wrote', OUT, lines.length, 'rows');
    });
  }
}
