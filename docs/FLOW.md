# flow rework: director brief

binding for branch `flow`. where it conflicts with SPEC.md or docs/ARCHITECTURE.md, this file wins. the owner's goal changed: the engine exists to keep credits flowing into statements. statement sales do not need to profit. unsold statements are fine: they wait for phase 2 and are redeemed through the exitModule.

naming rule: only `exitModule` and `exitToken`. never name or describe them.

superseded in part by section 10 (the port to the artcoins v2 stack, with its amendments 10.6 and 10.7). every statement in sections 1 to 9 about the v1 launch is marked superseded below and no longer true: the skim hook pushing to the Core, the 9.5 and 0.5 skim split, the tax, the factory admin steps, `deployTokenWithProtocolBpsAndTax`. the economic rules of the Core (settings, the bid, the sale, the exit, the locks) are unchanged.

## 1. owner decisions (all confirmed by the owner)

| # | decision |
|---|---|
| 1 | buy credits at one limit per credit (flat), not per score point. a dial lets the owner blend score back in later |
| 2 | never stop buying because statements are unsold. remove the inventory gate entirely |
| 3 | every economic setting is adjustable by the owner after deploy, effective at once. nothing economic is a constant or an immutable |
| 4 | statements are sold by english auction on the live pnd auction house, reserve 90% of the statement's cost. superseded by section 9: the controller prices the sale and the Core keeps a hard floor |
| 5 | the opening limit is set on launch day at about 75% of the market price of a credit |
| 6 | the split of sale proceeds between the pot and the buyback is an adjustable setting |
| 7 | REVOKED by section 9 (decision 15). there is no timelock: the owner sets the controller, the exit module and the allowed targets at once, with three one way locks (9.6) and a two step handover (9.7) |
| 8 | the owner can never transfer eth, credits, statements, coin or exit token out directly: no call moves them to an address the owner picks. this stays true under every combination of settings. what it does not mean: the owner sets the price the engine pays, so a dishonest owner or a stolen owner key could drain the eth pot by selling credits to the engine at an inflated limit. the owner accepted that economic control (every setting adjustable at once, no timelock, no raise guard). the bounds below cap how fast it goes: at most `spendCapBps` (10_000 at launch, bound 10_000) of the pot at the window open plus the eth booked since, per hour window. worst case, measured on a 13.0 eth pot: per transaction, 99.99 percent of the pot with every setting loosened and `setRate(1e15)` (credits worth 0.2 eth), and 99.99 percent with the launch settings and only `setRate` to the launch `rateCap` (credits worth 1.6 eth); per day, 99.99 percent in both cases. measured in `test_ACCEPTED_ownerCanOverpayAnAccompliceSeller`, `test_ACCEPTED_ownerPerTransactionAtLaunchSettings`, `test_ACCEPTED_ownerPerDayWorstCase`. holders therefore trust the owner key. amended by section 10.2: the fee router's owner can direct the fee stream to any engine until `lock()`. amended by decision 28: the owner can call `rescueCoin(to, amount)`, a transfer of coin the Core holds, of coin only |

## 2. settings

one `Settings` struct in Core storage, one owner function `setSettings(Settings)` that validates sanity bounds and emits the whole struct, plus `settings()` view. bounds are wide and exist only to stop typos and to keep rule 8 true (tips, reimbursements and keeper rewards stay capped so settings cannot become a withdrawal path). every function that depends on a setting reads storage. a settings change checkpoints the eth rate and the exit rate first so no climb is credited under the wrong numbers.

| setting | launch value | bounds | meaning |
|---|---|---|---|
| flatBps | 10_000 | 0 to 10_000 | share of the bid that is flat per credit. price = rate * (flatBps * avgScore + (10_000 - flatBps) * score) / 10_000 / 1e4, before the controller bonus |
| avgScore | 4_330_000 | 800_000 to 6_000_000 | the score a flat credit is priced as, and the "average credit" of the clamp |
| dropPerCreditBps | 50 | 1 to 1_000 | each credit bought lowers the rate by this share of the rate before that credit |
| dropFloorBps | 8_000 | 5_000 to 10_000 | within one minute bucket the rate does not fall below this share of the price state at the first fill of the bucket |
| climbPerMinBps | 50 | 1 to 1_000 | rate climb per minute, compounded |
| ceilBps | 12_500 | 10_000 to 30_000 | the rate stays at or below this share of the ceiling anchor |
| idleLoosenBps | 200 | 0 to 2_000 | the ceiling anchor grows by this share of itself per full 10 minutes since the last fill |
| spendCapBps | 10_000 | 100 to 10_000 | share of the pot at the window open plus the eth booked since, per hour window. over `avgScore` it is also the clamp of the read: the price of one average credit that the pot affords |
| bonusCapBps | 2_500 | 0 to 5_000 | |
| tipSavingsBps | 1_000 | 0 to 2_500 | |
| tipCapBps | 200 | 0 to 500 | |
| reimburseBps | 8_000 | 0 to 15_000 | of the metered gas cost. the Core meters gross gas and the EIP-3529 refund cap returns up to 20 percent of it to the caller |
| reimburseCapBps | 500 | 0 to 1_000 | of statement cost |
| saleFloorBps | 7_500 | 1_000 to 40_000 | the hard floor of a statement sale, bps of statement cost. replaces reserveBps (section 9) |
| auctionDuration | 24 hours | 6 hours to 30 days | runs from the first bid |
| exitAfter | 105 hours | 1 hour to 365 days | how long an eth lane statement must have been listed without a bid before it may be redeemed in phase 2 |
| saleToBuybackBps | 5_000 | 0 to 10_000 | share of sale proceeds to the coin buyback, rest to the pot |
| exitToBuybackBps | 5_000 | 0 to 10_000 | share of exit token from eth lane exits to the coin buyback |
| buybackSlice | 1 ether | 0.01 to 2 ether | |
| buybackDelay | 25 | 1 to 7_200 blocks | |
| keeperTipBps | 50 | 0 to 500 | |
| xRateCap / xRateFloor | 9_700 / 3_000 | floor <= cap <= 10_000 | |
| xRateClimbPerHour | 100 | 0 to 1_000 | |
| xRateDropPerCredit | 20 | 0 to 1_000 | |
| xAuctionHalfLife | 6 hours | 10 minutes to 30 days | |
| exitSliceCredits | 20 | 1 to 1_000 | |
| rateCap | 205_540_000_000_000 (10 * rateStart) | the rate bounds, 1e11 to 1e15 | wei per whole point. the eth rate stays at or below it: the read is at most min(ceiling, rateCap, clamp), `setRate` refuses above it, a lower cap pulls the rate down at the checkpoint |
| exitLaneToBuybackBps | 0 | 0 to 10_000 | share of exit token from EXIT lane exits to the coin buyback, the rest to `xPot` (section 8) |
| feeToBuybackBps | 0 | 0 to 10_000 | share of the eth booked from the fee router in `receive()` (the hook in v1, superseded by section 10) that goes to the coin buyback, the rest to the pot. last field of the struct (section 9) |

the credit bid is a rate in wei per whole point. state: the rate at the last checkpoint, the price state at the last fill (`lastFillRate`, the ceiling anchor, `RATE_START` before the first fill), `lastFillTime`, and the price state at the first fill of the current minute bucket (`timestamp / 60`).

* drop: each credit bought with the price state `p` at the fill sets the price state to `p * (10_000 - dropPerCreditBps) / 10_000`, not below `dropFloorBps * minuteStart / 10_000`, where `minuteStart` is the price state at the first fill of the same minute bucket. a `p` already below that floor (restated by `setRate`, or lowered by `ceilBps` or `rateCap`) starts a new floor: `minuteStart` becomes `p`. `p` becomes `lastFillRate` and `lastFillTime` is now. `buyListing` is one fill.
* price state: the stored rate `rateAtCheckpoint` with the anchor and the minute state. it climbs from checkpoint time `t` to `now` as `rate * (1 + climbPerMinBps / 10_000) ^ ((now - t) / 60)`, compounded per minute with a fractional minute as a fractional exponent, up to the clamp `ethPot * spendCapBps / (avgScore * clampCredits)`. a price state above the clamp holds its value, so a starved pot does not raise it and a refill resumes from the price before the starvation. it never exceeds `rateCap` or the ceiling `lastFillRate * (10_000 + idleLoosenBps * floor((now - lastFillTime) / 600)) * ceilBps / 1e8`, which a checkpoint stores. loosening is linear in the number of idle 10 minute intervals.
* read: `ethRate()` is the price state lowered to the clamp `ethPot * spendCapBps / avgScore`, the price of one average credit that the pot affords. the clamp is computed from the current pot and is not stored, so the read does not fall as the pot grows, is at most the price state, and is zero for an empty pot. the hourly room, `windowPot * spendCapBps / 10_000 - windowSpent`, is a separate check on every spend (`_requireRoom`; `windowPot` is the pot at the first spend of the hour plus the eth booked into the pot since): a sell batch whose running total crosses it reverts whole with `HourlyCap`, and the credits before the crossing are not filled.
* a fill pays the read. the drop, the minute floor and the anchor apply to the price state at the fill, whether or not the clamp binds, so a fill at the clamp leaves the price state exactly as a fill at full price would. `buyListing` is one fill and checks its price against the read.
* the ceiling and `rateCap` bound both the read and the stored value: a lowered `ceilBps` or `rateCap` takes effect on the next read and the next checkpoint stores the bounded rate.
* `setRate` restates the price: the stored rate and the ceiling anchor both become `rate`. the fill clock and the minute state stay, and a fill whose price state is below the floor of the minute starts a new floor. the clamp still lowers the read. `setSettings` keeps the anchor.

accepted properties of the rule.

* anyone can checkpoint the rate (a skim of 1 wei, or a fee receipt). the checkpoint stores the bounded rate and moves `checkpointTime`, which delays the climb of the stored rate. the loosening runs from `lastFillTime` and is not delayed, so a checkpoint delays the bid reaching a loosened ceiling by at most 4 minutes per 10 minute step.
* a seller who sells at falling prices across minutes can drag the anchor down: the minute floor restarts every minute, so each minute the rate can fall 20 percent and the anchor follows the price state at the fill. the recovery is the loosening of the ceiling or the owner's `setRate`.

also owner settable at once, each with its own small function and event: `setRate(uint256)` (restates the eth rate and its ceiling anchor, bounded to the rate bounds and to `rateCap`, checkpoints), `setXRate(uint256)` (within floor and cap). `rateStart` stays a constructor input. nothing else is immutable except addresses of external contracts and the owner.

the skim split (9.5 points to the engine, 0.5 to the creator) was the v1 launch fact and is superseded by section 10: 6.9 points of volume, 6.65022 to the router and 0.24978 the protocol leg (decision 31), set inside the v2 pool at launch (the baseline skim and `bountyBps` cannot change afterwards). the coin admin can repoint the bounty recipient until `lockRecipients()`: see 10.12. say so in the docs.

## 3. flat bid

`_ceiling(id)` uses the blended score above, then the controller bonus as before. with flatBps 10_000 the score contract is not read on the eth doors (save the gas). the exit token bid stays per point (phase 2 pays by rating). cost basis, piles, compose are unchanged. launch day rule for docs/DEPLOY.md: rateStart = 0.75 * (market price of one credit in wei) * 1e4 / avgScore, default in config 1.54e13 (0.0089 eth market).

## 4. statement sales on the pnd auction house

note: the reserve rule of this section (`reserveBps`) is superseded by section 9. read section 9.2 for the live rule. there is no queue and no delay anywhere in this file after section 9.

live factory: `SovereignAuctionHouseV2Factory` 0x77aB853543286C9Cdd7dd6c01222A7cC4Ac93d63 (verified; source saved under docs/reference/pnd/). facts read from the source:
* `createAuctionHouse()` deploys a non upgradeable clone owned forever by msg.sender. one per address. fee is fixed at the factory default (0 now).
* `createAuction(tokenId, tokenContract, duration, reservePrice, listingExpiry)` is owner only, pulls the token into the house with transferFrom (needs approval), returns an auction id. `getAuctionFor(token, id)` and `getAuction(id)` read it.
* before the first bid the token owner can `cancelAuction` (token returns) or `setAuctionReservePrice`. after the first bid neither is possible.
* bids: first bid at or above reserve starts the timer (duration), later bids need +5%, a bid in the last 15 minutes extends 15 minutes, the previous bidder is refunded in the same call (30k gas, else credited).
* `endAuction` is permissionless after the end: delivers the token to the winner, then pays the seller. a seller that is a CONTRACT is never pushed eth: the proceeds are added to `pendingRefunds[seller]` and the seller pulls them with `withdrawRefund()`.
* if delivery to the winner fails it is deferred; after 30 days anyone can unwind: the winner is refunded and the token goes back to the seller with a plain transferFrom.

design:
* the Core owns its own house: it calls `factory.createAuctionHouse()` in its constructor, stores the house address, and approves the house for all on Statements.
* compose (eth lane): after minting, the Core lists the statement: `createAuction(sid, Statements, auctionDuration, reserve, 0)` (reserve is `_reserveFor`, section 9.2: the controller price floored at `cost * saleFloorBps / 10_000`; `reserveBps` was replaced by section 9) and records the auction id on the statement. the dutch auction (`priceOf`, `buyStatement`, AUCTION_START_X, AUCTION_FLOOR_X, AUCTION_LENGTH) is deleted.
* `collectSales()`, permissionless, guarded: if `house.pendingRefunds(core) > 0`, call `withdrawRefund()`, measure the eth balance delta under the measuring flag, split it by `saleToBuybackBps` into `ethToBuyback` and `ethPot` (checkpoint first). the Core never bids, so everything credited to it in the house is sale proceeds. `buyback()` calls the same collection first so proceeds are never stranded.
* statement state is settled lazily and permissionlessly with `syncStatement(sid)`: if the Core's record says listed but the house has no auction for it and neither the house nor the Core owns it, it was sold: clear the record (emit `StatementSold`). if the Core owns it and it has no auction (unwound sale, or returned), relist it at the current reserve. `heldStatements()` may include sold statements until synced; add a view that reports the live status.
* phase 2 exit of an eth lane statement: allowed when the module is set, the statement is listed, has no bid, and `now >= listedAt + exitAfter`. the Core cancels the listing (this reverts if a bid arrived) and then exits exactly as before (balance delta check against `rating * unitPerPoint`). the exit lane is unchanged (immediate exit, never listed).
* overprint: both statements must be listed with no bid; cancel both, overprint, relist the base with the summed cost.
* reserve changes: `repriceStatement(sid)` permissionless: sets the listing's reserve to `_reserveFor(sid)` (section 9.2, `reserveBps` no longer exists) if it has no bid (so a settings change can be applied to old listings).
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

note: every mention of a queue, a 7 day delay or `Queued` in this section is superseded by section 9 (no timelock, every set works at once).

the real exit module interface is still unknown. the adapter is written later. these three changes keep the exit side repairable.

| # | decision |
|---|---|
| 9 | the exit module is replaceable. `setExitModule` may run any number of times (at once since section 9, until `lockExitModule`). the exitToken can never change once set: a later module must report the same `exitToken()` or the action reverts |
| 10 | `unitPerPoint` is read again from the module every time a module is set. setting the same module address again is allowed and is how the unit is updated. so a unit change is one transaction since section 9 |
| 11 | new setting `exitLaneToBuybackBps`: share of the exit token from EXIT lane exits that goes to the coin buyback, the rest goes to `xPot`. launch value 0 (today's behavior), bounds 0 to 10_000. it joins the `Settings` struct, the bounds, the config, every script and check that lists settings, the simulator if it models exit lane proceeds |

rules for a later set (the first set behaves as before):
* same validity checks as the first set on the module and on the unit (code, forbidden targets, unit range, the opening price floor of the exit auction computed with the new unit).
* a set clears `allowedTarget` of the new module, so a flag set earlier cannot come back to life after the module is replaced.
* checkpoint the exit rate under the OLD unit before the unit changes, resync the exit funded flag after. no climb is credited under the wrong numbers.
* the exit auction price is coin per exit token and does not depend on the unit, only the slice size does. a set must never make `buybackExit` cheaper than it was the moment before: a later set never touches `xStartPrice` or `xStartTime`, whether `xToBuyback` is zero or not: the price is found by the market and the unit only changes the slice size, so no rescale is applied. the first set opens the auction as before.
* pots, piles, held statements are untouched.
* `ExitModuleSet` is emitted every time.
* the old module stops being a forbidden target, the new one is forbidden at call time as today.

trust note for the docs (ARCHITECTURE accepted list): superseded by section 9 (no timelock, no queue, no `Queued` event, no 7 day delay). before section 8 the module door closed forever after one set. now it stays open until the owner calls `lockExitModule`, and every set works at once. a dishonest owner or a stolen key can set a module that returns dust for statements (tiny unit) or a unit so high that the exit token bid overpays an accomplice from `xPot`, with no delay and no public warning. the owner accepted this in exchange for a repairable exit side (section 9.4).

## 9. sale controller, no timelock, fee share (owner confirmed. replaces every earlier text on buy now)

### 9.1 decisions

| # | decision |
|---|---|
| 12 | the coin symbol is `CC` (script/config/mainnet.json). the name is still a placeholder |
| 13 | launch keeps `exitToBuybackBps` 5_000 |
| 14 | new setting `feeToBuybackBps`: share of swap fee eth booked in `receive()` that goes to `ethToBuyback` (from the hook in v1, from the fee router since section 10), the rest to `ethPot`. launch 0, bounds 0 to 10_000. eth booked later by `skim()` goes to the pot as today |
| 15 | NO TIMELOCK anywhere. decision 7 of section 1 is revoked. the queue, the delay constant, the queue events and the cancel path are deleted. the owner sets the controller, the exitModule, allowed targets and whatever else was queued with plain owner functions that take effect at once and emit an event. the validity rules of each action stay exactly as they are (section 8 for the exitModule, the forbidden target list, and so on). if an action named freeze exists, keep its meaning, it is just immediate |
| 16 | how a statement is priced and sold moves into the controller. the Core keeps custody, a hard floor and the booking of the money |
| 17 | launch sale design: the asking price starts at 110 percent of cost and falls one point every 3 hours to 75 percent (hour 105). in auction mode (launch) a first bid at the asking price opens the english auction on the house. in buy only mode a buyer pays the asking price and gets the statement at once. the owner flips the mode in the controller |

### 9.2 Core side

* setting `reserveBps` is replaced by `saleFloorBps` (launch 7_500, bounds 1_000 to 40_000): the hard floor. no statement leaves the Core by a sale for less than `cost * saleFloorBps / 10_000`.
* `IController` gains `function statementPrice(uint256 sid, uint256 cost, uint64 listedAt) external view returns (uint256 priceWei)`. the Core calls it with the same fixed gas cap as the other controller reads. `_reserveFor(sid) = max(priceWei, floorWei)`. if the call fails or returns malformed data: compose, the relist after overprint and `repriceStatement` revert (the stored reserve stays). the one exception is the relist of a held statement through `syncStatement` (an unwound sale, a returned statement): there the reserve falls back to the hard floor, so a statement can always be listed again and redeemed whatever the controller does.
* raising `saleFloorBps` does not move open reserves: a listing keeps the reserve it was set with until `repriceStatement`. a raise is not atomic for an EOA owner: a listing that has a bid, or gets one before its reprice lands, sells at its old reserve. the owner sends the raise with the reprice of every open listing (`SetSettings` with `REPRICE=1`, docs/DEPLOY.md). the script reads the held statements again after `setSettings`, reprices what is still below, and prints a table of what it could not reprice and why. run it again once the batch is mined: a statement composed after the script started is seen only by the rerun. a multisig can batch `setSettings` and the reprices in one transaction but cannot include a statement composed after its snapshot, so it reruns once after as well. this matters only when the new floor is above a listing's current reserve (a fresh listing sits at 110 percent of cost with the launch settings). this is the plain rule, say so in every runbook.
* listing at compose, relist after an unwound sale, relist after overprint: reserve `_reserveFor` at the new `listedAt` (age zero, so the start price).
* `repriceStatement(sid)`, permissionless: sets the house reserve to `_reserveFor(sid)` when the listing has no bid. this is the call a first bidder makes before bidding.
* `sellTo(uint256 sid, address buyer) external payable`, only the controller, guarded: eth lane statement, held and listed. cancels the house listing (reverts if a bid exists, a live auction always wins), requires `msg.value >= cost * saleFloorBps / 10_000`, sends the statement to `buyer` with `transferFrom`, books `msg.value` exactly like collected sale proceeds (checkpoint, split by `saleToBuybackBps`, resync funded), clears the record, emits a sold event with buyer and price. no refund logic in the Core.
* `exitAfter` STAYS a Core setting, launch value 105 hours (378_000), bounds as before. redemption never depends on the controller.
* redeem reimbursement: `exitStatement` repays the caller's gas in eth from `ethPot` with the same rule and settings as compose (`reimburseBps` of gas cost, capped at `reimburseCapBps` of the statement cost and at the pot; an exit lane statement uses the notional cap `composeExit` uses). nothing is added to a cost basis. bound the gas counted so a gas burning module cannot push it past the cap. paid after all state is final, no reentrancy opening.
* SPEC invariant 3 becomes: a statement only leaves the Core by a house auction whose reserve was at least the hard floor when it was set, by `sellTo` with payment at least the hard floor, by an exit that returned at least `rating * unitPerPoint`, or as the top of an overprint.

### 9.3 controller side (src/ControllerV1.sol, nothing is deployed so extend it in place)

* owner of the controller settings is the Core's owner read live (`core.owner()`), no second owner.
* settings, each owner settable at once with an event: `buyOnly` (launch false), `startBps` (11_000), `stepBps` (100), `stepEvery` (3 hours), `floorBps` (7_500). sane bounds: startBps 1_000 to 40_000, stepBps 0 to 5_000, stepEvery 1 minute to 30 days, floorBps 1_000 to startBps.
* `statementPrice(sid, cost, listedAt)`: `steps = (now - listedAt) / stepEvery`, `bps = max(startBps - min(steps * stepBps, startBps), floorBps)`, `cost * bps / 10_000`. in buy only mode it returns the start price without decay, so the house reserve is not walked down.
* `priceOf(sid)` view for frontends: the current asking price from the Core's `statementInfo`, in either mode, never below the Core hard floor `cost * saleFloorBps / 10_000` (so it is always a price `sellTo` takes).
* `buy(uint256 sid) external payable`, guarded, only when `buyOnly`: price is the decayed asking price, `msg.value >= price`, calls `core.sellTo{value: price}(sid, msg.sender)` (the price is `priceOf`, so the floor holds even if the owner raised `saleFloorBps` above the controller `floorBps`), refunds the excess to the caller last.
* the credit picking functions are unchanged.

### 9.4 trust note for the docs (replaces the timelock text everywhere)

with no delay the owner key controls everything at once: it can point the exitModule at a contract that returns dust and take every statement, swap the controller and sell every statement at the hard floor, lower the hard floor to its bound, and overpay for credits as already documented. a stolen owner key means the whole engine at once. the owner chose this: the system is new and must adapt fast, and he will announce changes off chain. holders trust the owner key fully. say it in exactly this strength in ARCHITECTURE and DEPLOY, no softening.

### 9.5 size

deleting the timelock machinery frees room. price math and anything movable go to `CoreLib`. final margin at least 150 bytes.

### 9.6 locks (owner confirmed)

the owner keeps full control for now (no extra hard limits were added, see 9.4). to be able to close doors later, three one way locks, each `onlyOwner`, irreversible, each with its own event and public flag:
* `lockController()`: after it the controller can never be changed.
* `lockExitModule()`: after it the exitModule (and so the unit) can never be changed. reverts while no exitModule is set, so phase 2 cannot be locked out by accident.
* `lockTargets()`: after it no target can be added (removing, if it exists, still works).
these replace the old `frozen` flag and the Freeze action. the setters revert with a clear error once locked. the Core settings and the controller's own sale settings stay adjustable after a lock. a fourth lock, `lockSuccessor()`, closes `setSuccessor` (10.10, decision 33).

### 9.7 transferable owner (owner confirmed)

`OWNER` is no longer immutable. two step handover: `transferOwnership(address)` by the owner sets a pending owner (zero clears it), `acceptOwnership()` by the pending owner completes it, events on both. no renounce. every `onlyOwner` check and the controller's `core.owner()` read use the live owner. scripts and postflight read `owner()`; the launch config owner is the first owner.

## 10. port to the artcoins v2 stack (owner confirmed 2026-10-07)

the coin launches on the artcoins v2 factory, not the v1 stack the launch package was built on. reference: the v2 repo, branch v2-legibility, commit d4aa46b (deployed on mainnet from launcher commit fbe07c7, script/config/v2-mainnet.json). the analysis is docs/V2-PORT.md: it is the working reference for every detail below, this section is the binding decision list. where V2-PORT.md and this section differ, this section wins. the v2 audit is pending and the stack is live, so every v2 address stays a config input and preflight pins the live code hashes.

### 10.1 decisions

| # | decision |
|---|---|
| 18 | the coin is launched `restricted` (v2 decision D73). there is no transfer tax any more: the tax config, the 44 venues and the exemption are deleted from the launch package. the Core, the fee router and the fee swapper are NOT put on the coin's allowlist (the hook grants the allowance each canonical swap needs, burns always pass) |
| 19 | a `FeeRouter` contract is the bounty recipient of the pool. the Core books eth as fees when it arrives from the router, no longer from the hook |
| 20 | the lp fee income of the project side goes through a v2 `FeeAutoSwapperV2` whose end recipient is the router, so it reaches the engine as eth |
| 21 | launch values follow the v2 factory defaults: engine share `bountyBps` and `lpFee` at the v2 factory defaults (replaced by decisions 23, 24 and 31), protocol locker slot at the factory default. skim stays 10 points of volume, anti sniper stays 90 points falling to 10 over 30 minutes if the v2 mev module allows it (else the nearest allowed values, reported) |
| 22 | the launch is signed by the v2 factory owner key (`deployTokenAsOwner`), which is the engine owner. the fresh deployer path and the factory admin enable and revoke steps are removed |

### 10.2 FeeRouter (src/FeeRouter.sol)

* `receive() external payable {}` and nothing else in it: no storage write, no cold read, no call. the hook pushes with the 2,300 gas stipend.
* `flush()`, permissionless, guarded against reentry (section 10.8): sends `balance - totalOwed - payee share` to `engine` with a plain call and all gas. the payee share is paid by `_payPayees` once the split is on, and a payee whose send fails is credited in `owed`, which `claim(payee)` pays out. `flush` reverts `NoEngine` while `engine` is unset and `FlushFailed` when the engine call fails, and the eth waits in the router until then.
* `engine`, set by the owner with `setEngine(address)` (must have code), any number of times until `lock()`, a one way lock with an event. events on every change.
* its own two step owner (`transferOwnership`, `acceptOwnership`), first owner from the constructor. it does not read the Core's owner: a later engine must be able to take over.
* no other function. it never holds coin on purpose and has no token path.
* trust note for the docs, in this strength: two owner switches direct value to an address the owner picks. the pool side switch is the hook bounty recipient (with the locker reward recipients), set by the coin admin with `setBountyRecipient` and `setRewardRecipient` until `coin.lockRecipients()` seals it. the router side switch is `router.setEngine`, which points every future flush at any contract until `router.lock()`. `lockRecipients` is a launch step (docs/DEPLOY.md): the pool then pays the router from then on, and `router.setEngine` is the migration switch for a later engine. neither touches what an engine already holds. FLOW decision 8 is amended to say so.

### 10.3 Core change (the only one)

* `Stack` gains `feeSource`. `receive()` books eth as fees (checkpoint, `feeToBuybackBps` split, resync) when `msg.sender == FEE_SOURCE` and no measurement is in flight (while one is, the fee source reverts `Measuring` and the router flush fails whole, V2R-1). eth from any other sender, the hook and the escrow included, is accepted and left for `skim()` as today.
* the forbidden target list takes the v2 addresses of V2-PORT.md section 7 plus the router.
* eth the v2 escrow holds for the Core (partial fill refunds of the Core's own buyback) is claimed by anyone with the escrow's claim and then booked by `skim()` to the pot. document it, no code.
* size: the Core must keep at least 60 bytes of headroom. if the change does not fit, move code to `CoreLib`, never drop a check.

### 10.4 launch package

rewritten for `IArtCoinsFactoryV2`: `DeploymentConfigV2`, the factory's own `predictToken` (the token creation hex and the hand prediction are deleted), `deployTokenAsOwner`. deploy order: library, controller, router (engine unset), Core (with `feeSource` the router and the predicted coin), the fee swapper if the v2 flow needs it deployed per coin, the launch, `router.setEngine(core)`, the swapper's post launch setup, postflight. preflight and postflight check every v2 field they can read back (restriction on, bounty recipient the router, bounty bps, lp fee, mev values, locker slots, protocol recipient reported, router engine and owner, nothing on the coin allowlist beyond the factory's seeds). the config hash sign off stays. owner steps on the v2 factory or escrow that the launch needs (for example registering the swapper as an escrow depositor) are listed in docs/DEPLOY.md as explicit owner commands.

### 10.5 tests

real contracts on the fork as before. the fixture attaches to the live v2 stack on the pinned fork at the addresses of script/config/v2-mainnet.json, with the factory owner impersonated. no hand written copy of a v2 contract and no mock of one.

### 10.6 amendments (owner, 2026-10-08). these win over 10.1 to 10.5

| # | decision |
|---|---|
| 23 | a trader pays 6.9 percent in total. skim `baselineSkimBps` 690 (bps of volume, 6.9 points), `lpFeePips` 0. the factory accepts an lp fee of 0 while the baseline skim is above 0, and a preflight check confirms the factory accepts the config. decision 20 is revoked: with no lp fee there is no lp income and no fee swapper anywhere in the launch package |
| 24 | `bountyBps` is 9_638 (decision 31). the protocol leg (362 of 10_000 of the skim, 0.24978 points of volume) belongs to the launcher protocol. it is a separate business from this engine and its owner's share: never describe it as the engine owner's income |
| 25 | the router pays payees out of what it receives. the owner's intent is 0.5 points of volume to the creator and 0.5 points to the artist. at launch there is ONE payee: the creator address (the config owner address) with both shares, 0.75 points of volume at launch (decision 31). the router receives 6.65022 points (9_638 of 6_900), so that is 112_778 parts per million of the gross router inflow. the owner replaces it later through `setPayees` (with a splitter contract or two entries), so the launch config holds every address it needs. the rest goes to the engine (5.9002215 points) |
| 26 | everything the router receives during the anti sniper window goes to the engine, with no payee share. the anti sniper skim starts at 90 points (`sniperStartBps` 9_000) and falls to the baseline 6.9 over 30 minutes if the v2 module allows it (else nearest allowed, reported) |
| 27 | `flush()` takes no argument. the balance goes to the payees and the engine. the gas of a flush started by a door is covered by the door's gas repay (10.8) |
| 28 | the Core gains `rescueCoin(address to, uint256 amount)`, owner only, guarded, with an event: it transfers coin the Core holds. the Core receives coin in `buyback`, which burns the coin it bought in the same call, so the function reaches only coin an allowlisted holder sent to the Core (insurance for that case). decision 8 is amended: this is an owner directed transfer of the coin only, never of eth, credits, statements or exitToken |
| 29 | the Core is not on the restricted coin's allowlist (`restriction.allowed` is the config's own entries, empty at launch). the buyback takes the coin it bought from the pool manager to the Core, and the token passes that move through the transfer allowance the hook grants for the swap (`ArtCoinsHookV2` afterSwap grants the coin side of the swap delta, `ArtCoinsTokenV2._route` consumes it). the take consumes the whole allowance, so no allowance remains for another caller in the transaction. `burn` does not pass through `_route`. a holder that is not on the allowlist cannot send coin to the Core, and coin an allowlisted holder sends to it is taken out with `rescueCoin` (decision 28). the coin address is a function of the signer, the router address and the launch config |

FeeRouter, replacing 10.2 where they differ:
* `receive() external payable {}` stays empty.
* modes. until the split starts every flush sends everything to the engine. `splitStart` is a timestamp the owner sets (the Resume run after the launch is mined sets it to the launch time read from the factory record plus the anti sniper window, no margin). the first `flush` at or after `splitStart` still sends everything to the engine and then turns the split on, so eth that arrived during the window is never shared. from then on each flush pays the payees their parts per million of the gross amount flushed and the engine the rest, so a payee gets exactly its share of the inflow.
* payees: up to 4 `(address, ppm)` entries, total at most 200_000 ppm (the engine always keeps at least 80 percent of a flush). a payee is paid by a plain call with a fixed gas cap; if that fails the amount is credited to `owed[payee]` and `claim()` lets the payee (or anyone, sending to the payee) pull it. a payee can never block a flush.
* the engine gets the rest by a plain call with all gas. if that call fails the whole flush reverts and the eth waits.
* owner setters, each with an event, all frozen by the one way `lock()`: `setEngine`, `setPayees`, `setSplitStart` (only while the split is not on).
* flush is guarded against reentry and reverts while the engine is unset.

### 10.7 amendment to decision 25 (owner, 2026-10-08)

the router's payee list holds ONE entry at launch: the creator address (the config `creator`), with the combined share of 0.75 points of volume, which is 112_778 parts per million of router inflow (0.75 / 6.65022, see 10.9). there is no separate artist payee and no placeholder for one: the owner will later point the payee at his own splitter contract with `setPayees`. the router keeps supporting up to 4 payees. because a payee may be a contract, the fixed gas cap on a payee payment is 100_000 and the `owed` and `claim` fallback stays.

### 10.9 protocol leg and payee share (owner, 2026-10-08). wins over 10.6 and 10.7

| # | decision |
|---|---|
| 31 | the protocol keeps 362 of every 10_000 of the skim and the router receives the rest: `bountyBps` 9_638. the payee share is 0.75 points of volume. the factory owner lowers the factory `minProtocolSkimShareBps` to at most 362 before the launch, 362 chosen so the pool floor equals the protocol's 0.25 points (the factory rule is `bountyBps <= min(9999, 10_000 - minProtocolSkimShareBps)`, a global factory setting, frozen per pool at creation), and preflight fails with the command named when the factory minimum is above 362 |

per 100 eth of volume at launch values (skim `baselineSkimBps` 690 is 6.9 points, 6.9 eth):

| leg | calculation | eth |
|---|---|---|
| protocol recipient | 6.9 * 362 / 10_000 | 0.24978 |
| router receives | 6.9 * 9_638 / 10_000 | 6.65022 |
| payee | 112_778 ppm of the router inflow: 0.75 / 6.65022 * 1e6 = 112_778.2, rounded down | 0.7499985 |
| engine | router inflow less payee | 5.9002215 |

anti sniper window (skim above the baseline, up to 90 points at the start): the protocol keeps its 0.24978 points of the baseline, the whole router inflow (6.65022 points plus everything above the baseline) goes to the engine, and no payee is paid. on a 1 eth buy at the start of the window the router receives 0.8975022 eth.

projection at comparable volume (1,961 eth in 90 days, the first 30 minutes of fees to the engine): the payee receives about 12 eth.

### 10.8 the Core pulls the fees

| # | decision |
|---|---|
| 30 | the Core flushes the fee router at the start of `sellForEth` (both overloads), `buyListing`, `compose` and `composeExit`, so fees reach the pot without a keeper. `flush()` takes no argument. a keeper may call `flush()` directly |

mechanism:
* `CoreLib.pullFees(router)` calls `flush()` on `FEE_SOURCE` with at most 1,000,000 gas and ignores the outcome. a router that reverts, burns its gas or has no code leaves the entry point unaffected and the fees in the router.
* the pull is the first action of the entry point: before the checkpoint, before any pot or rate read and before the measuring flag is set. the flush sends eth into `Core.receive`, which checkpoints and books it, so the entry point prices against the enlarged pot at the rate checkpointed at that moment. fee eth arriving in a measured window is refused by `Core.receive`, and the pull has finished before a window starts (V2R-1).
* an empty router returns early inside `flush` (after the engine check), which costs the entry point one library call and one router call.
* `sellForExitToken`, `exitStatement`, `collectSales`, `sellTo`, `skim` and `buyback` do not pull: the exit token entry points do not read the eth pot, and the others book or spend on their own schedule.
* gas of one credit sale, measured by `test/PullFees.t.sol`: 394,372 with an empty router and 455,567 with 1 eth in the router (the flush adds about 61,200). the most expensive flush (four payees that burn all their gas, the split on) costs 640,000 gas. gas of one call of each pulling door with an empty router and with 1 eth in it, measured by `test_gasOfThePullPerDoor_*` in `test/PullFees.t.sol`: `sellForEth` 373,245 and 434,440, `buyListing` 465,004 and 526,104, `adopt` 239,312 and 303,308, `compose` 8,702,314 and 8,737,565, `composeExit` 8,464,924 and 8,496,054. `test/GasCap.t.sol` measures the largest sell batch with the 1 eth pull.
* `gasStart` is taken before the pull in `compose` and `composeExit`, so the gas repay covers the flush. the repaid gas is `min(counted gas, COMPOSE_GAS)` with `COMPOSE_GAS` 12,000,000. the counted gas is the page, the flush, 50,000 of overhead and, in the eth lane, 350,000 for the listing. the worst measured case is the eth lane with 1 eth in the router and four payees that burn their gas, 11,379,921 counted as the Core meters it (`test_gas_compose_ethLane_routerWorstCaseFlush`), against 10,905,592 with a router that holds 1 eth and no burning payee, so the bound leaves about 5 percent above the worst case and a payee that burns its gas cannot raise the repaid gas past `COMPOSE_GAS`. the repay cap (`reimburseCapBps` of the cost basis, or of the notional cap in the exit lane) and the `ethPot` bound apply on top. a flush raises `ethPot`, which can lift the `ethPot` term of the `_repay` cap; the fees are booked fees and the lift is legitimate.
* the router pointer is the immutable `FEE_SOURCE`, fixed at deploy and checked for code.


### 10.10 rescue and migration (owner, 2026-10-08)

| # | decision |
|---|---|
| 32 | `rescueNft(token, id, to)`: the owner takes a stuck NFT out of the Core. a credit leaves only while it is not in a pile, a statement only while the Core has no record of it (`held` false), any other ERC721 leaves. the token's `ownerOf(id)` must answer with the Core, so a token whose `ownerOf(id)` does not answer with the Core is refused. owner only, guarded, `transferFrom`, event `NftRescued`, reverts `InPile`, `Held`, `NotHolder` |
| 33 | `setSuccessor(address)`, `lockSuccessor()` and `migrate(maxCredits)`: the owner moves the eth pots, the exit token pots and credits to a successor contract, in batches. the held statements, their listings and their records stay in the Core. a statement is a composed object with a record (lane, cost, clock) that only the Core which composed it can price, list, settle and exit, so a successor has no use for it, and the old engine sells its statements out itself through the house, `exitStatement` and `overprint`. an exit lane statement leaves only through `exitStatement`, so the exit module stays set and working on the old engine until its held list is empty. the proceeds are booked by `collectSales` and `syncStatement` and a later `migrate` moves them. the successor is zero and unlocked at launch. `lockSuccessor()` is the fourth one way lock and is allowed while the successor is zero, which disables migration. the lock decision is taken after the successor is final, or at once if no migration is wanted |

mechanism of 32:
* credit membership is the `inPile` flag of the credit record, set by `_push` (`sellForEth`, `buyListing`, `sellForExitToken`) and cleared when `compose` pulls the credit. a credit sent straight to the Core has no record, so its flag is false.
* statement membership is `Statement.held`, set at compose and cleared by `_unhold` (sale settled by `syncStatement`, `sellTo`, exit, overprint top). a sold statement whose record is not settled is still held, so it stays until `syncStatement` runs.
* the `ownerOf` probe is a staticcall that must return the Core's address. a WETH like token answers it with a revert, and the coin and an exitToken have no `ownerOf`, so they are refused.

mechanism of 33:
* `migrate` requires a nonzero successor. the order inside is eth, credits, exit token. `setSuccessor` refuses the Core, the exit module, the exit token, the house, the fee source, the coin, Credits and Statements (`BadSuccessor`).
* eth: `ethPot + ethToBuyback` goes to the successor with one plain call carrying the amount, after the eth rate is checkpointed and both trackers are zeroed. the hourly spend window (`windowStart`, `windowPot`, `windowSpent`) is reset to zero in the same step, so the next spend opens a window on the pot it finds. a successor that rejects the eth reverts the whole call. eth above the trackers stays, `skim` books it and a later call moves it.
* credits: up to `maxCredits` from the head of each pile (so up to twice that in all), `transferFrom`, then the pile head, tail and size are updated. each moved credit keeps its cost, lane and arrival time in its record, with `inPile` false and no links.
* statements: the held list, the listings on the house and the records of the held statements are as they were before the call, and the Core goes on selling, collecting and exiting them. `migrate` transfers eth, exit token and credits. `collectSales` and `syncStatement` book their proceeds into the pots and a later `migrate` moves those.
* exit token: `xPot + xToBuyback` by `transfer` after both are zero and the exit rate is checkpointed. the exit auction price and clock are left as they are, so the next injection re anchors at the stored start price.
* the coin stays (`rescueCoin` covers it). the proceeds the house owes the Core are not in a pot until `collectSales`, so they move in a later call.
* the state that changes is the moved assets, their trackers, the two rate checkpoints, the hourly spend window and the funded flag. the piles, the held list, the controller, the settings and the locks keep working, and fees booked after a call stay in the Core until the next call.
* gas, measured by `test/Migrate.t.sol` (`test_GAS_migrateEightyCreditsPerPile`): 158,999 with only the pots, 44,781 per credit, 8,030,991 for 80 credits per pile (160 credits). `maxCredits` applies to each pile, so with both piles deeper than the cap a call moves twice that. the largest `maxCredits` under the 16,777,216 transaction cap is 371 when one pile holds that many credits and 185 when both piles do. `maxCredits` 150 fits with room to spare (about 13.6 million for two full piles).

### 10.11 composability (owner, 2026-10-08)

| # | decision |
|---|---|
| 34 | a read only lens contract, `CoreLens`, answers the whole state a seller, a buyer or a keeper decides on in one `eth_call`. it has no storage and no state changing function, and the Core does not call it. the deploy creates it right after the Core, through the deterministic deployer (CREATE2, fixed salt, the Core as constructor argument), so its address is a function of the Core, and postflight verifies its pointers in every run. `Resume` creates it when its address has no code |
| 35 | `adopt(uint256[] ids)`: anyone puts credits the Core holds without a record into the eth pile. the cost basis of a credit is the price state per whole point at that moment times its score, `ethPrice() * score / 1e4`, at least 1 wei. the price state is what the engine pays with a funded pot, so the cost basis of a statement built from adopted credits stays at the level of the market that existed when they arrived. the clamped read of a thin pot would book 1 wei and the statement price would collapse. a donor who inflates the basis of a statement only loses the credits. the Core pulls the fee router first, like every door that reads the pot |
| 36 | the pot of the hourly spend window follows inflows. the first spend of an hour stores `windowPot = ethPot` and `windowStart`. every eth amount booked into `ethPot` during that hour adds the same amount to `windowPot`: the pot share of a fee pull or `receive`, of `skim`, and of sale proceeds (`collectSales`, `sellTo`). the room is `windowPot * spendCapBps / 10_000 - windowSpent`, the cap on the pot at open plus everything booked since, less the spend. a fee pull inside `sellForEth` raises the clamped bid and the room together, so a batch priced before the pull fits the room after it. spending is counted in `windowSpent`. reimbursements lower `ethPot` and leave `windowPot`. buybacks draw `ethToBuyback` and leave both. `migrate` resets the window |
| 37 | `clampCredits` is removed and `spendCapBps` is 10_000 at launch (owner decision 2026-10-09). the clamp of the read is `ethPot * spendCapBps / avgScore`, the price of one average credit that the pot affords, and the climb target is min(ceiling, `rateCap`, clamp). the engine spends as sellers come, the pot stays small and the bid does not run away. simulator, 3 seeds, against the previous launch configuration (spend cap 20 percent, 20 clamp credits): day one 1,994 credits against 1,549, day 90 31,495 against 31,635, highest bid 0.95x of market against 1.07x, lowest bid on day one 0.81x against 0.68x. the hourly window stays as the mechanism of `spendCapBps` below 100 percent. the bound of `spendCapBps` is 100 to 10_000. `Settings` has 30 fields |

mechanism of 34:
* pointers: the Core is the constructor argument. the router is `Core.FEE_SOURCE()` and the house is `Core.HOUSE()`, both read once in the constructor and held as immutables. Credits and Statements are the mainnet constants. the controller is read from `Core.controller()` on every call, so a controller replaced by the owner is followed.
* the Core has two new views. `ethPrice()` returns the first value of `_climb`: the price state (`rateAtCheckpoint` climbed to now, bounded by the ceiling and `rateCap`). `ethRate()` returns the second value, the price state lowered to the clamp. the price state cannot be computed outside the Core, because the ceiling anchor `lastFillRate` sits in Core storage. `hourlyRoom()` is `windowPot * spendCapBps / 10_000 - windowSpent` (the window pot follows inflows, decision 36) while the window is open and `ethPot * spendCapBps / 10_000` once an hour has passed since `windowStart`, which is the cap the next spend opens a window with. the Core runtime goes from 23,837 to 24,043 bytes (`ethPrice` 47, `hourlyRoom` 159).
* the average bid is `avgScore * ethRate / 1e4`, the payout for one credit of average score with no controller bonus. `bidFor(id)` is `ceilingOf(id)`.
* the flush fields repeat the arithmetic of `FeeRouter.flush`: `amount = balance - totalOwed`, the payee shares `amount * ppm / 1_000_000` while `splitOn`, and the rest goes to the Core. both are zero while the router has no engine or no balance above its debts. `test/Lens.t.sol` compares them with the balances after an actual flush.
* the reads of the controller (`nextPage` ready flag, `priceOf`) are bounded staticcalls. `nextPage` is read with the answer size `compose` requires (82 words), so the lens and `compose` agree on a short answer. a controller without code, a revert or a short answer reads as not ready.
* `askingPrice` is the controller's `priceOf` while a buyer can buy at it: an eth lane statement with status Listed (live auction, no bid). it is 0 in every other status (Held, Bid, Ended, Sold, Returned), for an exit lane statement and for a controller that does not answer. `status`, `topBid` and `endTime` describe the other states.
* a statement is `listed` while its auction is live on the house (status Listed, Bid or Ended). the status values are those of `Core.statementStatus`.
* `snapshot()` costs about 146,000 gas with no statements and 56,000 more per held statement (`test_GAS_snapshotPerStatement`). `statementsPage(start, n)` reads a slice of `heldStatements`.

mechanism of 35:
* a credit is adoptable when `CREDITS.ownerOf(id)` is the Core and `inPile` is false. `Empty` for an empty list, `ZeroId` for id zero, `InPile` for a credit already in a pile (the same id twice in one call included), `NotHolder` for a credit another address holds. an id that does not exist reverts inside Credits. one bad id reverts the whole call.
* the price state is the first value of `CoreLib.climb` for the stored rate, the pot, the fill clock and the checkpoint time, computed for the current second after the fee pull. the climb stops at the ceiling, `rateCap` and the clamp, so with an empty pot the price state does not climb. the clamp that lowers the read for a thin pot is applied to the read only, and no checkpoint is written. with an empty pot the read is zero and the basis is the price state times the score.
* the record written is the one `_push` writes: cost, lane Eth, `inPile`, arrival time now, links to the tail. the basis is booked and the eth pile grows. `windowSpent`, `rateAtCheckpoint`, `checkpointTime`, `lastFillTime`, the anchor words of `RateStore` and the pots keep their values apart from the fee pull, which books pending router eth as it does at every door.
* the compose of the controller then treats the credit as any other: the statement cost is the sum of the bases plus the compose reimbursement.
* a credit that left through `migrate` keeps its old record with `inPile` false. if it returns to the Core, `adopt` writes a new record over it.
* `adopt` is guarded by the reentrancy lock of the Core. `buyListing` calls an arbitrary target, and an `adopt` of the credit being bought from inside that call would put it in the pile before `buyListing` does.
* the successor of a `migrate` receives credits without records. `adopt` on the successor builds its pile from them, in the order of the call. the successor prices them with its own price state.
* the Core runtime goes from 24,043 to 24,150 bytes (the forwarder with the pull), `CoreLib` from 18,002 to 18,487. tests in `test/Adopt.t.sol`, the action `adopt` in `HandlerBase` with the ghost pile and the model price (`BidModel`).

mechanism of 36:
* `Core._addToPot(amount)` is the one place that increases `ethPot`: `ethPot += amount; windowPot += amount`. its callers are `receive` (the pot share of the router flush), `skim` (the eth above the recorded pots) and `_book` (the pot share of sale proceeds). `windowPot` is added to while the window is open (`block.timestamp < windowStart + 1 hours`). an expired window is replaced at the next spend by `windowPot = ethPot`, and `hourlyRoom()` reads `ethPot * spendCapBps / 10_000` once the hour has passed.
* the buyback share of fees and of sales goes to `ethToBuyback` and is not added. the reimbursement of a compose or an exit lowers `ethPot` and leaves `windowPot`, and a buyback draws on `ethToBuyback`, so neither changes the room.
* the clamp of the read follows the pot, and the room follows the pot at open plus inflows. the room before a fee pull is at most `spendCapBps` of (the pot plus the reimbursements paid this hour), because reimbursements lower `ethPot` and leave `windowPot` (each is at most `reimburseCapBps` of its statement cost). a batch priced before the pull has a total that rises by at most the pot growth ratio, which is `spendCapBps` of the pot share of the pull plus a slack of at most `spendCapBps` times the reimbursements of the hour times that ratio. the room rises by `spendCapBps` of the pot share of the pull.
* the simulator (`sim/engine.js`) adds the pot share to `windowPot` in `addFees` and `bookSale`, as the Core does.
* the Core runtime goes from 24,150 to 24,203 bytes. tests in `test/Window.t.sol`; the handler ghost of the window in `HandlerBase` adds the pot share of every booking (`_potIn`).

### 10.12 v2 commit d4aa46b: units, fee rules and recipients (owner, 2026-10-09)

| # | decision |
|---|---|
| 38 | the v2 reference is commit d4aa46b. the skim rates and the referral cap are in bps of volume: `baselineSkimBps` 690, `sniperStartBps` 9_000, referral cap 0. the lp fee is in uniswap pips and named `lpFeePips`. the economics of 10.1 to 10.9 hold in the new units: 6.9 points of skim, 90 points at the first block, `bountyBps` 9_638 (the protocol keeps 690 * 362 / 10_000 = 24.978 bps of volume, 0.24978 points), `payeePpm` 112_778 |
| 39 | the factory has no minimum lp fee. a launch needs an lp fee or a baseline skim above 0 (`ZeroFeeLaunch`), and the launch has the baseline skim. the only factory owner command of the launch is `setMinProtocolSkimShareBps(362)` |
| 40 | the coin admin, which is the owner, repoints the hook bounty recipient (`setBountyRecipient(poolId, recipient)` on the hook) and a locker reward recipient (`setRewardRecipient(coin, index, recipient)`, the protocol slot excluded) until it calls `lockRecipients()` on the coin. renouncing the admin freezes both. the router lock closes the router setters only, the hook recipient needs `lockRecipients()`. the baseline skim, `bountyBps`, the protocol recipient and the ticks of a pool cannot change after the launch. postflight warns while the recipients are not locked |
