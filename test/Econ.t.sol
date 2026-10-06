// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {Lane, Settings} from "../src/interfaces/Interfaces.sol";

/// @notice the economic dials of the eth bid that act on fills: the rate drop and the hourly spend cap. their bounds
/// are in Flow.t.sol (every setting at both edges). here is what each dial does at its edges and at the launch value,
/// on the real stack, with exact numbers. the inventory gate, the auction multiples and the constructor bounds of the
/// old `Econ` are gone with the dutch statement auction (the reserve and the listing are in Flow.t.sol)
contract EconDialsTest is Fixture {
    function _dial(uint256 dropBps, uint256 flatBps) internal {
        Settings memory s = core.settings();
        // forge-lint: disable-start(unsafe-typecast)
        s.dropBps = uint16(dropBps);
        s.flatBps = uint16(flatBps);
        // forge-lint: disable-end(unsafe-typecast)
        _setSettings(s);
    }

    /// repeated fills in one block follow the formula exactly, round the drop down, and the rate stays positive
    function _manyFills(uint256 dropBps, uint256 flatBps) internal {
        _dial(dropBps, flatBps);
        _skipSniperWindow();
        _fundPot(0.4 ether);
        uint256 r = core.ethRate();
        uint256 p = core.ethPot();
        uint256[] memory ids = _credits(seller, 40);
        uint256 p0 = p;
        for (uint256 i; i < ids.length; ++i) {
            uint256 x = core.ceilingOf(ids[i]);
            uint256 want = r - r * dropBps * x / (10_000 * p);
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
            assertEq(core.rateAtCheckpoint(), want, "drop formula, rounded down");
            r = want;
            p -= x;
            assertEq(core.ethPot(), p);
        }
        assertGt(r, 0);
        emit log_named_uint("share of the pot spent, bps", (p0 - p) * 10_000 / p0);
        emit log_named_uint("rate left, wei per point", r);
        _solvent();
    }

    function test_drop_launchValueFlat() public {
        assertEq(core.settings().dropBps, 2_000);
        _manyFills(2_000, 10_000);
    }

    function test_drop_launchValuePerPoint() public {
        _manyFills(2_000, 0);
    }

    function test_drop_atTheSmallestBound() public {
        _manyFills(500, 10_000);
    }

    function test_drop_justAboveTheSmallestBound() public {
        _manyFills(501, 10_000);
    }

    function test_drop_atTheLargestBound() public {
        _manyFills(5_000, 10_000);
        assertGt(core.rateAtCheckpoint(), 0);
    }

    /// one fill of x from a pot of p drops the rate by rate * 20 percent * x / p at the launch value, and a larger
    /// drop at a larger dial, with the exact launch number for a flat credit
    function test_drop_oneFillExactAtLaunchAndLarger() public {
        _fundPot(3 ether);
        uint256[] memory ids = _credits(seller, 2);
        uint256 r0 = core.ethRate();
        uint256 x = core.ceilingOf(ids[0]);
        assertEq(x, 4_330_000 * r0 / 1e4, "the flat price at the launch settings");
        uint256 p = core.ethPot();
        uint256 snap = vm.snapshotState();
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        uint256 launchRate = core.ethRate();
        assertEq(launchRate, r0 - r0 * 2_000 * x / (10_000 * p));
        vm.revertToState(snap);
        _dial(5_000, 10_000);
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        assertEq(core.ethRate(), r0 - r0 * 5_000 * x / (10_000 * p));
        assertLt(core.ethRate(), launchRate, "a bigger drop at a bigger dial");
    }

    /// sells at the clamp of the hourly cap and counts what one window admits
    function _window(uint256 capBps, uint256 pot) internal returns (uint256 sold, uint256 spent) {
        Settings memory s = core.settings();
        // forge-lint: disable-next-line(unsafe-typecast)
        s.spendCapBps = uint16(capBps);
        _setSettings(s);
        vm.deal(address(core), pot);
        core.skim();
        assertTrue(core.funded());
        uint256[] memory ids = _credits(seller, 12);
        for (uint256 i; i < ids.length; ++i) {
            uint256 x = core.ceilingOf(ids[i]);
            uint256 before = seller.balance;
            vm.prank(seller);
            try core.sellForEth(_one(ids[i])) {
                spent += seller.balance - before;
                assertEq(seller.balance - before, x);
                ++sold;
            } catch (bytes memory why) {
                bytes4 sel = bytes4(why);
                assertTrue(sel == Core.HourlyCap.selector || sel == Core.PotTooSmall.selector, "only the caps refuse");
                break;
            }
        }
    }

    /// at the smallest cap (1 percent of the pot an hour) a pot of 100 average credits admits one in the window
    function test_spendCap_atTheSmallestBound() public {
        (uint256 sold, uint256 spent) = _window(100, 0.2 ether);
        assertEq(sold, 1);
        assertLe(spent, 0.2 ether / 100);
    }

    /// at the largest cap (half of the pot) the window can spend nearly half of it, and no more than half
    function test_spendCap_atTheLargestBound() public {
        (uint256 sold, uint256 spent) = _window(5_000, 0.02 ether);
        assertGe(sold, 4);
        assertGt(spent, 0.02 ether * 4 / 10, "most of the half pot in one window");
        assertLe(spent, 0.02 ether / 2);
        _solvent();
    }
}
