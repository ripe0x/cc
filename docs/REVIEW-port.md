# independent review: the artcoins port of Core

## status

| finding | status | what was done |
|---|---|---|
| P-1 | accepted | third party eth from an open pool is a donation. listed in ARCHITECTURE section 10, item 18 |
| P-2 | fixed | every injection into `xToBuyback` re anchors the start price at `max(price now, start / 4)` and restarts the clock. proof converted to `test_FIXED_staleClockNoLongerPricesInjectedFunds`, invariant handler model updated |
| P-3 | fixed | `_setExitModule` reverts `BadModule` when the opening price is below 1e12. proofs converted to `test_FIXED_hugeUnitIsRejectedAtSetTime` and `test_FIXED_largeUnitIsRejectedAtSetTime` |
| P-4 | documented | no contract change. the deploy script refuses to run if the predicted coin already has code, and the launch runbook is in the script header, ARCHITECTURE section 2 and README |
| P-5 | fixed | permit2, the position manager and the universal router are forbidden targets. `test_FIXED_permit2AndRoutersAreForbiddenTargets` |
| P-6 | accepted | cost basis understatement from a hook push inside `buyListing`. ARCHITECTURE section 10, item 19 |
| P-7 | accepted | venue tax bypass, an artcoins hook issue. ARCHITECTURE section 10, item 20 |

the findings below are written as found. the `test_POC_*` names for P-2 and P-3 refer to proofs that have since been converted to `test_FIXED_*` regressions.

scope: `src/Core.sol` and `src/ControllerV1.sol` as they run on the live artcoins stack, `script/Deploy.s.sol`, and the environment findings in `artcoins-audit/1-hooks.md` and `2-token-factory-locker.md`. law: docs/ARCHITECTURE.md (its section 10 is not re reported). rate math, piles, doors, compose, statement auction and timelock were reviewed in REVIEW-core.md and are only re touched where the port exposes them. all proofs are in `test/ReviewPort.t.sol` on the pinned fork. `test_POC_*` prove a finding, `test_held_*` are attacks that failed.

result: no critical, high or medium finding. the money path (receive, books, buyback, burn) held under every attack tried. what is left is four lows and three infos, mostly around the exit auction clock and the launch process.

## findings

| id | severity | title | status |
|---|---|---|---|
| P-1 | info | eth pushed by the hook from any pool that names the core as bounty recipient is booked as fee income | proven |
| P-2 | low | exit auction clock restarts only at an exactly empty pot, so a leftover remainder prices later injected funds at the stale decayed price | proven |
| P-3 | low | opening exit price is integer math with no precision floor: zero above unit 1.15e37, zero within days above 1e36 | proven |
| P-4 | low | the predicted coin can be launched first with someone else's pool config once the factory is open, leaving the already deployed core bound to a pool that never pays it | proven |
| P-5 | info | the forbidden target list misses permit2, the position manager and the universal router | unproven |
| P-6 | info | `buyListing` books the hook push that lands inside the call as a cost reduction, so the cost basis and statement floor are understated by it | unproven |
| P-7 | info | the venue tax bypass (artcoins H-1 / T-2) caps this system's fee income at primary issuance | unproven (cites their proofs) |

no finding is at medium or above, so none is a blocker. P-2 and P-3 are the two worth a code change before phase 2 goes live. P-4 is process.

## P-1 info: third party eth is booked as fee income

where: `Core.receive` (L281). it books any eth whose sender is the hook, and `initializePoolOpen` lets anyone create more pools of the coin on the same hook with any `bountyRecipient`.

what happens: the attacker opens a second pool of the coin (tick spacing 60, baseline skim 50 percent, bounty leg 99.99 percent, recipient = the core), seeds it with coin, and swaps. the hook pushes the bounty to the core with `msg.sender == hook`, so the core checkpoints the rate, adds to `ethPot`, re syncs `funded` and emits `FeesAdded`. `lastFillTime`, the hourly window and the books are untouched, and `ethPot + ethToBuyback <= balance` holds.

numbers (proof `test_POC_openPoolSpoofsFeeIncome`): the attacker paid 0.001 eth into the open pool, the pot grew by 0.00049995 eth. it is a pure donation by the attacker. booking it cannot hurt: the rate climbs only while funded, is clamped by the pot, and every spend of the pot is still limited by the 20 percent hourly cap, so a donor can only hand the pot extra eth that the same rules then pay out to anyone at the ceiling.

what it does mean: `FeesAdded` is not proof of organic volume on the canonical pool, and an open pool with the core as `referralPayout` pushes eth through `notify`, which stays unbooked until `skim`.

fix: none needed. do not read `FeesAdded` as an organic volume signal.

## P-2 low: a leftover remainder keeps a stale clock for injected funds

where: `Core.exitStatement` L716 (`if (toBuyback != 0 && xToBuyback == 0) xStartTime = now`) with `Core.exitAuctionPrice` L824. `exitStatement` is permissionless once a statement has matured.

what happens: the auction clock restarts only when `xToBuyback` is exactly zero. while any remainder is unsold the old start time and start price stay, so funds injected later are priced from the already decayed curve. anyone can then call `exitStatement` on a matured statement and take the full slice at that stale price. with an empty pot the same injection would restart the clock at the stored start price.

numbers (proof `test_POC_staleClockPricesInjectedFunds`, unit 1e10): first exit leaves 1.504 slices, a taker fills one slice after 200 hours and 0.504 slice stays unsold. after 400 more hours a second statement is exited.

| arm | pot before injection | coin burned for the full 0.866e18 slice |
|---|---|---|
| A, remainder unsold | 0.504 slice | 2,134,389 wei of coin |
| B, remainder sold first, pot reaches zero, clock restarts | 0 | 6.25e25 coin (6.25 percent of supply) |

honest framing: arm B also decays and reaches dust after enough half lives, and a market with any buyer fills the remainder long before the price is dust, so the stale clock only matters when the exit token is close to unwanted for days. the flaw is that injected funds skip their own decay start, and that anyone can time the injection.

fix: on every injection with `toBuyback != 0`, re anchor the curve instead of testing for an empty pot: `xStartPrice = max(exitAuctionPrice(), xStartPrice / 4).max(1); xStartTime = now;` before adding. a remainder then never carries a decayed clock into new funds, and the quarter floor keeps the restart rule of the fills.

## P-3 low: opening price has no precision floor

where: `Core._setExitModule` L919, `xStartPrice = SUPPLY * 1e18 / (20 * AVG_SCORE * unit)`, with `unit` allowed up to uint128.

what happens: the opening price is a plain integer. it is 1.15e37 for unit 1, 1.15e27 at the test unit 1e10, and falls as 1 / unit. above unit 1.15e37 it is zero, so the first slice costs zero coin the moment it exists and any stranger takes it. around unit 1e36 it is 11, and a price of 11 halves to zero in four half lives, so every slice is free after 24 hours instead of after roughly 20 days at the test unit. the module and unit are owner set through the 7 day timelock and read once, so this is a parameter trap, not an outsider attack.

numbers (proofs `test_POC_hugeUnitMakesTheOpeningPriceZero`, `test_POC_largeUnitDecaysToZeroInDays`): unit 2e37 gives opening price 0, quote `coinIn` 0, and an account with no coin calls `buybackExit(0)` and receives the full slice of 1.732e45 units. unit 1e36 gives opening price 11 and a zero price after 4 half lives.

fix: in `_setExitModule` revert `BadModule` when the computed `xStartPrice < 1e12`, which keeps at least 40 half lives (10 days) before the integer reaches zero and still admits every unit up to about 1e25. do not just raise the price scale: at 1e36 the `p * factor` product can overflow for a dust slice at a very high restart price, which would brick the auction.

## P-4 low: launch hijack of the predicted coin (artcoins T-1, applied to our deploy)

where: `script/Deploy.s.sol` `deploySystem`: the Core is deployed against a predicted coin address, the launch comes after, and the coin address ignores the pool config and the caller (artcoins `ArtCoinsDeployer`, salt = `keccak256(tokenAdmin, userSalt)`).

what happens: while the factory is deprecated only the owner and marked admins can launch, so a stranger cannot copy the launch today. the moment the owner calls `setDeprecated(false)`, or if the deployer key is used from a public mempool with the factory open, a watcher copies `tokenConfig` and `taxConfig` and launches first with their own bounty recipient. the real launch then reverts on the CREATE2 collision. the Core (immutable `COIN`) is already deployed against that address and cannot be rebound.

numbers (proof `test_POC_launchHijackLeavesTheCoreDeadAgainstTheCoin`): after the attacker launch a 1 eth buy pushes 0.095000000000000001 eth to the attacker sink and 0 to the Core. the real launch reverts. no funds of ours are at risk, because a Core holds nothing before its first fee. the cost is a burned Core and Controller deployment, the brand of the coin sitting on a pool we do not own, and a rerun with a new salt.

fix: send the three transactions through a private relay, or better make the deploy atomic: a small deployer contract that creates the Controller and the Core and calls the factory in one transaction, so a front run reverts the whole thing with no orphan. keep `deprecated` true until the launch is mined and have the owner revoke `setAdmin(deployer, false)` afterwards, because an admin can also `setHook`, `setLocker`, `setMevModule` and `claimTeamFees`.

## P-5 info: forbidden targets miss permit2, the position manager and the universal router

where: `Core._forbidden` L589, checked at `AddTarget` and again at call time.

what happens: every artcoins contract that could matter is covered (factory, locker, escrow, hook, pool manager, coin). the default targets are Seaport 1.6 and CreditStrategy and neither can reach the core's coin or exit token, because the core approves nothing except credits to Statements and cannot sign (no `isValidSignature`). but the core now holds coin for a moment during `buyback` and holds the exit token in `xPot` and `xToBuyback`, and solady coin gives every holder an infinite allowance to Permit2. if the owner ever adds Permit2 or the position manager as a target, the post call checks (balance plus one credit and `ownerOf`) are the only guard and a target call that also moves tokens would be limited only by what that one call can do. unproven: no code path found, only a missing guard on a timelocked owner action.

fix: add `Mainnet.PERMIT2`, `Mainnet.POSITION_MANAGER` and `Mainnet.UNIVERSAL_ROUTER` to `_forbidden`. all three constants already exist in `Interfaces.sol`.

## P-6 info: the hook push inside `buyListing` lowers the cost basis

where: `Core.buyListing` L513 to L545, `receive` L281.

what happens: while the target call runs `receive()` books nothing, so eth the hook pushes in that window lowers the measured cost one for one (`cost = ethBefore - ethAfter`). books stay exact (existing `test_receiveMidBuyListing` and my `test_held_swapInsidePayoutCallbacks`): pot and balance fall by the same `cost + tip`. what is understated is the stored cost basis of that credit, by the hook push `F`, which feeds the statement floor (1.2 times basis). only a seller who runs a contract offerer on Seaport can arrange a swap inside the call, and the swap costs them 10 points of its volume `V` while `F` is 9.5 points of it. to shave `1.2 F` off a later statement price they pay `1.05 F` in skim plus the price impact of a volume of `10.5 F`, so the margin is at most 0.15 `F` and is gone once the impact of that volume passes 1.4 percent of it. the tip rule `min(10 percent of savings, 2 percent of cost)` gains at most `0.1 F` against the same outlay. no profit found at any pool depth the fixture reaches; unproven because the margin only exists in a very deep pool.

fix: track the hook inflow in a transient counter inside `receive` while measuring, then after the call use `cost = ethBefore + inflow - ethAfter`, add `inflow` to `ethPot` before `_spend`. the basis is then the gross price and the push is booked as the income it is.

## P-7 info: what the venue tax bypass means for this system's fee income

source: artcoins H-1 and T-2 (proofs in their `H1Hooks.t.sol` and `Poc_T2.t.sol`, including against the live 111 pool). any contract can add and remove liquidity on the canonical pool inside one unlock, the hook attests the removed coin as exemption budget, and any later venue outflow in the same transaction (a v2 or v3 pair of the 44 listed venues, any hookless v4 side pool) is then untaxed. cost: about 1.3 million gas per transaction and no capital.

our income is the 9.5 points of skim on volume through the canonical pool. the 15 percent tax goes to 0xdEaD and never reaches the core, so the bypass does not take eth from us directly. it removes the only deterrent against routing around the skim. without the bypass a buy on a side venue costs 15 points against 10 on the canonical pool, so the canonical pool is cheaper. with the bypass a side venue costs 0 points against 10, so every aggregator and every trader with a side pool route wins by 10 points, and sells into any side pool were already free. anyone can use it, a router can package it (the universal router already carries the v4 position actions, so it may need no custom contract at all), and the break even is a few hundredths of an eth of volume. the limit that remains is primary issuance: the whole supply starts in the locked canonical position, so every coin pays the 10 point skim on its first purchase from the pool. after that, trading between holders, side pools and wallets pays no skim at all, and arbitrage only pays skim on the canonical leg once the side price is more than 10 percent away. expect the long run fee income to be about 9.5 percent of net new money that enters through the canonical pool, not 9.5 percent of all volume. nothing in the core can change this. the fix is in artcoins (drop the removal attestation or net it against same transaction adds). open pools with zero skim do not add anything beyond this, because their coin outflow is taxed like any side pool and they earn no budget.

## the seven questions, answered

1. receive. it cannot revert and cannot be made expensive. the checkpoint loop runs one iteration per day of gap while `rate < cap` and the rate grows at least 27 percent a day, so it is tens of iterations at most for any pot below the eth supply (the existing 20 year test at rate 1 and pot 1e8 eth stays under 400k gas). `powWad` exponents are at most 24e18 per iteration, `r * factor` cannot overflow below a pot of 1e30 wei, pot counters are uint256. the measuring flag is transient and is set only around two external calls. the `streamForward` probe hits a contract with no fallback, which reverts with empty data and is caught by the hook, so artcoins H-2 does not apply. `receive` has no external calls and no guard on purpose, and `test_held_swapInsidePayoutCallbacks` fires a real swap from the eth callback of a sell payout, a compose reimbursement and a statement refund: each time the hook push is booked in full and `balance == ethPot + ethToBuyback`. nobody can lengthen a gap, and spoofed inflows from an open pool are a donation (P-1).
2. accounting. `ethPot + ethToBuyback <= balance` holds on every path: each outflow is paired with a pot decrement, inflow outside a measurement is booked in full, and inside one the measured cost is the balance delta so pot and balance move together. nothing is left unbooked by a swap inside the target call, it is netted into the cost. the swap inside the target call cannot dodge the ceiling (the ceiling and the hourly cap pre check run on gross `value`), and the tip gain from it is at most 0.1 of the push against an outlay of 1.05 of it. the only residue is the stored cost basis (P-6).
3. buyback. `unlockCallback` is reachable only from the pool manager and the manager calls only the address that called `unlock`, so the only caller is `buyback` and `data` is its own budget. the coin goes to the core (exempt) and the whole `bought` is burned: supply falls by exactly what the pool gave up. the price limit is the minimum, so a partial fill needs the whole book exhausted, which cannot happen (H-3 does not bite). the tip is scaled on spent and unspent input returns to the pot. the hook push comes back inside the guarded call and is booked. sandwich: front running with X, then the 1 eth slice, then selling back always loses (table below). a just in time position straddling the price made the core burn 2 percent more coin than baseline (12.088e6 against 11.851e6 coin), and the position lost value at the final price, because the lp fee is zero and the skim is not shared with lps. a 100 eth front run can cut the burn of one slice by 89 percent, but costs the attacker 18.3 eth, nearly all of it paid to the core pot and the creator, so it is a loss making grief.

| front run X | attacker net eth | coin burned for the core |
|---|---|---|
| none | 0 | 11.85 million |
| 5 eth | -0.804 | 9.74 million |
| 20 eth | -3.394 | 5.94 million |
| 100 eth | -18.278 | 1.26 million |

4. exit auction. the largest value ever in play is about 2e45 (a restart is at most twice the clearing price and the clearing price is bounded by the coin a taker can burn), so `p * factor` stays below 2e63. the price floors and `coinIn` ceils, so a fill with a non zero price and a non zero slice always burns at least 1 wei: no free fill from rounding. the restart `max(2 * clearing, previous / 4).max(1)` can never lower the next start below a quarter, so a cheap fill cannot push the price down for the next taker. the slice is the whole of `xToBuyback` up to a full slice, so nobody chooses a dust slice, and a dust fill of a leftover can only lift the next start toward a quarter of the previous one. `burnFrom` burns only `msg.sender`'s coin and needs the taker's allowance to the core, the permit2 allowance quirk is for permit2 as spender and does not touch this. a contract taker or a hostile exit token reenters into the guard. a front runner takes the same slice and leaves the loser with `NothingToBuy` or `Slippage`. open points: P-2 (injection mid auction) and P-3 (opening price precision).
5. targets: P-5.
6. deploy. prediction and read back hold. the launch is atomic with the prediction check inside one script run, so a mismatch aborts before anything is broadcast; if the chain state moves between simulation and mining the launch can revert after the Core exists, which orphans a Core (P-4). handover order is right (`lockPoolExtension` as admin, then `updateAdmin(owner)`, then read back). raw `PoolManager.initialize` on our key is refused by the hook (`beforeInitialize` always reverts) and `initializePoolOpen` refuses a coin with no code, so nobody can pre create our pool. tax config: the Core is exempt and `verifyLaunch` checks it. 0xdEaD is neither a venue (venues are CREATE2 pair addresses and the pool manager) nor exempt, the tax moves coin to it with a direct `_transfer` so there is no recursion, and tax coin stays in `totalSupply` while the Core's own `burn` reduces it. `referralPayout` is the Core and `notify` is a payable no op that fits the hook's 35,000 gas cap, and with the cap at 0 it is never called. small gap: `verifyLaunch` drops the last two fields of `skimConfig`, so it does not check `referralPayout` or the quote token.
7. venue tax bypass: P-7.

## attacks tried that held

* receive: revert by arithmetic, by gas after 20 year gaps, by pot overflow, by the measuring flag, by the `streamForward` probe, by reentry from a payout callback.
* spoofed fee income from an open pool on the same hook (donation only, P-1), and open pool referral eth through `notify` (stays unbooked, booked by `skim`).
* pots above balance by any ordering of hook push, measurement, refund and payout.
* tip farming and hourly cap dodging by a swap inside a `buyListing` target call.
* `unlockCallback` called directly or with crafted data.
* a taxed or short take on the buyback (the Core is exempt, burn equals take).
* sandwich of the 1 eth slice at 5, 20 and 100 eth, and a just in time position around the price.
* hourly cap, rate climb and funded flag manipulation through donations.
* exit auction: overflow and zero price in the shift and `powWad` path, free fill by rounding, dust slice and 1 wei slice, clock reset or start price push by a cheap fill, a taker that is a contract, reentry through the exit token, front running a fill.
* pre creating our pool through `PoolManager.initialize` or `initializePoolOpen` before the coin exists.
* any artcoins contract as a `buyListing` target: factory, locker, escrow, hook, manager and coin are forbidden, and the default targets cannot reach the core's coin or exit token.
