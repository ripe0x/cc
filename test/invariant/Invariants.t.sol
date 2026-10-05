// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {Core} from "../../src/Core.sol";
import {Lane, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {IArtCoinsMevSkim} from "../../src/interfaces/ArtCoins.sol";
import {InvariantFixture} from "./InvariantFixture.sol";
import {Handler} from "./Handler.sol";

/// @notice SPEC section 10, one `invariant_` function per item, against the real system on the mainnet fork.
///
/// how to run:
///   set -a; . ./.env; set +a
///   forge test --match-path 'test/invariant/*' -vv      # the default, runs 24 and depth 80, a few minutes
///   INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 \
///     forge test --match-contract '.*Deep' -vv           # deeper, only the Deep variants run
/// the defaults come from inline `forge-config` lines on the four concrete suites: phase 1 after the sniper window,
/// phase 1 starting inside the window (90 percent skim at the start), phase 2 with the exit auction, and phase 2
/// under a hostile controller. an inline line beats an
/// environment variable, so the Deep variants carry no inline config and skip themselves unless INVARIANT_DEEP is
/// set. they are the same suites, only the depth comes from the environment.
/// every `invariant_` function is its own campaign, so cost grows with runs times depth times the number of
/// functions. each campaign starts from the state after `setUp`, which has a funded pot, pre filled piles, a
/// composed statement and a climbed rate. `-vv` shows the call summary that `invariant_callSummary` logs. the
/// summary also keeps running totals over all runs in this process through the environment, which no revert
/// can undo.
///
/// every swap is a real swap through the live skim hook, which pushes its bounty into the core's receive(). a swap
/// failure is classified by revert selector, and the one that matters, the hook's BidForwardFailed, is a violation
/// of invariant 10.
///
/// the handler never reverts. a failed core call is caught, counted, and checked for leaving state untouched, so
/// a violation recorded in the ghosts cannot be lost to `fail_on_revert = false`.
abstract contract InvariantsBase is InvariantFixture {
    /// the violation codes of the handler, grouped by SPEC item.
    uint256[] internal g1 = [1, 2, 3, 4, 6, 20, 21, 23, 18, 26];
    uint256[] internal g2 = [5];
    uint256[] internal g3 = [7];
    uint256[] internal g4 = [8, 9, 19, 10];
    uint256[] internal g5 = [22];
    uint256[] internal g6 = [11, 12, 13];
    uint256[] internal g7 = [14];
    uint256[] internal g8 = [15, 16, 17];
    uint256[] internal g9 = [25];
    uint256[] internal g10 = [24];

    function _zero(uint256[] storage codes) internal view {
        for (uint256 i; i < codes.length; ++i) {
            assertEq(handler.viol(codes[i]), 0, handler.violMsg(codes[i]));
        }
    }

    /// 1. eth leaves the core only as a credit purchase within the ceiling, a capped tip, a capped compose
    /// reimbursement, a buyback slice (the swap input plus the keeper tip) or a refund of overpayment. every action's
    /// balance change is matched to those flows, measured at the recipients. the only inflows are the hook's skim
    /// pushed into receive() during real swaps, including the one the hook pushes back during the buyback, a
    /// statement sale and a plain donation. any other movement is a violation. exit token flows too: it leaves the
    /// core only as a bid payment in sellForExitToken or as an auction slice paid for at or above the quoted coin
    /// price.
    function invariant_01_ethOnlyLeavesByAllowedPaths() public view {
        _zero(g1);
    }

    /// 2. no credit is bought above score * ethRate * (1 + BONUS_CAP), rate and score read before the action.
    function invariant_02_noCreditAboveBonusCap() public view {
        _zero(g2);
    }

    /// 3. no statement is sold below 1.2 times its cost.
    function invariant_03_noStatementSoldBelowFloor() public view {
        _zero(g3);
        uint256 n = handler.everHeldCount();
        for (uint256 i; i < n; ++i) {
            uint256 sid = handler.everHeld(i);
            Handler.SG memory s = handler.statementGhost(sid);
            if (s.status == 2) {
                assertGe(s.price * 10_000, s.cost * 12_000, "sold below 1.2x cost");
                assertGe(s.price, s.quote, "sold below the quoted price");
            }
        }
    }

    /// 4. a statement leaves the core only by sale at or above price, by an exit that returned at least
    /// rating * unitPerPoint, or as the top of an overprint. every statement the core ever held is checked
    /// against its record.
    function invariant_04_statementsLeaveOnlyByAllowedPaths() public view {
        _zero(g4);
        uint256 n = handler.everHeldCount();
        uint256 held;
        uint256[] memory heldList = core.heldStatements();
        for (uint256 i; i < n; ++i) {
            uint256 sid = handler.everHeld(i);
            Handler.SG memory s = handler.statementGhost(sid);
            address o = _ownerOfStatement(sid);
            (bool coreHeld,,,) = core.statementInfo(sid);
            if (s.status == 1) {
                held++;
                assertEq(o, address(core), "recorded held but not owned by the core");
                assertTrue(coreHeld, "owned by the core but not marked held");
            } else if (s.status == 2) {
                assertTrue(!coreHeld && o != address(core), "sold but still held");
                assertGe(s.price, s.quote, "sold below price");
            } else if (s.status == 3) {
                assertTrue(!coreHeld && o != address(core), "exited but still held");
                assertGe(s.received, s.required, "exit returned less than rating * unit");
            } else if (s.status == 4) {
                assertTrue(!coreHeld, "overprint top still marked held");
                assertEq(o, address(0), "overprint top still exists");
                // the base kept its id. it may have left since, by a sale, an exit or an overprint of its own
                Handler.SG memory b = handler.statementGhost(s.base);
                assertTrue(b.status != 0, "overprint base is not a statement the core held");
                if (b.status == 1) {
                    (bool baseHeld,,,) = core.statementInfo(s.base);
                    assertTrue(baseHeld, "overprint base is not held");
                }
            } else {
                revert("an ever held statement has no recorded status");
            }
        }
        assertEq(held, heldList.length, "held count differs from the core's list");
    }

    /// 5. ethPot + ethToBuyback never exceeds the core's eth balance, and the same for the exit token pots.
    function invariant_05_potsNeverExceedBalances() public view {
        _zero(g5);
        assertLe(core.ethPot() + core.ethToBuyback(), address(core).balance, "eth pots above balance");
        address t = core.exitToken();
        if (t != address(0)) {
            (bool ok, bytes memory out) = t.staticcall(abi.encodeWithSignature("balanceOf(address)", address(core)));
            assertTrue(ok);
            assertLe(core.xPot() + core.xToBuyback(), abi.decode(out, (uint256)), "exit token pots above balance");
        }
    }

    /// 6. the rate does not rise in any interval where the pot was unfunded. checked around every action and
    /// every warp, with the funded flag recomputed independently from the pot and the rate.
    function invariant_06_rateNeverRisesWhileUnfunded() public view {
        _zero(g6);
        assertEq(core.funded(), core.ethPot() * 10_000 >= core.AVG_SCORE() * core.ethRate(), "funded flag stale");
    }

    /// 7. hourly eth spend never exceeds the cap. the window is read from core storage and checked against the
    /// cap, and against the window the handler rebuilt on its own from the spends it recorded.
    function invariant_07_hourlySpendWithinCap() public view {
        _zero(g7);
        uint256 ws = _windowStart();
        uint256 wp = _windowPot();
        uint256 sp = _windowSpent();
        assertLe(sp * 10_000, wp * core.SPEND_CAP_BPS_PER_HOUR(), "window spend above 20 percent of its pot");
        assertLe(ws, block.timestamp, "window starts in the future");
        assertEq(handler.gWinStart(), ws, "ghost window start differs");
        assertEq(handler.gWinPot(), wp, "ghost window pot differs");
        assertEq(handler.gWinSpent(), sp, "ghost window spend differs");
        assertLe(handler.gWinSpent() * 10_000, handler.gWinPot() * 2000, "ghost window spend above the cap");
    }

    /// 8. the controller has no path to move any asset. no controller ever held eth, coin, credits, statements
    /// or exit token, its attack calls all failed, and its reentry attempts through targets failed.
    function invariant_08_controllerHasNoPathToAssets() public view {
        _zero(g8);
        uint256 n = handler.controllerCount();
        address xtoken = core.exitToken();
        for (uint256 i; i < n; ++i) {
            address c = handler.controllers(i);
            assertEq(c.balance, handler.ethBase(c), "controller gained eth");
            assertEq(coin.balanceOf(c), 0, "controller holds coin");
            assertEq(CREDITS.balanceOf(c), 0, "controller holds credits");
            assertEq(_statementsBalance(c), 0, "controller holds statements");
            if (xtoken != address(0)) assertEq(_balanceOf(xtoken, c), 0, "controller holds exit token");
        }
        bool known;
        for (uint256 i; i < n; ++i) {
            if (handler.controllers(i) == core.controller()) known = true;
        }
        assertTrue(known, "the installed controller is not tracked");
    }

    /// 9. coin total supply never increases, and it falls by exactly the coin the eth buyback bought and burned plus
    /// the coin burned out of takers in exit auction fills. coin taxed to the burn address is a transfer, not a
    /// burn: 0xdEaD holds it and the supply does not move. the handler keeps a ghost of the expected supply and the
    /// two burn totals from the token's own transfer events and the auction's events.
    function invariant_09_coinSupplyOnlyFallsByBurns() public view {
        _zero(g9);
        uint256 supply = coin.totalSupply();
        assertLe(supply, core.SUPPLY(), "coin supply rose above its launch supply");
        assertEq(supply, handler.gSupply(), "coin supply differs from the ghost of expected supply");
        assertEq(
            core.SUPPLY() - supply,
            handler.gBurnedByBuyback() + handler.gBurnedByAuction(),
            "supply fell by something other than buyback and auction burns"
        );
        assertGe(coin.balanceOf(Mainnet.DEAD), handler.gDead(), "the burn address lost coin");
        assertEq(coin.balanceOf(Mainnet.DEAD), handler.sideTaxed(), "the burn address holds more than the buy tax");
        assertEq(coin.balanceOf(address(core)), 0, "the core holds coin");
    }

    /// 10. the core's receive() never reverted in the campaign. every direct send, from an account and from the
    /// hook's address, was accepted, and no real swap died of the hook's BidForwardFailed, which is how a reverting
    /// receive() would show up. swaps that failed for other reasons are counted by selector in the call summary.
    function invariant_10_receiveNeverReverts() public view {
        _zero(g10);
        assertEq(handler.receiveFails(), 0, "receive() reverted");
        uint256 n = handler.swapFailSelCount();
        for (uint256 i; i < n; ++i) {
            assertTrue(handler.swapFailSels(i) != bytes4(keccak256("BidForwardFailed()")), "bid forward failed");
        }
    }

    /// 11. model check: no action the ghost model expected to succeed reverted. a core that started refusing calls it
    /// used to accept would show up here and nowhere else.
    function invariant_11_noUnexpectedReverts() public view {
        uint256 n = handler.actionCount();
        for (uint256 a; a < n; ++a) {
            assertEq(
                handler.unexpectedFails(a),
                0,
                string.concat(
                    "unexpected revert in ",
                    handler.actionName(a),
                    ", selector ",
                    vm.toString(handler.lastUnexpected(a))
                )
            );
        }
    }

    /// logs how often each action ran, succeeded and was skipped in this run, and over all runs so far.
    function invariant_callSummary() public view {
        _summary();
    }

    function _summary() internal view {
        console.log("suite", handler.tag());
        console.log("action | attempts | ok | skipped | unexpected fail | totals over all runs: att ok skip unexp");
        uint256 n = handler.actionCount();
        for (uint256 a; a < n; ++a) {
            console.log(
                string.concat(
                    handler.actionName(a),
                    " | ",
                    vm.toString(handler.attempts(a)),
                    " | ",
                    vm.toString(handler.successes(a)),
                    " | ",
                    vm.toString(handler.skips(a)),
                    " | ",
                    vm.toString(handler.unexpectedFails(a)),
                    " ",
                    vm.toString(
                        vm.envOr(
                            string.concat("INV_", handler.tag(), "_", handler.actionName(a), "_lastsel"), bytes32(0)
                        )
                    ),
                    " | ",
                    vm.toString(handler.tally(a, "att")),
                    " ",
                    vm.toString(handler.tally(a, "ok")),
                    " ",
                    vm.toString(handler.tally(a, "skip")),
                    " ",
                    vm.toString(handler.tally(a, "unexpected"))
                )
            );
        }
        console.log("ghost spends", handler.gSpendEvents(), "biggest window use bps", handler.biggestSpendBps());
        console.log("eth pot", core.ethPot(), "rate", core.ethRate());
        console.log("statements ever held", handler.everHeldCount(), "held now", core.heldStatements().length);
        console.log("coin supply", coin.totalSupply(), "burned by buybacks", handler.gBurnedByBuyback());
        console.log("burned by auction fills", handler.gBurnedByAuction(), "held by the burn address", handler.gDead());
        console.log(
            "swaps under a skim above baseline", handler.windowSwaps(), "taxed to the burn address", handler.sideTaxed()
        );
        console.log("receive() direct sends", handler.receiveSends(), "failures", handler.receiveFails());
        uint256 f = handler.swapFailSelCount();
        for (uint256 i; i < f; ++i) {
            bytes4 sel = handler.swapFailSels(i);
            console.log("real swap failures by selector", vm.toString(sel), handler.swapFails(sel));
        }
    }

    /*//////////////////////////////////////////////////////////////
                         HANDLER SELF CHECKS
    //////////////////////////////////////////////////////////////*/

    /// dispatches one handler action by number. the arguments mean what the action needs.
    function _act(uint256 a, uint256 w, uint256 x, uint256 y, uint256 z) internal {
        a = a % 22;
        if (a == 0) handler.buyCoin(w, x, y);
        else if (a == 1) handler.sellCoin(w, x, y);
        else if (a == 2) handler.sellForEth(w, x, y, z);
        else if (a == 3) handler.listingStrategy(w, x);
        else if (a == 4) handler.listingHostile(w, x);
        else if (a == 5) handler.warp(w);
        else if (a == 6) handler.roll(w);
        else if (a == 7) handler.compose(w, x);
        else if (a == 8) handler.buyStatement(w, x, y, z);
        else if (a == 9) handler.buyback(w);
        else if (a == 10) handler.skim(w);
        else if (a == 11) handler.donate(w, x);
        else if (a == 12) handler.controllerSeed(w);
        else if (a == 13) handler.controllerSwap(w);
        else if (a == 14) handler.overprint();
        else if (a == 15) handler.probeController(w);
        else if (a == 16) handler.sellForExit(w, x, y);
        else if (a == 17) handler.composeExit(w, x);
        else if (a == 18) handler.exitStatement(w, x);
        else if (a == 19) handler.buybackExit(w, x);
        else if (a == 20) handler.moduleMode(w);
        else handler.sideBuy(w, x);
    }

    /// no action may revert, whatever the inputs. a reverting handler loses its ghost writes and hides violations.
    /// the violation counters must also stay at zero after any single action.
    function testFuzz_handlerNeverReverts(uint256 a, uint256 w, uint256 x, uint256 y, uint256 z) public {
        _act(a, w, x, y, z);
        for (uint256 i = 1; i < handler.violationCount(); ++i) {
            assertEq(handler.viol(i), 0, handler.violMsg(i));
        }
    }

    uint256 internal _nonce;

    /// calls action `a` with derived seeds until it succeeds once more than before, up to `tries` times.
    function _try(uint256 a, uint256 tries) internal returns (bool) {
        uint256 before = handler.successes(a);
        for (uint256 i; i < tries; ++i) {
            uint256 s = uint256(keccak256(abi.encode(a, i, before, ++_nonce)));
            // the fuzz controller answers from its seed, so a new seed gives new answers
            handler.controllerSeed(s >> 40);
            _act(a, s, s >> 8, s >> 16, s >> 24);
            if (handler.successes(a) > before) return true;
        }
        return false;
    }

    /// a suite where everything reverts proves nothing. this drives every action of the suite to a success.
    /// forge-config: default.gas_limit = 9223372036854775807
    function test_everyActionSucceeds() public virtual {
        _smoke();
        uint256 n = handler.actionCount();
        for (uint256 a; a < n; ++a) {
            if (!_available(a)) continue;
            assertGt(handler.successes(a), 0, string.concat("never succeeded: ", handler.actionName(a)));
        }
        for (uint256 i = 1; i < handler.violationCount(); ++i) {
            assertEq(handler.viol(i), 0, handler.violMsg(i));
        }
        _summary();
    }

    function _available(uint256 a) internal view returns (bool) {
        if (a >= 16 && !handler.phase2()) return false;
        if (a == 13 && !handler.canSwapController()) return false;
        return true;
    }

    function _smoke() internal virtual {
        // the fuzz controller is queued and ripe in the swap suites. switch to it, so overprints can answer. a run
        // that began inside the sniper window needs one more call, the first one allows the hostile target
        if (handler.canSwapController()) {
            assertTrue(_try(13, 20), "no controller swap executed");
            if (core.controller() != address(fuzz)) assertTrue(_try(13, 20), "no controller swap executed");
        }
        // plain actions
        _try(0, 20);
        _try(1, 20);
        assertTrue(_try(21, 20), "no taxed side pool buy");
        _try(5, 5);
        _try(6, 5);
        _try(10, 5);
        _try(11, 5);
        _try(12, 5);
        _try(13, 5);
        _try(15, 5);
        // credits in, so the eth pile reaches 80
        _try(2, 40);
        _try(2, 40);
        _try(2, 40);
        _try(4, 60);
        // the real listings need the ceiling to clear the price, so warp until one passes
        for (uint256 i; i < 12 && !_try(3, 20); ++i) {
            handler.warp(uint256(keccak256(abi.encode("w", i))) / 10 * 10 + 1);
        }
        assertTrue(handler.successes(3) > 0, "no real listing was bought");
        assertTrue(_try(7, 80), "compose never succeeded");
        // held eth statements are now at least three, so an overprint can pair two of them
        _overprintSmoke();
        if (handler.phase2()) _phase2Smoke();
        assertTrue(_try(8, 80), "no statement bought");
        // buyback needs 25 blocks after the last one
        handler.roll(200);
        assertTrue(_try(9, 60), "no buyback");
    }

    function _phase2Smoke() internal {
        // the statements composed so far are new or just overprinted, and an eth lane statement exits only after
        // its auction ran its length
        vm.warp(block.timestamp + 73 hours);
        assertTrue(_try(18, 80), "no exit");
        assertTrue(_try(16, 60), "no exit token sale");
        _try(16, 60);
        assertTrue(_try(17, 80), "no exit lane compose");
        assertTrue(_try(20, 20), "no module mode");
        // the auction opens at the whole coin supply for one slice and halves every hour. wait until a taker can
        // afford a fill with a little coin bought in the real pool
        for (uint256 i; i < 40 && handler.successes(19) == 0; ++i) {
            _try(19, 4);
            vm.warp(block.timestamp + 1 hours);
        }
        assertGt(handler.successes(19), 0, "no exit auction fill");
    }

    function _overprintSmoke() internal {
        for (uint256 i; i < 80 && handler.successes(14) == 0; ++i) {
            handler.controllerSeed(i + 1000);
            _try(14, 3);
        }
        assertGt(handler.successes(14), 0, "no overprint");
    }

    /*//////////////////////////////////////////////////////////////
                                  HELPERS
    //////////////////////////////////////////////////////////////*/

    function _ownerOfStatement(uint256 sid) internal view returns (address o) {
        (bool ok, bytes memory out) = address(STATEMENTS).staticcall(abi.encodeWithSignature("ownerOf(uint256)", sid));
        if (ok && out.length == 32) o = abi.decode(out, (address));
    }

    function _statementsBalance(address a) internal view returns (uint256) {
        return _balanceOf(address(STATEMENTS), a);
    }

    function _balanceOf(address token, address a) internal view returns (uint256 b) {
        (bool ok, bytes memory out) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", a));
        if (ok && out.length == 32) b = abi.decode(out, (uint256));
    }
}

/// phase 1 after the sniper window: the exit module slot is empty, the controller is ControllerV1 and may be swapped
/// for the fuzz controller in benign mode through the owner timelock. the owner setup took a week, so the skim is
/// the 10 point baseline.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsPhase1 is InvariantsBase {
    function setUp() public virtual override {
        _build(false, false, true, false, "p1");
    }

    /// the storage slots used by the handler and by invariant 7 match the public getters.
    function test_storageLayoutMatchesWindowSlots() public view {
        assertEq(uint256(vm.load(address(core), bytes32(uint256(5)))), core.ethPot());
        assertEq(uint256(vm.load(address(core), bytes32(uint256(9)))), core.rateAtCheckpoint());
        assertEq((uint256(vm.load(address(core), bytes32(uint256(10)))) >> 64) & type(uint64).max, core.lastFillTime());
        // the prefill opened a window, so the slots hold real values
        assertGt(_windowStart(), 0);
        assertGt(_windowPot(), 0);
        assertGt(_windowSpent(), 0);
        assertEq(handler.gWinStart(), _windowStart());
        assertEq(handler.gWinPot(), _windowPot());
        assertEq(handler.gWinSpent(), _windowSpent());
    }
}

/// the same suite for deep runs. it has no inline config, so it takes its runs and depth from the environment or
/// from foundry.toml, and it skips itself unless INVARIANT_DEEP is set. see the header of this file.
contract InvariantsPhase1Deep is InvariantsPhase1 {
    function setUp() public override {
        vm.skip(!vm.envOr("INVARIANT_DEEP", false));
        super.setUp();
    }
}

/// phase 1 starting inside the sniper window: setUp ends a few seconds after launch, the pot, the piles and the
/// statements were all built under a 90 percent skim, and the owner's hostile target and fuzz controller are only
/// queued. the run begins with the skim near its maximum and the handler allows the target and switches the
/// controller once the timelock has run.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsPhase1Window is InvariantsBase {
    function setUp() public virtual override {
        _build(false, false, true, true, "w1");
    }

    /// the run starts inside the window with the skim well above the baseline
    function test_startsInsideTheSniperWindow() public view {
        assertLt(block.timestamp, launchTime + SNIPER_WINDOW / 2);
        assertGt(_skimBpsNow(), 10_000);
    }

    function _skimBpsNow() internal view returns (uint256) {
        return IArtCoinsMevSkim(Mainnet.MEV_LINEAR_SKIM).currentSkimBps(poolId);
    }

    /// everything the money side does inside the window first, then the standard smoke after the week the owner
    /// actions need
    function _smoke() internal override {
        assertGt(_skimBpsNow(), 10_000);
        _try(0, 20);
        _try(1, 20);
        _try(2, 40);
        _try(2, 40);
        _try(10, 5);
        _try(11, 5);
        assertTrue(_try(7, 80), "no compose inside the window");
        // the compose used the pile up, so fill it again for the compose of the standard smoke, still inside the window
        for (uint256 i; i < 30 && core.pileSize(Lane.Eth) < 80; ++i) {
            _try(2, 10);
        }
        assertGe(core.pileSize(Lane.Eth), 80, "the pile did not refill");
        assertTrue(_try(8, 80), "no statement bought inside the window");
        // buyback needs 25 blocks after the last one. move blocks, not time, to stay inside the window
        vm.roll(block.number + 200);
        assertTrue(_try(9, 60), "no buyback inside the window");
        assertLt(block.timestamp, launchTime + SNIPER_WINDOW, "the window closed during the smoke");
        assertGe(handler.windowSwaps(), 3, "too few swaps ran under the high skim");
        vm.warp(block.timestamp + 7 days + 1);
        vm.roll(block.number + 7 days / 12);
        super._smoke();
    }
}

/// the same suite for deep runs. no inline config, skipped unless INVARIANT_DEEP is set.
contract InvariantsPhase1WindowDeep is InvariantsPhase1Window {
    function setUp() public override {
        vm.skip(!vm.envOr("INVARIANT_DEEP", false));
        super.setUp();
    }
}
