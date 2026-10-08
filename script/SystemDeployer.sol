// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice everything the deploy creates
struct Deployed {
    address core;
    address coin;
    address controller;
    address router;
    PoolKey launchKey;
    bytes32 poolId;
}

/// @notice the deploy routine, shared by the script and by tests. call it from a broadcast or from a prank of
/// `owner`, who must be the v2 factory owner (a deprecated v2 factory takes only its owner, through
/// `deployTokenAsOwner`). order (docs/FLOW.md 10.4): router (engine unset), controller, Core (fee source the router, coin
/// predicted by the factory), the launch, then the router is set up: engine, payees, tip, split start. the router is NOT
/// locked here, the owner closes it as a separate step. the controller, Core and coin addresses are predicted
/// and every prediction is checked after creation
/// TODO(v2 port stage 3): library creation order for `forge script`, the preflight and postflight calls, the factory
/// owner commands (`setMinLpFee(0)`), the swapper free flow checks
abstract contract SystemDeployer is LaunchChecks {
    /// @notice a created contract did not land at its predicted address
    error AddressMismatch(string what);
    /// @notice a placeholder of the config is unset, or rateStart or a setting is out of bounds
    error ConfigUnset(string what);
    /// @notice the signer is not the address the operator named in DEPLOYER
    error DeployerMismatch(address want, address got);
    /// @notice CONFIG_HASH is not the hash of the config the script loaded. `want` is the hash of this config
    error ConfigHashMismatch(bytes32 got, bytes32 want);

    /// @notice execution gas of the steps of the last `deploySystem`: router, controller, core, launch, router setup
    uint256[5] internal stepGas;

    /// @notice creates the router, the controller and the core. the script (`NewProd`) uses `new`, a test base uses
    /// `deployCode` on the artifacts, so the test contracts neither import the production sources nor embed their code
    function _newRouter(address owner) internal virtual returns (address);

    function _newController(address core, LaunchConfig memory c) internal virtual returns (address);

    function _newCore(address owner, address coin, address controller, LaunchConfig memory c)
        internal
        virtual
        returns (address);

    /// @notice deploys and launches the whole system. `c.stack.feeSource` is filled in with the new router
    /// @param owner the address that sends every transaction: the broadcaster or the active prank, the factory owner
    /// and the first owner of the router and the Core
    function deploySystem(address owner, LaunchConfig memory c) internal returns (Deployed memory d) {
        _requireConfig(c);
        uint256 g = gasleft();
        d.router = _newRouter(owner);
        stepGas[0] = g - gasleft();
        c.stack.feeSource = d.router;
        uint64 nonce = vm.getNonce(owner);
        address controllerAt = vm.computeCreateAddress(owner, nonce);
        address coreAt = vm.computeCreateAddress(owner, nonce + 1);
        address coinAt = predictCoin(c, owner, d.router, coreAt);

        g = gasleft();
        d.controller = _newController(coreAt, c);
        d.core = _newCore(c.owner, coinAt, d.controller, c);
        stepGas[1] = g - gasleft();
        if (d.controller != controllerAt) revert AddressMismatch("controller");
        if (d.core != coreAt) revert AddressMismatch("core");

        g = gasleft();
        d.coin = _launch(c, owner, coinAt, d.router, coreAt);
        stepGas[2] = g - gasleft();
        d.launchKey = poolKeyOf(d.coin, c.stack);
        d.poolId = keccak256(abi.encode(d.launchKey));

        g = gasleft();
        _setupRouter(c, d.router, d.core);
        stepGas[4] = g - gasleft();
    }

    /// @notice the launch through the factory as its owner, paying the live deploy fee. checks the coin address
    /// against the prediction the Core was built with
    function _launch(LaunchConfig memory c, address owner, address coinAt, address router, address core)
        internal
        returns (address coin)
    {
        IArtCoinsFactoryV2 factory = IArtCoinsFactoryV2(c.stack.factory);
        uint256 fee = factory.deployFee();
        uint256 g = gasleft();
        coin = factory.deployTokenAsOwner{value: fee}(buildConfig(c, c.owner, router, core), c.protocolBps);
        stepGas[3] = g - gasleft();
        if (coin != coinAt) revert AddressMismatch("coin");
        owner;
    }

    /// @notice points the router at the Core, sets its payees and tip, and starts the split after the anti sniper window.
    /// the caller is the router owner
    function _setupRouter(LaunchConfig memory c, address router, address core) internal {
        IFeeRouter r = IFeeRouter(payable(router));
        r.setEngine(core);
        address[] memory who = new address[](2);
        who[0] = c.creatorPayee;
        who[1] = c.artistPayee;
        uint32[] memory ppm = new uint32[](2);
        ppm[0] = c.payeePpm;
        ppm[1] = c.payeePpm;
        r.setPayees(who, ppm);
        r.setTip(c.tipPpm, c.tipCap);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.setSplitStart(uint64(block.timestamp + c.sniperSeconds));
    }

    /// @notice reverts unless the signer is the deployer the operator named
    function _requireDeployer(address want, address got) internal pure {
        if (want == address(0) || want != got) revert DeployerMismatch(want, got);
    }

    /// @notice the sign off value: reverts unless `given` is the hash of this config
    function _requireConfigHash(LaunchConfig memory c, bytes32 given) internal view {
        bytes32 want = configHash(c);
        if (given != want) revert ConfigHashMismatch(given, want);
    }

    /// @notice reverts when a placeholder is unset or rateStart or a setting is out of bounds
    function _requireConfig(LaunchConfig memory c) internal pure {
        string[] memory unset = unsetFields(c);
        if (unset.length != 0) revert ConfigUnset(unset[0]);
        if (!rateInBounds(c)) revert ConfigUnset("rateStart");
        if (settingsViolation(c) != 0) revert ConfigUnset("settings");
        if (saleViolation(c) != 0) revert ConfigUnset("sale");
    }
}
