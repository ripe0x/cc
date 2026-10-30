# Envio HyperIndex port of `indexer/`

This directory ports the Ponder indexer in [`indexer/`](../indexer/README.md) to
[Envio HyperIndex](https://docs.envio.dev). It indexes the same contracts from
the same start blocks into 18 of its 19 tables (`parity` is not ported, see
below), with the same columns and values. Event logs come from HyperSync. Everything the
original reads with `context.client` (pots and rates at each Core event, token
facts, `tokenURI`, controller and treasury state) comes from an Ethereum
archive RPC through the Effect API. The project targets `envio` 3.15.0.

`indexer/` is untouched. The port sits beside it so both can run while the
results are compared. It has its own pnpm lockfile (the Envio CLI expects
pnpm) and is not part of the npm workspaces.

## Run it

You need Node.js 22.15 or later, pnpm 10, Docker (for `pnpm dev`) and an Envio
API token for HyperSync (<https://envio.dev/app/api-tokens>).

```bash
cd envio
pnpm install
cp .env.example .env          # set ENVIO_API_TOKEN; optionally ENVIO_RPC_URL
pnpm dev                      # starts Postgres and Hasura in Docker, then indexes
```

Hasura serves GraphQL at <http://localhost:8080> (local admin password
`testing`). A cold sync of the full history, block 26,037,292 to head, took
about 7.5 minutes (measured with `ENVIO_HASURA=false`); see
[Benchmark](#benchmark).

To use your own Postgres instead of Docker, set `ENVIO_PG_HOST`,
`ENVIO_PG_PORT`, `ENVIO_PG_USER`, `ENVIO_PG_PASSWORD` and `ENVIO_PG_DATABASE`
(plus `ENVIO_HASURA=false` if you run without Hasura), then `pnpm start -r`.
`-r` wipes the database and re-indexes from scratch.

```bash
pnpm codegen      # regenerate types after editing config.yaml or schema.graphql
pnpm typecheck    # tsc --noEmit
pnpm test         # vitest: split maths, compose mode, migration patches, event arguments, batching
pnpm parity -- --original <ponder url> --pg <postgres url>   # compare with a running Ponder indexer (500 ms between requests; --delay-ms)
```

### RPC

HyperSync serves every log, but the original also makes `eth_call` reads, and
HyperRPC does not offer `eth_call`, so an archive RPC is needed:

| Read | When | Per |
| --- | --- | --- |
| Credit seed, paid time, `tokenURI`, `ownerOf` (event block); score and traits (latest) | first sight of a Credit id | Credit, grouped by block |
| Statement rating (latest), format, `tokenURI`, `ownerOf` | first sight of a Statement id | Statement |
| Core pots, rates, balances, flags, controller and treasury views | every block with a Core event, and every 300th block | block |
| Core constructor values, controller and treasury parameters | first Core event, `ControllerSet`, `BalanceModuleSet` | event |
| Block timestamp | every 300th block (block handlers receive only the number) | block |

Each read is an Effect (`src/lib/reads.ts`): cached in the database, so a
restart or a re-index does not repeat it, and deduplicated. During preload the
Credit reads of one block leave as a single Multicall3 (`Batcher` in
`src/lib/rpc.ts`, 40 Credits per call). Score and traits are read at the
latest block because the CreditScore contract is younger than the first
Credits; this is what `cache: "immutable"` does in the original.

`ENVIO_RPC_URL` takes one archive endpoint or a comma-separated list, tried in
order. If it is unset the port uses Tenderly's public gateway, `eth.drpc.org`
and Blast's public endpoint. These work but rate-limit hard (see the
benchmark), so a dedicated archive node will be faster. A failed request is
retried against the next endpoint and, after a full round, with backoff; after
eight rounds the indexer stops. A transport error is never treated as a
revert: where Multicall3 reports a failed `tokenURI` or `ownerOf`, the call is
repeated alone and only a real `execution reverted` becomes `null`. This
matters, because a node's per-call gas cap makes big batches of `tokenURI`
fail silently.

## What maps to what

| Ponder (`ponder.config.ts`, `src/`) | HyperIndex |
| --- | --- |
| `Core` (41 events, all handled) | `Core` in `config.yaml`, `src/handlers/core.ts` |
| `Controller` factory on `Core.ControllerSet` | `Controller` without an address, `indexer.contractRegister` in `src/handlers/factories.ts` |
| `Treasury` factory on `Core.BalanceModuleSet` | `Treasury`, registered the same way; the five events the two treasury versions emit with different signatures are `StatementConvertedPhase2`/`V2`, `CCRedeemedPhase2`/`V2`, `SwitchesSetPhase2`/`V2`, `TreasuryMigratedPhase2`/`V2`, `MigrationReceivedPhase2`/`V2` |
| `Coin` with `filter: Transfer(to = 0)` | `Coin.Transfer` with `where: {params: {to: ZERO}}` |
| `Credits`, `Statements`, `Strategy` | the same, `src/handlers/tokens.ts` |
| `Tick` block interval 300 from the Core deploy block | `indexer.onBlock` with `_gte: 26229330, _every: 300` |
| `ctx.db.insert/update` | `ctx.Entity.get/set`; `set` is synchronous |
| `context.client.multicall` | Effects with Multicall3, `src/lib/reads.ts` |
| `ponder.schema.ts` | `schema.graphql` (generated from it, then edited by hand) |
| `src/lib/{split,mode,migration,tokenuri,balance-history}.ts` | copied unchanged, with their tests (now vitest) |
| `abis/*.ts` | `src/abis/*.ts` (reads, typed) and `abis/*.json` (events, for `config.yaml`) |

Details that matter for exact parity:

- **Event arguments.** `log.args` holds the arguments as viem decodes them:
  integers of 48 bits or fewer as numbers, wider ones as decimal strings.
  Envio decodes every integer as a bigint, so `src/lib/args.ts` converts them
  back using the ABI.
- **Same-log rows.** A log that writes `setting_change` twice
  (`BalanceModuleSet`) keeps the first row, as `onConflictDoNothing` does.
- **Order.** Handlers run in block and log order across all contracts, and
  `Tick` snapshots fall where they do in Ponder: `engine_snapshot` matched row
  for row.

## Differences a consumer will notice

The stored data is the same. The API around it is not.

- **Names.** Tables are `Credit`, `EngineSnapshot`, `StatementCredit`… and
  columns keep the camelCase of the Ponder schema (`blockNumber`, `pileOrder`),
  not snake_case.
- **Ids are text.** `Credit.id`, `Statement.id` and `StrategyListing.id` are
  decimal strings (HyperIndex ids are strings), so an `order by id` sorts as
  text. `EngineSnapshot` and `StatsHourly` gain an `id` column equal to their
  `blockNumber` and `hour`.
- **Extra column.** Every table has a `chainId` column, always `1`.
- **Not ported:** the `parity` table, `/health/parity` and `/health/rpc` (the
  reconciliation reads live Core views and counts rows with SQL, which handlers
  cannot do; RPC counts are logged every 30 s instead). The `CreditBid` and
  `MarketRedeemer` sources are also not ported: `indexer/` configures them only
  when a phase 3 deployment record exists, and `deployments/` has none for
  chain 1.
- **No Ponder API.** There is no `/sql` endpoint for `@ponder/client`, no
  `/status` and no live queries. GraphQL comes from Hasura (not exercised in
  these tests; they ran with `ENVIO_HASURA=false`).
- **No time-travel and no reorg rollback of Effect cache.** Entities hold only
  their current value, as in the original.

### Queries in `web/` and `keeper/` that need a rewrite

`web/lib/indexer.ts` builds Drizzle queries over `@ponder/client`, which sends
SQL to `/sql/db`. HyperIndex has no such endpoint. Eleven tables are read
(`activity`, `anchor_move`, `credit`, `engine`, `log`, `statement`,
`statement_credit`, `statement_format`, `stats`, `stats_hourly`,
`strategy_listing`); the rest are not used by either app.

| Consumer | Query | Needs |
| --- | --- | --- |
| `fetchIxHealth` | `getStatus()` (`/status`), `count(*)` of held credits, engine identity row | another status source, e.g. Hasura `_meta`; two plain reads |
| `useEngine`, `useHeldCredits`, `useCreditRow`, `useWalletCreditsIx`, `useStatementRowsIx`, `fetchScoresIx`, `fetchTokenUris`, `useCreditTraitsIx` | single-table selects with `where`, `order by`, `in (…)` | Hasura `where`/`order_by`/`_in`; numeric ordering of ids |
| `useStatsIx` | `stats` row, `sum`/`count` over `statement.toPot` | an aggregate query |
| `useBuyRateIx`, `useFillsTodayIx` | `stats_hourly where hour >= n`, `min(hour)`, `activity where kind in (…)` | Hasura filters, an aggregate |
| `useMarketIx` | `credit` grouped by a `CASE` expression | raw SQL or a view |
| `fetchStrategyListings` | `strategy_listing LEFT JOIN credit … order by list_price` | a join: add a relationship, or two queries |
| `useCreditHistoryIx`, `useStatementDetailIx`, `useFeedIx` | joins of `activity` with `log`, `statement`, `statement_format`, and `count(*)` | joins and an aggregate |
| `keeper/src/inventory.ts` `indexerSeed` | GraphQL `strategyListings(where:{active:true}, orderBy:"id", limit:1000, after:$c){items{id} pageInfo{…}}` and `_meta{status}` | Hasura `StrategyListing(where:{active:{_eq:true}}, order_by:{id:asc}, limit, offset)` |
| `web/scripts/indexer-schema-guard.ts` | type check against `indexer/ponder.schema.ts` | point it at `schema.graphql` types or drop it |

Since the port writes plain Postgres, the least change for the web app is
direct SQL against these tables (`"Credit"`, `"blockNumber"`, …) behind a thin
read-only HTTP layer, but that was not tried here.

## Benchmark

Cold syncs on one laptop (Apple Silicon, Postgres 17 in Docker), empty
database and empty Effect cache, envio 3.15.0, from block 26,037,292. The
machine was running several other indexers, and the public RPC endpoints are
shared with them, so timings are noisy. Time runs from "Starting indexing" to
"Ready" in the indexer log.

| Run | To block | Time | Events | Waiting on RPC¹ | Waiting on HyperSync² | Handlers + DB² |
| --- | --- | --- | --- | --- | --- | --- |
| pinned (2026-10-30) | 26,304,600 | 441 s | 449,355 | ≥361 s | 0.5 s | 4.4 s + 3.5 s |
| head (2026-10-30) | 26,304,86x | 464 s | 449,360 | ≥373 s | 0.8 s | 5.2 s + 3.3 s |

¹ `wall_s` in the last `[rpc]` log line before Ready (wall-clock time with at
least one RPC request in flight; 17 s and 11 s before the end).
² `envio_processing_stalled_on_fetch_seconds`, `envio_processing_seconds` and
`envio_processing_stalled_on_storage_write_seconds`.

The full history is 267,309 blocks and 122,154 Credits. About four fifths of
the time is waiting on the RPC for `tokenURI` (about 6 KB per Credit) and the
other Credit reads. HyperSync and the database are not the limit. The public
endpoints failed over often: in the pinned run 21,546 requests were made, 10,511
of them failed and moved on to the next endpoint, and in 326 rounds all three
failed and the indexer backed off before retrying. With a dedicated archive
node the RPC share should shrink; that was not measured. The database was 828 MB
after the pinned run.

### Against the Ponder indexer

Same range for both: block 26,037,292 to 26,042,000, which holds all 122,154
Credit mints (171,294 events, about 100,000 of them in the first 800 blocks).
Both start from empty databases on the same machine within the same hour. The
Ponder side is the unmodified `indexer/` with its shipped RPC list and rate
caps, using the mainnet values from `env/mainnet.env`. Only two things were
changed so the range is valid: every source got an `endBlock`, and
`DEPLOY_BLOCK` and `STATEMENTS_START_BLOCK` were lowered to 26,037,292, so
nothing but Credits and the strategy is indexed in either run. No paid RPC was
used.

| Indexer | Run | Result |
| --- | --- | --- |
| Port | 1 | Ready after 324 s, 122,154 Credits |
| Port | 2 (42 min later) | Ready after 326 s, 122,154 Credits |
| Ponder | 1 | 66 events (blocks 26,037,292 to 26,037,317) in the first 19 s, then nothing for 600 s; its watchdog exited at 21 min, with 65 Credits indexed |
| Ponder | 2 (cold again) | the same: 65 Credits, then no progress for 600 s |

Ponder's log shows why: the public endpoints refuse its dense `eth_getLogs`
and block requests (`Request exceeds defined limit` from Tenderly, and errors
from publicnode, Blast and 1rpc for the log ranges), and the first 800 blocks
carry about 100,000 logs. `docs/STATUS.md` records that the deployed indexer
needed a temporary paid Alchemy endpoint for its backfill. That was not tried
here, so this does not show that Ponder cannot backfill with a better RPC, only
that the port needs no log endpoint, because HyperSync serves the logs and the
RPC is used only for the contract reads. Both indexers shared the machine and
the public endpoints with several other indexers.

## Parity

The reference is the original's own public deployment
(`https://cc-indexer-mainnet.fly.dev`, the `NEXT_PUBLIC_INDEXER_URL` in
`netlify.toml`), read through its `/sql/db` endpoint. `scripts/parity.mjs`
compares every row of every table with the port's Postgres, field by field.
Run 2 above, left running while the comparison ran: the port was at block
26,304,865 and the deployment at 26,304,864.

| Table | Rows compared | Fields | Result |
| --- | --- | --- | --- |
| Log | 449,305 | 10 | equal; 55 more rows in the port, see below |
| TransactionFact | 968 | 5 | equal |
| Engine | 1 | 42 | equal |
| EngineSnapshot | 1,233 | 22 | equal |
| SettingChange | 51 | 9 | equal |
| Controller | 2 | 33 | equal |
| TreasuryEvent | 13 | 19 | equal |
| TreasuryState | 1 | 29 | equal |
| Credit | 122,154 | 31 | 5 owners differ, see below |
| Statement | 569 | 20 | 9 ratings differ, see below |
| StatementCredit | 960 | 4 | equal |
| Activity | 1,146 | 13 | equal |
| Stats | 1 | 22 | equal |
| StatsHourly | 43 | 22 | equal |
| StrategyListing | 15,153 | 8 | equal |
| StatementFormat, AnchorMove | 0 | | both empty |
| `Credit.tokenUri`, `Statement.tokenUri` | 2,443 + 569 | 1 | equal; every 50th Credit and every Statement, plus no nulls on either side |

591,600 rows and 8,464,943 field values were compared. Columns that the
deployed original does not have yet (it trails `main`: `treasury_event.redeemer`,
17 `treasury_state` columns and the `redeemer` table) were skipped. 69 values
differ, all explained, and in each case the port agrees with the chain:

- **55 Credits `Transfer` logs are missing from the deployed original**, in
  nine blocks from 26,189,063 to 26,189,086. They are on chain (Tenderly and
  drpc each return 25 Credits logs for block 26,189,063 alone, and HyperSync
  lists them; the original's `log` table has none in that block). As a result 5 Credits have a
  stale `owner` there: 19180, 50034, 60326, 108871 and 115527 are held by the
  CreditStrategy (`ownerOf` at latest), and the original shows other addresses.
  Why those logs are missing was not investigated.
- **9 `Statement.rating` values** (all in state `outside`: 30, 70, 154, 162,
  228, 250, 307, 311 and 524) differ. `creditScoreOf` at the latest block
  agrees with the port for all 569 statements and differs from the original
  for exactly these nine. `creditScoreOf` is not constant:
  for statement 30 an `eth_call` returns 252,556,645 at blocks 26,150,000 to
  26,235,000 and 3,612,930,089 from block 26,250,000. The original read the
  rating once, with `cache: "immutable"`, and kept it; the port read it later.
  Two cold runs of the port at different times can differ in the same way.
