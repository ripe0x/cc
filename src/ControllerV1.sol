// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Lane, IController, ICoreViews} from "./interfaces/Interfaces.sol";

/// first policy module. no bonus for any credit, composes the oldest 80 of a lane with format 0, never overprints.
/// it holds no funds and has no privileged calls. the core reads it and enforces every limit itself.
contract ControllerV1 is IController {
    uint256 private constant PAGE = 80;

    ICoreViews public immutable CORE;

    constructor(address core) {
        CORE = ICoreViews(core);
    }

    /// returns zero for every credit.
    function wants(uint256) external pure returns (uint16) {
        return 0;
    }

    /// ready when the lane pile holds a full page. the page is the 80 oldest credits with format 0.
    function nextPage(Lane lane) external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        if (CORE.pileSize(lane) < PAGE) return (false, ids, 0);
        uint256[] memory page = CORE.pilePage(lane, 0, PAGE);
        for (uint256 i; i < PAGE; ++i) {
            ids[i] = page[i];
        }
        return (true, ids, 0);
    }

    /// never ready.
    function nextOverprint() external pure returns (bool, uint256, uint256) {
        return (false, 0, 0);
    }
}
