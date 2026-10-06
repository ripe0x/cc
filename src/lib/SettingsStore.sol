// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settings} from "../interfaces/Interfaces.sol";

/// where the settings live: a fixed storage slot of the Core, shared by the Core and the linked library, so the library
/// can write them when the Core hands it a `setSettings` call by delegatecall. three packed slots from here
library SettingsStore {
    // keccak256("credits.core.settings.v1")
    bytes32 internal constant SLOT = 0xb5805f89ef62cd999f965a45fb6f4c11141caa04e5c4acba9c2552ef76902804;

    function load() internal pure returns (Settings storage s) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            s.slot := slot
        }
    }
}
