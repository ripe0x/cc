# deploy runbook

this is the launch runbook for branch `flow`. the system launches on whichever artcoins version is current at deploy time. everything that depends on the artcoins version lives in the `stack` block of `script/config/mainnet.json`, the Core takes it as a constructor argument and nothing in `src/` hardcodes an artcoins address.

naming rule: only `exitModule` and `exitToken`. never name or describe them anywhere.

## 0. what you need

| item | note |
|---|---|
| deployer key | a fresh key that only does this launch, in `PRIVATE_KEY` (or use `--account` or `--ledger` on the commands that sign). it needs the factory deploy fee (0.069 eth at the pin, read live) plus gas for six transactions (the library, the controller, the core, the launch, the lock and the handover), about 12.29M gas measured by the rehearsal on a fork (library 1.84M, controller 0.25M, core 5.85M with the house creation inside it, launch 4.26M, lock 0.05M, handover 0.03M). with the 0.069 eth factory fee that is 0.081 eth at 1 gwei, 0.130 at 5 gwei, 0.315 at 20 gwei (the gas alone: 0.012, 0.061, 0.246). the rehearsal prints this table for the latest block, step 2. preflight requires the fee plus 13.5M gas at twice the base fee, so fund the key with about 20 percent over the table |
| read rpc | any archive capable mainnet rpc, in `MAINNET_RPC_URL`. used by every command that does not send |
| private rpc | `PRIVATE_RPC`, a relay that does not publish to the public mempool and still serves state reads. use `https://rpc.mevblocker.io`. `forge script --broadcast` forks the rpc it sends through, so it needs `eth_getCode`, `eth_getStorageAt` and `eth_call`, and the Flashbots Protect endpoint (`rpc.flashbots.net/fast`) does not serve them (504 on `eth_getCode`, 403 "rpc method is not whitelisted" on `eth_call`, measured 2026 10 05). see the rpc test right below |
| etherscan key | `ETHERSCAN_API_KEY`, for verification |
| the factory owner | the artcoins factory owner (0xCB43078C32423F5348Cab5885911C3B5faE217F9 for the live stack) must enable the deployer, step 4, and revoke it, step 10. it is a different party with its own signer. it signs with `--ledger` or `--account <name>`, never with a key typed into the shell |

shell variables used below. set them once, in the same shell, after `set -a; . ./.env; set +a`:

```sh
export PRIVATE_RPC=https://rpc.mevblocker.io
export LAUNCH_CONFIG=script/config/local.json   # step 1, gitignored
export FACTORY=0x49596c375c139E79bb937bcf826068a8F78D4e0e   # stack.factory of the config
export FACTORY_OWNER=0xCB43078C32423F5348Cab5885911C3B5faE217F9
export DEPLOYER=0xYourDeployerAddress           # the address of PRIVATE_KEY. Deploy and Resume refuse to run when the signer is another address
export OWNER=$(jq -r .owner $LAUNCH_CONFIG)     # after step 1
# set later: CONFIG_HASH (step 3), CORE, COIN, CONTROLLER, LIB (step 7)
```

the signer of `Deploy` and `Resume` comes from the command line flags only (`--private-key $PRIVATE_KEY`, `--account`, `--ledger`). no environment variable picks a signer, so a stray `PRIVATE_KEY` in `.env` cannot override a ledger.

secrets are read from the environment only: `PRIVATE_KEY` (only to pass it to `--private-key`) and `ETHERSCAN_API_KEY`. everything else is in the config file.

### test the private rpc first (before step 7)

```sh
cast code $FACTORY --rpc-url $PRIVATE_RPC | head -c 20            # must print 0x6080..., not an error
cast call $FACTORY "deprecated()(bool)" --rpc-url $PRIVATE_RPC     # must print true
```

both must answer. if either errors (a 5xx, "not whitelisted", a timeout), that rpc cannot carry step 7. the fallback is a normal rpc for step 7, with the exposure below. never improvise a third option on launch day (a relay that cannot serve state reads stalls the script after the core exists).

why the fallback is acceptable. while the factory is deprecated, `deployTokenWithProtocolBpsAndTax` reverts `Deprecated` for everyone except the factory owner and addresses it enabled with `setAdmin`. nobody watching the public mempool can launch to the predicted coin address, so the private relay protects secrecy, not safety. what stays exposed on a normal rpc:

| exposure | effect | why it is acceptable |
|---|---|---|
| builders and watchers read the config from the transactions (name, symbol, salt, owner, rate) before they mine | the launch is not secret. a watcher can prepare to trade in the launch block | the anti sniper skim sends 89.5 of the 90 points of a launch block buy to the Core, so being first costs the buyer |
| step 4 `setAdmin(deployer, true)` is public on any rpc | the deployer address is known, so the Core, controller and coin addresses are computable before step 7 | they can only pre send eth to the predicted Core, which books later through `skim` and is harmless |
| the factory owner opens the factory (`setDeprecated(false)`) while step 7 is pending | anyone could launch to the predicted coin with their own pool config and bind our Core to a dead coin (finding P-4 of docs/REVIEW-port.md) | the owner is the trusted party that runs step 4. the cost is the gas and one orphaned Core, not funds at risk. the script re-runs preflight right before the broadcast and fails on an open factory (`factory: deprecated`), and step 9 must not be skipped |
| the factory owner changes `deployFee` (up to 1 eth) between the simulation and the launch transaction | the launch transaction reverts and a Core is orphaned | a trusted party, recovery is section 6 |

## 1. commands in order

all commands run from the repo root after `set -a; . ./.env; set +a` and the variables of section 0. read rpc commands use `$MAINNET_RPC_URL`, the one broadcast uses `$PRIVATE_RPC`.

| step | action | command or owner |
|---|---|---|
| 1 | local config | `cp script/config/mainnet.json script/config/local.json` (gitignored, never edit the tracked file). edit `local.json`: `owner`, `creator`, `name`, `symbol`, `salt`, and `rateStart` by the launch day rule below. the `settings` block holds the launch values of every economic setting, review it row by row (section 2). `export LAUNCH_CONFIG=script/config/local.json`. review every row of the sign off tables in section 2 |
| 2 | rehearse the exact file on the latest block | `REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv`. it reads `LAUNCH_CONFIG`, fills only the placeholders the file leaves unset, and runs preflight, the whole deploy (the library included), postflight and a trading smoke. it prints the gas of each of the six transactions and the eth the deployer needs at 1, 5 and 20 gwei |
| 3 | preflight, first run, and the sign off | `DEPLOYER=$DEPLOYER forge script script/Preflight.s.sol --rpc-url $MAINNET_RPC_URL`. it knows the library takes the first deployer nonce when it is not on chain yet, so the predicted controller, core and coin are the ones the deploy will create. the only failure allowed is `factory: deployer may launch`, until the factory owner acts. read the `signoff:` rows, the owner signs them, then `export CONFIG_HASH=0x...` with the printed `CONFIG_HASH=` value. that one value stands for the whole config |
| 4 | the factory owner enables the deployer | from the factory owner, `cast send $FACTORY "setAdmin(address,bool)" $DEPLOYER true --rpc-url $MAINNET_RPC_URL --ledger` (or `--account <name>`). keep the factory `deprecated`. confirm: `cast call $FACTORY "admins(address)(bool)" $DEPLOYER --rpc-url $MAINNET_RPC_URL` prints true |
| 5 | preflight, second run | the same command as step 3. it must print every row ok and exit 0, and print the same `CONFIG_HASH` |
| 6 | dry run | `DEPLOYER=$DEPLOYER forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --sender $DEPLOYER`. needs `CONFIG_HASH` and `DEPLOYER` in the env (`DEPLOYER` must be the sender, the script refuses another signer). simulates all six transactions (the library first) and runs preflight and postflight inside the script. nothing is sent. forge prints "Estimated amount required", which excludes the factory fee sent as value, add the fee from the `factory: deployer balance` row |
| 7 | broadcast through the private rpc | after the rpc test of section 0: `forge script script/Deploy.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --private-key $PRIVATE_KEY`. note the printed core, coin and controller addresses and `export CORE=... COIN=... CONTROLLER=...`, and `export LIB=$(jq -r '.libraries[0]' broadcast/Deploy.s.sol/1/run-latest.json | cut -d: -f3)`. if anything stops half way, do not rerun, go to section 6 |
| 8 | verify on etherscan | section 3 |
| 9 | postflight | `CORE=$CORE DEPLOYER=$DEPLOYER forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. every row must be ok. it prints the constructor args and the config hash, which must be the signed `CONFIG_HASH` (set it in the env to have the script check it). run it inside the anti sniper window if you can: the skim readback of the sniper start and duration works only then |
| 10 | the factory owner revokes the deployer | from the factory owner, `cast send $FACTORY "setAdmin(address,bool)" $DEPLOYER false --rpc-url $MAINNET_RPC_URL --ledger`. an admin can also set hooks, lockers and mev modules and claim team fees, so do this right after postflight. then `REQUIRE_REVOKED=1 CORE=$CORE DEPLOYER=$DEPLOYER forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL` must pass: the row `deployer still factory admin` fails until the revoke is done |
| 11 | first actions after launch | section 4 |

rehearsing the whole runbook on a local fork (anvil), with a throwaway key and throwaway owner and creator in `local.json`. the same commands, with three differences: the rpc urls point at the fork (`anvil --fork-url $MAINNET_RPC_URL --chain-id 1 --port 8546`, then `export MAINNET_RPC_URL=http://127.0.0.1:8546 PRIVATE_RPC=http://127.0.0.1:8546`), the deployer is an unfunded key that you fund (`cast rpc anvil_setBalance $DEPLOYER 0x56BC75E2D63100000`), and the factory owner is impersonated instead of signing: step 4 is `cast rpc anvil_impersonateAccount $FACTORY_OWNER` then `cast rpc anvil_setBalance $FACTORY_OWNER 0x56BC75E2D63100000` then `cast send $FACTORY "setAdmin(address,bool)" $DEPLOYER true --rpc-url $MAINNET_RPC_URL --unlocked --from $FACTORY_OWNER`, and step 10 the same with `false`. a fork of a recent block carries the live factory state, so the factory is deprecated and the deterministic deployer exists. walked from a clean shell: preflight (only `factory: deployer may launch` fails), enable, preflight (all ok, same hash), dry run, broadcast (six transactions, the library first), postflight (72 of 72), `Resume` (stage 4, no op), revoke, postflight with `REQUIRE_REVOKED=1`.

the launch day rule for `rateStart`. `rateStart = 0.75 * (market price of one credit in wei) * 1e4 / avgScore`, where `avgScore` is the settings value (4,330,000 at launch), bounded to [1e11, 1e15] by the Core. the opening limit is about 75 percent of the market price of a credit, and the bid is flat per credit (`flatBps` 10,000), so one credit costs `rate * avgScore / 1e4` wei at the start. the default 1.54e13 is for a market price of 0.0089 eth (8.9e15 wei: 0.75 * 8.9e15 * 1e4 / 4.33e6 = 1.54e13). the market price is the median of the last 24 hours of paid sales. never open above the market price. one line to read a recent median from the chain, from any rpc that serves logs (`$PRIVATE_RPC` does), it samples the last 60 transactions that moved a Credit and prints the median of the nonzero eth values they carried in wei:

```sh
H=$(cast block-number --rpc-url $MAINNET_RPC_URL); cast logs --rpc-url $PRIVATE_RPC --address 0x97630aA70AB14ed9883B41dAfccBc11349723043 --from-block $((H-7200)) "Transfer(address,address,uint256)" --json | jq -r '[.[].transactionHash] | unique | .[-60:] | .[]' | while read t; do cast tx $t value --rpc-url $PRIVATE_RPC; done | grep -v '^0$' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
```

the reader needs a node that serves `eth_getLogs` over 7200 blocks: `$PRIVATE_RPC` (mevblocker) does, the free drpc tier rejects the range, then lower the `7200`. then the rule, in one line, with `M` the median in wei (the example gives 1.836e13 for 0.0106 eth):

```sh
M=10600000000000000; awk -v m=$M -v a=$(jq .settings.avgScore $LAUNCH_CONFIG) 'BEGIN{printf "%.0f\n", 0.75*m*1e4/a}'   # the value for rateStart in the config
```

the explorer way: open the Credits collection on OpenSea, Activity, filter Sales, look at the last 24 hours and take the median price. apply the rule above, round, put it in `rateStart`. the value only decides how soon the pot starts working (a higher limit buys the first credits sooner). the owner can move it after the launch with `setRate` (section 4), so a wrong guess is cheap to fix.

what the scripts do.

| script | does |
|---|---|
| `Preflight.s.sol` | read only. chain id 1, the pinned rules of section 2 (ticks, skim, sniper, tax, owner and creator), code at every stack address including the pnd auction factory, the stack cross checks (the hook reports the pool manager, factory and escrow, the locker reports the factory and position manager), hook, locker and mev module enabled on the factory, the factory deprecated, factory owner as configured, whether the deployer may launch, live `deployFee()` and the deployer balance against fee plus gas, predicted controller, core and coin addresses with no code at any of them, the coin prediction inputs, code at the deterministic deployer and the library row (the CREATE2 address of `CoreLib`, absent or the compiled code), the auction factory default fee is 0 (a loud WARN row otherwise: the fee is an immutable of the factory, the house of the Core would charge it, and postflight FAILs the house fee row, so the deploy simulation stops after the transactions ran and before the broadcast, there is no override: the fee cannot change, so either launch against another auction factory, which is a new `stack.auctionFactory` and a new `CONFIG_HASH`, or do not launch) and no auction house exists yet for the predicted core, Credits, Statements and CreditScore sanity, code at CreditStrategy, Seaport, Permit2, position manager and universal router, placeholders filled, `rateStart` in bounds, every field of `settings` against its bound (the rows print the bound and the value), supply equal to the Core constant. then the `signoff:` rows (one per setting) and the `CONFIG_HASH`. prints a table, reverts with the failed names. WARN rows (owner equals creator, owner or creator equals the deployer, a nonzero house fee) never fail |
| `Deploy.s.sol` | refuses to run while `owner`, `creator`, `name`, `symbol` or `salt` is unset, `rateStart` or a setting is out of bounds, or `CONFIG_HASH` is not the hash of the loaded config (the hash covers the settings). runs preflight, then predicts, deploys the library `CoreLib`, ControllerV1 and Core (the Core constructor needs code at the hook, pool manager, factory, locker, escrow and auction factory, creates its own auction house through the factory, approves it on Statements and stores the settings), launches through the factory and asserts the coin equals the prediction, locks the pool extension slot, hands the token admin role to `owner`, then runs postflight |
| `Postflight.s.sol` | read only. reads the deployed system back and compares it with the config: core immutables (owner, `RATE_START`, the stack including `AUCTION_FACTORY`), the linked library (the address inside the core runtime is code equal to the compiled `CoreLib`), the auction house (`HOUSE()` is the house the factory records for the core, its owner is the core, its fee is 0, the core has approved it for all on Statements), `settings()` equal to the config settings field by field, controller, allowed targets, coin name, symbol and supply and that it sits in the pool, pool key and id, start tick, the launch position ticks through the position manager, skim config on the hook (baseline, bounty, referral cap, lp fee, recipients), the sniper start, end and duration through the mev module, tax config on the token, core tax exempt, token admin equals owner, extension slot locked, locker reward slot, `ethRate` equals `rateStart`, code at the stack. prints the table, a row `not readable on chain` for what no getter exposes (the protocolBps argument, the sniper fee config, token image and metadata, locker data, the deploy fee paid, the salt itself which the coin address check binds), the config hash and the constructor args, reverts on any mismatch. supply, rate and start tick rows are exact only until the first trade or fill, afterwards they turn tolerant. the settings row is exact only until the owner calls `setSettings`. the sniper start and duration are readable only inside the window (30 minutes by default), after it only the end value is |
| `Resume.s.sol` | finishes a deploy that stopped half way. section 6 |

the six transactions are the library, controller, core, launch through the factory, `lockPoolExtension` and `updateAdmin`. the library is a contract the Core links against (`src/lib/CoreLib.sol`). forge deploys it by CREATE2 through the deterministic deployer (0x4e59b44847b379578588920ca78fbf26c0b4956c, present on mainnet), but as a transaction sent from the deployer, so it takes one deployer nonce when the library is not on chain yet: the library is nonce n, the controller n+1, the core n+2 (measured on a fork, the broadcast lists CoreLib, ControllerV1, Core, then the three calls). preflight and the dry run know this and predict the controller, core, coin and house for n+1 and n+2. if the library already exists (a rerun, or a second deploy) forge skips it and the controller takes n. the Core address is a function of the deployer and its nonce only (CREATE), it does not depend on the library address. the library address depends only on its creation code: `cast create2 --deployer 0x4e59b44847b379578588920ca78fbf26c0b4956c --salt 0x00 --init-code $(forge inspect src/lib/CoreLib.sol:CoreLib bytecode)` (preflight prints it in the row `library: CoreLib at its create2 address is the compiled code or absent`). two cases need no action. the library is already deployed: the preflight row says so, the deploy sends five transactions, nothing else changes. the library address holds different code: impossible, the address is the hash of the creation code, a hand made contract at that address would FAIL the same row, and nothing would be sent. `forge script` simulates all six on a fork first, so a failed check or a revert in the simulation stops the script before anything is sent. nothing of the checks runs on chain: a change between the simulation and the mining (the factory fee, the factory opened) is caught only by a transaction reverting or by step 9, which is why step 9 is not optional. while the factory is deprecated only its owner and marked admins can launch, so nobody can copy the launch to the predicted coin address. never rerun `Deploy` after it stopped: a rerun takes a new nonce, so it deploys a second Core (preflight cannot tell, a second system is a valid launch). check `cast nonce $DEPLOYER --rpc-url $MAINNET_RPC_URL` and `cast tx` for any pending transaction first, a transaction pending in the relay can still land.

### what the scripts refuse, the config mutation matrix

`test/ReviewMatrix.t.sol` mutates the signed config one change at a time (every stack address, every launch field, every settings field at its bounds and at plausible wrong values, owner, creator and deployer swaps, the salt, `rateStart`, the token creation code file, the library missing or with other code, 13 chain state cases) and records which layer stops it. the result is 206 mutations: 116 stopped by preflight, 4 reverting safely in the deploy, 2 caught by postflight, 84 change only the config hash (the hash sign off is what stops them: a changed value that stays inside every bound is a different launch, not an error), 0 slip. a swapped deployer is a safe revert (`DeployerMismatch`). when you change anything in the file after step 3, the hash changes, so you notice at step 5.

## 2. parameter sign off table

constants of the Core (compiled in, not configurable). the owner signs off each row. every economic number is a setting, see the next table.

| constant | value | meaning |
|---|---|---|
| `SUPPLY` | 1,000,000,000e18 | coin supply the exit auction is priced against. must equal the launch supply |
| `RATE_START_MIN_WEI`, `RATE_START_MAX_WEI` | 1e11, 1e15 | bounds of the constructor argument `rateStart` and of `setRate`, wei per whole point. defined once in `src/interfaces/Interfaces.sol`, shared by the Core and the scripts, no getter on the Core |
| `XRATE_START` | 6000 | opening exit token bid in bps of score, phase 2, clamped into the settings cap and floor at construction |
| `TIMELOCK` | 7 days | controller, exitModule and allowed target changes |
| `OVERPRINT_CAP_PER_DAY` | 8 | overprints per day |
| the pnd auction house | one house, created by the Core in its constructor through `stack.auctionFactory`, owned by the Core for ever, fee 0 | statements are listed on it, bidders use it directly. the address is `HOUSE()` |
| allowed targets at deploy | Seaport 1.6, CreditStrategy | `buyListing` targets. more only by timelock |
| forbidden targets | Credits, Statements, Core, coin, hook, pool manager, factory, locker, escrow, Permit2, position manager, universal router, exitModule, exitToken, the auction house, the auction factory | checked on add and at call time. the stack members come from the config |

the skim split (9.5 points of a 10 point skim to the engine, 0.5 to the creator) is fixed inside the artcoins pool at launch and cannot be made adjustable by this system.

settings. one struct, `Settings`, in Core storage, in the config file under `settings`, inside `CONFIG_HASH`. the owner changes any of them after the launch with `setSettings(Settings)` (all at once, effective at once, after a checkpoint of the eth rate and the exit rate; the whole struct is emitted in `SettingsSet`) and reads them with `settings()`. the Core rejects a value outside the bounds, and preflight rejects it first. the bounds exist to stop typos and to keep the owner from transferring assets out (tips, reimbursements and keeper rewards are capped). they do not bound the price the owner sets for credits: see the owner section of docs/ARCHITECTURE.md. postflight reads every field back. the owner signs off each row. the field order is the struct order.

| key | launch | bounds | meaning | adjustable after launch |
|---|---|---|---|---|
| `flatBps` | 10000 | 0 to 10000 | share of the bid that is flat per credit. price = rate * (flatBps * avgScore + (10000 - flatBps) * score) / 10000 / 1e4, before the controller bonus. at 10000 the score contract is not read on the eth doors | yes |
| `avgScore` | 4330000 | 800000 to 6000000 | the score a flat credit is priced as, and the average credit of the funded rule | yes |
| `climbBaseBps` | 100 | 0 to 1000 | rate climb per hour in the first period since the last fill | yes |
| `climbDoubleEvery` | 86400 | 3600 to 2592000 s | the climb doubles every period without a fill | yes |
| `climbMaxBps` | 800 | `climbBaseBps` to 2000 | top climb per hour | yes |
| `dropBps` | 2000 | 500 to 5000 | a fill of `x` from pot `p` drops the rate by `rate * dropBps / 10000 * min(x, p) / p` | yes |
| `spendCapBps` | 2000 | 100 to 5000 | hourly spend cap, share of the pot at the window open. also the funded threshold and the climb clamp | yes |
| `bonusCapBps` | 2500 | 0 to 5000 | largest controller bonus on a ceiling | yes |
| `tipSavingsBps`, `tipCapBps` | 1000, 200 | 0 to 2500, 0 to 500 | `buyListing` keeper tip, share of savings capped at a share of cost | yes |
| `reimburseBps`, `reimburseCapBps` | 11000, 500 | 0 to 15000, 0 to 1000 | gas reimbursement for compose, share of gas cost capped at a share of statement cost | yes |
| `reserveBps` | 9000 | 3000 to 40000 | auction reserve as bps of the statement cost. 9000 sells at no less than 90 percent of cost. the low bound of 30 percent means a bad setting can sell a statement for 30 percent of its cost (with the 6 hour auction minimum a stranger has time to bid over it), which is why the settings are owner only and public in `SettingsSet`. a raised value does not reach listings that have no bid yet until `repriceStatement` runs on each (see changing settings after launch) | yes |
| `auctionDuration` | 86400 | 21600 to 2592000 s | statement auction length, runs from the first bid | yes |
| `exitAfter` | 259200 | 3600 to 31536000 s | how long an eth lane statement must have been listed without a bid before it may be redeemed in phase 2 | yes |
| `saleToBuybackBps` | 5000 | 0 to 10000 | share of sale proceeds to the coin buyback pot, the rest to the credit pot | yes |
| `exitToBuybackBps` | 5000 | 0 to 10000 | share of exit token from an eth lane exit to the buyback pot | yes |
| `buybackSlice`, `buybackDelay`, `keeperTipBps` | 1 eth, 25 blocks, 50 | 0.01 to 5 eth, 1 to 7200, 0 to 500 | coin buyback slice, minimum block gap, caller tip in bps of the slice | yes |
| `xRateCap`, `xRateFloor` | 9700, 3000 | floor <= cap <= 10000 | exit token bid in bps of score, phase 2 | yes |
| `xRateClimbPerHour`, `xRateDropPerCredit` | 100, 20 | 0 to 1000 each | exit bid climb per hour and drop per credit | yes |
| `xAuctionHalfLife` | 21600 | 600 to 2592000 s | exit token dutch auction price half life | yes |
| `exitSliceCredits` | 20 | 1 to 1000 | credits per exit slice | yes |
| `rateCap` | 123200000000000 | 1e11 to 1e15 (the rate bounds) | wei per whole point, 8 times `rateStart` at launch. the eth rate never exceeds it: the climb stops at the lower of the funded clamp and `rateCap`, `setRate` refuses a value above it, and lowering it below the live rate pulls the rate down to it at once (checkpoint first). the owner's "never pay more than this per credit". `rateStart` must not exceed it (preflight row, and the Core constructor reverts `BadRate`) | yes |
| `exitLaneToBuybackBps` | 0 | 0 to 10000 | share of exit token from an exit lane exit to the buyback pot, the rest to the exit bid pot. 0 keeps all of it in the bid pot. last field of the struct | yes |

two more owner functions, each with its own event: `setRate(uint256)` resets the current eth limit (inside the rate bounds and at most `rateCap`, checkpoints first, keeps the last fill time) and `setXRate(uint256)` sets the exit bid (inside the settings floor and cap).

there is one config file, `script/config/mainnet.json`. the hash covers the settings, so a changed launch value is a new signed hash.

config values (`script/config/mainnet.json`). the owner signs off each row.

| key | default | meaning |
|---|---|---|
| `stack.poolManager` | 0x000000000004444c5dc75cB358380D2e3dE08A90 | uniswap v4 pool manager. pool key and swaps |
| `stack.hook` | 0x636c050296B5Cc528D8785169Bf8923716FCa9cc | skim hook. the only sender whose eth the Core books as fees |
| `stack.tickSpacing`, `stack.poolFee` | 200, 8388608 (0x800000) | pool key. spacing and the dynamic fee flag |
| `stack.factory` | 0x49596c375c139E79bb937bcf826068a8F78D4e0e | launches the coin |
| `stack.locker` | 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab | holds the launch liquidity |
| `stack.escrow` | 0x7559689765aE86cBB38e68CD1294830CccB125F2 | fee escrow of the hook, forbidden target |
| `stack.mevModule` | 0xb038D597365FfD108D63C265Bb0621444a1D8B83 | anti sniper linear skim module |
| `factoryOwner` | 0xCB43078C32423F5348Cab5885911C3B5faE217F9 | expected factory owner, a preflight check and the rehearsal prank |
| `owner` | unset, must fill | Core owner (timelock actions) and final token admin |
| `creator` | unset, must fill | skim protocol leg recipient (0.5 points) and the locker reward recipient |
| `name`, `symbol` | unset, must fill | coin name and symbol, part of the coin initcode so part of its address |
| `salt` | zero, must fill | user salt of the coin address. any nonzero value, change it if the predicted address is taken |
| `rateStart` | 1.54e13 | opening bid in wei per whole point, bounded to [1e11, 1e15] and to `rateCap`. launch day rule in section 1: `0.75 * (market price of one credit in wei) * 1e4 / avgScore`. 1.54e13 is for a market price of 0.0089 eth. it only decides how soon the pot starts working, `setRate` moves it later |
| `stack.auctionFactory` | 0x77aB853543286C9Cdd7dd6c01222A7cC4Ac93d63 | the pnd auction house factory. the Core creates its own house through it in the constructor. preflight needs code, a default fee of 0 and no house yet for the predicted core |
| `settings` | see the settings table above | the launch value of every economic setting, one key per field of `Settings`, in the hash |
| `launch.supply` | 1,000,000,000e18 | coin supply, all of it in the pool manager as the locked launch position (a few thousand wei of rounding dust stay in the locker), must equal the Core `SUPPLY` |
| `launch.startTick` | -175000 | `tickIfToken0IsArtCoins`, about 40M coin per eth. pinned: a multiple of the spacing and equal to `positionLower` (the single sided position starts at the price edge) |
| `launch.positionLower`, `positionUpper` | -175000, 887200 | the one launch position. pinned: `positionLower` equals `startTick`, `positionUpper` is the highest multiple of the spacing at or below the max tick 887272 (887200 for spacing 200) |
| `launch.baselineSkimBps` | 10000 | baseline skim in hundredths of a bp of volume, 10,000 of 100,000 is 10 points |
| `launch.bountyBps` | 9500 | share of the baseline skim to the Core, so 9.5 points to the Core and 0.5 to the creator |
| `launch.maxReferralBps` | 0 | referral cap, same hundredths of a basis point scale as `baselineSkimBps`. 0 means the hook never calls `notify`. pinned to 0 |
| `launch.lpFee` | 0 | extra lp fee, same scale as `baselineSkimBps`. pinned to 0 |
| `launch.sniperStartBps`, `sniperEndBps`, `sniperSeconds` | 90000, 10000, 1800 | skim decays linearly from 90 points to 10 over 30 minutes, the extra goes to the Core |
| `launch.taxBps`, `taxBpsMax` | 1500, 2000 | venue tax on coin leaving a venue (15 percent now, cap 20 percent) |
| `launch.taxBurn` | 0x000000000000000000000000000000000000dEaD | tax recipient |
| `launch.tokenCodeFile` | script/data/ArtCoinsToken.creation.hex | creation code of the token implementation, input of the coin address prediction |

pinned rules. preflight fails (and `Deploy` stops) on any value outside them. each row is a check in `script/Checks.sol`.

| rule | pinned to | override in the config file |
|---|---|---|
| tick spacing | 1 to 32767 (the v4 limit) | none |
| pool fee | 0x800000, the dynamic fee flag | none |
| `startTick`, `positionLower`, `positionUpper` | multiples of the spacing, `positionLower` equals `startTick`, `positionUpper` equals the highest multiple of the spacing at or below 887272, lower below upper | none |
| `baselineSkimBps` | exactly 10000 | none |
| `bountyBps` | exactly 9500 | `"overrides": {"bounty": true}` allows any value up to 9999 |
| `maxReferralBps`, `lpFee` | 0 and 0 | none |
| `sniperEndBps` | equal to `baselineSkimBps` | none |
| `sniperStartBps` | 50000 to 90000 (the module limit), above the end | none |
| `sniperSeconds` | 600 to 3600 (the module accepts 60 to 10800) | none |
| `taxBpsMax`, `taxBps` | 2000, and `taxBps` at most `taxBpsMax` | none |
| `taxBurn` | the dead address 0x...dEaD | `"overrides": {"taxBurn": true}` allows any nonzero address |
| factory | deprecated, so only the owner and admins can launch | `"overrides": {"openFactory": true}` for a future public factory |
| `owner`, `creator` | not the dead address, a stack address, the mev module or the factory owner. WARN when they are equal or when one is the deployer | none |
| `supply` | the Core `SUPPLY` constant | none |
| `rateStart` | [1e11, 1e15] and at most `settings.rateCap`, the Core limits | none |
| `settings` | every field inside its bound (the table in this section), `climbMaxBps` at least `climbBaseBps`, `xRateFloor` at most `xRateCap`. the Core checks the same bounds on `setSettings` and in its constructor | none |
| `stack.auctionFactory` | has code, the default fee is 0 (WARN otherwise), no house exists yet for the predicted core | none |

a change of a pinned value means editing `script/Checks.sol` on purpose, in a reviewed commit. a pinned rule cannot know a value that is plausible but not the intended one (another start price, another opening bid, `owner` and `creator` swapped). those are covered by the sign off: preflight prints the `signoff:` rows, the owner signs them, and `CONFIG_HASH` (keccak256 of the canonical abi encoding of the whole config and the token creation code) is the one value `Deploy` needs in its env. any later edit of the file changes the hash and `Deploy` reverts with `ConfigHashMismatch`. the overrides are inside the hash too.

what the sign off table covers: owner (Core owner and token admin), creator (0.5 point leg and lp rewards), the deployer, the skim bounty and referral payout that point to the Core, the protocol leg that points to the creator, the tax and burn address, the opening bid, one row per setting (the launch value of every economic setting) and the economics line (skim, bounty, sniper, tax).

## 3. verify on etherscan

the compiler settings are in `foundry.toml`: solc 0.8.30, evm cancun, via ir, optimizer 200 runs, `bytecode_hash = "none"`. the three contracts we own are the library `CoreLib` (`src/lib/CoreLib.sol`), ControllerV1 and Core. the coin, hook, factory, locker and auction house are artcoins and pnd contracts and verify on their own.

the library address is the CREATE2 address of the compiled code. take it from `jq -r '.libraries[0]' broadcast/Deploy.s.sol/1/run-latest.json | cut -d: -f3` or from the line `verify: library CoreLib at` that postflight prints (step 9), both are the same. export it as `LIB`. the Core links against it: its runtime code carries the library address in place of the placeholder, so verifying the Core needs `--libraries src/lib/CoreLib.sol:CoreLib:$LIB` or etherscan compiles an unlinked Core and reports a mismatch. verify the library first, it has no constructor arguments. postflight prints the exact `--libraries` flag, the Core constructor args and the controller constructor args (`verify:` lines), and its row `core: linked library is the compiled CoreLib` fails when the address inside the Core is not code equal to the compiled library.

the constructor arguments of the Core are `(owner, coin, controller, stack, rateStart, settings)`, where `stack` is the tuple `(poolManager, hook, tickSpacing, poolFee, factory, locker, escrow, auctionFactory)` and `settings` is the `Settings` tuple in the field order of the settings table (types: uint16 flatBps, uint32 avgScore, uint16 climbBaseBps, uint32 climbDoubleEvery, uint16 climbMaxBps, uint16 dropBps, uint16 spendCapBps, uint16 bonusCapBps, uint16 tipSavingsBps, uint16 tipCapBps, uint16 reimburseBps, uint16 reimburseCapBps, uint16 reserveBps, uint32 auctionDuration, uint32 exitAfter, uint16 saleToBuybackBps, uint16 exitToBuybackBps, uint128 buybackSlice, uint16 buybackDelay, uint16 keeperTipBps, uint16 xRateCap, uint16 xRateFloor, uint16 xRateClimbPerHour, uint16 xRateDropPerCredit, uint32 xAuctionHalfLife, uint16 exitSliceCredits, uint64 rateCap, uint16 exitLaneToBuybackBps). every member is a static type, so the tuples are encoded inline. postflight prints the exact hex read back from the deployed Core (the settings it prints are the current ones, so run it before any `setSettings`), compare it with the hex below.

```sh
export POOL_MANAGER=$(jq -r .stack.poolManager $LAUNCH_CONFIG) HOOK=$(jq -r .stack.hook $LAUNCH_CONFIG)
export LOCKER=$(jq -r .stack.locker $LAUNCH_CONFIG) ESCROW=$(jq -r .stack.escrow $LAUNCH_CONFIG)
export AUCTION_FACTORY=$(jq -r .stack.auctionFactory $LAUNCH_CONFIG)
export RATE_START=$(jq -r .rateStart $LAUNCH_CONFIG)   # OWNER, FACTORY, CORE, COIN, CONTROLLER, LIB as in sections 0 and 1
export SETTINGS="($(jq -r '.settings | [.flatBps,.avgScore,.climbBaseBps,.climbDoubleEvery,.climbMaxBps,.dropBps,.spendCapBps,.bonusCapBps,.tipSavingsBps,.tipCapBps,.reimburseBps,.reimburseCapBps,.reserveBps,.auctionDuration,.exitAfter,.saleToBuybackBps,.exitToBuybackBps,.buybackSlice,.buybackDelay,.keeperTipBps,.xRateCap,.xRateFloor,.xRateClimbPerHour,.xRateDropPerCredit,.xAuctionHalfLife,.exitSliceCredits,.rateCap,.exitLaneToBuybackBps] | map(tostring) | join(",")' $LAUNCH_CONFIG))"
ARGS=$(cast abi-encode \
  "constructor(address,address,address,(address,address,int24,uint24,address,address,address,address),uint256,(uint16,uint32,uint16,uint32,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint32,uint16,uint16,uint128,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint16,uint64,uint16))" \
  $OWNER $COIN $CONTROLLER \
  "($POOL_MANAGER,$HOOK,200,8388608,$FACTORY,$LOCKER,$ESCROW,$AUCTION_FACTORY)" \
  $RATE_START "$SETTINGS")

forge verify-contract $LIB src/lib/CoreLib.sol:CoreLib --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir

forge verify-contract $CORE src/Core.sol:Core --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir \
  --libraries src/lib/CoreLib.sol:CoreLib:$LIB \
  --constructor-args $ARGS

forge verify-contract $CONTROLLER src/ControllerV1.sol:ControllerV1 --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir \
  --constructor-args $(cast abi-encode "constructor(address)" $CORE)
```

`forge verify-contract` needs `ETHERSCAN_API_KEY`. check the verified source page shows the same constructor args as the postflight print. `ARGS` is built from the config and the printed `verify: core constructor args` is read back from the chain: on the anvil walk they were equal, so compare them (`[ "$ARGS" = "$PRINTED" ]`) before you submit.

verify without the network, to prove that the files you submit are the ones that were broadcast (all three checks passed on the anvil fork):

```sh
# the Core creation input of the broadcast is the linked creation code plus the args
INPUT=$(jq -r '[.transactions[] | select(.contractName=="Core")][0].transaction.input' broadcast/Deploy.s.sol/1/run-latest.json)
CODE=$(forge inspect src/Core.sol:Core bytecode --libraries src/lib/CoreLib.sol:CoreLib:$LIB)
[ "${CODE}${ARGS#0x}" = "$INPUT" ] && echo creation input equal
# the library: salt zero plus its creation code is the transaction to the create2 deployer
LIBIN=$(jq -r '[.transactions[] | select(.contractName=="CoreLib")][0].transaction.input' broadcast/Deploy.s.sol/1/run-latest.json)
[ "0x$(printf '0%.0s' $(seq 64))$(forge inspect src/lib/CoreLib.sol:CoreLib bytecode | cut -c3-)" = "$LIBIN" ] && echo library creation input equal
# the Core runtime on chain is the linked deployedBytecode (immutables differ: compare on a fork, or skip)
forge inspect src/Core.sol:Core deployedBytecode --libraries src/lib/CoreLib.sol:CoreLib:$LIB | head -c 20
```

if etherscan rejects `--libraries` (an old verifier), use the standard json route: `forge verify-contract $CORE src/Core.sol:Core --libraries src/lib/CoreLib.sol:CoreLib:$LIB --show-standard-json-input > core.json`. the file carries `settings.libraries` with `{"src/lib/CoreLib.sol":{"CoreLib":"0x..."}}` (checked), upload it on the etherscan page "Solidity (Standard-Json-Input)" with compiler 0.8.30, optimizer 200 runs, and the constructor args hex without the `0x`. the library itself verifies the same way without `--libraries`.

## 4. first actions after launch

all times are from the launch block. the anti sniper window is `launch.sniperSeconds` long (1800 seconds), measured from pool creation, which is the launch transaction.

| when | what happens | what to do |
|---|---|---|
| launch block | the pool is live. the skim is 90 points of volume, 9.5 points of the baseline plus the whole extra go to the Core, so early buyers fund the pot fast. the rate sits at `rateStart` and does not move while the pot is unfunded | read postflight. nothing else is needed |
| first buy | `Core.receive()` books the bounty into `ethPot` and `FeesAdded` fires | check `ethPot` and the balance are equal |
| funded | the pot is funded when `ethPot * spendCapBps / 10000 >= avgScore * rate / 1e4`, so at `rateStart` 1.54e13 the pot needs 3.33e16 wei, and at 1e11 it needs 2.17e14, at 1e15 it needs 2.17e18. from that moment the bid climbs lazily, `climbBaseBps` an hour (100), doubling every `climbDoubleEvery` (24 hours) since the last fill, `climbMaxBps` (800) at the top. the funded rule is logic, not a setting. there is no inventory gate: unsold statements never stop the buying. there is no retroactive climb for the unfunded time | watch `funded()` and `ethRate()` |
| 30 minutes | the anti sniper window ends and the skim is the 10 point baseline. the public can add liquidity to the pool after it | none |
| any time after funded | credit holders can call `sellForEth` into the bid. a credit sells when its ceiling fits the hourly cap, 20 percent of the pot at the window open. the ceiling is flat per credit at launch (`flatBps` 10000): `avgScore * rate / 1e4 * (1 + bonus)`, whatever the credit's score | check that real credits clear. at the clamp an average credit without bonus fits a fresh window |
| the clamp | the bid stops climbing where 20 percent of the pot buys exactly one average credit. so the highest bid is always one somebody can sell into | none |
| with no fills | after 72 hours without a fill the climb is 800 bps an hour until the clamp, so a bid that nobody hits runs up to what the pot can pay | none |
| statements | each eth lane compose lists the statement on the Core's own auction house at 90 percent of its cost, for 24 hours from the first bid. the proceeds are credited to the Core inside the house and move into the pots when anyone calls `collectSales()` (`buyback()` calls it first). a statement with a bid cannot be cancelled. `syncStatement(sid)` clears the record of a sold statement and relists a returned one, `repriceStatement(sid)` applies a changed `reserveBps` to an old listing with no bid | check `statementStatus(sid)` after the first compose, then that the first sale clears and `collectSales()` moves the eth |
| eth in `ethToBuyback` | it fills from statement sales (`collectSales`), so only after the first auction. `buyback()` then burns coin, one slice of at most 1 eth every 25 blocks | anyone may call, 0.5 percent tip |
| settings | the owner may change any setting at once with `setSettings(Settings)` and the eth limit with `setRate`, the exit bid with `setXRate`. the owner cannot transfer eth, credits, statements, coin or exit token out of the Core by any setting: tips, reimbursements and keeper rewards are capped and everything else is spent only by the engine's own doors. the owner does set the price the engine pays, so a dishonest owner or a stolen owner key could sell credits to the engine at an inflated limit and drain the pot at the bounded pace of docs/ARCHITECTURE.md section 10 (the owner accepted this, holders trust the owner key). use a multisig as owner | after any change read `settings()` and the `SettingsSet` event |
| phase 2 | exit doors stay shut while the exitModule slot is empty. the owner queues `SetExitModule` through the 7 day timelock. the same action may run again later: a new module must report the same `exitToken()`, and `unitPerPoint` is read again on every set (naming the same address again is how a changed unit is taken over, after the 7 days). `exitLaneToBuybackBps` (launch 0) sets the share of exit lane exits that goes to the coin buyback | queue only after the module is final. a later replacement is possible but public for 7 days |

housekeeping after launch.

| item | action |
|---|---|
| factory admin | revoke the deployer, step 10 of section 1. confirm with `cast call $FACTORY "admins(address)(bool)" $DEPLOYER` |
| token admin | the owner holds it. it can set the tax anywhere in [0, `taxBpsMax`], so it can raise 1500 to the 2000 ceiling, set metadata and renderer, and set the referral cap anywhere up to 1000 (raise it from 0). the owner signs `taxBpsMax` 2000 and the 1000 cap as the ceiling. it cannot change recipients, the bounty split, skim, ticks, venues or the exempt list |
| creator rewards | the creator claims the 0.5 point protocol leg from the fee escrow, `claim(creator, address(0))`, and lp fees through the locker `collectRewards(coin)` |
| the deployer key | sweep any leftover eth and retire the key |

### changing settings after launch

every setting of the table in section 2 is adjustable by the owner after launch, all at once, effective at once. the Core rejects a struct outside the bounds (`SettingsBounds`) and the pair rules (`climbMaxBps` at least `climbBaseBps`, `xRateFloor` at most `xRateCap`). the owner signs with `--ledger` or `--account <name>`. `setSettings` takes the whole struct, so always read the live one first, change one field, send it all back. after a change postflight fails the row `core: settings equal the config` until you run it with `SETTINGS_CHANGED=1` (it turns a warning, the other rows stay strict). the same flag lets `Resume` run on a Core whose settings changed.

the script way (reads the live struct, prints a before and after table with the bounds, the calldata and the `cast send` line, sends only with `SEND=1` and `--broadcast` and when the signer is the Core owner):

```sh
export CORE=0x...                       # the live Core
SET_reserveBps=8000 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL           # dry run, sends nothing
SETTINGS_PATCH='{"reserveBps":8000,"auctionDuration":43200}' forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL   # a json patch, text or file path
SET_reserveBps=8000 SET_RATE=20000000000000 SEND=1 forge script script/SetSettings.s.sol --rpc-url $PRIVATE_RPC --broadcast --ledger   # sends setSettings and setRate
```

after you change `reserveBps`, reprice the open listings in the same transaction batch. a listing keeps the reserve it was made with until `repriceStatement(sid)` runs on it, and anyone can bid at the old reserve first (after a bid the reserve and the sale price cannot change). raising the reserve is the case that needs it, a lower one only helps bidders. `repriceStatement` is permissionless, so a Safe batch can hold `setSettings` and one `repriceStatement` per listed statement without a bid. the script prepares them: add `REPRICE=1` and it appends one `repriceStatement` call for every statement the Core holds that is listed with no bid (read through `heldStatements()` and `statementStatus`), prints each `cast send`, and with `SEND=1` sends them after `setSettings` and `setRate`. send everything as one batch from the owner when the owner is a multisig, so no bid can land between the settings change and the reprices:

```sh
SET_reserveBps=12000 REPRICE=1 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL      # dry run, lists the repriceStatement calls
```

`SET_<field>` and `SETTINGS_PATCH` name the fields of the table, the single variables win over the patch, `SET_RATE` and `SET_XRATE` add `setRate` and `setXRate`, `REPRICE=1` adds the reprices. checked on the anvil fork: the table showed the live value 9000 and the new one 8000, the broadcast from the impersonated owner changed `reserveBps` and the rate.

the by hand way, with `cast`. the tuple type is the one of the constructor in section 3 (`T` below). field 13 is `reserveBps`, field 27 is `rateCap` and field 28 is `exitLaneToBuybackBps`, count the fields in the order of the table:

```sh
T="(uint16,uint32,uint16,uint32,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint32,uint16,uint16,uint128,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint16,uint64,uint16)"
S=$(cast call $CORE "settings()($T)" --rpc-url $MAINNET_RPC_URL | sed -E 's/ \[[^]]*\]//g')   # the live struct, plain numbers
NEW=$(echo "$S" | tr -d '() ' | awk -F, -v OFS=, '{$13=8000; print "(" $0 ")"}')                # change field 13 only
echo "$S"; echo "$NEW"                                                                          # read both before sending
cast send $CORE "setSettings($T)" "$NEW" --rpc-url $PRIVATE_RPC --ledger                        # as the owner
cast send $CORE "setRate(uint256)" 20000000000000 --rpc-url $PRIVATE_RPC --ledger               # the eth limit, wei per point, 1e11 to 1e15
cast call $CORE "settings()($T)" --rpc-url $MAINNET_RPC_URL; cast call $CORE "ethRate()(uint256)" --rpc-url $MAINNET_RPC_URL
```

`setRate` checkpoints the rate first, keeps the last fill time and resets the limit to the new value. `setXRate(uint256)` sets the exit bid inside the settings floor and cap. read back with `settings()` and `ethRate()`, and the `SettingsSet` event. both flows were run on the anvil fork as the impersonated owner.

## 5. when artcoins v2 ships

only the `stack` block of the config changes, plus anything the checks below flag. the Core is deployed with the new stack as constructor arguments, so there is no code change in `src/`.

| step | action |
|---|---|
| 1 | replace `stack.poolManager`, `hook`, `tickSpacing`, `poolFee`, `factory`, `locker`, `escrow`, `mevModule` and `factoryOwner` with the v2 values. keep `launch.*` unless the v2 launcher needs a different shape |
| 2 | replace `script/data/ArtCoinsToken.creation.hex` with the creation code of the v2 token, without constructor arguments. take it from a sourcify verified v2 coin: the creation transaction input minus the abi encoded constructor arguments, the same way the current file was cut from the live 111 coin. the prediction must equal what the real factory returns, the deploy reverts on a mismatch so a wrong file cannot launch |
| 3 | diff every function and event below against the v2 source and ABI |
| 4 | update the default stack in `src/interfaces/Interfaces.sol` (`Mainnet`) only so the default config and the tests match. nothing in `src/Core.sol` reads it |
| 5 | run preflight, the rehearsal on the latest block and the full suite. the hook bytecode flags, the dynamic fee flag and the tick spacing are all read from the config, never from code |

what the system depends on in artcoins, with signatures. each row is a diff target against v2.

factory (`stack.factory`)

| signature | used for |
|---|---|
| `deployTokenWithProtocolBpsAndTax(DeploymentConfig,uint16,TaxConfig) payable returns (address)` selector 0x373c0b29 | the launch, `msg.value` exactly `deployFee()` with no extensions |
| `deprecated() returns (bool)` | preflight, who may launch |
| `deployFee() returns (uint256)` | the launch value and the balance check |
| `owner() returns (address)`, `admins(address) returns (bool)`, `setAdmin(address,bool)` | who may launch, enablement and revoke |
| `enabledHooks(address) returns (bool)`, `enabledLockers(address,address) returns (bool)` (locker, hook), `enabledMevModules(address) returns (bool)` | preflight |
| create2 address of the coin: factory as deployer, salt `keccak256(abi.encode(tokenAdmin, userSalt))`, initcode is the token creation code plus `abi.encode(name, symbol, totalSupply, tokenAdmin, image, metadata, context, renderer, taxConfig)` | the coin prediction, the Core is deployed against it before the launch |
| struct layouts, field order exact: `TokenConfig(tokenAdmin,name,symbol,salt,image,metadata,context,totalSupply,renderer)`, `PoolConfig(hook,pairedToken,tickIfToken0IsArtCoins,tickSpacing,poolData)`, `LockerConfig(locker,rewardAdmins[],rewardRecipients[],rewardBps[],tickLower[],tickUpper[],positionBps[],lockerData)`, `MevModuleConfig(mevModule,mevModuleData)`, `SniperFeeConfig(recipient,lockRecipient)`, `ExtensionConfig(extension,msgValue,extensionBps,extensionData)`, `DeploymentConfig(tokenConfig,poolConfig,lockerConfig,mevModuleConfig,sniperFeeConfig,extensionConfigs[])`, `TaxVenue(kind,factory,initCodeHash,counterToken,v3Fee)`, `TaxConfig(enabled,taxBps,taxBpsMax,burnAddress,poolManager,canonicalHook,pairedToken,canonicalPoolFee,canonicalTickSpacing,exempt[],venues[])` | `src/interfaces/ArtCoins.sol` |
| `poolData` is `abi.encode(address extension, bytes extensionData, bytes feeData)` and `feeData` is `abi.encode(uint24 baselineSkimBps, uint16 bountyBps, uint24 maxReferralBpsOfVolume, uint24 lpFee, address bountyRecipient, address protocolRecipient, address referralPayout, address quoteToken)`. `mevModuleData` is `abi.encode(uint24 startBps, uint24 endBps, uint32 seconds)` | `script/Builder.sol` |

token (the coin, created by the factory)

| signature | used for |
|---|---|
| `burn(uint256)`, `burnFrom(address,uint256)` | Core buyback burn and the exit auction burn. real supply reduction |
| `totalSupply()`, `balanceOf(address)` | postflight, tests |
| `admin()`, `originalAdmin()`, `updateAdmin(address)` | the handover to `owner`, postflight |
| `taxEnabled()`, `taxBps()`, `taxBpsMax()`, `taxBurnAddress()`, `canonicalHook()`, `canonicalPoolId()`, `taxPoolManager()`, `isTaxVenue(address)`, `isTaxExempt(address)` | postflight read back of the tax config |
| `setTaxBps(uint16)` | tests of the admin path only |
| behaviour: the Core must be tax exempt (it is in `exempt[]`), coin leaving the pool manager to the Core in the canonical swap must be untaxed because the hook attests the budget, `canonicalPoolId` equals `keccak256(abi.encode(poolKey))` | the buyback and the pool id check |

skim hook (`stack.hook`)

| signature | used for |
|---|---|
| `skimConfig(bytes32 poolId) returns (uint24 baselineSkimBps, uint16 bountyBps, uint24 maxReferralBpsOfVolume, uint24 lpFee, address bountyRecipient, address protocolRecipient, address referralPayout, address quoteToken)` | postflight |
| `poolTaxEnabled(bytes32)`, `mevModuleEnabled(bytes32)`, `poolExtensionLocked(bytes32)`, `poolExtension(bytes32)` | postflight |
| `lockPoolExtension(PoolKey)` | called by the deploy as the token admin, closes the extension path for good |
| `setMaxReferralBpsOfVolume(PoolKey,uint24)` | tests of the referral path only |
| behaviour: the bounty leg is a native call to `bountyRecipient` with all gas and empty calldata, so it lands in `Core.receive()`. a revert there reverts the swap | `receive()` must never revert |
| behaviour: before each swap, if `bountyRecipient.balance >= 0.01 eth`, the hook calls `streamForward() returns (uint256)` inside try and catch. the Core has no fallback so the call reverts and is caught | the Core must keep no fallback |
| behaviour: referral pay is `referralPayout.notify{value, gas: 35000}(address)` and a failure folds into the escrow. the Core has a payable no op `notify(address)` | referral cap 0 means it is never called |
| behaviour: the hook only skims the eth side, native pairs only (`pairedToken` is `address(0)`), the pool key is `(address(0), coin, poolFee, tickSpacing, hook)` with the coin as currency1 | the Core pool key and `buyback` |
| behaviour: a raw `PoolManager.initialize` on our key is refused by the hook, and `initializePoolOpen` refuses a coin with no code, so nobody can pre create the pool | launch hijack safety |

locker, escrow, mev module, pool manager

| signature | used for |
|---|---|
| locker `tokenRewards(address) returns (TokenRewardInfo(token, poolKey, positionId, numPositions, rewardBps[], rewardAdmins[], rewardRecipients[]))` | postflight |
| locker `collectRewards(address)` | the creator claims lp fees, no code path of ours |
| escrow `availableFees(address,address) returns (uint256)`, `claim(address,address)` | creator claim of the 0.5 point protocol leg, tests |
| mev module `currentSkimBps(bytes32) returns (uint24)` | tests only. the config data layout above is the launch input |
| pool manager `unlock`, `swap`, `settle`, `take`, `getSlot0` through `StateLibrary` | the Core buyback and postflight. v4 core is pinned in `lib/` |

events the tests read, to diff by topic

| event | where |
|---|---|
| `SkimSplit(bytes32 indexed poolId, uint256 volume, uint256 bountyTotal, uint256 protocolNet, uint256 referral)` on the hook, topic0 is `keccak256("SkimSplit(bytes32,uint256,uint256,uint256,uint256)")` | `test/Fees.t.sol`, `test/invariant/Handler.sol`. the production contracts read no artcoins event. the Core only reacts to the eth arriving from the hook |

the verified live interfaces were executed against the pinned fork, see docs/reference/artcoins-notes.md. if any signature, struct field order or the create2 prediction differs in v2, fix `src/interfaces/ArtCoins.sol` and `script/Builder.sol` first, then rerun the rehearsal.

## 6. when a transaction fails half way

`Deploy` sends six transactions in this order: the library (a CREATE2 through the deterministic deployer, sent from the deployer, one nonce), the controller, the core (its constructor creates the pnd auction house), the launch through the factory, the lock of the extension slot, and the admin handover. every state between them is safe (the library is stateless, an orphan controller is inert, an orphan core holds nothing and its auction house is empty), but the states after the launch leave the deployer as the token admin, so finish them. every point below has a fork test (`test/Resume.t.sol`). do not rerun `Deploy`, and ignore any old advice to use a new salt: the coin address includes the Core address through the tax config, so a rerun takes a new nonce, a new Core and a new coin address, and leaves an orphan Core behind.

first read what is on chain (`export CORE=...`, the address `Deploy` printed or the transaction named Core in `broadcast/Deploy.s.sol/1/run-latest.json`):

```sh
export HOOK=$(jq -r .stack.hook $LAUNCH_CONFIG)
export COIN=$(cast call $CORE "COIN()(address)" --rpc-url $MAINNET_RPC_URL)
cast code $CORE --rpc-url $MAINNET_RPC_URL | head -c 12   # 0x... means the core exists
cast code $COIN --rpc-url $MAINNET_RPC_URL | head -c 12   # 0x means the launch is not sent
export POOLID=$(cast keccak $(cast abi-encode "f((address,address,uint24,int24,address))" "(0x0000000000000000000000000000000000000000,$COIN,8388608,200,$HOOK)"))
cast call $HOOK "poolExtensionLocked(bytes32)(bool)" $POOLID --rpc-url $MAINNET_RPC_URL   # false: not locked
cast call $COIN "admin()(address)" --rpc-url $MAINNET_RPC_URL                               # the owner when done (errors before the launch, the coin does not exist yet)
```

| failure point | state on chain | exploitable or stuck | recovery |
|---|---|---|---|
| 0. tx 1 only (the library) | the library on chain, stateless. the deployer nonce moved by one. no controller, no core | no | **rerun `Deploy`** (the one case where a rerun is right). preflight sees the library, forge skips it, the controller takes the live nonce and the core the next. the addresses are the ones preflight prints now. `Resume` has nothing to do (`no code at the core address`) |
| 1. tx 2 done (the controller), no core | orphan controller, holds nothing | no | nothing is needed, the controller is inert. either rerun `Deploy` (a new controller and a new core, the old controller stays orphaned) or keep the predicted addresses: resend the saved Core creation (`cast send --rpc-url $PRIVATE_RPC --private-key $PRIVATE_KEY --create $(jq -r '[.transactions[] \| select(.contractName=="Core")][0].transaction.input' broadcast/Deploy.s.sol/1/run-latest.json)`, the file lists all six transactions, sent or not) and resume from point 2 |
| 2. tx 3 done (the core with its house), launch not sent (`cast code $COIN` is empty) | the Core, its auction house (owned by the Core, empty) and the controller. the coin has no code. the Core holds 0 and ignores everyone but the hook | nobody can launch the predicted coin while the factory is deprecated, only the owner or an admin. if the owner opens the factory, anyone could launch there and bind the Core to a dead coin | **`Resume`, stage 1**. it sends the launch, the lock and the handover. the launch needs the deployer still enabled on the factory and the fee in its balance |
| 3. tx 4 done (the launch), slot not locked (`poolExtensionLocked` false) | live pool, tradeable. the token admin is the deployer, the extension slot is open but no extension is enabled on the factory, so it is inert. the deployer can still call `setTaxBps` in [0, 2000]. strangers cannot lock or move the admin | the deployer key only | **`Resume`, stage 2**. it sends the lock and the handover |
| 4. tx 5 done (the lock), handover not done (`admin()` is not the owner) | the owner cannot change tax or metadata until the handover. if the deployer key is lost the admin role is stuck for good (the Core is unaffected) | the deployer key only | **`Resume`, stage 3**. it sends the handover |
| 5. all six done, deployer still a factory admin | the deployer can set hooks, lockers and mev modules, claim team fees, launch on a deprecated factory | step 10 is not gated by the scripts, `REQUIRE_REVOKED=1` gates it | `Resume` is a no op (stage 4, nothing sent, the nonce does not move), then step 10 |

the script, for points 2, 3 and 4 (it detects the stage itself from the chain and sends only the missing steps, and runs postflight at the end). run it as the same deployer (`DEPLOYER` set, the script refuses another signer) with the same config and `CONFIG_HASH`, with the relay that passed the rpc test:

```sh
CORE=$CORE DEPLOYER=$DEPLOYER forge script script/Resume.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --private-key $PRIVATE_KEY
```

it refuses to run when there is no Core at `$CORE`, when the Core was not built from this config (owner, rate start, stack including the auction factory, coin prediction), when its settings differ from the signed ones (`CoreMismatch settings`: the owner called `setSettings` already, run it again with `SETTINGS_CHANGED=1` on purpose), when the caller is not the deployer of the run, or (stage 1 only) when the preflight rows for the factory fail. it prints `stage found` (0 no core, 1 core only, 2 launched, 3 locked, 4 done).

the same by hand, as the deployer, if the script cannot be used. each is the single transaction of that point (point 3 needs the lock, point 4 the handover, and the order is 2, 3, 4):

```sh
# point 2: send the saved launch transaction (the calldata is in the broadcast file) with the live fee
export LAUNCH_INPUT=$(jq -r '[.transactions[] | select((.function // "") | startswith("deployTokenWithProtocolBpsAndTax"))][0].transaction.input' broadcast/Deploy.s.sol/1/run-latest.json)
cast send $FACTORY $LAUNCH_INPUT --value $(cast call $FACTORY "deployFee()(uint256)" --rpc-url $MAINNET_RPC_URL) --rpc-url $PRIVATE_RPC --private-key $PRIVATE_KEY
# point 3: close the extension slot for good
cast send $HOOK "lockPoolExtension((address,address,uint24,int24,address))" "(0x0000000000000000000000000000000000000000,$COIN,8388608,200,$HOOK)" --rpc-url $PRIVATE_RPC --private-key $PRIVATE_KEY
# point 4: hand the token admin to the owner
cast send $COIN "updateAdmin(address)" $OWNER --rpc-url $PRIVATE_RPC --private-key $PRIVATE_KEY
```

then run step 9 (postflight). `8388608` is `stack.poolFee` and `200` is `stack.tickSpacing`, take them from the config if they differ. after a failed launch transaction the Core is still valid, so a retry of that one transaction is right. the broadcast file `broadcast/Deploy.s.sol/1/run-latest.json` is gitignored and holds the signed data, keep it private.

a transaction pending or dropped in the relay: look at `cast nonce $DEPLOYER --rpc-url $MAINNET_RPC_URL` against `cast nonce $DEPLOYER --block pending --rpc-url $MAINNET_RPC_URL`. when they differ a transaction is still pending, wait for it. if the relay dropped it, the nonce does not move and the state is the one the table reads, resume from it. never rerun the whole script while one is pending.
