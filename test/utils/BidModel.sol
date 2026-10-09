// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Settings} from "../../src/interfaces/Interfaces.sol";

/// @notice the credit bid rule restated in the tests, from the settings. the invariant handlers and the fuzz and model
/// suites (`HandlerBase`, `RateFuzz`, `ReviewEcon`, `Econ`, `CoreUnit`, `Lifecycle`, `Seaport`) use it as their model:
/// the drop per credit with the minute floor, the compounded climb per minute, the clamp and the ceiling with the
/// idle loosening of its anchor. the clamp lowers the read, the price state is stored. `BidRule.t.sol` asserts hand
/// arithmetic and does not use it
library BidModel {
    /// @dev the price state at the first fill of the minute after a fill at `fillState`: `minuteStart`, or `fillState` when
    /// it is below the floor of `minuteStart`
    function startAfter(Settings memory s, uint256 fillState, uint256 minuteStart) internal pure returns (uint256) {
        return fillState < minuteStart * s.dropFloorBps / 10_000 ? fillState : minuteStart;
    }

    /// @dev the rate after one credit bought with the price state `fillState`, where `minuteStart` is the price state at
    /// the first fill of the same minute bucket
    function dropOnce(Settings memory s, uint256 fillState, uint256 minuteStart) internal pure returns (uint256) {
        minuteStart = startAfter(s, fillState, minuteStart);
        return
            FixedPointMathLib.max(fillState * (10_000 - s.dropPerCreditBps) / 10_000, minuteStart * s.dropFloorBps / 10_000);
    }

    /// @dev the clamp: the price of one average credit that the hourly share of a pot affords, at most `rateCap`
    function clamp(Settings memory s, uint256 pot) internal pure returns (uint256) {
        return FixedPointMathLib.min(pot * s.spendCapBps / uint256(s.avgScore), s.rateCap);
    }

    /// @dev the ceiling: `ceilBps` of the anchor grown by `idleLoosenBps` per full 10 minutes idle
    function ceiling(Settings memory s, uint256 anchor, uint256 idle) internal pure returns (uint256) {
        return anchor * (10_000 + uint256(s.idleLoosenBps) * (idle / 10 minutes)) * s.ceilBps / 1e8;
    }

    /// @dev the price state after `dt` seconds from the stored rate `r`: at most `rateCap` and the ceiling,
    /// compounding `climbPerMinBps` a minute up to the clamp (a price state above the clamp holds)
    function price(Settings memory s, uint256 r, uint256 pot, uint256 anchor, uint256 idle, uint256 dt)
        internal
        pure
        returns (uint256)
    {
        uint256 cap = FixedPointMathLib.min(ceiling(s, anchor, idle), s.rateCap);
        if (r >= cap) return cap;
        uint256 target = FixedPointMathLib.min(cap, clamp(s, pot));
        if (dt == 0 || r == 0 || r >= target) return r;
        // forge-lint: disable-start(unsafe-typecast)
        int256 x =
            FixedPointMathLib.lnWad(int256(1e18 + uint256(s.climbPerMinBps) * 1e14)) * int256(dt * 1e18 / 60) / 1e18;
        // growing past the target: the target decides, and the exponential cannot overflow
        if (x >= FixedPointMathLib.lnWad(int256(target * 1e18 / r))) return target;
        return FixedPointMathLib.min(FixedPointMathLib.mulWad(r, uint256(FixedPointMathLib.expWad(x))), target);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev the read for the price state `p`: lowered to the clamp
    function read(Settings memory s, uint256 pot, uint256 p) internal pure returns (uint256) {
        return FixedPointMathLib.min(p, clamp(s, pot));
    }
}
