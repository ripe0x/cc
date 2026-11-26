# CC Bars sale repair review: `eb8b6efd`

Condensed record of an independent review (a fresh subagent, blind to the lead's conclusions until after its own pass)
of the repair delta `5fb6f09f..eb8b6efd` and of the final contract and script, 2026-11-25. Run against the local
fork cache at block 26,494,300; no paid RPC calls. Its four witness tests were deleted after the run; their outline is
kept in the session report only.

**Verdict: GO**, on condition that the owner confirms E1 falls inside the accepted price-manipulation risk and that the
run follows AGENTS.md (from `main`, before phase 3, dry run first, `--slow`).

## Security

| Rank | Finding | Evidence | Disposition |
|---|---|---|---|
| Low | `buy` kept a sold Bar's arrival time, so a buyer's plain-transfer return was listed at once at the floor, against the documented rule that a plain-transfer arrival is not for sale. Proceeds still reached `Core.fund` | executed witness: Bar bought at 20 days, returned by `transferFrom`, `multiplierOf` 15,000, `priceOf` equal to the original ask | repaired: `buy` deletes the arrival time; `test_fallingSaleFundsThePot` asserts it is 0 after a sale and a plain return is `NotForSale` |
| Info | anyone can stop the script before it sends by donating a Bar outside the scan range to the vault; recovery is one owner `transferBars` | existing `test_scriptStopsOnABarOutsideTheScan` | accepted |
| Info | `readback` reverts when the first held Bar has no arrival time or the quote is unusable | reasoned | accepted: readback only |

Checked sound: duplicate ids, reentrancy guard, rounding toward the seller, empty buy, CREATE2 front-run (identical
contract), a stranger's Bar sent to the sale (listed at 4x, proceeds to the pot), V3 exposes the same price views,
BalanceTreasuryV2 counts direct BALANCE as working. Gas: `execute` with the scan about 3.81M, a 63-Bar buy about
3.97M.

## Economics

| Rank | Finding | Evidence | Disposition |
|---|---|---|---|
| Medium, accepted | after any 10 quiet minutes one buyer in one transaction can dump BALANCE, call the public `refreshReference` (one 10 percent step down) and buy at the lowered reference: full inventory at the 1.5x floor 1.726438997 ETH against 1.917542482 ETH, swap round trip loss 0.003993608 ETH, net saving 0.187109877 ETH (9.76 percent); about 0.51 ETH at 4x (reasoned). The 1x promise holds under this only while `floorBps` is at least about 11,112 | executed witness, 100,000 BALANCE dump, reference down 996 bps | inside the owner's acceptance ("not an issue at this scale"); decision 302 now states the steady-state bound and the floor condition. No contract change |
| Info | the stale half of the `valuePerPoint(true)` gate is inert at the live `referenceMaxStale` of 4,294,967,295 s | reasoned | recorded in decision 302 |

Flows: 63 Bars at 4x 5,113,446,618,908,231,520 wei and at 1.5x 1,917,542,482,090,586,820 wei, all to the pot, the
sale's ETH balance 0; the melt round trip returns exactly the sum of the ids in BALANCE under v1 and v2; the
541.789275702 BALANCE leftover returns to v1. No ratchets.

## Prior findings (REVIEW-bars-sale-indep-5fb6f09f.md)

All seven fixed or documented; the plain-transfer arrival fix was incomplete for sold Bars (the Low above, now
repaired).
