// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice read only checks before a launch. safe to run against mainnet at any time, it sends nothing.
/// `DEPLOYER=0x... forge script script/Preflight.s.sol --rpc-url $MAINNET_RPC_URL` (add `--sender $DEPLOYER` or set
/// DEPLOYER). prints a table, the sign off rows and the config hash and reverts with the names of the failed checks. reads script/config/mainnet.json or the
/// file named by LAUNCH_CONFIG. the check "factory: deployer may launch" fails until the factory owner has enabled the
/// deployer, which is expected on the first run
contract Preflight is Script, LaunchChecks {
    function run() external {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        address deployer = vm.envOr("DEPLOYER", msg.sender);
        preflight(c, deployer);
        _print("preflight");
        console.log("sign off this value, Deploy needs it in CONFIG_HASH");
        console.log(string.concat("CONFIG_HASH=", vm.toString(configHash(c))));
        _require();
    }
}
