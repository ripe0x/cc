# flow rework: director brief

binding for branch `flow`. where it conflicts with SPEC.md or docs/ARCHITECTURE.md, this file wins. the owner's goal changed: the engine exists to keep credits flowing into statements. statement sales do not need to profit. unsold statements are fine: they wait for phase 2 and are redeemed through the exitModule.

naming rule: only `exitModule` and `exitToken`. never name or describe them.

## 1. owner decisions (all confirmed by the owner)

| # | decision |
|---|---|
| 1 | buy credits at one limit per credit (flat), not per score point. a dial lets the owner blend score back in later |
| 2 | never stop buying because statements are unsold. remove the inventory gate entirely |
| 3 | every economic setting is adjustable by the owner after deploy, effective at once. nothing economic is a constant or an immutable |
| 4 | statements are sold by english auction on the live pnd auction house, reserve 90% of the statement's cost |
| 5 | the opening limit is set on launch day at about 75% of the market price of a credit |
| 6 | the split of sale proceeds between the pot and the buyback is an adjustable setting |
| 7 | the controller, the exit module and the allowed targets keep the 7 day timelock |
| 8 | the owner can never transfer eth, credits, statements, coin or exit token out directly: no call moves them to an address the owner picks. this stays true under every combination of settings. what it does not mean: the owner sets the price the engine pays, so a dishonest owner or a stolen owner key could drain the eth pot by selling credits to the engine at an inflated limit. the owner accepted that economic control (every setting adjustable at once, no timelock, no raise guard). the bounds below cap how fast it goes: at most 50% of the pot per transaction (47.4% measured) and 99.99% per day with every setting loosened (98.96% per day with only `setRate` at the launch settings), measured in `test_ACCEPTED_ownerCanOverpayAnAccompliceSeller` and `test_ACCEPTED_ownerPerDayWorstCase`. holders therefore trust the owner key |

## 2. settings

one `Settings` struct in Core storage, one owner function `setSettings(Settings)` that validates sanity bounds and emits the whole struct, plus `settings()` view. bounds are wide and exist only to stop typos and to keep rule 8 true (tips, reimbursements and keeper rewards stay capped so settings cannot become a withdrawal path). every function that depends on a setting reads storage. a settings change checkpoints the eth rate and the exit rate first so no climb is credited under the wrong numbers.

| setting | launch value | bounds | meaning |
|---|---|---|---|
| flatBps | 10_000 | 0 to 10_000 | share of the bid that is flat per credit. price = rate * (flatBps * avgScore + (10_000 - flatBps) * score) / 10_000 / 1e4, before the controller bonus |
| avgScore | 4_330_000 | 800_000 to 6_000_000 | the score a flat credit is priced as, and the "average credit" in the funded rule |
| climbBaseBps | 100 | 0 to 1_000 | per hour |
| climbDoubleEvery | 24 hours | 1 hour to 30 days | |
| climbMaxBps | 800 | climbBaseBps to 2_000 | per hour |
| dropBps | 2_000 | 500 to 5_000 | |
| spendCapBps | 2_000 | 100 to 5_000 | per hour window |
| bonusCapBps | 2_500 | 0 to 5_000 | |
| tipSavingsBps | 1_000 | 0 to 2_500 | |
| tipCapBps | 200 | 0 to 500 | |
| reimburseBps | 11_000 | 0 to 15_000 | of gas cost |
| reimburseCapBps | 500 | 0 to 1_000 | of statement cost |
| reserveBps | 9_000 | 3_000 to 40_000 | auction reserve as bps of statement cost |
| auctionDuration | 24 hours | 6 hours to 30 days | runs from the first bid |
| exitAfter | 72 hours | 1 hour to 365 days | how long an eth lane statement must have been listed without a bid before it may be redeemed in phase 2 |
| saleToBuybackBps | 5_000 | 0 to 10_000 | share of sale proceeds to the coin buyback, rest to the pot |
| exitToBuybackBps | 5_000 | 0 to 10_000 | share of exit token from eth lane exits to the coin buyback |
| buybackSlice | 1 ether | 0.01 to 5 ether | |
| buybackDelay | 25 | 1 to 7_200 blocks | |
| keeperTipBps | 50 | 0 to 500 | |
| xRateCap / xRateFloor | 9_700 / 3_000 | floor <= cap <= 10_000 | |
| xRateClimbPerHour | 100 | 0 to 1_000 | |
| xRateDropPerCredit | 20 | 0 to 1_000 | |
| xAuctionHalfLife | 6 hours | 10 minutes to 30 days | |
| exitSliceCredits | 20 | 1 to 1_000 | |
| rateCap | 123_200_000_000_000 (8 * rateStart) | the rate bounds, 1e11 to 1e15 | wei per whole point. the eth rate never exceeds it: the climb stops at min(funded clamp, rateCap), `setRate` refuses above it, a lower cap pulls the rate down at the checkpoint. "never pay more than this per credit" |
| exitLaneToBuybackBps | 0 | 0 to 10_000 | share of exit token from EXIT lane exits to the coin buyback, the rest to `xPot`. last field of the struct (section 8) |

also owner settable at once, each with its own small function and event: `setRate(uint256)` (resets the current eth limit, bounded to the rate bounds and to `rateCap`, checkpoints), `setXRate(uint256)` (within floor and cap). the funded rule (the hourly cap must afford one average credit) is logic, not a setting. `rateStart` stays a constructor input. nothing else is immutable except addresses of external contracts and the owner.

the skim split (9.5 points to the engine, 0.5 to the creator) is fixed inside the artcoins pool at launch and cannot be made adjustable here. say so in the docs.

## 3. flat bid

`_ceiling(id)` uses the blended score above, then the controller bonus as before. with flatBps 10_000 the score contract is not read on the eth doors (save the gas). the exit token bid stays per point (phase 2 pays by rating). cost basis, piles, compose are unchanged. launch day rule for docs/DEPLOY.md: rateStart = 0.75 * (market price of one credit in wei) * 1e4 / avgScore, default in config 1.54e13 (0.0089 eth market).

## 4. statement sales on the pnd auction house

live factory: `SovereignAuctionHouseV2Factory` 0x77aB853543286C9Cdd7dd6c01222A7cC4Ac93d63 (verified; source saved under docs/reference/pnd/). facts read from the source:
* `createAuctionHouse()` deploys a non upgradeable clone owned forever by msg.sender. one per address. fee is fixed at the factory default (0 now).
* `createAuction(tokenId, tokenContract, duration, reservePrice, listingExpiry)` is owner only, pulls the token into the house with transferFrom (needs approval), returns an auction id. `getAuctionFor(token, id)` and `getAuction(id)` read it.
* before the first bid the token owner can `cancelAuction` (token returns) or `setAuctionReservePrice`. after the first bid neither is possible.
* bids: first bid at or above reserve starts the timer (duration), later bids need +5%, a bid in the last 15 minutes extends 15 minutes, the previous bidder is refunded in the same call (30k gas, else credited).
* `endAuction` is permissionless after the end: delivers the token to the winner, then pays the seller. a seller that is a CONTRACT is never pushed eth: the proceeds are added to `pendingRefunds[seller]` and the seller pulls them with `withdrawRefund()`.
* if delivery to the winner fails it is deferred; after 30 days anyone can unwind: the winner is refunded and the token goes back to the seller with a plain transferFrom.

design:
* the Core owns its own house: it calls `factory.createAuctionHouse()` in its constructor, stores the house address, and approves the house for all on Statements.
* compose (eth lane): after minting, the Core lists the statement: `createAuction(sid, Statements, auctionDuration, cost * reserveBps / 10_000, 0)` and records the auction id on the statement. the dutch auction (`priceOf`, `buyStatement`, AUCTION_START_X, AUCTION_FLOOR_X, AUCTION_LENGTH) is deleted.
* `collectSales()`, permissionless, guarded: if `house.pendingRefunds(core) > 0`, call `withdrawRefund()`, measure the eth balance delta under the measuring flag, split it by `saleToBuybackBps` into `ethToBuyback` and `ethPot` (checkpoint first). the Core never bids, so everything credited to it in the house is sale proceeds. `buyback()` calls the same collection first so proceeds are never stranded.
* statement state is settled lazily and permissionlessly with `syncStatement(sid)`: if the Core's record says listed but the house has no auction for it and neither the house nor the Core owns it, it was sold: clear the record (emit `StatementSold`). if the Core owns it and it has no auction (unwound sale, or returned), relist it at the current reserve. `heldStatements()` may include sold statements until synced; add a view that reports the live status.
* phase 2 exit of an eth lane statement: allowed when the module is set, the statement is listed, has no bid, and `now >= listedAt + exitAfter`. the Core cancels the listing (this reverts if a bid arrived) and then exits exactly as before (balance delta check against `rating * unitPerPoint`). the exit lane is unchanged (immediate exit, never listed).
* overprint: both statements must be listed with no bid; cancel both, overprint, relist the base with the summed cost.
* reserve changes: `repriceStatement(sid)` permissionless: sets the listing's reserve to `cost * reserveBps / 10_000` if it has no bid (so a settings change can be applied to old listings).
* a bidder interacts with the house directly (`createBid`, `endAuction`). nothing in the Core is needed to buy.
* SPEC invariant 3 becomes: a statement only leaves the Core's control by a house auction that cleared at or above its reserve at listing time, by an exit that returned at least `rating * unitPerPoint`, or as the top of an overprint. invariant 5 gains: eth owed to the Core by the house is not counted in the pots until collected.
* forbidden `buyListing` targets gain the house and the auction factory.
* the stack config gains `auctionFactory`. preflight checks it has code, that its default fee is 0 (warn loudly otherwise) and that no house exists yet for the predicted core address.

## 5. removed

the inventory gate and its counter, the `Econ` immutables (now settings), the dutch statement auction, the recommended config file (one config again), every constant that is now a setting.

## 6. size

the Core is at the limit. make room in this order: delete what section 5 removes, then move view helpers and settings validation into one external linked library under src/lib/ (a deployed library is allowed; proxies are not). if a library is added, the deploy script, nonce based address predictions, preflight, postflight, resume script, rehearsal and docs/DEPLOY.md must account for it. report the final margin; aim for at least 500 bytes.

## 7. tests and docs

real contracts only on the fork (Credits, Statements, CreditScore, CreditStrategy, Seaport, pool manager, artcoins stack, the pnd factory and house). the two exit stand ins and attacker contracts are the only doubles. everything in SPEC section 10 and 11 still needs coverage, adapted to the above. the simulator (sim/engine.js, sim/index.html, docs/SIMULATION.md) must model the same rules and names.

## 8. phase 2 flexibility (owner confirmed, added after the rework)

the real exit module interface is still unknown. the adapter is written later. these three changes keep the exit side repairable.

| # | decision |
|---|---|
| 9 | the exit module is replaceable. `SetExitModule` under the 7 day timelock may run any number of times. the exitToken can never change once set: a later module must report the same `exitToken()` or the action reverts |
| 10 | `unitPerPoint` is read again from the module every time a module is set. setting the same module address again is allowed and is how the unit is updated. so a unit change always waits 7 days |
| 11 | new setting `exitLaneToBuybackBps`: share of the exit token from EXIT lane exits that goes to the coin buyback, the rest goes to `xPot`. launch value 0 (today's behavior), bounds 0 to 10_000. it joins the `Settings` struct, the bounds, the config, every script and check that lists settings, the simulator if it models exit lane proceeds |

rules for a later set (the first set behaves as before):
* same validity checks as the first set on the module and on the unit (code, forbidden targets, unit range, the opening price floor of the exit auction computed with the new unit).
* a set clears `allowedTarget` of the new module, so a flag set earlier cannot come back to life after the module is replaced.
* checkpoint the exit rate under the OLD unit before the unit changes, resync the funded flag after. no climb is credited under the wrong numbers.
* the exit auction price is coin per exit token and does not depend on the unit, only the slice size does. a set must never make `buybackExit` cheaper than it was the moment before: a later set never touches `xStartPrice` or `xStartTime`, whether `xToBuyback` is zero or not: the price is found by the market and the unit only changes the slice size, so no rescale is applied. the first set opens the auction as before.
* pots, piles, held statements and the pending timelock queue are untouched. two queued sets may both run.
* `ExitModuleSet` is emitted every time.
* the old module stops being a forbidden target, the new one is forbidden at call time as today.

trust note for the docs (ARCHITECTURE accepted list): before this change the module door closed forever after one set. now it stays open behind the 7 day timelock for the life of the engine. a dishonest owner or a stolen key can queue a module that returns dust for statements (tiny unit) or a unit so high that the exit token bid overpays an accomplice from `xPot`. the 7 day public delay and the `Queued` event are the protection. the owner accepted this in exchange for a repairable exit side.
