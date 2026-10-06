// unit checks that the port matches src/Core.sol on hand computed cases. run: node engine.test.mjs
import assert from 'node:assert/strict';
import { Core, Pool, DEFAULTS, simulate, skimFraction, engineFeeFraction, stepVolume, W } from './engine.js';

let n = 0;
const near = (a, b, tol, msg) => {
  n++;
  const rel = Math.abs(a - b) / Math.max(Math.abs(b), 1e-300);
  assert.ok(rel <= tol, `${msg}: got ${a}, want ${b}, rel err ${rel}`);
};
const H = 3600;
const fresh = (over = {}, pot = 1000) => {
  const c = new Core(Object.assign({}, DEFAULTS, over), 0);
  c.addFees(pot, 0);
  return c;
};

// climb tiers: 100 bps an hour, doubling every 24 hours without a fill, capped at 800
{
  const c = fresh();
  near(c.ethRate(1 * H), 4.04e12, 1e-12, 'one hour at 1 percent');
  near(c.ethRate(24 * H), 5078938594127.659, 1e-12, '24h at 1 percent');
  near(c.ethRate(48 * H), 8169154022592.264, 1e-12, '48h: 24h at 1 percent then 24h at 2 percent');
  near(c.ethRate(72 * H), 20940026529752.96, 1e-12, '72h: then 24h at 4 percent');
  near(c.ethRate(96 * H), 132784492867766.5, 1e-12, '96h: then 24h at 8 percent');
  near(c.ethRate(120 * H), 132784492867766.5 * Math.pow(1.08, 24), 1e-12, '120h: speed stays at the 8 percent cap');
}
// a fill resets the doubling clock: 25 hours after a fill the speed is 2 percent
{
  const c = fresh();
  assert.ok(c.spend(1e-9, 0));
  const r0 = c.rateAtCheckpoint;
  near(c.ethRate(25 * H), r0 * Math.pow(1.01, 24) * 1.02, 1e-12, 'tier after a fill at t0');
}
// funded flag: the new rule needs pot * 2000 >= AVG_SCORE * rate, 8.66e15 wei at the start rate
{
  const lo = new Core(Object.assign({}, DEFAULTS), 0);
  lo.addFees(8.65e15 / W, 0);
  assert.equal(lo.funded, false); n++;
  near(lo.ethRate(100 * H), 4e12, 1e-12, 'unfunded rate does not climb');
  const hi = new Core(Object.assign({}, DEFAULTS), 0);
  hi.addFees(8.67e15 / W, 0);
  assert.equal(hi.funded, true); n++;
  // old rule: the pot affords one average credit, 433 * 4e12 = 1.732e15 wei
  const old = new Core(Object.assign({}, DEFAULTS, { fundedRule: 'old' }), 0);
  old.addFees(1.74e15 / W, 0);
  assert.equal(old.funded, true); n++;
}
// funded clamp: the climb stops where 20 percent of the pot buys one average credit, pot * 2000 / AVG_SCORE
{
  const c = fresh({}, 0.1);
  near(c.ethRate(10000 * H), 46189376443418.016, 1e-12, 'clamp at pot 0.1 eth');
  const c2 = fresh({}, 1000);
  near(c2.clamp(), 4.6189376443418016e17, 1e-12, 'clamp at pot 1000 eth');
  const o = fresh({ fundedRule: 'old' }, 0.1);
  assert.equal(o.clamp(), Infinity); n++;
}
// drop on fill: rate * (1 - 10% * x / pot), x capped by the pot
{
  const c = fresh({ rateStart: 1e13 }, 1);
  c.rateAtCheckpoint = 1e13; c.checkpointTime = 0;
  assert.ok(c.spend(0.1, 0)); // inside the 20 percent cap
  near(c.rateAtCheckpoint, 1e13 * (1 - 0.1 * 0.1), 1e-12, 'drop for a tenth of the pot');
  near(c.ethPot, 0.9, 1e-12, 'pot after the spend');
  const w = fresh({ rateStart: 1e13, SPEND_CAP_BPS_PER_HOUR: 10000 }, 1);
  assert.ok(w.spend(1, 0));
  near(w.rateAtCheckpoint, 9e12, 1e-12, 'a whole pot spent drops 10 percent');
}
// hourly cap: 20 percent of the pot when the window opened, fixed window
{
  const c = fresh({}, 10);
  assert.ok(c.spend(1.5, 0)); // window opens with pot 10, cap 2
  assert.equal(c.spend(0.6, 60), false); // 1.5 + 0.6 > 2
  assert.ok(c.spend(0.5, 120)); // exactly 2.0
  assert.equal(c.spend(0.01, 3599), false);
  assert.ok(c.spend(0.01, 3600)); // new window with the pot as it stands, 8.0
  near(c.windowPot, 8, 1e-12, 'window pot reopened');
  assert.equal(c.capHits, 2); n++;
}
// buyListing tip: min(10 percent of savings, 2 percent of cost) and booked as spend
{
  const c = fresh({}, 10);
  c.rateAtCheckpoint = 1e13 / 1; // ceiling for 1000 points = 0.01 eth
  const res = c.buyListing(1000, 0.008, 0);
  assert.ok(res); n++;
  near(res.tip, 0.00016, 1e-12, 'tip capped at 2 percent of cost');
  const c2 = fresh({}, 10); c2.rateAtCheckpoint = 1e13;
  const res2 = c2.buyListing(1000, 0.0099, 0);
  near(res2.tip, 0.00001, 1e-9, 'tip is 10 percent of savings when below the cap');
  assert.equal(c2.buyListing(1000, 0.0101, 0), null); n++;
}
// statement auction price: 4x falling linearly to 1.2x over 72 hours, then flat
{
  const c = fresh();
  const st = { cost: 1, t0: 0 };
  near(c.priceOf(st, 0), 4, 1e-12, 'start 4x');
  near(c.priceOf(st, 36 * H), 2.6, 1e-12, 'midpoint 2.6x');
  near(c.priceOf(st, 72 * H), 1.2, 1e-12, 'floor 1.2x');
  near(c.priceOf(st, 500 * H), 1.2, 1e-12, 'flat at the floor');
  near(c.priceOf({ cost: 0.8, t0: 0 }, 18 * H), 0.8 * (4 - 2.8 * 0.25), 1e-12, 'quarter way');
  const before = c.ethPot;
  const s = c.buyStatement({ cost: 1, t0: 0 }, 72 * H);
  near(s.toBuyback, 0.6, 1e-12, 'sale split 50 to buyback'); near(c.ethPot - before, 0.6, 1e-12, 'sale split 50 to pot');
}
// compose reimbursement: min(gas * 1.1, 5 percent of cost, pot)
{
  const c = fresh({ gasGwei: 1 }, 10);
  const st = c.compose(0.8, 'eth', 0, 1);
  near(st.reimb, (8.3e6 + 5e4) * 1e-9 * 1.1, 1e-12, 'gas reimbursement');
  near(st.cost, 0.8 + st.reimb, 1e-12, 'reimbursement added to cost');
  const hi = c.compose(0.8, 'eth', 0, 100);
  near(hi.reimb, 0.04, 1e-12, 'capped at 5 percent of cost');
}
// exit token auction: halves every 6 hours, clock stopped while the pot is empty, restart rule
{
  const c = fresh();
  c.setExitModule(0, 2.5e-5);
  near(c.xStartPrice, 1e9 / (20 * 433 * 2.5e-5), 1e-12, 'first start asks the whole supply for a full slice');
  c.xStartPrice = 1000; c.xStartTime = 0;
  near(c.xAuctionPrice(10 * H), 1000, 1e-12, 'empty pot: clock stopped');
  c.xToBuyback = 1;
  near(c.xAuctionPrice(0), 1000, 1e-12, 'start');
  near(c.xAuctionPrice(6 * H), 500, 1e-12, 'one half life');
  near(c.xAuctionPrice(9 * H), 353.5533905932738, 1e-12, 'one and a half half lives');
  near(c.xAuctionPrice(7.5 * H), 420.44820762685725, 1e-12, 'one and a quarter');
  near(c.xAuctionPrice(2000 * H), 0, 1e-9, 'long gap reaches zero'); // 256 half lives
  const f = c.xFill(6 * H);
  near(f.price, 500, 1e-12, 'fill price');
  near(c.xStartPrice, 1000, 1e-12, 'restart max(2 * 500, 1000 / 4)');
  c.xStartPrice = 1000; c.xStartTime = 0; c.xToBuyback = 1;
  c.xFill(30 * H); // price 1000 * 2^-5 = 31.25
  near(c.xStartPrice, 250, 1e-12, 'restart floors at a quarter of the start');
}
// exit token bid: climbs 100 bps an hour while funded, drops 20 per credit, bounds 3000 and 9700
{
  const c = fresh();
  c.setExitModule(0, 1e-5);
  c.xPot = 100; c.xCheckpoint(0); c.syncXFunded();
  assert.equal(c.xFunded, true); n++;
  near(c.xRate(5 * H), 6500, 1e-12, 'climb 100 bps an hour');
  near(c.xRate(100 * H), 9700, 1e-12, 'cap 9700');
  const paid = c.xBuy(500, 0);
  near(paid, (500 * 6000 * 1e-5) / 1e4, 1e-12, 'pays pts * xRate * xp'); near(c.xRateAtCheckpoint, 5980, 1e-12, 'drop 20 per credit');
  c.xRateAtCheckpoint = 3010; c.xBuy(100, 0); near(c.xRateAtCheckpoint, 3000, 1e-12, 'floor 3000');
}
{
  const c = fresh(); c.setExitModule(0, 1e-5);
  c.xPot = 0.002; c.xCheckpoint(0); c.syncXFunded();
  assert.equal(c.xFunded, false); n++; // below 433 * 0.6 * 1e-5 = 0.002598
  near(c.xRate(100 * H), 6000, 1e-12, 'unfunded exit bid does not climb');
  const st = { lane: 'eth', t0: 0 };
  c.xPot = 0;
  const res = c.exitStatement(st, 35000, 80 * H);
  near(res.received, 0.35, 1e-12, 'exit pays rating * unitPerPoint'); near(c.xToBuyback, 0.175, 1e-12, 'eth lane 50 to buyback'); near(c.xPot, 0.175, 1e-12, '50 to the bid pot');
  const lane = c.exitStatement({ lane: 'exit', t0: 0 }, 10000, 80 * H);
  near(c.xPot, 0.175 + 0.1, 1e-12, 'exit lane keeps all');
}
// buyback slice and keeper tip
{
  const c = fresh(); c.ethToBuyback = 2.5;
  const a = c.takeBuybackSlice(1000);
  near(a.slice, 1, 1e-12, 'slice is at most 1 eth'); near(a.tip, 0.005, 1e-12, 'tip 0.5 percent');
  assert.equal(c.takeBuybackSlice(1000 + 299), null); n++; // 25 blocks = 300 s
  assert.ok(c.takeBuybackSlice(1000 + 300)); n++;
  near(c.ethToBuyback, 0.5, 1e-12, 'pool after two slices');
}
// launch position: whole supply single sided, price 2.513e-8 eth per coin at the start tick
{
  const p = new Pool(DEFAULTS);
  near(p.price, 2.5131970949402153e-8, 1e-12, 'start price');
  near(p.coinInPool(), 1e9, 1e-9, 'whole supply in the position');
  const out = p.buy(80);
  near(p.price * 1e9, 439.7878, 1e-4, 'fdv after 80 eth net buys, matches the observed day one end price');
  near(p.ethInPool(), 80, 1e-9, 'eth in the position');
  const back = p.sell(80);
  near(back.eth, 80, 1e-12, 'round trip eth'); near(back.coin, out, 1e-9, 'round trip coin');
  near(p.price, 2.5131970949402153e-8, 1e-9, 'back at the start');
  assert.ok(p.sell(1).eth < 1e-9); n++; // nothing to sell below the start tick
}
// skim schedule: anti sniper 90 points falling to 10 over 30 minutes, 9.5 of the baseline to the engine
{
  near(skimFraction(DEFAULTS, 0), 0.9, 1e-12, 'launch skim'); near(skimFraction(DEFAULTS, 900), 0.5, 1e-12, 'midway');
  near(skimFraction(DEFAULTS, 1800), 0.1, 1e-12, 'end of window'); near(skimFraction(DEFAULTS, 99999), 0.1, 1e-12, 'baseline');
  near(engineFeeFraction(DEFAULTS, 0.1), 0.095, 1e-12, 'engine 9.5 points'); near(engineFeeFraction(DEFAULTS, 0.9), 0.095 + 0.8, 1e-12, 'extra to the engine');
  let v = 0;
  for (let t = 0; t < 3600; t += 120) v += stepVolume(DEFAULTS, t, 120);
  near(v, 1557 * 0.586, 1e-9, 'first hour volume');
  let d0 = 0;
  for (let t = 0; t < 3600; t += 120) d0 += stepVolume(DEFAULTS, t, 120);
  for (let h = 1; h < 24; h++) d0 += stepVolume(DEFAULTS, h * 3600, 3600);
  near(d0, 1557, 1e-9, 'day one volume');
}
// proposed inventory gate: no climb while gated, climb resumes after
{
  const c = fresh();
  c.setGate(true, 0);
  near(c.ethRate(48 * H), 4e12, 1e-12, 'gated rate does not climb');
  c.setGate(false, 10 * H);
  near(c.ethRate(11 * H), 4e12 * 1.01, 1e-12, 'climb resumes from the gate lift');
}
// whole run: deterministic, eth accounting closes, nothing negative
{
  const a = simulate({ days: 20, seed: 3 }), b = simulate({ days: 20, seed: 3 }), c = simulate({ days: 20, seed: 4 });
  assert.deepEqual(a.S.pot, b.S.pot); n++;
  assert.notDeepEqual(a.S.pot, c.S.pot); n++;
  assert.ok(Math.abs(a.stats.potCheck) < 1e-6, 'pot accounting ' + a.stats.potCheck); n++;
  assert.ok(Math.abs(a.stats.buybackCheck) < 1e-9, 'buyback accounting ' + a.stats.buybackCheck); n++;
  for (const k of ['pot', 'toBuyback', 'locked', 'burned']) assert.ok(a.S[k].every((x) => x >= -1e-12), k + ' negative'); n++;
  assert.ok(a.core.ethPot + a.core.ethToBuyback >= 0); n++;
  const p2 = simulate({ days: 30, phase2Day: 10, xp: 3e-5 });
  assert.ok(Math.abs(p2.stats.potCheck) < 1e-6, 'phase 2 pot accounting ' + p2.stats.potCheck); n++;
  assert.ok(p2.S.burned[30 * 24] <= 1e9); n++;
}
console.log(`ok, ${n} checks passed`);
