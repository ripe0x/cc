# review: the core against the pnd auction house (flow branch)

independent review of how `src/Core.sol` uses the live pnd auction house v2 (factory 0x77aB853543286C9Cdd7dd6c01222A7cC4Ac93d63) and of the house as a dependency. every line of `docs/reference/pnd/SovereignAuctionHouseV2.sol` and the factory was read. proofs are in `test/ReviewFlowHouse.t.sol`, run on the mainnet fork against the real house, real Statements and the real factory.

## status

| finding | status | one line |
|---|---|---|
| FH-1 | fixed | the `holder == HOUSE` revert in `syncStatement` is deleted: a statement a buyer parks back in the house clears as sold. `test_FIXED_FH1_soldStatementParkedInTheHouseClearsAsSold` |
| FH-2 | documented | a raised `reserveBps` reaches old listings only through `repriceStatement`. operating rule in docs/DEPLOY.md (reprice in the same batch), and `REPRICE=1` in `script/SetSettings.s.sol` appends the calls. `test_DOCUMENTED_FH2_raisedReserveDoesNotProtectOldListings`, `test_repriceModeListsOnlyUnbidListings` |
| FH-3 | documented | a token sent to the house outside an auction, or an unrecorded statement sent to the core, is lost. accepted loss for the sender |
| FH-4 | documented | sync and overprint relists reset the exit clock. bounded |
| FH-5 | documented | every listing is a standing option at the reserve. `reserveBps` is the price floor (minimum 3_000 after the audit fixes) |
| FH-6 | documented | nobody is paid to call `endAuction` or `collectSales`. `buyback` collects |

## verdict

no finding at medium or above. the core and the house compose safely: no path was found that loses a statement, sells one twice, exits a sold one, mis books proceeds, or lets a caller reach the house as the core. two low findings are proven (FH-1, FH-2), the first has a fix that makes the core smaller. for mainnet: ship, with the FH-1 deletion applied if the next build is cheap, and FH-2 handled as an operating rule (batch a reserve change with the reprices).

limits of this review: the house was read, not fuzzed. solvency of the house is argued from the source, not from an invariant campaign. the Statements contract was treated as a black box except for the probes below.

## the house as a dependency

| topic | result |
|---|---|
| clone, initializer | clone is made by `cloneDeterministic` with salt = `msg.sender` and `initialize` runs in the same call. the implementation has `_disableInitializers`. a clone cannot be initialised twice. nobody but the core can create the core's house, so there is nothing to front run. code already at the predicted address is impossible for the same reason (only the factory deploys there, only for the core). a pre sent balance changes nothing |
| fee | `protocolFeeBps` and `feeRecipient` are written only in `initialize`, from the factory's immutable defaults. no setter. it cannot change for an existing house. the core books what it receives, so a nonzero fee at deploy would only lower proceeds |
| owner | `transferOwnership` and `renounceOwnership` revert. the core owns its house for ever |
| code | no delegatecall, no selfdestruct, no upgrade path in the clone or the implementation source |
| proceeds | a contract seller is never pushed: `_payout` credits `pendingRefunds[core]`. the core pulls with `withdrawRefund`, its `receive` never reverts (it ignores any sender but the hook), so the pull cannot fail |
| bid refund | 30k gas push, else credited. state is written before the push and the house is `nonReentrant`, so a refund callback cannot touch the lot or call `withdrawRefund`. a deaf bidder is credited and loses nothing (tested) |
| delivery | `endAuction` needs `gasleft` of at least 580k, then a self call capped at 500k. the real `Statements.transferFrom` costs about 29k and has no receiver callback, so a winner that is a contract cannot make delivery fail, and a caller cannot starve it |
| deferred delivery | cannot be forced by a bidder with the real Statements. it only happens if Statements itself starts refusing transfers. then the lot and the winning bid sit for 30 days and `unwindStuckLot` returns the statement to the core and credits the bidder. proceeds are not paid in that case |
| insolvency | liabilities are live bids, `pendingRefunds` and deferred bids. every credit is matched by ETH that stays in the house, every payout deletes the record first. no path double credits (unwind clears `pendingDelivery` and sets `pendingReturn`, which blocks `endAuction` and `claimLot`). forced ETH only adds. `pendingRefunds[core]` can only grow from a sale of the core's own statement: the house credits only a seller (the core), a winner, an outbid bidder or the fee recipient, and the core never bids, so nobody else can credit it, and one bidder's refund is never paid from the core's proceeds |
| `recoverStuckERC721` | owner only, owner is the core, and the core has no call that reaches it: the only calls the core makes to the house are `createAuction`, `cancelAuction`, `setAuctionReservePrice`, `getAuction`, `pendingRefunds` and a fixed `withdrawRefund`. it should stay unreachable (a reachable one would be a path for a stuck buyListing target to pull statements). cost: a token parked in the house outside an auction is lost for good (FH-1) |
| approval | the core approves the house for all statements, but every house transfer is `from = address(this)` (deliver, claim, unwind, cancel, expire, recover). the approval does not expose statements the house does not hold. `expireAuction` is dead because the core lists with expiry 0 |
| 5 percent raise and 15 minute extension | each raise needs +5 percent of real, locked eth, and the last bidder wins. a griefer who keeps extending ends up paying the compounded price. bounded, not a drain |
| block stuffing at the end | possible for any auction house, cost grows with the 15 minute window. nothing to do |

### inherited house risks the core cannot mitigate

1. the house is immutable and the core can never leave it or replace it. a bug found later affects every live and future listing. the core can cancel only listings without a bid.
2. a bid cannot be removed. after the first bid the statement, the exit and the overprint are locked to the end of that auction, and the sale clears at the highest bid, which is at least the reserve.
3. anyone may place the first bid at the reserve, at any time, on any listing. so every statement is a standing 24 hour option at 90 percent of cost (or the current reserve). the exit lane after `exitAfter` competes with that option and loses whenever the exit value is above the reserve.
4. proceeds are pulled, not pushed. they wait in the house until `collectSales` or `buyback`. an ended auction waits until somebody calls `endAuction` (the winner has the incentive, nobody else is paid).
5. a token that arrives in the house outside an auction is stuck for ever (no caller can recover it).
6. if Statements ever refuses a transfer, delivery is deferred for 30 days and proceeds for that sale are not paid.
7. the 580k gas floor on `endAuction` and the fixed 500k delivery cap are in the house.

## the statement state machine

the core's record is `held` and `listed` plus `auctionId`, `listedAt`, `cost`. the house and Statements are the truth. `statementStatus` reads them.

| state | how the core sees it | transitions (who) |
|---|---|---|
| minted, not yet listed (eth lane) | record held, not listed. exists only inside `compose` | `_list` in the same call (the composer) |
| held (exit lane) | held, never listed, core owns it | `exitStatement` at once (anyone), `overprint` with a same lane partner (anyone, controller picks) |
| listed, no bid | held and listed, house owns, record has no first bid. status Listed | bid (anyone, at or above reserve), `repriceStatement` (anyone), `exitStatement` after `listedAt + exitAfter` (anyone, cancels), `overprint` (anyone, cancels and relists the base) |
| listed with a live bid | house owns, first bid set, before end. status Bid | outbid +5 percent (anyone, may extend 15 minutes), end of time. `exitStatement`, `overprint`, `repriceStatement` revert `HasBid` and change nothing |
| ended, unsettled | record unchanged, house owns, end passed. status Ended | `endAuction` (anyone, 580k gas floor). `exitStatement` reverts `HasBid` |
| delivery deferred | same as ended. `AuctionLive` on sync | `claimLot` (anyone, to zero, or the winner redirecting), `unwindStuckLot` after 30 days (anyone) |
| sold, not synced | auction gone, winner holds it, proceeds credited to the core in the house. record still held and listed. status Sold | `collectSales` (anyone), `syncStatement` (anyone) clears the record and emits `StatementSold`. the winner may keep it, send it to the core (Returned), burn it as an overprint top (still Sold), or park it in the house (FH-1) |
| sold, synced | record deleted | none |
| unwound and returned, or sent back by the winner | auction gone, core owns it, record still listed. status Returned | `syncStatement` (anyone) relists at `cost * reserveBps` of now and sets `listedAt = now`. `exitStatement` reverts `NotListed` until then |
| unwound, return failed | house still has the record, `pendingReturn`. `AuctionLive` | `returnUnwoundLot` (anyone), then Returned |
| cancelled | never persists: only inside `exitStatement` and `overprint`, atomic with what follows | cancel is core only, reverts if a bid exists, the whole call reverts with it |
| exited | record deleted, the `exitModule` holds it | none |
| overprinted, top | record deleted, token burned | none |
| overprinted, base | cost summed, relisted, new auction id, `listedAt = now` | as listed |
| sent to the core by a third party, unrecorded | not held. the core owns a token it does not know | none: no exit or list path, a donation that cannot be moved |
| sent to the house by a third party | recorded and sold: FH-1. unrecorded: lost | none |

checked, with the result:

* a bid between the core's check and its cancel: no external code runs between them in one call, and the house reverts `AuctionAlreadyStarted` anyway, so the call reverts whole. nothing changes (existing tests, and `_cancel` sets `listed` only after the house call).
* a sold statement can never be exited, repriced or overprinted: the house record is gone, so `_requireOpen` reverts `NotListed`. an exit of a sold statement that came back needs a sync first.
* `ownerOf` reverting reads as sold. that is true for a burned top. a caller cannot fake it by starving gas: the staticcall gets 63/64 of the gas, and leaving the call too little to finish also leaves the rest of the sync without gas.
* sold then returned before sync, relist at the old cost: not exploitable. the first sale was booked once, the returner gave a statement away, the second sale is a second legitimate sale (`test_state_soldThenReturnedBeforeSyncRelistsAndBooksEachSaleOnce`). a returned statement can only have a rating equal or higher (overprint only adds), so the old cost reserve never undersells it against what the core paid.
* `listedAt` moves only on `_list`: compose, sync of a gone auction, overprint of the base. `repriceStatement` does not move it. a live listing cannot be synced (`AuctionLive`), so nobody can reset the clock of a live listing, and nobody can exit early (only `exitAfter = 0` does, which is an owner setting). the overprint of a base resets its clock by design.
* the listing keeps the duration it was made with (`auctionDuration` is read at `_list`, reprice does not change it).
* ids: Statements ids are not reused, house auction ids only grow, so a stale `auctionId` never points at another statement.
* `heldStatements()` may contain sold or returned statements until synced, and the phantom of FH-1 for good. nothing on chain in this repo reads it (`ControllerV1.nextOverprint` is a pure no op). a later controller that picks from it must skip any statement whose `statementStatus` is not Listed. no state changing path loops over it: `_unhold` is O(1), compose, sync, reprice, exit and overprint are constant gas however many statements accumulate. the view alone grows linearly.

## proceeds, reserve, exit, targets, gas

| question | answer |
|---|---|
| can the booked delta differ from the sale proceeds | `_collect` books `owed`, the house's own `pendingRefunds[core]` read before the call, and only checks the balance rose by at least that. the house never pushes eth to the core (a contract seller is credited), so no eth arrives mid call, and the hook is not in the path. nobody can credit `pendingRefunds[core]`. a refund of someone else sent with `withdrawRefundTo(core)` is a plain donation: it is not split, `skim` books it all to the pot, and it changes nothing about `collectSales` (`test_state_aDonationFromTheHouseIsNotProceeds`) |
| can `skim` book proceeds first and skip the buyback split | no. until `collectSales` runs the proceeds are not in the core's balance, and `collectSales` books them in the same call that moves them |
| stranded for ever | no. `collectSales` is permissionless, `withdrawRefund` has no condition but a balance, and `receive` cannot revert. the only failure is a dead house, which cannot happen |
| `collectSales` or `buyback` reverting for good | `collectSales` reverts `CallFailed` only if the house call fails. `buyback` uses `_collect(false)`, so a failing house does not block it. that is the right shape, no change. note that `buyback` reverts `NothingToBuy` after collecting when `saleToBuybackBps` is 0: the collection rolls back with it, harmless, `collectSales` still works |
| split under a settings change | `saleToBuybackBps` is read at collection time. a keeper can pick which side of a settings change a collection lands on. the amount in play is one sale, and the owner is the one who changes it. not a finding |
| reserve at zero | the house accepts reserve 0 and then any bid of 1 wei. the core cannot produce it: an eth lane cost is at least 80 wei (80 credits at 1 wei) and `reserveBps` is at least 1,000, so the reserve is at least 8 wei. exit lane statements are never listed (`compose` lists only the eth lane) |
| reprice | permissionless and bounded to the settings the owner already chose. lowering is intended. raising is intended too, but does not reach a bid placed first: FH-2. a bidder's tx can fail `BidBelowReserve` if a reprice up lands first, which only costs them a retry |
| exit after cancel | `exitStatement` cancels then transfers to the `exitModule`, then checks the balance delta against `rating * unitPerPoint`. any failure reverts the cancel with it. proceeds in the house are unrelated to the statement, so an exit while the house holds proceeds is fine |
| overprint with a bid on one listing | reverts `HasBid` before any state change, including the daily counter. the stale sold case reverts `NotListed` the same way |
| `buyListing` and the house | the house, its factory, the Statements, Credits, the core, the coin, the hook, the pool manager and the exit pair are refused at call time even if the owner queues them (`ForbiddenTarget` at execute, `TargetNotAllowed` at call, tested). the core's only low level call with caller chosen data goes to an allowed target. nothing a caller supplies reaches `cancelAuction`, `setAuctionFundsRecipient`, `withdrawRefundTo` or `recoverStuckERC721` as the core. Seaport and the credit strategy cannot call the house as the core because `msg.sender` would be them |
| strangers on Statements and Credits | the core's credits are approved to Statements and its statements to the house. a stranger cannot compose the core's credits or overprint the core's statements, in the pile, on the house or in the core's hands (probes in the test file) |
| gas | one compose, eth lane, with listing, on the fork: 7.96m gas end to end (block gas limit on the fork 60m, 13 percent). `createAuction` alone is about 215k warm. the reimbursement counts 7.948m gas of it, so the keeper is within 0.2 percent of whole at the gas price, before the 5 percent of cost cap, which binds above about 3 gwei basefee. `endAuction` needs 580k of gas left but uses a small fraction. delivery is 29k against a 500k cap |

## findings

| id | severity | title | status | where |
|---|---|---|---|---|
| FH-1 | low | a sold statement parked in the house leaves a record `syncStatement` can never clear | proven | core |
| FH-2 | low | a raised `reserveBps` does not reach listings that have no bid yet: anyone can still bid at the old reserve until each is repriced | proven | core, operating rule |
| FH-3 | info | a token sent to the house outside an auction, or an unrecorded statement sent to the core, is lost for good | by reading | house, core |
| FH-4 | info | sync and overprint relists reset the exit clock | tested | core |
| FH-5 | info | every listing is a standing option at the reserve, so the exit lane competes with any bidder | by reading | house |
| FH-6 | info | nobody is paid to call `endAuction` or `collectSales` | by reading | house, core |

### FH-1 details

`syncStatement`: when the auction is gone and `ownerOf` is the house it reverts `BadAuction`. a winner sends the statement they bought into the house with `transferFrom`. it costs them the statement. the record stays held and listed for ever, `heldStatements()` lists it for ever, `exitStatement` and `repriceStatement` say `NotListed`, `statementStatus` says Sold. proof: `test_POC_FH1_soldStatementParkedInTheHouseCannotBeSynced`. damage: one phantom entry per sacrificed statement (each worth at least the reserve to the attacker), no loss to the core, and a future controller that enumerates `heldStatements` and picks a phantom reverts every `overprint` call. the branch guards nothing: a house held statement with a live or pending record already reverts `AuctionLive` before it, and the house returns every lot it holds under a record to the core or the winner.

fix: delete `else if (holder == address(HOUSE)) { revert BadAuction(); }` in `syncStatement`. the case then falls into the sold branch (holder is not the core), emits `StatementSold` with the house as holder and clears the record. about 40 to 60 bytes smaller (a compare, a jump and a revert, estimated, not built). `BadAuction` stays in use by `_auction`.

### FH-2 details

`setSettings` only writes the core's storage. a listing keeps the reserve it has until `repriceStatement` runs on it. after the owner raises `reserveBps` from 9,000 to 20,000 a bidder bids the old reserve on any old listing at once, and after that bid reprice reverts `HasBid` and the sale clears at the old reserve (`test_POC_FH2_raisedReserveDoesNotProtectOldListings`). lowering is not a problem, the bidder wants the low reserve anyway. loss is bounded by (new reserve minus old reserve) per listing that gets sniped.

fix: 0 bytes. when the owner raises the reserve, send `setSettings` and one `repriceStatement` per no bid listing in one transaction (a Safe batch: reprice is permissionless, so the multisig can call it in the same batch). the core cannot do this itself without a loop over `heldStatements`, which would be unbounded. put it in docs/DEPLOY.md as an operating rule.

### FH-3 to FH-6, short

* FH-3: `recoverStuckERC721` is unreachable and should stay so. nothing the core owns goes astray by itself. a statement or credit sent to the core by `transferFrom` is not recorded and has no exit path. accepted loss for the sender.
* FH-4: sync of a returned statement and the overprint of a base reset `listedAt`, so an exit waits `exitAfter` again. bounded: a sync needs a gone auction, an overprint consumes a top and is capped at 8 a day.
* FH-5: a bid at the reserve can land on any no bid listing, including just before its exit becomes possible. document it, it is the price floor of statements, and `reserveBps` is how the owner sets it.
* FH-6: the winner calls `endAuction` for the statement. the core's money is released by `collectSales`, which `buyback` already calls, so keepers of the buyback move it. no change.

## held

* nothing in this review blocks mainnet.
* held for a decision, not blocking: apply the FH-1 deletion, add the FH-2 operating rule to docs/DEPLOY.md.
* not covered here: settings validation, the bid, the linked library split (another auditor), a fuzz campaign on the house solvency, and behaviour of Statements if its owner ever changes transfer rules.
