# Focused re-audit: CC Bars sale repairs `9b798902`

Scope: `git diff 02519f3d..9b798902` (CCBarsSale.sol, BarsSale.s.sol, CCBarsSale.t.sol, DECISIONS row 302,
REVIEW-bars-sale-02519f3d.md) plus the sale/script paths the delta touches. Context read: CCBarsVault,
Core (`fund`/`setBalanceModule`/`balanceToken`/`_setBalanceModule`), Phase2BalanceTreasury
(`migrateTo`/`withdrawWorking`/`freeWorking`), Phase3.s.sol. Informed, diff-scoped (release-candidate tier), single
auditor, warm fork. Not blind, not exhaustive.

## Evidence executed

- `forge test --match-path test/CCBarsSale.t.sol` at block 26494300: **9/9 pass** (7 CCBarsSaleTest + 2
  CCBarsSalePhase3Test). The two Phase3 tests run the real `Phase3.deploy`+`migrate` on the fork (no mocks).
- Deploy dry run (`--sender <owner>`, no `--broadcast`/`--account`): **4 zero-value sends**, in order
  `returnBalance()` gas 169,734 → CREATE2 sale gas 1,764,887 → `transferBars(63 ids)` gas 3,357,948 →
  `setOn(true)` gas 47,083; total est. 5,339,652. Backing of Bar 2942 = 0.020063 ETH, ask at 4x = 0.080253 ETH.
- Absolute money checks reconcile: 2942 × 6.8196e12 wei = 0.02006 ETH ✓; 187,455 BALANCE × price × 4 =
  5.113446618908231520 ETH into `ethPot` (executed) ✓.
- `foundry.lock` and `lib/solady` restored; worktree clean.

## Prior findings A–D

**A. Future module with a different token misprices/misroutes — FIXED (code-read + premise executed-confirmed).**
`backingOf` (CCBarsSale.sol:137) and `meltBars` (:176) revert `TokenChanged` when `core.balanceToken() != balance`.
`priceOf`→`backingOf` and `buy`→`priceOf` inherit the guard, so every pricing/selling and the melt path are gated;
`multiplierOf` needs no token. I confirmed the premise is real: `Core._setBalanceModule` (Core.sol:1415) sets
`s.balanceToken = IBalanceModule(module).balanceToken()`, so a future module does change `balanceToken()`. Recovery
is preserved: `transferBars` (:185) has no token check, so the owner can always move Bars out. Melt stays correctly
blocked (released BALANCE must not be sent to a module accounting another token). The token-changed branch itself is
not executed (would need a live module on another token, or a protocol mock — rightly avoided); the guard is a
pre-effect equality check, risk of the reasoning being wrong is low.

**B. Script could leave 541.789 BALANCE in the vault after a module switch — FIXED (executed).**
BarsSale.s.sol: token check (:62); pre-broadcast refusal `require(leftover == 0 || balanceModule == vault.treasury())`
(:67) stops before any send when leftover is nonzero and the module is no longer v1; `returnBalance` is now the first
broadcast send (:74); post-run `require` of empty vault for BALANCE (:82) and Bars (:83).
`test_scriptStopsAfterPhase3UntilTheLeftoverIsRecovered` executes it: real Phase3 migrate first → `execute` reverts
with the exact string and nothing deployed → documented recovery (`returnBalance`, then v1 `withdrawWorking(v2,
leftover)`) moves 541.789275702 into v2 → rerun completes with an empty vault, 63 Bars in the sale. I verified the
recovery is sound against the contracts: after `migrateTo`, v1 custody == `totalOwed`, so `working()`==0; the returned
541.789 makes `working()`==541.789, and `withdrawWorking` has no `migrated` guard (`migrateTo` comment: "later inflows
leave through `withdrawWorking`"), so it is withdrawable provided `minimumWorkingBalance` is 0 at that state — which
the passing test establishes on the live fork.

**C. Bar moved out and returned by plain transfer kept its stale arrival — FIXED (executed).**
`transferBars` deletes `arrivedAt[id]` before sending (CCBarsSale.sol:187). `test_ownerEditsTheMultipliers` now moves
a Bar out, asserts `arrivedAt==0`, returns it by plain `transferFrom`, and asserts `multiplierOf==floor (20_000)`.

**D. v2 melt route after phase 3 unexercised — FIXED (executed, live contracts).**
`test_saleThenPhase3MeltsIntoV2`: sale deployed first, then production Phase3 deploy+migrate; V3 prices Bar 0 (ask ==
backing×4x asserted), a buy funds the same Core's `ethPot` exactly, a 10-Bar melt adds exactly Σ ids to **v2** custody
and working, and v1 custody is unchanged. No mock of a live contract (Phase3 contracts are the not-yet-deployed ones,
legitimately created fresh; Core/v1/Bars/pool are live).

## New findings (delta-introduced)

None rising to actionable severity. Observations:

1. **Low/none — `transferBars` to `address(this)` resets the clock to `now` instead of clearing it.** The delete at
   :187 is followed by `safeTransferFrom`; a safe transfer to self re-fires `onERC721Received`, which sets
   `arrivedAt = block.timestamp`. Net effect of a self-transfer is a fresh 4x fall (a *higher* ask), not the floor the
   NatSpec implies. Conservative, owner-only, not a loss path. Doc nuance only; untested but harmless.
2. **Benign — `--resume` and the post-broadcast `require`s.** The post-run requires (:82-83) run in script simulation
   *before* any real broadcast, so on a fresh run a would-be failure sends nothing (no stranding). Each send is guarded
   by a fresh-state conditional (`leftover!=0`, `code.length==0`, `ids.length!=0`, `!on`), so `--resume --slow` after a
   partial run is idempotent: I traced every partial-completion ordering (returnBalance/CREATE2/transfer/setOn) and each
   resumes cleanly. If BALANCE or Bars somehow reappeared in the vault between runs the resume would abort before
   sending a pending `setOn`; that cannot happen in the owner's controlled sequence, and `setOn` is directly callable.
3. **Confirmed, not new — reference-lag / spot-suppression** is owner-accepted at this inventory (DECISIONS 302); out
   of scope.

## Economic pass

Every owner outcome holds with measured numbers: proceeds → `Core.fund()`→`ethPot` to the wei (5.1134 ETH all-63 at
4x, executed); melt → current module (v1 executed, v2 executed); `floorBps >= 10_000` enforced in `_setSale`
(`9_999` reverts, tested); owner-only admin via `core.owner()`; script returns the 541.789 leftover and empties the
vault (dry run: Bars 0, BALANCE 0). No new ratchet, idle-capital or round-trip issue introduced by the delta; the
sale holds no ETH (refund last, `address(sale).balance==0` asserted) and no BALANCE except between a melt's two lines.

## Verdict

- **Merge PR #206: GO.** Repairs A–D are present and sound; A–D's runtime behavior is executed except the
  `TokenChanged` branch itself (low-risk, pre-effect guard).
- **Sale-step deploy: GO, conditioned on** (a) run **before** phase 3 (the script enforces it, but recovery after a
  wrong order is manual); (b) owner sends from an updated `main` after a fresh no-keystore dry run, `--slow`, and
  `--resume --slow` on any partial run (per AGENTS.md / the 4-send order above); (c) this is one informed audit, not an
  independent second review.

## Things that don't make sense

- `transferBars` to self resets rather than clears the clock (item 1) — contradicts the NatSpec's "clears", though the
  effect is a safe, higher price. Worth a one-word doc note, not a code change.
- The `TokenChanged` recovery story assumes `minimumWorkingBalance` is 0 at the migrated-v1 state for the manual
  `withdrawWorking` to move the full leftover; true on this fork (test passes) but it is a live-value dependency, not an
  invariant. If the owner ever sets a nonzero minimum before recovery, withdraw it in two steps or lower the minimum
  first.
- Nothing else. The delta is tight and the four repairs each map to an executed test (A to a reasoned guard).
