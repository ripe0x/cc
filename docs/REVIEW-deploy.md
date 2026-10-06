# deploy review

independent review of the launch of branch `artcoin` at a657c84: the contract delta of the last commit (`src/Core.sol`, `src/interfaces`) and the launch package (`script/`, `script/config/mainnet.json`, `docs/DEPLOY.md`, `test/Rehearsal.t.sol`). proofs and fuzz tests are in `test/ReviewDeploy.t.sol` (12 + 2 tests, `forge fmt` clean). the full suite passes with them (277 passed, 5 skipped deep invariant runs, 0 failed). nothing in `src/` or `script/` was edited.

## status after the fixes

all eleven findings are closed in `script/`, `src/Core.sol` (constructor only), `test/` and `docs/`. nothing here changes the runtime bytecode: Core runtime 23,983 bytes, margin 593, unchanged (initcode grew to 25,573, limit 49,152). full suite: 287 passed, 0 failed, 5 skipped deep invariant runs. the proofs of this review are now `test_FIXED_` regressions in `test/ReviewDeploy.t.sol` (plus `test/Resume.t.sol` and `test/CoreUnit.t.sol`). the runbook was followed literally from a clean shell on an anvil fork of the latest block, see section 6b.

| finding | status | what changed |
|---|---|---|
| D-1 | fixed (runbook) and documented | DEPLOY.md section 0 names `https://rpc.mevblocker.io` as `PRIVATE_RPC`, tests it first with `cast code` and `cast call` against the factory, and gives the normal rpc fallback with the exact reason (a deprecated factory takes launches only from its owner and admins) and the residual exposure table. measured from this network: Flashbots Protect 504 on `eth_getCode`, 403 not whitelisted on `eth_call`, mevblocker served both. broadcast through mevblocker itself was not run, only anvil |
| D-2 | fixed | pinned rules in preflight for every launch input that slipped (ticks, pool fee, skim, bounty with an override flag, referral cap, lp fee, sniper, tax, burn with an override flag, owner and creator, WARN rows), postflight reads back name, symbol, position ticks, start tick, the sniper start, end and duration through the mev module, and prints what cannot be read. `CONFIG_HASH`: preflight prints it, `Deploy` and `Resume` refuse to run without it, postflight prints it and checks it when set. matrix result in section 4b |
| D-3 | fixed | preflight rows: the hook reports the pool manager, factory and escrow, the locker reports the factory and position manager, the locker and mev module are enabled on the factory |
| D-4 | fixed | the Core constructor requires code at the pool manager, hook, factory, locker and escrow (the coin is not checked, it does not exist yet) and a tick spacing of at most 32767. runtime size unchanged |
| D-5 | fixed | preflight fails unless the factory is deprecated, `overrides.openFactory` in the config opens it for a future public factory |
| D-6 | fixed | DEPLOY.md section 6: the failure table, the `cast` commands for each resume point (all run on anvil), the "new salt" advice deleted and corrected, `script/Resume.s.sol` detects the stage on chain and sends only the missing steps, with a fork test for each stage |
| D-7 | fixed | local config `script/config/local.json` through `LAUNCH_CONFIG`, in `.gitignore`, and `Rehearsal.t.sol` rehearses that file (it fills only the placeholders the file leaves unset) |
| D-8 | fixed | DEPLOY.md housekeeping row: the token admin can raise the tax to `taxBpsMax` and the referral cap to 1000 |
| D-9 | fixed | every narrowing cast in the config loader is bounds checked and reverts with `ConfigOutOfRange(key)`, tested at the edges for six fields |
| D-10 | fixed | `Deploy` no longer reads `PRIVATE_KEY` from the environment, the signer comes from the flags only. `REQUIRE_REVOKED=1` makes the postflight row `deployer still factory admin` fail while the deployer is an admin |
| D-11 | fixed | spacing 0 is a rule row, not a panic. the factory owner step is step 4. SPEC.md funded rule corrected. DEPLOY.md says the forge estimate excludes the fee. `RATE_START_MIN` and `MAX` have one definition shared by the Core and the scripts |

also changed: the default `rateStart` is 5.6e12 (5.6e12 is the flat price 0.00896 eth divided by 1600), with the launch day rule in DEPLOY.md.

## verdict after the fixes

**go for the launch package**, on the condition the operator runs the rpc test of DEPLOY.md section 0 before step 7 and keeps the fallback in mind. every blocker of the first verdict is closed: step 7 has an rpc that serves state reads and a stated fallback (D-1), every mutation of the matrix is stopped by a rule, a safe revert or the config hash (D-2, section 4b), and a partial deploy has a script and a table (D-6). what is still unproven is listed in section 9.

## original verdict (before the fixes)

**no go for mainnet with the package as it stands. go for the contracts.** `src/` has no finding. the funded rule, the clamp and the new constructor inputs are correct (section 2). the blockers are in the launch procedure: one step that cannot run as written, and launch inputs that the checks cannot tell are wrong. all three fixes are in `script/` and `docs/`, none touches the runtime bytecode (593 bytes of margin stay untouched).

blocking items, in order:

1. **D-1** step 7 uses `forge script --rpc-url $PRIVATE_RPC`. forge forks the rpc it broadcasts through and needs `eth_getCode` and `eth_getStorageAt`. the Flashbots Protect endpoint named in the runbook answered both with a 504 here and `forge script Preflight.s.sol --rpc-url https://rpc.flashbots.net/fast` failed with `HTTP error 504`, while `https://rpc.mevblocker.io` served the same preflight (33 of 35 rows ok, the two failures were the expected deployer rows). the runbook as written stalls at step 7, which invites improvising on launch day.
2. **D-2** launch inputs that pass preflight, launch, and pass postflight while being wrong: a narrower or shifted position (proven: 1.63x fewer coin per eth for buyers), wrong sniper parameters, a tax recipient that is not the burn address, bounty bps 0 or 9999, owner and creator swapped, a wrong escrow. postflight compares the chain with the same config file, so a wrong value in the file is invisible. fix with pinned rules plus a config hash sign off (details below).
3. **D-6** the runbook has no recovery for a partial deploy and gives wrong advice ("the fix is a new salt"). the states after each transaction are all safe (section 5), but the operator needs exact commands for the two that leave the deployer as token admin.

## findings

| id | severity | title | proof |
|---|---|---|---|
| D-1 | medium | step 7 cannot run through the named private rpc, forge needs state reads the relay does not serve | proven against the endpoint, from this network |
| D-2 | medium | launch inputs that pass preflight and postflight yet launch wrong (14 of 51 mutations, section 4) | proven, `test_POC_wrongPositionLaunchesAndPassesAllChecks`, `test_POC_sniperParamsAreNotReadBack` |
| D-3 | low | escrow, pool manager and factory are never compared with what the hook itself reports | proven, `test_POC_wrongEscrowPassesAllChecks` |
| D-4 | low | the Core constructor accepts stack members without code | proven, `test_POC_coreAcceptsAStackWithoutCode` |
| D-5 | low | a factory that is not deprecated is not a preflight failure | proven, `test_POC_openFactoryPassesPreflight` |
| D-6 | medium | no partial failure recovery in the runbook, and the stated fix (new salt) is wrong | proven, `test_partialStates` |
| D-7 | low | the runbook edits the tracked mainnet.json, the rehearsal ignores `LAUNCH_CONFIG` | proven by reading, run on anvil |
| D-8 | low | DEPLOY.md says the token admin can only lower the tax and the referral cap, it can raise both | proven, `test_signoff_adminCanRaiseTaxAndReferralCap` |
| D-9 | low | json numbers are cut to the field width instead of rejected | proven, `test_POC_jsonNumbersAreTruncated` |
| D-10 | info | postflight row "deployer still factory admin" is ok when it is yes, `PRIVATE_KEY` in the env overrides `--ledger` and `--account` | proven on anvil |
| D-11 | info | small defects: preflight panics on spacing 0, step numbering, stale SPEC line, estimate excludes the fee, rate bounds duplicated | proven |

no finding in `src/`. no secrets in the repo or its history.

## minimal fixes

**D-1.** in `docs/DEPLOY.md` step 7 use a relay that serves state reads, for example `--rpc-url https://rpc.mevblocker.io`, or run the dry run on the read rpc and publish the signed transactions through the relay. add the rpc to the "what you need" table by env var name and say how to confirm it works (`cast code $FACTORY --rpc-url $PRIVATE_RPC`). note that while the factory is deprecated the public mempool cannot hijack the launch (only the factory owner and admins may launch), so the private relay protects secrecy, not safety. unproven from the owner's network: whether Protect times out only from this sandbox. test it with the cast line first.

**D-2.** three small additions, all script side.
* `_preConfig` "launch parameters sane": add `startTick % tickSpacing == 0`, `startTick == positionLower` (the single sided position starts at the price edge), `positionUpper == floor(MAX_TICK / spacing) * spacing`, `sniperStartBps > sniperEndBps`.
* postflight: read `IArtCoinsMevSkim(mevModule).currentSkimBps(poolId)` and require it equals `sniperStartBps` while `block.timestamp - poolCreationTimestamp(poolId) < 60`, and compare the position ticks with the config through the position manager (`positionId` from `tokenRewards`).
* preflight prints a keccak of the whole config and a table "owner (core owner and token admin)", "creator (0.5 point leg, lp rewards)", "points to the core", "points to the creator", "tax and burn address". `Deploy` requires `CONFIG_HASH=<that hash>` in the env. the owner signs the table, the script launches only what was signed, which closes the whole class of values that are individually plausible (swapped owner and creator, bounty 9999, lp fee, referral cap).

**D-3.** add three preflight rows: `hook.poolManager() == stack.poolManager`, `hook.factory() == stack.factory`, `hook.feeEscrow() == stack.escrow`. the getters exist on the live hook (read on the fork).

**D-4.** in the Core constructor require `code.length != 0` for poolManager, hook, factory, locker and escrow, and `tickSpacing <= 32767`. constructor code is not in the runtime, so the size margin is unchanged. this alone does not stop a wrong contract, D-3 does.

**D-5.** preflight fails `factory: deprecated` unless `ALLOW_OPEN_FACTORY=1` is set. `Deploy.run` already runs preflight right before the broadcast, so a factory opened between step 5 and step 7 stops the run.

**D-6.** add a "partial failure" section to the runbook with the table in section 5 and these commands, run as the deployer: `cast send $HOOK "lockPoolExtension((address,address,uint24,int24,address))" "(0x0000000000000000000000000000000000000000,$COIN,8388608,200,$HOOK)"` then `cast send $COIN "updateAdmin(address)" $OWNER`, then postflight. delete "the fix is a new salt": the coin address includes the Core address through the tax config, so a rerun with the same salt gets new addresses (proven: the second run with an identical config and salt in `test_matrixState` launched). after a failed launch transaction the Core is still usable, retry that one transaction by hand from the saved `broadcast/Deploy.s.sol/1/run-latest.json`.

**D-7.** runbook: `export LAUNCH_CONFIG=script/config/launch.local.json`, add that path to `.gitignore`, make `Rehearsal.t.sol` read `LAUNCH_CONFIG` (overwriting the five placeholders as it does now) so the rehearsal runs the values that will launch.

**D-8.** DEPLOY.md housekeeping row: the token admin can set the tax anywhere in [0, `taxBpsMax`] (raise to 20 percent) and raise the referral cap to 1000. the owner signs that as the ceiling.

**D-9.** loader: `require(v <= type(uint16).max)` style bounds before each narrowing cast, or read through `parseJsonUint` then `SafeCast`.

**D-10.** postflight: when `REQUIRE_REVOKED=1` the info row fails on yes. runbook: unset `PRIVATE_KEY` in the shell when using `--ledger` or `--account`, or have `Deploy` refuse to run when both are present.

**D-11.** guard `positionLower % tickSpacing` against spacing 0 with a row instead of a panic. DEPLOY.md section 0 says the factory owner acts in "step 3", it is step 4. SPEC.md line 160 still says funded means `ethPot >= AVG_SCORE * ethRate / 1e4`. forge's "Estimated amount required" (0.003 eth) excludes the 0.069 eth deploy fee. `RATE_START_MIN`/`MAX` exist in both `Core` and `ConfigReader`, read them from the Core.

## 2 contract delta (Part A)

**stack immutables.** `MANAGER`, `HOOK`, `TICK_SPACING`, `POOL_FEE`, `FACTORY`, `LOCKER`, `ESCROW` and `RATE_START` are immutables read from the constructor. the constructor checks nonzero for owner, coin, controller and five stack addresses, `tickSpacing > 0`, and the rate bounds. it does not check code (D-4). what each member can do if wrong:

| member | use in the Core | if wrong |
|---|---|---|
| `HOOK` | `receive` books eth only from it, pool key hooks field | an address with no code or an EOA means whoever controls that address books fees (proven in `test_POC_coreAcceptsAStackWithoutCode`). through the script the same value is sent to the factory, which refuses a hook it has not enabled (matrix rows 1 and 2, preflight fails), so this needs a hand deployed Core |
| `MANAGER` | `unlock`, swap, settle, take in the buyback, and `unlockCallback` authenticates `msg.sender == MANAGER` | a hostile contract here could call `unlockCallback` and make the Core settle pot eth to it. unreachable through the script: the factory launch fails with a wrong manager (matrix row 4 reverts) and postflight reads the pool from `core.MANAGER()` |
| `TICK_SPACING`, `POOL_FEE` | the pool key of the buyback | a mismatch swaps in an uninitialised pool (the swap reverts, nothing moves) or in a pool someone else opened with a different key on the same coin. postflight rules both out, see below |
| `FACTORY`, `LOCKER`, `ESCROW` | only the forbidden target list | a wrong value weakens the list. escrow is the only one no check ties to the hook (D-3, proven slip). locker is checked by `enabledLockers(locker, hook)`, factory by every factory call |

**does postflight prove the pool the Core swaps in is the launched pool?** yes. the Core key is `(0, COIN, POOL_FEE, TICK_SPACING, HOOK)` on `MANAGER`. postflight requires each of those immutables to equal the config, builds the key from the config, and then requires: `coin.canonicalPoolId()` equals its hash (set by the factory at launch), the locker `tokenRewards(coin).poolKey` equals the key, and `getSlot0(core.MANAGER(), id)` shows an initialised pool. a pool at any other key fails one of the three. the matrix confirms it: poolFee 3000 made the factory create the dynamic fee pool while the Core carried 3000, and postflight failed the pool initialised, skim config, hook and locker pool key rows.

**rateStart.** `RATE_START` is read in the constructor only (`rateAtCheckpoint = rateStart_`), nowhere else in `src/` or in the old constant's former places (grep). bounds [1e11, 1e15] are enforced at construction and mirrored in preflight. overflow: the largest products are `score * rate * 12500` at 1e15 (about 1e26 for a score of 1e7), `AVG_SCORE * rate` and `ethPot * 2000`, all far below 2^256; the climb multiplies a rate bounded by `ethPot * 2000 / AVG_SCORE` by a factor below 7e18. at the lower bound an average credit costs 4.33e13 wei and the pot is funded at 2.165e14 wei, exactly (`test_rateStartBounds` checks the flip at the wei at both ends). at 1e11 the pot funds on dust, the rate then needs about four days of climb to reach 4e12, and sales before that are at near zero prices: a market choice, no safety issue, but it is why the sign off must name the number.

**the funded rule and the clamp.** re derived: funded is `ethPot * 2000 >= AVG_SCORE * rate`, which is `AVG_SCORE * rate / 1e4 <= ethPot * 20%`, one average credit fits the hourly cap. the clamp is `cap = floor(ethPot * 2000 / AVG_SCORE)`. rounding goes the safe way: flooring the cap means any `r <= cap` satisfies `AVG_SCORE * r <= ethPot * 2000`, and a funded flag implies `r <= cap`. the credit price floors too, and the window cap `windowPot * 2000 / 10000` floors, and floor is monotone, so an average credit at the clamp always fits a fresh window. the same expression is used in `ethRate`, `_syncFunded` and `_requireRoom` bps; every writer of `ethPot` (receive, skim, `_spend`, `_compose`, `buyStatement`) checkpoints first and resyncs after, so no path leaves a stale flag.
* after a fill the stored rate can sit above the new cap (the rate drops 10 percent of the share, the cap drops the whole share): then `funded` is false and `cap <= r` returns the stored rate, no climb. correct and intended.
* window interaction: `windowPot` is fixed at window open. a window is opened only by a spend, which also resets `lastFillTime`, so during that window the climb tier is the base 100 bps per hour, at most 1 percent over the remaining hour, even if fees have since multiplied the pot. no scenario lets the rate climb materially while the window has no room, and a stale window cannot outlive one hour. nothing to fix.
* the phase 2 bid keeps `xPot * BPS >= AVG_SCORE * xRate * unit`. that is intentional and consistent: the phase 2 side has no hourly cap, a sale needs only `price <= pot`, so the threshold for the whole pot is the right one. nothing else in the Core uses the old 100 percent threshold (grep of `BPS / AVG_SCORE`, `ethPot * BPS`).
* fuzz: `testFuzz_fundedRuleAndClamp` (400 runs, rateStart anywhere in bounds, random fees, skims, warps up to 400 hours, real credit sales). per step it asserts: the flag equals its definition, a funded rate satisfies `AVG_SCORE * rate <= ethPot * 2000`, an unaffordable stored rate never climbs, an unfunded rate never moves, a funded rate never falls without a fill and never passes `max(r0, cap)`. it passes. the existing `testFuzz_clampKeepsAnAverageCreditSellable` covers the sale at the clamp.

**anything else in the diff.** `Mainnet.defaultStack()` is used by tests and the default config only. the forbidden list reads the three config members, and `buyListing` still runs `_forbidden` at call time. runtime size: 23,983 bytes, margin 593. each immutable is pushed at every use, so the 8 new ones cost bytes. fragile only in the sense that any runtime change over about 590 bytes breaks the 24,576 limit. every fix proposed here is in the constructor or the scripts, so none moves it. initcode is 25,438 bytes (limit 49,152). the deployed bytecode of the anvil run equals `forge inspect Core deployedBytecode` in all but the immutable slots (464 bytes differ, all inside the 29 immutable reference slots of the 10 immutables, checked).

## 3 sign off table check (Part B item 8)

every row of both tables was checked against `src/Core.sol`, `script/config/mainnet.json`, `script/Builder.sol` and the live fork. values, units and meanings match for all constant rows (SUPPLY, FEE_BPS, CREATOR_BPS, AVG_SCORE, RATE bounds, climb tiers and the 72 hour top, DROP_BPS, SPEND_CAP, BONUS_CAP, tip, auction 4x to 1.2x over 72 hours, splits, buyback slice and delay and tip, phase 2 bid constants, timelock, overprints, allowed and forbidden targets) and for the config rows (addresses, 200 and 8388608, ticks, skim units, tax). the "at launch" claims were run: a 1 eth buy in the launch block puts 0.895 eth in the pot (90 points minus the 0.5 creator leg, `test_signoff_sniperExtraGoesToTheCore`), a 1 eth buy after the window puts 0.095 eth (rehearsal).

mismatches and gaps:

| row | text | reality |
|---|---|---|
| token admin (housekeeping) | "it can lower the tax ... lower the referral cap" | it can set the tax anywhere in [0, 2000] (raise 1500 to 2000) and raise the referral cap from 0 to 1000 (D-8, proven) |
| `launch.startTick` and `positionLower` | listed as independent values | they must be tied: the position starts at the price edge. start tick -175200 or -175001 launches with the same price (harmless) but nothing checks it, and a different positionLower changes the price (D-2) |
| `launch.maxReferralBps`, `launch.lpFee` | "referral cap", "extra lp fee", no unit | both use the same hundredths of a basis point scale as `baselineSkimBps` (hook interface), the table should say so |
| `launch.supply` | "all of it in the locker" | all of it sits in the pool manager as the locked position, 3,551 wei rounding dust stays in the locker |
| section 0 | factory owner acts "step 3" | it is step 4 |
| `RATE_START_MIN`, `RATE_START_MAX` | in the Core table | also duplicated in `script/LaunchConfig.sol`, drift risk (D-11) |

## 4 config mutation matrix (Part B item 5)

method: `test_matrix` and `test_matrixState` fork mainnet at the pinned block, enable a throwaway deployer, and for each mutation of the default config (placeholders filled) run preflight, then the full `deploySystem` (controller, core, launch, lock, handover, postflight) on a snapshot. "pre" is the failed preflight rows. "deploy" is what the deploy does. a deploy that reverts on `Deprecated`, a factory error or a core error stops in the simulation, so nothing is broadcast. "postflight" means the in script postflight reverted the deploy, also before any broadcast. SLIP means preflight clean, the system launches, postflight clean.

| mutation | preflight | deploy | result |
|---|---|---|---|
| hook is a contract that is not the hook | fails hook enabled, locker enabled | factory reverts | caught |
| hook is an EOA | fails code, hook enabled, locker enabled | factory reverts | caught |
| locker is the escrow | fails locker enabled for hook | factory reverts | caught |
| pool manager is another contract | clean | reverts empty | safe revert |
| escrow is another contract | clean | launches, postflight clean | **SLIP** (D-3) |
| factory is another contract | fails 7 rows | reverts empty | caught |
| tick spacing 60 or 400 | fails parameters sane | factory reverts | caught |
| pool fee 3000 | clean | postflight fails pool, skim, hook, locker rows | caught by postflight |
| owner and creator swapped | clean | launches, postflight clean | **SLIP** (inherent) |
| name empty, salt zero (owner or creator zero is the same check) | fails placeholders | ConfigUnset | caught |
| taxBps 2100 over taxBpsMax 2000 | fails parameters sane | factory reverts | caught |
| taxBps = taxBpsMax = 9999 | clean | factory reverts | safe revert |
| taxBurn is the creator | clean | launches, postflight clean | **SLIP** |
| taxBurn zero | clean | factory reverts | safe revert |
| bountyBps 9999 | clean | launches, postflight clean | **SLIP** |
| bountyBps 0 | clean | launches, postflight clean | **SLIP** |
| bountyBps 10000 | fails parameters sane | factory reverts | caught |
| startTick -174800 or +175000 | clean | factory reverts | safe revert |
| startTick -175200 (one spacing off) | clean | launches, postflight clean | **SLIP**, price unchanged (harmless) |
| startTick -175001 (off the spacing) | clean | launches, postflight clean | **SLIP**, harmless |
| positionLower -175001, positionUpper 887201 | fails parameters sane | factory reverts | caught |
| positionUpper 887400 (beyond max tick) | clean | factory reverts | safe revert |
| positionUpper 600000 (aligned, narrower) | clean | launches, postflight clean | **SLIP** |
| positionLower -170000 (aligned, shifted) | clean | launches, postflight clean | **SLIP**, 1.63x fewer coin per eth (proven) |
| rateStart 0, 1e10, 1e16, 4e15 | fails rateStart in bounds | ConfigUnset (and the Core reverts BadRate) | caught |
| supply 1e27 + 1, 1e28, 0 | fails supply equals the Core constant | postflight or prediction mismatch | caught |
| token creation code, one byte changed | clean | `AddressMismatch(coin)` after the core exists, in the simulation | safe revert, preflight does not catch it |
| sniperSeconds 0, 86400, start below end | 0 fails sane, others clean | factory reverts | caught or safe revert |
| sniperStartBps 20000, sniperSeconds 300 (valid, wrong) | clean | launches, postflight clean | **SLIP** (D-2, proven, the module value is readable) |
| maxReferralBps 1000, lpFee 5000, baselineSkimBps 60000 | clean | launches, postflight clean | **SLIP** (values, inherent) |
| mev module is another contract | fails mev module enabled | factory reverts | caught |
| factoryOwner not the owner | fails owner matches | launches (a pure check) | caught by preflight |
| factory not deprecated (open) | clean | launches | **SLIP** (D-5) |
| deployer not enabled | fails deployer may launch | `Deprecated` revert | caught |
| deployer balance 0.05 eth | fails balance | reverts | caught |
| deployer balance 0.07 eth (fee, no gas) | fails balance | simulation passes (no gas price) | caught by preflight only |
| salt reuse after a first launch | clean | launches, new coin address | benign, the coin address includes the Core address |
| tick spacing 0 | preflight panics (modulo by zero) | core reverts BadStack | fails loud (D-11) |

count: 51 matrix runs, plus the sniper run tested separately. **14 of the 51 slip through every check** (6 structural gaps a rule can close: escrow, startTick x2, positionUpper, positionLower, open factory; 7 plausible values the checks cannot know are wrong: owner and creator swap, taxBurn, bounty 9999 and 0, referral cap, lp fee, baseline skim; 1 benign: salt reuse). with the sniper run, 15. the fixes in D-2 (pinned rules and the config hash) close the 7 value ones by making the owner sign the hash of the printed table, and the 6 structural ones by rules.

### 4b the matrix after the fixes

`test_FIXED_matrix` and `test_FIXED_matrixState` rerun the same mutations (56 config mutations, 5 state runs) plus the new ones for the new rules, and classify each: caught by a preflight rule, safe revert at deploy, caught by postflight, or launched with every check passing. the baseline launches clean.

| class | count |
|---|---|
| caught by preflight | 53 (49 config, 4 state: open factory, deployer not enabled, balance below the fee, balance without gas) |
| safe revert at deploy | 1 (the changed token creation code, `AddressMismatch(coin)` in the simulation) |
| caught by postflight | 0 here, preflight stops first. the postflight read backs are proven on their own: `test_FIXED_postflightFailsOnEveryReadableMismatch`, `ReadsThePositionBack`, `ReadsTheSniperParamsBack` |
| launch passes every check, hash differs | 6, all values a rule cannot know: owner and creator swapped, owner is the deployer, owner equals creator, another start price (start tick and lower both -170000), another opening bid (1e12), a bounty of 9999 with the override flag on. `Deploy` refuses each of them because the hash differs from the signed one (asserted for every mutation) |
| benign | 1 (salt reuse: a second launch with the same config and salt is a new coin) |

**54 of 61 stopped by a rule, a revert or the postflight, 6 only by the hash, 1 benign.** before the fixes it was 14 slips of 51.


## 5 atomicity and partial failure (Part B item 6)

five transactions: controller, core, launch through the factory, `lockPoolExtension`, `updateAdmin`. every state below was built by hand in `test_partialStates` and read with postflight.

| failure point | state left on chain | exploitable or stuck | runbook recovery |
|---|---|---|---|
| tx 1 sent, nothing after | orphan controller, holds nothing | no | none needed. a rerun takes the new nonce, new addresses |
| tx 2 done, launch not done | orphan Core and controller. coin address has no code. Core balance 0, inert (`receive` ignores everyone but the hook). postflight fails `code: coin` | nobody can launch the predicted coin while the factory is deprecated (a watcher's launch reverted in the test). only the factory owner or an admin can. if the owner opens the factory, anyone can launch there with their own pool config and bind the Core to a dead coin (P-4) | none. says "new salt", which is wrong and unneeded. the right recovery is to retry the launch transaction by hand with the saved calldata, the Core is still valid (D-6) |
| launch done, lock not done | live pool, tradeable. token admin is the deployer, the extension slot is open (no extension is enabled on the factory, so inert). deployer can still call `setTaxBps` in [0, 2000]. postflight fails `coin: admin is owner` and `hook: extension slot locked and empty` | strangers cannot lock or move the admin (reverted in the test). risk is the deployer key only | none, commands in D-6 |
| lock done, handover not done | admin is the deployer. postflight fails `coin: admin is owner` | the owner cannot change tax or metadata until the handover. if the deployer key is lost the admin role is stuck for good (the Core is unaffected) | none, `updateAdmin` in D-6 |
| all five done, deployer not revoked | the deployer is still a factory admin and can set hooks, lockers, mev modules, claim team fees, and launch on a deprecated factory | postflight prints the info row "deployer still factory admin: yes, revoke it" and passes (D-10) | step 10 of the runbook, not gated |

front run while the factory is deprecated: who can launch the predicted coin is exactly the factory owner (0xCB43, an EOA with an EIP 7702 delegation) and every address in `admins` (none at the pin, plus the deployer once step 4 ran). a stranger reverts on `Deprecated`. what a watcher sees: the step 4 `setAdmin(deployer, true)` (public if sent publicly) reveals the deployer, so the Core address, the controller address and the coin address are computable before tx 1; the deployer's own transactions via a relay reveal the stack, rate, name, symbol, salt and owner to builders. a watcher can pre send eth to the predicted Core address (it books later through `skim`, harmless) and can prepare to trade in the launch block (the sniper skim covers that, 89.5 of 90 points go to the Core). nothing else. the factory owner can also change `deployFee` (up to 1 eth) between the simulation and tx 3, which makes tx 3 revert and orphans a Core. that is a trusted party, not a watcher.

what the simulation does and does not cover: `forge script` simulates all five transactions on a fork first, so any revert or failed check there stops before the first broadcast. the checks do not run on chain, they run in that simulation, so a state change between simulation and mining (fee change, factory opened, a reorg) is caught only by the individual transactions reverting or by running postflight afterwards (step 9). that is why step 9 must not be skipped. no step in the runbook says what to do when a transaction through the relay is pending or dropped (check `cast nonce`, do not rerun the script while a transaction is pending).

## 6 runbook walkthrough on an anvil fork (Part B item 7)

done literally on `anvil --fork-url $MAINNET_RPC_URL` (block 26130611): a copy of the config in `cache/run.json` (ignored by git) with owner, creator, name, symbol and salt filled, selected with `LAUNCH_CONFIG`; anvil account 0 as deployer; the factory owner impersonated with `anvil_impersonateAccount`.

| step | result |
|---|---|
| 2 rehearsal | `REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` passes (11 s). note it reads the tracked config, not `LAUNCH_CONFIG` (D-7) |
| 3 preflight, first run | 34 of 35 ok, only `factory: deployer may launch` fails, exit 1, as documented |
| 4 enable deployer | works with `--from $FOWNER --unlocked`. the runbook line has no signer flag and names `$PRIVATE_RPC`, ambiguous for the factory owner who is a different party. `$FACTORY` and `$DEPLOYER` are not defined anywhere in the runbook |
| 5 preflight, second run | 35 of 35, exit 0 |
| 6 dry run | works with `--sender`. runs preflight (35) and postflight (50) inside. forge prints "Estimated amount required 0.003 eth", which excludes the 0.069 eth fee sent as value |
| 7 broadcast | works on anvil with `--broadcast --slow --private-key`. on mainnet the rpc named in the runbook cannot serve forge (D-1). five transactions mined, the printed core, coin and controller match the prediction |
| 8 etherscan | `cast abi-encode "constructor(...)"` with the section 3 signature gives 706 hex characters, identical to the postflight printed args, and `cast decode-abi` returns the deployed owner, coin, controller, the seven stack members and 4e12. `forge verify-contract ... --show-standard-json-input` shows via IR, optimizer 200, cancun, `bytecodeHash` none, 24 sources. the on chain runtime equals the local build outside the immutable slots. the etherscan upload itself was not run (no key, fork chain) |
| 9 postflight | 51 of 51 with the info row, prints both constructor args |
| 10 revoke | works with `--from --unlocked`, again no signer flag in the runbook, `admins(deployer)` returns false, the info row turns to "no". missing: nothing makes the step mandatory |
| placeholders | default config on `Deploy.s.sol`: `ConfigUnset("owner")`. on `Preflight.s.sol`: `ChecksFailed("placeholders filled")`. they block |

runbook defects, collected:

1. step 7 rpc (D-1).
2. no recovery and wrong salt advice (D-6).
3. the tracked file is edited, `LAUNCH_CONFIG` is not mentioned, the rehearsal does not read it (D-7).
4. undefined shell variables in commands (`$FACTORY`, `$DEPLOYER`, `$PRIVATE_RPC`, `$OWNER`, `$COIN` and the others of section 3). list them once.
5. steps 4 and 10 give no signer flag for the factory owner. the owner is a 7702 delegated EOA, give the exact `cast send --ledger` or `--account` form.
6. "any failed check reverts before the broadcast is mined" (section 1 prose): precisely, forge simulates the whole script first and a failed check stops there, nothing is sent. nothing runs on chain.
7. section 0 "step 3" for the factory owner is step 4.
8. `PRIVATE_KEY` from `.env` (sourced in the first line of section 1) wins over `--ledger` and `--account` inside `Deploy.run` (D-10).
9. no instruction for a pending or dropped relay transaction.
10. the deployer funding is stated as gas only, "about 10.1M gas". the real need is in section 7.
11. housekeeping row on the token admin (D-8).

### 6b the runbook rerun on anvil after the fixes

`docs/DEPLOY.md` followed step by step from a clean shell (`env -i`, `.env` sourced, the section 0 variables exported) on `anvil --fork-url` at block 26131005, a local config `script/config/local.json` (gitignored) with throwaway addresses (anvil accounts 0 to 2), the factory owner impersonated where steps 4 and 10 say the owner acts (on mainnet that is `--ledger`).

| step | result |
|---|---|
| 1 local config | `cp` then edit, `git check-ignore` confirms it is ignored |
| 2 rehearsal | `REHEARSAL=1 LAUNCH_CONFIG=... forge test` passes, prints the file it rehearses and the same `CONFIG_HASH` as preflight. it first failed with an arithmetic panic in the smoke assertion I had rewritten (a uint24 times a literal), fixed |
| 3 preflight first run | 66 of 67, only `factory: deployer may launch` fails, exit 1, prints the sign off rows and `CONFIG_HASH=0xade7...c9dee` |
| 4 enable the deployer | works, `admins(deployer)` prints true |
| 5 preflight second run | 67 of 67, exit 0, same hash |
| 6 dry run | works with `CONFIG_HASH` exported. without it: `ConfigHashMismatch(0x00..., 0xade7...)` and nothing is signed |
| 7 broadcast | the literal command works. five transactions, core, coin and controller equal the dry run |
| 8 etherscan args | the section 3 `cast abi-encode` is 706 hex characters and equals the postflight print. the section 3 variables were undefined in the doc, now exported from the config there |
| 9 postflight | 60 of 60, including the position ticks (-887200 to 175000), the sniper read (90000 at 0 s), name, symbol, the hash row |
| 10 revoke | works. `REQUIRE_REVOKED=1` fails before the revoke and passes after |
| section 6 | three half deploys built by a temporary script (core only, launched, locked), each finished by `Resume.s.sol` (stage found 1, 2 and 3), postflight clean. the manual commands of the table were run too: the launch from the saved calldata, the lock, the handover, and resending the saved Core creation. a stale `CONFIG_HASH` makes postflight fail on the hash row, as intended |


## 7 gas and eth the deployer needs

real receipts of the anvil run (five transactions, as broadcast): controller 249,841; core 5,420,632; launch through the factory 4,179,587 (plus the 0.069 eth value); lock extension 56,387; update admin 29,015. **total 9,935,462 gas** (the rehearsal estimate was 10,087,774, DEPLOY.md says about 10.1M, a safe margin). the factory fee is read live (0.069 eth at the pin).

| gas price | gas cost | plus 0.069 fee | the deployer needs |
|---|---|---|---|
| 1 gwei | 0.00994 eth | 0.069 | 0.0789 eth |
| 5 gwei | 0.04968 eth | 0.069 | 0.1187 eth |
| 20 gwei | 0.19871 eth | 0.069 | 0.2677 eth |

the price is the effective price (base fee plus tip). preflight requires `fee + 11M * basefee * 2`: 0.091 eth at a 1 gwei base fee, 0.179 at 5, 0.509 at 20. a fresh key funded with 10 percent over the table covers a tip. the base fee at the time of this review was 0.12 gwei, so the actual cost today is about 0.07 eth. sweep the remainder when done.

## 8 secrets and hygiene (Part B item 9)

* `git log -p --all` (12 commits, one author) searched for keys, 32 byte hex that is not a hash or an address, rpc urls with tokens, `.env` and keystore files: none. the only urls are public rpc endpoints in `.env.example`. `git ls-files` shows `.env.example` only, no `.env`, `broadcast`, `cache` or `out`.
* `.gitignore` covers `out/`, `cache/`, `broadcast/`, `.env`. `check-ignore` confirms each. the broadcast folder from the anvil run is ignored, and `cache/Deploy.s.sol/.../run-latest.json` ("sensitive values saved") is ignored too.
* `foundry.toml` has `fs_permissions` read on `./`, so a forge script can read `.env` and anything under the repo. low risk for these scripts, but do not run third party scripts from this checkout.
* the committed config has the five placeholders at zero and empty. they block `Deploy` and `Preflight` (run above). the test fixtures added by this review (`test/data/ReviewMutatedToken.creation.hex`, `test/data/ReviewTruncated.json`) hold only a mutated public creation code and the public anvil test addresses.
* the runbook tells the operator to edit the tracked `script/config/mainnet.json`. use a gitignored local copy (D-7) so real values are never one `git add .` from a commit.

## 9 held items

* the Flashbots Protect failure (D-1) was measured from this sandbox through its proxy. it may differ on the owner's network. test with `cast code`.
* the etherscan upload and `forge verify-contract --watch` were not run. the arguments, compiler settings and runtime equality were.
* the real factory owner flow (a 7702 delegated EOA signing `setAdmin`) was impersonated, not signed.
* behavior of a pending or dropped transaction on a private relay was not tested.
* the correct `rateStart` is a market decision; the simulation the runbook cites is not in the repo and was not reviewed.
* artcoins internals beyond the verified interfaces (hook, factory, locker, mev module) were not audited. the review relies on the earlier REVIEW-hook and REVIEW-port documents for them.
* Core logic outside the last commit's delta was not re reviewed (REVIEW-core and REVIEW-port cover it). the full suite, including the invariants, passed with the review tests added.
* `sniperSeconds 86400` and similar factory limits were seen as reverts with unnamed selectors (0x35be3ac8, 0x58e593bb, 0xb7e8c5be); what each limit is was not decoded.
* after the fixes: the broadcast through `rpc.mevblocker.io` itself was not run (anvil only). its state reads were measured. the real factory owner signing with a ledger and a 7702 delegated EOA was impersonated. the stage detection of `Resume.s.sol` is proven on a fork and on anvil, not against a pending relay transaction.
* the matrix classes "caught by postflight" count 0 because preflight stops first. the postflight read backs are proven separately, not through the matrix.
* the sniper start and duration can be read back only inside the anti sniper window, after it only the end value is readable, the output says so.
