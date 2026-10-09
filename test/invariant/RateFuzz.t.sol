// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../../src/interfaces/ICore.sol";
import {Settings, RATE_START_MAX_WEI} from "../../src/interfaces/Interfaces.sol";
import {Fixture} from "../utils/Fixture.sol";
import {BidModel} from "../utils/BidModel.sol";

/// @notice plain fuzz tests for the eth rate and the hourly cap (SPEC 5.1 and 5.2) with fuzzed times, amounts and
/// fuzzed settings: the climb per minute, the ceiling and its loosening, the funded clamp, the drop per credit, the spend
/// cap, the average score and the flat share are all fields of `Settings` that the owner may set, so the model is
/// parameterised by them. the climb is an independent whole minute integer walk, so it shares no code with the core's
/// wad pow. the pot is funded to an exact size by sending eth to the core and calling its real `skim()`, which is how
/// the core books any eth that did not arrive through the hook. credits are real ones, the settings are changed by the
/// real owner call.
contract RateFuzzTest is Fixture {
    /// @dev the seller of the credits, named as in the old unit tests
    address internal alice;

    uint256 internal constant START = 4e12;

    function setUp() public override {
        super.setUp();
        alice = seller;
    }

    /// @dev grows the pot by exactly `eth`: the eth is sent to the core and booked by the real `skim()`
    function _fund(uint256 eth) internal {
        uint256 pot = core.ethPot();
        vm.deal(address(core), pot + core.ethToBuyback() + eth);
        core.skim();
        assertEq(core.ethPot(), pot + eth, "pot grew by the funded amount");
    }

    /// @dev the least pot that is funded at the opening rate: the hourly cap must afford one average credit
    function _minPot(Settings memory s, uint256 rate) internal pure returns (uint256) {
        return (uint256(s.avgScore) * rate + s.spendCapBps - 1) / s.spendCapBps;
    }

    /// @dev the limit of the climb at `idle` seconds since the last fill, whose rate was `anchor`: the lowest of the funded
    /// clamp, `rateCap` and the loosened ceiling
    function _limitOf(Settings memory s, uint256 pot, uint256 anchor, uint256 idle) internal pure returns (uint256) {
        uint256 c = BidModel.clamp(s, pot);
        uint256 ceil = BidModel.ceiling(s, anchor, idle);
        return c < ceil ? c : ceil;
    }

    /// the rate after `mins` whole minutes of climbing from `r` at `climbBps` a minute, stopped at `limit`. a rate at or
    /// above the limit is the limit
    function _model(uint256 r, uint256 mins, uint256 limit, uint256 climbBps) internal pure returns (uint256) {
        if (limit <= r) return limit;
        for (uint256 j; j < mins; ++j) {
            r = r * (10_000 + climbBps) / 10_000;
            if (r >= limit) return limit;
        }
        return r;
    }

    /// the rate of the last of `n` credits bought from rate `r` in one minute, and the rate after them
    function _afterFills(Settings memory s, uint256 r, uint256 n) internal pure returns (uint256 last, uint256 next) {
        next = r;
        for (uint256 i; i < n; ++i) {
            last = next;
            next = BidModel.dropOnce(s, next, r);
        }
    }

    /// the price the core pays for a credit of `score` at `rate`, written out from docs/FLOW.md (no controller bonus)
    function _price(uint256 score, uint256 rate, Settings memory s) internal pure returns (uint256) {
        uint256 blend = uint256(s.flatBps) * s.avgScore + (10_000 - uint256(s.flatBps)) * score;
        return blend * rate * 10_000 / (10_000 * 10_000 * 1e4);
    }

    /// the refusal of a sale at `price`: the pot is checked before the hourly cap, so a sale the pot cannot pay is
    /// PotTooSmall even when the cap would refuse it too
    function _refusal(uint256 price) internal view returns (bytes4) {
        return price > core.ethPot() ? ICore.PotTooSmall.selector : ICore.HourlyCap.selector;
    }

    function _r(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// settings with a random climb, ceiling, clamp, cap, average score and flat share, the other fields at the launch
    /// values. `calm` keeps the climb, the ceiling and the clamp at the launch values
    function _randomSettings(uint256 seed, bool calm) internal view returns (Settings memory s) {
        s = core.settings();
        // forge-lint: disable-start(unsafe-typecast)
        s.avgScore = uint32(bound(_r(seed, 0), 800_000, 6_000_000));
        s.spendCapBps = uint16(bound(_r(seed, 1), 100, 5_000));
        s.flatBps = uint16(bound(_r(seed, 2), 0, 10_000));
        s.dropPerCreditBps = uint16(bound(_r(seed, 3), 1, 1_000));
        s.dropFloorBps = uint16(bound(_r(seed, 11), 5_000, 10_000));
        s.rateCap = uint64(RATE_START_MAX_WEI);
        if (!calm) {
            s.climbPerMinBps = uint16(bound(_r(seed, 4), 1, 1_000));
            s.ceilBps = uint16(bound(_r(seed, 5), 10_000, 30_000));
            s.idleLoosenBps = uint16(bound(_r(seed, 6), 0, 2_000));
            s.clampCredits = uint16(bound(_r(seed, 7), 1, 1_000));
        }
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// the climb while unfilled: funded from the start, whole minutes of waiting, under random climb, ceiling, clamp, cap
    /// and average score.
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_climbCompoundsPerMinute(uint256 seed, uint256 potSeed, uint256 waitSeed) public {
        Settings memory s = _randomSettings(seed, false);
        _setSettings(s);
        uint256 min = _minPot(s, START);
        uint256 pot = bound(potSeed, min, min + 1000 ether);
        uint256 mins = bound(waitSeed, 0, 240);
        _fund(pot);
        assertTrue(core.funded());
        _warp(mins * 1 minutes);
        uint256 limit = _limitOf(s, pot, START, block.timestamp - core.lastFillTime());
        uint256 want = _model(START, mins, limit, s.climbPerMinBps);
        assertApproxEqRel(core.ethRate(), want, 1e-7 ether, "compounded per minute, limited");
        assertLe(core.ethRate(), limit, "never above the limit");
    }

    /// no climb while the pot cannot afford one average credit at the hourly cap, and no retroactive climb once it can,
    /// whatever the settings. the idle time counts toward the ceiling anchor only.
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_pauseWhenUnfunded(uint256 seed, uint256 potSeed, uint256 idleSeed, uint256 topSeed, uint256 wait)
        public
    {
        Settings memory s = _randomSettings(seed, false);
        _setSettings(s);
        uint256 min = _minPot(s, START);
        uint256 pot = bound(potSeed, 0, min - 1);
        uint256 idle = bound(idleSeed, 0, 3000);
        if (pot != 0) _fund(pot);
        assertFalse(core.funded());
        _warp(idle * 1 hours);
        assertEq(core.ethRate(), START, "frozen while unfunded");

        uint256 top = bound(topSeed, min - pot, min - pot + 100 ether);
        _fund(top);
        assertTrue(core.funded());
        uint256 limit0 = _limitOf(s, pot + top, START, block.timestamp - core.lastFillTime());
        assertEq(core.ethRate(), limit0 < START ? limit0 : START, "no retroactive climb, bounded by the limit");
        uint256 start = core.rateAtCheckpoint();

        uint256 mins = bound(wait, 0, 240);
        _warp(mins * 1 minutes);
        uint256 limit = _limitOf(s, pot + top, START, block.timestamp - core.lastFillTime());
        assertApproxEqRel(core.ethRate(), _model(start, mins, limit, s.climbPerMinBps), 1e-7 ether);
    }

    /// a settings call keeps the stored rate exactly, even when it flips the funded flag, and the climb after it follows
    /// the new settings from the change on. no climb is credited under the wrong numbers.
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_settingsChangeKeepsTheRateAndClimbsOnTheNewNumbers(
        uint256 seedA,
        uint256 seedB,
        uint256 potSeed,
        uint256 m1,
        uint256 m2
    ) public {
        Settings memory a = _randomSettings(seedA, false);
        _setSettings(a);
        uint256 pot = bound(potSeed, _minPot(a, START), _minPot(a, START) + 500 ether);
        _fund(pot);
        m1 = bound(m1, 0, 240);
        _warp(m1 * 1 minutes);
        uint256 r1 = core.ethRate();
        uint256 limit1 = _limitOf(a, pot, START, block.timestamp - core.lastFillTime());
        assertApproxEqRel(r1, _model(START, m1, limit1, a.climbPerMinBps), 1e-7 ether);
        Settings memory b = _randomSettings(seedB, false);
        _setSettings(b);
        bool fundedNow = pot * b.spendCapBps >= uint256(b.avgScore) * r1;
        uint256 limitB = _limitOf(b, pot, START, block.timestamp - core.lastFillTime());
        assertEq(
            core.ethRate(),
            fundedNow && limitB < r1 ? limitB : r1,
            "the read is the rate it found, bounded by the new limit"
        );
        assertEq(core.rateAtCheckpoint(), r1, "and stores it");
        assertEq(core.funded(), fundedNow, "the funded flag follows the new numbers");
        m2 = bound(m2, 0, 240);
        _warp(m2 * 1 minutes);
        uint256 limit2 = _limitOf(b, pot, START, block.timestamp - core.lastFillTime());
        uint256 want = fundedNow ? _model(r1, m2, limit2, b.climbPerMinBps) : r1;
        assertApproxEqRel(core.ethRate(), want, 1e-7 ether, "climbing on the new settings");
    }

    /// a fill drops the rate by `dropPerCreditBps` per credit, no lower than `dropFloorBps` of the rate at the first
    /// fill of the minute, and makes the rate paid the ceiling anchor. the price is the blend of the flat share and the
    /// score share. the climb, the ceiling and the clamp stay at the launch values and the pot is large, so the hourly
    /// cap never binds
    /// forge-config: default.fuzz.runs = 30
    function testFuzz_fillDropsPerCreditAndSetsTheAnchor(uint256 seed, uint256 potSeed, uint256 waitSeed, uint256 count)
        public
    {
        Settings memory s = _randomSettings(seed, true);
        s.spendCapBps = uint16(bound(_r(seed, 9), 2_000, 5_000));
        _setSettings(s);
        uint256 pot = bound(potSeed, 20 ether, 1000 ether);
        uint256 mins = bound(waitSeed, 0, 240);
        uint256 n = bound(count, 1, 3);
        _fund(pot);
        _warp(mins * 1 minutes);
        uint256[] memory ids = _credits(alice, n);
        uint256 r = core.ethRate();
        uint256 limit = _limitOf(s, pot, START, block.timestamp - core.lastFillTime());
        assertApproxEqRel(r, _model(START, mins, limit, s.climbPerMinBps), 1e-7 ether);
        uint256 paid;
        uint256 rn = r;
        for (uint256 i; i < n; ++i) {
            paid += _price(core.scoreOf(ids[i]), rn, s);
            rn = BidModel.dropOnce(s, rn, r);
        }
        uint256 before = alice.balance;
        vm.prank(alice);
        core.sellForEth(ids);
        assertEq(alice.balance - before, paid);
        assertEq(core.rateAtCheckpoint(), rn, "dropped per credit, no lower than the minute floor");
        assertEq(core.ethPot(), pot - paid);
        assertEq(core.lastFillTime(), block.timestamp);
        (uint256 last,) = _afterFills(s, r, n);
        uint256 anchor;
        {
            uint256 minuteStart;
            (anchor, minuteStart,) = _anchor();
            assertEq(anchor, last, "the rate paid at the last fill is the anchor");
            assertEq(minuteStart, r, "the minute started at the first rate paid");
        }
        _climbAfterFill(s, rn, anchor);
    }

    /// the anchor restarted: ten minutes later the climb is the base, unless the rate sits at its limit
    function _climbAfterFill(Settings memory s, uint256 rn, uint256 anchor) internal {
        _warp(10 minutes);
        if (core.funded()) {
            uint256 limit = _limitOf(s, core.ethPot(), anchor, 10 minutes);
            assertApproxEqRel(core.ethRate(), _model(rn, 10, limit, s.climbPerMinBps), 1e-7 ether);
        } else {
            assertEq(core.ethRate(), rn, "unfunded after the fill: no climb");
        }
    }

    /// the hourly cap, with a random spend cap: an exact prediction of which sells pass, and the window reopens an hour
    /// after it opened. a cap of 100 percent is bounded by the pot instead (PotTooSmall comes first).
    /// forge-config: default.fuzz.runs = 20
    function testFuzz_hourlyCap(uint256 capSeed, uint256 potSeed, uint256 gapSeed) public {
        Settings memory s = core.settings();
        // forge-lint: disable-next-line(unsafe-typecast)
        s.spendCapBps = uint16(bound(capSeed, 100, 5_000));
        _setSettings(s);
        uint256 pot = bound(potSeed, 0.03 ether, 0.05 ether);
        _fund(pot);
        uint256[] memory ids = _credits(alice, 60);
        uint256 cap = pot * s.spendCapBps / 10_000;
        uint256 spent;
        uint256 i;
        bool sawBlock;
        for (; i < ids.length; ++i) {
            uint256 price = core.ceilingOf(ids[i]);
            bool fits = spent + price <= cap;
            bytes4 refusal = _refusal(price);
            vm.prank(alice);
            try core.sellForEth(_one(ids[i])) {
                assertTrue(fits, "passed above the cap");
                spent += price;
            } catch (bytes memory why) {
                assertEq(bytes4(why), refusal);
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
        bytes4 refusal1 = _refusal(core.ceilingOf(ids[i]));
        vm.prank(alice);
        vm.expectRevert(refusal1);
        core.sellForEth(_one(ids[i]));
        _warp(1 hours - gap);
        // a new window opens against the smaller pot. the same credit now passes if it fits that pot's cap.
        uint256 price2 = core.ceilingOf(ids[i]);
        bool fits2 = price2 <= core.ethPot() * s.spendCapBps / 10_000;
        bytes4 refusal2 = _refusal(price2);
        vm.prank(alice);
        try core.sellForEth(_one(ids[i])) {
            assertTrue(fits2);
        } catch (bytes memory why) {
            assertEq(bytes4(why), refusal2);
            assertFalse(fits2);
        }
    }

    /// a change of the spend cap inside an open window: the core compares the window's spend with the pot the window
    /// opened with times the cap in force at each spend. raised, the same window may spend past the cap it opened under.
    /// lowered, what was spent stays and nothing more passes until the window rolls. the prediction is exact.
    /// forge-config: default.fuzz.runs = 30
    function testFuzz_capChangeInsideAWindow(uint256 capA, uint256 capB, uint256 potSeed) public {
        Settings memory s = core.settings();
        // forge-lint: disable-start(unsafe-typecast)
        s.spendCapBps = uint16(bound(capA, 500, 5_000));
        _setSettings(s);
        uint256 pot = bound(potSeed, 0.5 ether, 2 ether);
        _fund(pot);
        uint256[] memory ids = _credits(alice, 60);
        // the first sale opens the window with the whole pot as its base
        vm.prank(alice);
        core.sellForEth(_one(ids[0]));
        uint256 windowPot = pot;
        uint256 spent = pot - core.ethPot();
        uint256 spent0 = spent;
        s.spendCapBps = uint16(bound(capB, 500, 5_000));
        // forge-lint: disable-end(unsafe-typecast)
        _setSettings(s);
        uint256 capNow = windowPot * s.spendCapBps / 10_000;
        for (uint256 i = 1; i < ids.length; ++i) {
            uint256 price = core.ceilingOf(ids[i]);
            bool fits = spent + price <= capNow && price <= core.ethPot();
            vm.prank(alice);
            try core.sellForEth(_one(ids[i])) {
                assertTrue(fits, "passed above the cap in force");
                spent += price;
            } catch (bytes memory why) {
                assertEq(bytes4(why), ICore.HourlyCap.selector);
                assertFalse(fits, "blocked below the cap in force");
                break;
            }
        }
        assertLe(spent, capNow > spent0 ? capNow : spent0, "no spend past the cap in force at the last spend");
        // raised: the window went past the cap it opened under. lowered: spending beyond the new cap was already done
        emit log_named_uint("spent over the opening cap of the window", spent * 10_000 / windowPot);
    }

    /// the funded clamp keeps an average credit sellable: at the clamp the hourly cap buys one average credit, so in a
    /// fresh window every credit priced at most the average sells in the same block, and one that costs more than the
    /// hourly cap is refused by it. under a random cap, average score and flat share.
    /// forge-config: default.fuzz.runs = 20
    function testFuzz_clampKeepsAnAverageCreditSellable(uint256 seed, uint256 potSeed, uint256 waitSeed) public {
        Settings memory s = _randomSettings(seed, true);
        s.clampCredits = 1;
        _setSettings(s);
        uint256 min = _minPot(s, START);
        // the funded clamp must sit below the rate cap, or the cap is what pins the rate (tested on its own)
        uint256 top = uint256(s.rateCap) * s.avgScore / s.spendCapBps;
        uint256 pot = bound(potSeed, min, min + 100 ether > top ? top : min + 100 ether);
        _fund(pot);
        _warp(bound(waitSeed, 3000, 20_000) * 1 hours);
        uint256 cap = BidModel.clamp(s, pot);
        assertEq(core.ethRate(), cap, "pinned at the funded clamp");
        assertTrue(core.funded());
        // one average credit costs what the hourly cap allows, up to rounding down of the rate
        uint256 avgPrice = uint256(s.avgScore) * cap / 1e4;
        assertLe(avgPrice, pot * s.spendCapBps / 10_000);
        assertGe(avgPrice * 1e4 + s.avgScore + 1e4, pot * s.spendCapBps);

        uint256[] memory ids = _credits(alice, 12);
        uint256 sold;
        for (uint256 i; i < ids.length; ++i) {
            uint256 price = core.ceilingOf(ids[i]);
            bytes4 refusal = _refusal(price);
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            try core.sellForEth(_one(ids[i])) {
                assertLe(price, pot * s.spendCapBps / 10_000);
                ++sold;
            } catch (bytes memory why) {
                assertGt(core.scoreOf(ids[i]), s.avgScore, "an average or smaller credit was refused at the clamp");
                assertEq(bytes4(why), refusal);
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("sold at the clamp of 12", sold);
    }

    /// documents deviation 4: the window is fixed, not rolling, so just across a boundary the core can spend about
    /// one cap at the end of one window and about one cap of what is left at the start of the next.
    /// forge-config: default.fuzz.runs = 12
    function testFuzz_documented_windowBoundaryAllowsTwoCaps(uint256 potSeed) public {
        uint256 pot = bound(potSeed, 0.03 ether, 0.06 ether);
        _fund(pot);
        uint256[] memory ids = _credits(alice, 60);
        uint256 cap0 = pot * 2000 / 10_000;
        uint256 i;
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
        uint256 spent1 = pot - core.ethPot();
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
