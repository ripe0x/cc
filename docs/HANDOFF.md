# handoff: credits engine

for a session that takes this work over. read this, then docs/NEXT.md (the open work list), then docs/FLOW.md sections 9 and 10 (binding decisions, 10.6 and 10.7 win), then docs/ARCHITECTURE.md and docs/DEPLOY.md.

## 1. state of the repo

| item | state |
|---|---|
| branch | `main` is the only branch, local and on github ripe0x/cc. every commit is pushed there. work on `main` or on short lived branches merged back into it |
| engine | ported to the artcoins v2 stack and tested: 1056 tests pass, 0 fail, 8 skipped (the Deep invariant suites), full run with REHEARSAL=1 on foundry 1.8.1 with isolate on, against the live v2 stack at fork block 26158000. the deep run below is from commit 6dd6805 and predates the v2 move. deep run (64 runs, depth 200) of the 7 Deep suites on 6dd6805: all clean after the hourly window followed inflows |
| contracts | `src/Core.sol` 24,064 bytes runtime (512 bytes of headroom under 24,576), `src/lib/CoreLib.sol` 16,967 (linked library, 7,609 bytes of room), `src/ControllerV1.sol` 4,445, `src/FeeRouter.sol` 4,446, `src/CoreLens.sol` 8,702 |
| v2 in tests | the live artcoins v2 stack (deployed 2026-10-09, blocks 26157195 to 26157222, from launcher commit fbe07c7 whose contract sources equal d4aa46b) at the addresses of script/config/v2-mainnet.json, attached by test/utils/V2Stack.sol on the fork at block 26158000. the factory owner 0xCB43 is the owner of every fixture, impersonated, and runs `setMinProtocolSkimShareBps(362)` in the fixture as step 3 of the runbook. no v2 contract is vendored |
| reviews | docs/REVIEW-*.md. the latest, REVIEW-v2port.md: one medium (a router flush inside a measured purchase) and one low (buyback sandwich above 2 eth), both fixed. an external audit (A01, A02) is fixed in the scripts |
| gas | every transaction fits the 16,777,216 mainnet cap (test/GasCap.t.sol). compose is the largest, 8.7 million. the caller of compose pays its own gas (the Core repays nothing, FLOW decision 41), so send it with a gas limit above 10 million |
| launch package | 9 transactions (the lens is one of them), 18.1 million gas measured by the rehearsal, signed by the v2 factory owner key. one factory owner command first: `setMinProtocolSkimShareBps(362)`. preflight refuses until it is done. steps after the broadcast: `Resume` sets the split start, the postflight passes, `Lock.s.sol` sends `coin.lockRecipients()`. `coin.lockAllowlist()` and `router.lock()` are owner decisions (docs/DEPLOY.md section 1) |
| simulator | sim/ models the v2 fee path. the headline table of docs/SIMULATION.md is current, the detail sections are labelled as the older run. published page: the owner's artifact "Credits Engine Simulator" |

## 2. what is built (all decided by the owner)

| topic | as built |
|---|---|
| coin | name and symbol `CC`. launched on artcoins v2 as a `restricted` coin (no wallet to wallet transfers), no transfer tax, the Core off the coin's allowlist (coin an allowlisted holder sends it is taken out with `rescueCoin`) |
| owner | 0xCB43078C32423F5348Cab5885911C3B5faE217F9: engine owner, creator, token admin, and the artcoins factory owner. the artcoins protocol is a separate business: never describe its revenue as the engine owner's income |
| trading fee | 6.9 percent skim in eth, no lp fee. anti sniper: 90 points falling to 6.9 over 30 minutes |
| fee path | pool, then `FeeRouter` (the pool's fee recipient: empty receive, `flush()` forwards), then the Core. the Core calls `flush` itself at the start of `sellForEth`, `buyListing`, `compose` and `composeExit` (FLOW 10.8), so no keeper is needed. the router pays one payee (the owner address, 0.75 points of volume, 112,778 ppm of the router inflow, to be repointed at the owner's own splitter), the rest to the engine. everything from the sniper window goes to the engine. the router's engine is owner settable until a one way lock, so a later engine can take over the fees |
| credits | bought at a flat bid per credit through two doors (`sellForEth`, `buyListing` on allowlisted targets). 80 make a statement. bid rule at launch: opens at the market price, each credit bought lowers it 0.5 percent (at most 20 percent per minute), it climbs 0.5 percent a minute while nobody sells, never above 125 percent of the last price paid, that ceiling loosens 2 percent per 10 idle minutes, never above rateCap (10 times the opening rate) and never above what the pot affords for one average credit. spend cap 100 percent of the pot per hour. every value is an owner setting. the owner reconsidered faster climbs on 2026-10-09 and kept 0.5 (docs/NEXT.md item 10) |
| statements | priced by the controller: 110 percent of cost falling one point every 3 hours to 75 percent. auction mode on the engine's own pnd auction house at launch, buy only mode is a controller switch. hard floor 75 percent in the Core |
| sale proceeds | 50 percent back to the pot, 50 percent buys and burns the coin, both adjustable |
| phase 2 | `exitModule` and `exitToken` placeholders. unsold statements redeem after 105 hours listed with no bid. module replaceable by the owner |
| owner control | every setting, the controller, the exitModule, targets, the router: changed at once, no timelock. four one way locks on the Core (the fourth closes `setSuccessor`), one on the router, two step owner handover on both. `rescueCoin` and `rescueNft` move stuck coin and stuck NFTs, `migrate` moves everything the Core tracks to the successor. the owner refused extra hard limits |

## 3. open work

docs/NEXT.md is the list: what the owner decided but is not built, what waits for his answer, and what the director still owes. docs/V2-REQUESTS.md is the list of changes wanted in the artcoins v2 repo, to be turned into a prompt for that session.

## 4. how to work in this repo

| topic | rule |
|---|---|
| naming | the phase 2 contracts are referred to only as `exitModule` and `exitToken` in code, comments, tests, docs and commit messages. never name or describe them |
| tests | mainnet fork tests pinned to a block, real contracts only (live ones, the v2 stack included). the only doubles are test/standins and attacker contracts |
| toolchain | foundry 1.8.1 (isolate on, the default since 1.8.0), solc 0.8.30. the suite is green on it with REHEARSAL=1: 1054 pass, 0 fail, 8 skipped (the deep invariant suites). deep runs: `INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract '^<Suite>Deep$'`, 375 to 475 s per suite |
| build | section 6. a clean build is about 4 minutes and 3 gb. the full suite is about 25 minutes: run it in the background and poll, or by path. after changing a production contract's external surface run `script/tools/gen-interfaces.sh` and repin test/BuildIdentity.t.sol |
| small machines | never run two forge processes at once on 8 gb. a sandbox that reclaims idle sessions kills background work: keep a foreground loop alive while agents run |
| rpc | public endpoints rate limit (429, 408). rerun a suite alone with `-j 1` before treating that as a failure |
| safety | no mainnet broadcast and no private key without the owner's explicit instruction |
| Core size | 512 bytes left, margin rule at least 60. new logic goes into `CoreLib`, which reads the Core's state through `CoreState` (docs/ARCHITECTURE.md section 1). never drop a check to make room |

## 5. things that are known and not fixed

| item | detail |
|---|---|
| exitModule gas | `exitStatement` forwards gas to a contract that does not exist yet. measure against the gas cap when it does |
| v2 live | the five stack addresses are in script/config/mainnet.json and preflight pins the `extcodehash` of nine live v2 contracts (read at block 26158000), `STACK_VERSION` 2 and the constants hash. the owner address 0xCB43 is an EIP 7702 delegated EOA with 0.068 eth at block 26158000: the launch needs 0.069 eth for the deploy fee plus gas, so preflight fails the balance row until it is funded. the v2 audit is pending |
| owner step on the v2 factory before launch | lower the minimum protocol skim share to 362 (`setMinProtocolSkimShareBps(362)`). preflight names it. the factory accepts the launch lp fee of 0 because the baseline skim is above 0 |
| owner power over the fee stream | two switches. the coin admin (the owner) repoints the hook bounty recipient and the creator reward slot recipient until `coin.lockRecipients()`, a launch step (`Lock.s.sol`, NEXT item 18), which freezes both. the router owner points the router at another engine with `setEngine` until `router.lock()`, an owner decision (NEXT item 19). postflight warns until the recipients are locked and fails after `RECIPIENTS_LOCKED=1` |
| fees per 100 eth of volume as built | skim 6.9 eth. protocol 0.24978 (`bountyBps` 9,638 leaves it 362 of 10,000), router 6.65022, of which payee 0.7499985 (112,778 ppm), engine 5.9002215 (the three legs sum to 6.9). inside the anti sniper window the payee share is 0 and the engine receives the router inflow. at comparable volume (1,961 eth in 90 days, the first 30 minutes of fees to the engine) the payee receives about 12 eth |
| owner powers over assets | `migrate` moves the eth pots, exit token pots and credits to the successor with no delay, until `lockSuccessor()` (the held statements stay in the Core and are sold out there); `rescueNft` takes stuck NFTs out; `rescueCoin` takes out coin that an allowlisted holder sent to the Core. the successor is unset at launch and the lock is a later decision. a stolen owner key can move the whole engine at once: use a multisig, watch `SuccessorSet` and `Migrated` (docs/ARCHITECTURE.md section 10, FLOW 10.10) |
| pricing rule | the bid drops only in proportion to the share of the pot spent, so it follows a falling market badly. NEXT item 10 |

## 6. the build loop (done)

per path compiler profiles are in foundry.toml: the default profile has no via_ir, a second profile (via_ir, 200 runs, cancun, no metadata hash) is forced on `src/[A-Z]*.sol` and `src/lib/CoreLib.sol`, and foundry pulls any file that imports them onto it. tests and scripts therefore use the generated interfaces and deploy from artifacts (`test/utils/Prod.sol`); `dynamic_test_linking` is on and works on 1.5.1. measured: clean build 226 s and 2.9 gb, a test file change 3 s, a `src/Core.sol` change 34 s. the whole suite (except Rehearsal) still takes about 25 minutes (the four invariant suites alone are about 12), so run it by path in batches of under 10 minutes per call. a private archive rpc and a larger `-j` are the remaining levers; with more than 8 gb, independent work can use parallel git worktrees (each has its own cache and out directory).
