# deploy runbook

this is the launch runbook for branch `flow`, on the artcoins v2 stack (v2 repo commit 87a7522). the whole v2 stack is a config input: the `stack` block of `script/config/mainnet.json` holds every v2 address, the Core takes it as a constructor argument and nothing in `src/` hardcodes an artcoins address. the final run waits for v2 on mainnet: the five v2 addresses in the tracked file are zero placeholders and `Deploy` refuses the file until they are filled.

naming rule: only `exitModule` and `exitToken`. never name or describe them anywhere.

## 0. what you need

| item | note |
|---|---|
| v2 on mainnet | the factory, hook, locker, fee escrow and mev module addresses go into `stack` of the local config (step 1). until then everything below runs only as the rehearsal (`REHEARSAL=1`), which deploys the vendored v2 artifacts onto a fork |
| the signer | one key does every transaction: the v2 factory owner, 0xCB43078C32423F5348Cab5885911C3B5faE217F9. it is also the config `owner` and `creator`, the Core owner and the router owner. `deployTokenAsOwner` is owner only, so there is no fresh deployer, no factory admin enable and no revoke. sign with `--ledger` or `--account <name>`, or `--private-key $PRIVATE_KEY` for a throwaway fork. `Deploy` and `Resume` refuse any other signer (`NotFactoryOwner`, `DeployerMismatch`) |
| eth | the factory deploy fee (read live, 0.069 eth at the pin, sent as the value of the launch) plus gas for nine transactions. measured by the rehearsal on the pinned fork: 14,488,887 gas in total (library 3,080,530, controller 1,017,857, router 1,130,952, core 5,447,926, launch 3,593,871, setEngine 47,654, setPayees 120,714, setTip 23,932, setSplitStart 25,451; each creation figure includes the 200 gas per byte code deposit, the intrinsic 21,000 and the calldata). with the fee that is 0.083 eth at 1 gwei, 0.141 at 5 gwei, 0.359 at 20 gwei. the rehearsal prints this table for the latest block. preflight requires the fee plus the gas at twice the base fee, so fund the key about 20 percent over the table. the setTip transaction is skipped when the router already holds the config tip (the router default is the launch tip), so eight transactions are sent at the default config and the 23,932 above is the 21,000 intrinsic plus the check of a skipped step |
| read rpc | any archive capable mainnet rpc, in `MAINNET_RPC_URL`. used by every command that does not send |
| private rpc | `PRIVATE_RPC`, a relay that does not publish to the public mempool and still serves state reads. `forge script --broadcast` forks the rpc it sends through, so it needs `eth_getCode`, `eth_getStorageAt` and `eth_call`. `https://rpc.mevblocker.io` served them when tested (2026 10 05), the Flashbots Protect endpoint did not. test it, below |
| etherscan key | `ETHERSCAN_API_KEY`, for verification |

with the owner as the only sender, a public mempool is not a safety problem. the v2 owner path cannot be copied by anyone else, so the relay protects secrecy only: a watcher can read the config from the pending launch and prepare to trade in the launch block. the anti sniper skim starts at 90 points of volume and falls to the baseline over 30 minutes, the extra above the baseline goes to the bounty recipient (the router, which shares none of the window with payees), so being first costs the buyer.

shell variables used below, set once after `set -a; . ./.env; set +a`:

```sh
export PRIVATE_RPC=https://rpc.mevblocker.io
export LAUNCH_CONFIG=script/config/local.json   # step 1, gitignored
export FACTORY=$(jq -r .stack.factory $LAUNCH_CONFIG)
export OWNER=$(jq -r .owner $LAUNCH_CONFIG)     # the factory owner, the signer
export DEPLOYER=$OWNER                          # Deploy and Resume refuse a signer that is another address
# set later: CONFIG_HASH (step 3), CORE, COIN, ROUTER, CONTROLLER, LIB (step 7)
```

the signer comes from the command line flags only (`--ledger`, `--account`, `--private-key`). no environment variable picks a signer, so a stray `PRIVATE_KEY` in `.env` cannot override a ledger.

test the private rpc before step 7:

```sh
cast code $FACTORY --rpc-url $PRIVATE_RPC | head -c 20       # must print 0x6080..., not an error
cast call $FACTORY "owner()(address)" --rpc-url $PRIVATE_RPC   # must print the owner
```

if either errors, use a normal rpc for step 7. nothing else changes: the exposure is only that the config is readable before it mines.

## 1. commands in order

all commands run from the repo root. read commands use `$MAINNET_RPC_URL`, the one broadcast uses `$PRIVATE_RPC`.

| step | action | command or owner |
|---|---|---|
| 1 | local config | `cp script/config/mainnet.json script/config/local.json` (gitignored, never edit the tracked file). fill the five v2 addresses in `stack` (`hook`, `factory`, `locker`, `escrow`, `mevModule`) from the v2 deployment, set `rateStart` by the launch day rule below, review every row of section 2. `owner`, `creator`, `name`, `symbol` and `salt` are filled in the tracked file, change `salt` only when the predicted coin address is taken. `export LAUNCH_CONFIG=script/config/local.json` |
| 2 | rehearse the exact file | `REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv`. it reads `LAUNCH_CONFIG`, deploys the vendored v2 artifacts onto the fork when the file leaves the stack at zero, runs preflight before and after the owner command, the whole deploy, postflight and a trading smoke (a sell and a buy through the universal router, flushes, the split start, a real credit sold into the bid). it prints the gas of each transaction and the eth the owner needs at 1, 5 and 20 gwei |
| 3 | owner command: minimum lp fee | the v2 factory enforces a minimum lp fee and the launch uses an lp fee of 0, so the factory owner sets the minimum to 0 once: `cast send $FACTORY "setMinLpFee(uint24)" 0 --rpc-url $MAINNET_RPC_URL --ledger`. confirm: `cast call $FACTORY "minLpFee()(uint24)" --rpc-url $MAINNET_RPC_URL` prints 0. until then preflight fails exactly two rows (`factory: min lp fee is at most the config lp fee` and `factory: deployTokenAsOwner accepts the config (simulated)`). it is the only owner command the launch needs: the launch has no fee swapper, so nothing is registered as an escrow depositor, and no extension is used |
| 4 | preflight and the sign off | `DEPLOYER=$DEPLOYER forge script script/Preflight.s.sol --rpc-url $MAINNET_RPC_URL`. 98 rows on the fixture, every one must be ok (WARN rows never fail). it knows the library takes the first deployer nonce when it is not on chain yet, so the predicted controller (n), router (n+1), core (n+2) and coin are the ones the deploy creates, and it simulates `deployTokenAsOwner` on a snapshot under the 16,777,216 per transaction gas cap. read the `signoff:` rows, then `export CONFIG_HASH=0x...` with the printed `CONFIG_HASH=` value. that one value stands for the whole config |
| 5 | dry run | `DEPLOYER=$DEPLOYER forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --sender $DEPLOYER`. needs `CONFIG_HASH` in the env. simulates all transactions, runs preflight first and postflight on the simulated result. nothing is sent. forge prints "Estimated amount required", which excludes the factory fee sent as value, add the fee |
| 6 | broadcast | after the rpc test of section 0: `forge script script/Deploy.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --ledger`. note the printed core, coin, controller and router addresses and `export CORE=... COIN=... ROUTER=... CONTROLLER=...` and `export LIB=$(jq -r '.libraries[0]' broadcast/Deploy.s.sol/1/run-latest.json | cut -d: -f3)`. if anything stops half way, do not rerun, go to section 6 |
| 7 | verify on etherscan | section 3 |
| 8 | postflight | `CORE=$CORE DEPLOYER=$DEPLOYER CONFIG_HASH=$CONFIG_HASH forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. 87 rows on the fixture, every one must be ok. it prints the constructor args of the Core, the router and the controller (built from the config), the config hash and the rows that cannot be read from chain. the mev schedule is frozen per pool and readable at any time, so there is no window to hit |
| 9 | router flush, repoint, lock | section 4 (router owner commands). the router is not locked by the deploy |
| 10 | keeper duties | section 4 |

the launch day rule for `rateStart`. `rateStart = (market price of one credit in wei) * 1e4 / avgScore`, where `avgScore` is the settings value (4,330,000 at launch), bounded to [1e11, 1e15] by the Core. the opening limit is the market price of a credit, and the bid is flat per credit (`flatBps` 10,000), so one credit costs `rate * avgScore / 1e4` wei at the start. the default 2.0554e13 is for a market price of 0.0089 eth. the market price is the median of the last 24 hours of paid sales. the ceiling anchor is `rateStart` until the first fill, then the rate paid at the last fill. one line to read a recent median from the chain, from any rpc that serves logs (it samples the last 60 transactions that moved a Credit):

```sh
H=$(cast block-number --rpc-url $MAINNET_RPC_URL); cast logs --rpc-url $PRIVATE_RPC --address 0x97630aA70AB14ed9883B41dAfccBc11349723043 --from-block $((H-7200)) "Transfer(address,address,uint256)" --json | jq -r '[.[].transactionHash] | unique | .[-60:] | .[]' | while read t; do cast tx $t value --rpc-url $PRIVATE_RPC; done | grep -v '^0$' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
M=10600000000000000; awk -v m=$M -v a=$(jq .settings.avgScore $LAUNCH_CONFIG) 'BEGIN{printf "%.0f\n", m*1e4/a}'   # the value for rateStart, M the median in wei
```

the value only decides how soon the pot starts working. the owner can move it after the launch with `setRate` (section 4), so a wrong guess is cheap to fix.

what the scripts do.

| script | does |
|---|---|
| `Preflight.s.sol` | read only. chain id 1, the pinned rules of section 2, code at every stack address, the v2 cross checks (the hook reports the pool manager and the escrow and lists the factory as a launcher, the locker reports the escrow and lists the factory, the mev module is bound to the hook, the hook is a core depositor and the locker a depositor of the escrow, the factory reports the pool manager, has a token deployer, enables the hook, locker, mev module and escrow, has an empty default allowlist, a contract as referral payout and a deploy fee of at most 0.1 eth), the signer is the factory owner and the config owner, the factory minimum lp fee, the deployer balance against fee plus gas, the predicted controller, router, core and coin with no code at any of them, the coin equal to the factory's own `predictToken`, code at the deterministic deployer and the library row, the auction factory (default fee 0, no house yet for the predicted core), Credits, Statements and CreditScore sanity, placeholders filled, `rateStart` and every `settings` field against its bound, and a simulation of `deployTokenAsOwner` with the config on a snapshot (hook flags, restriction, mev schedule, tick and fee acceptance). then the `signoff:` rows and the `CONFIG_HASH`. prints a table, reverts with the failed names |
| `Deploy.s.sol` | refuses to run while owner, creator, name, symbol or salt is unset, a value is out of bounds, `CONFIG_HASH` is not the hash of the loaded config, or the signer is not the factory owner. runs preflight, then sends in this order: the library `CoreLib`, ControllerV1, FeeRouter (engine unset), Core (constructor creates the auction house, takes the router as the fee source and the predicted coin), `deployTokenAsOwner`, then the router setup `setEngine(core)`, `setPayees`, and `setTip` (only when it differs from the router default). it does not send the split start: that needs the launch time as mined, so it is the one job of the next run, `Resume`, which reads `deploymentInfo(coin).launchedAt` from the factory and sets `splitStart` to it plus the anti sniper window, with no margin. asserts the coin equals the prediction, and runs postflight on the result before anything is mined (a split start of zero is a warning in that run, a failure in every later one). each transaction is checked against the gas cap in the simulation |
| `Postflight.s.sol` | read only. reads the deployed system back and compares it with the config: core immutables including the fee source, the runtime code of the Core and of the ControllerV1 against the compiled artifacts (immutables and the linked library address masked, the method of `test/BuildIdentity.t.sol`), settings field by field, the sale block of the controller, allowed targets, the house, the linked library, the coin (name, symbol, supply, image, metadata and context empty as launched, restricted, admin, launcher, canonical hook and pool, allowlist holding the Core, the locker and the escrow and none of the router, owner, creator, payee, hook, factory, mev module, house or controller), the pool and the mirrored launch position ticks (the coin is currency1), the hook skim config (6.9 points baseline, bounty bps, bounty recipient the router, lp fee 0), the mev schedule, the locker slots, the router (code, engine, owner, payees and share, tip, split start after the anti sniper window and at most an hour after it, not locked), the creation nonces and the factory prediction when DEPLOYER is set. WARN rows for what the owner may change (no pending owner, allowlist not locked, supply dust). a row `not readable on chain` lists what no getter exposes. the override flags SETTINGS_CHANGED, LOCKS_CHANGED, OWNER_CHANGED, COIN_CHANGED and ROUTER_CHANGED = 1 turn the rows for a named later change into warnings, the other rows stay strict |
| `Resume.s.sol` | finishes a deploy that stopped half way. section 6 |
| `SetSettings.s.sol` | owner settings changes. section 4 |

the library `CoreLib` is deployed by CREATE2 through the deterministic deployer (0x4e59b44847b379578588920ca78fbf26c0b4956c), as a transaction sent from the owner, so it takes one deployer nonce when it is not on chain yet: the library is nonce n, the controller n+1, the router n+2, the core n+3 in a forge script (the broadcast lists CoreLib, ControllerV1, FeeRouter, Core, then the calls). preflight and the dry run know this. if the library already exists forge skips it and every address moves one nonce down. the Core address is a function of the sender and its nonce only. never rerun `Deploy` after it stopped: a rerun takes new nonces and deploys a second system. check `cast nonce $DEPLOYER --rpc-url $MAINNET_RPC_URL` against `--block pending` first.

### what the scripts refuse, the config mutation matrix

`test/ReviewMatrix.t.sol` mutates the signed config and the chain state one change at a time (every stack address, every launch field, every settings field at its bounds and at wrong values, owner, creator, payee, router and sale fields, the salt, `rateStart`, the library missing or with other code, 31 chain state cases such as a disabled hook, an owner that is not the signer, a raised deploy fee, a default allowlist entry) and records which layer stops it. the result is 283 mutations: 177 stopped by preflight, 2 reverting safely in the deploy, 2 caught by postflight, 102 changing only the config hash (a value that stays inside every bound is a different launch, not an error, the hash sign off is what stops it), 0 slips. when you change anything in the file after step 4 the hash changes and `Deploy` reverts with `ConfigHashMismatch`.

## 2. parameter sign off table

constants of the Core (compiled in, not configurable). the owner signs off each row. every economic number is a setting, see the next table.

| constant | value | meaning |
|---|---|---|
| `SUPPLY` | 1,000,000,000e18 | coin supply the exit auction is priced against. must equal the launch supply |
| `RATE_START_MIN_WEI`, `RATE_START_MAX_WEI` | 1e11, 1e15 | bounds of the constructor argument `rateStart` and of `setRate`, wei per whole point. defined once in `src/interfaces/Interfaces.sol`, shared by the Core and the scripts, no getter on the Core |
| `XRATE_START` | 6000 | opening exit token bid in bps of score, phase 2, clamped into the settings cap and floor at construction |
| `OVERPRINT_CAP_PER_DAY` | 8 | overprints per day |
| the pnd auction house | one house, created by the Core in its constructor through `stack.auctionFactory`, owned by the Core for ever, fee 0 | statements are listed on it, bidders use it directly. the address is `HOUSE()` |
| allowed targets at deploy | Seaport 1.6, CreditStrategy | `buyListing` targets. the owner adds more with `addTarget` at once, until `lockTargets()` |
| forbidden targets | Credits, Statements, Core, coin, hook, pool manager, factory, locker, escrow, the fee router (fee source), Permit2, position manager, universal router, exitModule, exitToken, the auction house, the auction factory | checked on add and at call time. the stack members come from the config |

the skim split (6.9 points of volume in total, 9,000 bps of it to the bounty recipient, the router) is fixed inside the artcoins pool at launch and cannot be made adjustable by this system. the router splits what it receives and the owner changes that split (section 4).

settings. one struct, `Settings`, in Core storage, in the config file under `settings`, inside `CONFIG_HASH`. the owner changes any of them after the launch with `setSettings(Settings)` (all at once, effective at once, after a checkpoint of the eth rate and the exit rate; the whole struct is emitted in `SettingsSet`) and reads them with `settings()`. the Core rejects a value outside the bounds, and preflight rejects it first. the bounds exist to stop typos and to keep the owner from transferring assets out (tips, reimbursements and keeper rewards are capped). they do not bound the price the owner sets for credits: see the owner section of docs/ARCHITECTURE.md. postflight reads every field back. the owner signs off each row. the field order is the struct order.

| key | launch | bounds | meaning | adjustable after launch |
|---|---|---|---|---|
| `flatBps` | 10000 | 0 to 10000 | share of the bid that is flat per credit. price = rate * (flatBps * avgScore + (10000 - flatBps) * score) / 10000 / 1e4, before the controller bonus. at 10000 the score contract is not read on the eth doors | yes |
| `avgScore` | 4330000 | 800000 to 6000000 | the score a flat credit is priced as, and the average credit of the funded rule | yes |
| `dropPerCreditBps` | 50 | 1 to 1000 | each credit bought lowers the rate by this share of the rate before that credit | yes |
| `dropFloorBps` | 8000 | 5000 to 10000 | within one minute bucket the rate does not fall below this share of the rate paid at the first fill of the bucket | yes |
| `climbPerMinBps` | 50 | 1 to 1000 | rate climb per minute, compounded | yes |
| `ceilBps` | 12500 | 10000 to 30000 | the rate stays at or below this share of the ceiling anchor, the rate paid at the last fill (`rateStart` before the first fill) | yes |
| `idleLoosenBps` | 200 | 0 to 2000 | the ceiling anchor grows by this share of itself per full 10 minutes since the last fill | yes |
| `clampCredits` | 20 | 1 to 1000 | the read of the rate is lowered to the rate where the hourly cap affords this many average credits | yes |
| `spendCapBps` | 2000 | 100 to 5000 | hourly spend cap, share of the pot at the window open. also the funded threshold and, over `clampCredits`, the climb clamp | yes |
| `bonusCapBps` | 2500 | 0 to 5000 | largest controller bonus on a ceiling | yes |
| `tipSavingsBps`, `tipCapBps` | 1000, 200 | 0 to 2500, 0 to 500 | `buyListing` keeper tip, share of savings capped at a share of cost | yes |
| `reimburseBps`, `reimburseCapBps` | 8000, 500 | 0 to 15000, 0 to 1000 | gas reimbursement for compose and exit, 80 percent of the metered gas cost (the Core meters gross gas and the EIP-3529 refund cap returns up to 20 percent of it to the caller) capped at a share of statement cost | yes |
| `saleFloorBps` | 7500 | 1000 to 40000 | the hard floor of a statement sale, bps of the statement cost. no sale clears below it: the house reserve and `sellTo` are floored at it. the controller prices above it (see the sale controller). a low value lets a bad setting sell a statement cheap, which is why the settings are owner only and public in `SettingsSet`. a changed floor does not reach listings that have no bid yet until `repriceStatement` runs on each (see changing settings after launch) | yes |
| `auctionDuration` | 86400 | 21600 to 2592000 s | statement auction length, runs from the first bid | yes |
| `exitAfter` | 378000 | 3600 to 31536000 s | how long an eth lane statement must have been listed without a bid before it may be redeemed in phase 2 (105 hours, the hour the asking price reaches its floor) | yes |
| `saleToBuybackBps` | 5000 | 0 to 10000 | share of sale proceeds to the coin buyback pot, the rest to the credit pot | yes |
| `exitToBuybackBps` | 5000 | 0 to 10000 | share of exit token from an eth lane exit to the buyback pot | yes |
| `buybackSlice`, `buybackDelay`, `keeperTipBps` | 1 eth, 25 blocks, 50 | 0.01 to 2 eth, 1 to 7200, 0 to 500 | coin buyback slice, minimum block gap, caller tip in bps of the slice | yes |
| `xRateCap`, `xRateFloor` | 9700, 3000 | floor <= cap <= 10000 | exit token bid in bps of score, phase 2 | yes |
| `xRateClimbPerHour`, `xRateDropPerCredit` | 100, 20 | 0 to 1000 each | exit bid climb per hour and drop per credit | yes |
| `xAuctionHalfLife` | 21600 | 600 to 2592000 s | exit token dutch auction price half life | yes |
| `exitSliceCredits` | 20 | 1 to 1000 | credits per exit slice | yes |
| `rateCap` | 123200000000000 | 1e11 to 1e15 (the rate bounds) | wei per whole point, about 6 times `rateStart` at launch. the eth rate never exceeds it: the price state is at most the lower of the ceiling and `rateCap`, `setRate` refuses a value above it, and lowering it below the live rate pulls the rate down to it at once (checkpoint first). the owner's "never pay more than this per credit". `rateStart` must not exceed it (preflight row, and the Core constructor reverts `BadRate`) | yes |
| `exitLaneToBuybackBps` | 0 | 0 to 10000 | share of exit token from an exit lane exit to the buyback pot, the rest to the exit bid pot. 0 keeps all of it in the bid pot | yes |
| `feeToBuybackBps` | 0 | 0 to 10000 | share of the eth the Core receives as pool fees (`receive()`) that goes to the coin buyback pot, the rest to the credit pot. 0 keeps all of it in the credit pot. last field of the struct | yes |

two more owner functions, each with its own event: `setRate(uint256)` resets the current eth limit (inside the rate bounds and at most `rateCap`, checkpoints first, keeps the last fill time) and `setXRate(uint256)` sets the exit bid (inside the settings floor and cap).

launch inputs status. filled: `owner` and `creator` (both 0xCB43078C32423F5348Cab5885911C3B5faE217F9, the factory owner), `name` and `symbol` (`CC`), `salt` (keccak256 of the string CC), the router payee (the creator address). open: the five v2 stack addresses (zero until v2 is live) and the launch day `rateStart`. because the owner is the creator, preflight prints the warning row `warn: owner differs from creator`; it never fails.

there is one config file, `script/config/mainnet.json`. the hash covers everything in it except the fee source (derived, never signed), so a changed launch value is a new signed hash.

config values (`script/config/mainnet.json`). the owner signs off each row.

| key | default | meaning |
|---|---|---|
| `stack.poolManager` | 0x000000000004444c5dc75cB358380D2e3dE08A90 | uniswap v4 pool manager |
| `stack.hook`, `factory`, `locker`, `escrow`, `mevModule` | zero until v2 is live | the v2 skim hook, the v2 factory (its owner is the signer), the locker, the fee escrow and the linear skim mev module. the deploy refuses zero |
| `stack.tickSpacing`, `stack.poolFee` | 200, 8388608 (0x800000) | pool key. spacing and the dynamic fee flag |
| `stack.auctionFactory` | 0x77aB853543286C9Cdd7dd6c01222A7cC4Ac93d63 | the pnd auction house factory. the Core creates its own house through it in the constructor. preflight needs code, a default fee of 0 and no house yet for the predicted core |
| `owner` | 0xCB43...17F9, the factory owner | Core owner (immediate owner functions, three one way locks, two step handover), router owner, token admin, and the only signer |
| `creator` | 0xCB43...17F9 | the one project reward slot of the locker. at lp fee 0 the locker has no lp income to hand out |
| `name`, `symbol` | `CC`, `CC` | coin name and symbol. deploy refuses an empty name |
| `salt` | keccak256 of the string CC (0x56d96069...258a9c) | user salt of the coin address. any nonzero value, change it if the predicted address is taken |
| `rateStart` | 2.0554e13 | opening bid in wei per whole point, bounded to [1e11, 1e15] and to `settings.rateCap`. launch day rule in section 1 |
| `settings` | the table above | the launch value of every economic setting, in the hash |
| `sale` | `false, 11000, 100, 10800, 7500` | the controller sale settings, constructor arguments of `ControllerV1`: `buyOnly`, `startBps`, `stepBps`, `stepEvery` (seconds), `floorBps`. `floorBps` must not be below `saleFloorBps` |
| `launch.supply` | 1,000,000,000e18 | coin supply, all of it in the launch position. must equal the Core `SUPPLY`. the locker burns about 3,551 wei of dust to the dead address at the launch, so the live supply is a hair under it |
| `launch.startTick` | -175000 | `tickIfToken0IsArtCoin`, about 40M coin per eth. a multiple of the spacing and equal to `positionLower` |
| `launch.positionLower`, `positionUpper` | -175000, 887200 | the one launch position, configured as if the coin were token0. the coin is currency1 of the pool, so the ticks on chain are mirrored (-887200 and 175000), postflight checks the mirrored values |
| `launch.baselineSkimBps` | 6900 | baseline skim in hundredths of a basis point of volume: 6.9 points. a trader pays 6.9 percent in total |
| `launch.bountyBps` | 9000 | share of the baseline skim that goes to the bounty recipient, the router: 6.21 points of volume. the sniper extra goes whole to the bounty recipient |
| `launch.maxReferralBps`, `launch.lpFee` | 0, 0 | referral cap and extra lp fee, both pinned to 0. an lp fee of 0 needs the owner command of step 3 |
| `launch.sniperStartBps`, `launch.sniperSeconds` | 90000, 1800 | the mev module skim decays linearly from 90 points to the baseline over 30 minutes |
| `launch.protocolBps` | 2000 | the `protocolBps` argument of `deployTokenAsOwner`, pinned to 2000. the protocol leg belongs to the launcher protocol, a separate business from this engine: it is never the engine owner's income. preflight warns when the factory default differs |
| `launch.restricted`, `launch.allowed` | true, empty | the coin launches restricted. the allowlist holds only what the factory and this launch add: the Core (decision 29), the locker and the escrow. no config entries, the factory default allowlist must be empty |
| `router.creatorPayee`, `payeePpm` | 0xCB43...17F9, 161031 | the one payee of the router at launch: 161,031 parts per million of the gross amount of each flush, which is 1.0 point of volume out of the 6.21 the router receives (the tip is taken from the engine's part, not from the payee). the owner repoints it later with `setPayees` |
| `router.tipPpm`, `tipCap` | 5000, 0.005 eth | the `flush` caller's tip: 0.5 percent of the flush, capped. the router default, so no `setTip` is sent |
| `overrides.bounty`, `overrides.openFactory` | false, false | `bounty` allows any bounty bps below 10000, `openFactory` allows a non deprecated factory. both inside the hash |

pinned rules. preflight fails (and `Deploy` stops) on any value outside them. each row is a check in `script/Checks.sol`.

| rule | pinned to | override |
|---|---|---|
| tick spacing, pool fee | 1 to 32767, the dynamic fee flag 0x800000 | none |
| `startTick`, `positionLower`, `positionUpper` | multiples of the spacing, `positionLower` equals `startTick`, `positionUpper` the highest usable multiple, lower below upper | none |
| `baselineSkimBps` | exactly 6900 | none |
| `bountyBps` | exactly 9000 | `overrides.bounty` |
| `maxReferralBps`, `lpFee` | 0 and 0 | none |
| `sniperStartBps`, `sniperSeconds` | 50000 to 90000 and above the baseline, 600 to 3600 | none |
| `protocolBps` | 2000 | none |
| restriction | restricted, no config allowlist entries, the factory default allowlist empty | none |
| factory deploy fee | at most 0.1 eth | none |
| factory | deprecated, so only the owner can launch | `overrides.openFactory` |
| factory minimum lp fee | at most the config lp fee (0 after the owner command) | none |
| router | payee share, tip and tip cap inside the router bounds (share at most 200,000 ppm, tip at most 20,000 ppm, cap at most 0.05 eth) | none |
| `owner`, `creator`, payees | not the dead address, a stack address or the mev module. WARN when owner and creator differ | none |
| `supply`, `rateStart`, `settings` | the Core `SUPPLY`, the rate bounds and `rateCap`, every field inside its bound | none |
| `stack.auctionFactory` | has code, default fee 0, no house exists yet for the predicted core | none |

a change of a pinned value means editing `script/Checks.sol` on purpose, in a reviewed commit. a pinned rule cannot know a value that is plausible but not the intended one (another start price, `owner` and `creator` swapped). those are covered by the sign off: preflight prints the `signoff:` rows, the owner signs them, and `CONFIG_HASH` is the one value `Deploy` needs in its env. the overrides are inside the hash too.

what the sign off table covers: owner, creator, the signer, the predicted router and core addresses, the opening bid, one row per setting, the router payee and tip, and the economics line (skim, bounty, sniper).

### mainnet gas cap per transaction

mainnet caps one transaction at 16,777,216 gas (EIP-7825). every transaction of this system fits, and preflight simulates the launch under that cap (a create2 collision burns every forwarded gas, so the simulation forwards exactly the cap). the deploy transactions, measured by the rehearsal on the pinned fork (execution plus code deposit, intrinsic and calldata): library 3,080,530, controller 1,017,857, router 1,130,952, core 5,447,926, launch 3,593,871 (value: the deploy fee), setEngine 47,654, setPayees 120,714, setSplitStart 25,451. the largest after the deploy, measured by `test/GasCap.t.sol` on the pinned fork:

| transaction | gas | share of the cap |
|---|---|---|
| `compose()`, eth lane, 80 credits, first compose | 9,303,091 | 55.4 percent |
| `composeExit()`, 80 credits | 8,973,045 | 53.4 percent |
| `overprint()`, scripted controller, 160 to 640 credits | about 1,371,000 | 8.2 percent |
| every other call (doors, buybacks, flush, owner calls, the house) | under 500,000 | under 3 percent |

`compose` and `composeExit` sit at about half the cap because the live Statements contract needs about 8 million gas for 80 credits (7.90 to 8.07 million across pages of real credits). a keeper must not hardcode a gas limit under 10 million for them. `sellForEth` and `sellForExitToken` take any number of credits: the cap stops a batch at about 116 credits (flat bid), 93 (score bid, `flatBps` 0) or 98 (exit bid), and a larger call simply reverts for its sender. the gas capped reads inside the Core use under half of their caps. `exitModule` is a stand in in these tests: what a real one spends inside `exit` is added to `exitStatement`, and the Core forwards it all the remaining gas.

## 3. verify on etherscan

the compiler settings are in `foundry.toml`: solc 0.8.30, evm cancun, via ir, optimizer 200 runs, `bytecode_hash = "none"`. the four contracts we own are the library `CoreLib` (`src/lib/CoreLib.sol`), ControllerV1, FeeRouter and Core. the coin, hook, factory, locker, escrow and auction house are artcoins and pnd contracts and verify on their own.

the library address is the CREATE2 address of the compiled code: take it from `jq -r '.libraries[0]' broadcast/Deploy.s.sol/1/run-latest.json | cut -d: -f3` or from the line `verify: library CoreLib at` that postflight prints. export it as `LIB`. the Core links against it, so verifying the Core needs `--libraries src/lib/CoreLib.sol:CoreLib:$LIB`. verify the library first, it has no constructor arguments. postflight prints the exact `--libraries` flag and the constructor args of the Core, the router and the controller (`verify:` lines), built from the config and the first controller, never from live storage.

the constructor arguments of the Core are `(owner, coin, controller, stack, rateStart, settings)`, where `stack` is the tuple `(poolManager, hook, tickSpacing, poolFee, factory, locker, escrow, auctionFactory, feeSource)` (the fee source is the router) and `settings` is the `Settings` tuple in the field order of the settings table:

```sh
export POOL_MANAGER=$(jq -r .stack.poolManager $LAUNCH_CONFIG) HOOK=$(jq -r .stack.hook $LAUNCH_CONFIG)
export LOCKER=$(jq -r .stack.locker $LAUNCH_CONFIG) ESCROW=$(jq -r .stack.escrow $LAUNCH_CONFIG)
export AUCTION_FACTORY=$(jq -r .stack.auctionFactory $LAUNCH_CONFIG)
export RATE_START=$(jq -r .rateStart $LAUNCH_CONFIG)   # OWNER, FACTORY, CORE, COIN, ROUTER, CONTROLLER, LIB as in sections 0 and 1
export SETTINGS="($(jq -r '.settings | [.flatBps,.avgScore,.dropPerCreditBps,.dropFloorBps,.climbPerMinBps,.ceilBps,.idleLoosenBps,.clampCredits,.spendCapBps,.bonusCapBps,.tipSavingsBps,.tipCapBps,.reimburseBps,.reimburseCapBps,.saleFloorBps,.auctionDuration,.exitAfter,.saleToBuybackBps,.exitToBuybackBps,.buybackSlice,.buybackDelay,.keeperTipBps,.xRateCap,.xRateFloor,.xRateClimbPerHour,.xRateDropPerCredit,.xAuctionHalfLife,.exitSliceCredits,.rateCap,.exitLaneToBuybackBps,.feeToBuybackBps] | map(tostring) | join(",")' $LAUNCH_CONFIG))"
ARGS=$(cast abi-encode \
  "constructor(address,address,address,(address,address,int24,uint24,address,address,address,address,address),uint256,(uint16,uint32,uint16,uint32,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint32,uint16,uint16,uint128,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint16,uint64,uint16,uint16))" \
  $OWNER $COIN $CONTROLLER \
  "($POOL_MANAGER,$HOOK,200,8388608,$FACTORY,$LOCKER,$ESCROW,$AUCTION_FACTORY,$ROUTER)" \
  $RATE_START "$SETTINGS")

forge verify-contract $LIB src/lib/CoreLib.sol:CoreLib --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir

forge verify-contract $ROUTER src/FeeRouter.sol:FeeRouter --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir \
  --constructor-args $(cast abi-encode "constructor(address)" $OWNER)

forge verify-contract $CORE src/Core.sol:Core --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir \
  --libraries src/lib/CoreLib.sol:CoreLib:$LIB \
  --constructor-args $ARGS

forge verify-contract $CONTROLLER src/ControllerV1.sol:ControllerV1 --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir \
  --constructor-args $(cast abi-encode "constructor(address,(bool,uint16,uint16,uint32,uint16))" $CORE "($(jq -r '.sale | [.buyOnly,.startBps,.stepBps,.stepEvery,.floorBps] | map(tostring) | join(",")' $LAUNCH_CONFIG))")
```

`forge verify-contract` needs `ETHERSCAN_API_KEY`. compare `ARGS` with the printed `verify: core constructor args` before you submit. `CONTROLLER` must be the first controller, not what `controller()` answers now.

verify without the network, to prove that the files you submit are the ones that were broadcast:

```sh
INPUT=$(jq -r '[.transactions[] | select(.contractName=="Core")][0].transaction.input' broadcast/Deploy.s.sol/1/run-latest.json)
CODE=$(forge inspect src/Core.sol:Core bytecode --libraries src/lib/CoreLib.sol:CoreLib:$LIB)
[ "${CODE}${ARGS#0x}" = "$INPUT" ] && echo creation input equal
```

if etherscan rejects `--libraries`, use the standard json route: `forge verify-contract $CORE src/Core.sol:Core --libraries src/lib/CoreLib.sol:CoreLib:$LIB --show-standard-json-input > core.json` and upload it on the etherscan page "Solidity (Standard-Json-Input)" with compiler 0.8.30, optimizer 200 runs and the constructor args hex without the `0x`.

## 4. after launch

all times are from the launch block. the anti sniper window is `launch.sniperSeconds` long (1800 seconds), measured from pool creation, which is the launch transaction. the router starts sharing with payees at `splitStart`, exactly the launch time recorded by the factory plus the window (set by `Resume` after the launch is mined, postflight fails on any difference): the first `flush` at or after it still sends everything to the engine and turns the split on, so eth that arrived during the window is never shared.

### the router, owner commands

the router is the bounty recipient of the pool: the v2 hook pushes the bounty to it with a 2,300 gas stipend, so its `receive` does nothing and the eth sits there until someone calls `flush()`. the router owner (the config owner) can change everything below until `lock()`. read first:

```sh
export ROUTER=0x...   # printed by Deploy
cast call $ROUTER "engine()(address)" --rpc-url $MAINNET_RPC_URL
cast call $ROUTER "payees()(address[],uint32[])" --rpc-url $MAINNET_RPC_URL
cast call $ROUTER "tipPpm()(uint32)" --rpc-url $MAINNET_RPC_URL; cast call $ROUTER "tipCap()(uint96)" --rpc-url $MAINNET_RPC_URL
cast call $ROUTER "splitStart()(uint64)" --rpc-url $MAINNET_RPC_URL; cast call $ROUTER "splitOn()(bool)" --rpc-url $MAINNET_RPC_URL
cast call $ROUTER "locked()(bool)" --rpc-url $MAINNET_RPC_URL; cast call $ROUTER "totalOwed()(uint256)" --rpc-url $MAINNET_RPC_URL
```

| command (as the router owner, `--ledger` or `--account`) | effect |
|---|---|
| `cast send $ROUTER "setPayees(address[],uint32[])" "[$SPLITTER]" "[161031]"` | replaces the payee list. up to four entries, each nonzero, total at most 200,000 ppm of the gross amount flushed. this is how the launch payee (the creator address) is pointed at a splitter contract later, or split in two: `"[$A,$B]" "[80515,80515]"`. a payee contract is called with 100,000 gas and a plain call; a payee that reverts or runs out is credited in `owed` and pulls it with `claim(payee)`, it can never block a flush |
| `cast send $ROUTER "setTip(uint32,uint96)" 5000 5000000000000000` | the flush caller's tip: parts per million (at most 20,000) and a cap in wei (at most 0.05 eth) |
| `cast send $ROUTER "setSplitStart(uint64)" $TS` | the time of the first flush that turns the split on. only while the split is off |
| `cast send $ROUTER "setEngine(address)" $NEW_ENGINE` | points every future flush at another contract (it must have code). the old engine keeps what it already holds. this is the one owner switch that directs value to an address the owner picks: a stolen router owner key can redirect the fee stream until the router is locked |
| `cast send $ROUTER "lock()"` | closes every setter above for good. needs an engine. do it only when the payees and the engine are final |
| `cast send $ROUTER "transferOwnership(address)" $MULTISIG`, then `acceptOwnership()` from it | two step handover, never locked. run postflight with `ROUTER_CHANGED=1` after a change |

### keeper duties

anyone can run these. none is needed for safety, they keep the engine moving.

| duty | call | note |
|---|---|---|
| move the fee eth | `router.flush()` | pays the caller the tip, shares with payees once the split is on, sends the rest to the Core, which books it as fees. reverts only while the engine is unset or the engine call fails. an empty balance is a no op |
| collect the creator slot | `locker.collectRewards(coin)` | pays the caller a keeper reward and pushes the recipient shares. at lp fee 0 there is no lp income, so this moves only dust |
| book stray eth | `core.skim()` | books eth the Core received from anyone but the router (for example a partial fill refund from the escrow, claimed with the escrow's `claim`) |
| compose statements | `core.compose()`, `core.composeExit()` | the caller is repaid gas. set the gas limit above 10 million (about 8 million are used for 80 credits, the cap is 16,777,216) |
| collect sales | `core.collectSales()` | moves statement sale proceeds into the pots. `buyback()` calls it first |
| buyback | `core.buyback()` | burns coin bought with one slice of the buyback pot, caller tip `keeperTipBps` |
| reprice | `core.repriceStatement(sid)` | permissionless, listings with no bid |
| claim owed | `router.claim(payee)` | pays a payee whose send failed, to the payee |

| when | what happens | what to do |
|---|---|---|
| launch block | the pool is live. the skim is 90 points of volume; the bounty share of the baseline and the whole extra go to the router, which holds the eth until someone calls `flush`, and the router shares none of the window with payees. the rate sits at `rateStart` and does not move while the pot is unfunded | read postflight. nothing else is needed |
| first buy | the bounty eth lands in the router. the first `flush()` sends the tip to the caller and the rest to the Core, which books it into `ethPot` (`FeesAdded` fires) | call `flush()`, then check `ethPot` and the Core balance are equal |
| funded | the pot is funded when `ethPot * spendCapBps / 10000 >= avgScore * rate / 1e4`, so at `rateStart` 2.0554e13 the pot needs 4.45e16 wei, and at 1e11 it needs 2.17e14, at 1e15 it needs 2.17e18. from that moment the bid climbs lazily, `climbPerMinBps` a minute (50), compounded, up to the lower of `rateCap` and `ceilBps` (125 percent) of the rate paid at the last fill, loosened by `idleLoosenBps` (2 percent) per 10 idle minutes, and not past the clamp. the price paid is the read: the price state lowered to the clamp of `clampCredits` (20) average credits of hourly room. the funded rule is logic, not a setting. there is no inventory gate: unsold statements never stop the buying. there is no retroactive climb for the unfunded time | watch `funded()` and `ethRate()` |
| 30 minutes | the anti sniper window ends and the skim is the 6.9 point baseline. the public can add liquidity to the pool after it | none |
| any time after funded | credit holders can call `sellForEth` into the bid. a credit sells when its ceiling fits the hourly cap, 20 percent of the pot at the window open. the ceiling is flat per credit at launch (`flatBps` 10000): `avgScore * rate / 1e4 * (1 + bonus)`, whatever the credit's score | check that real credits clear. at the clamp an average credit without bonus fits a fresh window |
| the clamp | what the engine pays never exceeds the rate where 20 percent of the pot buys `clampCredits` (20) average credits, so a credit always fits the hourly cap. the clamp lowers the price paid and never the price state: with a small pot the engine pays less, the price state keeps its value, and a larger pot puts the read back at the price state | none |
| with no fills | the bid climbs 0.5 percent a minute up to 125 percent of the rate paid at the last fill, and that ceiling grows 2 percent per 10 idle minutes, so a bid that nobody hits follows the market up after a gap | none |
| statements | each eth lane compose lists the statement on the Core's own auction house. the controller prices it: 110 percent of the cost at listing, falling 1 point every 3 hours to 75 percent at hour 105 (the `sale` block of the config). in auction mode that price is the house reserve (a first bidder calls `repriceStatement(sid)` to take the current price, the auction runs 24 hours from the first bid); in buy only mode `ControllerV1.buy(sid)` pays the asking price and gets the statement at once through `Core.sellTo`. the hard floor `saleFloorBps` (7500) binds both. the proceeds are credited to the Core and move into the pots when anyone calls `collectSales()` (`buyback()` calls it first). a statement with a bid cannot be cancelled or sold by `buy`. `syncStatement(sid)` clears the record of a sold statement and relists a returned one | check `statementStatus(sid)` and `priceOf(sid)` after the first compose, then that the first sale clears and `collectSales()` moves the eth |
| eth in `ethToBuyback` | it fills from statement sales (`collectSales`) and from pool fees (`feeToBuybackBps`, launch 0), so with the launch settings only after the first auction. `buyback()` then burns coin, one slice of at most 1 eth every 25 blocks | anyone may call, 0.5 percent tip |
| settings | the owner may change any setting at once with `setSettings(Settings)` and the eth limit with `setRate`, the exit bid with `setXRate`. the owner (a plain address with immediate functions, no timelock) cannot transfer eth, credits, statements or exit token out of the Core by any setting (the one owner directed transfer is `rescueCoin`, coin only): tips, reimbursements and keeper rewards are capped and everything else is spent only by the engine's own doors. the owner does set the price the engine pays, so a dishonest owner or a stolen owner key could sell credits to the engine at an inflated limit and drain the pot at the bounded pace of docs/ARCHITECTURE.md section 10 (the owner accepted this, holders trust the owner key). use a multisig as owner | after any change read `settings()` and the `SettingsSet` event |
| phase 2 | exit doors stay shut while the exitModule slot is empty. the owner calls `setExitModule(address)` at once, and may call it again until `lockExitModule()`: a new module must report the same `exitToken()`, and `unitPerPoint` is read again on every set (naming the same address again is how a changed unit is taken over). `exitLaneToBuybackBps` (launch 0) sets the share of exit lane exits that goes to the coin buyback | set it only after the module is final. a later replacement is possible and takes effect in the same transaction, so lock it once the module is trusted |

housekeeping after launch.

| item | action |
|---|---|
| owner commands on v2 | the only one before the launch is `setMinLpFee(0)` (step 3 of section 1). nothing else is registered: no fee swapper, no escrow depositor, no extension, no factory admin |
| token admin | the owner holds it. on the restricted coin it can `setAllowed(account, bool)` (not the pool manager or the canonical hook, and the factory seeded entries cannot be removed), `unrestrict()` (one way, turns the restriction off for good, which opens side pools and lets volume bypass the skim, so it is a decision about fee income), `lock()` (freezes the allowlist and the restriction for good), set the image and metadata, `updateAdmin` and `renounceAdmin`. postflight warns while the allowlist is not locked. after a change run postflight with `COIN_CHANGED=1` |
| owner handover | `transferOwnership(multisig)` on the Core, then `acceptOwnership()` from the multisig, the same for the router. afterwards run postflight and resume with `OWNER_CHANGED=1` (and `ROUTER_CHANGED=1`, `COIN_CHANGED=1` for the router owner and the coin admin). postflight warns while a `pendingOwner()` is set |
| coin rescue | `core.rescueCoin(to, amount)`, owner only, for coin that arrived in the Core some other way (the Core is on the coin allowlist, so anyone can send it coin). it moves coin only, never eth, credits, statements or exitToken |
| credits and statements | the Core receives credits and statements through its own doors only. there is no door that moves a credit or a statement out except the engine's own sales, auctions and exits |
| the launch key | the factory owner key is also the deployer, there is nothing to revoke. sweep nothing from it, it is the owner |

### changing settings after launch

every setting of the table in section 2 is adjustable by the owner after launch, all at once, effective at once. the Core rejects a struct outside the bounds (`SettingsBounds`) and the pair rule (`xRateFloor` at most `xRateCap`). the owner signs with `--ledger` or `--account <name>`. `setSettings` takes the whole struct, so always read the live one first, change one field, send it all back. after a change postflight fails the row `core: settings equal the config` until you run it with `SETTINGS_CHANGED=1` (it turns a warning, the other rows stay strict). the same flag lets `Resume` run on a Core whose settings changed.

the script way (reads the live struct, prints a before and after table with the bounds, the calldata and the `cast send` line, sends only with `SEND=1` and `--broadcast` and when the signer is the Core owner):

```sh
export CORE=0x...                       # the live Core
SET_saleFloorBps=8000 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL           # dry run, sends nothing
SETTINGS_PATCH='{"saleFloorBps":8000,"auctionDuration":43200}' forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL   # a json patch, text or file path
SET_saleFloorBps=8000 SET_RATE=20000000000000 SEND=1 forge script script/SetSettings.s.sol --rpc-url $PRIVATE_RPC --broadcast --ledger   # sends setSettings and setRate
```

raising `saleFloorBps` is not atomic for an EOA owner. a listing keeps the reserve it was made with until `repriceStatement(sid)` runs on it, and anyone can bid at that old reserve first: after a bid the reserve and the sale price cannot change. so a listing that has a bid, or that gets one before its reprice lands, sells at its old reserve, below the new floor. this matters only when the new floor is above the current reserve of a listing: a fresh listing sits at 110 percent of cost with the launch settings, so a floor up to 110 percent needs no reprice. a lower floor or a lower reserve only helps bidders. `repriceStatement` is permissionless.

the script (`REPRICE=1`) closes the snapshot gap, not that window. it reads `heldStatements()` before the owner transaction. after `setSettings` it reads it again, reprices every listing without a bid whose house reserve is below what `repriceStatement` would set now, and reads again, for at most 4 passes. a dry run prints one `cast send` per reprice. it ends with a table of every listing still below the new floor and why (it has a bid, it appeared during the run, the controller cannot price it) and prints a `WARNING` when the table is not empty. `STRICT=1` makes a dry run revert while anything remains. a send run never reverts, that would drop the broadcast. two limits of a script: a forge run reads its own simulated state after `setSettings`, so a statement composed on chain after the run started is not seen by that run, and one transaction holds at most about 300 reprices (about 50,000 gas each, cold, against the cap of 16,777,216 per transaction), so a longer list goes in several batches. so run it, wait until the transactions are mined, and run the same command again: the rerun reads the chain fresh and reprices what appeared meanwhile.

an owner that is a multisig can batch `setSettings` and the reprices in one transaction, so no bid can land between them for the listings it knows. it still cannot include a statement composed after its snapshot, so it must rerun the script once after the batch is mined. the command, as a dry run first:

```sh
SET_saleFloorBps=12000 REPRICE=1 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL      # dry run, lists the repriceStatement calls
```

`SET_<field>` and `SETTINGS_PATCH` name the fields of the table, the single variables win over the patch, `SET_RATE` and `SET_XRATE` add `setRate` and `setXRate`, `REPRICE=1` adds the reprices. checked on the anvil fork: the table showed the live value 9000 and the new one 8000, the broadcast from the impersonated owner changed `saleFloorBps` and the rate.

the by hand way, with `cast`. the tuple type is the one of the constructor in section 3 (`T` below). field 13 is `saleFloorBps`, field 27 is `rateCap`, field 28 is `exitLaneToBuybackBps` and field 29 is `feeToBuybackBps`, count the fields in the order of the table:

```sh
T="(uint16,uint32,uint16,uint32,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint32,uint16,uint16,uint128,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint16,uint64,uint16,uint16)"
S=$(cast call $CORE "settings()($T)" --rpc-url $MAINNET_RPC_URL | sed -E 's/ \[[^]]*\]//g')   # the live struct, plain numbers
NEW=$(echo "$S" | tr -d '() ' | awk -F, -v OFS=, '{$13=8000; print "(" $0 ")"}')                # change field 13 only
echo "$S"; echo "$NEW"                                                                          # read both before sending
cast send $CORE "setSettings($T)" "$NEW" --rpc-url $PRIVATE_RPC --ledger                        # as the owner
cast send $CORE "setRate(uint256)" 20000000000000 --rpc-url $PRIVATE_RPC --ledger               # the eth limit, wei per point, 1e11 to 1e15
cast call $CORE "settings()($T)" --rpc-url $MAINNET_RPC_URL; cast call $CORE "ethRate()(uint256)" --rpc-url $MAINNET_RPC_URL
```

`setRate` checkpoints the rate first, keeps the last fill time and resets the limit to the new value. `setXRate(uint256)` sets the exit bid inside the settings floor and cap. read back with `settings()` and `ethRate()`, and the `SettingsSet` event. both flows were run on the anvil fork as the impersonated owner.

### owner doors, locks and the handover

there is no timelock. every owner door works at once and logs an event.

trust: with no delay the owner key controls everything at once. it can point the exit module at a contract that returns dust and take every statement, swap the controller and sell every statement at the hard floor, lower the hard floor to its bound, and overpay for credits as documented above. a stolen owner key means the whole engine at once. the owner chose this because the system is new and must adapt fast, and changes are announced off chain. holders trust the owner key fully. use a multisig as owner, and close each door with its lock once it is final.

| door | effect | event |
|---|---|---|
| `setController(address)` | replaces the controller, never zero. reverts `Locked("controller")` after `lockController()` | `ControllerSet` |
| `setExitModule(address)` | sets or replaces the exit module, see the next section. reverts `Locked("exitModule")` after `lockExitModule()` | `ExitModuleSet` |
| `addTarget(address)`, `removeTarget(address)` | allowed `buyListing` targets. forbidden targets are refused on add. an add reverts `Locked("targets")` after `lockTargets()`, a removal always works | `TargetAdded`, `TargetRemoved` |
| `setSettings(Settings)`, `setRate(uint256)`, `setXRate(uint256)` | as in the section above. never lockable | `SettingsSet`, `RateSet`, `XRateSet` |

the three one way locks: `lockController()`, `lockExitModule()` (reverts `NoExitModule` while the slot is empty, so phase 2 cannot be locked out by accident) and `lockTargets()`. each is irreversible and logs `ControllerLocked`, `ExitModuleLocked` or `TargetsLocked`. the settings and the sale settings of the controller stay open after all three. a controller that was locked in can still be tuned through its own owner doors, but not replaced. lock a controller only after it is proven in use: one that was locked while it reverts, burns its gas or answers short can never be replaced, and then `repriceStatement`, `compose` and the relist after an overprint revert `BadPrice` for good (the relist of an unwound sale falls back to the hard floor, so redemption still works).

a stranger can raise a reserve, not only lower it, after an owner change that raises the asking price (the flip to buy only mode, a higher `startBps`): `repriceStatement` sets the reserve to the current ask, and it needs that owner action first. a bidder who priced the old reserve should reprice or bid again before the flip is announced.

the owner handover has two steps: `transferOwnership(address to)` from the owner records `pendingOwner` (`OwnershipTransferStarted`), then `acceptOwnership()` from `to` makes it the owner (`OwnershipTransferred`). passing the zero address clears a pending handover. there is no renounce. move the owner to a multisig this way, check that the multisig can send a transaction (accept from it) before relying on it. `ControllerV1` reads the live owner of the Core, so its sale settings follow the handover.

### the sale controller

`ControllerV1(core, sale)` prices statements. the `sale` tuple is `(buyOnly, startBps, stepBps, stepEvery, floorBps)`, launch `(false, 11000, 100, 10800, 7500)`. the asking price of a statement is `cost * max(floorBps, startBps - stepBps * (age / stepEvery)) / 10000`. owner doors, at once, each with an event: `setBuyOnly(bool)`, `setStartBps(uint16)` (1000 to 40000, not below `floorBps`), `setStepBps(uint16)` (0 to 5000), `setStepEvery(uint32)` (1 minute to 30 days), `setFloorBps(uint16)` (1000 to `startBps`). the owner is the Core owner, read live.

modes. auction mode (`buyOnly` false) uses the asking price as the reserve of the house auction. buy only mode: `buy(uint256 sid)` pays at least `priceOf(sid)` and gets the statement through `Core.sellTo`, the excess is refunded, it reverts while a bid is live. flip the mode with `setBuyOnly`. the Core floor `saleFloorBps` binds whichever the controller says, so a low controller price cannot sell below it. a price change reaches an open listing only through `repriceStatement(sid)` (anyone may call it, listings with no bid).

verify args of the controller: `cast abi-encode "constructor(address,(bool,uint16,uint16,uint32,uint16))" $CORE "($(jq -r '.sale | [.buyOnly,.startBps,.stepBps,.stepEvery,.floorBps] | map(tostring) | join(",")' $LAUNCH_CONFIG))"`.

### changing the exit module or its unit

`setExitModule` may run any number of times until `lockExitModule()`, each at once. a later module must report the same `exitToken()` (else `ExitTokenChanged`). `unitPerPoint` is read again on every set, so naming the same address again is how a changed unit is taken over. a later set never touches the exit auction price or clock, clears the allowed target flag of the module, checkpoints the exit rate under the old unit and resyncs the funded flag. pots, piles and held statements are untouched. `exitToBuybackBps` is the eth lane share and `exitLaneToBuybackBps` is the exit lane share.

runbook:

1. a unit FALL: the exit token bid keeps paying the old unit until the set runs, so lower `xRateCap` and the rate (`setSettings`, `setXRate`) first, in the same batch ahead of `setExitModule`, and restore them after.
2. a unit RISE: the slice gets larger (`exitSliceCredits * avgScore * unit`), so fewer fills sell more exit token at one price. lower `exitSliceCredits` in the same batch as `setExitModule`. the exit rate is not clamped by a rise, so the funded flag turns false and sales revert `PotTooSmall` until `setXRate` lowers the rate.
3. call `setExitModule` with the new module (or the same address after its unit changed).
4. the opening price check (the price computed from the new unit must be at least 1e12) also bounds how high a later unit may go, about 1.15e25 at launch settings, and moves with `exitSliceCredits` and `avgScore`. a unit above it reverts `BadModule`.
5. after the set read back `exitModule()`, `unitPerPoint()`, `xRate()`, `exitAuctionQuote()` and the `ExitModuleSet` event. when the module is final call `lockExitModule()`.


## 5. what cannot change after launch, and the v2 surface

fixed for the life of the pool, by the artcoins contracts. neither this system nor the owner can change them:

| fixed | why it matters |
|---|---|
| the baseline skim (6.9 points of volume), `bountyBps` (9000), the lp fee (0), the referral cap (0), the sniper schedule (90 points falling to the baseline over 30 minutes) | set in the hook's skim config and the mev module schedule when the pool is created. a trader's total cost is fixed |
| the bounty recipient is the router | the pool's fee stream always goes to this router address. the router can point it at another engine (below), nothing else can change the recipient. a new engine can take over the fee stream, which is how a later engine migrates: build the new Core with the same router as its `feeSource`, then `router.setEngine(newCore)`. that works only while the router is unlocked, so do not call `lock()` while a migration is possible |
| the launch position (one position, the full range from the start tick) and the locker reward slots (the creator slot and the protocol slot) | set by the locker at the launch. the position cannot be moved or widened |
| the protocol leg (`protocolBps` 2000, the factory floor share of the skim) | belongs to the launcher protocol and its recipient. it is a separate business from this engine and its owner, it is never the engine's or the owner's income, and nothing here changes it |
| the coin: name, symbol, supply, canonical hook and pool, the pinned allowlist seeds (the locker and the escrow) | immutable in the token. the Core is on the allowlist at launch (decision 29) and the owner may add or remove other entries as token admin until `lock()` |
| the Core: its stack addresses and the fee source (immutables), `SUPPLY`, the rate bounds, the linked `CoreLib`, the auction house | the Core is not upgradeable. a different stack or fee source is a new Core |
| what no owner door can reach | eth, credits, statements and exitToken leave the Core only through its own sales, auctions and exits. coin leaves only through the buyback burn and the owner's `rescueCoin` |

changeable by the owner until the one way locks: the settings and the rates (never lockable), the controller (`lockController`), the exitModule (`lockExitModule`), the allowed targets (`lockTargets`), the router engine, payees, tip and split start (`router.lock`), the coin allowlist (`coin.lock`). irreversible once taken: each lock, `coin.unrestrict`, `coin.renounceAdmin`. a handover of the Core, the router or the coin admin to a multisig is not a lock, and each can be accepted back.

what the system calls on v2 (local copies in `src/interfaces/ArtCoinsV2.sol`, v2 repo commit 87a7522). if the live v2 differs from that commit, diff these first and rerun the rehearsal with new artifacts:

| contract | calls |
|---|---|
| factory | `deployTokenAsOwner(DeploymentConfigV2,uint16)`, `predictToken(address,DeploymentConfigV2)`, `owner`, `deprecated`, `deployFee`, `minLpFee`, `setMinLpFee` (owner command), `enabledHooks`, `enabledLockers`, `enabledMevModules`, `enabledEscrows`, `defaultAllowed`, `protocolRecipient`, `referralPayout`, `tokenDeployer`, `defaultProtocolFeeBps`, `poolManager` |
| hook | `poolInfo`, `skimConfig`, `globals`, `isLauncher`, `constantsHash` |
| token | `restricted`, `locked`, `isAllowed`, `isPinned`, `admin`, `originalAdmin`, `launcher`, `canonicalHook`, `canonicalPoolId`, `poolManager`, `burn`, `burnFrom` |
| locker | `tokenRewards`, `collectRewards`, `isLauncher`, `feeEscrow` |
| fee escrow | `claim`, `isDepositor`, `isCoreDepositor`, `balances` |
| mev module | `schedule`, `currentSkimBps`, `windowEnd`, `hook` |

behaviour the Core relies on: the hook pushes the bounty to the router with 2,300 gas, the router's `receive` is empty; on a restricted coin the hook grants the transient allowance each canonical swap needs, so a buyback burns what it buys in the same call; the bounty bps applies to the baseline skim only, the whole sniper extra goes to the bounty recipient.

what cannot be finished until v2 is on mainnet: the five v2 stack addresses in the local config, the `setMinLpFee(0)` command, preflight, the dry run and the broadcast against the real stack, etherscan verification, and the postflight and a first `flush` on real state. before step 4, compare the live hook `constantsHash()` and the factory runtime code with the vendored artifacts the rehearsal used (`test/v2-artifacts/README.md`).

## 6. when a transaction fails half way

`Deploy` sends, in order: the library (CREATE2 through the deterministic deployer, one nonce), the controller, the router (engine unset), the core (its constructor creates the auction house), the launch through the factory, then the router setup: `setEngine(core)`, `setPayees`, and `setTip` (skipped at the default tip). then `Resume` sends `setSplitStart` once the launch is mined (the launch time on chain plus the window). every state between them is safe: the library is stateless, an orphan controller or router is inert, an orphan core holds nothing, and after the launch the router holds fee eth safely until an engine is set. nobody else can launch to the predicted coin because the coin address depends on the sender (`predictToken(sender, config)`) and `deployTokenAsOwner` is owner only. do not rerun `Deploy` after it stopped past the library, a rerun takes new nonces and deploys a second system.

first read what is on chain (`export CORE=...`, the address `Deploy` printed or the transaction named Core in `broadcast/Deploy.s.sol/1/run-latest.json`):

```sh
cast code $CORE --rpc-url $MAINNET_RPC_URL | head -c 12    # 0x... means the core exists
export COIN=$(cast call $CORE "COIN()(address)" --rpc-url $MAINNET_RPC_URL)
export ROUTER=$(cast call $CORE "FEE_SOURCE()(address)" --rpc-url $MAINNET_RPC_URL)
cast code $COIN --rpc-url $MAINNET_RPC_URL | head -c 12    # 0x means the launch is not sent
cast call $ROUTER "engine()(address)" --rpc-url $MAINNET_RPC_URL     # zero until setEngine
cast call $ROUTER "payees()(address[],uint32[])" --rpc-url $MAINNET_RPC_URL
cast call $ROUTER "splitStart()(uint64)" --rpc-url $MAINNET_RPC_URL   # zero means never
```

| failure point | state on chain | recovery |
|---|---|---|
| 0. only the library sent | the library on chain, stateless, the nonce moved by one | rerun `Deploy` (the one case where a rerun is right). preflight sees the library, forge skips it and the addresses are the ones preflight prints now |
| 1. controller sent, no router | an orphan controller, inert | rerun `Deploy` (new controller, router and core). the old controller stays orphaned |
| 2. controller and router sent, no core | an orphan router with no engine and an orphan controller. the coin does not exist | rerun `Deploy`. the old router never received anything |
| 3. core sent, launch not sent (`cast code $COIN` empty) | the core, its empty auction house, the controller and the router. the core holds 0 | `Resume`, stage 1. it sends the launch and the router setup. needs the factory fee in the owner's balance and the factory minimum lp fee at 0 |
| 4. launched, router engine not set (stage 2) | the pool is live and tradeable. fee eth collects in the router and waits, `flush` reverts `NoEngine`. nothing is lost | `Resume` sends the setup |
| 5. engine set, payees, tip or split start missing (stage 3). this is the normal state right after `Deploy`: the split start is always the missing one | fees reach the Core through `flush`, with no payee share. an unset split start means the split never starts | `Resume` sends the missing setters, the split start from the mined launch time |
| 6. all done (stage 4) | as in the config | `Resume` is a no op |

the script detects the stage from the chain and sends only the missing steps, then runs postflight. run it as the same signer (`DEPLOYER` set, the script refuses another signer) with the same config and `CONFIG_HASH`:

```sh
CORE=$CORE DEPLOYER=$DEPLOYER CONFIG_HASH=$CONFIG_HASH forge script script/Resume.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --ledger
```

it prints `stage found` (0 no core, 1 core only, 2 launched, 3 router setup missing, 4 done). it refuses to run when there is no Core at `$CORE`, when the Core was not built from this config (owner, rate start, stack, coin prediction), when its settings differ from the signed ones (`SETTINGS_CHANGED=1` on purpose), when the signer is not the router owner, or (stage 1) when the preflight rows for the factory fail. `OWNER_CHANGED=1`, `LOCKS_CHANGED=1`, `ROUTER_CHANGED=1` and `COIN_CHANGED=1` name a change the owner made since the launch.

the same by hand, as the owner, if the script cannot be used. each is the single transaction of that point, in this order:

```sh
# point 3: send the saved launch transaction (the calldata is in the broadcast file) with the live fee
export LAUNCH_INPUT=$(jq -r '[.transactions[] | select((.function // "") | startswith("deployTokenAsOwner"))][0].transaction.input' broadcast/Deploy.s.sol/1/run-latest.json)
cast send $FACTORY $LAUNCH_INPUT --value $(cast call $FACTORY "deployFee()(uint256)" --rpc-url $MAINNET_RPC_URL) --rpc-url $PRIVATE_RPC --ledger
# points 3 to 5: the router setup, the commands of section 4
cast send $ROUTER "setEngine(address)" $CORE --rpc-url $PRIVATE_RPC --ledger
cast send $ROUTER "setPayees(address[],uint32[])" "[$OWNER]" "[161031]" --rpc-url $PRIVATE_RPC --ledger
cast send $ROUTER "setSplitStart(uint64)" $(( $(cast block --field timestamp --rpc-url $MAINNET_RPC_URL) + 1800 )) --rpc-url $PRIVATE_RPC --ledger   # by hand only: the launch time plus 1800, take the launch time from the factory record, not the block time of today
```

then run step 8 (postflight). after a failed launch transaction the Core is still valid, so a retry of that one transaction is right. the broadcast file `broadcast/Deploy.s.sol/1/run-latest.json` is gitignored and holds the signed data, keep it private.

a transaction pending or dropped in the relay: compare `cast nonce $DEPLOYER --rpc-url $MAINNET_RPC_URL` with `cast nonce $DEPLOYER --block pending --rpc-url $MAINNET_RPC_URL`. when they differ a transaction is still pending, wait for it. if the relay dropped it, the nonce does not move and the state is the one the table reads, resume from it. never rerun the whole script while one is pending.
