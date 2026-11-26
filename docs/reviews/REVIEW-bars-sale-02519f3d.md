# CC Bars sale pre-deploy audit: `02519f3d`

Condensed record of the informed, diff-scoped audit of PR #206 at `02519f3df75158d3bed22f72b28b91a8bd72699b`
(base `4ef17856`), delivered to the owner on 2026-11-25. The full report was pasted into the session; its witness
test sources (`REVIEW-bars-sale-02519f3d-attacks.sol`, `.patch`, `-bid.sol`) were not delivered and are not here.
Repairs follow at the end.

**Decision at `02519f3d`: NO-GO** as a completed release gate: the phase 3 melt destination was not exercised, and
the deploy script could succeed while leaving 541.789275702 BALANCE in the vault if the module switch came first.

## Security findings

| Rank | Finding | Proposed fix |
|---|---|---|
| Medium, conditional | A future module with a different token: the sale's `balance` is immutable BALANCE but the controller prices the Core's current token, and a melt would pay a module outside its custody. Example: a token at 0.1x BALANCE's price asks about 0.192 ETH for all 63 Bars at 1.5x instead of 1.918 ETH. Phase 3 keeps BALANCE. | Check the Core's `balanceToken()` equals `balance` before pricing and melting; define recovery |
| Low, conditional | The script skipped `returnBalance` once the module was no longer v1 and still reported success, leaving 541.789275702 BALANCE in the vault | Fail when the leftover cannot reach the intended module; assert an empty vault after the run |
| Low, owner-controlled | A Bar moved out and returned by plain `transferFrom` kept its old arrival time (about 3.82x a day after first arrival) instead of the documented floor | Clear the arrival time on owner transfer |

Accepted price-reference exposure, quantified: ControllerV2's `referenceMaxStale` is 4,294,967,295 s and a refresh is
not automatic; a 30-day-old reference still priced a purchase on the fork. At the pinned reference, a 2x true BALANCE
price with the spot suppressed to the old reference gives at most 0.639181 ETH gross across all 63 Bars at 1.5x,
before costs; the gap reaches 1.2 ETH (10% of the 12 ETH pool) at about 351,900 BALANCE of Bar backing. No net
profitable round trip was shown. The owner's acceptance covers the current inventory only.

## Economic findings

| Rank | Finding | Proposed control |
|---|---|---|
| Medium, demand | All 63 Bars are high numbered; their recent sales ran 0.33x to 1.33x backing against a 4x open, 2.75x at 7 days and a 1.5x floor. Zero sales is plausible | Keep the owner's 4x/1.5x; after the window keep, lower (at least 1x) or melt. The floor is 9.1% above the 1.375x Credit floor and about the 1.5x Statement ask |
| Low, lifecycle | Proceeds always fund the original Core; after a Core retirement they sit in its pot until another `migrate(0)` | Before any Core retirement, close or repoint the sale |
| Policy | A Bar is a claim on its vault's BALANCE, so this is a scoped sale of BALANCE exposure, approved in decision 302 | State the exception; do not generalize it |

## Scorecard (block 26,494,300)

- 63 Bars, 187,455 BALANCE inside, 1.278361654727058 ETH at the reference (the audit request's 1.7 ETH was wrong).
  Vault leftover 541.789275702 BALANCE. Reference and spot 6,819,565,520,936 wei per BALANCE.
- All 63 sold at 4x: 5.113446618908231520 ETH, the exact amount into `ethPot`; at 7 / 14 days 3.515494550499409170 /
  1.917542482090586820 ETH (model). The buyer's seven melts released 187,455 BALANCE (executed).
- One Bar sale then a real Credit bid fill: the 0.080252647050374848 ETH payment funded the seller 0.001269663367100759
  ETH and the artist 0.000038089901013022 ETH from the pot (executed).
- Deploy dry run, no keystore: 4 zero-value sends, gas limits 1,581,791 / 3,357,948 / 47,083 / 169,734, total
  5,156,556; runtime 4,912 bytes.

## Go conditions

1. Enforce v1-before-phase-3 ordering and a zero vault leftover after the run.
2. Run a real v2 fork melt cycle and check v2 custody and working accounting.
3. Ensure the controller prices the same BALANCE token as the sale.
4. Repeat only affected checks at the deployment candidate; the owner sends from an updated `main` after a
   no-keystore dry run, with `--slow` and `--resume --slow` on a partial run.

## Repairs (2026-11-25, PR #206)

| Finding | Repair | Evidence |
|---|---|---|
| Different-token module | `backingOf` and `meltBars` revert `TokenChanged` while `core.balanceToken() != balance`; recovery is `transferBars` | Reasoned and code-read; not executed (changing the Core's token needs a module bound to another token) |
| Script leftover | The script checks the Core's token, refuses before any send when the leftover is nonzero and the module is no longer v1 (recovery: `returnBalance`, then v1 `withdrawWorking` to the module), returns the leftover as its first send, and requires an empty vault after the run | `test_scriptStopsAfterPhase3UntilTheLeftoverIsRecovered`: the real Phase3 script migrates first, the run reverts with nothing sent, the recovery moves 541.789275702 BALANCE into v2, then the run completes with an empty vault |
| Plain reentry clock | `transferBars` deletes the Bar's arrival time | `test_ownerEditsTheMultipliers`: out by `transferBars`, back by plain `transferFrom`, asks the floor |
| v2 melt unexercised | none needed | `test_saleThenPhase3MeltsIntoV2`: sale first, then the production Phase3 deploy and migrate; V3 prices the Bar, a buy funds the same pot exactly, a 10-Bar melt adds exactly its BALANCE to v2 custody and working, v1 unchanged |
| Retired Core | documented in decision 302: before any Core retirement, switch the sale off and move the Bars to a successor | none |
| Demand risk, policy, reference lag | owner decisions in 302; unchanged | none |

Also added `test_fullInventoryBuyThenMelt` (63 Bars, 5.113446618908231520 ETH into the pot, 187,455 BALANCE melted).
`MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co forge test --match-path test/CCBarsSale.t.sol`: 9/9 at block
26,494,300. Runtime 5,197 bytes. The repairs have not had a second independent review; the deploy dry run is to be
repeated from `main` after merge.
