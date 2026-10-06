# review: flow rework, settings, flat bid, library split

independent review of branch `flow` at 1c0e16f. scope: settings and bounds, packed storage, the flat or blended bid, the CoreLib split, runtime size. the auction house integration and the deploy scripts are covered elsewhere. every finding of medium or higher has a passing proof of concept in `test/ReviewFlowCore.t.sol` (`test_POC_*`, mainnet fork). naming rule kept: only `exitModule` and `exitToken`.

## status

| finding | status | one line |
|---|---|---|
| FC-1 | accepted | the owner chose economic control of the pot: every setting adjustable at once, no timelock, no raise guard. mitigated by bounds only (`spendCapBps` at most 5_000, `dropBps` at least 500, `avgScore` at most 6_000_000, rate bounds kept). worst case measured under the new bounds on a 10 eth pot: 47.4 percent of the pot in one transaction (the spend cap allows 50 percent; 8 credits worth 0.07 eth paid 4.74 eth), 99.99 percent in 24 hours with every setting loosened, 98.96 percent in 24 hours with only `setRate` at the launch settings. `test_ACCEPTED_ownerCanOverpayAnAccompliceSeller`, `test_ACCEPTED_ownerPerDayWorstCase`. docs/ARCHITECTURE.md section 10 and docs/FLOW.md rule 8 say it |
| FC-2 | fixed | `reserveBps` at least 3_000, `auctionDuration` at least 6 hours. `test_FIXED_reserveAndAuctionDurationFloors` |
| FC-3 | fixed | `buybackSlice` at most 5 ether. `test_FIXED_buybackSliceCapStopsTheSandwich` |
| FC-4 | fixed | the exit lane compose reimbursement cap is the notional of an average statement at the immutable `RATE_START`, and the controller's `nextPage` read has a fixed gas cap (500,000, about 7 times the measured 73,000 of a full ControllerV1 page) in both lanes. `test_FIXED_gasBurningControllerCannotFarmTheExitLaneReimbursement` |
| FC-5 | fixed | new setting `rateCap` (last field of `Settings`, launch 123_200_000_000_000 = 8 * `rateStart`, rate bounds): the climb clamps at min(funded clamp, `rateCap`), `setRate` refuses above it, a lower cap pulls the rate down at the checkpoint. `test_FIXED_idleClimbStopsAtTheRateCap`, `test_FIXED_rateCapIsAHardCeiling`, `test_FIXED_climbClampsAtTheRateCap` |
| FC-6 | fixed | the `setSettings` forward builds the call above the free memory pointer instead of at memory 0 |
| FC-7 | fixed | `exitAfter` at least 1 hour. `test_FIXED_exitAfterFloorKeepsTheListingOpen` |

after the fixes the Core runtime is 23,992 bytes (margin 584 of 24,576), no Lens was needed. the sections below are the review as written, before the fixes: where a number differs (the bounds, the 663 byte margin) the status table and the docs it names are current.

## 1. verdict

conditional go for mainnet.

* the plumbing is sound. no division by zero, overflow, underflow or unbounded loop is reachable at any in bounds setting. `receive()` cannot be made to revert by any combination of settings, gaps or owner calls (worst case 44k gas after a 100 year idle gap). the packed settings round trip at both ends of every bound, out of width calldata is refused, never truncated. the library cannot be called directly, holds no state, has no selfdestruct, and a Core cannot be constructed against an address with no code. a settings change checkpoints both rates first and creates or destroys no credited climb.
* the hard rule does not hold in the sense the brief asks for. the owner, or anyone the owner sells credits through, can move almost the whole eth pot out of the Core in one block, because the bounds limit the speed and the size of a fill, not the price paid per credit (FC-1). the owner chose to accept economic control. the numbers are in section 2 so the choice is made with them.
* three further bounds are wider than any honest use needs and each has a proven loss: the statement reserve floor (FC-2), the buyback slice ceiling (FC-3) and the exit lane reimbursement cap (FC-4). all three are fixed with constants or a few bytes.
* conditions for launch: (a) tighten the constants in section 5 (zero bytes), (b) fix FC-4 (saves bytes), (c) decide on the FC-1 guard (measured plus 219 bytes), (d) FC-5 and FC-6 are small and cheap and should ride along. all four fixes together fit in the 663 byte margin (measured: margin 337 after all of them, 1,106 if the view helpers of section 7 are cut).

## 2. what the owner can extract

pot means `ethPot`. "per tx" is the largest single block take. "per day" is sustained use at launch settings with the owner acting every hour. measured numbers are from the PoC tests on a 10 eth pot.

| path | bound that limits it | worst case per tx | worst case per day |
|---|---|---|---|
| setRate to 1e15 and sell cheap credits (accomplice, or the owner's own credits) | rate at most 1e15, price per avg credit at most 0.433 eth (0.8 eth at avgScore 8M), hourly cap | at launch spendCap: 20% of the window pot. measured with spendCap 10_000, drop 0, avgScore 8M in the same block: 96% of the pot (9.6 of 10 eth) for credits that cost 0.107 eth | measured 99.2% (setRate only, launch settings, one window per hour, 33 credits worth 0.29 eth took 9.92 eth) and then every eth of fee inflow |
| setSettings spendCapBps 10_000 and dropBps 0 | spendCap at most 10_000, drop may be 0 | removes the 20% flow limit and the price decay: 100% of the pot in one tx | same |
| avgScore 8_000_000 | upper bound | flat price times 1.85 against launch | multiplies the rows above |
| flatBps | 0 to 10_000 | no extra. changes who is paid more, not how much leaves | none |
| controller bonus (timelock 7 days, collusion) | bonusCapBps at most 5_000, hourly cap | 33% of each spend is surplus. at launch cap 20% of pot per hour, so about 6.7% of the pot per hour | about 33% of the pot per day |
| tips on `buyListing` | tipSavings 25%, tipCap 5%, never above the ceiling | cost plus tip is at most the ceiling, so a tip adds nothing over selling at the ceiling | none |
| compose reimbursement, eth lane | at most 1.5 times gas times basefee and 10% of statement cost | 10% of one statement's cost (0.0136 of 0.136 eth measured at 50 gwei). caller net at most 3.3% of cost | per page of 80 credits |
| compose reimbursement, exit lane | 1.5 times gas times basefee. the cap is notional and follows the eth rate, so it does not bind (FC-4) | measured 0.82 eth out of the pot for one page with a gas burning controller (20M gas at 20 gwei), caller nets 0.27 eth | per page, limited by pages and basefee |
| coin buyback keeper tip | keeperTip at most 5% of the slice, slice at most 100 eth | 5 eth per call at a 100 eth slice | 5% of all eth routed to the buyback |
| coin buyback sandwich | slice at most 100 eth, no min out (FC-3) | measured: front run 150 eth, back run 196 eth, the Core burns 84% fewer coin. gain is 46 eth on a 100 eth slice. slice 1 and 5 eth lose money for the attacker, 10 eth plus 6%, 25 eth plus 19% | the buyback balance |
| reserveBps 1_000 with a one hour auction | reserve floor 10% (FC-2) | one statement sold at 10% of cost unless a stranger bids inside the hour (measured 0.0138 for 0.138 eth cost) | every statement listed after the change, and old listings through `repriceStatement` (their 24 hour duration stays) |
| exitAfter 0 | floor 0 (FC-7) | an unbid listing is cancelled and exited in the block it was made. no bidder can act | the whole unbid stock, once an exitModule is set (timelock 7 days) |
| exitModule path | timelock 7 days, unit read once | any statement the owner's module returns at least rating times unit for. trust, not a settings bound | out of scope, held |
| xRate 10_000 and setXRate | wash | measured: selling 80 credits at 100% and exiting the statement leaves the exit pot exactly whole | none |
| xAuctionHalfLife 10 minutes | dutch auction is open to all | a discount only if nobody bids, at most the xToBuyback balance | none beyond that |
| saleToBuybackBps, exitToBuybackBps | routing | moves value between pots, never out | none |
| climb settings and idle climb | clamp at 20% of the pot per credit (FC-5) | with no seller for 113 to 152 hours one credit pays 19.99% of the pot (22x to 450x market) | once per episode |

the dominant path is the first row. every other row is smaller or needs a timelock. no static bound can stop it: a bound on the rate only moves the premium over the market price, and a seller always gets the premium. only a time guard (the rate cannot rise fast) or a delay on loosening can. section 5 sizes both.

## 3. findings

| id | severity | title | status |
|---|---|---|---|
| FC-1 | high (accepted by the owner, unmitigated) | the bounds do not bound the price paid per credit: setRate plus spendCap, drop and avgScore move almost the whole pot in one block | proven |
| FC-2 | medium | reserveBps floor 1_000 with a one hour auction sells a statement at 10% of cost | proven |
| FC-3 | medium | buybackSlice up to 100 eth with no min out: the buyback is sandwiched for 46% of the slice | proven |
| FC-4 | medium | exit lane compose reimbursement is capped by a notional cost that follows the eth rate, so a gas burning controller farms the pot | proven |
| FC-5 | low | flat idle climb has no absolute ceiling: after 5 to 6 days with no seller one credit pays 20% of the pot | proven |
| FC-6 | low | `setSettings` forwarding writes calldata over memory 0 to 0x344 inside an assembly block marked memory safe | unproven |
| FC-7 | low | exitAfter 0 lets the exit cancel a listing in the block it was made | proven |

## 4. details

### FC-1 the price per credit is not bounded (high, accepted by the owner)

what is bounded: the pace (spendCapBps, one window per hour), the size of one fill (the pot), the rate range at `setRate` (1e11 to 1e15), the tips and reimbursements. what is not: the premium of the paid price over the market price of a credit. a flat price is `rate * avgScore / 1e4`. at rate 1e15 and avgScore 8M that is 0.8 eth per credit, 90 times the 0.0089 eth market at the pin. a credit costs the accomplice its market price and returns the difference. the credits stay in the Core, so the Core holds credits worth 0.0089 each and has paid 0.8.

proof: `test_POC_ownerDrainsThePotInOneBlock` (setSettings with spendCap 10_000, drop 0, avgScore 8M, setRate 1e15, a seller sells 12 credits, settings put back, same block): pot 10.0 eth to 0.4 eth, 9.6 eth paid for credits worth 0.107 eth. `test_POC_setRateAloneDrainsTheLaunchPotInADay`: launch settings untouched, one `setRate` per hour sized to the hourly room, 24 windows: pot 10.0 to 0.081 eth, 9.92 eth paid for 33 credits worth 0.29 eth. the owner is an immutable address. if it is an EOA the "one transaction" is two transactions in one block through a private bundle. if it is a contract or a multisig batch it is one.

the funded clamp does not help: it stops the climb, it never lowers a rate that was set. the hourly window cap is read at the time of the spend (`windowPot * spendCapBps`), so raising spendCapBps also raises the cap of a window that is already open.

minimal fixes, in order of strength:
1. zero bytes, constants only, still needs the existing edge tests changed: `RATE_START_MAX_WEI` 1e15 to 3e14 (20 times the launch rate, 14 times market at the pin), `avgScore` upper bound 8_000_000 to 6_000_000, `spendCapBps` upper bound 10_000 to 5_000, `dropBps` lower bound 0 to 1_000. this cuts the single block take but does not remove it.
2. plus 219 bytes (measured): a rate raise guard in `setRate`. a raise above twice the current `ethRate()` needs one day since the last such raise. a lower rate is always allowed. it makes the rate lever a visible geometric climb (a doubling per day) instead of a jump. it does not cover avgScore and spendCap, so use it with item 1.
3. about 350 to 500 bytes (estimate, not built): route every loosening through the existing `queue` and `execute` with a 24 hour delay: setRate up, avgScore up, spendCapBps up, dropBps down, reserveBps down, tipCap, keeperTip, reimburse up, buybackSlice up, exitAfter down. tightening stays immediate. this is the only change that makes rule 8 true again.

### FC-2 reserve floor (medium)

`reserveBps` accepts 1_000 and `auctionDuration` accepts 1 hour. the owner sets both, anyone composes, an accomplice bids the 10% reserve, and a stranger has one hour (plus the 15 minute extension rule) to bid over. `repriceStatement` is permissionless and applies the new reserve to old listings, but old listings keep their 24 hour duration, so the fast path is new listings. proof: `test_POC_reserveFloorSellsAStatementAtTenPercent`: cost 0.138 eth, the Core is paid 0.0138 eth, the accomplice owns the statement.

fix, zero bytes: `reserveBps` lower bound 1_000 to 5_000 and `auctionDuration` lower bound 1 hour to 6 hours. `ARCHITECTURE.md` item 14.2 accepted the 1_000 floor; it is wider than the stated goal (sell below cost, not at a tenth of cost).

### FC-3 buyback slice and no min out (medium)

`buyback()` swaps exact in with no price limit and anyone can call it, so the swap can be bracketed. at the launch slice (1 eth) the skim of both legs makes that lose money. the slice bound goes to 100 eth. proof: `test_POC_buybackSandwichAtTheMaxSlice`: pool with 40 eth of organic buys, 100 eth in `ethToBuyback`, slice 100, delay 1. front run 150 eth, buyback, back run: 196.1 eth back, so plus 46 eth for the attacker, and the Core burns 40.2M coin instead of 244.3M. `test_sandwichBySlice` on a fresh pool: slice 1 eth attacker minus 0.42 eth, 5 eth minus 0.46, 10 eth plus 0.64 (6%), 25 eth plus 4.6 (19%). the keeper tip at the same settings is 5 eth per call.

fix, zero bytes: `buybackSlice` upper bound 100 eth to 5 eth. accepted item 17 (no min out) stays accepted at that size.

### FC-4 exit lane reimbursement (medium)

in `_compose` the cap of the reimbursement on the exit lane is `PAGE * avgScore * ethRate() / 1e4 * reimburseCapBps / 10_000`. it is a notional cost with no eth behind it, and it follows `ethRate()`, which the owner sets (1e15) and which also reaches 20% of the pot per credit on the idle climb (FC-5). at those rates the cap is far above any gas cost, so the only limit left is `1.5 * gasUsed * basefee`, and `gasUsed` includes everything the controller's `nextPage` burns, because `_nextPage` forwards `gasleft()`. a controller set through the timelock burns gas in a staticcall and is repaid 1.5 times. proof: `test_POC_gasBurningControllerFarmsTheExitLaneReimbursement`: rate 1e15, reimburseBps 15_000, cap 1_000, 20M gas burnt at 20 gwei: the pot pays 0.82 eth for one page, the caller spent 0.55 eth of gas and nets 0.27 eth. the eth lane is not affected (cap is 10% of a real cost basis: 0.0136 eth measured).

fix, saves bytes: replace `ethRate()` in the exit lane cap with the immutable `RATE_START`, and give `nextPage` a fixed gas cap (2_000_000 instead of `gasleft()`; the V1 read should cost a few hundred thousand, an estimate). measured together with FC-5 and FC-6: plus 107 bytes in total.

### FC-5 flat idle climb has no ceiling (low)

in flat mode the limit climbs while nothing fills, up to the funded clamp (price of one average credit equals the hourly cap, 20% of the pot). the rate bounds apply to `setRate` and the constructor only, not to the climb. proof: `test_POC_idleClimbFromLaunchSettings`: launch settings, no seller, pot 1 eth: 113 hours until the climb stops, 5 eth: 134 hours, 20 eth: 152 hours. one seller then takes 19.99% of the pot for one credit (0.2, 1.0, 4.0 eth against a market of 0.0089 eth). a second sale is blocked by the hourly cap and the unfunded flag until fees refill the pot. a realistic path needs 5 to 6 days with no one willing to sell at a price that climbs 8% an hour above the market, which means a dead market or absent bots. the value at risk is one credit per episode at 20% of the pot.

fix, about 40 bytes (inside the measured 107): `ethPot * spendCapBps / avgScore` becomes `(...).min(8 * RATE_START)` in `ethRate()`. a rate above 8 times the launch rate then needs `setRate`.

### FC-6 memory clobber in the settings forward (low, unproven)

`setSettings` writes the selector at memory 0 and copies the whole calldata (836 bytes) to memory 4 through 0x344 before the delegatecall, in a block marked `memory-safe`. that overwrites the free memory pointer, the zero slot and any local the optimizer spilled to memory. nothing after the block reads memory today (storage only) and all tests pass, so no harm is shown. a future edit that adds an allocation or a spilled local after the block breaks silently. fix, about 20 bytes: use `let p := mload(0x40)` as `settings()` already does (measured inside the 107).

### FC-7 exitAfter 0 (low)

with an `exitModule` set and `exitAfter` 0, anyone can exit an eth lane statement in the block it was listed: `_cancel` succeeds because no bid exists yet. proof: `test_POC_exitAfterZeroKillsTheListingAtOnce`. the statement goes to the module and the auction never runs. the module path itself is a trust decision (timelock), so the loss is the sale a buyer might have made. fix, zero bytes: `exitAfter` lower bound 0 to 1 day.

## 5. recommended bound changes in one place

all are constants in `SettingsBounds` or `Interfaces` (zero runtime bytes) except where a size is given. the existing bound edge tests in `test/Flow.t.sol` and the config checks must follow.

| setting | now | recommended | why |
|---|---|---|---|
| rate max (`RATE_START_MAX_WEI`) | 1e15 | 3e14 | FC-1: 0.13 eth per average credit is still 14 times market |
| avgScore max | 8_000_000 | 6_000_000 | FC-1 |
| spendCapBps max | 10_000 | 5_000 | FC-1: no setting should allow the whole pot in one window |
| dropBps min | 0 | 1_000 | FC-1: a fill must lower the price |
| reserveBps min | 1_000 | 5_000 | FC-2 |
| auctionDuration min | 1 hour | 6 hours | FC-2: a stranger needs time to bid |
| buybackSlice max | 100 eth | 5 eth | FC-3 |
| exitAfter min | 0 | 1 day | FC-7 |
| `setRate` raise guard | none | at most twice per day | FC-1, plus 219 bytes measured |
| exit lane cap, `nextPage` gas, climb ceiling, memory safe forward | | see FC-4 to FC-6 | plus 107 bytes measured together |

effect of the constants and the guard together on the worst single block (assuming the rate sits near market): the rate may double, avgScore may rise 1.4 times against launch, spendCap 50%. at most 50% of the pot in a block and the premium paid on it at most 2.8 times market, instead of 100% at 90 times. it is smaller, not zero. only item 3 of FC-1 makes it zero.

## 6. held (checked, no finding)

* checkpointing. `setSettings` calls `_checkpoint()` and `_xCheckpoint()` before the library writes anything, so the climb up to now is credited under the old numbers and the new numbers apply from now. a change creates or destroys no credited climb. the climb tier is a function of time since the last fill and is read against the new `climbDoubleEvery` and base, so a change moves the future speed at once and credits nothing back (read from the code, not separately tested). `funded` is recomputed after the write. the exit rate is held inside the new band. `setRate` leaves `lastFillTime` alone by design, so after a long idle it restarts at the tier reached by the time since the last fill.
* exit auction re anchoring. a half life change with a live `xToBuyback` re anchors at the old curve's price now (`test_extremeSettingsPhase2`: price continuous within 0.1% across min, max and mixed settings, 100 day warps in between). with nothing to sell the clock is stopped and the next injection re anchors. a price that has decayed to zero becomes 1 at an anchor, which is harmless.
* `setXRate` must sit inside floor and cap. `setSettings` clamps the stored exit rate into the new band. `_syncXFunded` and `xRate()` divide by `avgScore * unitPerPoint`, which is zero only before an exitModule is set, and every caller of those two is gated on the module.
* bricking. avgScore at least 800_000 so `ethPot * spendCap / avgScore` never divides by zero. `climb` is at most 12 loop steps for any gap (shift capped at 16, one step from tier 11), reverts nowhere (the `lnWad` argument is at least 1e18 when the cap exceeds the rate, the exponent is below the log of the cap ratio), costs at most 44k gas in `receive()` (measured at 100 year gaps, doubling 1 hour, base 1). climb 0 and drop 5_000 are fine (a fill halves the rate at most, it never reaches zero). zero durations are excluded by the bounds. `buyback` cannot divide by zero (budget is at least 1 wei because the tip is at most 5% of the slice). `test_extremeSettingsNeverBrickReceive`: all minimum, all maximum and a hostile mix, gaps of 1 hour, 40 days and 10 years, a real swap through the hook each time books the push.
* packed storage. the three words match the compiler layout (slot 0 ends at bit 240, `auctionDuration` starts slot 1, `buybackSlice` is bits 96 to 223 of slot 1, `buybackDelay` and `keeperTipBps` fill it, slot 2 holds the last six). every bound fits its field with room (reserveBps 40_000 in 16 bits, durations at most 365 days in 32 bits, buybackSlice 1e20 in 128 bits). `test_libraryDirectCallsRevertAndPackingRoundTrips`: round trip at all minimum and all maximum, unused bits clear. `test_dirtyCalldataWordsAreRefused`: each of the 26 words with a bit set above its width is refused by the library's calldata validation, never truncated into bounds. the slot constant equals `keccak256("credits.core.settings.v1")`.
* forwarding. the Core dispatcher requires the full 4 + 832 bytes, only the owner can call, `nonReentrant`, extra trailing bytes are ignored, a revert from the library is bubbled unchanged, the event is emitted from the Core address by the delegatecall.
* the library. `setSettings` and `swapIn` revert when called directly (compiler guard on state changing library functions, tested), `climb`, `decay` and `unpack` are pure. no selfdestruct, no storage, address baked into the Core code. deployed by CREATE2 at an address that depends only on its bytecode, so a pre deployment by anyone yields the same code. a Core constructed against an address with no code reverts (`test_constructorRefusesAnEmptyLibraryAddress`, with a control that builds). a wrong library cannot be detected by the Core, only by the postflight code hash check, which exists.
* reentrancy across the boundary. `swapIn` runs only inside `buyback`, which holds the guard. `unlockCallback` is unguarded but accepts only the pool manager, and the pool manager calls back only whoever called `unlock`, which only `buyback` does. the hook's push into `receive()` during that swap is booked to the pot while `ethToBuyback` was already reduced, so pots stay below the balance. the transient measuring flag is set and cleared in pairs around three calls and rolls back on any revert.
* flat bid. ceiling at flat 0, 5_000 and 10_000 equals the formula with one division at the end (no rounding drift). at 10_000 the score contract is not read on the eth doors and is read on the exit token bid and at flat below 10_000. `tip` never lifts cost plus tip above the ceiling (maximum of `c + min(0.25 (C - c), 0.05 c)` is C). a bonus on top is capped by `bonusCapBps`. the tester's note is right and harmless: at the clamp the flat ceiling equals the hourly cap, so a bonus makes that credit unsellable with `HourlyCap`, the cap is never passed (`test_bonusAtTheClampCannotPassTheHourlyCap`). `sellForEth(ids, minOut)` and `sellForExitToken(ids, minOut)` protect against a same block rate drop. the unprotected overloads do not: a seller who uses them can be paid the minimum rate by an owner who lowers it first. the credits go to the Core, so this costs sellers, not the Core.
* exit bid. at 100% of score the bid pays exactly the rating times unit that the exitModule must return, so selling credits for exitToken and exiting the statement leaves the pot whole (`test_exitBidAtParIsAWash`). only the compose reimbursement from the eth pot is spent (FC-4).
* adverse selection under the flat bid (the cheapest credits are sold first) is the owner's decision 1, not a defect.

## 7. size

runtime of the Core is 23,913 bytes, margin 663 of 24,576 (2.7%). acceptable for launch if the only changes are the fixes above: measured on a scratch copy, FC-4, FC-5 and FC-6 together cost 107 bytes (margin 556) and the `setRate` raise guard 219 more (margin 337). if more room is needed, cut in this order (all measured on the same scratch copy):

| cut | frees |
|---|---|
| `statementStatus` (a read of the house that any client can do with `getAuction`) | 340 bytes |
| `heldStatements`, `creditInfo`, `statementInfo`, `pileNext` (these are in `ICoreViews`, so the interface, tests and scripts need edits) | 429 bytes together |

with both cuts and all fixes the margin is 1,106 bytes. the loosening timelock of FC-1 item 3 would need most of the 340 from the first cut.

## 8. tests added

`test/ReviewFlowCore.t.sol`, 17 passing tests: the seven `test_POC_*` for FC-1 (two), FC-2, FC-3, FC-4, FC-5, FC-7, and held checks for the empty library constructor, library direct calls with packing round trip, dirty calldata, extreme settings (receive and phase 2), the receive gas by gap, the reimbursement at its cap, the sandwich by slice, the bonus at the clamp and the exit bid at par.
