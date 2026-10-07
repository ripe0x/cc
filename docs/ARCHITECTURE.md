# architecture

this file describes the system as it is on branch `flow`. SPEC.md is the original handoff spec and where the two differ this file wins. docs/FLOW.md is the director brief this branch was built from and stays for the reasons behind each decision. the last section lists what is accepted, for the owner to confirm.

naming rule: only `exitModule` and `exitToken`. never name or describe them anywhere.

## 1. goal, what we own, what is live

the engine exists to keep credits flowing into statements. statement sales do not need to profit. a statement that sells below the cost of its 80 credits is better than one that does not sell. unsold statements are fine: they stay listed and are redeemed through the exitModule in phase 2. the engine never stops buying because statements are unsold, there is no inventory gate. early on it should acquire as many credits as possible, score can matter later through `flatBps`.

we own three contracts. everything else is live on mainnet and is used as deployed.

| contract | role |
|---|---|
| `Core` | custody and every rule: pots, rate, cap, piles, doors, compose, listing on the auction house, `collectSales`, exit, overprint, both buybacks, settings, the owner doors, three one way locks and a two step owner handover. also the bounty recipient of the skim hook and the owner of its own auction house |
| `CoreLib` | the one linked library of the Core (`src/lib/CoreLib.sol`). the settings write (validation, storage, event), the rate climb and exit auction decay math, the pool manager swap of the buyback. stateless, called by delegatecall, deployed once before the Core. `SettingsBounds` and `SettingsStore` sit beside it as internal libraries |
| `ControllerV1` | first policy module and the statement sale. holds the core address and five sale settings. `nextPage(lane)` is ready when the pile holds 80 credits and returns the first 80 ids with format 0. `wants` returns 0, `nextOverprint` is never ready. it prices statements (`statementPrice`, `priceOf`) and in buy only mode sells them (`buy`). it holds no funds between calls and its settings belong to the live owner of the Core, `core.owner()` |

live and external, used as deployed.

| piece | what it is |
|---|---|
| artcoins stack | factory, skim hook, lp locker, fee escrow, anti sniper module, uniswap v4 pool manager. the Core takes it as the constructor argument `Stack` and stores it as immutables. the hook is the only address whose eth `receive()` books as fees |
| pnd auction factory | `SovereignAuctionHouseV2Factory` 0x77aB853543286C9Cdd7dd6c01222A7cC4Ac93d63. verified source in docs/reference/pnd, our minimal interface in `src/interfaces/AuctionHouse.sol` |
| the Core's house | an auction house the Core creates through the factory in its constructor. non upgradeable, owned by the Core forever, one per address, fee fixed at the factory default (0 at the pin). the Core approves it for all on Statements. the Core lists statements on it and never bids |
| Credits, Statements, CreditScore, CreditStrategy, Seaport 1.6 | constants in `src/interfaces/Interfaces.sol`: Credits 0x97630aA70AB14ed9883B41dAfccBc11349723043, Statements 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b, CreditScore 0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7, CreditStrategy 0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6, Seaport 0x0000000000000068F116a894984e2DB1123eB395. Permit2, the position manager and the universal router are constants too |

the live artcoins stack at the pin (block 26127622, notes in docs/reference/artcoins-notes.md) is the default config only. a new artcoins version changes the stack block of `script/config/mainnet.json` and nothing else in code.

| piece | address |
|---|---|
| ArtCoinsFactory | 0x49596c375c139E79bb937bcf826068a8F78D4e0e |
| factory owner | 0xCB43078C32423F5348Cab5885911C3B5faE217F9 |
| skim hook (ArtCoinsHookSkimFee) | 0x636c050296B5Cc528D8785169Bf8923716FCa9cc |
| lp locker | 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab |
| fee escrow | 0x7559689765aE86cBB38e68CD1294830CccB125F2 |
| anti sniper module (ArtCoinsMevLinearSkim) | 0xb038D597365FfD108D63C265Bb0621444a1D8B83 |
| uniswap v4 pool manager | 0x000000000004444c5dc75cB358380D2e3dE08A90 |
| pnd auction factory | 0x77aB853543286C9Cdd7dd6c01222A7cC4Ac93d63 |

the coin is an `ArtCoinsToken` launched through the factory, not our code. toolchain: solc 0.8.30, cancun, via_ir, optimizer 200, solady, v4 core and periphery pinned in `lib/`. every runtime contract must stay under 24,576 bytes (`forge build --sizes`). the Core is close to the limit, which is why settings validation and the math live in `CoreLib`.

## 2. settings

one `Settings` struct in Core storage (a fixed slot shared with `CoreLib`, three packed words), one owner function `setSettings(Settings)` and the `settings()` view. every economic number is a setting. nothing economic is a constant or an immutable, except what the artcoins pool fixes at launch (below). the bounds stop typos and keep every tip, reimbursement and keeper reward capped (section 10). they are also tightened where a wider range had no honest use: the spend cap is at most 5_000, the drop at least 500, the average score at most 6_000_000, the auction at least 6 hours, `exitAfter` at least 1 hour and the buyback slice at most 5 ether. they do not bound the price the owner sets for credits (section 10). `setSettings` checkpoints the eth rate and the exit rate first, so no climb is credited under the wrong numbers, then validates every field, stores them at once and emits the whole struct. `setRate(uint256)` resets the current eth limit within [1e11, 1e15] wei per point and at most `rateCap` and `setXRate(uint256)` the exit rate within its floor and cap, each with its own event. `rateStart` is the constructor input and the opening value.

| setting | launch value | bounds | meaning |
|---|---|---|---|
| `flatBps` | 10_000 | 0 to 10_000 | share of the bid priced flat per credit. 10_000 is flat, 0 is per score point |
| `avgScore` | 4_330_000 | 800_000 to 6_000_000 | the score a flat credit is priced as, and the "average credit" of the funded rule (1e4 scale, 433 points) |
| `climbBaseBps` | 100 | 0 to 1_000 | rate climb per hour at the start of the tiers |
| `climbDoubleEvery` | 24 hours | 1 hour to 30 days | the climb doubles every this long without a fill |
| `climbMaxBps` | 800 | `climbBaseBps` to 2_000 | the climb per hour is capped here |
| `dropBps` | 2_000 | 500 to 5_000 | drop of the rate for a spend of the whole pot |
| `spendCapBps` | 2_000 | 100 to 5_000 | share of the pot spendable per hour window |
| `bonusCapBps` | 2_500 | 0 to 5_000 | cap of the controller bonus on a credit's price |
| `tipSavingsBps` | 1_000 | 0 to 2_500 | keeper tip as a share of the savings on a listing |
| `tipCapBps` | 200 | 0 to 500 | cap of that tip as a share of the cost |
| `reimburseBps` | 11_000 | 0 to 15_000 | compose reimbursement as a share of gas cost |
| `reimburseCapBps` | 500 | 0 to 1_000 | cap of the reimbursement as a share of statement cost |
| `saleFloorBps` | 7_500 | 1_000 to 40_000 | the hard floor of a statement sale, bps of statement cost. no sale leaves the Core below it. the controller prices above it, the house reserve and `sellTo` are floored at it |
| `auctionDuration` | 24 hours | 6 hours to 30 days | runs from the first bid |
| `exitAfter` | 105 hours | 1 hour to 365 days | how long an eth lane statement must have been listed without a bid before it may be redeemed in phase 2 |
| `saleToBuybackBps` | 5_000 | 0 to 10_000 | share of sale proceeds that goes to the coin buyback, the rest to the pot |
| `exitToBuybackBps` | 5_000 | 0 to 10_000 | share of exitToken from eth lane exits that goes to the exit auction |
| `buybackSlice` | 1 ether | 0.01 to 5 ether | eth per buyback |
| `buybackDelay` | 25 | 1 to 7_200 blocks | blocks between buybacks |
| `keeperTipBps` | 50 | 0 to 500 | buyback keeper tip as a share of the slice |
| `xRateCap` / `xRateFloor` | 9_700 / 3_000 | floor at most cap at most 10_000 | bounds of the exit bid in bps of score |
| `xRateClimbPerHour` | 100 | 0 to 1_000 | exit bid climb per hour |
| `xRateDropPerCredit` | 20 | 0 to 1_000 | exit bid drop per credit bought |
| `xAuctionHalfLife` | 6 hours | 10 minutes to 30 days | exitToken auction price halving time |
| `exitSliceCredits` | 20 | 1 to 1_000 | exitToken auction slice, in average credits |
| `rateCap` | 123_200_000_000_000 (8 * `rateStart`) | 1e11 to 1e15, the rate bounds | the most the eth rate can ever be, wei per point. the climb stops at the lower of the funded clamp and `rateCap`, `setRate` refuses a value above it, and a lower cap pulls the rate down to it at the checkpoint. "never pay more than this per credit" |
| `exitLaneToBuybackBps` | 0 | 0 to 10_000 | share of exitToken from exit lane exits that goes to the exit auction, the rest to the exit bid pot. launch 0 keeps every exit lane exit in the exit bid pot |
| `feeToBuybackBps` | 0 | 0 to 10_000 | share of the swap fee eth that the hook pays into `receive()` that goes to the coin buyback, the rest to the pot. last field of the struct. eth booked later by `skim` goes to the pot whole |

other numbers. `SUPPLY` (1,000,000,000e18, read by the exit auction opening price and checked against the launch supply), `XRATE_START` (6000 bps) and `OVERPRINT_CAP_PER_DAY` (8) are constants. the skim split of the pool (9.5 points to the engine, 0.5 to the creator, anti sniper 90 to 10 over 30 minutes) is fixed inside the artcoins pool at launch and cannot be made adjustable here. the 5 percent raise and the 15 minute extension of an auction are fixed in the house.

## 3. the bid

rate is wei per whole point. the price of credit `id` at `rate` is

`price = rate * (flatBps * avgScore + (10_000 - flatBps) * score(id)) / 10_000 / 1e4 * (1 + bonus)`

with `bonus` from the controller, capped by `bonusCapBps` (ControllerV1 returns 0). at `flatBps` 10_000 every credit is priced as an average one and the score contract is not read on the eth doors. at 0 the bid is per score point. in between the blend pays a floor for any credit and a premium for score. `score(id) = CreditScore.scoreOf(Credits.seedOf(id), Credits.timestampOf(id))`. the exitToken bid stays per point, phase 2 pays by rating.

rate rules, as built:

| rule | what it does |
|---|---|
| opening | `RATE_START`, constructor input in [1e11, 1e15] and at most `rateCap` (the constructor reverts `BadRate` otherwise), 75 percent of the market price of a credit on launch day: `rateStart = 0.75 * price in wei * 1e4 / avgScore`, default 1.54e13 for a market price of 0.0089 eth |
| climb | lazy and checkpointed. `climbBaseBps` per hour, doubling every `climbDoubleEvery` since the last fill, at most `climbMaxBps`. at launch values 100, 200, 400, 800 bps per hour in 24 hour tiers |
| funded | the hourly cap can afford one average credit at the stored rate: `ethPot * spendCapBps >= avgScore * rate`. unfunded, the rate does not climb |
| clamp | the climb stops at `min(ethPot * spendCapBps / avgScore, rateCap)`: the point where the hourly cap no longer buys one average credit, so the bid never climbs where nobody can sell into, and never above the owner's `rateCap`. a lower `rateCap` pulls the stored rate down to it in `setSettings`, `setRate` refuses a value above it |
| drop | every spend of `x` from pot `p` drops the rate by `rate * dropBps / 10_000 * min(x, p) / p` and sets `lastFillTime`. for `buyListing`, `x = cost + tip` |
| hourly cap | a fixed window. the first spend after `windowStart + 1 hour` opens a new window with `windowPot = ethPot`. a spend needs `windowSpent + x <= windowPot * spendCapBps / 10_000`. tips count, gas reimbursements do not |
| gate | none. unsold statements never close the bid, stop the climb or slow a fill |

every pot change checkpoints first. accounting: `ethPot` (buying), `ethToBuyback`, `xPot` (exitToken bid), `xToBuyback`. invariant: pots never exceed what the core holds, and eth owed to the Core by the house is not in the pots until collected.

piles: per lane (eth, exit) an insertion ordered doubly linked list keyed by credit id. id 0 is the null sentinel and is refused at every door. per credit: lane, inPile, cost, acquiredAt. credits sent to the core outside the doors are not in a pile and are stuck.

## 4. fee intake

there is no hook of ours. the skim hook of the configured stack takes its skim in eth on every swap and pushes the bounty to `Core.receive()` with all gas.

* from the skim hook while no measurement is in flight: checkpoint the rate, split the amount by `feeToBuybackBps` (that share to `ethToBuyback`, the rest to `ethPot`), resync the funded flag, emit `FeesAdded` with the whole amount. at the launch value 0 everything goes to the pot.
* anything else (donations, refunds from a purchase, a measurement in flight): accept and book nothing. `skim()` books it later. during a `buyListing`, an exit or a `collectSales` measurement the unbooked eth lowers the measured cost, which keeps pot and balance consistent.
* `receive()` never reverts and stays cheap, because a revert would brick every swap in the pool. it has no reentrancy guard for the same reason (the hook calls it during a guarded buyback).
* there is no fallback function. the hook calls `streamForward()` on the recipient once its balance reaches 0.01 eth and relies on that call reverting and being caught.
* `notify(address)` is a payable no op, the referral payout target. with the referral cap at 0 the hook never calls it.
* `skim()` is permissionless and guarded. it moves `balance - ethPot - ethToBuyback` into `ethPot` and the same for the exitToken into `xPot`.
* `onERC721Received` accepts only Statements and Credits.

## 5. doors

| door | what it does |
|---|---|
| `sellForEth(ids)` and `(ids, minOut)` | pays the price of section 3 per credit from `ethPot`, one checkpoint and one cap check per credit. the credit goes to the eth pile. `minOut` protects the seller against a rate drop in the same block |
| `buyListing(value, data, id, target)` | the caller builds the calldata, the core calls an allowed target (Seaport 1.6 and CreditStrategy at launch) with `value`. cost is measured as the eth balance fall. needs the credit to arrive, `cost <= value <= price`, and pot and cap room. the keeper tip is `min(tipSavingsBps of savings, tipCapBps of cost)`, and `cost + tip` is booked as the spend |
| `sellForExitToken(ids)` and `(ids, minOut)` | phase 2. pays `score * xRate * unitPerPoint / 1e4` in exitToken from `xPot` into the exit pile |

forbidden targets, checked when a target is added and again at call time: Credits, Statements, the Core, the coin, the hook, the pool manager, the factory, locker and fee escrow of the stack, the Core's house and the auction factory, Permit2, the position manager, the universal router, the exitModule and the exitToken.

## 6. compose and listing

`compose()` (eth lane) and `composeExit()` (exit lane, phase 2) ask the controller for a page, pull 80 credits and build a Statement through the live Statements contract. the returned id must equal `Statements.supply()` and be owned by the core. anyone may call and is repaid `min(gasUsed * basefee * reimburseBps, reimburseCapBps of cost, ethPot)`, gas measured from entry plus 50,000 for the work after, plus 350,000 for the listing on the eth lane. the same rule repays the caller of `exitStatement` (section 8). the exit lane has no eth cost basis, so its cap is notional (`80 * avgScore * RATE_START / 1e4`, at the immutable opening rate, not the live eth rate the owner can set) and nothing is added to the statement cost. the controller's `nextPage` read gets a fixed gas cap (500,000, in both lanes; ControllerV1 uses about 73,000 for a full page, measured), so a gas burning controller cannot inflate the reimbursement.

an eth lane statement is listed at once, in the same transaction. `createAuction(sid, Statements, auctionDuration, reserve, 0)` on the Core's house, with `reserve = max(controller.statementPrice(sid, cost, listedAt), cost * saleFloorBps / 10_000)` at age zero, pulls the statement with `transferFrom` (approved at construction) and returns an auction id that the Core records with `listedAt`. an exit lane statement is held and never listed. the statement record holds cost, auction id, `listedAt`, lane, `held` and `listed`.

## 7. the house auction

the live house works as follows (docs/reference/pnd has the source).

| rule | what happens |
|---|---|
| first bid | at or above the reserve. starts the timer: the auction ends `auctionDuration` after it |
| later bids | at least 5 percent over the top bid. the previous bidder is refunded in the same call |
| extension | a bid in the last 15 minutes pushes the end to 15 minutes from the bid |
| before the first bid | the seller may cancel (the token returns) or change the reserve. after the first bid neither is possible |
| end | `endAuction` is permissionless after the end. it delivers the statement to the winner and then pays the seller. a seller that is a contract is never pushed eth, the proceeds are added to its `pendingRefunds` and it pulls them with `withdrawRefund()` |
| failed delivery | deferred, and after 30 days anyone can unwind it: the winner is refunded and the statement goes back to the seller |
| unbid | a statement with no bid stays listed with no end. nothing expires |

the Core never bids. in auction mode a bidder talks to the house directly (`createBid`, `endAuction`), after a `repriceStatement` that walks the reserve down to the asking price of the moment. in buy only mode a buyer calls `ControllerV1.buy`.

### sale controller

the asking price of a statement is set by the controller, the Core keeps custody, the hard floor and the booking of the money. `ControllerV1` has five settings, each set by the live owner at once with its own event: `buyOnly` (launch false), `startBps` (11_000, bounds 1_000 to 40_000), `stepBps` (100, 0 to 5_000), `stepEvery` (3 hours, 1 minute to 30 days) and `floorBps` (7_500, 1_000 to `startBps`). `statementPrice(sid, cost, listedAt)` is `cost * max(startBps - min(steps * stepBps, startBps), floorBps) / 10_000` with `steps = (now - listedAt) / stepEvery`: 110 percent at listing, one point every 3 hours, 75 percent at hour 105. in buy only mode `statementPrice` returns the start price without decay, so the house reserve is not walked down. `priceOf(sid)` is the decayed asking price in either mode, never below the Core hard floor, for frontends. in auction mode (launch) a first bid at the asking price opens the english auction on the house. in buy only mode `buy(sid)` (payable, guarded) takes the decayed asking price, calls `core.sellTo{value: price}(sid, msg.sender)` and refunds the excess last. the price is the larger of the decayed ask and `cost * saleFloorBps / 10_000`, so buy only mode keeps working when the owner raises the core floor above the controller `floorBps`. `buy` reverts in auction mode and while a bid is live. the Core calls `statementPrice` with a fixed gas cap (200,000) and reads one word: a controller that fails or answers short makes compose, the relist after an overprint and `repriceStatement` revert, so a listing is never priced blind. the one exception is the relist of `syncStatement` (a statement that came back from an unwound sale): it is listed at the hard floor, so redemption never depends on the controller. whatever the controller answers, the Core floors it at `cost * saleFloorBps / 10_000`.

| call | what it does |
|---|---|
| `collectSales()` | permissionless and guarded. if the house owes the Core anything (`pendingRefunds`), calls `withdrawRefund()` under the measuring flag, checks the balance rose by the amount, and splits it: `saleToBuybackBps` to `ethToBuyback`, the rest to `ethPot` (checkpoint first). everything the house credits to the Core is sale proceeds. `buyback()` runs the same collection first, without reverting if the house fails, so proceeds are never stranded and a house fault never blocks the buyback. until someone calls it, sale proceeds sit in the house and are not in any pot |
| `syncStatement(sid)` | settles the record lazily and permissionlessly. if the Core says listed but the house has no auction for it: when the Core holds the statement (a sale that unwound, or one that came back) it is relisted at the controller price at age zero (floored, and at the hard floor when the controller price read fails), otherwise it was sold, the record is cleared and `StatementSold` is emitted |
| `repriceStatement(sid)` | permissionless. sets the reserve of a listing with no bid to the controller's asking price now (floored at the hard floor), from the age of the listing. this is the call a first bidder makes before bidding, and it carries a change of the controller, of its settings or of `saleFloorBps` to old listings. it reverts `HasBid` after a bid, and reverts when the controller fails or answers short (the stored reserve stays) |
| `sellTo(sid, buyer)` | payable, only the controller, guarded. cancels the listing (reverts `HasBid` while a bid exists: a live auction always wins), requires `msg.value >= cost * saleFloorBps / 10_000` (else `BelowFloor`), sends the statement to `buyer`, books `msg.value` like collected proceeds (split by `saleToBuybackBps`), clears the record and emits `StatementSoldTo`. no refund logic in the Core |
| `statementStatus(sid)` | the live status read from the house: None, Held, Listed, Bid, Ended, Sold or Returned, with auction id, reserve, top bid and end time |
| `heldStatements()` | the ids the Core has a record of. may include sold statements until `syncStatement` clears them |

## 8. exit and overprint

exit (`exitStatement`). needs the exitModule. an eth lane statement must be listed, have no bid, and `now >= listedAt + exitAfter`. the Core cancels the listing (this reverts if a bid arrived first), then hands the statement to the module and must end with at least `rating * unitPerPoint` more exitToken, measured as a balance delta. an exit lane statement is never listed and exits at once. `unitPerPoint` (non zero, at most uint128) and `exitToken` are read when a module is set, and `unitPerPoint` again on every later set, never in between, so a module cannot change what it owes between sets. eth lane: `exitToBuybackBps` of the received amount to `xToBuyback`, the rest to `xPot`. exit lane: `exitLaneToBuybackBps` (launch 0) of the received amount to `xToBuyback`, the rest to `xPot`. either way a share that is not zero re anchors the exit auction like any injection. the caller of `exitStatement` is repaid gas in eth from `ethPot` by the rule of compose: `min(gasUsed * basefee * reimburseBps, reimburseCapBps of the statement cost, ethPot)`, with the notional cap of the exit lane for an exit lane statement. the gas counted is the call plus 50,000 and is cut at 1,500,000, so a gas burning module cannot push it past the cap. nothing is added to a cost basis, and the eth is paid last, after all state is final.

replacing the module (`setExitModule`, owner only, effective at once, any number of times until `lockExitModule`). the exitToken never changes once set: a later module must report the same `exitToken()` or the set reverts `ExitTokenChanged`. the validity checks are those of the first set (code, forbidden targets, unit in range, opening price floor computed with the new unit). setting the same address again is allowed and is how a changed unit is taken over. a later set checkpoints the exit rate under the old unit first, then stores the module and the unit, and resyncs the funded flag. the exit auction price is coin per exitToken and does not depend on the unit, only the slice does: a later set never touches the start price or the clock, with or without something for sale, so `buybackExit` is never cheaper per exitToken right after a set and a mistaken unit leaves no poison in the price. only the first set opens the auction. a set also clears `allowedTarget` of the new module. pots, piles and held statements are untouched, `ExitModuleSet` is emitted every time, the old module stops being a forbidden target and the new one is forbidden from then on. while the exit measurement runs `receive()` books nothing. `exitStatement` is permissionless.

overprint. permissionless and guarded. asks `controller.nextOverprint()`, needs two different held statements of the same lane, at most 8 per day. on the eth lane both must be listed with no bid: both listings are cancelled, costs add onto the base, the top is merged into it, the base keeps its id and is listed again with the summed cost, and the combined score is checked against the sum.

## 9. buybacks and the exitToken lane

eth buyback. `buyback()`, guarded. collects sales first, then takes a slice `min(buybackSlice, ethToBuyback)`, at most once per `buybackDelay` blocks, tip `keeperTipBps` of the slice to the caller. the core swaps exact in through `PoolManager.unlock` and `unlockCallback` (the swap itself is `CoreLib.swapIn`) on the canonical pool key `(0, coin, POOL_FEE, TICK_SPACING, HOOK)`, takes the coin to itself (the core is exempt from the tax) and calls `burn` on the token, so total supply falls. it reverts `NothingBought()` when no coin came out. the callback returns what was spent and bought and requires the pool took no more than it was given. the tip scales down on a partial fill and unspent input goes back to `ethToBuyback`. the hook's skim on this swap returns to the core through `receive()`. there is no min out (section 14).

exitToken lane (phase 2 only). exit lane credits are bought with the exitToken bid and composed with `composeExit()`.

| item | rule |
|---|---|
| bid | `xRate` in bps of score starts at 6000, caps at `xRateCap`, floors at `xRateFloor`, climbs `xRateClimbPerHour` while funded (its pot affords one average credit) and drops `xRateDropPerCredit` per credit |
| exitToken auction | there is no exit pool. the buyback of the exitToken is a dutch auction inside the core, paid in coin that the core burns |
| slice | `min(xToBuyback, exitSliceCredits * avgScore * unitPerPoint)` |
| price | coin wei per exitToken unit, wad scaled. `price(t) = startPrice * 2^(-(t - startTime) / xAuctionHalfLife)`, continuous, never reverts, reaches zero for long gaps |
| cost | `coinIn = ceil(slice * price / 1e18)`, at most the caller's `maxCoinIn`. `buybackExit(maxCoinIn)` does `burnFrom(msg.sender, coinIn)` on the coin, then the slice goes to the caller. no tip, no delay, the caller approves the core first |
| restart after a fill | `startPrice = max(2 * clearingPrice, previousStartPrice / 4)`, `startTime = now`, at least 1 |
| clock | runs only while `xToBuyback` is not zero |
| injection | every time exitToken is added to `xToBuyback`: `startPrice = max(price now, startPrice / 4)` and `startTime = now`. injected funds never inherit a decayed clock |
| first start price | set when the first module is set: the price at which one full slice costs the whole coin supply. setting a module reverts `BadModule` if this is below 1e12 (computed with the unit of that set). a later set never touches the start price or the clock (section 8) |
| half life change | `setSettings` re anchors the curve at its price now when `xAuctionHalfLife` changes |
| views | `exitAuctionPrice()`, `exitAuctionQuote()` returning `(slice, coinIn)` |

the restart rule means the next auction can never start more than 4x below the start of the previous one, so a price that decayed to dust does not carry over. a taker who fills near a fair price restarts the auction at twice what they paid, and the cadence is one slice per half life. the same quarter floor applies to every injection.

## 10. owner powers, and the hard rule

| power | how it works |
|---|---|
| every economic number | `setSettings(Settings)`, `setRate`, `setXRate`. owner only, effective at once. bounded by `SettingsBounds`, the whole struct emitted in `SettingsSet` |
| controller | `setController(address)`, effective at once, never zero. reverts `Locked("controller")` after `lockController()` |
| exitModule | `setExitModule(address)`, effective at once, any number of times. the exitToken must stay the same, the unit is read again on every set. reverts `Locked("exitModule")` after `lockExitModule()`, which itself reverts while no module is set |
| allowed targets | `addTarget(address)` at once (forbidden targets refused), reverts `Locked("targets")` after `lockTargets()`. `removeTarget` at once, also after the lock |
| locks | `lockController()`, `lockExitModule()`, `lockTargets()`. owner only, one way, each with its own event (`ControllerLocked`, `ExitModuleLocked`, `TargetsLocked`) and public flag (`controllerLocked`, `exitModuleLocked`, `targetsLocked`). the Core settings and the controller's own sale settings stay adjustable after a lock |
| owner handover | `transferOwnership(address)` by the owner sets `pendingOwner` (the zero address clears it), `acceptOwnership()` by the pending owner completes it. events `OwnershipTransferStarted` and `OwnershipTransferred`. there is no renounce. every owner check and the controller's `core.owner()` read use the live owner |
| sale settings | on the controller: `setBuyOnly`, `setStartBps`, `setStepBps`, `setStepEvery`, `setFloorBps`, owner of the Core only, at once, each with an event |

the owner is the first owner of the launch config until a handover. **the hard rule: the owner cannot transfer eth, credits, statements, coin or exitToken out of the Core directly.** there is no function that sends them to the owner or to an address the owner chooses. that holds under every combination of settings, because every direct outflow is capped by a bound: tips by `tipCapBps` (500 at most) and `tipSavingsBps`, the compose reimbursement by `reimburseCapBps` (1,000 at most) of statement cost, the buyback keeper tip by `keeperTipBps` (500 at most), and credit purchases only pay sellers of real credits at the bid price, and the credits stay in the Core. the controller is read only for the Core: it names credits to compose and a bonus capped by `bonusCapBps`, and the Core enforces every limit itself. what the owner controls here is trust, not custody: a module set by the owner receives statements, and must return at least `rating * unitPerPoint` of a token the owner chose.

**what the rule does not say.** the owner sets the price the engine pays for a credit, and the owner may sell credits to the engine. so a dishonest owner, or a stolen owner key, can drain the eth pot without transferring anything out: it raises the limit (`setRate` up to 1e15, `rateCap` up to 1e15, `avgScore` up to 6_000_000, `spendCapBps` up to 5_000, `dropBps` down to 500) and sells credits to the engine at an inflated price through a seller it controls. the credits stay in the Core but are worth a small part of what was paid. the bounds limit the pace, not the price. measured on the fork with the tightened bounds (`test_ACCEPTED_ownerCanOverpayAnAccompliceSeller`, `test_ACCEPTED_ownerPerDayWorstCase`): per transaction (one block, every lever at its loosest, rate 1e15, `avgScore` 6_000_000): 47.4 percent of a 10 eth pot paid out (the spend cap allows 50 percent) for credits worth 0.07 eth, 0.6 eth paid per credit; per day (the owner acting every hour for 24 hours, loosest settings): 99.99 percent of the pot; at the launch settings with only `setRate` under the launch `rateCap` (no `setSettings`): 19.3 percent in the first window and 98.96 percent in 24 hours, for credits worth 1.69 eth against 9.9 eth paid. after that every eth of fee inflow can be taken the same way. holders therefore trust the owner key, the same trust as for the token admin. the owner accepted this (no raise guard on the settings, they are adjustable at once). a multisig owner and public `SettingsSet` and `RateSet` events are the mitigation.

**trust note.** with no delay the owner key controls everything at once: it can point the exitModule at a contract that returns dust and take every statement, swap the controller and sell every statement at the hard floor, lower the hard floor to its bound, and overpay for credits as documented above. a stolen owner key means the whole engine at once. the owner chose this: the system is new and must adapt fast, and he will announce changes off chain. holders trust the owner key fully. the three locks close doors later, and a handover can move the owner to a multisig, but until then nothing stands between the key and the engine.

what the owner can do at once is change every economic number: the bid, the reserve, the split of proceeds, the pace. holders trust the owner not to do so against them, the same trust as for the token admin. every change is one event with the whole struct, so it can be watched.

## 11. launch

one call to `ArtCoinsFactory.deployTokenWithProtocolBpsAndTax(cfg, 0, tax)` with `msg.value` equal to the live `deployFee()` (0.069 eth at the pin). script and tests use the same builder (`script/Builder.sol`, `script/Deploy.s.sol`), driven by one `LaunchConfig` loaded from `script/config/mainnet.json`. the config holds the stack (with `auctionFactory`), `rateStart` and the whole `settings` block with the launch values of section 2. there is one config file.

| field | value |
|---|---|
| supply | 1,000,000,000e18, no extensions, all of it in the locker |
| pool | native eth against the coin, hook = skim hook, dynamic fee flag 0x800000, tick spacing 200 |
| start price and position | tick -175000, about 40M coin per eth. one position from -175000 to 887200, 10,000 bps |
| skim | baseline 10 points of volume, `bountyBps` 9500, so 9.5 points to the core and 0.5 to the creator. `bountyRecipient` = Core, `protocolRecipient` = creator, `referralPayout` = Core. referral cap 0, `lpFee` 0 |
| anti sniper | linear skim module (90_000, 10_000, 1800): 90 points decaying to 10 over 30 minutes, the extra lands in the core's pot |
| locker | one reward slot: recipient creator, admin 0xdEaD, 10,000 bps |
| tax | enabled, `taxBps` 1500, `taxBpsMax` 2000, burn 0xdEaD, canonical pool = this pool, exempt = the Core, 44 venues |
| token admin | the deployer during launch, then `lockPoolExtension` and `updateAdmin(owner)` |

six transactions: the library `CoreLib` (CREATE2 through the deterministic deployer, no deployer nonce), ControllerV1, Core (its constructor needs code at the stack, creates the house through the auction factory, approves it on Statements and stores the settings), the launch through the factory, `lockPoolExtension`, `updateAdmin`. preflight also checks the auction factory has code, that its default fee is 0 (a loud warning otherwise) and that no house exists yet for the predicted Core address. postflight reads back the house (owned by the Core, fee 0, approved on Statements), the linked library and `settings()` field by field. the runbook, the factory deprecation guard, the private relay, the resume paths and the exact commands are in docs/DEPLOY.md.

## 12. tests policy

real contracts only. fork at block 26127622 (`FORK_BLOCK`), rpc from `MAINNET_RPC_URL` in `.env`.

| group | rule |
|---|---|
| live, never faked | Credits, Statements, CreditScore, CreditStrategy, Seaport 1.6, the pool manager, the whole artcoins stack (factory, token, skim hook, locker, escrow, anti sniper module), the pnd auction factory and the Core's real house |
| the two stand ins | `MockExitModule` and `MockExitToken` in `test/standins/`. nothing is deployed for them yet |
| attackers | hostile target, scripted and fuzz controllers, probes, statement buyers, mid swap callers, in `test/attackers/`. they attack the real system, they do not replace any of it |
| swaps | a small unlock based test swapper (a caller, not a stand in) and one test that buys and sells through the real universal router |
| owner action forced | one prank of the real factory owner: `setAdmin(deployer, true)` |
| rehearsal | `test/Rehearsal.t.sol` forks the latest block and skips unless `REHEARSAL` is set. the default suite stays pinned and fast |

everything in SPEC sections 10 and 11 still needs coverage, adapted to this file. `test/Flow.t.sol` covers the rework: settings and bounds, the blended bid, listing, bids on the real house, `collectSales`, `syncStatement`, `repriceStatement`, exits of unbid listings, overprint of listings. the simulator (sim/engine.js, sim/index.html, docs/SIMULATION.md) models the same rules and names, and its test reads script/config/mainnet.json to check the launch values.

## 13. invariants

SPEC section 10 invariants hold, with these changes.

| # | invariant on this branch |
|---|---|
| 3 | a statement only leaves the Core by a house auction whose reserve was at least the hard floor (`cost * saleFloorBps / 10_000`) when it was set, by `sellTo` with payment at least the hard floor, by an exit that returned at least `rating * unitPerPoint`, or as the top of an overprint |
| 5 | pots never exceed what the Core holds, and eth owed to the Core by the house is not counted in the pots until `collectSales` books it |
| new | the owner cannot transfer assets out directly (section 10), under every setting inside the bounds. the owner can still overpay a seller of credits it controls, at a bounded pace (section 10, item 28 of section 14) |
| new | no state of the statement stock closes the bid, stops the climb or stops a fill |

## 14. accepted properties and risks for the owner to confirm

none of these is a code change in this repo. each is a deliberate departure from SPEC.md or a property of the live stack we accept.

| # | item | what it means |
|---|---|---|
| 1 | the owner can change every economic number at once | the bid, the reserve, the split of proceeds, the buyback slice, the exit bid, the exit auction. no delay. holders trust the owner. only the bounds limit it. the owner cannot transfer assets out directly under any of them, but it can overpay a seller it controls (item 28) |
| 2 | `saleFloorBps` can be set as low as 1,000 | the controller can then ask, and the Core accept, as little as 10 percent of the cost. selling below cost is the stated goal, but a low floor with a low controller price gives statements away. `repriceStatement` moves old listings, so a cut reaches the whole stock at the price of one call each. a raise of the floor or of the controller price reaches a listing only through `repriceStatement`, and a raise is not atomic (item 39) |
| 3 | the 5 percent raise and the 15 minute extension are fixed in the house | the Core cannot change them. the owner cannot change the house, it is non upgradeable. the house fee is fixed at the factory default at creation (0 at the pin) |
| 4 | sale proceeds sit in the house until someone calls `collectSales` | they are in no pot, so they do not fund buying or the buyback until then. `buyback()` collects first. a keeper should call `collectSales` regularly |
| 5 | the english auction is in practice a fixed price at the reserve | the simulation finds a second bidder in about a third of sold auctions at most, and the price is on average 2 percent over the reserve. the reserve is the price, and with the launch controller it falls one point every 3 hours until a first bid, because a first bidder reprices to the asking price of the moment |
| 6 | `exitStatement` is permissionless | once the exitModule is set, anyone can redeem a listing that has had no bid for `exitAfter`, at whatever the exitToken is worth. at a low exitToken price that gives up a sale a buyer might still have made. the owner controls it through `exitAfter` and the time the module is set |
| 7 | a house failure | a failed delivery to the winner is deferred and unwinds after 30 days. a statement can come back to the Core, `syncStatement` relists it. `heldStatements()` may show sold statements until synced |
| 8 | the skim split is fixed | 9.5 points to the engine and 0.5 to the creator are set inside the artcoins pool at launch. it is not a setting |
| 9 | tax is a deterrent, not a wall | wallet to wallet transfers and unlisted venues pay neither skim nor tax. sells are never taxed. the venue list is frozen at launch. the token admin can lower the rate |
| 10 | anyone can LP the canonical pool | after the anti sniper window anyone may add liquidity. the launch position stays locked |
| 11 | token admin powers | the owner, as token admin, can lower the tax, set metadata and renderer, lower the referral cap, and attach an allowlisted pool extension (`lockPoolExtension` at launch closes that path). the admin cannot change recipients, bounty split, skim, ticks, venues or the exempt list |
| 12 | artcoins factory owner powers | 0xCB43 can deprecate the factory, set the deploy fee (up to 1 eth), set hooks, lockers and mev modules for new launches and mark admins. it cannot touch a launched pool, token, skim leg or locker position |
| 13 | `receive()` gas | adds about 15.6k gas to every swap in the pool, and must never revert or the pool is bricked for everyone |
| 14 | referral cap is 0, `notify` is a no op | eth received that way is booked later by `skim`, so a raised cap can never revert a swap |
| 15 | hourly cap is a fixed window | two adjacent windows can spend twice the share across a boundary. tips count against it, gas reimbursements do not |
| 16 | funded clamp equals the hourly cap | the bid cannot climb above what the cap lets anyone sell into. with a pot under one average credit over the cap the rate does not climb at all |
| 17 | eth buyback has no min out | the swap is exact in with no price floor. the launch liquidity is locked, and the slice (at most 5 ether) and the delay bound the exposure: a sandwich of a 1 or 5 eth slice loses money for the attacker after both skims |
| 18 | exit auction sells at a discount | the opening price asks the whole supply for a slice and falls by half every `xAuctionHalfLife`. buyers take exitToken below its market value whenever they wait. the restart rule keeps each start at least a quarter of the last, and the pace is one slice per half life, so a large exit batch waits months |
| 19 | `unitPerPoint` changes only with a set | read when the exitModule is set and again on every later set, never in between. the module cannot change what the Core requires afterwards without a set by the owner |
| 20 | fee on transfer or rebasing exitToken unsupported | pot accounting and the balance delta checks assume the amount sent is the amount received |
| 21 | credits sent to the Core outside the doors are stuck | they are in no pile. same for eth from a non hook sender until `skim` books it |
| 22 | the stack is a deploy input | the Core stores the stack it launched on and cannot be repointed. a launch on a new artcoins version is a new Core. `rateStart` is a deploy input in [1e11, 1e15], at most `rateCap` |
| 23 | SPEC sections on the Coin, FeeHook and Launcher do not apply | replaced by the live artcoins token, skim hook and factory |
| 24 | third party fee income | eth pushed by the hook from any open pool that names the core as bounty recipient is booked as fee income. it is a donation by the sender, so `FeesAdded` is not proof of organic volume |
| 25 | cost basis in `buyListing` | a hook push that lands inside the target call lowers the measured cost, so the stored basis and the reserve are understated by it. the books stay exact |
| 26 | venue tax bypass | the venue tax can be bypassed with a flash liquidity add and remove in the canonical pool, so model fee income on canonical pool volume only |
| 27 | the library | `CoreLib` is a deployed contract the Core links against. it is stateless and its address depends only on its bytecode. a proxy is not used anywhere |
| 28 | the owner can overpay a seller of credits it controls | see section 10. accepted by the owner. at most `spendCapBps` (5,000) of the pot per hour window, one window per hour. measured worst case 47.4 percent of the pot per transaction (bound 50 percent) and 99.99 percent per day with every setting loosened (98.96 percent per day with only `setRate` at the launch settings). mitigations are social: a multisig owner, `SettingsSet` and `RateSet` events, and `rateCap` as the owner's own visible ceiling on the price per credit |
| 29 | the exitModule door stays open and is immediate | the module door stays open for the life of the engine unless the owner calls `lockExitModule()`. a dishonest owner or a stolen key can set, at once, a module that returns dust for statements (a tiny unit) or a unit so high that the exitToken bid overpays an accomplice from `xPot`, and can take every statement held in the Core. the owner accepted this in exchange for a repairable exit side and fast changes, and announces changes off chain. the exitToken itself can never change |
| 30 | a unit rise enlarges the slice | the auction price is coin per exitToken and a set does not touch it, but the slice is `exitSliceCredits * avgScore * unit`. after a rise each fill sells more exitToken at one price and the pot drains in fewer fills (measured: 57 percent less coin per exitToken for a 100x rise, a 10x fall cuts the coin cost of a full slice 10x). lower `exitSliceCredits` in the same batch as a set that raises the unit (runbook in docs/DEPLOY.md) |
| 31 | the exit bid pays the old unit until the set is mined | before a unit fall the exitToken bid pays the old unit, so a seller who sees the owner's set in the mempool can sell credits into it at the old, higher payout in the same block. send the fall in a batch that first lowers `xRateCap` and the rate (`setSettings`, `setXRate`) and restore after |
| 32 | a unit rise does not clamp the exit rate | the rate stays and funded flips false, so exit bid sales revert `PotTooSmall` until `setXRate` lowers it |
| 33 | the opening price floor bounds a later unit | the check that the opening price computed from the new unit is at least 1e12 also caps how high a later unit may go (with launch settings about 1.15e25). a unit above it reverts `BadModule`, and a later `setSettings` of `exitSliceCredits` or `avgScore` moves that ceiling |
| 34 | the two exit shares are named by lane | `exitToBuybackBps` is the eth lane share and `exitLaneToBuybackBps` is the exit lane share |
| 35 | the owner changes the controller, the exitModule and the targets at once | decision 7 of docs/FLOW.md is revoked. the owner key sets the controller, the exitModule and the allowed targets at once. see the trust note of section 10 |
| 36 | one way locks | `lockController`, `lockExitModule` and `lockTargets` cannot be undone. `lockExitModule` reverts while no module is set. a lock does not freeze the Core settings or the controller's sale settings |
| 37 | owner handover | two steps, no renounce. a handover to an address that cannot call `acceptOwnership` simply never completes and can be replaced or cleared. the pending owner has no power before it accepts |
| 38 | mainnet caps a transaction at 16,777,216 gas | EIP-7825, since the fusaka upgrade. every transaction of the system fits (`test/GasCap.t.sol`, an estimate from cold access gas plus intrinsic and calldata). the largest: `compose` 9.30 million (55.4 percent of the cap, 7.47 million of headroom), `composeExit` 8.97 million (53.4 percent), Core creation 5.94 million (35.3 percent), launch through the factory 4.25 million (25.3 percent), `overprint` about 1.37 million (8.2 percent). everything else is under 3 percent. the sell doors have no batch bound in the Core, the cap stops a batch at about 93 to 116 credits and an oversized call reverts for its caller. a controller read uses at most 47 percent of its gas cap (`nextPage` 235,693 of 500,000 cold; the 73,000 figure of earlier notes was a warm read). a different gas schedule would change these figures: rerun the test |
| 39 | raising `saleFloorBps` is not atomic for an EOA owner | a house reserve stays valid until `repriceStatement` runs on it, which is the accepted design. a listing that has a bid, or gets one before its reprice lands, sells at its old reserve, below the new floor. `SetSettings` with `REPRICE=1` closes the snapshot gap (it reads `heldStatements()` again after `setSettings`, reprices what is below, and prints what it could not reprice and why) but not that window. an owner that is a multisig can batch `setSettings` and the reprices in one transaction, yet cannot include a statement composed after its snapshot, so it reruns the script once after. a forge run cannot see chain state mined after it started, so the rerun is part of the procedure. it matters only when the new floor is above a listing's current reserve: a fresh listing sits at 110 percent of cost with the launch settings. one transaction holds about 300 reprices. `test/audit/FloorRaiseRace.t.sol` |
