# independent review: Core.sol and ControllerV1.sol

scope: src/Core.sol, src/ControllerV1.sol. law: SPEC.md, docs/ARCHITECTURE.md (section 10 deviations not re reported). the line numbers and the exit pool scenarios below are those of the first design. all proofs of concept are in test/ReviewCore.t.sol, `test_POC_*`, run on the pinned fork and passing. tests named `test_held_*` in the same file are attacks that failed.

## status after the artcoins port

this review was written against the first design, with the exit token bought back in a pool. the port to artcoins replaced the exit pool with a dutch auction inside the core (docs/ARCHITECTURE.md sections 8 and 10), so the exit pool findings no longer apply to the code. proof tests of fixed findings are regression tests named `test_FIXED_*` where they still make sense, and the auction attacks live in `test/ReviewCore.t.sol` as `test_attack_*`.

| id | status | what |
|---|---|---|
| R1 | obsolete | the exit pool, its limit price and `SetExitPoolKey` are gone. the exit token buyback is a dutch auction in coin that the core burns, and no pool price can be chosen by a counterparty. the auction has its own accepted properties (ARCHITECTURE section 10, items 10 and 11) |
| R2 | obsolete | there is no pool key to validate. the owner timelock actions are now `SetController`, `SetExitModule`, `AddTarget`, `Freeze` |
| R3 | fixed, stays fixed | `unitPerPoint` is read once when the exit module is set, stored, bounded to non zero and at most uint128, and never read again |
| R4 | fixed for the eth buyback | the callback returns what was spent, unspent input and tip go back to the counter, and a buyback that buys nothing reverts `NothingBought()`. no longer applies to the exit side, which has no swap |
| R5 | fixed for the eth buyback | the callback requires the pool took no more than the amount it was given |
| R6 | accepted | a fee on transfer or rebasing exit token is not supported (ARCHITECTURE section 10, item 13). the auction pays out the exit token by a plain transfer |

## findings

| id | severity | title | status |
|---|---|---|---|
| R1 | high | `buybackExit` trades at any price and the exit pool price and liquidity are chosen by whoever gets there first | proven |
| R2 | medium | `SetExitPoolKey` does not validate the lp fee or tick spacing, so the owner can route buyback slices into its own position | proven |
| R3 | medium | `unitPerPoint` is read live with no bound, so the exitModule alone prices both the statement exit and the exit token bid | proven |
| R4 | low | a buyback books the whole slice as spent and tips the keeper even when nothing, or only part, was bought | proven |
| R5 | low | `unlockCallback` does not check that the pool took no more than the slice it was given | unproven |
| R6 | low | an exitToken with a transfer fee bricks the exit pool swaps and `buybackExit` | unproven |

no critical findings. eth accounting (invariants 1, 2, 3, 5, 6, 7) held under every attack tried against Core. the problems are all on the exit side and all sit behind the exitModule and exitToken seam that the spec leaves open.

## R1 high: exit buyback has no price protection

where: `Core.buybackExit` (L800), `Core.unlockCallback` (L817), `Core._setExitPoolKey` (L918). the hook allows anyone to initialize the exit pool and anyone to add liquidity (ARCHITECTURE 4).

what happens: the core swaps a slice of `xToBuyback` exact in with price limit at the tick extreme and no minimum out. v4 crosses empty ticks for free, so a position of dust placed far from the pool price is the only liquidity the swap meets, and the core sells the whole slice to it. the account then withdraws the position and keeps the exit token. the hook fee (10 percent) is the only cost and 90 percent of the slice is taken. the eth launch pool is not exposed because its liquidity is locked and its virtual depth never falls below roughly 25 eth against a 1 eth slice, which makes a sandwich lose to the 20 percent round trip fee.

scenario with numbers (the proof): exitModule and pool key set, pool initialized at 1:1 by the attacker, one statement exited at 1e10 unit per point, `xToBuyback` = 1.3025e18. attacker buys 1 eth of coin, adds liquidity 1e15 in a far single sided coin range (about 2e10 wei of coin), calls `buybackExit`. the core pays a net 8.66e17 exit token, 7.3e9 coin is burned (dust), the attacker withdraws 7.755e17 exit token. it repeats every 25 blocks while `xToBuyback` lasts and the range holds liquidity. the same works for any pool that is shallow relative to a slice (20 average credits worth, about a quarter statement), because the remainder of the slice spills into the attacker range.

test: `test_POC_anyoneDrainsExitBuybackThroughDustLiquidity`.

fix: anchor the buyback to a price the pool cannot choose. either (a) pass a reference sqrt price in the queued `SetExitPoolKey` data, store it, and in `unlockCallback` set `sqrtPriceLimitX96` to the reference moved by a fixed band and revert or return the unspent remainder when the limit is hit (it halts safely if the market leaves the band), or (b) compute a minimum coin out in the core from `ethRate`, `unitPerPoint` and the launch pool price (the launch pool is deep and cannot hold third party liquidity), and revert below it. in both cases credit unspent input back to `xToBuyback` (see R4).

## R2 medium: pool key lp fee and tick spacing are free

where: `Core._setExitPoolKey` (L918). it checks the hook and the currency pair only. `FeeHook` does not look at `key.fee` either.

what happens: the key is set once and cannot be fixed. an lp fee of 100 percent (1_000_000) is a valid v4 static fee for exact in swaps. the owner seeds the only position, and every `buybackExit` slice is taken as lp fees by that position. no coin is bought. an unusable tick spacing or fee makes the pool uninitializable, which strands `xToBuyback` forever instead. SPEC section 9 says the owner cannot move exit token. this is a path that does, within the single timelocked action.

scenario: owner queues `SetExitPoolKey` with fee 1_000_000, 7 days later initializes and seeds a position. `xToBuyback` = 1.3025e18, one slice paid net 8.66e17, zero coin burned, the position withdraws 7.755e17 more exit token than its baseline.

test: `test_POC_poolKeyLpFeeLetsOwnerCollectBuybackSlices`.

fix: in `_setExitPoolKey` require `k.fee == 0` and `k.tickSpacing == 60` (the same shape as the launch key), so the only fee is the hook fee. combine with the price anchor from R1.

## R3 medium: live unitPerPoint with no bound

where: `Core._unit` (L430), used by `exitStatement` (L727), `_sellForExitToken` (L584), `buybackExit` (L805), `xRate`. deviation 10 accepts the live read but does not bound it.

what happens: the received check in `exitStatement` is `rating * unitPerPoint`, and the exitModule is the party that reports `unitPerPoint`. a module that lowers its own unit just before an exit satisfies the check with dust and keeps the statement. the spec calls this check the whole safety story for the module, and it is empty against a module that sets its own price. the same live value prices the bid: raising it makes one junk credit take most of `xPot` in a single call, because the bid has no spend cap like the eth side.

scenario 1: eth lane statement composed at cost basis above 0.01 eth, auction elapsed, module sets unit to 1, anyone calls `exitStatement`. the core receives `rating * 1` (below 1e10 base units) and the statement is gone. scenario 2: after one exit, `xPot` = 1.3e18. module sets unit to 100 times, one credit sold, the seller receives about 100 times the fair price, more than half of the pot.

tests: `test_POC_liveUnitLetsModuleTakeStatementForDust`, `test_POC_liveUnitLetsModuleDrainBidPot`.

fix: bound how fast the unit can move. store `lastUnit` and `lastUnitAt` on every accepted read and accept a new value only inside `[lastUnit * 0.9^d, lastUnit * 1.1^d]` for d days elapsed (otherwise revert the exit or the bid, which fails safe). add the hourly spend cap of section 5.2 to `xPot` spends in `sellForExitToken`. snapshot the unit when the module is set so the first value is not free either.

## R4 low: buyback books the slice as spent

where: `Core.buyback` (L779), `Core.buybackExit` (L800), `Core.unlockCallback` (L817).

what happens: `ethToBuyback` or `xToBuyback` falls by the full slice and the keeper tip is paid before the swap result is known. `unlockCallback` accepts zero or partial fills (it only rejects the wrong sign). the unspent part stays in the core, is invisible to the pots, and joins the bid or buying pot on the next `skim`. the share meant for coin is moved to the other pot, and anyone can trigger this with an empty exit pool. the tip is paid for no purchase.

scenario: exit pool initialized with no liquidity, `xToBuyback` = 1.3025e18. any caller runs `buybackExit` every 25 blocks: no coin is burned, the keeper is tipped, `xToBuyback` falls by a slice, and `skim` moves the leftover into `xPot`.

test: `test_POC_emptyExitPoolSpendsBuybackShareWithoutBuying`.

fix: return the spent amount from `unlockCallback`, add `slice - tip - owed` back to the pool counter, and compute the tip on what was spent. revert when nothing was bought.

## R5 low (unproven): no upper bound on what the pool takes

where: `unlockCallback` L836. `owed = -inDelta` is paid from the core balance with no check against `amountIn`. the pots only stay solvent (invariant 5) because the hook returns a delta that equals the slice. if any hook or pool path ever reports more than the slice, the excess leaves the pots. fix: `require(owed <= amountIn)`.

## R6 low (unproven): exitToken with a transfer fee

where: `addExitFees` (L307) requires `balance >= xPot + xToBuyback + amount`, and `unlockCallback` settles `owed` tokens by transfer. with a fee on transfer exitToken the first reverts `Unfunded` for every exit pool swap, and the second leaves the manager delta unsettled so `buybackExit` always reverts. only the exit side is affected, and the owner and the exitModule choose the exitToken. fix: measure the balance delta in both places, or reject such a token when the module is set by a transfer round trip test.

## attacks tried that held

accounting and eth
* ethPot + ethToBuyback above balance: every outflow (sell payout, listing cost plus tip, reimbursement, tip, slice) is paired with a pot decrement. refunds from a target land in `receive` and lower `cost` instead of being booked twice. forced eth is only booked by `skim`, which is guarded and cannot run mid call.
* `addFees` during a buyback: the slice is removed from `ethToBuyback` before the unlock, so the hook share returning to the pot is consistent.
* `measuring` flag: transient, set only around the target call and the module call, cleared on every non revert path, and a revert clears everything. it cannot be left set and no third party swap can land inside those calls, so it cannot brick launch pool swaps. `Busy` closes the donation path that would otherwise count as cost or as received.
* `buyListing` with arbitrary calldata: the core holds no approvals except credits to Statements, cannot be a Seaport offerer (no `isValidSignature`), loses at most `value`, needs balance + 1 and `ownerOf(id)`. a forced credit or a decoy id cannot satisfy both checks. a third party cannot use the Statements approval: `test_held_thirdPartyCannotComposeCoreCredits`.
* tip farming: best self dealing total is `P + min(0.1 (C - P), 0.02 P)`, maximum 0.85 C at P = 0.833 C, below the 1.0 C paid by `sellForEth`. split listings and the controller bonus change nothing because the ceiling already includes the bonus. dust fills only reset the climb clock, which a normal fill also does.
* hourly cap: two fixed windows can spend 40 percent across a boundary (deviation 4). tips count, `x` is rechecked after the call.

rate
* `ethRate` ten years after the last checkpoint with a funded pot: clamps at `ethPot * 2000 / AVG_SCORE` (was `* 1e4` before the funded fix, see ARCHITECTURE section 10 item 8), 18k gas: `test_held_tenYearGapRateRead`. powWad exponent is at most 24e18 per segment, no overflow.
* funded clamp equals the funded test (`cap >= rate` iff `ethPot * 2000 >= AVG * rate` (the funded fix)), every pot change checkpoints first, so no climb while unfunded. drop at `x == p` gives exactly 10 percent, `x > p` reverts first, a zero pot reverts.

piles and statements
* list operations for single, head, tail, middle, and an id that leaves and returns (the struct is deleted on pull). id 0 is refused at every door. `_unhold` is correct when the removed id is the last slot, and overprint calls it before the external call, with base kept intact. compose cannot be bricked by a third party: a pile credit cannot leave the core.
* gas reimbursement is bounded by the real gas of the call, 110 percent, 5 percent of cost, and the pot.

auction and exit
* price is rounded up and never below 1.2x cost. boundary at exactly 72 hours opens the exit and sits on the floor. a reentering module hits the guard, `addExitFees` is blocked by `Busy`, and the balance delta check cannot be fed by donations made through core entry points.
* lane mixing: `_pull` checks the lane, overprint requires equal lanes, exit lane statements never reach `priceOf`.

owner
* queue key includes action and data, execute deletes before acting, once only locks hold, freeze is rechecked at execute, forbidden targets are rechecked at call time so a target added before it became the exitModule or exitToken is dead. no combination of controller, target and exitModule gives asset power beyond the bonus cap, ordering and merge power of section 9. the pool key is the exception (R2), and the module price is the other (R3).
* `unlockCallback` is only reachable from the pool manager, and the manager only calls the address that unlocked, so crafted data cannot arrive. the launch pool buyback sandwich loses to the round trip fee.
