// ================================================================= page: controls and state
const REAL_VOL = [1557.1, 80.6, 41.9, 46.2, 57.1, 12.8, 27.8, 57.6, 11.8, 40.8, 5.3, 1.9, 2.6, 0.4];
const REAL_P = [0.03, 0.0303, 0.0262, 0.025, 0.026, 0.0247, 0.0275, 0.0284, 0.0269, 0.0123, 0.0095, 0.0082, 0.0085, 0.0118];
const $ = (id) => document.getElementById(id);
const el = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; };
const fmtAx = (v) => (v == null || !isFinite(v) ? 'n/a' : Math.abs(v) >= 1000 ? Math.round(v).toLocaleString('en-US') : String(+v.toPrecision(3)));
const fmtN = (x, d = 3) => (x == null || !isFinite(x) ? 'n/a' : Number.isInteger(x) ? x.toLocaleString('en-US') : Math.abs(x) >= 1000 ? Math.round(x).toLocaleString('en-US') : Math.abs(x) >= 100 ? x.toFixed(0) : Math.abs(x) >= 10 ? x.toFixed(1) : Math.abs(x) >= 1 ? x.toFixed(2) : x === 0 ? '0' : x.toPrecision(d));
const fmtSci = (x) => (x == null || !isFinite(x) ? 'n/a' : x === 0 ? '0' : x.toExponential(2).replace('e+', 'e'));

// the one mid run change: the setting, its unit and a sensible value to switch to
const CHG = {
  flatBps: { label: 'flatBps (share of the bid priced flat)', unit: 'bps, 0 to 10000', to: 5000 },
  reserveBps: { label: 'reserveBps (auction reserve over cost)', unit: 'bps, 3000 to 40000', to: 6000 },
  auctionDuration: { label: 'auctionDuration', unit: 'hours, 6 to 720', to: 6, hours: true },
  saleToBuybackBps: { label: 'saleToBuybackBps (proceeds to burn)', unit: 'bps, 0 to 10000', to: 2500 },
  dropBps: { label: 'dropBps', unit: 'bps, 500 to 5000', to: 5000 },
  climbBaseBps: { label: 'climbBaseBps', unit: 'bps an hour, 0 to 1000', to: 200 },
  spendCapBps: { label: 'spendCapBps', unit: 'bps an hour, 100 to 5000', to: 4000 },
  exitAfter: { label: 'exitAfter', unit: 'hours, 1 to 8760', to: 24, hours: true },
  rateCap: { label: 'rateCap (most the eth rate can be)', unit: 'wei per point, 1e11 to 1e15', to: 50000000000000 },
};
// every control: key in the state object, how to show it. launch values are the Core's (script/config/mainnet.json)
const BASE_STATE = { volPreset: 'comparable', volScale: 1, volTail: 17, volHalfLifeDays: 3, buyShareLate: 'auto', pricePath: 'flat', priceP0: 0.0089, wtpMult: 1, stmtPerDay: 8, impactElast: 0.12,
  openPct: 75, flatBps: 10000, reserveBps: 9000, auctionHours: 24, saleToBuybackBps: 5000, exitAfterH: 72, dropBps: 2000, climbBaseBps: 100, spendCapBps: 2000, rateCap: 123200000000000, fundedRule: 'built',
  chgOn: false, chgDay: 30, chgKey: 'flatBps', chgValue: 5000,
  phase2On: false, phase2Day: 14, xp: 2.5e-5, takerThreshold: 0.15, days: 90, seed: 7 };
const GROUPS = [
  { title: 'market', open: true, ctl: [
    { k: 'volPreset', t: 'select', label: 'coin volume preset', opts: [['comparable', 'comparable decay'], ['sustained17', 'sustained 17 eth a day'], ['sustained50', 'sustained 50 eth a day'], ['deadWeek1', 'dead after week one'], ['custom', 'custom']] },
    { k: 'volScale', t: 'range', label: 'volume scale', min: 0.05, max: 5, log: true, fmt: (v) => v.toFixed(2) + 'x', hint: 'multiplies every day, launch day included' },
    { k: 'volTail', t: 'range', label: 'custom: eth a day', min: 0.2, max: 200, log: true, fmt: (v) => fmtN(v), only: 'custom' },
    { k: 'volHalfLifeDays', t: 'range', label: 'custom: half life of day two volume, days', min: 0.5, max: 20, step: 0.5, fmt: (v) => v + 'd', only: 'custom' },
    { k: 'buyShareLate', t: 'select', label: 'net flow after day one', opts: [['auto', 'preset default'], [0.42, 'heavy selling, 0.42 buys'], [0.46, 'selling, 0.46'], [0.5, 'balanced, 0.50'], [0.54, 'buying, 0.54']] },
    { k: 'pricePath', t: 'select', label: 'credit price path', opts: [['flat', 'flat at today'], ['decline', 'continued decline'], ['recovery', 'recovery']] },
    { k: 'priceP0', t: 'range', label: 'flat credit price today, eth', min: 0.003, max: 0.04, log: true, fmt: (v) => v.toFixed(4), hint: 'median 0.0089 at the snapshot, was 0.03' },
    { k: 'impactElast', t: 'range', label: 'engine price impact on credits', min: 0, max: 0.5, step: 0.02, fmt: (v) => v.toFixed(2), hint: '0 means the engine never moves the market' },
    { k: 'wtpMult', t: 'range', label: 'statement buyer willingness to pay', min: 0.5, max: 1.6, step: 0.05, fmt: (v) => v.toFixed(2) + 'x', hint: '1.00x is the observed median 0.84 of parts cost' },
    { k: 'stmtPerDay', t: 'range', label: 'statement buyers a day at launch', min: 1, max: 40, step: 1, fmt: (v) => v.toFixed(0), hint: 'observed 4 to 13 a day, decays to 2' },
  ] },
  { title: 'launch settings', open: true, ctl: [
    { k: 'openPct', t: 'range', label: 'opening limit, percent of market', min: 20, max: 125, step: 5, fmt: (v) => v + '%', hint: 'rateStart, wei per point =', hintFn: (s) => fmtSci(rateOf(s)) },
    { k: 'flatBps', t: 'range', label: 'flatBps', min: 0, max: 10000, step: 500, fmt: (v) => v, hint: '10000 is flat per credit, 0 is per score point' },
    { k: 'reserveBps', t: 'range', label: 'reserveBps', min: 3000, max: 15000, step: 500, fmt: (v) => v, hint: 'auction reserve as bps of the statement cost' },
    { k: 'auctionHours', t: 'range', label: 'auctionDuration, hours', min: 6, max: 168, log: true, fmt: (v) => (+v).toFixed(v < 10 ? 1 : 0) + 'h', hint: 'runs from the first bid' },
    { k: 'saleToBuybackBps', t: 'range', label: 'saleToBuybackBps', min: 0, max: 10000, step: 500, fmt: (v) => v, hint: 'share of collected sale proceeds that buys and burns the coin' },
    { k: 'exitAfterH', t: 'range', label: 'exitAfter, hours', min: 1, max: 336, step: 6, fmt: (v) => v + 'h', hint: 'a listing with no bid may be redeemed in phase 2 after this' },
  ] },
  { title: 'engine settings', open: false, ctl: [
    { k: 'dropBps', t: 'range', label: 'dropBps', min: 500, max: 5000, step: 250, fmt: (v) => v },
    { k: 'climbBaseBps', t: 'range', label: 'climbBaseBps', min: 0, max: 800, step: 25, fmt: (v) => v },
    { k: 'spendCapBps', t: 'range', label: 'spendCapBps', min: 100, max: 5000, log: true, fmt: (v) => v },
    { k: 'rateCap', t: 'range', label: 'rateCap, wei per point', min: 3e13, max: 1e15, log: true, fmt: fmtSci, hint: 'the eth rate never passes it. launch 1.23e14, 8 times rateStart. the page keeps it at or above rateStart' },
    { k: 'fundedRule', t: 'select', label: 'funded rule', opts: [['built', 'as built: the hourly cap affords one average credit'], ['old', 'counterfactual: the pot affords one average credit']] },
  ] },
  { title: 'change a setting on day N', open: true, ctl: [
    { k: 'chgOn', t: 'check', label: 'the owner changes one setting' },
    { k: 'chgDay', t: 'range', label: 'on day', min: 1, max: 89, step: 1, fmt: (v) => 'day ' + v },
    { k: 'chgKey', t: 'select', label: 'setting', opts: Object.keys(CHG).map((k) => [k, CHG[k].label]) },
    { k: 'chgValue', t: 'number', label: 'new value', hint: 'unit:', hintFn: (s) => CHG[s.chgKey].unit },
  ] },
  { title: 'phase 2: exitModule and exitToken', open: false, ctl: [
    { k: 'phase2On', t: 'check', label: 'phase 2 switched on' },
    { k: 'phase2Day', t: 'range', label: 'on day', min: 1, max: 89, step: 1, fmt: (v) => 'day ' + v },
    { k: 'xp', t: 'range', label: 'exitToken price, eth per point of rating', min: 2e-6, max: 3e-4, log: true, fmt: fmtSci, hint: 'a statement of 35,000 points pays rating times this, about 1 eth at 3e-5' },
    { k: 'takerThreshold', t: 'range', label: 'exitToken auction taker discount', min: 0.02, max: 0.4, step: 0.01, fmt: (v) => (v * 100).toFixed(0) + '%', hint: 'discount to the pool price, skim included, that triggers a fill' },
  ] },
  { title: 'run', open: false, ctl: [
    { k: 'days', t: 'select', label: 'horizon', opts: [[30, '30 days'], [60, '60 days'], [90, '90 days'], [180, '180 days']] },
    { k: 'seed', t: 'number', label: 'seed' },
  ] },
];
const rateOf = (s) => (s.openPct / 100) * (s.priceP0 * 1e18) / 433;
let state = Object.assign({}, BASE_STATE);
const widgets = {};
const toSlider = (c, v) => (c.log ? (Math.log(v / c.min) / Math.log(c.max / c.min)) * 1000 : v);
const fromSlider = (c, s) => {
  if (c.log) { const v = c.min * Math.pow(c.max / c.min, s / 1000); return +v.toPrecision(3); }
  return +s;
};
function buildControls() {
  const root = $('ctlRoot');
  for (const g of GROUPS) {
    const d = el('details', 'grp'); d.open = g.open;
    d.appendChild(el('summary', null, g.title));
    const rows = el('div', 'rows');
    for (const c of g.ctl) {
      const w = el('div', 'ctl'); w.id = 'row-' + c.k;
      const lab = el('label', null, c.label); lab.htmlFor = 'c-' + c.k; w.appendChild(lab);
      let inp;
      if (c.t === 'range') {
        inp = el('input'); inp.type = 'range';
        inp.min = c.log ? 0 : c.min; inp.max = c.log ? 1000 : c.max; inp.step = c.log ? 1 : c.step;
        const val = el('span', 'val'); val.id = 'v-' + c.k; w.appendChild(val); c.valEl = val;
      } else if (c.t === 'select') {
        inp = el('select');
        for (const [v, t] of c.opts) { const o = el('option', null, t); o.value = String(v); inp.appendChild(o); }
      } else if (c.t === 'check') {
        inp = el('input'); inp.type = 'checkbox'; inp.style.justifySelf = 'end';
      } else { inp = el('input'); inp.type = 'number'; inp.step = 'any'; }
      inp.id = 'c-' + c.k; w.appendChild(inp); c.inp = inp;
      if (c.hint) { const h = el('div', 'hint', c.hint); c.hintEl = h; w.appendChild(h); }
      const onChange = () => {
        if (c.t === 'range') state[c.k] = fromSlider(c, inp.value);
        else if (c.t === 'check') state[c.k] = inp.checked;
        else if (c.t === 'number') state[c.k] = c.k === 'seed' ? (+inp.value || 0) : (inp.value === '' ? 0 : +inp.value);
        else { const o = c.opts.find((x) => String(x[0]) === inp.value); state[c.k] = o ? o[0] : inp.value; }
        if (c.k === 'chgKey') { const ch = CHG[state.chgKey]; state.chgValue = ch.to; }
        syncControls(); schedule();
      };
      inp.addEventListener('input', onChange);
      if (c.t === 'select' || c.t === 'check') inp.addEventListener('change', onChange);
      rows.appendChild(w); widgets[c.k] = c;
    }
    d.appendChild(rows); root.appendChild(d);
  }
}
// push state into the widgets and show or hide the conditional ones
function syncControls() {
  for (const k of Object.keys(widgets)) {
    const c = widgets[k], v = state[k];
    if (c.t === 'range') { c.inp.value = toSlider(c, v); c.valEl.textContent = c.fmt(v); }
    else if (c.t === 'check') c.inp.checked = !!v;
    else if (document.activeElement !== c.inp) c.inp.value = String(v);
    if (c.only) $('row-' + k).style.display = state.volPreset === c.only ? '' : 'none';
    if (k === 'phase2Day' || k === 'xp' || k === 'takerThreshold') $('row-' + k).style.opacity = state.phase2On ? 1 : 0.5;
    if (k === 'chgDay' || k === 'chgKey' || k === 'chgValue') $('row-' + k).style.opacity = state.chgOn ? 1 : 0.5;
    if (c.hintFn) c.hintEl.innerHTML = c.hint + ' <b>' + c.hintFn(state) + '</b>';
  }
}
// the page state as the engine's parameters. settings carry the Core's names
function toParams(s) {
  const p = {
    volPreset: s.volPreset, volScale: s.volScale, volTail: s.volTail, volHalfLifeDays: s.volHalfLifeDays, buyShareLate: s.buyShareLate === 'auto' ? null : +s.buyShareLate,
    pricePath: s.pricePath, priceP0: s.priceP0, wtpMult: s.wtpMult, stmtPerDay: s.stmtPerDay, impactElast: s.impactElast, rateStart: rateOf(s),
    flatBps: s.flatBps, reserveBps: s.reserveBps, auctionDuration: Math.round(s.auctionHours * 3600), saleToBuybackBps: s.saleToBuybackBps, exitAfter: s.exitAfterH * 3600,
    dropBps: s.dropBps, climbBaseBps: s.climbBaseBps, spendCapBps: s.spendCapBps, fundedRule: s.fundedRule,
    rateCap: Math.max(s.rateCap, rateOf(s)), // the Core refuses a deploy with rateStart above rateCap
    phase2Day: s.phase2On ? s.phase2Day : null, xp: s.xp, takerThreshold: s.takerThreshold, days: +s.days, seed: s.seed,
  };
  p.climbMaxBps = Math.max(p.climbBaseBps, 800);
  if (p.phase2Day != null && p.phase2Day >= p.days) p.phase2Day = null;
  p.schedule = [];
  if (s.chgOn && s.chgDay < p.days) {
    const ch = CHG[s.chgKey], patch = {};
    patch[s.chgKey] = ch.hours ? Math.round(s.chgValue * 3600) : s.chgValue;
    if (s.chgKey === 'climbBaseBps') patch.climbMaxBps = Math.max(s.chgValue, p.climbMaxBps);
    p.schedule.push({ day: s.chgDay, patch });
  }
  return p;
}
