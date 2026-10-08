# simulation of the credits engine

sim/engine.js is a deterministic hourly model of the engine in src/Core.sol and src/ControllerV1.sol on branch flow: the blended bid (`flatBps`, `avgScore`), the rate climb, the funded rule, drop on fill, the hourly cap, both buy doors, compose, the statement asking price (controller settings `startBps`, `stepBps`, `stepEvery`, `floorBps`, `buyOnly`) with the Core's hard floor `saleFloorBps`, the english auction on the pnd auction house, instant sales in buy only mode, `collectSales`, the swap fee share `feeToBuybackBps`, the buyback, the exit lane, the exitToken bid, the exitToken dutch auction and settings changes mid run. rules and names are the contracts' (docs/FLOW.md section 9), launch values are script/config/mainnet.json (a test reads the file). the launch position is real concentrated liquidity math. sellers, statement buyers and coin volume are calibrated on the 13 day data pull in sim/data/notes.md. every number below is a mean over 3 to 5 seeds of a 90 day run unless stated. raw rows are in sim/results/*.json (node run.mjs q1 to q11), the interactive page is sim/index.html. `exitModule` and `exitToken` are the only names used for phase 2. the owner sets the exitModule, the controller and the allowed targets at once: there is no wait of any kind in the model.

## base case, before and after

before is the previous version of this file (fixed auction reserve of 90 percent of cost, `exitAfter` 72 hours, all fees to the pot). after is the launch settings of docs/FLOW.md section 9: asking price 110 percent of cost falling one point every 3 hours to 75 percent at hour 105, auction mode, hard floor 7500, `exitAfter` 105 hours, `feeToBuybackBps` 0. comparable coin volume, 5 seeds, day 90.

| base case, comparable volume, day 90 | before (old rules) | launch rules, v1 fee path (9.5 points) | v2 launch (6.9 points, router) |
| --- | --- | --- | --- |
| credits bought | 27,110 | 28,800 | 23,840 |
| statements created | 339 | 359 | 298 |
| statements sold | 121 | 158 | 137 |
| average sale price over cost | 92% | 91% | 91% |
| statements waiting | 216 | 201 | 159 |
| eth to burn | 31.3 | 42.2 | 35.9 |
| eth recycled by sales | 62.6 | 84.4 | 71.9 |
| launch pot spent on day | 6.5 | 6.5 | 5.9 |
| percent of supply burned | 8.1% | 10.0% | 9.2% |
| steady credits a day after the pot | 46 | 49 | 44 |

the new rules sell 37 more statements (158 against 121) at the same average price over cost (91 against 92 percent), so eth recycled by sales rises from 62.6 to 84.4 and eth to burn from 31.3 to 42.2 (10.0 percent of the coin, was 8.1). credits rise 6 percent (28,800 against 27,110) because half of every sale goes back to the pot. the launch pot is spent on day 6.5 in both: the sale side does not touch week one. why more sell: the old reserve was one price, 90 percent of cost. the buyers' willingness to pay is a multiple of the market cost of the parts, median 0.84, and the engine paid about 1.04 times market, so the median buyer can pay about 81 percent of cost. under the new curve that price is reached at about hour 90 and that buyer buys. a statement is now offered to every buyer from 110 percent down to 75 percent of cost, and the oldest statements sit at the cheapest price.

the third column is the v2 launch (docs/FLOW.md section 10). a trader pays 6.9 points of volume, not 10, and the engine no longer gets 9.5 of them. the pool pays 6.21 points (90 percent of the baseline skim, plus all of the anti sniper extra) to the fee router. a flush tip takes 0.5 percent of that, and from 30 minutes after launch (the end of the anti sniper window, the split start is the mined launch time plus the window) the single payee takes 161,031 parts per million of the gross inflow, and the tip comes out of the engine's part. the engine therefore books 5.18 points of volume in steady state, and the whole router inflow less the tip inside the window. there is no lp income: the launch lp fee is 0 and no fee swapper exists. the rerun, 5 seeds, day 90: fees booked fall from 297 eth to 220 (down 26 percent), credits bought from 28,800 to 23,840 (down 17 percent), statements created from 359 to 298, sold from 158 to 137, eth to burn from 42.2 to 35.9 and the share of the coin burned from 10.0 to 9.2 percent. the sale side per statement does not move (average price 91 percent of cost). the launch pot is spent on day 5.9 where it was 6.5, because the window extra is unchanged and the baseline share is smaller. (the model now follows the final router: payee on the gross inflow, 161,031 ppm, split start at the window end; the stored results were generated just before that refinement, which moves the engine share from 5.184 to 5.179 points, 0.1 percent, below seed noise.) the model sets the tip at its 0.5 percent upper bound (the 0.005 eth cap per flush is ignored) and assumes the router is flushed as fees arrive.

## sensitivity rows (comparable volume, 5 seeds, day 90)

the rows here and the tables of sections 1 and 7 are rerun on the v2 fee path (all batches in sim/results were regenerated with `node sim/run.mjs`). the reading notes under the tables and every figure quoted in prose, and the tables of sections 2 to 6 and 8 to 10, still quote the previous run on the v1 fee path (9.5 points to the engine): treat their figures as stale and read the direction; the json files hold the new numbers. the direction of every effect named in them holds in the rerun (checked against the rows: `startBps` and `stepEvery` move the average price and eth recycled, the hard floor binds when only `floorBps` is lowered, buy only sells more than auction, `feeToBuybackBps` is a strong burn dial that costs credits, the pessimistic buyer sells more at the floor). absolute credits are 17 percent lower at comparable volume.

launch is `startBps` 11000, `stepEvery` 3 hours, `stepBps` 100, `floorBps` 7500, `saleFloorBps` 7500, auction mode, `feeToBuybackBps` 0. eth to burn is eth spent buying and burning the coin. differences in credits under 2 percent are seed noise.

| setting | credits bought | statements created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | sold at the lowest price |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **launch: 11000 / 3h / 7500, auction, fee share 0** | 23,840 | 298 | 137 | 91% | 159 | 35.9 | 71.9 | 25% |
| `startBps` 9000 | 23,510 | 293 | 140 | 81% | 152 | 33.9 | 67.8 | 36% |
| `startBps` 13000 | 25,390 | 317 | 159 | 100% | 157 | 45.3 | 90.6 | 17% |
| `stepEvery` 1 hour | 23,680 | 295 | 139 | 85% | 155 | 34.7 | 69.4 | 38% |
| `stepEvery` 6 hours | 24,540 | 306 | 147 | 96% | 159 | 40.5 | 81.0 | 13% |
| `floorBps` 7500 with `saleFloorBps` 7500 | 23,840 | 298 | 137 | 91% | 159 | 35.9 | 71.9 | 25% |
| `floorBps` 6000 with `saleFloorBps` 7500 | 23,840 | 298 | 137 | 91% | 159 | 35.9 | 71.9 | 25% |
| `floorBps` 5000 with `saleFloorBps` 7500 | 23,840 | 298 | 137 | 91% | 159 | 35.9 | 71.9 | 25% |
| `floorBps` and `saleFloorBps` both 6000 | 24,730 | 309 | 170 | 80% | 138 | 41.1 | 82.1 | 25% |
| `floorBps` and `saleFloorBps` both 5000 | 25,440 | 318 | 200 | 70% | 117 | 45.3 | 90.7 | 26% |
| buy only mode | 25,410 | 317 | 179 | 90% | 138 | 48.6 | 97.3 | 29% |
| `feeToBuybackBps` 1000 | 22,950 | 286 | 143 | 91% | 143 | 60.0 | 75.4 | 25% |
| `feeToBuybackBps` 2500 | 21,380 | 267 | 149 | 91% | 117 | 95.6 | 78.9 | 24% |
| `feeToBuybackBps` 5000 | 18,000 | 225 | 153 | 92% | 70 | 154.1 | 80.7 | 25% |
| pessimistic: every buyer waits for the floor, auction mode | 25,050 | 313 | 172 | 75% | 139 | 39.0 | 78.1 | 100% |
| pessimistic: every buyer waits for the floor, buy only mode | 24,260 | 303 | 159 | 75% | 143 | 35.6 | 71.3 | 100% |

the same rows at 17 eth a day of coin volume, 3 seeds (the launch row is the 5 seed run):

| sustained 17 eth a day, day 90 | credits bought | statements created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | sold at the lowest price |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| launch (5 seed run) | 35,560 | 444 | 219 | 83% | 224 | 48.5 | 97.0 | 54% |
| `startBps` 9000 | 34,750 | 434 | 205 | 79% | 228 | 42.4 | 84.8 | 59% |
| `startBps` 13000 | 35,410 | 442 | 210 | 83% | 229 | 47.5 | 95.1 | 56% |
| `stepEvery` 1 hour | 35,230 | 440 | 219 | 79% | 218 | 45.8 | 91.6 | 68% |
| `stepEvery` 6 hours | 35,130 | 439 | 198 | 85% | 239 | 45.1 | 90.1 | 44% |
| both floors 6000 | 34,790 | 434 | 228 | 68% | 204 | 42.9 | 85.9 | 48% |
| both floors 5000 | 34,350 | 429 | 235 | 61% | 193 | 40.0 | 80.0 | 51% |
| buy only mode | 35,980 | 449 | 244 | 84% | 205 | 55.8 | 111.6 | 45% |
| `feeToBuybackBps` 1000 | 33,320 | 416 | 212 | 82% | 203 | 74.9 | 93.7 | 54% |
| `feeToBuybackBps` 2500 | 30,350 | 379 | 219 | 84% | 159 | 119.7 | 97.8 | 46% |
| `feeToBuybackBps` 5000 | 24,180 | 302 | 205 | 89% | 95 | 191.1 | 95.3 | 21% |
| pessimistic, auction | 35,340 | 441 | 217 | 75% | 222 | 43.8 | 87.5 | 100% |

reading the rows:

1. **`startBps` and `stepEvery` set the average price, not the credits.** 9000 against 13000 moves the average sale price from 82 to 96 percent of cost, eth recycled from 68 to 92 and eth to burn from 34 to 46, for 7 percent more credits (the recycled eth goes back to the pot). a slower fall (6 hours a step) is the same dial: 95 percent, 87.5 eth recycled. a fast fall (1 hour a step) gives 84 percent and 69 eth. a low or fast curve also sells fewer statements, not more (141 to 142 against 158 to 165). the reason is the buyer rule: a buyer takes the lowest asking price that fits, which is often a live auction at the 5 percent raise, and a second bid uses up a buyer without selling a statement. second bidders reach 27 percent of auctions at 9000, 19 at 11000 and 15 at 13000. at 17 eth a day there are more statements than buyers, only 2 percent of auctions get a second bid and the dial does nothing to eth recycled (100 to 102).
2. **the hard floor binds.** with `saleFloorBps` at 7500 a `floorBps` of 6000 or 5000 changes nothing, the rows are identical to launch: the price used is never below the Core's floor. to sell lower the owner must lower both. both at 6000: 174 sold (10 percent more), 80 percent of cost, eth recycled unchanged (84.7), burn unchanged. both at 5000: 201 sold, 73 percent, 93 eth recycled (11 percent more than launch, a single row, treat it as a small gain at most). at 17 eth a day lowering both costs eth: recycled 102 to 91 to 83, burn 51 to 46 to 42, credits down 3 percent at 5000. at comparable volume a lower floor sells more statements for about the same eth (demand close to unit elastic in the observed willingness to pay), as the old reserve did. a cut on day 14 beats a cut at launch (section 4).
3. **buy only against auction.** buy only sells 185 against 158 (17 percent more), recycles 98 against 84 and burns 49 against 42, credits 29,660 against 28,800. two causes: no buyer is used up on a second bid, and the proceeds reach the pots at once instead of at the next hourly `collectSales` (pot spent day 6.1, was 6.5). at 17 eth a day there is no difference (229 against 225 sold). under random pick the gain is 243 against 234. so the mode is a small edge that shows only when buyers are scarce and pile onto live auctions. buy only also removes the chance of a bidding contest, which the model barely finds (1.22 bids a sale).
4. **`feeToBuybackBps` is a launch decision and a strong burn dial.** 1000 sends 30 eth of the 297 eth of fees to the buyback: eth to burn goes from 42 to 71 (the other 41 is from sales), credits fall 4.5 percent. 2500: 117 eth burned (2.8 times launch), credits down 12 percent, statements created 315 instead of 359. 5000: 195 eth, credits down 28 percent. the percent of the coin burned goes 10.0, 22.8, 26.9, 29.7 because later eth buys less supply as the price rises. per extra eth burned the fee share costs about 45 credits at 1000 and 48 at 2500, the sale share about 165 (section 5): measured, not derived. 86 percent of the fees come on day one, so the share only matters while the launch pot is large: switching it to 2500 on day 14 changes nothing (28,560 credits, 43.5 eth burned, launch 28,800 and 42.2).
5. **the pessimistic run: every buyer waits for the floor.** every sale is at 75 percent of cost, hour 331 after listing on average (14 days), and no buyer gets used up on a rebid. in auction mode that sells 179 (more than launch, for the rebid reason), recycles 81.7 eth (3 percent less than launch) and burns 40.8 eth (3 percent less). in buy only mode 167 sell, 75.5 recycled, 37.8 burned. at 17 eth a day the cost is larger: 204 sold, 86 eth recycled (16 percent less), burn 43 (16 percent less), credits 46,540 (1 percent less). so waiting for the floor costs 3 percent of the sale side when buyers are scarce and 16 percent when statements are plentiful, and the credits barely move in either case: at comparable volume the eth recycled barely changes, and at 17 eth a day coin fees (1.6 eth a day), not sales, fund the pot after week one. what it does not model: fewer arrivals when the price is not yet attractive, which would make the sale side smaller.

## what the sale model assumes

exactly what the buyers and the sale rules are in sim/engine.js, so the numbers can be challenged:

1. **two prices, never mixed.** a buyer's willingness to pay is a multiple of the MARKET cost of the 80 credits: the calibrated quantiles (p10 0.48, p25 0.71, median 0.84, p75 1.07, 21 percent at 1.2 or more, max 1.32) times `wtpMult` times 80 times the flat market price of a credit on the day the buyer arrives (including the lift from the engine's own buying). the asking price is a share of what the ENGINE PAID: the statement cost, the sum of the costs of its 80 credits plus the compose reimbursement. the engine pays about 1.04 times market on comparable volume and 0.92 on sustained 17 eth a day, so the same buyer clears a different share of cost in each case.
2. **asking price.** steps = floor(age / `stepEvery`), age counted from the listing, a new statement starts at age zero. bps = max(`startBps` minus steps times `stepBps`, `floorBps`) of cost. the price used is never below `saleFloorBps` of cost (the Core's hard floor). launch: 110 percent, 109 at hour 3, 100 at hour 30, 75 from hour 105. the controller settings and the hard floor are read live, a change applies to every listed statement at once.
3. **arrivals and the pick rule are the old ones.** buyers arrive as a Poisson process, 8 a day at launch, halving every 21 days down to 2 a day, whatever the price. each buyer makes one purchase attempt. it takes the statement with the lowest asking price at or under its willingness to pay (`stmtPick` random takes any that fits, section 4 shows both). a buyer that fits nothing leaves for good and is counted as a miss (31 percent of arrivals at launch).
4. **a buyer does not wait strategically.** a buyer who can afford a statement now buys it now, it does not hold back for the price to fall further. this is the optimistic side and the pessimistic run below is its opposite: with `buyerWaits` set to `floor` every buyer only buys a statement whose asking price has reached its lowest level (the higher of `floorBps` and `saleFloorBps`) and nobody bids on a live auction.
5. **auction mode (launch).** a buyer at or above the asking price opens the english auction at that price: the first bid is the asking price at that moment (the first bidder reprices the listing to it first). `auctionDuration` 24 hours runs from the first bid, a later bidder must have a higher willingness to pay than the top bidder and bid 5 percent more, a bid in the last 15 minutes extends the end to 15 minutes from the bid. the proceeds are credited to the Core in the house and reach the pots when `collectSales` runs (an hourly keeper), split by `saleToBuybackBps`. a statement with a bid never exits through the exitModule.
6. **buy only mode.** the buyer pays the asking price through `sellTo` and gets the statement at once. the proceeds are booked into the pots in the same call, split by `saleToBuybackBps`, nothing waits in the house. a house listing in this mode sits at the start price, and a bid straight on the house at that price is not modelled: buyers use the controller.
7. **fee share.** all swap fee eth reaches the Core through `receive()`: `feeToBuybackBps` of it goes to the buyback pot and the rest to the pot. fees from the buyback's own swaps and from the exitToken auction takers count the same. eth booked later by `skim()` goes to the pot as today and is not modelled separately.
8. **keepers and nothing else.** `collectSales` runs every hour, `endAuction` is called the moment an auction ends, the buyback keeper runs every 25 blocks. a statement is only ever sold once, a house delivery failure is not modelled.

what is not assumed: no buyer reads the curve and decides when to come, and arrivals do not respond to the price level. both are the largest unknowns of the sale side (section 10).

## the goal and the headline metrics

the engine exists to keep credits flowing into statements. a statement selling below the cost of its 80 credits is better than no sale. unsold statements are fine, they wait for the exitModule in phase 2. the engine never stops buying because statements are unsold (there is no inventory gate in the Core and none in the model). early on it should acquire as many credits as possible, score can matter later.

headline metrics, in this order: credits acquired, statements created, statements sold with their average price over cost, statements waiting for phase 2, eth sent to buy and burn the coin (from sales and from fees), eth recycled by sales, days until the launch pot is spent, steady state credits per day after that. the launch pot is spent when the pot falls under 5 percent of its peak. steady state is the last 30 days of a 90 day run.

verdict in one paragraph: **the engine keeps buying under every volume preset, and unsold statements never slow it.** as launched on the comparable coin it acquires 28,800 credits in 90 days, 25,410 of them by day 30, creates 359 statements and sells 158 of them at 91 percent of cost on average. 42 eth buys and burns 10.0 percent of the coin. 201 statements wait for phase 2. the launch pot of about 290 eth is spent on day 6.5. after that the flow is about 49 credits a day, paid for by the 0.05 eth a day the coin still pays and by sale proceeds. a second bidder shows up in 19 percent of the auctions, so in this model the asking price at the moment of the first buyer is the price: the curve walks until a buyer's willingness to pay is reached and nobody bids it up. the sale design is a dial on eth recycled and burn, never on week one.

## what the model changed against the old branch

| piece | now |
|---|---|
| bid | `flatBps` 10000 prices every credit as `avgScore`, 0 prices it by its own score, in between blends. no controller bonus (ControllerV1 returns 0) |
| gate | removed, with every trace. a test checks the source |
| statement price | the controller's asking price: `startBps` 11000 of cost, minus `stepBps` 100 every `stepEvery` 3 hours, to `floorBps` 7500. the Core's `saleFloorBps` 7500 replaces `reserveBps` as the hard floor: the price used is never below it |
| statement sale | auction mode (launch): a buyer at or above the asking price opens the english auction at that price, `auctionDuration` timer from the first bid, 5 percent raise, 15 minute extension. buy only mode: the buyer pays the asking price and gets the statement at once. unbid statements stay listed |
| proceeds | auction: credited to the Core in the house, reach the pots when `collectSales` runs (an hourly keeper). buy only: booked at once. both split by `saleToBuybackBps` |
| fees | `feeToBuybackBps` (launch 0) of the swap fee eth goes to the buyback pot, the rest to the pot |
| phase 2 exit | an unbid listing may exit through the exitModule after `exitAfter` (105 hours, where the asking price reaches its floor), a statement with a bid never. the owner sets the exitModule at once |
| settings | one `Settings` object with the Core's field names plus the controller's five, `schedule` of `{day, patch}` changes them mid run with the Core's checkpoint and bounds |
| opening limit | `rateStart` 1.54e13, 75 percent of the market price of a credit over `avgScore` |
| rate cap | `rateCap` 1.232e14 (8 times `rateStart`): the climb stops at the lower of the funded clamp and `rateCap`, `setRate` refuses above it. the launch runs below it, so the numbers do not depend on it |

port checks: node engine.test.mjs runs 456 numeric checks against hand computed values: the launch values against mainnet.json, climb tiers, the funded rule and clamp, the rate cap, the bounds (the Core's and the controller's), the exit lane reimbursement cap at `rateStart`, drop on fill, hourly cap, the blended ceiling, tip rule, compose reimbursement with the listing gas, the asking price at exact hours (110 at 0, 109 at 3, 100 at 30, 75 at 105 and after), the hard floor winning over a lower curve floor, the auction opening at the accepted price, every english auction rule (5 percent raise, extension, end, winner), buy only being instant, the proceeds split in both modes, the fee share at 0, 2500, 5000 and 10000, conservation of eth, `setSettings` bounds and checkpoint, exit eligibility, the exitToken auction and bid, buyback, the pool, and eth accounting identities over whole runs (pot, buyback pot, house) in both modes.

## model in short

| piece | what it does | calibration |
|---|---|---|
| coin market | exogenous daily volume, buy share, skim 6.9 percent with 5.18 points to the pot after the router's tip and payee (6.21 points to the router), anti sniper 90 to 6.9 percent over 30 minutes, single sided position tick -175000 to 887200 | model price after day one 4.48e-7, observed 4.44e-7 |
| credit sellers | uniform scores 80 to 800, flat ask per credit with lognormal spread 0.27, top tier premium above 740, 150 offers an hour, 5 percent leave an hour, more offers when the bid is above market, a float of 96,800 credits | median 0.0089 eth, p10 0.0069, p90 0.0138 |
| doors | the sell door pays the bid for any credit whose ceiling clears its ask, cheapest ask per bid point first. CreditStrategy listings clear through the listing door with the tip | 13,132 listings at median 0.036 eth |
| statement buyers | arrivals 8 a day decaying to 2, willingness to pay as a multiple of 80 times the MARKET flat price, rating insensitive, one purchase each, no waiting for a lower price. the price they meet is a share of what the engine PAID (assumptions above) | median 0.84, 21 percent at 1.2 or more, max 1.32, from fixed price sales. no data on the curve or on auctions |
| engine to market feedback | engine spend lifts the flat price, elasticity 0.12, half life 48 hours, cap 3x | assumption |
| phase 2 | exitModule pays rating times unitPerPoint, exit lane, exitToken bid by score, dutch auction with takers at a set discount, a keeper exits every eligible listing | assumption |

## 1. the launch configuration as built

| preset | day | credits acquired | statements created | sold | avg sale price over cost | eth spent buying $CC | percent of supply burned | waiting for phase 2 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| comparable decay | 30 | 20,930 | 261 | 86 | 91% | 23.3 | 6.4% | 174 |
|  | 60 | 22,520 | 281 | 115 | 91% | 30.4 | 8.0% | 165 |
|  | 90 | 23,840 | 298 | 137 | 91% | 35.9 | 9.2% | 159 |
| sustained 17 eth a day | 30 | 23,380 | 292 | 108 | 88% | 28.2 | 4.7% | 181 |
|  | 60 | 29,490 | 368 | 164 | 85% | 38.5 | 6.0% | 203 |
|  | 90 | 35,560 | 444 | 219 | 83% | 48.5 | 7.1% | 224 |
| sustained 50 eth a day | 30 | 28,620 | 357 | 111 | 80% | 27.9 | 4.7% | 243 |
|  | 60 | 41,750 | 521 | 171 | 78% | 40.4 | 6.2% | 349 |
|  | 90 | 54,580 | 682 | 220 | 78% | 50.5 | 7.3% | 460 |
| dead after week one | 30 | 20,390 | 255 | 83 | 90% | 22.7 | 5.9% | 171 |
|  | 60 | 22,010 | 275 | 113 | 91% | 30.3 | 7.5% | 161 |
|  | 90 | 23,490 | 293 | 141 | 91% | 37.4 | 8.8% | 152 |

| preset | fees in | launch pot spent on day | steady credits a day | steady statements a day | steady sold a day | price paid over market | average score bought | eth recycled by sales, 90 days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| comparable decay | 220 | 5.9 | 44 | 0.56 | 0.75 | 0.99x | 427 | 71.9 |
| sustained 17 eth a day | 278 | 5.8 | 202 | 2.54 | 1.83 | 0.90x | 425 | 97.0 |
| sustained 50 eth a day | 430 | 5.9 | 428 | 5.35 | 1.64 | 0.87x | 424 | 100.9 |
| dead after week one | 216 | 5.9 | 49 | 0.61 | 0.92 | 1.00x | 427 | 74.9 |

reading it:

1. the pot is spent in 6 to 7 days under every preset, because 255 of the 297 eth arrive on day one. by day 7 the engine holds 21,020 credits, 73 percent of what it will have at day 90 on comparable volume.
2. unsold statements do not slow anything. 201 statements wait at day 90 and the engine bought 1,470 credits in days 60 to 90 regardless. with no statement buyer at all the engine still buys every day, but sale proceeds are the pot's income after week one, so credits are 14 percent lower at day 30 (21,790 against 25,450) and 22 percent lower at day 90 (22,440 against 28,910).
3. after the pot is gone the flow is set by income: coin fees plus sale proceeds that go to the pot (half of every sale at launch values). at the comparable floor of 0.5 eth a day of coin volume that is 49 credits a day, at 17 eth a day 306, at 50 eth a day 675 (section 7).
4. statements sold are limited by buyers, not by the engine. 280 buyers arrive in 90 days, 86 find no price they accept and 35 more bid on a live auction. sustained volume makes more statements (590 at 17 eth a day) and sells about the same (226), so the waiting stock grows 3 a day, and the average sale price falls to 79 percent because the stock is old and sells at the floor (67 percent of sales at the lowest price).
5. 42 eth of buyback burns 10.0 percent of supply because the pool price sits near 3e-7. the percent depends on the coin price more than on the engine.
6. the engine bids above the market in days 2 to 6 (up to 1.26x the market price of a 440 point credit) while the pot is large, then falls to about 60 percent of it. all credits cost 1.04x the flat price on comparable volume.

## 2. the opening limit

note: the numbers in this section are from the run before the v2 fee change (10 percent skim, 9.5 points to the engine). the headline table in section 1 and sim/results/*.json hold the current run.

`rateStart` as a share of the market price of a credit (0.0089 eth, so 75 percent is 1.54e13).

| share | rateStart | hours to first buy | credits day 1 | day 3 | day 7 | day 14 | day 30 | first 80 cost over market | all credits over market |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 25% | 5.14e12 | 33.20 | 0 | 70 | 7,080 | 22,120 | 24,310 | 0.52 | 1.05 |
| 40% | 8.22e12 | 0.11 | 22 | 1,047 | 13,390 | 22,300 | 24,470 | 0.53 | 1.05 |
| 50% | 1.03e13 | 0.03 | 177 | 2,660 | 17,120 | 22,570 | 24,590 | 0.54 | 1.04 |
| 60% | 1.23e13 | 0.03 | 617 | 4,439 | 19,620 | 23,010 | 25,140 | 0.60 | 1.04 |
| **75%** | 1.54e13 | 0.03 | 1,561 | 6,984 | 21,020 | 23,020 | 25,040 | 0.74 | 1.04 |
| 90% | 1.85e13 | 0.03 | 2,683 | 9,446 | 21,000 | 23,240 | 25,370 | 0.89 | 1.04 |
| 100% | 2.06e13 | 0.03 | 3,440 | 10,840 | 20,730 | 22,740 | 24,820 | 0.99 | 1.05 |
| 125% | 2.57e13 | 0.03 | 5,295 | 13,490 | 20,220 | 22,320 | 24,400 | 1.23 | 1.06 |

1. the opening limit changes the first three days and nothing after day 7. credits at day 14 and day 30 are flat from 40 to 100 percent (22,300 to 23,240 and 24,470 to 25,370), the pot is spent in the same week.
2. below 40 percent the engine waits: at 25 percent nothing is bought for 33 hours and day 7 holds a third of the credits (7,080 against 21,020).
3. the first fills are the cheapest sellers. the first 80 credits cost 0.74x market at 75 percent and 0.99x at 100 percent. the engine pays its bid to every seller that clears, not their ask, so a higher limit pays more for the same credits.
4. the price paid over all credits does not move (1.04 to 1.06) because the climb and the drop take over within two days.
5. rising market (price recovers to 2.2x): a higher limit is better, day 7 holds 19,010 credits at 100 percent against 17,430 at 75. falling market: 60 to 75 percent is best at day 7 (22,200 to 22,500). the rule scales with price: at flat prices of 0.0045, 0.018 and 0.03 the same 75 percent buys within the first hour. what the pot then buys depends on the price (38,930, 16,020 and 13,620 credits by day 30).

confirm 75 percent. it sits on the plateau for total credits, buys at once, and pays 0.74x for the first fills. 90 percent is the dial for a faster first three days: it buys 35 percent more by day 3 (9,446 against 6,984) for 15 points more on the first 80 and nothing different at day 7. launch day rule: rateStart = share times market price of a credit in wei times 1e4 over `avgScore`, market price the median of the last 24 hours of seaport fills.

## 3. flat, blended or per point

note: the numbers in this section are from the run before the v2 fee change (10 percent skim, 9.5 points to the engine). the headline table in section 1 and sim/results/*.json hold the current run.

`flatBps` 10000 prices every credit as an average one (433 points), 0 prices it by its own score. comparable volume, 90 days.

| flatBps | credits acquired | price paid over market | price per point over market | average score bought | statements created | sold | credits day 7 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10000 flat | 28,800 | 1.04x | 1.07x | 427 | 359 | 158 | 21,010 |
| 7500 | 27,960 | 1.06x | 0.93x | 503 | 349 | 152 | 20,620 |
| 5000 | 25,890 | 1.14x | 0.90x | 555 | 323 | 134 | 19,350 |
| 2500 | 24,090 | 1.23x | 0.92x | 591 | 301 | 126 | 17,920 |
| 0 per point | 22,570 | 1.31x | 0.94x | 611 | 282 | 117 | 16,830 |

sustained 17 eth a day: 47,210 / 45,740 / 43,030 / 40,360 / 39,140 credits at 10000 / 7500 / 5000 / 2500 / 0, average score 426 / 524 / 586 / 620 / 640, price paid 0.92x / 0.95x / 1.01x / 1.07x / 1.12x.

1. flat buys the most credits and the most statements. going from flat to per point loses 22 percent of the credits and 21 percent of the statements, and pays 27 points more per credit.
2. the market prices credits flat in score (notes.md fact 1), so a per point bid pays the same ask for a low score credit and clears the high score ones first. that is why the average score rises from 427 to 611.
3. score is bought at a price: from flat to 7500 the average score rises 76 points (18 percent) for 2 points of price and 2.9 percent of credits. past 7500 each step loses more credits than it gains in score.
4. the switch on day 30 does little. the pot is gone by day 7, so the bid has little to buy with. flat to 5000 on day 30: credits 28,660 (28,800 unchanged), average score 454, steady flow 53 a day (49). flat to 0: 28,590, score 458, steady flow 51. in sustained 17 eth a day a switch to 5000 costs 3 percent of credits (45,620 against 47,210) and a switch to 0 costs 6 percent (44,380). if score matters later, a blend of 7500 is the cheap step.

## 4. the statement sale: asking price, floors, mode and the buyers

note: the numbers in this section are from the run before the v2 fee change (10 percent skim, 9.5 points to the engine). the headline table in section 1 and sim/results/*.json hold the current run.

this section replaces the old reserve sweep. the sale design has five dials (`startBps`, `stepBps` with `stepEvery`, `floorBps`, `saleFloorBps`, `buyOnly`) and two inputs that are not settings (the pick rule and the buyers' willingness to pay). the rows against launch are in the table at the top of this file. what they say, with the extra sweeps:

1. **credits acquired and statements created hardly depend on the sale design.** 27,620 to 29,690 across every row of the top table except the fee share, which takes eth out of the pot in week one. the design moves how many statements sell and how much eth they bring back (68 to 98 eth recycled across the dials).
2. **the price is where the first fitting buyer arrives.** 77 percent of the sales at launch happen on the way down the curve and 23 percent at the lowest price. the mean age at the first buyer is 157 hours because the oldest statements wait at the floor for weeks. the model does not make buyers read the curve, it only matches each arrival to the lowest asking price that fits.
3. **plenty of stock means every buyer pays the floor.** the pick rule sends a buyer to the lowest asking price, and when there are more statements than buyers one is always at the floor. at 17 eth a day (590 statements, 226 buyers) 67 percent of sales are at the lowest price and the average is 79 percent of cost whatever the start price (77 percent at 9000, 81 at 13000). at comparable volume stock at the floor is thin, so `startBps` and `stepEvery` do move the price (82 to 96 percent). the sale design therefore matters most when the engine sells most of what it makes, and little when it makes more than the buyers take.

**the auction duration.** comparable volume, auction mode, cheapest pick:

| `auctionDuration` | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 hour | 29,750 | 371 | 183 | 89% | 188 | 49.3 | 98.7 | 1% |
| 6 hours | 29,560 | 369 | 178 | 90% | 190 | 48.6 | 97.3 | 10% |
| 24 hours | 28,800 | 359 | 158 | 91% | 201 | 42.2 | 84.4 | 19% |
| 72 hours | 28,150 | 351 | 137 | 92% | 212 | 35.4 | 70.7 | 35% |
| 168 hours | 28,650 | 358 | 140 | 91% | 213 | 35.3 | 70.6 | 41% |

4. **a long auction costs eth in this model, through one mechanism.** a buyer takes the lowest asking price that fits, which is often a live auction at the 5 percent raise, and the longer an auction runs the more buyers pile onto it: second bidders go from 1 percent at one hour to 41 percent at 168 hours, sold falls from 183 to 140 and eth recycled from 99 to 71. the real house may or may not show that pile on (the buyers' rule is the weakest input, see the pick rule below). `auctionDuration` is adjustable at once, so the owner can read the second bidder share in the first weeks and shorten it: 6 hours recycles 15 percent more than 24 in this model.

**the pick rule and the number of buyers.** the pick rule decides the second bidder share and so a large part of the sale side. cheapest means a buyer takes the lowest asking price that fits, random means any statement that fits.

| sale mode, pick rule, buyers a day | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| auction, cheapest, 8 | 28,800 | 359 | 158 | 91% | 201 | 42.2 | 84.4 | 19% |
| auction, cheapest, 20 | 32,350 | 404 | 239 | 94% | 164 | 75.6 | 151.3 | 29% |
| auction, random, 8 | 32,150 | 401 | 234 | 81% | 167 | 63.9 | 127.7 | 4% |
| auction, random, 20 | 38,650 | 483 | 374 | 87% | 108 | 120.1 | 240.1 | 17% |
| buy only, cheapest, 8 | 29,660 | 370 | 185 | 89% | 186 | 49.1 | 98.2 | 0% |
| buy only, cheapest, 20 | 33,410 | 417 | 279 | 93% | 139 | 91.5 | 182.9 | 0% |
| buy only, random, 8 | 31,980 | 399 | 243 | 81% | 156 | 66.9 | 133.9 | 0% |
| buy only, random, 20 | 34,860 | 435 | 320 | 89% | 115 | 109.3 | 218.5 | 0% |

5. **random pick sells 48 percent more statements than cheapest at 8 buyers a day** (234 against 158) because buyers spread out and few bid on a live auction (4 percent against 19), and recycles 51 percent more eth (128 against 84), at a lower average price (81 percent against 91). buy only is worth 4 percent of the statements sold under random pick (243 against 234) and 17 percent under cheapest. 20 buyers a day lift credits to 32,350 (cheapest) or 38,650 (random).
6. **the design conclusions hold under random pick, with two differences.** `startBps` and `stepEvery` matter less for eth recycled (120 to 137 eth across the rows against 68 to 92), because buyers spread over the whole stock and no one piles onto the cheapest. lowering both floors costs eth instead of being free: recycled 128, 125, 119 at 7500, 6000, 5000, average price 81, 67, 59 percent. the table, all rows against random pick launch:

| random pick, all rows | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| launch | 32,150 | 401 | 234 | 81% | 167 | 63.9 | 127.7 | 4% |
| `startBps` 9000 | 32,010 | 399 | 236 | 76% | 161 | 62.8 | 125.6 | 3% |
| `startBps` 13000 | 31,530 | 394 | 210 | 85% | 181 | 59.6 | 119.3 | 4% |
| `stepEvery` 1 hour | 32,140 | 401 | 238 | 77% | 162 | 62.9 | 125.8 | 3% |
| `stepEvery` 6 hours | 33,050 | 413 | 242 | 84% | 169 | 68.7 | 137.4 | 4% |
| both floors 6000 | 31,930 | 399 | 235 | 67% | 162 | 62.4 | 124.8 | 3% |
| both floors 5000 | 31,380 | 392 | 240 | 59% | 150 | 59.4 | 118.7 | 2% |
| buy only | 31,980 | 399 | 243 | 81% | 156 | 66.9 | 133.9 | 0% |
| `feeToBuybackBps` 1000 | 30,910 | 386 | 232 | 80% | 150 | 93.8 | 126.9 | 4% |
| `feeToBuybackBps` 2500 | 28,910 | 361 | 234 | 80% | 125 | 141.1 | 128.7 | 4% |
| `feeToBuybackBps` 5000 | 24,040 | 300 | 224 | 80% | 74 | 216.1 | 118.5 | 3% |
| every buyer waits for the floor | 31,970 | 399 | 223 | 75% | 175 | 55.8 | 111.5 | 0% |

**willingness to pay and the number of buyers** are the real inputs of the sale side, not the curve. cheapest pick, comparable volume:

| buyer willingness to pay, times the observed | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.70x | 26,200 | 327 | 103 | 86% | 223 | 24.2 | 48.5 | 19% |
| 0.84x | 27,600 | 345 | 132 | 89% | 211 | 33.3 | 66.6 | 21% |
| 1.00x | 28,910 | 361 | 162 | 91% | 199 | 43.7 | 87.4 | 18% |
| 1.30x | 30,420 | 380 | 190 | 92% | 189 | 52.7 | 105.4 | 18% |
| 1.60x | 31,600 | 395 | 215 | 92% | 178 | 61.1 | 122.1 | 21% |

| statement buyers a day at launch | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 3 | 26,980 | 337 | 112 | 88% | 224 | 25.6 | 51.1 | 22% |
| 8 | 28,910 | 361 | 162 | 91% | 199 | 43.7 | 87.4 | 18% |
| 20 | 32,250 | 403 | 238 | 94% | 163 | 75.8 | 151.5 | 29% |
| 40 | 36,430 | 455 | 326 | 96% | 128 | 118.0 | 236.0 | 37% |

7. willingness to pay: 0.7x the observed sells 103 statements, 1.0x sells 162, 1.6x sells 215, and eth recycled goes 49, 87, 122. buyers a day: 3 sell 112, 20 sell 238, 40 sell 326 (recycled 51, 152, 236), and credits go from 26,980 to 36,430. five times more buyers lifts eth recycled by 170 percent. neither is a setting. the owner can only choose how the stock is offered to the buyers that come.
8. the average price rises with demand (88 percent at 3 buyers a day, 96 at 40) because with many buyers the oldest statements at the floor are taken and the later buyers meet younger, higher priced statements.

**changing a setting later.** one change on day N, comparable volume, 5 seeds, against launch:

| change on day N | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| day 7: both floors to 6000 | 29,020 | 362 | 175 | 80% | 186 | 43.0 | 85.9 | 19% |
| day 14: both floors to 6000 | 29,730 | 371 | 182 | 86% | 188 | 47.3 | 94.5 | 17% |
| day 30: both floors to 6000 | 29,500 | 368 | 175 | 88% | 192 | 45.9 | 91.8 | 20% |
| day 14: `startBps` to 9000 | 28,380 | 354 | 157 | 84% | 196 | 39.6 | 79.2 | 22% |
| day 14: buy only | 30,400 | 380 | 191 | 90% | 189 | 51.1 | 102.1 | 2% |
| day 14: `feeToBuybackBps` to 2500 | 28,560 | 356 | 157 | 90% | 199 | 43.5 | 83.9 | 21% |
| launch, no change | 28,800 | 359 | 158 | 91% | 201 | 42.2 | 84.4 | 19% |
| both floors 6000 from launch | 28,920 | 361 | 174 | 80% | 186 | 42.4 | 84.7 | 19% |

9. a cut of both floors on day 14 beats a cut at launch: 182 sold at 86 percent and 94.5 eth recycled, against 174 at 80 percent and 84.7. early sales at the higher price bring more eth while buyers are plentiful, the old stock then clears at the lower price. a day 7 cut gives 175 sold and 86 eth recycled, a day 30 cut 175 and 92. lowering only `floorBps` changes nothing until `saleFloorBps` is lowered too (the Core's hard floor wins).
10. `startBps` down to 9000 on day 14 loses eth (79 against 84 recycled). buy only on day 14 gives about what buy only gives from launch (102 against 98 recycled, within seed noise). the fee share on day 14 does nothing (86 percent of the fees are already in). so the three levers have different timing: the floors are worth cutting once the first weeks show the stock waiting, the fee share has to be chosen at launch, the mode can wait.

recommendation for the sale design: **keep the launch values** (11000, 3 hours, 100, floor 7500, auction, fee share 0). in this model the curve moves the price by 14 points across its dials and the credits by 7 percent, while the pick rule and the number of buyers each move eth recycled by 50 percent or more. the owner's useful moves after week two, in order: lower both floors to 6000 if statements older than the 105 hours of the curve keep piling up and fewer than one sells a day, raise `startBps` or `stepEvery` if the average price over cost is low while few statements wait, switch to buy only if second bidders pile onto live auctions, shorten `auctionDuration` if second bidders are a large share of sales (19 percent at launch in this model, 41 percent at 168 hours).

## 5. the proceeds split

note: the numbers in this section are from the run before the v2 fee change (10 percent skim, 9.5 points to the engine). the headline table in section 1 and sim/results/*.json hold the current run.

`saleToBuybackBps` is the share of sale proceeds that goes to the coin buyback, the rest to the pot. it applies the same in auction mode (at `collectSales`) and in buy only mode (at the sale). the fee share is a separate setting (section 4, row 4).

| saleToBuybackBps | credits day 7 | day 30 | day 90 | statements created | sold | eth spent buying $CC | percent of supply burned | steady credits a day |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 21,370 | 28,230 | 35,690 | 446 | 216 | 0.0 | 0.0% | 121 |
| 2500 | 21,180 | 26,670 | 31,860 | 398 | 181 | 22.1 | 6.4% | 83 |
| 5000 | 21,010 | 25,410 | 28,800 | 359 | 158 | 42.2 | 10.0% | 49 |
| 7500 | 20,890 | 23,690 | 25,850 | 323 | 138 | 57.9 | 12.0% | 35 |
| 10000 | 20,710 | 22,330 | 23,440 | 292 | 126 | 74.3 | 13.8% | 18 |

sustained 17 eth a day: credits at day 90 52,640 / 49,610 / 47,210 / 44,510 / 41,700, eth spent buying coin 0 / 25.4 / 51.5 / 78.0 / 99.0, steady credits a day 355 / 323 / 306 / 283 / 264. sustained 50: 82,490 to 73,290 credits, 0 to 106 eth burned.

1. the split has no effect on the first week (21,370 to 20,710 credits on day 7). it acts only after the launch pot is gone, when sale proceeds are the pot's main income.
2. the price of burn in credits: from 0 to 100 percent the engine gives up 12,250 credits (34 percent) for 74 eth of burn. one eth of burn costs about 165 credits at comparable volume, 110 at 17 eth a day.
3. the burn side is weak: 100 percent buys 13.8 percent of the supply, 0 buys none. the steady credit flow falls from 121 to 18 a day. with the owner's order of goals (credits first, burn fifth) the split is the first thing to move toward the pot if credits per day matter more than burn.
4. launch at 5000 is safe because the first week is unaffected. decide at day 7 to 14 when the pot is gone and the steady flow is visible.
5. against the fee share: an extra eth of burn through `feeToBuybackBps` costs about 45 credits (section 4, row 4), about a quarter of the sale share price, but fees come on day one, so that lever has to be set at launch while the sale split can be turned any week.

## 6. dropBps, climbBaseBps, spendCapBps

note: the numbers in this section are from the run before the v2 fee change (10 percent skim, 9.5 points to the engine). the headline table in section 1 and sim/results/*.json hold the current run.

comparable volume, 90 days, launch values 2000 / 100 / 2000. the bounds were tightened after the first runs: `dropBps` 500 to 5000 and `spendCapBps` 100 to 5000, so the `dropBps` 0 and `spendCapBps` 10000 rows are counterfactuals the Core now refuses.

| dropBps | credits day 3 | day 14 | day 90 | price paid over market | launch pot spent on day | peak bid over market |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 8,164 | 19,670 | 20,290 | 1.38x | 5.1 | 6.0x |
| 500 | 7,826 | 20,490 | 21,580 | 1.30x | 5.4 | 2.9x |
| 1000 | 7,545 | 22,190 | 27,690 | 1.07x | 5.7 | 1.3x |
| **2000** | 6,974 | 23,130 | 28,800 | 1.04x | 6.5 | 1.3x |
| 3000 | 6,408 | 23,670 | 29,300 | 1.02x | 7.4 | 1.2x |
| 5000 | 5,503 | 25,010 | 31,600 | 0.98x | 9.6 | 1.2x |

| climbBaseBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | launch pot spent on day |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 25 | 2,289 | 7,281 | 20,950 | 31,790 | 35,850 | 0.92x | 18.4 |
| 50 | 3,675 | 13,380 | 25,830 | 28,120 | 31,350 | 0.98x | 11.0 |
| **100** | 6,974 | 21,010 | 23,130 | 25,410 | 28,800 | 1.04x | 6.5 |
| 200 | 13,310 | 18,820 | 21,010 | 23,090 | 26,390 | 1.10x | 3.7 |
| 400 | 14,510 | 15,490 | 16,050 | 16,410 | 18,160 | 1.47x | 2.2 |

| spendCapBps | credits day 7 | day 30 | day 90 | price paid over market | hours the cap blocked a sale |
| --- | --- | --- | --- | --- | --- |
| 500 | 20,240 | 22,100 | 22,770 | 1.25x | 1,809 |
| 1000 | 20,870 | 25,070 | 28,580 | 1.04x | 311 |
| **2000** | 21,010 | 25,410 | 28,800 | 1.04x | 11 |
| 4000 | 20,960 | 25,300 | 28,560 | 1.04x | 0 |
| 10000 | 20,960 | 25,300 | 28,560 | 1.04x | 0 |

1. the climb and the drop together set how fast the pot is spent and what the engine pays. when the engine buys every hour, the climb per hour equals the drop per hour at a spend of `climbBaseBps / dropBps` of the pot an hour: 5 percent at launch values, a pot half life of about 14 hours. that is why the pot is gone in a week whatever the opening limit is.
2. `climbBaseBps` is the strongest dial. faster is earlier and dearer: at 400 the engine has 14,510 credits by day 3 and 18,160 at day 90, paying 1.47x with a bid up to 3.1x market. slower is later and cheaper: at 25 it has 2,289 by day 3 and 35,850 at day 90 (24 percent more), paying 0.92x. the crossing with the launch value is between day 14 and day 30.
3. `dropBps` is the price discipline. at 0 the bid never comes back and the engine pays 1.38x with a bid up to 6x market (capped there by `rateCap`). 1000 to 3000 is flat in credits and price within 4 percent. raising it from 2000 to 3000 gives 2 percent more credits by day 14 and by day 90 and costs 8 percent of day 3 credits. 5000 is slower still.
4. `spendCapBps` is a guard, not a dial. at 4000 and 10000 it never blocks a sale. at 2000 it blocks 11 hours in 90 days. at 1000 it blocks 311 hours and costs nothing in credits by day 90. at 500 it blocks 1,809 hours, the engine pays 1.25x and ends 21 percent lower. it also clamps the climb through the funded rule, so a low cap clamps the bid early.
5. hard cases (opening limit 40 percent with a market that doubles, or a falling market) give the same ranking: no drop and a low cap lose, the climb sets the pace. in the recovery case credits at day 90 are 17,950 / 23,560 / 24,240 / 25,680 at `dropBps` 0 / 1000 / 2000 / 5000, and 22,860 / 24,240 / 17,480 at `climbBaseBps` 25 / 100 / 400.

recommendation: **keep 2000 / 100 / 2000.** the launch values sit mid curve for pace and price. what changes the answer is the goal: earlier credits at a higher price (raise `climbBaseBps` to 200 gives 13,310 by day 3, loses 8 percent of day 90 credits and pays 1.10x), or more credits later at a lower price (50 gives 12 percent more by day 14 and 9 percent more by day 90 and cuts day 7 by over a third). since the goal is early credits, keep. watch price paid over market: above 1.15x, raise `dropBps` or lower `climbBaseBps`.

## 7. after the launch pot: credits and statements per day against coin volume

coin volume that decays from day two to the stated constant by about day 10 (custom preset), last 30 days of a 90 day run, launch values.

| coin volume, eth a day | fees a day, eth | launch pot spent on day | steady credits a day | steady statements a day | steady sold a day | eth a day buying $CC | credits acquired by day 90 | waiting for phase 2 at day 90 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 0.052 | 5.8 | 55 | 0.7 | 0.9 | 0.23 | 24,220 | 157 |
| 5 | 0.259 | 5.8 | 100 | 1.3 | 1.3 | 0.28 | 28,070 | 173 |
| 17 | 0.881 | 5.9 | 195 | 2.4 | 1.6 | 0.28 | 35,850 | 240 |
| 50 | 2.590 | 5.9 | 433 | 5.4 | 1.9 | 0.40 | 55,220 | 456 |
| 150 | 7.770 | 6.2 | 889 | 11.1 | 1.5 | 0.38 | 96,780 | 1,012 |

1. sale proceeds carry about 45 to 55 credits a day at any volume, and coin fees add to that, about 8 credits a day per eth of daily volume at 17 eth a day and 8 at 50 (fees reaching the pot are 5.18 percent of volume in steady state, a credit costs 0.0089 eth). the flow grows with volume up to 50 eth a day.
2. statements a day are credits over 80. sold a day saturates at 1 to 2 whatever the volume, because buyers do not grow with supply (8 a day decaying to 2, 30 percent of them find no price). the waiting stock grows by the difference.
3. at 150 eth a day the engine has bought 96,780 credits by day 90, 88 percent of the 110,000 live credits, and its steady flow is 889 a day. a bigger float is a hard cap on credits acquired. at 50 eth a day it holds 50 percent of the live credits by day 90 (55,220).
4. five times more statement buyers (40 a day decaying to 10) lift steady flow at 17 eth a day from 195 to 320 credits a day (sale proceeds) and sold from 206 to 510 in 90 days. the sale side is the lever below 17 eth a day.
5. the buyback spends 0.23 to 0.40 eth a day after the launch pot.

## 8. phase 2

note: the numbers in this section are from the run before the v2 fee change (10 percent skim, 9.5 points to the engine). the headline table in section 1 and sim/results/*.json hold the current run.

the owner sets the exitModule at once, on day 14, 30 or 60. the keeper exits every eligible unbid listing (older than `exitAfter`, 105 hours) at once. an exit pays `rating * unitPerPoint` of exitToken, so the value in eth is the rating times the exitToken price per point (`xp`). a typical exited statement rates about 34,100 points and cost 1.21 eth (the unsold ones are the dear ones, the average statement cost 0.94), so the break even exitToken price is about 3.5e-5 eth per point, and the price at which an exit returns the hard floor of 75 percent of cost is about 2.6e-5.

| module on day | exitToken price per point | stock waiting before | statements exited by day 90 | exit value over cost | exit bid pot after 7 days | exit bid rate after 7 days, bps of score | credits bought through the exit bid by day 90 | credits acquired by day 90 | percent of supply burned |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 14 | 5e-6 | 219 | 214 | 0.14 | 18 | 9,700 | 0 | 27,160 | 10.1% |
| 14 | 1e-5 | 219 | 314 | 0.29 | 37 | 9,560 | 8,075 | 34,960 | 11.6% |
| 14 | 2e-5 | 219 | 328 | 0.57 | 80 | 5,007 | 9,180 | 36,750 | 14.5% |
| 14 | 3e-5 | 219 | 329 | 0.86 | 123 | 3,333 | 9,264 | 37,580 | 16.7% |
| 14 | 5e-5 | 219 | 694 | 1.43 | 265 | 3,000 | 38,480 | 65,820 | 19.4% |
| 14 | 1e-4 | 219 | 1,121 | 2.81 | 911 | 3,000 | 72,290 | 97,230 | 23.2% |
| 30 | 1e-5 | 211 | 292 | 0.28 | 36 | 9,580 | 6,585 | 33,940 | 11.3% |
| 30 | 3e-5 | 211 | 301 | 0.85 | 121 | 3,193 | 7,341 | 35,700 | 15.5% |
| 30 | 5e-5 | 211 | 590 | 1.42 | 261 | 3,000 | 30,420 | 58,100 | 18.1% |
| 60 | 1e-5 | 204 | 244 | 0.28 | 35 | 9,480 | 3,293 | 31,550 | 10.6% |
| 60 | 3e-5 | 204 | 250 | 0.84 | 118 | 3,147 | 3,743 | 32,380 | 12.8% |
| 60 | 5e-5 | 204 | 395 | 1.41 | 254 | 3,000 | 15,320 | 43,600 | 14.5% |

1. the stock is the same whenever the module arrives: 219, 211, 204 unbid statements, because the stock stops growing once the pot is gone (day 7) and about one a day sells. the exit takes the whole stock at the first hour.
2. what it is worth depends on the exitToken price only. exit value over cost is 0.14 at 5e-6, 0.57 at 2e-5, 0.86 at 3e-5 and 1.43 at 5e-5. below 3.5e-5 the exit gives back less than the engine paid, below 2.6e-5 less than the hard floor.
3. the exit feeds the engine. an exit puts 50 percent of the exitToken in the exit bid pot (`exitToBuybackBps`), which buys credits through the exit lane. at 1e-5 that bought 8,075 credits by day 90 when the module arrives on day 14 (the exit bid pays by score, so it buys the high score credits first) and lifted credits acquired from 28,910 to 34,960, 21 percent. at 5e-5 and 1e-4 the pot is so large the bid sits at its floor and still buys 38,480 to 72,290 credits, more than the float, so read these as an upper bound. later arrival gives less because less time remains: 9,264 at day 14, 7,341 at day 30, 3,743 at day 60 for 3e-5.
4. exit bid pace: the bid climbs 100 bps an hour while its pot affords one average credit, so it reaches 9,560 to 9,700 bps in a day or two when the price is low (5e-6, 1e-5) and sits near its 3,000 floor when the pot is large against the price (5e-5 and up), where each credit bought drops it 20 bps.
5. the exitToken dutch auction runs at a pace of one slice per half life by design: 272 fills in 76 days at about 6 hours each, mean 15 percent all in discount to the pool price at the taker threshold. a slice is 20 average credits of exitToken, 0.26 eth of value at 3e-5. one slice per 6 hours is about 1 eth of exitToken a day. the exit of 214 unbid statements puts about 110 eth of exitToken into the auction pot at 3e-5 (module on day 14), 71 eth of it has been filled and 39 eth is still waiting at day 90. a large exit batch waits months for the auction. a larger `exitSliceCredits` or a shorter `xAuctionHalfLife` is the dial.
6. a keeper that exits only when the module pays at least the asking price (instead of at once) exits nothing at 1e-5 and sells 162 statements by day 90 against 131 when it exits at once. `exitStatement` is permissionless, so at a low exitToken price anyone can force the exit of listings that a buyer would still have bought. the owner controls this only through `exitAfter` and the moment the exitModule is set.

## 9. sensitivity ranking

note: the numbers in this section are from the run before the v2 fee change (10 percent skim, 9.5 points to the engine). the headline table in section 1 and sim/results/*.json hold the current run.

low and high value of each input against the base case (28,800 credits and 359 statements at day 90, 158 sold at 91 percent of cost, 42 eth burned; 3 seed rows, base 3 seeds 28,910 credits and 162 sold). statements created move by the same share as credits, because 80 credits make one statement. ranked by the swing in credits.

| rank | input | low | high | credits low | credits high | swing | statements sold low | statements sold high | avg sale price low | avg sale price high |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | coin volume scale | 0.25x | 4x | 15,360 | 56,020 | 265% | 155 | 177 | 93% | 91% |
| 2 | flat credit price, eth | 0.0045 | 0.018 | 41,610 | 17,950 | 132% | 157 | 123 | 89% | 91% |
| 3 | seller offers an hour | 60 | 400 | 22,550 | 34,550 | 53% | 116 | 184 | 92% | 89% |
| 4 | `saleToBuybackBps` | 0 | 10000 | 35,820 | 23,460 | 53% | 217 | 127 | 83% | 83% |
| 5 | `dropBps` | 500 | 4000 | 21,500 | 30,240 | 41% | 108 | 158 | 78% | 90% |
| 6 | engine price impact | 0 | 0.3 | 32,430 | 23,610 | 37% | 159 | 140 | 91% | 91% |
| 7 | `flatBps` | 0 | 10000 | 22,540 | 28,910 | 28% | 117 | 162 | 90% | 91% |
| 8 | anti sniper volume share | 0.2 | 0.6 | 26,000 | 31,090 | 20% | 151 | 163 | 89% | 89% |
| 9 | statement buyers a day | 3 | 20 | 26,980 | 32,250 | 20% | 112 | 238 | 88% | 94% |
| 10 | credit price path | decline | recovery | 30,570 | 26,070 | 17% | 140 | 197 | 92% | 83% |
| 11 | statement willingness to pay | 0.7x | 1.3x | 26,200 | 30,420 | 16% | 103 | 190 | 86% | 92% |
| 12 | `climbBaseBps` | 50 | 200 | 30,890 | 26,650 | 16% | 146 | 160 | 89% | 91% |
| 13 | `feeToBuybackBps` | 0 | 2500 | 28,910 | 25,420 | 14% | 162 | 158 | 91% | 91% |
| 14 | buyer pick rule | cheapest | random | 28,910 | 32,350 | 12% | 162 | 238 | 91% | 80% |
| 15 | seller book churn | 0.02 | 0.15 | 30,650 | 28,240 | 9% | 178 | 159 | 89% | 90% |
| 16 | hour one share of day one volume | 0.45 | 0.7 | 27,140 | 29,450 | 9% | 149 | 154 | 90% | 90% |
| 17 | listed share of offers | 0 | 0.5 | 28,910 | 31,310 | 8% | 162 | 172 | 91% | 91% |
| 18 | seller supply elasticity | 0.5 | 3 | 27,950 | 29,610 | 6% | 156 | 164 | 90% | 89% |
| 19 | `startBps` | 9000 | 13000 | 27,870 | 29,210 | 5% | 148 | 160 | 82% | 97% |
| 20 | `stepEvery` | 1h | 6h | 27,850 | 29,170 | 5% | 146 | 160 | 84% | 96% |
| 21 | seller ask spread | 0.15 | 0.4 | 27,970 | 29,210 | 4% | 150 | 155 | 87% | 94% |
| 22 | `auctionDuration` | 6h | 72h | 29,360 | 28,210 | 4% | 175 | 139 | 90% | 92% |
| 23 | gas price, gwei | 0.5 | 10 | 28,800 | 27,870 | 3% | 154 | 150 | 91% | 91% |
| 24 | both floors (`floorBps`, `saleFloorBps`) | 5000 | 7500 | 29,610 | 28,910 | 2% | 200 | 162 | 73% | 91% |
| 25 | sale mode | auction | buy only | 28,910 | 29,560 | 2% | 162 | 184 | 91% | 89% |
| 26 | `rateStart` | 25% | 100% | 27,640 | 28,230 | 2% | 139 | 149 | 91% | 90% |
| 27 | buyers wait for the floor | no | yes | 28,910 | 29,360 | 2% | 162 | 178 | 91% | 75% |
| 28 | `spendCapBps` | 1000 | 4000 | 28,580 | 28,370 | 1% | 155 | 151 | 92% | 91% |
| 29 | coin buy share after day one | 0.42 | 0.52 | 28,910 | 28,910 | 0% | 162 | 162 | 91% | 91% |
| 30 | `exitAfter` | 24h | 168h | 28,910 | 28,910 | 0% | 162 | 162 | 91% | 91% |

1. credits acquired follow the money (coin volume), the price of a credit and the supply of sellers. these are not settings.
2. of the settings only five matter for credits: `saleToBuybackBps` (53 percent), `dropBps` (41), `flatBps` (28), `climbBaseBps` (16) and `feeToBuybackBps` (14). `saleToBuybackBps` is the biggest, and it is the owner's choice between burn and credits. the fee share is the same choice at launch.
3. for statements sold the order is different: the buyer rules (pick rule 162 to 238 sold, buyers a day 112 to 238, willingness to pay 103 to 190), `saleToBuybackBps` through credits (217 to 127), then the sale design: `auctionDuration` (175 to 139), both floors (200 to 162), buy only (162 to 184), waiting buyers (162 to 178), `startBps` (148 to 160) and `stepEvery` (146 to 160). the sale design moves the average price more than the count: 82 to 97 percent across `startBps`, 84 to 96 across `stepEvery`, 73 to 91 across the floors.
4. `rateStart`, `spendCapBps`, `exitAfter` and the whole sale design (the curve, the floors, the mode) move credits acquired by 5 percent or less. the sale design acts on statements sold and eth recycled, not on credits or on statements created.

## 10. what the model cannot tell us, and its weakest assumptions

note: the numbers in this section are from the run before the v2 fee change (10 percent skim, 9.5 points to the engine). the headline table in section 1 and sim/results/*.json hold the current run.

1. the ask distribution. only fills are visible, not asks. the cheap tail of sellers (lognormal spread 0.27) sets how cheap the first credits are and how fast the price climbs. a thinner tail means the engine overpays from the first fill. the engine pays its bid to every seller that clears, so the first fill price is a bid, not an ask.
2. statement demand and buyer behaviour. 42 priced sales over 5 days, all at fixed prices, none at auction and none on a falling price. arrivals are fixed at 8 a day decaying to 2 and **do not respond to the price level or to the curve**, so a lower price in the model only sells to the same buyers. in reality a cheaper statement may draw more, and a buyer who sees a falling price may wait for it: the pessimistic run is that case with every buyer waiting for the floor, and it still sells 167 to 179 statements because the buyers keep arriving. a real buyer that waits also stops arriving at high prices, which the model does not show. the pick rule decides the second bidder share (4 percent when buyers pick any, 19 percent when they pick the lowest ask) and a large part of eth recycled (84 against 128).
3. the two prices. a buyer judges a statement against the MARKET cost of its parts, the curve is set against what the engine PAID. the engine pays about 1.04 times market on comparable volume and 0.92 on sustained volume, so a start price of 110 percent of cost is 114 percent of market in one case and 101 in the other. buyers who judge by something else (the rating, the best score inside, a rare credit) are not modelled. willingness to pay is rating insensitive and that may change once the exitModule pays by rating.
4. the coin net flow. buy share after day one (0.46) drives the coin price and so the percent of supply burned. volume is exogenous, so buybacks and statement sales do not draw volume.
5. the engine's own footprint. price impact elasticity 0.12 is a guess. credits acquired swing 37 percent between no impact and 0.3. the lift also raises statement willingness to pay in the model.
6. seller supply and the float. 150 offers an hour, 5 percent leave an hour, more when the bid is above market, a float of 96,800 credits that credits burned into statements never come back to. no whale seller, no strategy relist at 1.2x, no competing protocol bid like the fwa hub at 0.029 flat. at 50 eth a day the engine buys 71 percent of the float and at 150 eth a day all of it.
7. the anti sniper volume (40 percent of hour one volume inside 30 minutes) is inferred from the comparable's implied 406 eth against 194 eth at a flat 10 percent. 86 percent of fees come on day one, so the starting pot is the biggest input and the least observed, and the fee share is only worth setting on day one. credits acquired swing 20 percent across 20 to 60 percent.
8. phase 2 is parametric. the exitToken price per point is a constant, the module pays exactly `rating * unitPerPoint`, a keeper exits every eligible listing at once, takers fill exactly at their threshold, credit sellers compare exit bids with no friction, and the exit bid buying 38,000 to 72,000 credits at high prices ignores the float.
9. keepers. `collectSales` runs every hour, `endAuction` is called the moment an auction ends, the first bidder reprices the listing to the asking price in the same step (there is no separate reprice keeper), the buyback keeper runs every 25 blocks, nobody sandwiches the 1 eth buyback, no wash volume (71 percent of the comparable's pool volume was churn and the model treats it as organic fee base). a house delivery failure (30 day unwind) is not modelled, and neither is a bid placed straight on the house at the start price in buy only mode.
10. the launch day market price. the opening limit is a share of the market price on launch day. the model holds that price at 0.0089 eth (or its path). a different price on the day moves the rate with it, which is why the limit is set on launch day.
11. the owner. the model has one change at a time at a known day. a real owner reacts to signals and may change several settings at once, which the Core allows, and the controller's settings and the Core's are separate calls (lowering `floorBps` without `saleFloorBps` does nothing). the owner key is trusted fully, with no wait on any change: the model assumes an owner who announces and does not abuse that.

## recommended launch settings

| setting | launch value | recommendation | why |
|---|---|---|---|
| `rateStart` | 1.54e13 (75% of market) | keep | on the plateau for total credits, buys at once, first 80 cost 0.74x. 90% gets 35% more by day 3 for 15 points on the first 80 |
| `flatBps` | 10000 | keep | most credits and statements. a blend of 7500 later buys 18% more score for 3% of credits |
| `avgScore` | 4,330,000 | keep | the population mean is 440 points, flat buys 427 |
| `startBps`, `stepBps`, `stepEvery`, `floorBps` | 11000, 100, 3 hours, 7500 | keep | the curve moves the average price by 14 points and credits by 7 percent at most. higher or slower is more eth per sale, lower or faster sells no more |
| `saleFloorBps` | 7500 | keep | the hard floor wins: lowering `floorBps` alone changes nothing, lower both together. cut both to 6000 on day 7 to 14 if old statements pile up (more sold at the same eth) |
| `buyOnly` | false (auction) | keep, switch later if second bidders pile onto live auctions | buy only sells 17% more statements under the lowest ask rule and 4% more under random pick, credits +3% |
| `auctionDuration` | 24 hours | keep, shorten if the second bidder share is high | 6 hours recycles 15% more eth under the lowest ask rule. a real house may not show the pile on |
| `feeToBuybackBps` | 0 | keep: a launch decision | 86% of fees come on day one. 1000 burns 68% more eth for 4.5% fewer credits, 2500 burns 2.8 times for 12% fewer. after day 7 it does nothing |
| `saleToBuybackBps` | 5000 | keep for the first week | no effect on week one. decide on day 7 to 14, it is the largest lever left |
| `dropBps` | 2000 | keep | 3000 gives 2% more credits by day 14 and 8% fewer on day 3 |
| `climbBaseBps` | 100 | keep | the biggest pace dial. 200 is earlier and dearer, 50 later and cheaper |
| `spendCapBps` | 2000 | keep | a guard. blocks 11 hours in 90 days. at most 5000 |
| `rateCap` | 1.232e14 | keep | 8 times `rateStart`. never reached at launch values (the climb is clamped by the pot first). it is the owner's "never pay more than this per credit" |
| `exitAfter` | 105 hours | keep, and keep it equal to the hour the curve reaches its floor | no effect before phase 2. if `stepEvery` or `stepBps` slow the curve, raise it with them, or statements exit before they reach their lowest price |
| `exitToBuybackBps`, `exitLaneToBuybackBps` and exitToken settings | as launched (the exit lane share is 0: exit lane proceeds stay in the exit bid pot) | keep | phase 2 only. the auction pace is slow (1 slice per 6 hours) |

## settings the owner should expect to adjust, and the signal

| setting | expected move | signal to watch |
|---|---|---|
| `floorBps` with `saleFloorBps` | 7500 to 6000 together | statements older than 105 hours keep piling up and fewer than one sells a day |
| `startBps`, `stepEvery` | up, to raise the price | average sale price over cost low while few statements wait |
| `buyOnly` | to true | second bidders pile onto live auctions, or buyers skip auctions |
| `auctionDuration` | shorter | second bidders a large share of sales (19% at launch in the model) |
| `feeToBuybackBps` | only at launch | the owner prefers burn over credits in the first week |
| `saleToBuybackBps` | toward the pot if credits matter more than burn, toward the buyback if burn does | credits a day after the pot is spent under 50 at launch volume, eth spent buying coin per day |
| `climbBaseBps`, `dropBps` | raise `dropBps` or lower `climbBaseBps` | price paid over market above 1.15x, the bid above 130% of market for more than a day |
| `setRate` | reset the limit | the market price of a credit moves 30% from the launch day value in week one, or the pot sits unspent for days with the bid under market |
| `flatBps` | 7500 | credits flowing steadily and the average score bought below the population mean of 440 |
| `exitSliceCredits`, `xAuctionHalfLife` | larger slice or shorter half life | exitToken waiting for the auction above 30 days of slices after phase 2 |
| `exitAfter` | longer, if the exitToken price is below the break even of about 3.5e-5 per point, or with a slower curve | exitToken price per point against 1.21 eth over a 34,100 point statement |

## files

sim/engine.js (model, the single source), sim/engine.test.mjs (456 checks), sim/run.mjs (batches, node run.mjs q1 to q11), sim/results/*.json, sim/build.mjs and the page parts (page.css, page.body.html, page.ui1.js to page.ui4.js), sim/index.html (built, single file).

