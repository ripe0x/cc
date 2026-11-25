# CC Bars sale independent re-audit: `5fb6f09f`

Condensed record of the independent re-audit delivered to the owner on 2026-11-25 (partial: the public Tenderly
gateway's egress was exhausted, so no fork test or dry run executed; findings are source-reasoned). Its witness
source was at `/private/tmp/cc-bars-indep-5fb6f09f/test/CCBarsSaleIndep.t.sol`, outside the repository.

**Verdict at `5fb6f09f`: merge NO-GO, sale deploy NO-GO.**

| Rank | Finding | Repair (2026-11-25) | Evidence |
|---|---|---|---|
| CI | The contracts job forked at RPC_FORK_BLOCK 26,251,200, below the sale tests' pin 26,494,300 | `.github/workflows/ci.yml` RPC_FORK_BLOCK 26,494,300 | CI rerun |
| Medium, conditional | The sale priced from the raw reference and spot while the controller's protected quote could be unusable (stale reference, thin liquidity) | `backingOf` also requires `valuePerPoint(true)` ok, the gate the Core's Credit and Statement sales use | `test_saleStopsWhenTheProtectedQuoteIsUnusable`: warped one second past the live 4,294,967,295 s reference lifetime, `priceOf` and `buy` revert `NoQuote` |
| Medium, conditional | `--resume` replays saved sends without re-simulating, so a resume after phase 3 could return the leftover to migrated v1 or re-enable a paused sale | Operational rule in the script header and decision 302: phase 3 only after all four receipts and the readback; before any resume confirm the module is still v1 | Reasoned |
| Low | The empty-vault postcondition used the bounded 2935 to 3034 scan and missed a Bar outside it | The script requires the Bars contract's `balanceOf(vault)` to equal the scan before sending and to be zero after | `test_scriptStopsOnABarOutsideTheScan`: Bar 2934 donated to the vault stops the run with nothing sent; after the owner moves it out the run finishes with a count of zero |
| Low, requirement | A plain-transfer arrival sold at the floor, not 4x | A Bar with no arrival time is not for sale; the owner starts its clock with `transferBars` to the sale | `test_ownerEditsTheMultipliers`: plain return, `priceOf` and `buy` revert `NotForSale`; transfer to self asks the start multiplier |
| Low | Unsolicited BALANCE stayed in the sale | `meltBars` sends every BALANCE held to the module (an empty id list sweeps). Forced ETH is accepted as unrecoverable: it can only arrive by selfdestruct, at the sender's loss | `test_meltPaysTheCurrentModule`: 1 BALANCE sent directly reaches the module with the melt |
| Tests | `test_guards` used a bare `expectRevert`; `test_fullInventoryBuyThenMelt` derived its payment from `priceOf` | The re-entering buyer records the inner error and asserts `Reentrant`, with the outer buy completing for one Bar; the inventory total is checked against the independent formula and the absolute 5,113,446,618,908,231,520 wei | both tests |

Not addressed: an owner handover test on the sale (the same `core.owner()` check is exercised in the vault suite),
a token change and recovery (needs a module bound to another token), an interrupted real `--resume --slow`,
launch gas economics (tests run at zero gas price), and runtime hash matching of the partially verified integrations.

Evidence: `forge test --match-path test/CCBarsSale.t.sol` 11/11 at block 26,494,300, served from the local Foundry
fork cache while the public gateway was exhausted. Runtime 5,320 bytes. Not yet re-reviewed.
