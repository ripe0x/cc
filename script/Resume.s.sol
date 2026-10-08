// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {Deployed} from "./SystemDeployer.sol";
import {SystemResumer, Stage} from "./SystemResumer.sol";
import {NewProd} from "./NewProd.sol";

/// @notice `CORE=0x... CONFIG_HASH=0x... forge script script/Resume.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow
/// --private-key $KEY`. run it as the same deployer as the original run. reads the stage from the chain and sends
/// only what is missing: the launch (if the core exists and the coin does not), then the router setup (engine, payees, tip, split start).
/// then runs postflight. prints the stage it found. the runbook is docs/DEPLOY.md section 6
contract Resume is Script, SystemResumer, NewProd {
    function run() external {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        _requireConfig(c);
        _requireConfigHash(c, vm.envOr("CONFIG_HASH", bytes32(0)));
        address core = vm.envAddress("CORE");
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        vm.stopBroadcast();
        _requireDeployer(vm.envOr("DEPLOYER", address(0)), deployer);
        // the checks simulate the launch on a snapshot, so they run outside the broadcast
        Stage from = resumeChecks(deployer, c, core);
        vm.startBroadcast();
        Deployed memory d = resumeSend(deployer, c, core, from);
        vm.stopBroadcast();
        console.log("stage found", uint256(from));
        console.log("0 no core, 1 core only, 2 launched, 3 router setup missing, 4 done");
        console.log("coin", d.coin);
        console.log("router", d.router);
    }
}
