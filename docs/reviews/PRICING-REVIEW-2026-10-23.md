# Pricing review: every Credit Cycle door against the live market, 2026-10-23

**Takeaway.** The engine prices every Credit as points times the $BALANCE price. The market does not. OpenSea pays a flat floor of about 0.0087 ETH (offers) to 0.0090 ETH (cheapest listings) for any Credit whatever its points, and above that about 1.21 to 1.3 times par per point on the ask side and 0.7 to 0.95 times par on the bid side. So every Credit under roughly 400 points is worth three to five times more to the market as an NFT than to the engine as points, and the engine's Credit sale gives that gap away: the three Credits in the example sold for 31 percent of what the market paid for them within the hour. The market value of a Credit is roughly `max(flat collection offer of about 0.0087 ETH, points value)`. The flat floor dominates below about 480 points at the 2026-10-23 $BALANCE price (364 points when the example Credits were bought at block 26,248,473, 512 when they were sold at 26,252,999), and the collection offers did not move when $BALANCE fell 29.0 percent between those blocks (spot 2.3913e-5 to 1.6987e-5): the offer fills were 0.0086 to 0.0087 WETH at 26,253,153 and the top offer is 0.0087 today. The points value moves with the token; the picture value does not. The ETH bid is not stalled by price. It reads zero because the pot (0.0719 ETH) is under the 0.1 ETH processing reserve, and the pot is being drained 0.0006 ETH every ten minutes by searchers calling the paid `refreshReference` door. The $BALANCE bid is priced correctly for the only Credits it can ever win (over about 500 points) and simply has no sellers yet. Statement sales never happened because the ask (1.8 times par) sits above where Statements now fill (1.0 to 1.5 times par on the bid side). The proposal is in `docs/specs/PRICING.md`; the fork replay is `test/pricing/PricingReplay.t.sol`.

Evidence base: live reads at block 26,255,116 (2026-10-23, about 11:50 UTC) through `https://gateway.tenderly.co/public/mainnet`; Core and ControllerV2 logs from stage B (26,243,776) to 26,255,200; OpenSea best listings (600, six pages), collection offers (50) and the last 50 sales, the credits.ninja feed (40 sales, 40 listings, 24 h stats) and 36 Statement sales decoded from Seaport receipts since block 26,235,000, all taken within the same hour; scores from the live CreditScore contract. The snapshot is `docs/reviews/pricing-2026-10-23/market-snapshot.csv`, the derived tables `market-summary.txt`. Par below means 1 point = 1 $BALANCE at the live spot, 1.784e-5 ETH per point (the protected sale price, `valuePerPoint(true)`, is 1.8136e-5; the buy price 1.784e-5).

## 1. The live state

| item | value | note |
|---|---|---|
| value mode | on | since C5a, block 26,245,505 |
| $BALANCE spot / reference | 1.7840e-5 / 1.8136e-5 ETH | 138 refreshes since 26,244,636; the reference went 2.69e-5 (10-21) to 1.55e-5 (26,251,558, minus 42 percent) and back to 1.81e-5 |
| ETH bid `ethRate()` | **0** | `ethPrice()` 0.001962 per 100 points (1.1 times par), but the pot 0.0719 ETH is under `reserveWei` 0.1 ETH, so the royalty adjusted room is 0 |
| shared instance | 11,000 bps | at the cap `balanceBidCapBps` 11,000 since 26,250,656 |
| $BALANCE bid | 8,000 bps of par | `balanceDiscountBps` 2,000, bid on since 26,248,373; value mode clamp (1.1 times par in tokens) never binds |
| Credit sale | on, window 14,400 s, spread 1,000, start 15,000, `floorMultBps` 12,100 | floor 1.21 times par by points, never under the Core cost floor (`saleFloorBps` 10,000, that is cost) |
| Statement sale | on, multiplier 15,000 | ask 1.5 times (1.21 times par) = 1.815 times par; redeem delay 3,600 s; **no Statement is held**, all 12 converted |
| pile | 15 Credits | 11 of 500 to 770 points at cost 1.21 to 1.72 times par per point, 4 at 2.8 to 9.6 times par (launch era purchases) |
| ETH pot / buyback / reserve | 0.0719 / 0.00159 / 0.1 ETH | |
| treasury | 570,082 held, 513,044 available, 57,037 claim reserve | 9.15 ETH at spot; the engine's value is almost all $BALANCE |
| pool depth | liquidity 5.11e21 | selling 1,000 $BALANCE moves the price 0.17 percent, 50,000 (one Statement) 8.1 percent |
| royalty / cuts | `buyToArtistBps` 300 on top of every purchase, `saleToArtistBps` 300 off every sale, `creditCostToPotBps` 8,000 | |

## 2. What the market actually pays

### Credits, ask side (600 cheapest OpenSea listings, single Credit, ETH)

| points | n | cheapest | median | cheapest per point (times par) | median per point (times par) |
|---|---|---|---|---|---|
| 80 to 200 | 210 | 0.0090 | 0.0129 | 2.71 | 4.86 |
| 200 to 300 | 171 | 0.0091 | 0.0130 | 1.78 | 2.95 |
| 300 to 400 | 126 | 0.0090 | 0.0129 | 1.37 | 2.10 |
| 400 to 500 | 50 | 0.0104 | 0.0129 | 1.28 | 1.72 |
| 500 to 600 | 27 | 0.0129 | 0.0150 | 1.24 | 1.49 |
| 600 to 700 | 11 | 0.0148 | 0.0158 | 1.23 | 1.32 |
| 700 to 800 | 5 | 0.0151 | 0.0167 | 1.21 | 1.29 |

The frontier is `ask = max(0.0090 ETH, 1.21 to 1.3 times par times points)`. Nothing on the whole book lists under 1.21 times par per point; the flat floor binds up to about 420 points. The 24 h stats (credits.ninja): floor 0.00904 ETH, 787 sales, 9.1 ETH volume.

### Credits, bid side (50 collection offers, 50 last sales)

| item | value |
|---|---|
| top collection offer | 0.0087 ETH for any Credit, 25 deep; 0.0085 next; 51 Credits of depth at or above 0.0080 |
| offer fills (33 of the last 50 sales, WETH) | median 0.0087; small Credits (94 to 281 points) fill at 0.0085 to 0.0088, that is 3.4 to 5.5 times par; big ones (636 to 793 points) at 0.0091 to 0.0145, that is 0.71 to 1.07 times par, median about 0.85 |
| listing takes (17 of 50, ETH) | median 0.0092; small Credits at 0.0091, big ones at 1.0 to 1.3 times par |

So the bid side is `max(0.0087 ETH, about 0.85 times par times points)`.

### Where 1 point = 1 $BALANCE holds

Nowhere exactly. Per point the market asks 1.21 to 1.3 times par and bids 0.7 to 0.95 times par for Credits over about 500 points; under about 420 points (ask) and 490 points (bid) the flat NFT floor dominates and the per point price rises to 3 to 5 times par at 100 points. The earlier reading that the market prices at par came from large Credits on the bid side only.

### Statements (36 Seaport sales since block 26,235,000)

Before the $BALANCE token opened transfers (block 26,241,565) Statements sold from listings at 2.3 to 6.0 ETH, 4 to 6 times today's par per rating point (at the $BALANCE price of that time, about 2.7e-5, still 3 to 4 times). Since then every sale but one filled a collection offer: 0.86 to 0.89 ETH for 11k to 18k ratings on 10-21 (2.7 to 4.6 times par), 0.60 to 0.61 ETH on 10-22 (2.1 to 3.1 times par), and on 10-23 0.70 ETH for Statement 52 (38,527 rating, **1.02 times par**), 0.51 ETH for 562 and 563 (18.5k and 21.1k, 1.55 and 1.36 times par). The Statement market is converging on par from above, faster for big ratings. The engine's ask of 1.815 times par (about 1.6 ETH for a 50k Statement) was never inside the bids; the 12 conversions at par (42.5k to 50.2k $BALANCE each, blocks 26,249,166 to 26,249,775) matched what big Statements now fetch.

## 3. Every price the protocol sets or pays

| door | formula (live) | anchored to | live number | market | how it loses or stalls |
|---|---|---|---|---|---|
| ETH bid (`sellForEth`) | `sharedRate * valuePerPoint(false) * 100`, at most `rateCap`, clamped to `(pot - reserve) / 1.03` | $BALANCE buy price times the shared instance (floor 9,000, cap 11,000, climbs 100 bps/min idle, drops 29 bps per 100 points) | 0.001962 ETH per 100 points when funded; **0 now** | above the bid side (0.85 par) and 10 percent under the ask side (1.21 par) for big Credits; far under the flat floor for small ones | pot under the reserve closes it; the reserve is drained by the refresh door (section 5); when open it pays 1.1 par plus 3 percent royalty, that is 1.133 par in ETH for 1.0 par of $BALANCE on conversion |
| keeper listing buys (`buyListing`) | at most `bidOf(id)` and the room; keeper pays itself from the gap | same as the ETH bid | 4 buys in phase 2 (0.0105 to 0.0197 ETH, blocks 26,244,767 to 26,250,681), none since | cheapest listing per point is 1.21 par; the bid tops at 1.1 par, so no listing can fill | structurally idle unless listings fall under the bid or the bid cap rises above the ask side (then it overpays by construction) |
| $BALANCE bid (`sellForBalance`) | `score * 1e14 * 8,000 / 10,000`, lowered to the value mode cap `ethPrice * score / pSell` | par times a flat discount | 0.8 par; cap 1.1 par never binds | seller's alternative is 0.0087 flat or 0.85 par: the bid wins only above 610 points (0.8), 542 (0.9), 503 (0.97) | 3 fills in phase 2, all by the owner wallet (291 $BALANCE for 353 points, 0.0052 ETH at spot, against 0.0259 ETH of OpenSea offers for the same three); the /exchange page shows no market comparison |
| Credit sale (`buyCredit`) | start 1.5 times floor, straight line over 14,400 s to floor `max(cost * 1.0, 1.21 * pSell * points)` | par times points | the pile asks cost (1.21 to 1.72 par) on the big ones; the example asked cost 0.0022 to 0.0031 | ask side floor 0.0090 flat; 1.21 par per point above about 420 points | **sells any Credit under about 400 points for a third of the market**; sells big ones at the market ask (fine); Credits bought at launch rates (cost up to 9.6 par) never sell |
| Statement sale (`buy`) | `max(cost, ceil(1.21 * pSell * rating * 1.5))` | par times rating | 1.815 par | fills at 1.0 to 1.5 par (bid side), 2 to 5 par on the pre-token listings | no sale ever; the Statement converts after 3,600 s instead, so the door is decorative |
| Statement conversion (`redeemStatement`) | `rating * 1e14` tokens measured, 10 percent earmarked | par by construction | 12 conversions, 42.5k to 50.2k $BALANCE each | equals the current bid side for big Statements | none; it is the par anchor itself |
| CC redemption | off (stage D) | | | | PR 190 adds a market priced redeemer at `min(CC ref, spot) / max(BAL ref, spot) * 1.05`, 20k $BALANCE per day: a standing 5 percent arbitrage whose counterparties sell the $BALANCE into the pool |
| artist royalty | 3 percent on top of every purchase, 3 percent off every sale | | | | a round trip through the engine costs 6 percent before any spread; the $BALANCE bid cap must stay at or under 9,700 bps for the treasury not to lose tokens on conversion |

## 4. The example, verified on chain

| Credit | points | paid by the bid | seller got | booked cost | sold to the bot (26,252,995 / 26,252,999) | OpenSea offer filled (26,253,153 to 26,253,158) |
|---|---|---|---|---|---|---|
| 29255 | 97.3 | 80.17 $BALANCE (77.83 + 2.34 royalty) | 0.00139 ETH at spot, 16 percent of the offer | 0.0022278 ETH (1.28 par) | 0.0022278 | 0.0086 WETH (4.95 par) |
| 46817 | 141.1 | 116.27 (112.88 + 3.39) | 0.00201, 23 percent | 0.0031448 (1.25 par) | 0.0031448 | 0.0086 (3.42 par) |
| 109607 | 115.2 | 94.89 (92.13 + 2.76) | 0.00164, 19 percent | 0.0025665 (1.25 par) | 0.0025665 | 0.0087 (4.23 par) |

- The seller into the $BALANCE bid was the owner wallet 0xCB43 (transactions 0xfe5005… at 26,248,473 and 0xb46e3d… at 26,250,092). It received 282.84 $BALANCE, 0.0052 ETH at spot, for Credits the market would have paid 0.0259 ETH for.
- The cost was booked as `ethFloorNow * score`, the value mode ETH bid at the fill: 1.1 times the buy price of that block (2.09e-5 to 2.23e-5), not what the engine paid.
- At the sale the spot had fallen to 1.70e-5, so the value mode floor (1.21 times 1.70e-5 = 2.06e-5 per point) was under the booked cost (2.29e-5) and the Core cost floor held: the three asked exactly cost, 0.0079391 ETH in all. The bot 0x1F35 paid it (0.00571 and 0.00223 in two transactions from 0x55fc), forwarded them to 0x55fc, and 0x55fc filled collection offers for 0.0259 WETH gross, 0.02564 after the 1 percent fee. Bot gross profit 0.0177 ETH; engine share of market value 31 percent.
- The engine kept 0.0077 ETH after the 3 percent artist cut: 0.00635 to the pot, 0.00135 to the buyback. Net of the 291 $BALANCE it paid (0.0052 ETH at spot) it made 0.0025 ETH on a round trip the market valued at 0.0259.
- The rule "never below cost" held. The cost is points times the $BALANCE price, which for a 100 point Credit is a quarter of the NFT floor. The rule protects against selling under what the engine paid, not under what the market pays.

The fork replay (`test/pricing/PricingReplay.t.sol`, pinned at 26,252,994) reproduces the 0.0079391 ETH purchase against the live ControllerV2, then shows the same purchase under a controller that differs only by the Credit floor reference of the proposal: the three ask 0.008858 ETH each (the 0.0086 top offer of that hour plus a 300 bps spread), 0.026574 in all, more than the bot's net resale, so the round trip stops paying and a real buyer pays the engine 3.3 times the recorded sale. A 752 point pile Credit asks the same as before.

## 5. The other symptoms, verified

**The ETH bid is closed by the reserve and a pot leak, not by the $BALANCE price.** `ethRate()` is `min(valueRate, (pot - reserve) / 1.03)`. The pot fell under the 0.1 ETH reserve at about block 26,252,999 and `ethRate()` has read 0 since, whatever `balanceBidCapBps` says (raising it to 11,000 at 26,250,656 raised `ethPrice()` and nothing else). The pot went 0.158 ETH (26,250,681) to 0.111 (26,250,746) through four ETH fills, then to 0.0719 by 26,255,116 while taking in 0.0064 ETH of Credit sales and 0.008 ETH of fees. The difference is the paid refresh door: `Core.refreshReference()` pays its caller `callerFee` 0.0006 ETH plus gas at up to 3 gwei from the pot every time the controller's reference moves, which is every 600 seconds. 89 refreshes since the last fill, each taking 0.000604 to 0.000608 ETH from the pot, 0.054 ETH in all, called by searchers (0xBb13…, 0x225F…), not the keeper, which calls the controller directly and unpaid (decision 273). At 0.087 ETH a day this door alone outruns the fee income of the last two days (0.17 ETH). With the pot under the reserve nothing can be bought in ETH no matter how the bid is priced.

**The $BALANCE bid buys almost nothing because it cannot.** At 0.8 par it beats the market only for Credits over 610 points (the flat 0.0087 offer equals 0.8 par at 610 points). Sellers of big Credits get 0.85 par from OpenSea offers in WETH; the engine offers 0.8 par in $BALANCE that costs 0.3 percent plus 0.1 percent of impact to sell. There were no non-owner fills. Raising the discount to 9,000 or 9,700 bps moves the break-even to 542 or 503 points and puts the engine above the market's bid side for every big Credit; above 9,700 the treasury pays out more $BALANCE (with the 3 percent royalty) than the Credit brings back on conversion.

**Statements at 1.5 times produced no sales** because 1.5 times the 1.21 reference is 1.815 par, and Statements now fill at 1.0 to 1.5 par on the bid side. The Statement was then converted after an hour, so the sale door never had a buyer or time. Converting a big Statement at par is currently the right trade (0.70 ETH for a 38.5k rating is where the bid side sits); a sale at 1.05 to 1.2 par would beat it when ETH is the scarce asset, which it is.

**"The market prices Credits, Statements and $BALANCE at 1 point = 1 $BALANCE"** holds within 20 to 30 percent for Credits over 500 points and for big Statements on the bid side only. It breaks completely under about 420 points, where the NFT floor sets the price, and it breaks by 20 to 30 percent on the ask side for every size.

## 6. Every way the design loses value or stalls, with numbers

1. **Small Credit giveaway.** Any pile Credit under about 400 points is asked at 1.21 par by points (0.0022 to 0.0087 ETH) while the market pays at least 0.0087. The example lost 0.0177 ETH on three Credits; the four small Credits bought at launch rates sit at cost and will never sell, but every future small Credit from either bid will leave at a third of its value.
2. **The $BALANCE bid pays sellers a fraction of the market for small Credits** (16 to 23 percent in the example) with no warning on /exchange. Sellers who notice will not come back; sellers who do not notice are overcharged by the design.
3. **The paid refresh door drains the ETH pot** at 0.0006 ETH per 600 seconds (0.087 ETH a day), above the fee income, and keeps the pot under the reserve, so the ETH bid reads 0 and the keeper buys nothing.
4. **The ETH bid, when funded, pays 1.1 par plus 3 percent royalty, 1.133 par in ETH, for Credits that convert to 1.0 par in $BALANCE.** Against the market's bid side (0.85 par) it overpays by 33 percent; against the ask side it is 10 percent under, so it never fills a listing and takes every direct seller. Each ETH point bought this way turns 1.133 par of the scarce asset into 1.0 par of the abundant one.
5. **Booked cost is a price, not a payment.** A $BALANCE bought Credit is booked at the ETH bid of the moment, not at the $BALANCE paid (0.0022 booked against 0.0014 paid in the example). The never-below-cost rule then protects a number that moves with the $BALANCE price between the fill and the sale (down 25 percent here), so the ask can rest on a cost floor that is both below the market and above the value mode floor.
6. **The Credit sale floor and the ETH bid share one multiplier chain** (`floorMultBps = (1 + spread) * balanceBidCapBps`). PR 190 lowers the cap to 10,000, which lowers the sale floor to 1.1 par while the market asks 1.21 to 1.3: big Credits would then sell 9 percent under the ask side and bots would list them back at 1.21.
7. **Statement sale ask 1.815 par against bids of 1.0 to 1.5 par**, with a 3,600 s conversion delay: the door cannot sell. PR 190's 1.21 par (multiplier 11,000 over a 1.1 reference) with the same hour is closer but still untested against a thin book.
8. **The ETH side is starved by construction.** Inflows are coin fees (0.17 ETH in two days), Credit resale (80 percent of cost to the pot) and Statement sales (none). The treasury holds 9.15 ETH of $BALANCE it never sells. Every ETH purchase converts into $BALANCE. Without a priced Statement sale or Credit sale that actually clears, the ETH bid is a one way drain.
9. **The 1.21 floor is a coincidence.** It equals (1 + 1,000) times 11,000 bps and happens to match today's ask side. It does not follow the market; the owner tunes it by hand.
10. **The market priced redeemer (PR 190) is a 5 percent standing arbitrage**: buy CC, burn for $BALANCE at 1.05 times the cross rate, sell the $BALANCE. Capped at 20,000 a day (about 1,000 $BALANCE a day given away, 0.018 ETH) and off by default; the counterparties' sales are the protocol selling $BALANCE one step removed.
11. **Keeper listing buys cannot execute** while the bid cap (1.1 par) is under the cheapest listing per point (1.21 par); the keeper's discovery, signing and gas run for nothing.
12. **Pool manipulation windows** remain those of ControllerV2 (reference step 1,000 bps per 600 s at 6,000 bps per hour; the same block guard takes the worse of sample and spot). A 10 percent move every ten minutes is allowed by the quote; the ask floor and the bid follow it. Not a loss today, a bound.

## 7. What PR 190 (ripe0x/cc#190, head 01a22d1) gets right and wrong

Keep: the treasury buckets and the cushion; the permissionless `sellCredit` bid with a climb while idle and a drop per fill; the loop guard (`creditSoldAt` plus the clamp under `floorMultBps`); the pluggable redeemers with per period caps and the one day start delay; the quote step 900; ControllerV3 carrying every ControllerV2 view.

Change: the $BALANCE bid cap from 10,000 to 9,700 bps (break-even with the 3 percent royalty, decision 284 said never above par and the royalty is paid on top); the Credit sale floor must gain the market floor term before the cap drops to 10,000, or `creditSpreadBps` must rise to 2,000 so the per point floor stays at 1.2 par; the Statement ask multiplier from 11,000 to 10,000 on the 1.2 reference (1.2 par) and the redemption delay back to 7 days as decision 280 had it, since the ask is now inside the market; the idle loosening stays shipped at 0 (decision 285), the ETH bid never needs to exceed par.

Remove or hold: the market redeemer's 500 bps premium (set 0 to 200, or hold it until the ETH side is funded); `callerFee` 0.0006 on the Core is a Core setting, not PR 190's, but the SetSettings send PR 190 already plans (`balanceBidCapBps` 10,000) is the place to set `callerFee` 0 as well.

Add (this proposal): the Credit floor reference on ControllerV3 (section 3 of the spec), the keeper posting it, the /exchange comparison. It fits in PR 190 as one more ControllerV3 feature and one more keeper door; nothing in treasury v2 changes.

## 8. Limits of this review

- The market snapshot is one hour on one day with the $BALANCE price 34 percent below its 10-21 level; the multipliers (1.21 ask, 0.85 bid, 0.0087 floor) are observations, not constants.
- OpenSea's key-less API served the first 600 listings and 50 sales; sales beyond the first page need a key. The Statement sample is 36 fills over three days.
- The fork replay deploys an evidence copy of ControllerV2 with the floor term (`test/pricing/ControllerV2Floor.sol`); it is not the production change, which goes into ControllerV3 after acceptance. The Core's own state at the pin is the live state.
- No cost of gas or MEV to the counterparties is modeled; the bot's 0.0177 ETH is before its gas.
