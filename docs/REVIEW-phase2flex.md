# review: phase 2 flexibility (commit a970943)

independent review of `git diff ae6cac0 a970943 -- src/ script/` against docs/FLOW.md section 8. proofs in `test/ReviewPhase2Flex.t.sol` (fork, 20 tests, all pass). naming: only `exitModule` and `exitToken`.

verdict: no critical or high. the core change is sound: no sequence found that puts `xPot + xToBuyback` above the exitToken balance or leaves value unbooked for a third party. the findings are economic edges of the unit refresh and the auction, one stale flag, and the test workaround.

## findings

| id | severity | finding | proof test | suggested fix |
|---|---|---|---|---|
| RP-1 | medium | the auction keeps the price per exitToken across a set but the slice follows the unit and the price doubles per fill. a unit rise lets the whole `xToBuyback` go in fewer bigger fills: draining it costs 57 percent less coin per exitToken (100x rise, measured) than the moment before. a unit fall cuts the coin cost of a full slice by the same factor as the unit (10x measured) | `test_FINDING_unitRiseDrainsThePotCheaperPerExitToken`, `test_FINDING_unitFallCutsTheCoinCostOfAFullSlice` | with `xToBuyback != 0` rescale the stored start price by `oldUnit / newUnit` at the set (floor 1) so the coin cost of one full slice is the same before and after. needs an owner decision: FLOW 8 says the price per exitToken does not depend on the unit, this keeps the price per point instead |
| RP-2 | low | with `xToBuyback == 0` the start is `max(new, stored)` and only ratchets up. a mistaken low unit (1 instead of 1e10) poisons it and the repair to the right unit cannot undo it. the next injection anchors at the poisoned price: 1e10 times too high, 33.2 halvings = 199 hours (8.3 days) at the 6 hour half life, 996 days at 30 days. at 7 days a slice still costs 37 times the whole coin supply. worst case start (unit 1, 1 slice credit, avgScore 800_000) is 1.09e12 above a sane one: 40 halvings, 10 days at 6 hours, 1200 days at 30 days | `test_FINDING_startPriceRatchetKeepsAMistakenLowUnit`, `test_OK_poisonedStartCanBeWorkedOffWithAShortHalfLife` | scale the stored start by `oldUnit / newUnit` instead of `max` (same fix as RP-1, it makes the repair exact). workaround today: after an injection `setSettings` with a 10 minute half life re anchors and brings it down in 6 hours |
| RP-3 | low | `allowedTarget[x]` set while x was not the exitModule stays set while x is the exitModule (blocked at call time by `_forbidden`) and is live again the moment a later set replaces it. nothing is pulled out (a credit must arrive or the call reverts) but an old approval comes back without a new 7 day queue | `test_FINDING_dormantAllowedTargetRevivesWhenTheModuleIsReplaced` | in `_setExitModule` do `delete allowedTarget[module]` (core has 452 bytes of runtime size left, see RP-7) or document that the flag must be removed before a module is set |
| RP-4 | info | the opening price floor (`start < 1e12` reverts `BadModule`) is computed from the new unit alone and also blocks a later unit rise when the stored price is high. with launch settings units above 1.1547e25 are refused. a later `setSettings` (exitSliceCredits, avgScore) moves that ceiling, so a set that worked can revert with the misleading `BadModule` | `test_FINDING_hugeUnitRepairRefusedByOpeningPriceFloor` | check the floor on `max(start, stored)` for later sets, or a dedicated error |
| RP-5 | medium (operational) | the bid pays the old unit for the whole 7 day window. before a unit fall anyone can sell credits into the exit bid at the old unit: 2.319e18 paid for 80 credits, the exit of the composed statement returns 2.605e17 under the new unit (8.9x). the pot is net down by the difference. a rise cannot be front run this way | `test_FINDING_bidPaysTheOldUnitUntilTheSetBlockSoAFallIsFrontRunnable` | runbook in DEPLOY: when queuing a fall, lower `xRateCap` and `xRateFloor` with `setSettings` (instant) and restore in the batch that executes. add to the ARCHITECTURE trust note |
| RP-6 | info | a unit rise does not clamp the exit rate to what the pot carries under the new unit: the rate stays, funded flips false, the rate is flat and every credit the pot cannot pay reverts `PotTooSmall` until the owner calls `setXRate` | `test_FINDING_unitRiseLeavesTheRateAbovePotAndFlat` | in the executing batch call `setXRate`, or clamp `xRateAtCheckpoint` to the new pot cap in `_setExitModule` |
| RP-7 | info | core runtime code is 24,124 bytes of the 24,576 limit (452 left). the full forced rebuild is byte identical to the cached build | n/a, `forge build --sizes` | keep new core code under about 400 bytes or move more into `CoreLib` |
| RP-8 | info | `exitToBuybackBps` now applies to eth lane exits only and `exitLaneToBuybackBps` to exit lane exits. the struct comment and docs say so, the names do not | n/a | doc only, or rename `exitToBuybackBps` to `ethLaneToBuybackBps` before launch (storage layout does not change) |
| RP-9 | low (tests) | the `test/Fees.t.sol` workaround adds `assertEq(core.settings().exitLaneToBuybackBps, 0)` under a comment that claims the share has no bearing on the eth buyback. the line only reads the default and tests nothing of the kind. see test quality below | n/a | see below |

what was not a finding, with proof: `test_OK_*` in the same file.

## notes per question

### 1. pots against the exitToken balance, unbooked value

* first set: `_xCheckpoint` runs with unit 0 and `xFunded` false, so no division by zero (`xRate` returns the stored rate before it would divide). `xPot` is 0 before the first set (skim is gated on the token, `exitStatement` on the exitModule), so leaving `xFunded` unsynced on the first set equals the definition.
* `exitStatement` books exactly the balance delta: `toBuyback = received * bps / 10_000` rounds down and the remainder goes to `xPot`, so the two add to `received`. `sellForExitToken` pays at most `xPot` and writes the pot before the transfer. `buybackExit` takes the slice out of `xToBuyback` before the transfer.
* a gift before the first set sits unbooked, any caller can `skim` it into `xPot` after the set, nobody can capture it for themselves. same for a gift just before an exit (it is in `balanceBefore`, so it is not mistaken for proceeds).
* proofs: `test_OK_nothingUnbookedAroundSets` (pots equal the balance after every step), `_solvent()` in every scenario test.

### 2. exit rate checkpoint across a unit change

* order in `_setExitModule`: checkpoint under the old unit and old funded flag, store the new unit, resync funded. in the block of the set `xRate()` is identical before and after.
* matrix of 12 cases (unit x1000 and x0.001, rate at floor, middle and cap, pot that carries the bid and pot that does not): continuity, funded flag equals its definition, never climbs past the cap of the new unit, flat when unfunded. `test_OK_rateCheckpointAcrossAUnitChangeMatrix`.
* a seller in the block of the set: `_sellForExitToken` reads the unit and checkpoints in one call, so it is the old unit with the old rate or the new unit with the checkpointed rate, never a mix. no overpay path found. `test_OK_sellInTheBlockOfTheSetUsesOneUnitAndMinOutProtectsAFall`.
* `minOut` is in exitToken units. when the unit drops it protects a seller who sized the sale on the old unit: the call reverts `Slippage` instead of paying a tenth. it does not exist in the one argument overload. it does not protect the pot (RP-5).
* rate frozen above what the pot carries after a rise: RP-6. unit fall resumes the climb at once (funded flips true).

### 3. exit auction

* with `xToBuyback != 0` price, start and clock are untouched: the price per exitToken is the same in the block of the set for rise, fall and same address. the slice follows the unit (RP-1 for what that does to a drain). rounding: `coinIn` rounds up, slice is `min(xToBuyback, fullSlice)`, no case found where a fill is cheaper per exitToken than the quote right before.
* the re anchor on the next injection is unchanged code: `max(price now, start / 4)`. after a set with a high stored start it anchors at least there. it cannot be lowered by a set.
* `xToBuyback == 0`: `max(new start, stored)` never lowers the price (`test_OK_emptyBuybackPotPriceNeverFallsAcrossASet`). the cost is the ratchet (RP-2). numbers: half life 6 hours, poison factor 1e10 (unit 1 against 1e10): 33.2 halvings, 199 hours. half life 30 days: 996 days. at the 10 minute minimum: 5.5 hours. worst case stored start 1.25e39 against a sane 1.15e27: 40 halvings, 240 hours (10 days) at 6 hours.
* `decay` returns 0 after 256 halvings and `coinIn` rounds up from a zero price to zero: a fully decayed auction gives the slice away. unchanged by this commit.

### 4. reentrancy and callbacks

* every state changing door of the core has `nonReentrant` or `onlyOwner`. the unguarded externals are `receive` (hook only), `notify` (empty), `onERC721Received` (view), `unlockCallback` (pool manager only).
* `exitToken()` and `unitPerPoint()` are read with static calls (`_ask` is a `staticcall`, the interface functions are `view`), so a hostile module cannot change state from them at all.
* `exit(sid)` is the only mutable callback. a module that tried 15 doors from inside it (skim, composeExit, compose, collectSales, overprint, buyback, buybackExit, sellForEth, sellForExitToken, exitStatement, syncStatement, repriceStatement, buyListing, setXRate, execute) got 0 through, and the same skim works outside the callback (control). `test_OK_hostileModuleCannotReenterAnyDoor`.
* a module that reports another exitToken after it was set: the core keeps its own copy and never asks again. its exits revert `Underpaid`, setting the same address again reverts `ExitTokenChanged`, a good module replaces it, pots stay solvent. `test_OK_moduleThatChangesItsReportedTokenOnlyBricksItself`.
* a module whose own unit drops later without a set makes every exit revert `Underpaid` until a set runs (7 days). that is the design (unit read only at a set), listed here so the runbook knows.

### 5. forbidden targets

* the old module may be added as a target after a replacement (`_forbiddenBase` does not list it), the new module and the exitToken are refused on add (`ForbiddenTarget`) and at call time (`TargetNotAllowed`). calling the old module through `buyListing` pulls nothing: a credit must arrive or `NoCredit` reverts the whole call. `test_OK_forbiddenSetsAfterAReplacement`.
* a module that is a stack member, or has no code, is refused as in the first set (`test_OK_replacementStillRefusesStackMembersAndNonContracts`).
* a target flagged before it became the exitModule: RP-3.

### 6. leftovers of the old exitModule

* the core stores no per statement module and gives no approval to the exitModule: the only approvals in `src/Core.sol` are credits to Statements and statements to the house. an exit is `transferFrom` by the core as owner. nothing to revoke. statements already handed to the old module stay with it.

### 7. exit lane share

* at 10_000 `xPot` is not refilled from the exit lane and `xToBuyback` gets the whole proceeds. nothing divides by it: the only divisions are by `avgScore * unit` (both non zero) and by `BPS`. the bid runs dry with a plain `PotTooSmall`, views never revert, `composeExit` works and repays the same eth as at 0 (reimbursement is eth from `ethPot`, capped by `PAGE * avgScore * RATE_START`, no exitToken or share in it). `test_OK_exitLaneShareAtMaxIsHarmless`.
* the share is read at the exit, not at the compose: a statement composed at 0 and exited at 10_000 goes whole to the buyback pot. the lane comes from the memory copy of the record taken before `_unhold`, so it cannot be flipped mid call. `test_OK_exitLaneShareChangedBetweenComposeAndExit`. the owner can move the split with `setSettings` at any time, instant, accepted settings control.
* eth lane path: `exitToBuybackBps` only, unchanged (Phase2Flex has the matrix, nothing contradicting it found).
* with a share above 0 any holder of an exit lane statement can exit it at once and re anchor the auction price up to a quarter of the start. the eth lane has the same lever after `exitAfter`. unchanged class, not a finding.

### 8. storage packing and bounds

* the third word: 7 fields up to bit 175 (`rateCap` at 112 to 175), the new field alone at 176 to 191, bits 192 to 255 unused. with every one of the 28 fields at the max of its type (past the bounds) the compiler layout gives words `2^240-1`, `2^256-1`, `2^192-1`, decode returns the same struct, and a write to the new field alone touches only bits 176 to 191. `test_OK_packingEveryFieldAtTypeMaxRoundTrips`. test/ReviewFlowCore.t.sol already round trips all min and all max through `setSettings`.
* bounds: 10_000 accepted, 10_001 reverts `BadSetting("exitLaneToBuybackBps")`, 0 accepted, the field is last in check order. `test_OK_exitLaneShareBounds`.

### 9. scripts and config

all 28 fields are covered everywhere the other 27 are. `SettingsFields` (N, `get`, `set`, `lo`, `hi`, `names` in struct order, 20 character name fits `bytes32`), `SetSettings` (TUPLE has the trailing uint16, arrays sized 28), `LaunchConfig` (`_u16` read of `.settings.exitLaneToBuybackBps`, a missing key reverts in `parseJsonUint`), `Checks` preflight row (printed), `settingsViolation` through `SettingsBounds`, `mainnet.json` (0). `PostflightChecks` compares the whole struct by `keccak256(abi.encode(live)) == keccak256(abi.encode(c.settings))` and the bounds check, so the new field is compared without a per field list, and `Resume.s.sol` does the same. no missed field. the postflight print row now includes it. no other file lists fields (grep of `buybackSlice` outside src and tests: Checks, SettingsFields, LaunchConfig, mainnet.json, docs, sim).

### 10. test quality and the solc internal error

* reproduced: a scratch copy of a970943 with the three added lines removed from `test/Fees.t.sol`, `forge build test/Fees.t.sol --force` dies after 81 seconds with `Internal compiler error ... assembleYul ... Tag too large for reserved space` (solc 0.8.30, via_ir, optimizer 200 runs). with the lines in place the whole project builds.
* `src/` is deterministic: a forced full rebuild into a fresh out and cache dir (984 seconds) produced byte identical creation and runtime code for all 196 artifacts present in both builds, Core included (24,124 bytes runtime).
* cause as far as it can be told: it is a solc assembler limit in a big test contract, not in `src/`. every test contract that inherits `Fixture` embeds the creation code of the Core, the controller and the artcoins launch data through `SystemDeployer`, about 320 KB of creation code each (largest measured 326,169 bytes), far above the 64 KiB a two byte tag can address. whether the assembler fits its reserved tag space then depends on the layout of the whole contract, so an unrelated three line edit moves it. which contract in `Fees.t.sol` trips was not isolated (solc does not name it).
* what the workaround hides: nothing in the contracts under test. the added `assertEq(core.settings().exitLaneToBuybackBps, 0)` reads a default, it is not a test of the comment above it ("no bearing on the eth buyback"). it only shifts code layout, so the next edit to `Fees.t.sol`, `Fixture` or `Core` can bring the error back with no relation to the change.
* robust fix, in order of effort: (1) stop embedding the system in every test contract: deploy `SystemDeployer` as its own contract in `setUp` (or `deployCode` from artifacts) so each test contract is a few tens of KB; this removes the cause and also cuts the 16 minute cold compile. (2) split `AuctionTest` (500 lines) and the other long contracts of `Fees.t.sol`. (3) try a newer solc and check the release notes for the tag fix, not verified here. (4) run `forge build --force` in CI so a layout dependent failure shows on the pull request, and replace the dodge line by a real test: set `exitLaneToBuybackBps` to 10_000 and assert the eth buyback is byte for byte the same as at 0.
* the new `Phase2Flex.t.sol` and the invariant handler cover the change well (replacement, unit refresh, share split, bounds). gaps this review filled: aggregate drain price (RP-1), start price ratchet (RP-2), dormant flag (RP-3), hostile reentry, a module that changes its report, same block sale with `minOut`, packing at type max.

## not checked

* the real exitModule (unknown interface): the stand ins pay `rating * unit` exactly, a real one may round, charge, or pay late.
* a fee on transfer or rebasing exitToken: the pots assume plain balance deltas.
* the economic meaning of a unit change for the real exitToken: RP-1 and RP-5 assume a unit change changes what one exitToken is worth in points, which only the real adapter can settle.
* a compromised owner (out of scope), solc behavior on other versions, the sim and docs beyond the scripts, gas griefing of `execute` with a module that burns gas in `exitToken()` (owner only).
