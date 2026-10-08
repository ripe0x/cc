// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {Deployed} from "./SystemDeployer.sol";
import {SystemResumer, Stage} from "./SystemResumer.sol";
import {NewProd} from "./NewProd.sol";

/// @notice `CORE=0x... CONFIG_HASH=0x... forge script script/Resume.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow
/// --private-key $KEY`. run it as the same deployer as the original run. reads the stage from the chain and sends
/// only what is missing: the launch (if the core exists and the coin does not), the extension lock, the admin handover.
/// then runs postflight. prints the stage it found. the runbook is docs/DEPLOY.md section 6
contract Resume is Script, SystemResumer, NewProd {
    function run() external {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        _requireConfig(c);
        _requireConfigHash(c, vm.envOr("CONFIG_HASH", bytes32(0)));
        address core = vm.envAddress("CORE");
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        _requireDeployer(vm.envOr("DEPLOYER", address(0)), deployer);
        (Stage from, Deployed memory d) = resumeSystem(deployer, c, core);
        vm.stopBroadcast();
        console.log("stage found", uint256(from));
        console.log("0 no core, 1 core only, 2 launched, 3 locked, 4 done");
        _print("postflight after resume");
        console.log("coin", d.coin);
    }
}
