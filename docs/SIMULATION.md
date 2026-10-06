# simulation of the credits engine

sim/engine.js is a deterministic hourly model of the engine in src/Core.sol (rate climb tiers, funded clamp, drop on fill, hourly cap, both doors, compose, statement auction, buyback, exit lane, exitToken bid, dutch auction). the launch position is real concentrated liquidity math. sellers, statement buyers and coin volume are calibrated on the 13 day data pull in sim/data/notes.md. every number below is a mean over 3 to 5 seeds of a 90 day run unless stated. raw rows are in sim/results/*.json, the interactive page is sim/index.html. `exitModule` and `exitToken` are the only names used for phase 2.

verdict in one paragraph: **the phase 1 loop does not turn on today's market.** about 295 eth of fees arrive, 86 percent of them on day one. the engine spends all of it on credits by day 12 at 1.43x the flat market price per credit, composes about 240 statements at a cost basis near 1.3 eth, and buyers who pay 0.84x of parts cost show up at 8 a day and then fewer. about 50 statements sell, 187 sit at the floor, 283 eth is locked, and 5.8 percent of supply is burned from 19 eth of buyback. the cause is not the starting rate. it is the price the engine pays per credit against what statement buyers will pay, plus a pot that is spent far faster than statements can be sold.

## model in short

| piece | what it does | calibration |
|---|---|---|
| coin market | exogenous daily volume, buy share, skim 10 percent with 9.5 points to the pot, anti sniper 90 to 10 percent over 30 minutes, single sided position tick -175000 to 887200 | model price after day one 4.48e-7, observed 4.44e-7 |
| credit sellers | uniform scores 80 to 800, flat ask per credit with lognormal spread 0.27, top tier premium above 740, 150 offers an hour, 5 percent leave an hour, more offers when the bid is above market | median 0.0089 eth, p10 0.0069, p90 0.0138 |
| doors | sell door pays score times rate for any credit whose ceiling clears its ask, cheapest ask per point first. CreditStrategy listings clear through the listing door with the tip | 13,132 listings at median 0.036 eth |
| statements | arrivals 8 a day decaying to 2, willingness to pay as a multiple of 80 times the flat price, rating insensitive | median 0.84, 21 percent at 1.2 or more, max 1.32 |
| engine to market feedback | engine spend lifts the flat price, elasticity 0.12, half life 48 hours, cap 3x | assumption |
| phase 2 | exitModule pays rating times unitPerPoint, exit lane, exitToken bid, dutch auction, takers fill at a set discount | assumption |

port checks: node engine.test.mjs runs 86 numeric checks against hand computed Core values (climb tiers 1, 2, 4, 8 percent an hour, the funded clamp, drop on fill, hourly cap, auction curve 4x to 1.2x, exit auction half life, tip rule, pool round trip) and an eth accounting identity over whole runs.

## 1. does the phase 1 loop turn

| preset | day | eth into pot (fees) | credits bought | composed | sold | stuck at floor | eth returned to pot | eth to buyback | coin burned (m) | percent of supply | eth locked | pot now |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| comparable decay | 30 | 292 | 17,520 | 219 | 30.2 | 187 | 12.8 | 12.8 | 40.6 | 4.06% | 284 | 0.0352 |
|  | 60 | 293 | 18,270 | 228 | 39.6 | 187 | 15.7 | 15.7 | 49.1 | 4.91% | 283 | 0.0822 |
|  | 90 | 295 | 19,080 | 238 | 49.6 | 187 | 18.9 | 18.9 | 57.9 | 5.79% | 283 | 0.0675 |
| sustained 17 eth a day | 30 | 303 | 20,620 | 257 | 38.8 | 208 | 15.8 | 15.8 | 28.0 | 2.80% | 292 | 1.00 |
|  | 60 | 352 | 28,240 | 353 | 62.8 | 280 | 24.3 | 24.3 | 40.6 | 4.06% | 336 | 0.845 |
|  | 90 | 402 | 35,660 | 445 | 82.0 | 354 | 31.1 | 31.1 | 49.5 | 4.95% | 380 | 0.652 |
| sustained 50 eth a day | 30 | 394 | 26,880 | 336 | 36.4 | 278 | 15.6 | 15.6 | 27.8 | 2.78% | 382 | 1.87 |
|  | 60 | 537 | 43,270 | 540 | 49.4 | 470 | 21.1 | 21.1 | 36.1 | 3.61% | 521 | 2.11 |
|  | 90 | 680 | 59,660 | 745 | 61.6 | 663 | 26.2 | 26.2 | 43.2 | 4.32% | 661 | 2.05 |
| dead after week one | 30 | 285 | 16,990 | 212 | 26.8 | 185 | 11.5 | 11.5 | 34.5 | 3.44% | 278 | 0.0328 |
|  | 60 | 286 | 17,330 | 216 | 31.2 | 185 | 13.0 | 13.0 | 38.5 | 3.85% | 278 | 0.0221 |
|  | 90 | 287 | 17,630 | 220 | 35.0 | 184 | 14.3 | 14.3 | 41.8 | 4.18% | 278 | 0.0241 |

no. under every preset it stalls. the loop is: fees fill the pot, the pot buys credits, 80 credits become a statement, the statement sells for at least 1.2x cost, half returns to the pot and half buys coin. it breaks at the sale step. the pot is under 1 eth by day 11.6 (comparable) to 12.4 (sustained 50), and everything it held is now in statements nobody buys at the floor.

why it stalls, in order of weight:

1. price. the engine's cost per credit is 1.43x the flat price (1.17x under sustained volume where the market lifts), so a statement costs 1.32 eth against a parts market cost of 0.71 eth. buyers pay a median 0.84x of parts cost, 0.6 eth. the floor is 1.2x cost, 1.58 eth. no observed buyer paid more than 1.32x of parts cost, so the floor clears for none of them.
2. pace. 255 of the 295 eth arrive in the first day (sniper window plus launch volume). the bid climbs 1 percent an hour from 4e12, reaches the market around day 7, and the pot is spent between day 7 and day 12: about 16,000 credits in six days. buyers absorb 5 to 8 statements a day. the engine composes 40 a day.
3. demand is a hard ceiling. 271 statement buyers arrive in 90 days under the base case and 221 of them find no price they accept. even a free floor cannot sell more statements than there are buyers.
4. sustained volume does not fix it. at 17 eth a day fees reach 402 eth but stuck statements reach 354, because sales stay near 80. at 50 eth a day 663 statements are stuck and 661 eth is locked.

burn: 19 eth to buyback (comparable) buys 58m coin, 5.8 percent of supply, because the pool price sits near 3e-7. the percent of supply depends on the coin price path more than on the engine (section 8). burn only ever comes from statement sales, so no sales means no burn.

eth recycled: sales return 0.12 eth per eth spent on credits.

## 2. the starting rate

at today's flat price of 0.0089 eth. m is rateStart times 800 over the flat price in wei, so m = 1 is the rate at which an 800 point credit clears at the flat price.

| rateStart | m | hours to first fill | hours to first 80 credits | first 80 cost over market | average score of first 80 | statements sold by day 90 | percent of supply burned | all credits cost over market |
|---|---|---|---|---|---|---|---|---|
| 1.00e12 | 0.0899 | 70.0 | 127 | 0.608 | 695 | 51.0 | 6.06 | 1.42 |
| 2.00e12 | 0.18 | 52.3 | 111 | 0.601 | 691 | 46.0 | 5.39 | 1.42 |
| 3.00e12 | 0.27 | 38.0 | 92.0 | 0.604 | 692 | 46.3 | 5.58 | 1.44 |
| 4.00e12 | 0.36 | 22.3 | 74.3 | 0.609 | 703 | 50.7 | 5.93 | 1.43 |
| 6.00e12 | 0.539 | 0.0333 | 37.7 | 0.615 | 694 | 48.0 | 5.40 | 1.42 |
| 8.00e12 | 0.719 | 0.0333 | 10.0 | 0.643 | 693 | 58.0 | 6.26 | 1.40 |
| 1.00e13 | 0.899 | 0.0333 | 0.0333 | 0.768 | 687 | 63.7 | 6.67 | 1.38 |
| 1.50e13 | 1.35 | 0.0333 | 0.0333 | 1.15 | 687 | 57.7 | 6.18 | 1.40 |
| 2.00e13 | 1.80 | 0.0333 | 2.00 | 1.53 | 686 | 54.0 | 5.86 | 1.43 |
| 3.00e13 | 2.70 | 0.0333 | 2.00 | 2.30 | 688 | 62.3 | 6.53 | 1.48 |

reading it:

1. the first fills are the cheapest sellers at the highest scores. the engine pays score times rate, so an 800 point credit with an ask 40 percent under the median clears first, and the engine pays about 0.6x of market for its first 80 credits at an average score of 693. below m = 0.5 that price is the same and only the wait grows (22 hours at 4e12, 70 hours at 1e12).
2. above m = 0.75 the engine starts paying full price. at m = 1 the first 80 cost 0.85x, at m = 1.35 they cost 1.15x, at 3e13 they cost 2.3x. a rate above the market buys the first 80 credits in two minutes but at a premium to the flat price.
3. downstream results do not depend on it. statements sold by day 90 range 46 to 64 and percent burned 5.4 to 6.7 across the whole sweep, within seed noise. rateStart sets only how soon the pot starts working, because the pot is large either way.
4. at m = 0.5 the first fill lands inside the anti sniper window and the first 80 credits are done after 45 hours.

recommendation: **rateStart = 5.6e12 for launch at 0.0089.** rule for launch day: rateStart = flat credit price in wei divided by 1600, which is m = 0.5, half the rate at which an 800 point credit clears at the flat price. the flat price is the median over the last 24 hours of seaport fills. never go above price over 800 (m = 1). the sweep was repeated at flat prices of 0.0045, 0.018 and 0.03 and the same m gives the same first 80 cost ratio at the first three prices (0.61, 0.61, 0.61 at m = 0.5), 0.54 at 0.03, so the rule scales with price. the current default 4e12 is m = 0.36 and also safe, it only waits 22 hours.

## 3. per point bid against the flat market

the market prices a credit flat in score. the engine pays score times rate. the model has sellers who clear when score times rate reaches their flat ask, so the cheapest ask per point sells first, which means high scores.

| metric | per point bid (the Core) | flat per credit counterfactual | per point, no price impact | per point, half the offers are listings | per point, declining market |
|---|---|---|---|---|---|
| average score bought (population 440) | 594 | 428 | 580 | 594 | 589 |
| cost per credit over flat price | 1.43 | 1.09 | 1.51 | 1.22 | 1.53 |
| cost per point over market per point | 1.06 | 1.12 | 1.15 | 0.903 | 1.14 |
| cost over what sellers asked | 1.50 | 1.28 | 1.64 | 1.28 | 1.60 |
| average statement cost basis, eth | 1.32 | 1.00 | 1.09 | 1.12 | 1.07 |
| average statement rating, points | 47,470 | 34,240 | 46,400 | 47,480 | 47,090 |
| statements composed | 238 | 327 | 291 | 285 | 286 |
| statements sold | 49.6 | 98.6 | 65.2 | 68.2 | 54.4 |
| stuck at floor | 187 | 226 | 225 | 215 | 230 |
| percent of supply burned | 5.79 | 8.90 | 6.81 | 7.15 | 3.69 |
| first 80 cost over market | 0.608 | 0.519 | 0.605 | 0.597 | 0.605 |

who sells, by score bin, whole run (comparable decay):

| score bin | credits bought | average price paid, eth |
|---|---|---|
| 80 to 152 | 0.8 | 0.00553 |
| 152 to 224 | 35.0 | 0.00745 |
| 224 to 296 | 325 | 0.00937 |
| 296 to 368 | 969 | 0.0114 |
| 368 to 440 | 1,685 | 0.0132 |
| 440 to 512 | 2,351 | 0.0143 |
| 512 to 584 | 2,886 | 0.0154 |
| 584 to 656 | 3,329 | 0.0168 |
| 656 to 728 | 3,867 | 0.0175 |
| 728 to 800 | 3,636 | 0.0199 |

the score frontier (the lowest score a median ask seller can sell at) and the average score bought:

| day | frontier score | average score bought that day | bid over market (440 point credit) |
|---|---|---|---|
| 1 | 900 | 726 | 0.251 |
| 3 | 900 | 700 | 0.404 |
| 5 | 691 | 666 | 0.637 |
| 7 | 468 | 608 | 0.94 |
| 10 | 339 | 563 | 1.30 |
| 12 | 426 | 600 | 1.03 |
| 14 | 548 | 672 | 0.803 |
| 20 | 859 | 520 | 0.512 |
| 30 | 900 | 505 | 0.476 |

what it says:

1. adverse selection is real and expensive. the engine's average credit scores 594 against 440 in the population and it pays 1.43x the flat price per credit. a 728 to 800 point credit costs 0.0199 eth, a 152 to 224 credit 0.0074. the market pays the same for both.
2. it wins early and loses later. the first 80 credits cost 0.61x of market because only cheap asks clear. once the cheap tail is gone the bid has to climb to the ask of a typical seller, and every seller above 440 points is overpaid by score over 440.
3. per point it roughly breaks even (1.06x market per point). but a point is worth nothing in phase 1: statement price is flat in rating (r2 0.03). so the engine buys points it cannot sell. its statements rate 47,500 against 35,200 for a random 80, and sell for the same price.
4. a flat per credit bid (pay 433 points of rate for any credit) costs 1.09x instead of 1.43x, composes 327 statements and sells 99 instead of 50, burn 8.9 percent instead of 5.8. statement cost basis falls from 1.32 to 1.00 eth.
5. the cost of that: a flat bid stops accumulating rating, 34,200 per statement against 47,500. that rating matters only if the exitModule pays by rating, which it does in phase 2 (rating times unitPerPoint). so the per point bid is a phase 2 asset bought with phase 1 eth. decide with the exitToken price in hand (section 7).
6. if half the offers are visible listings that keepers take through buyListing at the ask, cost per credit drops to 1.22x and sold rises to 68. the listing door is the cheaper door, and keepers will route to it where they can. the model's default (listed share 0) is the sell door only, as specified.

## 4. statement auction parameters

what the current setting does with the observed 0.84 median. the price starts at 4x of cost and falls linearly to 1.2x over 72 hours, then stays at 1.2x. a buyer who values the statement at w times its parts market cost buys at the first moment the price is at or under w times parts cost. so the statement clears only when w is at least 1.2 times the engine's cost basis over parts cost, and the 4x start matters for no buyer (none above 1.32). share of observed buyers that clear, by the engine's cost basis as a multiple of the parts market cost:

| cost basis over market | floor 1.2x | floor 1.0x | floor 0.8x | floor 0.6x | start 4x |
|---|---|---|---|---|---|
| 0.6 | 73% | 82% | 90% | 95% | 0% |
| 0.7 | 50% | 76% | 85% | 93% | 0% |
| 0.8 | 37% | 58% | 80% | 90% | 0% |
| 0.9 | 25% | 43% | 73% | 86% | 0% |
| 1 | 21% | 33% | 58% | 82% | 0% |
| 1.2 | 0% | 21% | 37% | 73% | 0% |
| 1.4 | 0% | 0% | 23% | 50% | 0% |
| 1.6 | 0% | 0% | 4% | 37% | 0% |

at cost basis equal to the market, 1.2x clears for 21 percent of buyers, which matches the observed 21 percent that reached 1.2x. at the median buyer (0.84) the engine would need a cost basis of 0.70x of market. at the sim's cost basis of 1.43x it clears for nobody, which is the 187 stuck statements.

sweep of start multiple and floor multiple, 72 hours, 90 days:

| start | floor | composed | sold | stuck | eth locked | eth returned to pot | coin burned (m) | percent of supply | sale price over cost | pot |
|---|---|---|---|---|---|---|---|---|---|---|
| 4 | 1.2 | 239 | 50.7 | 187 | 283 | 19.5 | 59.3 | 5.93 | 1.25 | 0.0953 |
| 4 | 1 | 254 | 75.3 | 177 | 274 | 26.1 | 75.3 | 7.53 | 1.10 | 0.0317 |
| 4 | 0.8 | 264 | 105 | 158 | 257 | 32.6 | 89.0 | 8.90 | 0.905 | 0.071 |
| 4 | 0.6 | 276 | 141 | 133 | 226 | 36.9 | 97.7 | 9.77 | 0.69 | 0.0283 |
| 3 | 1.2 | 243 | 53.3 | 188 | 284 | 20.0 | 61.0 | 6.10 | 1.28 | 0.135 |
| 3 | 1 | 252 | 74.0 | 177 | 275 | 25.7 | 74.2 | 7.42 | 1.11 | 0.0749 |
| 3 | 0.8 | 272 | 114 | 157 | 255 | 36.3 | 96.2 | 9.62 | 0.935 | 0.0673 |
| 3 | 0.6 | 278 | 143 | 133 | 227 | 39.2 | 101 | 10.1 | 0.717 | 0.0496 |
| 2.5 | 1.2 | 244 | 53.7 | 189 | 284 | 20.6 | 62.3 | 6.23 | 1.32 | 0.0376 |
| 2.5 | 1 | 255 | 77.0 | 177 | 275 | 27.2 | 77.4 | 7.74 | 1.14 | 0.0364 |
| 2.5 | 0.8 | 269 | 110 | 158 | 257 | 35.8 | 94.9 | 9.49 | 0.952 | 0.145 |
| 2.5 | 0.6 | 282 | 152 | 129 | 222 | 41.4 | 106 | 10.6 | 0.717 | 0.166 |
| 2 | 1.2 | 249 | 57.7 | 190 | 285 | 22.4 | 66.9 | 6.69 | 1.37 | 0.0431 |
| 2 | 1 | 254 | 76.0 | 177 | 275 | 27.6 | 77.6 | 7.76 | 1.15 | 0.0292 |
| 2 | 0.8 | 271 | 112 | 158 | 257 | 37.0 | 97.0 | 9.71 | 0.965 | 0.0675 |
| 2 | 0.6 | 276 | 139 | 136 | 231 | 38.7 | 100 | 10.0 | 0.742 | 0.0473 |
| 1.5 | 1.2 | 248 | 60.7 | 187 | 283 | 23.4 | 68.2 | 6.82 | 1.30 | 0.101 |
| 1.5 | 1 | 259 | 80.0 | 179 | 275 | 28.7 | 80.2 | 8.02 | 1.18 | 0.302 |
| 1.5 | 0.8 | 270 | 106 | 163 | 261 | 34.9 | 92.6 | 9.26 | 0.991 | 0.0634 |
| 1.5 | 0.6 | 276 | 137 | 139 | 234 | 39.4 | 101 | 10.1 | 0.777 | 0.336 |

length sweep, two settings:

| length hours | start and floor | composed | sold | stuck | eth locked | percent burned |
|---|---|---|---|---|---|---|
| 12 | 4x and 1.2x | 237 | 51.0 | 186 | 282 | 5.71 |
| 12 | 2x and 0.8x | 256 | 103 | 153 | 252 | 8.46 |
| 24 | 4x and 1.2x | 237 | 47.0 | 190 | 284 | 5.22 |
| 24 | 2x and 0.8x | 264 | 111 | 153 | 252 | 9.23 |
| 72 | 4x and 1.2x | 239 | 50.7 | 187 | 283 | 5.93 |
| 72 | 2x and 0.8x | 271 | 112 | 158 | 257 | 9.71 |
| 168 | 4x and 1.2x | 249 | 54.7 | 192 | 285 | 6.39 |
| 168 | 2x and 0.8x | 269 | 100 | 166 | 265 | 9.37 |
| 336 | 4x and 1.2x | 255 | 53.3 | 193 | 286 | 6.31 |
| 336 | 2x and 0.8x | 271 | 91.7 | 175 | 272 | 9.07 |

reading it:

1. the floor is the lever, the start is not. start 4x to 1.5x moves sold from 51 to 61. floor 1.2x to 1.0x to 0.8x to 0.6x moves sold 51, 75, 105, 141 and burn 5.9, 7.5, 8.9, 9.8 percent.
2. no setting clears the inventory. the best cell (floor 0.6x) still leaves 133 stuck and 226 eth locked, because 271 buyers arrive in 90 days and the engine composes 276. clearing needs fewer statements, not a lower price (section 9).
3. a floor under 1.0x sells below cost basis. at 0.8x the average sale is 0.9x of cost, at 0.6x it is 0.69x. what it buys is recycling: eth returned to the pot goes 19.5, 26.1, 32.6, 36.9 eth, buyback the same. the unsold alternative returns nothing.
4. length is nearly irrelevant. 12 hours to 336 hours moves sold within 47 to 55 at 4x and 1.2x, 92 to 112 at 2x and 0.8x. a long auction slightly delays recycling.
5. with floor under 1.0 the invariant in SPEC section 10 (no statement sold under 1.2x cost) is gone. that is a deliberate change of a Core constant and its invariant test.

## 5. the funded rule

old rule: the pot affords one average credit, no clamp on the climb. new rule: 20 percent of the pot affords one average credit, climb clamped where it stops. overshoot is the peak of bid rate over the market rate for a 440 point credit.

| scenario | rule | peak bid over market | hours above 1.5x | credits bought | sold | longest stall, hours | hours at the clamp |
|---|---|---|---|---|---|---|---|
| base case | old | 17.4 | 882 | 18,070 | 38.0 | 30.3 | 0 |
|  | new | 1.30 | 0 | 19,130 | 50.7 | 11.3 | 1.67 |
| small pot (volume x0.03) | old | 7.50 | 1,241 | 3,465 | 42.3 | 408 | 0 |
|  | new | 0.596 | 0 | 3,799 | 46.7 | 117 | 199 |
| tiny pot (17 eth a day x0.005) | old | 10.8 | 1,827 | 476 | 4.67 | 126 | 0 |
|  | new | 0.57 | 0 | 954 | 11.0 | 56.0 | 24.0 |
| credit price recovery | old | 3.68 | 286 | 16,870 | 93.0 | 22.7 | 0 |
|  | new | 1.08 | 0 | 17,770 | 102 | 17.7 | 6.33 |
| continued decline | old | 1.45 | 0 | 23,040 | 56.7 | 12.0 | 0 |
|  | new | 1.45 | 0 | 22,930 | 54.3 | 12.0 | 0 |
| sustained 50 eth a day | old | 1.30 | 0 | 59,590 | 61.0 | 9.67 | 0 |
|  | new | 1.30 | 0 | 59,590 | 61.0 | 9.67 | 0 |
| rateStart 1e12 | old | 17.4 | 1,363 | 17,550 | 31.0 | 25.7 | 0 |
|  | new | 1.30 | 0 | 19,170 | 51.0 | 12.3 | 2.67 |
| no engine price impact | old | 1.72 | 41.0 | 23,050 | 60.3 | 10.3 | 0 |
|  | new | 1.72 | 41.0 | 23,160 | 62.7 | 10.3 | 0 |

1. the old rule overshoots wherever the pot is small against the credit price: peak 17x market in the base case once the pot has drained (882 hours above 1.5x), 7.5x with a small pot, 3.7x if the credit price recovers. the new rule peaks at 1.3x, 0.6x and 1.1x.
2. the mechanism: with the pot at 0.02 eth the old rule still calls it funded, the rate climbs to 8 percent an hour with no fill, and the hourly cap (20 percent of the pot) then blocks every credit above a cheap one. the bid is far above the market and nothing can sell into it. the new clamp holds the bid where 20 percent of the pot affords an average credit.
3. new rule costs: in a small pot regime the bid sits at 0.6x of market and the engine buys only the cheap tail. that is not a defect. it paid 0.75x of market and sold 47 of 47 statements (burn 33 percent of supply, because the pot was small and the coin price low).
4. with a rich pot (sustained 50, decline) the two rules give the same result. the new rule is never worse. keep it.

## 6. hourly cap, climb and drop constants

base case: the hourly cap blocked at least one clearing sale in 1,775 of 2,160 hours, but only 4.20 of those hours had a pot above 5 eth. longest stretch with no purchase after the first fill: 11.2 hours. the rate makes 955 direction changes in 90 days with a mean move of 0.86 percent an hour.

1. the cap is a small pot effect. while the pot is rich (days 1 to 12) it never binds: 150 offers an hour at 0.015 eth is 2 eth an hour against a cap of 50 eth. once the pot is 0.02 eth the cap is 0.004 eth and sits under the price of one credit, so a clearing sale waits for fees to arrive. that is design item 8 in ARCHITECTURE and it behaves as described.
2. CLIMB_MAX_BPS_PER_HOUR never binds. after the first fill the doubling clock restarts every hour a purchase happens, and no stall in the base case reaches 72 hours. sweeping it from 200 to 1600 changes nothing. it only matters in a dead market, where it governs how fast the bid finds the first seller.
3. DROP_BPS scales with the share of the pot spent. with a pot of 250 eth a 0.015 eth purchase drops the rate by 0.0006 percent. the bid is undamped until the pot is nearly gone. that is why the engine spends the whole pot in about six days and why the rate rides up to 1.3x of market. the drop works only when the pot is small.
4. oscillation is a small sawtooth: a 1 percent climb against drop, about 0.9 percent an hour, with no growth. no limit cycle of any size.
5. the constants sit at the edge of a stable region. a weaker drop (500), faster climb (200 bps) or lower cap (1000) each push the bid to 3.5x of market and cut sales roughly in half. a stronger drop (2000) or a higher cap (4000) improve cost and sales.

DROP_BPS:

| value | peak bid over market | cap hours | clamp hours | direction changes | sold | stuck | percent burned | cost over market | longest stall h |
|---|---|---|---|---|---|---|---|---|---|
| 250 | 3.64 | 1,842 | 21.7 | 42.7 | 27.0 | 180 | 3.71 | 1.56 | 26.0 |
| 500 | 3.48 | 1,853 | 34.3 | 96.3 | 30.7 | 181 | 4.18 | 1.54 | 26.3 |
| 1000 | 1.30 | 1,767 | 1.67 | 958 | 50.7 | 187 | 5.93 | 1.43 | 11.3 |
| 2000 | 1.26 | 68.7 | 0 | 518 | 65.7 | 194 | 7.05 | 1.34 | 9.67 |
| 4000 | 1.19 | 0 | 0 | 623 | 65.7 | 209 | 7.09 | 1.29 | 9.67 |

CLIMB_BASE_BPS_PER_HOUR:

| value | peak bid over market | cap hours | clamp hours | direction changes | sold | stuck | percent burned | cost over market | longest stall h |
|---|---|---|---|---|---|---|---|---|---|
| 50 | 1.14 | 229 | 0.333 | 291 | 62.7 | 223 | 6.84 | 1.27 | 23.3 |
| 100 | 1.30 | 1,767 | 1.67 | 958 | 50.7 | 187 | 5.93 | 1.43 | 11.3 |
| 200 | 3.48 | 1,956 | 70.0 | 177 | 24.0 | 157 | 3.19 | 1.71 | 25.7 |
| 400 | 10.8 | 2,077 | 158 | 148 | 19.7 | 134 | 2.68 | 1.97 | 27.3 |

SPEND_CAP_BPS_PER_HOUR:

| value | peak bid over market | cap hours | clamp hours | direction changes | sold | stuck | percent burned | cost over market | longest stall h |
|---|---|---|---|---|---|---|---|---|---|
| 500 | 3.79 | 1,479 | 121 | 38.3 | 26.7 | 181 | 3.66 | 1.58 | 38.3 |
| 1000 | 3.49 | 1,731 | 87.3 | 122 | 24.0 | 188 | 3.27 | 1.53 | 38.3 |
| 2000 | 1.30 | 1,767 | 1.67 | 958 | 50.7 | 187 | 5.93 | 1.43 | 11.3 |
| 4000 | 1.30 | 318 | 0.333 | 486 | 74.3 | 184 | 7.85 | 1.36 | 10.7 |
| 10000 | 1.30 | 0 | 0 | 476 | 67.0 | 187 | 7.13 | 1.37 | 15.7 |

small pot (volume x0.03), SPEND_CAP_BPS_PER_HOUR:

| cap | credits bought | sold | cost over market | longest stall h |
|---|---|---|---|---|
| 500 | 1,487 | 13.3 | 1.04 | 451 |
| 1000 | 3,048 | 37.3 | 0.888 | 155 |
| 2000 | 3,799 | 46.7 | 0.747 | 117 |
| 5000 | 4,065 | 50.0 | 0.728 | 93.0 |

## 7. phase 2

setup: module set on day 14, 182 statements are already past their auction by then. xp is the eth value of the exitToken paid per point of rating, so a statement of rating 47,500 exits for 47,500 times xp. exit is automatic once the auction has run its length. credit sellers choose the better of the eth bid and the exitToken bid.

where exiting beats the floor. exit value is rating times xp. the floor price is 1.2 times cost. exit wins when xp is above 1.2 times cost over rating.

| engine cost per statement | rating | xp where exit beats the floor | xp where exit just repays cost |
|---|---|---|---|
| 1.32 eth, per point bid base case | 47,500 | 3.3e-5 | 2.8e-5 |
| 1.00 eth, flat bid | 34,200 | 3.5e-5 | 2.9e-5 |
| 0.80 eth | 47,500 | 2.0e-5 | 1.7e-5 |
| 0.70 eth, cheap tail buying | 34,200 | 2.5e-5 | 2.0e-5 |

but the floor is a price only if a buyer shows up. in the base case it clears for 0 to 21 percent of buyers, so the expected floor value of the stuck inventory is near zero and exit wins at any xp. the comparison that binds is on credit buying: a median ask seller (0.0089 eth) takes the exitToken bid only when xRate times 440 times xp reaches the ask. that needs xp of 2.1e-5 at the 97 percent cap, 3.4e-5 at the 60 percent start, 6.7e-5 at the 30 percent floor.

full sweep, exit always on against never exiting:

| xp | eth lane sold | exited at the floor | stuck | eth locked | credits bought with exitToken | exit lane statements | bid pot end | waiting for dutch | burned by dutch (m) | percent burned | percent burned if never exit |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 5.00e-06 | 34.3 | 196 | 0 | 0.146 | 5.33 | 0 | 22.7 | 10.3 | 28.6 | 7.25% | 5.93% |
| 1.00e-05 | 34.7 | 299 | 0 | 0.328 | 8,501 | 106 | 47.2 | 19.8 | 52.5 | 9.59% | 5.93% |
| 1.50e-05 | 31.0 | 309 | 0 | 0.32 | 9,105 | 113 | 101 | 30.6 | 72.9 | 11.3% | 5.93% |
| 2.00e-05 | 31.3 | 311 | 0 | 0.503 | 9,182 | 114 | 156 | 41.4 | 89.6 | 13.0% | 5.93% |
| 3.00e-05 | 31.3 | 315 | 0 | 0.352 | 9,263 | 115 | 267 | 64.7 | 116 | 15.6% | 5.93% |
| 4.00e-05 | 29.3 | 584 | 0 | 0.376 | 31,080 | 388 | 763 | 81.1 | 137 | 17.6% | 6.01% |
| 6.00e-05 | 26.7 | 1,183 | 0 | 0.753 | 79,480 | 993 | 2,330 | 112 | 168 | 20.4% | 6.42% |
| 1.00e-04 | 26.7 | 1,188 | 0 | 1.78 | 79,610 | 995 | 3,507 | 197 | 201 | 23.8% | 6.54% |

1. below xp of about 1e-5 phase 2 does little. exits return 0.2 to 0.5 eth of value per statement against a cost of 1.3, the exit bid cannot buy credits (only 5 bought at 5e-6), and burn rises from 5.9 to 7.2 percent only because the 196 stuck statements feed the dutch auction.
2. between 1e-5 and 3e-5 the stuck inventory clears (locked eth falls from 283 to under 1) and burn reaches 9.6 to 15.6 percent. the exit lane starts: 106 to 115 exit lane statements built from 8,500 to 9,300 credits bought with exitToken.
3. above 4e-5 the exit bid runs at its floor of 30 percent, buys 31,000 to 80,000 credits and the bid pot compounds: an exit lane statement costs xRate times its rating in exitToken and returns the full rating, so every cycle grows the pot by 1 over xRate, 3.3x at the floor. the bid pot reaches 760 to 3,500 eth of value. that is a supply of exitToken the exitModule has to honour, so check unitPerPoint against exitToken supply before choosing the module.
4. the eth side is dead after exit. the eth pot stays under 0.2 eth, because exit returns no eth. phase 2 turns a locked eth inventory into exitToken claims, it does not refill the eth bid.
5. exiting also pre empts floor sales. eth lane sold falls from 51 to 27 to 35 because statements exit at 72 hours rather than waiting for a buyer. a keeper rule that exits only when rating times xp is at least the floor price keeps the floor option. that rule is an off chain policy because exitStatement is permissionless, so any caller can exit.

exit token bid dynamics (seed 1):

| xp | day | xRate bps | bid pot | waiting for dutch | credits bought | statements exited | percent burned | dutch fills |
|---|---|---|---|---|---|---|---|---|
| 1.00e-05 | 14.5 | 7,200 | 41.6 | 41.6 | 0 | 181 | 3.97 | 0 |
| 1.00e-05 | 15 | 8,340 | 41.8 | 41.9 | 3.00 | 182 | 3.97 | 0 |
| 1.00e-05 | 16 | 9,560 | 41.7 | 42.1 | 62.0 | 183 | 3.97 | 0 |
| 1.00e-05 | 18 | 9,620 | 42.2 | 42.6 | 231 | 187 | 3.99 | 1 |
| 1.00e-05 | 20 | 9,520 | 42.6 | 42.1 | 454 | 191 | 4.17 | 9 |
| 1.00e-05 | 25 | 9,560 | 42.7 | 40.4 | 1,033 | 198 | 4.59 | 29 |
| 1.00e-05 | 30 | 9,540 | 43.4 | 38.9 | 1,626 | 207 | 5.00 | 49 |
| 1.00e-05 | 45 | 9,320 | 43.7 | 33.6 | 3,334 | 228 | 6.43 | 109 |
| 1.00e-05 | 60 | 9,400 | 45.2 | 28.9 | 5,126 | 253 | 7.50 | 169 |
| 1.00e-05 | 90 | 9,660 | 47.1 | 19.3 | 8,644 | 300 | 9.55 | 288 |
| 3.00e-05 | 14.5 | 4,120 | 125 | 125 | 154 | 182 | 3.97 | 0 |
| 3.00e-05 | 15 | 3,840 | 127 | 126 | 228 | 184 | 3.97 | 0 |
| 3.00e-05 | 16 | 3,500 | 130 | 126 | 365 | 187 | 3.97 | 0 |
| 3.00e-05 | 18 | 3,380 | 134 | 127 | 611 | 192 | 4.17 | 3 |
| 3.00e-05 | 20 | 3,320 | 138 | 126 | 854 | 196 | 4.67 | 11 |
| 3.00e-05 | 25 | 3,200 | 148 | 121 | 1,460 | 204 | 5.95 | 31 |
| 3.00e-05 | 30 | 3,120 | 155 | 116 | 2,064 | 211 | 7.08 | 50 |
| 3.00e-05 | 45 | 3,120 | 183 | 102 | 3,864 | 237 | 10.1 | 110 |
| 3.00e-05 | 60 | 3,260 | 209 | 88.5 | 5,657 | 261 | 12.4 | 170 |
| 3.00e-05 | 90 | 3,120 | 265 | 62.4 | 9,269 | 312 | 15.9 | 289 |

the bid does not saturate against its cap when xp is high. at xp 3e-5 it starts at 6,000, falls 20 bps per credit at 120 to 150 credits a day, is at 3,500 on day 16 and sits at 3,100 to 3,300 from day 20, close to its floor of 3,000, with the pot still growing. at xp 1e-5 demand is thin, the 100 bps an hour climb wins and the bid sits at 9,300 to 9,700 near the cap. the per credit drop is what makes both behave. a drop scaled to the pot would pin the rate at the cap, as the spec said.

dutch auction. the price asks the whole supply for a slice at the start and halves every 6 hours. the first fill arrives about 3.4 days after the module is set (hour 418 against hour 336). after that a fill restarts the price at twice the clearing price, so the next fill is one half life later, and the cadence is one slice per 6.03 hours (289 fills in 76 days) whatever the taker threshold. a slice is 20 average credits, 0.26 eth of value at xp 3e-5, so the throughput is about 1.04 eth of value a day. that is slower than the inflow: the waiting amount grows to 65 eth of value at day 90, 62 days of backlog.

realised discount equals the taker's threshold because takers wait for it:

| taker threshold | fills | median hours between fills | realised all in discount | waiting at day 90 (value) | coin burned by dutch (m) | percent of supply burned |
|---|---|---|---|---|---|---|
| 0.02 | 289 | 6.03 | 1.9% | 65.7 | 126 | 16.6 |
| 0.05 | 289 | 6.03 | 4.9% | 65.3 | 124 | 16.4 |
| 0.1 | 289 | 6.03 | 9.9% | 64.8 | 120 | 16.0 |
| 0.15 | 289 | 6.03 | 14.9% | 64.7 | 116 | 15.6 |
| 0.25 | 289 | 6.03 | 24.9% | 63.9 | 108 | 14.7 |
| 0.4 | 289 | 6.02 | 39.9% | 62.5 | 93.5 | 13.3 |

a taker threshold of 2 percent against 40 percent changes burn from 126m to 93m coin (a 26 percent cut) and nothing else. the discount is not a cost to the engine in eth. it is coin the engine does not burn. the all in discount includes the 10 percent skim the taker pays on the coin it buys. against the pool price alone the discount is larger (22.7 percent at a 14.8 percent all in threshold).

## 8. sensitivity

each input moved from a low to a high value with everything else at base, 3 seeds each. base: coin burned 57.9m (5.79 percent of supply), eth sent to buyback 18.9, stuck statements 187. locked eth is not ranked: it is almost constant at 283 eth because the engine always spends the pot, so it follows fee income (volume x0.25 gives 64, x4 gives 1,151).

ranked by coin burned, millions of coin:

| input | low | high | result at low | result at high | swing |
|---|---|---|---|---|---|
| volScale | 0.25 | 4 | 196 | 14.7 | 182 |
| buyShareLate | 0.42 | 0.52 | 131 | 26.7 | 104 |
| pricePath | decline | recovery | 37.3 | 141 | 104 |
| wtpMult | 0.7 | 1.3 | 27.2 | 115 | 87.6 |
| priceP0 | 0.0045 | 0.018 | 42.4 | 90.8 | 48.4 |
| offersPerHour | 60 | 400 | 43.9 | 91.6 | 47.7 |
| askSigma | 0.15 | 0.4 | 32.4 | 78.5 | 46.1 |
| SPEND_CAP_BPS_PER_HOUR | 1000 | 4000 | 32.7 | 78.5 | 45.8 |
| CLIMB_BASE_BPS_PER_HOUR | 50 | 200 | 68.4 | 31.9 | 36.5 |
| bidMode | flat | perPoint | 91.3 | 59.3 | 32.1 |
| AUCTION_FLOOR_X | 8000 | 12000 | 89.0 | 59.3 | 29.7 |
| DROP_BPS | 500 | 2000 | 41.8 | 70.5 | 28.6 |

ranked by eth sent to buyback (the economic driver of burn):

| input | low | high | result at low | result at high | swing |
|---|---|---|---|---|---|
| pricePath | decline | recovery | 11.2 | 65.3 | 54.1 |
| wtpMult | 0.7 | 1.3 | 7.77 | 47.2 | 39.5 |
| volScale | 0.25 | 4 | 18.0 | 40.3 | 22.4 |
| priceP0 | 0.0045 | 0.018 | 13.1 | 34.1 | 21.0 |
| offersPerHour | 60 | 400 | 13.4 | 33.9 | 20.4 |
| askSigma | 0.15 | 0.4 | 9.96 | 27.6 | 17.6 |
| SPEND_CAP_BPS_PER_HOUR | 1000 | 4000 | 10.2 | 27.5 | 17.3 |
| bidMode | flat | perPoint | 33.3 | 19.5 | 13.9 |
| AUCTION_FLOOR_X | 8000 | 12000 | 32.6 | 19.5 | 13.1 |
| CLIMB_BASE_BPS_PER_HOUR | 50 | 200 | 22.3 | 10.7 | 11.6 |

ranked by unsold statements stuck at the floor:

| input | low | high | result at low | result at high | swing |
|---|---|---|---|---|---|
| volScale | 0.25 | 4 | 64.3 | 426 | 362 |
| priceP0 | 0.0045 | 0.018 | 326 | 107 | 220 |
| pricePath | decline | recovery | 230 | 119 | 111 |
| impactElast | 0 | 0.3 | 225 | 144 | 80.4 |
| offersPerHour | 60 | 400 | 150 | 230 | 80.0 |
| CLIMB_BASE_BPS_PER_HOUR | 50 | 200 | 223 | 157 | 66.3 |
| sniperVolShare | 0.2 | 0.6 | 165 | 210 | 44.7 |
| bidMode | flat | perPoint | 225 | 187 | 38.0 |
| AUCTION_FLOOR_X | 8000 | 12000 | 158 | 187 | 29.0 |
| wtpMult | 0.7 | 1.3 | 201 | 173 | 28.3 |

reading it:

1. the outside world dominates: fee volume, the credit price path, statement buyer willingness to pay and the net buy share of the coin (which sets the coin price and therefore burn per eth). none of those are engine settings.
2. the engine inputs that matter are the bid shape (flat against per point), the auction floor, the climb and drop constants and the spend cap. start multiple, auction length, rateStart, CLIMB_MAX and the tip and gas constants are all in the noise: rateStart swings burn by 2m coin of 58m and stuck statements by 2 of 187.
3. burn in percent of supply swings with the coin price path more than with anything the engine does. sell heavy flow (0.42 buy share) drags the price to the launch tick and the same 19 eth burns 13 percent of supply. read burn in eth to buyback when comparing designs.

## 9. what to change, ranked by impact

combinations, comparable decay, 90 days (sustained 17 and credit price recovery are in results/q9.json and agree in direction):

| name | what is changed |
|---|---|
| base | the Core as built, rateStart 4e12 |
| rule | rateStart 5.6e12 |
| constants | rule plus start 2x, floor 0.8x, DROP_BPS 2000 |
| floor06 | constants with floor 0.6x |
| flatBid | constants plus a flat per credit bid (design change) |
| gate20 | rule plus an inventory gate: no buying or climbing while 20 statements are unsold. implemented in the Core as the deploy input `INVENTORY_GATE` (eth lane statements held for sale, the simulator checks it once per step, the Core at every change) |
| gate20constants | gate plus constants. the same four values are `script/config/mainnet.recommended.json`: `AUCTION_START_X` 20000, `AUCTION_FLOOR_X` 8000, `DROP_BPS` 2000, `INVENTORY_GATE` 20 |
| gate20flat | gate plus constants plus flat bid |

| config | composed | sold | stuck | eth locked | pot idle | eth to buyback | percent burned | cost over market |
|---|---|---|---|---|---|---|---|---|
| base | 238 | 49.6 | 187 | 283 | 0.0675 | 18.9 | 5.79 | 1.43 |
| rule | 241 | 51.2 | 189 | 284 | 0.0852 | 18.9 | 5.73 | 1.42 |
| constants | 284 | 115 | 169 | 257 | 0.276 | 36.1 | 9.48 | 1.30 |
| floor06 | 299 | 160 | 137 | 222 | 0.36 | 44.6 | 11.0 | 1.28 |
| flatBid | 358 | 151 | 206 | 253 | 0.348 | 42.7 | 10.6 | 1.04 |
| gate20 | 46.4 | 21.6 | 24.8 | 21.2 | 267 | 8.84 | 2.89 | 1.04 |
| gate20constants | 131 | 96.4 | 29.4 | 38.3 | 210 | 33.7 | 9.02 | 1.25 |
| gate20flat | 160 | 119 | 41.4 | 37.8 | 207 | 37.3 | 9.71 | 1.08 |

same for sustained 17 eth a day:

| config | composed | sold | stuck | eth locked | pot idle | eth to buyback | percent burned | cost over market |
|---|---|---|---|---|---|---|---|---|
| base | 444 | 78.7 | 357 | 381 | 0.736 | 29.6 | 4.76 | 1.16 |
| rule | 450 | 84.7 | 356 | 380 | 0.548 | 32.0 | 5.08 | 1.16 |
| constants | 485 | 189 | 286 | 328 | 1.55 | 50.9 | 7.16 | 1.12 |
| floor06 | 477 | 213 | 253 | 302 | 1.60 | 45.9 | 6.66 | 1.13 |
| flatBid | 572 | 195 | 366 | 337 | 1.56 | 45.6 | 6.62 | 0.926 |
| gate20 | 44.0 | 19.3 | 24.7 | 20.9 | 373 | 7.79 | 1.48 | 1.03 |
| gate20constants | 129 | 99.0 | 22.0 | 33.1 | 319 | 34.5 | 5.38 | 1.24 |
| gate20flat | 152 | 112 | 40.0 | 36.0 | 317 | 34.5 | 5.38 | 1.06 |

recommendations, ranked by impact on stuck inventory and recycling:

1. **design change: an inventory gate on credit buying.** stop buying and stop the climb while about 20 statements are unsold, resume when they sell. at the base market it keeps 207 to 267 eth in the pot instead of locking 283 eth in statements nobody buys, and with constants it still sells 96 statements against 50 and burns 9.0 percent against 5.8. the eth is not burned, it is kept: the pot is the only asset that works in phase 2 and in a recovery. locked statements are worth 0.6 eth each at observed prices. cost: slower credit buying, less rating accumulated for phase 2.
2. **constant change in Core: AUCTION_FLOOR_X 1.2 to 0.8 and AUCTION_START_X 4 to 2.** sold 50 to 115, eth returned to the pot 19.5 to 36, burn 5.8 to 9.5 percent in the same run (constants row). it sells some statements under cost (0.9x), which retires invariant 3 of SPEC section 10, so the invariant test and the architecture note change with it. the start multiple alone is worth 10 sales. the floor is the lever.
3. **constant change in Core: DROP_BPS 1000 to 2000.** cost per credit 1.43 to 1.34, sold 51 to 66. it moves the engine away from the 3.5x overshoot region that begins at a drop of 500. a spend cap of 4000 is also better (sold 74) but is second order.
4. **design change: a flat per credit bid or a blend.** cost per credit 1.43 to 1.09 and sold 50 to 99 on its own, but it forgoes rating, which phase 2 pays for. decide after the exitToken price is known. at an xp under 3e-5 rating is worth less than the credits cost and flat wins. at 5e-5 and above rating is worth more than the premium and the per point bid wins.
5. **config only: rateStart 5.6e12 (flat price in wei over 1600).** first 80 credits at 0.61x of market, first fill inside the anti sniper window, no waiting 22 hours. impact on day 90 outcomes is zero within noise, so this is hygiene.
6. **phase 2 policy, off chain: exit only when rating times xp is at least the floor price.** keeps floor sales (eth lane sold 51 against 31 with automatic exit) and avoids dumping statements into an exitToken worth less than the floor.

what i would not change:

1. the new funded rule. the old rule is 17x overshoot in the base case. keep it exactly.
2. CLIMB_MAX_BPS_PER_HOUR, CLIMB_DOUBLE_EVERY, BONUS_CAP_BPS. never binding in any run.
3. SPEND_CAP_BPS_PER_HOUR at 2000. it only binds on a small pot and a lower value is worse.
4. AUCTION_LENGTH at 72 hours. 12 to 336 hours moves sold by under 10 percent.
5. TIP and gas reimbursement constants. tips total 0.002 eth and reimbursement 3 eth over 90 days, 1 percent of fees.
6. the XAUCTION_HALF_LIFE and restart rule. they give a clean one slice per half life with no mispricing. the only note is that the cadence is slow against exit inflow (about 1 eth of value a day at 3e-5), so a large exit batch waits weeks. a larger slice or a shorter half life is a later knob, not a fix.
7. rateStart bounds, buyback constants.

## what the model cannot tell us, and its weakest assumptions

1. the ask distribution. only fills are visible, not asks. the cheap tail of sellers (lognormal spread 0.27) sets how cheap the engine's first 80 credits are (0.61x) and how fast cost climbs. a thinner tail means the engine overpays from the first fill.
2. statement demand. 42 priced sales over 5 days, arrivals 8 a day decaying to 2. a doubling to 20 a day lifts sold by 11 and burn by 18m coin. statement buyers may also respond to the engine's own supply (80 credits of known provenance, auction price) in ways the secondary data cannot show. the willingness to pay is rating insensitive in phase 1 and that may change once the exitModule pays by rating.
3. the coin net flow. buy share after day one (0.46) drives the coin price and so percent of supply burned. the model holds volume exogenous, so engine buybacks do not draw volume.
4. the engine's own footprint. price impact elasticity 0.12 is a guess. at 0 the engine pays 1.51x, at 0.3 about the same, so cost per credit is not very sensitive, but the lift also raises statement willingness to pay in the model.
5. seller supply: 150 offers an hour, 5 percent leave an hour, more when the bid is above market. no whale seller, no strategy relist at 1.2x, no competing protocol bid like the fwa hub at 0.029 flat.
6. the anti sniper volume (40 percent of hour one volume inside 30 minutes) is inferred from the comparable's implied 406 eth against 194 eth at a flat 10 percent. 86 percent of fees come on day one, so the starting pot is the biggest input and it is the least observed. stuck statements swing by 45 across 20 to 60 percent.
7. phase 2 is parametric. the exitToken price per point is a constant, the exit bid supply is assumed to be honoured by the module, takers fill exactly at their threshold, and credit sellers compare bids with no friction.
8. no adversaries. keepers are always on, buyback runs every 25 blocks, no sandwiching of the 1 eth buyback, no wash volume (71 percent of the comparable's pool volume was churn and the model treats it as organic fee base).

## files

sim/engine.js (model), sim/engine.test.mjs (86 checks), sim/run.mjs (batches, node run.mjs q1 to q9), sim/results/*.json, sim/build.mjs and the page parts (page.css, page.body.html, page.ui1.js to page.ui4.js), sim/index.html (built, single file).
