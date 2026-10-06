notes for the credits market calibration pull (all lowercase, no dashes, tables are plain text)

coverage window
the whole life of every contract. credits mint block 26037294 (2026/09/23 02:47 utc) to snapshot block 26130271 (2026/10/06 02:12 utc), about 13 days. nothing is sampled: all 303,426 credits transfer logs, all 87,453 non mint tx receipts, all 122,154 scores, all 153 statements, all 43,033 strategy logs, all 7,796 pool swaps. the chain moved about 190 blocks past the snapshot (ignored). 30d and 90d medians therefore equal the whole window median and are labelled so. first and last utc days are partial.

what was reused vs added
reused from the previous engineer: raw transfers, receipts, scores, strategy logs, pool logs, statement logs, block timestamps. extended: logs topped up to the snapshot block, statement state refreshed (141 to 153 ids), eth balance of the strategy every 300 blocks, nftForSale for every held id, ownerOf spot check (600 random ids, 0 mismatches vs the transfer replay), tx senders of the swap txs. rebuilt classification (build_sales.py) to fix round trips and add blur and fwa hub.

files
file                     rows     content
credits_sales.csv        118,316  every identifiable sale (price in eth and wei, venue, buyer, seller, score, price per whole point, flags, wash flags)
statements.csv           153      compose data, rating, owner, sales json, cost basis, parts cost estimates, premium
strategy.csv             14       per utc day: bought, sold, inventory, listing price quantiles, pool volume, fees, buybacks, balance, coin price
credit_price_daily.csv   119      daily n, volume, median, p10, p90 per point and per credit, per venue group
summary.json                      calibration numbers, each with its window
raw/                              scores.json (cached), rows.pkl, sales.pkl, swaps2.pkl, receipts etc

method
1 credits Transfer logs are the ground truth. moves are grouped per tx and token and collapsed to first sender and last receiver (a tx where the token returns to its start is split into hops: these are the strategy arb loops).
2 per tx decode of: seaport OrderFulfilled (1.6, 1.5 seen 0 times), CreditStrategy NFTBoughtByProtocol and NFTSoldByProtocol, blur takeAsk executions, fwa hub 0x958c events.
3 seaport price = sum of the matched order consideration (listing) or offer weth (offer accept), split by nft count if the order holds several nfts (flag bundle_prorata, excluded from stats). sweeps are separate orders so each has its own exact price. spot check: 19,105 of 20,000 single order native fills equal tx.value exactly, the rest are routers with extra value.
4 strategy purchase rows carry the price the strategy paid (a flat tier) plus seaport_leg_price_wei, what the seller got from the searcher bot. market statistics use the seaport leg for these rows so nothing is double counted.
5 scores read on chain at block 26130000 via multicall (immutable, cached in raw/scores.json). price per point = wei / (score_1e4 / 1e4).
6 clean sample = priced, not bundle pro rata, not mixed order, not non eth. market sample = seaport fills and accepts, blur single token, strategy purchase seaport legs (n 109,714). protocol venues (strategy, fwa hub) are reported separately.

row counts by venue
venue                       rows    eth        note
seaport listing fill        74,832  2,090      exact consideration
seaport offer accept        22,797  496        weth offers
credit strategy purchase    13,810  407        flat tier price paid by the strategy
credit strategy sale        678     21.9       relist at 1.2x
other blur takeAsk          1,082   251        price = tx value over executions, 760 rows flagged unreliable or bundle, one 219 eth value dropped
other fwa hub bid accepted  5,117   149        gross = payout + 10% fee, 1,017 paid in strategy tokens
not sales: mints 122,154 (all in day one), burns into statements 12,240 (153 x 80), fwa hub deposits 8,181, hub returns 2,958, plain transfers with no payment found 26,328

data quality caveats
seaport listings that were never filled are off chain and not derivable. only fills are visible, so fills show the cheapest asks, not the ask distribution.
blur prices are tx value split over blur executions (a tx can hold other collections); only 322 single execution rows are clean.
fwa hub 0x958c is a depositor escrow with an oracle band of 0.025 to 0.032 eth; its accepted bids are a protocol price, not an open market. buyer and bidder labels follow the event topics.
hub event to token matching is by order inside a tx (121 rows flagged hub_match_uncertain).
cost basis of statement credits uses the last priced acquisition by the composer: 8,448 priced, 905 mint origin, 2,887 unpriced transfers.
statement creditsOf is 80 x (1 + overprints), only 80 credits per statement are burned on chain, overprinted ones (7) rate up to 7.8x.
fee model: pool Swap events give notional only. hook fee is about 10% steady state (verified on 3 traces and by eth_getBalance reconciliation, 7.7% of notional reaches the strategy, 8% by design). the first 600 blocks carried a decaying launch fee (about 50% hook fee), so 10% of notional understates early income: implied strategy inflow 406.5 eth vs 194.4 eth at a flat 10%.

wash and dominance flags
flag                                  rows     share of eth
repeat_pair_ge5 (same seller buyer)   32,489   20%   sweeper bots, treat as one actor
price_gt10x_day_median                105      9%    mostly 790+ pt credits (premium tier), one 10.8 eth seaport sale
returns_to_prior_seller               110      0.06% possible round trips
strategy_roundtrip_arb                170      0.2%  85 loops, strategy lost 0.47 eth in total
same_party                            1        0
one bot (0xc8bd1dca) delivered 55% of strategy purchases, top 5 bots 88%. top buyer is 2.6% of market eth, top 10 buyers 12%, top 100 37%. 71% of pool volume is matched buy and sell by the same sender (churn), top 10 senders 16%. no single wallet dominates organic sales.

market state now (window end)
metric                                   value
credit price per credit, last 24h        median 0.0089 eth (p10 0.0069, p90 0.0138)
price per point, last 24h                median 2.20e13 wei (p10 1.28e13, p90 5.75e13)
price per point, whole window            median 5.95e13 (day one 7.8e13, before 10/02 7.1e13, after 2.4e13)
daily sales, last full day               3,528 sales, 32.6 eth (day two 12,316 sales, 429 eth)
live credits, holders                    109,914 live, 13,715 holders, strategy holds 13,132 (12%)
top 10 and top 100 share excl protocol   6.9% and 22.8% of live credits
credits traded at least once             65,815 (53.9%), mean score 425 vs 440 for all
score census (points)                    mean 440, median 440, deciles 152 224 296 368 440 512 584 656 728

the 10 facts for a per point bid (opens 4e12 wei per point, +1% per hour)
1 the market does not price by score. relative price vs day median is 0.99 to 1.01 from 80 to 650 points, pooled r2 0.0001 (slope 3.3e13 wei per point, intercept 0.0145 eth, n 109,714), flat model error 0.13 vs per point model 0.48 (mean abs log). a premium exists only above 740 points (median 1.12x), and at 790+ (1.4% of credits) the median is 2.0x. sellers price per credit, plus a rare top tier.
2 today the market pays 0.0089 eth per credit, which is 2.2e13 wei per point at the median. the opening bid is 5.5x below that (14.9x below the whole window median). at 4e12 a 440 point credit gets 0.00176 eth, 20% of today's flat price and 6.4% of the price before 10/02.
3 climb time to the market (1%/h, hours = ln(target/4e12)/ln(1.01)) in the table below.
4 the price was held up by the strategy: it bought about 1 credit a minute at flat tiers 0.025 to 0.04 (13,810 credits, 407 eth) until its eth ran out at 2026/10/01 21:00 utc. the market median fell from 0.028 (10/01 12:00) to 0.011 (10/02 06:00) and daily market eth volume fell about 65%. this coincides with strategy exhaustion (10/01 18:00 to 21:00) and statements going live (10/02 00:15), so the two causes are not separable. a new bid replaces the strategy demand: 0.03 flat was the ceiling, 0.009 is the current level.
5 a per point bid clears high scores first. a seller with flat ask p clears when bid x score >= p. at ask 0.0089: first 800 point credit at hour 103, the median 440 point credit at hour 163, everything down to 80 points only at hour 334. at hour 168 53% of credits clear. the bid overpays high score credits and fills low score ones last.
6 the strategy listing level is far above the market. 13,132 held credits listed at a median 0.036 eth (1.0e14 wei per point, p10 5.4e13, p90 2.7e14) vs a market 0.0089. only 678 of 13,810 sold (4.9%). listings are 1.2x of its own flat purchase price, never score based. holdings skew low (mean 371 points, none above 790), an overhang if it reprices.
7 competing protocol bid: fwa hub accepted 5,117 depositor bids at a flat 0.025 to 0.032 (median 0.0293, 7.8e13 per point), 3.3x today's market. it is flat per credit as well.
8 depth: the last 3 full days saw 3.5k to 5.9k sales and 33 to 72 eth a day. unique sellers 12,541, buyers 5,518 in the window, so a bid has many small counterparties, no whale seller.
9 statements as an exit: 42 priced sales of 153 statements (33 distinct, 21.6%), median 0.745 eth flat regardless of rating (r2 0.03), median 0.84x the market cost of their credits. 21% reached 1.2x, max 1.32x, none near 4x. an auction starting at 4x with a 1.2x floor would not clear except against the top fifth of buyers, and not at 4x at all. composers' own cost basis was about 2.6x the sale price (bought at launch prices).
10 coin comparable (CREDITSTR): 1,944 eth swap volume, 80% on launch day (912 eth in the first hour), peak hour 2026/09/23 04:00 utc, last 7 calendar days 17.2 eth a day (1.7 eth fees at 10%), last 3 calendar days 1.65 eth a day (0.17 eth fees, last day partial). 1,234 distinct senders. daily volume: 1,557, 81, then 12 to 58, then 0.4 to 5 over the final 3 days, so fee income decays about 99% in two weeks.

climb time table (market targets, wei per point)
target                          wei per point   hours   days
p10 last 24h                    1.28e13         117     4.9
median last 24h                 2.19e13         171     7.1
p90 last 24h                    5.75e13         268     11.2
median whole window             5.95e13         271     11.3
strategy listing p10            5.39e13         261     10.9
strategy listing median         9.97e13         323     13.5
strategy listing p90            2.72e14         424     17.7
note the target moves: the daily median per point went 7.8e13, 6.4e13, 5.9e13, 6.3e13, 5.8e13, 6.4e13, 6.2e13, 5.4e13, then 2.7e13, 2.1e13, 1.9e13, 2.0e13, 2.6e13 (10/06 partial).
