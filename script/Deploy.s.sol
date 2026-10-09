// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemDeployer, Deployed} from "./SystemDeployer.sol";
import {NewProd} from "./NewProd.sol";

/// @notice `CONFIG_HASH=0x... DEPLOYER=0x... forge script script/Deploy.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow
/// --private-key $KEY` (or `--account` or `--ledger`). the signer must be the v2 factory owner and the config owner, it
/// comes from the flags only, DEPLOYER only has to agree with it. reads script/config/mainnet.json, or the file named by
/// LAUNCH_CONFIG. refuses to run while owner, creator, name, symbol or salt is unset, unless CONFIG_HASH is the hash
/// that preflight printed for this config, and unless the signer is the factory owner. the order of the transactions
/// (docs/FLOW.md 10.4): the library, the controller, the router, the Core, the lens, the launch, then the router setup (engine,
/// payees). the split start is NOT sent here: it is derived from the launch time as mined, so it is the one step of
/// the Resume script (run it after this one, docs/DEPLOY.md). preflight runs first and postflight runs on the simulated result, both before anything is
/// sent. the full runbook is docs/DEPLOY.md
contract Deploy is Script, NewProd {
    /// @notice runs the deploy as the broadcaster
    function run() external returns (Deployed memory d) {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        _requireConfig(c);
        // nothing is signed or sent until the operator's sign off value equals the hash of this config
        _requireConfigHash(c, vm.envOr("CONFIG_HASH", bytes32(0)));
        // the signer, read once; the checks run outside the broadcast because they simulate the launch on a snapshot
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        vm.stopBroadcast();
        _requireDeployer(vm.envOr("DEPLOYER", address(0)), deployer);
        _requireOwner(c, deployer);
        // every preflight check runs first. a failed check reverts here, before anything is sent
        preflight(c, deployer);
        _print("preflight");
        _require();
        vm.startBroadcast();
        d = deploySystem(deployer, c);
        vm.stopBroadcast();
        // the same read back as the Postflight script, on the result of the run. a failure reverts the simulation, so
        // nothing is sent. the split start is still zero here (a warning): Resume sets it from the mined launch time
        splitStartPending = true;
        postflightAs(c, d.core, deployer);
        _print("postflight of the simulated launch");
        _require();
        console.log("core", d.core);
        console.log("coin", d.coin);
        console.log("controller", d.controller);
        console.log("router", d.router);
        console.log("lens", d.lens);
        console.log("split start NOT set: run script/Resume.s.sol once the launch is mined (docs/DEPLOY.md)");
        console.log("fee recipients NOT locked: run script/Lock.s.sol once the postflight passes (docs/DEPLOY.md)");
        for (uint256 i; i < STEPS; ++i) {
            console.log(string.concat("gas of step ", vm.toString(i)), stepGas[i]);
        }
    }
}
