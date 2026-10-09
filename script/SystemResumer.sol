// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../src/interfaces/ICore.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemDeployer, Deployed} from "./SystemDeployer.sol";

/// @notice how far a deploy got. read from the chain, never from a file
enum Stage {
    NoCore, // no code at the core address, nothing to resume (run Deploy again)
    CoreOnly, // controller, router and core deployed, the launch through the factory is not sent
    Launched, // coin launched, the router does not point at the core yet
    Setup, // router engine, payees or the split start still missing (the split start waits for a mined launch)
    Done // router set up as in the config
}

/// @notice finishes a deploy that stopped half way: detects the stage on chain and sends only the missing steps, as the
/// factory owner. the split start is set here, in the run after the launch is mined, from the launch time on chain.
/// shared by the `Resume` script and the tests
abstract contract SystemResumer is SystemDeployer {
    /// @notice the core at the given address was not built from this config
    error CoreMismatch(string what);
    /// @notice the caller is not the owner of the router, so it cannot set it up
    error NotRouterOwner(address routerOwner, address caller);

    /// @notice the stage of the deploy of `core`, from chain state only
    function detectStage(LaunchConfig memory c, address core) internal view returns (Stage) {
        if (core.code.length == 0) return Stage.NoCore;
        address coin = ICore(payable(core)).COIN();
        if (coin.code.length == 0) return Stage.CoreOnly;
        IFeeRouter r = IFeeRouter(payable(ICore(payable(core)).FEE_SOURCE()));
        if (address(r).code.length == 0) revert CoreMismatch("the fee source has no code");
        // ROUTER_CHANGED=1: the owner changed the router since the launch, the deploy is done whatever it holds
        if (_routerChanged()) return r.engine() == core ? Stage.Done : Stage.Launched;
        if (r.engine() != core) return Stage.Launched;
        (address[] memory who, uint32[] memory ppm) = r.payees();
        bool payees = who.length == 1 && who[0] == c.creatorPayee && ppm[0] == c.payeePpm;
        if (!payees || r.splitStart() == 0) return Stage.Setup;
        return Stage.Done;
    }

    /// @dev the core must be the one this config would have built, and its coin the one the config predicts
    function _requireCoreMatches(LaunchConfig memory c, address deployer, address core_, bool launching) private view {
        ICore core = ICore(payable(core_));
        if (!_ownerChanged() && core.owner() != c.owner) revert CoreMismatch("owner (OWNER_CHANGED=1 after a handover)");
        if (core.RATE_START() != c.rateStart) revert CoreMismatch("rateStart");
        // the owner can call `setSettings` as soon as the core exists. a core whose settings differ from the signed config
        // is finished only on purpose, with SETTINGS_CHANGED=1 (the postflight at the end warns and prints it)
        if (!_settingsChanged() && keccak256(abi.encode(core.settings())) != keccak256(abi.encode(c.settings))) {
            revert CoreMismatch("settings (SETTINGS_CHANGED=1 if the owner changed them)");
        }
        if (
            address(core.MANAGER()) != c.stack.poolManager || core.HOOK() != c.stack.hook
                || core.TICK_SPACING() != c.stack.tickSpacing || core.POOL_FEE() != c.stack.poolFee
                || core.FACTORY() != c.stack.factory || core.LOCKER() != c.stack.locker
                || core.ESCROW() != c.stack.escrow || core.AUCTION_FACTORY() != c.stack.auctionFactory
        ) revert CoreMismatch("stack");
        if (launching) {
            // before the launch the factory prediction for the deployer and this config must give the Core's coin
            (bool ok, address want) = _predict(c, deployer, c.stack.feeSource, core_);
            if (!ok || want != core.COIN()) revert CoreMismatch("coin prediction (config or deployer)");
        }
    }

    /// @notice everything the resume checks before it sends: the stage, that the core is the one this config builds, and
    /// the preflight rows that still apply. reverts on any failure. the script runs it outside the broadcast
    function resumeChecks(address deployer, LaunchConfig memory c, address core_) internal returns (Stage from) {
        _requireConfig(c);
        from = detectStage(c, core_);
        if (from == Stage.NoCore) revert CoreMismatch("no code at the core address, run Deploy instead");
        c.stack.feeSource = ICore(payable(core_)).FEE_SOURCE();
        _requireCoreMatches(c, deployer, core_, from == Stage.CoreOnly);
        preflightResume(c, deployer, from == Stage.CoreOnly);
        _require();
    }

    /// @dev creates the lens when `lensAddress(core)` has no code. the address is a function of the Core, so a run that
    /// stopped between the Core and the lens (or later) sends it whatever the deployer nonce is
    function _ensureLens(address core_) private returns (address lensAt) {
        lensAt = lensAddress(core_);
        if (lensAt.code.length != 0) return lensAt;
        uint256 g = gasleft();
        address made = _newLens(core_);
        _step(7, g);
        if (made != lensAt) revert AddressMismatch("lens");
    }

    /// @notice sends the steps the chain is still missing (after `resumeChecks`), then runs postflight and reverts on any
    /// failed row. the caller must be the deployer of the original run, because the coin address and the router owner
    /// depend on it
    function resumeSend(address deployer, LaunchConfig memory c, address core_, Stage from)
        internal
        returns (Deployed memory d)
    {
        ICore core = ICore(payable(core_));
        splitStartPending = false;
        c.stack.feeSource = core.FEE_SOURCE();
        d.router = c.stack.feeSource;
        d.core = core_;
        d.coin = core.COIN();
        d.controller = core.controller();
        d.lens = _ensureLens(core_);
        d.launchKey = poolKeyOf(d.coin, c.stack);
        d.poolId = keccak256(abi.encode(d.launchKey));

        if (from == Stage.CoreOnly) {
            _requireOwner(c, deployer);
            _launch(c, d.coin, d.router, core_);
        }
        if (from != Stage.Done) {
            address ro = IFeeRouter(payable(d.router)).owner();
            if (ro != deployer) revert NotRouterOwner(ro, deployer);
            _setupRouter(c, d.router, core_);
            // the split start needs the mined launch time. a run that sent the launch cannot know it: the next run does
            if (from == Stage.CoreOnly) splitStartPending = true;
            else startSplitAfterLaunch(c, d.router, d.coin);
        }
        postflightAs(c, core_, deployer);
        _require();
    }
}
