// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settings, RATE_START_MIN_WEI, RATE_START_MAX_WEI} from "../src/interfaces/Interfaces.sol";

/// @notice the 30 fields of `Settings` by index (the order of the struct), their names and the documented bounds of
/// docs/FLOW.md section 2, for the settings script and the config and deploy tests. the two fields bounded by another
/// field (xRateCap, xRateFloor) have the bounds of the other field in the callers' hands
library SettingsFields {
    uint256 internal constant N = 30;

    /// @dev field i of the settings struct, in declaration order
    function get(Settings memory s, uint256 i) internal pure returns (uint256) {
        uint256[30] memory f = [
            uint256(s.flatBps),
            s.avgScore,
            s.dropPerCreditBps,
            s.dropFloorBps,
            s.climbPerMinBps,
            s.ceilBps,
            s.idleLoosenBps,
            s.spendCapBps,
            s.bonusCapBps,
            s.tipSavingsBps,
            s.tipCapBps,
            s.reimburseBps,
            s.reimburseCapBps,
            s.saleFloorBps,
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
            s.exitSliceCredits,
            s.rateCap,
            s.exitLaneToBuybackBps,
            s.feeToBuybackBps
        ];
        return f[i];
    }

    /// @dev sets field i, narrowing the value (callers stay inside the width of the field)
    function set(Settings memory s, uint256 i, uint256 v) internal pure {
        // forge-lint: disable-start(unsafe-typecast)
        if (i == 0) s.flatBps = uint16(v);
        else if (i == 1) s.avgScore = uint32(v);
        else if (i == 2) s.dropPerCreditBps = uint16(v);
        else if (i == 3) s.dropFloorBps = uint16(v);
        else if (i == 4) s.climbPerMinBps = uint16(v);
        else if (i == 5) s.ceilBps = uint16(v);
        else if (i == 6) s.idleLoosenBps = uint16(v);
        else if (i == 7) s.spendCapBps = uint16(v);
        else if (i == 8) s.bonusCapBps = uint16(v);
        else if (i == 9) s.tipSavingsBps = uint16(v);
        else if (i == 10) s.tipCapBps = uint16(v);
        else if (i == 11) s.reimburseBps = uint16(v);
        else if (i == 12) s.reimburseCapBps = uint16(v);
        else if (i == 13) s.saleFloorBps = uint16(v);
        else if (i == 14) s.auctionDuration = uint32(v);
        else if (i == 15) s.exitAfter = uint32(v);
        else if (i == 16) s.saleToBuybackBps = uint16(v);
        else if (i == 17) s.exitToBuybackBps = uint16(v);
        else if (i == 18) s.buybackSlice = uint128(v);
        else if (i == 19) s.buybackDelay = uint16(v);
        else if (i == 20) s.keeperTipBps = uint16(v);
        else if (i == 21) s.xRateCap = uint16(v);
        else if (i == 22) s.xRateFloor = uint16(v);
        else if (i == 23) s.xRateClimbPerHour = uint16(v);
        else if (i == 24) s.xRateDropPerCredit = uint16(v);
        else if (i == 25) s.xAuctionHalfLife = uint32(v);
        else if (i == 26) s.exitSliceCredits = uint16(v);
        else if (i == 27) s.rateCap = uint64(v);
        else if (i == 28) s.exitLaneToBuybackBps = uint16(v);
        else s.feeToBuybackBps = uint16(v);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev the documented lower bound of every field. xRateFloor and xRateCap are bounded by each other, those two are
    /// handled by the callers
    function lo() internal pure returns (uint256[30] memory) {
        return [
            uint256(0),
            800_000,
            1,
            5_000,
            1,
            10_000,
            0,
            100,
            0,
            0,
            0,
            0,
            0,
            1_000,
            6 hours,
            1 hours,
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
            1,
            RATE_START_MIN_WEI,
            0,
            0
        ];
    }

    function hi() internal pure returns (uint256[30] memory) {
        return [
            uint256(10_000),
            6_000_000,
            1_000,
            10_000,
            1_000,
            30_000,
            2_000,
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
            2 ether,
            7_200,
            500,
            10_000,
            10_000,
            1_000,
            1_000,
            30 days,
            1_000,
            RATE_START_MAX_WEI,
            10_000,
            10_000
        ];
    }

    function names() internal pure returns (bytes32[30] memory) {
        return [
            bytes32("flatBps"),
            "avgScore",
            "dropPerCreditBps",
            "dropFloorBps",
            "climbPerMinBps",
            "ceilBps",
            "idleLoosenBps",
            "spendCapBps",
            "bonusCapBps",
            "tipSavingsBps",
            "tipCapBps",
            "reimburseBps",
            "reimburseCapBps",
            "saleFloorBps",
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
            "exitSliceCredits",
            "rateCap",
            "exitLaneToBuybackBps",
            "feeToBuybackBps"
        ];
    }
}
