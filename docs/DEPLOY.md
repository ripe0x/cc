# deploy runbook

this is the launch runbook for branch `artcoin`. the system launches on whichever artcoins version is current at deploy time. everything that depends on the artcoins version lives in the `stack` block of `script/config/mainnet.json`, the Core takes it as a constructor argument and nothing in `src/` hardcodes an artcoins address.

naming rule: only `exitModule` and `exitToken`. never name or describe them anywhere.

## 0. what you need

| item | note |
|---|---|
| deployer key | a fresh key that only does this launch, in `PRIVATE_KEY` (or use `--account` or `--ledger` on the commands that sign). it needs the factory deploy fee (0.069 eth at the pin, read live) plus gas for five transactions, about 9.94M gas measured, so 0.079 eth at 1 gwei, 0.119 at 5 gwei, 0.268 at 20 gwei. preflight requires the fee plus 11M gas at twice the base fee |
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
export DEPLOYER=0xYourDeployerAddress           # the address of PRIVATE_KEY
# set later: CONFIG_HASH (step 3), CORE, COIN, CONTROLLER (step 7), OWNER, CREATOR from the config
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
| 1 | local config | pick one of the two tracked files, `script/config/mainnet.json` (the engine as specified) or `script/config/mainnet.recommended.json` (the simulation's `gate20constants` economics, see the economic dials table in section 2), and `cp` it to `script/config/local.json` (gitignored, never edit the tracked files). edit `local.json`: `owner`, `creator`, `name`, `symbol`, `salt`, and `rateStart` by the launch day rule below. `export LAUNCH_CONFIG=script/config/local.json`. review every row of the sign off tables in section 2 |
| 2 | rehearse the exact file on the latest block | `REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv`. it reads `LAUNCH_CONFIG`, fills only the placeholders the file leaves unset, and runs preflight, the whole deploy, postflight and a trading smoke. both tracked config files pass it (`LAUNCH_CONFIG=script/config/mainnet.recommended.json REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` for the second) |
| 3 | preflight, first run, and the sign off | `DEPLOYER=$DEPLOYER forge script script/Preflight.s.sol --rpc-url $MAINNET_RPC_URL`. the only failure allowed is `factory: deployer may launch`, until the factory owner acts. read the `signoff:` rows, the owner signs them, then `export CONFIG_HASH=0x...` with the printed `CONFIG_HASH=` value. that one value stands for the whole config |
| 4 | the factory owner enables the deployer | from the factory owner, `cast send $FACTORY "setAdmin(address,bool)" $DEPLOYER true --rpc-url $MAINNET_RPC_URL --ledger` (or `--account <name>`). keep the factory `deprecated`. confirm: `cast call $FACTORY "admins(address)(bool)" $DEPLOYER --rpc-url $MAINNET_RPC_URL` prints true |
| 5 | preflight, second run | the same command as step 3. it must print every row ok and exit 0, and print the same `CONFIG_HASH` |
| 6 | dry run | `forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --sender $DEPLOYER`. needs `CONFIG_HASH` in the env. simulates all five transactions and runs preflight and postflight inside the script. nothing is sent. forge prints "Estimated amount required", which excludes the factory fee sent as value, add the fee from the `factory: deployer balance` row |
| 7 | broadcast through the private rpc | after the rpc test of section 0: `forge script script/Deploy.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --private-key $PRIVATE_KEY`. note the printed core, coin and controller addresses and `export CORE=... COIN=... CONTROLLER=...`. if anything stops half way, do not rerun, go to section 6 |
| 8 | verify on etherscan | section 3 |
| 9 | postflight | `CORE=$CORE DEPLOYER=$DEPLOYER forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. every row must be ok. it prints the constructor args and the config hash, which must be the signed `CONFIG_HASH` (set it in the env to have the script check it). run it inside the anti sniper window if you can: the skim readback of the sniper start and duration works only then |
| 10 | the factory owner revokes the deployer | from the factory owner, `cast send $FACTORY "setAdmin(address,bool)" $DEPLOYER false --rpc-url $MAINNET_RPC_URL --ledger`. an admin can also set hooks, lockers and mev modules and claim team fees, so do this right after postflight. then `REQUIRE_REVOKED=1 CORE=$CORE DEPLOYER=$DEPLOYER forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL` must pass: the row `deployer still factory admin` fails until the revoke is done |
| 11 | first actions after launch | section 4 |

the launch day rule for `rateStart`. `rateStart = (flat market price of one credit in wei) / 1600`, bounded to [1e11, 1e15] by the Core. the flat price is the median of the last 24 hours of paid sales. for the default 5.6e12 the flat price is 8.96e15 wei, 0.00896 eth (the simulation in docs/SIMULATION.md used 0.0089). never go above price / 800. one line to read a recent median from the chain, from any rpc that serves logs (`$PRIVATE_RPC` does), it samples the last 60 transactions that moved a Credit and prints the median of the nonzero eth values they carried in wei:

```sh
H=$(cast block-number --rpc-url $MAINNET_RPC_URL); cast logs --rpc-url $PRIVATE_RPC --address 0x97630aA70AB14ed9883B41dAfccBc11349723043 --from-block $((H-7200)) "Transfer(address,address,uint256)" --json | jq -r '[.[].transactionHash] | unique | .[-60:] | .[]' | while read t; do cast tx $t value --rpc-url $PRIVATE_RPC; done | grep -v '^0$' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
```

the explorer way: open the Credits collection on OpenSea, Activity, filter Sales, look at the last 24 hours and take the median price. divide by 1600, round, put it in `rateStart`. the value only decides how soon the pot starts working (a higher bid buys the first credits sooner), it does not change where the system ends up: in the simulation statements sold, burn and locked eth stayed within seed noise across the whole sweep. the default already sits in the safe range, it only waits longer when the market is above it.

what the scripts do.

| script | does |
|---|---|
| `Preflight.s.sol` | read only. chain id 1, the pinned rules of section 2 (ticks, skim, sniper, tax, owner and creator), code at every stack address, the stack cross checks (the hook reports the pool manager, factory and escrow, the locker reports the factory and position manager), hook, locker and mev module enabled on the factory, the factory deprecated, factory owner as configured, whether the deployer may launch, live `deployFee()` and the deployer balance against fee plus gas, predicted controller, core and coin addresses with no code at any of them, the coin prediction inputs, Credits, Statements and CreditScore sanity, code at CreditStrategy, Seaport, Permit2, position manager and universal router, placeholders filled, `rateStart` and the four economic dials in bounds (a row each, the auction row also checks the floor below the start, the gate row prints whether the gate is on), supply equal to the Core constant. then the `signoff:` rows and the `CONFIG_HASH`. prints a table, reverts with the failed names. WARN rows (owner equals creator, owner or creator equals the deployer) never fail |
| `Deploy.s.sol` | refuses to run while `owner`, `creator`, `name`, `symbol` or `salt` is unset, `rateStart` or an economic dial is out of bounds, or `CONFIG_HASH` is not the hash of the loaded config. runs preflight, then predicts, deploys ControllerV1 and Core (the Core constructor needs code at the hook, pool manager, factory, locker and escrow), launches through the factory and asserts the coin equals the prediction, locks the pool extension slot, hands the token admin role to `owner`, then runs postflight |
| `Postflight.s.sol` | read only. reads the deployed system back and compares it with the config: core immutables (owner, `RATE_START`, `AUCTION_START_X`, `AUCTION_FLOOR_X`, `DROP_BPS`, `INVENTORY_GATE`, the stack), controller, allowed targets, coin name, symbol and supply and that it sits in the pool, pool key and id, start tick, the launch position ticks through the position manager, skim config on the hook (baseline, bounty, referral cap, lp fee, recipients), the sniper start, end and duration through the mev module, tax config on the token, core tax exempt, token admin equals owner, extension slot locked, locker reward slot, `ethRate` equals `rateStart`, code at the stack. prints the table, a row `not readable on chain` for what no getter exposes (the protocolBps argument, the sniper fee config, token image and metadata, locker data, the deploy fee paid, the salt itself which the coin address check binds), the config hash and the constructor args, reverts on any mismatch. supply, rate and start tick rows are exact only until the first trade or fill, afterwards they turn tolerant. the sniper start and duration are readable only inside the window (30 minutes by default), after it only the end value is |
| `Resume.s.sol` | finishes a deploy that stopped half way. section 6 |

the five transactions are controller, core, launch through the factory, `lockPoolExtension` and `updateAdmin`. `forge script` simulates all five on a fork first, so a failed check or a revert in the simulation stops the script before anything is sent. nothing of the checks runs on chain: a change between the simulation and the mining (the factory fee, the factory opened) is caught only by a transaction reverting or by step 9, which is why step 9 is not optional. while the factory is deprecated only its owner and marked admins can launch, so nobody can copy the launch to the predicted coin address. never rerun `Deploy` after it stopped: a rerun takes a new nonce, so it deploys a second Core. check `cast nonce $DEPLOYER --rpc-url $MAINNET_RPC_URL` and `cast tx` for any pending transaction first, a transaction pending in the relay can still land.

## 2. parameter sign off table

constants of the Core (compiled in, not configurable). the owner signs off each row.

| constant | value | meaning |
|---|---|---|
| `SUPPLY` | 1,000,000,000e18 | coin supply the exit auction is priced against. must equal the launch supply |
| `AVG_SCORE` | 4,330,000 | average credit score at 1e4 scale. one average credit costs `AVG_SCORE * rate / 1e4` wei |
| `RATE_START_MIN_WEI`, `RATE_START_MAX_WEI` | 1e11, 1e15 | bounds of the constructor argument `rateStart`, wei per whole point. defined once in `src/interfaces/Interfaces.sol`, shared by the Core and the scripts, no getter on the Core |
| `CLIMB_BASE_BPS_PER_HOUR` | 100 | rate climb per hour in the first 24 hours since the last fill |
| `CLIMB_DOUBLE_EVERY` | 24 hours | the climb doubles every 24 hours without a fill |
| `CLIMB_MAX_BPS_PER_HOUR` | 800 | top climb, reached after 72 hours without a fill |
| `SPEND_CAP_BPS_PER_HOUR` | 2000 | hourly spend cap, 20 percent of the pot at the window open. also the funded threshold and the climb clamp |
| `BONUS_CAP_BPS` | 2500 | largest controller bonus on a ceiling |
| `TIP_SAVINGS_BPS`, `TIP_CAP_BPS` | 1000, 200 | `buyListing` keeper tip, 10 percent of savings capped at 2 percent of cost |
| `AUCTION_LENGTH` | 72 hours | statement auction length, linear fall from `AUCTION_START_X` to `AUCTION_FLOOR_X`, then flat |
| `SALE_SPLIT` | 5000 | share of statement sale proceeds to the coin buyback pot |
| `EXIT_SPLIT` | 5000 | share of exit token from an unsold statement to the buyback pot |
| `BUYBACK_SLICE`, `BUYBACK_DELAY`, `KEEPER_TIP_BPS` | 1 eth, 25 blocks, 50 | coin buyback slice, minimum block gap, caller tip in bps of the slice |
| `XRATE_START`, `XRATE_CAP`, `XRATE_FLOOR` | 6000, 9700, 3000 | exit token bid in bps of score, phase 2 |
| `XRATE_CLIMB_PER_HOUR`, `XRATE_DROP_PER_CREDIT` | 100, 20 | exit bid climb per hour and drop per credit |
| `XAUCTION_HALF_LIFE` | 6 hours | exit token dutch auction price half life |
| `TIMELOCK` | 7 days | owner actions |
| `OVERPRINT_CAP_PER_DAY` | 8 | overprints per day |
| allowed targets at deploy | Seaport 1.6, CreditStrategy | `buyListing` targets. more only by timelock |
| forbidden targets | Credits, Statements, Core, coin, hook, pool manager, factory, locker, escrow, Permit2, position manager, universal router, exitModule, exitToken | checked on add and at call time. the stack members come from the config |

economic dials. constructor arguments of the Core, stored as immutables, each with a public view of the same name, each read back by postflight, each in the config file under `econ` and inside `CONFIG_HASH`. the Core rejects a value outside the bounds at construction and preflight rejects it first. the defaults are the engine as specified, so a config that leaves them alone changes nothing. the owner signs off each row.

| key in `econ` (and Core view) | default | bounds | meaning |
|---|---|---|---|
| `AUCTION_START_X` | 40000 | [15000, 40000] | opening price of a statement auction in bps of its cost, 40000 is 4x |
| `AUCTION_FLOOR_X` | 12000 | [6000, 12000], strictly below `AUCTION_START_X` | the lowest price a statement is ever sold at, bps of cost, 12000 is 1.2x. SPEC invariant 3: no statement is sold below it. the auction falls linearly from the start to this over `AUCTION_LENGTH`, then stays flat |
| `DROP_BPS` | 1000 | [1000, 4000] | a fill of `x` from pot `p` drops the eth rate by `rate * DROP_BPS / 10000 * min(x, p) / p` |
| `INVENTORY_GATE` | 0 | 0 (off) or [5, 200] | a count of eth lane statements. while the Core holds this many or more eth lane statements for sale, `sellForEth` and `buyListing` revert `GateClosed` and the eth rate does not climb, exactly like unfunded time. buying resumes when a statement sale, an exit or an overprint brings the count below the gate. composing, statement sales, the buybacks, exits and the exit token lane are never gated. the live count is `ethHeld()` |

there are two config files that differ only in these four values: `script/config/mainnet.json` (the engine as specified: 40000, 12000, 1000, 0) and `script/config/mainnet.recommended.json` (the `gate20constants` row of docs/SIMULATION.md section 9: 20000, 8000, 2000, gate 20). the operator picks one file in step 1 (`cp` it to `local.json`), nothing else in the two files differs. a test (`test_recommendedDiffersOnlyInTheEconKeys`) keeps it that way.

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
| `rateStart` | 5.6e12 | opening bid in wei per whole point, bounded to [1e11, 1e15]. launch day rule in section 1: `(flat price of one credit in wei) / 1600`. 5.6e12 is the flat price 0.00896 eth. it only decides how soon the pot starts working |
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

pinned rules. preflight fails (and `Deploy` stops) on any value outside them. each row is a check in `script/Checks.sol`, and `test/ReviewDeploy.t.sol` `test_FIXED_matrix` proves every row against the mutations it closes.

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
| `rateStart` | [1e11, 1e15], the Core limits | none |
| `econ.AUCTION_START_X`, `econ.AUCTION_FLOOR_X` | [15000, 40000] and [6000, 12000], the floor strictly below the start | none |
| `econ.DROP_BPS` | [1000, 4000] | none |
| `econ.INVENTORY_GATE` | 0 or [5, 200] | none |

a change of a pinned value means editing `script/Checks.sol` on purpose, in a reviewed commit. a pinned rule cannot know a value that is plausible but not the intended one (another start price, another opening bid, `owner` and `creator` swapped). those are covered by the sign off: preflight prints the `signoff:` rows, the owner signs them, and `CONFIG_HASH` (keccak256 of the canonical abi encoding of the whole config and the token creation code) is the one value `Deploy` needs in its env. any later edit of the file changes the hash and `Deploy` reverts with `ConfigHashMismatch`. the overrides are inside the hash too.

what the sign off table covers: owner (Core owner and token admin), creator (0.5 point leg and lp rewards), the deployer, the skim bounty and referral payout that point to the Core, the protocol leg that points to the creator, the tax and burn address, the opening bid, the auction line (start and floor), the rate drop, the inventory gate line, and the economics line (skim, bounty, sniper, tax).

## 3. verify on etherscan

the compiler settings are in `foundry.toml`: solc 0.8.30, evm cancun, via ir, optimizer 200 runs, `bytecode_hash = "none"`. the two contracts we own are ControllerV1 and Core. the coin, hook, factory and locker are artcoins contracts and verify on their own.

the constructor arguments of the Core are `(owner, coin, controller, stack, rateStart, econ)`, where `stack` is the tuple `(poolManager, hook, tickSpacing, poolFee, factory, locker, escrow)` and `econ` is the tuple `(AUCTION_START_X, AUCTION_FLOOR_X, DROP_BPS, INVENTORY_GATE)`. every member is a static type, so the tuples are encoded inline. postflight prints the exact hex read back from the deployed immutables, and a test (`test_coreConstructorArgsReadBack`) keeps that encoding equal to `abi.encode` of the inputs. the same bytes by hand:

```sh
export POOL_MANAGER=$(jq -r .stack.poolManager $LAUNCH_CONFIG) HOOK=$(jq -r .stack.hook $LAUNCH_CONFIG)
export LOCKER=$(jq -r .stack.locker $LAUNCH_CONFIG) ESCROW=$(jq -r .stack.escrow $LAUNCH_CONFIG)
export RATE_START=$(jq -r .rateStart $LAUNCH_CONFIG)   # OWNER, FACTORY, CORE, COIN, CONTROLLER as in sections 0 and 1
export ECON="($(jq -r '.econ | "\(.AUCTION_START_X),\(.AUCTION_FLOOR_X),\(.DROP_BPS),\(.INVENTORY_GATE)"' $LAUNCH_CONFIG))"
ARGS=$(cast abi-encode \
  "constructor(address,address,address,(address,address,int24,uint24,address,address,address),uint256,(uint256,uint256,uint256,uint256))" \
  $OWNER $COIN $CONTROLLER \
  "($POOL_MANAGER,$HOOK,200,8388608,$FACTORY,$LOCKER,$ESCROW)" \
  $RATE_START "$ECON")

forge verify-contract $CORE src/Core.sol:Core --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir \
  --constructor-args $ARGS

forge verify-contract $CONTROLLER src/ControllerV1.sol:ControllerV1 --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir \
  --constructor-args $(cast abi-encode "constructor(address)" $CORE)
```

`forge verify-contract` needs `ETHERSCAN_API_KEY`. check the verified source page shows the same constructor args as the postflight print.

## 4. first actions after launch

all times are from the launch block. the anti sniper window is `launch.sniperSeconds` long (1800 seconds), measured from pool creation, which is the launch transaction.

| when | what happens | what to do |
|---|---|---|
| launch block | the pool is live. the skim is 90 points of volume, 9.5 points of the baseline plus the whole extra go to the Core, so early buyers fund the pot fast. the rate sits at `rateStart` and does not move while the pot is unfunded | read postflight. nothing else is needed |
| first buy | `Core.receive()` books the bounty into `ethPot` and `FeesAdded` fires | check `ethPot` and the balance are equal |
| funded | the pot is funded when `ethPot * 20% >= AVG_SCORE * rate / 1e4`, so at `rateStart` 5.6e12 the pot needs 1.21e16 wei, and at 1e11 it needs 2.17e14, at 1e15 it needs 2.17e18. from that moment the bid climbs lazily, 100 bps an hour, doubling every 24 hours since the last fill, 800 bps at the top. there is no retroactive climb for the unfunded time | watch `funded()` and `ethRate()` |
| 30 minutes | the anti sniper window ends and the skim is the 10 point baseline. the public can add liquidity to the pool after it | none |
| any time after funded | credit holders can call `sellForEth` into the bid. a credit sells when its ceiling `score * rate * (1 + bonus)` fits the hourly cap, 20 percent of the pot at the window open | check that real credits clear. at the clamp an average credit without bonus fits a fresh window |
| the clamp | the bid stops climbing where 20 percent of the pot buys exactly one average credit. so the highest bid is always one somebody can sell into | none |
| with no fills | after 72 hours without a fill the climb is 800 bps an hour until the clamp, so a bid that nobody hits runs up to what the pot can pay | none |
| eth in `ethToBuyback` | it fills from statement sales, so only after the first auction. `buyback()` then burns coin, one slice of at most 1 eth every 25 blocks | anyone may call, 0.5 percent tip |
| phase 2 | exit doors stay shut while the exitModule slot is empty. the owner queues `SetExitModule` through the 7 day timelock | queue only after the module is final |

housekeeping after launch.

| item | action |
|---|---|
| factory admin | revoke the deployer, step 10 of section 1. confirm with `cast call $FACTORY "admins(address)(bool)" $DEPLOYER` |
| token admin | the owner holds it. it can set the tax anywhere in [0, `taxBpsMax`], so it can raise 1500 to the 2000 ceiling, set metadata and renderer, and set the referral cap anywhere up to 1000 (raise it from 0). the owner signs `taxBpsMax` 2000 and the 1000 cap as the ceiling. it cannot change recipients, the bounty split, skim, ticks, venues or the exempt list |
| creator rewards | the creator claims the 0.5 point protocol leg from the fee escrow, `claim(creator, address(0))`, and lp fees through the locker `collectRewards(coin)` |
| the deployer key | sweep any leftover eth and retire the key |

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

`Deploy` sends five transactions. every state between them is safe (proven in `test/ReviewDeploy.t.sol` `test_partialStates` and `test/Resume.t.sol`), but three of them leave the deployer as the token admin, so finish them. do not rerun `Deploy`, and ignore any old advice to use a new salt: the coin address includes the Core address through the tax config, so a rerun takes a new nonce, a new Core and a new coin address, and leaves an orphan Core behind.

first read what is on chain (`export CORE=...`, the address `Deploy` printed or the second transaction in `broadcast/Deploy.s.sol/1/run-latest.json`):

```sh
export HOOK=$(jq -r .stack.hook $LAUNCH_CONFIG)
export COIN=$(cast call $CORE "COIN()(address)" --rpc-url $MAINNET_RPC_URL)
cast code $CORE --rpc-url $MAINNET_RPC_URL | head -c 12   # 0x... means the core exists
cast code $COIN --rpc-url $MAINNET_RPC_URL | head -c 12   # 0x means the launch is not sent
export POOLID=$(cast keccak $(cast abi-encode "f((address,address,uint24,int24,address))" "(0x0000000000000000000000000000000000000000,$COIN,8388608,200,$HOOK)"))
cast call $HOOK "poolExtensionLocked(bytes32)(bool)" $POOLID --rpc-url $MAINNET_RPC_URL   # false: not locked
cast call $COIN "admin()(address)" --rpc-url $MAINNET_RPC_URL                               # the owner when done (errors at point A, the coin does not exist yet)
```

| failure point | state on chain | exploitable or stuck | resume point and recovery |
|---|---|---|---|
| tx 1 sent, nothing after | orphan controller, holds nothing | no | none needed, the controller is inert. a rerun of `Deploy` takes the new nonce and new addresses and leaves it orphaned. to keep the predicted addresses instead, resend the saved Core creation with its own nonce: `cast send --rpc-url $PRIVATE_RPC --private-key $PRIVATE_KEY --create $(jq -r '.transactions[1].transaction.input' broadcast/Deploy.s.sol/1/run-latest.json)` (the file lists all five transactions, sent or not), then resume point A |
| tx 2 done, launch not sent (`cast code $COIN` is empty) | orphan Core and controller. the coin address has no code. the Core holds 0 and ignores everyone but the hook | nobody can launch the predicted coin while the factory is deprecated, only the owner or an admin. if the owner opens the factory, anyone could launch there and bind the Core to a dead coin | **resume point A**. `Resume` sends the launch, the lock and the handover. the launch needs the deployer still enabled on the factory and the fee in its balance |
| launch done, extension slot not locked (`poolExtensionLocked` false) | live pool, tradeable. the token admin is the deployer, the extension slot is open but no extension is enabled on the factory, so it is inert. the deployer can still call `setTaxBps` in [0, 2000]. strangers cannot lock or move the admin | risk is the deployer key only | **resume point B**. `Resume` sends the lock and the handover |
| lock done, handover not done (`admin()` is not the owner) | the owner cannot change tax or metadata until the handover. if the deployer key is lost the admin role is stuck for good (the Core is unaffected) | the deployer key only | **resume point C**. `Resume` sends the handover |
| all five done, deployer still a factory admin | the deployer can set hooks, lockers and mev modules, claim team fees, launch on a deprecated factory | step 10 is not gated by the scripts, `REQUIRE_REVOKED=1` gates it | step 10 |

the script, for A, B and C (it detects the point itself and sends only the missing steps, and runs postflight at the end). run it as the same deployer with the same config and `CONFIG_HASH`, with the relay that passed the rpc test:

```sh
CORE=$CORE forge script script/Resume.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --private-key $PRIVATE_KEY
```

it refuses to run when the Core at `$CORE` was not built from this config (owner, rate start, stack, coin prediction), when the caller is not the deployer of the run, or (point A only) when the preflight rows for the factory fail. it prints `stage found` (1 core only, 2 launched, 3 locked, 4 done).

the same by hand, as the deployer, if the script cannot be used. each is the single transaction of that point:

```sh
# point A: send the saved launch transaction (the calldata is in the broadcast file) with the live fee
export LAUNCH_INPUT=$(jq -r '[.transactions[] | select((.function // "") | startswith("deployTokenWithProtocolBpsAndTax"))][0].transaction.input' broadcast/Deploy.s.sol/1/run-latest.json)
cast send $FACTORY $LAUNCH_INPUT --value $(cast call $FACTORY "deployFee()(uint256)" --rpc-url $MAINNET_RPC_URL) --rpc-url $PRIVATE_RPC --private-key $PRIVATE_KEY
# point B: close the extension slot for good
cast send $HOOK "lockPoolExtension((address,address,uint24,int24,address))" "(0x0000000000000000000000000000000000000000,$COIN,8388608,200,$HOOK)" --rpc-url $PRIVATE_RPC --private-key $PRIVATE_KEY
# point C: hand the token admin to the owner
cast send $COIN "updateAdmin(address)" $OWNER --rpc-url $PRIVATE_RPC --private-key $PRIVATE_KEY
```

then run step 9 (postflight). `8388608` is `stack.poolFee` and `200` is `stack.tickSpacing`, take them from the config if they differ. after a failed launch transaction the Core is still valid, so a retry of that one transaction is right. the broadcast file `broadcast/Deploy.s.sol/1/run-latest.json` is gitignored and holds the signed data, keep it private.

a transaction pending or dropped in the relay: look at `cast nonce $DEPLOYER --rpc-url $MAINNET_RPC_URL` against `cast nonce $DEPLOYER --block pending --rpc-url $MAINNET_RPC_URL`. when they differ a transaction is still pending, wait for it. if the relay dropped it, the nonce does not move and the state is the one the table reads, resume from it. never rerun the whole script while one is pending.
