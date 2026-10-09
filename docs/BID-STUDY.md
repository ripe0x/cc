# Bid rule study

Simulator study of three bid rules for the Credits engine at one minute resolution. Source: `sim/engine.js`, runner `sim/study-bid.mjs`, data in `sim/results/`. No contract code was changed.

## What was run

Rules.

1. `built`: the rule in `src/Core.sol`. Climbs 1 percent an hour, doubling per idle day up to 8 percent an hour. A fill drops the bid by 20 percent times the share of the pot spent. Run at an opening bid of 75 percent of market (as built) and 100 percent.
2. `dropToLast`: after each fill the bid is `dropToPct` of the rate that fill paid, then climbs `climbPerMin` percent a minute with no ceiling. Opens at 100 percent of market. Studied: climb 0.5, 1, 2 and `dropToPct` 80 (the owner's setting), 90, 95.
3. `stepped`: each fill drops the bid by `dropPerCreditPct`, down to a floor of `dropToPct` (80) of the bid at the first fill of that minute. The bid climbs `climbPerMin` percent a minute and never exceeds `ceilPct` of the rate of the last fill (of the opening bid before any fill). Opens at 100 percent of market. Studied: drop 0.25, 0.5, 1; climb 0.5, 1, 2; ceiling 110, 125, 150 (27 settings).

Every rule keeps the hourly spend cap (20 percent of the pot per hour) and the clamp (the current pot times the hourly share over `clampCredits` average credits, which lowers the read and stops the climb) and `rateCap`.

Markets, all with the comparable coin volume preset and 90 days.

| market | credit price path | sellers |
|---|---|---|
| flat | constant | 150 offers an hour |
| falling | halves over day 1, then flat | 150 an hour |
| rising | doubles over 7 days, then flat | 150 an hour |
| thin | constant | 37.5 offers an hour (25 percent) |
| whipsaw | falls 60 percent in 12 hours from day 2, recovers over the next 2 days | 150 an hour |

Settings of the run: 60 second steps after the first hour (the first hour keeps the existing 120 second launch steps), seeds 1, 2 and 3 for every rule, 38 rule settings x 5 markets = 190 rows. Credit counts, paid_vs_market, statements and burn are means over the three seeds. max_bid_over_market, max_paid_over_market and idle_hours_max are the maximum over the seeds. Extra rows (throttler, ask floor, ceiling decay) and probes are listed in the CSV params column and in `bid-rule-probes.csv`.

Interpretation choices in the new rules. Each credit sold is one purchase and changes the bid before the next credit sells. `stepped` treats all fills at the same simulated minute as one burst for the `dropToPct` floor. "Last price paid" is the bid rate at that fill, which equals the price for the flat bid (`flatBps` 10000).

Columns of `bid-rule-study.csv`: rule, params, market, credits_day1, credits_day3, credits_day7, credits_day30, credits_day90, paid_vs_market (eth paid over the market value of the credits bought), statements_created_day90, eth_to_burn_day90, max_bid_over_market (largest bid over market price at any step), idle_hours_max (longest time since the last purchase while the pot held at least one bid), max_paid_over_market (largest single fill price over market), throttler_credits_day90.

## Headline table

Per market: the built rule at both openings, the best `dropToLast` setting by credits at day 90 among those whose bid stayed under 1.5 times market, and the best two `stepped` settings by credits at day 30 among those with paid_vs_market at most 1.05. Where `stepped` rows show a max bid far above market, see the section on the runaway bid.

| market | setting | d1 | d7 | d30 | d90 | paid/mkt | max bid/mkt | idle h |
|---|---|---|---|---|---|---|---|---|
| flat | built open 100 | 3385 | 17240 | 20916 | 24091 | 0.99 | 1.23 | 11.8 |
| flat | built open 75 | 1520 | 17572 | 21156 | 24306 | 0.98 | 1.23 | 10.0 |
| flat | dropToLast to 95 climb 1 | 288 | 1964 | 8388 | 25150 | 0.65 | 0.70 | 0.4 |
| flat | stepped drop 1 climb 1 ceil 110 | 1641 | 10181 | 25963 | 26519 | 0.99 | 5.99 | 28.4 |
| flat | stepped drop 0.5 climb 0.5 ceil 110 | 1615 | 10182 | 25710 | 26289 | 1.01 | 5.99 | 28.4 |
| falling | built open 100 | 7533 | 22717 | 27014 | 29647 | 1.26 | 1.80 | 9.6 |
| falling | built open 75 | 5496 | 25186 | 29159 | 31876 | 1.23 | 1.58 | 6.7 |
| falling | dropToLast to 95 climb 2 | 576 | 3912 | 16697 | 50053 | 0.73 | 0.78 | 0.2 |
| falling | stepped drop 1 climb 1 ceil 150 | 2891 | 11442 | 44233 | 49636 | 0.96 | 11.97 | 28.4 |
| falling | stepped drop 0.5 climb 0.5 ceil 150 | 2449 | 11041 | 44000 | 49943 | 0.96 | 11.96 | 29.0 |
| rising | built open 100 | 2844 | 14292 | 17532 | 21395 | 0.85 | 1.08 | 16.2 |
| rising | built open 75 | 1072 | 11654 | 16389 | 19989 | 0.83 | 1.03 | 10.2 |
| rising | dropToLast to 95 climb 1 | 287 | 1950 | 8375 | 25135 | 0.65 | 0.70 | 0.4 |
| rising | stepped drop 1 climb 0.5 ceil 150 | 1509 | 5732 | 18105 | 19243 | 0.89 | 2.99 | 28.4 |
| rising | stepped drop 1 climb 0.5 ceil 125 | 1249 | 5474 | 18053 | 19218 | 0.90 | 2.99 | 28.4 |
| thin | built open 100 | 1049 | 11895 | 14427 | 16819 | 1.40 | 1.91 | 16.1 |
| thin | built open 75 | 473 | 10559 | 14310 | 16412 | 1.41 | 1.92 | 16.0 |
| thin | dropToLast to 95 climb 1 | 284 | 1958 | 8384 | 25145 | 0.83 | 0.93 | 0.4 |
| whipsaw | built open 100 | 3385 | 19273 | 22882 | 26356 | 1.13 | 2.43 | 8.9 |
| whipsaw | built open 75 | 1520 | 20889 | 24428 | 27903 | 1.09 | 2.33 | 12.9 |
| whipsaw | dropToLast to 95 climb 1 | 288 | 1964 | 8389 | 25149 | 0.65 | 0.70 | 0.4 |
| whipsaw | stepped drop 1 climb 1 ceil 110 | 1641 | 10181 | 26689 | 27346 | 1.01 | 5.98 | 28.4 |
| whipsaw | stepped drop 1 climb 1 ceil 125 | 1954 | 10500 | 26550 | 27141 | 1.01 | 5.99 | 28.4 |

## Grid

Flat market first, then day 90 credits and paid_vs_market in the other four markets. The full grid with every column is in `sim/results/bid-rule-study.csv`.

| setting | flat d1 | flat d30 | flat d90 | flat paid/mkt | flat max bid | falling d90 | falling paid/mkt | rising d90 | rising paid/mkt | thin d90 | thin paid/mkt | whipsaw d90 | whipsaw paid/mkt |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| built open 100 | 3385 | 20916 | 24091 | 0.99 | 1.23 | 29647 | 1.26 | 21395 | 0.85 | 16819 | 1.40 | 26356 | 1.13 |
| built open 75 | 1520 | 21156 | 24306 | 0.98 | 1.23 | 31876 | 1.23 | 19989 | 0.83 | 16412 | 1.41 | 27903 | 1.09 |
| dropToLast to 80 climb 0.5 | 36 | 969 | 2901 | 0.50 | 0.56 | 2903 | 0.50 | 2897 | 0.50 | 2900 | 0.58 | 2900 | 0.50 |
| dropToLast to 80 climb 1 | 67 | 1930 | 5783 | 0.53 | 0.59 | 5786 | 0.53 | 5780 | 0.53 | 5782 | 0.62 | 5782 | 0.53 |
| dropToLast to 80 climb 2 | 131 | 3836 | 11504 | 0.58 | 0.64 | 11507 | 0.58 | 11501 | 0.58 | 11503 | 0.69 | 11504 | 0.58 |
| dropToLast to 90 climb 0.5 | 75 | 2051 | 6141 | 0.54 | 0.60 | 6148 | 0.54 | 6135 | 0.54 | 6141 | 0.64 | 6141 | 0.54 |
| dropToLast to 90 climb 1 | 141 | 4085 | 12246 | 0.59 | 0.64 | 12252 | 0.59 | 12238 | 0.59 | 12243 | 0.71 | 12245 | 0.59 |
| dropToLast to 90 climb 2 | 275 | 8124 | 24363 | 0.64 | 0.70 | 24370 | 0.64 | 24356 | 0.64 | 24361 | 0.81 | 24363 | 0.64 |
| dropToLast to 95 climb 0.5 | 151 | 4211 | 12612 | 0.60 | 0.64 | 12626 | 0.60 | 12598 | 0.60 | 12608 | 0.72 | 12612 | 0.60 |
| dropToLast to 95 climb 1 | 288 | 8388 | 25150 | 0.65 | 0.70 | 25164 | 0.65 | 25135 | 0.65 | 25145 | 0.83 | 25149 | 0.65 |
| dropToLast to 95 climb 2 | 562 | 16684 | 37481 | 0.75 | 5.98 | 50053 | 0.73 | 20640 | 0.80 | 26555 | 1.05 | 37290 | 0.75 |
| stepped drop 0.25 climb 0.5 ceil 110 | 2846 | 18667 | 19070 | 1.22 | 5.99 | 37440 | 1.16 | 15501 | 1.28 | 9463 | 2.06 | 21993 | 1.23 |
| stepped drop 0.25 climb 0.5 ceil 125 | 3184 | 18528 | 18899 | 1.25 | 5.99 | 36827 | 1.17 | 15453 | 1.30 | 9285 | 2.10 | 21812 | 1.26 |
| stepped drop 0.25 climb 0.5 ceil 150 | 3455 | 18325 | 18749 | 1.24 | 5.99 | 36489 | 1.18 | 15581 | 1.30 | 9357 | 2.09 | 21569 | 1.25 |
| stepped drop 0.25 climb 1 ceil 110 | 5438 | 14319 | 14543 | 1.45 | 5.99 | 25446 | 1.41 | 14107 | 1.51 | 7960 | 2.31 | 16276 | 1.48 |
| stepped drop 0.25 climb 1 ceil 125 | 5781 | 13876 | 14011 | 1.51 | 5.99 | 24384 | 1.44 | 13700 | 1.56 | 7714 | 2.41 | 14730 | 1.53 |
| stepped drop 0.25 climb 1 ceil 150 | 6533 | 13530 | 13675 | 1.55 | 5.99 | 23073 | 1.45 | 13511 | 1.60 | 7616 | 2.45 | 13648 | 1.56 |
| stepped drop 0.25 climb 2 ceil 110 | 9453 | 11348 | 11425 | 1.73 | 5.99 | 16071 | 1.80 | 11868 | 1.74 | 7532 | 2.41 | 11420 | 1.74 |
| stepped drop 0.25 climb 2 ceil 125 | 9333 | 10422 | 10473 | 1.93 | 5.98 | 14144 | 1.98 | 11001 | 1.89 | 7205 | 2.55 | 10477 | 1.94 |
| stepped drop 0.25 climb 2 ceil 150 | 9105 | 10050 | 10101 | 2.02 | 5.99 | 12653 | 2.07 | 10640 | 1.98 | 7075 | 2.61 | 10095 | 2.04 |
| stepped drop 0.5 climb 0.5 ceil 110 | 1615 | 25710 | 26289 | 1.01 | 5.99 | 50859 | 0.96 | 16304 | 1.08 | 15342 | 1.48 | 26839 | 1.01 |
| stepped drop 0.5 climb 0.5 ceil 125 | 1927 | 25547 | 26119 | 1.01 | 5.99 | 50086 | 0.96 | 16283 | 1.08 | 15345 | 1.50 | 26891 | 1.02 |
| stepped drop 0.5 climb 0.5 ceil 150 | 2189 | 25264 | 25885 | 1.03 | 5.98 | 49943 | 0.96 | 16301 | 1.08 | 15324 | 1.49 | 26566 | 1.02 |
| stepped drop 0.5 climb 1 ceil 110 | 2941 | 19026 | 19405 | 1.20 | 5.99 | 37900 | 1.16 | 15700 | 1.28 | 9578 | 2.02 | 22142 | 1.22 |
| stepped drop 0.5 climb 1 ceil 125 | 3261 | 18483 | 18907 | 1.24 | 5.99 | 37030 | 1.16 | 15519 | 1.29 | 9265 | 2.10 | 21769 | 1.24 |
| stepped drop 0.5 climb 1 ceil 150 | 3985 | 18176 | 18538 | 1.24 | 5.99 | 35753 | 1.18 | 15591 | 1.32 | 9186 | 2.12 | 21411 | 1.26 |
| stepped drop 0.5 climb 2 ceil 110 | 5587 | 14585 | 14839 | 1.41 | 5.99 | 26238 | 1.38 | 14373 | 1.48 | 8162 | 2.24 | 16844 | 1.43 |
| stepped drop 0.5 climb 2 ceil 125 | 5932 | 13910 | 14077 | 1.50 | 5.99 | 24662 | 1.43 | 13896 | 1.56 | 7709 | 2.40 | 14773 | 1.52 |
| stepped drop 0.5 climb 2 ceil 150 | 6675 | 13536 | 13677 | 1.55 | 5.99 | 23318 | 1.45 | 13505 | 1.60 | 7566 | 2.46 | 13650 | 1.56 |
| stepped drop 1 climb 0.5 ceil 110 | 965 | 21683 | 33860 | 0.82 | 5.98 | 64066 | 0.78 | 19101 | 0.89 | 23026 | 1.17 | 34421 | 0.82 |
| stepped drop 1 climb 0.5 ceil 125 | 1269 | 21990 | 33798 | 0.82 | 5.99 | 63977 | 0.78 | 19218 | 0.90 | 22760 | 1.17 | 34034 | 0.83 |
| stepped drop 1 climb 0.5 ceil 150 | 1532 | 22255 | 34251 | 0.83 | 5.99 | 63432 | 0.79 | 19243 | 0.89 | 22664 | 1.16 | 33384 | 0.83 |
| stepped drop 1 climb 1 ceil 110 | 1641 | 25963 | 26519 | 0.99 | 5.99 | 51416 | 0.95 | 16320 | 1.07 | 15734 | 1.47 | 27346 | 1.01 |
| stepped drop 1 climb 1 ceil 125 | 1954 | 25596 | 26213 | 1.01 | 5.99 | 50381 | 0.95 | 16376 | 1.08 | 15537 | 1.48 | 27141 | 1.01 |
| stepped drop 1 climb 1 ceil 150 | 2672 | 25477 | 26042 | 1.01 | 5.99 | 49636 | 0.96 | 16596 | 1.09 | 15489 | 1.49 | 26631 | 1.03 |
| stepped drop 1 climb 2 ceil 110 | 2984 | 19209 | 19623 | 1.19 | 5.99 | 38339 | 1.14 | 15896 | 1.26 | 10124 | 1.93 | 22364 | 1.20 |
| stepped drop 1 climb 2 ceil 125 | 3314 | 18746 | 19132 | 1.22 | 5.99 | 37422 | 1.15 | 15715 | 1.29 | 9369 | 2.08 | 21982 | 1.24 |
| stepped drop 1 climb 2 ceil 150 | 4042 | 18230 | 18600 | 1.25 | 5.99 | 35985 | 1.17 | 15684 | 1.31 | 9312 | 2.09 | 21542 | 1.26 |

## What the data says

Throughput of `dropToLast` is fixed by its climb and drop, and independent of seller prices. After a fill the bid has to climb back by 1/dropTo before the next fill can happen at a price the sellers accept. At a drop to 80 and a climb of 1 percent a minute that takes about 22 minutes, so the engine buys about 65 credits a day (5,783 in 90 days on the flat market). A drop to 95 with a climb of 1 percent buys about 280 a day. The built rule buys 1,520 (open 75) or 3,385 (open 100) credits on day 1 and about 17,000 by day 7. The price paid by `dropToLast` depends on the seller ask distribution (next section).

`stepped` buys at the pace of the built rule early (about 1,600 to 2,000 credits on day 1 and 10,000 by day 7 at climb 0.5 to 1) and follows a falling market far more closely than the built rule. In the first 24 hours of the falling market the built rule pays 1.52 (open 75) and 1.78 (open 100) times market by hour 24, because the climb continues while the market halves and the drop per credit is a small share of the pot. `stepped` with drop 1, climb 1, ceiling 110 pays 0.89 times market at hour 24.

### Hour by hour in the falling market

First 24 hours at minute steps, seed 1, from `sim/results/bid-rule-falling-day1.csv` (hourly rows for each setting are in the file).

| setting | credits in 24 h | paid/mkt hour 1 | hour 6 | hour 12 | hour 24 | bid/mkt hour 24 |
|---|---|---|---|---|---|---|
| built open 75 | 5352 | 0.74 | 0.87 | 1.05 | 1.52 | 1.55 |
| built open 100 | 7478 | 0.98 | 1.09 | 1.30 | 1.78 | 1.80 |
| dropToLast to 80 climb 1 | 71 | 0.62 | 0.50 | 0.52 | 0.52 | 0.44 |
| dropToLast to 95 climb 1 | 301 | 0.64 | 0.59 | 0.62 | 0.66 | 0.65 |
| dropToLast to 95 climb 2 | 575 | 0.62 | 0.63 | 0.65 | 0.73 | 0.73 |
| stepped drop 1 climb 1 ceil 110 | 1756 | 0.82 | 0.79 | 0.84 | 0.89 | 0.89 |
| stepped drop 0.5 climb 0.5 ceil 125 | 2160 | 0.84 | 0.85 | 0.88 | 0.91 | 0.90 |

## The runaway bid in `stepped`

The max bid column shows `stepped` bids at about 6 times market on the flat market (the `rateCap`, 6 times the opening bid) and 12 times market on the falling market (the same cap against a market that halved). This is the rule as specified. The ceiling is applied at every step and the market reference follows the seller price path. A trace of one run (falling market, drop 1, climb 1, ceiling 110, seed 1) shows the cause. At the sampled minutes through day 34 the bid is between 0.86 and 0.95 of market. At day 34.7 the pot is 5 eth and at day 38 it is 0.14 eth, so the hourly cap affords one or two credits an hour. Sellers are plentiful (the book holds 6,000 offers), so every fill happens at the current bid, and fills come less often than one a minute, so the 1 percent climb a minute outruns the 1 percent drop per credit. Each fill sets the last price paid to the bid at that fill, which lifts the ceiling to 110 percent of it. The next fill then happens at up to 1.1 times the previous price. The ceiling anchors on the previous fill and has no link to the market, so it ratchets up about 10 percent per fill until `rateCap`. At minute 121,589 the trace shows bid 11.97 times market, last paid 11.44 times, ceiling 12.58 times, market price 0.00446 eth, pot 0.27 eth.

The same ratchet appears in `dropToLast` with a drop to 95 and a climb of 2 percent (max bid 5.98 on flat), where 5 percent per fill is smaller than 2 percent a minute at a few fills an hour. The built rule keeps its maximum bid at 1.23 times market on the flat market. Its drop is proportional to the share of the pot spent, and one fill is a large share of a nearly empty pot.

Fixes tried.

* Ceiling anchored on min(last paid, bid at last fill): both are the same number for the flat bid, so the result is identical to the table above.
* Ceiling headroom that halves every 6 hours since the last fill (`ceilDecayHours`). Fills in the starved pot arrive about every hour, so the headroom stays and the maximum bid is unchanged.

| setting | market | max bid/mkt without decay | with decay | credits d90 without | with |
|---|---|---|---|---|---|
| stepped drop 1 climb 1 ceil 110 | flat | 5.99 | 5.98 | 26519 | 26727 |
| stepped drop 1 climb 1 ceil 110 | falling | 11.97 | 11.97 | 51416 | 51403 |
| stepped drop 0.5 climb 0.5 ceil 125 | flat | 5.99 | 5.99 | 26119 | 26073 |
| stepped drop 0.5 climb 0.5 ceil 125 | falling | 11.97 | 11.97 | 50086 | 50346 |

* Funded clamp for N credits (`clampCredits`). The climb stops where the hourly cap affords N average credits instead of one. With N of 5 to 80 the maximum bid is 0.95 to 1.32 times market in every market tested, credits at day 90 rise (30,151 to 30,555 on flat against 26,519), and paid_vs_market falls to 0.86. The cost is a longer idle stretch while the pot refills (6.5 to 18.5 hours maximum against 28.4). Rows are from `bid-rule-probes.csv`, three seeds.

| stepped drop 1 climb 1 ceil 110 | market | clampCredits | credits d30 | credits d90 | paid/mkt | max bid/mkt | idle h |
|---|---|---|---|---|---|---|---|
| | flat | 1 (as built) | 25963 | 26519 | 0.99 | 5.99 | 28.4 |
| | flat | 5 | 26876 | 30151 | 0.86 | 1.03 | 18.5 |
| | flat | 20 | 27187 | 30555 | 0.86 | 1.03 | 13.2 |
| | flat | 80 | 26793 | 30272 | 0.86 | 0.96 | 8.2 |
| | falling | 1 (as built) | 43097 | 51416 | 0.95 | 11.97 | 28.4 |
| | falling | 5 | 43097 | 54321 | 0.89 | 1.04 | 15.4 |
| | falling | 20 | 43097 | 54512 | 0.89 | 1.02 | 9.0 |
| | falling | 80 | 43097 | 54453 | 0.89 | 0.96 | 6.5 |
| | rising | 1 (as built) | 15473 | 16320 | 1.07 | 2.99 | 28.4 |
| | rising | 5 | 16985 | 20473 | 0.82 | 1.32 | 18.5 |
| | rising | 20 | 17277 | 20751 | 0.80 | 1.01 | 18.4 |
| | rising | 80 | 17097 | 21242 | 0.79 | 0.95 | 11.1 |

The working fix is a bid limit tied to what the pot can afford, because the pot is the only quantity the contract knows that falls when the market cannot absorb the engine's buying. A limit tied to the previous fill price cannot work, since the previous fill price is itself the result of the ratchet.

## Dependence on the seller ask distribution

The seller model draws each offer's ask as a multiple of the market price from a lognormal with sigma 0.27, so about 3 percent of offers sit under 0.6 times market and 20 percent under 0.8. The willingness to pay table `WTP_Q` in the simulator belongs to statement buyers and has no effect on credit sellers. The low paid_vs_market of `dropToLast` (0.50 to 0.65 on the flat market) comes from the lognormal tail of asks: after each fill the bid falls and the cheapest remaining sellers take it, so the bid settles at the low end of the ask distribution. A sensitivity run puts a floor of 0.8 times market under every ask (`askFloor`). The number of credits is unchanged (it is set by the climb), and the price paid rises to 0.80 times market.

| setting | market | asks as modeled: credits d90 | paid/mkt | askFloor 0.8: credits d90 | paid/mkt |
|---|---|---|---|---|---|
| dropToLast to 80 climb 1 | flat | 5783 | 0.53 | 5781 | 0.80 |
| dropToLast to 95 climb 1 | flat | 25150 | 0.65 | 25145 | 0.80 |
| built open 100 | flat | 24091 | 0.99 | 22213 | 1.06 |

If real sellers do not offer credits at half of market, the `dropToLast` price result moves to the floor's level and its volume stays at 65 to 280 credits a day. The built rule at 100 percent open moves from 0.99 to 1.06 paid_vs_market under the floor.

## Throttling attack

The `throttler` toggle adds one seller with unlimited supply who sells one credit per minute step whenever the bid has reached `throttleFrac` of the market price, ahead of honest sellers in the same step. Its draws use a separate random stream, so honest seller arrivals are identical with the toggle on or off. Two measurements.

At `throttleFrac` 0.95 with the modeled asks:

| setting | market | credits d90 off | credits d90 on | paid/mkt off | paid/mkt on | credits sold by the throttler |
|---|---|---|---|---|---|---|
| built open 100 | flat | 24091 | 25192 | 0.99 | 0.94 | 5684 |
| built open 100 | thin | 16819 | 20359 | 1.40 | 1.16 | 7995 |
| dropToLast to 80 climb 1 | flat | 5783 | 5782 | 0.53 | 0.53 | 1 |
| dropToLast to 80 climb 1 | thin | 5782 | 5782 | 0.62 | 0.62 | 1 |
| dropToLast to 95 climb 1 | flat | 25150 | 25150 | 0.65 | 0.65 | 1 |
| dropToLast to 95 climb 1 | thin | 25145 | 25145 | 0.83 | 0.83 | 1 |
| stepped drop 1 climb 1 ceil 110 | flat | 26519 | 26689 | 0.99 | 1.00 | 456 |
| stepped drop 1 climb 1 ceil 110 | thin | 15734 | 24978 | 1.47 | 1.04 | 17760 |
| stepped drop 0.5 climb 0.5 ceil 125 | flat | 26119 | 25864 | 1.01 | 1.01 | 417 |
| stepped drop 0.5 climb 0.5 ceil 125 | thin | 15345 | 24677 | 1.50 | 1.05 | 17692 |

At `throttleFrac` 0.8 with an ask floor of 0.8 (so honest sellers and the throttler compete at the same price level), flat market:

| setting | askFloor 0.8 | throttler off credits d90 | throttler on credits d90 | paid/mkt off | paid/mkt on | credits sold by the throttler |
|---|---|---|---|---|---|---|
| built open 100 | yes | 22213 | 24110 | 1.06 | 0.99 | 12944 |
| dropToLast to 80 climb 1 | yes | 5781 | 5781 | 0.80 | 0.80 | 5780 |
| dropToLast to 95 climb 1 | yes | 25145 | 25145 | 0.80 | 0.80 | 25141 |
| stepped drop 1 climb 1 ceil 110 | yes | 26323 | 30385 | 1.00 | 0.89 | 29567 |

What it shows. Under `stepped` one sale moves the bid by at most the drop per credit (0.5 or 1 percent), which a 0.5 to 1 percent climb a minute recovers in a minute or two, so the throttler cannot hold the bid down: on the flat market it sells 456 of 26,689 credits. Under `dropToLast` the first honest sellers already hold the bid near 0.55 to 0.7 of market, so a throttler at 0.95 sells once. At the floor setting the throttler takes essentially all of the `dropToLast` volume (5,780 of 5,781 credits at drop 80, 25,141 of 25,145 at drop 95): the engine buys the same count at the same price and the honest sellers are displaced, because the volume of `dropToLast` is capped at one fill per climb cycle and a seller that is first at each cycle takes it. For `stepped` and `built` the throttler adds supply, and in the thin market it raises credits at day 90 from 15,734 to 24,978 (stepped) and lowers paid_vs_market from 1.47 to 1.04. In every measured case the credits the engine buys stay within 1 percent of the value without the throttler or rise. The measured effects are displacement of honest sellers and a lower price paid.

## Idle loosening of the ceiling anchor

The tables in this section and in the next follow the earlier simulator semantics (compounded loosening, clamp stored in the bid). The section "Contract semantics rerun (2026-10-08)" has the rows for the contract rules.

A ceiling of 110 percent of the last price paid parks the bid when the market gaps up by more than the ceiling between two fills and no seller accepts the parked bid. The anchor stays at the last fill, so the bid stops at the ceiling until the market comes back. The `rising` market of the grid (doubling over 7 days) moves 1 percent an hour and never triggered this.

Fix: `idleLoosenPct` percent is added to the anchor every `idleLoosenMin` minutes while no fill happens. A fill resets the idle clock. The anchor is the last rate paid, so the ceiling at idle time `k` intervals is `ceilPct x anchor x (1 + idleLoosenPct)^k`. All rows below use `clampCredits` 20 (the runaway guard). Setting A is drop 1, climb 1, ceiling 110. Setting B is drop 0.5, climb 0.5, ceiling 125. Market path `gap`: one jump at hour 6 of a flat day, then flat. Three seeds, minute steps, from `sim/results/bid-rule-stalls.csv` (scenario `a_gap_up`). "First fill" is minutes from the jump to the next purchase, "credits 24 h" and "paid/mkt 24 h" cover the 24 hours after the jump, "stall h" is the stall metric defined in the next section.

| setting | first fill, 13% | first fill, 30% | 100%: first fill | credits 24 h | paid/mkt 24 h | stall h | 300%: first fill | credits 24 h | paid/mkt 24 h | stall h |
|---|---|---|---|---|---|---|---|---|---|---|
| A, loosen 0% | 2 min | 7 min | 929 min | 446 | none | 16.2 | never | 0 | none | 66.0 |
| A, loosen 0.5% | 3 min | 13 min | 117 min | 1199 | 0.82 | 1.8 | 856 min | 276 | 0.49 | 18.5 |
| A, loosen 1% | 1 min | 3 min | 77 min | 1269 | 0.82 | 0.8 | 422 min | 812 | 0.67 | 8.0 |
| A, loosen 2% | 4 min | 6 min | 76 min | 1291 | 0.84 | 0.0 | 193 min | 1071 | 0.70 | 3.9 |
| B, loosen 0% | 2 min | 9 min | 102 min | 1210 | 0.83 | 1.0 | never | 0 | none | 66.0 |
| B, loosen 0.5% | 2 min | 5 min | 27 min | 1270 | 0.85 | 0.0 | 447 min | 791 | 0.66 | 7.4 |
| B, loosen 1% | 2 min | 8 min | 41 min | 1276 | 0.85 | 0.0 | 200 min | 1010 | 0.69 | 4.3 |
| B, loosen 2% | 2 min | 8 min | 54 min | 1277 | 0.85 | 0.0 | 94 min | 1157 | 0.70 | 0.0 |

Jumps of 13 and 30 percent resolve in under 15 minutes for every setting, because the lowest asks in the modeled book sit far below the bid and each cheap fill moves the anchor up 10 to 25 percent. Jumps of 100 and 300 percent separate the settings. Setting A without loosening waits 929 minutes after a 100 percent jump and never fills after a 300 percent jump (66 hours, the rest of the run). Setting B with 2 percent per 10 minutes fills within 54 minutes after 100 percent and 94 minutes after 300 percent with no stall hours.

Runaway check over 90 days (the bid over market stays near market with the clamp at 20, loosening has little effect):

| setting | flat: max bid/mkt | credits d90 | paid/mkt | falling: max bid/mkt | credits d90 | paid/mkt |
|---|---|---|---|---|---|---|
| A, loosen 0% | 1.03 | 30555 | 0.86 | 1.02 | 54512 | 0.89 |
| A, loosen 0.5% | 1.03 | 30683 | 0.85 | 1.02 | 54056 | 0.89 |
| A, loosen 1% | 1.05 | 30657 | 0.85 | 1.03 | 54509 | 0.89 |
| A, loosen 2% | 1.08 | 30905 | 0.85 | 1.07 | 54000 | 0.89 |
| B, loosen 0% | 1.23 | 30449 | 0.86 | 1.17 | 53121 | 0.90 |
| B, loosen 0.5% | 1.18 | 30117 | 0.86 | 1.19 | 53578 | 0.89 |
| B, loosen 1% | 1.20 | 30136 | 0.86 | 1.23 | 52803 | 0.90 |
| B, loosen 2% | 1.17 | 30240 | 0.86 | 1.21 | 53221 | 0.90 |

Recommended values: `idleLoosenPct` 2 and `idleLoosenMin` 10 on setting B (drop 0.5, climb 0.5, ceiling 125, `clampCredits` 20). Value 1 percent leaves a 4.3 hour stall at a 300 percent gap and 0.5 percent leaves 7.4 hours. Setting A shows a lower maximum bid (1.08 against 1.17 to 1.21) and a 3.9 hour stall at 300 percent with the 2 percent value.

## Stalls

Definition used by the simulator (`stallHours`, `stallHoursMax`, `stallRuns` in the run statistics): a step is stalled when the pot affords the cheapest ask in the book, the engine buys nothing in that step, and the stretch of such steps lasts longer than 2 hours. The total counts the full length of every stretch over 2 hours. `gapHoursMax` is the longest stretch of any length. Each stalled step is assigned a cause: `low_clamp` (the pot limited climb, which is `clampCredits`, is under the cheapest ask), `low_rateCap`, `low_ceiling` (the stepped ceiling), `low_climbing` (the bid is still climbing), `room` (the bid is at or above the cheapest ask and above what the pot and the hourly cap afford) or `other`. Rows are in `sim/results/bid-rule-stalls.csv` with one column per cause.

Setting for all rows: stepped B, idleLoosenPct 2 every 10 minutes, `clampCredits` 20, unless the row names another clamp. Tests ran on minute steps with three seeds.

| cause | trigger | duration | fix or accepted |
|---|---|---|---|
| ceiling anchor behind a gap (`low_ceiling`) | market jumps by 100 percent or more between fills | without loosening: setting A 929 minutes after +100 percent, 66 hours (to the end of the run) after +300 percent; with 2 percent per 10 minutes: no stall hours, first fill 54 and 94 minutes | fixed by `idleLoosenPct` 2 per 10 minutes |
| low anchor after one cheap fill (`low_ceiling`) | one fill at 0.3 times market, then flat | without loosening a 24.4 hour stall (longest gap 32.9 hours); with loosening 0.9 hours total | fixed by loosening |
| slow recovery after a cheap fill | one fill at 0.5 times market | no stall in either case; bid returns to 0.9 times market after 1,475 minutes without loosening and 969 minutes with it, because each fill lifts the anchor by at most the ceiling factor | accepted, about 16 hours |
| pot accumulation under the clamp (`low_clamp`) | the pot affords fewer than N credits an hour at the cheapest ask, which is a pot under about 2.5 x N x market price in eth | N 20 at a 0.03 market: 365 to 381 stall hours of 480 at pots of 0.25 to 1 eth, none at 2 eth. Over 90 days on the five markets, N 20: 463 to 765 hours (longest single stretch 14.8 to 22.1 hours); N 80: 270 hours on flat | accepted: credits per day are the same across N (288 to 336 on flat) because purchases are limited by income, the engine waits for the pot instead of paying above its means |
| bid above the hourly room (`room`) | clamp N of 1 (as built) or 5 and a starved pot: the bid sits at the clamp, 5.98 times market for N 1, and the pot cannot pay it | flat 90 days: N 1 1,099 hours (longest 28.4), N 5 902 hours (longest 24.7) | fixed by N 20 or more, which turns the stall into pot accumulation above and ends the 6 times overpay |
| `rateCap` | market above the cap price, which is 5.99 times the launch market price (0.0533 eth at 433 points) | +700 percent (8x): 9 hours while the anchor loosens, then fills from sellers asking under 0.75 times market, 474 credits a day; +1500 percent (16x) and +3000 percent (31x): no fill until the end of the run (114 hours), 100 hours of `rateCapHours` | accepted by design: the owner raises `rateCap` with `setSettings`. With the strategy listings on (priced in eth, not following the market) the engine keeps buying 1,483 credits a day at 0.1 to 0.4 times market and the cap does not show |
| hourly cap drained at the hour start by a bot | a bot sells into the bid at the first minute of each hour until the hourly room is used | longest gap 1.0 hour (0.7 hours at a 50 eth pot), 0 stall hours. Credits per hour allowed: 474 at a 20 eth pot and 839 at 50 eth with the bot, 66 and 64 without | pacing, accepted. The bot lowers the price paid to 0.57 times market because it sells at any ask |
| inventory gate (`REVIEW-econ.md` E-4) | bid closed while unsold statements are held | 0 hours in the simulator. `docs/FLOW.md` rule 2 removed the gate and neither `src/Core.sol` nor the simulator has it. Counterfactual with a gate of 20 held statements the bid would be closed 2,146 of 2,160 hours in the 90 day flat run | simulator unchanged. A gate of 20 would dominate every other stall in this table |
| supply limited overpay (not a stall) | the market cannot supply the throughput target, which is climb over drop credits a minute (1 for setting B) | pot held at 5 eth and a 0.0089 market: bid rises to 5.3 times market, 29 credits an hour, because the clamp for N 20 at a 5 eth pot is 5.6 times market | accepted, noted: the clamp bounds the bid by the pot, so at pots above about 0.9 eth (N 20) the bid is bounded by supply and the ceiling alone |
| bid pulled down to the clamp (probe, removed) | a probe that cut the bid to the clamp whenever the pot was below it | the rate collapsed to 0 at launch, where the pot is empty, and never recovered | any such pull needs a floor on the rate |

Smallest pot without a stall, by clampCredits, market price 0.03 eth, pot held constant for 20 days (480 hours), hours stalled and credits per day:

| clampCredits | 0.1 eth | 0.25 eth | 0.5 eth | 1 eth | 2 eth | 5 eth | 10 eth | 20 eth |
|---|---|---|---|---|---|---|---|---|
| 1 | 480 h, 0/day | 178 h, 18/day | 0 h, 26/day | 0 h, 76/day | 0 h, 179/day | 0 h, 471/day | 0 h, 1012/day | 0 h, 1357/day |
| 5 | 480 h, 0/day | 2 h, 39/day | 0 h, 80/day | 0 h, 121/day | 0 h, 179/day | 0 h, 471/day | 0 h, 1012/day | 0 h, 1357/day |
| 20 | 480 h, 0/day | 365 h, 11/day | 381 h, 16/day | 368 h, 19/day | 0 h, 270/day | 0 h, 518/day | 0 h, 1012/day | 0 h, 1357/day |
| 80 | 480 h, 0/day | 377 h, 9/day | 419 h, 9/day | 434 h, 9/day | 441 h, 9/day | 378 h, 16/day | 0 h, 538/day | 0 h, 1322/day |

From the grid: N 1 needs 0.5 eth, N 5 needs 0.5 eth (0.25 eth stalls 2 hours), N 20 needs 2 eth, N 80 needs 10 eth. The pot threshold scales with the market price: at the launch market of 0.0089 eth the thresholds are about 0.11 eth for N 5, 0.45 eth for N 20 and 1.8 eth for N 80.

Other states searched for a bid that cannot reach the cheapest ask while the pot is funded. The hourly window opens with the pot at the first spend after the previous window ended, so a drained pot refilled by fees shortens the cap for at most one hour (pacing, longest gap 1.0 hour in the bot runs). After a large purchase burst the bid sits at 0.8 times the bid at the burst start and the anchor at the lowest fill, which recovers in minutes. Rate bounds apply to `setRate` and `rateStart` in `SettingsBounds`, and the climb path holds only the clamp and `rateCap`, so no run reached a rate floor.

## Contract semantics rerun (2026-10-08)

The rows in this section follow the contract as built in `src/lib/CoreLib.sol` (`climb`, `drop`, commit 6a5ba30) and the bid rule section of `docs/FLOW.md`. The stepped rule changed in the simulator as follows. The earlier sections of this document were produced before the change, which is why the "earlier sim" columns below differ from the new columns.

1. Idle loosening is linear: the anchor is the last fill rate times `1 + idleLoosenPct x floor(idleSeconds / (idleLoosenMin x 60))`. The earlier sim compounded the percent per interval.
2. The price state holds the stored rate and the anchor. It climbs per minute toward min(ceiling, rateCap, clamp), where the clamp is the hourly room divided by `clampCredits`. A stored rate above the ceiling or `rateCap` reads as that bound. A stored rate above the clamp holds its value: the clamp stops the climb and never lowers the price state.
3. The read bid is the price state lowered to the clamp at every pot, funded or not. The read bid is what a seller is paid. A fill drops the price state rate and sets the anchor to the price state rate at the fill, the clamp is never stored. An empty pot reads 0. The minute floor of the drop restarts at the price when the price is already under the floor of the current minute.

A checkpoint stores the price state. The fill price is the read, and the drop, the minute floor and the anchor use the price state at the fill, so a small pot leaves the stored rate and the anchor at the price state.

Setting for all rows: stepped B (drop 0.5, climb 0.5, ceiling 125, drop floor 80), `idleLoosenPct` 2 per 10 minutes, `clampCredits` 20, comparable volume, minute steps, three seeds. Data: `sim/results/bid-rule-stalls-contract.csv`. The older `sim/results/bid-rule-stalls.csv` keeps the earlier semantics.

90 days on the five markets:

| market | stepped credits d1 / d7 / d30 / d90 | paid/mkt | max bid/mkt | stall h (longest) | earlier sim: credits d90 | paid/mkt | max bid/mkt | stall h (longest) | built open 100: credits d90 | paid/mkt | max bid/mkt |
|---|---|---|---|---|---|---|---|---|---|---|---|
| flat | 2189 / 10770 / 26492 / 29948 | 0.86 | 1.17 | 780 (11.6) | 30240 | 0.86 | 1.17 | 530 (16.9) | 24091 | 0.99 | 1.23 |
| falling | 2449 / 11041 / 44000 / 53331 | 0.90 | 1.21 | 483 (8.8) | 53221 | 0.90 | 1.21 | 463 (22.1) | 29647 | 1.26 | 1.80 |
| rising | 2156 / 10598 / 17345 / 21390 | 0.80 | 1.32 | 742 (14.2) | 21535 | 0.80 | 1.32 | 575 (15.1) | 21395 | 0.85 | 1.08 |
| thin | 1489 / 10049 / 16451 / 18550 | 1.28 | 1.99 | 1005 (17.0) | 18749 | 1.27 | 1.98 | 765 (18.8) | 16819 | 1.40 | 1.91 |
| whipsaw | 2189 / 10775 / 27423 / 31126 | 0.86 | 1.39 | 717 (16.3) | 31020 | 0.86 | 1.39 | 535 (14.8) | 26356 | 1.13 | 2.43 |

Gap up (flat day, one jump at hour 6):

| jump at hour 6 | first fill (min) | credits 24 h | paid/mkt 24 h | stall h | earlier sim: first fill | credits 24 h | stall h |
|---|---|---|---|---|---|---|---|
| +13% | 2 | 1394 | 0.90 | 0.0 | 2 | 1394 | 0.0 |
| +30% | 8 | 1369 | 0.89 | 0.0 | 8 | 1369 | 0.0 |
| +100% | 54 | 1277 | 0.85 | 0.0 | 54 | 1277 | 0.0 |
| +300% | 101 | 1151 | 0.70 | 0.0 | 94 | 1157 | 0.0 |

Small pot, `clampCredits` 20, pot held for 20 days (480 hours), hours stalled and credits per day:

| pot (eth) | 0.1 | 0.25 | 0.5 | 1 | 2 | 5 | 10 | 20 |
|---|---|---|---|---|---|---|---|---|
| contract semantics | 480 h, 0/day | 480 h, 0/day | 480 h, 0/day | 480 h, 0/day | 0 h, 262/day | 0 h, 539/day | 0 h, 1012/day | 0 h, 1357/day |
| earlier sim | 480 h, 0/day | 365 h, 11/day | 381 h, 16/day | 368 h, 19/day | 0 h, 270/day | 0 h, 518/day | 0 h, 1012/day | 0 h, 1357/day |

What changed against the earlier sim. Credits at day 90 are within 1.1 percent on every market (flat 29,948 against 30,240, falling 53,331 against 53,221, rising 21,390 against 21,535, thin 18,550 against 18,749, whipsaw 31,126 against 31,020). The maximum bid over market is 1.17 to 1.39 on four markets and 1.99 on thin, as before. Stall hours on the five markets are 483 to 1,005 against 463 to 765, all `low_clamp`, because the clamp stays under the cheapest ask while the pot is small and the price state is not pulled down to it. Pots of 1 eth and below buy nothing at N 20; the earlier sim bought 11 to 19 credits a day at 0.25 to 1 eth through the stored clamp. The pot threshold for N 20 stays between 1 and 2 eth at a 0.03 market. Gap rows resolve with no stall hours: first fill in 54 minutes after +100 percent and 101 minutes after +300 percent. The recommended `idleLoosenPct` 2 per 10 minutes on setting B holds. Every row of this section equals the rerun at b16049e: the pots in these runs stay above one credit and no run lowers the price below the minute floor, so the read at every pot and the restarting floor (commit 6a5ba30) change nothing here. Against the first contract rerun of this date (price state climbing past the clamp) the maximum bid is lower: flat 1.17 against 1.31, falling 1.21 against 1.35. Rows of the stall table that were not rerun (cheap fill, `rateCap`, bot, N 1, 5 and 80) follow the earlier semantics.

## Where the numbers may be untrustworthy

1. Seller asks are a lognormal around the market price. The cheap tail drives every low paid_vs_market value and is untested against real listing data (sensitivity above).
2. Credits are unlimited in supply for the throttler and the book is capped at 6,000 offers. Large engine purchases against a thin real book could differ.
3. The engine pays the bid on the `sellForEth` path as in the Core. Listing purchases through `buyListing` pay the seller's ask.
4. Three seeds. Differences of a few percent between neighboring rows are inside the seed noise; the large effects (throughput of `dropToLast`, the runaway bid, the clamp fix) are many times larger than that noise.
5. The market price used for ratios includes the engine's own price lift (`impactElast`), which decays with a 48 hour half life, so the ratio is to the market as the engine moves it.
6. In the whipsaw market the fall starts on day 2 so the engine is already buying; a fall at launch would be a different test.
7. Order within a minute: the throttler sells first. Real transaction ordering in a block could differ.
8. The stall rows use a held pot in the small pot and bot tests (topped up after every step), which breaks the pot accounting check for those runs only. The strategy listings are priced in eth and sit in the book at fixed prices, which hides market gaps unless switched off.
