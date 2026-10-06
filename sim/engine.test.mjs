// unit checks that the port matches src/Core.sol on hand computed cases. run: node engine.test.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { Core, Pool, DEFAULTS, SETTINGS, simulate, summary, firstViolation, skimFraction, engineFeeFraction, stepVolume, W } from './engine.js';

let n = 0;
const near = (a, b, tol, msg) => {
  n++;
  const rel = Math.abs(a - b) / Math.max(Math.abs(b), 1e-300);
  assert.ok(rel <= tol, `${msg}: got ${a}, want ${b}, rel err ${rel}`);
};
const ok = (c, msg) => { n++; assert.ok(c, msg); };
const H = 3600;
const fresh = (over = {}, pot = 1000) => {
  const c = new Core(Object.assign({}, DEFAULTS, over), 0);
  c.addFees(pot, 0);
  return c;
};
const R0 = 1.54e13;

// the launch values are the ones in script/config/mainnet.json, field for field
{
  const cfg = JSON.parse(fs.readFileSync(new URL('../script/config/mainnet.json', import.meta.url), 'utf8'));
  for (const [k, v] of Object.entries(cfg.settings)) near(SETTINGS[k], k === 'buybackSlice' ? v / 1e18 : v, 1e-12, 'setting ' + k);
  near(DEFAULTS.rateStart, cfg.rateStart, 1e-12, 'rateStart');
  near(DEFAULTS.rateStart, (0.75 * 0.0089 * W) / 433, 2e-3, 'rateStart is 75 percent of the market price over avgScore');
  assert.equal(Object.keys(SETTINGS).length, Object.keys(cfg.settings).length); n++;
  assert.equal(firstViolation(SETTINGS), null); n++;
}
// no inventory gate and no dutch statement auction anywhere
{
  const src = fs.readFileSync(new URL('./engine.js', import.meta.url), 'utf8');
  ok(!/inventoryGate|setGate|gated|AUCTION_START|AUCTION_FLOOR|AUCTION_LENGTH|priceOf|buyStatement|bidMode/.test(src), 'no trace of the gate or the dutch auction');
  ok(DEFAULTS.inventoryGate === undefined && Core.prototype.setGate === undefined, 'no gate in the defaults or the Core');
}
// climb tiers: 100 bps an hour, doubling every 24 hours without a fill, capped at 800 (rateCap raised above its bounds so it does not clamp)
{
  const c = fresh({ rateCap: 1e17 }); // the climb function alone, above the bounds
  near(c.ethRate(1 * H), R0 * 1.01, 1e-12, 'one hour at 1 percent');
  near(c.ethRate(24 * H), R0 * Math.pow(1.01, 24), 1e-12, '24h at 1 percent');
  near(c.ethRate(48 * H), R0 * Math.pow(1.01, 24) * Math.pow(1.02, 24), 1e-12, '48h: 24h at 1 percent then 24h at 2 percent');
  near(c.ethRate(72 * H), R0 * Math.pow(1.01, 24) * Math.pow(1.02, 24) * Math.pow(1.04, 24), 1e-12, '72h: then 24h at 4 percent');
  const r96 = R0 * Math.pow(1.01, 24) * Math.pow(1.02, 24) * Math.pow(1.04, 24) * Math.pow(1.08, 24);
  near(c.ethRate(96 * H), r96, 1e-12, '96h: then 24h at 8 percent');
  near(c.ethRate(120 * H), r96 * Math.pow(1.08, 24), 1e-12, '120h: speed stays at the 8 percent cap');
}
// a fill resets the doubling clock: 25 hours after a fill the speed is 2 percent
{
  const c = fresh();
  ok(c.spend(1e-9, 0));
  const r0 = c.rateAtCheckpoint;
  near(c.ethRate(25 * H), r0 * Math.pow(1.01, 24) * 1.02, 1e-12, 'tier after a fill at t0');
}
// funded flag as built: pot * spendCapBps >= avgScore * rate, 0.033341 eth at the launch rate
{
  const need = (4330000 * R0) / 2000 / W;
  const lo = new Core(Object.assign({}, DEFAULTS), 0);
  lo.addFees(need * 0.999, 0);
  assert.equal(lo.funded, false); n++;
  near(lo.ethRate(100 * H), R0, 1e-12, 'unfunded rate does not climb');
  const hi = new Core(Object.assign({}, DEFAULTS), 0);
  hi.addFees(need * 1.001, 0);
  assert.equal(hi.funded, true); n++;
  // old rule counterfactual: the pot affords one average credit, 433 * rate
  const old = new Core(Object.assign({}, DEFAULTS, { fundedRule: 'old' }), 0);
  old.addFees((433 * R0 * 1.01) / W, 0);
  assert.equal(old.funded, true); n++;
}
// funded clamp: the climb stops where the hourly cap buys one average credit, pot * spendCapBps / avgScore
{
  const c = fresh({}, 0.1);
  near(c.ethRate(10000 * H), 46189376443418.016, 1e-12, 'clamp at pot 0.1 eth');
  near(fresh({}, 1000).clamp(), 123200000000000, 1e-12, 'clamp at pot 1000 eth is the rate cap, 8 times rateStart');
  assert.equal(fresh({ fundedRule: 'old' }, 0.1).clamp(), Infinity); n++;
  near(fresh({ spendCapBps: 1000 }, 0.1).clamp(), 46189376443418.016 / 2, 1e-12, 'clamp follows spendCapBps');
}
// drop on fill: rate * (1 - dropBps * x / pot / 10000), x capped by the pot
{
  const c = fresh({ rateStart: 1e13 }, 1);
  ok(c.spend(0.1, 0)); // inside the 20 percent cap
  near(c.rateAtCheckpoint, 1e13 * (1 - 0.2 * 0.1), 1e-12, 'drop for a tenth of the pot');
  near(c.ethPot, 0.9, 1e-12, 'pot after the spend');
  const w = fresh({ rateStart: 1e13, spendCapBps: 5000 }, 1);
  ok(w.spend(0.5, 0));
  near(w.rateAtCheckpoint, 9e12, 1e-12, 'half the pot spent drops 10 percent');
  const z = fresh({ rateStart: 1e13, dropBps: 500 }, 1);
  ok(z.spend(0.1, 0)); near(z.rateAtCheckpoint, 1e13 * (1 - 0.05 * 0.1), 1e-12, 'dropBps 500 is the least drop');
}
// hourly cap: spendCapBps of the pot when the window opened, fixed window
{
  const c = fresh({}, 10);
  ok(c.spend(1.5, 0)); // window opens with pot 10, cap 2
  assert.equal(c.spend(0.6, 60), false); // 1.5 + 0.6 > 2
  ok(c.spend(0.5, 120)); // exactly 2.0
  assert.equal(c.spend(0.01, 3599), false);
  ok(c.spend(0.01, 3600)); // new window with the pot as it stands, 8.0
  near(c.windowPot, 8, 1e-12, 'window pot reopened');
  assert.equal(c.capHits, 2); n++;
}
// the blended bid: price = rate * (flatBps * avgScore + (10000 - flatBps) * score) / 10000 / 1e4, no gate on score at flat
{
  const rate = 1e13;
  near(fresh({ flatBps: 10000 }).ceiling(80, rate), 433 * rate / W, 1e-12, 'flat: every credit priced as the average, low score');
  near(fresh({ flatBps: 10000 }).ceiling(800, rate), 433 * rate / W, 1e-12, 'flat: high score pays the same');
  near(fresh({ flatBps: 0 }).ceiling(800, rate), 800 * rate / W, 1e-12, 'per point: score times rate');
  near(fresh({ flatBps: 0 }).ceiling(80, rate), 80 * rate / W, 1e-12, 'per point: low score');
  near(fresh({ flatBps: 5000 }).ceiling(800, rate), 616.5 * rate / W, 1e-12, 'half blend, 800 points');
  near(fresh({ flatBps: 7500 }).ceiling(100, rate), 349.75 * rate / W, 1e-12, 'three quarters flat, 100 points');
  near(fresh({ flatBps: 5000, avgScore: 3000000 }).ceiling(500, rate), 400 * rate / W, 1e-12, 'avgScore sets the flat part');
  // the blended ceiling at any flatBps sits between the per point price of the lowest and the highest score
  for (const f of [0, 2500, 5000, 7500, 10000]) {
    const c = fresh({ flatBps: f });
    ok(c.ceiling(80, rate) <= c.ceiling(433, rate) + 1e-18 && c.ceiling(433, rate) <= c.ceiling(800, rate) + 1e-18, 'ceiling is monotone in score');
    near(c.ceiling(433, rate), 433 * rate / W, 1e-12, 'an average score credit is priced the same at every flatBps');
  }
  const c = fresh({ flatBps: 10000 }); c.rateAtCheckpoint = 1e13; c.checkpointTime = 0;
  const paid = c.sellForEth(80, 0);
  near(paid, 433e13 / W, 1e-12, 'sellForEth pays the flat price for an 80 point credit');
}
// buyListing tip: min(tipSavingsBps of savings, tipCapBps of cost) and booked as spend
{
  const c = fresh({ flatBps: 0 }, 10);
  c.rateAtCheckpoint = 1e13; // ceiling for 1000 points = 0.01 eth
  const res = c.buyListing(1000, 0.008, 0);
  ok(res);
  near(res.tip, 0.00016, 1e-12, 'tip capped at 2 percent of cost');
  const c2 = fresh({ flatBps: 0 }, 10); c2.rateAtCheckpoint = 1e13;
  near(c2.buyListing(1000, 0.0099, 0).tip, 0.00001, 1e-9, 'tip is 10 percent of savings when below the cap');
  assert.equal(c2.buyListing(1000, 0.0101, 0), null); n++;
}
// compose reimbursement: min(gas * 1.1, 5 percent of cost, pot), the listing gas counts on the eth lane only
{
  const c = fresh({ gasGwei: 1 }, 10);
  const st = c.compose(0.8, 'eth', 0, 1);
  near(st.reimb, (8.3e6 + 5e4 + 350000) * 1e-9 * 1.1, 1e-12, 'gas reimbursement with the listing');
  near(st.cost, 0.8 + st.reimb, 1e-12, 'reimbursement added to cost');
  near(c.compose(0.8, 'eth', 0, 100).reimb, 0.04, 1e-12, 'capped at 5 percent of cost');
  near(c.compose(0, 'exit', 0, 1).reimb, (8.3e6 + 5e4) * 1e-9 * 1.1, 1e-12, 'exit lane pays no listing gas');
}
// the reserve: reserveBps of statement cost at listing, repriced on request while unbid
{
  const c = fresh({ gasGwei: 1 }, 10);
  const st = c.compose(0.8, 'eth', 0, 1);
  near(st.reserve, st.cost * 0.9, 1e-12, 'reserve is 90 percent of cost at launch values');
  near(fresh({ reserveBps: 6000 }, 10).compose(1, 'eth', 0, 0).reserve, 0.6, 1e-12, 'reserveBps 6000');
  near(fresh({ reserveBps: 12000 }, 10).compose(1, 'eth', 0, 0).reserve, 1.2, 1e-12, 'reserveBps 12000');
  assert.equal(c.compose(0, 'exit', 0, 1).reserve, undefined); n++; // exit lane statements are never listed
  const s2 = c.compose(1, 'eth', 0, 0);
  c.setSettings({ reserveBps: 5000 }, 10);
  near(s2.reserve, 0.9 * s2.cost, 1e-12, 'a settings change does not move a live listing by itself');
  c.reprice(s2);
  near(s2.reserve, 0.5 * s2.cost, 1e-12, 'repriceStatement applies the new reserve');
  ok(c.bidOn(s2, s2.reserve, 20, 1)); c.setSettings({ reserveBps: 3000 }, 30); c.reprice(s2);
  near(s2.reserve, 0.5 * s2.cost, 1e-12, 'a listing with a bid cannot be repriced');
  ok(!c.bidOn(c.compose(1, 'eth', 0, 0), 0.3 - 1e-9, 0, 1), 'a bid under the reserve reverts');
}
// the english auction as the house runs it: first bid at the reserve starts the timer, +5 percent, 15 minute extension
{
  const c = fresh({ auctionDuration: 24 * H }, 10);
  const st = c.compose(1, 'eth', 0, 0);
  assert.equal(st.bid, 0); assert.equal(st.end, 0); n += 2; // unbid statements stay listed, no timer
  ok(!c.bidOn(st, 0.9 - 1e-6, 100, 1), 'below the reserve');
  ok(c.bidOn(st, 0.9, 100, 1), 'the reserve starts the auction');
  assert.equal(st.end, 100 + 24 * H); n++;
  near(c.minBid(st), 0.945, 1e-12, 'next bid at least 5 percent over');
  ok(!c.bidOn(st, 0.9449, 200, 2), 'under the 5 percent raise');
  ok(c.bidOn(st, 0.945, 200, 2), 'exactly 5 percent over');
  assert.equal(st.end, 100 + 24 * H); n++; // far from the end, no extension
  // a bid 10 minutes before the end pushes the end to 15 minutes from the bid
  const t = st.end - 600;
  ok(c.bidOn(st, st.bid * 1.06, t, 3));
  assert.equal(st.end, t + 900); n++;
  // a bid 20 minutes before the end does not extend
  const st2 = c.compose(1, 'eth', 0, 0); c.bidOn(st2, 0.9, 0, 1);
  const e2 = st2.end; c.bidOn(st2, 1, e2 - 1200, 2);
  assert.equal(st2.end, e2); n++;
  ok(!c.bidOn(st2, 2, e2, 3), 'a bid at or after the end reverts');
  // the highest bidder wins and its bid is what the house owes
  assert.equal(st.bids, 3); assert.equal(st.bidderWtp, 3); n += 2;
  near(c.settle(st), 0.945 * 1.06, 1e-12, 'the top bid is paid');
  near(c.houseOwed, 0.945 * 1.06, 1e-12, 'credited to the Core in the house');
  // a duration change applies to new listings, not to one already listed
  const st3 = c.compose(1, 'eth', 0, 0);
  c.setSettings({ auctionDuration: 6 * H }, 5);
  c.bidOn(st3, 0.9, 10, 1);
  assert.equal(st3.end, 10 + 24 * H); n++;
  assert.equal(c.compose(1, 'eth', 0, 0).duration, 6 * H); n++;
}
// the proceeds split: nothing reaches the pots before collectSales, then saleToBuybackBps to the buyback
{
  const c = fresh({}, 10);
  const pot0 = c.ethPot;
  c.houseOwed = 1;
  assert.equal(c.ethPot, pot0); assert.equal(c.ethToBuyback, 0); n += 2;
  const r = c.collectSales(0);
  near(r.toBuyback, 0.5, 1e-12, 'launch split 50 to buyback'); near(c.ethPot - pot0, 0.5, 1e-12, 'and 50 to the pot');
  assert.equal(c.houseOwed, 0); assert.equal(c.collectSales(0), null); n += 2;
  for (const [bps, bb] of [[0, 0], [2500, 0.25], [7500, 0.75], [10000, 1]]) {
    const d = fresh({ saleToBuybackBps: bps }, 10); const p0 = d.ethPot; d.houseOwed = 2;
    d.collectSales(0);
    near(d.ethToBuyback, 2 * bb, 1e-12, 'buyback share at ' + bps); near(d.ethPot - p0, 2 * (1 - bb), 1e-12, 'pot share at ' + bps);
  }
}
// setSettings: validates, checkpoints both rates first, applies at once
{
  const c = fresh({}, 1000);
  c.setSettings({ dropBps: 1000 }, 10 * H);
  near(c.rateAtCheckpoint, R0 * Math.pow(1.01, 10), 1e-12, 'the climb to the change is credited under the old numbers');
  assert.equal(c.checkpointTime, 10 * H); n++;
  near(c.ethRate(11 * H), R0 * Math.pow(1.01, 11), 1e-12, 'the climb goes on after the change');
  assert.throws(() => c.setSettings({ flatBps: 10001 }, 0), /flatBps/); n++;
  assert.throws(() => c.setSettings({ climbBaseBps: 900, climbMaxBps: 800 }, 0), /climbMaxBps/); n++;
  assert.throws(() => c.setSettings({ reserveBps: 999 }, 0), /reserveBps/); n++;
  assert.throws(() => c.setSettings({ rate: 1e10 }, 0), /BadRate/); n++;
  near(c.s.dropBps, 1000, 1e-12, 'a rejected change leaves the settings alone');
  c.setSettings({ rate: 2e13, spendCapBps: 100 }, 20 * H);
  near(c.ethRate(20 * H), 2e13, 1e-12, 'setRate resets the limit'); near(c.s.spendCapBps, 100, 1e-12, 'spend cap changed');
  // a lower hourly cap lowers the clamp at once
  const d = fresh({}, 0.1); d.setSettings({ spendCapBps: 1000 }, 0);
  near(d.clamp(), 46189376443418.016 / 2, 1e-12, 'clamp reads the live spend cap');
  assert.equal(firstViolation(Object.assign({}, SETTINGS, { exitAfter: 366 * 86400 })), 'exitAfter'); n++;
  // the tightened bounds of the audit fixes (FC-1 accepted with bounds, FC-2, FC-3, FC-7) and the rate cap (FC-5)
  const bad = (patch, name) => { assert.equal(firstViolation(Object.assign({}, SETTINGS, patch)), name); n++; };
  bad({ spendCapBps: 5001 }, 'spendCapBps'); bad({ dropBps: 499 }, 'dropBps'); bad({ avgScore: 6000001 }, 'avgScore');
  bad({ reserveBps: 2999 }, 'reserveBps'); bad({ auctionDuration: 6 * 3600 - 1 }, 'auctionDuration');
  bad({ buybackSlice: 5.01 }, 'buybackSlice'); bad({ exitAfter: 3599 }, 'exitAfter');
  bad({ rateCap: 1e11 - 1 }, 'rateCap'); bad({ rateCap: 1e15 + 1 }, 'rateCap');
  bad({ exitLaneToBuybackBps: 10001 }, 'exitLaneToBuybackBps');
  assert.equal(firstViolation(Object.assign({}, SETTINGS, { spendCapBps: 5000, dropBps: 500, avgScore: 6000000, reserveBps: 3000, auctionDuration: 6 * 3600, buybackSlice: 5, exitAfter: 3600, rateCap: 1e15 })), null); n++;
  assert.equal(SETTINGS.rateCap, 8 * DEFAULTS.rateStart); n++;
  assert.equal(firstViolation(Object.assign({}, SETTINGS, { xRateFloor: 9800 })), 'xRateFloor'); n++;
}
// rateCap: the climb clamps at it, setRate refuses above it, a lower cap pulls the rate down at the checkpoint
{
  const c = fresh({}, 1000);
  near(c.ethRate(10000 * H), 123200000000000, 1e-12, 'the climb stops at rateCap with a huge pot');
  assert.throws(() => c.setSettings({ rate: 123200000000001 }, 0), /BadRate/); n++;
  c.setSettings({ rate: 123200000000000 }, 10000 * H);
  near(c.ethRate(10000 * H), 123200000000000, 1e-12, 'setRate to the cap');
  c.setSettings({ rateCap: 5e13 }, 10000 * H);
  near(c.rateAtCheckpoint, 5e13, 1e-12, 'a lower cap pulls the rate down now');
  near(c.ethRate(11000 * H), 5e13, 1e-12, 'and the climb clamps there');
  c.setSettings({ rateCap: 2e14 }, 11000 * H);
  near(c.ethRate(12000 * H), 2e14, 1e-12, 'a higher cap lets the climb go on');
}
// the exit lane reimbursement cap is notional at rateStart, not at the live rate (FC-4)
{
  const c = fresh({ rateStart: 1e13, reimburseBps: 15000, reimburseCapBps: 1000 }, 3);
  c.setSettings({ rateCap: 1e15, rate: 1e15 }, 0);
  const st = c.compose(0, 'exit', 0, 1000);
  near(st.reimb, (80 * 4330000 * 1e13) / 1e4 / W * 0.1, 1e-12, 'capped by the notional cost at rateStart');
}
// phase 2 exit eligibility: a listing without a bid for exitAfter, the exit lane at once, never with a bid
{
  const c = fresh({}, 10); c.setExitModule(0, 1e-5);
  const st = c.compose(1, 'eth', 0, 0);
  assert.equal(c.exitReady(st, 72 * H - 1), false); assert.equal(c.exitReady(st, 72 * H), true); n += 2;
  c.bidOn(st, st.reserve, 100, 1);
  assert.equal(c.exitReady(st, 500 * H), false); n++;
  assert.equal(c.exitReady({ lane: 'exit', bid: 0, t0: 0 }, 0), true); n++;
  assert.equal(fresh({}, 10).exitReady(c.compose(1, 'eth', 0, 0), 9999 * H), false); n++; // no module, no exit
  const d = fresh({ exitAfter: 24 * H }, 10); d.setExitModule(0, 1e-5);
  assert.equal(d.exitReady(d.compose(1, 'eth', 0, 0), 24 * H), true); n++;
}
// exitToken auction: halves every xAuctionHalfLife, clock stopped while the pot is empty, restart rule
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
  // a settings change of the half life re anchors the curve at its price now
  const d = fresh(); d.setExitModule(0, 2.5e-5); d.xStartPrice = 1000; d.xStartTime = 0; d.xToBuyback = 1;
  d.setSettings({ xAuctionHalfLife: 12 * H }, 6 * H);
  near(d.xStartPrice, 500, 1e-12, 're anchored at the price now'); near(d.xAuctionPrice(18 * H), 250, 1e-12, 'new half life from the anchor');
  near(fresh({ exitSliceCredits: 40 }).xSlice(), 0, 1e-12, 'no slice without a pot');
}
// exitToken bid: climbs 100 bps an hour while funded, drops 20 per credit, bounds 3000 and 9700, per point of score
{
  const c = fresh();
  c.setExitModule(0, 1e-5);
  c.xPot = 100; c.xCheckpoint(0); c.syncXFunded();
  assert.equal(c.xFunded, true); n++;
  near(c.xRate(5 * H), 6500, 1e-12, 'climb 100 bps an hour');
  near(c.xRate(100 * H), 9700, 1e-12, 'cap 9700');
  const paid = c.xBuy(500, 0);
  near(paid, (500 * 6000 * 1e-5) / 1e4, 1e-12, 'pays pts * xRate * xp, by the credit own score'); near(c.xRateAtCheckpoint, 5980, 1e-12, 'drop 20 per credit');
  c.xRateAtCheckpoint = 3010; c.xBuy(100, 0); near(c.xRateAtCheckpoint, 3000, 1e-12, 'floor 3000');
}
{
  const c = fresh(); c.setExitModule(0, 1e-5);
  c.xPot = 0.002; c.xCheckpoint(0); c.syncXFunded();
  assert.equal(c.xFunded, false); n++; // below 433 * 0.6 * 1e-5 = 0.002598
  near(c.xRate(100 * H), 6000, 1e-12, 'unfunded exit bid does not climb');
  c.xPot = 0;
  const res = c.exitStatement({ lane: 'eth', t0: 0 }, 35000, 80 * H);
  near(res.received, 0.35, 1e-12, 'exit pays rating * unitPerPoint'); near(c.xToBuyback, 0.175, 1e-12, 'eth lane 50 to buyback'); near(c.xPot, 0.175, 1e-12, '50 to the bid pot');
  c.exitStatement({ lane: 'exit', t0: 0 }, 10000, 80 * H);
  near(c.xPot, 0.175 + 0.1, 1e-12, 'exit lane keeps all');
  const e = fresh({ exitToBuybackBps: 2000 }); e.setExitModule(0, 1e-5);
  near(e.exitStatement({ lane: 'eth', t0: 0 }, 10000, 0).toBuyback, 0.02, 1e-12, 'exitToBuybackBps');
  // exitLaneToBuybackBps: the exit lane share to the buyback, the rest to the bid pot, the eth lane unaffected
  for (const [bps, want] of [[0, 0], [5000, 0.05], [10000, 0.1]]) {
    const l = fresh({ exitLaneToBuybackBps: bps }); l.setExitModule(0, 1e-5);
    const r = l.exitStatement({ lane: 'exit', t0: 0 }, 10000, 0);
    near(r.toBuyback, want, 1e-12, 'exit lane to buyback at ' + bps); near(l.xPot, 0.1 - want, 1e-12, 'exit lane rest to the bid pot at ' + bps);
    near(l.exitStatement({ lane: 'eth', t0: 0 }, 10000, 0).toBuyback, 0.05, 1e-12, 'eth lane ignores exitLaneToBuybackBps');
  }
}
// buyback slice and keeper tip
{
  const c = fresh(); c.ethToBuyback = 2.5;
  const a = c.takeBuybackSlice(1000);
  near(a.slice, 1, 1e-12, 'slice is at most 1 eth'); near(a.tip, 0.005, 1e-12, 'tip 0.5 percent');
  assert.equal(c.takeBuybackSlice(1000 + 299), null); n++; // 25 blocks = 300 s
  ok(c.takeBuybackSlice(1000 + 300));
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
  ok(p.sell(1).eth < 1e-9); // nothing to sell below the start tick
}
// skim schedule: anti sniper 90 points falling to 10 over 30 minutes, 9.5 of the baseline to the engine
{
  near(skimFraction(DEFAULTS, 0), 0.9, 1e-12, 'launch skim'); near(skimFraction(DEFAULTS, 900), 0.5, 1e-12, 'midway');
  near(skimFraction(DEFAULTS, 1800), 0.1, 1e-12, 'end of window'); near(skimFraction(DEFAULTS, 99999), 0.1, 1e-12, 'baseline');
  near(engineFeeFraction(DEFAULTS, 0.1), 0.095, 1e-12, 'engine 9.5 points'); near(engineFeeFraction(DEFAULTS, 0.9), 0.095 + 0.8, 1e-12, 'extra to the engine');
  let d0 = 0;
  for (let t = 0; t < 3600; t += 120) d0 += stepVolume(DEFAULTS, t, 120);
  near(d0, 1557 * 0.586, 1e-9, 'first hour volume');
  for (let h = 1; h < 24; h++) d0 += stepVolume(DEFAULTS, h * 3600, 3600);
  near(d0, 1557, 1e-9, 'day one volume');
}
// whole runs: deterministic, every eth identity closes, nothing negative
{
  const a = simulate({ days: 20, seed: 3 }), b = simulate({ days: 20, seed: 3 }), c = simulate({ days: 20, seed: 4 });
  assert.deepEqual(a.S.pot, b.S.pot); n++;
  assert.notDeepEqual(a.S.pot, c.S.pot); n++;
  for (const r of [a, simulate({ days: 40, flatBps: 0, reserveBps: 6000, seed: 5 }), simulate({ days: 40, phase2Day: 12, xp: 3e-5, stmtPick: 'random' })]) {
    ok(Math.abs(r.stats.potCheck) < 1e-6, 'pot accounting ' + r.stats.potCheck);
    ok(Math.abs(r.stats.buybackCheck) < 1e-9, 'buyback accounting ' + r.stats.buybackCheck);
    ok(Math.abs(r.stats.houseCheck) < 1e-9, 'house accounting ' + r.stats.houseCheck);
    for (const k of ['pot', 'toBuyback', 'locked', 'burned', 'pending']) ok(r.S[k].every((x) => x >= -1e-12), k + ' negative');
    ok(r.S.burned[r.H] <= 1e9);
  }
  // the engine never stops buying because statements are unsold: no buyers at all, statements pile up, credits keep coming
  const none = simulate({ days: 30, stmtPerDay: 0, stmtFloorPerDay: 0, seed: 3 });
  ok(none.T.sold === 0 && none.S.waiting[none.H] > 100, 'no statement sells, many wait');
  ok(none.S.credits[none.H] > 0.9 * simulate({ days: 30, seed: 3 }).S.credits[30 * 24], 'credits acquired do not depend on statement sales');
  // a statement is bought at the reserve when no other buyer shows up, and the sale price is never under the reserve
  const e = simulate({ days: 30, seed: 3 });
  ok(e.T.sold > 0 && e.T.soldPrice >= e.T.soldReserve * (1 - 1e-9), 'sales clear at or above the reserve');
  ok(e.stats.bidsPerSale >= 1, 'every sale has at least one bid');
  // a settings change mid run: flatBps 5000 on day 5 and reserveBps 6000 on day 10 take effect
  const sw = simulate({ days: 20, seed: 3, schedule: [{ day: 5, patch: { flatBps: 5000 } }, { day: 10, patch: { reserveBps: 6000, saleToBuybackBps: 7500 } }] });
  assert.equal(sw.core.s.flatBps, 5000); assert.equal(sw.core.s.reserveBps, 6000); assert.equal(sw.core.s.saleToBuybackBps, 7500); assert.equal(sw.T.settingsChanges, 2); n += 4;
  ok(sw.unbid.every((st) => st.reserve <= 0.9 * st.cost * (1 + 1e-9)), 'listings were repriced or listed under the lower reserve');
  ok(Math.abs(sw.stats.potCheck) < 1e-6, 'accounting closes across settings changes');
  const p2 = simulate({ days: 30, phase2Day: 10, xp: 3e-5, seed: 3 });
  ok(p2.T.exited > 0 && p2.T.exitedAge > 0, 'unbid listings exit through the exitModule');
  const s = summary(a); ok(s.credits > 0 && s.potGoneDay > 1 && s.statements > 0, 'summary reads the run');
}
console.log(`ok, ${n} checks passed`);
