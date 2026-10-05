// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Coin} from "../../src/Coin.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {Launcher} from "../../src/Launcher.sol";
import {SystemDeployer} from "../../script/Deploy.s.sol";
import {MockCore} from "../mocks/MockCore.sol";

/// @notice the hook test wiring: the real Coin, FeeHook and Launcher around a MockCore, without launching.
/// the order and the nonce prediction are the same as in the deploy routine
struct Wired {
    Launcher launcher;
    MockCore core;
    Coin coin;
    FeeHook hook;
    PoolKey launchKey;
}

abstract contract MockWiring is SystemDeployer {
    error WiringMismatch();

    /// @notice deploys launcher, mock core, coin and hook from `deployer`, which must be the caller of this code
    function wireWithMockCore(address deployer, address creator) internal returns (Wired memory w) {
        uint64 nonce = vm.getNonce(deployer);
        address coinAddress = vm.computeCreateAddress(deployer, nonce + 2);

        w.launcher = new Launcher(deployer);
        w.core = new MockCore();
        (address hookAddress, bytes32 salt) = mineHook(coinAddress, address(w.core), creator, address(w.launcher));
        w.coin = new Coin("Test Coin", "TEST", address(w.core), hookAddress, address(w.launcher));
        w.hook = FeeHook(payable(create2Hook(salt, coinAddress, address(w.core), creator, address(w.launcher))));
        if (address(w.coin) != coinAddress || address(w.hook) != hookAddress) revert WiringMismatch();

        w.launchKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(w.coin)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(w.hook))
        });
    }
}
