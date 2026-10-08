// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemDeployer, Deployed} from "./SystemDeployer.sol";
import {NewProd} from "./NewProd.sol";

/// @notice `CONFIG_HASH=0x... forge script script/Deploy.s.sol --rpc-url $PRIVATE_RPC --broadcast --private-key $KEY`
/// (or `--account` or `--ledger`), with DEPLOYER set to the address of that signer. the signer comes from the flags only,
/// no environment variable picks one, DEPLOYER only has to agree with it. reads
/// script/config/mainnet.json, or the file named by LAUNCH_CONFIG. refuses to run while owner, creator, name, symbol or
/// salt is unset, and unless CONFIG_HASH is the hash that preflight printed for this config. the full runbook is
/// docs/DEPLOY.md
contract Deploy is Script, NewProd {
    /// @dev the predicted coin address already has code, so someone launched first or the salt was reused
    error CoinAlreadyDeployed(address coin);

    /// @notice runs the deploy as the broadcaster
    function run() external returns (Deployed memory d) {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        _requireConfig(c);
        // nothing is signed or sent until the operator's sign off value equals the hash of this config
        _requireConfigHash(c, vm.envOr("CONFIG_HASH", bytes32(0)));
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        // the signer must be the address of the sign off table (DEPLOYER, the one the factory owner enabled)
        _requireDeployer(vm.envOr("DEPLOYER", address(0)), deployer);
        // every preflight check runs first. a failed check reverts here, before anything is sent
        preflight(c, deployer);
        _print("preflight");
        _require();
        // refuse to deploy a Core against a coin address that is already taken
        address coreAt = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        address coinAt = predictCoin(c, deployer, coreAt);
        if (coinAt.code.length != 0) revert CoinAlreadyDeployed(coinAt);
        d = deploySystem(deployer, c);
        vm.stopBroadcast();

        _print("launch read back");
        console.log("core", d.core);
        console.log("coin", d.coin);
        console.log("controller", d.controller);
    }
}
