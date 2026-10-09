# review of the sale controller, the removed timelock and the fee share

independent review of `git diff 1e7009e HEAD -- src/ script/` (commit a3e2fa3 on `flow`) against docs/FLOW.md section 9. the owner chose instant full control (9.4), so nothing below reports "the owner can do X". every finding is about a non owner, a break, a contradiction with the spec, or a state the owner cannot leave.

status after the fixes: fixed S-1, S-4, S-5, S-6, S-9, S-10, S-11. accepted S-2. resolved by the 8_000 share S-8. documented S-3, S-7. the proof tests were renamed: `test_FIXED_*` asserts the new behavior, `test_ACCEPTED_*` pins an accepted or documented behavior, `test_OK_*` confirms a safety property. the text below is the review as written, the status column says what happened.

proof tests: `test/ReviewSale.t.sol` on the pinned fork. run with `forge test --match-path test/ReviewSale.t.sol`. no file of src/, script/ or an existing test was changed. the 302 tests of Flow, CoreUnit, Phase2Flex, SetSettings, Config, Fees, Econ, Gate and the rest of that batch were re run in the review copy and pass.

no critical, high or medium finding. nothing a non owner can use to take eth, a statement or credits, to book a payment twice, or to sell below the hard floor that was in force when a reserve was set.

## findings

| id | severity | finding | proof test | suggested fix | status |
|---|---|---|---|---|---|
| S-1 | low | buy only mode is dead while the controller ask is under the core hard floor. `buy` sends exactly the ask to `sellTo`, which reverts `BelowFloor`, and the buyer cannot overpay. happens after the owner raises `saleFloorBps` without raising the controller `floorBps`, once the ask has decayed below it. `priceOf` also quotes a price nobody can pay | `test_FINDING_buyOnlyDeadWhileTheAskIsUnderTheCoreFloor` | in `buy` and `priceOf` clamp the price to `cost * core.settings().saleFloorBps / 10_000`, or let `buy` forward `max(price, floor)` | fixed. `buy` and `priceOf` use max(ask, core hard floor). `test_FIXED_buyOnlyWorksWhileTheAskIsUnderTheCoreFloor` |
| S-2 | low | after the owner raises `saleFloorBps`, a listing keeps its old reserve until someone calls `repriceStatement`. a bid at the old reserve wins the statement below the new floor. this follows the SPEC invariant ("reserve at least the floor when it was set") but not the plain sentence of 9.2 ("no statement leaves the core by a sale for less than the floor") | `test_FINDING_reserveStaysBelowARaisedFloorUntilRepriced` | say it in 9.2 and DEPLOY (the batch of `SetSettings` with `REPRICE=1` already covers it, make it the only documented way), or accept it. an on chain fix needs a loop over held statements and does not fit the size margin | accepted and documented (FLOW 9.2, DEPLOY: raise the floor with `REPRICE=1`). `test_ACCEPTED_reserveStaysBelowARaisedFloorUntilRepriced` |
| S-3 | low | the owner can lock a controller that cannot price (reverts, burns gas, answers short). then `repriceStatement`, `compose` and the relist of an unwound sale revert with `BadPrice` for good and `setController` reverts `Locked`. redemption of a normal statement is unaffected | `test_FINDING_lockControllerAcceptsAControllerThatCannotPrice` | `lockController` could require one successful `statementPrice` probe call, or the docs warn to lock only a controller already proven in use | documented (DEPLOY: lock only a controller proven in use). `test_ACCEPTED_lockControllerAcceptsAControllerThatCannotPrice` |
| S-4 | low | redemption of an unwound (`Returned`) statement now depends on the controller: `exitStatement` needs the listing, a returned statement has none, so `syncStatement` must relist first and the relist reads `statementPrice`. 9.2 says "redemption never depends on the controller". with a broken or locked bad controller such a statement is stuck | no direct test: the real Statements never refuses a transfer, so an unwind needs a mocked failure, which this review does not use. the coupling is shown by S-3 and by the existing `test_exit_returnedStatementMustBeRelistedFirst` | in `_list` fall back to the hard floor when the controller call fails, only on the relist path, or let `exitStatement` accept a returned statement the core holds | fixed on the relist path: `syncStatement` lists at the hard floor when the controller price read fails, compose and reprice keep reverting. `test_FIXED_relistFallsBackToTheHardFloorWhenTheControllerFails` |
| S-5 | low | postflight reads `owner()` but never `pendingOwner()`. a handover offered to an unknown address is invisible to every row, and the owner is now a live slot | `test_FINDING_postflightDoesNotReadThePendingOwner` | add a row `core: no pending owner` (warning is enough) | fixed. postflight warning row `warn: no pending owner`. `test_FIXED_postflightWarnsOnAPendingOwner` |
| S-6 | low | `OWNER_CHANGED=1` relaxes the core owner row only. DEPLOY.md hands the token admin over separately, and then the row `coin: admin is owner` (compares with the launch owner) fails with no override. `Resume` reads the same admin: stage becomes `Locked` and `_handover` reverts `NotTokenAdmin` | `test_FINDING_ownerChangedFlagDoesNotRelaxTheCoinAdminRow` (postflight half. the `Resume` half is code reading of `detectStage` and `resumeSystem`) | let `OWNER_CHANGED=1` also turn the admin row into a warning and make `detectStage` return `Done` when the admin is not the deployer after a handover | fixed. `OWNER_CHANGED=1` relaxes the coin admin row, `Resume` counts a handed over admin as done. `test_FIXED_ownerChangedFlagRelaxesTheCoinAdminRow`, `test_resumeOwnerChangedTreatsAHandedOverAdminAsDone` |
| S-7 | info | a stranger can raise a reserve, not only lower it, after an owner change that raises the ask (the mode flip to buy only, a higher `startBps`). the reserve goes back to the start price under a bidder who priced it at the old one. by design of `repriceStatement`, it needs an owner action first | `test_FINDING_aStrangerCanRaiseTheReserveAfterAnOwnerAskChange` | none needed, mention in the docs | documented (DEPLOY). `test_ACCEPTED_aStrangerCanRaiseTheReserveAfterAnOwnerAskChange` |
| S-8 | info | at the former launch share of 11_000 `exitStatement` repaid 110 percent of (gas used plus a fixed 50_000) while a real call carries about 23_000 of intrinsic cost, so each exit nets a small profit at a zero priority fee (about 5.4e12 wei at 0.2 gwei). one per statement, capped, not farmable | `test_FINDING_exitRepayExceedsTheRealGasCost` | none, or lower `COMPOSE_OVERHEAD_GAS` for the exit path | resolved by the launch share `reimburseBps` 8_000: the exit repays 80 percent of the metered gross gas, which is the net gas the caller pays after the EIP-3529 refund, so the repayment stays at or below the real cost. `test_exitRepayIsTheNetGasCostAtTheLaunchShare` |
| S-9 | info | `acceptOwnership` with nothing pending passes for a caller equal to the zero address and would set the owner to zero. no key exists for it on mainnet | `test_FINDING_acceptOwnershipFromZeroWhenNothingPending` | `if (msg.sender == address(0) \|\| msg.sender != pendingOwner)`, one comparison, fits the 216 byte margin | fixed. `acceptOwnership` rejects the zero caller. `test_FIXED_acceptOwnershipRejectsTheZeroCaller` |
| S-10 | info | the postflight row `core: no locks, no exit module` has no override flag, so postflight fails after any lock or after phase 2 starts, and `Resume` ends in a postflight | `test_OK_postflight_readsTheLiveOwnerAndTheLocks` | add a `STATE_CHANGED=1` style flag like `SETTINGS_CHANGED` | fixed. `LOCKS_CHANGED=1` turns the row into a report line. `test_FIXED_locksChangedFlagTurnsTheLockRowIntoAReportLine` |
| S-11 | info | stale text: SPEC.md still has `TIMELOCK`, the queue and freeze table (lines 134, 266, 281 to 289), FLOW.md sections 4 and 8 still say `reserveBps`, a 7 day delay and `Queued` (lines 75, 80, 117). section 9 says it replaces them, but a reader of section 8 gets the old rule | none (grep) | mark or edit those lines | fixed. SPEC.md and FLOW.md sections 4 and 8 carry superseded notes or were edited in place |

## notes per area

### sellTo
* caller: only `controller`. a stranger, the owner and a replaced old controller all hit `OnlyController` (`test_OK_sellTo_onlyTheCurrentController`).
* state: `_cancel` runs `_requireOpen`, so the call needs a held, listed statement whose house auction exists and has no bid. unknown id, exit lane, mid auction, ended but unsettled, sold on the house (stale record and cleared record) and already sold by `sellTo` all revert (`test_OK_sellTo_*`). the exit lane statement never has a listing, so the lane test is implicit and proven by revert.
* floor: `msg.value < floor` reverts `BelowFloor`, exactly the floor passes. `floor = cost * saleFloorBps / 10_000` rounds down, so the real floor is missed by under one wei, which is the same rounding as the reserve (`test_OK_sellTo_hardFloorExactAndRounding`). a zero cost statement cannot exist: compose and the reimbursement make the cost positive, and a record that does not exist reverts `NotListed` before the zero floor matters.
* booking: `msg.value` is booked once by `_book`, split by `saleToBuybackBps`. balance rose by the payment, pots rose by the payment, `skim`, `collectSales` and the house show nothing more (`test_OK_sellTo_msgValueBookedOnceNeverDoubleCounted`). `receive()` ignores any sender but the hook.
* reentrancy: the Statements `transferFrom` has no callback (a buyer contract with `onERC721Received` was never called), the house cancel hands the statement back to the core, whose `onERC721Received` is a view that takes only the Statements and Credits contracts, and `sellTo` is `nonReentrant`. a controller cannot re enter, because `statementPrice` is a staticcall and `sellTo` has no outward call a controller sees.
* not checked: a sale on a statement in the `Returned` state (needs an unwind, see S-4), and a relisted statement mid decay, which needs the same unwind or an overprint (the shipped controller never overprints).

### ControllerV1.buy
* refund reentrancy: the refund goes last, `_busy` blocks `buy` from the refund, the re entry reverted `Reentrant` (`test_OK_sellTo_buyerGetsNoCallbackAndRefundReentryIsBlocked`).
* a buyer that reverts on refund reverts its own buy only, the statement stays held, an exact payment works (`test_OK_buy_revertingRefundRevertsTheWholeBuy`).
* eth in the controller: it has no `receive` and no fallback, a direct send fails, and every buy leaves its balance at zero.
* price change: the ask only falls with time for a stranger (`test_OK_buy_quoteNeverRisesForAThirdParty`), so a quote from an earlier block always covers the later price and the excess comes back. only the owner can raise it.
* front running: a bid that blocks a buy must meet the stored reserve, which is never under the current ask (`test_OK_buy_aBidderBlockingABuyPaysAtLeastTheAsk`), so blocking costs more than buying.
* `buyOnly` false reverts `NotBuyOnly`. after a handover the old owner loses the setters at once and the new owner has them, the controller reads `core.owner()` live.

### statementPrice and _reserveFor
* no overflow or underflow: `drop` is capped at `startBps` before the subtraction, steps times `stepBps` at 5_000 and 1 minute still ends at the floor, a 40_000 start with a 2^128 cost works, cost zero asks zero (`test_OK_price_extremesDoNotOverflowOrUnderflow`). a `listedAt` in the future reverts on the subtraction, which the core never sends (it sets `listedAt` to now first).
* a controller that answers under the floor is floored, one that reverts, burns its 200_000 gas or answers with 31 bytes makes reprice revert `BadPrice` and the stored reserve stays (`test_OK_reserve_*`).
* gas: a cold `statementPrice` of the shipped controller costs about 3,700 gas against the cap of 200,000.
* an absurdly high ask is honored (it only makes auctions unwinnable), the owner picks the controller.

### repriceStatement
* a stranger can only walk a reserve down to the ask of the moment, loops change nothing and `listedAt` is not touched, so the exit clock cannot be reset (`test_OK_reprice_aStrangerCanOnlyWalkTheReserveDownAndLoopsAreHarmless`). a bid blocks it (`HasBid`).
* buy only mode: the controller answers the start price without decay, so a reprice puts the reserve at the start. see S-7.
* the stored reserve can sit under a raised floor until repriced: S-2. when called, the reserve follows the floor (`test_OK_reprice_reserveFollowsTheRaisedFloorWhenCalled`).

### timelock removal and the locks
* no leftover selector: `queue`, `execute`, `cancel`, `TIMELOCK`, `frozen`, `OWNER`, `queuedEta`, `reserveBps` all fail (`test_OK_noQueuePathOrOldNameRemains`). grep finds no code, script or doc that assumes a queue except the stale lines of S-11.
* every former action keeps its checks: zero controller, a module without code, a zero unit, a different exitToken, the core as module, the four forbidden targets, and the cleared target flag of a module (`test_OK_formerActionsKeepTheirValidityChecks`). all eleven owner doors revert `OnlyOwner` for a stranger.
* each lock blocks exactly its setter and nothing else, repeating a lock is a no op, `lockExitModule` reverts `NoExitModule` while unset and redemption still works after it, `removeTarget` works after `lockTargets`, settings, rate and the controller sale settings stay open after all three (`test_OK_lock*`, `test_OK_allThreeLocksLeaveSettingsAndSaleSettingsOpen`).
* what the owner cannot undo: S-3 (a locked controller that cannot price).

### owner handover
* two steps, a stranger and the old owner cannot accept, the pending owner has no power before accepting, a replaced or cleared pending owner loses the right, the old owner loses every door and the controller setters after the accept (`test_OK_handover_*`).
* handover to the core itself never completes (the core cannot call `acceptOwnership`), the owner keeps the role and can overwrite it. there is no renounce or `setOwner`. the zero address edge is S-9.
* scripts: `SetSettings` and `Resume` read `owner()`, postflight reads `owner()` with the `OWNER_CHANGED` flag. gaps are S-5, S-6 and S-10.

### fee split in receive()
* only the hook is booked, a stranger's eth waits for `skim`, which books it whole to the pot as the spec says (`test_OK_receive_onlyHookEthIsBookedAndSkimStaysWhole`).
* the split rounds the buyback share down and the dust goes to the pot, no wei is lost or created for 0, 1, 2, 3, 9_999, 10_001 and 1 ether plus 7 at 33.33 percent, pots stay under the balance (`test_OK_receive_splitConservesEveryWei...`).
* the core's own `buyback()` is not a measuring path: the hook's skim on that swap comes back through `receive`, is split by the same setting, the accounting adds to `ethToBuyback` instead of overwriting it, and the pots stay covered (`test_OK_receive_theCoreOwnBuybackStaysSolventWithTheShare`).
* the measuring paths (`buyListing`, exit, `collectSales`) leave their eth unbooked as before, later booked whole by `skim`. not exercised with the hook as the sender, because that needs the real hook to pay inside a measured call.
* `receive()` gained one cold settings read and one storage write, well inside the gas the hook forwards (all gas).

### redeem reimbursement
* paid once, from the pot, equal to the pot debit, capped by `reimburseCapBps` of the cost (`test_OK_exitRepay_paidFromThePotOnceAndCapped`). a second call reverts `NotHeld`.
* a module that burns 6,000,000 gas is counted at 1,500,000 only (`test_OK_exitRepay_gasBurningModuleCannotPassTheGasBound`). an exit lane statement uses the notional cap (`test_OK_exitRepay_exitLaneUsesTheNotionalCap`).
* a late revert (module pays short, `Underpaid`) pays nothing and changes nothing. the transfer is the last statement, in a `nonReentrant` function, after all state.
* profit over the real cost: S-8.

### settings, scripts, config
* all 29 fields round trip through the three packed slots at every table maximum and every table minimum (`test_OK_settings_packingRoundTripAtEveryMaxAndMin`). each field refuses one above its table maximum and one below its minimum, in the library and in `SettingsBounds` (`test_OK_settings_everyFieldBoundMatchesTheScriptTable`).
* the struct has 29 words, the tuple string of `SetSettings.s.sol` hashes to the selector of `setSettings` (`test_OK_settings_fieldCountAndSelectorAgreeEverywhere`).
* mainnet.json has exactly the 29 settings keys, no `reserveBps`, the five sale keys, and loads equal to the defaults, symbol `CC` (`test_OK_config_jsonCarriesEveryFieldAndTheSaleBlock`).
* postflight flags a change of every one of the 29 settings fields and of every sale field (`test_OK_postflight_comparesEveryFieldOfTheSettingsAndTheSaleBlock`). the config hash covers the whole struct, `sale` included.
* the script sale bounds and the controller constructor bounds agree on nine edge variants (`test_OK_saleBounds_scriptAndControllerConstructorAgree`). Checks.sol warns when the controller floor sits under the core floor, which is the S-1 setup, but only at launch.
* the Checks signoff rows print the new fields, the verify inputs print `abi.encode(core, sale)` for the controller.

### size and determinism
* Core 24,360 bytes, margin 216, ControllerV1 3,664, CoreLib 8,674 (`test_OK_sizeMarginOfTheCore` and `forge build --sizes`).
* two clean `forge build --force` runs of src/ into separate out and cache directories gave identical creation and runtime bytecode for Core, ControllerV1 and CoreLib, and the same as the shipped out directory.

### what this review did not check
* a sale or redemption of a statement in the `Returned` state, and the relist after an overprint with a live controller (an unwind needs a mocked failure of the real Statements, a double the brief does not allow).
* the hook paying `receive()` inside a measured call.
* the full invariant and Rehearsal suites. only the batch named at the top was re run.
