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
| 8 | the owner can never transfer eth, credits, statements, coin or exit token out directly: no call moves them to an address the owner picks. this stays true under every combination of settings. what it does not mean: the owner sets the price the engine pays, so a dishonest owner or a stolen owner key could drain the eth pot by selling credits to the engine at an inflated limit. the owner accepted that economic control (every setting adjustable at once, no timelock, no raise guard). the bounds below cap how fast it goes: at most 50% of the pot per transaction (47.4% measured) and 99.99% per day with every setting loosened (98.96% per day with only `setRate` at the launch settings), measured in `test_ACCEPTED_ownerCanOverpayAnAccompliceSeller` and `test_ACCEPTED_ownerPerDayWorstCase`. holders therefore trust the owner key amended by section 10.2: the fee router's owner can redirect future fees until the router is locked. amended by section 10.6 decision 28: the owner can call `rescueCoin(to, amount)`, a transfer of coin the Core holds, never of eth, credits, statements or exit token amended by section 10 (decision 28 and 10.2): the router owner can direct the fee stream to any engine until `lock()`, and the owner can send stray coin out of the Core with `rescueCoin`. eth, credits, statements and exit token still never leave by an owner call |

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
| saleFloorBps | 7_500 | 1_000 to 40_000 | the hard floor of a statement sale, bps of statement cost. replaces reserveBps (section 9) |
| auctionDuration | 24 hours | 6 hours to 30 days | runs from the first bid |
| exitAfter | 105 hours | 1 hour to 365 days | how long an eth lane statement must have been listed without a bid before it may be redeemed in phase 2 |
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
| exitLaneToBuybackBps | 0 | 0 to 10_000 | share of exit token from EXIT lane exits to the coin buyback, the rest to `xPot` (section 8) |
| feeToBuybackBps | 0 | 0 to 10_000 | share of the eth booked from the fee router in `receive()` (the hook in v1, superseded by section 10) that goes to the coin buyback, the rest to the pot. last field of the struct (section 9) |

also owner settable at once, each with its own small function and event: `setRate(uint256)` (resets the current eth limit, bounded to the rate bounds and to `rateCap`, checkpoints), `setXRate(uint256)` (within floor and cap). the funded rule (the hourly cap must afford one average credit) is logic, not a setting. `rateStart` stays a constructor input. nothing else is immutable except addresses of external contracts and the owner.

the skim split (9.5 points to the engine, 0.5 to the creator) was the v1 launch fact and is superseded by section 10: 6.9 points of volume, 6.21 to the router and 0.69 the protocol leg, fixed inside the v2 pool at launch and not adjustable here. say so in the docs.

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
* checkpoint the exit rate under the OLD unit before the unit changes, resync the funded flag after. no climb is credited under the wrong numbers.
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
these replace the old `frozen` flag and the Freeze action. the setters revert with a clear error once locked. the Core settings and the controller's own sale settings stay adjustable after a lock.

### 9.7 transferable owner (owner confirmed)

`OWNER` is no longer immutable. two step handover: `transferOwnership(address)` by the owner sets a pending owner (zero clears it), `acceptOwnership()` by the pending owner completes it, events on both. no renounce. every `onlyOwner` check and the controller's `core.owner()` read use the live owner. scripts and postflight read `owner()`; the launch config owner is the first owner.

## 10. port to the artcoins v2 stack (owner confirmed 2026-10-07)

the coin launches on the artcoins v2 factory, not the v1 stack the launch package was built on. reference: the public repo ripe0x/artcoins, branch v2, commit 87a7522 (a clone is at /home/claude/nmcl/v2). the analysis is docs/V2-PORT.md: it is the working reference for every detail below, this section is the binding decision list. where V2-PORT.md and this section differ, this section wins. v2 is not on mainnet yet and its audit is pending, so every v2 address stays a config input and the final run waits for the live stack.

### 10.1 decisions

| # | decision |
|---|---|
| 18 | the coin is launched `restricted` (v2 decision D73). there is no transfer tax any more: the tax config, the 44 venues and the exemption are deleted from the launch package. the Core, the fee router and the fee swapper are NOT put on the coin's allowlist (the hook grants the allowance each canonical swap needs, burns always pass) |
| 19 | a `FeeRouter` contract is the bounty recipient of the pool. the Core books eth as fees when it arrives from the router, no longer from the hook |
| 20 | the lp fee income of the project side goes through a v2 `FeeAutoSwapperV2` whose end recipient is the router, so it reaches the engine as eth |
| 21 | launch values follow the v2 factory defaults: engine share `bountyBps` 9_000 (the protocol keeps 1_000), `lpFee` 3_000 pips, protocol locker slot at the factory default. skim stays 10 points of volume, anti sniper stays 90 points falling to 10 over 30 minutes if the v2 mev module allows it (else the nearest allowed values, reported) |
| 22 | the launch is signed by the v2 factory owner key (`deployTokenAsOwner`), which is the engine owner. the fresh deployer path and the factory admin enable and revoke steps are removed |

### 10.2 FeeRouter (src/FeeRouter.sol)

* `receive() external payable {}` and nothing else in it: no storage write, no cold read, no call. the hook pushes with the 2,300 gas stipend.
* `flush()`, permissionless, guarded against reentry: sends the whole balance to `engine` with a plain call and all gas, reverts if the call fails or while `engine` is unset. eth waits safely in the router until then.
* `engine`, set by the owner with `setEngine(address)` (must have code), any number of times until `lock()`, a one way lock with an event. events on every change.
* its own two step owner (`transferOwnership`, `acceptOwnership`), first owner from the constructor. it does not read the Core's owner: a later engine must be able to take over.
* no other function. it never holds coin on purpose and has no token path.
* trust note for the docs, in this strength: the router owner can point every future fee at any address with one call until the router is locked. it never touches what an engine already holds. this is the one owner switch in the system that directs value to an address the owner picks, the owner accepted it to keep a later engine migration possible. FLOW decision 8 is amended to say so.

### 10.3 Core change (the only one)

* `Stack` gains `feeSource`. `receive()` books eth as fees (checkpoint, `feeToBuybackBps` split, resync) when `msg.sender == FEE_SOURCE` and no measurement is in flight. eth from any other sender, the hook and the escrow included, is accepted and left for `skim()` as today.
* the forbidden target list takes the v2 addresses of V2-PORT.md section 7 plus the router.
* eth the v2 escrow holds for the Core (partial fill refunds of the Core's own buyback) is claimed by anyone with the escrow's claim and then booked by `skim()` to the pot. document it, no code.
* size: the Core must keep at least 60 bytes of headroom. if the change does not fit, move code to `CoreLib`, never drop a check.

### 10.4 launch package

rewritten for `IArtCoinsFactoryV2`: `DeploymentConfigV2`, the factory's own `predictToken` (the token creation hex and the hand prediction are deleted), `deployTokenAsOwner`. deploy order: library, controller, router (engine unset), Core (with `feeSource` the router and the predicted coin), the fee swapper if the v2 flow needs it deployed per coin, the launch, `router.setEngine(core)`, the swapper's post launch setup, postflight. preflight and postflight check every v2 field they can read back (restriction on, bounty recipient the router, bounty bps, lp fee, mev values, locker slots, protocol recipient reported, router engine and owner, nothing on the coin allowlist beyond the factory's seeds). the config hash sign off stays. owner steps on the v2 factory or escrow that the launch needs (for example registering the swapper as an escrow depositor) are listed in docs/DEPLOY.md as explicit owner commands.

### 10.5 tests

real contracts on the fork as before. the v2 stack is not on mainnet, so the fixture deploys it onto the pinned fork from prebuilt v2 artifacts (built from the v2 repo at the reference commit with the v2 repo's own compiler settings, vendored under test/v2-artifacts/ with the commit hash and the build command recorded in a README there), following the v2 repo's own deploy library. no hand written copy of a v2 contract and no mock of one. when v2 is live the fixture switches to the mainnet addresses by config.

### 10.6 amendments (owner, 2026-10-08). these win over 10.1 to 10.5

| # | decision |
|---|---|
| 23 | a trader pays 6.9 percent in total. skim `baselineSkimBps` 6_900 (6.9 points of volume), `lpFee` 0. v2's factory enforces a minimum lp fee, so the launch needs the factory owner to set that minimum to 0 first: an explicit owner command in docs/DEPLOY.md and a preflight check that the factory accepts the config. decision 20 is revoked: with no lp fee there is no lp income and no fee swapper anywhere in the launch package |
| 24 | `bountyBps` stays 9_000. the protocol leg (the factory floor, 10 percent of the skim, 0.69 points of volume) belongs to the launcher protocol. it is a separate business from this engine and its owner's share: never describe it as the engine owner's income |
| 25 | the router pays payees out of what it receives. the owner's intent is 0.5 points of volume to the creator and 0.5 points to the artist. at launch there is ONE payee: the creator address (the config owner address) with both shares, 1.0 point of volume. the router receives 6.21 points (9_000 of 6_900), so that is 161_030 parts per million of router inflow. the owner replaces it later through `setPayees` (with a splitter contract or two entries), so no artist address is needed for launch and nothing about it is a placeholder. the rest goes to the engine (5.21 points) |
| 26 | everything the router receives during the anti sniper window goes to the engine, with no payee share. the anti sniper skim starts at 90 points and falls to the baseline 6.9 over 30 minutes if the v2 module allows it (else nearest allowed, reported) |
| 27 | `flush` pays its caller a small tip out of what it forwards |
| 28 | the Core gains `rescueCoin(address to, uint256 amount)`, owner only, guarded, with an event: it transfers coin the Core holds. the Core only holds coin in passing (the buyback burns what it buys in the same call), so this reaches only coin that arrived some other way. FLOW decision 8 is amended: this is an owner directed transfer of the coin only, never of eth, credits, statements or exitToken |
| 29 | the Core is on the restricted coin's allowlist at launch (`restriction.allowed` holds the predicted Core). owner decision, it overrides decision 18 for the Core only (router: still not listed). accepted effects, to be written in ARCHITECTURE: anyone can send coin to the Core (it sits there until rescued), and after each buyback an allowance equal to the bought amount stays usable by anyone until the end of that transaction |

FeeRouter, replacing 10.2 where they differ:
* `receive() external payable {}` stays empty.
* modes. until the split starts every flush sends everything (after the tip) to the engine. `splitStart` is a timestamp the owner sets (the deploy script sets it to the launch block time plus the anti sniper window). the first `flush` at or after `splitStart` still sends everything to the engine and then turns the split on, so eth that arrived during the window is never shared. from then on each flush pays the payees their parts per million and the engine the rest.
* tip: `min(amount * tipPpm / 1e6, tipCap)` to `msg.sender`, taken off the top. launch 5_000 ppm (0.5 percent) capped at 0.005 ether. a failed tip send is skipped, never a revert.
* payees: up to 4 `(address, ppm)` entries, total at most 200_000 ppm (the engine always keeps at least 80 percent of a flush). a payee is paid by a plain call with a fixed gas cap; if that fails the amount is credited to `owed[payee]` and `claim()` lets the payee (or anyone, sending to the payee) pull it. a payee can never block a flush.
* the engine gets the rest by a plain call with all gas. if that call fails the whole flush reverts and the eth waits.
* owner setters, each with an event, all frozen by the one way `lock()`: `setEngine`, `setPayees`, `setTip` (ppm at most 20_000, cap at most 0.05 ether), `setSplitStart` (only while the split is not on).
* flush is guarded against reentry and reverts while the engine is unset.

### 10.7 amendment to decision 25 (owner, 2026-10-08)

the router's payee list holds ONE entry at launch: the creator address (the config `creator`), with the combined share of 1.0 point of volume, which is 161_031 parts per million of router inflow (1.0 / 6.21). there is no separate artist payee and no placeholder for one: the owner will later point the payee at his own splitter contract with `setPayees`. the router keeps supporting up to 4 payees. because a payee may be a contract, the fixed gas cap on a payee payment is 100_000 and the `owed` and `claim` fallback stays.
