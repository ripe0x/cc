note: this file is the record of the artcoins v1 stack at block 26127622 and is kept as written. the engine now launches on the artcoins v2 stack (docs/FLOW.md section 10, docs/V2-PORT.md); nothing below describes v2.

# artcoins launch recipe notes (skim hook + venue tax, modeled on 111)

verified 2026 10 05 against mainnet block 26127622 (ts 1791220847), latest checked 26128926. nothing relevant changed between the two (no events on factory, escrow, locker, mev module, allowlist, controller after the pin). source reading is /home/claude/artcoins (head 003ee06). every live contract in the 111 stack (factory, hook, token, locker, escrow, controller) was pulled from sourcify and the `src/` files are byte identical to /home/claude/artcoins/src, so line pointers below are valid for the live bytecode. line numbers refer to /home/claude/artcoins unless a path says permanent collection (pc = /home/claude/permanent-collection).

verification harness: a forge fork test suite (real contracts at the pin, only a recipient stub and a plain unlock swapper written by me) lives in the session scratchpad `/tmp/claude-0/-home-claude/d82c2ac8-14b2-57ac-9126-121e363f7cb8/scratchpad/fork/test/` (Base, Launch, Econ, Dirs, Tax, Gaps, Admin). every number marked (fork) below was executed there: launch, address prediction, all four swap directions, anti sniper decay, referral, tax gaps, locker collect, admin powers. run: `FORK_URL=https://mainnet.gateway.tenderly.co forge test` in that dir (solc 0.8.26 offline).

## 0. headline

| question | answer |
|---|---|
| does a fresh launch work at the pin as is | no for strangers: factory `deprecated == true`. yes for owner 0xCB43 (fork). one owner call fixes it |
| the factory to use | 0x49596c375c139E79bb937bcf826068a8F78D4e0e (the only factory with the skim hook, tax entry point and linear skim module enabled) |
| exact msg.value | `deployFee()` = 0.069 ether at the pin (owner settable, max 1 ether). must match exactly when no extensions, else `ExtensionMsgValueMismatch` |
| max bounty share | `bountyBps` max 9999, so 99.99% of baseline skim, plus 100% of the anti sniper extra in the first window |
| artcoins cut of the skim | zero. there is no hook level cut and no hook owner |
| artcoins cuts anywhere | flat deploy fee, and an optional locker protocol slot on LP fees (deployer chooses 0 to 3000 bps, 0 allowed) |

## 1. live addresses at block 26127622 (all have code at the pin, checked with `cast code --block`)

| item | address | state read at pin |
|---|---|---|
| ArtCoinsFactory (skim capable) | 0x49596c375c139E79bb937bcf826068a8F78D4e0e | version "1", deprecated true, owner 0xCB43078C32423F5348Cab5885911C3B5faE217F9, teamFeeRecipient 0xCB43..17F9, defaultProtocolFeeBps 2000, deployFee 0.069e18, admins none, created block 25260062 |
| ArtCoinsDeployer (library, delegatecalled) | 0x92584b320a8b871934a50b9d6f05833f6f82cb81 | linked into factory per sourcify settings. CREATE2 runs in the factory context so the factory address is the deployer |
| ArtCoinsHookSkimFee (only skim hook, no redeploy exists) | 0x636c050296B5Cc528D8785169Bf8923716FCa9cc | enabledHooks true. immutables: factory 0x4959..., poolExtensionAllowlist 0xd6D5fb5CfE386d0eB73a09cba5d190beb802e6E8, feeEscrow 0x7559..., weth, poolManager. address low bits 0x29cc (mined flags). no owner, no admin |
| SkimFeeInitLib (library) | 0x115510a709d1afd798325f3ffb74b127a08dd3c9 | delegatecalled at pool init |
| ArtCoinsLpLocker | 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab | enabledLockers[locker][hook] true. owner 0xCB43, keeperRewardBps 0 (default 50, max 200), keeperRewardCap 0.01e18, max 14 positions, max 7 reward slots |
| ArtCoinsFeeEscrow | 0x7559689765aE86cBB38e68CD1294830CccB125F2 | owner 0xCB43. allowedDepositors: hook true, locker true. no remove function |
| ArtCoinsMevLinearSkim | 0xb038D597365FfD108D63C265Bb0621444a1D8B83 | enabledMevModules true. not on sourcify, behavior verified by calls and fork. no owner |
| pool extension allowlist | 0xd6D5fb5CfE386d0eB73a09cba5d190beb802e6E8 | owner 0xCB43, zero extensions enabled (only an OwnershipTransferred log ever) |
| factory extensions enabled | none | all six known extension addresses read false. so `extensionConfigs` must be empty |
| other mev modules on this factory | LinearFees, Descending, TimeDelay, SteppedFees | all false. only linear skim or address(0) |
| ProtocolFeeController (pc instance) | 0xd8C63401268744d430EbE0C18412211421498013 | treasury 0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4, burnRouter 0x0EB22955E8904b8C5a4EC6f1D476f5b0C93854ca, 8667/1333. NOT the factory team recipient, only used by pc as its protocolRecipient chain |
| ProtocolFeeController (layer instance) | 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60 | 6000/4000, teamFeeRecipient of the OLD factory 0xd159 only |
| older factories (do not use) | 0xf051cd4c4f3f36f9f24d8a19d60ee8f84fc6793e (v3, deprecated false, deployFee 0, static fee hook 0xaad673ea only, no tax entry point), 0xd1595a2742c392d1c109b616b4f08918d02292f9 (deprecated true, layer, static fee v2 hook) | skim hook enabled on neither. selector 0x373c0b29 absent from f051 bytecode |
| 111 token | 0x61C9d89fe1212F6b55fF888816A151463287B8ae | supply 1.11e27, admin = originalAdmin = TokenAdminPoker 0xA96a11257890ED1C43C16c098E286e18e45E6258 |
| 111 pool id | 0xf860d8f4896aed6cc1c68d234ba728680902f0ae43a459fbee6f6baa8036f795 | key: currency0 0x0 (eth), currency1 111, fee 0x800000 (dynamic), tickSpacing 200, hooks 0x636c.... hashed and checked against PoolManager slot0 (lpFee 5000, uniswap protocolFee 0) |
| PoolManager | 0x000000000004444c5dc75cB358380D2e3dE08A90 | uniswap owner 0x1a9C..., protocolFeeController 0x89A5D5bF00a27D55c02951E49078a5C5771051dB. new pools got protocolFee 0 (fork) |
| PositionManager | 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e | locker immutable |
| Permit2 | 0x000000000022D473030F116dDEE9F6B43aC78BA3 | |
| WETH | 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 | hook immutable, unused for native pools |
| universal router | 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af | poolManager() and V4_POSITION_MANAGER() match. also v4 quoter 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203, state view 0x7ffe42c4a5deea5b0fec41c94c136cf115597227 |

111 wiring (pc docs and chain agree): launch tx 0x3aca132bed96c778e90408dacfc3621966ea29a70a30040722d071f3dbc63cf2 block 25275351 from 0xCB43, msg.value 0 (deployFee had been set to 0 for that tx, restored to 0.069 at block 25655778), selector 0x373c0b29 `deployTokenWithProtocolBpsAndTax`. skimConfig(pid) = baselineSkimBps 6000, bountyBps 8333, maxReferralBpsOfVolume 250, lpFee 5000, bountyRecipient LiveBidAdapter 0x8C72FBc2bB32e76aa54243F76745266a0F92CD01, protocolRecipient ProtocolFeePhaseAdapter 0xed3E9D3Bf693372060b7ce62aDB49650145b2ba9, referralPayout 0xB03Cbd862F47059e928C113182814c676eA29d4c, quoteToken 0. mev module config (90000, 6000, 1800). locker: positionId 309865, 14 positions, reward slot 10000 bps to FeeAutoSwapper 0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961 with reward admin 0xdEaD (recipient locked forever). window ended long ago (pool born 1780953647, `operational` false).

## 2. the launch call

entry points (src/ArtCoinsFactory.sol): `deployToken(cfg)` line 156 (protocol slot = defaultProtocolFeeBps, no tax), `deployTokenWithProtocolBps(cfg, bps)` line 176, `deployTokenWithProtocolBpsAndTax(cfg, bps, tax)` line 200. all payable, nonReentrant, call `_doDeploy` line 217.

gates in `_doDeploy`: line 222 `if (deprecated && msg.sender != owner() && !admins[msg.sender]) revert Deprecated();`. supply 0 becomes 1_000_000_000e18, below 1e18 reverts `TotalSupplyTooLow` (fork). msg.value rule lines 353 to 372: no extensions means `msg.value == deployFee`; with extensions `sum(msgValue) + fee == msg.value`. fee forwarded to teamFeeRecipient at line 374 (reverts `TeamFeeRecipientNotSet` if fee > 0 and recipient 0). hook, locker (pair), mev module must be enabled or `HookNotEnabled`, `LockerNotEnabled`, `MevModuleNotEnabled`. mev module address(0) is allowed (fork: no anti sniper, baseline skim from block 0). ordering: token create2, extensions, deploy fee, inject protocol slot, `hook.initializePool`, sniper recipient, `locker.placeLiquidity` (positions minted to the locker), extensions, `hook.initializeMevModule`.

who may call: anyone once `deprecated` is false, otherwise only owner or an `admins` entry (fork: `setAdmin(deployer,true)` works while deprecated stays true).

struct tree (src/interfaces/IArtCoinsFactory.sol lines 22 to 110, tax types src/interfaces/IArtCoinsTaxable.sol lines 71 to 120):

| struct | fields in order and meaning |
|---|---|
| DeploymentConfig | tokenConfig, poolConfig, lockerConfig, mevModuleConfig, sniperFeeConfig, extensionConfigs[] |
| TokenConfig | tokenAdmin (nonzero, goes in the salt and the token ctor), name, symbol, salt (bytes32 user salt), image, metadata, context (strings, can be ""), totalSupply (0 means 1B, all of it minus extensions goes to the locker), renderer (0 means built in json, else must have code) |
| PoolConfig | hook (0x636c), pairedToken (address(0) is mandatory for skim: quoteToken must be native), tickIfToken0IsArtCoins (int24, see below), tickSpacing (111 uses 200), poolData |
| poolData | `abi.encode(address extension, bytes extensionData, bytes feeData)` = PoolInitializationData (src/interfaces/IArtCoinsHook.sol:159). extension 0 and extensionData "" for no pool extension. feeData = `abi.encode(SkimHookFeeData)` |
| SkimHookFeeData (src/hooks/interfaces/IArtCoinsHookSkimFee.sol:114) | uint24 baselineSkimBps (100_000 denominator, max 90_000), uint16 bountyBps (10_000 denominator, must be < 10_000), uint24 maxReferralBpsOfVolume (100_000 denominator, max 1000), uint24 lpFee (ppm, max 100_000 = 10%), address bountyRecipient, address protocolRecipient, address referralPayout (all nonzero), address quoteToken (must be 0). validation: src/hooks/libraries/SkimFeeInitLib.sol:59 to 85 |
| LockerConfig | locker (0x866e), rewardAdmins[], rewardRecipients[], rewardBps[] (sum 10_000 after the protocol slot, each > 0, max 7 entries counting the injected slot), tickLower[], tickUpper[], positionBps[] (sum 10_000, max 14), lockerData (ignored, "") |
| MevModuleConfig | mevModule (0xb038 or 0), mevModuleData = `abi.encode(uint24 startingBps, uint24 endingBps, uint32 durationSeconds)`; or empty bytes for defaults (68_690 to 5_000 over 69 min, read from chain: DEFAULT_DURATION 4140). startingBps <= 90_000, endingBps < startingBps, 60 <= duration <= 10_800. endingBps should equal baselineSkimBps (not enforced) |
| SniperFeeConfig | (address(0), false). inert for the skim hook, skip |
| ExtensionConfig[] | empty. no extension is enabled on this factory |
| TaxConfig (only the AndTax entry point) | enabled, taxBps, taxBpsMax (<= 2000), burnAddress (nonzero), poolManager (nonzero), canonicalHook (nonzero, = skim hook), pairedToken (0 = native, used only for the canonical pool id), canonicalPoolFee (0x800000), canonicalTickSpacing (= PoolConfig.tickSpacing), exempt[], venues[] of TaxVenue(kind 1 v2 or 2 v3, factory, initCodeHash, counterToken, v3Fee) |

ticks: factory passes `tickIfToken0IsArtCoins` as the start tick in token0 orientation. because the coin is always currency1 against native eth, the pool starts at `-tickIfToken0IsArtCoins` and each position is mirrored (locker lines 307, 333 to 338). 111 passes -172200 and its pool opened at tick +172200. locker rules (lines 286 to 313): ticks multiples of tickSpacing, lower <= upper, every tickLower >= tickIfToken0IsArtCoins, positionBps sum 10_000. positions are single sided coin, so they sit above the start price in token0 orientation. fork tick check: new pool reads tick 172200, lpFee 0 until the first swap (hook sets dynamic fee in `_beforeSwap`).

protocol bps: `deployTokenWithProtocolBps*` with bps 0 injects nothing (rewardBps must sum 10_000 alone); with bps > 0 the factory appends a slot (recipient teamFeeRecipient, admin the factory) and `projectSum + bps` must equal 10_000 else `ProjectSideBpsMismatch` (lines 388 to 421). cap 3000 else `ProtocolFeeBpsTooHigh`. the plain `deployToken` always uses defaultProtocolFeeBps 2000, so reward bps must sum 8000 there (fork confirmed both reverts).

verified encoding (fork/test/Base.sol, executed against the real factory at the pin; `IFactory` is a local copy of the structs above):

```solidity
// feeData = SkimHookFeeData(baselineSkimBps, bountyBps, maxReferralBpsOfVolume, lpFee, bountyRecipient, protocolRecipient, referralPayout, quoteToken)
bytes memory fee = abi.encode(uint24(10_000), uint16(9500), uint24(250), uint24(5000), treasury, protocolRecipient, referralPayout, address(0));
// poolData = PoolInitializationData(extension, extensionData, feeData)
poolConfig = IFactory.PoolConfig(HOOK, address(0), -172200, 200, abi.encode(address(0), bytes(""), fee));
lockerConfig = IFactory.LockerConfig(LOCKER, [0xdEaD], [treasury], [10_000], tickLowers, tickUppers, positionBps, "");
mevModuleConfig = IFactory.MevModuleConfig(MEV, abi.encode(uint24(90_000), uint24(10_000), uint32(1800)));
sniperFeeConfig = IFactory.SniperFeeConfig(address(0), false);
// taxConfig = TaxConfig(true, 1500, 2000, burnSink, POOL_MANAGER, HOOK, address(0), 0x800000, 200, exempt[], venues[])
// launch: msg.value exactly deployFee (0.069 ether); bps 0 => lockerConfig.rewardBps sums to 10_000 alone
factory.deployTokenWithProtocolBpsAndTax{value: 0.069 ether}(cfg, 0, taxConfig);
```

notes on the encoding: the hook decodes `feeData` as eight static words (word order above, uint16 and uint24 are padded to 32 bytes). the pc script builds the same thing at pc contracts/script/Deploy.s.sol `_buildFactoryConfig` line 1070 and `_buildTaxConfig` line 1216, the mev init at `_mevSkimInitData` line 131, the call at line 936. the live 111 decode (launch_decoded.txt in the scratchpad) matches word for word. `maxReferralBpsOfVolume` may be 0 (no referral carve out). `lpFee` 5000 ppm = 0.5%. reward admin 0xdEaD makes the reward recipient permanent.

## 3. token address determination and prediction

formula (src/utils/ArtCoinsDeployer.sol lines 49 to 61, the factory delegatecalls this library so the CREATE2 deployer is the factory):

| piece | value |
|---|---|
| deployer | factory 0x49596c37... (not the caller, not the library) |
| salt | `keccak256(abi.encode(tokenAdmin, userSalt))`. admin is in the salt, so changing admin changes the address and a front runner cannot squat another admin's address |
| initcode | `ArtCoinsToken.creationCode ++ abi.encode(name, symbol, supplyResolved, tokenAdmin, image, metadata, context, renderer, taxConfig)`. supplyResolved is the number after the 0 means 1B default rule |
| address | `address(uint160(uint256(keccak256(abi.encodePacked(0xff, factory, salt, keccak256(initcode))))))` |

proofs: (1) the shell recomputation from the 111 launch calldata and sourcify creation bytecode gives 0x61C9d89fe1212F6b55fF888816A151463287B8ae, equal to the live token. (2) fork: predicted address equals the returned coin for two launches (Launch.t.sol lines 37 to 69). there is no on chain predict helper in the factory. the repo helper script/LaunchLayer.s.sol `_predictTokenAddress` (lines 476 to 506) only encodes an EMPTY tax config, so it is wrong for a taxed token: the tax config is part of the initcode and changes the address.

consequences for our wiring:
- the taxConfig contains no token dependent field (venues are derived inside the ctor from `address(this)`), so the prediction needs no circular input. the tax config does contain `canonicalHook`, `exempt[]`, venues, `burnAddress`, so fix all of them before predicting. any change moves the address.
- the fee recipient contract needs the coin address only if it stores it. the recipient address goes into `poolData` and `lockerConfig`, which are NOT in the initcode, so the order is: deploy recipient (any address), predict coin, then launch. if the recipient must know the coin, predict with the final tax config and a fixed userSalt, deploy the recipient with that address, then launch with the same salt and admin. the recipient address does not feed the coin address.
- supply, name, symbol, image, metadata, context and renderer are all in the initcode. use the same literals in the prediction (empty strings are fine, `totalSupply` 0 must be predicted as 1_000_000_000e18).
- sorting: `_initializePool` (src/hooks/ArtCoinsHook.sol:425 to 462) sets `token0IsArtCoins = artCoin < pairedToken`. paired token is address(0) (native), so this is always false: coin is currency1, eth currency0, `artCoinIsToken0` false, start tick `-tickIfToken0IsArtCoins`. no vanity or sort mining is needed. `artCoin == address(0)` reverts `ETHPoolNotAllowed` (cannot happen for a CREATE2 token).
- the pool key is `(address(0), coin, 0x800000, tickSpacing, hook)` and the pool id is `keccak256(abi.encode(key))`. the token computes the same id in its ctor as `canonicalPoolId` (src/ArtCoinsToken.sol:396). fork: matches for new launches.
- a duplicate (admin, userSalt, initcode) reverts at CREATE2, so bump userSalt.

## 4. skim fee flow, native eth pool (src/hooks/ArtCoinsHookSkimFee.sol)

mechanics: `_beforeSwap` lines 258 to 320, `_afterSwap` 322 to 397, split `_processSkimAndAttribution` 520 to 580, `_skimAmounts` 582 to 600, `_flushAccruedSkim` 684 to 741, tax attestation 455 to 493. the hook only skims the ETH (quote) side. if eth is the specified amount it takes the skim in `_beforeSwap` through a BeforeSwapDelta on the specified side, otherwise it measures the eth leg in `_afterSwap` and returns an unspecified delta. skim is minted as ERC6909 claims, then burned and taken as native eth to the hook, then pushed out, all inside the same afterSwap, so the hook never holds a balance between swaps.

| direction (eth is currency0) | skim base | formula | who pays |
|---|---|---|---|
| buy exact in (amountSpecified < 0, zeroForOne true) | eth in | `vol * bps / 100_000` | taken out of the eth the buyer sends, pool trades the rest |
| buy exact out (coin specified) | eth the pool needs | `X * bps / (100_000 - bps)` | buyer pays pool eth plus skim on top (fork: skim = 9.5% of gross paid at bps 10_000 and bountyBps 9500) |
| sell exact in (coin in) | eth out of pool | `X * bps / 100_000` | taken from the eth the seller receives (seller gets 90% at 10_000) |
| sell exact out (eth specified) | eth out | `X * bps / (100_000 - bps)` | seller spends more coin so nets exactly X (fork) |

`bps` is `_currentSkimBpsClamped`: the mev module's `currentSkimBps(pid)` clamped to [baselineSkimBps, 90_000]; with no module, or a module call that reverts, it is baselineSkimBps. `baselineSkim` uses the same base with baselineSkimBps, `antiSniperExtra = total - baseline`.

legs (all lines of `_processSkimAndAttribution`):
- `bountyShare = baselineSkim * bountyBps / 10_000`, `protocolShare = baselineSkim - bountyShare` (absorbs rounding dust).
- referral: only when the swap hookData carries a referrer. `min(volume * min(att.referralBps, maxReferralBpsOfVolume) / 100_000, protocolShare)` is carved out of the PROTOCOL leg only. the bounty leg is never reduced by a referrer.
- `bountyTotal = bountyShare + antiSniperExtra`: the entire anti sniper extra goes to the bounty leg.
- bounty delivery: `bountyRecipient.call{value: b}("")` with all gas and empty calldata, so it hits `receive()` (or `fallback`). a failing call reverts the whole swap (`BidForwardFailed`), the hook holds nothing (fork: gasleft inside receive about 972M, no cap, and a reverting recipient bricks every swap). do not use a recipient that can ever reject eth, and do not make `receive()` heavy: the buyer pays the gas.
- protocol delivery: `feeEscrow.storeFeesNative{value: p}(protocolRecipient)` (escrow 0x7559..., the hook is an allowlisted depositor, never fails). claim later with `claim(feeOwner, address(0))` (anyone may trigger, pays feeOwner) or `claimTo` (feeOwner only). `protocolRecipient` is just a nonzero address in the pool config, it can be our own contract.
- referral delivery: `referralPayout.notify{value: r, gas: 35_000}(referrer)`, on failure it folds into the protocol escrow. so a bad payout contract cannot brick swaps.
- `IPreSwapStream` (src/interfaces/IPreSwapStream.sol:19): `streamForward() returns (uint256)`. at the start of every swap, if `bountyRecipient.balance >= 0.01 ether` the hook calls it in `try/catch {}`. a plain contract with only `receive()` just reverts, which is caught. a contract with a PAYABLE `fallback` that returns no data is the trap: the call succeeds but the 32 byte return decode fails in the hook, and that revert is not caught, so every swap reverts once the recipient balance is at least 0.01 eth (fork Dirs.t.sol: first swap ok, second reverts). a fallback that returns one word is fine. recommended: no fallback, or implement `streamForward` returning a uint256.
- events: `SkimSplit(pid, volume, bountyTotal, protocolNet, referral)` per swap.

anti sniper (mev module 0xb038...): `currentSkimBps = startingBps - (startingBps - endingBps) * elapsed / duration` from pool creation, floored at endingBps. fork: at t=0 in the same block as launch, total 90_000 so 1 eth buy skims 0.9 eth; baseline 0.1; extra 0.8 to bounty. at t=900 of 1800s total 50_000. pool is also locked for public liquidity while `operational` (`_beforeAddLiquidity`). window with no module: none, baseline from block 0.

worked example, 1 eth exact in buy after the window, baselineSkimBps 10_000, bountyBps 9500, maxReferral 250, lpFee 5000 (fork asserts the 3 skim rows exactly):

| item | wei | note |
|---|---|---|
| total skim | 100_000_000_000_000_000 | 1e18 * 10_000 / 100_000 = 10 points |
| bounty leg to the treasury `receive()` | 95_000_000_000_000_000 | 9.5 points, 95% of skim |
| protocol leg to escrow under protocolRecipient | 5_000_000_000_000_000 | 0.5 points |
| with a referrer at 250 | referral 2_500_000_000_000_000, protocol net 2_500_000_000_000_000 | bounty unchanged (fork) |
| eth into the pool | 900_000_000_000_000_000 | then lpFee 0.5% of that, about 4.5e15, accrues to the position owner (the locker), paid to reward recipients on `collectRewards` (not asserted numerically) |

maximum bounty share: `bountyBps` is a uint16 over 10_000 and must be below 10_000 (`BadLegBps`), so 9999. at 1 eth and 10_000 baseline: bounty 99_990_000_000_000_000 and protocol escrow 10_000_000_000_000 (fork asserts both). so at most 99.99% of baseline skim reaches the bounty recipient plus all anti sniper extra, and the remainder 0.01% plus rounding dust always goes to the protocol leg (escrow under `protocolRecipient`, which we can set to our own contract and claim). `baselineSkimBps` max 90_000 (`BaselineSkimBpsTooHigh`), `maxReferralBpsOfVolume` max 1000 (`MaxReferralTooHigh`), lpFee max 100_000. fork confirms each revert.

what artcoins takes: from the skim, nothing: no protocol share constant, no hook owner, no fee on the legs (the escrow is a pass through, no sweep or remove function, owner can only add depositors). artcoins gets (a) `deployFee` 0.069 eth to `teamFeeRecipient` per launch, owner settable up to 1 eth, (b) the locker protocol slot on LP fees: `protocolBps` in `deployTokenWithProtocolBps*`, 0 to 3000, 0 allowed, plain `deployToken` forces 2000, (c) the locker keeper reward `keeperRewardBps` (default 50, max 200, cap 0.01 eth) paid to whoever calls `collectRewards`, owner settable. none of these touch the skim legs. uniswap's own protocol fee on the new pool read 0 (fork), uniswap governance controls it (PoolManager owner 0x1a9C...) and could set it later.

## 5. venue scoped transfer tax (src/ArtCoinsToken.sol, src/interfaces/IArtCoinsTaxable.sol)

structs: `TaxConfig` and `TaxVenue` are in the struct tree of section 2 (IArtCoinsTaxable.sol lines 71 to 120). the ctor (lines 158 to 218, `_initTaxSets` 412 to 462) stores `taxEnabled`, `taxBpsMax`, `taxBurnAddress`, `canonicalHook`, `canonicalPoolId`, `taxPoolManager` as immutables, `taxBps` as the only mutable storage, plus the exempt and venue mappings. ctor guards: bps <= bpsMax <= 2000 (compile cap), burn, poolManager, hook nonzero, else `TaxConfigInvalid` (fork: cap 2001 reverts at launch).

mechanics (`transfer` 249 and `transferFrom` 255 route into `_taxedTransfer` 281 to 307):
- a transfer is taxed only if `taxEnabled`, `taxBps != 0`, `from` is a venue (the PoolManager immutable, or a derived V2/V3 pair), and `to` is not on the exempt list, after subtracting the transient canonical budget. only coin LEAVING a venue is taxed. coin going INTO a venue, wallet to wallet, mint, burn are never taxed.
- taxed slice = `taxable * taxBps / 10_000` sent from `from` to `taxBurnAddress`; the recipient gets `amount - tax` (two Transfer logs plus `TaxApplied`). the venue is debited the full amount so pool accounting is unaffected.
- venues: V4 = the PoolManager singleton, so EVERY V4 pool of the coin is a venue. V2 (kind 1): `CREATE2(factory, keccak256(abi.encodePacked(t0, t1)), initCodeHash)`. V3 (kind 2): `CREATE2(factory, keccak256(abi.encode(t0, t1, fee)), initCodeHash)` where for pancake v3 the "factory" is the pool deployer. one entry covers one (factory, counter token, fee tier). t0 and t1 sorted vs `address(this)`.
- venues and exempt addresses are frozen at construction. there is no add or remove path (grep: no setter). the hook, burn sink, pool manager and cap are immutable.
- the exemption budget: ERC1153 transient slot `_CANONICAL_BUDGET_SLOT`. `attestCanonicalBudget(poolId, amount)` (token line 342) only accepts `msg.sender == canonicalHook` and silently ignores any pool id other than `canonicalPoolId`. every venue outflow calls `_consumeCanonicalBudget` (line 318) BEFORE the exempt check, even when `to` is exempt, so an unspent budget cannot survive to subsidise a later outflow of a different kind.
- who attests (hook, only if `cfg.taxEnabled` and `locker[pid] != 0`, i.e. a factory made pool, never an `initializePoolOpen` pool): `_afterSwap` (line 322 ff, call at the end) attests the realized coin out of every canonical swap, and `_afterRemoveLiquidity` (455 to 477) attests the coin removed, which covers public LP exits and locker fee collection (a collect is a zero liquidity decrease, so the fee coin shows in delta). fork: canonical buys, exact out buys, sells, and `collectRewards` are all untaxed with or without the locker on the exempt list (Tax.t.sol).
- who changes the rate: only the token admin through `setTaxBps(uint16)` (line 363), range [0, taxBpsMax]. on 111 the admin is the TokenAdminPoker contract 0xA96a..., pc docs say its `setTokenTaxBps` adds a two key carve out. `renounceAdmin` freezes the rate. nobody can raise it above `taxBpsMax`. nothing else (factory owner, hook) can touch it.

the live 111 values (read at the pin, token 0x61C9...):

| field | value |
|---|---|
| taxEnabled / taxBps / taxBpsMax | true / 1500 (15%) / 2000 |
| taxBurnAddress | 0xf5c3eC7e185d0a592264791D523496EA6e368753 (pc vault burn pool) |
| taxPoolManager | 0x000000000004444c5dc75cB358380D2e3dE08A90 |
| canonicalHook / canonicalPoolId | 0x636c...a9cc / 0xf860d8f4896aed6cc1c68d234ba728680902f0ae43a459fbee6f6baa8036f795 (pairedToken 0, fee 0x800000, spacing 200) |
| exempt (isTaxExempt true) | 0xf8a2D6F8c58626eE3BcDb4638F2a2f30Fe021242 (pc burner) and the locker 0x866e... |
| venues, 44 total, decoded from the launch tx input | v2 x 12: factories uni 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f (init hash 0x96e8ac42...), sushi 0xC0AEe478..., pancake v2 0x1097053F..., each vs WETH, USDC, USDT, DAI. v3 x 32: uni 0x1F98431c8aD98523631AE4a59f267346ea31F984 (hash 0xe34f199b...) tiers 100, 500, 3000, 10000 and pancake deployer 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9 tiers 100, 500, 2500, 10000, each vs the same four counters |

for a new coin, reuse the same exempt list shape: add the locker if you want locker collects budget independent (not needed, fork shows the attest covers it), add whichever fee recipient or burner contract receives coin straight from a venue (otherwise it is taxed at 15%). `exempt` can only be set at launch.

contract swapper through `PoolManager.unlock` buying from the canonical pool: coin goes PoolManager to swapper, which is a venue outflow, but the afterSwap attestation equals that amount, so it is untaxed (fork Admin.t.sol, exact in and exact out). if the swapper keeps the coin as ERC6909 claims then no ERC20 moves and nothing is taxed until the claim is taken out.

### gap analysis versus a hard transfer restriction

111 does not restrict anything. no transfer ever reverts, there is no allowlist of holders or destinations. it only skims 15% of coin leaving a listed venue. everything below was executed on the fork unless marked (reasoned).

| route | taxed or skimmed | 111 covers it | cost |
|---|---|---|---|
| wallet to wallet, OTC, escrow or settlement contracts, multisig | neither | no | free (fork: 400k transfer untaxed) |
| unlisted dex: v2 pair vs WBTC or any counter not in the 4, other v2/v3 forks, fee tiers outside the list, curve, balancer, solidly, maverick, order book, rfq | neither (V2 WBTC pair buy untaxed, fork) | no | create a pool or use an existing one, free |
| listed v2/v3 pair (4 counters) | buy taxed 15%, no skim | partly | attacker pays 15% on buys, sells free |
| v4 side pool, no hook, other fee tier or spacing | buy taxed 15% (PoolManager is a venue), no skim | partly | 15% on buys. SELLS into it are untaxed and unskimmed (fork) |
| `initializePoolOpen` pool on the skim hook (anyone can call) | taxed 15% on buys, creator picks skim config (fork: baseline 0 means no skim), gets NO budget | partly | same as side pool |
| v4 claims route: swap in a side pool minting ERC6909 claims, trade claim to claim, `take` later | no tax until `take` as ERC20, then 15% (fork) | partly | deferred only. claims are transferable inside the PoolManager (reasoned) |
| same tx budget subsidy: canonical buy minted as claims (budget attested, never consumed), then side pool buy with ERC20 take | side buy untaxed up to the canonical coin out of that tx (fork) | no | the attacker pays the skim on the canonical leg, so cost = skim on equal volume |
| aggregator or router settlement | taxed when it receives from a listed venue, free through unlisted ones | partly | same as the venue |
| wrappers, vaults, lending markets, bridges | coin deposit is wallet to contract, untaxed. the wrapper token trades anywhere | no | free |
| sell side anywhere | never taxed or skimmed outside the canonical hook pool | no | free. the tax is buy side only |

so the three gaps that matter for a hard restriction: (1) transfers and any unlisted venue are fully free, tax and skim both missing, nothing reverts; (2) every sell and every non canonical pool bypasses the skim, the only toll is 15% on coin leaving a venue and V4 side pools are the cheapest place to trade it, with sells into them completely free; (3) the tax rate is admin tunable down to 0 and the venue list is frozen at 44 entries, so the only structural coverage is the PoolManager immutable. for a hard transfer restriction the token itself would need a transfer allowlist (revert unless a side is the canonical pool path), which this token does not have. this is outside the factory config, it is a different token contract.

## 6. plain swapper through `PoolManager.unlock`, burn, approve

swapper requirements (all fork verified, Base.sol and Admin.t.sol `test_contract_swapper_receives_untaxed_from_poolmanager`):
- call `PoolManager.unlock(data)` and do the swap in `unlockCallback`. pool key `(address(0), coin, 0x800000, tickSpacing, hook)`. buy is `zeroForOne = true`, sell is false. `sqrtPriceLimitX96` must be a legal limit (4295128740 for a buy, `TickMath.MAX_SQRT_PRICE - 1` for a sell).
- the delta the PoolManager returns to the swapper is the GROSS one: the skim is already inside it (1 eth exact in buy gives delta0 = -1 eth exactly). settle eth with `settle{value: x}()` (native, no `sync` needed), receive coin with `take(currency1, to, amount)`. for a sell, `sync(coin)`, transfer coin to the PoolManager, `settle()`, then `take(currency0, ...)` for eth. the swapper must accept native eth (`receive`) if it takes eth.
- hookData: empty bytes is accepted (fork). exact in and exact out both work in all four directions (Dirs.t.sol). no minimums, no per swap size limits, no mev window restriction on swaps (the window only locks public liquidity adds). optional attribution hookData for referral credit: `abi.encode(PoolSwapData(bytes mevModuleSwapData, bytes poolExtensionSwapData = abi.encode(PCSwapData(PCAttribution(bytes32 sourceId, address referrer, bytes16 campaignId, uint24 referralBps), bytes extensionPayload))))`, see pc docs/reference/guides/swap-with-attribution.md. malformed hookData is ignored (try/catch), no revert.
- taxed? no. the coin comes from the PoolManager (a venue) but the hook attests exactly the realized coin out in `_afterSwap`, so the budget covers the take, also when the receiver is a contract (fork: swapper got the full pool amount, also on exact out). a sell pays no tax (coin goes into the venue). if the swapper keeps coin as ERC6909 claims, a `take` in a later tx has no budget left (transient) and is taxed 15% (reasoned from the transient slot, the side pool claims case is fork verified).
- the hook returns `afterSwap` unspecified deltas so the swapper should not assume a quoted amount, read the delta returned by `swap`.
- native eth only: `quoteToken` must be address(0). a router that can only move erc20 cannot trade this pool, there is no WETH pool.

token surface (src/ArtCoinsToken.sol): solady ERC20 with permit, plus
- `burn(uint256 amount)` line 229 burns from msg.sender. `burnFrom(address account, uint256 amount)` line 234 spends the caller's allowance then burns (fork: totalSupply drops, allowance consumed). no tax, no hook, burn reduces totalSupply.
- Permit2 special case (solady): `allowance(owner, PERMIT2)` returns max uint without any approval, and `approve(PERMIT2, x)` reverts for any x other than max (fork: `approve(P2, 5)` reverts, `approve(P2, max)` ok). Permit2 is 0x000000000022D473030F116dDEE9F6B43aC78BA3. other spenders behave normally. permit (EIP 2612) exists.
- admin functions: `updateAdmin`, `renounceAdmin`, `updateImage`, `updateMetadata`, `setMetadataRenderer`, `verify` (original admin), `setTaxBps`. no pause, no blacklist, no mint after the ctor, no owner.

## 7. powers after launch

| actor | can | cannot |
|---|---|---|
| token admin (tokenAdmin from the config, can be a contract, `updateAdmin` moves it, `renounceAdmin` zeros it) | `setTaxBps` in [0, taxBpsMax]; token image, metadata, renderer; hook `setMaxReferralBpsOfVolume` up to 1000; `setSniperFeeRecipient` and its lock (inert for skim); `setPoolExtension` to an allowlisted extension (none enabled today), `lockPoolExtension` (all fork verified) | change bountyRecipient, protocolRecipient, bountyBps, baselineSkimBps, lpFee, quote token, tick or position set, venues, exempt list, burn sink; a non admin is rejected on every one |
| skim hook 0x636c | nothing: no owner, no admin, no pause. skim config is written once at `initializePool` | cannot be disabled for a live pool. `factory.setHook(hook,false)` only blocks NEW launches (fork: live pool kept skimming and trading) |
| factory owner 0xCB43 (an EOA with an EIP 7702 delegation, code 0xef0100...) | `setDeprecated`, `setDeployFee` (max 1 eth), `setTeamFeeRecipient`, `setDefaultProtocolFeeBps`, `setHook`, `setLocker`, `setMevModule`, `setExtension`, `setAdmin`, `recoverETH`, `claimTeamFees` (factory held tokens) | touch existing pools, tokens, skim legs or LP positions |
| locker owner 0xCB43 | keeper reward knobs (`setKeeperRewardBps` max 200, `setKeeperRewardCap` bounded), `withdrawETH` and `withdrawERC20` of balances sitting in the locker contract | move LP positions: the NFTs sit in the locker and there is no transfer or principal decrease path, only zero liquidity fee collects (locker line 489) |
| locker reward admin (per slot, set at launch) | `updateRewardRecipient` and `updateRewardAdmin` for that slot. launching with admin 0xdEaD makes the recipient permanent (fork: only 0xdEaD itself could change it, which nobody controls) | n/a |
| fee escrow owner 0xCB43 | `addDepositor` | remove depositors, sweep, change balances |
| pool extension allowlist owner 0xCB43 | enable extensions, after which a token admin may attach one. an extension runs in `_afterSwap` and could revert swaps. none enabled, and `lockPoolExtension` or renouncing admin removes the path | |
| mev module 0xb038 | read only `currentSkimBps`, no owner. a reverting module falls back to baseline | |
| uniswap v4 governance | can set a protocol fee on the pool (0 at launch, fork) | |
| anyone | `collectRewards(coin)` (pays keeper reward if set, rest to reward recipients through the escrow), `claim(feeOwner, token)` on the escrow, `initializePoolOpen` side pools on the hook | |

what can redirect or stop the bounty flow after launch: (a) nothing in artcoins can change `bountyRecipient` or `bountyBps`; they are fixed at launch. (b) the recipient contract itself: if its `receive()` reverts or runs out of gas, every swap reverts (this also freezes the pool for everyone, sells included). if the recipient is upgradeable or can be paused, that is a stop switch, and if it holds a payable `fallback` returning empty data it self bricks at 0.01 eth balance. (c) the factory owner cannot reach live pools. (d) token admin can only lower the referral cap, lower the tax and attach an allowlisted extension (none now). (e) the LP fee leg goes to the locker reward recipient, not the bounty recipient, and is only changeable by that slot's admin (0xdEaD at launch means never). (f) anyone can route around the canonical pool (section 5), which reduces skim volume without anyone holding a power.

## 8. what stops a fresh launch at the pin, and the minimal owner action

| check | state at 26127622 (and at latest) | blocks? |
|---|---|---|
| `factory.deprecated()` | true, `_doDeploy` line 222 reverts `Deprecated` for any caller that is not owner or in `admins` | yes, for everyone except owner 0xCB43 |
| hook enabled | `enabledHooks(0x636c)` true | no |
| locker enabled for that hook | `enabledLockers(0x866e, 0x636c)` true | no |
| mev module | `enabledMevModules(0xb038)` true (address(0) also fine) | no |
| extensions | none enabled, so `extensionConfigs` must be empty | no if empty (`ExtensionNotEnabled` otherwise, fork) |
| msg.value | must equal `deployFee` 0.069 ether | wrong value reverts |
| supply | 0 or >= 1e18 | no |
| teamFeeRecipient | 0xCB43 set, receives eth | no |
| protocol bps | `WithProtocolBpsAndTax` with bps 0 | no |

minimal real owner action: `ArtCoinsFactory.setDeprecated(false)` called from the owner 0xCB43078C32423F5348Cab5885911C3B5faE217F9, which opens launching to everyone (fork: `vm.prank(OWNER)`). narrower alternative: `ArtCoinsFactory.setAdmin(ourDeployer, true)` from the owner, then `deprecated` can stay true and only that address can launch (fork verified, also `claimTeamFees`, `setHook`, `setLocker`, `setMevModule` become callable by an admin, so do not hand it out lightly). the owner can also simply launch itself: with `vm.prank(OWNER)` as the caller everything works while deprecated stays true (fork Launch.t.sol). on a foundry fork use `vm.prank(OWNER)` or `vm.startPrank`. the owner has an EIP 7702 delegation on mainnet, so on anvil use `anvil_impersonateAccount`. nothing else needs changing: no hook, locker, module or allowlist call. a fresh launch needs a new `userSalt` or admin for each coin.

## 9. gotchas collected

- only factory 0x4959... can launch with the skim hook and tax. the older factory 0xf051... is not deprecated and accepts launches, but it has no skim hook and no tax entry point.
- plain `deployToken` cannot be used: it forces the 20% protocol slot and has no tax parameter. use `deployTokenWithProtocolBpsAndTax(cfg, 0, tax)`.
- 111 launched with `msg.value 0` only because the owner had set `deployFee` to 0 for that tx. today it is 0.069 ether exactly.
- the tax config is in the CREATE2 initcode: predict with the exact taxConfig. `script/LaunchLayer.s.sol` predicts with an empty one.
- `tickIfToken0IsArtCoins` is mirrored for an eth pool. pass the 111 style negative value and expect a positive pool tick. locker tickLower must be at or above the passed value.
- `referralPayout` must be a contract with a payable `notify(address)`: with an EOA payout any swap that carries a referrer reverts (fork: `swap with referrer and EOA payout succeeded: false`), because the high level call hits the extcodesize check outside the try/catch. swaps without a referrer are fine.
- bounty recipient: no gas cap, hard revert on failure. payable fallback with empty return plus balance of 0.01 eth or more bricks every swap (forge shows `WrappedError(hook, 0x575e24b4, ...)`, 0x575e24b4 is the beforeSwap selector, where `streamForward` is called). with the 0.01 threshold a treasury that holds eth for other reasons is exposed.
- the anti sniper window skims up to 90% of volume to the bounty recipient and locks public liquidity adds. pass `0x` or an address(0) module to skip it. `endingBps` should equal `baselineSkimBps` or the decay settles at the wrong level (not enforced).
- venue tax is on coin leaving a venue only. budget is transient per tx, so an exempt contract that receives coin straight from a venue must be in `exempt` or be in the same tx as a canonical swap.
- the pool starts at lpFee 0 until the first swap sets the dynamic fee in `_beforeSwap`.
- all fork results above are from `/tmp/claude-0/-home-claude/d82c2ac8-14b2-57ac-9126-121e363f7cb8/scratchpad/fork`. 2 of the 77 tests there (the same prefunded fallback treasury case counted per inheriting contract) fail on purpose, they demonstrate the brick above.
