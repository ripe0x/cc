
// ================================================================= page: calibration, scenarios, theme, start
const SCENARIOS = [
  { id: 'sc-base', label: 'as launched', set: {} },
  { id: 'sc-open100', label: 'opening limit 100%', set: { openPct: 100 } },
  { id: 'sc-open40', label: 'opening limit 40%', set: { openPct: 40 } },
  { id: 'sc-flat30', label: 'blend half per point on day 30', set: { chgOn: true, chgDay: 30, chgKey: 'flatBps', chgValue: 5000 } },
  { id: 'sc-perpoint', label: 'per point bid from day 0', set: { flatBps: 0 } },
  { id: 'sc-res14', label: 'reserve 60% on day 14', set: { chgOn: true, chgDay: 14, chgKey: 'reserveBps', chgValue: 6000 } },
  { id: 'sc-res60', label: 'reserve 60% from launch', set: { reserveBps: 6000 } },
  { id: 'sc-burn100', label: 'all proceeds to burn', set: { saleToBuybackBps: 10000 } },
  { id: 'sc-burn0', label: 'no proceeds to burn', set: { saleToBuybackBps: 0 } },
  { id: 'sc-s17', label: 'sustained 17 eth a day', set: { volPreset: 'sustained17' } },
  { id: 'sc-dead', label: 'dead after week one', set: { volPreset: 'deadWeek1' } },
  { id: 'sc-recov', label: 'credit price recovery', set: { pricePath: 'recovery' } },
  { id: 'sc-p2', label: 'phase 2 on day 30', set: { phase2On: true, phase2Day: 30, xp: 2e-5 } },
  { id: 'sc-noimp', label: 'engine never moves the market', set: { impactElast: 0 } },
];
function applyScenario(sc) { state = Object.assign({}, BASE_STATE, sc.set); syncControls(); run(); }
let calCh = null;
function modelVolume(p, d) { return dayVolume(p, d) * p.volScale; }
function setCalData() {
  const p = Object.assign({}, DEFAULTS, toParams(state));
  calCh.xs = REAL_VOL.map((_, i) => i);
  calCh.data = [REAL_VOL, calCh.xs.map((d) => modelVolume(p, d))];
  paint(calCh);
}
function buildCalibration() {
  const spec = { id: 'cal', title: '', fmt: { l: (v) => (v >= 1 ? v.toFixed(0) : v.toFixed(1)) }, log: { l: true }, series: [
    { label: 'observed daily volume', short: 'observed', color: '--s2', f: null }, { label: 'model, current preset', short: 'model', color: '--s1', f: null } ] };
  calCh = { spec, cv: $('calChart'), ro: { textContent: '', dataset: {} }, hover: -1, xs: [], data: [] };
  $('calLegend').innerHTML = '<span><i style="border-color:var(--s2)"></i>observed</span><span><i style="border-color:var(--s1)"></i>model, current preset</span>';
  const rows = [
    ['flat credit price per credit', 'median 0.0089 eth now, 0.03 at launch, p10 0.0069, p90 0.0138', 'flat in score, premium only above 740 points, 2x at 790 and up'],
    ['credit scores', 'uniform 80 to 800, mean 440', 'census of 122,154 credits'],
    ['statement buyer willingness to pay', 'p10 0.48, p25 0.71, median 0.84, p75 1.07, 21% at 1.2 or more, max 1.32 of parts cost', '42 priced sales, 33 statements'],
    ['statement buyers a day', '13, 11, 8, 6, 4 in the first five days, model 8 decaying to 2', 'composed 119, 19, 9, 3, 3 a day'],
    ['comparable coin volume', 'day one 1,557 eth, 912 in hour one, then 81, 42, 46, 57, 13, 28, 58, 12, 41, 5, 2, 3', 'fit 123 exp(-0.286 d), floor 0.5 eth a day'],
    ['coin buys against sells', 'day one 819 to 738 eth, net 80 eth moves price 2.5e-8 to 4.4e-7', 'model reproduces 4.48e-7 on day one'],
    ['CreditStrategy inventory', '13,132 credits listed at median 0.036 eth, mean score 371', 'static, cleared through buyListing when the ceiling passes the ask'],
    ['statement auction', 'listed at compose on the house, reserve reserveBps of cost, first bid at the reserve starts the timer, later bids 5% higher, 15 minute extension, proceeds reach the pots when collectSales runs (hourly keeper)', 'src/Core.sol, docs/reference/pnd'],
    ['launch position', 'tick -175000 to 887200, whole supply, 10% skim of which 9.5 points to the engine, 90% falling to 10% over 30 minutes', 'script/config/mainnet.json'],
  ];
  $('calTbl').innerHTML = '<thead><tr><th>input</th><th>value in the model</th><th>source</th></tr></thead><tbody>' + rows.map((r) => '<tr><td>' + r[0] + '</td><td style="white-space:normal;text-align:left">' + r[1] + '</td><td style="white-space:normal;text-align:left">' + r[2] + '</td></tr>').join('') + '</tbody>';
}
function setTheme(mode) {
  const root = document.documentElement;
  if (mode === 'auto') root.removeAttribute('data-theme'); else root.setAttribute('data-theme', mode);
  $('themeToggle').textContent = 'theme: ' + mode;
  $('themeToggle').dataset.mode = mode;
  redrawAll();
}
function start() {
  buildControls(); syncControls();
  const sc = $('scenarios');
  for (const s of SCENARIOS) { const b = el('button', null, s.label); b.type = 'button'; b.id = s.id; b.addEventListener('click', () => applyScenario(s)); sc.appendChild(b); }
  $('reset').addEventListener('click', () => applyScenario(SCENARIOS[0]));
  for (const spec of CHART_SPECS) mkChart(spec);
  buildCalibration();
  $('themeToggle').addEventListener('click', () => { const m = $('themeToggle').dataset.mode || 'auto'; setTheme(m === 'auto' ? 'light' : m === 'light' ? 'dark' : 'auto'); });
  if (window.matchMedia) window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', redrawAll);
  let raf = 0;
  const redraw = () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(redrawAll); };
  if (window.ResizeObserver) new ResizeObserver(redraw).observe($('charts')); else window.addEventListener('resize', redraw);
  run();
}
start();
