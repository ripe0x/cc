# handoff: credits engine, port to the artcoins v2 stack

for a session that takes this work over on a larger machine with both repos checked out. read this, then docs/FLOW.md section 10 (binding decisions), then docs/V2-PORT.md (analysis with file and line references, written without a build: verify its claims).

## 1. state of the repo

| item | state |
|---|---|
| branch | `flow` is the working branch. `main` on github was fast forwarded to `flow` at 3bc342d. everything after that is local to the previous session and comes in the git bundle |
| engine on the v1 stack | complete and tested: 856 tests pass on foundry 1.5.1, deep invariant suites pass, launch rehearsal passes, external audit findings A01 and A02 fixed |
| per transaction gas | measured in test/GasCap.t.sol against the 16,777,216 mainnet cap. compose is the largest call at 9.3 million (55 percent). a keeper must send compose with a gas limit above 10 million |
| Core size | 24,415 of 24,576 bytes, 161 bytes of headroom. there is almost no room |
| v2 port | decided, not built. section 3 |

## 2. decisions the owner made (all binding, see docs/FLOW.md sections 9 and 10)

| topic | decision |
|---|---|
| coin | name and symbol `CC`. owner and creator 0xCB43078C32423F5348Cab5885911C3B5faE217F9, which is also the artcoins factory owner |
| launch stack | artcoins v2 (ripe0x/artcoins branch v2, mirrored from the private working repo). the analysis was done at commit 87a7522. v2 is not on mainnet, its audit is pending, and it still changes: re read its DECISIONS.md and diff against 87a7522 before building |
| restriction | the coin launches `restricted` (v2 decision D73). no tax exists any more |
| fees | a `FeeRouter` contract is the bounty recipient. the Core books eth as fees when it arrives from the router. the router's engine is owner settable until a one way lock, so a later engine can take over the fees |
| lp fee income | through a v2 `FeeAutoSwapperV2` whose end recipient is the router |
| launch values | v2 factory defaults: engine share 9_000 of the skim, lp fee 3_000 pips, skim 10 points, anti sniper 90 to 10 points over 30 minutes if the v2 module allows |
| owner control | every setting, the controller, the exitModule and targets change at once, no timelock. three one way locks and a two step owner handover exist. the owner refused extra hard limits |
| statement sales | the controller prices: 110 percent of cost falling one point per 3 hours to 75 percent. auction mode at launch, buy only mode is a controller switch. hard floor 75 percent in the Core |
| not wanted | selling held credits as credits. hard limits on owner settings. a multisig requirement |

## 3. the port, in the order to build it

1. the v2 stack in the engine's tests. deploy v2 onto the pinned fork from v2's own build output (the engine cannot compile v2 source: solc 0.8.26 against 0.8.30 and a library version clash). vendor trimmed artifacts under test/v2-artifacts/ with the v2 commit recorded. mirror script/v2/DeployV2Lib.sol and script/v2/env/mainnet.env.
2. src/FeeRouter.sol (FLOW 10.2) and the one Core change (FLOW 10.3): `Stack.feeSource`, `receive()` books from it. keep at least 60 bytes of Core headroom, move code to CoreLib if needed.
3. script/Builder.sol and LaunchConfig for `DeploymentConfigV2` and `predictToken`. test/utils/Fixture.sol on the v2 stack. existing suites green.
4. Deploy, Checks, Preflight, Postflight, Resume and their tests (FLOW 10.4). docs/DEPLOY.md.
5. new tests: fee path through the router, restricted coin paths, lp income, engine migration by repointing the router, escrow credits. docs. simulator (9.0 share plus lp income).
6. an independent review, including the open audit question in section 5.

steps 1 to 3 and 5 can be done before v2 is live. the final signoff hash, the real addresses and the last full run need the deployed v2 stack.

advice from the previous session: v2 changed its whole tax model in one day. build steps 1 and 2 now (they depend only on how v2 pushes fees, which is stable), and hold step 4 until v2 is frozen for its audit tag, or it will be written twice.

## 4. how to work in this repo

| topic | rule |
|---|---|
| naming | the phase 2 contracts are referred to only as `exitModule` and `exitToken` in code, comments, tests, docs and commit messages. never name or describe them |
| tests | mainnet fork tests pinned to a block, real contracts only. the only doubles are test/standins and attacker contracts |
| toolchain | foundry 1.5.1, solc 0.8.30, via_ir, cancun. the suite is known to fail on foundry 1.8.1 (29 tests, not yet classified: gas meter assertions, library address assumptions, test linking). pin 1.5.1 or classify and fix |
| memory | one compile of the test tree with via_ir peaks above 6 gb and takes over 10 minutes on 2 cores. on a small machine never run two forge processes at once |
| rpc | public endpoints rate limit (429, 408). rerun a suite alone with `-j 1` before treating that as a failure. an archive endpoint of your own removes this |
| safety | no mainnet broadcast, no private key, without the owner's explicit instruction |
| speed | see section 6 |

## 5. open items

| item | detail |
|---|---|
| reimbursement cap, 1 wei | an external audit stress run on foundry 1.8.1 reported the compose and exit gas reimbursement above its cap by 1 wei. unknown whether the Core or the test mirror rounds wrongly. check the arithmetic in src/Core.sol and src/lib/CoreLib.sol |
| the 29 failures on foundry 1.8.1 | not reproduced to the end. rerun on the final code |
| exitModule gas | `exitStatement` forwards gas to a contract that does not exist yet. measure against the transaction gas cap when it does |
| v2 doc mismatches | docs/V2-PORT.md section 0.1 lists places where the v2 docs and the v2 source disagree. pass them to the v2 developer |
| launch day | `rateStart` is set from the market price of a credit on the day (docs/DEPLOY.md). it changes the signoff hash |

## 6. making the build loop fast (not yet tried here)

1. compile tests without via_ir. foundry supports per path compiler profiles (`additional_compiler_profiles` and `compilation_restrictions` in foundry.toml): keep via_ir for `src/**`, drop it for `test/**` and `script/**`. the fixture already deploys the system from artifacts, so tests mostly need interfaces. expect some test functions to hit stack too deep and need small edits.
2. turn on `dynamic_test_linking` so a change in src/ does not recompile every test.
3. with more than 8 gb, run independent work in parallel git worktrees (each has its own cache and out directory).
4. use a private archive rpc and raise `-j`.
