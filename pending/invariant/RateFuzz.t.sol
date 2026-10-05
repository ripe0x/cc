// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Core} from "../../src/Core.sol";
import {CoreBase} from "../CoreUnit.t.sol";

/// @notice plain fuzz tests for the eth rate and the hourly cap (SPEC 5.1 and 5.2) with fuzzed times and amounts.
/// the model is an independent whole hour integer walk, so it shares no code with the core's wad pow.
contract RateFuzzTest is CoreBase {
    uint256 internal constant AVG = 4_330_000;
    uint256 internal constant START = 4e12;

    /// the rate after `hrs` whole hours of climbing from `r`, where `offset` hours have passed since the last fill.
    function _model(uint256 r, uint256 offset, uint256 hrs, uint256 cap) internal pure returns (uint256) {
        for (uint256 j; j < hrs; ++j) {
            if (r >= cap) break;
            uint256 k = (offset + j) / 24;
            uint256 bps = k >= 4 ? 800 : (100 << k);
            if (bps > 800) bps = 800;
            r = r * (10_000 + bps) / 10_000;
        }
        return r < cap ? r : cap;
    }

    function _dropOf(uint256 r, uint256 x, uint256 p) internal pure returns (uint256) {
        return r - r * 1000 * x / (10_000 * p);
    }

    /// slow climb and acceleration while unfilled: funded from the start, whole hours of waiting.
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_climbFollowsTiers(uint256 potSeed, uint256 waitSeed) public {
        uint256 pot = bound(potSeed, 0.01 ether, 1000 ether);
        uint256 hrs = bound(waitSeed, 0, 400);
        _fund(pot);
        assertTrue(core.funded());
        _warp(hrs * 1 hours);
        uint256 cap = pot * 1e4 / AVG;
        uint256 want = _model(START, 0, hrs, cap);
        assertApproxEqRel(core.ethRate(), want, 1e-9 ether, "tiers 1, 2, 4 then 8 percent per hour, clamped");
        assertLe(core.ethRate(), cap < START ? START : cap);
        // the first day never climbs faster than the slow tier of one percent an hour
        if (hrs <= 24 && want < cap) {
            assertLe(core.ethRate(), _model(START, 0, hrs, type(uint256).max) * (1e9 + 1) / 1e9);
        }
    }

    /// no climb while the pot cannot afford one average credit, and no retroactive climb once it can.
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_pauseWhenUnfunded(uint256 potSeed, uint256 idleSeed, uint256 topSeed, uint256 waitSeed) public {
        // one average credit costs AVG * rate / 1e4 = 1.732e15 wei at the start rate
        uint256 pot = bound(potSeed, 0, 1.73e15);
        uint256 idle = bound(idleSeed, 0, 3000);
        if (pot != 0) _fund(pot);
        assertFalse(core.funded());
        _warp(idle * 1 hours);
        assertEq(core.ethRate(), START, "frozen while unfunded");

        uint256 top = bound(topSeed, 1e16, 100 ether);
        _fund(top);
        assertTrue(core.funded());
        assertEq(core.ethRate(), START, "no retroactive climb");

        // the tier clock runs from the last fill, so the idle time counts toward the tier but not toward the rate
        uint256 hrs = bound(waitSeed, 0, 200);
        _warp(hrs * 1 hours);
        uint256 cap = (pot + top) * 1e4 / AVG;
        assertApproxEqRel(core.ethRate(), _model(START, idle, hrs, cap), 1e-9 ether);
    }

    /// a fill resets the tier clock and drops the rate in proportion to the share of the pot spent.
    /// forge-config: default.fuzz.runs = 30
    function testFuzz_fillDropsByShareAndResetsTier(uint256 potSeed, uint256 waitSeed, uint256 count) public {
        uint256 pot = bound(potSeed, 5 ether, 1000 ether);
        uint256 hrs = bound(waitSeed, 0, 72);
        uint256 n = bound(count, 1, 3);
        _fund(pot);
        _warp(hrs * 1 hours);
        uint256[] memory ids = _creditsTo(alice, n);
        uint256 r = core.ethRate();
        assertApproxEqRel(r, _model(START, 0, hrs, pot * 1e4 / AVG), 1e-9 ether);
        uint256 p = pot;
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            uint256 price = core.scoreOf(ids[i]) * r / 1e4;
            paid += price;
            r = _dropOf(r, price, p);
            p -= price;
        }
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(ids);
        assertEq(alice.balance - before, paid);
        assertEq(core.rateAtCheckpoint(), r, "dropped by 10 percent of the share spent, per credit");
        assertEq(core.ethPot(), pot - paid);
        assertEq(core.lastFillTime(), block.timestamp);
        // the tier clock restarted: one hour later the climb is the base 1 percent
        _warp(1 hours);
        uint256 after1 = core.ethRate();
        assertApproxEqRel(after1, core.rateAtCheckpoint() * 101 / 100, 1e-9 ether);
    }

    /// the hourly cap: an exact prediction of which sells pass, and the window reopens an hour after it opened.
    /// forge-config: default.fuzz.runs = 20
    function testFuzz_hourlyCap(uint256 potSeed, uint256 gapSeed) public {
        uint256 pot = bound(potSeed, 0.03 ether, 0.2 ether);
        _fund(pot);
        uint256[] memory ids = _creditsTo(alice, 40);
        uint256 cap = pot * 2000 / 10_000;
        uint256 spent;
        uint256 i;
        bool sawBlock;
        for (; i < ids.length; ++i) {
            uint256 price = core.ceilingOf(ids[i]);
            bool fits = spent + price <= cap;
            vm.prank(alice);
            try core.sellForEth(_one(ids[i])) {
                assertTrue(fits, "passed above the cap");
                spent += price;
            } catch (bytes memory why) {
                assertEq(bytes4(why), Core.HourlyCap.selector);
                assertFalse(fits, "blocked below the cap");
                sawBlock = true;
                break;
            }
        }
        assertTrue(sawBlock, "cap was reached");
        assertLe(spent, cap);

        // one second short of the hour is still blocked. the window opened at the first sale, which was now.
        uint256 gap = bound(gapSeed, 0, 1 hours - 1);
        _warp(gap);
        vm.prank(alice);
        vm.expectRevert(Core.HourlyCap.selector);
        core.sellForEth(_one(ids[i]));
        _warp(1 hours - gap);
        // a new window opens against the smaller pot. the same credit now passes if it fits 20 percent of that pot.
        uint256 price2 = core.ceilingOf(ids[i]);
        bool fits2 = price2 <= core.ethPot() * 2000 / 10_000;
        vm.prank(alice);
        try core.sellForEth(_one(ids[i])) {
            assertTrue(fits2);
        } catch (bytes memory why) {
            assertEq(bytes4(why), Core.HourlyCap.selector);
            assertFalse(fits2);
        }
    }

    /// documents behaviour worth a design look: the funded clamp lets the rate climb to the level where one average
    /// credit costs the whole pot, but the hourly cap allows only a fifth of the pot an hour. an average credit then
    /// cannot be bought at all, so the rate never drops and stays pinned. only credits scoring under a fifth of
    /// the average can still be sold, and each of those drops the rate a little.
    /// forge-config: default.fuzz.runs = 20
    function testFuzz_documented_clampOutrunsHourlyCap(uint256 potSeed, uint256 waitSeed) public {
        uint256 pot = bound(potSeed, 0.01 ether, 100 ether);
        _fund(pot);
        _warp(bound(waitSeed, 2000, 20_000) * 1 hours);
        uint256 cap = pot * 1e4 / AVG;
        assertEq(core.ethRate(), cap, "pinned at the funded clamp");
        assertTrue(core.funded());
        // an average credit costs the whole pot (up to rounding), five times what an hour allows
        uint256 avgPrice = AVG * cap / 1e4;
        assertGe(avgPrice * 1e4, pot * 9_999);
        assertGt(avgPrice, pot * 2000 / 10_000);

        uint256[] memory ids = _creditsTo(alice, 12);
        uint256 blocked;
        for (uint256 i; i < ids.length; ++i) {
            uint256 price = core.ceilingOf(ids[i]);
            uint256 rateBefore = core.rateAtCheckpoint();
            vm.prank(alice);
            try core.sellForEth(_one(ids[i])) {
                assertLe(price, pot * 2000 / 10_000);
            } catch (bytes memory why) {
                // above the whole pot it is PotTooSmall, otherwise the cap
                assertEq(bytes4(why), price > pot ? Core.PotTooSmall.selector : Core.HourlyCap.selector);
                assertEq(core.rateAtCheckpoint(), rateBefore, "a blocked sell leaves the rate alone");
                ++blocked;
            }
        }
        // no assertion on how many were blocked: it depends on the scores of the credits picked
        emit log_named_uint("blocked of 12", blocked);
    }

    /// documents deviation 4: the window is fixed, not rolling, so just across a boundary the core can spend about
    /// 20 percent of the pot at the end of one window and about 20 percent of what is left at the start of the next.
    /// forge-config: default.fuzz.runs = 12
    function testFuzz_documented_windowBoundaryAllowsTwoCaps(uint256 potSeed) public {
        uint256 pot = bound(potSeed, 0.03 ether, 0.06 ether);
        _fund(pot);
        uint256[] memory ids = _creditsTo(alice, 60);
        uint256 cap0 = pot * 2000 / 10_000;
        uint256 i;
        uint256 spent1;
        // the first sale opens the window
        vm.prank(alice);
        core.sellForEth(_one(ids[i]));
        _warp(1 hours - 2);
        uint256 potMid = core.ethPot();
        for (++i; i < ids.length; ++i) {
            vm.prank(alice);
            try core.sellForEth(_one(ids[i])) {}
            catch {
                break;
            }
        }
        spent1 = pot - core.ethPot();
        assertLe(spent1, cap0);
        assertLt(potMid, pot);
        // three seconds later the window has rolled over and a fresh cap applies to the smaller pot
        _warp(3);
        uint256 potOpen = core.ethPot();
        for (; i < ids.length; ++i) {
            vm.prank(alice);
            try core.sellForEth(_one(ids[i])) {}
            catch {
                break;
            }
        }
        uint256 spent2 = potOpen - core.ethPot();
        assertLe(spent2, potOpen * 2000 / 10_000);
        assertLt(i, ids.length, "ids ran out before the cap");
        assertGt(spent1 + spent2, cap0, "more than one hourly cap spent across a boundary");
        assertLe(spent1 + spent2, cap0 + potOpen * 2000 / 10_000);
    }
}
