# v2 port plan

## status after the port (2026-10-08)

the port is implemented as docs/FLOW.md section 10 decides (10.1 to 10.7, the amendments win over the plan below). the engine was ported on v2 commit 87a7522 and runs on the vendored v2 artifacts of commit d4aa46b (test/v2-artifacts/README.md). the changes between the two are in the next section. where this file and section 10 differ, section 10 wins.

### v2 changes from 87a7522 to d4aa46b that touch the engine

| change | engine effect |
|---|---|
| skim rates and the referral cap are in bps of volume (6.9 points is 690, `MAX_BASELINE_SKIM_BPS` 1000, `DEFAULT_START_SKIM_BPS` 6869, `MAX_SKIM_BPS` 9000), the lp fee is `lpFeePips` | config `baselineSkimBps` 690, `sniperStartBps` 9000, `lpFeePips` 0. the fee split is unchanged: `bountyBps` 9_638, `payeePpm` 112_778, factory `minProtocolSkimShareBps` 362 (FLOW 10.12) |
| factory: `setMinLpFee`, `minLpFee`, `setReferralPayout`, `referralPayout`, `setEscrow`, `enabledEscrows` removed. `ZeroFeeLaunch` when the lp fee and the baseline skim are both 0 | one factory owner command left. the preflight rows for the min lp fee, the referral payout and the enabled escrow are removed |
| `isArtCoin` is `isCoin`. `DeploymentInfoV2` gains `escrow`, `configHash` and `restricted` | postflight reads `isCoin` and compares the recorded escrow and restricted flag with the config |
| hook: `setBountyRecipient`, `minProtocolShareBps(poolId)`. `setDeliveryParams` and the delivery globals removed. `SkimConfig` loses `referralPayout` and `quoteToken`, `globals()` holds the fee escrow and the extension allowlist | the bounty recipient is repointable by the coin admin until `lockRecipients()` (FLOW 10.12) |
| locker: `setRewardRecipient`, `protocolSlotIndex`. `placeLiquidity` takes `hasProtocolSlot` | the creator slot recipient is repointable by the coin admin until `lockRecipients()` |
| token: `metadata` and `context` merged into `description`. `lock` split into `lockAllowlist` and `lockRecipients`. `verify`, `isVerified`, `originalAdmin` removed | postflight reads `description`, `allowlistLocked` and `recipientsLocked` |
| fee swapper: `artCoin` is `coin` | `test/utils/V2Stack.sol` `deploySwapper` |

### claims that were wrong or are superseded

| plan claim | what is true | evidence |
|---|---|---|
| section 5.3: the coin address depends on the router address, not on the Core address | wrong once the Core is on the coin's allowlist (decision 29): the allowlist is in the config the factory hashes, so the coin address depends on the Core address too. controller (nonce n), router (n+1), Core (n+2) and the coin are all predicted from the owner nonce and checked after each deploy | `script/SystemDeployer.sol`, `Fixture.predictCoin(c, owner, router, core)` |
| section 5.3 steps 7 and 8: `setEngine`, then lock | the deploy does not lock the router. a later engine migration needs `setEngine` open. the deploy runs `setEngine` and `setPayees`, the next Resume run `setSplitStart` from the mined launch time, the owner locks when no migration is wanted | docs/DEPLOY.md, `V2PortMigration.t.sol` |
| section 0.1 flags 2 and 3, section 5.1: bounty 9000 and lpFee 3000 as the nearest allowed values | superseded by decision 23: baseline skim 6.9 points, `bountyBps` 9638, `lpFeePips` 0, reached by the factory owner command `setMinProtocolSkimShareBps(362)` before the launch. the protocol leg is 0.24978 points (362 of 10,000 of the skim) and belongs to the launcher protocol | `V2Stack.t.sol` `test_v1LaunchValuesRevert`, preflight rows |
| section 6, the lp income options A, B, C | moot. with `lpFee` 0 the locker has nothing to pay: no swapper, no lp income path, no escrow depositor registration. the locker slots are the creator 8,000 bps and the factory protocol slot 2,000 bps | `V2Port.t.sol` `test_noLpIncomeAtLpFeeZero` |
| section 4.2 recommendation: do not allowlist the Core | the owner decided the opposite (decision 29). the plan's description of both cases is right and now tested: allowlisted, the buyback leaves an allowance of exactly the coin bought that a stranger can spend inside the same transaction, and anyone can donate coin (rescued by `rescueCoin`). not allowlisted (a delisted Core, a second Core), the take consumes the allowance exactly and a plain transfer reverts | `V2PortRestriction.t.sol`, `V2PortMigration.t.sol` |
| section 2.2: the Core change is 0 to +90 bytes and the Core keeps 161 bytes | the Core runtime is 24,501 bytes with 75 bytes of headroom (the V2R-1 revert in `receive` added 5 bytes to the 24,496 of the first port). the fee source immutable, the extra forbidden target and `rescueCoin` (delegated to `CoreLib`) cost 81 bytes in total. the plan's range held, its starting headroom was spent, FLOW 10.3 asked for 60 and has 80 | `forge build --sizes` |
| section 9.1: simulator change is small | wrong. the skim (10 points to 6.9), the router payee split and the missing lp income change the model's inflow. see docs/SIMULATION.md | sim/engine.js |
| section 3: a partial fill refund of the Core's buyback arrives as an escrow credit | the mechanics after the credit are right and tested (anyone claims it into the Core, nobody redirects it, `skim()` books it). a partial fill itself could not be produced: on the launch pool it needs about 3e42 wei of input (an estimate, the position runs to the end of the tick range), over the int128 range of a pool amount. the credit is tested by crediting the Core through the real hook as depositor | `V2Port.t.sol` `test_escrowCreditOfTheCoreIsClaimedByAnyoneThenSkimmed` |

### claims checked and right

| claim | evidence |
|---|---|
| a push to a Core `receive()` that books cannot fit the 2,300 stipend (est over 15k gas) | the booking path costs 12,045 gas in the same block, 20,184 an hour later, 46,211 after 20 years at the worst rate (`Fees.t.sol` `test_receiveGas*`). the empty router `receive` fits exactly (`FeeRouter.t.sol` `test_receiveFitsExactly2300Gas`) |
| the escrow claim reaches the Core with the escrow as sender, so it is not booked, and `skim()` books it to the pot | `V2Port.t.sol` |
| a claim inside `buyListing` lowers the measured cost, keeps pots and balance consistent, tip at most 0.1 of E and 2 percent of cost, and E at or over the price reverts `BadCost` | `V2Port.t.sol` `test_claimMid*` |
| a flush inside a measured call reverts `Measuring` (superseded, V2R-1) and the fees wait in the router | `Fees.t.sol` `test_receiveMid*`, `ReviewV2Port.t.sol` `test_FIXED_*` |
| the buyback swap, the pool key, the delta check and `burn` work unchanged on v2, the hook's skim goes to the router | `Fees.t.sol`, `FeeShare.t.sol` |
| the hook's push gas is the stipend whatever `pushGas` says (flag 8) | `V2Stack.t.sol` `test_writingRecipientIsCreditedInEscrowAndClaims` |
| restricted coin: `burn` and `burnFrom` bypass the rule, wallets cannot move coin, a side pool cannot be seeded, a just in time position cannot be built | `Fees.t.sol` `RestrictedCoinTest`, `ReviewPort.t.sol`, `V2PortRestriction.t.sol` |
| the factory's `deployTokenAsOwner` takes the fee as value, `predictToken` matches the returned token | `Launch.t.sol` |
| a compose and the launch fit the 16,777,216 gas cap | `GasCap.t.sol`: compose 55.4 percent cold, launch 21.0 percent |

### still open

| # | question | owner |
|---|---|---|
| 1 | v2 is not on mainnet and its audit is pending. the five stack addresses are zero in the tracked config. before the real preflight compare the live hook `constantsHash()` and the factory runtime code with the vendored artifacts (`test/v2-artifacts/README.md`) | owner, v2 team |
| 2 | `payeePpm` was 161,031 as FLOW 10.7 said (the first port used 161,030); the current value is 112,778, FLOW 10.9. the payee share is of the gross flush and the engine receives the rest (V2R-4) | owner rules |
| 3 | `predictToken` depends on mutable factory state (default allowlist, token deployer, hook escrow). preflight reads it, the config hash does not cover it: recompute right before the broadcast | operator |
| 4 | the partial fill refund path of the Core's own buyback has never run on a real pool | v2 team, live check |
| 5 | section 10.2 questions to the v2 developer stand as asked (seeded routers in D73 against the source, leftover allowance of an allowlisted taker, per launch overrides for the global knobs, `pushGas` unused, missing `factory()` and `feeEscrow()` getters on the hook, published artifact sets) | v2 team |
| 6 | the stale lines of `CREDITS-ENGINE-INTERFACE.md` (section 11 below) are in the v2 repo, not ours | v2 team |
| 7 | the split start is the mined launch time plus the window (no margin, V2R-7) and the single launch payee are launch choices the owner may change with `setSplitStart` and `setPayees` | owner |


status of everything below this section: the analysis written before the port, kept unchanged. it was written without building anything. the port is done on branch `flow` and the section above it says what held and what did not. reviewed against v2 `origin/v2` HEAD 87a75228 (2026-10-07), source at `/home/claude/nmcl/v2`. engine at branch flow, Core runtime 24415 bytes, 161 bytes headroom (from `out/Core.sol/Core.json`).

rules used: source beats docs. where `docs/v2/CREDITS-ENGINE-INTERFACE.md` or `DECISIONS.md` disagree with source, the source wins and the conflict is named. all line numbers are v2 unless prefixed `engine:`. byte and gas figures marked (est) are opcode arithmetic, not measured, because no build ran.

pending on the v2 side: deploy waits on the v2-audit-4 audit (STATUS.md), D75 merges v2 into master before deploy. mainnet stack addresses do not exist yet.

## 0. what v2 changes for the engine (updated table)

| area | v1 (today) | v2 (source) | engine effect | verdict |
|---|---|---|---|---|
| fee delivery | hook pushes eth to Core, `receive()` books it | hook pushes with the 2300 stipend, falls back to escrow (`FeeDelivery.sol` L26 to 37, hook L103, L470 to 474) | Core `receive()` can never book a push (section 1) | breaks silently |
| bounty recipient | Core | Core works only through `skim()`; a FeeRouter is the clean path | router plus one line Core change, or router plus `skim()` | decision needed |
| buyback swap | `CoreLib.swapIn` into taxed pool | same key shape, hook takes skim in `beforeSwap`, refund on partial fill goes to escrow (D58) | `swapIn` and `unlockCallback` unchanged | works |
| coin | ArtCoinsToken v1 with tax | ArtCoinsTokenV2, `restricted` flag, no tax, transient allowance (`ArtCoinsTokenV2.sol` L229 to 249) | tax exemption logic gone; Core should NOT be allowlisted | works, policy choice |
| burn | `burn`, `burnFrom` | same, both bypass `_route` (token L213 to 221) | `buyback`, `buybackExit` unchanged | works |
| launch | `deployTokenWithProtocolBpsAndTax` | `deployTokenAsOwner(c, protocolBps)` with `DeploymentConfigV2` (factory interface L78 to 86) | Builder, Deploy, Checks, Config rewritten | rewrite |
| predictToken | local CREATE2 from `ArtCoinsToken.creation.hex` | `factory.predictToken(sender, c)` view (factory L236 to 252) | hex file and `Builder.predictCoin` removed | replaces |
| launch fields | bounty 9500, lpFee 0 | bounty cap 9000 at mainnet env, lpFee floor 3000 | two fields cannot keep values without owner knobs | breaks |
| lp fee | none (lpFee 0) | locker `collectRewards` pays eth and coin to reward recipients | new income stream, needs a recipient design | new |
| admin model | factory admins, extension lock, handover | none; owner only `deployTokenAsOwner`, token admin set directly | stages collapse, factory owner key signs launch | simplifies |
| forbidden list | v1 hook, factory, locker, escrow | same four, v2 addresses | constants and Stack change only | works |
| tests | v1 fixture, solc 0.8.30 | v2 needs solc 0.8.26 sources, OZ 5.1+, v1 tree imports | consume prebuilt artifacts, do not compile v2 | rework |
| hook flags | v1 included afterRemoveLiquidity | 0x28CC: beforeInitialize, beforeAddLiquidity, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta | postflight flag checks change | rewrite |

## 0.1 flags (read these first)

1. the bounty push never books (section 1). if the Core stays the bounty recipient, 100% of fees arrive via escrow credit and `skim()`, and `feeToBuybackBps` is dead on the fee path.
2. `bountyBps` 9500 reverts `BountyBpsTooHigh(9500, 9000)` at mainnet `MIN_PROTOCOL_SKIM_SHARE_BPS=1000` (`mainnet.env`). only the factory owner can lower the global knob, and it is global.
3. `lpFee` 0 reverts below `minLpFee` 3000. same story.
4. the protocol 0.5 point leg goes to the factory injected `protocolRecipient`, not the creator, unless the owner calls `setProtocolRecipient` first (frozen per pool at init).
5. the owner setter on a FeeRouter conflicts with FLOW.md decision 8. mitigate with lock after first set.
6. only the v2 factory owner can launch while deprecated; the "fresh deployer as admin" path in DEPLOY.md steps 4 and 10 disappears.
7. doc vs source: D73 says permit2, router, fee swapper and burn router are seeded into the allowlist. the source seeds none of them (factory `_restriction` L282 to 316; commit 92c34e81). trust source.
8. doc vs source: the hook declares `Constants.PUSH_GAS_DEFAULT` (50000) in globals (hook L150, `setDeliveryParams` L613 to 631) but pushes with `_PUSH_GAS = 0` (L103, L472). the tunable does nothing for the bounty leg. the stipend is the real behaviour.
9. doc vs source: CREDITS-ENGINE-INTERFACE.md says the skim refund rides the afterSwap return delta. D58 and hook L388 to 397 say the refund goes to the escrow.
10. v2 audit pending: every number here can still move before mainnet.

## 1. fee delivery

### 1.1 how the hook delivers the bounty leg

| item | fact | source |
|---|---|---|
| legs | bounty, protocol, referral, split in `_split` | hook L421 to 468 |
| push call | `FeeDelivery.sendNative(escrow, to, amount, _PUSH_GAS)` with `_PUSH_GAS = 0` | hook L103, L472 |
| gas to callee | `call(gasCap=0, ...)` so the callee gets only the 2300 stipend | `FeeDelivery.sol` L26 to 37 |
| failure | `escrow.storeFeesNative{value}(to)` credits the recipient | `FeeDelivery.sol` L35 |
| event | `FeeDelivered(pid, leg, to, amount, !pushed)` | hook L470 to 474 |
| msg.sender on push | the hook | call from hook |
| msg.sender on escrow claim | the escrow | escrow `_payout` L120, `recipient.call{value}("")` with all gas |
| who can claim | anyone, unless the recipient set `selfClaimOnly` | escrow L87 to 90 |
| redirect | `claimTo` only by the fee owner (the credited address) | escrow L93 to 99 |
| escrow events | `FeesStored`, `FeesClaimed` | escrow |
| recipient checks | nonzero, not hook, not PoolManager; no code check | `_validateSkim` L548 to 563, `_checkReceiver` L565 to 567 |

there is no `streamForward` probe in the hook (hook L55). Constants still carries `STREAM_GAS_*` (Constants.sol L38 to 44), unused by the hook path. do not build on it.

### 1.2 what happens if the Core is the bounty recipient

engine receive, `engine:src/Core.sol` L356 to 364: returns early unless `msg.sender == HOOK && !_measuring`, else `_checkpoint()`, SSTOREs, LOG.

| question | answer |
|---|---|
| does a push succeed | no, on the booking path. it needs at least two cold SLOADs (2 x 2100), several SSTOREs, possibly a cold delegatecall to CoreLib (2600) and a LOG. that is over 15k gas against 2300 (est). EIP-2200 also forbids SSTORE with 2300 or less left. |
| when does a push succeed | only on the early return path (`_measuring` set), and then nothing is booked |
| where does the eth sit | escrow, credited to the Core |
| who can move it | `escrow.claim(core, 0)` by anyone, paying only to the Core. `claimTo` needs msg.sender == Core, and the Core has no code path that calls it (the escrow is a forbidden target) |
| msg.sender the Core sees on claim | the escrow, so `receive()` returns early and books nothing |
| booked as fees or left for skim | left as unbooked balance. `skim()` (engine L381 to 399) later books 100% to `ethPot` |
| effect on `feeToBuybackBps` | bypassed. `skim()` does not apply the split, so the setting is dead on the fee path |
| effect on `FeesAdded` | not emitted; `Skimmed` is |

### 1.3 measuring flag and mid call claims

`buyListing` sets `_measuring` around the seller call (engine L602, flag L614 to 616). a seller contract paid by Seaport can call `escrow.claim(core, 0)` mid call, so E eth lands in the Core with msg.sender escrow.

| consequence | detail |
|---|---|
| funds | safe. the pot is debited cost minus E and the balance holds E, so arithmetic stays consistent |
| cost basis | recorded cost understated by E |
| DoS | if E >= cost then `ethAfter >= ethBefore` and the call reverts `BadCost` |
| split bypass | E skips `feeToBuybackBps` entirely |
| tip | caller may earn a small inflated tip, at most 0.1E and capped at 2% of cost (tiny) |
| other paths | `exit` and `collectSales` (`exitStatement` L926) are unaffected, extra eth only helps |
| precedent | the same class exists today with a plain eth send to the Core during the seller call |

the buyback's own skim no longer returns synchronously through `receive`. in v2 it goes to escrow (refund, D58) and the fee legs, so `buyback()` never sees it as a re-entrant eth credit.

## 2. fee router option

a tiny `FeeRouter` as the bounty recipient: `receive() external payable {}`, permissionless `flush()` forwarding the balance to the current engine, an owner `setEngine` with a one way lock.

### 2.1 checks

| check | result |
|---|---|
| stipend | an empty receive costs about 20 to 40 gas (est), far inside 2300. so every push succeeds and the hook never writes escrow credit for it |
| rules in v2 forbidding it | none. hook checks nonzero and not hook or PM (L548 to 567). factory `_validateFee` (L434) checks nonzero only, no code check. `_checkRecipients` (L502 to 524) applies to locker reward recipients, not the bounty recipient |
| tax sink and exempt rules | gone after D73 |
| must not do | emit events (a LOG1 is about 1000 gas, risky under repricing), proxy delegatecall, SSTORE, cold SLOAD, external call |
| guard | `flush()` must revert when engine == address(0). a call to address(0) succeeds and burns the eth |
| flush shape | `engine.call{value: balance}("")`, reverts on failure, anyone can call |
| circularity | the coin address depends on the router address, not the Core address. order: router, `predictToken`, Core(coin), `router.setEngine(core)`, lock. this also removes the escrow credit risk |
| trust | the owner setter lets the owner point the whole stream anywhere until locked. this conflicts with FLOW.md decision 8 (owner can never redirect eth). flag it. mitigations: require code at the target, lock after the first set, set and lock in the same deploy script |

### 2.2 smallest Core change (C1)

| edit | lines | bytes (est) |
|---|---|---|
| add `address private immutable FEE_SOURCE`, new `Stack` field, constructor arg | `engine:src/Core.sol` constructor L295, `Interfaces.sol` Stack L173 | 0 (same PUSH32 count) |
| change `msg.sender != HOOK` to `msg.sender != FEE_SOURCE` in `receive()` | L357 | about 0 (swap one PUSH32 for another) |
| keep `HOOK` for `_forbiddenBase` (L685), `unlockCallback` arg, getter | none | 0 |
| optional getter `feeSource()` | new | about +50 |
| optional forbidden target entry for the router | `_forbiddenBase` L685 | about +40 |
| optional delete dead `notify(address)` (v2 never calls it) | L368 | about minus 25 |

total range 0 to about +90 against 161 headroom (est, measure after the edit). an ungated `receive()` (book any sender when not measuring) is possible but loosens the SPEC invariant that only the hook feeds the pot, so it is not recommended.

with C1 the router must still forward through a plain call, and then `msg.sender` at the Core is the router, which `FEE_SOURCE` accepts. `feeToBuybackBps` and `FeesAdded` keep working. the `_measuring` early return still applies, so a flush mid measured call books nothing and leaves the eth unbooked until `skim()`. consider making the router `flush()` check nothing and rely on that; the loss is only a timing skew, not funds.

### 2.3 alternative with no Core change

`router.flush()` sends the eth, then calls `Core.skim()`.

| lost | gained |
|---|---|
| `feeToBuybackBps` split (100% to the pot) | `skim()` is nonReentrant, so flush reverts inside a measured call and a third party cannot skew a measurement through the router |
| `FeesAdded` event (replaced by `Skimmed`) | zero Core bytes |
| router must know the `skim()` selector | |

the lost split matters: it is the only knob that sends fee eth to buyback. if the owner wants buyback funding, take C1.

## 3. buyback swap

compare `CoreLib.swapIn` (`engine:src/lib/CoreLib.sol` L154 to 181) and `unlockCallback` (`engine:src/Core.sol` L1034) with `ArtCoinsHookV2`.

| item | engine assumption | v2 behaviour | outcome |
|---|---|---|---|
| pool key | `(0, coin, 0x800000, 200, hook)` | same shape: `DYNAMIC_FEE_FLAG`, currency0 eth, currency1 coin (hook L184 to 190, token L148 to 155) | works |
| permissions | hook flags with afterRemoveLiquidity | 0x28CC, no afterRemoveLiquidity | postflight check only |
| direction | `zeroForOne`, exact in, limit `MIN_SQRT_PRICE+1` | hook `_beforeSwap` (L297 to 326) takes skim s on the input and returns specified delta +s | works |
| delta seen by Core | `owed == amountIn`, check `owed > amountIn` reverts | caller delta amount0 is minus the full budget a, so `owed == amountIn` | passes |
| output | `bought = d.amount1` | ret = 0 for this swap shape, unchanged | works |
| hookData | `""` | `HookCalldata.decode` and `refundTo` tolerate empty; no referral, no swapper restriction | works |
| restricted coin take | `take(currency1, this, bought)` | `afterSwap` grants allowance exactly `|delta.amount1|` before the take (L375 to 382) | works, see section 4 |
| partial fill (price limit hit) | assumed refund in swap | over charge refunded to the escrow, credited to the PM caller (the Core), not in swap (D58, hook L388 to 397) | works, refund arrives as escrow credit and sits until `claim(core,0)` then `skim()` |
| sync rule | n/a | hook resets sync (L399 to 409) | irrelevant, the Core settles native with `settle{value}` and no sync |
| skim refund D42/D51 | refund inside swap | superseded by D58 | doc stale |
| getters | engine reads `factory()` / `feeEscrow()` on the hook | the hook has neither. use `globals().feeEscrow`, `isLauncher`, `poolInfo`, `skimConfig` | `Checks._preStack` L287 breaks |
| `skimConfig(bytes32)` | decoded as 8 words | 8 static words, same order as v1 | works |

nothing in swapIn reverts or misaccounts. the one behavioural change is the partial fill refund path: it is escrow credit, unbooked, and reaches the pot only through `claim(core,0)` plus `skim()`. a keeper or `skim()` caller should claim first. state this in ARCHITECTURE section 4.

the buyback's own skim: the swap's skim s is split by the hook to bounty (Core or router), protocol and referral. the Core's own bounty share comes back as fee eth. with the router and C1 it books through `receive()`; without, via `skim()`.

## 4. token and restriction

### 4.1 semantics

| item | fact | source |
|---|---|---|
| burn | `burn(amount)` and `burnFrom(account, amount)` call `_burn` and skip `_route`, so they pass while restricted | token L213 to 221 |
| burnFrom allowance | `_spendAllowance(account, msg.sender, amount)`, a normal ERC20 allowance | token L213 to 221 |
| restricted rule | `_route`: if `restricted && !_allowed[from] && !_allowed[to]` then require `from == pm || to == pm`, then require a transient allowance >= amount and consume it | token L229 to 240 |
| allowance grant | `increaseTransferAllowance`, callable only by the canonical hook, only for the canonical pool id, undirected | token L245 to 249 |
| grant timing | hook `afterSwap`, exactly `|delta.amount1|` | hook L375 to 382 |
| `setAllowed` | admin only, not after lock, rejects PM and hook, cannot remove pinned entries | token L271 to 280 |
| `unrestrict` | admin, one way | token L283 to 289 |
| `lock` | freezes allowlist and restriction state | token L292 to 297 |
| `renounceAdmin` | freezes the current state | token L335 to 341 |
| initial allowlist | factory `_restriction`: defaultAllowed (not pinned), locker (pinned), escrow (pinned), extensions (pinned), plus user list; max 64 | factory L282 to 316, Constants L80 |
| defaultAllowed | ships empty; `DeployV2Lib._checkFactory` asserts it | `script/v2/DeployV2Lib.sol` |

doc vs source: D73 text lists permit2, the universal router, the fee swapper and the burn router as seeded. the source seeds none (commit 92c34e81), and `example-restricted.json` L3 says never list a router, aggregator or smart wallet because an allowlisted forwarder reopens wallet to wallet transfers.

### 4.2 coin movements

| movement | Core not allowlisted | Core allowlisted |
|---|---|---|
| buyback: PM to Core `take` | works. the take consumes exactly the granted allowance (bought) | works but `_allowed[to]` short circuits, leaving a transient allowance of `bought` that anyone can spend in the rest of the transaction |
| `burn(bought)` | works (bypasses `_route`) | works |
| `buybackExit`: `burnFrom(buyer)` | works if buyer approved the Core | works |
| holder sends coin to the Core | reverts (neither side allowed, neither is PM) | succeeds, coin is stuck (the Core has no coin sweep; `skim` handles eth and `exitToken` only) |
| locker coin reward to the Core | passes (the locker is pinned allowed), coin is stuck | same |
| fee swapper `convert` | works without any allowlisting (`test_holds_restricted_swapperConvert`, `test/v2/review-v2/b/V2BPeriphery.fork.t.sol` L257 asserts the allowance fully consumed) | n/a |

recommendations:

| address | allowlist it | why |
|---|---|---|
| Core | no | allowlisting leaves a spendable leftover allowance and opens a donation sink. not allowlisted, the buyback take consumes the exact allowance |
| FeeRouter | no | it only holds and forwards eth, never coin |
| swapper | no | convert works without it. listing it would leak leftover allowance (flag for the v2 developer, the example json suggests listing one) |
| exitModule, exitToken | decide when phase 2 is specified | they must not need coin transfers from wallets; if they do, list them only when their coin outflows are fixed by their own logic |

### 4.3 what a restricted coin means for holders

| consequence | detail |
|---|---|
| wallet to wallet | reverts |
| CEX deposits, bridges, side pools, multisig moves | revert |
| trading | only through the canonical pool (via the universal router or permit2, which are not allowlisted) |
| D74 bypass cost | a round trip through the pool: about 2 x (10% skim + lpFee), roughly 20% or more |
| if restricted OFF | the 10% skim is easy to route around through side pools, so volume leaks and fee income falls. restricted ON is essentially needed to protect fee income |
| after `unrestrict` | the hook keeps granting allowance (minor v2 note), harmless |
| engine impact | `burnFrom(buyer)` still works, so holders can still exit into the Core by approval |

## 5. launch

### 5.1 field map

| engine field | v2 field | constraint | outcome |
|---|---|---|---|
| supply 1e27 | `token.totalSupply` | 0 means 1B default; min 1e18 | works |
| startTick -175000 | `pool.tickIfToken0IsArtCoin` | multiple of tickSpacing | works |
| tick range lower -175000, upper 887200 | `locker.tickLower[]`, `tickUpper[]`, `positionBps [10000]` | lo >= startTick, multiples of spacing, hi <= MAX_TICK | works |
| baselineSkimBps 10000 | `fee.baselineSkimBps` | max 10000 (`MAX_BASELINE_SKIM_BPS`, Constants L27) | works at the cap |
| bountyBps 9500 | `fee.bountyBps` | <= BPS minus `minProtocolSkimShareBps`; mainnet env 1000 so cap 9000 | breaks: `BountyBpsTooHigh(9500, 9000)` |
| nearest allowed | | 9000 now, or owner calls `setMinProtocolSkimShareBps(<=500)` first | global knob, frozen per pool at init; cost of 9000 is about minus 0.5 point |
| creator's 0.5 point protocol leg | factory injected `protocolRecipient` | the v2 ProtocolFeeController, not the creator | owner calls `setProtocolRecipient(creator)` before launch, then restores |
| maxReferralBps 0 | `fee.maxReferralBpsOfVolume` | cap formula in the factory | works |
| lpFee 0 | `fee.lpFee` | needs >= `minLpFee` (mainnet 3000) | breaks. nearest 3000, or owner `setMinLpFee(0)` temporarily. see section 6 |
| protocol bps 0 | `deployTokenAsOwner(c, 0)` | owner only, range 0 to 3000, public default 2000; 0 appends no protocol slot | works on the owner path |
| sniper 90000 for 1800 s | `mev.startingSkimBps`, `mev.windowSeconds` | max 90000; window 60 to 10800; module enabled and bound to the hook | works |
| sniperEndBps | none | hook appends the baseline as the end | works |
| tax 15% on 44 venues, Core exempt | `restriction.restricted`, `restriction.allowed` | no tax in v2 | lost: the 15% tax burn and the exempt Core |
| locker rewards to creator | `locker.rewardRecipients`, `rewardBps` | frozen, no reward admins; recipients may not be factory, coin, PM, hook, locker, deployer, escrows, mev module | works |
| tokenAdmin | `token.tokenAdmin` | set directly to the owner, no `lockPoolExtension`, no handover | simpler |
| deployFee 0.069 | `msg.value` | paid even on the owner path; excess refunded | to teamFeeRecipient |
| image, metadata, context, renderer | same names | strings in the config; the config hash folds them in | works |

the factory injects `protocolRecipient`, `referralPayout` (default the escrow, which must have code, hook L561), the protocol locker slot, the allowlist seeds, the D52 floor, `quoteToken` 0, and launcher = factory.

### 5.2 predictToken

`predictToken(sender, c)` (factory L236 to 252): CREATE2 from the deployer, salt `keccak256(abi.encode(sender, keccak256(abi.encode(c))))`, init code `type(ArtCoinsTokenV2).creationCode` plus constructor args. it is a view that depends on mutable owner state (`tokenDeployer`, `defaultAllowed`, the hook escrow), so recompute right before broadcast. msg.sender must equal `sender`.

it replaces: `script/data/ArtCoinsToken.creation.hex`, `Builder.predictCoin`, `coinInitcode`, `buildTaxConfig`, and the creation code hash in the engine `configHash`.

### 5.3 deploy order

| step | action | note |
|---|---|---|
| 1 | v2 stack exists (escrow, hook, locker, mev, factory, tokenDeployer) | the Core constructor needs code at hook, factory, locker, escrow and auctionFactory |
| 2 | deploy FeeRouter | its address fixes the coin address |
| 3 | `factory.predictToken(owner, c)` with `fee.bountyRecipient = router` | |
| 4 | deploy controller, then Core with `coin_ = predicted` | constructor needs only nonzero `coin_`, not code |
| 5 | `factory.deployTokenAsOwner(c, 0)` with deploy fee | owner key signs |
| 6 | assert returned token == predicted | |
| 7 | `router.setEngine(core)`, then lock | one way |
| 8 | postflight | |

without a router: Core first, then predict with bounty recipient = Core, same order minus steps 2 and 7. only the factory owner can launch, so the owner key signs everything and the "owner or creator is the factory owner" warning applies. resume stages collapse, since there is no extension lock and no handover.

## 6. new income: the lp fee

v1 ran lpFee 0. v2 floors it at `minLpFee` (3000 on mainnet), so 0.3% of volume accrues to the locked liquidity as a new stream, unless the owner lowers the floor.

| item | fact | source |
|---|---|---|
| collector | `ArtCoinsLpLockerV2.collectRewards`, permissionless | `lp-lockers/ArtCoinsLpLockerV2.sol` L274 to 309 |
| currencies | both: eth and coin (the LP fee is charged on the input side) | same |
| eth push | `FeeDelivery.sendNative(escrow, to, amount, PUSH_GAS)`, `PUSH_GAS = 150k` (L55), msg.sender = locker | L301 |
| coin push | ERC20 `transfer` with all gas via `sendErc20`, escrow fallback. the locker is allowlisted and pinned, so coin passes under restriction | |
| keeper reward | 0 bps | |
| slots | frozen at launch | |
| bad recipients | factory, coin, PM, hook, locker, deployer, escrows, mev module | factory `_checkRecipients` L502 to 524 |

note the 150k push is generous: a Core receive that books (est 15k gas) would succeed from the locker, but `msg.sender` is the locker, not the hook, so it would be refused by the gate or, with an ungated receive, booked as fees.

| option | how | eth | coin | cost |
|---|---|---|---|---|
| A. creator EOA | recipient = owner wallet | to the owner, outside the engine | to the owner (restricted: the owner is subject to the rule, but the locker is allowlisted so receipt works) | none; the engine earns nothing from it |
| B. FeeAutoSwapperV2 to router | recipient = swapper, `endRecipient` = router | eth pushed at `END_RECIPIENT_GAS` 500k (`FeeAutoSwapperV2.sol` L61), then router flush | `convert` sells coin through the pool and pays skim, which returns through the router | swapper must be an escrow depositor (`addDepositor(swapper,false)`), `setup(coin)` by its deployer, `selfClaimOnly`; keepers needed |
| C. Core direct | recipient = Core | unbooked unless the Core accepts the locker as a fee source | coin stuck | optional `burnHeld()` about 80 to 120 bytes (est), plus a second accepted sender, which breaks the single source gate |

recommendation: A for the first launch (no engine change), B as a follow up if the owner wants lp fee income routed to the pot. avoid C.

## 7. forbidden target list and stack immutables

| immutable or entry | v2 address | forbid | reason |
|---|---|---|---|
| `HOOK` | ArtCoinsHookV2 | yes | PM callbacks, already forbidden |
| factory | ArtCoinsFactoryV2 | yes | unchanged |
| locker | ArtCoinsLpLockerV2 | yes | unchanged |
| escrow | ArtCoinsFeeEscrowV2 | yes, critical | the Core is a fee owner there; a call as the Core to `claimTo` or `setSelfClaimOnly` would be abusable |
| tokenDeployer, keeper, controller, burnRouter, allowlist, mev module, swapper | | optional | they grant the Core no special rights; belt and braces |
| FeeRouter | | optional, with C1 | stops a seller call from being routed through it |
| `PoolManager`, `auctionFactory`, Seaport | unchanged | as today | |

Stack struct change (`engine:src/interfaces/Interfaces.sol` L173): add `feeSource` (router). `Mainnet` library (L185) and `defaultStack` (L255) take the new v2 addresses after deploy. v1 constants at L200 to 205 are removed. the hook has no `factory()` or `feeEscrow()` getters, so the engine's `_preStack` reads (`Checks.sol` L287) switch to `globals().feeEscrow` and `isLauncher`.

## 8. tests

### 8.1 how v2 deploys its stack on a fork

| item | fact |
|---|---|
| lib | `DeployV2Lib.deploy(p)` (`script/v2/DeployV2Lib.sol` L139 to 169), shared by `DeployV2Stack.s.sol` and the harness `ForkStack.deployV2Stack` (`test/v2/harness/ForkStack.sol` L386 to 408, under `vm.startPrank(broadcaster)`) |
| hook | mined by CREATE2 via deployer 0x4e59... for flags 0x28CC, up to 400k iterations |
| order | escrow, allowlist, hook, locker, mev, factory, tokenDeployer (`setTokenDeployer`), burnRouter, controller, keeper, wiring, ownership |
| engine minimum | escrow, hook, locker, mev, factory, tokenDeployer. allowlist may be 0, protocol recipient any nonzero address, referral payout = escrow |
| fork pin | v2 uses block 26130269, engine uses 26127622 |

### 8.2 toolchain

| item | v2 | engine |
|---|---|---|
| solc | 0.8.26, cancun | 0.8.30, cancun |
| optimizer | via_ir; default runs 20000, ci/tune runs 200; the stack ships from `FOUNDRY_PROFILE=ci`; the deployer exceeds EIP-170 at the default profile | via_ir, runs 200 |
| OpenZeppelin | needs `ReentrancyGuardTransient` (5.1 or later) | 5.0.2 nested in v4 libs, missing it |
| imports | `src/v2` imports v1 tree files (`src/hooks/interfaces/IArtCoinsPoolExtension*.sol`, `src/interfaces/IMetadataRenderer.sol`, `src/hooks/ArtCoinsPoolExtensionAllowlist.sol`, `IArtCoinsLpLocker`, `IArtCoinsFeeLocker`) | not present |
| libs | submodules empty on this disk; `foundry.lock` pins different v4-core and v4-periphery revs | own revs |
| compile cost | about 14 GB cold (HANDOFF) | |
| solady | 0.1.26 | 0.1.26 |

### 8.3 can the engine use prebuilt artifacts

yes, and it is the recommendation. compiling the v2 sources inside the engine would need an OZ bump, the v1 import tree, matching v4 revs and 14 GB. precedent already exists: `script/data/ArtCoinsToken.creation.hex`, `test/data/*.creation.hex`, and the Fixture uses `deployCode` for Core and Controller.

plan:
1. build the v2 stack once in the v2 repo with the ci profile, export creation bytecode for escrow, hook, locker, mev, factory, tokenDeployer into engine `test/data/`.
2. load them with `deployCode` in a new `test/utils/V2Stack.sol`.
3. mine the hook salt with v4-periphery `HookMiner` (present in the engine), flags 0x28CC, deployer 0x4e59....
4. make the Stack data: fork deployed v2 addresses differ from the future mainnet addresses.
5. record the v2 commit and the artifact hashes in a data manifest, so a rebuild is detectable.

no prebuilt artifacts exist on this machine (no `foundry-out` in the v2 repo), so step 1 needs a machine that can build v2.

## 9. work list

### 9.1 by group

| group | file | change | size |
|---|---|---|---|
| Core | `src/Core.sol` | `receive()` L356 to 364 gate, new immutable, constructor L295, `_forbiddenBase` L685, dead `notify` L368, comments at L37, L230, L350 to 355, L1007 to 1033 | small, 0 to +90 bytes (est) |
| Core | `src/interfaces/Interfaces.sol` | `Stack` L173, `Mainnet` L185, `defaultStack` L255, v1 constants L200 to 205 | small |
| Core | `src/interfaces/ArtCoins.sol` | v1 copies, rewrite to the v2 ABI (factory, hook, token, locker, escrow) | medium |
| Core | `src/FeeRouter.sol` (new) | receive, flush, setEngine, lock | small, about 40 lines |
| Core | `src/lib/CoreLib.sol`, `src/ControllerV1.sol` | none | none |
| controller | none expected | the controller only calls the Core | none |
| scripts | `script/Builder.sol` | large rewrite: `buildConfig`, drop tax config and the 44 venues, prediction via `predictToken` | large |
| scripts | `script/LaunchConfig.sol` | tax fields L40, L41, L85, L86, L184, L185; `tokenCodeFile`; add restriction, mev, router; overrides | medium |
| scripts | `script/Checks.sol` | `PIN_BOUNTY_BPS` L28, `PIN_TAX_BPS_MAX` L29, `_ruleTax` L196, `_preFactory` L249 (`enabledLockers(locker,hook)`, `admins`, `deprecated`), `_preStack` L287 (hook `factory()`, `feeEscrow()`, locker `factory()`), `_prePredictions` L320 | large |
| scripts | `script/Deploy.s.sol` | `deployTokenWithProtocolBpsAndTax` becomes `deployTokenAsOwner`; remove `_lock` and `_handover`; add router deploy, `setEngine`, lock | large |
| scripts | `script/PostflightChecks.sol` (542 lines) | coin, hook, tax, locker, mev checks; drop `poolCreationTimestamp`, `rewardAdmins`; add restriction, router checks | large |
| scripts | `Postflight.s.sol`, `Resume.s.sol`, `Preflight.s.sol`, `Report.sol` | `admins` check, stage detection via `poolExtensionLocked`, report fields | medium |
| config | `script/config/mainnet.json`, `script/data/ArtCoinsToken.creation.hex` | new fields (restriction, router, bounty, lpFee, mev), remove hex | small |
| tests | see 9.2 | | large |
| docs | `docs/DEPLOY.md` (52 refs), `ARCHITECTURE.md` (34 refs), `FLOW.md`, `README.md`, `SPEC` | rewrite launch steps, factory admin, tax; section 4 fee intake mentions `streamForward`; buyback text "exempt from the tax"; accepted items 9, 11, 14, 26 | medium |
| docs | `docs/reference/artcoins-notes.md` | stays as the v1 record | none |
| sim | `sim/engine.js`, `sim/index.html` | a few refs | small |

### 9.2 tests (v1 specific reference counts)

| file | refs | action |
|---|---|---|
| `test/Launch.t.sol` | 50 | rewrite for `deployTokenAsOwner` |
| `test/Fees.t.sol` (1676 lines) | 48 | rewrite delivery tests (stipend, escrow, skim, router) |
| ReviewDeploy | 24 | rework |
| ReviewMatrix | 20 | rework |
| CoreUnit | 16 | update stack |
| invariant/HandlerBase | 13 | update |
| `test/utils/Fixture.sol` | 11 | `setAdmin`, `PoolSwapData` attribution structs, `deploySystem`: rebuild on `V2Stack` |
| ReviewPort | 10 | rework |
| GasCap | 10 | rework (stipend) |
| Resume | 9 | stages collapse |
| Config | 6 | new fields |
| Invariants 5, Lifecycle 5, Rehearsal 4, ReviewHarness 2, others 1 each | | touch up |
| new | | FeeRouter, restricted coin paths (take exact allowance, leftover with allowlisted Core, donation revert), v2 delivery (stipend push to Core fails into escrow, `claim` then `skim`), partial fill refund, mid call claim DoS, launch field limits (bounty 9000, lpFee 3000) |

### 9.3 before and after the v2 mainnet deployment

| before v2 deploys | after v2 deploys |
|---|---|
| Core change C1 and size measurement | mainnet stack addresses in `Stack` and config |
| FeeRouter and its tests | real `predictToken` result and the signoff hash |
| artifact loader and tests on the fork stack | owner knobs set (`setMinProtocolSkimShareBps`, `setMinLpFee`, `setProtocolRecipient`) |
| Builder, Checks, Deploy, Postflight rewrite | deploy, postflight, `setEngine` and lock |
| docs rewrite | final doc numbers |

## 10. open questions

### 10.1 for the owner

| # | question |
|---|---|
| 1 | restricted flag yes or no, and the lock or `unrestrict` policy. who is the coin admin |
| 2 | bounty 9500 or 9000, and may the factory owner lower the global `minProtocolSkimShareBps` |
| 3 | where does the protocol leg go: controller or treasury, or the creator via `setProtocolRecipient` |
| 4 | lpFee 0 (needs temporary `setMinLpFee(0)`) or 0.3% income, and which recipient takes it: creator, swapper to router, or Core plus `burnHeld` |
| 5 | protocol locker slot 0 (owner path) or the 2000 default |
| 6 | router setter trust against FLOW decision 8: accept set once then lock, or hardcode the engine by deploying the router after the Core (which breaks the prediction order) |
| 7 | the factory owner key must sign the launch; is that the engine owner key |
| 8 | launch timing: audit pending, D75 merge to master first |
| 9 | deploy fee 0.069 goes to teamFeeRecipient, which is the owner; acceptable |
| 10 | take C1 (keeps `feeToBuybackBps`) or the no change `skim()` path (100% to the pot) |

### 10.2 for the v2 developer

| # | question |
|---|---|
| 1 | D73 text lists seeded routers; the source seeds none. which is intended |
| 2 | update CREDITS-ENGINE-INTERFACE.md (section 11) |
| 3 | an allowlisted contract taking coin from the PM leaves unconsumed transient allowance; `example-restricted.json` L3 suggests listing a fee swapper or burn router, which would leak |
| 4 | per launch overrides for `minProtocolSkimShareBps`, `minLpFee`, `protocolRecipient` instead of global mutable knobs |
| 5 | `predictToken` depends on mutable owner state; can the factory expose a snapshot or hash |
| 6 | no code check on the bounty recipient: intended |
| 7 | the hook keeps granting allowance after `unrestrict` |
| 8 | `pushGas` in globals is not used for the push (`_PUSH_GAS = 0`); remove or wire it |
| 9 | a reason the hook has no `factory()` and `feeEscrow()` getters; can they be added for checks |
| 10 | will a prebuilt artifact set (creation bytecode plus hook salt) be published per release |

## 11. stale statements in `docs/v2/CREDITS-ENGINE-INTERFACE.md`

the file predates D73 (tax modes retired for the `restricted` flag). trust source and DECISIONS.md.

| lines | statement | status |
|---|---|---|
| 3 | sources list D10, D46, D47, D42/D51 | stale: tax decisions, D42/D51 superseded by D58 |
| 16 | tax sink row | stale |
| 21 | D46 liquidity on a taxed pool | stale |
| 22 | D47 exempt row | stale |
| 23 | skim refund inside the swap through the afterSwap return delta | wrong: D58, refund goes to the escrow (hook L388 to 397) |
| 60 | `tax.taxSink` | stale |
| 66 | `setExemptAllowed` | does not exist in the factory |
| 67 | tax sink as treasury | stale |
| 73 to 109 | example uses `c.tax`, `TaxConfigV2`, `Constants.TAX_MODE_VENUE` | none exist; `DeploymentConfigV2` has `restriction` (RestrictionConfigV2) and no `tax` |
| 109 | taxBps raisable | stale |
| 115 | confirm bounty recipient and sink | stale |
| 117 | normal refunds ride the return delta and emit nothing here | wrong: all refunds go through the escrow and emit `SkimRefunded` |
| 146 | `setExemptAllowed` | does not exist |
| 149 | D46 canonical pool locker only liquidity | stale |

confirmed correct: the stipend push, escrow fallback, `FeeDelivered` event, locker 150k, swapper 500k, `bountyBps` cap, referral cap formula, `lpFee` minimum, keeper gas floors (900k, 150k, 400k).

similar stale text elsewhere: `RUNBOOK.md` 2b rows 1 and 2 (`setExemptAllowed`, tax venues and sink) and L262, `DESIGN.md` section 7 (tax proceeds row), D73's text on allowlist seeding against the source, and `Constants.sol` L38 to 44 (`STREAM_GAS_*` for a probe the hook no longer has).
