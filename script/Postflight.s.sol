// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {IArtCoinsFactory} from "../src/interfaces/ArtCoins.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice read only check of a launched system against the config. safe to run against mainnet at any time.
/// `CORE=0x... forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. set DEPLOYER too to print whether
/// the deployer still holds the factory admin role (an information row, the revoke comes after this check).
/// prints a table and reverts on any mismatch. run it right after the launch: the supply and rate rows are exact only
/// until the first trade or the first fill
contract Postflight is Script, LaunchChecks {
    function run() external {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        address core = vm.envAddress("CORE");
        postflight(c, core);
        address deployer = vm.envOr("DEPLOYER", address(0));
        if (deployer != address(0)) {
            bool admin = IArtCoinsFactory(c.stack.factory).admins(deployer);
            _check("info: deployer still factory admin", true, admin ? "yes, revoke it" : "no");
        }
        _print("postflight");
        if (core.code.length != 0) {
            console.log("core constructor args, for etherscan verification");
            console.logBytes(coreConstructorArgs(Core(payable(core))));
            console.log("controller constructor args");
            console.logBytes(abi.encode(core));
        }
        _require();
    }
}
