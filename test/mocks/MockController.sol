// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Lane, IController} from "../../src/interfaces/Interfaces.sol";

/// settable controller for unit tests. it can also revert, burn gas or answer with an oversized word.
contract MockController is IController {
    mapping(uint256 => uint16) public bonus;
    bool public revertWants;
    bool public burnWants;
    bool public rawWants;

    mapping(Lane => bool) public pageReady;
    mapping(Lane => uint256[80]) internal _pageIds;
    mapping(Lane => uint8) public pageFormat;
    bool public revertPage;

    bool public overprintReady;
    uint256 public overprintBase;
    uint256 public overprintTop;

    /// sets the bonus for one credit.
    function setWants(uint256 id, uint16 bps) external {
        bonus[id] = bps;
    }

    /// makes wants revert.
    function setRevertWants(bool on) external {
        revertWants = on;
    }

    /// makes wants spin until it runs out of gas.
    function setBurnWants(bool on) external {
        burnWants = on;
    }

    /// makes wants answer with a word above the uint16 range.
    function setRawWants(bool on) external {
        rawWants = on;
    }

    /// sets the page answer for a lane.
    function setPage(Lane lane, bool ready, uint256[80] calldata ids, uint8 format) external {
        pageReady[lane] = ready;
        _pageIds[lane] = ids;
        pageFormat[lane] = format;
    }

    /// makes nextPage revert.
    function setRevertPage(bool on) external {
        revertPage = on;
    }

    /// sets the overprint answer.
    function setOverprint(bool ready, uint256 baseId, uint256 topId) external {
        overprintReady = ready;
        overprintBase = baseId;
        overprintTop = topId;
    }

    function wants(uint256 id) external view returns (uint16) {
        if (revertWants) revert();
        if (burnWants) {
            uint256 i;
            while (true) {
                ++i;
            }
        }
        if (rawWants) {
            assembly {
                mstore(0, not(0))
                return(0, 32)
            }
        }
        return bonus[id];
    }

    function nextPage(Lane lane) external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        if (revertPage) revert();
        return (pageReady[lane], _pageIds[lane], pageFormat[lane]);
    }

    function nextOverprint() external view returns (bool ready, uint256 baseId, uint256 topId) {
        return (overprintReady, overprintBase, overprintTop);
    }
}
