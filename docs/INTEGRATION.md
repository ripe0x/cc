# integration

for integrators and keepers: the contracts, the call sequences of each door, the events, the reverts and the measured gas. the rules behind the numbers are in docs/ARCHITECTURE.md (the bid, the doors, the settings) and docs/FLOW.md (the decisions). the owner commands are in docs/DEPLOY.md.

units. a rate is wei per whole point. a score is on a 1e4 scale, so the price of a credit is `rate * score / 1e4` wei. a `Lane` is 0 for the eth lane and 1 for the exit lane. bps is out of 10,000, ppm out of 1,000,000. settings values quoted below are the launch values of `script/config/mainnet.json`; `core.settings()` returns the live ones.

## 1. contracts and addresses

| contract | address | where to read it |
|---|---|---|
| Credits | 0x97630aA70AB14ed9883B41dAfccBc11349723043 | constant `Mainnet.CREDITS` |
| Statements | 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b | constant `Mainnet.STATEMENTS` |
| CreditScore | 0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7 | constant `Mainnet.CREDIT_SCORE`. `core.scoreOf(id)` reads it |
| CreditStrategy | 0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6 | allowed target of `buyListing` at launch |
| Seaport 1.6 | 0x0000000000000068F116a894984e2DB1123eB395 | allowed target of `buyListing` at launch |
| pnd auction factory | 0x77aB853543286C9Cdd7dd6c01222A7cC4Ac93d63 | creates the house of the Core |
| pool manager | 0x000000000004444c5dc75cB358380D2e3dE08A90 | uniswap v4, holds the coin pool |
| Core | the `core` line of the `Deploy` output | custody and every rule |
| coin | `core.COIN()` | launched through the artcoins v2 factory |
| controller | `core.controller()` | ControllerV1 at launch. the owner can replace it until `lockController` |
| fee router | `core.FEE_SOURCE()` | the bounty recipient of the pool |
| house | `core.HOUSE()` | the auction house of the Core, where statements are listed |
| lens | the `lens` line of the `Deploy` output, or the CREATE2 address derived from the Core | `CoreLens`. `lens.CORE()` names the Core it reads |
| exitModule, exitToken | `core.exitModule()`, `core.exitToken()` | zero until the owner sets them |

the record of a launch is the output of `script/Deploy.s.sol` (core, coin, controller, router, lens), the broadcast file `broadcast/Deploy.s.sol/1/run-latest.json`, and the table that `script/Postflight.s.sol` prints after reading every address back (docs/DEPLOY.md steps 6 and 8). a keeper needs the Core address and reads the rest from it. the lens address is a function of the Core (CREATE2 through the deterministic deployer, salt `keccak256("credits.core.lens.v1")`, the Core as constructor argument), which `Postflight` derives from `CORE`.

## 2. quoting a credit

| question | call |
|---|---|
| the eth a seller receives now for credit `id` | `lens.bidFor(id)` (the Core's `ceilingOf(id)`) |
| the bid per whole point, as the Core reads it | `core.ethRate()` |
| the price state before the clamp of a thin pot | `core.ethPrice()` |
| the payout for one credit of average score | `lens.snapshot().averageBid` |
| the eth the hourly cap still allows | `core.hourlyRoom()` |

a batch sold through `sellForEth` is paid credit by credit. after each credit the rate falls by `dropPerCreditBps` (50, which is 0.5 percent) and stays at or above `dropFloorBps` (8,000) of the price state at the first fill of the current minute, so the total of a batch of `n` credits is below `n * bidFor`. the quote of the first credit is exact for the state of the block the transaction runs in. the pull of fees (section 7) runs first and can raise the pot, which can only raise the read, so the first credit is paid `bidFor(id)` or more. `minOut` is the floor on the total.

## 3. door 1: sell credits for eth

`sellForEth(uint256[] ids)` and `sellForEth(uint256[] ids, uint256 minOut)`. the first form is the second with `minOut` 0.

sequence for a seller:

1. approve the Core once: `Credits.setApprovalForAll(core, true)`, or `Credits.approve(core, id)` per credit.
2. quote with `lens.bidFor(id)` per credit and set `minOut` below the expected total.
3. call `core.sellForEth(ids, minOut)` from the owner of every credit in `ids`.

what the call does, in order:

1. `CoreLib.pullFees(router, msg.sender)`: the Core calls `router.flush(msg.sender)` with at most 1,000,000 gas and ignores the outcome. fee eth reaches `ethPot` before any price is read, and the router pays the flush tip to the caller of the Core.
2. reverts `Empty` for an empty list.
3. for each id: the caller must own the credit (`ZeroId`, `NotOwner`). the price is the ceiling at the current rate. the spend is checked against the pot (`PotTooSmall`, `ZeroAmount`) and the hourly cap (`HourlyCap`). the rate falls. the credit enters the eth pile with the price as its cost basis. `Credits.transferFrom(caller, core, id)`. event `CreditBought(id, caller, 0, price)`.
4. `Slippage` when the total is below `minOut`.
5. the total goes to the caller in one eth transfer, last. a contract caller needs a `receive()` that accepts eth.

what the caller receives: the total payout, and the flush tip when the router held fee eth. the tip is `tipPpm` (5,000 ppm) of the router inflow, at most `tipCap` (0.005 eth) per flush, sent with 50,000 gas. a recipient that refuses it receives nothing (`TipFailed`), the tip goes to the engine with the rest and the sale goes on.

the batch size is bounded by the transaction gas cap: the largest batch under 16,777,216 gas is 112 credits at the launch settings (section 13).

`sellForExitToken(ids)` and `(ids, minOut)` are the phase 2 door (docs/ARCHITECTURE.md section 5).

## 4. door 2: buy a listed credit through an allowed marketplace

`buyListing(uint256 value, bytes data, uint256 id, address target)`. the caller supplies the complete calldata for the marketplace and earns a tip from the savings. the Core pays with its own eth and the credit arrives at the Core.

sequence for a keeper:

1. find a listing of credit `id` on an allowed target: Seaport 1.6 or the CreditStrategy at launch (`core.allowedTarget(target)`).
2. check the room: `price <= lens.bidFor(id)`, `price <= core.ethPot()` and `price <= core.hourlyRoom()`.
3. build the calldata that makes the target deliver `id` to the Core. for Seaport the recipient of the order is the Core. for the CreditStrategy the call is `sellTargetNFT(id)` with `value` equal to `nftForSale(id)`. `test/GasCap.t.sol` runs a basic order, a basic order with a fee recipient, an advanced order and the CreditStrategy.
4. call `core.buyListing(value, data, id, target)`. `value` is the eth the Core forwards, at most the ceiling.

what the call does, in order:

1. the fee pull of section 7, before anything is measured.
2. `TargetNotAllowed` when the target is not allowed or is a forbidden contract. `ZeroId`. `AlreadyOwned` when the Core owns the credit. `PotTooSmall`, `AboveCeiling` (value above `ceilingOf(id)`), `HourlyCap`.
3. the Core calls `target` with `value` and `data`. `CallFailed` when it reverts. during the call the router cannot flush into the Core (`Measuring`), so the pull waits for the next door.
4. the Core checks that exactly one credit arrived and that it is `id` (`NoCredit`), that the eth balance fell (`BadCost`) and that the fall is at most `value` (`BadCost`). the fall is the cost, so a target that refunds part of `value` lowers the cost.
5. the tip is `min(tipSavingsBps * (ceiling - cost) / 10_000, tipCapBps * cost / 10_000)` (1,000 and 200 at launch), paid to the caller last.
6. `cost + tip` is spent from the pot and is the cost basis of the credit. event `ListingBought(id, target, caller, cost, tip, rate)`.

## 5. compose

`compose()` for the eth lane and `composeExit()` for the exit lane. anyone may call. the controller decides the page: `ControllerV1.nextPage(lane)` is ready when the lane pile holds 80 credits and returns the 80 oldest with format 0. `lens.snapshot().ethPageReady` reports it.

what the call does:

1. the fee pull of section 7.
2. `NotReady` when the controller reports no page. `BadFormat` for a format above 7.
3. the 80 credits leave the pile (`NotInPile`, `NotHeld`) and go to `Statements.compose`. `BadStatement` when the result is not the next statement id held by the Core with 80 credits.
4. the caller is repaid `min(gasUsed * basefee * reimburseBps / 10_000, reimburseCapBps * cost / 10_000, ethPot)` (8,000 and 500 at launch), where `gasUsed` is the measured gas plus 50,000 and, on the eth lane, 350,000 for the listing. the reimbursement is added to the statement cost on the eth lane.
5. event `Composed(sid, lane, format, cost, reimbursement, caller)`. an eth lane statement is listed on the house in the same call (`StatementListed(sid, auctionId, reserve)`).

send at least 10,000,000 gas: the live Statements contract needs about 8.5 million for 80 credits (section 13).

## 6. statements: buying through the house and the buy mode

an eth lane statement is listed on `core.HOUSE()` at once. `lens.snapshot().statements` lists every held statement with its status, auction id, top bid, end time and `askingPrice`. the asking price of the controller starts at `startBps` (11,000) of the cost and falls `stepBps` (100) every `stepEvery` (10,800 seconds) down to `floorBps` (7,500). the reserve and the `sellTo` price are at least `saleFloorBps` (7,500) of the cost. `controller.priceOf(sid)` returns the asking price now in either mode.

the controller is in one of two modes (`controller.buyOnly()`).

auction mode:

1. read the asking price and the auction id from the lens.
2. optional: `core.repriceStatement(sid)` sets the reserve of a listing without a bid to the asking price now. anyone may call it, and the first bidder calls it before bidding.
3. `house.createBid{value: amount}(auctionId)`. the first bid must reach the reserve (`BidBelowReserve`) and each later bid must exceed the top bid by 500 bps (`BidBelowMinimum`). the auction runs `auctionDuration` (86,400 seconds) from the first bid.
4. after the end time anyone calls `house.endAuction(auctionId)` with at least 2,000,000 gas (the house needs 580,000 for its delivery). the statement goes to the winner and the proceeds are credited to the Core on the house.
5. `core.collectSales()` books the proceeds (`saleToBuybackBps` to the coin buyback pot, the rest to `ethPot`) and `core.syncStatement(sid)` deletes the record of the sold statement. both are permissionless and `buyback()` collects first.

buy mode (`buyOnly` true):

1. `controller.priceOf(sid)` returns the price. `NotForSale` for a statement that is not held, is on the exit lane or has no listing time.
2. `controller.buy{value: v}(sid)` with `v` at least the price (`Underpaid`). the controller calls `core.sellTo(sid, buyer)`, which cancels the listing (`HasBid` while a bid is live), sends the statement to the buyer and books the payment as sale proceeds. the excess of `v` is refunded to the caller last.
3. events `StatementSoldTo(sid, buyer, price)` on the Core and `Bought(sid, buyer, price)` on the controller. `buy` reverts `NotBuyOnly` in auction mode.

## 7. the fee pull and flush(tipTo)

the pool sends fee eth to the fee router. the router holds it until `flush(address tipTo)`:

* anyone may call. `amount = balance - totalOwed`.
* `tip = min(amount * tipPpm / 1_000_000, tipCap)`, sent to `tipTo` with 50,000 gas. a zero `tipTo` or a refusing recipient leaves the tip in the amount.
* while the split is on (`splitOn`, from `splitStart`), each payee receives `amount * ppm / 1_000_000` with 100,000 gas. a share that fails is recorded in `owed` and paid by `claim(payee)`.
* the rest goes to the engine, the Core, whose `receive()` books it: `feeToBuybackBps` to the coin buyback pot, the rest to `ethPot`. `FlushFailed` when the engine refuses it, and the fees stay in the router. `NoEngine` while no engine is set. an empty balance returns early.

the Core pulls the fees itself. `sellForEth` (both forms), `buyListing`, `compose`, `composeExit` and `adopt` call `flush(msg.sender)` first, so the flush tip goes to whoever triggers the door. `CoreLib.pullFees` uses at most 1,000,000 gas and ignores a failing router. `adopt` pulls as well, before it reads the price. `sellForExitToken`, `exitStatement`, `collectSales`, `sellTo`, `skim` and `buyback` read no eth price and book on their own schedule. `lens.snapshot()` reports what a flush would send now: `flushToCore`, `flushTip` and `flushToPayees`.

## 8. adopt

`adopt(uint256[] ids)`, callable by anyone. it records credits that were sent to the Core with a plain transfer (`Credits.transferFrom(owner, core, id)` or a safe transfer) so they enter the eth pile.

sequence:

1. transfer the credits to the Core. a transferred credit has no record and sits in no pile. compose pages draw from the piles, so the credit joins a page once it is adopted. the owner can send it out with `rescueNft`.
2. call `core.adopt(ids)`.

the call, in order: the fee pull of section 7, so pending router eth is booked before the price is read (the flush tip goes to the caller). `Empty` for an empty list. for each id: `ZeroId`, `InPile` when the credit is in a pile (the same id twice in a call included), `NotHolder` when another address holds it (an id that does not exist reverts inside Credits). the credit enters the eth pile with the arrival time of the block. event `CreditAdopted(id, cost)`.

the cost basis is `core.ethPrice() * score / 1e4`, at least 1 wei: the price state per whole point at that moment before the clamp, times the score of the credit. the price state is what the engine pays with a funded pot, so a statement built from adopted credits is priced at that level. the read after the clamp of a thin pot would book a basis of 1 wei and the statement price would collapse with it. a donor who inflates the basis of a statement only loses the credits.

the basis is booked and the eth pile grows. eth, the rate state, the hourly room and the pots keep their values apart from the fee pull. the order of the pile is the order of the ids. a statement composed from adopted credits costs the sum of their bases plus the compose reimbursement.

a successor Core (section 9) receives credits without records and adopts them the same way. a credit that left through `migrate` and returned can be adopted again.

## 9. migrate and rescue (owner only)

| call | what it does | reverts |
|---|---|---|
| `setSuccessor(address)` | names the contract that `migrate` sends to. zero or an address with code other than the Core, the exit module, the exit token, the house, the fee source, the coin, Credits or Statements | `OnlyOwner`, `Locked("successor")`, `NoCode`, `BadSuccessor` |
| `lockSuccessor()` | closes `setSuccessor` permanently. allowed while the successor is zero, which disables `migrate` | `OnlyOwner` |
| `migrate(maxCredits, maxStatements)` | moves in batches: `ethPot + ethToBuyback` by one plain call, up to `maxCredits` from the head of each pile by `transferFrom`, held statements scanned from the end of the held list (a listed one is taken back from the house first), `xPot + xToBuyback` by `transfer` | `OnlyOwner`, `NoSuccessor`, `Reentrancy`, `CallFailed` |
| `rescueNft(token, id, to)` | sends an ERC721 the Core holds to `to`: a credit only while it is outside both piles, a statement only while the Core has no record of it, any other ERC721 freely | `OnlyOwner`, `ZeroAddress`, `InPile`, `Held`, `NotHolder` |
| `rescueCoin(to, amount)` | sends coin the Core holds to `to` | `OnlyOwner`, `ZeroAddress` |

what a successor has to implement: a `receive()` that accepts a plain eth call. credits and statements arrive by `transferFrom`, so the `onERC721Received` of the successor is skipped. a statement with a live bid, a sold statement whose record is not settled and a statement the house will not return stay in the Core and are counted in `Migrated`. call `migrate` again until it moves nothing. `maxCredits` applies to each pile and `maxStatements` must exceed the number of skipped statements at the end of the held list. the successor builds its pile with `adopt`.

## 10. the lens

`CoreLens` (`src/CoreLens.sol`) holds immutable pointers and reads state only.

| call | returns |
|---|---|
| `snapshot()` | the `Snapshot` struct below, with every held statement |
| `statementsPage(start, n)` | `StatementView[]` for the held statements `start` to `start + n`, in the order of `core.heldStatements()` |
| `bidFor(id)` | the eth a seller receives now for credit `id` |
| `controller()` | the controller of the Core now |
| `CORE()`, `ROUTER()`, `HOUSE()`, `CREDITS()`, `STATEMENTS()` | the pointers |

| `Snapshot` field | meaning |
|---|---|
| `ethRate` | the bid per whole point as the Core reads it for a sale |
| `ethPrice` | the price state before the clamp |
| `averageBid` | the payout for one credit of average score, `avgScore * ethRate / 1e4` |
| `hourlyRoom` | eth the hourly spend cap still allows |
| `ethPileSize`, `ethPileHead`, `exitPileSize`, `exitPileHead` | size and oldest credit of each pile |
| `ethPageReady`, `exitPageReady` | the controller answers `nextPage` for the lane with a ready flag and the full answer size (82 words) that `compose` requires |
| `ethPot`, `ethToBuyback`, `xPot`, `xToBuyback` | the four pots |
| `unbookedEth` | Core balance above the booked pots. `skim()` books it |
| `salesOwed` | sale proceeds waiting in the house. `collectSales()` books them |
| `routerBalance`, `routerOwed` | eth in the router, and the part owed to payees |
| `flushToCore`, `flushTip`, `flushToPayees` | what `flush(tipTo)` with a tip recipient sends now |
| `controller`, `successor` | the addresses now |
| `controllerLocked`, `exitModuleLocked`, `targetsLocked`, `successorLocked` | the four one way locks |
| `statements` | `StatementView[]` |

| `StatementView` field | meaning |
|---|---|
| `id`, `lane`, `cost` | statement id, lane and cost basis |
| `listed` | the auction is live on the house: no bid, a bid running, or ended and not settled |
| `status` | `Core.StatementStatus`: 0 None, 1 Held, 2 Listed, 3 Bid, 4 Ended, 5 Sold, 6 Returned |
| `auctionId`, `topBid`, `endTime` | from the house. `topBid` and `endTime` are 0 before the first bid |
| `askingPrice` | the controller's `priceOf(id)` in wei while a buyer can buy at it: an eth lane statement with status Listed (live auction, no bid). 0 in every other status, for an exit lane statement and for a controller that does not answer. `status`, `topBid` and `endTime` describe the other states |

`snapshot()` costs about 146,000 gas plus 56,000 per held statement. a list of several hundred statements exceeds the gas that a public node allows for one `eth_call`, so a keeper reads them with `statementsPage` in pages of a few hundred.

## 11. events

the Core (`src/interfaces/ICore.sol`):

| event | fields | emitted when |
|---|---|---|
| `Buyback` | `address indexed caller, uint256 amountIn, uint256 tip` | `buyback`: `amountIn` eth swapped for coin and the coin burned, `tip` paid to `caller` |
| `CoinRescued` | `address indexed to, uint256 amount` | `rescueCoin` |
| `Composed` | `uint256 indexed sid, Lane lane, uint8 format, uint256 cost, uint256 reimbursement, address indexed caller` | `compose` or `composeExit`. `lane` 0 or 1, `format` the Statements format, `cost` the cost basis of the statement (the bases of the 80 credits plus `reimbursement` on the eth lane), `reimbursement` the gas repayment sent to `caller` |
| `ControllerLocked` | (empty) | `lockController` |
| `ControllerSet` | `address controller` | `setController` (also at construction) |
| `CreditAdopted` | `uint256 indexed id, uint256 cost` | `adopt`, one per credit. `cost` is the cost basis written |
| `CreditBought` | `uint256 indexed id, address indexed from, Lane lane, uint256 cost` | one per credit of `sellForEth` or `sellForExitToken`. `lane` 0 is the eth lane, 1 the exit lane. `cost` is the payout and the cost basis |
| `EthRateFill` | `uint256 spent, uint256 rate, uint256 pot` | every spend from `ethPot`: `spent`, the price state after the drop (`rate`) and the pot after the spend |
| `ExitBuyback` | `address indexed caller, uint256 slice, uint256 coinIn` | `buybackExit` (phase 2): `slice` sold to `caller` for `coinIn` coin, which is burned |
| `ExitModuleLocked` | (empty) | `lockExitModule` |
| `ExitModuleSet` | `address exitModule, address exitToken, uint256 unitPerPoint` | `setExitModule` |
| `ExitRateFill` | `uint256 rate, uint256 pot` | phase 2 spend of the exit pot by `sellForExitToken`: the exit rate and the pot after |
| `FeesAdded` | `uint256 amount` | `receive()` booked a flush of the fee router: `feeToBuybackBps` of it to the coin buyback pot, the rest to `ethPot` |
| `ListingBought` | `uint256 indexed id, address indexed target, address indexed caller, uint256 cost, uint256 tip, uint256 rate` | `buyListing`. `cost` is the eth the target took, `tip` the caller tip, `rate` the price state after the fill. the cost basis of the credit is `cost + tip` |
| `Migrated` | `address indexed successor, uint256 eth, uint256 credits, uint256 statements, uint256 exitTokens, uint256 skippedStatements` | `migrate`: eth moved (pots and buyback pot), credits and statements moved, exitToken moved, statements skipped |
| `NftRescued` | `address indexed token, uint256 indexed id, address indexed to` | `rescueNft` |
| `Overprinted` | `uint256 indexed baseId, uint256 indexed topId, uint256 cost` | `overprint` merged `topId` into `baseId`. `cost` is the summed cost basis |
| `OwnershipTransferStarted` | `address indexed owner, address indexed pending` | the owner named `pending` |
| `OwnershipTransferred` | `address indexed from, address indexed to` | `acceptOwnership` completed (also at construction, from the zero address) |
| `RateSet` | `uint256 rate` | the owner restated the eth rate (wei per whole point) |
| `SalesCollected` | `uint256 amount, uint256 toBuyback` | `collectSales` (or `buyback`) pulled `amount` from the house: `toBuyback` to the coin buyback pot, the rest to `ethPot` |
| `SettingsSet` | `Settings settings` | the owner set every setting |
| `Skimmed` | `uint256 eth, uint256 exitToken` | `skim` booked eth and exitToken the Core held above the recorded pots |
| `StatementExited` | `uint256 indexed sid, Lane lane, uint256 received` | `exitStatement` handed the statement on (phase 2). `received` is the exitToken that came back |
| `StatementListed` | `uint256 indexed sid, uint256 indexed auctionId, uint256 reserve` | an eth lane statement was listed on the Core house (at compose, after a relist by `syncStatement`, after an overprint). `reserve` is the opening reserve |
| `StatementRepriced` | `uint256 indexed sid, uint256 reserve` | `repriceStatement` set the reserve of a listing without a bid |
| `StatementSold` | `uint256 indexed sid, uint256 indexed auctionId, address indexed holder` | `syncStatement` found the auction gone and the statement with `holder`: the sale cleared and the record is deleted |
| `StatementSoldTo` | `uint256 indexed sid, address indexed buyer, uint256 price` | `sellTo` (the controller `buy` path): the statement went to `buyer` for `price`, booked as sale proceeds |
| `SuccessorLocked` | (empty) | `lockSuccessor` |
| `SuccessorSet` | `address successor` | `setSuccessor` |
| `TargetAdded` | `address target` | `addTarget` (Seaport and CreditStrategy at construction) |
| `TargetRemoved` | `address target` | `removeTarget` |
| `TargetsLocked` | (empty) | `lockTargets` |
| `XRateSet` | `uint256 rate` | the owner restated the exit rate (phase 2) |

the controller (`src/interfaces/IControllerV1.sol`):

| event | fields | emitted when |
|---|---|---|
| `Bought` | `uint256 indexed sid, address indexed buyer, uint256 price` | `buy`: `buyer` paid `price` and received statement `sid` |
| `BuyOnlySet` | `bool buyOnly` | the owner switched the sale mode |
| `FloorBpsSet` | `uint16 floorBps` | sale setting changed |
| `StartBpsSet` | `uint16 startBps` | sale setting changed |
| `StepBpsSet` | `uint16 stepBps` | sale setting changed |
| `StepEverySet` | `uint32 stepEvery` | sale setting changed |

the fee router (`src/interfaces/IFeeRouter.sol`):

| event | fields | emitted when |
|---|---|---|
| `Claimed` | `address indexed payee, uint256 amount` | `claim` paid an owed share |
| `EngineSet` | `address indexed previous, address indexed engine` | the owner set the engine |
| `Flushed` | `address indexed engine, uint256 toEngine, uint256 tip, uint256 toPayees` | `flush`: `toEngine` sent to the engine (the Core), `tip` to the tip recipient, `toPayees` shared (paid or owed) |
| `Locked` | `address indexed engine` | the owner locked the router settings |
| `OwnershipTransferStarted` | `address indexed owner, address indexed pendingOwner` | the router owner named `pendingOwner` |
| `OwnershipTransferred` | `address indexed previousOwner, address indexed newOwner` | the router owner changed |
| `PayeeOwed` | `address indexed payee, uint256 amount` | a payee share failed to send (100,000 gas limit) and is recorded in `owed` for `claim` |
| `PayeePaid` | `address indexed payee, uint256 amount` | a payee share was sent |
| `PayeesSet` | `address[] payees, uint32[] ppm` | the owner set the payee list and the shares in ppm |
| `SplitStartSet` | `uint64 at` | the owner set the split start time |
| `SplitStarted` | `uint256 at` | the first flush at or after the split start turned the split on |
| `TipFailed` | `address indexed to, uint256 amount` | the tip recipient refused the tip (50,000 gas limit). the tip goes to the engine with the rest |
| `TipSet` | `uint32 ppm, uint96 cap` | the owner set the tip ppm and the cap |

the house (`src/interfaces/AuctionHouse.sol`) emits its own auction events; the interface file lists them.

## 12. reverts

the Core. an error named here is declared in `ICore`, and the ones raised inside `CoreLib` carry the same selectors.

| error | raised by | meaning |
|---|---|---|
| `AboveCeiling()` | `buyListing` | `value` is above `ceilingOf(id)` |
| `AlreadyOwned()` | `buyListing` | the Core already owns the credit |
| `AuctionLive()` | `syncStatement` | the auction is still live on the house |
| `BadAuction()` | statement reads | the house did not answer, or an auction is in a state the call does not accept |
| `BadCost()` | `buyListing` | the eth balance did not fall, or fell by more than `value` |
| `BadFormat()` | `compose` | the controller returned a format above 7 |
| `BadModule()` | `setExitModule` | the module is rejected |
| `BadOverprint()` | `overprint` | the pair is the same statement, not held, or in different lanes |
| `BadPrice()` | `compose`, `repriceStatement` | the controller did not answer `statementPrice` with one word |
| `BadRate()` | `setRate`, `setXRate`, constructor | the rate is outside its bounds |
| `BadSender()` | `onERC721Received` | an ERC721 other than Credits or Statements was safe transferred to the Core |
| `BadSetting(bytes32 field)` | `setSettings` | the setting `field` is outside its bounds |
| `BadStack()` | constructor | a stack value is invalid |
| `BadStatement()` | `compose`, `overprint` | Statements returned an id, holder, credit count or rating other than expected |
| `BadSuccessor(address who)` | `setSuccessor` | the address is the Core or a contract the Core works with (`who`) |
| `BadSwap()` | `buyback` | the pool swap result is out of bounds |
| `BelowFloor()` | `sellTo` | `msg.value` is below the hard floor `cost * saleFloorBps / 10_000` |
| `CallFailed()` | `buyListing`, `collectSales`, `migrate` | the target call reverted, the house did not pay what it owed, or the successor refused the eth |
| `DailyCap()` | `overprint` | 8 overprints already today |
| `Empty()` | `sellForEth`, `sellForExitToken`, `adopt` | an empty id list |
| `ExitTokenChanged()` | `setExitModule` | a replacement module names another exitToken |
| `ForbiddenTarget()` | `addTarget` | the target is a contract the Core refuses to call |
| `HasBid()` | `repriceStatement`, `sellTo`, `exitStatement`, `overprint` | the auction has a bid, so it cannot be cancelled or repriced |
| `Held()` | `rescueNft` | the statement is on the books of the Core |
| `HourlyCap()` | `sellForEth`, `buyListing` | the spend would pass `spendCapBps` of the pot of the current hour |
| `InPile()` | `adopt`, `rescueNft` | the credit is in a pile |
| `Locked(bytes32 what)` | owner setters | the door `what` (`controller`, `exitModule`, `targets`, `successor`) is locked |
| `Measuring()` | `receive` | the fee router sent eth while a measured external call of the Core was running |
| `NoCode(address who)` | constructor, `setSuccessor` | the address has no code |
| `NoCredit()` | `buyListing` | the target call did not deliver exactly the credit `id` to the Core |
| `NoExitModule()` | phase 2 functions | no exit module is set |
| `NoSuccessor()` | `migrate` | the successor is zero |
| `NotHeld()` | `compose`, `exitStatement` | the Core does not hold the credit of the page, or has no record of the statement |
| `NotHolder()` | `adopt`, `rescueNft` | the Core is not the holder of the token |
| `NotInPile(uint256 id)` | `compose` | the controller named a credit that is not in the lane pile (`id`) |
| `NotListed()` | `syncStatement`, `repriceStatement`, `sellTo` | the record does not say listed, or the house has no auction for it |
| `NotOwner()` | `sellForEth`, `sellForExitToken` | the caller does not own the credit |
| `NotReady()` | `compose`, `overprint` | the controller reports no page or no pair, or the read fails |
| `NothingBought()` | `buyback` | the swap bought no coin |
| `NothingToBuy()` | `buyback`, `buybackExit` | the buyback pot is empty |
| `OnlyController()` | `sellTo` | the caller is not the controller |
| `OnlyOwner()` | owner functions | the caller is not `owner` |
| `OnlyPendingOwner()` | `acceptOwnership` | the caller is not the pending owner |
| `OnlyPoolManager()` | `unlockCallback` | the caller is not the pool manager |
| `PotTooSmall()` | `sellForEth`, `buyListing`, `sellForExitToken` | the spend is larger than the pot |
| `Reentrancy()` | guarded functions | a guarded function was entered while another guarded call runs |
| `Slippage()` | `sellForEth`, `sellForExitToken`, `buybackExit` | total payout below `minOut`, or the coin cost above `maxCoinIn` |
| `TargetNotAllowed()` | `buyListing` | the target is not on the allowlist, or it is a forbidden contract |
| `TooEarly()` | `exitStatement` | the listing is younger than `exitAfter` |
| `TooSoon()` | `buyback` | fewer than `buybackDelay` blocks since the last buyback |
| `Underpaid()` | `exitStatement` | the module returned less than the rating times the unit |
| `ZeroAddress()` | constructor, `rescueCoin`, `rescueNft`, `setController` | a zero address argument |
| `ZeroAmount()` | `sellForEth` | a spend of 0 wei: the bid is 0 (empty pot) for that credit |
| `ZeroId()` | `sellForEth`, `buyListing`, `adopt` | credit id 0 |

the controller:

| error | raised by | meaning |
|---|---|---|
| `BadSetting(bytes32 field)` | sale setters, constructor | the setting `field` is outside its bounds |
| `NotBuyOnly()` | `buy` | the controller is in auction mode |
| `NotForSale()` | `buy`, `priceOf` | the statement is not held, is on the exit lane, or has no listing time |
| `OnlyOwner()` | sale setters | the caller is not `core.owner()` |
| `Reentrant()` | `buy` | `buy` was entered again |
| `Underpaid()` | `buy` | `msg.value` is below `priceOf(sid)` |

the fee router:

| error | raised by | meaning |
|---|---|---|
| `BadPayees()` | `setPayees` | more than 4 payees, a zero address, a zero share, or a total above 200,000 ppm |
| `BadTip()` | `setTip` | the tip above 20,000 ppm or the cap above 0.05 eth |
| `ClaimFailed()` | `claim` | the payee refused the eth |
| `FlushFailed()` | `flush` | the engine refused the eth |
| `IsLocked()` | owner setters | the router is locked |
| `NoCode(address account)` | `setEngine` | the engine has no code (`account`) |
| `NoEngine()` | `flush`, `lock` | no engine is set |
| `NothingOwed()` | `claim` | the payee is owed nothing |
| `OnlyOwner()` | owner setters | the caller is not the router owner |
| `OnlyPendingOwner()` | `acceptOwnership` | the caller is not the pending owner |
| `Reentered()` | `flush`, `claim` | the router was entered again |
| `SplitIsOn()` | `setSplitStart` | the split already started |
| `ZeroAddress()` | setters | a zero address |

## 13. gas

measured on the pinned fork with foundry 1.8.1. `tx` includes the intrinsic 21,000 and the calldata, `exec` is the gas inside the call. the transaction cap is 16,777,216.

| call | gas | pinned by |
|---|---|---|
| `sellForEth`, 1 credit, flat bid, cold | tx 491,700 | `test/GasCap.t.sol` `test_gas_sellForEth_batch_launchSettings` |
| `sellForEth`, each further credit | 145,517 | the same test (fit over 1 to 40 credits) |
| `sellForEth`, largest batch under the cap | 112 credits, tx 16,670,075 | the same test |
| `sellForEth`, 1 credit, router empty, call gas | 394,965 | `test/PullFees.t.sol` `test_gasOfThePullOnOneCredit` |
| `sellForEth`, 1 credit, router holds 1 eth, call gas | 465,847 | the same test |
| `flush`, most expensive case (four payees and a tip recipient that burn all their gas) | 706,490 | `test/PullFees.t.sol` `test_worstCaseFlushGasAndTheDoorCompletes` |
| `flush` with the split on, tip and two payees | tx 150,388 | `test/GasCap.t.sol` `test_gas_routerFlush` |
| `flush` that turns the split on | tx 116,023 | `test/GasCap.t.sol` `test_gas_routerFlush_firstAtSplitStart` |
| `buyListing` through the CreditStrategy | tx 485,872 | `test/GasCap.t.sol` `test_gas_buyListing_creditStrategy` |
| `buyListing` through Seaport, basic order | tx 498,098 | `test_gas_buyListing_seaport_basic` |
| `buyListing` through Seaport, basic order with a fee recipient | tx 535,429 | `test_gas_buyListing_seaport_basicWithFee` |
| `buyListing` through Seaport, advanced order | tx 511,987 | `test_gas_buyListing_seaport_advanced` |
| `compose()`, eth lane, 80 credits, first compose | tx 8,728,243 | `test/GasCap.t.sol` `test_gas_compose_ethLane_firstCold` |
| `compose()`, second compose | tx 8,677,591 | `test_gas_compose_ethLane_secondWarmAndCold` |
| `composeExit()`, 80 credits | tx 8,486,449 | `test_gas_composeExit_andExitStatement_exitLane` |
| `ControllerV1.nextPage`, full eth pile, cold | 238,573 (the Core allows 500,000) | `test_gas_readCaps_nextPageAndStatementPrice` |
| `repriceStatement` | tx 102,405 | `test_gas_repriceStatement` |
| house `createBid`, first bid | tx 102,760 | `test_gas_house_createBid_andEndAuction` |
| house `createBid`, outbid | tx 89,520 | the same test |
| house `endAuction` | tx 151,342 | the same test |
| `syncStatement`, sold statement | tx 92,550 | `test_gas_syncStatement_soldPath` |
| `syncStatement`, relist after an unwound sale | tx 360,016 | `test_gas_syncStatement_relistPath` |
| `controller.buy` (the `sellTo` path) | tx 243,504 | `test_gas_sellTo_throughControllerBuy` |
| `collectSales` | tx 118,746 | `test_gas_collectSales_andBuyback` |
| `buyback` with proceeds waiting in the house | tx 270,582 | the same test |
| `adopt`, 1 credit, router empty | call gas 242,489 | `test/Adopt.t.sol` `test_GAS_adopt` (asserted within 5 percent) |
| `adopt`, 80 credits, router empty | call gas 10,552,467 (131,905 per credit) | the same test |
| `migrate`, eth only | call gas 124,469 | `test/Migrate.t.sol` `test_GAS_migrateEightyCreditsAndFiveStatements` |
| `migrate`, 80 credits and 5 statements | call gas 4,589,530 (40,697 per credit, 96,073 per statement) | the same test |
| `lens.snapshot()` | 145,864 with no statements, 55,766 more per statement | `test/Lens.t.sol` `test_GAS_snapshotPerStatement` |

## 14. interface files

generated from the production abi by `script/tools/gen-interfaces.sh`, which `--check` compares with the committed files.

| file | contract |
|---|---|
| `src/interfaces/ICore.sol` | `Core`: functions, events, errors and the `StatementStatus` enum |
| `src/interfaces/IControllerV1.sol` | `ControllerV1` |
| `src/interfaces/IFeeRouter.sol` | `FeeRouter` |
| `src/interfaces/ICoreLens.sol` | `CoreLens` with the `Snapshot` and `StatementView` structs |
| `src/interfaces/ICoreLib.sol` | `CoreLib`: the pure and view functions of the library and `swapIn`. the Core forwards its owner functions, `sellForExitToken` and `adopt` to the library under the same selectors, so a caller uses `ICore` for them |

hand written shared types and external interfaces: `src/interfaces/Interfaces.sol` (`Lane`, `Settings`, `Stack`, `Sale`, Credits, Statements, the score contract and the `Mainnet` constants), `src/interfaces/AuctionHouse.sol` (the house and its factory) and `src/interfaces/ArtCoinsV2.sol` (the v2 stack).
