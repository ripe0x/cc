// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {Core} from "../../src/Core.sol";
import {Lane, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {InvariantFixture} from "./InvariantFixture.sol";
import {Handler} from "./Handler.sol";

/// @notice SPEC section 10, one `invariant_` function per item, against the real system on the mainnet fork.
///
/// how to run:
///   set -a; . ./.env; set +a
///   forge test --match-path 'test/invariant/*' -vv      # the default, runs 24 and depth 80, a few minutes
///   INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 \
///     forge test --match-contract '.*Deep' -vv           # deeper, only the Deep variants run
/// the defaults come from inline `forge-config` lines on the three concrete suites. an inline line beats an
/// environment variable, so the Deep variants carry no inline config and skip themselves unless INVARIANT_DEEP is
/// set. they are the same suites, only the depth comes from the environment.
/// every `invariant_` function is its own campaign, so cost grows with runs times depth times the number of
/// functions. each campaign starts from the state after `setUp`, which has a funded pot, pre filled piles, a
/// composed statement and a climbed rate. `-vv` shows the call summary that `invariant_callSummary` logs. the
/// summary also keeps running totals over all runs in this process through the environment, which no revert
/// can undo.
///
/// the handler never reverts. a failed core call is caught, counted, and checked for leaving state untouched, so
/// a violation recorded in the ghosts cannot be lost to `fail_on_revert = false`.
abstract contract InvariantsBase is InvariantFixture {
    /// the violation codes of the handler, grouped by SPEC item.
    uint256[] internal g1 = [1, 2, 3, 4, 6, 20, 21, 23, 18];
    uint256[] internal g2 = [5];
    uint256[] internal g3 = [7];
    uint256[] internal g4 = [8, 9, 19, 10];
    uint256[] internal g5 = [22];
    uint256[] internal g6 = [11, 12, 13];
    uint256[] internal g7 = [14];
    uint256[] internal g8 = [15, 16, 17];

    function _zero(uint256[] storage codes) internal view {
        for (uint256 i; i < codes.length; ++i) {
            assertEq(handler.viol(codes[i]), 0, handler.violMsg(codes[i]));
        }
    }

    /// 1. eth leaves the core only as a buy that returned a credit within its ceiling, a capped tip, a capped gas
    /// reimbursement, a buyback slice or a refund of overpayment. every action's balance change is matched to
    /// those flows, measured at the recipients. any other movement is a violation. exit token flows too.
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
        uint256 ws = (uint256(vm.load(address(core), bytes32(uint256(14)))) >> 136) & type(uint64).max;
        uint256 wp = uint256(vm.load(address(core), bytes32(uint256(15))));
        uint256 sp = uint256(vm.load(address(core), bytes32(uint256(16))));
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
            assertEq(c.balance, 0, "controller holds eth");
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

    /// 9. coin total supply never increases, and stays exactly SUPPLY.
    function invariant_09_coinSupplyIsFixed() public view {
        assertEq(coin.totalSupply(), core.SUPPLY(), "coin supply moved");
        assertEq(coin.totalSupply(), coin.SUPPLY(), "coin supply moved");
    }

    /// logs how often each action ran, succeeded and was skipped in this run, and over all runs so far.
    function invariant_callSummary() public view {
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
    }

    /*//////////////////////////////////////////////////////////////
                         HANDLER SELF CHECKS
    //////////////////////////////////////////////////////////////*/

    /// dispatches one handler action by number. the arguments mean what the action needs.
    function _act(uint256 a, uint256 w, uint256 x, uint256 y, uint256 z) internal {
        a = a % 24;
        if (a == 0) handler.buyCoin(w, x, y);
        else if (a == 1) handler.sellCoin(w, x, y);
        else if (a == 2) handler.sellForEth(w, x, y, z);
        else if (a == 3) handler.listingStrategy(w, x);
        else if (a == 4) handler.listingMock(w, x, y, z);
        else if (a == 5) handler.listingHostile(w, x);
        else if (a == 6) handler.warp(w);
        else if (a == 7) handler.roll(w);
        else if (a == 8) handler.compose(w, x);
        else if (a == 9) handler.buyStatement(w, x, y, z);
        else if (a == 10) handler.buyback(w);
        else if (a == 11) handler.skim(w);
        else if (a == 12) handler.donate(w, x);
        else if (a == 13) handler.controllerSeed(w);
        else if (a == 14) handler.controllerSwap(w);
        else if (a == 15) handler.overprint();
        else if (a == 16) handler.probeController(w);
        else if (a == 17) handler.sellForExit(w, x, y);
        else if (a == 18) handler.composeExit(w, x);
        else if (a == 19) handler.exitStatement(w, x);
        else if (a == 20) handler.buybackExit(w);
        else if (a == 21) handler.moduleMode(w);
        else if (a == 22) handler.sendExitFees(w);
        else handler.exitPoolSwap(w, x, y);
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
    }

    function _available(uint256 a) internal view returns (bool) {
        if (a >= 17 && !handler.phase2()) return false;
        if (a == 14 && !handler.canSwapController()) return false;
        return true;
    }

    function _smoke() internal virtual {
        // the fuzz controller is queued and ripe in the swap suites. switch to it, so overprints can answer
        if (handler.canSwapController()) assertTrue(_try(14, 20), "no controller swap executed");
        // plain actions
        _try(0, 20);
        _try(1, 20);
        _try(6, 5);
        _try(7, 5);
        _try(11, 5);
        _try(12, 5);
        _try(13, 5);
        _try(16, 5);
        // credits in, so the eth pile reaches 80
        _try(2, 40);
        _try(2, 40);
        _try(2, 40);
        _try(4, 60);
        _try(5, 60);
        // the real listings need the ceiling to clear the price, so warp until one passes
        for (uint256 i; i < 12 && !_try(3, 20); ++i) {
            handler.warp(uint256(keccak256(abi.encode("w", i))) / 10 * 10 + 1);
        }
        assertTrue(handler.successes(3) > 0, "no real listing was bought");
        assertTrue(_try(8, 80), "compose never succeeded");
        // held eth statements are now at least three, so an overprint can pair two of them
        _overprintSmoke();
        if (handler.phase2()) {
            // the statements composed so far are new or just overprinted, and an eth lane statement exits only after
            // its auction ran its length
            vm.warp(block.timestamp + 73 hours);
            assertTrue(_try(19, 80), "no exit");
            assertTrue(_try(17, 60), "no exit token sale");
            _try(17, 60);
            assertTrue(_try(18, 80), "no exit lane compose");
            assertTrue(_try(23, 60), "no exit pool swap");
            assertTrue(_try(23, 60), "no exit pool swap");
            assertTrue(_try(22, 60), "no exit fees sent");
            assertTrue(_try(21, 20), "no module mode");
            assertTrue(_try(20, 60), "no exit buyback");
        }
        assertTrue(_try(9, 80), "no statement bought");
        // buyback needs 25 blocks after the last one
        handler.roll(200);
        assertTrue(_try(10, 60), "no buyback");
    }

    function _overprintSmoke() internal {
        for (uint256 i; i < 80 && handler.successes(15) == 0; ++i) {
            handler.controllerSeed(i + 1000);
            _try(15, 3);
        }
        assertGt(handler.successes(15), 0, "no overprint");
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

/// phase 1: the exit module slot is empty, the controller is ControllerV1 and may be swapped for the fuzz
/// controller in benign mode through the owner timelock.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsPhase1 is InvariantsBase {
    function setUp() public virtual {
        _build(false, false, true, "p1");
    }

    /// the hourly window slots used by the handler and by invariant 7 match the public getters.
    function test_storageLayoutMatchesWindowSlots() public {
        assertEq(uint256(vm.load(address(core), bytes32(uint256(9)))), core.ethPot());
        assertEq(uint256(vm.load(address(core), bytes32(uint256(13)))), core.rateAtCheckpoint());
        assertEq((uint256(vm.load(address(core), bytes32(uint256(14)))) >> 64) & type(uint64).max, core.lastFillTime());
        // the prefill opened a window, so the slots hold real values
        uint256 ws = (uint256(vm.load(address(core), bytes32(uint256(14)))) >> 136) & type(uint64).max;
        assertGt(ws, 0);
        assertGt(uint256(vm.load(address(core), bytes32(uint256(15)))), 0);
        assertGt(uint256(vm.load(address(core), bytes32(uint256(16)))), 0);
        assertEq(handler.gWinStart(), ws);
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
