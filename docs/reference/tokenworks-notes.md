# tokenworks reference notes

source: sourcify exact_match, pulled 2026 10 05. all code is MIT. paths below are under `docs/reference/tokenworks/`.
`impl/` is the live CreditStrategy implementation 0xdF9F...13A5 (authoritative). `hook/` and `factory/` are their own verified sources. the strategy files inside `factory/src/strategies/` are an OLDER snapshot (no `manager`, `setPriceMultiplier` is onlyFactory). do not copy from them.

## 1. what is deployed and how it is wired (all read from chain)

| item | address | note |
|---|---|---|
| CreditStrategy proxy | 0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6 | ERC1967 clone with immutable args, UUPS. impl 0xdF9FEC9Ac40dd7F0911d139327B7b4a6dE9713A5 (VERSION 1) |
| hook (NFTStrategyHook) | 0x8fb66C6E0f3cbb25001e0f1C0352Cc888cFF6444 | one shared hook for every tokenworks nft strategy. not a proxy |
| factory (NFTStrategyFactory) | 0x1966780F08b1699fB57E05ED2d7654E3ec64390D | `strategy.factory()`. immutable args bytes 0..20. hook.nftStrategyFactory is the same address. factory.hookAddress() is now 0, so no new launches |
| PoolManager | 0x000000000004444c5dc75cB358380D2e3dE08A90 | v4. proxy args bytes 40..60 |
| router (buybacks) | 0x00000000000044a361Ae3cAc094c9D1b14Eece97 | z0r0z/v4-router UniswapV4Router04. proxy args bytes 20..40. NOT verified on sourcify. README of that repo lists this address |
| PositionManager | 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e | used by the factory at launch only |
| Permit2 | 0x000000000022D473030F116dDEE9F6B43aC78BA3 | factory immutable |
| global distributor handler | 0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D | hardcoded in BaseStrategy:64, allowlists transfers, owner is the tokenworks owner 0x019817aD02a31B990433542097bE29D97613E8Cb |
| Seaport 1.6 | 0x0000000000000068F116a894984e2DB1123eB395 | NFTStrategy:113 |
| strategy owner | 0x019817aD02a31B990433542097bE29D97613E8Cb | can upgrade, set distributors. manager is 0 |
| collection | Credits 0x97630aA70AB14ed9883B41dAfccBc11349723043 | |
| other chain facts | hook.feeAddress 0x2ABD4B16a9663F4913F35A87A2C3078dF165bF12, feeAddressClaimedByOwner[strategy] 0xc8f8e2F59Dd95fF67c3d39109ecA2e2A017D4c8a, hook.deploymentTime[strategy] 1790135603 | |

pool key (confirmed by hashing the key and reading PoolManager slot0):

```
currency0 = address(0) (ETH)     currency1 = 0x8e60...53d6 (coin)
fee = 0     tickSpacing = 60     hooks = 0x8fb6...6444
poolId = 0x75f26ca71b6dd3f7316b3da177fdd469a72e66bdac73a4533c70657431e559fe
```

pool state at the pinned block: tick 158628, sqrtPriceX96 220437659388812490248312444546290, protocolFee 0, lpFee 0, liquidity 158372218983990412488087 (equal to the launch liquidity, so nothing was ever added or removed).

## 2. build settings and versions (details and method in section 9)

solc 0.8.30+commit.73712a01, optimizer on runs 200, evm cancun, via_ir true, bytecodeHash ipfs, appendCBOR true. same for impl, hook, factory. full remappings in each `compilation.json`.
solady v0.1.25. v4-core npm 1.0.2 (59d3ecf). v4-periphery npm 1.0.2 (ad04c9f). v4-router z0r0z at f5d5bfc. permit2 interfaces cc56ad0. universal-router: nothing vendored.

## 3. transfer restriction

`impl/src/strategies/BaseStrategy.sol:416-456` (solady ERC20 hook, runs after balances move):

```solidity
function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    if (from == address(0)) return;                       // mint at init
    address distributor = _globalDistributor();           // :508 mainnet = 0xDf99..., else storage
    if (distributor != address(0)) {
        if (IGlobalDistributor(distributor).isGlobalDistributor(from) ||
            IGlobalDistributor(distributor).isGlobalDistributor(to)) return;
    }
    if (isDistributor[from] || isDistributor[to]) return;  // local allowlist, owner or manager sets
    if ((from == address(poolManager()) || to == address(poolManager()))) {
        uint256 transferAllowance = getTransferAllowance();
        require(transferAllowance >= amount, InvalidTransfer());
        assembly { let newAllowance := sub(transferAllowance, amount) tstore(0, newAllowance) }
        emit AllowanceSpent(from, to, amount);
        return;
    }
    revert InvalidTransfer();
}
```

the allowance, `BaseStrategy.sol:334-341` and `:461-469`:

```solidity
function increaseTransferAllowance(uint256 amountAllowed) external {
    if (msg.sender != hookAddress) revert OnlyHook();
    uint256 currentAllowance = getTransferAllowance();
    assembly { tstore(0, add(currentAllowance, amountAllowed)) }
    emit AllowanceIncreased(amountAllowed);
}
function getTransferAllowance() public view returns (uint256 a) { assembly { a := tload(0) } }
```

facts:

* one transient slot, `tstore(0)`, a single fungible counter. not bound to a pool, payer or direction. it dies at end of tx.
* only `hookAddress` may raise it (storage var, owner can change it via `updateHookAddress`).
* the check order is: mint, global allowlist, local allowlist, PoolManager leg, revert. so an allowlisted address bypasses the allowance for every transfer, including to or from the PoolManager.
* `to == address(0)` (burn) from a non allowlisted sender reverts. tokenworks burns by sending to 0xdEaD as the swap receiver, not by `_burn`. coin goes PoolManager to dead under hook allowance.
* the allowance is only set by two hook callbacks: `_afterAddLiquidity` and `_afterSwap`. nothing else raises it.

| flow | transfers that happen | allowance the hook sets |
|---|---|---|
| liquidity add (launch only) | factory to PoolManager via permit2 | `-delta.amount1()` in afterAddLiquidity, before posm settles |
| sell, exact in (coin to ETH) | user or router to PoolManager | `abs(delta.amount1())` |
| buy, exact in (ETH to coin), fee in coin | PoolManager to receiver (amount minus fee), PoolManager to hook (fee), hook to PoolManager (fee, nested swap) | `abs(delta.amount1()) + fee` |
| remove liquidity | PoolManager to owner | none set, so any coin leg reverts |

risk to carry into our design: the hook must never over grant. a leftover allowance is usable by any later PoolManager transfer in the same tx, in any pool.

## 4. fee hook (`hook/src/NFTStrategyHook.sol`)

permissions, `:220-237`: beforeInitialize, afterAddLiquidity, afterSwap, afterSwapReturnDelta. nothing else.

| flag | bit | value |
|---|---|---|
| BEFORE_INITIALIZE | 13 | 0x2000 |
| AFTER_ADD_LIQUIDITY | 10 | 0x0400 |
| AFTER_SWAP | 6 | 0x0040 |
| AFTER_SWAP_RETURNS_DELTA | 2 | 0x0004 |
| low 14 bits | | 0x2444 |

deployed hook address ends 0x6444 (bits 14, 15 are unconstrained, mined by CREATE2). `BaseHook` constructor validates flags against `getHookPermissions`. mine with `v4-periphery/src/utils/HookMiner.sol` (exists at ad04c9f). `Hooks.sol` skips every callback when `msg.sender == hook` (`v4-core Hooks.sol:293` for afterSwap), which is what lets the hook run a nested swap without recursing.

fee currency is the UNSPECIFIED currency of the swap, `hook:288-352`:

```solidity
if (params.amountSpecified > 0) revert ExactOutputNotAllowed();          // exact out is banned
bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
(Currency feeCurrency, int128 swapAmount) =
    (specifiedTokenIs0) ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
if (swapAmount < 0) swapAmount = -swapAmount;
uint128 currentFee = calculateFee(collection, params.zeroForOne);        // zeroForOne == buying
uint256 feeAmount = uint128(swapAmount) * currentFee / TOTAL_BIPS;
uint256 collectionAmountToTransfer = abs(delta.amount1());
if (feeAmount == 0) { INFTStrategy(collection).increaseTransferAllowance(collectionAmountToTransfer); return (afterSwap.selector, 0); }
collectionAmountToTransfer += (feeCurrency == key.currency1) ? feeAmount : 0;   // buys: fee in coin
INFTStrategy(collection).increaseTransferAllowance(collectionAmountToTransfer);
manager.take(feeCurrency, address(this), feeAmount);
if (!ethFee) { uint256 feeInETH = _swapToEth(key, feeAmount); _processFees(collection, feeInETH); }
else { _processFees(collection, feeAmount); }
return (BaseHook.afterSwap.selector, feeAmount.toInt128());
```

what this means, and where it differs from SPEC section 4 ("taken in eth"):

* sells (coin in, exact in): specified is the coin, so the fee is taken in ETH out of the ETH output. direct.
* buys (ETH in, exact in): specified is ETH, so the fee is taken in COIN out of the coin output, then the hook sells that coin back into the same pool (`_swapToEth`, `:359-373`, oneForZero, price limit MAX-1, no min out) and gets ETH. the fee is "in ETH" only after a nested swap that moves the price.
* exact out is reverted, so every integration must swap exact in. the dead branch that doubles the fee for exact out (`:328`) never runs.
* fee schedule `calculateFee :202-216`: sells flat 1000 bps. buys start 9900 bps at pool init and fall 100 bps per minute until 1000 (89 minutes). `deploymentTime[collection]` set in beforeInitialize. now both sides are 1000 (verified by call).
* split `_processFees :176-195`: 80% to `strategy.addFees{value}` (only `hookAddress` may call), 10% forceSafeTransferETH to the factory (buys PNKSTR), 10% to `feeAddressClaimedByOwner[strategy]` else `feeAddress`. all three are push transfers inside the swap.
* liquidity add: afterAddLiquidity sets the allowance (section 5). liquidity remove: no callback at all.
* the hook inherits `ReentrancyGuard` but never uses the modifier.

if we want a true ETH fee on buys without the nested swap (our idea, not theirs): enable beforeSwap and beforeSwapReturnDelta (flags 0x2444 | 0x80 | 0x08 = 0x24CC), return `BeforeSwapDelta(+fee, 0)` on the specified ETH side and `manager.take` it in beforeSwap. the coin then never touches the hook.

## 5. launch (`factory/src/factories/StrategyFactory.sol:242-316`, called from `NFTStrategyFactory.sol:166`)

```solidity
loadingLiquidity = true;
uint24 lpFee = 0;  int24 tickSpacing = 60;
uint256 token0Amount = 1;  uint256 token1Amount = 1_000_000_000 * 10 ** 18;
uint160 startingPrice = 501082896750095888663770159906816;   // 40,000,000 coin per ETH (comment in source is wrong)
int24 tickLower = TickMath.minUsableTick(tickSpacing);       // -887220
int24 tickUpper = int24(175020);
uint128 liquidity = 158372218983990412488087;                // hardcoded
key = PoolKey(currency0 = 0, currency1 = token, 0, 60, IHooks(hookAddress));
actions = MINT_POSITION, SETTLE_PAIR;  recipient = DEAD_ADDRESS
params[0] = posm.initializePool(key, startingPrice, hookData);
params[1] = posm.modifyLiquidities(abi.encode(actions, mintParams), block.timestamp + 60);
permit2.approve(_token, address(posm), type(uint160).max, type(uint48).max);
posm.multicall{value: 2 wei}(params);
loadingLiquidity = false;
```

* whole supply (1B, MAX_SUPPLY, minted to the factory in `__BaseStrategy_init :187`) goes into one position. no team allocation, no ETH seed beyond 2 wei dust.
* start sqrt price is exactly 4e7 coin per ETH, tick floor 175052. tickUpper 175020 is below it (price 3.987e7), so the position is 100% coin and the pool opens just above the range. the first ETH in walks the price down into the range. max range is [-887220, 175020], so liquidity is deep and one sided.
* initialization and the mint happen in one `posm.multicall` in the same tx. `hook._beforeInitialize :243` requires `loadingLiquidity` true and currency0 == ETH, so nobody else can initialize the pool at a different price. `_afterAddLiquidity :262` requires the same flag, so nobody else can ever add liquidity either.
* position owner: the posm NFT is minted to `DEAD_ADDRESS`. pool liquidity equals the hardcoded launch value on chain, so it was never changed. removal is blocked three ways: nobody controls the NFT, the hook gives no allowance on remove, and the coin leg would revert in `_afterTokenTransfer`. lpFee is 0 so there are no LP fees to collect.
* factory auth: `onlyLauncher` (owner or `launchers`). buyIncrement bounded 0.01 to 0.1 ether at launch.
* anti snipe: only the decaying buy fee in section 4 (99% falling 1% per minute). nothing else (no max wallet, no block delay). SPEC section 13 drops the stepping fee, so the launch has no snipe protection unless we add one.
* initial coin liquidity is placed by the factory with allowance from the hook, no allowlist entry for the factory is needed.

## 6. buyTargetNFT check sequence (`impl/src/strategies/NFTStrategy.sol:230-293`)

order of checks (all revert with a custom error):

1. `nonReentrant`.
2. snapshot `ethBalanceBefore = address(this).balance`, `nftBalanceBefore = collection.balanceOf(this)`.
3. `collection.ownerOf(expectedId) == this` reverts `AlreadyNFTOwner`. (also reverts if the id does not exist.)
4. `value > currentFees` reverts `NotEnoughEth`.
5. `value > getMaxPriceForBuy()` reverts `PriceTooHigh`. (`BaseStrategy:306`, `(blocksSinceLastBuy+1) * buyIncrement`.) we do not reuse this.
6. `target == address(collection)` reverts `InvalidTarget`. this is the ONLY target restriction. `target` and `data` are otherwise arbitrary, so the strategy can be made to call anything as itself (approvals, coin transfers). our allowlist fixes it.
7. `(bool ok, bytes memory reason) = target.call{value: value}(data)`; `!ok` reverts `ExternalCallFailed(reason)`.
8. `collection.balanceOf(this) != nftBalanceBefore + 1` reverts `NeedToBuyNFT`.
9. `collection.ownerOf(expectedId) != this` reverts `NotNFTOwner`.
10. `cost = ethBalanceBefore - address(this).balance` (checked math, underflows if balance rose). `currentFees -= cost`.
11. `salePrice = cost * priceMultiplier / 1000` (1200 means 1.2x). `nftForSale[id] = salePrice`. `lastBuyBlock = block.number`. optional seaport listing. emit.

there is no explicit `cost <= value` check, and no caller tip. gotchas for our port:

* `receive() :620-626` books ETH from Seaport as sale proceeds (`ethToTwap += 99.5%`, `syncListingReward += 0.5%`). a Seaport REFUND during `buyTargetNFT` lowers `cost` and is also booked as proceeds: it is counted twice. our Core must not book revenue in `receive()`, or must ignore inbound ETH while a buy is in flight.
* the cost measures the whole balance, not just the target's effect. keep the guard and the allowlist.

`sellTargetNFT :297-325` (the function our Core will call on CreditStrategy): `nonReentrant`, `price = nftForSale[id]`, `price == 0` reverts, `msg.value != price` reverts `NFTPriceTooLow`, requires it owns the id, cancels a seaport listing, `collection.transferFrom(this, msg.sender, id)` (plain transferFrom, no receiver callback), `delete nftForSale[id]`, `ethToTwap += price`.

## 7. processTokenTwap and the buyback swap

`BaseStrategy.sol:355-380`:

```solidity
function processTokenTwap() external virtual nonReentrant {
    if (ethToTwap == 0) revert NoETHToTwap();
    if (block.number < lastTwapBlock + twapDelayInBlocks) revert TwapDelayNotMet();
    uint256 burnAmount = twapIncrement;                     // 1 ether, 1 block delay today
    if (ethToTwap < twapIncrement) burnAmount = ethToTwap;
    uint256 reward = (burnAmount * 5) / 1000;               // 0.5% tip to the caller
    burnAmount -= reward;
    ethToTwap -= burnAmount + reward;                       // effects before interaction
    lastTwapBlock = block.number;
    _buyAndBurnTokens(burnAmount);
    SafeTransferLib.forceSafeTransferETH(msg.sender, reward);
}
```

`:389-409`:

```solidity
PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(this)), 0, 60, IHooks(hookAddress));
BalanceDelta delta = router().swapExactTokensForTokens{value: amountIn}(
    amountIn, 0, true, key, "", DEAD_ADDRESS, block.timestamp);
```

* router: `IUniswapV4Router04` single pool overload `swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, bool zeroForOne, PoolKey poolKey, bytes hookData, address receiver, uint256 deadline)`, selector 0xb1a0d571. payable, native ETH sent as msg.value. the router refunds unused ETH to the payer (`BaseSwapRouter._refundETH`), which is why `receive()` must accept it.
* slippage: `amountOutMin = 0`, `deadline = block.timestamp`. there is no slippage protection at all. exposure is capped only by slice size (1 ETH per call) and the 1 block delay. a sandwich can take the whole slice. we should set a real min out or an oracle bound.
* tip: 0.5% of the slice, paid after the swap with force send.
* burn: coin delivered straight to 0xdEaD as the swap `receiver` (PoolManager to dead), not `_burn`. dead is not on tokenworks' allowlist, it works through the hook allowance. totalSupply is unchanged.
* fee: the buyback swap is a normal buy, so it pays the hook fee. at 10% the hook takes 10% of the coin out as the fee, converts it to ETH, and sends 80% of that into `addFees` (back to `currentFees`), 10% to the factory, 10% to the creator. dead receives 90% of the coin. a 99% buy fee window would eat the buyback.
* funding: `ethToTwap` grows only from `sellTargetNFT` proceeds and Seaport sale proceeds. hook fees go to `currentFees` (buying nfts), never to the buyback.
* `addFees` and `increaseTransferAllowance` are called by the hook mid buyback, while the guard is held (section 8).
* factory has its own copy for PNKSTR (`StrategyFactory.sol:389`) with the same tip and slice.

## 8. reentrancy guard usage

* `ReentrancyGuard` is solady v0.1.25 `src/utils/ReentrancyGuard.sol`: STORAGE based, slot constant 0x929eee149b4bd21268 holds `address(this)` while locked and `codesize()` after. the transient variant `ReentrancyGuardTransient.sol` exists in the same tag but is unused.
* guarded: `processTokenTwap`, `buyTargetNFT`, `sellTargetNFT`, `createSeaportListing`, `syncOrderStatus` (all share one lock). factory `processTokenTwap` guarded.
* NOT guarded and must stay that way: `addFees`, `increaseTransferAllowance`, `receive`. the hook calls them during `processTokenTwap` while the lock is held. a guard on `addFees` would revert every buyback. SPEC section 12 says "reentrancy guards on every external path": that cannot include `addFees`. keep it gated by `msg.sender == hook` and do checks effects interactions.
* the hook has no guard in practice.
* the token's ERC20 transfers are never guarded.

## 9. versions and how they were matched

method: git blob hash of every vendored file in the sourcify `sources` map compared against `git log --find-object` over full upstream clones, then the intersection of commit ranges in which all vendored files are byte identical. file lists are in `tokenworks/vendored-libs.txt`.

| lib | match | evidence |
|---|---|---|
| solady | tag v0.1.25 (d07f92e, 2025-08-25) | ERC20, ERC721, Ownable, Initializable, UUPS, LibClone, ReentrancyGuard, SafeTransferLib, CallContextChecker all identical. SafeTransferLib pins it to 71d5107..d07f92e (the safeMoveETH fix) |
| v4-core | 1.0.2, commit 59d3ecf (2025-05-13) | all vendored src and `test/utils/CurrencySettler.sol` identical across a7cf038 (2025-04-28) to HEAD, with no src change after. v4.0.0 (2025-01-21) does NOT match: PoolOperation.sol and the new Hooks.sol and IPoolManager.sol came later. the live PoolManager is the v4.0.0 deployment, the ABI is compatible |
| v4-periphery | 1.0.2, commit ad04c9f (2025-05-13) | vendored subset identical across 444c526 to 7ebd04b. subset is only BaseHook, ImmutableState, IPositionManager, Actions and interfaces, so exact commit inside that range is not provable. 1.0.2 is the npm release and pins v4-core 59d3ecf |
| v4-router | z0r0z/v4-router f5d5bfc (2025-08-21) | only IUniswapV4Router04 and PathKey vendored, identical across a1d9371 to f5d5bfc. f5d5bfc pins v4-core 59d3ecf and v4-periphery ad04c9f, which matches the two rows above |
| permit2 | cc56ad0 (2023-09-29) | only interfaces ISignatureTransfer, IEIP712, IAllowanceTransfer. repo has no tags |
| universal-router | none | remapping only, no code compiled. the router submodule pin is 8bd498a (2025-02-11) |

compiler settings (all three contracts): solc 0.8.30+commit.73712a01, optimizer enabled runs 200, evm cancun, via_ir true, bytecodeHash ipfs, appendCBOR true, useLiteralContent false. pragma is ^0.8.26 everywhere. tstore needs cancun.
for our foundry.toml: `solc = "0.8.30"` (SPEC says 0.8.28 or later, fine), `evm_version = "cancun"`, `via_ir = true`, `optimizer_runs = 200`. note `CurrencySettler` lives in v4-core `test/utils`, which is fine under forge.
the unverified router: deployed bytecode could not be compared. its address matches the repo README. we only need its ABI, which is vendored in `impl/`.

## 10. what this means for SPEC.md

* section 4 allowlist says "the second pool added in phase 2". a v4 pool is not an address. every pool shares the PoolManager, and tokenworks' restriction treats the PoolManager as one party. putting the PoolManager on the allowlist turns the restriction off for every pool, including a hookless coin/ETH pool anyone can initialize, which is the fee dodge it exists to stop. what is possible: (a) `Coin` keeps a set of hooks allowed to call `increaseTransferAllowance` (tokenworks has one `hookAddress`), and the second pool gets its own hook that grants exact allowances. (b) a private second pool traded only by allowlisted addresses (Core, dead). Core can move coin to and from the PoolManager freely because the allowlist check comes first. nobody else can swap or LP in that pool. any public coin/exitToken pool needs (a). also tokenworks' hook is ETH/coin only (`require currency0 is native`, fee conversion swaps in the same pool), so the same `FeeHook` cannot serve a non ETH pool unchanged.
* liquidity add is not mentioned in section 4. the launch needs the hook to grant allowance in afterAddLiquidity, gated by a one shot launch flag held by the launcher (tokenworks: `factory.loadingLiquidity`), or the launcher must be on the allowlist. gate beforeInitialize and afterAddLiquidity the same way, or a third party can initialize the pool at their price or add liquidity. the coin needs the hook address in its constructor, the hook is address mined, and the hook needs the Core address: plan the deploy order.
* section 4 "taken in eth" is only literally true on sells. buys are taken in coin and converted by a nested swap, because exact out is banned. decide: copy that, or use beforeSwap return delta (section 4 end).
* section 4 `CREATOR_BPS` and `Core.addFees()`: tokenworks splits 80/10/10 and `addFees` is unguarded by design (section 8).
* section 5.4 is looser upstream: no target allowlist, no cost vs value check, no tip, and a double count of Seaport refunds in `receive()`.
* section 8.1: upstream buyback has no slippage protection (min out 0) and the buyback pays the hook fee. dead address is not on the upstream allowlist, it only works under hook allowance.
* section 13 and open item 3: no step down fee means no snipe protection at launch. the whole supply sits in one sided liquidity at a fixed 40M per ETH start.
* section 1: credits held by CreditStrategy now 13,133 (spec says about 13,125). listings are flat price per piece (0.036, 0.048, 0.06 ETH), not per point, so score per ETH varies about 6x across listings.
* the allowance is a single global tstore counter, shared across pools, not bound to a payer. over grants are exploitable within the tx. test exact accounting for buy, sell and the buyback.
* the global distributor and local `isDistributor` lists are mutable by the tokenworks owner. SPEC wants a fixed allowlist: use immutables or a one way set.
* fork tests: publicnode serves state only for about the last 100 blocks (tested: 100 back works, 128 back returns 403 "archive requests require a personal token"). the pinned block below is already outside that window, so tests need an archive RPC key, or a re pin at run time.

## 11. fork facts (read at the pinned block)

| fact | value |
|---|---|
| pinned fork block | 26127622 (latest was 26127642 when pinned), timestamp 1791220847, hash 0x4f3f37c2ebfc3c4568e3314e3dc24a8cf13549a24b840cb2187407a34c6997d5 |
| Statements.supply() | 148 (a 148th statement exists, 80 credits, creditScoreOf(148) = 324240913) |
| Statements.score() | 0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7, equals SPEC |
| Credits.supply() | 122154, equals SPEC. Credits.isSealed() true |
| Credits.balanceOf(CreditStrategy) | 13133 |
| CreditStrategy.currentFees / ETH balance | 3834721108400426 wei (about 0.00383 ETH), identical. ethToTwap 0 |
| CreditStrategy.getMaxPriceForBuy() | 2.565 ETH (growing 0.005 per block, so the cap is not binding) |
| CreditStrategy params | priceMultiplier 1200, buyIncrement 5e15, twapIncrement 1e18, twapDelayInBlocks 1, lastTwapBlock 26122356 |
| coin | CREDITSTR, totalSupply 1e27 (1B), pool tick 158628 (about 7.74M coin per ETH) |

three for sale ids (ownerOf is the strategy, nftForSale read at the pin):

| id | price (wei) | price (ETH) | score (1e4 scale) |
|---|---|---|---|
| 18683 | 48000000000000000 | 0.048 | 1513903 (151.39) |
| 28352 | 60000000000000000 | 0.060 | 3687052 (368.71) |
| 35377 | 36000000000000000 | 0.036 | 6554551 (655.46) |

a sample of 140 ids from `tokensOf(strategy)` showed all listed (0 at zero price), mostly 0.048.
