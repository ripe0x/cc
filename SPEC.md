# credits engine: build spec v1

this is the original handoff spec. the branch `flow` is the current implementation and docs/ARCHITECTURE.md lists what differs. superseded by docs/FLOW.md section 9: the timelock, the queue and the freeze action no longer exist, owner actions work at once with three one way locks and a two step owner handover. sections 8 and 9 below carry a note at each spot.

## 0. what this is

an erc20 on ethereum mainnet whose swap fees buy Credits nfts, compose them into Statements, and exit each statement one of two ways: sold at a falling price auction for eth, or handed to an exit module for an exit token. proceeds buy and burn the coin and refill the buying.

it launches in phase 1 with the exit module slot empty. phase 2 begins when the owner fills that slot.

### naming rule

in all code, comments, tests, commit messages, and docs use only the neutral names `exitModule` and `exitToken`. never name, guess at, or describe what they are.

### build environment

* foundry, solidity 0.8.28 or later, mainnet fork tests
* solady for ERC20, SafeTransferLib, ReentrancyGuard, FixedPointMathLib
* uniswap v4 core and a v4 router, same versions tokenworks uses
* no proxies. every contract is immutable. the only mutability is the slots listed in section 9

## 1. external contracts and verified facts

everything in this section was read from chain or tested on a mainnet fork on 2026 10 05.

| name | address | notes |
|---|---|---|
| Credits | 0x97630aA70AB14ed9883B41dAfccBc11349723043 | erc721, verified source, sealed, 122,154 minted |
| Statements | 0x75edd94b7e49b3bd5c8047b91f165a5e265a069b | erc721, source NOT verified. interface below confirmed against bytecode selectors |
| CreditScore | 0x817a9cffb4d6e7c206e745a4229001a472c1b7b7 | returned by Statements.score() |
| CreditStrategy (CREDITSTR) | 0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6 | tokenworks strategy, holds about 13,125 credits |
| Seaport 1.6 | 0x0000000000000068F116a894984e2DB1123eB395 | opensea orders |

### Credits

```solidity
function seedOf(uint256 id) external view returns (bytes21);
function timestampOf(uint256 id) external view returns (uint64);
function tokensOf(address owner) external view returns (uint256[] memory);
function setApprovalForAll(address operator, bool approved) external;
function burn(address owner, uint256[] calldata ids) external returns (bytes21[] memory); // owner or approved operator
```

seeds and timestamps stay readable after a credit is burned.

### CreditScore

```solidity
function scoreOf(bytes21 seed, uint64 paidAt) external pure returns (uint256); // 1e4 scale. 800.0000 returns 8_000_000
function traitsOf(bytes21 seed, uint64 paidAt) external pure returns (uint256 mask, uint256 active, uint256 occupied, uint256 eights, uint256 band);
```

score range is 800_000 to 8_000_000 (80 to 800). a credit's score is `scoreOf(Credits.seedOf(id), Credits.timestampOf(id))`. about 30k gas per read.

### Statements

```solidity
function compose(uint256[80] calldata creditIds, uint8 format) external returns (uint256 statementId);
function compose(uint256[80] calldata creditIds, uint8 format, address to) external returns (uint256 statementId);
function overprint(uint256 baseId, uint256 topId) external;
function creditScoreOf(uint256 statementId) external view returns (uint256); // the statement's rating, 1e4 scale, sum of its credits' scores
function creditsOf(uint256 statementId) external view returns (uint256);     // count of credits inside
function overprintsOf(uint256 statementId) external view returns (uint256);
function supply() external view returns (uint256);                          // last minted id
function setFormat(uint256 statementId, uint8 format) external;
```

fork tested behavior:

| behavior | result |
|---|---|
| caller must hold all 80 credits and have approved Statements for all on Credits | confirmed |
| compose gas | 8.2m to 8.4m per call. it must be its own transaction |
| mint is a safe mint | composing to a contract with no erc721 receiver reverts. the core MUST implement onERC721Received |
| valid formats | 0 to 7. format 8 reverts |
| duplicate credit id in the array | reverts |
| new statement id | equals supply() after the call |
| overprint gas | about 1.4m |
| overprint requires | caller owns both. top is destroyed, base keeps its id |
| rating after overprint | exact sum of both ratings |
| overprint count | NOT capped. an eighth overprint succeeds. INVERTED_AT is 7 and only affects rendering |
| burn function | none exists. a statement leaves circulation only by overprint or by transfer |

### CreditStrategy

```solidity
function nftForSale(uint256 tokenId) external view returns (uint256 price); // 0 if not for sale
function sellTargetNFT(uint256 tokenId) external payable;                   // msg.value must equal price exactly. transfers the credit to msg.sender
```

it is an upgradeable proxy. treat every call to it as untrusted and verify outcomes.

## 2. contracts to build

| contract | role | mutable? |
|---|---|---|
| `Coin` | erc20, fixed supply, restricted transfers | no |
| `FeeHook` | uniswap v4 hook on the coin/eth pool. takes the swap fee in eth | no |
| `Core` | custody and every rule in this spec | only the slots in section 9 |
| `ControllerV1` | first policy module | replaceable |
| `MockExitModule`, `MockExitToken` | test doubles for phase 2 | tests only |

the controller holds no funds and has no privileged calls. the core reads the controller's answers and enforces every limit itself.

## 3. parameters

all are immutable constants in the core unless marked.

| name | default | meaning |
|---|---|---|
| `SUPPLY` | 1_000_000_000e18 | coin supply, minted once |
| `AVG_SCORE` | 4_330_000 | 433 in 1e4 scale. used for "can the pot afford one credit" |
| `RATE_START` | 5.6e12 wei per whole point (config default) | starting eth rate, a deploy input in [1e11, 1e15]. launch day rule: flat credit price in wei divided by 1600 |
| `CLIMB_BASE_BPS_PER_HOUR` | 100 | 1% an hour |
| `CLIMB_DOUBLE_EVERY` | 24 hours | climb speed doubles for each full period with no fill |
| `CLIMB_MAX_BPS_PER_HOUR` | 800 | ceiling on climb speed |
| `DROP_BPS` | 1000 (config default) | rate falls 10% if a whole pot is spent, scaled by share spent. a deploy input in [1000, 4000] |
| `SPEND_CAP_BPS_PER_HOUR` | 2000 | at most 20% of the eth pot may be spent in any rolling hour |
| `BONUS_CAP_BPS` | 2500 | max extra the controller may add to the rate for a preferred credit |
| `TIP_SAVINGS_BPS` | 1000 | caller of buyListing gets 10% of the savings |
| `TIP_CAP_BPS` | 200 | tip never above 2% of the cost |
| `AUCTION_START_X` | 40_000 bps, 4x cost (config default) | auction opening price. a deploy input in [15_000, 40_000] |
| `AUCTION_FLOOR_X` | 12_000 bps, 1.2x cost (config default) | auction floor. a deploy input in [6_000, 12_000], strictly below the start |
| `INVENTORY_GATE` | 0, off (config default) | a count of eth lane statements held for sale. a deploy input, 0 or [5, 200]. while the core holds this many or more, the eth bid is closed and the rate does not climb |
| `AUCTION_LENGTH` | 72 hours | linear fall from start to floor, then flat at floor |
| `SALE_SPLIT` | 50 / 50 | eth sale proceeds: coin buyback / eth pot |
| `EXIT_SPLIT` | 50 / 50 | exit token from an unsold statement: coin buyback / exit token bid pot |
| `BUYBACK_SLICE` | 1 ether | max eth per buyback call |
| `BUYBACK_DELAY` | 25 blocks | min gap between buyback calls |
| `KEEPER_TIP_BPS` | 50 | 0.5% tip on buyback slices |
| `XRATE_START / CAP / FLOOR` | 60 / 97 / 30 | exit token bid, percent of score |
| `XRATE_CLIMB_PER_HOUR` | 1 point | while funded |
| `XRATE_DROP_PER_CREDIT` | 0.2 point | fixed, per credit bought |
| `TIMELOCK` | removed | superseded by docs/FLOW.md section 9: there is no timelock and no queue, owner actions work at once |
| `OVERPRINT_CAP_PER_DAY` | 8 | core limit on overprints requested by a controller |

## 4. coin and fee

* `Coin` mints `SUPPLY` once at deploy. no mint function after.
* transfers are restricted the way tokenworks does it: a transfer is allowed only when it is to or from the v4 pool manager with a transient allowance set by `FeeHook` in the same transaction, or when either side is on a fixed allowlist (the core, the dead address, and the second pool added in phase 2). every other transfer reverts. this exists so the fee cannot be dodged through a side pool. mirror `BaseStrategy._afterTokenTransfer` from tokenworks (MIT).
* `FeeHook` charges `FEE_BPS` on every swap in the coin/eth pool, taken in eth. it forwards `CREATOR_BPS` worth to the creator address and the rest to `Core.addFees()`.
* `Core.addFees()` is callable only by the hook. it adds to `ethPot`.
* launch config: mirror the tokenworks strategy launch (whole supply placed single sided in the pool, no team allocation). this is open item 3.

## 5. buying credits

### 5.1 the eth rate

`ethRate` is wei per whole point. the price ceiling for credit `id` is:

```
ceiling(id) = score(id) * ethRate * (10_000 + bonusBps(id)) / 10_000 / 1e4
```

`bonusBps` comes from `controller.wants(id)` and is clamped to `BONUS_CAP_BPS` by the core.

rate dynamics, computed lazily from a checkpoint (`rateAtCheckpoint`, `checkpointTime`, `lastFillTime`, `funded`):

* climbing happens only while `funded`, where funded means the hourly cap affords one average credit: `ethPot * 2000 >= AVG_SCORE * ethRate`, that is `AVG_SCORE * ethRate / 1e4 <= 20 percent of ethPot`. the climb is clamped to `ethPot * 2000 / AVG_SCORE`.
* hourly climb speed is `CLIMB_BASE_BPS_PER_HOUR * 2^(floor((now - lastFillTime) / CLIMB_DOUBLE_EVERY))`, capped at `CLIMB_MAX_BPS_PER_HOUR`. compound continuously within each segment using a wad pow.
* every function that changes `ethPot` first calls `_checkpoint()`, which applies the climb earned under the old funded state and then recomputes `funded`.
* on a fill that spends `x` from a pot of `p` (pot measured before the spend): `ethRate = ethRate * (1 - DROP_BPS/10_000 * min(1, x/p))`, and `lastFillTime = now`.
* the rate never climbs while unfunded. this is the main lesson from CREDITSTR, whose cap outran the market.
* the rate never climbs while gated either. gated means `INVENTORY_GATE != 0` and the core holds at least that many eth lane statements for sale (`ethHeld`). `sellForEth` and `buyListing` revert while gated. the counter changes on compose (+1), statement sale (-1), exit of an eth lane statement (-1) and overprint of eth lane statements (-1), and each change that crosses the gate checkpoints the rate first, like a change of the funded flag. nothing else is gated.

### 5.2 the hourly spend cap

track a rolling one hour window. total eth spent on buys in the window may not exceed `SPEND_CAP_BPS_PER_HOUR` of the pot as it stood when the window opened. a buy that would exceed it reverts.

### 5.3 door one: sell into the bid

```solidity
function sellForEth(uint256[] calldata ids) external nonReentrant;
```

for each id: caller must own it and have approved the core. pay `ceiling(id)` with zero bonus unless the controller wants it. transfer the credit in, record `costOf[id]`, push to the eth pile, apply the drop per credit.

### 5.4 door two: take a listing

```solidity
function buyListing(uint256 value, bytes calldata data, uint256 id, address target) external nonReentrant;
```

this is tokenworks' `buyTargetNFT` with a per point ceiling. checks, in order:

1. `allowedTarget[target]` is true. launch allowlist: Seaport 1.6 and CreditStrategy. the Credits contract and the core itself may never be targets.
2. the core does not already own `id`.
3. `value <= ethPot`, `value <= ceiling(id)`, and the hourly cap allows it.
4. record eth balance and credit balance, then `target.call{value: value}(data)`. require success.
5. require the core's Credits balance rose by exactly one and `ownerOf(id) == core`.
6. `cost = ethBefore - ethAfter`. require `cost <= value`.
7. tip the caller `min(TIP_SAVINGS_BPS of (ceiling - cost), TIP_CAP_BPS of cost)` from the pot. `costOf[id] = cost + tip`.
8. deduct from `ethPot`, push to the eth pile, apply the drop.

notes for the builder:

* a CreditStrategy purchase is `target = CreditStrategy`, `data = sellTargetNFT(id)`, `value = nftForSale(id)`.
* opensea orders usually need a server signature in the order's extra data. the caller supplies the complete Seaport calldata. write a fork test that fulfills a real listing through this door.
* the tip must never make it profitable to list your own credit cheap and call the door yourself. with the two caps above the tip is always under 2% of what you gave up. add a test that proves it.

## 6. composing

```solidity
function compose() external nonReentrant; // anyone
```

* calls `controller.nextPage(Lane.Eth)` which returns 80 ids and a format, or signals not ready.
* core checks every id is in the eth pile and owned by the core, format is 0 to 7, no duplicates.
* core calls `Statements.compose(ids, format)`. the statement mints to the core.
* `statementCost[sid] = sum of costOf[ids]`. record `composedAt`.
* reimburse the caller for gas from `ethPot`: `min(gasUsed * block.basefee * 110%, 5% of statementCost)`. add the reimbursement to `statementCost`.
* the core approves Statements for all on Credits once, in the constructor.

compose costs about 8.3m gas. nothing else may share that transaction.

## 7. exits

### 7.1 auction

every eth lane statement is for sale from the moment it is composed.

```
price(t) = cost * AUCTION_START_X, falling linearly to cost * AUCTION_FLOOR_X over AUCTION_LENGTH, then flat
```

```solidity
function buyStatement(uint256 sid) external payable nonReentrant;
function priceOf(uint256 sid) external view returns (uint256);
```

require `msg.value >= price`, refund the excess, transfer the statement to the buyer. split the price by `SALE_SPLIT`: half to `ethToBuyback`, half to `ethPot`.

in phase 1 a statement that reaches the floor simply stays listed at the floor.

### 7.2 exit through the module (phase 2 only)

```solidity
interface IExitModule {
    function exitToken() external view returns (address);
    function unitPerPoint() external view returns (uint256);            // exit token base units per 1e4 scaled score point
    function exit(uint256 statementId) external returns (uint256 out);  // called by core after it transfers the statement to the module
}

function exitStatement(uint256 sid) external nonReentrant; // anyone
```

allowed when the module is set and the statement's auction has run its full length (eth lane), or immediately (exit token lane). the core:

1. reads `rating = Statements.creditScoreOf(sid)`.
2. records its exit token balance, transfers the statement to the module, calls `exit(sid)`.
3. requires its exit token balance rose by at least `rating * unitPerPoint`. this check is the whole safety story for the module. no module can take a statement and return less.
4. eth lane statement: split by `EXIT_SPLIT`, half to `xToBuyback`, half to `xPot`. exit token lane statement: all of it back to `xPot`.

### 7.3 overprint

the controller may request `overprint(base, top)` for two statements the core holds. the core enforces `OVERPRINT_CAP_PER_DAY`, sums the two cost bases onto the base, and restarts the base's auction clock. ControllerV1 never requests it.

## 8. buybacks and the exit token bid

### 8.1 eth buyback

copy tokenworks' `processTokenTwap`: anyone calls `buyback()`, at most once per `BUYBACK_DELAY` blocks, spending up to `BUYBACK_SLICE` from `ethToBuyback`, tipping the caller `KEEPER_TIP_BPS`, swapping eth for the coin in the hooked pool and sending the coin to the dead address.

### 8.2 exit token buyback (phase 2)

same shape, spending `xToBuyback` through a coin/exitToken pool whose key is set once by the owner (superseded by docs/FLOW.md section 9: at once, no timelock). dormant until set.

### 8.3 exit token bid (phase 2)

```solidity
function sellForExitToken(uint256[] calldata ids) external nonReentrant;
```

* pays `score(id) * xRate / 100 * unitPerPoint` from `xPot`.
* `xRate` starts at `XRATE_START`, climbs `XRATE_CLIMB_PER_HOUR` while `xPot` can afford one average credit, never above `XRATE_CAP`, and falls `XRATE_DROP_PER_CREDIT` per credit bought, never below `XRATE_FLOOR`.
* credits go to a separate exit token pile. at 80 the controller composes them (`Lane.Exit`) and the statement may be exited at once with no auction.
* the fixed per credit drop is deliberate. a drop scaled to the pot does not work here because the pot is large relative to flow. the simulation showed the rate pinned at the cap.

## 9. owner powers

superseded by docs/FLOW.md section 9 (no timelock, no queue, no freeze). the old rule, kept out of this file on purpose: it no longer holds.

the owner is a multisig address. every action works at once and emits an event.

| action | limit |
|---|---|
| set controller | at once, until `lockController` |
| set exit module | at once, any number of times, until `lockExitModule`. the exitToken never changes once set |
| add an allowed target | at once, until `lockTargets`. removal always works |
| transfer ownership | two step: `transferOwnership`, then `acceptOwnership` by the new owner |

there are no other owner functions. the owner cannot move eth, credits, statements, coin, or exit token, cannot change any parameter in section 3, and cannot pause.

```solidity
enum Lane { Eth, Exit }
interface IController {
    function wants(uint256 creditId) external view returns (uint16 bonusBps);
    function nextPage(Lane lane) external view returns (bool ready, uint256[80] memory ids, uint8 format);
    function nextOverprint() external view returns (bool ready, uint256 baseId, uint256 topId);
}
```

`ControllerV1`: `wants` returns 0. `nextPage` returns the 80 oldest credits in the lane's pile with format 0. `nextOverprint` returns not ready.

the core must expose the piles and per credit data as views so later controllers can sort by trait.

## 10. invariants

write each as a fuzz or invariant test.

1. eth leaves the core only as: a buy that returned a credit within its ceiling, a capped tip, a capped gas reimbursement, a buyback slice, or a refund of overpayment.
2. no credit is bought above `score * ethRate * (1 + BONUS_CAP)`.
3. no statement is sold below `AUCTION_FLOOR_X` of its cost (`statementCost * AUCTION_FLOOR_X / 10_000`, 1.2x at the default).
4. a statement leaves the core only by sale at or above price, by exit that returned at least `rating * unitPerPoint`, or by being the top of an overprint.
5. `ethPot + ethToBuyback` never exceeds the core's eth balance. same for the exit token pots.
6. the rate does not rise in any interval where the pot was unfunded or the core was gated.
7. hourly eth spend never exceeds the cap.
8. the controller address has no path to move any asset.
9. coin total supply never increases.

## 11. tests on a mainnet fork

pin a block. composing through a public rpc fork is slow, so cache state.

* buy through `sellForEth`, through Seaport, and through CreditStrategy
* compose from the core and confirm the statement id, cost basis, and gas refund
* auction price curve, sale, split, refund of excess
* phase 2 with the mocks: exit, the received amount check, the splits, the exit token bid, the exit token lane compounding
* a hostile exit module that returns too little must revert
* a hostile target that takes eth and returns no credit must revert
* a CreditStrategy call that fails must revert only that buy
* rate behavior: slow climb, acceleration when unfilled, pause when unfunded, drop on fill, hourly cap
* the self dealing tip test from 5.4
* every invariant in section 10

## 12. reuse from tokenworks

their `BaseStrategy.sol` and `NFTStrategy.sol` are MIT and verified at implementation 0xdF9FEC9Ac40dd7F0911d139327B7b4a6dE9713A5.

| reuse | do not reuse |
|---|---|
| transfer restriction with transient allowance | the per piece price cap and `buyIncrement` |
| fee intake from the hook as its own counter | owner settable buy speed |
| `buyTargetNFT` check sequence | fixed 1.2x relist with no fallback |
| twap buyback with caller tip | the upgradeable proxy |
| reentrancy guards on every external path | |

## 13. out of scope for v1

* redemption of the coin for treasury assets
* a fee schedule that steps down
* any controller beyond ControllerV1
* a front end

## 14. open items

1. the real exit module interface. section 7.2 is our placeholder. the adapter is written later.
2. redemption is left out. confirm.
3. launch config and who seeds. default is to mirror tokenworks.
4. name and ticker.
5. the Statements contract is unverified. behavior in section 1 is from fork tests, not source. rerun those tests before deploy.
6. legal review of the fee, the buyback, and the launch timing.
