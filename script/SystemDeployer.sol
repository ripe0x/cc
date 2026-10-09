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
    address lens;
    PoolKey launchKey;
    bytes32 poolId;
}

/// @notice the deploy routine, shared by the script and by tests. call it from a broadcast or from a prank of
/// `owner`, who must be the v2 factory owner and the config owner (a deprecated v2 factory takes only its owner, through
/// `deployTokenAsOwner`). order (docs/FLOW.md 10.4): the library `CoreLib` (linked by `forge script` before `run`), the
/// controller, the router (engine unset), the Core (fee source the router, coin predicted by the factory), the lens
/// `CoreLens` (read only, pointing at the Core), the launch, then the router is set up in three transactions: engine, payees, tip. the fourth, the split start, is a separate step
/// that runs after the launch is mined (`startSplitAfterLaunch`, the Resume script): it reads the launch time from the chain.
/// the router is NOT locked here, the owner closes it as a separate step. the controller, router, Core and coin addresses are predicted and every
/// prediction is checked after creation
abstract contract SystemDeployer is LaunchChecks {
    /// @notice a created contract did not land at its predicted address
    error AddressMismatch(string what);
    /// @notice a placeholder of the config is unset, or rateStart or a setting is out of bounds
    error ConfigUnset(string what);
    /// @notice the signer is not the address the operator named in DEPLOYER
    error DeployerMismatch(address want, address got);
    /// @notice CONFIG_HASH is not the hash of the config the script loaded. `want` is the hash of this config
    error ConfigHashMismatch(bytes32 got, bytes32 want);
    /// @notice the sender is not the factory owner, or not the config owner: the owner path of the factory is the only way in
    error NotFactoryOwner(address factoryOwner, address sender);
    /// @notice a transaction of the deploy would not fit under the per transaction gas cap
    error TxOverGasCap(uint256 step, uint256 gas);

    /// @dev what a transaction costs on top of the execution gas measured inside the call: the base 21_000 and the
    /// calldata of the largest creation (about 30 kb at 16 gas a byte, a bound)
    uint256 internal constant TX_OVERHEAD = 520_000;
    /// @notice the launch is not recorded by the factory yet, so there is no launch time to derive the split start from
    error LaunchNotMined();

    /// @dev the steps of `stepGas`, in the order they are sent
    uint256 internal constant STEPS = 9;

    /// @notice execution gas of the transactions of the last `deploySystem`: controller, router, core, launch, setEngine,
    /// setPayees, setTip, setSplitStart (measured by `startSplitAfterLaunch`, not by `deploySystem`), lens (sent right after
    /// the core). the library goes first and is measured by the rehearsal
    uint256[9] internal stepGas;

    /// @notice creates the router, the controller and the core. the script (`NewProd`) uses `new`, a test base uses
    /// `deployCode` on the artifacts, so the test contracts neither import the production sources nor embed their code
    function _newRouter(address owner) internal virtual returns (address);

    function _newController(address core, LaunchConfig memory c) internal virtual returns (address);

    /// @notice creates the lens of `core` at `lensAddress(core)`: CREATE2 through the deterministic deployer with `LENS_SALT`
    function _newLens(address core) internal virtual returns (address);

    function _newCore(address owner, address coin, address controller, LaunchConfig memory c)
        internal
        virtual
        returns (address);

    /// @notice deploys and launches the whole system. `c.stack.feeSource` is filled in with the new router
    /// @param owner the address that sends every transaction: the broadcaster or the active prank, the factory owner
    /// and the first owner of the router and the Core
    function deploySystem(address owner, LaunchConfig memory c) internal returns (Deployed memory d) {
        _requireConfig(c);
        _requireOwner(c, owner);
        uint64 nonce = vm.getNonce(owner);
        address controllerAt = vm.computeCreateAddress(owner, nonce);
        address routerAt = vm.computeCreateAddress(owner, nonce + 1);
        address coreAt = vm.computeCreateAddress(owner, nonce + 2);
        c.stack.feeSource = routerAt;
        address coinAt = predictCoin(c, owner, routerAt, coreAt);

        uint256 g = gasleft();
        d.controller = _newController(coreAt, c);
        _step(0, g);
        g = gasleft();
        d.router = _newRouter(owner);
        _step(1, g);
        g = gasleft();
        d.core = _newCore(c.owner, coinAt, d.controller, c);
        _step(2, g);
        if (d.controller != controllerAt) revert AddressMismatch("controller");
        if (d.router != routerAt) revert AddressMismatch("router");
        if (d.core != coreAt) revert AddressMismatch("core");
        g = gasleft();
        d.lens = _newLens(d.core);
        _step(8, g);
        if (d.lens != lensAddress(d.core)) revert AddressMismatch("lens");

        d.coin = _launch(c, coinAt, d.router, coreAt);
        d.launchKey = poolKeyOf(d.coin, c.stack);
        d.poolId = keccak256(abi.encode(d.launchKey));
        _setupRouter(c, d.router, d.core);
    }

    function _step(uint256 i, uint256 gasBefore) internal {
        uint256 used = gasBefore - gasleft();
        stepGas[i] = used;
        if (used + TX_OVERHEAD > TX_GAS_CAP) revert TxOverGasCap(i, used);
    }

    /// @notice the sender must be the factory owner and the config owner
    function _requireOwner(LaunchConfig memory c, address sender) internal view {
        (bool ok, address fo) = _addr(c.stack.factory, abi.encodeCall(IArtCoinsFactoryV2.owner, ()));
        if (!ok || fo != sender || c.owner != sender) revert NotFactoryOwner(fo, sender);
    }

    /// @notice the launch through the factory as its owner, paying the live deploy fee. checks the coin address
    /// against the prediction the Core was built with
    function _launch(LaunchConfig memory c, address coinAt, address router, address core)
        internal
        returns (address coin)
    {
        IArtCoinsFactoryV2 factory = IArtCoinsFactoryV2(c.stack.factory);
        uint256 fee = factory.deployFee();
        uint256 g = gasleft();
        coin = factory.deployTokenAsOwner{value: fee}(buildConfig(c, c.owner, router, core), c.protocolBps);
        _step(3, g);
        if (coin != coinAt) revert AddressMismatch("coin");
    }

    /// @notice the three router transactions, each one only when the router does not hold the value yet: engine, payees,
    /// tip. the caller is the router owner. the split start is not here: it needs the mined launch time (`startSplitAfterLaunch`)
    function _setupRouter(LaunchConfig memory c, address router, address core) internal {
        IFeeRouter r = IFeeRouter(payable(router));
        uint256 g = gasleft();
        if (r.engine() != core) r.setEngine(core);
        _step(4, g);
        g = gasleft();
        (address[] memory have, uint32[] memory havePpm) = r.payees();
        if (have.length != 1 || have[0] != c.creatorPayee || havePpm[0] != c.payeePpm) {
            address[] memory who = new address[](1);
            who[0] = c.creatorPayee;
            uint32[] memory ppm = new uint32[](1);
            ppm[0] = c.payeePpm;
            r.setPayees(who, ppm);
        }
        _step(5, g);
        g = gasleft();
        if (r.tipPpm() != c.tipPpm || r.tipCap() != c.tipCap) r.setTip(c.tipPpm, c.tipCap);
        _step(6, g);
    }

    /// @notice the last router transaction, only after the launch transaction is mined: the split starts when the anti
    /// sniper window ends, the launch time read from the factory record of the coin plus the window, no margin. only
    /// when the router has no split start yet. the caller is the router owner
    function startSplitAfterLaunch(LaunchConfig memory c, address router, address coin) internal {
        (bool ok, IArtCoinsFactoryV2.DeploymentInfoV2 memory info) = _deployment(c.stack.factory, coin);
        if (!ok || info.launchedAt == 0) revert LaunchNotMined();
        uint256 g = gasleft();
        IFeeRouter r = IFeeRouter(payable(router));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (r.splitStart() == 0) r.setSplitStart(uint64(uint256(info.launchedAt) + c.sniperSeconds));
        _step(7, g);
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
