# credits engine web app

Next.js 14 (app router), wagmi 2, viem 2, RainbowKit. Every value comes from
the chain: one viem multicall over the views of `docs/INTEGRATION.md` section 2
(`lib/live.ts`) and one incremental event scan (`lib/engine.ts`, rows in
`lib/events.ts`). `lib/abis.ts` is a hand written subset of
`src/interfaces/ICore.sol`, `IControllerV1.sol` and `ISeaportBasicAdapter.sol`.

## run against anvil

```bash
cd web
npm install
npm run dev:local        # http://localhost:3000
```

`dev:local` runs `scripts/local-env.mjs`, which reads `../deployments/31337.json`
(`RECORD=<path>` reads another file), writes the ignored `.env.local`, then
starts `next dev`. When the record is missing it prints the reason and exits.
Run anvil with `--auto-impersonate`: RainbowKit's wallet list shows the
accounts of the record as wallets, and writes are signed by anvil for the
connected address, so no wallet extension is needed.

## run against mainnet

```bash
cp .env.example .env.local   # set NEXT_PUBLIC_CORE and NEXT_PUBLIC_DEPLOY_BLOCK
npm run dev                  # or npm run build && npm start
```

The controller, coin and balance module are read from the Core. Without
`NEXT_PUBLIC_CORE` the engine pages show "engine not deployed". Wallets connect
through RainbowKit. `npm run check` covers the sell replays, swap encoders and
pool settings; `npm run build` type checks.

The CC swap panel reads the pool hook, fee and tick spacing from the configured
Core. Optional `NEXT_PUBLIC_POOL_*` values from the verified deployment record
must match those on-chain values; a mismatch disables CC swaps and shows the
configuration error. The pool is read once after the coin launches, so deferred
Core deployment does not require a live coin pool.

## pages and actions

Prices shown to buyers are the asking prices (`priceOf`, `creditPrice`); the
artist and operator cuts come off the payment inside the sale. The balance side
(redeem, sell for balance, the balance pot, rating value) shows once
`core.balanceModule()` is set.

| page | reads | actions |
|---|---|---|
| `/` flywheel, stats bar, engine feed, swap panel | event scan, snapshot, pool slot0 (StateView), v4 Quoter, Chainlink ETH/USD | Universal Router `execute` (eth for coin and back), coin `approve` and Permit2 `approve` before a sell |
| `/keeper` | snapshot, `lastBuybackBlock`, head block, the feed stats | `core.book()`, `core.buyback()` (the artist and payee are paid by push, no claim) |
| `/credits`, `/credits/[id]` | `pilePage`, `creditInfo`, `creditPrice`, `pastWindow` | `controller.buyCredit(id)`, `buyCredits(ids)` while `creditSaleOn` |
| `/sell` | `ethRate`, `ethPot`, `settings`, `Credits.tokensOf` | `Credits.setApprovalForAll(core)`, `core.sellForEth(ids, minOut)`, `core.sellForBalance(ids, minOut, expectedToken)` while `balanceBidOn` |
| `/compose` | `nextPage`, `pileSize`, `chosenComposeOn`, `minCcToChoose` | `core.compose()`, `core.compose(format)`, `core.composeChosen(ids, format)` while `chosenComposeOn` |
| `/statements`, `/statements/[id]` | `heldStatements`, `statementInfo`, `statementAge`, `ratingOf`, `composerOf`, `priceOf`, `referenceOf`, `atFloor`, `valueOf` | `controller.buy(sid)` at the asking price, `core.setHeldFormat(sid, format)`, `core.redeemStatement(sid)` when `redeemOn` and `atFloor` |
| `/docs` and `/docs/...` | static guides and a catalog from current engine interfaces plus the pinned deployed CreditScoreLens interface | search and navigation only; no chain write |

For contract surface changes, run `npm run gen:docs` to refresh the signature catalog, then `npm run check:docs` to check it and the curated reference. Engine docs are pinned to public main `0dba672`; update the source link and copy when the contract revision changes. Credits, Statements, Core, CC and adapter addresses come from `deployments/1.json`; ControllerV2, Phase2BalanceTreasury and BALANCE token addresses come from `deployments/1-phase2.json`. Core, ControllerV2 and the balance module show curated methods. BALANCE exchange has its own guide; Statement conversion and claim guides remain off. CreditScoreLens uses its deployed historical interface snapshot at `web/docs-sources/ICreditScoreLens.sol`.

`sellForEth` and `sellForBalance` send `minOut` at 99.5% of the batch total,
replayed from the Core's per-credit rules at click time (`lib/sell.ts`, read by
`sellQuote` and `balanceQuote` in `lib/live.ts`). A sweep of a listing
(`buyListing`) is a keeper action and has no page.

The sell page reads all 34 Core settings. ETH bids and quotes show the current rate; they do not reserve the ETH purchase budget. ETH purchases share the configured bucket cap (100 bps per 60 seconds at launch), and `SpendCapReached` asks the holder to retry in the next bucket. A setting of 10,000 bps bypasses the limiter. Balance purchases do not use this cap.

Balance sales pin the token address from the quote snapshot, so an owner token replacement cannot silently change the payment currency.
