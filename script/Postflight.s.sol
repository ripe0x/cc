// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice read only check of a launched system against the config. safe to run against mainnet at any time.
/// `CORE=0x... forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. set DEPLOYER to print the verify inputs. set CONFIG_HASH to check the signed off hash.
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
        // TODO(v2 port stage 3): there is no factory admin to revoke on v2, the launch is signed by the factory owner
        address deployer = vm.envOr("DEPLOYER", address(0));
        _print("postflight");
        if (core.code.length != 0) printVerifyInputs(ICore(payable(core)), c, deployer);
        _require();
    }
}
