// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane, Settings} from "../src/interfaces/Interfaces.sol";
import {BidModel} from "./utils/BidModel.sol";

/// @notice the economic dials of the eth bid that act on fills: the rate drop per credit with its minute floor, and the hourly spend cap. their bounds
/// are in Flow.t.sol (every setting at both edges). here is what each dial does at its edges and at the launch value,
/// on the real stack, with exact numbers. the inventory gate, the auction multiples and the constructor bounds of the
/// old `Econ` are gone with the dutch statement auction (the reserve and the listing are in Flow.t.sol)
contract EconDialsTest is Fixture {
    function _dial(uint256 dropPerCreditBps, uint256 dropFloorBps, uint256 flatBps) internal {
        Settings memory s = core.settings();
        // forge-lint: disable-start(unsafe-typecast)
        s.dropPerCreditBps = uint16(dropPerCreditBps);
        s.dropFloorBps = uint16(dropFloorBps);
        s.flatBps = uint16(flatBps);
        // forge-lint: disable-end(unsafe-typecast)
        _setSettings(s);
    }

    /// repeated fills in one block follow the formula exactly: each credit drops the rate by `dropPerCreditBps` rounded
    /// down, no lower than `dropFloorBps` of the rate at the first fill, and the rate stays positive
    function _manyFills(uint256 dropPerCreditBps, uint256 dropFloorBps, uint256 flatBps) internal {
        _dial(dropPerCreditBps, dropFloorBps, flatBps);
        _skipSniperWindow();
        _fundPot(0.4 ether);
        Settings memory s = core.settings();
        uint256 r = core.ethRate();
        uint256 start = r;
        uint256 p = core.ethPot();
        uint256[] memory ids = _credits(seller, 40);
        for (uint256 i; i < ids.length; ++i) {
            uint256 x = core.ceilingOf(ids[i]);
            uint256 want = BidModel.dropOnce(s, r, start);
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
            assertEq(core.rateAtCheckpoint(), want, "drop formula, rounded down");
            (uint256 last,,) = _anchor();
            assertEq(last, r, "the anchor is the rate paid");
            r = want;
            p -= x;
            assertEq(core.ethPot(), p);
        }
        assertGt(r, 0);
        assertGe(r, start * dropFloorBps / 10_000, "never below the minute floor");
        emit log_named_uint("rate left, bps of the first rate", r * 10_000 / start);
        _solvent();
    }

    function test_drop_launchValueFlat() public {
        assertEq(core.settings().dropPerCreditBps, 50);
        assertEq(core.settings().dropFloorBps, 8_000);
        _manyFills(50, 8_000, 10_000);
    }

    function test_drop_launchValuePerPoint() public {
        _manyFills(50, 8_000, 0);
    }

    function test_drop_atTheSmallestBound() public {
        _manyFills(1, 8_000, 10_000);
    }

    function test_drop_atTheLargestBoundHitsTheFloor() public {
        _manyFills(1_000, 8_000, 10_000);
        assertEq(
            core.rateAtCheckpoint(), _anchorMinuteStart() * 8_000 / 10_000, "40 credits at 10 percent sit on the floor"
        );
    }

    function test_drop_floorAtTheLowestBound() public {
        _manyFills(1_000, 5_000, 10_000);
        assertEq(core.rateAtCheckpoint(), _anchorMinuteStart() * 5_000 / 10_000);
    }

    function test_drop_floorAtTheHighestBoundHoldsTheRate() public {
        uint256 r0 = core.rateAtCheckpoint();
        _manyFills(500, 10_000, 10_000);
        assertEq(core.rateAtCheckpoint(), _anchorMinuteStart(), "a floor of 100 percent never lets the rate fall");
        assertGe(core.rateAtCheckpoint(), r0 - 1);
    }

    function _anchorMinuteStart() internal view returns (uint256 start) {
        (, start,) = _anchor();
    }

    /// one fill drops the rate by 0.5 percent at the launch value, and a larger dial drops more, with the exact launch
    /// number for a flat credit
    function test_drop_oneFillExactAtLaunchAndLarger() public {
        _fundPot(3 ether);
        uint256[] memory ids = _credits(seller, 2);
        uint256 r0 = core.ethRate();
        uint256 x = core.ceilingOf(ids[0]);
        assertEq(x, 4_330_000 * r0 / 1e4, "the flat price at the launch settings");
        uint256 snap = vm.snapshotState();
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        uint256 launchRate = core.ethRate();
        assertEq(launchRate, r0 * 9_950 / 10_000);
        vm.revertToState(snap);
        _dial(1_000, 8_000, 10_000);
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        assertEq(core.ethRate(), r0 * 9_000 / 10_000);
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
                assertTrue(sel == ICore.HourlyCap.selector || sel == ICore.PotTooSmall.selector, "only the caps refuse");
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
