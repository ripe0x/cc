// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Coin} from "../src/Coin.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {Launcher} from "../src/Launcher.sol";
import {ICoreFees, Mainnet} from "../src/interfaces/Interfaces.sol";
import {SystemDeployer, Deployed} from "../script/Deploy.s.sol";

/// @notice runs the deploy routine from a prank and from a broadcast. it needs the real Core and ControllerV1
/// artifacts and skips itself while they do not exist
contract DeployTest is Test, SystemDeployer {
    using StateLibrary for IPoolManager;

    address internal deployer = makeAddr("fx.deployer.9c1e");
    address internal owner = makeAddr("fx.owner.9c1e");
    address internal creator = makeAddr("fx.creator.9c1e");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        try vm.getCode("Core.sol:Core") returns (bytes memory) {}
        catch {
            vm.skip(true);
        }
    }

    function _check(Deployed memory d) internal view {
        assertEq(uint160(d.hook) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
        assertEq(Coin(d.coin).core(), d.core);
        assertEq(Coin(d.coin).hook(), d.hook);
        assertEq(FeeHook(payable(d.hook)).coin(), d.coin);
        assertEq(FeeHook(payable(d.hook)).core(), d.core);
        assertEq(FeeHook(payable(d.hook)).creator(), creator);
        assertEq(FeeHook(payable(d.hook)).launcher(), d.launcher);
        assertEq(Launcher(d.launcher).deployer(), deployer);
        assertTrue(Launcher(d.launcher).launched());
        assertFalse(Launcher(d.launcher).launching());
        assertEq(ICoreFees(d.core).exitPoolId(), bytes32(0));
        assertEq(Coin(d.coin).balanceOf(d.launcher), 0);
        assertEq(
            Coin(d.coin).balanceOf(Mainnet.POOL_MANAGER) + Coin(d.coin).balanceOf(Mainnet.DEAD), Coin(d.coin).SUPPLY()
        );
        (uint160 sqrtPrice,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(PoolIdLibrary.toId(d.launchKey));
        assertEq(sqrtPrice, 501082896750095888663770159906816);
        (bool ok, bytes memory ret) = d.core.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && ret.length == 32) assertEq(abi.decode(ret, (address)), owner);
    }

    function test_deployUnderPrank() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, owner, creator, "Name", "SYM");
        vm.stopPrank();
        _check(d);
    }

    function test_deployUnderBroadcast() public {
        vm.startBroadcast(deployer);
        Deployed memory d = deploySystem(deployer, owner, creator, "Name", "SYM");
        vm.stopBroadcast();
        _check(d);
    }

    function test_deployWithAdvancedNonce() public {
        vm.setNonce(deployer, 17);
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, owner, creator, "Name", "SYM");
        vm.stopPrank();
        _check(d);
        assertEq(d.launcher, vm.computeCreateAddress(deployer, 17));
    }

    /// H6 regression: someone deploys the hook first with the public salt and initcode, after the deployer mined
    /// it. the script treats the existing hook as done and still launches
    function test_deployAfterHookFrontRun() public {
        uint64 n = vm.getNonce(deployer);
        address launcher = vm.computeCreateAddress(deployer, n);
        address core = vm.computeCreateAddress(deployer, n + 1);
        address coin = vm.computeCreateAddress(deployer, n + 2);
        (address hook, bytes32 salt) = mineHook(coin, core, creator, launcher);

        vm.prank(makeAddr("fx.attacker.9c1e"));
        assertEq(create2Hook(salt, coin, core, creator, launcher), hook, "front run lands at the same address");

        vm.startPrank(deployer);
        Deployed memory d = deploySystemWithSalt(deployer, owner, creator, "Name", "SYM", hook, salt);
        vm.stopPrank();
        assertEq(d.hook, hook);
        _check(d);
    }
}
