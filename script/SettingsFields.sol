// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settings} from "../src/interfaces/Interfaces.sol";

/// @notice the 26 fields of `Settings` by index (the order of the struct), their names and the documented bounds of
/// docs/FLOW.md section 2, for the settings script and the config and deploy tests. the three fields bounded by another
/// field (climbMaxBps, xRateCap, xRateFloor) have the bounds of the other field in the callers' hands
library SettingsFields {
    uint256 internal constant N = 26;

    /// @dev field i of the settings struct, in declaration order
    function get(Settings memory s, uint256 i) internal pure returns (uint256) {
        uint256[26] memory f = [
            uint256(s.flatBps),
            s.avgScore,
            s.climbBaseBps,
            s.climbDoubleEvery,
            s.climbMaxBps,
            s.dropBps,
            s.spendCapBps,
            s.bonusCapBps,
            s.tipSavingsBps,
            s.tipCapBps,
            s.reimburseBps,
            s.reimburseCapBps,
            s.reserveBps,
            s.auctionDuration,
            s.exitAfter,
            s.saleToBuybackBps,
            s.exitToBuybackBps,
            s.buybackSlice,
            s.buybackDelay,
            s.keeperTipBps,
            s.xRateCap,
            s.xRateFloor,
            s.xRateClimbPerHour,
            s.xRateDropPerCredit,
            s.xAuctionHalfLife,
            s.exitSliceCredits
        ];
        return f[i];
    }

    /// @dev sets field i, narrowing the value (callers stay inside the width of the field)
    function set(Settings memory s, uint256 i, uint256 v) internal pure {
        // forge-lint: disable-start(unsafe-typecast)
        if (i == 0) s.flatBps = uint16(v);
        else if (i == 1) s.avgScore = uint32(v);
        else if (i == 2) s.climbBaseBps = uint16(v);
        else if (i == 3) s.climbDoubleEvery = uint32(v);
        else if (i == 4) s.climbMaxBps = uint16(v);
        else if (i == 5) s.dropBps = uint16(v);
        else if (i == 6) s.spendCapBps = uint16(v);
        else if (i == 7) s.bonusCapBps = uint16(v);
        else if (i == 8) s.tipSavingsBps = uint16(v);
        else if (i == 9) s.tipCapBps = uint16(v);
        else if (i == 10) s.reimburseBps = uint16(v);
        else if (i == 11) s.reimburseCapBps = uint16(v);
        else if (i == 12) s.reserveBps = uint16(v);
        else if (i == 13) s.auctionDuration = uint32(v);
        else if (i == 14) s.exitAfter = uint32(v);
        else if (i == 15) s.saleToBuybackBps = uint16(v);
        else if (i == 16) s.exitToBuybackBps = uint16(v);
        else if (i == 17) s.buybackSlice = uint128(v);
        else if (i == 18) s.buybackDelay = uint16(v);
        else if (i == 19) s.keeperTipBps = uint16(v);
        else if (i == 20) s.xRateCap = uint16(v);
        else if (i == 21) s.xRateFloor = uint16(v);
        else if (i == 22) s.xRateClimbPerHour = uint16(v);
        else if (i == 23) s.xRateDropPerCredit = uint16(v);
        else if (i == 24) s.xAuctionHalfLife = uint32(v);
        else s.exitSliceCredits = uint16(v);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev the documented lower bound of every field. climbMaxBps is bounded below by climbBaseBps and xRateFloor and
    /// xRateCap by each other, those three are handled by the callers
    function lo() internal pure returns (uint256[26] memory) {
        return [
            uint256(0),
            800_000,
            0,
            1 hours,
            0,
            0,
            100,
            0,
            0,
            0,
            0,
            0,
            1_000,
            1 hours,
            0,
            0,
            0,
            0.01 ether,
            1,
            0,
            0,
            0,
            0,
            0,
            10 minutes,
            1
        ];
    }

    function hi() internal pure returns (uint256[26] memory) {
        return [
            uint256(10_000),
            8_000_000,
            1_000,
            30 days,
            2_000,
            5_000,
            10_000,
            5_000,
            2_500,
            500,
            15_000,
            1_000,
            40_000,
            30 days,
            365 days,
            10_000,
            10_000,
            100 ether,
            7_200,
            500,
            10_000,
            10_000,
            1_000,
            1_000,
            30 days,
            1_000
        ];
    }

    function names() internal pure returns (bytes32[26] memory) {
        return [
            bytes32("flatBps"),
            "avgScore",
            "climbBaseBps",
            "climbDoubleEvery",
            "climbMaxBps",
            "dropBps",
            "spendCapBps",
            "bonusCapBps",
            "tipSavingsBps",
            "tipCapBps",
            "reimburseBps",
            "reimburseCapBps",
            "reserveBps",
            "auctionDuration",
            "exitAfter",
            "saleToBuybackBps",
            "exitToBuybackBps",
            "buybackSlice",
            "buybackDelay",
            "keeperTipBps",
            "xRateCap",
            "xRateFloor",
            "xRateClimbPerHour",
            "xRateDropPerCredit",
            "xAuctionHalfLife",
            "exitSliceCredits"
        ];
    }
}
