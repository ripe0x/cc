# handoff: credits engine

for a session that takes this work over. read this, then docs/NEXT.md (the open work list), then docs/FLOW.md sections 9 and 10 (binding decisions, 10.6 and 10.7 win), then docs/ARCHITECTURE.md and docs/DEPLOY.md.

## 1. state of the repo

| item | state |
|---|---|
| branch | `main` is the only branch, local and on github ripe0x/cc. every commit is pushed there. work on `main` or on short lived branches merged back into it |
| engine | ported to the artcoins v2 stack and tested: 918 tests pass, 9 skipped, with the launch rehearsal on (full run on foundry 1.8.1, isolate on, commit 5f61f2c) |
| contracts | `src/Core.sol` 24,462 bytes runtime (114 bytes of headroom under 24,576), `src/lib/CoreLib.sol` 11,751 (linked library, lots of room), `src/ControllerV1.sol` 4,464, `src/FeeRouter.sol` 5,043 |
| v2 in tests | the real artcoins v2 contracts (v2 commit 87a7522, the owner says final, not deployed on mainnet) are deployed onto the pinned fork from vendored build output in test/v2-artifacts/ by test/utils/V2Stack.sol |
| reviews | docs/REVIEW-*.md. the latest, REVIEW-v2port.md: one medium (a router flush inside a measured purchase) and one low (buyback sandwich above 2 eth), both fixed. an external audit (A01, A02) is fixed in the scripts |
| gas | every transaction fits the 16,777,216 mainnet cap (test/GasCap.t.sol). compose is the largest, 9.3 million. a keeper must send compose with a gas limit above 10 million |
| launch package | 9 transactions, about 14.5 million gas, signed by the v2 factory owner key. 98 preflight rows, 87 postflight rows, a mutation matrix of 283 config changes with 0 slips |
| simulator | sim/ models the v2 fee path. the headline table of docs/SIMULATION.md is current, the detail sections are labelled as the older run. published page: the owner's artifact "Credits Engine Simulator" |

## 2. what is built (all decided by the owner)

| topic | as built |
|---|---|
| coin | name and symbol `CC`. launched on artcoins v2 as a `restricted` coin (no wallet to wallet transfers), no transfer tax, the Core on the coin's allowlist |
| owner | 0xCB43078C32423F5348Cab5885911C3B5faE217F9: engine owner, creator, token admin, and the artcoins factory owner. the artcoins protocol is a separate business: never describe its revenue as the engine owner's income |
| trading fee | 6.9 percent skim in eth, no lp fee. anti sniper: 90 points falling to 6.9 over 30 minutes |
| fee path | pool, then `FeeRouter` (the pool's fee recipient: empty receive, `flush(tipTo)` forwards), then the Core. the Core calls `flush` itself at the start of `sellForEth`, `buyListing`, `compose` and `composeExit` (FLOW 10.8), so no keeper is needed. the router pays one payee (the owner address, 1.0 point of volume, to be repointed at the owner's own splitter), a flush tip (0.5 percent, capped 0.005 eth), the rest to the engine. everything from the sniper window goes to the engine. the router's engine is owner settable until a one way lock, so a later engine can take over the fees |
| credits | bought at a flat bid per credit through two doors (`sellForEth`, `buyListing` on allowlisted targets). 80 make a statement |
| statements | priced by the controller: 110 percent of cost falling one point every 3 hours to 75 percent. auction mode on the engine's own pnd auction house at launch, buy only mode is a controller switch. hard floor 75 percent in the Core |
| sale proceeds | 50 percent back to the pot, 50 percent buys and burns the coin, both adjustable |
| phase 2 | `exitModule` and `exitToken` placeholders. unsold statements redeem after 105 hours listed with no bid. module replaceable by the owner |
| owner control | every setting, the controller, the exitModule, targets, the router: changed at once, no timelock. three one way locks on the Core, one on the router, two step owner handover on both. `rescueCoin` moves stuck coin. the owner refused extra hard limits |

## 3. open work

docs/NEXT.md is the list: what the owner decided but is not built, what waits for his answer, and what the director still owes. docs/V2-REQUESTS.md is the list of changes wanted in the artcoins v2 repo, to be turned into a prompt for that session.

## 4. how to work in this repo

| topic | rule |
|---|---|
| naming | the phase 2 contracts are referred to only as `exitModule` and `exitToken` in code, comments, tests, docs and commit messages. never name or describe them |
| tests | mainnet fork tests pinned to a block, real contracts only (live ones, and v2 from its vendored build output). the only doubles are test/standins and attacker contracts |
| toolchain | foundry 1.8.1 (isolate on, the default since 1.8.0), solc 0.8.30. the suite is green on it: 918 pass, 0 fail, 9 skipped (the deep invariant suites) of 927 tests |
| build | section 6. a clean build is about 4 minutes and 3 gb. the full suite is about 25 minutes: run it in the background and poll, or by path. after changing a production contract's external surface run `script/tools/gen-interfaces.sh` and repin test/BuildIdentity.t.sol |
| small machines | never run two forge processes at once on 8 gb. a sandbox that reclaims idle sessions kills background work: keep a foreground loop alive while agents run |
| rpc | public endpoints rate limit (429, 408). rerun a suite alone with `-j 1` before treating that as a failure |
| safety | no mainnet broadcast and no private key without the owner's explicit instruction |
| Core size | 75 bytes left. new logic goes into `CoreLib`. never drop a check to make room |

## 5. things that are known and not fixed

| item | detail |
|---|---|
| loosened test | `test_everyActionSucceeds` under the hostile controller needed its compose tries raised from 80 to 300 after the review fixes. the cause was not proven |
| exitModule gas | `exitStatement` forwards gas to a contract that does not exist yet. measure against the gas cap when it does |
| v2 not live | five v2 addresses in script/config/mainnet.json are placeholders. the real preflight, the signoff hash and a comparison of the live v2 bytecode against test/v2-artifacts wait for the v2 deployment |
| owner steps on the v2 factory before launch | set the minimum lp fee to 0. (and lower the minimum protocol skim share once NEXT item 2 is built) |
| pricing rule | the bid drops only in proportion to the share of the pot spent, so it follows a falling market badly. NEXT item 10 |

## 6. the build loop (done)

per path compiler profiles are in foundry.toml: the default profile has no via_ir, a second profile (via_ir, 200 runs, cancun, no metadata hash) is forced on `src/[A-Z]*.sol` and `src/lib/CoreLib.sol`, and foundry pulls any file that imports them onto it. tests and scripts therefore use the generated interfaces and deploy from artifacts (`test/utils/Prod.sol`); `dynamic_test_linking` is on and works on 1.5.1. measured: clean build 226 s and 2.9 gb, a test file change 3 s, a `src/Core.sol` change 34 s. the whole suite (except Rehearsal) still takes about 25 minutes (the four invariant suites alone are about 12), so run it by path in batches of under 10 minutes per call. a private archive rpc and a larger `-j` are the remaining levers; with more than 8 gb, independent work can use parallel git worktrees (each has its own cache and out directory).
