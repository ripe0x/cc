# architecture and director decisions

SPEC.md is the law. this file resolves what the spec leaves open and fixes the seams between contracts. where this file and the spec disagree, this file wins and the deviation is listed in section 9 for the owner to confirm.

naming rule: only `exitModule` and `exitToken`. never name or describe them anywhere.

## 1. toolchain

solc 0.8.30, cancun, via_ir, optimizer 200. solady v0.1.25. v4-core 59d3ecf and v4-periphery ad04c9f (the versions tokenworks compiled against). imports: `v4-core/src/...`, `v4-periphery/src/...`, `solady/...`. reference code: `docs/reference/tokenworks-notes.md` and `docs/reference/tokenworks/`.

every runtime contract must be under 24,576 bytes. check with `forge build --sizes`. Core is the risk: use custom errors, no revert strings, and if needed move pure math into an external library (linked libraries are fine, proxies are not).

shared interfaces and mainnet addresses live in `src/interfaces/Interfaces.sol`. do not change them without sign off. `ICoin` changed once by director decision: `noteDelta(int256)` and `pendingDelta()` replace `increaseTransferAllowance`.

## 2. deploy graph and constructors (fixed)

```
Launcher(address deployer)                                   tx 1, plain create
Core(address owner, address coin, address hook, address controller)   plain create, addresses predicted by nonce
Coin(string name, string symbol, address core, address hook, address supplyReceiver)   supply minted to supplyReceiver = launcher
ControllerV1(address core)
FeeHook(address coin, address core, address creator, address launcher)   create2 through 0x4e59b44847b379578588920cA78FbF26c0B4956C, salt mined for flags
Launcher.launch(coin, hook)                                  one shot, deployer only
```

core, coin and controller addresses are predicted from the deployer nonce (`vm.computeCreateAddress`), so the hook initcode is known before mining. pool manager, credits, statements etc are constants from `Mainnet`.

`Launcher.launch` sets `launching = true`, approves permit2 and the position manager, then in one posm multicall initializes the coin/eth pool and mints one single sided position holding the whole supply to the dead address, mirroring tokenworks (notes section 5): currency0 eth, currency1 coin, fee 0, tickSpacing 60, sqrtPriceX96 501082896750095888663770159906816, range [minUsableTick, 175020], 2 wei of eth. compute liquidity with LiquidityAmounts rather than hardcoding, send any coin dust to dead, then `launching = false` and lock forever.

`script/Deploy.s.sol` exposes a library style function usable from tests (`deploySystem(owner, creator, name, symbol) returns (Deployed memory)`) that loads Core and ControllerV1 creation code with `vm.getCode` so it does not need their types at compile time.

## 3. Coin

* solady ERC20, `SUPPLY` minted once in the constructor, no mint or burn entry points.
* immutables: `core`, `hook`. constant pool manager and dead.
* `noteDelta(int256 coinDelta)` hook only. adds to a transient signed counter D, the net coin the pool manager owes the current locker (positive) or is owed by it (negative). `pendingDelta()` reads it. the hook notes the signed coin leg of every hooked action from the locker's side, so the counter is the net coin the pool manager must still move for hooked actions, and nothing more.
* `_afterTokenTransfer` order (differs from tokenworks on purpose so a note is always consumed before the allowlist is looked at):
  1. mint: return.
  2. transfer from the pool manager of `a`: covered when `D >= a`. then `D -= a` and return.
  3. transfer to the pool manager of `a`: covered when `D <= -a`. then `D += a` and return.
  4. either side is `core` or dead: return.
  5. revert `InvalidTransfer`.
* a note is direction bound. coin can only leave the pool manager against coin the pool manager owes the locker, and only enter it against coin the locker owes. add then remove liquidity nets to zero (up to 1 to 2 wei of rounding, never positive), and a buy then sell round trip nets to zero, so nothing is ever covered beyond the net coin of hooked actions. the counter is transient and a note left over (for example a swap whose coin output was minted as claims) can only be spent by the same transaction in the direction it was noted.
* there is no "second pool" allowlist entry. a v4 pool is not an address. the second pool is served by the same FeeHook (section 4).

## 4. FeeHook

serves exactly two pools: the launch pool (eth / coin) and, in phase 2, the one pool whose id equals `core.exitPoolId()` (coin / exitToken).

permissions: beforeInitialize, afterAddLiquidity, afterRemoveLiquidity, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta. mine the address with HookMiner.

* beforeInitialize: allow the launch key only while `launcher.launching()`. allow another key only if its id equals `core.exitPoolId()` and that is non zero. everything else reverts.
* afterAddLiquidity: launch pool only while `launching`. exit pool: anyone. notes the signed coin leg of the caller's delta (negative, the caller owes coin).
* afterRemoveLiquidity: exit pool only (the launch position is owned by dead). notes the signed coin leg (positive, the pool manager owes the caller coin).
* fee: exactly `FEE_BPS` of the trader's gross notional in the fee currency, where the fee currency is the non coin side (eth, or exitToken in the exit pool). always taken in the fee currency, never in coin, with no nested swap. the gross is what the trader pays (buys) or what the pool pays out before the fee (sells):
  * buy exact in, trader pays E: `fee = E * FEE_BPS / 10_000`. the pool gets the rest.
  * sell exact in, the pool pays out G: `fee = G * FEE_BPS / 10_000`. the trader nets the rest.
  * buy exact out, the pool needs P: the trader pays `P / 0.9`, `fee = P * FEE_BPS / (10_000 - FEE_BPS)`.
  * sell exact out, the trader wants net N: the pool pays `N / 0.9`, `fee = N * FEE_BPS / (10_000 - FEE_BPS)`.
  * fees round down, so the fee is within one wei of the exact share of the gross.
  * fee currency is the specified currency (exact in buy, exact out sell): take it in beforeSwap, return a positive specified delta and `poolManager.take` it. the fee is sized on the whole amount before the pool knows how much fills, so in afterSwap the specified leg of the swap delta must equal what the fee assumed (the offered amount less the fee for exact in, the wanted amount plus the fee for exact out). anything else reverts `PartialFill()`. a price limit or thin liquidity therefore reverts the swap instead of charging the fee on the unfilled amount.
  * fee currency is the unspecified currency (exact in sell, exact out buy): take it in afterSwap from the swap delta, return the fee as the hook delta.
  * both exact in and exact out are supported.
* afterSwap also notes the signed coin leg of the swap delta on the coin (positive when the swapper is owed coin, negative when it owes coin). never more than the net coin of the hooked actions.
* the core's exit buyback is the one exception to the partial fill rule. it swaps exact in with a price limit and so may fill partly. when `sender` is the core, the swap is exact in and the pool is the exit pool, the hook takes no fee in beforeSwap. in afterSwap it takes the fee on what was actually spent, `fee = spent * FEE_BPS / (BPS - FEE_BPS)`, the same gross rule, by pulling the exit token from the core with `transferFrom` into the pool manager and settling it (the afterSwap return value can only change the unspecified currency, so the fee cannot ride on the swap delta). the core approves the hook for exactly the room it left for the fee before the swap and revokes it after, so the hook can never pull more. the fee is booked as claims and split like any other. the eth buyback in the launch pool does not use this path: its fee is taken in beforeSwap and a partial fill reverts.
* split: creator gets `fee * CREATOR_BPS / FEE_BPS`, the core gets the rest. eth: `forceSafeTransferETH(creator, cut, gas stipend)` so a hostile creator cannot brick swaps, then `core.addFees{value: rest}()`. exit token: creator cut accrues in the hook and is paid by a permissionless `claimCreator()`, the rest is transferred to the core followed by `core.addExitFees(rest)`.
* the core's own buyback swaps pay the fee like anyone else (same as tokenworks), with the exit pool timing described above. the core share returns to the pots.
* no owner, no setters.

## 5. Core

`Core(address owner, address coin, address hook, address controller)`. owner is immutable. solady ReentrancyGuard on every external state changing function EXCEPT `addFees`, `addExitFees`, `receive`, `unlockCallback`, `onERC721Received` (the hook calls back into the core during a guarded buyback).

### 5.1 accounting

`ethPot`, `ethToBuyback`, `xPot`, `xToBuyback`. `receive()` accepts eth and books nothing (seaport refunds land here mid buy). `skim()` is permissionless and guarded: moves `balance - ethPot - ethToBuyback` into `ethPot`, and the same for the exit token into `xPot`.

`onERC721Received` accepts only calls from Statements or Credits.

### 5.2 eth rate

state: `rateAtCheckpoint`, `checkpointTime`, `lastFillTime`, `funded`. `ethRate()` is a view that returns the lazily climbed value.

* tiers by time since `lastFillTime`: under 24h 100 bps per hour, 24 to 48h 200, 48 to 72h 400, after that 800. walk the tiers between `checkpointTime` and now, in each `rate = rate * powWad(1e18 + bps * 1e14, dt * 1e18 / 3600) / 1e18`.
* only if `funded` at the checkpoint. additionally clamp the climbed rate to `max(rateAtCheckpoint, ethPot * 1e4 / AVG_SCORE)`: the rate stops climbing at the exact point the pot can no longer afford one average credit. this makes invariant 6 hold between checkpoints.
* `_checkpoint()` runs first in every function that changes `ethPot`, including `addFees`, then the pot changes, then `funded` is recomputed.
* fill of `x` from pot `p` (before the spend): `rate -= rate * DROP_BPS * min(x, p) / (10_000 * p)`, `lastFillTime = now`. for buyListing `x = cost + tip`.
* `lastFillTime` and `checkpointTime` start at deploy.

### 5.3 hourly cap

fixed window that reopens on the first buy after it expires: `windowStart`, `windowPot`, `windowSpent`. on a buy, if `now >= windowStart + 1 hours` open a new window with `windowPot = ethPot` (after checkpoint, before the spend). require `windowSpent + x <= windowPot * SPEND_CAP_BPS_PER_HOUR / 10_000`. tips count, gas reimbursements do not.

### 5.4 credits and piles

per lane an insertion ordered doubly linked list keyed by credit id (0 is the null sentinel, so id 0 is rejected at every door). per credit: lane, inPile, cost, acquiredAt. removing a credit from its pile clears `inPile`, which is also the duplicate check in compose. credits sent to the core outside the doors are not in any pile and are stuck: document, do not handle.

`score(id) = CreditScore.scoreOf(Credits.seedOf(id), Credits.timestampOf(id))`.

### 5.5 doors

* `sellForEth(uint256[] ids)` and `sellForEth(uint256[] ids, uint256 minOut)`. per id: checkpoint, price = ceiling(id), require pot and cap, require `ownerOf(id) == msg.sender`, `transferFrom` in, record, push, drop. pay the total once at the end. `minOut` protects the seller from being front run.
* `buyListing(value, data, id, target)` exactly as spec 5.4, with `x = cost + tip` checked again against pot and cap after the call. forbidden targets (enforced when a target is added and again at call time): Credits, Statements, the core, the coin, the hook, the pool manager, the exit module, the exit token.

### 5.6 compose

`compose()` for the eth lane (spec 6) and `composeExit()` for the exit lane (phase 2 only). measure gas from function entry plus a 50_000 overhead constant. reimbursement `min(gasUsed * basefee * 110 / 100, 5% of statementCost, ethPot)`. for the exit lane the cost basis is in exit token, so its reimbursement cap is `5% of 80 * AVG_SCORE * ethRate / 1e4` and nothing is added to the cost basis. verify the returned id equals `Statements.supply()` and is owned by the core.

### 5.7 statements

per statement: held, lane, cost, clockStart. `priceOf` reverts for exit lane or not held statements. `buyStatement`: half (rounded down) to `ethToBuyback`, the rest to `ethPot`, statement sent with `safeTransferFrom`, excess refunded.

`exitStatement(sid)`: module set, held, eth lane needs `now >= clockStart + AUCTION_LENGTH`, exit lane is immediate. `exitToken` and `unitPerPoint` are read once when the module is set and stored (the unit must be non zero and at most `type(uint128).max`, and is part of the `ExitModuleSet` event). the module is never asked for the unit again. required out is `rating * unitPerPoint` (the stored unit) measured as the core's exit token balance delta. a module that pays by a different unit later is simply held to the stored one. eth lane: half to `xToBuyback`, rest to `xPot`. exit lane: all to `xPot`. eth lane statements remain buyable at the floor until exited.

`overprint()` is permissionless and guarded: asks `controller.nextOverprint()`, requires both held, different, same lane, at most `OVERPRINT_CAP_PER_DAY` per `block.timestamp / 1 days` bucket. cost bases sum onto the base, base clock restarts, top is no longer held.

### 5.8 buybacks

the core swaps directly against the pool manager through `unlock` and `unlockCallback` (no external router). exact in, no min out. coin output is taken straight to the dead address. the callback returns the input actually spent and the coin bought. it requires the pool took no more than the amount it was given, and the call reverts `NothingBought()` when the coin out is zero. the keeper tip is sized on the slice and scaled down in proportion when the fill is partial. input that was not spent (and the part of the tip that was not paid) is credited back to the counter it came from, so nothing is left unbooked.

* `buyback()`: spec 8.1. slice `min(BUYBACK_SLICE, ethToBuyback)`, tip `slice * KEEPER_TIP_BPS / 10_000` to the caller, the rest swapped. no price limit beyond the tick math bounds. its fee is taken in beforeSwap, so a partial fill reverts, which cannot happen at this pool depth.
* `buybackExit()`: same with `xToBuyback` through the exit pool key, its own last block. slice is `20 * AVG_SCORE * unitPerPoint` (a quarter of an average statement), tip in exit token. the swap uses the exit pool's fixed price limit (below). it reverts `PriceBeyondLimit()` when the pool price is already beyond the limit. the swap amount is `(slice - tip) * (BPS - FEE_BPS) / BPS`, so that the swap plus the hook fee on what was spent (exactly 10 percent of the gross spent) never exceeds `slice - tip`. the spend is measured as the loss in the core's exit token balance around the swap, and the callback approves the hook for the fee room only for the duration of the swap. a partial fill spends proportionally less, and the unspent part of the slice goes back to `xToBuyback`.

the limit price. `SetExitPoolKey` carries `(PoolKey key, uint160 sqrtPriceLimitX96)`. the limit is stored once with the key, validated to lie strictly inside the tick math bounds, and is the worst price the core will ever accept in `buybackExit`. the exit pool has no owned liquidity (anyone can initialize it and add liquidity), so without a limit the counterparty chooses the price. with the limit, hostile liquidity beyond it is never reached and the swap stops at the limit, so the exposure per call is bounded by what the pool can absorb inside the band and the rest returns to `xToBuyback`. the owner must choose the limit on the side that fits the swap direction (below the pool price when the exit token is currency0, above it when it is currency1). this cannot be checked when the key is set because the pool is not initialized, so it is checked at swap time.

weakness, accepted for now: a static limit is either loose or can stall the exit buyback. a loose limit lets a counterparty take a larger band at a bad price. a tight limit is stalled by anyone who moves a thin or empty pool beyond it (the exact out swap of one wei is free in an empty pool), and the buyback then reverts `PriceBeyondLimit()` until the price returns. unspent input stays in `xToBuyback`, so a stall costs time and never funds. a sturdier design (a reference price that may drift) is an open decision.

### 5.9 exit token bid

`xRate` is stored in bps of score: start 6000, cap 9700, floor 3000, climb 100 per hour linear, drop 20 per credit. funded means `xPot >= AVG_SCORE * xRate * unitPerPoint / 10_000` with the stored unit. lazy checkpoint like the eth rate, including the affordability clamp. the clock starts when the module is set. `sellForExitToken(ids)` and a `minOut` overload. payment `score * xRate * unitPerPoint / 10_000`.

### 5.10 owner and timelock

`queue(Action action, bytes data)`, `execute(Action action, bytes data)`, `cancel(Action action, bytes data)`, all owner only, keyed by `keccak256(abi.encode(action, data))`, eta `now + TIMELOCK`. actions: `SetController(address)` (blocked after freeze), `SetExitModule(address)` (once), `SetExitPoolKey(PoolKey, uint160 sqrtPriceLimitX96)` (once, module must be set, hooks must equal the hook, fee must be 0, tick spacing must be 60, currencies must be coin and exitToken in sorted order, the limit must lie strictly between `TickMath.MIN_SQRT_PRICE` and `MAX_SQRT_PRICE`; sets `exitPoolId` and the stored limit), `AddTarget(address)`, `Freeze`. `removeTarget(address)` is immediate. launch targets Seaport 1.6 and CreditStrategy are set in the constructor. events for queue, execute, cancel and every state change in the system.

## 6. ControllerV1

holds only the core address. `wants` returns 0. `nextPage(lane)` returns ready when `pileSize(lane) >= 80`, with the first 80 ids from `pilePage` and format 0. `nextOverprint` not ready.

## 7. mocks (test/mocks)

`MockExitToken` (plain mintable erc20), `MockExitModule` (configurable `unitPerPoint`, mints `rating * unitPerPoint` on exit, with a switch to underpay), `HostileTarget` (takes eth, returns nothing), `MockCore` for hook and coin unit tests.

## 8. tests

fork at block 26127622 (`FORK_BLOCK`), rpc from `MAINNET_RPC_URL` in `.env` (archive needed, alternates in `.env.example`). foundry caches fork state on disk, so reruns are fast. all fork tests inherit one fixture `test/utils/Fixture.sol` that deploys the full system through the deploy library.

RATE_START is far below the CreditStrategy listing prices at the pin (see notes section 11), so listing tests must fund the pot and warp until the ceiling clears the listing.

a real opensea listing cannot be fetched from the sandbox. the Seaport test builds a genuine Seaport 1.6 order on the fork (a test key takes a credit from a real holder with prank, approves Seaport, signs with vm.sign) and fulfills it through `buyListing`.

## 9. deviations and decisions for the owner to confirm

1. second pool: handled by the hook, not by an allowlist entry. the fee is charged in exit token in that pool.
2. buy side fee is taken in eth through a beforeSwap delta, not in coin with a nested swap as tokenworks does. exact out swaps are allowed.
3. buybacks swap directly on the pool manager instead of the unverified z0r0z router. no min out, as upstream. the exit buyback is bound by a fixed price limit instead (5.8).
4. the hourly cap is a fixed window that reopens on the first buy after expiry.
5. the rate climb is clamped at the funded threshold between checkpoints.
6. added: `skim()`, `minOut` overloads on both sell doors, `composeExit()`, `buybackExit()` slice size, `cancel` on the timelock.
7. exit lane compose gas is reimbursed from the eth pot with a notional cap.
8. `addFees` and `addExitFees` cannot carry the reentrancy guard.
9. no launch snipe protection exists once the stepping fee is out of scope.
10. `unitPerPoint` is read once when the exit module is set and the unit is fixed from then on. the module cannot change what the core pays or requires.
11. the coin's transient allowance is a signed, netted counter bound to direction (section 3), not an unsigned additive allowance.
12. a swap whose fee was taken in beforeSwap reverts when it fills partly. the core's exit buyback takes its fee in afterSwap on the actual spend instead, by a hook pull from the core through a one swap approval (section 4).
13. the exit buyback has a fixed limit price chosen by the owner with the pool key. it is either loose or can stall the buyback (5.8). the owner picks the limit.
14. a fee on transfer or rebasing exit token is not supported. pot accounting, the core balance checks and the fee pull assume the amount sent is the amount received.
