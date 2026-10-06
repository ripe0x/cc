> **banner:** the reviewed FeeHook, Coin and Launcher were removed in the artcoins port. the file is kept for history. the live replacements are the artcoins token, skim hook and factory, see docs/ARCHITECTURE.md.

# hook review (independent, round 2)

scope: src/FeeHook.sol, src/Coin.sol, src/Launcher.sol, script/Deploy.s.sol, the buyback and unlock parts of src/Core.sol. spec 2, 3, 4, 8, 9 and docs/ARCHITECTURE.md. naming: only `exitModule` and `exitToken`.

proofs: `test/ReviewHook.t.sol`, run with `set -a; . ./.env; set +a; forge test --match-path test/ReviewHook.t.sol -vv`. every proof is a passing test that shows the bad outcome on the fork. no file in src/ or script/ was edited. fixes below are not validated by code.

## status after fixes

proof tests of fixed findings are now regression tests named `test_FIXED_*` in `test/ReviewHook.t.sol` and show that the attack fails. see docs/ARCHITECTURE.md sections 3, 4, 5 and 9 for the changed behavior.

| id | status | what |
|---|---|---|
| H1 | fixed | the coin keeps a signed, direction bound, netted counter. add then remove nets to zero and nothing is granted beyond the net coin of hooked actions |
| H2 | fixed | when the fee is taken in beforeSwap a partial fill reverts `PartialFill()`. the core exit buyback takes its fee on the actual spend instead |
| H3 | mitigated | mitigated by a fixed limit price, see ARCHITECTURE; a sturdier design is an open decision (same as R1) |
| H4 | fixed | an empty or thin exit pool makes `buybackExit` revert `NothingBought()`, and unspent input returns to `xToBuyback` |
| H5 | fixed | the exit key must have fee 0 and tick spacing 60, and the limit must lie inside the price bounds |
| H6 | fixed | the deploy script treats an existing hook at the predicted address as done after checking its constructor values, and still launches |
| H7 | accepted | accepted, cannot be fixed at coin or hook level |
| H8 | accepted | an empty exit pool price can still be moved for free by an exact out swap (exact in in the fee currency now reverts). liquidity providers initialize and mint in one multicall. it can stall `buybackExit` (ARCHITECTURE 5.8) |
| H9 | fixed | a buy then sell round trip nets to zero and leaves no allowance |
| H10 | open | unproven small items, unchanged |

## findings

| id | severity | title | status |
|---|---|---|---|
| H1 | high | exit pool liquidity add plus remove mints unlimited free transient coin allowance, so the coin moves wallet to wallet and trades in any pool with no fee | proven |
| H2 | medium | buy exact in and sell exact out charge the fee on the unfilled amount when the swap fills partially | proven |
| H3 | medium | `buybackExit` has no min out and the exit pool is open to any liquidity provider, so a hostile provider takes about 90 percent of a slice per call | proven |
| H4 | low | `buybackExit` into an empty or thin exit pool pays the fee for nothing and silently turns buyback budget into bid budget | proven |
| H5 | low | exit key shape is not validated and is set once, an unusable key locks the exit pool forever | proven |
| H6 | low | a create2 front run of the hook aborts the deploy script half way | proven |
| H7 | info | claims side market (accepted limitation) quantified, no hook or coin side mitigation exists | proven |
| H8 | info | an exit pool with no liquidity has a price anyone can set for free | proven |
| H9 | info | phase 1 round trip leaves allowance, costs 19 percent, not worth it | proven |
| H10 | info | small items: fee floor on dust, creator gas, launcher approvals | unproven |

## H1 high: free unlimited transient allowance from exit pool liquidity

where: `FeeHook._afterAddLiquidity`, `_afterRemoveLiquidity`, `_grant`; `Coin.increaseTransferAllowance`, `_afterTokenTransfer`.

what happens: after phase 2 starts anyone may add and remove liquidity in the exit pool. the hook adds `abs(coin leg)` to the transient allowance after the add and again after the remove. inside one unlock the add and the remove net to zero, so nothing is paid, nothing moves, and the hook has granted twice the coin leg. the leg is limited only by pool math (int128), so the grant is effectively unbounded and free (rounding dust of 1 to 2 wei per currency). the coin then lets any transfer to or from the pool manager through. the pool manager can move coin from any wallet to any address in one unlock: sync, `transferFrom(wallet, PM)`, settle, take to the recipient. that is a free arbitrary transfer, so every restriction in spec 4 is gone: coin goes to any address, any hookless v4 pool, and any external venue, and the 10 percent fee is skipped on all of it.

scenario with numbers (fork, `ReviewFreeGrantTest`):
1. `test_POC_freeAllowanceMakesCoinTransferable`: mallory buys 10 eth of coin (about 1.006e8 coin), plain `coin.transfer` to carol reverts. in one unlock she adds and removes 1e30 liquidity in the exit pool, then pushes her whole balance through the pool manager to carol. carol receives all of it, hook claims stay 0, no fee.
2. `test_POC_freeAllowanceSellsInHooklessPool`: mallory buys 20 eth of coin (fee 2 eth paid on the way in), then sells the whole bag in a hookless eth/coin pool using the same trick. hooked sale returns 16.2 eth. hookless sale returns 23.92 eth gross of the hook fee, the hook fee that was not paid is about 2.39 eth (10 percent of the gross), core pot and hook claims unchanged. depth of the side pool differs from the launch pool, so only the fee line is the like for like number.

this exists only after the owner sets the exit pool key (phase 2), because before that the launch pool refuses liquidity. tokenworks does not grant on remove at all, this grant is new.

fix: stop adding. let the hook set the allowance to the locker's real remaining need: `abs(poolManager.currencyDelta(sender, coin) + coin leg of this action)` (read through TransientStateLibrary, the delta of this action is not booked yet when the hook runs), written with a hook only `setTransferAllowance` on the coin instead of `increase`. add then remove then nets to 0. if that is too invasive, restrict exit pool liquidity to a fixed address and keep grants only in swaps, but swaps in a pool priced by its own provider are still cheap grants, so the delta based version is the real fix. not validated by code.

## H2 medium: fee on the unfilled amount

where: `FeeHook._beforeSwap` (specified fee currency path: buy exact in, sell exact out).

what happens: the fee is computed from `amountSpecified` before the pool knows how much will fill. when a price limit or thin liquidity stops the swap early the pool refunds the unfilled input, but the fee was already booked on the whole amount. the other two kinds take the fee in `afterSwap` from the real leg and are exact.

scenario (`test_POC_partialFillPaysFeeOnTheUnfilledAmount`): after a 1 eth buy so the price sits inside the position, mallory offers 10 eth exact in with a price limit 0.1 percent in sqrt price below spot. total paid 1.026 eth, of which fee 1.000 eth, which is 97 percent of what she paid instead of 10 percent. the same mechanics hit a sell exact out. any router that passes a real slippage limit, and the core buyback in a thin exit pool, pays it. if nothing fills, the whole 10 percent is paid for zero output.

fix: in `_afterSwap` for the specified fee kinds assert the specified leg of `delta` equals what the hook expected (absolute value: the offered amount minus the fee for exact in, the wanted amount plus the fee for exact out) and revert `PartialFill` otherwise. a revert is correct for the user, and the core buyback must then use the H3 price limit and handle the revert.

## H3 medium: buybackExit drained by hostile liquidity

where: `Core.buybackExit`, `Core.unlockCallback` (exact in, price limit at the tick math bound, no min out) against an exit pool anyone can initialize and fill (`FeeHook._beforeInitialize`, `_afterAddLiquidity`).

what happens: accepted deviation 3 justified no min out with "exposure bounded by slice and delay". in the launch pool that holds, the only liquidity is the dead owned position and the fee is 10 percent per side. the exit pool has neither property. its liquidity is whatever strangers put in, so the price the core trades at is chosen by the counterparty. exposure is the whole slice, not slice times impact, and the call repeats every 25 blocks.

scenario (`test_POC_buybackExitDrainedByHostileLiquidity`, mock exitToken, slice 0.866): the exit pool exists with nobody else in it. in one transaction mallory adds 2e12 coin wei of coin only liquidity priced about 1e6 exitToken per coin, calls the public `buybackExit()`, then removes. the core spent the slice, burned 7.8e-7 coin, and mallory pulled out 0.7755 exitToken, 89.5 percent of the slice. fee leakage to hook claims and the 0.5 percent tip are the rest. repeat per call until `xToBuyback` is empty. with honest liquidity present the same result needs a price push first, bounded by honest depth and the 10 percent fee on each side, so the empty or thin pool is the realistic window.

fix: bound what the core accepts per call. use a `sqrtPriceLimitX96` about 1 to 2 percent from the pre swap price, so thin or hostile depth cannot be consumed, and keep a stored reference price that may only drift a small percent per call (revert when spot is outside it). unspent input must go back to `xToBuyback` (see H4). not validated by code.

## H4 low: buyback into an empty or thin pool

where: `Core.buybackExit`, `Core.unlockCallback`.

what happens: `xToBuyback` is debited the full slice before the swap. with no liquidity the swap fills nothing, but the hook still takes 10 percent of the offered amount (H2 mechanics). the core pays that fee, burns no coin, and the rest of the slice stays in the core unbooked. `skim()` is permissionless and moves it into `xPot`, so buyback budget turns into bid budget.

scenario (`test_POC_buybackExitIntoEmptyPoolPaysFeeForNothing`, slice 0.866): core paid 0.0905 exitToken (fee 0.0862 plus tip 0.0043), burned 0 coin, 0.7755 left unbooked, `skim()` books it into `xPot`. the swap also pushes the pool price to the extreme bound.

fix: revert with `NothingToBuy` when pool liquidity is zero, and add `amountIn minus actual spend` back to `xToBuyback` (the same for the eth path, which is deep so less urgent).

## H5 low: exit key not validated

where: `Core._setExitPoolKey`.

what happens: only hooks, sort order and the pair are checked. a tickSpacing of 0 (or above 32767, or a fee above 1e6) passes, sets `exitPoolId` once, and the pool manager can never initialize it. the once only rule then blocks the repair. a static lp fee or the dynamic flag is accepted and harmless to the fee math (the hook never sets a dynamic fee, so it stays 0) but costs the core on buybacks.

scenario: `test_POC_unusableExitKeyIsAcceptedAndLocked`. a key with tickSpacing 0 is accepted, `PM.initialize` reverts, queuing a good key reverts `AlreadySet`.

fix: require `fee == 0` and `tickSpacing == 60` (the launch shape) in `_setExitPoolKey`. owner and timelock make this a mistake risk, not an attack.

## H6 low: create2 front run aborts the deploy

where: `script/Deploy.s.sol` `create2Hook`, `deploySystem`.

what happens: the hook initcode and salt are fully determined by public values. anyone who watches the nonce can deploy the identical hook first. the same hook lands at the same address, so nothing is stolen, but `create2Hook` reverts `CreateFailed("hook")`. launcher, core, coin and controller are already on chain, the supply is parked in the launcher, and the script has no resume. the deployer can still call `launch(coin, hook)` by hand.

scenario: `test_POC_create2FrontRunAbortsTheDeploy`.

fix: treat an existing contract at the predicted hook address with the expected codehash as success, and always run the launch step. optionally deploy the hook first.

## H7 info: claims side market, quantified

known and accepted. the end to end shape, with numbers (`ReviewSideMarketTest`):

| step | what | protocol fee |
|---|---|---|
| entry | buy coin in the launch pool, take the output as pool manager claims (`mint` instead of `take`) | 1.9 eth to the core plus 0.1 eth to the creator on a 20 eth buy, once |
| move | erc6909 `transfer` of the claims between wallets | none |
| trade | claims pay and receive in a hookless eth/coin pool (burn to pay, mint to receive). 5 cycles in the test moved 142 eth of volume | none |
| exit to eth | sell claims into the hookless pool, take eth | none |
| exit to erc20 | `take` of coin needs allowance, which only a hooked swap with a coin leg at least as big grants. plain take reverts. on a 2 eth bag the grant swap was 5 eth notional, 0.475 eth to the core pot | one more 10 percent on the grant swap |

so the fee is paid once per unit entering the side market, and the side market itself never pays it again. a coin side or hook side mitigation does not exist: the claims never touch erc20 transfer, the hook is not in the hookless pool, and the coin cannot see erc6909 balances. the only lever is making entry and erc20 exit cost something, which they already do. H1 removes even that, which is why H1 ranks above this.

## H8 info: price of an empty exit pool is free to move

`test_POC_emptyExitPoolPriceIsFreeToMove`: a one wei swap with a price limit moves the empty exit pool to any chosen price, fee 0, no cost. first liquidity is exposed to whoever moves the price last, and the core buyback can jump the price to the bound (H4). liquidity providers should initialize and mint in one position manager multicall and set a price bound. no code change for the hook.

## H9 info: phase 1 round trip

`test_POC_roundTripLeavesAllowanceButCostsBothFees`: buy 10 eth then sell the exact coin in one unlock. net coin 0, transient allowance left equals twice the coin leg, fees paid 1.9 eth (19 percent). the leftover could dodge at most 20 percent of the same notional in a hookless pool, so it breaks even at best. a swap settled with claims leaves the coin leg as allowance (see the exit to erc20 row in H7), which costs the same 10 percent as a normal buy. phase 1 has no cheap source of allowance.

## H10 info, unproven

1. fee floor: fees round down, so a swap of 9 units or less pays 0. at the launch price one wei of eth buys about 4e7 coin wei, so a loop of dust swaps saves under one wei per swap against about 100k gas. the same holds for exitToken unless one base unit is worth more than the gas of a swap.
2. creator payout: `forceSafeTransferETH` with a 30k stipend, falling back to a force send contract, so a creator that reverts or burns gas cannot brick swaps, but a hostile creator adds about 30k to 65k gas to every swap that pays it. the creator is fixed at deploy.
3. launcher residuals: after launch it holds no coin, but it keeps a max erc20 approval to permit2 and a max permit2 allowance to the position manager. nothing can reach the launcher with coin, since wallet to launcher transfers are blocked, so no power is left.
4. exit token `claimCreator` to a creator that cannot receive: it reverts for that call only, `creatorExitOwed` stays, the core share is unaffected.

## attacks tried that held

1. fee math in all four swap kinds, both currency orderings, both pools: signs and floor rounding match the notional rule within one unit (outside the partial fill case H2). the specified and unspecified fee paths agree with the pool manager delta accounting.
2. who bears the fee: always the trader, never the lp, in both pools.
3. hook `unlockCallback`: only the pool manager may call it, and only the hook starts an unlock that targets it, so no third party can make the pool manager call it with crafted data. same for `Core.unlockCallback`, which only runs inside the core's own `buyback` and `buybackExit`. re-entering `unlock` from a creator callback or token callback fails with AlreadyUnlocked.
4. creator claim accounting: `claimCreator` zeroes the owed amount before the unlock, donated claims only grow the core share, the creator share cannot be taken because only the hook can burn its claims, exitToken is set once so it cannot change, floor rounding favors the core by under one unit per swap.
5. `sendExitFeesToCore` and `Core.addExitFees` balance check: after the take the balance always covers pots plus amount, `Busy` only fires inside core calls that hold `measuring`, so it cannot be used against ordinary swaps.
6. launch pool: init only inside `launch`; a pool key with a hook address that has no code cannot be initialized before the hook is deployed (`InvalidHookResponse`); add, remove and zero delta pokes revert; the position belongs to the dead address, lp fee is 0 so nothing accrues, eth donations land in the dead position; coin donations need a grant. no way found to remove or collect.
7. launch front running: the hook can only be deployed with the mined initcode, a same salt front run gives the identical contract (H6 is the only effect), eth dust sent to predicted addresses is harmless, `launch` is deployer only and one shot.
8. coin: no mint or burn entry, transfers of zero and self transfers between wallets revert, only the hook can grant, permit2 shortcut is off, wallet to pool manager transfers need a grant in the same transaction. the grant is consumed before the allowlist check. (the grant itself is H1.)
9. creator payout: reverting or gas burning creator cannot stop swaps, 30k stipend cannot reenter the pool manager or core in a useful way.
10. core re-entry: the fee callback `addFees` during a guarded `buyback` books pots consistently (pots never exceed balance), and the tip payout runs after the unlock.
11. sandwiching the eth buyback in the launch pool: 10 percent fee on each side means the attacker needs more than about 20 percent price impact from a 1 eth slice. the opening depth gives roughly 8 percent (virtual eth reserve near 25 eth) and the curve deepens as the price falls, so it never pays. this is an estimate from the position math, not a test.
12. dynamic fee flag in the exit key: the hook never sets an lp fee, so it stays 0.
