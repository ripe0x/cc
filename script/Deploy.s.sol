// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Core} from "../src/Core.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {IArtCoinsFactory, IArtCoinsToken, IArtCoinsSkimHook} from "../src/interfaces/ArtCoins.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice everything the deploy creates
struct Deployed {
    address core;
    address coin;
    address controller;
    PoolKey launchKey;
    bytes32 poolId;
}

/// @notice the deploy routine, shared by the script and by tests. call it from a broadcast or from a prank of
/// `deployer`. the controller and core addresses are predicted from the deployer nonce, the coin address from the
/// factory create2 formula, and every prediction is checked after creation. the deployer must be allowed to launch
/// on the factory of the config (a deprecated factory takes only its owner or an admin) and must hold the deploy fee.
/// the config carries the whole artcoins stack, so a new artcoins version needs no code change here
abstract contract SystemDeployer is LaunchChecks {
    /// @notice a created contract did not land at its predicted address
    error AddressMismatch(string what);
    /// @notice a placeholder of the config is unset, or rateStart is out of bounds
    error ConfigUnset(string what);

    /// @notice execution gas of the five steps of the last `deploySystem`: controller, core, launch through the factory,
    /// lock the extension slot, hand over the token admin. intrinsic transaction gas comes on top of each
    uint256[5] internal stepGas;

    /// @notice deploys and launches the whole system
    /// @param deployer the address that sends every transaction. must be the broadcaster or the active prank
    /// @param c the launch config, placeholders filled
    function deploySystem(address deployer, LaunchConfig memory c) internal returns (Deployed memory d) {
        _requireConfig(c);
        uint64 nonce = vm.getNonce(deployer);
        address controllerAt = vm.computeCreateAddress(deployer, nonce);
        address coreAt = vm.computeCreateAddress(deployer, nonce + 1);
        address coinAt = predictCoin(c, deployer, coreAt);

        uint256 g = gasleft();
        d.controller = address(new ControllerV1(coreAt));
        stepGas[0] = g - gasleft();
        g = gasleft();
        d.core = address(new Core(c.owner, coinAt, d.controller, c.stack, c.rateStart));
        stepGas[1] = g - gasleft();
        if (d.controller != controllerAt) revert AddressMismatch("controller");
        if (d.core != coreAt) revert AddressMismatch("core");

        IArtCoinsFactory factory = IArtCoinsFactory(c.stack.factory);
        uint256 fee = factory.deployFee();
        g = gasleft();
        d.coin = factory.deployTokenWithProtocolBpsAndTax{value: fee}(
            buildConfig(c, deployer, coreAt), 0, buildTaxConfig(c, coreAt)
        );
        stepGas[2] = g - gasleft();
        if (d.coin != coinAt) revert AddressMismatch("coin");

        d.launchKey = poolKeyOf(d.coin, c.stack);
        d.poolId = keccak256(abi.encode(d.launchKey));

        // the extension slot is empty and locked for good, then the owner takes the token admin role
        g = gasleft();
        IArtCoinsSkimHook(c.stack.hook).lockPoolExtension(d.launchKey);
        stepGas[3] = g - gasleft();
        g = gasleft();
        IArtCoinsToken(d.coin).updateAdmin(c.owner);
        stepGas[4] = g - gasleft();
        postflight(c, d.core);
        _require();
    }

    /// @notice reverts when a placeholder is unset or rateStart is out of bounds
    function _requireConfig(LaunchConfig memory c) internal pure {
        string[] memory unset = unsetFields(c);
        if (unset.length != 0) revert ConfigUnset(unset[0]);
        if (!rateInBounds(c)) revert ConfigUnset("rateStart");
    }
}

/// @notice `forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY`
/// (or `--account` or `--ledger`). reads script/config/mainnet.json, or the file named by LAUNCH_CONFIG. the only
/// environment override is PRIVATE_KEY (a secret), used when no signer flag is given. refuses to run while owner,
/// creator, name, symbol or salt is unset. the full runbook is docs/DEPLOY.md
contract Deploy is Script, SystemDeployer {
    /// @dev the predicted coin address already has code, so someone launched first or the salt was reused
    error CoinAlreadyDeployed(address coin);

    /// @notice runs the deploy as the broadcaster
    function run() external returns (Deployed memory d) {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        _requireConfig(c);
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
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
