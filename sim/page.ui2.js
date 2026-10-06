
// ================================================================= page: charts drawn on canvas
const cssVar = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
function niceTicks(lo, hi, n) {
  const span = hi - lo || 1, raw = span / n, mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const f = raw / mag, step = (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * mag;
  const out = [];
  for (let v = Math.ceil(lo / step) * step; v <= hi + step * 1e-9; v += step) out.push(+v.toPrecision(12));
  return out;
}
function logTicks(lo, hi) {
  const out = [];
  for (let e = Math.floor(Math.log10(lo)); e <= Math.ceil(Math.log10(hi)); e++) { const v = Math.pow(10, e); if (v >= lo * 0.999 && v <= hi * 1.001) out.push(v); }
  return out;
}
const charts = [];
function mkChart(spec) {
  const box = el('div', 'chart');
  box.appendChild(el('h3', null, '<span>' + spec.title + '</span>'));
  const lg = el('div', 'legend');
  for (const s of spec.series) lg.appendChild(el('span', null, '<i style="border-color:var(' + s.color + ');' + (s.dash ? 'border-top-style:dashed' : '') + '"></i>' + s.label + (s.axis === 'r' ? ' (right)' : '')));
  box.appendChild(lg);
  const cv = el('canvas'); cv.id = 'chart-' + spec.id; cv.setAttribute('role', 'img'); cv.setAttribute('aria-label', spec.title);
  box.appendChild(cv);
  const ro = el('div', 'readout', 'move over the chart for values'); ro.id = 'readout-' + spec.id; box.appendChild(ro);
  $('charts').appendChild(box);
  const ch = { spec, cv, ro, hover: -1, xs: [], data: [] };
  cv.addEventListener('pointermove', (e) => { const r = cv.getBoundingClientRect(); ch.hover = (e.clientX - r.left) / r.width; paint(ch); });
  cv.addEventListener('pointerleave', () => { ch.hover = -1; paint(ch); });
  charts.push(ch);
  return ch;
}
function paint(ch) {
  const { cv, spec } = ch, xs = ch.xs;
  const dpr = window.devicePixelRatio || 1, W0 = cv.clientWidth || 300, H0 = cv.clientHeight || 200;
  if (cv.width !== Math.round(W0 * dpr) || cv.height !== Math.round(H0 * dpr)) { cv.width = Math.round(W0 * dpr); cv.height = Math.round(H0 * dpr); }
  const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W0, H0);
  const muted = cssVar('--muted'), grid = cssVar('--grid'), ink = cssVar('--ink');
  const hasR = spec.series.some((s) => s.axis === 'r');
  const m = { l: 54, r: hasR ? 50 : 10, t: 8, b: 20 }, pw = W0 - m.l - m.r, ph = H0 - m.t - m.b;
  const xmax = xs.length ? xs[xs.length - 1] : 1;
  const X = (x) => m.l + (x / xmax) * pw;
  const dom = {};
  for (const ax of ['l', 'r']) {
    const ss = spec.series.filter((s) => (s.axis || 'l') === ax); if (!ss.length) continue;
    const log = !!(spec.log && spec.log[ax]);
    let lo = Infinity, hi = -Infinity;
    for (const s of ss) for (const v of ch.data[spec.series.indexOf(s)]) { if (!isFinite(v) || (log && v <= 0)) continue; lo = Math.min(lo, v); hi = Math.max(hi, v); }
    if (!isFinite(lo)) { lo = log ? 1 : 0; hi = log ? 10 : 1; }
    if (spec.fixed && spec.fixed[ax]) { lo = spec.fixed[ax][0]; hi = spec.fixed[ax][1]; }
    else if (log) { lo = Math.pow(10, Math.floor(Math.log10(lo))); hi = Math.pow(10, Math.ceil(Math.log10(hi))); if (hi <= lo) hi = lo * 10; }
    else { lo = Math.min(lo, 0); if (hi <= lo) hi = lo + 1; hi *= 1.05; }
    const f = log ? (v) => (Math.log10(Math.max(v, lo)) - Math.log10(lo)) / (Math.log10(hi) - Math.log10(lo)) : (v) => (v - lo) / (hi - lo);
    dom[ax] = { lo, hi, log, Y: (v) => m.t + ph - f(v) * ph, ticks: log ? logTicks(lo, hi) : niceTicks(lo, hi, 4) };
  }
  g.font = '10px ' + cssVar('--mono'); g.textBaseline = 'middle';
  g.lineWidth = 1;
  const dl = dom.l || dom.r;
  for (const v of dl.ticks) { const y = Math.round(dl.Y(v)) + 0.5; g.strokeStyle = grid; g.beginPath(); g.moveTo(m.l, y); g.lineTo(W0 - m.r, y); g.stroke(); }
  g.fillStyle = muted; g.textAlign = 'right';
  if (dom.l) for (const v of dom.l.ticks) g.fillText(spec.fmt.l(v), m.l - 5, dom.l.Y(v));
  g.textAlign = 'left';
  if (dom.r) for (const v of dom.r.ticks) g.fillText(spec.fmt.r(v), W0 - m.r + 5, dom.r.Y(v));
  g.textAlign = 'center'; g.textBaseline = 'top';
  const step = xmax > 120 ? 30 : xmax > 45 ? 10 : 5;
  for (let d = 0; d <= xmax + 1e-9; d += step) { const x = X(d); g.fillText(d + 'd', Math.min(Math.max(x, 8), W0 - 8), H0 - m.b + 5); g.strokeStyle = grid; g.beginPath(); g.moveTo(Math.round(x) + 0.5, m.t + ph); g.lineTo(Math.round(x) + 0.5, m.t + ph + 3); g.stroke(); }
  g.save(); g.beginPath(); g.rect(m.l, m.t, pw, ph); g.clip();
  spec.series.forEach((s, i) => {
    const d = dom[s.axis || 'l']; if (!d) return;
    g.strokeStyle = cssVar(s.color); g.lineWidth = 1.6; g.setLineDash(s.dash ? [5, 3] : []);
    g.beginPath(); let pen = false;
    ch.data[i].forEach((v, j) => {
      if (!isFinite(v) || (d.log && v <= 0)) { pen = false; return; }
      const x = X(xs[j]), y = d.Y(v);
      if (!pen) { g.moveTo(x, y); pen = true; } else g.lineTo(x, y);
    });
    g.stroke();
  });
  g.restore(); g.setLineDash([]);
  if (spec.marks) for (const mk of spec.marks(ch)) { g.strokeStyle = cssVar('--muted'); g.setLineDash([2, 3]); const x = Math.round(X(mk.x)) + 0.5; g.beginPath(); g.moveTo(x, m.t); g.lineTo(x, m.t + ph); g.stroke(); g.setLineDash([]); g.textAlign = 'left'; g.fillStyle = muted; g.fillText(mk.label, x + 3, m.t + 2); }
  if (ch.hover >= 0 && xs.length) {
    const fx = Math.min(1, Math.max(0, (ch.hover * W0 - m.l) / pw)) * xmax;
    let j = 0; while (j < xs.length - 1 && xs[j + 1] <= fx) j++;
    if (j < xs.length - 1 && fx - xs[j] > xs[j + 1] - fx) j++;
    const x = Math.round(X(xs[j])) + 0.5; g.strokeStyle = ink; g.globalAlpha = 0.5; g.beginPath(); g.moveTo(x, m.t); g.lineTo(x, m.t + ph); g.stroke(); g.globalAlpha = 1;
    ch.ro.textContent = 'day ' + xs[j].toFixed(1) + '  ' + spec.series.map((s, i) => s.short + ' ' + (spec.fmt[s.axis || 'l'])(ch.data[i][j])).join('  ');
  } else ch.ro.textContent = ch.ro.dataset.idle || 'move over the chart for values';
}
function setChartData(ch, res) {
  const H = res.H, step = Math.max(1, Math.ceil(H / 540)), idx = [];
  for (let h = 0; h <= H; h += h < 48 ? 1 : step) idx.push(h);
  if (idx[idx.length - 1] !== H) idx.push(H);
  ch.xs = idx.map((h) => h / 24);
  ch.data = ch.spec.series.map((s) => idx.map((h) => s.f(res, h)));
  paint(ch);
}
const redrawAll = () => { charts.forEach(paint); if (calCh) paint(calCh); };
