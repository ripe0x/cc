// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CommonBase} from "forge-std/Base.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Coin} from "../src/Coin.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {Launcher} from "../src/Launcher.sol";

/// @notice everything the deploy creates
struct Deployed {
    address core;
    address coin;
    address hook;
    address controller;
    address launcher;
    PoolKey launchKey;
}

/// @notice the deploy routine, shared by the script and by tests. call it from a broadcast or from a prank of
/// `deployer`. addresses of the core, coin and controller are predicted from the deployer nonce, so the hook
/// initcode is known before it is mined, and every prediction is checked after creation.
abstract contract SystemDeployer is CommonBase {
    /// @notice the create2 deployer proxy
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice the hook permission bits, which must equal the low bits of the hook address
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    /// @notice a created contract did not land at its predicted address
    error AddressMismatch(string what);
    /// @notice creation failed
    error CreateFailed(string what);

    /// @notice deploys and launches the whole system
    /// @param deployer the address that sends every transaction. must be the broadcaster or the active prank
    /// @param owner the core owner
    /// @param creator receives the creator share of every fee
    /// @param name coin name
    /// @param symbol coin symbol
    function deploySystem(address deployer, address owner, address creator, string memory name, string memory symbol)
        internal
        returns (Deployed memory d)
    {
        uint64 nonce = vm.getNonce(deployer);
        (address hook, bytes32 salt) = mineHook(
            vm.computeCreateAddress(deployer, nonce + 2),
            vm.computeCreateAddress(deployer, nonce + 1),
            creator,
            vm.computeCreateAddress(deployer, nonce)
        );
        return deploySystemWithSalt(deployer, owner, creator, name, symbol, hook, salt);
    }

    /// @notice the same as deploySystem with the hook address and salt already mined. the hook step is skipped when
    /// the hook is already deployed at that address, as after a front run of the public salt
    function deploySystemWithSalt(
        address deployer,
        address owner,
        address creator,
        string memory name,
        string memory symbol,
        address hook,
        bytes32 salt
    ) internal returns (Deployed memory d) {
        uint64 nonce = vm.getNonce(deployer);
        address launcher = vm.computeCreateAddress(deployer, nonce);
        address core = vm.computeCreateAddress(deployer, nonce + 1);
        address coin = vm.computeCreateAddress(deployer, nonce + 2);
        address controller = vm.computeCreateAddress(deployer, nonce + 3);

        d.launcher = address(new Launcher(deployer));
        d.core = createContract(
            abi.encodePacked(vm.getCode("Core.sol:Core"), abi.encode(owner, coin, hook, controller)), "core"
        );
        d.coin = address(new Coin(name, symbol, core, hook, launcher));
        d.controller = createContract(
            abi.encodePacked(vm.getCode("ControllerV1.sol:ControllerV1"), abi.encode(core)), "controller"
        );
        d.hook = ensureHook(salt, hook, coin, core, creator, launcher);

        if (d.launcher != launcher) revert AddressMismatch("launcher");
        if (d.core != core) revert AddressMismatch("core");
        if (d.coin != coin) revert AddressMismatch("coin");
        if (d.controller != controller) revert AddressMismatch("controller");
        if (d.hook != hook) revert AddressMismatch("hook");

        Launcher(launcher).launch(coin, hook);
        d.launchKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    /// @notice finds a create2 salt that gives the hook an address with the right permission bits
    function mineHook(address coin, address core, address creator, address launcher)
        internal
        view
        returns (address hook, bytes32 salt)
    {
        return HookMiner.find(
            CREATE2_DEPLOYER, HOOK_FLAGS, type(FeeHook).creationCode, abi.encode(coin, core, creator, launcher)
        );
    }

    /// @notice deploys the hook unless it is already there. the salt and initcode are public, so anyone can deploy the
    /// same hook first. it then lands at the same address and nothing is lost, so the step counts as done once the
    /// contract at the predicted address reports the expected constructor values
    function ensureHook(bytes32 salt, address hook, address coin, address core, address creator, address launcher)
        internal
        returns (address)
    {
        if (hook.code.length == 0) return create2Hook(salt, coin, core, creator, launcher);
        FeeHook h = FeeHook(payable(hook));
        if (h.coin() != coin || h.core() != core || h.creator() != creator || h.launcher() != launcher) {
            revert AddressMismatch("hook");
        }
        return hook;
    }

    /// @notice deploys the hook through the create2 deployer proxy
    function create2Hook(bytes32 salt, address coin, address core, address creator, address launcher)
        internal
        returns (address hook)
    {
        bytes memory initcode = abi.encodePacked(type(FeeHook).creationCode, abi.encode(coin, core, creator, launcher));
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initcode));
        if (!ok || ret.length != 20) revert CreateFailed("hook");
        hook = address(bytes20(ret));
    }

    /// @notice plain create from the calling account, so the nonce prediction holds
    function createContract(bytes memory initcode, string memory what) internal returns (address created) {
        assembly {
            created := create(0, add(initcode, 0x20), mload(initcode))
        }
        if (created == address(0)) revert CreateFailed(what);
    }
}

/// @notice `forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast` with OWNER, CREATOR,
/// COIN_NAME and COIN_SYMBOL in the environment
contract Deploy is Script, SystemDeployer {
    /// @notice runs the deploy as the broadcaster
    function run() external returns (Deployed memory d) {
        address owner = vm.envAddress("OWNER");
        address creator = vm.envAddress("CREATOR");
        string memory name = vm.envString("COIN_NAME");
        string memory symbol = vm.envString("COIN_SYMBOL");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        d = deploySystem(deployer, owner, creator, name, symbol);
        vm.stopBroadcast();

        console.log("launcher", d.launcher);
        console.log("core", d.core);
        console.log("coin", d.coin);
        console.log("controller", d.controller);
        console.log("hook", d.hook);
    }
}
