# simulation of the credits engine

follows the contract at commit `e194648` (`git log --oneline -1 -- src/`). launch values are script/config/mainnet.json.

sim/engine.js is a deterministic model of the engine in src/Core.sol, src/lib/CoreLib.sol and src/ControllerV1.sol on branch flow. it covers the stepped bid rule (drop per credit, drop floor, climb per minute, ceiling with idle loosening, clamp), the blended bid (`flatBps`, `avgScore`), the funded flag, the hourly cap, both buy doors, compose, the statement asking price (controller settings `startBps`, `stepBps`, `stepEvery`, `floorBps`, `buyOnly`) with the Core's hard floor `saleFloorBps`, the english auction on the pnd auction house, instant sales in buy only mode, `collectSales`, the swap fee share `feeToBuybackBps`, the buyback, the exit lane, the exitToken bid, the exitToken dutch auction and settings changes mid run. rules and names are the contracts' (docs/FLOW.md section 9). launch values are script/config/mainnet.json and a test reads the file. the launch position is concentrated liquidity math. sellers, statement buyers and coin volume are calibrated on the 13 day data pull in sim/data/notes.md. the time step is 60 seconds after the first hour (the first hour runs in 120 second sub steps for the anti sniper window), which matches the minute bucket of the contract's drop floor and climb. every number below is a mean over 3 to 5 seeds of a 90 day run unless stated. raw rows are in sim/results/*.json (node run.mjs q1 to q11), the interactive page is sim/index.html. `exitModule` and `exitToken` are the only names used for phase 2. the owner sets the exitModule, the controller and the allowed targets at once, so every change applies at once in the model.

the bid rule is `bidRule: 'stepped'`. the earlier rule stays available as `bidRule: 'built'` for the comparison in docs/BID-STUDY.md.

## base case, before and after

the headline of the previous run next to this run. the previous run used the built bid rule (opening limit 75 percent of market, `reimburseBps` 11000), a router split of `bountyBps` 9000 and 161,031 ppm to the payee, and hourly time steps. this run uses the launch values: stepped bid rule (`dropPerCreditBps` 50, `dropFloorBps` 8000, `climbPerMinBps` 50, `ceilBps` 12500, `idleLoosenBps` 200 per 10 minutes, `clampCredits` 20), opening limit 100 percent of market (`rateStart` 2.0554e13 wei per point), `reimburseBps` 8000, `bountyBps` 9638, 112,778 ppm to the payee, 60 second steps. comparable coin volume, 5 seeds, day 90. the fifth column is the launch run before the model followed the contract's hourly spend window (eth booked while a window is open raises the window pot and the room); the sixth column is this run with that rule.

| comparable volume, day 90 | previous run (stored) | previous settings, rerun | previous bid rule, launch router split | launch, before the window pot fix | launch (this run) |
| --- | --- | --- | --- | --- | --- |
| credits bought | 23,840 | 24,045 | 24,822 | 31,720 | 31,740 |
| statements created | 298 | 300 | 310 | 396 | 396 |
| statements sold | 137 | 147 | 147 | 173 | 170 |
| average sale price over cost | 91% | 91% | 91% | 85% | 86% |
| statements waiting | 159 | 152 | 162 | 221 | 224 |
| eth to burn | 35.9 | 39.4 | 38.8 | 44.7 | 43.8 |
| eth recycled by sales | 71.9 | 78.9 | 77.6 | 89.4 | 87.6 |
| fees booked, eth | 220 | 218 | 230 | 231 | 231 |
| launch pot spent on day | 5.9 | 5.9 | 6.0 | 17.4 | 17.9 |
| percent of supply burned | 9.2% | 9.7% | 9.7% | 10.6% | 10.6% |
| steady credits a day after the pot | 44 | 43 | 51 | 56 | 59 |
| price paid over market | n/a | 0.99x | 1.00x | 0.87x | 0.86x |
| credits on day 1 | n/a | 1,469 | 1,456 | 2,207 | 1,551 |
| credits at day 7 | n/a | 17,619 | 18,153 | 10,790 | 10,120 |

the third column is the previous settings run again on the current engine (credits 0.9 percent above the stored run). the fourth column changes only the router split to the launch values: the engine books 5.867 points of volume instead of 5.179, fees booked rise from 218 to 230 eth, credits rise 3 percent (24,045 to 24,822) and the sale side stays within 2 percent (sold 147 in both, eth recycled 78.9 to 77.6). the sixth column adds the stepped bid rule, the 100 percent opening limit and `reimburseBps` 8000 to the fourth: credits rise by 28 percent (24,822 to 31,740), statements created by 28 percent (310 to 396) and statements sold by 16 percent (147 to 170). the average sale price falls from 91 to 86 percent of cost and the price paid over market from 1.00 to 0.86, because the stepped bid pays about 14 percent under market on average where the built bid paid at market. the launch pot lasts until day 17.9 where the built rule spent it by day 6. by day 7 the engine holds 10,120 credits (32 percent of the day 90 figure) against 18,153 for the built rule on the same router split, and by day 30 28,110 against 21,753. the window rule leaves day 90 credits within 0.1 percent (31,720 to 31,740) and lowers day 1 from 2,207 to 1,551 credits and day 7 from 10,790 to 10,120.

fee path. a trader pays 6.9 points of volume. the pool pays 96.38 percent of the baseline skim (6.65022 points) plus all of the anti sniper extra to the fee router, and 0.25 points to the protocol leg. the Core pulls the router at the start of `sellForEth`, `buyListing`, `compose` and `composeExit`, so fees reach the pot as they arrive and the model books them at the moment they arrive. a flush tip takes 0.5 percent of the flushed amount (the model applies 0.5 percent and ignores the 0.005 eth cap per flush, which makes the tip an upper bound). from 30 minutes after launch (the end of the anti sniper window) the single payee takes 112,778 parts per million of the gross inflow (0.75 points of volume) and the tip comes out of the engine's part. the engine books 5.867 points of volume in steady state and the whole router inflow less the tip inside the window. the launch lp fee is 0, so lp income is 0. 89 percent of the 90 day fees (205 of 230 eth) arrive in the first 24 hours and 72 percent in the first hour.

## sensitivity rows (comparable volume, 5 seeds, day 90)

launch is `startBps` 11000, `stepEvery` 3 hours, `stepBps` 100, `floorBps` 7500, `saleFloorBps` 7500, auction mode, `feeToBuybackBps` 0. eth to burn is eth spent buying and burning the coin. differences in credits under 2 percent are seed noise.

| setting | credits bought | statements created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | sold at the lowest price |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **launch: 11000 / 3h / 7500, auction, fee share 0** | 31,740 | 396 | 170 | 86% | 224 | 43.8 | 87.6 | 48% |
| `startBps` 9000 | 31,350 | 391 | 174 | 79% | 217 | 41.6 | 83.3 | 60% |
| `startBps` 13000 | 32,300 | 403 | 171 | 92% | 231 | 46.4 | 92.8 | 40% |
| `stepEvery` 1 hour | 31,650 | 395 | 176 | 81% | 218 | 43.3 | 86.7 | 60% |
| `stepEvery` 6 hours | 31,570 | 394 | 161 | 89% | 231 | 42.6 | 85.2 | 32% |
| `stepBps` 50 | 31,590 | 394 | 162 | 89% | 232 | 42.8 | 85.5 | 32% |
| `stepBps` 200 | 31,480 | 393 | 170 | 83% | 222 | 42.2 | 84.5 | 56% |
| `floorBps` 6000 with `saleFloorBps` 7500 | 31,740 | 396 | 170 | 86% | 224 | 43.8 | 87.6 | 48% |
| `floorBps` 5000 with `saleFloorBps` 7500 | 31,740 | 396 | 170 | 86% | 224 | 43.8 | 87.6 | 48% |
| `floorBps` and `saleFloorBps` both 6000 | 32,510 | 406 | 209 | 74% | 196 | 47.4 | 94.8 | 46% |
| `floorBps` and `saleFloorBps` both 5000 | 32,180 | 402 | 228 | 63% | 171 | 45.1 | 90.2 | 48% |
| buy only mode | 33,260 | 415 | 205 | 86% | 210 | 52.8 | 105.5 | 48% |
| `feeToBuybackBps` 1000 | 29,880 | 373 | 177 | 86% | 195 | 68.8 | 90.9 | 48% |
| `feeToBuybackBps` 2500 | 26,150 | 326 | 167 | 87% | 158 | 101.8 | 85.8 | 44% |
| `feeToBuybackBps` 5000 | 20,100 | 251 | 159 | 88% | 89 | 159.3 | 79.9 | 39% |
| pessimistic: every buyer waits for the floor, auction mode | 32,070 | 400 | 190 | 75% | 208 | 42.8 | 85.6 | 100% |
| pessimistic: every buyer waits for the floor, buy only mode | 32,300 | 403 | 197 | 75% | 206 | 44.4 | 88.8 | 100% |

the same rows at 17 eth a day of coin volume, 3 seeds (all rows are 3 seed runs):

| sustained 17 eth a day, day 90 | credits bought | statements created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | sold at the lowest price |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| launch | 43,090 | 538 | 220 | 80% | 317 | 49.0 | 98.0 | 65% |
| `startBps` 9000 | 42,650 | 533 | 215 | 77% | 316 | 46.2 | 92.4 | 75% |
| `startBps` 13000 | 42,750 | 534 | 202 | 81% | 330 | 46.1 | 92.2 | 65% |
| `stepEvery` 1 hour | 43,220 | 540 | 234 | 77% | 305 | 49.6 | 99.3 | 84% |
| `stepEvery` 6 hours | 43,570 | 544 | 226 | 83% | 316 | 51.8 | 103.5 | 42% |
| both floors 6000 | 42,570 | 532 | 240 | 66% | 290 | 45.3 | 90.7 | 65% |
| both floors 5000 | 41,790 | 522 | 237 | 58% | 283 | 39.9 | 79.8 | 63% |
| buy only mode | 43,220 | 540 | 225 | 80% | 315 | 50.6 | 101.2 | 63% |
| `feeToBuybackBps` 1000 | 40,700 | 508 | 237 | 80% | 269 | 82.2 | 104.5 | 59% |
| `feeToBuybackBps` 2500 | 35,410 | 442 | 220 | 82% | 221 | 124.1 | 97.3 | 56% |
| `feeToBuybackBps` 5000 | 26,650 | 332 | 201 | 85% | 131 | 196.6 | 87.4 | 41% |
| pessimistic, auction | 42,230 | 527 | 198 | 75% | 329 | 41.0 | 82.0 | 100% |

reading the rows:

1. **`startBps`, `stepEvery` and `stepBps` set the average price.** `startBps` 9000 against 13000 moves the average sale price from 79 to 92 percent of cost, eth recycled from 83.3 to 92.8 and eth to burn from 41.6 to 46.4, for 3 percent more credits (31,350 to 32,300). a slower fall (6 hours a step, or 50 a step) raises the price to 89 percent and sells 161 to 162 statements where launch sells 170, so eth recycled stays at 85 (85.2 and 85.5 against 87.6). a faster fall (1 hour a step) gives 81 percent and 176 sold. the share of sales at the lowest price is 60 percent at 9000, 48 at 11000 and 40 at 13000. at 17 eth a day there are more statements than buyers, 65 percent of sales are at the lowest price and the dials change eth recycled by 6 percent or less (92.2 to 103.5 against 98.0 at launch).
2. **the hard floor binds.** with `saleFloorBps` at 7500 a `floorBps` of 6000 or 5000 leaves the rows equal to launch. selling lower needs both set. both at 6000: 209 sold (23 percent more), price 74 percent of cost, eth recycled 94.8 (8 percent more), credits 32,510. both at 5000: 228 sold at 63 percent and eth recycled 90.2 (3 percent more than launch), so 6000 recycles the most. at 17 eth a day lowering both costs eth: recycled 98.0 to 90.7 to 79.8, burn 49.0 to 45.3 to 39.9. a lower floor therefore gains at comparable volume, where buyers are scarce and old statements sit at the floor, and costs eth when statements are plentiful.
3. **buy only against auction.** buy only sells 205 against 170 (21 percent more), recycles 105.5 against 87.6 (20 percent more), burns 52.8 against 43.8 and lifts credits to 33,260 (5 percent). two causes: buyers go to sales instead of second bids and the proceeds reach the pots at once instead of at the next hourly `collectSales`. at 17 eth a day the gain is 225 against 220 sold and 101.2 against 98.0 recycled. under random pick the gain is 240 against 234 sold.
4. **`feeToBuybackBps` is a launch decision and a strong burn dial.** 1000 raises eth to burn from 43.8 to 68.8 and lowers credits by 6 percent (29,880). 2500 burns 101.8 eth (2.3 times launch) at 17.6 percent fewer credits (26,150). 5000 burns 159.3 eth (3.6 times) at 36.7 percent fewer credits (20,100) and 251 statements created. each extra eth burned costs 74 to 101 credits through the fee share (74 at 1000, 96 at 2500, 101 at 5000) and 130 through the sale share (section 5). 89 percent of the fees arrive on day one, so the share matters only while the launch pot is large: switching to 2500 on day 14 gives 31,560 credits and 44.6 eth burned against launch 31,740 and 43.8.
5. **the pessimistic run, every buyer waits for the floor.** every sale is at 75 percent of cost. in auction mode that sells 190 (more than launch: each purchase opens its own auction), recycles 85.6 eth (2 percent less than launch) and burns 42.8 (2 percent less). in buy only mode 197 sell, 88.8 recycled, 44.4 burned. at 17 eth a day the cost is 16 percent of the sale side (82.0 recycled against 98.0) and credits move 2 percent (42,230 against 43,090). arrivals follow the fixed schedule of the sale model assumptions, so the rows hold arrivals constant while the price changes.

## what the sale model assumes

the buyers and the sale rules in sim/engine.js, so the numbers can be checked:

1. **two prices.** a buyer's willingness to pay is a multiple of the MARKET cost of the 80 credits: the calibrated quantiles (p10 0.48, p25 0.71, median 0.84, p75 1.07, 21 percent at 1.2 or more, max 1.32) times `wtpMult` times 80 times the flat market price of a credit on the day the buyer arrives (including the lift from the engine's own buying). the asking price is a share of what the ENGINE PAID: the statement cost, the sum of the costs of its 80 credits plus the compose reimbursement. the engine pays 0.86 times market on comparable volume and 0.82 on sustained 17 eth a day, so the same buyer clears a different share of cost in each case.
2. **asking price.** steps = floor(age / `stepEvery`), age counted from the listing, a new statement starts at age zero. bps = max(`startBps` minus steps times `stepBps`, `floorBps`) of cost. the price used is the higher of that and `saleFloorBps` of cost (the Core's hard floor). launch: 110 percent, 109 at hour 3, 100 at hour 30, 75 from hour 105. the controller settings and the hard floor are read live, a change applies to every listed statement at once.
3. **arrivals and the pick rule.** buyers arrive as a Poisson process, 8 a day at launch, halving every 21 days down to 2 a day, whatever the price. each buyer makes one purchase attempt. it takes the statement with the lowest asking price at or under its willingness to pay (`stmtPick` random takes any that fits, section 4 shows both). a buyer that fits nothing leaves and is counted as a miss (26 percent of arrivals at launch, 71 of 279).
4. **a buyer buys what it can afford now.** a buyer who can afford a statement now buys it now. the pessimistic run is the opposite: with `buyerWaits` set to `floor` every buyer buys only a statement whose asking price has reached its lowest level (the higher of `floorBps` and `saleFloorBps`) and nobody bids on a live auction.
5. **auction mode (launch).** a buyer at or above the asking price opens the english auction at that price: the first bid is the asking price at that moment (the first bidder reprices the listing to it first). `auctionDuration` 24 hours runs from the first bid, a later bidder must have a higher willingness to pay than the top bidder and bid 5 percent more, a bid in the last 15 minutes extends the end to 15 minutes from the bid. the proceeds are credited to the Core in the house and reach the pots when `collectSales` runs (an hourly keeper), split by `saleToBuybackBps`. a statement with a bid stays out of the exitModule.
6. **buy only mode.** the buyer pays the asking price through `sellTo` and gets the statement at once. the proceeds are booked into the pots in the same call, split by `saleToBuybackBps`. a house listing in this mode sits at the start price, and buyers use the controller.
7. **fee share.** all swap fee eth reaches the Core through the fee router, which the Core pulls at the start of every sell and compose door, and the model books it as it arrives. `feeToBuybackBps` of it goes to the buyback pot and the rest to the pot. fees from the buyback's own swaps and from the exitToken auction takers count the same. eth booked later by `skim()` goes to the pot.
8. **keepers.** `collectSales` runs every hour, `endAuction` is called the moment an auction ends, the buyback keeper runs every 25 blocks. a statement is sold once, and a house delivery failure is outside the model.

arrivals follow a fixed schedule: the price level and the curve leave the number of buyers unchanged. that and the buyers' rule are the largest unknowns of the sale side (section 10).

## the goal and the headline metrics

the engine exists to keep credits flowing into statements. a statement selling below the cost of its 80 credits is better than no sale. unsold statements wait for the exitModule in phase 2. the engine keeps buying whatever the unsold stock is. early on it should acquire as many credits as possible, score can matter later.

headline metrics, in this order: credits acquired, statements created, statements sold with their average price over cost, statements waiting for phase 2, eth sent to buy and burn the coin (from sales and from fees), eth recycled by sales, days until the launch pot is spent, steady state credits per day after that. the launch pot is spent when the pot falls under 5 percent of its peak. steady state is the last 30 days of a 90 day run.

verdict in one paragraph: **the engine keeps buying under every volume preset, and unsold statements leave the buying rate unchanged.** as launched on the comparable coin it acquires 31,740 credits in 90 days, 28,110 of them by day 30, creates 396 statements and sells 170 of them at 86 percent of cost on average. 43.8 eth buys and burns 10.6 percent of the coin. 224 statements wait for phase 2. about 205 eth of fees arrive in the first 24 hours and the launch pot is spent on day 17.9, because the stepped bid buys about 1,440 credits a day while the pot lasts (1,551 on day 1). after that the flow is about 59 credits a day, paid for by the 0.03 eth a day the coin still pays and by sale proceeds. a second bidder shows up in 18 percent of the auctions, so the asking price at the moment of the first buyer is the price: the curve walks until a buyer's willingness to pay is reached. the sale design is a dial on eth recycled and burn, and week one is the same under every sale setting (10,120 credits on day 7 in every row of section 5).

## what the model changed against the old branch

| piece | now |
|---|---|
| bid | `bidRule` stepped. a fill lowers the bid by `dropPerCreditBps` 50 (0.5 percent), staying at or above `dropFloorBps` 8000 of the rate at the first fill of the minute. the bid climbs `climbPerMinBps` 50 a minute toward the lowest of `ceilBps` 12500 of the last fill rate (grown by `idleLoosenBps` 200 per idle 10 minutes, linear), `rateCap` and the clamp. the read bid is lowered to the clamp, the hourly cap divided by `clampCredits` 20 average credits. `flatBps` 10000 prices every credit as `avgScore`, 0 prices it by its own score, in between blends. the controller bonus is 0 (ControllerV1 returns 0) |
| gate | removed, with every trace. a test checks the source |
| statement price | the controller's asking price: `startBps` 11000 of cost, minus `stepBps` 100 every `stepEvery` 3 hours, to `floorBps` 7500. the Core's `saleFloorBps` 7500 is the hard floor: the price used is the higher of the two |
| statement sale | auction mode (launch): a buyer at or above the asking price opens the english auction at that price, `auctionDuration` timer from the first bid, 5 percent raise, 15 minute extension. buy only mode: the buyer pays the asking price and gets the statement at once. unbid statements stay listed |
| proceeds | auction: credited to the Core in the house, reach the pots when `collectSales` runs (an hourly keeper). buy only: booked at once. both split by `saleToBuybackBps` |
| fees | the fee router pays the Core: 6.65022 points of volume at the baseline plus the anti sniper extra, less the 0.5 percent flush tip and, from 30 minutes after launch, 112,778 ppm to the payee. `feeToBuybackBps` (launch 0) of the booked eth goes to the buyback pot, the rest to the pot |
| compose | `reimburseBps` 8000 |
| phase 2 exit | an unbid listing may exit through the exitModule after `exitAfter` (105 hours, where the asking price reaches its floor), a statement with a bid stays out of the exitModule. the owner sets the exitModule at once |
| settings | one `Settings` object with the Core's field names plus the controller's five, `schedule` of `{day, patch}` changes them mid run with the Core's checkpoint and bounds |
| opening limit | `rateStart` 2.0554e13, 100 percent of the market price of a credit over `avgScore` |
| rate cap | `rateCap` 1.232e14 (about 6 times `rateStart`): the climb stops at the lowest of the ceiling, the funded clamp and `rateCap`, `setRate` refuses above it. the peak bid at launch values is 1.19 times market, so the cap stays out of reach |

port checks: node engine.test.mjs runs 567 numeric checks against hand computed values: the launch values against mainnet.json (including the stepped bid fields, `rateStart` and the router split), the stepped rule (drop per credit, minute floor, ceiling, idle loosening, clamp, rate cap), the funded rule and clamp, the exit lane reimbursement cap at `rateStart`, the hourly cap, the blended ceiling, tip rule, compose reimbursement with the listing gas, the asking price at exact hours (110 at 0, 109 at 3, 100 at 30, 75 at 105 and after), the hard floor winning over a lower curve floor, the auction opening at the accepted price, every english auction rule (5 percent raise, extension, end, winner), buy only being instant, the proceeds split in both modes, the fee share at 0, 2500, 5000 and 10000, the router split (6.65022 points to the router, 5.867 to the engine), conservation of eth, `setSettings` bounds and checkpoint, exit eligibility, the exitToken auction and bid, buyback, the pool, eth accounting identities over whole runs (pot, buyback pot, house) in both modes, and the default run (stepped, 60 second steps). the checks of the built rule run on `bidRule: 'built'` with its own parameters.

## model in short

| piece | what it does | calibration |
|---|---|---|
| coin market | exogenous daily volume, buy share, skim 6.9 percent with 5.87 points to the pot after the router's tip and payee (6.65 points to the router), anti sniper 90 to 6.9 percent over 30 minutes, single sided position tick -175000 to 887200 | model price after day one 4.48e-7, observed 4.44e-7 |
| credit sellers | uniform scores 80 to 800, flat ask per credit with lognormal spread 0.27, top tier premium above 740, 150 offers an hour, 5 percent leave an hour, more offers when the bid is above market, a float of 96,800 credits | median 0.0089 eth, p10 0.0069, p90 0.0138 |
| doors | the sell door pays the bid for any credit whose ceiling clears its ask, cheapest ask per bid point first. CreditStrategy listings clear through the listing door with the tip | 13,132 listings at median 0.036 eth |
| statement buyers | arrivals 8 a day decaying to 2, willingness to pay as a multiple of 80 times the MARKET flat price, rating insensitive, one purchase each, buying what they can afford now. the price they meet is a share of what the engine PAID (assumptions above) | median 0.84, 21 percent at 1.2 or more, max 1.32, from fixed price sales. the response to a curve and to auctions is assumed |
| engine to market feedback | engine spend lifts the flat price, elasticity 0.12, half life 48 hours, cap 3x | assumption |
| phase 2 | exitModule pays rating times unitPerPoint, exit lane, exitToken bid by score, dutch auction with takers at a set discount, a keeper exits every eligible listing | assumption |

## 1. the launch configuration as built

| preset | day | credits acquired | statements created | sold | avg sale price over cost | eth spent buying $CC | percent of supply burned | waiting for phase 2 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| comparable decay | 30 | 28,110 | 351 | 104 | 82% | 27.9 | 7.4% | 245 |
|  | 60 | 29,960 | 374 | 138 | 85% | 36.0 | 9.1% | 235 |
|  | 90 | 31,740 | 396 | 170 | 86% | 43.8 | 10.6% | 224 |
| sustained 17 eth a day | 30 | 29,540 | 369 | 110 | 82% | 29.2 | 4.8% | 255 |
|  | 60 | 36,360 | 454 | 166 | 81% | 39.3 | 6.1% | 286 |
|  | 90 | 43,060 | 538 | 219 | 80% | 48.6 | 7.1% | 317 |
| sustained 50 eth a day | 30 | 35,430 | 442 | 113 | 80% | 30.4 | 5.0% | 328 |
|  | 60 | 50,140 | 626 | 174 | 78% | 42.9 | 6.5% | 450 |
|  | 90 | 64,500 | 806 | 221 | 78% | 52.3 | 7.4% | 583 |
| dead after week one | 30 | 27,880 | 348 | 107 | 82% | 28.9 | 7.2% | 239 |
|  | 60 | 29,730 | 371 | 143 | 84% | 37.5 | 8.8% | 226 |
|  | 90 | 31,410 | 392 | 176 | 86% | 45.3 | 10.1% | 215 |

| preset | fees in | launch pot spent on day | steady credits a day | steady statements a day | steady sold a day | price paid over market | average score bought | eth recycled by sales, 90 days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| comparable decay | 231 | 17.9 | 59 | 0.73 | 1.09 | 0.86x | 425 | 87.6 |
| sustained 17 eth a day | 296 | 17.6 | 223 | 2.79 | 1.77 | 0.82x | 425 | 97.3 |
| sustained 50 eth a day | 469 | 20.8 | 478 | 5.97 | 1.57 | 0.82x | 424 | 104.7 |
| dead after week one | 226 | 17.7 | 56 | 0.70 | 1.09 | 0.86x | 425 | 90.6 |

reading it:

1. the pot is spent in 18 to 21 days under every preset, because 89 percent of the fees arrive on day one and the stepped bid buys at a set pace. at launch values the bid settles where the drop per credit equals the climb per minute, which is `climbPerMinBps / dropPerCreditBps` = 1 credit a minute, about 1,500 credits a day (section 6). by day 7 the engine holds 10,120 credits (32 percent of what it will have at day 90 on comparable volume), by day 14 20,140 (63 percent) and by day 21 27,540 (87 percent).
2. unsold statements leave the buying rate unchanged. 224 statements wait at day 90 and the engine bought 1,780 credits in days 60 to 90. with no statement buyer at all the engine still buys every day, but sale proceeds are the pot's income after the launch pot, so credits are 12 percent lower at day 30 (24,630 against 28,110) and 21 percent lower at day 90 (25,050 against 31,740).
3. after the pot is gone the flow is set by income: coin fees plus the sale proceeds that go to the pot (half of every sale at launch values). at the comparable floor of 0.5 eth a day of coin volume that is 59 credits a day, at 17 eth a day 223, at 50 eth a day 478 (section 7).
4. statements sold are limited by buyers. 279 buyers arrive in 90 days, 71 find no price they accept and 36 place a second bid on an auction already open (18 percent of auctions). sustained volume makes more statements (538 at 17 eth a day) and sells about the same (219), so the waiting stock grows by about one a day after day 30, and the average sale price falls to 80 percent because the stock is old and 66 percent of sales are at the lowest price.
5. 43.8 eth of buyback burns 10.6 percent of supply because the pool price sits near 3e-7. the percent depends on the coin price more than on the engine.
6. the read bid stays at 0.86 to 0.93 of the market price of a credit through day 14, while the pot is large, and falls to 0.50 to 0.56 of it once the pot is empty and the clamp (the hourly cap over 20 average credits) sets the bid. all credits cost 0.86 times the flat price on comparable volume (0.82 at 17 eth a day) and the peak bid is 1.19 times market (1.21 at 17 eth a day).

## 2. the opening limit

`rateStart` as a share of the market price of a credit (0.0089 eth, so 100 percent is 2.06e13). the stepped bid starts at `rateStart` and climbs 0.5 percent a minute.

| share | rateStart | hours to first buy | credits day 1 | day 3 | day 7 | day 14 | day 30 | day 90 | first 80 cost over market | all credits over market | peak bid over market |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 25% | 5.14e12 | 2.13 | 1,149 | 3,989 | 9,708 | 19,730 | 28,250 | 31,820 | 0.54 | 0.86 | 1.20 |
| 40% | 8.22e12 | 0.03 | 1,277 | 4,115 | 9,839 | 19,870 | 27,960 | 31,480 | 0.54 | 0.86 | 1.19 |
| 50% | 1.03e13 | 0.03 | 1,321 | 4,161 | 9,884 | 19,910 | 28,150 | 31,750 | 0.55 | 0.86 | 1.16 |
| 60% | 1.23e13 | 0.03 | 1,357 | 4,201 | 9,918 | 19,950 | 28,210 | 31,550 | 0.57 | 0.86 | 1.18 |
| 75% | 1.54e13 | 0.03 | 1,439 | 4,280 | 10,000 | 20,030 | 28,260 | 31,820 | 0.64 | 0.86 | 1.19 |
| 90% | 1.85e13 | 0.03 | 1,545 | 4,389 | 10,110 | 20,140 | 28,210 | 31,710 | 0.77 | 0.86 | 1.20 |
| **100%** | 2.06e13 | 0.03 | 1,552 | 4,396 | 10,120 | 20,140 | 27,930 | 31,470 | 0.86 | 0.86 | 1.21 |
| 125% | 2.57e13 | 0.03 | 1,706 | 4,554 | 10,280 | 20,310 | 28,290 | 32,130 | 1.07 | 0.86 | 1.16 |

1. the opening limit changes day 1 and day 3 and leaves later days close together. credits at day 14 run from 19,730 (25 percent) to 20,310 (125 percent), at day 30 from 27,930 to 28,260 and at day 90 from 31,470 to 32,130.
2. at 25 percent the first buy comes after 2.1 hours and day 1 holds 1,149 credits against 1,552 at 100 percent. from 40 percent up the first buy is within 2 minutes.
3. the first fills are the cheapest sellers. the first 80 credits cost 0.54 times market at 25 to 40 percent, 0.86 at 100 percent and 1.07 at 125 percent. the engine pays its bid to every seller that clears, so a higher limit pays more for the same credits.
4. the price paid over all credits is 0.86 times market at every limit, because the climb and the drop find the market within minutes.
5. rising market (price recovers to 2.2 times): a higher limit buys slightly more in week one, day 7 holds 9,637 credits at 25 percent and 10,210 at 125 percent, and day 90 24,850 to 26,150. falling market: day 7 holds 9,747 to 10,320 and day 30 37,150 to 37,760 at every limit. the rule scales with price: at flat prices of 0.0045, 0.018 and 0.03 the 100 percent limit buys within the first minutes (day 30 holds 43,230, 15,000 and 11,410 credits).

100 percent is the launch value (`rateStart` 20,554,000,000,000). it buys at once and pays 0.86 times market for the first 80 credits, with later totals level across the range. launch day rule: rateStart = share times market price of a credit in wei times 1e4 over `avgScore`, market price the median of the last 24 hours of seaport fills.

## 3. flat, blended or per point

`flatBps` 10000 prices every credit as an average one (433 points), 0 prices it by its own score. comparable volume, 90 days.

| flatBps | credits acquired | price paid over market | price per point over market | average score bought | statements created | sold | credits day 7 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10000 flat | 31,740 | 0.86x | 0.89x | 425 | 396 | 170 | 10,120 |
| 7500 | 30,500 | 0.90x | 0.76x | 521 | 381 | 166 | 10,130 |
| 5000 | 27,390 | 0.98x | 0.74x | 583 | 342 | 143 | 10,210 |
| 2500 | 25,030 | 1.06x | 0.75x | 616 | 312 | 127 | 10,200 |
| 0 per point | 23,230 | 1.12x | 0.78x | 632 | 290 | 114 | 10,170 |

sustained 17 eth a day: 43,060 / 41,240 / 38,250 / 35,930 / 34,180 credits at 10000 / 7500 / 5000 / 2500 / 0, average score 425 / 531 / 597 / 630 / 647, price paid 0.82x / 0.85x / 0.91x / 0.97x / 1.01x.

1. flat buys the most credits and the most statements. going from flat to per point loses 27 percent of the credits (31,740 to 23,230) and 27 percent of the statements (396 to 290), and pays 26 points more per credit (0.86 to 1.12 times market).
2. the market prices credits flat in score (notes.md fact 1), so a per point bid pays the same ask for a low score credit and clears the high score ones first. that is why the average score rises from 425 to 632.
3. score has a price: from flat to 7500 the average score rises 96 points (23 percent) for 4 points of price paid and 4 percent of credits. below 7500 each step loses more credits than it gains in score (5000 loses another 10 percent of credits for 62 points).
4. the switch on day 30 changes little. the pot is gone by day 18, so the bid has little to buy with. flat to 5000 on day 30: credits 31,540 (31,740 unchanged), average score 450, steady flow 55 a day (59). flat to 0: 31,630, score 455, steady flow 52. in sustained 17 eth a day a switch to 5000 costs 3 percent of credits (41,910 against 43,060) and a switch to 0 costs 4 percent (41,380). if score matters later, 7500 is the cheap step.

## 4. the statement sale: asking price, floors, mode and the buyers

the sale design has five dials (`startBps`, `stepBps` with `stepEvery`, `floorBps`, `saleFloorBps`, `buyOnly`) and two inputs outside the owner's settings (the pick rule and the buyers' willingness to pay). the rows against launch are in the table at the top of this file. what they say, with the extra sweeps:

1. **credits acquired and statements created depend little on the sale design.** 31,350 to 33,260 credits across every row of the top table except the fee share, which takes eth out of the pot in week one. the design moves how many statements sell (161 to 228) and how much eth they bring back (83.3 to 105.5 eth recycled across the dials).
2. **the price is where the first fitting buyer arrives.** 52 percent of the sales at launch happen on the way down the curve and 48 percent at the lowest price. the mean age at sale is 250 hours because the oldest statements wait at the floor for weeks. each arrival is matched to the lowest asking price that fits.
3. **plenty of stock means every buyer pays the floor.** the pick rule sends a buyer to the lowest asking price, and when there are more statements than buyers one is always at the floor. at 17 eth a day (538 statements, 278 buyers) 65 percent of sales are at the lowest price and the average is 77 to 83 percent of cost across the dials (77 percent at 9000, 81 at 13000). at comparable volume stock at the floor is thinner, so `startBps` and `stepEvery` move the price (79 to 92 percent). the sale design therefore matters most when the engine sells most of what it makes, and little when it makes more than the buyers take.

**the auction duration.** comparable volume, auction mode, cheapest pick:

| `auctionDuration` | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 hour | 33,310 | 416 | 206 | 86% | 210 | 53.1 | 106.2 | 1% |
| 6 hours | 32,870 | 410 | 196 | 86% | 214 | 50.4 | 100.8 | 7% |
| 24 hours | 31,740 | 396 | 170 | 86% | 224 | 43.8 | 87.6 | 18% |
| 72 hours | 31,440 | 393 | 162 | 86% | 228 | 41.6 | 83.3 | 20% |
| 168 hours | 30,800 | 385 | 142 | 87% | 237 | 36.1 | 72.2 | 26% |

4. **a long auction costs eth in this model, through one mechanism.** a buyer takes the lowest asking price that fits, which is often a live auction at the 5 percent raise, and the longer an auction runs the more buyers pile onto it: second bidders go from 1 percent at one hour to 20 percent at 72 hours and 26 percent at 168 hours, sold falls from 206 to 162 and 142, and eth recycled from 106.2 to 83.3 and 72.2. the real house may show a different pile on (the buyers' rule is the weakest input, see the pick rule below). `auctionDuration` is adjustable at once, so the owner can read the second bidder share in the first weeks and shorten it: 6 hours recycles 15 percent more than 24 in this model (100.8 against 87.6).

**the pick rule and the number of buyers.** the pick rule decides the second bidder share and so a large part of the sale side. cheapest means a buyer takes the lowest asking price that fits, random means any statement that fits.

| sale mode, pick rule, buyers a day | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| auction, cheapest, 8 | 31,740 | 396 | 170 | 86% | 224 | 43.8 | 87.6 | 18% |
| auction, cheapest, 20 | 37,930 | 474 | 336 | 85% | 137 | 93.4 | 186.8 | 15% |
| auction, random, 8 | 34,700 | 433 | 234 | 80% | 198 | 61.7 | 123.4 | 3% |
| auction, random, 20 | 42,770 | 534 | 446 | 83% | 85 | 125.5 | 251.1 | 6% |
| buy only, cheapest, 8 | 33,260 | 415 | 205 | 86% | 210 | 52.8 | 105.5 | 0% |
| buy only, cheapest, 20 | 40,790 | 509 | 400 | 85% | 109 | 111.4 | 222.9 | 0% |
| buy only, random, 8 | 34,880 | 436 | 240 | 80% | 195 | 63.1 | 126.2 | 0% |
| buy only, random, 20 | 42,720 | 533 | 446 | 83% | 88 | 126.0 | 251.9 | 0% |

5. **random pick sells 38 percent more statements than cheapest at 8 buyers a day** (234 against 170) because buyers spread out and few bid on a live auction (3 percent against 18), and recycles 41 percent more eth (123.4 against 87.6), at a lower average price (80 percent against 86). buy only is worth 3 percent of the statements sold under random pick (240 against 234) and 21 percent under cheapest. 20 buyers a day lift credits to 37,930 (cheapest) or 42,770 (random).
6. **the design conclusions hold under random pick, with two differences.** `startBps` and `stepEvery` matter less for eth recycled (119.4 to 127.0 across the rows against 83.3 to 92.8), because buyers spread over the whole stock and no one piles onto the cheapest. lowering both floors costs eth: recycled 123.4, 116.4, 103.9 at 7500, 6000, 5000, average price 80, 68, 61 percent, where under cheapest pick 6000 gains. the table, all rows against random pick launch:

| random pick, all rows | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| launch | 34,700 | 433 | 234 | 80% | 198 | 61.7 | 123.4 | 3% |
| `startBps` 9000 | 34,480 | 430 | 237 | 76% | 192 | 60.0 | 120.0 | 3% |
| `startBps` 13000 | 34,520 | 431 | 221 | 82% | 208 | 59.7 | 119.4 | 2% |
| `stepEvery` 1 hour | 34,660 | 433 | 240 | 77% | 191 | 61.0 | 122.0 | 2% |
| `stepEvery` 6 hours | 34,990 | 437 | 235 | 82% | 200 | 63.5 | 127.0 | 2% |
| both floors 6000 | 34,150 | 427 | 251 | 68% | 174 | 58.2 | 116.4 | 2% |
| both floors 5000 | 33,110 | 413 | 248 | 61% | 163 | 51.9 | 103.9 | 3% |
| buy only | 34,880 | 436 | 240 | 80% | 195 | 63.1 | 126.2 | 0% |
| `feeToBuybackBps` 1000 | 32,670 | 408 | 236 | 80% | 170 | 85.7 | 124.5 | 2% |
| `feeToBuybackBps` 2500 | 29,490 | 368 | 241 | 79% | 126 | 121.6 | 124.9 | 2% |
| `feeToBuybackBps` 5000 | 23,260 | 290 | 242 | 80% | 47 | 180.0 | 120.1 | 3% |
| every buyer waits for the floor | 33,700 | 421 | 210 | 75% | 208 | 52.3 | 104.6 | 0% |

**willingness to pay and the number of buyers** are the real inputs of the sale side, beside the curve. cheapest pick, comparable volume:

| buyer willingness to pay, times the observed | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.70x | 28,400 | 354 | 91 | 85% | 263 | 21.7 | 43.5 | 17% |
| 0.84x | 30,230 | 377 | 134 | 86% | 243 | 33.6 | 67.2 | 18% |
| 1.00x | 31,640 | 395 | 168 | 86% | 225 | 43.4 | 86.8 | 18% |
| 1.30x | 32,580 | 407 | 193 | 86% | 213 | 50.6 | 101.1 | 17% |
| 1.60x | 33,480 | 418 | 212 | 86% | 205 | 56.2 | 112.4 | 15% |

| statement buyers a day at launch | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 3 | 29,850 | 372 | 117 | 87% | 255 | 27.9 | 55.8 | 19% |
| 8 | 31,640 | 395 | 168 | 86% | 225 | 43.4 | 86.8 | 18% |
| 20 | 38,120 | 476 | 344 | 84% | 131 | 95.3 | 190.7 | 14% |
| 40 | 49,080 | 613 | 599 | 89% | 13 | 181.6 | 363.1 | 14% |

7. willingness to pay: 0.7x the observed sells 91 statements, 1.0x sells 168, 1.6x sells 212, and eth recycled goes 43.5, 86.8, 112.4. buyers a day: 3 sell 117, 20 sell 344, 40 sell 599 (recycled 55.8, 190.7, 363.1), and credits go from 29,850 to 49,080. 2.5 times more buyers (20 a day) lifts eth recycled by 120 percent. the owner chooses how the stock is offered to the buyers that come.
8. the average price moves 5 points across 3 to 40 buyers a day (87, 86, 84, 89 percent of cost).

**changing a setting later.** one change on day N, comparable volume, 5 seeds, against launch:

| change on day N | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| day 7: both floors to 6000 | 32,570 | 407 | 212 | 74% | 193 | 47.8 | 95.6 | 8% |
| day 14: both floors to 6000 | 32,350 | 404 | 201 | 77% | 201 | 46.9 | 93.9 | 9% |
| day 30: both floors to 6000 | 32,520 | 406 | 197 | 81% | 207 | 48.1 | 96.2 | 9% |
| day 14: `startBps` to 9000 | 31,360 | 392 | 170 | 81% | 219 | 41.7 | 83.3 | 17% |
| day 14: buy only | 33,030 | 412 | 200 | 86% | 212 | 51.3 | 102.6 | 1% |
| day 14: `feeToBuybackBps` to 2500 | 31,560 | 394 | 170 | 85% | 223 | 44.6 | 87.2 | 15% |
| launch, no change | 31,740 | 396 | 170 | 86% | 224 | 43.8 | 87.6 | 18% |
| both floors 6000 from launch | 32,510 | 406 | 209 | 74% | 196 | 47.4 | 94.8 | 8% |

9. a cut of both floors adds eth recycled whenever it is made in the first month: day 7 cut 95.6, day 14 cut 93.9, day 30 cut 96.2, cut at launch 94.8, against 87.6 at launch values. a day 14 cut sells 201 at 77 percent, a cut at launch 209 at 74 percent. lowering only `floorBps` changes nothing until `saleFloorBps` is lowered too (the Core's hard floor wins).
10. `startBps` down to 9000 on day 14 loses eth (83.3 against 87.6 recycled). buy only on day 14 gives most of the gain of buy only from launch (102.6 and 105.5 recycled). the fee share on day 14 leaves the result unchanged (89 percent of the fees are already in). the three levers differ in timing: the floors can be cut once the first weeks show the stock waiting, the fee share has to be chosen at launch, the mode can be switched at any time.

recommendation for the sale design: **keep the launch values** (11000, 3 hours, 100, floor 7500, auction, fee share 0). in this model the curve moves the average price by 13 points across its dials and credits by 3 percent, while the pick rule and the number of buyers move eth recycled by 38 percent and more. the owner's useful moves after week two, in order: lower both floors to 6000 if statements older than the 105 hours of the curve keep piling up and fewer than one sells a day (comparable volume gains 8 percent eth recycled, 17 eth a day loses 7 percent), switch to buy only if second bidders pile onto live auctions (comparable volume gains 20 percent eth recycled, 17 eth a day gains 3 percent), raise `startBps` or `stepEvery` if the average price over cost is low while few statements wait, shorten `auctionDuration` if second bidders are a large share of sales.

## 5. the proceeds split

`saleToBuybackBps` is the share of sale proceeds that goes to the coin buyback, the rest to the pot. it applies the same in auction mode (at `collectSales`) and in buy only mode (at the sale). the fee share is a separate setting (section 4, row 4).

| saleToBuybackBps | credits day 7 | day 30 | day 90 | statements created | sold | eth spent buying $CC | percent of supply burned | steady credits a day |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 10,120 | 31,000 | 38,010 | 474 | 196 | 0.0 | 0.0% | 115 |
| 2500 | 10,120 | 29,720 | 34,300 | 428 | 173 | 21.6 | 6.4% | 74 |
| 5000 | 10,120 | 28,110 | 31,740 | 396 | 170 | 43.8 | 10.6% | 59 |
| 7500 | 10,120 | 26,600 | 28,890 | 361 | 168 | 66.0 | 13.4% | 39 |
| 10000 | 10,120 | 24,970 | 25,840 | 323 | 173 | 93.6 | 15.9% | 14 |

sustained 17 eth a day: credits at day 90 48,480 / 45,830 / 43,060 / 40,220 / 37,170, eth spent buying coin 0 / 24.4 / 48.6 / 73.7 / 99.1, steady credits a day 263 / 244 / 223 / 203 / 178. sustained 50: 68,810 to 59,260 credits, 0 to 105.4 eth burned.

1. the split leaves the first week unchanged (10,120 credits on day 7 in every row). it acts after the launch pot is gone, when sale proceeds are the pot's main income.
2. the price of burn in credits: from 0 to 100 percent the engine gives up 12,170 credits (32 percent) for 93.6 eth of burn, 130 credits per eth at comparable volume, 114 at 17 eth a day.
3. the burn side is modest: 100 percent buys 15.9 percent of the supply, 0 burns 0 percent. the steady credit flow falls from 115 to 14 a day. with the owner's order of goals (credits first, burn fifth) the split is the first thing to move toward the pot if credits per day matter more than burn.
4. launch at 5000 leaves week one untouched. decide between day 7 and day 18 when the pot is gone and the steady flow is visible.
5. against the fee share: an extra eth of burn through `feeToBuybackBps` costs 74 to 101 credits (section 4, row 4), the sale share about 130, and fees come on day one, so the fee lever has to be set at launch while the sale split can be turned any week.

## 6. the bid rule: drop, climb, ceiling, clamp

comparable volume, 90 days, launch values `dropPerCreditBps` 50, `dropFloorBps` 8000, `climbPerMinBps` 50, `ceilBps` 12500, `idleLoosenBps` 200, `clampCredits` 20, `spendCapBps` 2000, 5 seeds. one setting changes per table.

the mechanism. each credit bought lowers the bid by `dropPerCreditBps` and the bid climbs `climbPerMinBps` a minute, so the bid is stationary where the engine buys `climbPerMinBps / dropPerCreditBps` credits a minute. the launch values give 1 a minute, about 1,440 a day, while the pot affords it. the ceiling holds the bid under `ceilBps` of the last fill rate, the drop floor limits one minute of buying to a fall of 10000 minus `dropFloorBps` from the rate at the first fill of that minute, and the clamp lowers the read bid to the rate at which the hourly cap affords `clampCredits` average credits.

| climbPerMinBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 25 | 2,288 | 5,153 | 10,180 | 21,650 | 38,390 | 0.77x | 0.82x | 47.4 | 1 |
| **50** | 4,394 | 10,120 | 20,140 | 28,110 | 31,740 | 0.86x | 1.19x | 17.9 | 25 |
| 100 | 8,607 | 19,100 | 20,820 | 22,400 | 25,360 | 0.98x | 2.27x | 6.5 | 72 |
| 200 | 13,690 | 15,560 | 17,320 | 18,990 | 21,970 | 1.11x | 3.57x | 2.5 | 123 |

| dropPerCreditBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 25 | 8,523 | 19,050 | 20,820 | 22,290 | 25,410 | 0.98x | 2.06x | 6.5 | 81 |
| **50** | 4,394 | 10,120 | 20,140 | 28,110 | 31,740 | 0.86x | 1.19x | 17.9 | 25 |
| 100 | 2,285 | 5,143 | 10,140 | 21,580 | 38,420 | 0.76x | 0.82x | 47.8 | 0 |
| 200 | 1,218 | 2,641 | 5,128 | 10,820 | 32,150 | 0.69x | 0.80x | after day 90 | 0 |

| dropFloorBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 5000 | 4,300 | 10,020 | 20,050 | 28,420 | 31,990 | 0.86x | 1.18x | 18.2 | 26 |
| **8000** | 4,394 | 10,120 | 20,140 | 28,110 | 31,740 | 0.86x | 1.19x | 17.9 | 25 |
| 9500 | 4,965 | 10,690 | 20,720 | 27,960 | 31,520 | 0.87x | 1.27x | 17.4 | 28 |

| ceilBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 11000 | 4,394 | 10,120 | 20,140 | 28,170 | 31,590 | 0.87x | 1.12x | 17.9 | 24 |
| **12500** | 4,394 | 10,120 | 20,140 | 28,110 | 31,740 | 0.86x | 1.19x | 17.9 | 25 |
| 15000 | 4,394 | 10,120 | 20,140 | 28,110 | 31,740 | 0.86x | 1.19x | 17.9 | 25 |
| 20000 | 4,394 | 10,120 | 20,140 | 28,110 | 31,740 | 0.86x | 1.19x | 17.9 | 25 |

| idleLoosenBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 4,394 | 10,120 | 20,140 | 28,170 | 31,860 | 0.86x | 1.16x | 17.9 | 27 |
| 100 | 4,394 | 10,120 | 20,140 | 28,100 | 31,660 | 0.86x | 1.18x | 17.9 | 25 |
| **200** | 4,394 | 10,120 | 20,140 | 28,110 | 31,740 | 0.86x | 1.19x | 17.9 | 25 |
| 500 | 4,394 | 10,120 | 20,140 | 28,110 | 31,740 | 0.86x | 1.19x | 17.9 | 25 |

| clampCredits | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 4,394 | 10,120 | 20,140 | 27,110 | 28,190 | 0.99x | 5.98x | 17.9 | 953 |
| 5 | 4,394 | 10,120 | 20,140 | 27,600 | 30,220 | 0.92x | 2.84x | 17.9 | 475 |
| **20** | 4,394 | 10,120 | 20,140 | 28,110 | 31,740 | 0.86x | 1.19x | 17.9 | 25 |
| 50 | 4,394 | 10,120 | 20,140 | 28,100 | 31,800 | 0.86x | 0.95x | 17.9 | 0 |

| spendCapBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 500 | 4,304 | 10,030 | 20,060 | 27,870 | 31,570 | 0.87x | 1.78x | 18.0 | 43 |
| 1000 | 4,361 | 10,080 | 20,110 | 28,050 | 31,690 | 0.86x | 1.45x | 18.0 | 29 |
| **2000** | 4,394 | 10,120 | 20,140 | 28,110 | 31,740 | 0.86x | 1.19x | 17.9 | 25 |
| 4000 | 4,538 | 10,260 | 20,290 | 28,050 | 31,360 | 0.87x | 1.00x | 17.9 | 11 |

1. `climbPerMinBps` and `dropPerCreditBps` set the pace and the price together. the pace follows their ratio: climb 100 or drop 25 (ratio 2) buys 2 credits a minute, 8,607 and 8,523 credits by day 3, spends the pot on day 6.5 and pays 0.98 times market with a peak bid of 2.1 to 2.3 times market; climb 25 or drop 100 (ratio 0.5) buys 0.5 a minute, 2,288 and 2,285 credits by day 3, spends the pot on day 47 to 48 and pays 0.76 to 0.77 times market. the faster rules end lower on comparable volume (25,360 and 25,410 credits at day 90, 20 percent under launch) and the slower rules higher (38,390 and 38,420, 21 percent over launch), because the slow rule spends the same pot at lower prices and the sale proceeds keep funding it. `dropPerCreditBps` 200 leaves part of the pot unspent at day 90.
2. `dropFloorBps` limits bursts. 9500 allows a fall of 5 percent a minute: day 3 holds 4,965 credits (4,394 at launch) with a peak bid of 1.27 times market and day 90 31,520. 5000 differs little from 8000 (4,300 by day 3, 31,990 at day 90).
3. `ceilBps` trims the peak bid below launch. 11000 lowers the peak bid to 1.12 times market and moves credits by under 1 percent (31,590 at day 90). 12500, 15000 and 20000 give the same result on a flat market, because the bid stays under 125 percent of the last fill rate anyway. it is a guard for markets that rise fast.
4. `idleLoosenBps` leaves a flat market unchanged (credits at day 90 within 1 percent for 0, 100, 200, 500). its job is to raise the ceiling after a stretch of minutes in which nothing fills, which docs/BID-STUDY.md measures.
5. `clampCredits` is the guard on a thin pot. at 1 the clamp is the hourly cap over one credit: the bid reaches 6 times market, the engine pays 0.99 times market and ends 11 percent lower (28,190), and the cap blocks buying for 953 minutes. at 5 the peak is 2.8 times and credits are 30,220. 20 holds the peak at 1.19 times market. 50 gives 31,800 credits and a peak of 0.95.
6. `spendCapBps` moves credits by 1 percent across 500 to 4000. it sets the clamp together with `clampCredits`: the peak bid is 1.78 times market at 500, 1.45 at 1000, 1.19 at 2000 and 1.00 at 4000.
7. hard cases (3 seeds, opening limit 40 percent in a recovering market, or a declining market) give the same ranking: pace sets the outcome. recovering market, credits at day 90: 25,320 at launch, 21,920 at `climbPerMinBps` 200 (0.98x paid) and 25,370 at 25. declining market: 40,630 at launch, 64,870 at `climbPerMinBps` 25 (0.79x paid) and 21,740 at 200 (1.19x paid). in a falling market the slow bid gains the most because it spends the pot at lower prices.

recommendation: **keep the launch values.** they buy 1 credit a minute, 4,394 credits by day 3 and 20,140 by day 14, at 0.86 times market with a peak bid of 1.19 times market. what changes the answer is the goal: earlier credits at a higher price (`climbPerMinBps` 100 gives 8,607 by day 3, ends 20 percent lower at day 90 and pays 0.98 times market), or more credits later at a lower price (`climbPerMinBps` 25 gives 21 percent more at day 90 at 0.77 times market, with 5,153 by day 7 against 10,120). since the goal is early credits, keep. the signals to watch: price paid over market near 1.0 or above, or a peak bid above 1.3 times market, mean the climb outpaces the drop: lower `climbPerMinBps` or raise `dropPerCreditBps`.

## 7. after the launch pot: credits and statements per day against coin volume

coin volume that decays from day two to the stated constant by about day 10 (custom preset), last 30 days of a 90 day run, launch values.

| coin volume, eth a day | fees a day, eth | launch pot spent on day | steady credits a day | steady statements a day | steady sold a day | eth a day buying $CC | credits acquired by day 90 | waiting for phase 2 at day 90 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 0.059 | 17.6 | 60 | 0.7 | 1.0 | 0.23 | 31,700 | 223 |
| 5 | 0.293 | 17.8 | 106 | 1.3 | 1.3 | 0.26 | 35,190 | 246 |
| 17 | 0.998 | 18.6 | 218 | 2.7 | 1.6 | 0.27 | 44,330 | 332 |
| 50 | 2.935 | 21.4 | 478 | 6.0 | 1.5 | 0.31 | 64,990 | 591 |
| 150 | 8.805 | 44.8 | 652 | 8.2 | 1.5 | 0.43 | 95,150 | 976 |

1. sale proceeds carry about 52 credits a day at any volume, and coin fees add to that, about 8 to 12 credits a day per eth of daily volume up to 50 eth a day (fees reaching the pot are 5.87 percent of volume in steady state, a credit costs about 0.0077 eth at 0.86 times market). the flow grows with volume up to 50 eth a day.
2. statements a day are credits over 80. sold a day saturates at 1 to 2 whatever the volume, because buyers stay at 8 a day decaying to 2 as supply grows ( 26 percent of them find no price). the waiting stock grows by the difference.
3. at 150 eth a day the engine has bought 95,150 credits by day 90, 98 percent of the 96,800 float, the launch pot lasts until day 45 and the steady flow is 652 a day. at 50 eth a day it holds 67 percent of the float by day 90 (64,990). a bigger float is a hard cap on credits acquired.
4. five times more statement buyers (40 a day decaying to 10) lift steady flow at 17 eth a day from 218 to 424 credits a day (sale proceeds) and sold from 220 to 795 in 90 days. the sale side is the lever below 17 eth a day.
5. the buyback spends 0.23 to 0.43 eth a day after the launch pot.

## 8. phase 2

the owner sets the exitModule at once, on day 14, 30 or 60. the keeper exits every eligible unbid listing (older than `exitAfter`, 105 hours) at once. an exit pays `rating * unitPerPoint` of exitToken, so the value in eth is the rating times the exitToken price per point (`xp`). a typical exited statement rates about 33,500 points and costs about 0.75 eth, so the break even exitToken price is about 2.25e-5 eth per point, and the price at which an exit returns the hard floor of 75 percent of cost is about 1.7e-5. the comparison without a module is 31,640 credits at day 90 (3 seeds).

| module on day | exitToken price per point | stock waiting before | statements exited by day 90 | exit value over cost | exit bid pot after 7 days | exit bid rate after 7 days, bps of score | credits bought through the exit bid by day 90 | credits acquired by day 90 | percent of supply burned |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 14 | 5e-6 | 183 | 249 | 0.23 | 18 | 9,700 | 0 | 29,170 | 10.1% |
| 14 | 1e-5 | 183 | 349 | 0.45 | 36 | 9,692 | 8,152 | 37,210 | 11.9% |
| 14 | 2e-5 | 183 | 359 | 0.89 | 74 | 5,233 | 9,180 | 38,800 | 14.9% |
| 14 | 3e-5 | 183 | 362 | 1.34 | 118 | 3,480 | 9,280 | 39,230 | 17.0% |
| 14 | 5e-5 | 183 | 707 | 2.23 | 222 | 3,006 | 37,040 | 66,490 | 19.9% |
| 14 | 1e-4 | 183 | 1,133 | 3.60 | 1,042 | 3,000 | 72,110 | 98,120 | 23.7% |
| 30 | 1e-5 | 245 | 331 | 0.45 | 42 | 9,564 | 6,931 | 36,220 | 11.0% |
| 30 | 3e-5 | 245 | 336 | 1.35 | 138 | 3,232 | 7,363 | 37,380 | 15.4% |
| 30 | 5e-5 | 245 | 627 | 2.24 | 291 | 3,002 | 30,640 | 59,980 | 18.1% |
| 60 | 1e-5 | 236 | 278 | 0.45 | 40 | 9,353 | 3,396 | 33,830 | 10.4% |
| 60 | 3e-5 | 236 | 282 | 1.34 | 134 | 3,157 | 3,762 | 34,490 | 12.7% |
| 60 | 5e-5 | 236 | 430 | 2.24 | 284 | 3,009 | 15,530 | 45,900 | 14.5% |

1. the stock is of similar size whenever the module arrives: 183 unbid statements on day 14 (the pot lasts until day 18, so the stock is still growing), 245 on day 30 and 236 on day 60, then about one a day sells. the exit takes the whole stock at the first hour.
2. what an exit is worth depends on the exitToken price only. exit value over cost is 0.23 at 5e-6, 0.89 at 2e-5, 1.34 at 3e-5 and 2.23 at 5e-5. below 2.25e-5 the exit gives back less than the engine paid, below 1.7e-5 less than the hard floor.
3. the exit feeds the engine. an exit puts 50 percent of the exitToken in the exit bid pot (`exitToBuyback`), which buys credits through the exit lane. at 1e-5 that bought 8,152 credits by day 90 when the module arrives on day 14 (the exit bid pays by score, so it buys the high score credits first) and lifted credits acquired from 31,640 to 37,210, 18 percent. at 5e-5 and 1e-4 the pot is so large the bid sits at its floor and still buys 37,040 to 72,110 credits, more than the float allows in practice, so read these as an upper bound. a later arrival gives less because less time remains: 8,152 on day 14, 6,931 on day 30, 3,396 on day 60 at 1e-5.
4. exit bid pace: the bid climbs 100 bps an hour while its pot affords one average credit, so it reaches 9,350 to 9,700 bps within a week when the price is low (5e-6, 1e-5) and sits near its 3,000 floor when the pot is large against the price (5e-5 and up), where each credit bought drops it 20 bps.
5. the exitToken dutch auction runs at a pace of one slice per half life by design: 292 fills in 76 days at about 6 hours each, mean 14.9 percent all in discount to the pool price at the taker threshold. a slice is 20 average credits of exitToken, 0.26 eth of value at 3e-5. one slice per 6 hours is about 1 eth of exitToken a day. the exit of 362 unbid statements puts about 251 eth of exitToken into the two pots at 3e-5 (module on day 14), half to the exit bid pot and 126 eth to the auction pot: 76 eth of it has been filled and 50 eth is still waiting at day 90. a large exit batch waits months for the auction. a larger `exitSliceCredits` or a shorter `xAuctionHalfLife` speeds it.
6. a keeper that exits only when the module pays at least the asking price (instead of at once) exits 0 statements at 1e-5 and sells 168 statements by day 90 against 121 when it exits at once, and credits end at 31,640 against 36,220. `exitStatement` is permissionless, so at a low exitToken price anyone can force the exit of listings that a buyer would still have bought. the owner controls this through `exitAfter` and the moment the exitModule is set.

## 9. sensitivity ranking

low and high value of each input against the base case (31,740 credits and 396 statements at day 90, 170 sold at 86 percent of cost, 43.8 eth burned; the rows are 3 seed runs, base 3 seeds 31,640 credits and 168 sold). statements created move by the same share as credits, because 80 credits make one statement. ranked by the swing in credits.

| rank | input | low | high | credits low | credits high | swing | statements sold low | statements sold high | avg sale price low | avg sale price high |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | coin volume scale | 0.25x | 4x | 14,320 | 99,090 | 592% | 165 | 197 | 91% | 77% |
| 2 | flat credit price, eth | 0.0045 | 0.018 | 57,050 | 18,490 | 209% | 178 | 156 | 82% | 89% |
| 3 | `climbPerMinBps` | 25 | 200 | 38,810 | 22,020 | 76% | 232 | 145 | 81% | 92% |
| 4 | seller offers an hour | 60 | 400 | 23,660 | 38,880 | 64% | 109 | 208 | 89% | 85% |
| 5 | credit price path | decline | recovery | 40,630 | 25,480 | 59% | 145 | 223 | 84% | 80% |
| 6 | `saleToBuybackBps` | 0 | 10000 | 38,430 | 25,870 | 49% | 203 | 180 | 84% | 79% |
| 7 | anti sniper volume share | 0.2 | 0.6 | 25,890 | 38,030 | 47% | 167 | 185 | 86% | 84% |
| 8 | `flatBps` | 0 | 10000 | 23,210 | 31,640 | 36% | 113 | 168 | 87% | 86% |
| 9 | engine price impact | 0 | 0.3 | 35,190 | 25,840 | 36% | 187 | 147 | 85% | 87% |
| 10 | statement buyers a day | 3 | 20 | 29,850 | 38,120 | 28% | 117 | 344 | 87% | 84% |
| 11 | `dropPerCreditBps` | 25 | 200 | 25,430 | 32,150 | 26% | 141 | 226 | 90% | 84% |
| 12 | `feeToBuybackBps` | 0 | 2500 | 31,640 | 25,840 | 22% | 168 | 161 | 86% | 87% |
| 13 | hour one share of day one volume | 0.45 | 0.7 | 28,940 | 34,060 | 18% | 168 | 174 | 86% | 85% |
| 14 | statement willingness to pay | 0.7x | 1.3x | 28,400 | 32,580 | 15% | 91 | 193 | 85% | 86% |
| 15 | `clampCredits` | 1 | 50 | 28,240 | 31,910 | 13% | 181 | 176 | 77% | 86% |
| 16 | seller ask spread | 0.15 | 0.4 | 29,740 | 33,330 | 12% | 159 | 174 | 84% | 86% |
| 17 | buyer pick rule | cheapest | random | 31,640 | 34,570 | 9% | 168 | 231 | 86% | 79% |
| 18 | listed share of offers | 0 | 0.5 | 31,640 | 33,990 | 7% | 168 | 182 | 86% | 85% |
| 19 | sale mode | auction | buy only | 31,640 | 33,470 | 6% | 168 | 209 | 86% | 86% |
| 20 | `auctionDuration` | 6h | 72h | 33,210 | 31,580 | 5% | 202 | 166 | 86% | 86% |
| 21 | gas price, gwei | 0.5 | 10 | 31,850 | 31,100 | 2% | 169 | 173 | 86% | 86% |
| 22 | `startBps` | 9000 | 13000 | 31,620 | 32,300 | 2% | 180 | 172 | 79% | 92% |
| 23 | both floors (`floorBps`, `saleFloorBps`) | 5000 | 7500 | 32,320 | 31,640 | 2% | 233 | 168 | 63% | 86% |
| 24 | buyers wait for the floor | no | yes | 31,640 | 32,250 | 2% | 168 | 195 | 86% | 75% |
| 25 | seller book churn | 0.02 | 0.15 | 32,170 | 31,640 | 2% | 172 | 175 | 86% | 85% |
| 26 | `spendCapBps` | 1000 | 4000 | 31,830 | 31,310 | 2% | 175 | 164 | 85% | 85% |
| 27 | seller supply elasticity | 0.5 | 3 | 31,890 | 31,620 | 1% | 174 | 168 | 86% | 86% |
| 28 | `idleLoosenBps` | 0 | 500 | 31,800 | 31,640 | 1% | 172 | 168 | 86% | 86% |
| 29 | `rateStart` | 25% | 125% | 31,940 | 32,100 | 1% | 176 | 179 | 85% | 86% |
| 30 | `stepEvery` | 1h | 6h | 31,640 | 31,600 | 0% | 177 | 161 | 81% | 90% |
| 31 | `ceilBps` | 11000 | 20000 | 31,630 | 31,640 | 0% | 168 | 168 | 86% | 86% |
| 32 | coin buy share after day one | 0.42 | 0.52 | 31,640 | 31,640 | 0% | 168 | 168 | 86% | 86% |
| 33 | `exitAfter` | 24h | 168h | 31,640 | 31,640 | 0% | 168 | 168 | 86% | 86% |

1. credits acquired follow the money (coin volume), the price of a credit and the supply of sellers. these are inputs of the world.
2. of the settings six matter for credits: `climbPerMinBps` (76 percent), `saleToBuybackBps` (49), `flatBps` (36), `dropPerCreditBps` (26), `feeToBuybackBps` (22) and `clampCredits` (13). `climbPerMinBps` is the biggest, as the pace dial of section 6. `saleToBuybackBps` is the owner's choice between burn and credits, and the fee share is the same choice at launch.
3. for statements sold the order is different: the buyer rules (buyers a day 117 to 344 sold, willingness to pay 91 to 193, pick rule 168 to 231), then the bid pace through credits (`climbPerMinBps` 232 to 145, `dropPerCreditBps` 141 to 226), `flatBps` (113 to 168), both floors (233 against 168), buy only (168 to 209) and `auctionDuration` (202 to 166). the sale design moves the average price more than the count: 79 to 92 percent across `startBps`, 81 to 90 across `stepEvery`, 63 to 86 across the floors.
4. `rateStart`, `spendCapBps`, `idleLoosenBps`, `ceilBps`, `exitAfter` and the whole sale design (the curve, the floors, the mode) move credits acquired by 6 percent or less. the sale design acts on statements sold and eth recycled, and leaves credits and statements created close to unchanged.

## 10. what the model cannot tell us, and its weakest assumptions

1. the ask distribution. only fills are visible, so the ask distribution behind them is inferred. the cheap tail of sellers (lognormal spread 0.27) sets how cheap the first credits are and how fast the price climbs. a thinner tail means the engine overpays from the first fill. the engine pays its bid to every seller that clears, so the first fill price is a bid. docs/BID-STUDY.md tests the bid rule against other ask distributions.
2. statement demand and buyer behaviour. 42 priced sales over 5 days, all at fixed prices. arrivals are fixed at 8 a day decaying to 2 **whatever the price level or the curve**, so a lower price in the model sells to the same buyers. in reality a cheaper statement may draw more, and a buyer who sees a falling price may wait for it: the pessimistic run is that case with every buyer waiting for the floor, and it sells 190 to 197 statements because the buyers keep arriving. a real buyer that waits also arrives less often at a high price.
3. the two prices. a buyer judges a statement against the MARKET cost of its parts, the curve is set against what the engine PAID. the engine pays 0.86 times market on comparable volume and 0.82 on sustained volume, so a start price of 110 percent of cost is 95 percent of market in one case and 90 in the other. buyers who judge by something else (the rating, the best score inside, a rare credit) are outside the model. willingness to pay is rating insensitive and that may change once the exitModule pays by rating.
4. the coin net flow. buy share after day one (0.46) drives the coin price and so the percent of supply burned. volume is exogenous and independent of buybacks and statement sales.
5. the engine's own footprint. price impact elasticity 0.12 is a guess. credits acquired swing 36 percent between impact 0 and 0.3. the lift also raises statement willingness to pay in the model.
6. seller supply and the float. 150 offers an hour, 5 percent leave an hour, more when the bid is above market, a float of 96,800 credits, which shrinks as credits are burned into statements. the model has one kind of seller. a whale seller, a strategy relist at 1.2x and a competing protocol bid like the fwa hub at 0.029 flat are outside it. at 50 eth a day the engine buys 67 percent of the float and at 150 eth a day 98 percent.
7. the anti sniper volume (40 percent of hour one volume inside 30 minutes) is inferred from the comparable's implied 406 eth against 194 eth at a flat 10 percent. 89 percent of fees come on day one, so the starting pot is the biggest input and the least observed, and the fee share is only worth setting on day one. credits acquired swing 47 percent across 20 to 60 percent.
8. phase 2 is parametric. the exitToken price per point is a constant, the module pays exactly `rating * unitPerPoint`, a keeper exits every eligible listing at once, takers fill exactly at their threshold, credit sellers compare exit bids frictionlessly, and the exit bid buying 37,000 to 72,000 credits at high prices ignores the float.
9. keepers and fees. `collectSales` runs every hour, `endAuction` is called the moment an auction ends, the first bidder reprices the listing to the asking price in the same step, the buyback keeper runs every 25 blocks. the Core pulls the fee router at the start of each sell and compose door, so fees wait in the router between door calls; the model books them as they arrive (flush delay 0, keeper cadence 0). the flush tip is the 0.5 percent upper bound. the 1 eth buyback executes at the pool price, and wash volume is 0 (71 percent of the comparable's pool volume was churn and the model treats it as organic fee base). a house delivery failure (30 day unwind) is outside the model, and so is a bid placed on the house at the start price in buy only mode.
10. the launch day market price. the opening limit is a share of the market price on launch day. the model holds that price at 0.0089 eth (or its path). a different price on the day moves the rate with it, which is why the limit is set on launch day.
11. the owner. the model has one change at a time at a known day. a real owner reacts to signals and may change several settings at once, which the Core allows, and the controller's settings and the Core's are separate calls (lowering `floorBps` without `saleFloorBps` changes nothing). the stepped bid fields (`dropPerCreditBps` and the rest) are fixed in the model for a run: `schedule` patches the Core settings and the controller settings, so the stepped fields stay fixed for a run. the owner key is trusted fully and every change applies at once: the model assumes an owner who announces every change.

## recommended launch settings

| setting | launch value | recommendation | why |
|---|---|---|---|
| `rateStart` | 2.0554e13 (100% of market) | keep | buys at once, first 80 cost 0.86x market, day 1 holds 1,552 credits against 1,149 at 25%. later totals are flat across 25% to 125% |
| `flatBps` | 10000 | keep | most credits and statements. a blend of 7500 later buys 23% more score for 4% of credits |
| `avgScore` | 4,330,000 | keep | the population mean is 440 points, flat buys 425 |
| `dropPerCreditBps`, `climbPerMinBps` | 50, 50 | keep | 1 credit a minute, about 1,440 a day while the pot lasts, 0.86x market, peak bid 1.19x. the ratio sets the pace: 100 on the climb is earlier and dearer, 25 later and cheaper |
| `dropFloorBps` | 8000 | keep | limits one minute of buying to a 20% fall. 9500 raises the peak bid to 1.27x |
| `ceilBps`, `idleLoosenBps` | 12500, 200 | keep | guards for fast markets and gaps. same result as launch on a flat market |
| `clampCredits` | 20 | keep | holds the peak bid at 1.19x market. at 1 the peak is 6x and credits are 11% lower |
| `spendCapBps` | 2000 | keep | sets the clamp with `clampCredits`. credits move 1% across 500 to 4000. at most 5000 |
| `rateCap` | 1.232e14 | keep | about 6 times `rateStart`. the peak bid is 1.19x market, so the cap stays out of reach at launch values. it is the owner's "never pay more than this per credit" |
| `startBps`, `stepBps`, `stepEvery`, `floorBps` | 11000, 100, 3 hours, 7500 | keep | the curve moves the average price by 13 points and credits by 3 percent at most. higher or slower is more eth per sale, lower or faster sells about the same count |
| `saleFloorBps` | 7500 | keep | the hard floor wins: lowering `floorBps` alone changes nothing, lower both together. cut both to 6000 on day 7 to 30 if old statements pile up (comparable volume: 23% more sold, 8% more eth recycled) |
| `buyOnly` | false (auction) | keep, switch later if second bidders pile onto live auctions | buy only sells 21% more statements and recycles 20% more eth under the lowest ask rule, 3% more statements under random pick, credits +5% |
| `auctionDuration` | 24 hours | keep, shorten if the second bidder share is high | 6 hours recycles 15% more eth under the lowest ask rule. a real house may differ |
| `feeToBuybackBps` | 0 | keep: a launch decision | 89% of fees come on day one. 1000 burns 57% more eth for 6% fewer credits, 2500 burns 2.3 times for 18% fewer. after day 7 the result is unchanged |
| `saleToBuybackBps` | 5000 | keep for the first week | the first week is unchanged by it. decide between day 7 and day 18, it is the largest lever left |
| `reimburseBps` | 8000 | keep | compose reimbursement, in every run |
| `exitAfter` | 105 hours | keep, and keep it equal to the hour the curve reaches its floor | applies in phase 2 only. if `stepEvery` or `stepBps` slow the curve, raise it with them, or statements exit before they reach their lowest price |
| `exitToBuybackBps`, `exitLaneToBuybackBps` and exitToken settings | as launched (the exit lane share is 0: exit lane proceeds stay in the exit bid pot) | keep | phase 2 only. the auction pace is slow (1 slice per 6 hours) |

## settings the owner should expect to adjust, and the signal

| setting | expected move | signal to watch |
|---|---|---|
| `floorBps` with `saleFloorBps` | 7500 to 6000 together | statements older than 105 hours keep piling up and fewer than one sells a day |
| `startBps`, `stepEvery` | up, to raise the price | average sale price over cost low while few statements wait |
| `buyOnly` | to true | second bidders pile onto live auctions, or buyers skip auctions |
| `auctionDuration` | shorter | second bidders a large share of sales (18% at launch in the model) |
| `feeToBuybackBps` | only at launch | the owner prefers burn over credits in the first week |
| `saleToBuybackBps` | toward the pot if credits matter more than burn, toward the buyback if burn does | credits a day after the pot is spent under 50 at launch volume, eth spent buying coin per day |
| `climbPerMinBps`, `dropPerCreditBps` | lower the climb or raise the drop | price paid over market near 1.0 or above, the bid above 130% of market for more than a day |
| `setRate` | reset the limit | the market price of a credit moves 30% from the launch day value in week one, or the pot sits unspent for days with the bid under market |
| `flatBps` | 7500 | credits flowing steadily and the average score bought below the population mean of 440 |
| `exitSliceCredits`, `xAuctionHalfLife` | larger slice or shorter half life | exitToken waiting for the auction above 30 days of slices after phase 2 |
| `exitAfter` | longer, if the exitToken price is below the break even of about 2.25e-5 per point, or with a slower curve | exitToken price per point against 0.75 eth over a 33,500 point statement |

## files

sim/engine.js (model, the single source), sim/engine.test.mjs (567 checks), sim/run.mjs (batches, `node run.mjs q1 to q11`), sim/results/*.json, sim/build.mjs and the page parts (page.css, page.body.html, page.ui1.js to page.ui4.js), sim/index.html (built, single file, 5 minute steps). a 90 day run takes 5.7 seconds at 60 second steps. the 11 batches run as parallel processes in 40 minutes on a 16 core machine (the longest, q4, takes 40 minutes alone).
