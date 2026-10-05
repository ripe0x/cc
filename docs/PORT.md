# port to artcoins: director brief

binding for this branch. where it conflicts with SPEC.md or the old ARCHITECTURE.md, this file wins. facts about the live artcoins stack are in `docs/reference/artcoins-notes.md` (verified on a fork at the pinned block). read that file before touching code.

naming rule: only `exitModule` and `exitToken`. never name or describe them.

## 1. what changes

| piece | before | after |
|---|---|---|
| coin | `src/Coin.sol` | a live `ArtCoinsToken` launched through the real artcoins factory. delete Coin.sol |
| hook | `src/FeeHook.sol` | the live `ArtCoinsHookSkimFee` 0x636c050296B5Cc528D8785169Bf8923716FCa9cc. delete FeeHook.sol |
| launch | `src/Launcher.sol` | `ArtCoinsFactory.deployTokenWithProtocolBpsAndTax` on 0x49596c375c139E79bb937bcf826068a8F78D4e0e. delete Launcher.sol |
| fee dodge defense | transfers revert | the token's venue scoped buy tax, configured like the live 111 coin |
| exit token buyback | swap in a coin/exitToken pool | dutch auction, no pool |
| we own | 5 contracts | `Core`, `ControllerV1` |

## 2. launch config (script and fixture use the same builder)

| field | value |
|---|---|
| entry | `deployTokenWithProtocolBpsAndTax(cfg, 0, tax)` with `msg.value == factory.deployFee()` read live |
| supply | 1_000_000_000e18, no extensions, all of it in the locker |
| pool | hook = skim hook, pairedToken = address(0), tickSpacing 200, `tickIfToken0IsArtCoins = -175000` (about 40M coin per eth, the tokenworks start) |
| positions | one position, `tickLower = -175000`, `tickUpper` = the highest usable tick that is a multiple of 200, `positionBps = 10_000`. if the locker rejects that shape, use the smallest set of positions that covers the same range and report it |
| skim | `baselineSkimBps = 10_000`, `bountyBps = 9500`, `maxReferralBpsOfVolume = 0`, `lpFee = 0`, `bountyRecipient = Core`, `protocolRecipient = creator`, `quoteToken = address(0)` |
| referralPayout | must never brick a swap. verify on the fork that with the cap at 0 a swap that carries a referrer does not revert. if any doubt remains, point it at a contract that implements `notify(address) payable` (the Core may implement it and book the eth as unbooked surplus) |
| anti sniper | `ArtCoinsMevLinearSkim` 0xb038D597365FfD108D63C265Bb0621444a1D8B83 with `(90_000, 10_000, 1800)`. the extra lands in the Core's pot |
| locker | 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab, one reward slot: recipient creator, admin 0xdEaD, 10_000 bps |
| tax | enabled, `taxBps 1500`, `taxBpsMax 2000`, burn address 0xdEaD, poolManager, canonicalHook = skim hook, pairedToken 0, canonicalPoolFee 0x800000, canonicalTickSpacing 200, `exempt = [Core]`, venues = the same 44 entry pattern the 111 coin uses (3 v2 factories and uni v3 plus pancake v3 tiers, each against WETH, USDC, USDT, DAI; exact factories, init code hashes and tiers are in the notes and can be decoded from the 111 launch tx) |
| token admin | the deployer during launch. after launch the script calls `lockPoolExtension` (if that function exists as the notes say) and then `updateAdmin(owner)`. the owner keeps: lower the tax, metadata and renderer, referral cap |

deploy order (no circularity): predict the Core address from the deployer nonce, build the tax config with the Core in `exempt`, predict the coin with CREATE2 (factory as deployer, salt `keccak256(abi.encode(tokenAdmin, userSalt))`, initcode includes the tax config), deploy ControllerV1(core predicted), deploy Core at the predicted address with the predicted coin, launch, assert the returned coin equals the prediction, lock the extension slot, hand over the admin.

the factory is `deprecated` at the pin, so only its owner 0xCB43078C32423F5348Cab5885911C3B5faE217F9 or an address it marks admin can launch. tests do `vm.prank(factoryOwner); factory.setAdmin(deployer, true)` on the real factory. that prank of a real owner action is the only state the tests force on artcoins.

## 3. Core changes

constructor `Core(address owner, address coin, address controller)`. the skim hook, artcoins addresses and the pool tick spacing are constants. pool key for swaps: `(address(0), coin, 0x800000, 200, skimHook)`.

1. fee intake. remove `addFees`, `addExitFees`, `exitPoolId` and the `ICoreFees` interface. `receive()`:
   * from the skim hook while no measurement is in flight: `_checkpoint()`, `ethPot += msg.value`, `_syncFunded()`, emit `FeesAdded`.
   * anything else, or while the `measuring` flag is set: accept and book nothing (skim books it later; during a buyListing measurement the unbooked eth simply lowers the measured cost, which keeps pot and balance consistent).
   * `receive()` must NEVER revert and must stay cheap: the hook pushes with full gas and a revert bricks every swap in the pool. no fallback function. prove with a test that it cannot revert in any state (unfunded, funded, years without a checkpoint, mid buyback, mid buyListing, mid exit).
   * the hook calls `streamForward()` on the recipient in a try/catch once the balance is at least 0.01 eth. with no fallback that call reverts and is caught. add a fork test that swaps keep working with a large Core balance.
2. eth buyback. same slice, delay and tip rules. swap exact in through `PoolManager.unlock`, take the coin to the Core, then `burn` it on the token (real burn, total supply falls). revert when no coin was bought. the skim on the buyback returns to the Core through `receive()` during the guarded call; that is expected.
3. exit token buyback becomes a dutch auction. remove the exit pool key, its limit price, `SetExitPoolKey`, and all exit pool swap code.
   * `buybackExit(uint256 maxCoinIn)`, guarded, phase 2 only. slice = `min(xToBuyback, 20 * AVG_SCORE * unitPerPoint)`.
   * price is coin wei per exit token unit in wad. `price(t) = startPrice * 2^(-(t - startTime) / XAUCTION_HALF_LIFE)` with `XAUCTION_HALF_LIFE = 1 hours`, computed with solady wad math, continuous, never reverting for long gaps (it may reach zero).
   * `coinIn = ceil(slice * price / 1e18)`. require `coinIn <= maxCoinIn`. a `coinIn` of zero is allowed only if price has truly decayed to zero; otherwise round up to at least 1.
   * the Core calls `burnFrom(msg.sender, coinIn)` on the coin, then sends the slice of exit token to the caller. no tip, no block delay.
   * after a fill: `startPrice = 2 * clearing price`, `startTime = now`.
   * the clock only runs while there is something to sell: whenever `xToBuyback` goes from zero to non zero, set `startTime = now` (keep `startPrice`).
   * initial `startPrice` is set when the exit module is set: the price at which one full slice costs the whole coin supply (`SUPPLY * 1e18 / fullSlice`).
   * views: `exitAuctionPrice()` and `exitAuctionQuote()` returning `(slice, coinIn)`.
4. timelock actions are now `SetController`, `SetExitModule`, `AddTarget`, `Freeze`. `removeTarget` stays immediate.
5. forbidden targets: Credits, Statements, the Core, the coin, the skim hook, the pool manager, the artcoins factory, locker and fee escrow, the exit module and exit token.
6. everything else in the Core stays as it is (rate, cap, piles, doors, compose, auction, exit, overprint, skim, views). keep the section 3 parameter constants. keep runtime size under 24,576 bytes and report the margin.

## 4. tests: real contracts only

* Credits, Statements, CreditScore, CreditStrategy, Seaport 1.6, PoolManager, and the whole artcoins stack (factory, token, skim hook, locker, escrow, mev module) are the live contracts on the fork at `FORK_BLOCK`. no stand in for any of them, ever.
* the only stand ins allowed are `MockExitModule` and `MockExitToken` (nothing is deployed for them yet; the spec lists both as test doubles). they live in `test/standins/`.
* attack contracts the spec requires tests for (hostile target, hostile or scripted controllers, probes) are not mocks of real systems. they live in `test/attackers/`.
* delete `test/mocks/` entirely, plus MockCore, MockHook, MockSeller, MockMarket, MockWiring. the self dealing tip test runs on real Seaport orders.
* swaps in tests go through a small unlock based test swapper (a caller, not a stand in) and at least one test buys and sells through the real universal router 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af.

## 5. accepted properties to document, not fix

* the tax is a deterrent, not a wall: wallet to wallet and unlisted venues pay neither skim nor tax; sells are never taxed; the venue list is frozen at launch; the token admin can lower the rate.
* anyone can add liquidity to the canonical pool after the anti sniper window.
* the token admin and the artcoins factory owner exist (powers table in the notes, section 7).
* `receive()` adds gas to every swap in the pool.
