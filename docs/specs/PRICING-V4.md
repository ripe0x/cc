# ControllerV4: one valuation, one bid on two rails, Statements as the ETH exit

Status: specification for the owner's acceptance, 2026-10-23, revision 2 (loop closure corrected, two ask spreads, break-even table, stranded inventory, alternatives), forked off PR 190 (`claude/treasury-v2-controller-v3-8a3081`, head f5aad37). It replaces ControllerV3 with ControllerV4 in that PR's deploy and keeps treasury v2's code as it is; the rest is settings. The evidence is `docs/reviews/PRICING-REVIEW-2026-10-23.md` (main); the incremental alternative is `docs/specs/PRICING.md` (main). The Core is immutable; section 9 lists what that keeps out of reach.

## 1. What the engine is for

A Credit has two values. Its picture value is the flat collection offer any Credit fetches on OpenSea (`F`, about 0.0087 ETH on 2026-10-23), set by collectors, unmoved by a 29 percent fall in $BALANCE. Its points value is `P × points` (`P` the $BALANCE price in ETH), realizable only by composing 80 Credits into a Statement and converting at par. Royalties take 3 percent on every engine buy and 3 percent off every engine sale, so flipping pictures (a 3 to 4 percent market spread) loses money. **The one trade with margin is: buy points under par, compose, sell the Statement for ETH at a premium over par, or convert at par as the floor.** That trade is the Credit Cycle: $BALANCE buys points, points become Statements, Statements become ETH at a premium or $BALANCE at par, ETH buys more points or burns CC, surplus $BALANCE backs CC. Every price below serves that trade and nothing else.

## 2. The valuation and its two references

`V(credit) = max(F, P × points)`.

| reference | source | bounds | on failure |
|---|---|---|---|
| `P` (ETH per $BALANCE; `P_buy` for bids, `P_sell` for asks) | ControllerV2's protected reference on the v4 pool, unchanged: prior block sample, rate and step bound, liquidity gate, worse of sample and spot per side | `Quote` as PR 190 ships (step 900, rate 6,000 per hour, tol 100, minSeconds 600, minLiquidity 3e21) | unusable quote: every value mode bid and ask closes (today's rule) |
| `F` (ETH per Credit, the picture floor) | the top executable collection offer, posted by the keeper or the owner | band `[minWei, maxWei]`, at most `stepBps` per post for the keeper, `minSeconds` apart; the owner posts anything inside the band | no post or a stale post: the last value stands. Only asks read `F`, so a wrong `F` can only mis-set an ask, never a bid |

Spreads are three owner numbers. `bidHaircutBps` under par on every bid. `askSpreadBps` over the points value and `floorSpreadBps` over the picture floor on every ask: `ask floor = max(F × (1 + floorSpread), P_sell × points × (1 + askSpread))`. Two ask spreads because the two markets have different widths: pictures trade 3 to 4 percent wide (offer 0.0087, listing 0.0090), points 40 percent wide (bid 0.85 par, ask 1.21 par). One spread would either overprice small Credits out of the market or underprice big ones.

Loop closure is about the attacker, who pays the ask and receives the bid whole (royalties fall on the engine, not on them): `(1 + askSpread) × (1 - tol) ≥ cap × (1 - bidHaircut) × (1 + tol)`, with `cap` the Core's `balanceBidCapBps`. At cap 10,000, haircut 300, tol 100 the ask spread must be at least 230 bps; 2,000 leaves room for the owner to lower the haircut to 0. Floor class Credits need no closure term: their bid is per point and sits far under `F`. The setters check the inequality on every change of a spread, the cap or the tolerance. The market's own multipliers (1.21 par asks, 0.85 par bids on 2026-10-23) are not references; they are what the owner reads off `/market-compare` when tuning the spreads.

## 3. Every door

| door | price | settings | why |
|---|---|---|---|
| the bid, ETH rail (`sellForEth`, `buyListing`) | `shared × P_buy × (1 - bidHaircut) × points`, `shared` the Core's instance in `[1 - balanceBidMarginBps, balanceBidCapBps]`, clamped to the funded room | `balanceBidMarginBps` 1,500 (floor 0.85 par), `balanceBidCapBps` 10,000, `bidHaircutBps` 300, climb 100 bps per minute, drop 29 bps per 100 points, `callerFee` 0, `reserveWei` 0.02 ETH | the Core's instance is the one adaptive spread: it opens at the market's bid side, climbs to 0.97 par while idle, drops on fills. The haircut is the royalty, so a point never costs more than the $BALANCE point it becomes. `callerFee` 0 ends the 0.0006 ETH per 600 s searcher drain; the keeper refreshes unpaid |
| the bid, $BALANCE rail (treasury v2 `sellCredit`) | the same ETH value in tokens: `ethPrice × points / P_sell` with `overEthBps` 0, `floorBps` = `capBps` = 10,000, so the treasury's own band never sets the price | `BalanceBid{10,000, 10,000, 0, 1, 1, 0, 20,000, 60,000}` (floor, cap, climb, step, drop, overEth, per call, per day; climb and drop at the smallest values `setBid` accepts), `cushion` 150,000 | one quote per Credit whichever rail pays. The treasury reads `ethPrice()`, the value rate before the pot clamp, so the $BALANCE rail keeps quoting while the ETH rail reads 0 for want of a pot: the seller gets ETH while the pot has room, $BALANCE otherwise (the web picks the rail; both doors stay public). Treasury code unchanged: its existing eth bound does the work |
| Credit ask (`buyCredit`) | start `creditStartBps` of the floor, straight line over `creditWindow` to the floor; **floor = `max(cost × saleFloorBps, F × (1 + floorSpread), P_sell × points × (1 + askSpread))`** | `floorSpreadBps` 300, `askSpreadBps` 2,000, `creditStartBps` 15,000, `creditWindow` 14,400, Core `saleFloorBps` 5,000 | the ask is never under the picture nor under the points plus the spread. The Core cost floor stops being the operative floor and becomes the owner's loss guard: half of cost. The example Credits ask 0.00896 each (`F` 0.0087 × 1.03, just under the 0.0090 listing floor, so the engine is the cheapest ask and sells first) instead of 0.0022 to 0.0031; the pile's big Credits ask 1.2 par as today |
| composition (`nextPage`, `composeChosen`) | a Credit is floor class when `P_sell × points < F`; floor class Credits are never composed, they are for sale at the picture price | `classify(ids)` caches each Credit's points once (anyone, the keeper on intake); `nextPage` walks the pile oldest first and skips floor class Credits inside the Core's 500,000 gas probe, not ready when 80 are not found in budget; the keeper composes chosen pages (`chosenComposeOn` true, `minCcToChoose` the keeper's holding) of the 80 highest point window-past Credits | a page of 80 small Credits is an 8,000 $BALANCE Statement for the same 11.5M gas as a 56,000 one; small Credits are worth more as pictures |
| Statement ask (`buy`) | Dutch: `P_sell × rating × startBps` at composition, straight line over `statementDecaySeconds` to `P_sell × rating × (1 + askSpread_statement)`, then rests; never under `cost × saleFloorBps` | `statementStartBps` 20,000, `statementDecaySeconds` 604,800, `statementFloorBps` 11,000, `statementRedeemDelaySeconds` 604,800 | collectors paid 4 to 6 par before the token and 1.0 to 1.5 par since; a week from 2 par to 1.1 par finds the buyer if there is one, and conversion at par takes it after. ETH is the scarce asset; a sale at 1.1 par returns 10 percent more than conversion in it |
| Statement conversion (`redeemStatement`) | par, unchanged | eligibility: age ≥ `statementRedeemDelaySeconds` | the floor of the Dutch auction |
| CC redemption (treasury v2 redeemers) | redeemer 1 pro rata `ccIn × bucket / supply`, on; redeemer 2 (market) premium 0, off | sweep shares 2,500 bid, 7,500 redeemer 1 | backing per CC is the coin's value story and rises as the cycle runs; a market premium is a drain whose counterparties sell $BALANCE for the protocol |
| keeper listing buys | unchanged: at most the bid; the keeper stops discovery and signing while `ethRate()` reads 0 | | |

Numbers at the 2026-10-23 state for a 700 point Credit: bid opens at 0.85 × 0.97 × par = 0.0103 ETH (market bid side 0.0106, OpenSea top offer 0.0087), climbs to 0.0121; ask floor 1.2 par = 0.0150 (cheapest listing 0.0151). For a 100 point Credit: bid 0.00147 to 0.00173 (the market pays 0.0087, the engine does not compete and should not); ask floor 0.00896.

Break-even per point, the engine's side (royalty 3 percent on top of every buy, 3 percent off every sale):

| trade | engine pays | engine receives | margin |
|---|---|---|---|
| buy a big Credit at the bid cap, convert | 0.97 par + 3 percent = 0.999 par (ETH or $BALANCE) | 1.0 par in $BALANCE | 0 at the cap, +12 percent at the band floor |
| buy at the cap, sell the Statement at the curve floor | 0.999 par | 1.1 par × 0.97 = 1.067 par in ETH | +6.8 percent, in the scarce asset |
| buy at the cap, sell the Credit at the ask floor | 0.999 par | 1.2 par × 0.97 = 1.164 par in ETH | +16.5 percent |
| sell a floor class Credit at the picture floor | the bid it was bought at (per point, far under `F`) | `F` × 1.03 × 0.97 = 0.999 `F` | the whole gap between points and picture value, 3 to 5x for Credits under 150 points |
| compose a floor class Credit (what V3 does) | `F` worth of picture | its points in $BALANCE | minus 70 to 80 percent |

Stranded inventory: the four launch era pile Credits (cost 2.8 to 9.6 par per point) ask `max(cost × 0.5, V × spread)` under V4. The three big ones compose. 75067 (139.5 points, cost 0.0235) asks 0.0118 against a 0.0090 market and waits for the floor to rise 30 percent or for the owner to lower the guard; that is the price of a cost guard, chosen over selling it at a 55 percent loss today.

## 4. ControllerV4, the deltas from ControllerV3

New file `src/ControllerV4.sol` next to V3, V3 stays in the tree. Carried unchanged from V3: the protected reference, `refreshReference`, `valuePerPoint`, `balanceClampFor`, `creditSoldAt`, the CC reference and prior samples, `setBalancePoolKey`, `setQuote`, the legacy views, the Core-facing surface the keeper, indexer and web read.

1. **Spreads.** `bidHaircutBps` (0 to 2,000) applied inside `valuePerPoint(false)`, which the Core's ETH bid, its booked cost and the treasury's eth bound all read; `askSpreadBps` (loop closure lower bound to 5,000) and `floorSpreadBps` (0 to 5,000) replace `creditSpreadBps` and the `floorMultBps` chain: `floorMultBps()` answers `10,000 + askSpreadBps` for the legacy readers (treasury v2's `_fillBps` clamp among them) and no longer reads `balanceBidCapBps`. Setter `setSpreads(bidHaircut, askSpread, floorSpread)` checks loop closure against `quote.tolBps` and the Core's live `balanceBidCapBps`; `setQuote` rechecks it.
2. **Credit floor reference.** `creditFloorWei`, `creditFloorTime`, `floorPoster`, `FloorBounds{minWei, maxWei, stepBps, minSeconds}`; `setFloorBounds`, `setFloorPoster`, `postCreditFloor`, view `creditFloor()`. The exact code is `test/pricing/ControllerV2Floor.sol` on main less the spread field, which moves into `askSpreadBps`.
3. **Idle loosening removed.** V3's `IdleLoosening`, `fillHint`, `syncFill`, `idleSince`, `idleLoosenBps` go; the Core's instance is the one adaptive element. (PR 190 ships them at cap 0 already.)
4. **Page rule.** `classify(uint256[] ids)` stores `points` (uint16, whole points, from the score contract, immutable so cached once) per id; `isFloorClass(id)` = `P_sell × points < creditFloor()`, read at the walk, so a Credit near the boundary can change class as `P` moves (harmless: both doors price it either way); `nextPage` walks `pilePage(0, n)` in slices, skipping floor class and unclassified ids, returns ready with the first 80 window-past non floor ids or not ready when the walk passes `PAGE_WALK` (an owner bound under the Core's 500,000 gas probe, about 120 ids). The keeper classifies on every intake event and composes chosen pages; public `compose` keeps working as the fallback.
5. **Statement Dutch curve.** `StatementCurve{startBps, decaySeconds, floorBps}` replaces `statementSaleMultiplierBps`; `priceOf` = `max(cost × saleFloorBps / 10,000, ceil(P_sell × rating × curve(age)))` with `curve` linear from `startBps` to `floorBps` over `decaySeconds` of age outside pauses (the Core's `statementAge`); `atFloor` = age ≥ `statementRedeemDelaySeconds` as in V3; `markupBps()` answers `startBps` clamped to uint16 (the Core bounds `saleFloorBps` by it, so `saleFloorBps` 5,000 ≤ 20,000 holds).
6. **Events** `SpreadsSet(bidHaircut, askSpread, floorSpread)`, `CreditFloorPosted`, `FloorBoundsSet`, `FloorPosterSet`, `Classified(id, points)`, `StatementCurveSet`.
7. **Size.** V3 is 19,791 bytes; the loosening removal frees about 1.2 KB, the additions take about 2.5 KB; expected under 21,500, inside EIP-170 with margin. Re-pin `script/Checks.sol` and `test/BuildIdentity.t.sol`; regenerate `IControllerV4.sol` with `script/tools/gen-interfaces.sh`.

Treasury v2: no code change. `Phase3.params()` sets the bid band to 10,000 / 10,000 with `overEthBps` 0 and `dropPer100PointsBps` 1 (its lower bound), so the Core's instance alone moves the price.

## 5. Settings

| where | field | value | bound | reason |
|---|---|---|---|---|
| Core | `balanceBidMarginBps` | 1,500 | ≤ 9,999 | bid opens at the market's bid side |
| Core | `balanceBidCapBps` | 10,000 | ≥ 10,000 | never above par |
| Core | `climbPerMinBps` / `recoveryClimbPerMinBps` | 100 / 100 | ≥ 1 | 0.85 to 1.0 in about 100 idle minutes |
| Core | `dropPer100PointsBps` | 29 | 1 to 9,999 | a 700 point fill drops the bid 2 percent |
| Core | `saleFloorBps` | 5,000 | ≤ controller `markupBps` | the cost floor becomes a loss guard, the market floor operates |
| Core | `callerFee` | 0 | | ends the refresh bounty; compose and redeem callers get the gas refund at `callerMaxBaseFee` |
| Core | `reserveWei` | 0.02 ETH | | lets a small pot bid; refunds compose gas in full under 1 gwei |
| Core | `chosenComposeOn` / `minCcToChoose` | true / the keeper's CC holding | | the keeper composes chosen pages |
| V4 | `bidHaircutBps` / `askSpreadBps` / `floorSpreadBps` | 300 / 2,000 / 300 | loop closure; floor spread 0 to 5,000 | royalty under par; 1.2 par asks at today's ask side; picture asks just under the listing floor |
| V4 | floor bounds | 0.004 to 0.03 ETH, step 1,000, 600 s; poster the keeper | | |
| V4 | `creditStartBps` / `creditWindow` | 15,000 / 14,400 | unchanged | |
| V4 | Statement curve | start 20,000, decay 604,800, floor 11,000; redeem delay 604,800 | floor ≥ 10,000 | |
| treasury v2 | bid | floor 10,000, cap 10,000, climb and drop at their smallest accepted values, overEth 0, 20,000 per call, 60,000 per day | `setBid` refuses cap > 10,000 and a cap at or above `floorMultBps` (12,000 here) | one price on both rails |
| treasury v2 | redeemer 1 on, redeemer 2 premium 0 and off, shares 2,500 / 7,500 | | | |

## 6. Migration

PR 190's `script/Phase3.s.sol` with ControllerV4 in place of V3 in `deploy`, `migrate` and `readback`; the same order (v1 off, `setBalanceModule(v2)`, v1 `migrateTo(v2)`, v2 settings, redeemers, sweep, V4 pool key and quote, Statement sales on, `setController(V4)`), plus in `migrate`: `setSpreads`, `setFloorBounds`, `setFloorPoster`, the first `postCreditFloor` from the top offer of the hour, `setStatementCurve`, and the Core `setSettings` fields of section 5 in one send through `script/SetSettings.s.sol`. The v2 bid turns on in its own send at least `returnLockSeconds` after `setController(V4)` (decision 278). Every owner send: from the main checkout, the no-keystore dry run with `--sender 0xCB43078C32423F5348Cab5885911C3B5faE217F9` and its gas estimate first, then `--account ripe0x --broadcast --slow`.

## 7. Off chain

- Keeper: `postCreditFloor` from the top executable collection offer when it moved more than 300 bps and 600 s passed; `classify` on every `CreditBought`, `ListingBought` and `CreditAdopted`; `composeChosen` of the 80 highest point window-past non floor Credits once the pile holds 80 of them; discovery and listing signing off while `ethRate()` is 0.
- Web: `/exchange` shows one quote per Credit, the rail it pays on, and the OpenSea offer beside it, marking floor class Credits "worth more on OpenSea"; `/market-compare` adds the floor, the two spreads and the market's bid and ask multipliers; Statement pages show the Dutch curve and the conversion date.
- Indexer: the new events; the page composition reads `Composed` as today.

## 8. Acceptance on a fork pinned at 26,252,994 or later, each once

1. The example replay: the three Credits ask `F × 1.2` under V4 and the recorded 0.0079391 ETH purchase reverts `Underpaid`.
2. One quote, two rails: for the same Credit `bidOf(id)` in ETH and treasury `quoteCredit(id)` in tokens agree at the protected price within rounding, and the treasury pays nothing above the ETH rail's value.
3. Loop closure: buying at the ask and selling to either rail loses at the band edges after the return lock, with real pool moves of plus and minus the quote tolerance.
4. Page rule: a pile of 90 with 15 floor class Credits composes the 80 non floor ones through `nextPage` within the Core's probe gas and through `composeChosen`; the floor class ones stay for sale.
5. Statement curve: a held Statement's `priceOf` falls from 2 par to 1.1 par over the week, never under the cost guard, and `atFloor` turns true at the delay; a sale at the floor returns more ETH than its conversion would $BALANCE at par.
6. Floor poster bounds: clamped, step bound, interval bound, owner override.
7. Build identity and size pins; `gen-interfaces.sh --check`.
8. Settings: `saleFloorBps` 5,000 accepted against `markupBps` 20,000; `callerFee` 0 pays the searcher nothing and the keeper's refresh still moves the reference.

## 9. Alternatives considered

- A per point multiplier instead of `F`: the break-even between picture and points value moved from 364 to 512 points in four hours on 2026-10-23 as $BALANCE fell; no per point number tracks a flat floor.
- Refusing Credits under a points threshold at the bids: they already do not come (the market pays 3 to 5 times more); the refusal only loses the few that do. Pricing by `V` and the floor class page rule keep them out of pages without refusing them.
- The engine selling into OpenSea collection offers itself: a new Core door, and the Core is immutable. At an ask just under the listing floor a bot carries the Credit to the market for the spread, which is the same outcome.
- An oracle for the market's per point multipliers: a wrong value costs a spread, not a giveaway, and the numbers move over days; owner tuned spreads are enough.
- Keeping two independent bids (ETH instance and a treasury band): two prices for one Credit means the lower one never fills and the higher one sets the engine's cost; one quote removes the gap and the clamp machinery around it.

## 10. What the Core keeps out of reach

- The booked cost of a $BALANCE bought Credit stays `ethFloorNow × points`; V4 makes it irrelevant to the ask (the cost guard is 50 percent of it) but cannot change the record.
- The Core's ETH bid cannot read `F`; it never needs to, the engine does not buy pictures.
- The instance machinery (climb, drop, peak, recovery) cannot be removed, only parameterized; V4 uses it as the one spread rather than fighting it.
- `nextPage` runs inside a 500,000 gas probe, so the on-chain page walk is bounded; the keeper's chosen pages carry the rest.
- `refreshReference` through the Core stays public; with `callerFee` 0 it pays the gas refund at most, which a searcher cannot profit from.

## 11. Decisions for the owner

1. ControllerV4 as PR 190's controller instead of V3 (this document), or V3 plus the incremental `PRICING.md` step first. Recommended: V4, since V3 has not been deployed and the deltas are one file.
2. `saleFloorBps` 5,000: the Core cost floor becomes a loss guard rather than the operative floor. Recommended; the alternative keeps the four launch era Credits and every future bad buy unsellable.
3. Statement curve 2 par to 1.1 par over 7 days, conversion after. Recommended; the owner set 1 hour on 2026-10-23 before the Statement market data existed.
4. Redeemer 2 premium 0 and off; redeemer 1 on. Recommended.
5. Bid band 0.85 to 0.97 par (margin 1,500, haircut 300). Recommended; the owner may prefer a narrower band.
6. Ask spreads 300 over the picture floor and 2,000 over the points value. Recommended; the floor spread keeps the engine the cheapest picture ask, the points spread sits at today's ask side.
