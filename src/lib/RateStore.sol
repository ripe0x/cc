// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// where the bid anchor state lives: three packed words from a fixed storage slot of the Core, shared by the Core and
/// the linked library, so the library can update it on a fill
library RateStore {
    // keccak256("credits.core.rate.v1")
    bytes32 internal constant SLOT = 0x4e200413f073f3688fb10caa054c801ceec5347eca7dbe3116ccdf1d7ddcb6a5;

    struct Anchor {
        /// the rate paid at the last fill. the rate at deployment before the first fill
        uint256 lastFillRate;
        /// the rate paid at the first fill of the minute bucket `minuteBucket`
        uint256 minuteStartRate;
        /// `timestamp / 60` of the first fill of the current minute
        uint64 minuteBucket;
    }

    function load() internal pure returns (Anchor storage a) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            a.slot := slot
        }
    }
}
