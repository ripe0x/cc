# credits engine indexer: spec

status: approved (decision 132). phases 1 and 2 and the listing sources (decision 134) are built, 2026-10-15. phase 3 waits for a page that uses it; phase 4 waits for `deployments/1.json`.

This document is the data contract between the chain, the indexer and the web app. Every value the web shows has one row in section 9 that names its source. A change that adds a value to the web adds its row here in the same change.

## 1. goals

1. The web reads history, lists, counts and slow-moving state from one indexed database. The browser keeps live chain reads through the website API for values that change every block or every second (section 4).
2. Every event from every engine contract is stored, including events no page uses today, so a new page is a new query and a full reindex is rare.
3. The indexer runs on free public RPC endpoints, led by Tenderly's public gateway, inside a fixed request budget, with automatic failover.
4. One deploy path for local, testnet and mainnet, driven by the deployment record (`deployments/<chainId>.json`).
5. The indexer checks itself against the chain and reports drift.

## 2. best practice this design follows

- **Index the protocol, serve the product.** Tables mirror protocol objects (credit, statement, engine, controller, activity), never page layouts. Pages compose queries over them. A redesigned page reuses the same tables.
- **Keep every log.** A `log` table stores every decoded event from every indexed address with its full arguments. Typed tables are projections of it. A feature that needs an event nobody projected yet starts from `log` and promotes it to a typed column later.
- **Events for history, calls for state without events.** State that changes without an event (pots, bid rate, balances, pool price) is read by `eth_call` at chosen blocks and stored as snapshots. Section 5 lists each one.
- **The RPC cache is the backfill budget.** Ponder stores every RPC response in its database. A schema change reindexes from the cache with near zero RPC traffic. The cache survives redeploys because it lives in Postgres.
- **One source per value at a time.** The web reads each value from one place (section 9) chosen by one app-wide mode (section 11): the indexer while it is healthy, the browser's on-chain read path otherwise. The browser keeps the on-chain read paths (`web/lib/engine.ts` log scan, `creditInfo`, `tokensOf`, `ownerOf`, `tokenURI` reads) as an automatic fallback for every indexer read (owner decision 133, 2026-10-15). They run only in fallback mode.
- **Reconcile continuously.** A job compares indexed projections with on-chain views every N blocks and exposes the result (section 8.4).
- **Data contract in the repo.** This file is the contract. `AGENTS.md` gains a rule: a change that adds web data names its source in section 9.

## 3. framework, hosting, layout

| choice | value | reason |
|---|---|---|
| framework | Ponder 0.17.x, pinned exact (the shapes indexer pins 0.17.8) | the owner's other indexers use Ponder; native reorg handling, RPC response cache, factory sources for the swappable controller, GraphQL and SQL over HTTP built in |
| database | Postgres (Fly Postgres or Neon free tier); PGlite only for local dev | the RPC cache and schema-per-deploy blue/green redeploys need a database that outlives the machine |
| host | Fly.io, region iad, shared-cpu-1x, 1 GB, one always-on machine, `/health` check | same as artcoins and shapes |
| repo path | `indexer/` at the repo root, beside `web/` | the deployment record and ABIs are in this repo |
| API | GraphQL at `/graphql`, `@ponder/client` SQL over HTTP at `/sql`, both read only and public | the frontend is public; a bearer token in the browser bundle protects nothing |
| live updates | `@ponder/client` live queries (server-sent events), verify support in the pinned version | pages update when a new block is indexed, without a polling interval |

Layout, following `shapes/indexer`:

```
indexer/
  ponder.config.ts        chains, sources, start blocks, all from the record and env
  ponder.schema.ts        tables (section 6)
  abis/                   generated from forge out/ for Core, CoreLib, ControllerV1; pinned JSON for external contracts
  src/index.ts            event handlers
  src/state.ts            block handlers for state snapshots (section 5)
  src/lib/*.ts            pure helpers (splits, price curves, eta) with node --test unit tests
  src/api/index.ts        graphql, sql client, /health/parity
  deploy.sh               one deploy path (section 10)
  fly.<env>.toml          values only
```

ABIs for Core, CoreLib and ControllerV1 are generated from `forge build` output by a script, so an event change in `src/` fails the indexer typecheck.

## 4. what the indexer serves and what stays a live read

| class | examples | source |
|---|---|---|
| history and lists | feed, credit history, statement history, held pile with order, statements by state, sales, buybacks | indexer |
| per-token facts fixed at creation | credit seed, paidAt, score, traits mask, statement credit ids, rating, composer, compose mode | indexer (read once, stored) |
| token art | credit `tokenURI`, statement `tokenURI` (refreshed after `HeldFormatSet`) | indexer |
| settings and parameters | Core settings, controller sale and credit sale params, anchor, creditCostToPotBps, locks, owner, payee, artist | indexer (event projections plus deploy-block reads) |
| aggregates | counts by kind, ETH into credits, fees booked, $CC burned (all engine burns), buy rate per hour, payee and artist received | indexer |
| state without events, minute scale | pot, toBuyback, redeemBurn, bid rate, balance rate, module available | indexer snapshots at every engine-event block and every 300 blocks; the browser snapshot keeps the current value |
| state that moves every block or second | `ethRate` climb, `bidOf`, `creditPrice`, `priceOf`, pool slot0, quotes, Chainlink, hook skim decay | browser, one multicall (`web/lib/live.ts`) and market hooks, unchanged cadence |
| wallet data | balances, allowances, approvals, the wallet's credits | browser for balances and allowances; indexer for the wallet's credits and statements (owner column) |

The browser snapshot multicall stays because a price that decays every second is cheaper to read once per 15 s than to index per block. Its inputs that rarely change (settings, controller params) move to the indexer, which shrinks the multicall.

## 5. sources

All addresses and start blocks come from `deployments/<chainId>.json`. The config throws when a required value is missing.

### 5.1 log sources

| source | address | filter | start block | events |
|---|---|---|---|---|
| Core | record `core` (CoreLib events are emitted under the Core address) | all events | record `deployBlock` | every Core and CoreLib event (inventory B1, about 35) |
| Controller | factory over Core `ControllerSet(address controller)` | all events | block of each `ControllerSet` | `Bought`, `AnchorMoved`, `SaleSet`, `CreditSaleSet`, `AnchorBpsSet`, `BalancePoolKeySet`, `QuoteSet`, `ReferenceRefreshed`, the ControllerV2 statement sale events, and the ControllerV3 events `IdleLooseningSet`, `FillSynced`, `CreditSoldRecorded`, `CcPoolKeySet`, `CcQuoteSet`, `CcReferenceRefreshed`. The source ABI is the union of ControllerV1, V2 and V3 (`abis/Controller.ts`), so every version's events decode through this one factory |
| balance module | factory over Core `BalanceModuleSet(address balanceModule, ...)` | all events | block of each `BalanceModuleSet` | the Phase2BalanceTreasury events (phase 2) and the BalanceTreasuryV2 events (phase 3): `BidFill`, `CreditSold`, `Swept`, `Allocated`, `Unallocated`, `RedeemerRegistered`, `RedeemerCapsSet`, `RedeemerSwitched`, `SharesSet`, `CCRedeemed`, `ClaimReleased`, `StatementConverted`, `CushionSet`, `BidSet`, `PausedSet`, `SwitchesSet`, `ConversionToClaimBpsSet`, `PaymentAccrued`, `OwedClaimed`, `WorkingWithdrawn`, `MigrationReceived`, `TokenRescued`. The source ABI is the union of both (`abis/Treasury.ts`); `CCRedeemed`, `StatementConverted` and `MigrationReceived` differ in signature between the versions, so the union keeps both and the handlers register them by full signature. A StatementBalanceModule emits none and its registration is inert. The v2 treasury and V3 controller are discovered here by their `BalanceModuleSet` / `ControllerSet` selection, exactly as phase 2 was; only redeemer 2 (next row) needs the phase 3 record, because no Core event creates it |
| MarketRedeemer (redeemer 2) | phase 3 record `<chainId>-phase3.json` `marketRedeemer` (env `MARKET_REDEEMER_ADDRESS`) | all events | record `deployBlock` (env `MARKET_REDEEMER_START_BLOCK`) | `PremiumSet(uint16 premiumBps, uint64 configEpoch)` only (also at construction). A static source: the owner registers this adapter, so no Core factory discovers it. Configured only when the record (a sibling of the main record; `DEPLOYMENT_RECORD_PHASE3` overrides the path) carries `marketRedeemer` and `treasuryV2`; absent either, the source is unregistered and the indexer runs exactly as before. The ABI is `abis/MarketRedeemer.ts` (`npm run abis`) |
| CC burns | record `coin` | `Transfer` with `to = 0x0` | record `deployBlock` | all burns; attribution to the engine via the tx (Buyback tx, `CreditSwapped.fee`) |
| $BALANCE acquisition commitments | Core | `BalanceFill.paid` (seller payout) and `BalanceFill.toArtist` (amount requested from the module for the artist), associated with preceding `CreditBought` and latest prior `BalanceModuleSet` | Core deployment | event-time token, per-credit commitment in log order; no module ERC-20 transfer ledger |
| Credits | `0x97630aA70AB14ed9883B41dAfccBc11349723043` | `Transfer` | collection deploy block (to be read) | owners for every credit, engine ins and outs, migrate moves |
| Statements | `0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b` | `Transfer` | collection deploy block (to be read) | statement owners after sale |
| CreditStrategy | `0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6` (proxy) | `NFTBoughtByProtocol`, `NFTSoldByProtocol` | env `STRATEGY_START_BLOCK`; chain 1 requires it (`26037623`, the first block with code); local fork: 60000 blocks before the Core deploy block | strategy listings (6.11) |

The Credits and Statements event lists must be confirmed against the deployed contracts before build. Their source is outside this repo.

PoolManager swap sources are planned for phase 2 and are absent from the current config. They will need indexed pool-id filters before use; the current indexer does not ingest swap history or populate hourly pool prices.

### 5.2 call sources

| what | when | calls |
|---|---|---|
| engine state snapshot | every block that holds an engine event, plus a block interval of 300 blocks (about 1 h) | one Multicall3 at that block: `ethPot`, `ethToBuyback`, `ethRedeemBurn`, `ethRate`, `floorRate`, `balanceRate`, `getEthBalance(core)`, `pileSize`, `payeeOn`, `paused`, module `available()` |
| deploy-block reads | once per Core and once per controller at its first block | Core: `artist`, `creditCostToPotBps`, `chosenComposeOn`, `minCcToChoose`, `settings`, `owner`, `payee`. Controller: all sale and credit sale params, `anchorBps`, `balancePoolKey` |
| credit facts | first time a credit id appears in any source | Credits `seedOf`, `timestampOf`; CreditScore `scoreOf`, `traitsOf`; Credits `tokenURI` |
| statement facts | `Composed` | Core `ratingOf(sid)` at the event block; Statements `tokenURI`; again after each `HeldFormatSet` |
| credit sale split | `CreditSold` | `creditCostToPotBps` from the indexed setting in force at that block (the `CreditCostToPotBpsSet` history plus the deploy read); no call needed |

Historical `eth_call` needs an endpoint that serves the requested state. The transport in section 7 falls through public endpoints on unavailable historical state.

## 6. schema

Conventions: addresses lowercase hex; amounts `bigint` in base units; every row written from an event carries `blockNumber`, `blockTimestamp`, `txHash`, `logIndex`; enums are text with a CHECK listing the values; comments in the schema state invariants.

### 6.1 `log` (every event)

`id` (`txHash:logIndex`), `address`, `contract` (core, controller, coin, credits, statements, strategy), `event` (name), `args` (json, bigints as strings), block and tx fields. Index on (`contract`, `event`, `blockNumber`). BALANCE token transfers from modules are not indexed as raw logs; `BalanceFill` records acquisition obligations, not observed ERC-20 outflow.

### 6.2 `engine` (one row per Core)

addresses: `core`, `controller`, `coin`, `balanceModule`, `balanceToken`, `owner`, `pendingOwner`, `payee`, `artist`, `successor`.
flags: `paused`, `retired`, `controllerLocked`, `balanceModuleLocked`, `adaptersLocked`, `successorLocked`, `chosenComposeOn`, `payeeOn`.
values: `settings` (all fields as typed columns plus json), `creditCostToPotBps`, `minCcToChoose`, `lastBuybackBlock`.
latest snapshot: `ethPot`, `ethToBuyback`, `ethRedeemBurn`, `ethRate`, `floorRate`, `balanceRate`, `coreEthBalance`, `balanceAvailable`, `snapshotBlock`.

### 6.3 `engine_snapshot`

One row per snapshot block (section 5.2) with the snapshot fields. Drives charts and lets history views show the pot at the time of an event.

### 6.4 `setting_change`

One row per setter event (`SettingsSet`, `RateSet`, `BalanceRateSet`, `CreditCostToPotBpsSet`, `ChosenComposeOnSet`, `MinCcToChooseSet`, `PausedSet`, `PayeeSet`, `ArtistSet`, `ControllerSet`, `BalanceModuleSet`, `AdapterSet`, lock events, ownership events, controller `SaleSet`, `CreditSaleSet`, `AnchorBpsSet`, `BalancePoolKeySet`, `QuoteSet`): `name`, `before` json, `after` json. Answers "what was X at block B" without archive calls. `BalanceRateSet` records value mode's shared instance reset under a `sharedRateBps` key, not the posted balance bid rate: the posted rate is `10,000 - balanceDiscountBps` in the `balanceRate` column, sourced from `SettingsSet` and the snapshot read (decision 164). The handler change needs a full reindex to drop the old `balanceRate` before/after rows this event wrote.

### 6.5 `controller`

`address`, `setBlock`, `active`, sale params (`markupBps`, `startCapBps`, `decayHours`, `anchorHalfLife`, `anchorMinCost`), credit sale params (`saleOn`, `window`, `spreadBps`, `startBps`), `anchorBps` (stored value and its block), `balancePoolKey` fields, the reference price settings (`referenceRateBpsPerHour`, `referenceStepBps`, `referenceTolBps`, `referenceMaxStale`, `referenceMinSeconds`, `referenceMinLiquidity`, from `QuoteSet`), and the reference at the last `ReferenceRefreshed` (`referencePrice`, `referenceSpot`, `referenceTime`, decisions 148 and 157).

ControllerV3 adds no column. Its new events index as history only, because no page reads them as indexed state (the web reads the live V3 views, section 9.6): `IdleLooseningSet`, `CcPoolKeySet` and `CcQuoteSet` as `controller` `setting_change` rows; `FillSynced`, `CreditSoldRecorded` and `CcReferenceRefreshed` as `log` rows. Every ControllerV1 and V2 event still indexes for a V3 controller through the union source ABI.

### 6.6 `credit`

| column | meaning |
|---|---|
| `id` | token id |
| `seed`, `paidAt`, `score`, `rating` (score / 10000 as text), `mask`, `active`, `occupied`, `eights`, `band` | fixed facts; mask bit0 C, bit1 M, bit2 Y, bit3 K, set means printed |
| `owner` | from Credits `Transfer` |
| `state` | `outside`, `held`, `composed`, `sold`, `swapped_out`, `migrated` |
| `costBasis`, `acquiredAt`, `acquiredBlock`, `acquiredTx`, `acquiredHow` | `eth_bid`, `balance_bid`, `listing`, `adopted`, `swap_in`; a swap-in copies the swapped-out credit's cost and time (the event omits them) |
| `seller` | `CreditBought.from` or listing seller |
| `balancePaid` | `BalanceFill.paid` for a balance bid, the seller's posted payout |
| `royalty` | the artist royalty assigned at acquisition: `CreditBought.toArtist` for an ETH bid (wei), `ListingBought.toArtist` for a listing (wei), `BalanceFill.toArtist` for a BALANCE bid (`balancePaidToken` units, paid or recorded as claimable debt); null for an adopted or swapped-in credit |
| `pileOrder` | sort key for pile order: insertion sequence; a swap-in takes the out credit's key; `Migrated` removes from the head |
| `statementId`, `pagePosition` | after `Composed` |
| `salePrice`, `buyer`, `toArtist`, `toOperator`, `toPot`, `toBuyback`, `costToPotBps` | after `CreditSold`, split computed with the bps in force at that block |
| `tokenUri` | art data URI |

### 6.7 `statement`

`id`, `composedAt`, `composedBlock`, `composeTx`, `composer`, `mode` (`default` or `chosen`, from the tx input selector; null for an internal call), `cost`, `composePrice`, `rating`, `format`, `state` (`held`, `sold`, `redeemed`), `owner`, `salePrice`, `buyer`, `toBuyback`, `toArtist`, `toOperator`, `toPot`, `redeemedReceived`, `tokenUri`, `formatName` (metadata `Format` attribute).

`statement_credit`: (`statementId`, `position` 0..79, `creditId`), from `Composed.ids`, in pile order.

`statement_format`: one row per `HeldFormatSet`, (`statementId`, `from`, `to`, `caller`, block fields).

`anchor_move`: one row per `AnchorMoved`.

### 6.7b `treasury_state`, `treasury_event` and `redeemer` (phase 2 decisions 245 to 252; phase 3 adds the v2 columns)

`treasury_state`, one row per balance module named by `BalanceModuleSet`, written from the treasury's own events only, never from a latest state read (except the one-time seed read at selection, below): `version` (`phase2`, `v2` or null for a StatementBalanceModule, detected at selection), `balanceToken`, `setBlock`, `active`, `claimReserve`, `totalOwed` (PaymentAccrued less OwedClaimed), `configEpoch`, `policy`, `conversionToClaimBps`, `redemptionFeeBps`, the switches (`conversionEnabled`, `workingPaymentsEnabled`, and `ccRedemptionEnabled` on phase 2 / `bidEnabled` on v2), `paused` (v2), `minimumWorkingBalance`, `migrated`, `successor`, and the phase 3 earmarks `proRataRedeemer`, `cushion`, `bidBudget`, `bidShareBps`, `totalShareBps`. Running totals: `convertedTotal`, `contributedTotal`, `conversions`, `redeemedCcTotal`, `paidBalanceTotal`, `redemptions` (public burns) kept apart from `ownerFundedTotal`, `ownerAllocatedTotal`, `ownerReturnedTotal`, `ownerWithdrawnTotal`, plus `accruedTotal`, `claimedTotal`, and the phase 3 bid/sweep totals `bidInTotal` (Swept.toBid), `bidOutTotal` (BidFill paid+toArtist), `bidFills`, `bidCreditsTotal`, `sweptSurplusTotal`, `bucketsFundedTotal`, `allocatedTotal`, `unallocatedTotal`, `claimReleasedTotal`, and `lastEventBlock`. A value an event has not carried yet is null; a treasury's constructor and preselection events are not indexed (the factory discovers it at `BalanceModuleSet`), so the handler seeds the row with one tolerant read at that block (phase 2: the claim fields; v2: version, `proRataRedeemer`, `cushion`, `bidBudget`, shares, switches, `totalOwed`).

`treasury_event`, one row per treasury event: `kind` (phase 2: `statement_converted`, `cc_redeemed`, `claims_funded`, `claims_allocated`, `claims_returned`, `working_withdrawn`, `policy_set`, `fee_set`, `switches_set`, `contribution_set`, `minimum_working_set`, `migrated_out`, `migration_received`, `payment_accrued`, `owed_claimed`; phase 3 adds `bid_fill`, `swept`, `allocated`, `unallocated`, `redeemer_registered`, `redeemer_caps_set`, `redeemer_switched`, `shares_set`, `claim_released`, `cushion_set`, `paused_set`, `bid_set`), `ccIn`, `balanceOut`, `claimReserve`, `ccSupply`, `configEpoch`, `amount`, `bps`, `actor`, `recipient`, `redeemer` (the phase 3 redeemer-scoped events), `policy`, `statementId`, `detail` json, block and tx fields. Public redemptions are the `cc_redeemed` rows (v2 also names the `redeemer` and carries mode/claimId in `detail`); owner reserve changes are the phase 2 `claims_*` / `working_withdrawn` and the phase 3 `allocated` / `unallocated` / `swept` rows. Burns are never inferred from contribution events. `CCRedeemed`, `StatementConverted` and `MigrationReceived` differ in signature between phase 2 and v2, so each version has its own handler by full signature; `SwitchesSet` shares a signature, so its third switch follows `treasury_state.version`.

`redeemer` (phase 3), one row per redeemer a v2 treasury has registered, keyed `treasury:redeemer`: `registered`, `on` (the switch, off by default), `activeAt`, `epoch`, `shareBps`, the caps `perCall` / `perPeriod` / `lifetime`, and the running history totals `redeemedCcTotal`, `paidBalanceTotal`, `redemptions`, `allocatedTotal`, `unallocatedTotal`, `claimReleasedTotal`, with `firstBlock` and `lastEventBlock`. The registry here is projected from post-selection events; the current bucket balance and live cumulative in/out are read from the chain (`treasury.redeemers(address)`), because a sweep funds buckets in a lump by share with no per-redeemer figure in the event. A redeemer registered at deployment (before selection, e.g. the shipped pro-rata redeemer) is not replayed; its address is in `treasury_state.proRataRedeemer` and the web reads its state live. Redeemer 2 (MarketRedeemer) adds `premiumBps` and `premiumEpoch` to its row, projected from its own `PremiumSet(premiumBps, configEpoch)` event (the one event that adapter emits, also at construction). That event comes from the static MarketRedeemer source (section 5.1), not the treasury, so its handler keys the row `treasuryV2:marketRedeemer` from the record and upserts, landing the premium on the same row the treasury's `RedeemerRegistered` writes whichever event the indexer sees first. `premiumEpoch` is the premium's epoch and is distinct from the caps `epoch`; both are null for redeemer 1.

The `controller` row gains nullable `statementSalesEnabled`, `statementSaleMultiplierBps`, `statementRedeemDelaySeconds` from the ControllerV2 setter events; a V2 controller leaves the V1 anchor columns null and `anchorBps` at its derived 10,000. ControllerV3 adds no column (section 6.5).

### 6.8 `activity` (the ledger)

One row per user-visible event, newest first by (`blockNumber`, `logIndex`): `kind` (`credit_bought`, `credit_adopted`, `listing_bought`, `credit_swapped`, `composed`, `restyled`, `statement_sold`, `credit_sold`, `redeemed`, `buyback`, `fees_added`, `funded`, `escrow_collected`), `creditId`, `statementId`, `account`, `amount` (ETH wei), `amount2` (kind specific, documented per kind in the schema), block and tx fields. Index on (`kind`, `blockNumber`) and on `account`.

### 6.9 aggregates

`stats` (singleton per Core): counts per activity kind, `ethIntoCredits`, `feesBooked`, `toPayee`, `toArtist` (the artist cut of sales), `toArtistBuys` (the artist royalty on ETH bid and listing purchases, wei; BALANCE bid royalties are inside `balanceCommittedByToken`), `toOperator`, `ccBurned` (Buyback burns plus swap-fee burns), `ethToBuybackSpent`, `balanceCommittedByToken` (seller payouts plus Core-requested artist amounts, raw-unit decimal strings keyed by lowercase token address, also hourly; currencies are never summed). The production module may pay the artist or record claimable debt. This counter does not prove that an owner-supplied module fulfilled the request. The schema rename requires an indexer replay before any persisted stats are used.

`stats_hourly`: the same counters per hour bucket, plus `creditsBought`. The buy rate for compose estimates reads the last 24 rows.

`price_hourly` is planned for phase 2. The current schema has no such table or `Swap` handler.

### 6.10 `account`

`address`, credits sold to the engine, statements bought, credits bought, CC burned through swaps, first and last seen. Supports a future "your activity" view.

### 6.11 `strategy_listing`

One row per Credits id the CreditStrategy has listed: `id`, `listPrice` (wei, from `NFTBoughtByProtocol`), `active`, `boughtBlock`, `boughtAt`, `soldBlock`, `soldAt`, `buyer`. `NFTBoughtByProtocol` sets `active` and clears the sold fields; `NFTSoldByProtocol` and any Credits `Transfer` out of the strategy end the listing. A price change emits no event, so consumers read `nftForSale(id)` for the rows they use. Index on (`active`, `listPrice`).

## 7. RPC plan

### 7.1 endpoints

Tenderly is always the first attempt. When `RPC_FAST_FALLBACK_URL` is set to an operator-authorized Alchemy mainnet endpoint, it is the first fallback, capped at four physical requests per second. The owner withdrew Alchemy on 2026-10-22: the `RPC_FAST_FALLBACK_*` secrets were unset on `cc-indexer-mainnet` and must not be set again. The remaining public endpoints keep this fixed order before the optional paid reserve. Historical calls require an endpoint that serves the requested state; section 7.5 records the verification criteria.

1. `https://gateway.tenderly.co/public/mainnet`: 4 requests per second, one active request
2. `https://eth-mainnet.public.blastapi.io`: 8 requests per second
3. `https://1rpc.io/eth`: 5 requests per second
4. `https://ethereum-rpc.publicnode.com`: 10 requests per second
5. `https://eth.drpc.org`: 5 requests per second
6. `https://rpc.mevblocker.io`: 5 requests per second

`RPC_RPS` overrides these public caps in list order. The Alchemy URL stays in the Fly secret store; `RPC_RPS_FAST_FALLBACK` may lower its cap from four. Optional `PONDER_RPC_URL_1` is used only after all six public endpoints fail for a request; it receives no request while any earlier public endpoint serves it. Its cap is `RPC_RPS_RESERVE`, default 10 requests per second.

### 7.2 transport

`src/lib/rpc.ts` uses a fixed ordered viem fallback. One concrete transport is cached across client constructors. Each physical endpoint has one shared Ponder `rateLimit` queue, so concurrent constructors cannot reset its quota. Tenderly receives every initial attempt; healthy primary traffic never falls through. At the configured 4 RPS, the Ponder limiter permits one active Tenderly attempt.

HTTP attempts have an independent 20-second rejection deadline, request abort on expiry and no automatic retries. The deadline starts after the rate limiter dequeues the physical attempt, so queued waiting is not charged as an RPC attempt. The rate limiter and fallback also disable retries, so one physical attempt consumes one endpoint request slot. Fallback ranking is disabled.

`guardedHttp` rejects malformed `eth_getLogs` results and converts pruned-state and availability errors to errors that allow fallback. Deterministic execution reverts stop immediately without trying another public or the reserve. The final config transport rebuilds errors without the original credential-bearing URL or cause before Ponder can log them. Request counts, non-revert errors, queued/active attempts and the last start/settlement times per host are available at `/health/rpc`; failures are also logged.

### 7.3 chain options

| option | value | reason |
|---|---|---|
| `ethGetLogsBlockRange` | 5000 | the artcoins value; public endpoints reject larger ranges unpredictably |
| `pollingInterval` | 12000 | one check per block; Ponder fetches every block for reorg checks, so a longer interval saves nothing |
| `reorgWindow` | default 180 s | |
| `cacheRpcRequests` | true (false only for local anvil) | |

### 7.4 budget

Traffic depends on historical event density, block fetching, metadata reads and provider failures. Core sources start at the recorded deployment block; collection and strategy histories start earlier at their own configured blocks. Ponder persists its RPC cache in Postgres, but a new schema can still require handler work and uncached reads.

When a Credits Transfer introduces a missing token, the handler reads that block's collection Transfer logs, validates their collection, block hash and topics, and hydrates only the current token's deterministic group of at most 64 unique ids. Existing rows are skipped. Missing facts use three Multicall3 stages: immutable seed/time, immutable score/traits, and event-block tokenURI/owner. Only this bounded peer path sets the Viem subcall-calldata batch size to 16,384 bytes, allowing a full 64-id group to use three wire requests. Other callers retain default splitting. The aggregate ABI request is larger than the summed subcall calldata; actual Fly probes validated 128 decoded score/traits results on two archives and 128 successful URI/owner results on Tenderly, with the URI JSON response about 867 KB. This establishes accepted sampled calls, not a latency or gas guarantee for all history. Ordered event handlers still apply ownership and state changes; batching does not advance them to a later block.

Measure backfill progress from completed handlers and historical checkpoints as well as fetched blocks. Fetch-cache progress alone does not prove that indexed rows have caught up. Backfill duration and sustained throughput remain unproven until measured on the production history; `/ready` must report completion before serving it as caught up.

### 7.5 indexer verification

Decision 228 defers historical indexer acceptance beyond coin launch when the verified website chain fallback, keeper and alerts remain available. The historical verification below is not a coin-launch prerequisite under that decision; it remains unproven until replay completes. Decision 226 separately permits the bounded temporary Alchemy fallback.

1. Probe each endpoint for archive support: `eth_getStorageAt` on the Core at a pinned old block returns a value.
2. Measure each endpoint's real limit: send `eth_blockNumber` at rising rates and record the rate where 429 responses start. Set each cap to 70 % of it.
3. Run a full backfill against mainnet with only public endpoints and log requests per endpoint, failovers and 429s. Pass: zero failed handlers, under 1 % failovers.
4. Log a warning on every failover and a counter per endpoint, so a slide onto the paid reserve shows up in logs and on `/health/rpc`.

## 8. correctness

### 8.1 reorgs

Ponder rolls back writes inside `reorgWindow`. Snapshot rows written by block handlers roll back the same way. The snapshot gate checks the persisted row for the block; an RPC or write failure, or a same-height rollback, leaves the block eligible for retry. It does not cache the last attempted height in process memory.

### 8.2 ordering facts the handlers rely on

- `EthRateFill` (in value mode `ValueRateFill`, decision 148) precedes its `CreditBought` in the same tx; a bought credit with a preceding fill in the tx is an `eth_bid`, with a `BalanceFill` after it a `balance_bid`. `CreditBought.cost` is the pile cost basis (eth bid: the price plus the artist royalty; balance bid: the eth floor basis) and `CreditBought.toArtist` the royalty in the route's currency; `ListingBought.toArtist` is the royalty on the listing price and the pile basis is `cost + toArtist + paid` (decision 163, docs/reviews/SPEC-royalty-balance-161.md).
- `Bought` (controller) and `StatementSoldTo` (Core) are one sale; the activity row comes from `StatementSoldTo`.
- `CreditSwapped`: the in credit takes the out credit's pile key, cost basis and acquisition time.
- `Migrated` moves credits with no per-id event; Credits `Transfer(core, successor)` in the same tx gives the ids.
- `Composed.ids` is in pile order; it removes those 80 credits from the pile.

### 8.3 deploy-time state

Constructor values and a new controller's constructor settings emit no event. The handler for the first event of a Core or controller reads them by call at that block.

### 8.4 reconciliation

Every 300 blocks a block handler compares projections with views at the same block and writes a `parity` row: `pileSize` vs count of held credits, `heldStatements()` vs held statements, first page of `pilePage` vs `pileOrder`, `ethPot` vs the latest snapshot. `/health/parity` returns the last row and fails when any check failed. A failing check is a bug to fix in the handler, then reindex.

### 8.5 tests

- Pure helpers (`src/lib`): unit tests with `node --test`, as in shapes.
- Static handler check (`npm run check:handlers`, `scripts/check-handlers.mjs`): every `ponder.on` in `src/index.ts` registers an event present in that source's ABI, by the exact name Ponder expects (the plain name, or the full signature for an overloaded name on the Controller and Treasury union sources), and no event is registered twice. Parses the source and the generated `abis/*.ts`; runs no chain or database.
- End to end: the candidate flow seeds a local Anvil fork, starts Ponder against Postgres, and checks `/ready`, `/health/parity`, and SQL reads against Core state (`script/dev/check-indexer.sh`). `script/dev/e2e.sh` itself exercises the contracts and does not start Ponder.

## 9. frontend data contract

Source key: **I** indexer table.column, **L** live chain read through the website `/api/rpc`, **K** the keeper's read-only market view through the website `/api/listings`, **D** derived in the browser from the named inputs. A value marked L today that moves to I is listed with its new source. Every I row has an on-chain fallback that runs in chain mode (section 11, owner decision 133); the tables name the indexer source. Wired in phase 2: the rows below as written.

Mainnet browser reads use the same-origin read-only RPC API, with Tenderly first, bounded queues, physical-request pacing, identical-read deduplication and short caches. Server metadata and listings reads share that dispatcher. Its memory and throttle are per warm Netlify instance; this is not a deployment-wide quota or a guarantee against public-provider outages. Local Anvil reads and wallet signing remain direct.

### 9.1 shared

| value | source |
|---|---|
| block number in footer | L `getBlockNumber` (existing head poll) |
| contract addresses | L snapshot (Core reads, one multicall) |
| browser indexer identity gate | I `getStatus` chain id and `engine.core`, `engine.coin`, `engine.deployBlock` for the configured Core; L snapshot `Core.COIN()`; D compare with the website chain, `NEXT_PUBLIC_CORE` and `NEXT_PUBLIC_DEPLOY_BLOCK` before using any indexed history |
| settings, controller params | L snapshot; also I `engine.settings`, `controller` (not read by the web yet) |
| pot (live, with unbooked income) | L snapshot; D `potWithPending` |
| reserve and the room the bids read (packet B, decision 154) | L `Core.reserve()` in the snapshot; D `potRoom` = `potWithPending` less the reserve, the clamp of the eth bid and the cap of a listing sweep |
| buying room and processing reserve | L snapshot `potWithPending`, `reserve`, `potRoom`. The home shows only the spendable room as "pot" (decision 242); the keeper page labels the gross pot, room and reserve separately |
| value mode and the quote (packet C, decision 148) | L snapshot: `settings.valueModeOn`; `noQuote` when value mode is on and the protected buy quote is unusable, while `ethRate` can use its last good value; controller `valuePerPoint(false)` and `valuePerPoint(true)` for `value.usable` and the per point values; also I `controller.quote*` (QuoteSet) |
| balance token reference against spot (packet C, decisions 148 and 157) | L controller `referencePrice()`, `referenceTime()`, `spotPrice()` and `quote()` in the snapshot (`value.referencePrice`, `value.spot`); shown on the balance page; also I `controller.referencePrice`, `referenceSpot`, `referenceTime` at the last `ReferenceRefreshed` |
| ETH/USD | L Chainlink |
| rating display | D `score / 10000` from I `credit.score` (chain mode: `CreditScore.scoreOf`) |
| header bid per 100 points | L snapshot `ethRate`; D per-point display is `ethRate / 100` |
| strategy listings (listings page and feed tab) | I `strategy_listing` where `active`, with `credit.score`; chain mode: browser `getLogs` of the two strategy events from `NEXT_PUBLIC_STRATEGY_START_BLOCK`, replayed in log order; both re-read live at each head: `nftForSale`, Credits `ownerOf`, Core `bidOf`, `ethPot`, `retired`, `allowedAdapter` |
| listing spend cap | L `Core.spendState()` in the listings multicall; a listing over the bucket's remaining budget waits for the next bucket; a row's acquire button simulates `buyListing` before sending |
| OpenSea asks (feed tab, listings page) | K keeper market view (`keeper/src/market-view.ts`, `Sources.marketView`: the keeper's compatible Seaport catalog less quarantined, transferred and expired orders, ranked by exact price per point with its cached immutable scores, plus discovery status) through the server route `web/app/api/listings` (`KEEPER_MARKET_URL` and `KEEPER_MARKET_TOKEN` server only, one keeper read per 5 s window per warm instance, identity gate on chain, Core and adapter, last good view kept and marked stale through failures); the browser polls the route every 10 s through one shared query (`web/lib/market-view.ts`). `?fulfill=<orderHash>` serves the keeper's prepared fulfillment of a signed order in the current view. Decision 235 |

### 9.2 home

| value | source |
|---|---|
| pre-launch banner and disabled CC trading | L `useCoinLive()` checks bytecode at snapshot `coin` through the read-only website RPC API, polling every 15 seconds until code exists; an unset Core also uses pre-launch. Unknown status remains disabled/loading. The banner disappears and normal market discovery resumes when live becomes true, without a reload |
| empty-ledger artwork and placeholder rows | D presentation only while `useFeed` has no rows, before or after coin launch; placeholders are not transactions. The existing reduced-motion-aware `CCLogo` is reused. Ledger is the default feed view; a manual choice of Listings persists through polling. Mobile is one scroll that shows the latest 6 ledger rows until "view full ledger" (decision 242) |
| credits held, statements held | L snapshot `pileSize`, `heldStatements` |
| $CC bought + burned and % | I `stats.ccBurned` (chain mode: Core buyback burns scanned, swap-fee burns not included); D % over the launch supply constant |
| ETH recycled and its sale count | I sum and count of `statement.toPot` where set (only StatementSoldTo sets it); chain mode: D `price - toBuyback - toArtist - toOperator` per StatementSoldTo in the scan. A controller-only `Bought` sale has no split and is left out |
| points held by engine | D sum of the pile credits' scores (I `credit.score`; chain mode `CreditScore.scoreOf` over `Core.pilePage`, unknown while the pile exceeds its first page) plus L `Core.ratingOf` of each held statement (current, so an overprint counts); shown as score / 10,000 |
| pot row and step 02 chip | L snapshot `potRoom` (spendable room; the reserve is not shown) |
| statement sale split (intro line 3, proportion bar) | L snapshot `settings.saleToBuybackBps`; the caption states it applies after the artist and operator cuts |
| $CC burned so far (split caption) | as $CC bought + burned |
| ledger $CC burned rows | I `activity` kind `buyback`: `amount` ETH spent, `amount2` the Core's coin burn in the same tx (`transaction_fact.coreBurn`); chain mode: `Buyback.amountIn` and the scanned coin `Transfer` to zero from the Core in the same tx. No source statement is named: a buyback pools every sale's share |
| ledger statement sold rows | I `activity` kind `statement_sold` (`amount` price, `amount2` toBuyback) joined to `statement.toPot`; chain mode: StatementSoldTo |
| ledger rows | Currency is I `activity.balanceToken` for BALANCE purchases/redemptions (chain mode: prior `BalanceModuleSet` in log order); amount is `BalanceFill.paid` per credit (the seller's posted payout; the artist royalty `BalanceFill.toArtist` is an additional obligation that may remain claimable debt) or `StatementRedeemed.received`. Historical metadata is used only for the matching token, otherwise show exact raw units and token address. I `activity` joined to `statement`, `statement_format` and `log`; score and plates by id from I `credit` (`useScores`, `useCreditTraits`); art from I `credit.tokenUri`, `statement.tokenUri`; paged by row limit |
| next credit progress | D pot over bid from L snapshot |
| next statement progress | L snapshot `pileSize` mod 80 |

### 9.3 credits index

| value | source |
|---|---|
| held credits, newest first, paged | I `credit` where `held`, order `pileOrder` (no 200 cap; chain mode keeps the `pilePage` cap) |
| price per credit | L `creditPrice(id)` for every held credit (the pile is bounded by compose) |
| paid, got by, bought time, rating | I `credit` |
| buy rate per hour | I `stats_hourly` last 24 hourly buckets |
| compose estimate | D from I pile position, pile size, `controller.window`, `saleOn`, buy rate |
| header meta | D held count from the pile; the next compose estimate (above) |
| market report: median paid, sales and change by rating band | I `credit` where `acquiredHow` is `eth_bid` or `listing` and `acquiredAt` within 14 days, counted in SQL by rating band, week and `costBasis` bucket of 0.0001 ETH (`useMarketIx`; the SQL API has no percentile function, so D the median from the counts, `web/lib/market-report.ts`); chain mode: the newest 200 scan purchases with their scores |
| market report: engine ask, vs median | D the cheapest held credit's L `creditPrice` per band, and each held credit's price against its band's median |
| market report: market ask | K keeper market view through `/api/listings` (9.1): D the cheapest scored, unexpired OpenSea ask of its best rows and CreditStrategy row per band |
| sort orders | D from the values above (`web/lib/credit-sort.ts`) |

### 9.4 credit detail

| value | source |
|---|---|
| facts, holder, history | I `credit` (cost, time, how, tx, owner), `activity` where `creditId` or `otherCreditId`, `statement` for the composed step |
| plates | I `credit.mask` |
| prev / next | I neighbours by `pileOrder` |
| price curve | D from I `costBasis`, `acquiredAt`, `controller` params; L `valueOf(score)` for the floor (live pool term) |
| sold split | I `credit.salePrice`, `toArtist`, `toOperator`, `toPot`, `toBuyback` (chain mode: archive read in `useCreditCostToPotAt`) |
| composes into statement N | I next statement id (`stats.composed + 1` cross-checked with Statements supply) |
| swap panel: wallet credits with rating | I `credit` where `owner = wallet` (chain mode: `tokensOf`); L approvals |

### 9.5 statements index and detail

| value | source |
|---|---|
| lists by state, counts, next compose | I `statement`, `stats.composed`; D estimate |
| rating, format, format name, cost, composer, mode, credits | I `statement`, `statement_credit` |
| price, at floor, reference | L controller `priceOf`, `referenceOf`, `atFloor` for held statements (time and pool dependent) |
| price curve | D from L reference and I `controller` params, statement age (I `composedAt` and pause history from `setting_change`) |
| sold and redeemed details | I `statement`; redemption currency from I `activity.balanceToken`, captured from the prior `BalanceModuleSet` in log order; chain mode replays the same setter logs |
| history: composed, restyled, anchor moved, sold, redeemed | I `activity`, `statement_format`, `anchor_move` |
| holder | I `statement.owner` |
| art | I `statement.tokenUri` |
| forming statement (an id at or past the next one): page, credits, state | L snapshot `nextStatementId`, `pileSize`, `page.ready`, `paused`, `creditWindow`; the pile from I `credit` held by the Core, oldest first (chain mode: `Core.pilePage`, first 200); D page `id - nextStatementId` of 80 (`web/lib/forming.ts`) |
| forming cost, rating and compose estimate | D sum of the page's I `credit.cost` (chain mode: `creditInfo`) and I `credit.score` (indexer mode only); D `composeEta` from the page's newest acquisition time and I `stats_hourly` buy rate |

### 9.6 sell, compose, balance, keeper

| page | indexer | live |
|---|---|---|
| sell | wallet credits with scores (I `credit` by owner) | bids and quotes (`bidOf`, anchor slots; in value mode `balanceRate` and controller `valuePerPoint(false)`), approvals; per-credit batch fills D from the same quote reads (eth: `replayEthFills`; balance: `replayBalanceFills` over the L snapshot `balanceRate` and `balanceUnit`; value mode: `replayValueFills`); USD at the L Chainlink ETH/USD feed, the balance side through the L balance pool spot |
| exchange (local development; public route disabled by default) | same wallet Credits and scores as sell through `useWalletCredits` | L snapshot module/token, posted rate/unit, available reserve, bid/pause/retirement, artist royalty and protected value. D existing `replayBalanceFills` gives the payout, protocol fee is gross less posted payout, price protection is posted less executable payout; reserve check includes per-Credit artist royalties on top. Before an executable quote, show selected point ratings/their sum and the configured fee percentage, with an explicit unavailable notice. Exact minimum uses 0/0.5/1-percent tolerance. Approval is followed by full-batch `sellForBalance(ids,minOut,expectedToken)` simulation; pending display and consent freeze and wallet/network changes stop further sends. No new indexer table. |
| exchange claim panel "Burn CC for BALANCE" (phase 2, same gate) | history only, not read by the web yet: I `treasury_event` (one row per treasury event; public burns are kind `cc_redeemed`, the owner's reserve changes are `claims_funded`, `claims_allocated`, `claims_returned`, `working_withdrawn`) and I `treasury_state` (per treasury named by `BalanceModuleSet`: event-carried `claimReserve`, `totalOwed`, `configEpoch`, `policy`, `conversionToClaimBps`, `redemptionFeeBps`, the three switches, `migrated`, and the running totals `convertedTotal`, `contributedTotal`, `redeemedCcTotal`, `paidBalanceTotal`); I `controller.statementSalesEnabled`, `statementSaleMultiplierBps`, `statementRedeemDelaySeconds` for a ControllerV2 | every value shown is L through the Core's `balanceModule` read as a `Phase2BalanceTreasury` (`useTreasury`, `useClaimQuote` in `web/lib/live.ts`), see the table below |
| compose | pile with order and window state (I) | `nextPage` readiness, CC balance |
| balance | $BALANCE price history (phase 2) | pool, quotes, module available |
| keeper | `engine.lastBuybackBlock` (I; chain mode: Core view), `stats` payouts | pots, artist, payee, head |

### 9.6b exchange claim panel

The claim panel's values, every one a live read (L) through `/api/rpc`, polled every 15 s. The panel hides behind a notice when the module does not answer `quoteRedemption` and `claimReserve` (no module, or the StatementBalanceModule).

| value | source |
|---|---|
| BALANCE token address and symbol | L treasury `balanceToken()`; L erc20 `symbol()` and `decimals()` of that token (tolerant) |
| redemption policy address and version | L treasury `redemptionPolicy()`; L policy `VERSION()` (tolerant; `pro-rata-v1` is the first policy, any other version is labelled) |
| claim reserve | L treasury `claimReserve()` |
| free working funds | L treasury `freeWorking()` |
| CC total supply, symbol, decimals | L coin `totalSupply()`, `symbol()`, `decimals()` at the treasury's `ccToken()` |
| contribution rate | L treasury `conversionToClaimBps()`; D `bps / 100` percent |
| redemption fee | L treasury `redemptionFeeBps()`; D `bps / 100` percent |
| backing per CC | D `claimReserve * 1e18 / ccSupply` from the quote's reserve and supply (`backingPerCc` in `web/lib/exchange.ts`) |
| your CC | L coin `balanceOf(wallet)` |
| quoted BALANCE out | L treasury `quoteRedemption(ccIn)` for the entered amount (`balanceOut`, `reserve`, `supply`, `epoch`, `executable`); D `proRataQuote` = `floor(ccIn * reserve / supply) * (10000 - fee) / 10000` stands in until the read answers and flags a mismatch (`claimQuote`) |
| minimum you receive | D `balanceOut * (10000 - tolerance) / 10000` at the 0, 0.5 or 1 percent tolerance of `EXCHANGE_SLIPPAGE`, exact |
| terms epoch | L `quoteRedemption(ccIn).epoch`, pinned at consent and passed as `expectedConfigEpoch`; a changed epoch stops the burn before any send (`redeemClaim`) |
| disabled states | L treasury `ccRedemptionEnabled()`, `selectedForClaims()` (fallback `selected()`), `transfersReady()`, `solvent()`, `migrated()` and the quote's `executable`; wallet and chain from wagmi |
| approval | L coin `allowance(wallet, treasury)`; an `approve(treasury, ccIn)` for exactly the amount only when short |
| burn | L simulate then send treasury `redeemCC(ccIn, wallet, minOut, now + 20 minutes, epoch)`; the receipt's own `CCRedeemed` log gives the burned and received amounts shown after confirmation (`decodeRedemption`) |

### 9.6c phase 3 treasury (BalanceTreasuryV2, ControllerV3)

The exchange shows the better of the Core's 80% offer and the v2 $BALANCE bid; `/claim` reads redeemer 1 (the pro-rata redeemer, shipped off) and, when it is registered and `on`, redeemer 2 (MarketRedeemer, an immediate market-rate burn at a premium); market-compare reads the v2 bid. As in phase 2, current balances and prices are live reads (L) through the Core's `balanceModule` and `controller`; the indexer serves the registry, parameters and cumulative history. The web resolves the v2 treasury, V3 controller and pro-rata redeemer addresses from `deployments/1-phase3.json`, and finds redeemer 2 on-chain by scanning `redeemerList(i)` for `i < redeemerCount()` for the entry that answers `premiumBps()` (the indexer discovers the treasury and controller through the Core factory sources, and takes redeemer 2's address from that same record). Addresses are unset until the owner deploys; the panels hide behind a notice until the module answers the v2 views.

| value | source |
|---|---|
| per-redeemer bucket and cumulative in/out | L treasury `redeemers(address)` (`bucket`, `totalIn`, `totalOut`), polled; the registry (which redeemers, `on`, `activeAt`, `shareBps`, caps) and the redemption/allocation history are I `redeemer` and I `treasury_event` (kinds `redeemer_registered`, `redeemer_caps_set`, `redeemer_switched`, `shares_set`, `allocated`, `unallocated`, `cc_redeemed`, `claim_released`). The shipped redeemer 1 address is I `treasury_state.proRataRedeemer` (chain: `treasury.proRataRedeemer()`) |
| redeemer 2 live rate, premium and remaining daily cap | L MarketRedeemer `preview(ccIn)` (BALANCE out for a burn, and `ok`) and `premiumBps()`; the daily cap left is `perPeriod − periodUsed` from the treasury's `redeemers(address)` when the period is current. The burn is `BalanceTreasuryV2.redeemCC(redeemer2, ccIn, recipient, minOut, deadline, treasuryEpoch, abi.encode(configEpoch))`, with `minOut` the preview less a tolerance and the coin approved to the treasury. The premium and its epoch are also I `redeemer.premiumBps` / `premiumEpoch` for history |
| bid budget and cumulative in/out, bid price | L treasury `bidBudget()`, `bidIn()`, `bidOut()` and `bidBpsNow()` (the current price per point is `bidBpsNow / 10_000 * unitPerPoint`), with `bid()` for floor/cap/overEth; I `treasury_state.bidBudget`, `bidInTotal`, `bidOutTotal`, `bidFills`, `bidCreditsTotal` and the `bid_fill` / `swept` / `bid_set` `treasury_event` rows for history and charts |
| cushion, working, committed payouts | L treasury `cushion()`, `working()`, `available()`, `totalCommitted()`, `totalBuckets()`, `surplus()`; I `treasury_state.cushion` and the `cushion_set` / `swept` history. Committed vesting and deferred claims are I `treasury_event` kind `claim_released` (cumulative `claimReleasedTotal`) with the current open amount read live (`claimOf`) |

### 9.6a listings page

| value | source |
|---|---|
| listed credits, both venues | I `strategy_listing` where `active` (chain mode: the strategy event scan) and the keeper market view through the `web/app/api/listings` route (9.1): the best `VIEW_LIMIT` (1,000) of the keeper's compatible OpenSea asks by price per point, with the catalog total stated; one row per credit at its cheapest price |
| listings status lines | D from the route answer (`viewLines` in `web/lib/market-view.ts`): coverage, view read time, the keeper's last applied change and reconciliation, stream live / disconnected / gap, backoff, last discovery failure, and the time or failure of the last chain read with a retry; stale or disconnected data is never labelled live |
| Seaport order status | L `Seaport.getOrderStatus(orderHash)` for the live OpenSea rows in the same multicall; a cancelled or filled order leaves the table |
| rating | I `credit.score`; chain mode `creditScores` |
| bid | D `ethRate * score / RATE_SCORE` (`RATE_SCORE` is 1,000,000 stored score units, or 100 points) from the L snapshot for every row; L `bidOf`, `ownerOf` and `nftForSale` for the 100 rows nearest the bid |
| balance bid column and header line | L `Core.balanceBidOf(id)` for the 100 rows nearest the bid, in the same multicall (allowFailure, read only with a module set and `balanceBidOn`); D `score * balanceUnit * balanceRate / 10,000` for the other rows (marked ~); header "balance bid R% of par" from L snapshot `balanceRate` |
| fills today | I `stats_hourly.creditsEth` and `creditsBalance` summed over the hours since 00:00 UTC; hidden while the indexer is not serving |
| gap, counts, histogram | D price over bid |
| clears in | D `web/lib/climb.ts` (mirror of `CoreLib._climb`) from L `rateAtCheckpoint`, `checkpointTime`, `lastFillTime`, `climbMultiplier`, storage slot 10's `climbRestartTime`, anchor slots 28, 30, 31, settings, booked `ethPot` and snapshot reserve and pending pot income; assumes no fills, fee booking or pot change |
| credit floor multiplier | L controller `floorMultBps()` in the snapshot (`creditFloorBps` of the snapshot): `(10,000 + creditSpreadBps)` of the Core's `balanceBidCapBps` |
| spend headroom ("pot covers N, this minute M", "next bucket" rows) | L `Core.spendState()` (bucket, budget, spent), the settings `spendCapBps`, `bucketSeconds`, `keeperFee`; D `fitsBucket` and `bucketCount` in `web/lib/acquire.ts`; the same read decides the header button |
| acquire action | L `Core.buyListing`, simulated before the header button enables and again before sending, shared with the header button (`useAcquireTx`) |

### 9.7 swap panel

Live only: slot0, quoter, hook fee, balances, allowances, receipts. The price change beside the price is D from L `StateView.getSlot0` now against `getSlot0` at the block 7,200 back; for a pool younger than that, against the `sqrtPriceX96` of its L PoolManager `Initialize` log (`eth_getLogs` in spans under 5,000 blocks, kept in localStorage), labelled since launch. The market cap links to the token's DexScreener page and the token contract to evm.now. Phase 2 adds I `price_hourly` for a 24 h change and a chart, replacing the archive `getSlot0` read.

### 9.8 page metadata and share images

Server side (`web/lib/meta.ts`), cached 60 s, each source under a 2.5 s timeout. The indexer is read first; the chain second.

| field | source |
|---|---|
| credit and statement title, rating, state, format name | I `credit`, `statement` row (`score`, `rating`, `state`, `formatName`) |
| token art of the share image | I `tokenUri`; L `tokenURI` when the row is absent |
| held and composed counts on the index share images | I count of `credit` rows in `held`, count of `statement` rows |

### 9.9 documentation

The `/docs` section is static, curated content in `web/lib/docs-content.ts` plus a signature catalog generated into `web/lib/docs-catalog.ts` by `web/scripts/gen-docs-catalog.mjs`. Core, ControllerV2, Phase2BalanceTreasury and adapter references use public `src/interfaces/` on main `0dba672`; the balance module has a curated page but no generated full-interface catalog or separate balance sale, Statement conversion or claim guide. Credits, Statements, Core, CC and adapter addresses and the coin launch block come from `deployments/1.json`; the selected ControllerV2 and treasury addresses come from `deployments/1-phase2.json`. The phase 2 record's activation fields describe its recorded stage, not current switch state. The CreditScoreLens interface snapshot in `web/docs-sources/ICreditScoreLens.sol` matches the deployed helper's historical interface at `5875fbd`. Its Ethereum mainnet address comes from the recorded deployment in `docs/DEPLOY-credit-score-lens.md` at `5875fbd`, confirmed against Sourcify's matching creation and runtime record on 2026-10-18. Search runs locally over the content and catalog. The docs UI does not read the indexer or chain. Check current deployment state and settings separately before a transaction.

## 10. deploy

One path, as in shapes PR #59 and the owner's deploy rule:

- `indexer/deploy.sh <env>` reads `deployments/<chainId>.json` (Core, deploy block, coin, collections, pool key) and `indexer/env/<env>.env` (values only: chain id, Fly app, RPC caps, database schema name).
- It refuses when the record is missing, when the database schema name was already used for a different Core address (tracked in `indexer/deployments.json`), or when a required value is empty. `DRY_RUN=1` runs every check without deploying.
- Each deploy starts under a new `DATABASE_SCHEMA` and the public API switches to it after the backfill is ready (`/ready`), so a reindex never takes the site down.
- After Fly deploy it binds the database schema to that Core in `indexer/deployments.json`. Historical catch-up can outlast the deploy command. Before accepting indexed data, run `RPC_URL=<read rpc> indexer/check-live.sh mainnet`; decision 228 permits coin launch during historical backfill when the live website chain fallback, keeper and alerts pass, with indexer acceptance explicitly deferred. It requires readiness, recent parity, SQL Core and coin identity, an indexed head within five blocks, and pile and ETH pot agreement with fresh chain reads. Retry that read-only check after catch-up without redeploying.
- Local: `script/dev` writes `deployments/31337.json` for the Anvil fork; `indexer/deploy.sh local` can start Ponder against it. For the web SQL path, use Postgres: the PGlite path has a `credit` temp-table collision and leaves web health in chain mode. The candidate gate uses Postgres.

Prerequisites before mainnet: `deployments/1.json` with the mainnet Core, deploy block, controller block and module block; the collection deploy blocks.

### 10.1 running the chain 1 indexer directly (fork rehearsal)

`indexer/` is its own npm package, outside the root workspaces, so a run installs its dependencies with `npm ci` in `indexer/`.

A chain 1 run with Postgres reads three values the local PGlite path supplies on its own:

- `DATABASE_URL`, the Postgres connection string (`ponder.config.ts` requires it on a real chain).
- `DATABASE_SCHEMA`, the schema name. `ponder start` with Postgres requires it; the Fly path passes it from `indexer/env/mainnet.env`, and a direct `ponder start` sets it in the environment or with `--schema`.
- the collection and strategy start blocks `CREDITS_START_BLOCK` (26037292), `STATEMENTS_START_BLOCK` (26100733) and `STRATEGY_START_BLOCK` (26037623). Chain 1 requires each; the local path defaults them from the Core deploy block.

Live chain 1 uses the public endpoint list of section 7.1 through `fallbackTransport`; `PONDER_RPC_URL_1` joins last as a reserve. Chain 31337 uses the record's `rpcUrl` or `RPC_URL` through `guardedHttp`. A chain-id-1 fork requires an explicit loopback `RPC_URL` matching the record's `rpcUrl` and uses that single transport with no public fallback. A full history backfill from block 26037292 is bounded by the public endpoint rate caps: the Ponder log reports `Unable to find available JSON-RPC provider` and the fetch of each 5000 block window grows to tens of seconds, so the full backfill wants an archive endpoint with headroom above the section 7.1 caps.

A direct run against a fresh database:

```sh
cd indexer && npm ci
CHAIN_ID=1 DEPLOYMENT_RECORD=../deployments/1.json \
  DATABASE_URL=postgresql:///<db> DATABASE_SCHEMA=<schema> \
  CREDITS_START_BLOCK=26037292 STATEMENTS_START_BLOCK=26100733 STRATEGY_START_BLOCK=26037623 \
  node_modules/.bin/ponder start      # /graphql, /sql and /status on PORT (default 42069)
```

## 11. web changes

The browser keeps the on-chain read paths as an automatic fallback for every indexer read (owner decision 133, 2026-10-15). Nothing may break while the indexer is down.

1. `NEXT_PUBLIC_INDEXER_URL` (`web/scripts/local-env.mjs` writes `http://localhost:42169` locally) and a typed client from `@ponder/client`. The indexer schema imports the `ponder` runtime, which does not bundle for the browser, so `web/lib/indexer-schema.ts` declares the columns the web reads as drizzle tables, and a compile-time guard fails `tsc` when a column type differs from `indexer/ponder.schema.ts`.
2. One app-wide mode (`useIxMode`, set by `web/components/IndexerSync.tsx`):
   - `ix` when the indexer answers `getStatus`, is at most 5 blocks behind the chain head (`useHead`), identifies the configured Core, its on-chain coin and deploy block, and its count of held credits equals `Core.pileSize`; `chain` when it is unconfigured, unreachable, behind, inconsistent, or one of its queries failed in the last 5 blocks; `checking` until the first health result (no source runs).
   - Each data hook reads the indexer in `ix` mode and its on-chain path in `chain` mode, with the other path's react-query `enabled` off. A healthy indexer therefore causes no `eth_getLogs`, no per-row `getBlock` and no `tokensOf`, `ownerOf` or `tokenURI` reads. Components call one hook and never branch.
   - Hooks: `useStats`, `useFeed`, `useBuyRate`, `useCreditDetail`, `useStatementIndex`, `useStatementView` (`web/lib/data.ts`); `usePile`, `useCredit`, `useWalletCredits`, `useScores`, `useCreditTraits`, owners, `useCreditCostToPotAt` (`web/lib/live.ts`); `useTokenMeta` (`web/lib/art.ts`).
3. Live reads stay in both modes: the snapshot multicall, `creditPrice`, `priceOf`, `referenceOf`, `atFloor`, `bidOf`, `valueOf`, market hooks, balances, allowances, approvals, receipts.
4. The browser transport is `fallback([primary, Tenderly public, publicnode, llamarpc])` on mainnet (`web/lib/wagmi.ts`); local anvil is one transport.
5. Freshness: one `@ponder/client` live query (server-sent events) on `engine.snapshotBlock` invalidates the indexer queries; while the stream is down a new chain head does.
6. "history unavailable" shows only when both sources fail (indexer mode off and the browser scan failed).
7. Chain mode keeps today's limits: the pile list is the first 200 credits of `pilePage`. Values with no on-chain equivalent degrade: the credit sale split of a sold credit uses the current `creditCostToPotBps` (marked "~") when the sale block's state is unreadable; the buy rate comes from the scanned buy events; formatName comes from the `tokenURI` Format attribute.

## 12. phases

1. Core, controller, burns, collections, snapshots, `log`, `activity`, `credit`, `statement`, `stats`; parity endpoint; local e2e.
2. Web switches to the indexer (section 11); browser scan removed.
3. Pool `Swap` sources, `price_hourly`, account views.
4. Mainnet deploy after the mainnet record exists.

## 13. open items

1. Confirm the Credits and Statements event ABIs against the deployed contracts, and read both collection deploy blocks.
2. Measure the public endpoint limits (7.5) and set the caps.
3. Pick Fly Postgres or Neon.
4. Confirm `@ponder/client` live queries in the pinned Ponder version.
5. Decide whether the coin's v2 factory, hook and escrow data come from the artcoins indexer or are indexed here as well.
6. The mainnet deployment record.

Balance token replacement schema update: replay the indexer from the Core deployment to populate `activity.balanceToken` and token-keyed payout totals before serving this web version. Existing raw amounts are kept as stored. Browser scan and query cache keys are versioned so pre-replacement history is discarded.
