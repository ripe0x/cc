# architecture

this file describes the system as it is on branch `artcoin`. SPEC.md is the original handoff spec and where the two differ this file wins. the last section lists what differs or is accepted, for the owner to confirm.

naming rule: only `exitModule` and `exitToken`. never name or describe them anywhere.

## 1. what we own and what is live

we own two contracts. everything else is live on mainnet and is used as deployed.

| contract | role |
|---|---|
| `Core` | custody and every rule: pots, rate, cap, piles, doors, compose, statement auction, exit, overprint, both buybacks, timelock. also the bounty recipient of the skim hook |
| `ControllerV1` | first policy module. holds only the core address. `nextPage(lane)` is ready when the pile holds 80 credits and returns the first 80 ids with format 0. `wants` returns 0, `nextOverprint` is never ready |

the artcoins stack is a deploy input. the Core takes it as the constructor argument `Stack { poolManager, hook, tickSpacing, poolFee, factory, locker, escrow }` and stores it as immutables (`MANAGER`, `HOOK`, `TICK_SPACING`, `POOL_FEE`, `FACTORY`, `LOCKER`, `ESCROW`). nothing in `src/Core.sol` names an artcoins address. the table below is the live stack at block 26127622 (verified in docs/reference/artcoins-notes.md), which is the DEFAULT config only: `script/config/mainnet.json`, `Mainnet.defaultStack()` and the tests. a new artcoins version changes the stack block of the config and nothing else in code (docs/DEPLOY.md section 5). the hook is the only address whose eth `receive()` books as fees. the factory, locker and escrow feed the pool key and the forbidden target list.

| piece | address |
|---|---|
| ArtCoinsFactory | 0x49596c375c139E79bb937bcf826068a8F78D4e0e |
| factory owner | 0xCB43078C32423F5348Cab5885911C3B5faE217F9 |
| skim hook (ArtCoinsHookSkimFee) | 0x636c050296B5Cc528D8785169Bf8923716FCa9cc |
| lp locker | 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab |
| fee escrow | 0x7559689765aE86cBB38e68CD1294830CccB125F2 |
| anti sniper module (ArtCoinsMevLinearSkim) | 0xb038D597365FfD108D63C265Bb0621444a1D8B83 |
| uniswap v4 pool manager | 0x000000000004444c5dc75cB358380D2e3dE08A90 |
| universal router | 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af |

the coin is an `ArtCoinsToken` launched through the factory. it is not our code. the other live pieces the core touches are Credits 0x97630aA70AB14ed9883B41dAfccBc11349723043, Statements 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b, CreditScore 0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7, CreditStrategy 0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6 and Seaport 1.6 0x0000000000000068F116a894984e2DB1123eB395. constants live in `src/interfaces/Interfaces.sol`. Credits, Statements, CreditScore, CreditStrategy, Seaport, Permit2, the position manager and the universal router stay constants.

toolchain: solc 0.8.30, cancun, via_ir, optimizer 200, solady, v4 core and periphery pinned in `lib/`. every runtime contract must stay under 24,576 bytes (`forge build --sizes`).

## 2. launch config

one call to `ArtCoinsFactory.deployTokenWithProtocolBpsAndTax(cfg, 0, tax)` with `msg.value` equal to the live `deployFee()` (0.069 eth at the pin). script and tests use the same builder (`script/Builder.sol`, `script/Deploy.s.sol` `SystemDeployer`), driven by one `LaunchConfig` struct (`script/LaunchConfig.sol`) that the scripts load from `script/config/mainnet.json` and the tests fill in memory.

| field | value |
|---|---|
| supply | `launch.supply` 1,000,000,000e18 (equal to the Core `SUPPLY` constant), no extensions, all of it in the locker |
| pool | native eth against the coin, hook = skim hook, dynamic fee flag 0x800000, tick spacing 200 |
| start price | `tickIfToken0IsArtCoins = -175000`, about 40M coin per eth |
| position | one position from -175000 to 887200 (highest multiple of 200), 10,000 bps |
| skim | baseline 10 points of volume (`baselineSkimBps` 10_000 of 100_000), `bountyBps` 9500, so 9.5 points to the core and 0.5 to the creator |
| skim recipients | `bountyRecipient` = Core, `protocolRecipient` = creator, `referralPayout` = Core, quote token eth |
| referral and lp fee | `maxReferralBpsOfVolume` 0, `lpFee` 0 |
| anti sniper | linear skim module with (90_000, 10_000, 1800): fee decays from 90 points to 10 over 30 minutes, the extra lands in the core's pot |
| locker | one reward slot: recipient creator, admin 0xdEaD, 10,000 bps |
| tax | enabled, `taxBps` 1500, `taxBpsMax` 2000, burn 0xdEaD, canonical pool = this pool, exempt = the Core, 44 venues (three v2 factories, uniswap v3 and pancake v3 tiers, each against WETH, USDC, USDT, DAI), the same list as the live 111 coin |
| token admin | the deployer during launch. the script then calls `lockPoolExtension` and `updateAdmin(owner)` |

deploy order, no circularity:

| step | action |
|---|---|
| 0 | `_requireConfig`: owner, creator, name, symbol and salt must be set and `rateStart` and the four economic dials in bounds, then the whole preflight runs |
| 1 | predict the Core and ControllerV1 addresses from the deployer nonce |
| 2 | build the tax config with the Core in `exempt` and predict the coin with CREATE2 (factory as deployer, salt `keccak256(abi.encode(tokenAdmin, userSalt))`, initcode includes the tax config) |
| 3 | deploy ControllerV1 with the predicted Core |
| 4 | deploy Core at the predicted address with the predicted coin, the stack, `rateStart` and the four economic dials (`econ`) |
| 5 | launch through the factory and assert the returned coin equals the prediction |
| 6 | `lockPoolExtension`, then `updateAdmin(owner)`, then the postflight read back of every configured value, which reverts on any mismatch |

the factory is `deprecated` at the pin, so only its owner or an address the owner marks admin can launch. the owner calls `setAdmin(deployer, true)` first. that is the only artcoins state the tests force, through a prank of the real owner.

launch runbook. the exact commands in order are in docs/DEPLOY.md. the predicted coin address ignores the pool config, so a copy of the launch made first by anyone else would leave the already deployed Core bound to a pool that never pays it. so: keep the factory deprecated until the launch is mined, the factory owner enables only the deployer, the broadcast goes through a private relay, the script reverts on any prediction mismatch or if code already exists at the predicted coin address, and the factory owner revokes the deployer right after the postflight, since an admin can also set hooks, lockers and mev modules and claim team fees.

config, checks and rehearsal.

| piece | what it is |
|---|---|
| `script/config/mainnet.json` | everything a launch needs: the stack (live artcoins as default), mev module, factory owner, owner (core owner and final token admin), creator, name, symbol, salt, `rateStart`, the four economic dials (`econ`) and the launch parameters. `script/config/mainnet.recommended.json` is the same file with four values changed (the simulation's `gate20constants` economics), the operator picks one. owner, creator, name, symbol and salt are placeholders (zero address, empty strings) that must be filled. `Deploy` refuses to run while any is unset. read with `vm.parseJson`, `LAUNCH_CONFIG` names another file, `PRIVATE_KEY` is the only env override and is a secret |
| `script/Preflight.s.sol` | read only. checks chain id 1, code at every address, the hook, locker and mev module enabled on the factory, who may launch, deploy fee against the deployer balance, the predicted addresses empty, Credits, Statements and CreditScore sanity, placeholders, `rateStart` and the four economic dials (bounds, a printed sign off line each). prints a table, reverts with the failed names |
| `script/Postflight.s.sol` | read only. reads a deployed core back and compares every immutable, the controller, allowed targets, coin supply and its place in the pool, pool key and id, skim config, tax config, exempt core, token admin, extension lock, locker reward slot and `ethRate` with the config. the four economic dials are read back from the Core views. prints a table and the constructor args, reverts on a mismatch |
| `test/Rehearsal.t.sol` | forks the latest block, runs preflight, the real deploy as the factory owner enables the deployer, postflight and a smoke (buy and sell through the universal router, the fee lands in the pot, a real credit sold into the bid). skipped unless `REHEARSAL` is set |
| `test/Config.t.sol` | the json equals the default config, the placeholder guard, preflight and postflight pass and fail where they should |

## 3. fee intake

there is no hook of ours. the skim hook of the configured stack takes its skim in eth on every swap and pushes the bounty to `Core.receive()` with all gas.

* from the skim hook while no measurement is in flight: checkpoint the rate, add to `ethPot`, resync the funded flag, emit `FeesAdded`.
* anything else (donations, refunds from a purchase, a measurement in flight): accept and book nothing. `skim()` books it later. during a `buyListing` or exit measurement the unbooked eth lowers the measured cost, which keeps pot and balance consistent.
* `receive()` never reverts and stays cheap, because a revert would brick every swap in the pool. it has no reentrancy guard for the same reason (the hook calls it during a guarded buyback). a test proves it cannot revert unfunded, funded, years without a checkpoint, mid buyback, mid buyListing and mid exit.
* there is no fallback function. the hook calls `streamForward()` on the recipient once its balance reaches 0.01 eth and relies on that call reverting and being caught. a fork test keeps swaps working with a large core balance.
* `notify(address)` is a payable no op. it is the referral payout target. with the referral cap at 0 the hook never calls it.
* `skim()` is permissionless and guarded. it moves `balance - ethPot - ethToBuyback` into `ethPot` and the same for the exit token into `xPot`.
* `onERC721Received` accepts only Statements and Credits.

## 4. rate, cap, piles

accounting: `ethPot` (buying), `ethToBuyback`, `xPot` (exit token bid), `xToBuyback`. invariant: pots never exceed what the core holds.

rate (wei per whole point of score). it opens at `RATE_START`, an immutable constructor argument bounded to [`RATE_START_MIN_WEI` 1e11, `RATE_START_MAX_WEI` 1e15, shared constants of `Interfaces.sol`] because the right opening bid depends on the market on launch day (the default in the config is 5.6e12, the launch day rule is in docs/DEPLOY.md section 1). lazy and checkpointed:

| since last fill | climb per hour |
|---|---|
| under 24h | 100 bps |
| 24h to 48h | 200 bps |
| 48h to 72h | 400 bps |
| after 72h | 800 bps |

* `funded` means the hourly cap can afford one average credit at the stored rate: `ethPot * 2000 >= AVG_SCORE * rate` (cap is 20 percent of the pot, one average credit costs `AVG_SCORE * rate / 1e4`, `AVG_SCORE` 4,330,000). at the start rate that is a pot of 5 average credits, 8.66e15 wei. between 1 and 5 average credits the pot is unfunded and the rate does not climb.
* it climbs only while `funded`, and is clamped at `max(rateAtCheckpoint, ethPot * 2000 / AVG_SCORE)`, the exact point where 20 percent of the pot no longer buys one average credit. so at the clamp an average credit can still be sold in the same block, the bid never climbs to a level nobody can sell into.
* every pot change checkpoints first. a fill of `x` from pot `p` drops the rate by `rate * DROP_BPS / 10000 * min(x, p) / p` (`DROP_BPS` is a deploy input, default 1000, bounds [1000, 4000]) and sets `lastFillTime`. for `buyListing`, `x = cost + tip`.
* the inventory gate (`INVENTORY_GATE`, a deploy input, 0 is off, otherwise [5, 200]). `ethHeld` counts the eth lane statements the core holds for sale. while the gate is on and `ethHeld >= INVENTORY_GATE` the core is gated: `sellForEth` and `buyListing` revert `GateClosed`, and `ethRate()` returns the stored rate with no climb, the same as for unfunded time. `ethHeld` changes in four places and each checkpoints the rate first when the change crosses the gate, so a gated interval is never credited a climb and an open one always is: `compose` (+1), `buyStatement` (-1), `exitStatement` of an eth lane statement (-1), `overprint` of two eth lane statements (-1, the base stays). all of them are in `_unhold` and `_compose`, so there is no other path. fee intake, composing, statement sales, the buybacks, exits and the exit token lane are never gated, and the fill clock (`lastFillTime`) keeps running, so the climb tier on reopening is the same as for unfunded time.

hourly cap: a fixed window. the first spend after `windowStart + 1 hours` opens a new window with `windowPot = ethPot`. a spend needs `windowSpent + x <= windowPot * 20%`. tips count, gas reimbursements do not.

piles: per lane (eth, exit) an insertion ordered doubly linked list keyed by credit id. id 0 is the null sentinel and is refused at every door. per credit: lane, inPile, cost, acquiredAt. credits sent to the core outside the doors are not in a pile and are stuck.

`score(id) = CreditScore.scoreOf(Credits.seedOf(id), Credits.timestampOf(id))`.

## 5. doors

| door | what it does |
|---|---|
| `sellForEth(ids)` and `(ids, minOut)` | pays the ceiling `score * rate * (1 + bonus)` per credit from `ethPot`, one checkpoint and one cap check per credit. the credit goes to the eth pile. `minOut` protects the seller against a rate drop in the same block |
| `buyListing(value, data, id, target)` | the caller builds the calldata, the core calls an allowed target (Seaport 1.6 and CreditStrategy at launch) with `value`. cost is measured as the eth balance fall. needs the credit to arrive, `cost <= value <= ceiling`, and pot and cap room. the keeper tip is `min(10% of savings, 2% of cost)`, and `cost + tip` is booked as the spend |
| `sellForExitToken(ids)` and `(ids, minOut)` | phase 2. pays `score * xRate * unitPerPoint / 1e4` in exit token from `xPot` into the exit pile. `xRate` starts at 6000 bps of score, caps at 9700, floors at 3000, climbs 100 bps per hour and drops 20 bps per credit |

forbidden targets, checked when a target is added and again at call time: Credits, Statements, the Core, the coin, the hook, the pool manager, the factory, locker and fee escrow of the stack, Permit2, the position manager, the universal router, the exitModule and the exitToken.

## 6. compose, auction, exit, overprint

compose: `compose()` (eth lane) and `composeExit()` (exit lane, phase 2) ask the controller for a page, pull 80 credits and build a Statement through the live Statements contract. the returned id must equal `Statements.supply()` and be owned by the core. anyone may call and is repaid `min(gasUsed * basefee * 110%, 5% of cost, ethPot)`, gas measured from entry plus 50,000. the exit lane has no eth cost basis, so its cap is notional (`80 * AVG_SCORE * ethRate / 1e4`) and nothing is added to the statement cost.

statement auction (eth lane): the price falls linearly from `AUCTION_START_X` (default 4x) to `AUCTION_FLOOR_X` (default 1.2x) of cost over 72 hours (`priceOf`), then stays flat at the floor. both are deploy inputs, bounds [15000, 40000] and [6000, 12000] bps of cost with the floor strictly below the start. SPEC invariant 3 reads: no statement is sold below `AUCTION_FLOOR_X` of its cost. `buyStatement` splits the price 50 percent to `ethToBuyback` and 50 percent to `ethPot`, sends the statement and refunds the excess. exit lane statements are never for sale.

exit (`exitStatement`): needs the exitModule. an eth lane statement is exitable once its 72 hours ran, an exit lane statement at once. the core hands the statement to the module and must end with at least `rating * unitPerPoint` more exitToken, measured as a balance delta. `unitPerPoint` and `exitToken` are read once when the module is set (unit non zero and at most uint128) and never again, so a module cannot change what it owes later. eth lane: half of the received amount to `xToBuyback`, half to `xPot`. exit lane: all to `xPot`. while the exit measurement runs `receive()` books nothing.

overprint: permissionless and guarded. asks `controller.nextOverprint()`, needs two different held statements of the same lane, at most 8 per day. costs add onto the base, the base clock restarts, the top is no longer held, and the combined score is checked against the sum.

## 7. eth buyback with a real burn

`buyback()`, guarded. slice `min(1 eth, ethToBuyback)`, at most once per 25 blocks, tip 0.5 percent of the slice to the caller. the core swaps exact in through `PoolManager.unlock` and `unlockCallback` on the canonical pool key `(0, coin, POOL_FEE, TICK_SPACING, HOOK)` (0x800000 and 200 on the live stack), takes the coin to itself (the core is exempt from the tax) and calls `burn` on the token, so total supply falls. it reverts `NothingBought()` when no coin came out.

the callback returns what was spent and what was bought and requires the pool took no more than it was given. the tip scales down on a partial fill and unspent input goes back to `ethToBuyback`. the hook's skim on this swap returns to the core through `receive()` during the guarded call, which is expected and books into the pot. there is no min out (section 10).

## 8. exit token dutch auction

there is no exit pool. the buyback of the exitToken is an auction inside the core, paid in coin that the core burns. phase 2 only.

| item | rule |
|---|---|
| slice | `min(xToBuyback, 20 * AVG_SCORE * unitPerPoint)` |
| price | coin wei per exitToken unit, wad scaled. `price(t) = startPrice * 2^(-(t - startTime) / XAUCTION_HALF_LIFE)`, solady wad math, continuous, never reverts, reaches zero for long gaps |
| half life | `XAUCTION_HALF_LIFE` = 6 hours |
| cost | `coinIn = ceil(slice * price / 1e18)`, must be at most the caller's `maxCoinIn`. zero only when the price truly decayed to zero |
| fill | `burnFrom(msg.sender, coinIn)` on the coin, then the slice goes to the caller. no tip, no block delay, the caller approves the core first |
| restart after a fill | `startPrice = max(2 * clearingPrice, previousStartPrice / 4)`, `startTime = now`. if that computes to zero it is 1 |
| clock | runs only while `xToBuyback` is not zero |
| injection | every time exit token is added to `xToBuyback` (not only from empty): `startPrice = max(price now, startPrice / 4)` (at least 1) and `startTime = now`. with an empty pot the price now is the stored start price, so it is kept. injected funds never inherit a decayed clock |
| first start price | set when the module is set: the price at which one full slice costs the whole coin supply (`SUPPLY * 1e18 / fullSlice`). setting the module reverts `BadModule` if this is below 1e12, which rejects units above about 1e25 and keeps at least 40 half lives before the integer reaches zero |
| views | `exitAuctionPrice()`, `exitAuctionQuote()` returning `(slice, coinIn)` |

what the restart rule does. the next auction can never start more than 4x below the start of the previous one, so a price that decayed to dust does not carry over. every slice needs its own long decay before it can go cheap. measured in tests: the first slice reaches a price of 0.001 coin after about 240 hours (about 40 halvings from the opening price). the second starts a quarter lower and needs about 12 hours less, the third 12 hours less again, so three slices at dust take about 28 days, against one decay under a fixed floor. a taker who fills near a fair price restarts the auction at twice what they paid, the price is back to what they paid one half life later, and the cadence is one slice per half life.

the same quarter floor applies to every injection of new exit token, so a refill after a long quiet spell restarts the curve at a quarter of the last start at the least, and the decay figures above are for a pot that is not refilled in between (each refill pulls the next dust date a little closer, never below the quarter floor).

the price rounds to zero after about 90 half lives (about 22 days) from the opening start, and after 256 half lives at the latest. a fill at zero is free and the restart is a quarter of the start just played, so the rest of the queue is not cheap.

## 9. timelock actions and tests

timelock: `queue(action, data)`, `execute`, `cancel`, all owner only, 7 days, keyed by `keccak256(abi.encode(action, data))`. actions: `SetController` (blocked after `Freeze`), `SetExitModule` (once), `AddTarget`, `Freeze`. `removeTarget` is immediate. Seaport 1.6 and CreditStrategy are allowed from the constructor. the owner is immutable.

tests policy: real contracts only. fork at block 26127622 (`FORK_BLOCK`), rpc from `MAINNET_RPC_URL` in `.env`.

| group | rule |
|---|---|
| live, never faked | Credits, Statements, CreditScore, CreditStrategy, Seaport 1.6, the pool manager and the whole artcoins stack (factory, token, skim hook, locker, escrow, anti sniper module) |
| the two stand ins | `MockExitModule` and `MockExitToken` in `test/standins/`. nothing is deployed for them yet |
| attackers | hostile target, scripted and fuzz controllers, probes, statement buyers, mid swap callers, in `test/attackers/`. they attack the real system, they do not replace any of it |
| swaps | a small unlock based test swapper (a caller, not a stand in) and one test that buys and sells through the real universal router |
| owner action forced | one prank of the real factory owner: `setAdmin(deployer, true)` |
| rehearsal | `test/Rehearsal.t.sol` forks the latest block instead of the pinned one and skips unless `REHEARSAL` is set. the default suite stays pinned and fast |

suites: `CoreUnit`, `Config`, `Fees`, `Launch`, `Lifecycle`, `ReviewCore`, `Seaport`, `Econ` (bounds, views and effect of the four economic dials), `Gate` (the inventory gate: closed bid at the threshold, reopening on sale, exit and overprint, exact no climb numbers, gate 0 off, a fuzz of the rate over gated and unfunded intervals) and the invariant handlers in `test/invariant/` (the handler models the auction price with the 6 hour half life and the restart rule, and reads every economic dial from the Core, so the suites run under three dial sets chosen by the env var `INVARIANT_ECON`: `default`, `recommended` (the recommended config file, gate 20) and `gate5` (defaults with the gate at 5 and four statements held at the start, so the fuzz reaches the gate)). listing tests must fund the pot and warp until the ceiling clears the listing price, because `RATE_START` is far below the CreditStrategy prices at the pin. the Seaport test builds genuine Seaport 1.6 orders on the fork and fulfills them through `buyListing`.

## 10. deviations and accepted properties for the owner to confirm

none of these is a code change in this repo. each is either a deliberate departure from SPEC.md or a property of the live stack we accept.

| # | item | what it means |
|---|---|---|
| 1 | tax is a deterrent, not a wall | wallet to wallet transfers and unlisted venues pay neither skim nor tax. sells are never taxed. the venue list is frozen at launch. the token admin can lower the rate |
| 2 | anyone can LP the canonical pool | after the anti sniper window anyone may add liquidity to the pool. the launch position stays locked |
| 3 | token admin powers | the owner, as token admin, can lower the tax, set metadata and renderer, lower the referral cap, and attach an allowlisted pool extension (none is enabled today, and `lockPoolExtension` at launch closes that path). the admin cannot change recipients, bounty split, skim, ticks, venues or the exempt list |
| 4 | artcoins factory owner powers | 0xCB43 can deprecate the factory, set the deploy fee (up to 1 eth), set hooks, lockers and mev modules for new launches and mark admins. it cannot touch a launched pool, token, skim leg or locker position. launching needs it to mark our deployer admin |
| 5 | `receive()` gas | `receive()` adds about 15.6k gas to every swap in the pool, and must never revert or the pool is bricked for everyone, sells included |
| 6 | referral cap is 0, `notify` is a no op | the core implements `notify` and books nothing, so a raised cap can never revert a swap. eth it receives that way is booked later by `skim` |
| 7 | hourly cap is a fixed window | the window reopens on the first spend after it expires, so two adjacent windows can spend 40 percent of the pot across a boundary. tips count against it, gas reimbursements do not |
| 8 | funded clamp equals the hourly cap (changed, adopted) | `funded` and the climb clamp use the threshold where 20 percent of the pot buys one average credit, so the bid cannot climb above what the cap lets anyone sell into. the cost is that the bid stops lower: at the clamp the whole pot is five average credits, and with a pot under that the rate does not climb at all. credits with a score above the average or a bonus can still exceed the hourly cap and wait for a bigger pot |
| 9 | eth buyback has no min out | the swap is exact in with no price floor, as in the upstream pattern. the launch liquidity is locked and no third party position can sit in the way of the slice, and a sandwich pays the skim and tax round trip. the 1 eth slice and the 25 block delay bound the exposure |
| 10 | exit auction sells at a discount | the opening price asks the whole supply for a slice and falls by half every 6 hours. buyers take exitToken below its market value whenever they wait. it can go cheap only after a long unattended decay for each slice, because every restart is at least a quarter of the last start |
| 11 | exit auction restart can sit above a fair price | a fill at a high price doubles the next start. the price then decays on the clock only, with no demand signal |
| 12 | `unitPerPoint` is fixed | read once when the exitModule is set. the module cannot change what the core pays or requires afterwards |
| 13 | fee on transfer or rebasing exitToken unsupported | pot accounting and the balance delta checks assume the amount sent is the amount received |
| 14 | exit lane compose is reimbursed from the eth pot | with a notional cap of 5 percent of `80 * AVG_SCORE * ethRate / 1e4` |
| 15 | credits sent to the core outside the doors are stuck | they are in no pile. same for eth sent by a non hook sender, until `skim` books it |
| 16 | added to the spec | `skim()`, `minOut` overloads on both sell doors, `composeExit()`, `buybackExit(maxCoinIn)`, `cancel` on the timelock |
| 17 | SPEC.md sections on the Coin, FeeHook and Launcher do not apply | replaced by the live artcoins token, skim hook and factory. the transfer restriction is replaced by the token's venue scoped buy tax |
| 18 | review P-1: third party fee income | eth pushed by the hook from any open pool that names the core as bounty recipient is booked as fee income. it is a donation by the sender, so `FeesAdded` is not proof of organic volume |
| 19 | review P-6: cost basis in `buyListing` | a hook push that lands inside the target call lowers the measured cost, so the stored basis and the statement floor are understated by it. the books stay exact and no profitable path was found |
| 20 | review P-7: venue tax bypass | the venue tax can be bypassed with a flash liquidity add and remove in the canonical pool (an artcoins hook issue found in the artcoins audit), so the tax is a weak deterrent against a purpose built router. model fee income on canonical pool volume only, about 9.5 percent of net new money entering through that pool |
| 21 | stack is a deploy input | the Core stores the stack it launched on and cannot be repointed. a launch on a new artcoins version is a new Core. the token creation code file (`launch.tokenCodeFile`) is also an input of the coin prediction and must match the token implementation of the stack |
| 22 | `rateStart` is a deploy input | bounded to [1e11, 1e15] wei per whole point and immutable. the default 5.6e12 comes from the simulation (flat price divided by 1600), the launch day rule is in docs/DEPLOY.md section 1 |
| 23 | `FEE_BPS` and `CREATOR_BPS` removed from the Core | they were informational, no logic read them, and the bytecode room went to the economic dials (item 24). the skim is configured at the hook. `SUPPLY` is read by the exit auction and must equal the launch supply, which preflight and postflight check. `RATE_START_MIN` and `RATE_START_MAX` lost their getters for the same reason, the bounds live in `Interfaces.sol` |
| 24 | four economic dials are deploy inputs | `AUCTION_START_X` [15000, 40000] default 40000, `AUCTION_FLOOR_X` [6000, 12000] strictly below the start, default 12000, `DROP_BPS` [1000, 4000] default 1000, `INVENTORY_GATE` 0 or [5, 200] default 0. immutable, public views of the same name, checked in the constructor and in preflight, read back by postflight, part of `CONFIG_HASH`. the defaults reproduce the engine as specified exactly. `script/config/mainnet.recommended.json` sets 20000, 8000, 2000 and 20 (the simulation's `gate20constants` row). with a floor below 1.0x the engine can sell statements under cost, which is a choice the owner makes by picking the file. the gate keeps eth in the pot instead of statements, at the price of slower credit buying and less rating for phase 2. what to watch with the gate on: `ethHeld()`, `ethRate()` and whether the bid stays closed for long stretches when statements do not sell (they exit after 72 hours only if an exitModule is set, until then only a sale or an overprint lowers the count) |
