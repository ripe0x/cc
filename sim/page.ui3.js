
// ================================================================= page: charts, verdict, table
const mark2 = () => { const p = toParams(state); return p.phase2Day != null ? [{ x: p.phase2Day, label: 'phase 2' }] : []; };
const CHART_SPECS = [
  { id: 'pot', title: 'eth pot, cumulative fees, eth locked in unsold statements', fmt: { l: fmtAx }, marks: mark2, series: [
    { label: 'eth pot', short: 'pot', color: '--s1', f: (r, h) => r.S.pot[h] },
    { label: 'cumulative fees', short: 'fees', color: '--s4', dash: true, f: (r, h) => r.S.cumFees[h] },
    { label: 'locked in unsold statements', short: 'locked', color: '--s2', f: (r, h) => r.S.locked[h] } ] },
  { id: 'rate', title: 'bid rate against market clearing rate, wei per point, and the score frontier', fmt: { l: fmtSci, r: (v) => v.toFixed(0) }, log: { l: true }, fixed: { r: [0, 900] }, marks: mark2, series: [
    { label: 'bid rate', short: 'bid', color: '--s1', f: (r, h) => r.S.rate[h] },
    { label: 'market price over 440 points', short: 'market', color: '--s4', dash: true, f: (r, h) => r.S.mktPerPoint[h] },
    { label: 'score frontier', short: 'frontier', color: '--s2', axis: 'r', f: (r, h) => r.S.frontier[h] } ] },
  { id: 'bought', title: 'credits bought and average score', fmt: { l: fmtAx, r: (v) => v.toFixed(0) }, fixed: { r: [0, 800] }, marks: mark2, series: [
    { label: 'credits bought', short: 'bought', color: '--s1', f: (r, h) => r.S.bought[h] },
    { label: 'average score, last 24h', short: 'avg24h', color: '--s2', axis: 'r', f: (r, h) => (r.S.avgScoreDay[h] || NaN) },
    { label: 'average score, cumulative', short: 'avgCum', color: '--s3', dash: true, axis: 'r', f: (r, h) => (r.S.avgScoreCum[h] || NaN) } ] },
  { id: 'stmts', title: 'statements composed, sold, held at the floor, exited', fmt: { l: fmtAx }, marks: mark2, series: [
    { label: 'composed', short: 'composed', color: '--s4', dash: true, f: (r, h) => r.S.composed[h] },
    { label: 'sold', short: 'sold', color: '--s3', f: (r, h) => r.S.sold[h] },
    { label: 'held at the floor', short: 'floor', color: '--s2', f: (r, h) => r.S.heldFloor[h] },
    { label: 'exited', short: 'exited', color: '--s1', f: (r, h) => r.S.exited[h] } ] },
  { id: 'burn', title: 'eth to buyback and coin burned', fmt: { l: fmtAx, r: (v) => v.toFixed(1) + '%' }, marks: mark2, series: [
    { label: 'eth sent to buyback', short: 'toBB', color: '--s4', dash: true, f: (r, h) => r.S.saleToBuyback[h] },
    { label: 'eth spent buying coin', short: 'spent', color: '--s1', f: (r, h) => r.S.buybackSpent[h] },
    { label: 'coin burned, percent of supply', short: 'burned', color: '--s2', axis: 'r', f: (r, h) => r.S.burnedPct[h] } ] },
  { id: 'price', title: 'coin price, eth per coin', fmt: { l: fmtSci }, log: { l: true }, marks: mark2, series: [
    { label: 'pool price', short: 'price', color: '--s1', f: (r, h) => r.S.coinPrice[h] } ] },
  { id: 'x', title: 'phase 2: exit bid in bps of score, pots in eth value of exitToken', fmt: { l: fmtAx, r: (v) => v.toFixed(0) }, fixed: { r: [0, 10000] }, marks: mark2, series: [
    { label: 'exit bid pot', short: 'xPot', color: '--s3', f: (r, h) => r.S.xPot[h] },
    { label: 'waiting for the dutch auction', short: 'xToBB', color: '--s2', dash: true, f: (r, h) => r.S.xToBuyback[h] },
    { label: 'exit bid rate', short: 'xRate', color: '--s1', axis: 'r', f: (r, h) => (r.S.xRate[h] || NaN) } ] },
];
let lastRes = null;
function renderVerdict(res, ms) {
  const p = res.params, days = res.H / 24, a = res.at(days), st = res.stats, T = res.T;
  const composed = a.composed + T.composedX * 0, soldShare = a.composed ? a.sold / a.composed : 0, lockShare = a.cumFees ? a.locked / a.cumFees : 0;
  const exitedShare = a.composed ? T.exited / a.composed : 0;
  const turns = soldShare + exitedShare >= 0.6 && lockShare < 0.25;
  const mid = (soldShare + exitedShare >= 0.3 && lockShare < 0.5) || (T.exited > 0 && lockShare < 0.1);
  const cls = turns ? 'good' : mid ? 'warn' : 'bad';
  $('verdict').className = 'verdict ' + cls;
  $('v1').textContent = (turns ? 'the loop turns' : mid ? 'the loop turns partly' : 'the loop stalls') + ': ' + fmtN(a.sold) + ' of ' + fmtN(a.composed) + ' statements sold' + (T.exited ? ', ' + fmtN(T.exited) + ' exited' : '') + ', ' + fmtN(a.heldFloor) + ' stuck at the floor, ' + fmtN(a.locked) + ' eth locked, ' + a.burnedPct.toFixed(1) + '% of supply burned by day ' + days;
  const dry = (() => { for (let h = 48; h <= res.H; h++) if (res.S.pot[h] < 1 && res.S.cumFees[h] > 20) return (h / 24).toFixed(0); return null; })();
  $('v2').textContent = 'fees in ' + fmtN(a.cumFees) + ' eth. credits cost ' + st.costVsMarket.toFixed(2) + 'x the flat market price on average, average score bought ' + st.avgScoreBought.toFixed(0) + ' against 440 in the population. ' + fmtN(st.stmtArrivals - st.stmtMiss) + ' of ' + fmtN(st.stmtArrivals) + ' statement buyers found a price they accept. ' + (dry ? 'the pot is under 1 eth from day ' + dry + '.' : 'the pot stays above 1 eth.');
  $('runinfo').textContent = 'ran ' + Math.round(ms) + ' ms, ' + res.H + ' hours, seed ' + p.seed;
}
function renderTable(res) {
  const days = res.H / 24, ds = [30, 60, 90, 180].filter((d) => d <= days);
  if (!ds.length || ds[ds.length - 1] !== days) ds.push(days);
  const cols = [['day', (a) => a.day], ['fees in, eth', (a) => fmtN(a.cumFees)], ['credits bought', (a) => fmtN(a.bought)], ['composed', (a) => fmtN(a.composed)], ['sold', (a) => fmtN(a.sold)],
    ['stuck at floor', (a) => fmtN(a.heldFloor)], ['eth locked', (a) => fmtN(a.locked)], ['returned to pot', (a) => fmtN(a.saleToPot)], ['to buyback', (a) => fmtN(a.saleToBuyback)],
    ['coin burned, m', (a) => fmtN(a.burned / 1e6)], ['percent of supply', (a) => a.burnedPct.toFixed(2) + '%'], ['pot now', (a) => fmtN(a.pot)]];
  let h = '<thead><tr>' + cols.map((c) => '<th>' + c[0] + '</th>').join('') + '</tr></thead><tbody>';
  for (const d of ds) { const a = res.at(d); h += '<tr>' + cols.map((c) => '<td>' + c[1](a) + '</td>').join('') + '</tr>'; }
  $('tbl').innerHTML = h + '</tbody>';
  const st = res.stats, T = res.T;
  const notes = [
    '<b>cost per credit</b> ' + st.costVsMarket.toFixed(2) + 'x the flat price, per point ' + st.costPerPointVsMarket.toFixed(2) + 'x the market per point, ' + st.costVsAsk.toFixed(2) + 'x what sellers asked',
    '<b>first fill</b> hour ' + (st.firstFillHour < 0 ? 'none' : st.firstFillHour.toFixed(1)) + (st.first80 ? ', first 80 credits cost ' + st.first80.ratio.toFixed(2) + 'x market at score ' + st.first80.avgScore.toFixed(0) : ''),
    '<b>hourly cap</b> blocked a sale in ' + fmtN(st.capSteps) + ' hours, ' + fmtN(st.capStepsRich) + ' of them with the pot above 5 eth; climb clamp active ' + fmtN(st.clampSteps) + ' hours',
    '<b>bid</b> peaked at ' + st.rateMaxBidRatio.toFixed(2) + 'x the market rate for a 440 point credit',
  ];
  if (T.xFills || T.boughtX) notes.push('<b>phase 2</b> exit bid bought ' + fmtN(T.boughtX) + ' credits, ' + fmtN(T.exited + T.exitedX) + ' statements exited, ' + fmtN(T.xFills) + ' dutch fills at ' + (st.xMeanDiscount * 100).toFixed(0) + '% all in discount, one every ' + st.xMedianIntervalH.toFixed(1) + ' h');
  $('notes').innerHTML = notes.join(' &nbsp; ');
  $('tblnote').textContent = 'engine eth accounting closes to ' + Math.abs(st.potCheck).toExponential(1) + ' eth';
}
function run() {
  const t = performance.now();
  const res = simulate(toParams(state));
  const ms = performance.now() - t;
  lastRes = res;
  renderVerdict(res, ms); renderTable(res);
  for (const ch of charts) {
    if (ch.spec.id === 'x') ch.ro.dataset.idle = res.params.phase2Day == null ? 'phase 2 is off, switch it on in the controls' : 'move over the chart for values';
    setChartData(ch, res);
  }
  setCalData();
}
let timer = null;
function schedule() { clearTimeout(timer); timer = setTimeout(run, 140); }
