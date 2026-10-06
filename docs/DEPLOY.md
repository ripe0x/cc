# deploy runbook

this is the launch runbook for branch `artcoin`. the system launches on whichever artcoins version is current at deploy time. everything that depends on the artcoins version lives in the `stack` block of `script/config/mainnet.json`, the Core takes it as a constructor argument and nothing in `src/` hardcodes an artcoins address.

naming rule: only `exitModule` and `exitToken`. never name or describe them anywhere.

## 0. what you need

| item | note |
|---|---|
| deployer key | a fresh key that only does this launch. it needs the factory deploy fee (0.069 eth at the pin, read live) plus gas for five transactions, about 10.1M gas in total (measured by the rehearsal) |
| private rpc | a relay that does not publish to the public mempool, for example Flashbots Protect `https://rpc.flashbots.net/fast`. never broadcast through a public rpc, see the launch hijack finding P-4 in docs/REVIEW-port.md |
| read rpc | any archive capable mainnet rpc, in `MAINNET_RPC_URL` |
| etherscan key | `ETHERSCAN_API_KEY`, for verification |
| the factory owner | the artcoins factory owner (0xCB43078C32423F5348Cab5885911C3B5faE217F9 for the live stack) must enable the deployer, step 3 |

secrets are read from the environment only: `PRIVATE_KEY` (or use `--account` or `--ledger`) and `ETHERSCAN_API_KEY`. everything else is in the config file.

## 1. commands in order

all commands run from the repo root after `set -a; . ./.env; set +a`.

| step | action | command or owner |
|---|---|---|
| 1 | fill the config | edit `script/config/mainnet.json`: `owner`, `creator`, `name`, `symbol`, `salt`. set `rateStart` from the simulation. review every row of the sign off table in section 2 |
| 2 | rehearse on the latest block | `REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` |
| 3 | preflight, first run | `DEPLOYER=0xYourDeployer forge script script/Preflight.s.sol --rpc-url $MAINNET_RPC_URL`. the only failure allowed is `factory: deployer may launch`, until the factory owner acts |
| 4 | the factory owner enables the deployer | `cast send $FACTORY "setAdmin(address,bool)" $DEPLOYER true --rpc-url $PRIVATE_RPC` from the factory owner. keep the factory `deprecated` |
| 5 | preflight, second run | the same command as step 3. it must print every row ok and exit 0 |
| 6 | dry run | `forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --sender $DEPLOYER`. simulates all five transactions and runs preflight and postflight inside the script. nothing is sent |
| 7 | broadcast through the private rpc | `forge script script/Deploy.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --private-key $PRIVATE_KEY`. note the printed core, coin and controller addresses |
| 8 | verify on etherscan | section 3 |
| 9 | postflight | `CORE=0xCore DEPLOYER=0xYourDeployer forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. every row must be ok. it also prints the constructor args |
| 10 | the factory owner revokes the deployer | `cast send $FACTORY "setAdmin(address,bool)" $DEPLOYER false` from the factory owner. an admin can also set hooks, lockers and mev modules and claim team fees, so do this right after postflight. postflight prints `info: deployer still factory admin` until then |
| 11 | first actions after launch | section 4 |

what the scripts do.

| script | does |
|---|---|
| `Preflight.s.sol` | read only. chain id 1, code at every stack address, hook enabled on the factory, locker enabled for the hook, mev module enabled, factory owner as configured, whether the deployer may launch, live `deployFee()` and the deployer balance against fee plus gas, predicted controller, core and coin addresses with no code at any of them, the coin prediction inputs (salt, nonce, tax config hash, initcode hash), Credits, Statements and CreditScore sanity, code at CreditStrategy, Seaport, Permit2, position manager and universal router, placeholders filled, `rateStart` in bounds, supply equal to the Core constant. prints a table, reverts with the failed names |
| `Deploy.s.sol` | refuses to run while `owner`, `creator`, `name`, `symbol` or `salt` is unset or `rateStart` is out of bounds. runs preflight, then predicts, deploys ControllerV1 and Core, launches through the factory and asserts the coin equals the prediction, locks the pool extension slot, hands the token admin role to `owner`, then runs postflight. any failed check reverts before the broadcast is mined |
| `Postflight.s.sol` | read only. reads the deployed system back and compares it with the config: core immutables, controller, allowed targets, coin supply and that it sits in the pool (minus locker dust), pool key and id, skim config on the hook, tax config on the token, core tax exempt, token admin equals owner, extension slot locked, locker reward slot, `ethRate` equals `rateStart`, code at the stack. prints a table and the constructor args, reverts on any mismatch. supply and rate rows are exact only until the first trade or fill, afterwards they turn tolerant |

the five transactions are controller, core, launch through the factory, `lockPoolExtension` and `updateAdmin`. while the factory is deprecated only its owner and marked admins can launch, so nobody can copy the launch to the predicted coin address. if the factory is ever open, a watcher could copy it first, which is why the broadcast goes through a private rpc and why the script reverts on any prediction mismatch. a mismatch after the core exists orphans a core and controller, the fix is a new salt.

## 2. parameter sign off table

constants of the Core (compiled in, not configurable). the owner signs off each row.

| constant | value | meaning |
|---|---|---|
| `SUPPLY` | 1,000,000,000e18 | coin supply the exit auction is priced against. must equal the launch supply |
| `FEE_BPS` | 1000 | the skim as bps of volume, 10 percent. informational, no logic reads it. the live value is `launch.baselineSkimBps` |
| `CREATOR_BPS` | 50 | the creator share of volume in bps, 0.5 percent. informational, no logic reads it. the live value is `baselineSkimBps` and `bountyBps` |
| `AVG_SCORE` | 4,330,000 | average credit score at 1e4 scale. one average credit costs `AVG_SCORE * rate / 1e4` wei |
| `RATE_START_MIN`, `RATE_START_MAX` | 1e11, 1e15 | bounds of the constructor argument `rateStart`, wei per whole point |
| `CLIMB_BASE_BPS_PER_HOUR` | 100 | rate climb per hour in the first 24 hours since the last fill |
| `CLIMB_DOUBLE_EVERY` | 24 hours | the climb doubles every 24 hours without a fill |
| `CLIMB_MAX_BPS_PER_HOUR` | 800 | top climb, reached after 72 hours without a fill |
| `DROP_BPS` | 1000 | a fill of `x` from pot `p` drops the rate by `rate * 10% * min(x, p) / p` |
| `SPEND_CAP_BPS_PER_HOUR` | 2000 | hourly spend cap, 20 percent of the pot at the window open. also the funded threshold and the climb clamp |
| `BONUS_CAP_BPS` | 2500 | largest controller bonus on a ceiling |
| `TIP_SAVINGS_BPS`, `TIP_CAP_BPS` | 1000, 200 | `buyListing` keeper tip, 10 percent of savings capped at 2 percent of cost |
| `AUCTION_START_X`, `AUCTION_FLOOR_X`, `AUCTION_LENGTH` | 40,000, 12,000, 72 hours | statement auction from 4x to 1.2x of cost, linear |
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
| `rateStart` | 4e12 | opening bid in wei per whole point, bounded to [1e11, 1e15]. the simulation sets the real number |
| `launch.supply` | 1,000,000,000e18 | coin supply, all of it in the locker, must equal the Core `SUPPLY` |
| `launch.startTick` | -175000 | `tickIfToken0IsArtCoins`, about 40M coin per eth |
| `launch.positionLower`, `positionUpper` | -175000, 887200 | the one launch position, multiples of the tick spacing |
| `launch.baselineSkimBps` | 10000 | baseline skim in hundredths of a bp of volume, 10,000 of 100,000 is 10 points |
| `launch.bountyBps` | 9500 | share of the baseline skim to the Core, so 9.5 points to the Core and 0.5 to the creator |
| `launch.maxReferralBps` | 0 | referral cap. 0 means the hook never calls `notify` |
| `launch.lpFee` | 0 | extra lp fee |
| `launch.sniperStartBps`, `sniperEndBps`, `sniperSeconds` | 90000, 10000, 1800 | skim decays linearly from 90 points to 10 over 30 minutes, the extra goes to the Core |
| `launch.taxBps`, `taxBpsMax` | 1500, 2000 | venue tax on coin leaving a venue (15 percent now, cap 20 percent) |
| `launch.taxBurn` | 0x000000000000000000000000000000000000dEaD | tax recipient |
| `launch.tokenCodeFile` | script/data/ArtCoinsToken.creation.hex | creation code of the token implementation, input of the coin address prediction |

## 3. verify on etherscan

the compiler settings are in `foundry.toml`: solc 0.8.30, evm cancun, via ir, optimizer 200 runs, `bytecode_hash = "none"`. the two contracts we own are ControllerV1 and Core. the coin, hook, factory and locker are artcoins contracts and verify on their own.

the constructor arguments of the Core are `(owner, coin, controller, stack, rateStart)`, where `stack` is the tuple `(poolManager, hook, tickSpacing, poolFee, factory, locker, escrow)`. every member is a static type, so the tuple is encoded inline. postflight prints the exact hex read back from the deployed immutables, and a test (`test_coreConstructorArgsReadBack`) keeps that encoding equal to `abi.encode` of the inputs. the same bytes by hand:

```sh
ARGS=$(cast abi-encode \
  "constructor(address,address,address,(address,address,int24,uint24,address,address,address),uint256)" \
  $OWNER $COIN $CONTROLLER \
  "($POOL_MANAGER,$HOOK,200,8388608,$FACTORY,$LOCKER,$ESCROW)" \
  $RATE_START)

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
| funded | the pot is funded when `ethPot * 20% >= AVG_SCORE * rate / 1e4`, so at `rateStart` 4e12 the pot needs 8.66e15 wei, and at 1e11 it needs 2.17e14, at 1e15 it needs 2.17e18. from that moment the bid climbs lazily, 100 bps an hour, doubling every 24 hours since the last fill, 800 bps at the top. there is no retroactive climb for the unfunded time | watch `funded()` and `ethRate()` |
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
| token admin | the owner holds it. it can lower the tax, set metadata and renderer, lower the referral cap. it cannot change recipients, the bounty split, skim, ticks, venues or the exempt list |
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
