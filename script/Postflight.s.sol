// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IArtCoinsFactory} from "../src/interfaces/ArtCoins.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice read only check of a launched system against the config. safe to run against mainnet at any time.
/// `CORE=0x... forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. set DEPLOYER too to print whether
/// the deployer still holds the factory admin role (an information row, the revoke comes after this check, set
/// REQUIRE_REVOKED=1 to make it a failure). set CONFIG_HASH to check the signed off hash.
/// prints a table and reverts on any mismatch. run it right after the launch: the supply and rate rows are exact only
/// until the first trade or the first fill
contract Postflight is Script, LaunchChecks {
    function run() external {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        address core = vm.envAddress("CORE");
        postflight(c, core);
        // the same hash preflight printed and Deploy required. when CONFIG_HASH is set it must match
        bytes32 given = vm.envOr("CONFIG_HASH", bytes32(0));
        if (given != bytes32(0)) _eq("config hash equals CONFIG_HASH", configHash(c), given);
        address deployer = vm.envOr("DEPLOYER", address(0));
        if (deployer != address(0)) {
            bool admin = IArtCoinsFactory(c.stack.factory).admins(deployer);
            // REQUIRE_REVOKED=1 turns the revoke into a gate: the row fails while the deployer is still an admin
            bool gate = vm.envOr("REQUIRE_REVOKED", uint256(0)) == 1;
            _check("deployer still factory admin", !admin || !gate, admin ? "yes, revoke it (step 10)" : "no");
        }
        _print("postflight");
        if (core.code.length != 0) printVerifyInputs(ICore(payable(core)), c, deployer);
        _require();
    }
}
