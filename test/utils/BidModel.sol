// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Settings} from "../../src/interfaces/Interfaces.sol";

/// @notice the credit bid rule restated in the tests, from the settings. the invariant handlers and the fuzz and model
/// suites (`HandlerBase`, `RateFuzz`, `ReviewEcon`, `Econ`, `CoreUnit`, `Lifecycle`, `Seaport`) use it as their model:
/// the drop per credit with the minute floor, the compounded climb per minute, the funded clamp and the ceiling with the
/// idle loosening of its anchor. `BidRule.t.sol` asserts hand arithmetic and does not use it
library BidModel {
    /// @dev the rate after one credit bought at `paid`, where `minuteStart` is the rate paid at the first fill of the
    /// same minute bucket
    function dropOnce(Settings memory s, uint256 paid, uint256 minuteStart) internal pure returns (uint256) {
        uint256 lowest = FixedPointMathLib.min(minuteStart * s.dropFloorBps / 10_000, paid);
        return FixedPointMathLib.max(paid * (10_000 - s.dropPerCreditBps) / 10_000, lowest);
    }

    /// @dev the funded clamp: the hourly cap of a pot over `clampCredits` average credits, at most `rateCap`
    function clamp(Settings memory s, uint256 pot) internal pure returns (uint256) {
        return FixedPointMathLib.min(pot * s.spendCapBps / (uint256(s.avgScore) * s.clampCredits), s.rateCap);
    }

    /// @dev the ceiling: `ceilBps` of the anchor grown by `idleLoosenBps` per full 10 minutes idle
    function ceiling(Settings memory s, uint256 anchor, uint256 idle) internal pure returns (uint256) {
        return anchor * (10_000 + uint256(s.idleLoosenBps) * (idle / 10 minutes)) * s.ceilBps / 1e8;
    }

    /// @dev the rate after `dt` seconds of climbing from `r`: `climbPerMinBps` a minute compounded, stopped at the lowest
    /// of the clamp and the ceiling, which also bounds a rate that starts above it
    function climb(Settings memory s, uint256 r, uint256 pot, uint256 anchor, uint256 idle, uint256 dt)
        internal
        pure
        returns (uint256)
    {
        uint256 limit = FixedPointMathLib.min(clamp(s, pot), ceiling(s, anchor, idle));
        if (r >= limit) return limit;
        // forge-lint: disable-start(unsafe-typecast)
        int256 x =
            FixedPointMathLib.lnWad(int256(1e18 + uint256(s.climbPerMinBps) * 1e14)) * int256(dt * 1e18 / 60) / 1e18;
        // growing past the limit: the limit decides, and the exponential cannot overflow
        if (x >= FixedPointMathLib.lnWad(int256(limit * 1e18 / r))) return limit;
        return FixedPointMathLib.min(FixedPointMathLib.mulWad(r, uint256(FixedPointMathLib.expWad(x))), limit);
        // forge-lint: disable-end(unsafe-typecast)
    }
}
