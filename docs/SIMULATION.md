# simulation of the credits engine

follows the contract at commit `cd7d404`. launch values are script/config/mainnet.json.

sim/engine.js is a deterministic model of the engine in src/Core.sol, src/lib/CoreLib.sol and src/ControllerV1.sol on branch flow. it covers the stepped bid rule (drop per credit, drop floor, climb per minute, ceiling with idle loosening, the clamp at one average credit, `rateCap`), the blended bid (`flatBps`, `avgScore`), the funded flag, the hourly cap, both buy doors, compose, the statement asking price (controller settings `startBps`, `stepBps`, `stepEvery`, `floorBps`, `buyOnly`) with the Core's hard floor `saleFloorBps`, the english auction on the pnd auction house, instant sales in buy only mode, `collectSales`, the swap fee share `feeToBuybackBps`, the buyback, the exit lane, the exitToken bid, the exitToken dutch auction and settings changes mid run. rules and names are the contracts' (docs/FLOW.md section 9). launch values are script/config/mainnet.json and a test reads the file. the launch position is concentrated liquidity math. sellers, statement buyers and coin volume are calibrated on the 13 day data pull in sim/data/notes.md. the time step is 60 seconds after the first hour (the first hour runs in 120 second sub steps for the anti sniper window), which matches the minute bucket of the contract's drop floor and climb. every number below is a mean over 3 to 5 seeds of a 90 day run unless stated. raw rows are in sim/results/*.json (node run.mjs q1 to q11), the interactive page is sim/index.html. `exitModule` and `exitToken` are the only names used for phase 2. the owner sets the exitModule, the controller and the allowed targets at once, so every change applies at once in the model.

the bid rule is `bidRule: 'stepped'`. the earlier rule stays available as `bidRule: 'built'` for the comparison in docs/BID-STUDY.md.

## base case, before and after

the headline of the previous runs next to this run. the previous run used the built bid rule (opening limit 75 percent of market, `reimburseBps` 11000), a router split of `bountyBps` 9000 and 161,031 ppm to the payee, and hourly time steps. the columns "launch, before the window pot fix" and "launch, clamp 20 credits (previous run)" use the earlier launch values: stepped bid rule (`dropPerCreditBps` 50, `dropFloorBps` 8000, `climbPerMinBps` 50, `ceilBps` 12500, `idleLoosenBps` 200 per 10 minutes, `clampCredits` 20), `spendCapBps` 2000, `rateCap` 1.232e14 (about 6 times `rateStart`), opening limit 100 percent of market (`rateStart` 2.0554e13 wei per point), `reimburseBps` 8000, `bountyBps` 9638, 112,778 ppm to the payee, 60 second steps. the column "launch, before the window pot fix" is that run before the model followed the contract's hourly spend window (eth booked while a window is open raises the window pot and the room); "launch, clamp 20 credits (previous run)" is that run with the rule. "launch (this run)" uses the final launch values: the same stepped bid rule with the clamp at the rate where the hourly cap affords one average credit (no `clampCredits`), `spendCapBps` 10000 and `rateCap` 2.0554e14 (10 times `rateStart`). comparable coin volume, 5 seeds, day 90.

| comparable volume, day 90 | previous run (stored) | previous settings, rerun | previous bid rule, launch router split | launch, before the window pot fix | launch, clamp 20 credits (previous run) | launch (this run) |
| --- | --- | --- | --- | --- | --- | --- |
| credits bought | 23,840 | 24,045 | 24,822 | 31,720 | 31,740 | 31,510 |
| statements created | 298 | 300 | 310 | 396 | 396 | 394 |
| statements sold | 137 | 147 | 147 | 173 | 170 | 168 |
| average sale price over cost | 91% | 91% | 91% | 85% | 86% | 85% |
| statements waiting | 159 | 152 | 162 | 221 | 224 | 225 |
| eth to burn | 35.9 | 39.4 | 38.8 | 44.7 | 43.8 | 43.5 |
| eth recycled by sales | 71.9 | 78.9 | 77.6 | 89.4 | 87.6 | 87.0 |
| fees booked, eth | 220 | 218 | 230 | 231 | 231 | 231 |
| launch pot spent on day | 5.9 | 5.9 | 6.0 | 17.4 | 17.9 | 17.6 |
| percent of supply burned | 9.2% | 9.7% | 9.7% | 10.6% | 10.6% | 10.5% |
| steady credits a day after the pot | 44 | 43 | 51 | 56 | 59 | 56 |
| price paid over market | n/a | 0.99x | 1.00x | 0.87x | 0.86x | 0.87x |
| credits on day 1 | n/a | 1,469 | 1,456 | 2,207 | 1,551 | 2,002 |
| credits at day 7 | n/a | 17,619 | 18,153 | 10,790 | 10,120 | 10,580 |

the third column is the previous settings run again on the current engine (credits 0.9 percent above the stored run). the fourth column changes only the router split to the launch values: the engine books 5.867 points of volume instead of 5.179, fees booked rise from 218 to 230 eth, credits rise 3 percent (24,045 to 24,822) and the sale side stays within 2 percent (sold 147 in both, eth recycled 78.9 to 77.6). the sixth column adds the stepped bid rule, the 100 percent opening limit and `reimburseBps` 8000 to the fourth: credits rise by 28 percent (24,822 to 31,740), statements created by 28 percent (310 to 396) and statements sold by 16 percent (147 to 170). the average sale price falls from 91 to 86 percent of cost and the price paid over market from 1.00 to 0.86, because the stepped bid pays about 14 percent under market on average where the built bid paid at market. the launch pot lasts until day 17.9 where the built rule spent it by day 6. by day 7 the engine holds 10,120 credits (32 percent of the day 90 figure) against 18,153 for the built rule on the same router split, and by day 30 28,110 against 21,753. the window rule leaves day 90 credits within 0.1 percent (31,720 to 31,740) and lowers day 1 from 2,207 to 1,551 credits and day 7 from 10,790 to 10,120.

this run against the previous launch run: the clamp is the rate at which the hourly cap affords one average credit (20 before), the hourly cap is the whole pot (`spendCapBps` 10000 against 2000) and `rateCap` is 2.0554e14 against 1.232e14. credits at day 90 move from 31,740 to 31,510 (0.7 percent lower), sold from 170 to 168, eth recycled from 87.6 to 87.0 and eth to burn from 43.8 to 43.5. day 1 holds 2,002 credits where the previous run held 1,551, day 7 10,580 against 10,120 and day 14 20,600 against 20,140. the launch pot lasts until day 17.6 (17.9 before). the peak bid is 0.95 times market (1.19 before) and the price paid over market 0.87x (0.86x). after the launch pot is spent the bid sits lower than before (0.13 to 0.31 times market against 0.50 to 0.56) and steady credits a day are 56 against 59.

fee path. a trader pays 6.9 points of volume. the pool pays 96.38 percent of the baseline skim (6.65022 points) plus all of the anti sniper extra to the fee router, and 0.25 points to the protocol leg. the Core pulls the router at the start of `sellForEth`, `buyListing`, `compose` and `composeExit`, so fees reach the pot as they arrive and the model books them at the moment they arrive. from 30 minutes after launch (the end of the anti sniper window) the single payee takes 112,778 parts per million of the gross inflow (0.75 points of volume). the engine books 5.900 points of volume in steady state and the whole router inflow inside the window. the launch lp fee is 0, so lp income is 0. 89 percent of the 90 day fees (205 of 231 eth) arrive in the first 24 hours and 72 percent in the first hour.

## sensitivity rows (comparable volume, 5 seeds, day 90)

launch is `startBps` 11000, `stepEvery` 3 hours, `stepBps` 100, `floorBps` 7500, `saleFloorBps` 7500, auction mode, `feeToBuybackBps` 0. eth to burn is eth spent buying and burning the coin. differences in credits under 2 percent are seed noise.

| setting | credits bought | statements created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | sold at the lowest price |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **launch: 11000 / 3h / 7500, auction, fee share 0** | 31,510 | 394 | 168 | 85% | 225 | 43.5 | 87.0 | 51% |
| `startBps` 9000 | 31,450 | 393 | 179 | 78% | 213 | 43.3 | 86.6 | 61% |
| `startBps` 13000 | 32,590 | 407 | 179 | 92% | 227 | 48.9 | 97.8 | 44% |
| `stepEvery` 1 hour | 31,220 | 390 | 168 | 81% | 220 | 41.8 | 83.5 | 65% |
| `stepEvery` 6 hours | 31,790 | 397 | 167 | 89% | 228 | 44.6 | 89.2 | 36% |
| `stepBps` 50 | 31,550 | 394 | 162 | 89% | 230 | 43.3 | 86.6 | 35% |
| `stepBps` 200 | 31,700 | 396 | 176 | 83% | 218 | 44.3 | 88.7 | 59% |
| `floorBps` 6000 with `saleFloorBps` 7500 | 31,510 | 394 | 168 | 85% | 225 | 43.5 | 87.0 | 51% |
| `floorBps` 5000 with `saleFloorBps` 7500 | 31,510 | 394 | 168 | 85% | 225 | 43.5 | 87.0 | 51% |
| `floorBps` and `saleFloorBps` both 6000 | 32,350 | 404 | 210 | 73% | 193 | 47.6 | 95.2 | 50% |
| `floorBps` and `saleFloorBps` both 5000 | 31,930 | 399 | 225 | 62% | 173 | 44.6 | 89.2 | 49% |
| buy only mode | 33,300 | 416 | 207 | 86% | 209 | 53.6 | 107.3 | 50% |
| `feeToBuybackBps` 1000 | 29,710 | 371 | 173 | 86% | 196 | 68.2 | 89.8 | 49% |
| `feeToBuybackBps` 2500 | 26,240 | 328 | 170 | 87% | 157 | 102.4 | 87.0 | 45% |
| `feeToBuybackBps` 5000 | 20,240 | 252 | 162 | 89% | 89 | 160.8 | 82.9 | 37% |
| pessimistic: every buyer waits for the floor, auction mode | 31,540 | 394 | 179 | 75% | 213 | 41.0 | 82.0 | 100% |
| pessimistic: every buyer waits for the floor, buy only mode | 32,300 | 403 | 199 | 75% | 205 | 45.5 | 91.0 | 100% |

the same rows at 17 eth a day of coin volume, 3 seeds (all rows are 3 seed runs):

| sustained 17 eth a day, day 90 | credits bought | statements created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | sold at the lowest price |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| launch | 43,810 | 547 | 228 | 80% | 317 | 49.4 | 98.8 | 62% |
| `startBps` 9000 | 43,740 | 546 | 235 | 77% | 309 | 49.3 | 98.5 | 73% |
| `startBps` 13000 | 43,510 | 543 | 211 | 81% | 331 | 47.1 | 94.1 | 64% |
| `stepEvery` 1 hour | 43,300 | 541 | 220 | 77% | 319 | 46.4 | 92.8 | 83% |
| `stepEvery` 6 hours | 44,020 | 550 | 221 | 84% | 328 | 50.4 | 100.8 | 40% |
| both floors 6000 | 43,220 | 540 | 248 | 66% | 290 | 45.4 | 90.8 | 63% |
| both floors 5000 | 42,130 | 526 | 234 | 57% | 290 | 38.1 | 76.2 | 65% |
| buy only mode | 43,780 | 547 | 226 | 80% | 321 | 49.6 | 99.1 | 62% |
| `feeToBuybackBps` 1000 | 39,990 | 499 | 211 | 79% | 286 | 76.0 | 92.1 | 65% |
| `feeToBuybackBps` 2500 | 35,800 | 447 | 224 | 82% | 220 | 124.4 | 97.8 | 53% |
| `feeToBuybackBps` 5000 | 26,920 | 336 | 197 | 87% | 138 | 195.2 | 84.8 | 35% |
| pessimistic, auction | 42,990 | 537 | 207 | 75% | 328 | 42.2 | 84.5 | 100% |

reading the rows:

1. **`startBps`, `stepEvery` and `stepBps` set the average price.** `startBps` 9000 against 13000 moves the average sale price from 78 to 92 percent of cost, eth recycled from 86.6 to 97.8 and eth to burn from 43.3 to 48.9, for 4 percent more credits (31,450 to 32,590). a slower fall (6 hours a step, or 50 a step) raises the price to 89 percent and sells 167 and 162 statements where launch sells 168, so eth recycled stays within 1 percent of launch (89.2 and 86.6 against 87.0). a faster fall (1 hour a step) gives 81 percent and 168 sold. the share of sales at the lowest price is 61 percent at 9000, 51 at 11000 and 44 at 13000. at 17 eth a day there are more statements than buyers, 62 percent of sales are at the lowest price and the dials change eth recycled by 6 percent or less (92.8 to 100.8 against 98.8 at launch).
2. **the hard floor binds.** with `saleFloorBps` at 7500 a `floorBps` of 6000 or 5000 leaves the rows equal to launch. selling lower needs both set. both at 6000: 210 sold (25 percent more), price 73 percent of cost, eth recycled 95.2 (9 percent more), credits 32,350. both at 5000: 225 sold at 62 percent and eth recycled 89.2 (3 percent more than launch), so 6000 recycles the most. at 17 eth a day lowering both costs eth: recycled 98.8 to 90.8 to 76.2, burn 49.4 to 45.4 to 38.1. a lower floor therefore gains at comparable volume, where buyers are scarce and old statements sit at the floor, and costs eth when statements are plentiful.
3. **buy only against auction.** buy only sells 207 against 168 (23 percent more), recycles 107.3 against 87.0 (23 percent more), burns 53.6 against 43.5 and lifts credits to 33,300 (6 percent). two causes: buyers go to sales instead of second bids and the proceeds reach the pots at once instead of at the next hourly `collectSales`. at 17 eth a day the gain disappears: 226 against 228 sold and 99.1 against 98.8 recycled. under random pick buy only sells 222 against 232 and recycles 119.3 against 122.9.
4. **`feeToBuybackBps` is a launch decision and a strong burn dial.** 1000 raises eth to burn from 43.5 to 68.2 and lowers credits by 6 percent (29,710). 2500 burns 102.4 eth (2.4 times launch) at 16.7 percent fewer credits (26,240). 5000 burns 160.8 eth (3.7 times) at 35.8 percent fewer credits (20,240) and 252 statements created. each extra eth burned costs 73 to 96 credits through the fee share (73 at 1000, 89 at 2500, 96 at 5000) and 127 through the sale share (section 5). 89 percent of the fees arrive on day one, so the share matters only while the launch pot is large: switching to 2500 on day 14 gives 31,490 credits and 45.3 eth burned against launch 31,510 and 43.5.
5. **the pessimistic run, every buyer waits for the floor.** every sale is at 75 percent of cost. in auction mode that sells 179 (more than launch: each purchase opens its own auction), recycles 82.0 eth (6 percent less than launch) and burns 41.0 (6 percent less). in buy only mode 199 sell, 91.0 recycled, 45.5 burned. at 17 eth a day the cost is 14 percent of the sale side (84.5 recycled against 98.8) and credits move 2 percent (42,990 against 43,810). arrivals follow the fixed schedule of the sale model assumptions, so the rows hold arrivals constant while the price changes.

## what the sale model assumes

the buyers and the sale rules in sim/engine.js, so the numbers can be checked:

1. **two prices.** a buyer's willingness to pay is a multiple of the MARKET cost of the 80 credits: the calibrated quantiles (p10 0.48, p25 0.71, median 0.84, p75 1.07, 21 percent at 1.2 or more, max 1.32) times `wtpMult` times 80 times the flat market price of a credit on the day the buyer arrives (including the lift from the engine's own buying). the asking price is a share of what the ENGINE PAID: the statement cost, the sum of the costs of its 80 credits plus the compose reimbursement. the engine pays 0.87 times market on comparable volume and 0.81 on sustained 17 eth a day, so the same buyer clears a different share of cost in each case.
2. **asking price.** steps = floor(age / `stepEvery`), age counted from the listing, a new statement starts at age zero. bps = max(`startBps` minus steps times `stepBps`, `floorBps`) of cost. the price used is the higher of that and `saleFloorBps` of cost (the Core's hard floor). launch: 110 percent, 109 at hour 3, 100 at hour 30, 75 from hour 105. the controller settings and the hard floor are read live, a change applies to every listed statement at once.
3. **arrivals and the pick rule.** buyers arrive as a Poisson process, 8 a day at launch, halving every 21 days down to 2 a day, whatever the price. each buyer makes one purchase attempt. it takes the statement with the lowest asking price at or under its willingness to pay (`stmtPick` random takes any that fits, section 4 shows both). a buyer that fits nothing leaves and is counted as a miss (29 percent of arrivals at launch, 80 of 278).
4. **a buyer buys what it can afford now.** a buyer who can afford a statement now buys it now. the pessimistic run is the opposite: with `buyerWaits` set to `floor` every buyer buys only a statement whose asking price has reached its lowest level (the higher of `floorBps` and `saleFloorBps`) and nobody bids on a live auction.
5. **auction mode (launch).** a buyer at or above the asking price opens the english auction at that price: the first bid is the asking price at that moment (the first bidder reprices the listing to it first). `auctionDuration` 24 hours runs from the first bid, a later bidder must have a higher willingness to pay than the top bidder and bid 5 percent more, a bid in the last 15 minutes extends the end to 15 minutes from the bid. the proceeds are credited to the Core in the house and reach the pots when `collectSales` runs (an hourly keeper), split by `saleToBuybackBps`. a statement with a bid stays out of the exitModule.
6. **buy only mode.** the buyer pays the asking price through `sellTo` and gets the statement at once. the proceeds are booked into the pots in the same call, split by `saleToBuybackBps`. a house listing in this mode sits at the start price, and buyers use the controller.
7. **fee share.** all swap fee eth reaches the Core through the fee router, which the Core pulls at the start of every sell and compose door, and the model books it as it arrives. `feeToBuybackBps` of it goes to the buyback pot and the rest to the pot. fees from the buyback's own swaps and from the exitToken auction takers count the same. eth booked later by `skim()` goes to the pot.
8. **keepers.** `collectSales` runs every hour, `endAuction` is called the moment an auction ends, the buyback keeper runs every 25 blocks. a statement is sold once, and a house delivery failure is outside the model.

arrivals follow a fixed schedule: the price level and the curve leave the number of buyers unchanged. that and the buyers' rule are the largest unknowns of the sale side (section 10).

## the goal and the headline metrics

the engine exists to keep credits flowing into statements. a statement selling below the cost of its 80 credits is better than no sale. unsold statements wait for the exitModule in phase 2. the engine keeps buying whatever the unsold stock is. early on it should acquire as many credits as possible, score can matter later.

headline metrics, in this order: credits acquired, statements created, statements sold with their average price over cost, statements waiting for phase 2, eth sent to buy and burn the coin (from sales and from fees), eth recycled by sales, days until the launch pot is spent, steady state credits per day after that. the launch pot is spent when the pot falls under 5 percent of its peak. steady state is the last 30 days of a 90 day run.

verdict in one paragraph: **the engine keeps buying under every volume preset, and unsold statements leave the buying rate unchanged.** as launched on the comparable coin it acquires 31,510 credits in 90 days, 28,160 of them by day 30, creates 394 statements and sells 168 of them at 85 percent of cost on average. 43.5 eth buys and burns 10.5 percent of the coin. 225 statements wait for phase 2. about 205 eth of fees arrive in the first 24 hours and the launch pot is spent on day 17.6, because the stepped bid buys about 1,440 credits a day while the pot lasts (2,002 on day 1). after that the flow is about 56 credits a day, paid for by the 0.03 eth a day the coin still pays and by sale proceeds. a second bidder shows up in 13 percent of the auctions, so the asking price at the moment of the first buyer is the price: the curve walks until a buyer's willingness to pay is reached. the sale design is a dial on eth recycled and burn, and week one is the same under every sale setting (10,580 credits on day 7 in every row of section 5).

## what the model changed against the old branch

| piece | now |
|---|---|
| bid | `bidRule` stepped. a fill lowers the bid by `dropPerCreditBps` 50 (0.5 percent), staying at or above `dropFloorBps` 8000 of the rate at the first fill of the minute. the bid climbs `climbPerMinBps` 50 a minute toward the lowest of `ceilBps` 12500 of the last fill rate (grown by `idleLoosenBps` 200 per idle 10 minutes, linear), `rateCap` and the clamp. the read bid is lowered to the clamp, the rate at which the hourly cap (`spendCapBps` 10000 of the pot an hour) affords one average credit. `flatBps` 10000 prices every credit as `avgScore`, 0 prices it by its own score, in between blends. the controller bonus is 0 (ControllerV1 returns 0) |
| gate | removed, with every trace. a test checks the source |
| statement price | the controller's asking price: `startBps` 11000 of cost, minus `stepBps` 100 every `stepEvery` 3 hours, to `floorBps` 7500. the Core's `saleFloorBps` 7500 is the hard floor: the price used is the higher of the two |
| statement sale | auction mode (launch): a buyer at or above the asking price opens the english auction at that price, `auctionDuration` timer from the first bid, 5 percent raise, 15 minute extension. buy only mode: the buyer pays the asking price and gets the statement at once. unbid statements stay listed |
| proceeds | auction: credited to the Core in the house, reach the pots when `collectSales` runs (an hourly keeper). buy only: booked at once. both split by `saleToBuybackBps` |
| fees | the fee router pays the Core: 6.65022 points of volume at the baseline plus the anti sniper extra, less, from 30 minutes after launch, 112,778 ppm to the payee. `feeToBuybackBps` (launch 0) of the booked eth goes to the buyback pot, the rest to the pot |
| compose | `reimburseBps` 8000 |
| phase 2 exit | an unbid listing may exit through the exitModule after `exitAfter` (105 hours, where the asking price reaches its floor), a statement with a bid stays out of the exitModule. the owner sets the exitModule at once |
| settings | one `Settings` object with the Core's field names plus the controller's five, `schedule` of `{day, patch}` changes them mid run with the Core's checkpoint and bounds |
| opening limit | `rateStart` 2.0554e13, 100 percent of the market price of a credit over `avgScore` |
| rate cap | `rateCap` 2.0554e14 (10 times `rateStart`): the climb stops at the lowest of the ceiling, the funded clamp and `rateCap`, `setRate` refuses above it. the peak bid at launch values is 0.95 times market, a tenth of the cap |

port checks: node engine.test.mjs runs 564 numeric checks against hand computed values: the launch values against mainnet.json (including the stepped bid fields, `rateStart` and the router split), the stepped rule (drop per credit, minute floor, ceiling, idle loosening, rate cap), the funded rule and the one credit clamp, the exit lane reimbursement cap at `rateStart`, the hourly cap, the blended ceiling, tip rule, compose reimbursement with the listing gas, the asking price at exact hours (110 at 0, 109 at 3, 100 at 30, 75 at 105 and after), the hard floor winning over a lower curve floor, the auction opening at the accepted price, every english auction rule (5 percent raise, extension, end, winner), buy only being instant, the proceeds split in both modes, the fee share at 0, 2500, 5000 and 10000, the router split (6.65022 points to the router, 5.900 to the engine), conservation of eth, `setSettings` bounds and checkpoint, exit eligibility, the exitToken auction and bid, buyback, the pool, eth accounting identities over whole runs (pot, buyback pot, house) in both modes, and the default run (stepped, 60 second steps). the checks of the built rule run on `bidRule: 'built'` with its own parameters.

## model in short

| piece | what it does | calibration |
|---|---|---|
| coin market | exogenous daily volume, buy share, skim 6.9 percent with 5.90 points to the pot after the router's payee (6.65 points to the router), anti sniper 90 to 6.9 percent over 30 minutes, single sided position tick -175000 to 887200 | model price after day one 4.48e-7, observed 4.44e-7 |
| credit sellers | uniform scores 80 to 800, flat ask per credit with lognormal spread 0.27, top tier premium above 740, 150 offers an hour, 5 percent leave an hour, more offers when the bid is above market, a float of 96,800 credits | median 0.0089 eth, p10 0.0069, p90 0.0138 |
| doors | the sell door pays the bid for any credit whose ceiling clears its ask, cheapest ask per bid point first. CreditStrategy listings clear through the listing door with the tip | 13,132 listings at median 0.036 eth |
| statement buyers | arrivals 8 a day decaying to 2, willingness to pay as a multiple of 80 times the MARKET flat price, rating insensitive, one purchase each, buying what they can afford now. the price they meet is a share of what the engine PAID (assumptions above) | median 0.84, 21 percent at 1.2 or more, max 1.32, from fixed price sales. the response to a curve and to auctions is assumed |
| engine to market feedback | engine spend lifts the flat price, elasticity 0.12, half life 48 hours, cap 3x | assumption |
| phase 2 | exitModule pays rating times unitPerPoint, exit lane, exitToken bid by score, dutch auction with takers at a set discount, a keeper exits every eligible listing | assumption |

## 1. the launch configuration as built

| preset | day | credits acquired | statements created | sold | avg sale price over cost | eth spent buying $CC | percent of supply burned | waiting for phase 2 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| comparable decay | 30 | 28,160 | 351 | 106 | 82% | 28.9 | 7.6% | 244 |
|  | 60 | 29,830 | 373 | 137 | 84% | 36.2 | 9.1% | 235 |
|  | 90 | 31,510 | 394 | 168 | 85% | 43.5 | 10.5% | 225 |
| sustained 17 eth a day | 30 | 29,710 | 371 | 112 | 83% | 29.9 | 4.9% | 256 |
|  | 60 | 36,840 | 460 | 172 | 81% | 40.3 | 6.2% | 287 |
|  | 90 | 43,660 | 545 | 223 | 80% | 48.9 | 7.1% | 320 |
| sustained 50 eth a day | 30 | 35,680 | 446 | 114 | 79% | 30.8 | 5.0% | 330 |
|  | 60 | 50,610 | 632 | 170 | 78% | 41.9 | 6.4% | 460 |
|  | 90 | 65,340 | 816 | 220 | 78% | 51.6 | 7.4% | 596 |
| dead after week one | 30 | 27,630 | 345 | 104 | 82% | 28.2 | 7.0% | 240 |
|  | 60 | 29,360 | 366 | 138 | 84% | 36.5 | 8.6% | 228 |
|  | 90 | 30,840 | 385 | 166 | 85% | 43.5 | 9.7% | 218 |

| preset | fees in | launch pot spent on day | steady credits a day | steady statements a day | steady sold a day | price paid over market | average score bought | eth recycled by sales, 90 days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| comparable decay | 231 | 17.6 | 56 | 0.70 | 1.03 | 0.87x | 426 | 87.0 |
| sustained 17 eth a day | 296 | 17.2 | 228 | 2.84 | 1.69 | 0.81x | 425 | 97.7 |
| sustained 50 eth a day | 469 | 20.3 | 491 | 6.13 | 1.65 | 0.82x | 425 | 103.2 |
| dead after week one | 226 | 17.4 | 50 | 0.62 | 0.96 | 0.87x | 426 | 87.0 |

reading it:

1. the pot is spent in 17 to 20 days under every preset, because 89 percent of the fees arrive on day one and the stepped bid buys at a set pace. at launch values the bid settles where the drop per credit equals the climb per minute, which is `climbPerMinBps / dropPerCreditBps` = 1 credit a minute, about 1,500 credits a day (section 6). by day 7 the engine holds 10,580 credits (34 percent of what it will have at day 90 on comparable volume), by day 14 20,600 (65 percent) and by day 21 27,190 (86 percent). day 1 holds 2,002 credits (1,551 with the clamp at 20 credits and `spendCapBps` 2000).
2. unsold statements leave the buying rate unchanged. 225 statements wait at day 90 and the engine bought 1,690 credits in days 60 to 90. with no statement buyer at all the engine still buys every day, but sale proceeds are the pot's income after the launch pot, so credits are 13 percent lower at day 30 (24,560 against 28,160) and 21 percent lower at day 90 (25,010 against 31,510).
3. after the pot is gone the flow is set by income: coin fees plus the sale proceeds that go to the pot (half of every sale at launch values). at the comparable floor of 0.5 eth a day of coin volume that is 56 credits a day, at 17 eth a day 228, at 50 eth a day 491 (section 7).
4. statements sold are limited by buyers. 278 buyers arrive in 90 days, 80 find no price they accept, and a second bid lands on 13 percent of the auctions. sustained volume makes more statements (545 at 17 eth a day) and sells about the same (223), so the waiting stock grows by about one a day after day 30, and the average sale price falls to 80 percent because the stock is old and 63 percent of sales are at the lowest price.
5. 43.5 eth of buyback burns 10.5 percent of supply because the pool price sits near 3e-7. the percent depends on the coin price more than on the engine.
6. the read bid stays at 0.89 to 0.93 of the market price of a credit through day 14, while the pot is large, and falls to 0.13 to 0.31 of it once the pot is empty and the clamp (the rate at which the hourly cap affords one average credit) sets the bid (0.34 to 0.46 at 17 eth a day). all credits cost 0.87 times the flat price on comparable volume (0.81 at 17 eth a day) and the peak bid is 0.95 times market.

## 2. the opening limit

`rateStart` as a share of the market price of a credit (0.0089 eth, so 100 percent is 2.06e13). the stepped bid starts at `rateStart` and climbs 0.5 percent a minute.

| share | rateStart | hours to first buy | credits day 1 | day 3 | day 7 | day 14 | day 30 | day 90 | first 80 cost over market | all credits over market | peak bid over market |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 25% | 5.14e12 | 2.13 | 1,149 | 3,989 | 9,708 | 19,730 | 28,250 | 31,990 | 0.54 | 0.86 | 0.96 |
| 40% | 8.22e12 | 0.03 | 1,277 | 4,115 | 9,839 | 19,870 | 28,150 | 31,820 | 0.54 | 0.86 | 0.96 |
| 50% | 1.03e13 | 0.03 | 1,321 | 4,161 | 9,884 | 19,910 | 28,460 | 32,110 | 0.55 | 0.86 | 0.95 |
| 60% | 1.23e13 | 0.03 | 1,357 | 4,201 | 9,918 | 19,950 | 28,340 | 32,280 | 0.57 | 0.86 | 0.95 |
| 75% | 1.54e13 | 0.03 | 1,439 | 4,280 | 10,000 | 20,030 | 28,320 | 32,160 | 0.64 | 0.86 | 0.96 |
| 90% | 1.85e13 | 0.03 | 1,721 | 4,568 | 10,300 | 20,320 | 28,110 | 31,900 | 0.77 | 0.86 | 0.96 |
| **100%** | 2.06e13 | 0.03 | 2,004 | 4,852 | 10,580 | 20,600 | 28,220 | 31,740 | 0.86 | 0.87 | 0.95 |
| 125% | 2.57e13 | 0.03 | 2,020 | 4,873 | 10,600 | 20,620 | 28,180 | 31,770 | 1.07 | 0.87 | 0.96 |

1. the opening limit changes day 1 and day 3 and leaves later days close together. credits at day 14 run from 19,730 (25 percent) to 20,620 (125 percent), at day 30 from 28,110 to 28,460 and at day 90 from 31,740 to 32,280.
2. at 25 percent the first buy comes after 2.1 hours and day 1 holds 1,149 credits against 2,004 at 100 percent. from 40 percent up the first buy is within 2 minutes.
3. the first fills are the cheapest sellers. the first 80 credits cost 0.54 times market at 25 to 40 percent, 0.86 at 100 percent and 1.07 at 125 percent. the engine pays its bid to every seller that clears, so a higher limit pays more for the same credits.
4. the price paid over all credits is 0.86 to 0.87 times market at every limit, because the climb and the drop find the market within minutes.
5. rising market (price recovers to 2.2 times): a higher limit buys slightly more in week one, day 7 holds 9,637 credits at 25 percent and 10,530 at 125 percent, and day 90 25,020 to 25,590. falling market: day 7 holds 9,747 to 10,640 and day 30 36,410 to 38,020 at every limit. the rule scales with price: at flat prices of 0.0045, 0.018 and 0.03 the 100 percent limit buys within the first minutes (day 30 holds 43,540, 15,390 and 11,770 credits).

100 percent is the launch value (`rateStart` 20,554,000,000,000). it buys at once and pays 0.86 times market for the first 80 credits, with later totals level across the range. launch day rule: rateStart = share times market price of a credit in wei times 1e4 over `avgScore`, market price the median of the last 24 hours of seaport fills.

## 3. flat, blended or per point

`flatBps` 10000 prices every credit as an average one (433 points), 0 prices it by its own score. comparable volume, 90 days.

| flatBps | credits acquired | price paid over market | price per point over market | average score bought | statements created | sold | credits day 7 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10000 flat | 31,510 | 0.87x | 0.90x | 426 | 394 | 168 | 10,580 |
| 7500 | 30,350 | 0.91x | 0.77x | 517 | 379 | 167 | 10,610 |
| 5000 | 27,270 | 0.99x | 0.75x | 578 | 340 | 141 | 10,570 |
| 2500 | 24,750 | 1.07x | 0.77x | 609 | 309 | 123 | 10,510 |
| 0 per point | 21,790 | 1.19x | 0.84x | 622 | 272 | 105 | 10,450 |

sustained 17 eth a day: 43,660 / 41,820 / 38,610 / 26,360 / 21,960 credits at 10000 / 7500 / 5000 / 2500 / 0, average score 425 / 527 / 568 / 592 / 620, price paid 0.81x / 0.85x / 0.92x / 1.27x / 1.48x.

1. flat buys the most credits and the most statements. going from flat to per point loses 31 percent of the credits (31,510 to 21,790) and 31 percent of the statements (394 to 272), and pays 32 points more per credit (0.87 to 1.19 times market).
2. the market prices credits flat in score (notes.md fact 1), so a per point bid pays the same ask for a low score credit and clears the high score ones first. that is why the average score rises from 426 to 622.
3. score has a price: from flat to 7500 the average score rises 91 points (21 percent) for 4 points of price paid and 4 percent of credits. below 7500 each step loses more credits than it gains in score (5000 loses another 10 percent of credits for 61 points).
4. the switch on day 30 costs credits in proportion to the pot. flat to 5000 on day 30: credits 31,580 (31,510 unchanged), average score 448, steady flow 52 a day (56). flat to 0: 30,910, score 447, steady flow 36. in sustained 17 eth a day a switch to 5000 costs 4 percent of credits (42,000 against 43,660) and a switch to 0 costs 26 percent (32,300), with a steady flow of 36 a day against 228. if score matters later, 7500 is the cheap step.

## 4. the statement sale: asking price, floors, mode and the buyers

the sale design has five dials (`startBps`, `stepBps` with `stepEvery`, `floorBps`, `saleFloorBps`, `buyOnly`) and two inputs outside the owner's settings (the pick rule and the buyers' willingness to pay). the rows against launch are in the table at the top of this file. what they say, with the extra sweeps:

1. **credits acquired and statements created depend little on the sale design.** 31,220 to 33,300 credits across every row of the top table except the fee share, which takes eth out of the pot in week one. the design moves how many statements sell (162 to 225) and how much eth they bring back (83.5 to 107.3 eth recycled across the dials).
2. **the price is where the first fitting buyer arrives.** 49 percent of the sales at launch happen on the way down the curve and 51 percent at the lowest price. the mean age at sale is 244 hours because the oldest statements wait at the floor for weeks. each arrival is matched to the lowest asking price that fits.
3. **plenty of stock means every buyer pays the floor.** the pick rule sends a buyer to the lowest asking price, and when there are more statements than buyers one is always at the floor. at 17 eth a day (547 statements, 283 buyers) 62 percent of sales are at the lowest price and the average is 77 to 84 percent of cost across the dials (77 at 9000, 81 at 13000). at comparable volume stock at the floor is thinner, so `startBps` and `stepEvery` move the price (78 to 92 percent). the sale design therefore matters most when the engine sells most of what it makes, and little when it makes more than the buyers take.

**the auction duration.** comparable volume, auction mode, cheapest pick:

| `auctionDuration` | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 hour | 32,640 | 407 | 193 | 85% | 214 | 50.0 | 100.0 | 1% |
| 6 hours | 32,430 | 405 | 189 | 85% | 216 | 48.8 | 97.7 | 7% |
| 24 hours | 31,510 | 394 | 168 | 85% | 225 | 43.5 | 87.0 | 13% |
| 72 hours | 31,230 | 390 | 158 | 86% | 230 | 40.9 | 81.9 | 22% |
| 168 hours | 30,990 | 387 | 147 | 87% | 235 | 37.8 | 75.5 | 29% |

4. **a long auction costs eth in this model, through one mechanism.** a buyer takes the lowest asking price that fits, which is often a live auction at the 5 percent raise, and the longer an auction runs the more buyers pile onto it: second bidders go from 1 percent at one hour to 22 percent at 72 hours and 29 percent at 168 hours, sold falls from 193 to 158 and 147, and eth recycled from 100.0 to 81.9 and 75.5. the real house may show a different pile on (the buyers' rule is the weakest input, see the pick rule below). `auctionDuration` is adjustable at once, so the owner can read the second bidder share in the first weeks and shorten it: 6 hours recycles 12 percent more than 24 in this model (97.7 against 87.0).

**the pick rule and the number of buyers.** the pick rule decides the second bidder share and so a large part of the sale side. cheapest means a buyer takes the lowest asking price that fits, random means any statement that fits.

| sale mode, pick rule, buyers a day | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| auction, cheapest, 8 | 31,510 | 394 | 168 | 85% | 225 | 43.5 | 87.0 | 13% |
| auction, cheapest, 20 | 38,490 | 481 | 348 | 85% | 130 | 97.4 | 194.7 | 13% |
| auction, random, 8 | 34,570 | 432 | 232 | 80% | 197 | 61.4 | 122.9 | 2% |
| auction, random, 20 | 42,460 | 530 | 442 | 81% | 86 | 122.4 | 244.8 | 6% |
| buy only, cheapest, 8 | 33,300 | 416 | 207 | 86% | 209 | 53.6 | 107.3 | 0% |
| buy only, cheapest, 20 | 40,740 | 509 | 401 | 85% | 108 | 111.9 | 223.8 | 0% |
| buy only, random, 8 | 34,180 | 427 | 222 | 80% | 205 | 59.6 | 119.3 | 0% |
| buy only, random, 20 | 43,420 | 542 | 469 | 83% | 73 | 132.9 | 265.8 | 0% |

5. **random pick sells 38 percent more statements than cheapest at 8 buyers a day** (232 against 168) because buyers spread out and few bid on a live auction (2 percent against 13), and recycles 41 percent more eth (122.9 against 87.0), at a lower average price (80 percent against 85). buy only sells 4 percent fewer statements than auction under random pick (222 against 232) and 23 percent more under cheapest (207 against 168). 20 buyers a day lift credits to 38,490 (cheapest) or 42,460 (random).
6. **the design conclusions hold under random pick, with two differences.** `startBps` and `stepEvery` matter less for eth recycled (119.1 to 125.4 across the rows against 86.6 to 97.8), because buyers spread over the whole stock and no one piles onto the cheapest. lowering both floors costs eth: recycled 122.9, 109.9, 106.0 at 7500, 6000, 5000, average price 80, 68, 61 percent, where under cheapest pick 6000 gains. the table, all rows against random pick launch:

| random pick, all rows | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| launch | 34,570 | 432 | 232 | 80% | 197 | 61.4 | 122.9 | 2% |
| `startBps` 9000 | 34,410 | 430 | 234 | 76% | 194 | 59.8 | 119.6 | 2% |
| `startBps` 13000 | 34,820 | 435 | 227 | 83% | 205 | 62.7 | 125.4 | 2% |
| `stepEvery` 1 hour | 34,590 | 432 | 240 | 77% | 191 | 61.6 | 123.1 | 3% |
| `stepEvery` 6 hours | 34,370 | 429 | 221 | 82% | 206 | 59.6 | 119.1 | 2% |
| both floors 6000 | 33,420 | 417 | 233 | 68% | 181 | 54.9 | 109.9 | 2% |
| both floors 5000 | 33,130 | 414 | 250 | 61% | 161 | 53.0 | 106.0 | 2% |
| buy only | 34,180 | 427 | 222 | 80% | 205 | 59.6 | 119.3 | 0% |
| `feeToBuybackBps` 1000 | 32,500 | 406 | 232 | 79% | 172 | 85.1 | 123.4 | 2% |
| `feeToBuybackBps` 2500 | 28,900 | 361 | 230 | 79% | 129 | 118.6 | 119.0 | 2% |
| `feeToBuybackBps` 5000 | 23,070 | 288 | 237 | 80% | 50 | 179.0 | 118.2 | 3% |
| every buyer waits for the floor | 33,850 | 423 | 217 | 75% | 204 | 53.8 | 107.6 | 0% |

**willingness to pay and the number of buyers** are the real inputs of the sale side, beside the curve. cheapest pick, comparable volume:

| buyer willingness to pay, times the observed | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.70x | 28,370 | 354 | 90 | 84% | 264 | 21.5 | 42.9 | 17% |
| 0.84x | 30,430 | 380 | 140 | 84% | 240 | 35.0 | 70.0 | 17% |
| 1.00x | 31,500 | 393 | 167 | 85% | 225 | 43.1 | 86.2 | 14% |
| 1.30x | 32,710 | 409 | 196 | 86% | 212 | 51.8 | 103.5 | 14% |
| 1.60x | 33,480 | 418 | 214 | 86% | 200 | 56.9 | 113.8 | 15% |

| statement buyers a day at launch | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 3 | 29,640 | 370 | 112 | 87% | 257 | 26.9 | 53.8 | 21% |
| 8 | 31,500 | 393 | 167 | 85% | 225 | 43.1 | 86.2 | 14% |
| 20 | 38,470 | 480 | 345 | 85% | 134 | 96.3 | 192.6 | 14% |
| 40 | 49,230 | 615 | 598 | 90% | 16 | 183.7 | 367.5 | 12% |

7. willingness to pay: 0.7x the observed sells 90 statements, 1.0x sells 167, 1.6x sells 214, and eth recycled goes 42.9, 86.2, 113.8. buyers a day: 3 sell 112, 20 sell 345, 40 sell 598 (recycled 53.8, 192.6, 367.5), and credits go from 29,640 to 49,230. 2.5 times more buyers (20 a day) lifts eth recycled by 123 percent. the owner chooses how the stock is offered to the buyers that come.
8. the average price moves 5 points across 3 to 40 buyers a day (87, 85, 85, 90 percent of cost).

**changing a setting later.** one change on day N, comparable volume, 5 seeds, against launch:

| change on day N | credits | created | sold | avg sale price over cost | waiting | eth to burn | eth recycled by sales | second bidder share |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| day 7: both floors to 6000 | 32,030 | 400 | 202 | 73% | 197 | 45.8 | 91.5 | 6% |
| day 14: both floors to 6000 | 32,440 | 405 | 205 | 76% | 199 | 48.4 | 96.8 | 7% |
| day 30: both floors to 6000 | 32,310 | 404 | 194 | 80% | 209 | 47.8 | 95.5 | 9% |
| day 14: `startBps` to 9000 | 31,330 | 391 | 171 | 80% | 219 | 42.4 | 84.8 | 15% |
| day 14: buy only | 33,590 | 419 | 213 | 86% | 206 | 55.3 | 110.6 | 0% |
| day 14: `feeToBuybackBps` to 2500 | 31,490 | 393 | 170 | 85% | 221 | 45.3 | 88.5 | 12% |
| launch, no change | 31,510 | 394 | 168 | 85% | 225 | 43.5 | 87.0 | 13% |
| both floors 6000 from launch | 32,350 | 404 | 210 | 73% | 193 | 47.6 | 95.2 | 7% |

9. a cut of both floors adds eth recycled whenever it is made in the first month: day 7 cut 91.5, day 14 cut 96.8, day 30 cut 95.5, cut at launch 95.2, against 87.0 at launch values. a day 14 cut sells 205 at 76 percent, a cut at launch 210 at 73 percent. lowering only `floorBps` changes nothing until `saleFloorBps` is lowered too (the Core's hard floor wins).
10. `startBps` down to 9000 on day 14 loses eth (84.8 against 87.0 recycled). buy only on day 14 recycles 110.6, level with buy only from launch (107.3). the fee share on day 14 leaves the result unchanged (89 percent of the fees are already in). the three levers differ in timing: the floors can be cut once the first weeks show the stock waiting, the fee share has to be chosen at launch, the mode can be switched at any time.

recommendation for the sale design: **keep the launch values** (11000, 3 hours, 100, floor 7500, auction, fee share 0). in this model the curve moves the average price by 14 points across its dials and credits by 4 percent, while the pick rule and the number of buyers move eth recycled by 41 percent and more. the owner's useful moves after week two, in order: lower both floors to 6000 if statements older than the 105 hours of the curve keep piling up and fewer than one sells a day (comparable volume gains 9 percent eth recycled, 17 eth a day loses 8 percent), switch to buy only if second bidders pile onto live auctions (comparable volume gains 23 percent eth recycled, 17 eth a day gains under 1 percent), raise `startBps` or `stepEvery` if the average price over cost is low while few statements wait, shorten `auctionDuration` if second bidders are a large share of sales.

## 5. the proceeds split

`saleToBuybackBps` is the share of sale proceeds that goes to the coin buyback, the rest to the pot. it applies the same in auction mode (at `collectSales`) and in buy only mode (at the sale). the fee share is a separate setting (section 4, row 4).

| saleToBuybackBps | credits day 7 | day 30 | day 90 | statements created | sold | eth spent buying $CC | percent of supply burned | steady credits a day |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 10,580 | 31,340 | 38,200 | 477 | 201 | 0.0 | 0.0% | 109 |
| 2500 | 10,580 | 29,830 | 35,150 | 439 | 186 | 23.6 | 6.9% | 89 |
| 5000 | 10,580 | 28,160 | 31,510 | 394 | 168 | 43.5 | 10.5% | 56 |
| 7500 | 10,580 | 26,560 | 28,930 | 361 | 173 | 68.7 | 13.7% | 41 |
| 10000 | 10,580 | 24,920 | 25,830 | 323 | 180 | 97.7 | 16.2% | 15 |

sustained 17 eth a day: credits at day 90 49,200 / 46,490 / 43,660 / 40,700 / 37,720, eth spent buying coin 0 / 24.5 / 48.9 / 72.5 / 97.3, steady credits a day 280 / 247 / 228 / 210 / 186. sustained 50: 70,900 to 59,960 credits, 0 to 103.2 eth burned.

1. the split leaves the first week unchanged (10,580 credits on day 7 in every row). it acts after the launch pot is gone, when sale proceeds are the pot's main income.
2. the price of burn in credits: from 0 to 100 percent the engine gives up 12,370 credits (32 percent) for 97.7 eth of burn, 127 credits per eth at comparable volume, 118 at 17 eth a day.
3. the burn side is modest: 100 percent buys 16.2 percent of the supply, 0 burns 0 percent. the steady credit flow falls from 109 to 15 a day. with the owner's order of goals (credits first, burn fifth) the split is the first thing to move toward the pot if credits per day matter more than burn.
4. launch at 5000 leaves week one untouched. decide between day 7 and day 18 when the pot is gone and the steady flow is visible.
5. against the fee share: an extra eth of burn through `feeToBuybackBps` costs 73 to 96 credits (section 4, row 4), the sale share about 127, and fees come on day one, so the fee lever has to be set at launch while the sale split can be turned any week.

## 6. the bid rule: drop, climb, ceiling, hourly cap

comparable volume, 90 days, launch values `dropPerCreditBps` 50, `dropFloorBps` 8000, `climbPerMinBps` 50, `ceilBps` 12500, `idleLoosenBps` 200, `spendCapBps` 10000, `rateCap` 2.0554e14, 5 seeds. one setting changes per table.

the mechanism. each credit bought lowers the bid by `dropPerCreditBps` and the bid climbs `climbPerMinBps` a minute, so the bid is stationary where the engine buys `climbPerMinBps / dropPerCreditBps` credits a minute. the launch values give 1 a minute, about 1,440 a day, while the pot affords it. the ceiling holds the bid under `ceilBps` of the last fill rate, the drop floor limits one minute of buying to a fall of 10000 minus `dropFloorBps` from the rate at the first fill of that minute, the clamp lowers the read bid to the rate at which the hourly cap (`spendCapBps` of the pot) affords one average credit, and `rateCap` stops the climb at 10 times `rateStart`.

| climbPerMinBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 25 | 2,740 | 5,607 | 10,630 | 22,100 | 38,310 | 0.77x | 0.82x | 46.6 | 1 |
| **50** | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |
| 100 | 9,082 | 19,220 | 21,030 | 22,570 | 25,560 | 0.98x | 1.15x | 6.3 | 13 |
| 200 | 14,090 | 15,790 | 17,590 | 19,420 | 22,390 | 1.09x | 1.47x | 2.3 | 22 |

| dropPerCreditBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 25 | 8,990 | 19,230 | 20,990 | 22,580 | 25,740 | 0.98x | 1.15x | 6.3 | 16 |
| **50** | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |
| 100 | 2,742 | 5,598 | 10,600 | 22,030 | 38,360 | 0.77x | 0.82x | 47.1 | 1 |
| 200 | 1,674 | 3,094 | 5,584 | 11,270 | 32,600 | 0.69x | 0.80x | after day 90 | 0 |

| dropFloorBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 5000 | 4,300 | 10,020 | 20,050 | 28,320 | 32,030 | 0.87x | 0.95x | 18.2 | 2 |
| **8000** | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |
| 9500 | 5,267 | 10,990 | 21,020 | 28,080 | 31,750 | 0.87x | 0.96x | 17.2 | 2 |

| ceilBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 11000 | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |
| **12500** | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |
| 15000 | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |
| 20000 | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |

| idleLoosenBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |
| 100 | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |
| **200** | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |
| 500 | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |

| spendCapBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | peak bid over market | launch pot spent on day | minutes the hourly cap blocked a sale |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 500 | 4,304 | 10,030 | 20,060 | 26,450 | 27,790 | 1.01x | 9.07x | 18.0 | 1,570 |
| 1000 | 4,361 | 10,080 | 20,110 | 27,000 | 28,220 | 0.99x | 9.37x | 18.0 | 1,303 |
| 2000 | 4,394 | 10,120 | 20,140 | 27,120 | 28,230 | 1.00x | 9.96x | 17.9 | 1,011 |
| 4000 | 4,538 | 10,260 | 20,290 | 27,240 | 28,200 | 1.00x | 9.97x | 17.9 | 599 |
| **10000** | 4,852 | 10,580 | 20,600 | 28,160 | 31,510 | 0.87x | 0.95x | 17.6 | 1 |

1. `climbPerMinBps` and `dropPerCreditBps` set the pace and the price together. the pace follows their ratio: climb 100 or drop 25 (ratio 2) buys 2 credits a minute, 9,082 and 8,990 credits by day 3, spends the pot on day 6.3 and pays 0.98 times market with a peak bid of 1.15 times market; climb 25 or drop 100 (ratio 0.5) buys 0.5 a minute, 2,740 and 2,742 credits by day 3, spends the pot on day 47 and pays 0.77 times market. the faster rules end lower on comparable volume (25,560 and 25,740 credits at day 90, 19 percent under launch) and the slower rules higher (38,310 and 38,360, 22 percent over launch), because the slow rule spends the same pot at lower prices and the sale proceeds keep funding it. `dropPerCreditBps` 200 leaves part of the pot unspent at day 90.
2. `dropFloorBps` limits bursts. 9500 allows a fall of 5 percent a minute: day 3 holds 5,267 credits (4,852 at launch) with a peak bid of 0.96 times market and day 90 31,750. 5000 differs little from 8000 (4,300 by day 3, 32,030 at day 90).
3. `ceilBps` gives the same result at 11000, 12500, 15000 and 20000 on a flat market, because the peak bid is 0.95 times market, under every ceiling tested. it is a guard for markets that rise fast.
4. `idleLoosenBps` leaves a flat market unchanged (identical rows at 0, 100, 200 and 500). its job is to raise the ceiling after a stretch of minutes in which nothing fills, which docs/BID-STUDY.md measures.
5. `spendCapBps` is the share of the pot one hour window can spend, and sets the clamp. at 10000 the cap blocks buying for 1 minute in 90 days and the peak bid is 0.95 times market. below 10000 the window blocks buying for 599 minutes (4000) to 1,570 minutes (500), the peak bid reaches 9.07 to 9.97 times market (the rate cap is 10 times `rateStart`), the price paid is 0.99 to 1.01 times market and credits at day 90 end 10 to 12 percent lower (27,790 to 28,230 against 31,510). day 7 is 3 to 5 percent lower (10,030 to 10,260 against 10,580).
6. `rateCap` bounds the peak bid. `rateCap` is 10 times `rateStart`. at launch values the peak bid is 0.95 times market, a tenth of the cap. with `spendCapBps` below 10000 the peak bid reaches 9.07 to 9.97 times market, where the cap bounds it.
7. hard cases (3 seeds, opening limit 40 percent in a recovering market, or a declining market) give the same ranking: pace sets the outcome. recovering market, credits at day 90: 25,040 at launch, 21,930 at `climbPerMinBps` 200 (0.97x paid) and 25,480 at 25. declining market: 40,560 at launch, 65,020 at `climbPerMinBps` 25 (0.79x paid) and 22,080 at 200 (1.16x paid). in a falling market the slow bid gains the most because it spends the pot at lower prices.

recommendation: **keep the launch values.** they buy 1 credit a minute, 4,852 credits by day 3 and 20,600 by day 14, at 0.87 times market with a peak bid of 0.95 times market. what changes the answer is the goal: earlier credits at a higher price (`climbPerMinBps` 100 gives 9,082 by day 3, ends 19 percent lower at day 90 and pays 0.98 times market), or more credits later at a lower price (`climbPerMinBps` 25 gives 22 percent more at day 90 at 0.77 times market, with 5,607 by day 7 against 10,580). since the goal is early credits, keep. the signals to watch: price paid over market near 1.0 or above, or a peak bid above 1.3 times market, mean the climb outpaces the drop: lower `climbPerMinBps` or raise `dropPerCreditBps`. the hourly cap should stay at 10000: any lower value blocks buying for 599 to 1,570 minutes in 90 days and takes the peak bid to 9 to 10 times market.

## 7. after the launch pot: credits and statements per day against coin volume

coin volume that decays from day two to the stated constant by about day 10 (custom preset), last 30 days of a 90 day run, launch values.

| coin volume, eth a day | fees a day, eth | launch pot spent on day | steady credits a day | steady statements a day | steady sold a day | eth a day buying $CC | credits acquired by day 90 | waiting for phase 2 at day 90 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 0.059 | 17.3 | 67 | 0.8 | 1.1 | 0.26 | 31,530 | 223 |
| 5 | 0.294 | 17.5 | 116 | 1.4 | 1.5 | 0.30 | 35,540 | 247 |
| 17 | 0.998 | 18.3 | 230 | 2.9 | 1.9 | 0.32 | 44,930 | 330 |
| 50 | 2.935 | 20.9 | 493 | 6.2 | 1.7 | 0.34 | 66,040 | 598 |
| 150 | 8.805 | 44.0 | 678 | 8.5 | 1.6 | 0.39 | 102,200 | 1,058 |

1. sale proceeds carry about 55 credits a day at any volume, and coin fees add to that, about 8 to 12 credits a day per eth of daily volume up to 50 eth a day (fees reaching the pot are 5.87 percent of volume in steady state, a credit costs about 0.0077 eth at 0.87 times market). the flow grows with volume up to 50 eth a day.
2. statements a day are credits over 80. sold a day saturates at 1 to 2 whatever the volume, because buyers stay at 8 a day decaying to 2 as supply grows (29 percent of them find no price). the waiting stock grows by the difference.
3. at 150 eth a day the engine has bought 102,200 credits by day 90, 106 percent of the opening float of 96,800 (the book refills at 150 offers an hour), the launch pot lasts until day 44 and the steady flow is 678 a day. at 50 eth a day it holds 68 percent of the float by day 90 (66,040). the seller book bounds credits acquired.
4. five times more statement buyers (40 a day decaying to 10) lift steady flow at 17 eth a day from 230 to 410 credits a day (sale proceeds) and sold from 229 to 770 in 90 days. the sale side is the lever below 17 eth a day.
5. the buyback spends 0.26 to 0.39 eth a day after the launch pot.

## 8. phase 2

the owner sets the exitModule at once, on day 14, 30 or 60. the keeper exits every eligible unbid listing (older than `exitAfter`, 105 hours) at once. an exit pays `rating * unitPerPoint` of exitToken, so the value in eth is the rating times the exitToken price per point (`xp`). a typical exited statement rates about 33,500 points and costs about 0.75 eth, so the break even exitToken price is about 2.25e-5 eth per point, and the price at which an exit returns the hard floor of 75 percent of cost is about 1.7e-5. the comparison without a module is 31,500 credits at day 90 (3 seeds).

| module on day | exitToken price per point | stock waiting before | statements exited by day 90 | exit value over cost | exit bid pot after 7 days | exit bid rate after 7 days, bps of score | credits bought through the exit bid by day 90 | credits acquired by day 90 | percent of supply burned |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 14 | 5e-6 | 190 | 250 | 0.22 | 19 | 9,700 | 5 | 28,960 | 9.9% |
| 14 | 1e-5 | 190 | 354 | 0.45 | 37 | 9,639 | 8,414 | 37,430 | 11.8% |
| 14 | 2e-5 | 190 | 361 | 0.89 | 78 | 5,080 | 9,181 | 38,860 | 15.0% |
| 14 | 3e-5 | 190 | 365 | 1.34 | 123 | 3,333 | 9,326 | 39,300 | 17.1% |
| 14 | 5e-5 | 190 | 727 | 2.23 | 233 | 3,002 | 38,370 | 68,720 | 20.1% |
| 14 | 1e-4 | 190 | 1,125 | 3.64 | 1,044 | 3,000 | 70,870 | 98,340 | 23.8% |
| 30 | 1e-5 | 244 | 331 | 0.45 | 42 | 9,387 | 7,007 | 36,470 | 11.2% |
| 30 | 3e-5 | 244 | 336 | 1.35 | 138 | 3,093 | 7,414 | 37,630 | 15.6% |
| 30 | 5e-5 | 244 | 637 | 2.24 | 291 | 3,003 | 31,520 | 61,910 | 18.4% |
| 60 | 1e-5 | 234 | 276 | 0.45 | 40 | 9,480 | 3,422 | 33,920 | 10.6% |
| 60 | 3e-5 | 234 | 281 | 1.34 | 133 | 3,101 | 3,790 | 34,580 | 12.9% |
| 60 | 5e-5 | 234 | 430 | 2.24 | 279 | 3,007 | 15,670 | 46,540 | 14.8% |

1. the stock is of similar size whenever the module arrives: 190 unbid statements on day 14 (the pot lasts until day 18, so the stock is still growing), 244 on day 30 and 234 on day 60, then about one a day sells. the exit takes the whole stock at the first hour.
2. what an exit is worth depends on the exitToken price only. exit value over cost is 0.22 at 5e-6, 0.89 at 2e-5, 1.34 at 3e-5 and 2.23 at 5e-5. below 2.25e-5 the exit gives back less than the engine paid, below 1.7e-5 less than the hard floor.
3. the exit feeds the engine. an exit puts 50 percent of the exitToken in the exit bid pot (`exitToBuyback`), which buys credits through the exit lane. at 1e-5 that bought 8,414 credits by day 90 when the module arrives on day 14 (the exit bid pays by score, so it buys the high score credits first) and lifted credits acquired from 31,500 to 37,430, 19 percent. at 5e-5 and 1e-4 the pot is so large the bid sits at its floor and still buys 38,370 to 70,870 credits, more than the float allows in practice, so read these as an upper bound. a later arrival gives less because less time remains: 8,414 on day 14, 7,007 on day 30, 3,422 on day 60 at 1e-5.
4. exit bid pace: the bid climbs 100 bps an hour while its pot affords one average credit, so it reaches 9,390 to 9,700 bps within a week when the price is low (5e-6, 1e-5) and sits near its 3,000 floor when the pot is large against the price (5e-5 and up), where each credit bought drops it 20 bps.
5. the exitToken dutch auction runs at a pace of one slice per half life by design: 292 fills in 76 days at about 6 hours each, mean 14.9 percent all in discount to the pool price at the taker threshold. a slice is 20 average credits of exitToken, 0.26 eth of value at 3e-5. one slice per 6 hours is about 1 eth of exitToken a day. the exit of 365 unbid statements puts about 254 eth of exitToken into the two pots at 3e-5 (module on day 14), half to the exit bid pot and 127 eth to the auction pot: 76 eth of it has been filled and 51 eth is still waiting at day 90. a large exit batch waits months for the auction. a larger `exitSliceCredits` or a shorter `xAuctionHalfLife` speeds it.
6. a keeper that exits only when the module pays at least the asking price (instead of at once) exits 0 statements at 1e-5 and sells 167 statements by day 90 against 123 when it exits at once, and credits end at 31,500 against 36,470. `exitStatement` is permissionless, so at a low exitToken price anyone can force the exit of listings that a buyer would still have bought. the owner controls this through `exitAfter` and the moment the exitModule is set.

## 9. sensitivity ranking

low and high value of each input against the base case (31,510 credits and 394 statements at day 90, 168 sold at 85 percent of cost, 43.5 eth burned; the rows are 3 seed runs, base 3 seeds 31,500 credits and 167 sold). statements created move by the same share as credits, because 80 credits make one statement. ranked by the swing in credits.

| rank | input | low | high | credits low | credits high | swing | statements sold low | statements sold high | avg sale price low | avg sale price high |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | coin volume scale | 0.25x | 4x | 14,300 | 99,210 | 594% | 163 | 203 | 92% | 77% |
| 2 | flat credit price, eth | 0.0045 | 0.018 | 56,010 | 18,360 | 205% | 170 | 155 | 82% | 88% |
| 3 | `climbPerMinBps` | 25 | 200 | 37,880 | 22,330 | 70% | 208 | 143 | 80% | 93% |
| 4 | seller offers an hour | 60 | 400 | 23,560 | 38,810 | 65% | 109 | 206 | 87% | 84% |
| 5 | credit price path | decline | recovery | 40,560 | 25,390 | 60% | 153 | 219 | 83% | 79% |
| 6 | `saleToBuybackBps` | 0 | 10000 | 38,310 | 25,790 | 49% | 203 | 171 | 83% | 78% |
| 7 | `flatBps` | 0 | 10000 | 21,750 | 31,500 | 45% | 105 | 167 | 80% | 85% |
| 8 | anti sniper volume share | 0.2 | 0.6 | 26,140 | 37,340 | 43% | 171 | 170 | 88% | 84% |
| 9 | engine price impact | 0 | 0.3 | 34,890 | 25,950 | 34% | 180 | 151 | 84% | 86% |
| 10 | statement buyers a day | 3 | 20 | 29,640 | 38,470 | 30% | 112 | 345 | 87% | 85% |
| 11 | `dropPerCreditBps` | 25 | 200 | 25,850 | 32,590 | 26% | 146 | 209 | 92% | 81% |
| 12 | `feeToBuybackBps` | 0 | 2500 | 31,500 | 26,150 | 20% | 167 | 167 | 85% | 87% |
| 13 | hour one share of day one volume | 0.45 | 0.7 | 28,930 | 33,950 | 17% | 165 | 171 | 87% | 85% |
| 14 | statement willingness to pay | 0.7x | 1.3x | 28,370 | 32,710 | 15% | 90 | 196 | 84% | 86% |
| 15 | seller ask spread | 0.15 | 0.4 | 29,840 | 33,740 | 13% | 162 | 185 | 83% | 85% |
| 16 | `spendCapBps` | 1000 | 10000 | 28,260 | 31,500 | 11% | 184 | 167 | 77% | 85% |
| 17 | buyer pick rule | cheapest | random | 31,500 | 34,690 | 10% | 167 | 234 | 85% | 80% |
| 18 | listed share of offers | 0 | 0.5 | 31,500 | 34,210 | 9% | 167 | 188 | 85% | 86% |
| 19 | sale mode | auction | buy only | 31,500 | 33,220 | 5% | 167 | 205 | 85% | 85% |
| 20 | gas price, gwei | 0.5 | 10 | 31,940 | 30,630 | 4% | 172 | 164 | 85% | 85% |
| 21 | `auctionDuration` | 6h | 72h | 32,460 | 31,150 | 4% | 189 | 156 | 85% | 85% |
| 22 | `startBps` | 9000 | 13000 | 31,310 | 32,360 | 3% | 174 | 174 | 78% | 91% |
| 23 | seller book churn | 0.02 | 0.15 | 32,240 | 31,240 | 3% | 175 | 165 | 85% | 85% |
| 24 | `stepEvery` | 1h | 6h | 31,030 | 31,660 | 2% | 163 | 164 | 81% | 88% |
| 25 | both floors (`floorBps`, `saleFloorBps`) | 5000 | 7500 | 31,890 | 31,500 | 1% | 224 | 167 | 62% | 85% |
| 26 | `rateStart` | 25% | 125% | 31,990 | 31,720 | 1% | 177 | 172 | 85% | 85% |
| 27 | buyers wait for the floor | no | yes | 31,500 | 31,510 | 0% | 167 | 178 | 85% | 75% |
| 28 | seller supply elasticity | 0.5 | 3 | 31,500 | 31,500 | 0% | 167 | 167 | 85% | 85% |
| 29 | coin buy share after day one | 0.42 | 0.52 | 31,500 | 31,500 | 0% | 167 | 167 | 85% | 85% |
| 30 | `ceilBps` | 11000 | 20000 | 31,500 | 31,500 | 0% | 167 | 167 | 85% | 85% |
| 31 | `idleLoosenBps` | 0 | 500 | 31,500 | 31,500 | 0% | 167 | 167 | 85% | 85% |
| 32 | `exitAfter` | 24h | 168h | 31,500 | 31,500 | 0% | 167 | 167 | 85% | 85% |

1. credits acquired follow the money (coin volume), the price of a credit and the supply of sellers. these are inputs of the world.
2. of the settings six matter for credits: `climbPerMinBps` (70 percent), `saleToBuybackBps` (49), `flatBps` (45), `dropPerCreditBps` (26), `feeToBuybackBps` (20) and `spendCapBps` (11). `climbPerMinBps` is the biggest, as the pace dial of section 6. `saleToBuybackBps` is the owner's choice between burn and credits, and the fee share is the same choice at launch.
3. for statements sold the order is different: the buyer rules (buyers a day 112 to 345 sold, willingness to pay 90 to 196, pick rule 167 to 234), then the bid pace through credits (`climbPerMinBps` 208 to 143, `dropPerCreditBps` 146 to 209), `flatBps` (105 to 167), both floors (224 against 167), buy only (167 to 205) and `auctionDuration` (189 to 156). the sale design moves the average price more than the count: 78 to 91 percent across `startBps`, 81 to 88 across `stepEvery`, 62 to 85 across the floors.
4. `rateStart`, `idleLoosenBps`, `ceilBps`, `exitAfter` and the whole sale design (the curve, the floors, the mode) move credits acquired by 5 percent or less. the sale design acts on statements sold and eth recycled, and leaves credits and statements created close to unchanged.

## 10. what the model cannot tell us, and its weakest assumptions

1. the ask distribution. only fills are visible, so the ask distribution behind them is inferred. the cheap tail of sellers (lognormal spread 0.27) sets how cheap the first credits are and how fast the price climbs. a thinner tail means the engine overpays from the first fill. the engine pays its bid to every seller that clears, so the first fill price is a bid. docs/BID-STUDY.md tests the bid rule against other ask distributions.
2. statement demand and buyer behaviour. 42 priced sales over 5 days, all at fixed prices. arrivals are fixed at 8 a day decaying to 2 **whatever the price level or the curve**, so a lower price in the model sells to the same buyers. in reality a cheaper statement may draw more, and a buyer who sees a falling price may wait for it: the pessimistic run is that case with every buyer waiting for the floor, and it sells 179 to 199 statements because the buyers keep arriving. a real buyer that waits also arrives less often at a high price.
3. the two prices. a buyer judges a statement against the MARKET cost of its parts, the curve is set against what the engine PAID. the engine pays 0.87 times market on comparable volume and 0.81 on sustained volume, so a start price of 110 percent of cost is 96 percent of market in one case and 89 in the other. buyers who judge by something else (the rating, the best score inside, a rare credit) are outside the model. willingness to pay is rating insensitive and that may change once the exitModule pays by rating.
4. the coin net flow. buy share after day one (0.46) drives the coin price and so the percent of supply burned. volume is exogenous and independent of buybacks and statement sales.
5. the engine's own footprint. price impact elasticity 0.12 is a guess. credits acquired swing 34 percent between impact 0 and 0.3. the lift also raises statement willingness to pay in the model.
6. seller supply and the float. 150 offers an hour, 5 percent leave an hour, more when the bid is above market, a float of 96,800 credits, which shrinks as credits are burned into statements. the model has one kind of seller. a whale seller, a strategy relist at 1.2x and a competing protocol bid like the fwa hub at 0.029 flat are outside it. at 50 eth a day the engine buys 68 percent of the opening float and at 150 eth a day 106 percent.
7. the anti sniper volume (40 percent of hour one volume inside 30 minutes) is inferred from the comparable's implied 406 eth against 194 eth at a flat 10 percent. 89 percent of fees come on day one, so the starting pot is the biggest input and the least observed, and the fee share is only worth setting on day one. credits acquired swing 43 percent across 20 to 60 percent.
8. phase 2 is parametric. the exitToken price per point is a constant, the module pays exactly `rating * unitPerPoint`, a keeper exits every eligible listing at once, takers fill exactly at their threshold, credit sellers compare exit bids frictionlessly, and the exit bid buying 38,000 to 71,000 credits at high prices ignores the float.
9. keepers and fees. `collectSales` runs every hour, `endAuction` is called the moment an auction ends, the first bidder reprices the listing to the asking price in the same step, the buyback keeper runs every 25 blocks. the Core pulls the fee router at the start of each sell and compose door, so fees wait in the router between door calls; the model books them as they arrive (flush delay 0, keeper cadence 0). the 1 eth buyback executes at the pool price, and wash volume is 0 (71 percent of the comparable's pool volume was churn and the model treats it as organic fee base). a house delivery failure (30 day unwind) is outside the model, and so is a bid placed on the house at the start price in buy only mode.
10. the launch day market price. the opening limit is a share of the market price on launch day. the model holds that price at 0.0089 eth (or its path). a different price on the day moves the rate with it, which is why the limit is set on launch day.
11. the owner. the model has one change at a time at a known day. a real owner reacts to signals and may change several settings at once, which the Core allows, and the controller's settings and the Core's are separate calls (lowering `floorBps` without `saleFloorBps` changes nothing). the stepped bid fields (`dropPerCreditBps` and the rest) are fixed in the model for a run: `schedule` patches the Core settings and the controller settings, so the stepped fields stay fixed for a run. the owner key is trusted fully and every change applies at once: the model assumes an owner who announces every change.

## recommended launch settings

| setting | launch value | recommendation | why |
|---|---|---|---|
| `rateStart` | 2.0554e13 (100% of market) | keep | buys at once, first 80 cost 0.86x market, day 1 holds 2,004 credits against 1,149 at 25%. later totals are flat across 25% to 125% |
| `flatBps` | 10000 | keep | most credits and statements. a blend of 7500 later buys 21% more score for 4% of credits |
| `avgScore` | 4,330,000 | keep | the population mean is 440 points, flat buys 426 |
| `dropPerCreditBps`, `climbPerMinBps` | 50, 50 | keep | 1 credit a minute, about 1,440 a day while the pot lasts, 0.87x market, peak bid 0.95x. the ratio sets the pace: 100 on the climb is earlier and dearer, 25 later and cheaper |
| `dropFloorBps` | 8000 | keep | limits one minute of buying to a 20% fall. 9500 lifts day 3 credits from 4,852 to 5,267 and the peak bid to 0.96x |
| `ceilBps`, `idleLoosenBps` | 12500, 200 | keep | guards for fast markets and gaps. same result as launch on a flat market |
| `spendCapBps` | 10000 | keep, the bound | the hourly window may spend the whole pot, and sets the clamp at one average credit. below 10000 the cap blocks buying for 599 to 1,570 minutes in 90 days, the peak bid reaches 9 to 10 times market and credits at day 90 end 10 to 12% lower. 10000 is the highest value |
| `rateCap` | 2.0554e14 | keep | 10 times `rateStart`. the peak bid at launch values is 0.95x market, a tenth of the cap. it is the owner's "never pay more than this per credit" |
| `startBps`, `stepBps`, `stepEvery`, `floorBps` | 11000, 100, 3 hours, 7500 | keep | the curve moves the average price by 14 points and credits by 4 percent at most. higher or slower is more eth per sale, lower or faster sells about the same count |
| `saleFloorBps` | 7500 | keep | the hard floor wins: lowering `floorBps` alone changes nothing, lower both together. cut both to 6000 on day 7 to 30 if old statements pile up (comparable volume: 25% more sold, 9% more eth recycled) |
| `buyOnly` | false (auction) | keep, switch later if second bidders pile onto live auctions | buy only sells 23% more statements and recycles 23% more eth under the lowest ask rule, 4% fewer statements under random pick, credits +6% |
| `auctionDuration` | 24 hours | keep, shorten if the second bidder share is high | 6 hours recycles 12% more eth under the lowest ask rule. a real house may differ |
| `feeToBuybackBps` | 0 | keep: a launch decision | 89% of fees come on day one. 1000 burns 57% more eth for 6% fewer credits, 2500 burns 2.4 times for 17% fewer. after day 7 the result is unchanged |
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
| `auctionDuration` | shorter | second bidders a large share of sales (13% at launch in the model) |
| `feeToBuybackBps` | only at launch | the owner prefers burn over credits in the first week |
| `saleToBuybackBps` | toward the pot if credits matter more than burn, toward the buyback if burn does | credits a day after the pot is spent under 50 at launch volume, eth spent buying coin per day |
| `climbPerMinBps`, `dropPerCreditBps` | lower the climb or raise the drop | price paid over market near 1.0 or above, the bid above 130% of market for more than a day |
| `setRate` | reset the limit | the market price of a credit moves 30% from the launch day value in week one, or the pot sits unspent for days with the bid under market |
| `flatBps` | 7500 | credits flowing steadily and the average score bought below the population mean of 440 |
| `exitSliceCredits`, `xAuctionHalfLife` | larger slice or shorter half life | exitToken waiting for the auction above 30 days of slices after phase 2 |
| `exitAfter` | longer, if the exitToken price is below the break even of about 2.25e-5 per point, or with a slower curve | exitToken price per point against 0.75 eth over a 33,500 point statement |

## files

sim/engine.js (model, the single source), sim/engine.test.mjs (564 checks), sim/run.mjs (batches, `node run.mjs q1 to q11`), sim/results/*.json, sim/build.mjs and the page parts (page.css, page.body.html, page.ui1.js to page.ui4.js), sim/index.html (built, single file, 5 minute steps). a 90 day run takes 4.9 seconds at 60 second steps. the 11 batches run as parallel processes in 44 minutes on a 16 core machine (the longest, q4, takes 43 minutes alone).
