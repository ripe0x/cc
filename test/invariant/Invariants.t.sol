// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Lane, Mainnet, Settings} from "../../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../../src/interfaces/AuctionHouse.sol";
import {IArtCoinsMevSkim} from "../../src/interfaces/ArtCoins.sol";
import {InvariantFixture} from "./InvariantFixture.sol";
import {HandlerBase} from "./HandlerBase.sol";

/// @notice SPEC section 10 as reworked by docs/FLOW.md, one `invariant_` function per item, against the real system on
/// the mainnet fork: the real Core, the real pnd auction house it owns, the live Credits, Statements, CreditScore,
/// CreditStrategy, pool manager and artcoins stack. only the exit module and exit token are stand ins.
///
/// how to run:
///   set -a; . ./.env; set +a
///   forge test --match-path 'test/invariant/*' -vv      # the default, runs 24 and depth 80, a few minutes
///   INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 \
///     forge test --match-contract '.*Deep' -vv           # deeper, only the Deep variants run
/// the defaults come from inline `forge-config` lines on the concrete suites: phase 1 after the sniper window, phase 1
/// starting inside the window (90 percent skim at the start), phase 2 with the exit auction, phase 2 under a hostile
/// controller, and phase 2 under a hostile owner (the owner's calls are frequent and adversarial). an inline line beats
/// an environment variable, so the Deep variants carry no inline config and skip themselves unless INVARIANT_DEEP is
/// set. they are the same suites, only the depth comes from the environment.
/// every `invariant_` function is its own campaign, so cost grows with runs times depth times the number of
/// functions. each campaign starts from the state after `setUp`, which has a funded pot, pre filled piles, listed
/// statements, two of them sold (one collected) and a climbed rate. `-vv` shows the call summary that
/// `invariant_callSummary` logs. the summary also keeps running totals over all runs in this process through the
/// environment, which no revert can undo.
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
    uint256[] internal g5 = [22, 28];
    uint256[] internal g6 = [11, 12, 13];
    uint256[] internal g7 = [14];
    uint256[] internal g8 = [15, 16, 17, 27, 29];
    uint256[] internal g9 = [25];
    uint256[] internal g10 = [24];
    /// sales through sellTo and buy, and the departures of statements
    uint256[] internal g11 = [7, 8, 30];
    /// locks and handovers
    uint256[] internal g12 = [31];

    function _zero(uint256[] storage codes) internal view {
        for (uint256 i; i < codes.length; ++i) {
            assertEq(handler.viol(codes[i]), 0, handler.violMsg(codes[i]));
        }
    }

    /// 1. eth leaves the core only as a credit purchase within the ceiling, a tip within tipCapBps and tipSavingsBps, a
    /// compose reimbursement within its cap, a buyback slice (the swap input plus the keeper tip) or a refund of
    /// overpayment. every action's balance change is matched to those flows, measured at the recipients, against the
    /// settings in force at that moment (the owner changes them throughout). the only inflows are the hook's skim pushed
    /// into receive() during real swaps, including the one the hook pushes back during the buyback, `collectSales` (and
    /// the collection a buyback starts with) and a plain donation. any other movement is a violation. exit token flows
    /// too: it leaves the core only as a bid payment in sellForExitToken or as an auction slice paid for at or above
    /// the quoted coin price.
    function invariant_01_ethOnlyLeavesByAllowedPaths() public view {
        _zero(g1);
    }

    /// 2. no credit is bought above the blended ceiling, flatBps * avgScore + (1 - flatBps) * score at the eth rate,
    /// with the controller bonus at the bonus cap in force. rate, score and settings are read before the action.
    function invariant_02_noCreditAboveBonusCap() public view {
        _zero(g2);
    }

    /// 3. a statement leaves the core's control only through a house auction whose winning bid was at or above the
    /// reserve the core set for it (tracked at the listing and at every reprice), an exit that returned at least
    /// rating * unitPerPoint, or as the top of an overprint. here the first part: every sold statement sold at or above
    /// its reserve, and the reserve was the one the core's rule gives (cost * saleFloorBps of the settings in force when
    /// it was listed or repriced).
    function invariant_03_noStatementSoldBelowItsReserve() public view {
        _zero(g3);
        uint256 n = handler.everHeldCount();
        for (uint256 i; i < n; ++i) {
            HandlerBase.SG memory s = handler.statementGhost(handler.everHeld(i));
            if (s.status == handler.S_SOLD()) {
                assertGe(s.price, s.reserve, "sold below the reserve the core set");
                assertGe(s.reserve, s.floorAtSet, "an auction reserve was set below the hard floor");
                assertGe(s.price, s.floorAtSet, "an auction cleared below the hard floor of its listing");
            } else if (s.status == handler.S_SOLD_TO()) {
                assertGe(s.price, s.floorAtSet, "a sellTo sale paid less than the hard floor");
                assertGe(s.price, s.reserve, "a sellTo sale paid less than the floor it was checked against");
            }
        }
    }

    /// 4. every statement ever composed is, at all times, exactly one of: listed on the house, held by the core
    /// unlisted, sold, exited, or overprinted. the ghost status is checked against the statements token, the house
    /// and the core's own records. a sold statement is stale in the core's record until `syncStatement`, which is
    /// then run for every one of them (and undone) and must clear the record. a listed one must refuse it.
    function invariant_04_everyStatementIsInExactlyOnePlace() public {
        _zero(g4);
        uint256 n = handler.everHeldCount();
        uint256 inRecord;
        uint256 listedOrHeld;
        for (uint256 i; i < n; ++i) {
            uint256 sid = handler.everHeld(i);
            HandlerBase.SG memory s = handler.statementGhost(sid);
            address o = _ownerOfStatement(sid);
            (bool held,, uint256 cost, uint64 clock) = core.statementInfo(sid);
            if (s.status == handler.S_LISTED()) {
                inRecord++;
                listedOrHeld++;
                _checkListed(sid, s, o, held, cost, clock);
            } else if (s.status == handler.S_HELD()) {
                inRecord++;
                listedOrHeld++;
                assertEq(o, address(core), "an exit lane statement is not held by the core");
                assertTrue(held, "an exit lane statement is not recorded as held");
                assertEq(cost, s.cost, "exit lane cost basis differs");
                (ICore.StatementStatus st,,,,) = core.statementStatus(sid);
                assertEq(uint256(st), uint256(ICore.StatementStatus.Held), "held statement has another status");
            } else if (s.status == handler.S_SOLD()) {
                assertEq(o, s.winner, "a sold statement is not with its winner");
                assertGe(s.price, s.reserve, "sold below the reserve");
                if (!s.synced) {
                    inRecord++;
                    assertTrue(held, "a sold, unsynced statement lost its record");
                    (ICore.StatementStatus st,,,,) = core.statementStatus(sid);
                    assertEq(uint256(st), uint256(ICore.StatementStatus.Sold), "the live status of a sale is Sold");
                } else {
                    assertTrue(!held, "a synced sale is still recorded as held");
                }
            } else if (s.status == handler.S_SOLD_TO()) {
                assertEq(o, s.winner, "a statement sold at once is not with its buyer");
                assertTrue(!held, "a statement sold at once is still recorded as held");
                assertGe(s.price, s.floorAtSet, "sold at once below the hard floor");
                (bool exists,) = house.getAuctionFor(address(STATEMENTS), sid);
                assertTrue(!exists, "the house has an auction for a statement sold at once");
            } else if (s.status == handler.S_EXITED()) {
                assertTrue(!held, "exited but still held");
                assertEq(o, address(s.module), "an exited statement is not with the module that took it");
                assertGe(s.received, s.required, "exit returned less than rating * unitPerPoint");
            } else if (s.status == handler.S_TOP()) {
                assertTrue(!held, "overprint top still marked held");
                assertEq(o, address(0), "overprint top still exists");
                HandlerBase.SG memory b = handler.statementGhost(s.base);
                assertTrue(b.status != 0, "overprint base is not a statement the core held");
            } else {
                revert("an ever held statement has no recorded status");
            }
        }
        assertEq(inRecord, core.heldStatements().length, "held count differs from the core's list");
        _syncEverything(n, inRecord - listedOrHeld);
    }

    function _checkListed(uint256 sid, HandlerBase.SG memory s, address o, bool held, uint256 cost, uint64 clock)
        internal
        view
    {
        assertEq(o, address(house), "a listed statement is not held by the house");
        assertTrue(held, "a listed statement is not recorded as held");
        assertEq(cost, s.cost, "listed cost basis differs");
        assertEq(clock, s.listedAt, "listing time differs");
        (ICore.StatementStatus st, uint256 aid, uint256 reserve, uint256 bid,) = core.statementStatus(sid);
        assertEq(aid, s.auctionId, "auction id differs");
        assertEq(reserve, s.reserve, "the reserve on the house is not the one the core set");
        assertEq(bid, s.bid, "the top bid differs");
        assertTrue(
            st == ICore.StatementStatus.Listed || st == ICore.StatementStatus.Bid || st == ICore.StatementStatus.Ended,
            "a listed statement has another live status"
        );
        IAuctionHouse.Auction memory au = house.getAuction(s.auctionId);
        assertEq(au.tokenOwner, address(core), "the house does not name the core as the seller");
        assertEq(au.tokenId, sid, "the house auction is for another statement");
        assertEq(au.bidder, s.bidder, "the top bidder differs");
    }

    /// runs `syncStatement` for every statement the ghost model has sold, and for every listed one, and undoes it. a
    /// sold one must clear the core's record and leave the winner the holder, a listed one must refuse with
    /// AuctionLive. afterwards the core's held list is exactly the listed and the held statements
    function _syncEverything(uint256 n, uint256 soldUnsynced) internal {
        uint256 snap = vm.snapshotState();
        uint256 listedOrHeld = core.heldStatements().length - soldUnsynced;
        for (uint256 i; i < n; ++i) {
            uint256 sid = handler.everHeld(i);
            HandlerBase.SG memory s = handler.statementGhost(sid);
            if (s.status == handler.S_SOLD() && !s.synced) {
                core.syncStatement(sid);
                (bool held,,,) = core.statementInfo(sid);
                assertTrue(!held, "syncStatement left the sold statement recorded");
                assertEq(_ownerOfStatement(sid), s.winner, "syncStatement moved the sold statement");
            } else if (s.status == handler.S_LISTED()) {
                try core.syncStatement(sid) {
                    revert("syncStatement settled a statement that is still listed");
                } catch (bytes memory why) {
                    assertEq(bytes4(why), ICore.AuctionLive.selector, "a listed statement refused for another reason");
                }
            }
        }
        assertEq(
            core.heldStatements().length, listedOrHeld, "after syncStatement the record is not the listed and held"
        );
        vm.revertToState(snap);
    }

    /// 5. ethPot + ethToBuyback never exceeds the core's eth balance, and the same for the exit token pots. the proceeds
    /// the house owes the core are not in the pots until collected: what it owes is exactly the sum of the winning
    /// bids of the settled auctions less what was collected, and after `collectSales` it owes nothing, the core's
    /// balance rose by what it owed and the pots by that amount split by saleToBuybackBps. the sum ever collected
    /// equals the sum of the winning bids of the auctions settled so far, less what is still owed.
    function invariant_05_potsNeverExceedBalances() public {
        _zero(g5);
        assertLe(core.ethPot() + core.ethToBuyback(), address(core).balance, "eth pots above balance");
        address t = core.exitToken();
        if (t != address(0)) {
            assertLe(core.xPot() + core.xToBuyback(), _balanceOf(t, address(core)), "exit token pots above balance");
        }
        uint256 won;
        uint256 n = handler.everHeldCount();
        for (uint256 i; i < n; ++i) {
            HandlerBase.SG memory s = handler.statementGhost(handler.everHeld(i));
            if (s.status == handler.S_SOLD()) won += s.price;
        }
        assertEq(won, handler.gWon(), "the sum of the sold prices differs from the winning bids settled");
        assertEq(
            house.pendingRefunds(address(core)), handler.gWon() - handler.gCollected(), "the house owes the wrong sum"
        );
        _collectAndCheck();
    }

    /// collects the sales as a stranger and checks the books, then undoes it
    function _collectAndCheck() internal {
        uint256 snap = vm.snapshotState();
        uint256 owed = house.pendingRefunds(address(core));
        uint256 bal = address(core).balance;
        uint256 pot = core.ethPot();
        uint256 tb = core.ethToBuyback();
        uint256 toBuyback = owed * core.settings().saleToBuybackBps / 10_000;
        vm.prank(address(0xC011));
        core.collectSales();
        assertEq(house.pendingRefunds(address(core)), 0, "the house owes the core after collectSales");
        assertEq(address(core).balance, bal + owed, "collectSales did not bring exactly what the house owed");
        assertEq(core.ethToBuyback(), tb + toBuyback, "collected buyback share");
        assertEq(core.ethPot(), pot + owed - toBuyback, "collected pot share");
        assertLe(core.ethPot() + core.ethToBuyback(), address(core).balance, "eth pots above balance after collecting");
        vm.revertToState(snap);
    }

    /// 6. the rate does not rise in any interval where the pot was unfunded, whatever the settings. checked around
    /// every action and every warp against the settings in force over the interval. the only calls that make the stored
    /// rate jump are the owner's `setRate`, which lands on the rate asked for, and nothing else: a settings call keeps
    /// the rate exactly. the funded flag is recomputed independently from the pot, the stored rate and the settings.
    function invariant_06_rateNeverRisesWhileUnfunded() public view {
        _zero(g6);
        Settings memory st = core.settings();
        assertEq(
            core.funded(),
            core.ethPot() * st.spendCapBps >= uint256(st.avgScore) * core.rateAtCheckpoint(),
            "funded flag stale"
        );
    }

    /// 7. hourly eth spend never exceeds the cap. the core applies the cap in force at each spend to the pot the window
    /// opened with, so a change of spendCapBps inside a window takes effect on the next spend: raised, the window may
    /// spend past the cap it opened under (counted as `gOverOpenCap`), lowered, spending that already happened stays
    /// and nothing more passes (`gOverNowCap`). the model checks exactly that at every spend, and with no change of the
    /// cap in the window the original cap. the window is read from core storage and compared with the ghost.
    function invariant_07_hourlySpendWithinCap() public view {
        _zero(g7);
        uint256 ws = _windowStart();
        uint256 wp = _windowPot();
        uint256 sp = _windowSpent();
        assertLe(ws, block.timestamp, "window starts in the future");
        assertEq(handler.gWinStart(), ws, "ghost window start differs");
        assertEq(handler.gWinPot(), wp, "ghost window pot differs");
        assertEq(handler.gWinSpent(), sp, "ghost window spend differs");
        if (!handler.gWinCapChanged()) {
            assertLe(sp * 10_000, wp * handler.gWinCap(), "window spend above the cap the window opened under");
        }
    }

    /// 8. the hard rule: across the whole campaign neither the owner address nor any controller address ever gains eth,
    /// coin, credits, statements or exit token from the core, whatever settings the owner chooses. their balances are
    /// compared with what they held at the start (the owner pays gas only). the controllers' attack calls all failed,
    /// their reentry attempts through targets failed, and nobody but the owner changed a setting.
    function invariant_08_ownerAndControllersNeverGain() public view {
        _zero(g8);
        uint256 n = handler.watchedCount();
        address xtoken = core.exitToken();
        for (uint256 i; i < n; ++i) {
            address c = handler.watched(i);
            (uint256 eth, uint256 coin_, uint256 credits_, uint256 statements_, uint256 xt_) = handler.baseOf(c);
            assertLe(c.balance, eth, "owner or controller gained eth");
            assertLe(coin.balanceOf(c), coin_, "owner or controller gained coin");
            assertLe(CREDITS.balanceOf(c), credits_, "owner or controller gained credits");
            assertLe(_statementsBalance(c), statements_, "owner or controller gained statements");
            if (xtoken != address(0)) assertLe(_balanceOf(xtoken, c), xt_, "owner or controller gained exit token");
        }
        bool known;
        for (uint256 i; i < handler.controllerCount(); ++i) {
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

    /// 11. model check: no action the ghost model expected to succeed reverted, and every action it expected to
    /// revert did so with the selector it expected. a core that started refusing calls it used to accept, or refusing
    /// for another reason, would show up here and nowhere else.
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

    /// 12. docs/FLOW.md 9.2, SPEC invariant 3 as changed: a statement leaves the core only by a house auction whose reserve
    /// was at least the hard floor (cost * saleFloorBps) when the core set it and which cleared at or above it, by `sellTo`
    /// with a payment at least the hard floor, booked whole and split by saleToBuybackBps, by an exit that returned at
    /// least rating * unitPerPoint, or as the top of an overprint. every ghost status is one of those, the record and the
    /// house agree (invariant 4), and nobody the owner can name holds a statement they did not pay the floor for.
    function invariant_12_aStatementOnlyLeavesByASaleAnExitOrAnOverprint() public view {
        _zero(g11);
        uint256 n = handler.everHeldCount();
        for (uint256 i; i < n; ++i) {
            HandlerBase.SG memory s = handler.statementGhost(handler.everHeld(i));
            uint8 st = s.status;
            assertTrue(
                st == handler.S_LISTED() || st == handler.S_HELD() || st == handler.S_SOLD() || st == handler.S_SOLD_TO()
                    || st == handler.S_EXITED() || st == handler.S_TOP(),
                "a statement left the core by a path that is not allowed"
            );
            if (st == handler.S_SOLD_TO()) assertGe(s.price, s.floorAtSet, "a sale at once below the hard floor");
            if (st == handler.S_SOLD()) assertGe(s.price, s.floorAtSet, "an auction below the hard floor");
        }
    }

    /// 13. the three one way locks never come undone, the setter of a locked door always refuses, every former owner has no
    /// power for the core or for the controller's sale settings, and the core's owner is the one the handler last saw
    /// accept. the handler checks each of these again on every call here
    function invariant_13_locksAndHandoversNeverComeUndone() public {
        handler.lockCheck();
        handler.formerOwnersCheck();
        _zero(g12);
        assertEq(core.owner(), handler.owner(), "the core owner differs from the last accepted owner");
        assertTrue(core.pendingOwner() != core.owner(), "the pending owner is the owner");
    }

    /// 14. no exit module ever called the core, or the selling controller, successfully from inside an exit: every door is
    /// shut while the core is inside `exitStatement`, whatever the module does with its gas
    function invariant_14_noCallFromInsideAnExitEverWorked() public view {
        uint256 n = handler.moduleEverCount();
        for (uint256 i; i < n; ++i) {
            assertTrue(!handler.modulesEver(i).calledOk(), "a module made a call into the core that went through");
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
        console.log("cap changes inside an open window", handler.gCapChanges());
        console.log(
            "spends past the opening cap", handler.gOverOpenCap(), "windows past the new cap", handler.gOverNowCap()
        );
        console.log("eth pot", core.ethPot(), "rate", core.ethRate());
        console.log("won on the house", handler.gWon(), "collected", handler.gCollected());
        console.log("owed by the house", house.pendingRefunds(address(core)));
        console.log("owner calls checked", handler.gOwnerCalls(), "refused as expected", handler.gOwnerRefused());
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
    function _act(uint256 a, uint256 w, uint256 x, uint256 y, uint256 z) internal virtual {
        a = a % 32;
        if (a == 0) handler.buyCoin(w, x, y);
        else if (a == 1) handler.sellCoin(w, x, y);
        else if (a == 2) handler.sellForEth(w, x, y, z);
        else if (a == 3) handler.listingStrategy(w, x);
        else if (a == 4) handler.listingHostile(w, x);
        else if (a == 5) handler.warp(w);
        else if (a == 6) handler.roll(w);
        else if (a == 7) handler.compose(w, x);
        else if (a == 8) handler.bid(w, x, y, z);
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
        else if (a == 21) handler.sideBuy(w, x);
        else if (a == 22) handler.endAuction(w, x);
        else if (a == 23) handler.collectSales(w);
        else if (a == 24) handler.syncStatement(w, x);
        else if (a == 25) handler.repriceStatement(w, x);
        else if (a == 26) handler.setSettings(w, x);
        else if (a == 27) handler.setSettingsInvalid(w, x);
        else if (a == 28) handler.setRate(w, x);
        else if (a == 29) handler.setXRate(w, x);
        else if (a == 30) handler.ownerMisc(w, x);
        else handler.replaceModule(w, x);
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

    /// the sale and owner actions of `HandlerSale` run only in the suites that list them
    function _saleSuite() internal pure virtual returns (bool) {
        return false;
    }

    function _available(uint256 a) internal view returns (bool) {
        if (a >= 32) return _saleSuite();
        if ((a >= 16 && a <= 20 || a == 31) && !handler.phase2()) return false;
        if (a == 13 && !handler.canSwapController()) return false;
        return true;
    }

    function _smoke() internal virtual {
        // the owner may swap to the fuzz controller at once in the swap suites. switch to it, so overprints can answer
        if (handler.canSwapController()) {
            assertTrue(_try(13, 20), "no controller swap executed");
            // the swap action may have ended on the plain controller: put the fuzz controller in force by hand
            if (core.controller() != address(fuzz)) {
                vm.prank(handler.owner());
                core.setController(address(fuzz));
            }
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
        // listed eth statements are now at least three, so an overprint can pair two of them
        _overprintSmoke();
        // the statement sales on the house: bids around the reserve, a settlement, the collection, the lazy sync
        // of a sold statement and the reprice of a listing that has no bid
        assertTrue(_try(8, 80), "no bid on a listed statement");
        assertTrue(_try(22, 80), "no auction settled");
        assertTrue(_try(23, 20), "no collectSales");
        assertTrue(_try(24, 80), "no sync of a sold statement");
        assertTrue(_try(25, 80), "no reprice of a listing");
        if (handler.phase2()) _phase2Smoke();
        // buyback needs buybackDelay blocks after the last one
        vm.roll(block.number + 200);
        assertTrue(_try(9, 60), "no buyback");
        _ownerSmoke();
    }

    /// the owner's calls: valid settings across the bounds, refused ones, the rates and the other doors
    function _ownerSmoke() internal {
        assertTrue(_try(26, 20), "no settings change");
        assertTrue(_try(27, 20), "no refused settings");
        assertTrue(_try(28, 20), "no setRate");
        assertTrue(_try(29, 20), "no setXRate");
        assertTrue(_try(30, 20), "no owner door");
        // the books keep working under the new settings, whatever they are
        for (uint256 i; i < 6; ++i) {
            _try(26, 5);
            _try(5, 5);
            _try(2, 5);
        }
    }

    function _phase2Smoke() internal {
        // the statements composed so far are new or just overprinted, and an eth lane statement exits only after it
        // was listed without a bid for exitAfter (105 hours at launch)
        vm.warp(block.timestamp + 106 hours);
        assertTrue(_try(18, 80), "no exit");
        assertTrue(_try(16, 60), "no exit token sale");
        _try(16, 60);
        assertTrue(_try(17, 80), "no exit lane compose");
        assertTrue(_try(20, 20), "no module mode");
        // the owner replaces the exit module: a new one, the same one with a new unit, and the refusals
        assertTrue(_try(31, 40), "no module replacement");
        for (uint256 i; i < 8; ++i) {
            handler.replaceModule(i * 7919 + 1, i);
        }
        // the auction opens at the whole coin supply for one slice and halves every 6 hours. wait until a taker can
        // afford a fill with a little coin bought in the real pool
        for (uint256 i; i < 120 && handler.successes(19) == 0; ++i) {
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
/// for the fuzz controller in benign mode at once. the owner setup came a week, so the skim is
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
        assertEq(uint256(vm.load(address(core), bytes32(uint256(6)))), core.ethPot());
        assertEq(uint256(vm.load(address(core), bytes32(uint256(10)))), core.rateAtCheckpoint());
        assertEq((uint256(vm.load(address(core), bytes32(uint256(11)))) >> 64) & type(uint64).max, core.lastFillTime());
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
/// statements were all built under a 90 percent skim, and the owner has allowed the hostile target. the run begins
/// with the skim near its maximum and the handler may switch the controller at any time.
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
        return IArtCoinsMevSkim(lc.mevModule).currentSkimBps(poolId);
    }

    /// everything the money side does inside the window first, then the standard smoke after a week
    function _smoke() internal override {
        assertGt(_skimBpsNow(), 10_000);
        _try(0, 20);
        _try(1, 20);
        _try(2, 40);
        _try(2, 40);
        _try(10, 5);
        _try(11, 5);
        assertTrue(_try(7, 80), "no compose inside the window");
        // statements listed inside the window take bids. an auction cannot finish inside it, so no sale yet
        assertTrue(_try(8, 80), "no bid inside the window");
        for (uint256 i; i < 5; ++i) {
            _try(0, 10);
        }
        assertLt(block.timestamp, launchTime + SNIPER_WINDOW, "the window closed during the smoke");
        assertGe(handler.windowSwaps(), 3, "too few swaps ran under the high skim");
        // the compose used the pile up, so fill it again for the compose of the standard smoke
        for (uint256 i; i < 30 && core.pileSize(Lane.Eth) < 80; ++i) {
            _try(2, 10);
        }
        assertGe(core.pileSize(Lane.Eth), 80, "the pile did not refill");
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
