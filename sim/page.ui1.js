
// ================================================================= page: controls and state
const REAL_VOL = [1557.1, 80.6, 41.9, 46.2, 57.1, 12.8, 27.8, 57.6, 11.8, 40.8, 5.3, 1.9, 2.6, 0.4];
const REAL_P = [0.03, 0.0303, 0.0262, 0.025, 0.026, 0.0247, 0.0275, 0.0284, 0.0269, 0.0123, 0.0095, 0.0082, 0.0085, 0.0118];
const $ = (id) => document.getElementById(id);
const el = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; };
const fmtAx = (v) => (v == null || !isFinite(v) ? 'n/a' : Math.abs(v) >= 1000 ? Math.round(v).toLocaleString('en-US') : String(+v.toPrecision(3)));
const fmtN = (x, d = 3) => (x == null || !isFinite(x) ? 'n/a' : Number.isInteger(x) ? x.toLocaleString('en-US') : Math.abs(x) >= 1000 ? Math.round(x).toLocaleString('en-US') : Math.abs(x) >= 100 ? x.toFixed(0) : Math.abs(x) >= 10 ? x.toFixed(1) : Math.abs(x) >= 1 ? x.toFixed(2) : x === 0 ? '0' : x.toPrecision(d));
const fmtSci = (x) => (x == null || !isFinite(x) ? 'n/a' : x === 0 ? '0' : x.toExponential(2).replace('e+', 'e'));

// every control: key in the params object, how to show it
const BASE_STATE = { volPreset: 'comparable', volScale: 1, volTail: 17, volHalfLifeDays: 3, buyShareLate: 'auto', pricePath: 'flat', priceP0: 0.0089, wtpMult: 1, stmtPerDay: 8, impactElast: 0.12,
  rateStart: 4e12, startX: 4, floorX: 1.2, lengthH: 72, fundedRule: 'new', CLIMB_BASE_BPS_PER_HOUR: 100, DROP_BPS: 1000, SPEND_CAP_BPS_PER_HOUR: 2000, bidMode: 'perPoint', inventoryGate: 0,
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
    { k: 'stmtPerDay', t: 'range', label: 'statement buyers a day at launch', min: 1, max: 40, step: 1, fmt: (v) => v.toFixed(0), hint: 'observed 4 to 13 a day, decays' },
  ] },
  { title: 'launch config', open: true, ctl: [
    { k: 'rateStart', t: 'range', label: 'rateStart, wei per point', min: 1e11, max: 1e14, log: true, fmt: fmtSci, hint: 'rule: price per credit in wei over 1600 =', hintFn: (s) => fmtSci((s.priceP0 * 1e18) / 1600) },
  ] },
  { title: 'engine constants', open: false, ctl: [
    { k: 'startX', t: 'range', label: 'AUCTION_START_X', min: 1.5, max: 4, step: 0.25, fmt: (v) => v.toFixed(2) + 'x' },
    { k: 'floorX', t: 'range', label: 'AUCTION_FLOOR_X', min: 0.5, max: 1.4, step: 0.05, fmt: (v) => v.toFixed(2) + 'x' },
    { k: 'lengthH', t: 'range', label: 'AUCTION_LENGTH, hours', min: 12, max: 336, step: 12, fmt: (v) => v + 'h' },
    { k: 'fundedRule', t: 'select', label: 'funded rule', opts: [['new', 'new: 20 percent of pot affords one average credit'], ['old', 'old: pot affords one average credit']] },
    { k: 'CLIMB_BASE_BPS_PER_HOUR', t: 'range', label: 'CLIMB_BASE_BPS_PER_HOUR', min: 25, max: 400, step: 25, fmt: (v) => v },
    { k: 'DROP_BPS', t: 'range', label: 'DROP_BPS', min: 250, max: 4000, step: 250, fmt: (v) => v },
    { k: 'SPEND_CAP_BPS_PER_HOUR', t: 'range', label: 'SPEND_CAP_BPS_PER_HOUR', min: 500, max: 5000, step: 250, fmt: (v) => v },
    { k: 'bidMode', t: 'select', label: 'bid shape', opts: [['perPoint', 'per point, as in the Core'], ['flat', 'flat per credit (design change)']] },
    { k: 'inventoryGate', t: 'range', label: 'inventory gate, design change', min: 0, max: 100, step: 5, fmt: (v) => (v === 0 ? 'off' : v + ' unsold'), hint: 'stop buying while this many statements are unsold. off is the Core' },
  ] },
  { title: 'phase 2: exitModule and exitToken', open: false, ctl: [
    { k: 'phase2On', t: 'check', label: 'phase 2 switched on' },
    { k: 'phase2Day', t: 'range', label: 'on day', min: 1, max: 89, step: 1, fmt: (v) => 'day ' + v },
    { k: 'xp', t: 'range', label: 'exitToken price, eth per point of rating', min: 2e-6, max: 3e-4, log: true, fmt: fmtSci, hint: 'floor sale beats exit when this is under 1.2 x cost / rating' },
    { k: 'takerThreshold', t: 'range', label: 'dutch auction taker threshold', min: 0.02, max: 0.4, step: 0.01, fmt: (v) => (v * 100).toFixed(0) + '%', hint: 'discount to the pool price, skim included, that triggers a fill' },
  ] },
  { title: 'run', open: false, ctl: [
    { k: 'days', t: 'select', label: 'horizon', opts: [[30, '30 days'], [60, '60 days'], [90, '90 days'], [180, '180 days']] },
    { k: 'seed', t: 'number', label: 'seed' },
  ] },
];
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
      } else { inp = el('input'); inp.type = 'number'; inp.step = 1; }
      inp.id = 'c-' + c.k; w.appendChild(inp); c.inp = inp;
      if (c.hint) { const h = el('div', 'hint', c.hint); c.hintEl = h; w.appendChild(h); }
      const onChange = () => {
        if (c.t === 'range') state[c.k] = fromSlider(c, inp.value);
        else if (c.t === 'check') state[c.k] = inp.checked;
        else if (c.t === 'number') state[c.k] = +inp.value || 0;
        else { const o = c.opts.find((x) => String(x[0]) === inp.value); state[c.k] = o ? o[0] : inp.value; }
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
    else c.inp.value = String(v);
    if (c.only) $('row-' + k).style.display = state.volPreset === c.only ? '' : 'none';
    if (k === 'phase2Day' || k === 'xp' || k === 'takerThreshold') $('row-' + k).style.opacity = state.phase2On ? 1 : 0.5;
    if (c.hintFn) c.hintEl.innerHTML = c.hint + ' <b>' + c.hintFn(state) + '</b>';
  }
}
function toParams(s) {
  const p = {
    volPreset: s.volPreset, volScale: s.volScale, volTail: s.volTail, volHalfLifeDays: s.volHalfLifeDays, buyShareLate: s.buyShareLate === 'auto' ? null : +s.buyShareLate,
    pricePath: s.pricePath, priceP0: s.priceP0, wtpMult: s.wtpMult, stmtPerDay: s.stmtPerDay, impactElast: s.impactElast, rateStart: s.rateStart,
    AUCTION_START_X: Math.round(s.startX * 1e4), AUCTION_FLOOR_X: Math.round(Math.min(s.floorX, s.startX) * 1e4), AUCTION_LENGTH: s.lengthH * 3600,
    fundedRule: s.fundedRule, CLIMB_BASE_BPS_PER_HOUR: s.CLIMB_BASE_BPS_PER_HOUR, DROP_BPS: s.DROP_BPS, SPEND_CAP_BPS_PER_HOUR: s.SPEND_CAP_BPS_PER_HOUR,
    bidMode: s.bidMode, inventoryGate: s.inventoryGate, phase2Day: s.phase2On ? s.phase2Day : null, xp: s.xp, takerThreshold: s.takerThreshold, days: +s.days, seed: s.seed,
  };
  if (p.phase2Day != null && p.phase2Day >= p.days) p.phase2Day = null;
  return p;
}
