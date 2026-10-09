// unit checks that the port matches src/Core.sol on hand computed cases. run: node engine.test.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { Core, Pool, DEFAULTS, SETTINGS, CONTROLLER, simulate, controllerViolation, summary, firstViolation, skimFraction, pathPrice, routerFeeFraction, engineFeeFraction, stepVolume, W } from './engine.js';

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

// the launch values are the ones in script/config/mainnet.json, field for field. the file is the other half of the launch package: where it already
// carries a field of the rules in docs/FLOW.md section 9 it must match, and a field of the old rules (reserveBps) must be gone from the model
{
  const cfg = JSON.parse(fs.readFileSync(new URL('../script/config/mainnet.json', import.meta.url), 'utf8'));
  const moved = cfg.settings.reserveBps !== undefined; // the config still on the old rules: the new fields are not there yet
  const newFields = ['saleFloorBps', 'feeToBuybackBps'];
  // the stepped bid rule fields of the Core are sim parameters of the bidRule stepped (setting B of docs/BID-STUDY.md), under other names. the built rule fields are sim only
  const STEPPED = { dropPerCreditBps: 50, dropFloorBps: 8000, climbPerMinBps: 50, ceilBps: 12500, idleLoosenBps: 200, clampCredits: 20 };
  const BUILT_ONLY = ['climbBaseBps', 'climbDoubleEvery', 'climbMaxBps', 'dropBps'];
  for (const [k, v] of Object.entries(STEPPED)) if (cfg.settings[k] !== undefined) near(cfg.settings[k], v, 1e-12, 'launch stepped bid rule ' + k);
  for (const [k, v] of Object.entries(cfg.settings)) {
    if (k in STEPPED) continue;
    if (k === 'reimburseBps' && v !== SETTINGS[k]) continue; // launch 8000 since commit 5f61f2c. the sim keeps 11000 so the study rows stay comparable
    if (k === 'reserveBps') { ok(SETTINGS.reserveBps === undefined, 'reserveBps is gone from the model'); continue; }
    if (moved && k === 'exitAfter') continue; // 72 hours in the old file, 105 hours in the new rules
    near(SETTINGS[k], k === 'buybackSlice' ? v / 1e18 : v, 1e-12, 'setting ' + k);
  }
  for (const k of newFields) if (cfg.settings[k] !== undefined) near(SETTINGS[k], cfg.settings[k], 1e-12, 'setting ' + k);
  for (const k of Object.keys(SETTINGS)) ok(BUILT_ONLY.includes(k) || cfg.settings[k] !== undefined || (moved && (newFields.includes(k) || k === 'reserveBps')), 'the config carries ' + k);
  if (cfg.controller) for (const k of Object.keys(CONTROLLER)) near(+CONTROLLER[k], +cfg.controller[k], 1e-12, 'controller ' + k);
  // the launch rateStart is 100 percent of market (stepped rule). the sim default is the built rule's 75 percent, the study sets rateStart per run
  near(cfg.rateStart, (0.0089 * W) / 433, 1e-3, 'launch rateStart is 100 percent of the 0.0089 market');
  // the pool and router values of the v2 launch
  for (const k of ['baselineSkimBps', 'bountyBps', 'sniperStartBps']) near(DEFAULTS[k], cfg.launch[k], 1e-12, 'launch ' + k);
  near(DEFAULTS.sniperSeconds, cfg.launch.sniperSeconds, 1e-12, 'launch sniperSeconds');
  near(DEFAULTS.sniperEndBps, cfg.launch.baselineSkimBps, 1e-12, 'the sniper skim falls to the baseline');
  ok(cfg.launch.lpFee === 0, 'no lp fee, so no lp income in the model');
  near(DEFAULTS.routerPayeePpm, cfg.router.payeePpm, 1e-12, 'router payeePpm'); near(DEFAULTS.routerTipPpm, cfg.router.tipPpm, 1e-12, 'router tipPpm');
  near(DEFAULTS.rateStart, (0.75 * 0.0089 * W) / 433, 2e-3, 'rateStart is 75 percent of the market price over avgScore');
  assert.equal(firstViolation(SETTINGS), null); n++;
  assert.equal(controllerViolation(CONTROLLER), null); n++;
  // the rules of docs/FLOW.md section 9 at launch
  assert.deepEqual(CONTROLLER, { buyOnly: false, startBps: 11000, stepBps: 100, stepEvery: 3 * H, floorBps: 7500 }); n++;
  assert.equal(SETTINGS.saleFloorBps, 7500); assert.equal(SETTINGS.exitAfter, 105 * H); assert.equal(SETTINGS.feeToBuybackBps, 0); n += 3;
}
// no inventory gate and no dutch statement auction anywhere
{
  const src = fs.readFileSync(new URL('./engine.js', import.meta.url), 'utf8');
  ok(!/inventoryGate|setGate|gated|AUCTION_START|AUCTION_FLOOR|AUCTION_LENGTH|buyStatement|bidMode/.test(src), 'no trace of the gate or the dutch auction');
  ok(DEFAULTS.inventoryGate === undefined && Core.prototype.setGate === undefined, 'no gate in the defaults or the Core');
  ok(!/reserveBps/.test(src) && DEFAULTS.reserveBps === undefined && Core.prototype.reprice === undefined, 'reserveBps is gone from the model, the reprice step is folded into the first bid');
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
// the asking price of a statement (ControllerV1.statementPrice, then the Core's hard floor): startBps minus stepBps every stepEvery, never under floorBps
// or under saleFloorBps. the price is a share of what the engine PAID, the statement cost
{
  const c = fresh({}, 10);
  const st = { cost: 1, t0: 0 }; // cost 1 eth keeps the percent readable
  const at = (h) => c.askingPrice(st, h * H);
  near(at(0), 1.10, 1e-12, 'asking 110 at hour 0');
  near(c.askingPrice(st, 3 * H - 1), 1.10, 1e-12, 'still 110 one second before hour 3');
  near(at(3), 1.09, 1e-12, 'asking 109 at hour 3');
  near(at(6), 1.08, 1e-12, 'asking 108 at hour 6');
  near(at(30), 1.00, 1e-12, 'asking 100 at hour 30');
  near(at(60), 0.90, 1e-12, 'asking 90 at hour 60');
  near(at(99), 0.77, 1e-12, 'asking 77 at hour 99');
  near(c.askingPrice(st, 105 * H - 1), 0.76, 1e-12, 'asking 76 one second before the floor');
  near(at(105), 0.75, 1e-12, 'asking 75 at hour 105');
  near(at(106), 0.75, 1e-12, 'floor after hour 105'); near(at(5000), 0.75, 1e-12, 'floor long after');
  near(c.askingPrice({ cost: 2.4, t0: 10 * H }, 40 * H), 2.4 * 1.00, 1e-12, 'age counts from listedAt, price scales with cost');
  near(c.askingPrice({ cost: 1, t0: 100 }, 50), 1.10, 1e-12, 'a clock before listedAt is age zero');
  assert.equal(c.lowestPrice(st), 0.75); n++;
  // the curve settings are read live: a smaller step, a longer step, another start, another floor
  const d = fresh({ stepBps: 50, stepEvery: 6 * H, startBps: 13000, floorBps: 9000, saleFloorBps: 7500 }, 10);
  near(d.askingPrice(st, 0), 1.30, 1e-12, 'start 130'); near(d.askingPrice(st, 5 * H), 1.30, 1e-12, 'step 6 hours'); near(d.askingPrice(st, 6 * H), 1.295, 1e-12, 'drop 50 at hour 6');
  near(d.askingPrice(st, 1000 * H), 0.90, 1e-12, 'curve floor 90 above the hard floor wins');
  near(fresh({ stepBps: 0 }, 10).askingPrice(st, 1000 * H), 1.10, 1e-12, 'stepBps 0 never drops');
  near(fresh({ startBps: 9000 }, 10).askingPrice(st, 0), 0.90, 1e-12, 'start 90');
  // the controller settings change at once through setSettings and are validated against the controller bounds
  const e = fresh({}, 10); e.setSettings({ startBps: 12000, stepEvery: H }, 5 * H);
  near(e.askingPrice(st, 5 * H), 1.15, 1e-12, 'a changed start and step read at once');
  assert.throws(() => e.setSettings({ floorBps: 12001 }, 0), /floorBps/); assert.throws(() => e.setSettings({ stepEvery: 59 }, 0), /stepEvery/); n += 2;
  assert.throws(() => e.setSettings({ startBps: 999 }, 0), /startBps/); assert.throws(() => e.setSettings({ stepBps: 5001 }, 0), /stepBps/); n += 2;
  near(e.c.startBps, 12000, 1e-12, 'a rejected change leaves the controller alone');
  for (const [k, bad] of [['startBps', 40001], ['floorBps', 999], ['stepEvery', 30 * 86400 + 1]]) assert.equal(controllerViolation(Object.assign({}, CONTROLLER, { [k]: bad })), k), n++;
  assert.equal(controllerViolation(Object.assign({}, CONTROLLER, { startBps: 40000, floorBps: 40000, stepBps: 5000, stepEvery: 60 })), null); n++;
}
// the hard floor: the price used is never below saleFloorBps of cost, a lower curve floor does not get under it
{
  const st = { cost: 1, t0: 0 };
  const a = fresh({ floorBps: 6000, saleFloorBps: 7500 }, 10);
  near(a.askingPrice(st, 105 * H), 0.75, 1e-12, 'curve floor 60 under the hard floor 75: the hard floor wins at hour 105');
  near(a.askingPrice(st, 150 * H), 0.75, 1e-12, 'and after the curve would have reached 60');
  near(a.askingPrice(st, 90 * H), 0.80, 1e-12, 'above the hard floor the curve decides');
  const b = fresh({ floorBps: 5000, saleFloorBps: 7500, startBps: 6000 }, 10);
  near(b.askingPrice(st, 0), 0.75, 1e-12, 'a start under the hard floor is lifted to it');
  const c = fresh({ floorBps: 6000, saleFloorBps: 6000 }, 10);
  near(c.askingPrice(st, 1000 * H), 0.60, 1e-12, 'with both lowered the price walks to 60');
  near(fresh({ saleFloorBps: 9500 }, 10).askingPrice(st, 1000 * H), 0.95, 1e-12, 'a hard floor above the curve floor wins');
  near(fresh({ saleFloorBps: 9500 }, 10).lowestPrice(st), 0.95, 1e-12, 'lowest price is the higher of the two');
  near(a.floorPrice({ cost: 2 }), 1.5, 1e-12, 'floorPrice is cost times saleFloorBps');
  // sellTo refuses a payment under the hard floor even if the controller would ask less
  const s = a.compose(1, 'eth', 0, 0);
  assert.equal(a.sellTo(s, 0.7499, 0), null); assert.notEqual(a.sellTo(s, 0.75, 0), null); n += 2;
}
// compose lists the statement at age zero, at the start price. the exit lane statement is never listed
{
  const c = fresh({ gasGwei: 1 }, 10);
  const st = c.compose(0.8, 'eth', 0, 1);
  near(st.reserve, st.cost * 1.1, 1e-12, 'listed at the start price, 110 percent of cost');
  near(fresh({ startBps: 9000 }, 10).compose(1, 'eth', 0, 0).reserve, 0.9, 1e-12, 'startBps 9000');
  near(fresh({ startBps: 13000 }, 10).compose(1, 'eth', 0, 0).reserve, 1.3, 1e-12, 'startBps 13000');
  assert.equal(c.compose(0, 'exit', 0, 1).reserve, undefined); n++;
  assert.equal(st.bid, 0); assert.equal(st.end, 0); n += 2; // unbid statements stay listed, no timer
}
// auction mode: a buyer at or above the asking price opens the english auction AT that price (the first bidder reprices the listing to it first),
// then the house rules: timer from the first bid, 5 percent raise, 15 minute extension
{
  const c = fresh({ auctionDuration: 24 * H }, 10);
  const st = c.compose(1, 'eth', 0, 0);
  assert.equal(st.bid, 0); assert.equal(st.end, 0); n += 2; // unbid statements stay listed, no timer
  ok(!c.bidOn(st, 1.10 - 1e-6, 100, 1), 'below the asking price');
  ok(c.bidOn(st, 1.10, 100, 1), 'the asking price starts the auction');
  near(st.reserve, 1.10, 1e-12, 'the auction opened at the asking price at that moment'); assert.equal(st.end, 100 + 24 * H); n++;
  // a buyer who comes at hour 30 finds the asking price at 100 and opens there
  const s30 = c.compose(1, 'eth', 0, 0);
  ok(!c.bidOn(s30, 1.0 - 1e-6, 30 * H, 1), 'under 100 at hour 30'); ok(c.bidOn(s30, 1.0, 30 * H, 1), 'opens at 100 at hour 30');
  near(s30.reserve, 1.0, 1e-12, 'reserve is the accepted price'); near(s30.bid, 1.0, 1e-12, 'first bid is the accepted price'); assert.equal(s30.end, 30 * H + 24 * H); n++;
  // and one at the floor opens at the floor
  const s105 = c.compose(1, 'eth', 0, 0);
  ok(c.bidOn(s105, 0.75, 200 * H, 1)); near(s105.reserve, 0.75, 1e-12, 'opens at the hard floor');
  // later bids: 5 percent over the top bid, no matter what the asking curve says
  near(c.minBid(st, 100), 1.155, 1e-12, 'next bid at least 5 percent over');
  near(c.minBid(st, 100 + 1000 * H), 1.155, 1e-12, 'a live auction ignores the curve');
  ok(!c.bidOn(st, 1.1549, 200, 2), 'under the 5 percent raise');
  ok(c.bidOn(st, 1.155, 200, 2), 'exactly 5 percent over');
  assert.equal(st.end, 100 + 24 * H); n++; // far from the end, no extension
  // a bid 10 minutes before the end pushes the end to 15 minutes from the bid
  const t = st.end - 600;
  ok(c.bidOn(st, st.bid * 1.06, t, 3));
  assert.equal(st.end, t + 900); n++;
  // a bid 20 minutes before the end does not extend
  const st2 = c.compose(1, 'eth', 0, 0); c.bidOn(st2, 1.1, 0, 1);
  const e2 = st2.end; c.bidOn(st2, 1.3, e2 - 1200, 2);
  assert.equal(st2.end, e2); n++;
  ok(!c.bidOn(st2, 2, e2, 3), 'a bid at or after the end reverts');
  // the highest bidder wins and its bid is what the house owes
  assert.equal(st.bids, 3); assert.equal(st.bidderWtp, 3); n += 2;
  near(c.settle(st), 1.155 * 1.06, 1e-12, 'the top bid is paid');
  near(c.houseOwed, 1.155 * 1.06, 1e-12, 'credited to the Core in the house');
  // a duration change applies to new listings, not to one already listed
  const st3 = c.compose(1, 'eth', 0, 0);
  c.setSettings({ auctionDuration: 6 * H }, 5);
  c.bidOn(st3, 1.1, 10, 1);
  assert.equal(st3.end, 10 + 24 * H); n++;
  assert.equal(c.compose(1, 'eth', 0, 0).duration, 6 * H); n++;
}
// buy only mode: sellTo pays the asking price and the statement is gone at once, no auction, nothing waits in the house
{
  const c = fresh({ buyOnly: true }, 10);
  const pot0 = c.ethPot;
  const st = c.compose(1, 'eth', 0, 0);
  const ask = c.askingPrice(st, 30 * H); near(ask, 1.0, 1e-12, 'asking price at hour 30');
  const r = c.sellTo(st, ask, 30 * H);
  ok(r !== null && st.sold === true, 'sold in the same call');
  near(r.toBuyback, 0.5, 1e-12, 'launch split: half to the buyback'); near(r.toPot, 0.5, 1e-12, 'half to the pot');
  near(c.ethPot - pot0, 0.5, 1e-12, 'the pot has it at once'); near(c.ethToBuyback, 0.5, 1e-12, 'the buyback pot has it at once');
  assert.equal(c.houseOwed, 0); assert.equal(st.bid, 0); assert.equal(st.bids, 0); n += 3; // nothing in the house, no bid, no timer
  assert.equal(c.sellTo(st, ask, 31 * H), null); n++; // a statement is sold once
  const live = c.compose(1, 'eth', 0, 0); c.bidOn(live, 1.1, 0, 1);
  assert.equal(c.sellTo(live, 5, 1), null); n++; // a live auction always wins
  assert.equal(c.sellTo(c.compose(0, 'exit', 0, 0), 5, 1), null); n++; // the exit lane is never listed
  // overpaying is booked in full, the Core gives no refund
  const o = c.compose(1, 'eth', 0, 0); const p1 = c.ethPot + c.ethToBuyback;
  c.sellTo(o, 3, 0); near(c.ethPot + c.ethToBuyback - p1, 3, 1e-12, 'what is paid is booked');
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
// the split arithmetic is the same in both modes: auction proceeds after collectSales, buy only proceeds at once, saleToBuybackBps to the buyback
{
  for (const [bps, bb] of [[0, 0], [1000, 0.1], [5000, 0.5], [10000, 1]]) {
    const a = fresh({ saleToBuybackBps: bps }, 10); const pa = a.ethPot;
    const sa = a.compose(1, 'eth', 0, 0); a.bidOn(sa, 1.1, 0, 1); a.settle(sa);
    near(a.ethToBuyback, 0, 1e-12, 'auction mode: nothing before collectSales at ' + bps);
    a.collectSales(0);
    near(a.ethToBuyback, 1.1 * bb, 1e-12, 'auction mode buyback share at ' + bps); near(a.ethPot - pa, 1.1 * (1 - bb), 1e-12, 'auction mode pot share at ' + bps);
    const b = fresh({ saleToBuybackBps: bps, buyOnly: true }, 10); const pb = b.ethPot;
    const sb = b.compose(1, 'eth', 0, 0); b.sellTo(sb, 1.1, 0);
    near(b.ethToBuyback, 1.1 * bb, 1e-12, 'buy only buyback share at ' + bps); near(b.ethPot - pb, 1.1 * (1 - bb), 1e-12, 'buy only pot share at ' + bps);
  }
  // a split change applies to the next booking, the Core reads it live
  const c = fresh({}, 10); c.setSettings({ saleToBuybackBps: 2500 }, 0); const p0 = c.ethPot; c.houseOwed = 4; c.collectSales(0);
  near(c.ethToBuyback, 1, 1e-12, 'live split'); near(c.ethPot - p0, 3, 1e-12, 'live split, pot');
}
// feeToBuybackBps: the share of swap fee eth booked in receive() that goes to the buyback pot, the rest to the pot
{
  for (const [bps, bb] of [[0, 0], [2500, 0.25], [5000, 0.5], [10000, 1]]) {
    const c = new Core(Object.assign({}, DEFAULTS, { feeToBuybackBps: bps }), 0);
    const r = c.addFees(8, 0);
    near(c.ethToBuyback, 8 * bb, 1e-12, 'fee share to buyback at ' + bps); near(c.ethPot, 8 * (1 - bb), 1e-12, 'fee share to pot at ' + bps);
    near(r.toBuyback + r.toPot, 8, 1e-12, 'fee split adds up at ' + bps); near(c.feeToBuyback, 8 * bb, 1e-12, 'fee share booked at ' + bps);
  }
  const z = fresh({ feeToBuybackBps: 0 }, 10); near(z.ethToBuyback, 0, 1e-12, 'launch value 0 sends no fee to the buyback'); near(z.ethPot, 10, 1e-12, 'all of it to the pot');
  // 5000: half; the funded flag follows the pot only (the buyback share is not in the pot)
  const h = new Core(Object.assign({}, DEFAULTS, { feeToBuybackBps: 5000 }), 0);
  const need = (4330000 * R0) / 2000 / W;
  h.addFees(need * 1.5, 0); assert.equal(h.funded, false); h.addFees(need * 1, 0); assert.equal(h.funded, true); n += 2; // pot 1.25 need after the second booking
  // a change applies to the next booking, sale proceeds are not touched by it
  const s = fresh({}, 10); s.setSettings({ feeToBuybackBps: 10000 }, 0); s.addFees(1, 0);
  near(s.ethToBuyback, 1, 1e-12, 'live fee share'); near(s.ethPot, 10, 1e-12, 'pot unchanged by a fee booked at 10000');
  s.houseOwed = 2; s.collectSales(0); near(s.ethToBuyback, 2, 1e-12, 'sales follow saleToBuybackBps, not the fee share');
  assert.throws(() => s.setSettings({ feeToBuybackBps: 10001 }, 0), /feeToBuybackBps/); n++;
  assert.throws(() => s.setSettings({ saleFloorBps: 999 }, 0), /saleFloorBps/); n++;
}
// conservation of eth through the Core: fees, sales, reimbursement, spend and the buyback slice all come from and go to one ledger
{
  for (const over of [{}, { buyOnly: true }, { feeToBuybackBps: 5000 }, { buyOnly: true, feeToBuybackBps: 2500, saleToBuybackBps: 7500 }, { feeToBuybackBps: 10000, saleToBuybackBps: 0 }]) {
    const c = new Core(Object.assign({}, DEFAULTS, { gasGwei: 1 }, over), 0);
    let inflow = 0, out = 0;
    c.addFees(20, 0); inflow += 20;
    c.addFees(3.3, 50); inflow += 3.3;
    if (c.spend(1.2, 100)) out += 1.2; else ok(c.s.feeToBuybackBps === 10000, 'a spend only fails on an empty pot');
    const st = c.compose(0.9, 'eth', 200, 1); out += st.reimb;
    if (c.c.buyOnly) { c.sellTo(st, c.askingPrice(st, 40 * H), 40 * H); inflow += c.askingPrice(st, 40 * H); }
    else { c.bidOn(st, c.askingPrice(st, 40 * H), 40 * H, 1); c.settle(st); inflow += st.bid; c.collectSales(41 * H); }
    const b = c.takeBuybackSlice(50 * H); if (b) out += b.slice;
    near(c.ethPot + c.ethToBuyback + c.houseOwed + out, inflow, 1e-12, 'eth conserved ' + JSON.stringify(over));
    ok(c.ethPot >= 0 && c.ethToBuyback >= 0, 'no negative pot');
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
  assert.throws(() => c.setSettings({ saleFloorBps: 999 }, 0), /saleFloorBps/); n++;
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
  bad({ saleFloorBps: 999 }, 'saleFloorBps'); bad({ saleFloorBps: 40001 }, 'saleFloorBps'); bad({ feeToBuybackBps: 10001 }, 'feeToBuybackBps'); bad({ auctionDuration: 6 * 3600 - 1 }, 'auctionDuration');
  bad({ buybackSlice: 2.01 }, 'buybackSlice'); bad({ exitAfter: 3599 }, 'exitAfter');
  bad({ rateCap: 1e11 - 1 }, 'rateCap'); bad({ rateCap: 1e15 + 1 }, 'rateCap');
  bad({ exitLaneToBuybackBps: 10001 }, 'exitLaneToBuybackBps');
  assert.equal(firstViolation(Object.assign({}, SETTINGS, { spendCapBps: 5000, dropBps: 500, avgScore: 6000000, saleFloorBps: 1000, feeToBuybackBps: 10000, auctionDuration: 6 * 3600, buybackSlice: 2, exitAfter: 3600, rateCap: 1e15 })), null); n++;
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
  assert.equal(c.exitReady(st, 105 * H - 1), false); assert.equal(c.exitReady(st, 105 * H), true); n += 2; // exitAfter 105 hours, the hour the asking price reaches its floor
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
// skim schedule: anti sniper 90 points falling to the 6.9 point baseline over 30 minutes. the router gets 90 percent of the baseline
// plus the whole extra, a flush tip comes out of the engine's part and after the split start the payee takes 161,031 ppm of the gross inflow
{
  near(skimFraction(DEFAULTS, 0), 0.9, 1e-12, 'launch skim'); near(skimFraction(DEFAULTS, 900), (0.9 + 0.069) / 2, 1e-12, 'midway');
  near(skimFraction(DEFAULTS, 1800), 0.069, 1e-12, 'end of window'); near(skimFraction(DEFAULTS, 99999), 0.069, 1e-12, 'baseline');
  near(routerFeeFraction(DEFAULTS, 0.069), 0.0621, 1e-12, 'router 6.21 points'); near(routerFeeFraction(DEFAULTS, 0.9), 0.0621 + 0.831, 1e-12, 'extra to the router');
  const tip = 1 - 5000 / 1e6;
  near(engineFeeFraction(DEFAULTS, 0.069, 3600), 0.0621 * (1 - 5000 / 1e6 - 161031 / 1e6), 1e-12, 'engine share after the split start');
  near(engineFeeFraction(DEFAULTS, 0.069, 3600) * 1e3, 51.7905, 1e-3, 'engine 5.18 points of 1 eth is 51.79 finney');
  near(engineFeeFraction(DEFAULTS, 0.9, 0), (0.0621 + 0.831) * tip, 1e-12, 'the window is not shared with the payee');
  near(engineFeeFraction(DEFAULTS, 0.069, 1799), 0.0621 * tip, 1e-12, 'nor is anything before the split start');
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
  for (const r of [a, simulate({ days: 40, flatBps: 0, floorBps: 6000, saleFloorBps: 6000, seed: 5 }), simulate({ days: 40, buyOnly: true, feeToBuybackBps: 2500, seed: 6 }), simulate({ days: 40, buyerWaits: 'floor', feeToBuybackBps: 10000, seed: 8 }), simulate({ days: 40, phase2Day: 12, xp: 3e-5, stmtPick: 'random' })]) {
    ok(Math.abs(r.stats.potCheck) < 1e-6, 'pot accounting ' + r.stats.potCheck);
    ok(Math.abs(r.stats.buybackCheck) < 1e-9, 'buyback accounting ' + r.stats.buybackCheck);
    ok(Math.abs(r.stats.houseCheck) < 1e-9, 'house accounting ' + r.stats.houseCheck);
    for (const k of ['pot', 'toBuyback', 'locked', 'burned', 'pending']) ok(r.S[k].every((x) => x >= -1e-12), k + ' negative');
    ok(r.S.burned[r.H] <= 1e9);
  }
  // the engine never stops buying because statements are unsold: no buyers at all, statements pile up, credits keep coming
  const none = simulate({ days: 30, stmtPerDay: 0, stmtFloorPerDay: 0, seed: 3 });
  ok(none.T.sold === 0 && none.S.waiting[none.H] > 100, 'no statement sells, many wait');
  ok(none.S.credits[none.H] > 0.8 * simulate({ days: 30, seed: 3 }).S.credits[30 * 24], 'credits keep coming with no sale at all, at least 80 percent of the base run at day 30');
  // every sale clears at or above the hard floor (cost * saleFloorBps) and at or above the price the buyer saw
  const e = simulate({ days: 30, seed: 3 });
  ok(e.T.sold > 0 && e.T.soldPrice >= e.T.soldFloor * (1 - 1e-9), 'sales clear at or above the hard floor');
  ok(e.stats.bidsPerSale >= 1, 'every sale has at least one bid');
  ok(e.stats.saleOverCost >= 0.75 && e.stats.saleOverCost <= 1.2, 'average sale price over cost sits between the floor and the start');
  // buy only: every sale is one instant payment, no bid, nothing waits in the house, no auction is ever live
  const bo = simulate({ days: 30, seed: 3, buyOnly: true });
  ok(bo.T.sold > 0 && bo.T.soldInstant === bo.T.sold, 'every buy only sale is instant'); assert.equal(bo.stats.bidsPerSale, 1); assert.equal(bo.live.length, 0); n += 2;
  ok(bo.S.pending.every((x) => x === 0), 'nothing waits in the house in buy only mode'); ok(bo.T.soldPrice >= bo.T.soldFloor * (1 - 1e-9), 'buy only sales clear at the hard floor or above');
  ok(e.T.soldInstant === 0, 'auction mode has no instant sales');
  // the pessimistic run: a buyer who waits for the floor pays the lowest price of every statement it takes, and none sells young
  const wf = simulate({ days: 30, seed: 3, buyerWaits: 'floor' });
  ok(wf.T.sold > 0 && Math.abs(wf.stats.saleOverCost - 0.75) < 1e-9 && wf.stats.saleAtFloorShare === 1, 'waiting buyers pay the floor');
  ok(wf.stats.saleAgeHours >= 105, 'and only after the asking price has reached it');
  // a settings change mid run: controller settings on day 5, the mode and the floors on day 10, all read at once
  const sw = simulate({ days: 20, seed: 3, schedule: [{ day: 5, patch: { flatBps: 5000, startBps: 13000, stepBps: 200 } }, { day: 10, patch: { floorBps: 6000, saleFloorBps: 6000, buyOnly: true, feeToBuybackBps: 2500, saleToBuybackBps: 7500 } }] });
  assert.equal(sw.core.s.flatBps, 5000); assert.equal(sw.core.c.floorBps, 6000); assert.equal(sw.core.s.saleFloorBps, 6000); assert.equal(sw.core.c.buyOnly, true); n += 4;
  assert.equal(sw.core.c.startBps, 13000); assert.equal(sw.core.s.saleToBuybackBps, 7500); assert.equal(sw.core.s.feeToBuybackBps, 2500); assert.equal(sw.T.settingsChanges, 2); n += 4;
  ok(sw.T.soldInstant > 0 && sw.T.soldInstant < sw.T.sold, 'sales before the flip went through auctions, after it instantly');
  ok(sw.core.feeToBuyback > 0, 'the fee share starts at its change'); ok(Math.abs(sw.stats.potCheck) < 1e-6, 'accounting closes across settings changes');
  ok(Math.abs(sw.stats.buybackCheck) < 1e-9, 'buyback accounting closes across settings changes');
  const f0 = simulate({ days: 20, seed: 3 }), f1 = simulate({ days: 20, seed: 3, feeToBuybackBps: 10000 });
  assert.equal(f0.core.feeToBuyback, 0); ok(f1.core.feeToBuyback > 0.9 * f1.S.cumFees[f1.H], 'at 10000 every fee goes to the buyback'); n++;
  ok(f1.T.sold >= 0 && f1.S.credits[f1.H] < f0.S.credits[f0.H], 'sending the fees to the buyback leaves less to buy credits');
  // the buyer's willingness to pay is a multiple of the MARKET cost of 80 credits, the asking price a share of what the engine PAID: a low willingness
  // sells less under the same asking curve (the engine paid more than market for most parts), and lowering the asking curve lets it buy again
  const w55 = simulate({ days: 30, seed: 3, wtpMult: 0.55 }), w100 = simulate({ days: 30, seed: 3 });
  ok(w55.T.sold > 0 && w55.T.sold < 0.7 * w100.T.sold, 'a lower willingness to pay sells fewer statements at the same asking prices');
  const w55low = simulate({ days: 30, seed: 3, wtpMult: 0.55, startBps: 5000, floorBps: 3000, saleFloorBps: 3000 });
  ok(w55low.T.sold > 1.8 * w55.T.sold, 'the same buyers buy more when the asking curve is lower'); ok(w55low.stats.saleOverCost < 0.5, 'and they pay a lower share of cost');
  const p2 = simulate({ days: 30, phase2Day: 10, xp: 3e-5, seed: 3 });
  ok(p2.T.exited > 0 && p2.T.exitedAge > 0, 'unbid listings exit through the exitModule');
  const s = summary(a); ok(s.credits > 0 && s.potGoneDay > 1 && s.statements > 0, 'summary reads the run');
}
// sub-hour step: the default is the hourly step, minute and five minute steps give the same economy within sampling noise, and the books close
{
  const h = simulate({ days: 30, seed: 1 }), h2 = simulate({ days: 30, seed: 1, stepSec: 3600 });
  assert.deepEqual(h.S.credits, h2.S.credits); n++;
  const m5 = simulate({ days: 30, seed: 1, stepSec: 300 }), m1 = simulate({ days: 30, seed: 1, stepSec: 60 });
  for (const m of [m5, m1]) {
    const c = m.S.credits[m.H], c0 = h.S.credits[h.H];
    ok(c > 0.9 * c0 && c < 1.1 * c0, 'credits bought at a sub hour step stay within 10 percent of the hourly step');
    ok(Math.abs(m.stats.potCheck) < 1e-6 && Math.abs(m.stats.houseCheck) < 1e-6, 'accounting closes at a sub hour step');
    assert.equal(m.S.pot.length, h.S.pot.length); n++;
  }
  assert.throws(() => simulate({ days: 2, stepSec: 7 })); n++;
}
// bid rules dropToLast and stepped
{
  const R = 1e13, MIN = 60;
  const mk = (over) => fresh(Object.assign({ rateStart: R, spendCapBps: 5000 }, over), 1000);
  // dropToLast: a fill sets the bid to dropToPct of the rate that fill paid, whatever share of the pot it spent; the climb is climbPerMin per minute
  {
    const c = mk({ bidRule: 'dropToLast', dropToPct: 80, climbPerMin: 1 });
    near(c.ethRate(0), R, 1e-12, 'dropToLast opens at rateStart');
    near(c.ethRate(30 * MIN), R * Math.pow(1.01, 30), 1e-12, 'dropToLast climbs 1 percent a minute before any fill');
    ok(c.spend(0.001, 30 * MIN));
    near(c.rateAtCheckpoint, R * Math.pow(1.01, 30) * 0.8, 1e-12, 'a one credit fill drops the bid to 80 percent of the rate paid');
    const r1 = c.rateAtCheckpoint;
    near(c.ethRate(30 * MIN + 10 * MIN), r1 * Math.pow(1.01, 10), 1e-12, 'climb after 10 minutes');
    ok(c.spend(100, 30 * MIN + 10 * MIN));
    near(c.rateAtCheckpoint, r1 * Math.pow(1.01, 10) * 0.8, 1e-12, 'a fill of a tenth of the pot drops to the same 80 percent');
    const c2 = mk({ bidRule: 'dropToLast', dropToPct: 90, climbPerMin: 2 });
    ok(c2.spend(0.001, 0)); near(c2.rateAtCheckpoint, R * 0.9, 1e-12, 'dropToPct 90');
    near(c2.ethRate(5 * MIN), R * 0.9 * Math.pow(1.02, 5), 1e-12, 'climbPerMin 2');
  }
  // stepped: a fixed drop per credit, a floor of dropToPct of the bid at the first fill of the timestamp, a ceiling of ceilPct of the last rate paid
  {
    const c = mk({ bidRule: 'stepped', dropPerCreditPct: 0.5, dropToPct: 80, climbPerMin: 1, ceilPct: 125 });
    ok(c.spend(0.001, 0));
    near(c.rateAtCheckpoint, R * 0.995, 1e-12, 'one credit drops the bid 0.5 percent');
    ok(c.spend(0.001, 0)); near(c.rateAtCheckpoint, R * 0.995 * 0.995, 1e-12, 'a second credit in the same minute drops it again');
    for (let i = 0; i < 100; i++) c.spend(0.001, 0);
    near(c.rateAtCheckpoint, R * 0.8, 1e-12, 'a burst of fills in one minute cannot drop the bid below 80 percent of the bid at its first fill');
    // the next minute opens a new burst from the current bid
    c.spend(0.001, 60); near(c.rateAtCheckpoint, R * 0.8 * 1.01 * 0.995, 1e-9, 'a new timestamp starts a new burst, after one minute of climb');
    // ceiling: the bid never climbs above 125 percent of the last rate paid
    near(c.ethRate(60 + 1000 * MIN), c.lastPaidRate * 1.25, 1e-12, 'ceiling is ceilPct of the last rate paid');
    near(c.lastPaidRate, R * 0.8 * 1.01, 1e-9, 'the last rate paid is the rate of the last fill');
    // climb below the ceiling: 10 minutes at 1 percent
    const t = 60 + 1000 * MIN; c.checkpoint(t); c.spend(0.001, t);
    const r0 = c.rateAtCheckpoint; near(c.ethRate(t + 10 * MIN), Math.min(r0 * Math.pow(1.01, 10), c.lastPaidRate * 1.25), 1e-12, 'climb after 10 minutes');
    // before any fill the ceiling is the opening bid times ceilPct
    const d = mk({ bidRule: 'stepped', climbPerMin: 2, ceilPct: 110 });
    near(d.ethRate(1000 * MIN), R * 1.1, 1e-12, 'opening ceiling is rateStart times ceilPct');
    near(d.ethRate(3 * MIN), R * Math.pow(1.02, 3), 1e-12, 'climb 2 percent a minute');
  }
  // the built rule is unchanged by the new params
  {
    const c = mk({ bidRule: 'built', dropPerCreditPct: 5, dropToPct: 10, climbPerMin: 50 });
    ok(c.spend(100, 0)); near(c.rateAtCheckpoint, R * (1 - 0.2 * 100 / 1000), 1e-12, 'built drop is dropBps times the share of the pot');
    near(c.ethRate(3600), c.rateAtCheckpoint * 1.01, 1e-12, 'built climb is 1 percent an hour');
  }
  // whole runs: books close, the stepped bid never exceeds its ceiling at a step end, the throttler sells at its fraction of the market
  const rs = (share) => (share * 0.0089e18) / 433;
  for (const o of [{ bidRule: 'dropToLast' }, { bidRule: 'stepped', ceilPct: 110 }]) {
    const r = simulate(Object.assign({ days: 6, seed: 2, stepSec: 60, rateStart: rs(1), climbPerMin: 1 }, o));
    ok(Math.abs(r.stats.potCheck) < 1e-6 && Math.abs(r.stats.houseCheck) < 1e-6, 'accounting closes under ' + o.bidRule);
    ok(r.S.credits[r.H] > 0 && r.stats.idleHoursMax >= 0);
    if (o.bidRule === 'stepped') ok(r.core.ethRate(r.H * 3600) <= r.core.lastPaidRate * 1.1 * (1 + 1e-9) || r.core.ethRate(r.H * 3600) <= r.p.rateStart * 1.1, 'stepped ceiling at the end of a run');
  }
  const a = simulate({ days: 4, seed: 2, stepSec: 60, bidRule: 'dropToLast', rateStart: rs(1) }), b = simulate({ days: 4, seed: 2, stepSec: 60, bidRule: 'dropToLast', rateStart: rs(1), throttler: true });
  ok(a.T.throttled === 0 && b.T.throttled > 0, 'the throttler sells credits when on');
  ok(Math.abs(b.stats.potCheck) < 1e-6, 'accounting closes with the throttler');
  // market paths
  const q = (path, h, o = {}) => pathPrice(Object.assign({}, DEFAULTS, { pricePath: path }, o), h * 3600) / DEFAULTS.priceP0;
  near(q('falling', 24), 0.5, 1e-12, 'falling halves over day one'); near(q('falling', 500), 0.5, 1e-12, 'falling stays flat after');
  near(q('rising', 7 * 24), 2, 1e-12, 'rising doubles over 7 days'); near(q('rising', 24 * 30), 2, 1e-12, 'rising stays flat after');
  near(q('whipsaw', 48), 1, 1e-12, 'whipsaw before the fall'); near(q('whipsaw', 60), 0.4, 1e-12, 'whipsaw falls 60 percent in 12 hours');
  near(q('whipsaw', 108), 1, 1e-12, 'whipsaw recovers over 2 days'); near(q('whipsaw', 300), 1, 1e-12, 'whipsaw flat after');
}
// clampCredits, ceilDecayHours, askFloor
{
  const R = 1e13, MIN = 60;
  const c1 = fresh({ rateStart: R, bidRule: 'stepped', climbPerMin: 50, ceilPct: 1000, spendCapBps: 2000 }, 0.1), c20 = fresh({ rateStart: R, bidRule: 'stepped', climbPerMin: 50, ceilPct: 1000, spendCapBps: 2000, clampCredits: 20 }, 0.1);
  near(c1.clamp(), 0.1 * W * 2000 / 4330000, 1e-12, 'clamp affords one average credit'); near(c20.clamp(), c1.clamp() / 20, 1e-12, 'clampCredits 20 divides the clamp by 20');
  const d = fresh({ rateStart: R, bidRule: 'stepped', climbPerMin: 100, ceilPct: 150, ceilDecayHours: 1 }, 1000);
  near(d.ethRate(10 * 3600), R * (1 + 0.5 * Math.pow(2, -10)), 1e-12, 'no fill yet: headroom halves every hour from time zero');
  d.spend(0.001, 0); const lp = d.lastPaidRate;
  near(d.ethRate(3600), Math.min(R * 0.995 * Math.pow(2, 60), lp * 1.25), 1e-9, 'after one half life the headroom is halved');
  const f = simulate({ days: 3, seed: 2, askFloor: 0.8 });
  const g = simulate({ days: 3, seed: 2 }); ok(f.stats.costVsMarket >= g.stats.costVsMarket - 0.2, 'a floor on seller asks does not lower the price paid');
}
// idle loosening of the stepped ceiling anchor, gap path, forced fill, bot drain, stall metric
{
  const R = 1e13, MIN = 60;
  const c = fresh({ rateStart: R, bidRule: 'stepped', climbPerMin: 100, ceilPct: 110, idleLoosenPct: 1, idleLoosenMin: 10 }, 1000);
  near(c.ethRate(5 * MIN), R * 1.1, 1e-12, 'before the first interval the ceiling is ceilPct of the anchor');
  near(c.ethRate(25 * MIN), R * 1.1 * (1 + 0.01 * 2), 1e-12, 'two idle intervals raise the anchor by 1 percent of itself each, linearly');
  ok(c.spend(0.001, 25 * MIN)); const lp = c.lastPaidRate;
  near(c.ethRate(25 * MIN + 9 * MIN), Math.min(c.rateAtCheckpoint * Math.pow(2, 9), lp * 1.1), 1e-12, 'a fill resets the idle clock');
  near(c.ethRate(25 * MIN + 31 * MIN), lp * 1.1 * (1 + 0.01 * 3), 1e-12, 'three intervals after the fill');
  const o = fresh({ rateStart: R, bidRule: 'stepped', climbPerMin: 100, ceilPct: 110 }, 1000);
  near(o.ethRate(10000 * MIN), R * 1.1, 1e-12, 'idleLoosenPct 0 leaves the ceiling at ceilPct of the anchor');
  const q = (h, g) => pathPrice(Object.assign({}, DEFAULTS, { pricePath: 'gap', gapPct: g, gapHour: 6 }), h * 3600) / DEFAULTS.priceP0;
  near(q(5.9, 30), 1, 1e-12, 'gap path before the jump'); near(q(6, 30), 1.3, 1e-12, 'gap path after the jump'); near(q(80, 100), 2, 1e-12, 'gap path stays');
  const rs = (share) => (share * 0.0089e18) / 433;
  const base = { days: 2, seed: 2, stepSec: 60, bidRule: 'stepped', rateStart: rs(1), clampCredits: 20 };
  const ff = simulate(Object.assign({ forceFillHour: 6, forceFillFrac: 0.5 }, base));
  ok(Math.abs(ff.stats.potCheck) < 1e-6, 'accounting closes with a forced fill'); ok(ff.T.throttled === 0, 'a forced fill is not counted as a throttler credit');
  const bd = simulate(Object.assign({ botDrain: true, holdPot: 5, volScale: 0, strategyOn: false }, base));
  ok(bd.S.credits[bd.H] > 0 && bd.stats.gapHoursMax <= 1.01, 'with a bot draining the hourly cap each hour the longest gap is about an hour (pacing)');
  const st0 = simulate(Object.assign({ pricePath: 'gap', gapPct: 300, gapHour: 6, idleLoosenPct: 0, days: 3 }, { seed: 2, stepSec: 60, bidRule: 'stepped', rateStart: rs(1), clampCredits: 20 }));
  const st1 = simulate(Object.assign({ pricePath: 'gap', gapPct: 300, gapHour: 6, idleLoosenPct: 2, days: 3 }, { seed: 2, stepSec: 60, bidRule: 'stepped', rateStart: rs(1), clampCredits: 20 }));
  ok(st0.stats.stallHours > st1.stats.stallHours, 'idle loosening shortens the stall after a gap up'); ok(st0.stats.stallRuns.length >= 1 && st0.stats.stallHoursMax > 2, 'a stall run is recorded');
  const hp = simulate(Object.assign({ holdPot: 0.1, volScale: 0, strategyOn: false, priceP0: 0.03, rateStart: rs(1) * 0.03 / 0.0089 }, base, { rateStart: (0.03e18) / 433, days: 4 }));
  ok(hp.stats.stallHours > 0, 'a pot of 0.1 eth at a 0.03 market with clampCredits 20 stalls');
}
// stepped: the clamp bounds the bid that is read and paid, and is never stored. the drop and the anchor use the price state rate
{
  const R = 1e13, MIN = 60;
  const c = fresh({ rateStart: R, bidRule: 'stepped', climbPerMin: 1, ceilPct: 125, clampCredits: 20, spendCapBps: 2000 }, 0.1);
  const clamp = c.clamp(); ok(clamp < R / 3, 'the clamp of a 0.1 eth pot is far under the stored rate');
  near(c.ethRate(0), clamp, 1e-12, 'the read bid is held at the clamp');
  near(c.priceRate(0), R, 1e-12, 'the price state rate is the stored rate');
  const paid = c.sellForEth(440, 0); near(paid, (433 * clamp) / W, 1e-12, 'a fill pays the read (clamped) bid');
  near(c.lastPaidRate, R, 1e-12, 'the anchor is the price state rate at the fill, not the clamped bid');
  near(c.rateAtCheckpoint, R * 0.995, 1e-12, 'the drop applies to the price state rate');
  c.addFees(1000, 10 * MIN);
  near(c.ethRate(10 * MIN), R * 0.995, 1e-12, 'the price state held its value while above the clamp, it did not climb');
  near(c.ethRate(20 * MIN), Math.min(R * 0.995 * Math.pow(1.01, 10), R * 1.25), 1e-9, 'once the pot affords it the price state climbs again from the held value');
  const e = fresh({ rateStart: R / 10, bidRule: 'stepped', climbPerMin: 1, ceilPct: 1000, clampCredits: 20, spendCapBps: 2000 }, 0.1);
  near(e.priceRate(1000 * MIN), e.clamp(), 1e-12, 'the climb target is the clamp when it is under the ceiling'); near(e.ethRate(1000 * MIN), e.clamp(), 1e-12, 'read at the clamp');
  const d = fresh({ rateStart: R, bidRule: 'stepped', climbPerMin: 1, ceilPct: 125, clampCredits: 20, spendCapBps: 2000, rateCap: R * 1.2 }, 1000);
  near(d.ethRate(100 * MIN), R * 1.2, 1e-12, 'rateCap bounds the price state'); d.rateAtCheckpoint = R * 3; near(d.ethRate(100 * MIN), R * 1.2, 1e-12, 'a stored rate above a bound reads as the bound');
}
console.log(`ok, ${n} checks passed`);
