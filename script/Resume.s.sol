// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {IArtCoinsToken, IArtCoinsSkimHook} from "../src/interfaces/ArtCoins.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemDeployer, Deployed} from "./Deploy.s.sol";

/// @notice how far a deploy got. read from the chain, never from a file
enum Stage {
    NoCore, // no code at the core address, nothing to resume
    CoreOnly, // core deployed, the launch through the factory is not sent
    Launched, // coin launched, the extension slot is still open
    Locked, // slot locked, the token admin is still the deployer
    Done // slot locked and the owner is the token admin
}

/// @notice finishes a deploy that stopped half way: detects the stage on chain and sends only the missing steps, as the
/// deployer. shared by the `Resume` script and the tests
abstract contract SystemResumer is SystemDeployer {
    /// @notice the core at the given address was not built from this config
    error CoreMismatch(string what);
    /// @notice the caller is not the token admin, so it cannot lock or hand over
    error NotTokenAdmin(address admin, address caller);

    /// @notice the stage of the deploy of `core`, from chain state only
    function detectStage(LaunchConfig memory c, address core) internal view returns (Stage) {
        if (core.code.length == 0) return Stage.NoCore;
        address coin = Core(payable(core)).COIN();
        if (coin.code.length == 0) return Stage.CoreOnly;
        bytes32 id = keccak256(abi.encode(poolKeyOf(coin, c.stack)));
        if (!IArtCoinsSkimHook(c.stack.hook).poolExtensionLocked(id)) return Stage.Launched;
        if (IArtCoinsToken(coin).admin() != c.owner) return Stage.Locked;
        return Stage.Done;
    }

    /// @dev the core must be the one this config would have built, and its coin the one the config predicts
    function _requireCoreMatches(LaunchConfig memory c, address deployer, address core_) private view {
        Core core = Core(payable(core_));
        if (core.OWNER() != c.owner) revert CoreMismatch("owner");
        if (core.RATE_START() != c.rateStart) revert CoreMismatch("rateStart");
        if (
            address(core.MANAGER()) != c.stack.poolManager || core.HOOK() != c.stack.hook
                || core.TICK_SPACING() != c.stack.tickSpacing || core.POOL_FEE() != c.stack.poolFee
                || core.FACTORY() != c.stack.factory || core.LOCKER() != c.stack.locker
                || core.ESCROW() != c.stack.escrow || core.AUCTION_FACTORY() != c.stack.auctionFactory
        ) revert CoreMismatch("stack");
        if (predictCoin(c, deployer, core_) != core.COIN()) {
            revert CoreMismatch("coin prediction (config or deployer)");
        }
    }

    /// @notice performs the steps the chain is still missing, then runs postflight and reverts on any failed row. the
    /// caller must be the deployer of the original run, because the coin address and the token admin depend on it
    /// @return from the stage found
    /// @return d what the deploy created
    function resumeSystem(address deployer, LaunchConfig memory c, address core_)
        internal
        returns (Stage from, Deployed memory d)
    {
        _requireConfig(c);
        from = detectStage(c, core_);
        if (from == Stage.NoCore) revert CoreMismatch("no code at the core address, run Deploy instead");
        _requireCoreMatches(c, deployer, core_);
        preflightResume(c, deployer, from == Stage.CoreOnly);
        _require();

        Core core = Core(payable(core_));
        d.core = core_;
        d.coin = core.COIN();
        d.controller = core.controller();
        d.launchKey = poolKeyOf(d.coin, c.stack);
        d.poolId = keccak256(abi.encode(d.launchKey));

        if (from == Stage.CoreOnly) _launch(c, deployer, d.coin, core_);
        if (from != Stage.Done) {
            address admin = IArtCoinsToken(d.coin).admin();
            if (admin != deployer) revert NotTokenAdmin(admin, deployer);
        }
        if (from == Stage.CoreOnly || from == Stage.Launched) _lock(c, d.launchKey);
        if (from != Stage.Done) _handover(c, d.coin);
        postflight(c, core_);
        _require();
    }
}

/// @notice `CORE=0x... CONFIG_HASH=0x... forge script script/Resume.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow
/// --private-key $KEY`. run it as the same deployer as the original run. reads the stage from the chain and sends
/// only what is missing: the launch (if the core exists and the coin does not), the extension lock, the admin handover.
/// then runs postflight. prints the stage it found. the runbook is docs/DEPLOY.md section 6
contract Resume is Script, SystemResumer {
    function run() external {
        LaunchConfig memory c = loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
        _requireConfig(c);
        _requireConfigHash(c, vm.envOr("CONFIG_HASH", bytes32(0)));
        address core = vm.envAddress("CORE");
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        (Stage from, Deployed memory d) = resumeSystem(deployer, c, core);
        vm.stopBroadcast();
        console.log("stage found", uint256(from));
        console.log("0 no core, 1 core only, 2 launched, 3 locked, 4 done");
        _print("postflight after resume");
        console.log("coin", d.coin);
    }
}
