# simulation of the credits engine

sim/engine.js is a deterministic hourly model of the engine in src/Core.sol on branch flow: the blended bid (`flatBps`, `avgScore`), the rate climb, the funded rule, drop on fill, the hourly cap, both buy doors, compose, listing on the pnd auction house as an english auction, `collectSales`, the buyback, the exit lane, the exitToken bid, the exitToken dutch auction and settings changes mid run. rules and names are the Core's, launch values are script/config/mainnet.json (a test reads the file). the launch position is real concentrated liquidity math. sellers, statement buyers and coin volume are calibrated on the 13 day data pull in sim/data/notes.md. every number below is a mean over 3 to 5 seeds of a 90 day run unless stated. raw rows are in sim/results/*.json (node run.mjs q1 to q11), the interactive page is sim/index.html. `exitModule` and `exitToken` are the only names used for phase 2.

## the goal and the headline metrics

the engine exists to keep credits flowing into statements. a statement selling below the cost of its 80 credits is better than no sale. unsold statements are fine, they wait for the exitModule in phase 2. the engine never stops buying because statements are unsold (there is no inventory gate in the Core and none in the model). early on it should acquire as many credits as possible, score can matter later.

headline metrics, in this order: credits acquired, statements created, statements sold, eth sent to buy and burn the coin, statements waiting for phase 2, days until the launch pot is spent, steady state credits per day after that. the launch pot is spent when the pot falls under 5 percent of its peak. steady state is the last 30 days of a 90 day run.

verdict in one paragraph: **the engine keeps buying under every volume preset, and unsold statements never slow it.** as launched on the comparable coin it acquires 27,100 credits in 90 days, 24,350 of them by day 30, creates 339 statements and sells 121 of them. 31 eth buys and burns 8.1 percent of the coin. 216 statements wait for phase 2. the launch pot of about 290 eth is spent on day 6.5. after that the flow is about 46 credits a day, paid for by the 0.05 eth a day the coin still pays and by sale proceeds. a second bidder shows up in about a third of the auctions the model sells, so in this model the reserve is the price.

## what the model changed against the old branch

| piece | now |
|---|---|
| bid | `flatBps` 10000 prices every credit as `avgScore`, 0 prices it by its own score, in between blends. no controller bonus (ControllerV1 returns 0) |
| gate | removed, with every trace. a test checks the source |
| statements | listed at compose on an english auction, reserve `reserveBps` of cost, `auctionDuration` timer from the first bid, 5 percent raise, 15 minute extension, highest bid wins, unbid statements stay listed |
| proceeds | credited to the Core in the house at the end of the auction, reach the pots only when `collectSales` runs (a keeper every hour), split by `saleToBuybackBps` |
| phase 2 exit | an unbid listing may exit through the exitModule after `exitAfter` (72 hours), a statement with a bid never |
| settings | one `Settings` object with the Core's field names, `schedule` of `{day, patch}` changes it mid run with the Core's checkpoint, bounds and reprice rules |
| opening limit | `rateStart` 1.54e13, 75 percent of the market price of a credit over `avgScore` |
| rate cap | `rateCap` 1.232e14 (8 times `rateStart`): the climb stops at the lower of the funded clamp and `rateCap`, `setRate` refuses above it. the launch runs below it, so every number in this file is the same with and without it (checked: identical credits, statements and sales at 90 days on three presets) |

port checks: node engine.test.mjs runs 254 numeric checks against hand computed Core values: the launch values against mainnet.json, climb tiers, the funded rule and clamp, the rate cap (climb clamp, `setRate`, a lower cap pulling the rate down), the tightened bounds, the exit lane reimbursement cap at `rateStart`, drop on fill, hourly cap, the blended ceiling at five values of `flatBps`, tip rule, compose reimbursement with the listing gas, the reserve and repricing, every english auction rule (reserve, 5 percent raise, extension, end, winner), the proceeds split at five values, `setSettings` bounds and checkpoint, exit eligibility, the exitToken auction and bid, buyback, the pool, and eth accounting identities over whole runs (pot, buyback pot, house).

## model in short

| piece | what it does | calibration |
|---|---|---|
| coin market | exogenous daily volume, buy share, skim 10 percent with 9.5 points to the pot, anti sniper 90 to 10 percent over 30 minutes, single sided position tick -175000 to 887200 | model price after day one 4.48e-7, observed 4.44e-7 |
| credit sellers | uniform scores 80 to 800, flat ask per credit with lognormal spread 0.27, top tier premium above 740, 150 offers an hour, 5 percent leave an hour, more offers when the bid is above market, a float of 96,800 credits | median 0.0089 eth, p10 0.0069, p90 0.0138 |
| doors | the sell door pays the bid for any credit whose ceiling clears its ask, cheapest ask per bid point first. CreditStrategy listings clear through the listing door with the tip | 13,132 listings at median 0.036 eth |
| statement buyers | arrivals 8 a day decaying to 2, willingness to pay as a multiple of 80 times the flat price, rating insensitive. each buyer bids once, the minimum the house accepts, on the cheapest auction that fits (`stmtPick` random takes any that fits) | median 0.84, 21 percent at 1.2 or more, max 1.32, from fixed price sales. no data on auctions |
| engine to market feedback | engine spend lifts the flat price, elasticity 0.12, half life 48 hours, cap 3x | assumption |
| phase 2 | exitModule pays rating times unitPerPoint, exit lane, exitToken bid by score, dutch auction with takers at a set discount, a keeper exits every eligible listing | assumption |

## 1. the launch configuration as built

| preset | day | credits acquired | statements created | sold | eth spent buying coin | percent of supply burned | waiting for phase 2 |
|---|---|---|---|---|---|---|---|
| comparable decay | 30 | 24,350 | 304 | 77 | 21.0 | 5.6% | 227 |
|  | 60 | 25,740 | 321 | 100 | 26.3 | 6.9% | 221 |
|  | 90 | 27,110 | 339 | 121 | 31.3 | 8.1% | 216 |
| sustained 17 eth a day | 30 | 28,610 | 357 | 108 | 29.0 | 4.7% | 247 |
|  | 60 | 38,240 | 478 | 164 | 42.0 | 6.2% | 312 |
|  | 90 | 47,430 | 592 | 209 | 52.6 | 7.3% | 382 |
| sustained 50 eth a day | 30 | 37,180 | 464 | 100 | 29.3 | 4.7% | 364 |
|  | 60 | 57,680 | 720 | 149 | 42.8 | 6.3% | 570 |
|  | 90 | 78,160 | 976 | 196 | 55.5 | 7.6% | 778 |
| dead after week one | 30 | 23,460 | 293 | 72 | 20.1 | 5.2% | 220 |
|  | 60 | 24,800 | 310 | 96 | 25.8 | 6.4% | 213 |
|  | 90 | 25,990 | 324 | 117 | 30.8 | 7.4% | 207 |

| preset | fees in | launch pot spent on day | steady credits a day | steady statements a day | steady sold a day | price paid over market | average score bought |
|---|---|---|---|---|---|---|---|
| comparable decay | 296 | 6.5 | 46 | 0.57 | 0.71 | 1.05x | 428 |
| sustained 17 | 403 | 6.3 | 306 | 3.8 | 1.5 | 0.92x | 425 |
| sustained 50 | 683 | 6.5 | 683 | 8.5 | 1.6 | 0.91x | 425 |
| dead after week one | 288 | 6.5 | 40 | 0.48 | 0.69 | 1.07x | 429 |

reading it:

1. the pot is spent in 6 to 7 days under every preset, because 255 of the 296 eth arrive on day one. by day 7 the engine holds 21,000 credits, 77 percent of what it will have at day 90 on comparable volume.
2. unsold statements do not slow anything. 216 statements wait at day 90 and the engine bought 1,360 credits in days 60 to 90 regardless. with no statement buyer at all (stmtPerDay 0) credits acquired at day 30 stay within 10 percent of the base run (a test checks it).
3. after the pot is gone the flow is set by income: coin fees plus sale proceeds that go to the pot (half of every sale at launch values). at the comparable floor of 0.5 eth a day of coin volume that is 46 credits a day, at 17 eth a day 306, at 50 eth a day 683 (section 7).
4. statements sold are limited by buyers, not by the engine. 281 buyers arrive in 90 days, 106 find no price they accept. sustained volume makes more statements (592 at 17 eth a day) and sells about the same (209), so the waiting stock grows 3 a day.
5. 31 eth of buyback burns 8.1 percent of supply because the pool price sits near 3e-7. the percent depends on the coin price more than on the engine.
6. the engine bids above the market in days 2 to 6 (up to 1.26x the market price of a 440 point credit) while the pot is large, then falls to about 60 percent of it. all credits cost 1.05x the flat price on comparable volume.

## 2. the opening limit

`rateStart` as a share of the market price of a credit (0.0089 eth, so 75 percent is 1.54e13).

| share | rateStart | hours to first buy | credits day 1 | day 3 | day 7 | day 14 | day 30 | first 80 cost over market | all credits over market |
|---|---|---|---|---|---|---|---|---|---|
| 25% | 5.14e12 | 33.2 | 0 | 70 | 7,062 | 21,910 | 23,450 | 0.52 | 1.06 |
| 40% | 8.22e12 | 0.11 | 22 | 1,047 | 13,400 | 22,290 | 23,760 | 0.53 | 1.06 |
| 50% | 1.03e13 | 0.03 | 177 | 2,660 | 17,130 | 22,540 | 24,030 | 0.54 | 1.06 |
| 60% | 1.23e13 | 0.03 | 617 | 4,431 | 19,610 | 22,710 | 24,170 | 0.60 | 1.05 |
| **75%** | 1.54e13 | 0.03 | 1,561 | 6,991 | 20,960 | 22,910 | 24,430 | 0.74 | 1.05 |
| 90% | 1.85e13 | 0.03 | 2,683 | 9,425 | 20,970 | 22,920 | 24,290 | 0.89 | 1.06 |
| 100% | 2.06e13 | 0.03 | 3,440 | 10,860 | 20,810 | 22,810 | 24,230 | 0.99 | 1.06 |
| 125% | 2.57e13 | 0.03 | 5,295 | 13,530 | 20,330 | 22,480 | 23,970 | 1.23 | 1.08 |

1. the opening limit changes the first three days and nothing after day 7. credits at day 14 and day 30 are flat from 50 to 100 percent (22,500 to 22,900 and 24,000 to 24,400), the pot is spent in the same week.
2. below 40 percent the engine waits: at 25 percent nothing is bought for 33 hours and day 7 holds a third of the credits.
3. the first fills are the cheapest sellers. the first 80 credits cost 0.74x market at 75 percent and 0.99x at 100 percent. the engine pays its bid to every seller that clears, not their ask, so a higher limit pays more for the same credits.
4. the price paid over all credits does not move (1.05 to 1.06) because the climb and the drop take over within two days.
5. rising market (price recovers to 2.2x): a higher limit is better, day 7 holds 18,980 credits at 100 percent against 17,370 at 75. falling market: 60 to 75 percent is best at day 7 (22,400). the rule scales with price: at flat prices of 0.0045, 0.018 and 0.03 the same 75 percent buys within the first hour. what the pot then buys depends on the price (38,750, 15,220 and 12,670 credits by day 30).

confirm 75 percent. it sits on the plateau for total credits, buys at once, and pays 0.74x for the first fills. 90 percent is the dial for a faster first three days: it buys 35 percent more by day 3 (9,425 against 6,991) for 15 points more on the first 80 and nothing different at day 7. launch day rule: rateStart = share times market price of a credit in wei times 1e4 over `avgScore`, market price the median of the last 24 hours of seaport fills.

## 3. flat, blended or per point

`flatBps` 10000 prices every credit as an average one (433 points), 0 prices it by its own score. comparable volume, 90 days.

| flatBps | credits acquired | price paid over market | price per point over market | average score bought | statements created | sold | credits day 7 |
|---|---|---|---|---|---|---|---|
| 10000 flat | 27,110 | 1.05x | 1.08x | 428 | 339 | 121 | 20,970 |
| 7500 | 26,760 | 1.08x | 0.95x | 501 | 334 | 125 | 20,560 |
| 5000 | 24,870 | 1.15x | 0.92x | 551 | 310 | 112 | 19,370 |
| 2500 | 23,070 | 1.25x | 0.93x | 587 | 288 | 103 | 17,910 |
| 0 per point | 21,350 | 1.33x | 0.97x | 606 | 266 | 91 | 16,810 |

sustained 17 eth a day: 47,430 / 45,670 / 42,900 / 40,840 / 39,070 credits at 10000 / 7500 / 5000 / 2500 / 0, average score 425 / 523 / 586 / 620 / 639, price paid 0.92x / 0.95x / 1.01x / 1.07x / 1.12x.

1. flat buys the most credits and the most statements. going from flat to per point loses 21 percent of the credits and 21 percent of the statements, and pays 28 points more per credit.
2. the market prices credits flat in score (notes.md fact 1), so a per point bid pays the same ask for a low score credit and clears the high score ones first. that is why the average score rises from 428 to 606.
3. score is bought at a price: from flat to 7500 the average score rises 73 points (17 percent) for 2.4 points of price and 1.3 percent of credits. past 7500 each step loses more credits than it gains in score.
4. the switch on day 30 does little. the pot is gone by day 7, so the bid has little to buy with. flat to 5000 on day 30: credits 27,190 (27,110 unchanged), average score 453, steady flow 44 a day (46). flat to 0: 27,100, score 457, steady flow 38. in sustained 17 eth a day a switch to 5000 costs 4 percent of credits (45,520 against 47,430) and a switch to 0 costs 6 percent (44,610). if score matters later, a blend of 7500 is the cheap step.

## 4. the reserve and the auction duration

reserve sweep, comparable volume, 90 days (reserve as bps of statement cost).

| reserveBps | statements sold | eth recycled by sales | eth spent buying coin | waiting for phase 2 | credits acquired | sale price over cost | auctions with a second bidder |
|---|---|---|---|---|---|---|---|
| 5000 | 179 | 60.0 | 30.0 | 161 | 27,390 | 0.51 | 29% |
| 6000 | 164 | 62.5 | 31.2 | 179 | 27,550 | 0.61 | 32% |
| 7000 | 145 | 61.7 | 30.9 | 195 | 27,320 | 0.71 | 33% |
| 8000 | 131 | 61.9 | 31.0 | 207 | 27,150 | 0.81 | 32% |
| 9000 | 121 | 62.6 | 31.3 | 216 | 27,110 | 0.92 | 34% |
| 10000 | 123 | 69.1 | 34.6 | 220 | 27,570 | 1.02 | 36% |
| 11000 | 112 | 65.9 | 33.0 | 230 | 27,460 | 1.12 | 30% |
| 12000 | 108 | 67.7 | 33.8 | 236 | 27,580 | 1.22 | 28% |

sustained 17 eth a day: sold 249 / 248 / 229 / 209 / 195 / 156 / 130 at 5000 / 6000 / 7000 / 9000 / 10000 / 11000 / 12000, eth recycled 69 / 83 / 90 / 105 / 109 / 94 / 85, eth spent buying coin 35 / 41 / 45 / 53 / 54 / 47 / 43.

how often an auction gets a second bidder. one third of the sold auctions at 8 buyers a day (1.43 bids a sale), 8 percent in sustained 17 eth a day (more statements, same buyers), 61 percent at 20 buyers a day. buyers arrive one at a time and take the cheapest bid that fits their willingness to pay, so cheap statements attract second bids. if buyers pick any statement that fits instead (`stmtPick` random), the share is 7 percent at 8 buyers a day (1.07 bids a sale) and 27 percent at 20. the average sale price is 1.8 percent over the reserve (1.004 to 1.02 across presets), because a second bid raises the price only 5 percent. a bid in the last 15 minutes happened 1 time in 90 days. what it implies: **the english auction is a fixed price sale at the reserve.** `reserveBps` is the price. the auction duration matters little (below). nobody bids against the reserve to find a higher price in any quantity that moves eth recycled.

duration, comparable volume (cheapest pick): 1 hour 161 sold, 6 hours 152, 24 hours 121, 3 days 110, 7 days 90, with eth recycled 86 / 81 / 63 / 54 / 43. under random pick the same sweep is flat: 225 / 218 / 215 / 205 sold, recycled 131 / 124 / 123 / 117. the long duration loss under cheapest pick is a pile on of buyers onto one live auction, which the real house may or may not show. keep 24 hours: it costs nothing under either assumption beyond a few percent.

1. credits acquired and statements created do not depend on the reserve at all (27,100 to 27,600 across the sweep, seed noise). the reserve only moves how many statements sell and how much eth they bring back.
2. statements sold fall by a quarter from a reserve of 6000 to 9000 (164 to 121), but eth recycled and eth to burn are flat (62 to 63 eth, 31 eth). demand is close to unit elastic in the observed willingness to pay quantiles, so a lower price sells more units for the same eth. under comparable volume a lower reserve is free for the headline metrics and sells 35 percent more statements at 6000.
3. under sustained volume a lower reserve costs burn: 6000 recycles 83 eth against 105 at 9000 (minus 21 percent) and sells 19 percent more statements.
4. under random pick the same holds more strongly: 6000 sells 263 against 215 at 9000 and recycles 124 against 123.
5. a cut on day 14 beats a lower reserve from launch. reserve 6000 from day 14 (repriced listings): sold 161, recycled 71, burn 35.5 eth, waiting 186. reserve 6000 from launch: sold 164, recycled 62.5, burn 31.2. a day 7 cut gives 160 sold and 33 eth burned, a day 30 cut 152 and 35. early sales at 90 percent bring more eth when buyers are plentiful, the old stock then clears at the lower price. repriced listings keep their `listedAt` (the Core only moves the reserve).
6. willingness to pay is the real input: 0.7x median sells 80, 1.0x sells 124, 1.6x sells 191 (the reserve at 9000).

## 5. the proceeds split

`saleToBuybackBps` is the share of collected proceeds that goes to the coin buyback, the rest to the pot.

| saleToBuybackBps | credits day 7 | credits day 30 | credits day 90 | statements created | sold | eth spent buying coin | percent of supply burned | steady credits a day |
|---|---|---|---|---|---|---|---|---|
| 0 | 21,200 | 27,680 | 34,670 | 433 | 186 | 0 | 0 | 113 |
| 2500 | 21,090 | 25,930 | 30,210 | 377 | 149 | 18.3 | 5.4% | 68 |
| 5000 | 20,970 | 24,350 | 27,110 | 339 | 121 | 31.3 | 8.1% | 46 |
| 7500 | 20,860 | 23,200 | 25,160 | 314 | 113 | 46.9 | 10.5% | 32 |
| 10000 | 20,700 | 22,230 | 23,270 | 291 | 104 | 63.1 | 12.6% | 16 |

sustained 17 eth a day: credits at day 90 53,240 / 50,280 / 47,430 / 44,560 / 41,660, eth spent buying coin 0 / 26.8 / 52.6 / 76.4 / 95.9, steady credits a day 355 / 331 / 306 / 285 / 264. sustained 50: 82,230 to 73,300 credits, 0 to 108 eth burned.

1. the split has no effect on the first week (21,200 to 20,700 credits on day 7). it acts only after the launch pot is gone, when sale proceeds are the pot's main income.
2. the price of burn in credits: from 0 to 100 percent the engine gives up 11,400 credits (33 percent) for 63 eth of burn. one eth of burn costs about 180 credits at comparable volume, 120 at 17 eth a day.
3. the burn side is weak: 100 percent buys 12.6 percent of the supply, 0 buys none. the steady credit flow falls from 113 to 16 a day. with the owner's order of goals (credits first, burn fifth) the split is the first thing to move toward the pot if credits per day matter more than burn.
4. launch at 5000 is safe because the first week is unaffected. decide at day 7 to 14 when the pot is gone and the steady flow is visible.

## 6. dropBps, climbBaseBps, spendCapBps

comparable volume, 90 days, launch values 2000 / 100 / 2000. the bounds were tightened after these runs: `dropBps` 500 to 5000 and `spendCapBps` 100 to 5000, so the `dropBps` 0 and `spendCapBps` 10000 rows are counterfactuals the Core now refuses.

| dropBps | credits day 3 | day 14 | day 90 | price paid over market | launch pot spent on day | peak bid over market |
|---|---|---|---|---|---|---|
| 0 | 8,164 | 19,600 | 20,050 | 1.35x | 5.1 | 14x |
| 500 | 7,819 | 20,430 | 21,250 | 1.28x | 5.4 | 2.8x |
| 1000 | 7,556 | 21,950 | 26,090 | 1.09x | 5.7 | 1.30x |
| **2000** | 6,979 | 22,970 | 27,110 | 1.05x | 6.5 | 1.26x |
| 3000 | 6,428 | 23,570 | 28,030 | 1.03x | 7.4 | 1.23x |
| 5000 | 5,524 | 24,820 | 29,800 | 1.00x | 9.5 | 1.18x |

| climbBaseBps | credits day 3 | day 7 | day 14 | day 30 | day 90 | price paid over market | launch pot spent on day |
|---|---|---|---|---|---|---|---|
| 25 | 2,289 | 7,276 | 20,890 | 31,480 | 34,670 | 0.93x | 18.4 |
| 50 | 3,657 | 13,330 | 25,840 | 27,360 | 30,330 | 0.99x | 11.1 |
| **100** | 6,979 | 20,970 | 22,970 | 24,350 | 27,110 | 1.05x | 6.5 |
| 200 | 13,320 | 18,670 | 20,660 | 22,100 | 25,130 | 1.12x | 3.7 |
| 400 | 14,480 | 15,350 | 15,850 | 16,180 | 17,710 | 1.47x | 2.2 |

| spendCapBps | credits day 7 | day 30 | day 90 | price paid over market | hours the cap blocked a sale |
|---|---|---|---|---|---|
| 500 | 20,190 | 21,940 | 22,530 | 1.24x | 1,853 |
| 1000 | 20,830 | 24,140 | 27,000 | 1.06x | 367 |
| **2000** | 20,970 | 24,350 | 27,110 | 1.05x | 18 |
| 4000 | 20,890 | 24,490 | 27,690 | 1.05x | 0 |
| 10000 | 20,890 | 24,490 | 27,690 | 1.05x | 0 |

1. the climb and the drop together set how fast the pot is spent and what the engine pays. when the engine buys every hour, the climb per hour equals the drop per hour at a spend of `climbBaseBps / dropBps` of the pot an hour: 5 percent at launch values, a pot half life of about 14 hours. that is why the pot is gone in a week whatever the opening limit is.
2. `climbBaseBps` is the strongest dial. faster is earlier and dearer: at 400 the engine has 14,480 credits by day 3 and 17,700 at day 90, paying 1.47x with a bid up to 3.3x market. slower is later and cheaper: at 25 it has 2,290 by day 3 and 34,700 at day 90 (28 percent more), paying 0.93x. the crossing with the launch value is on day 10 to 20.
3. `dropBps` is the price discipline. at 0 the bid never comes back and the engine pays 1.35x with a bid up to 14x market. 1000 to 3000 is flat in credits and price within 8 percent. raising it from 2000 to 3000 gives 3 percent more credits by day 14 and day 90 and costs 8 percent of day 3 credits. 5000 is slower still.
4. `spendCapBps` is a guard, not a dial. at 4000 and 10000 it never blocks a sale. at 2000 it blocks 18 hours in 90 days. at 1000 it blocks 367 hours and costs nothing in credits by day 90. at 500 it blocks 1,853 hours, the engine pays 1.24x and ends 17 percent lower. it also clamps the climb through the funded rule, so a low cap clamps the bid early.
5. hard cases (opening limit 40 percent with a market that doubles, or a falling market) give the same ranking: no drop and a low cap lose, the climb sets the pace.

recommendation: **keep 2000 / 100 / 2000.** the launch values sit mid curve for pace and price. what changes the answer is the goal: earlier credits at a higher price (raise `climbBaseBps` to 200 gives 13,300 by day 3, loses 7 percent of day 90 credits and pays 1.12x), or more credits later at a lower price (50 gives 12 percent more by day 14 and by day 90 and cuts day 7 by a third). since the goal is early credits, keep. watch price paid over market: above 1.15x, raise `dropBps` or lower `climbBaseBps`.

## 7. after the launch pot: credits and statements per day against coin volume

coin volume that decays from day two to the stated constant by about day 10 (custom preset), last 30 days of a 90 day run, launch values.

| coin volume, eth a day | fees a day, eth | launch pot spent on day | steady credits a day | steady statements a day | steady sold a day | eth a day buying coin | credits acquired by day 90 | waiting for phase 2 at day 90 |
|---|---|---|---|---|---|---|---|---|
| 1 | 0.095 | 6.4 | 52 | 0.65 | 0.75 | 0.16 | 27,290 | 213 |
| 5 | 0.48 | 6.4 | 143 | 1.8 | 1.6 | 0.33 | 34,450 | 237 |
| 17 | 1.6 | 6.5 | 314 | 3.9 | 1.7 | 0.39 | 48,330 | 400 |
| 50 | 4.75 | 6.6 | 678 | 8.5 | 1.5 | 0.41 | 78,540 | 785 |
| 150 | 14.25 | 7.1 | 430 | 5.4 | 1.0 | 0.35 | 109,700 | 1,223 |

1. sale proceeds carry about 45 credits a day at any volume, and coin fees add to that, about 16 credits a day per eth of daily volume at 17 eth a day and 13 at 50 (fees are 9.5 percent of volume, a credit costs 0.0089 eth). the flow grows with volume up to 50 eth a day.
2. statements a day are credits over 80. sold a day saturates at 1 to 2 whatever the volume, because buyers do not grow with supply (8 a day decaying to 2, 25 percent of them find no price). the waiting stock grows by the difference.
3. at 150 eth a day the model hits the float: the engine has bought 109,700 credits, about all of the 110,000 live credits, and falls to 430 a day with a price of 1.28x. a bigger float limit is a hard cap on credits acquired. at 50 eth a day it holds 71 percent of the live credits by day 90.
4. five times more statement buyers (40 a day decaying to 10) lifts steady flow at 17 eth a day from 314 to 459 credits a day (sale proceeds) and sold from 202 to 581 in 90 days. the sale side is the lever below 17 eth a day.
5. the buyback spends 0.16 to 0.41 eth a day after the launch pot.

## 8. phase 2

the exitModule is set through the 7 day timelock on day 14, 30 or 60. the keeper exits every eligible unbid listing (older than `exitAfter`, 72 hours) at once. an exit pays `rating * unitPerPoint` of exitToken, so the value in eth is the rating times the exitToken price per point (`xp`). a typical statement rates 35,200 points and costs 1.18 eth, so the break even exitToken price is about 3.3e-5 eth per point.

| module on day | exitToken price per point | stock waiting before | statements exited by day 90 | exit value over cost | exit bid pot after 7 days | exit bid rate after 7 days, bps of score | credits bought through the exit bid by day 90 | credits acquired by day 90 | percent of supply burned |
|---|---|---|---|---|---|---|---|---|---|
| 14 | 5e-6 | 229 | 228 | 0.15 | 20 | 9,700 | 0 | 25,610 | 8.4% |
| 14 | 1e-5 | 229 | 333 | 0.29 | 39 | 9,607 | 8,467 | 33,820 | 10.1% |
| 14 | 2e-5 | 229 | 342 | 0.59 | 85 | 4,827 | 9,180 | 35,140 | 13.4% |
| 14 | 3e-5 | 229 | 343 | 0.88 | 131 | 3,240 | 9,263 | 35,830 | 15.8% |
| 14 | 5e-5 | 229 | 702 | 1.47 | 277 | 3,000 | 38,020 | 63,850 | 19.0% |
| 14 | 1e-4 | 229 | 1,146 | 2.88 | 907 | 3,000 | 73,120 | 97,210 | 23.1% |
| 30 | 1e-5 | 224 | 308 | 0.29 | 39 | 9,520 | 6,732 | 32,580 | 9.8% |
| 30 | 3e-5 | 224 | 315 | 0.88 | 129 | 3,087 | 7,345 | 34,100 | 14.6% |
| 30 | 5e-5 | 224 | 600 | 1.46 | 272 | 3,000 | 30,190 | 56,420 | 17.5% |
| 60 | 1e-5 | 219 | 259 | 0.29 | 38 | 9,560 | 3,304 | 29,890 | 8.8% |
| 60 | 3e-5 | 219 | 264 | 0.87 | 126 | 3,167 | 3,747 | 30,670 | 11.4% |
| 60 | 5e-5 | 219 | 406 | 1.45 | 265 | 3,000 | 15,070 | 41,700 | 13.4% |

1. the stock is the same whenever the module arrives: 229, 224, 219 unbid statements, because the stock stops growing once the pot is gone (day 7) and about one a day sells. the exit takes the whole stock at the first hour.
2. what it is worth depends on the exitToken price only. exit value over cost is 0.15 at 5e-6, 0.59 at 2e-5, 0.88 at 3e-5 and 1.47 at 5e-5. below 3.3e-5 the exit gives back less than the 90 percent reserve.
3. the exit feeds the engine. an exit puts 50 percent of the exitToken in the exit bid pot (`exitToBuybackBps`), which buys credits through the exit lane. at 1e-5 that bought 8,467 credits by day 90 when the module arrives on day 14 (the exit bid pays by score, so it buys the high score credits first) and lifted credits acquired from 27,100 to 33,800, 25 percent. at 5e-5 and 1e-4 the pot is so large the bid sits at its floor and still buys 38,000 to 73,000 credits, more than the float, so read these as an upper bound. later arrival gives less because less time remains: 9,263 at day 14, 7,345 at day 30, 3,747 at day 60 for 3e-5.
4. exit bid pace: the bid climbs 100 bps an hour while its pot affords one average credit, so it reaches 9,700 bps in a day or two when the price is low (5e-6, 1e-5) and sits near its 3,000 floor when the pot is large against the price (3e-5 and up), where each credit bought drops it 20 bps.
5. the exitToken dutch auction runs at a pace of one slice per half life by design: about 270 fills in 76 days at 6 hours each, mean 15 percent all in discount to the pool price at the taker threshold. a slice is 20 average credits of exitToken, 0.26 eth of value at 3e-5. one slice per 6 hours is about 1 eth of exitToken a day. the exit of 229 statements puts about 118 eth of exitToken in the auction pot at 3e-5, and 46 eth of it is still waiting at day 90. a large exit batch waits months for the auction. a larger `exitSliceCredits` or a shorter `xAuctionHalfLife` is the dial.
6. a keeper that exits only when the module pays at least the reserve (instead of at once) exits nothing at 1e-5 and sells 124 statements by day 90 against 98 when it exits at once. `exitStatement` is permissionless, so at a low exitToken price anyone can force the exit of listings that a buyer would still have bought. the owner controls this only through `exitAfter` and the moment the exitModule is set.

## 9. sensitivity ranking

low and high value of each input against the base case (27,110 credits and 339 statements at day 90, 121 sold, 31 eth burned). statements created move by the same share as credits, because 80 credits make one statement. ranked by the swing in credits.

| rank | input | low | high | credits low | credits high | swing | statements sold low | statements sold high |
|---|---|---|---|---|---|---|---|---|
| 1 | coin volume scale | 0.25 | 4 | 13,970 | 54,830 | 151% | 126 | 152 |
| 2 | flat credit price | 0.0045 | 0.018 | 40,230 | 17,670 | 83% | 130 | 116 |
| 3 | seller offers an hour | 60 | 400 | 21,280 | 33,610 | 45% | 94 | 162 |
| 4 | `saleToBuybackBps` | 0 | 10000 | 34,920 | 23,280 | 43% | 189 | 105 |
| 5 | engine price impact | 0 | 0.3 | 31,340 | 22,450 | 33% | 134 | 113 |
| 6 | `dropBps` | 500 | 4000 | 21,260 | 28,920 | 28% | 82 | 131 |
| 7 | `flatBps` | 0 | 10000 | 21,350 | 27,160 | 21% | 91 | 124 |
| 8 | buyer pick rule | cheapest | random | 27,160 | 32,230 | 19% | 124 | 220 |
| 9 | `climbBaseBps` | 50 | 200 | 30,310 | 25,340 | 18% | 131 | 132 |
| 10 | anti sniper volume share | 0.2 | 0.6 | 24,970 | 29,420 | 16% | 128 | 124 |
| 11 | credit price path | decline | recovery | 28,940 | 25,420 | 13% | 112 | 168 |
| 12 | statement willingness to pay | 0.7x | 1.3x | 25,300 | 28,700 | 13% | 80 | 156 |
| 13 | seller book churn | 0.02 | 0.15 | 29,440 | 26,110 | 12% | 149 | 112 |
| 14 | statement buyers a day | 3 | 20 | 26,280 | 29,410 | 12% | 96 | 178 |
| 15 | listed share of offers | 0 | 0.5 | 27,160 | 29,730 | 9% | 124 | 135 |
| 16 | seller ask spread | 0.15 | 0.4 | 26,220 | 28,180 | 7% | 108 | 138 |
| 17 | `auctionDuration` | 6h | 72h | 28,200 | 26,910 | 5% | 151 | 110 |
| 18 | `spendCapBps` | 1000 | 4000 | 26,970 | 27,730 | 3% | 122 | 135 |
| 19 | `reserveBps` | 5000 | 12000 | 27,320 | 27,460 | 1% | 178 | 106 |
| 20 | `rateStart` | 25% | 100% | 26,770 | 27,020 | 1% | 117 | 128 |
| 21 | `exitAfter`, net coin flow | any | any | 27,160 | 27,160 | 0% | 124 | 124 |

1. credits acquired follow the money (coin volume), the price of a credit and the supply of sellers. these are not settings.
2. of the settings only four matter for credits: `saleToBuybackBps`, `dropBps`, `flatBps`, `climbBaseBps`. `saleToBuybackBps` is the biggest, and it is the owner's choice between burn and credits.
3. for statements sold the order is different: the buyer rules, willingness to pay, buyers a day, `saleToBuybackBps` (through credits), then `reserveBps` (178 to 106) and `auctionDuration`.
4. `rateStart`, `reserveBps`, `spendCapBps` and `exitAfter` do not move credits acquired or statements created at day 90.

## 10. what the model cannot tell us, and its weakest assumptions

1. the ask distribution. only fills are visible, not asks. the cheap tail of sellers (lognormal spread 0.27) sets how cheap the first credits are and how fast the price climbs. a thinner tail means the engine overpays from the first fill. the engine pays its bid to every seller that clears, so the first fill price is a bid, not an ask.
2. statement demand and buyer behaviour. 42 priced sales over 5 days, all at fixed prices, none at auction. arrivals are fixed at 8 a day decaying to 2 and **do not respond to the reserve**, so a lower reserve in the model only sells to the same buyers. in reality a cheaper statement may draw more. buyers bid once, at the minimum, with no sniping and no defence bids, and the pick rule decides the second bidder share (7 percent when buyers pick any, 34 percent when they pick the cheapest). willingness to pay is rating insensitive in phase 1 and that may change once the exitModule pays by rating.
3. the coin net flow. buy share after day one (0.46) drives the coin price and so the percent of supply burned. volume is exogenous, so buybacks and statement sales do not draw volume.
4. the engine's own footprint. price impact elasticity 0.12 is a guess. credits acquired swing 33 percent between no impact and 0.3. the lift also raises statement willingness to pay in the model.
5. seller supply and the float. 150 offers an hour, 5 percent leave an hour, more when the bid is above market, a float of 96,800 credits that credits burned into statements never come back to. no whale seller, no strategy relist at 1.2x, no competing protocol bid like the fwa hub at 0.029 flat. at 50 eth a day the engine buys 71 percent of the float and at 150 eth a day all of it.
6. the anti sniper volume (40 percent of hour one volume inside 30 minutes) is inferred from the comparable's implied 406 eth against 194 eth at a flat 10 percent. 86 percent of fees come on day one, so the starting pot is the biggest input and the least observed. credits acquired swing 16 percent across 20 to 60 percent.
7. phase 2 is parametric. the exitToken price per point is a constant, the module pays exactly `rating * unitPerPoint`, a keeper exits every eligible listing at once, takers fill exactly at their threshold, credit sellers compare exit bids with no friction, and the exit bid buying 38,000 to 73,000 credits at high prices ignores the float.
8. keepers. `collectSales` runs every hour, `endAuction` is called the moment an auction ends, `repriceStatement` is called on every unbid listing when `reserveBps` changes, the buyback keeper runs every 25 blocks, nobody sandwiches the 1 eth buyback, no wash volume (71 percent of the comparable's pool volume was churn and the model treats it as organic fee base). a house delivery failure (30 day unwind) is not modelled.
9. the launch day market price. the opening limit is a share of the market price on launch day. the model holds that price at 0.0089 eth (or its path). a different price on the day moves the rate with it, which is why the limit is set on launch day.
10. the owner. the model has one change at a time at a known day. a real owner reacts to signals and may change several settings at once, which the Core allows.

## recommended launch settings

| setting | launch value | recommendation | why |
|---|---|---|---|
| `rateStart` | 1.54e13 (75% of market) | keep | on the plateau for total credits, buys at once, first 80 cost 0.74x. 90% gets 35% more by day 3 for 15 points on the first 80 |
| `flatBps` | 10000 | keep | most credits and statements. a blend of 7500 later buys 17% more score for 1% of credits |
| `avgScore` | 4,330,000 | keep | the population mean is 440 points, flat buys 428 |
| `reserveBps` | 9000 | keep, cut on day 7 to 14 | credits unaffected. at launch volume 6000 sells 35% more statements at the same burn. a cut on day 14 beats a cut at launch |
| `auctionDuration` | 24 hours | keep | no effect under random pick, a few percent under cheapest pick |
| `saleToBuybackBps` | 5000 | keep for the first week | no effect on week one. decide on day 7 to 14, it is the largest lever left |
| `dropBps` | 2000 | keep | 3000 gives 3% more credits by day 14 and 8% fewer on day 3 |
| `climbBaseBps` | 100 | keep | the biggest pace dial. 200 is earlier and dearer, 50 later and cheaper |
| `spendCapBps` | 2000 | keep | a guard. blocks 18 hours in 90 days. at most 5000 |
| `rateCap` | 1.232e14 | keep | 8 times `rateStart`. never reached at launch values (the climb is clamped by the pot first). it is the owner's "never pay more than this per credit" |
| `exitAfter` | 72 hours | keep | no effect before phase 2 |
| `exitToBuybackBps` and exitToken settings | as launched | keep | phase 2 only. the auction pace is slow (1 slice per 6 hours) |

## settings the owner should expect to adjust, and the signal

| setting | expected move | signal to watch |
|---|---|---|
| `reserveBps` | 9000 to 6000 or 7000, then `repriceStatement` on the backlog | unbid listings older than 3 days above 100 and fewer than one sale a day |
| `saleToBuybackBps` | toward the pot if credits matter more than burn, toward the buyback if burn does | credits a day after the pot is spent under 50 at launch volume, eth spent buying coin per day |
| `climbBaseBps`, `dropBps` | raise `dropBps` or lower `climbBaseBps` | price paid over market above 1.15x, the bid above 130% of market for more than a day |
| `setRate` | reset the limit | the market price of a credit moves 30% from the launch day value in week one, or the pot sits unspent for days with the bid under market |
| `flatBps` | 7500 | credits flowing steadily and the average score bought below the population mean of 440 |
| `exitSliceCredits`, `xAuctionHalfLife` | larger slice or shorter half life | exitToken waiting for the auction above 30 days of slices after phase 2 |
| `exitAfter` | longer, if the exitToken price is below the break even of about 3.3e-5 per point | exitToken price per point against 1.18 eth over a 35,200 point statement |
| `auctionDuration` | longer | second bids above 40 percent of sales with prices over the reserve |

## files

sim/engine.js (model, the single source), sim/engine.test.mjs (254 checks), sim/run.mjs (batches, node run.mjs q1 to q11), sim/results/*.json, sim/build.mjs and the page parts (page.css, page.body.html, page.ui1.js to page.ui4.js), sim/index.html (built, single file).
