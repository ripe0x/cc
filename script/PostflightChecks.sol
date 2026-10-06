// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Core} from "../src/Core.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {Mainnet, Stack, Econ} from "../src/interfaces/Interfaces.sol";
import {
    IArtCoinsFactory,
    IArtCoinsToken,
    IArtCoinsSkimHook,
    IArtCoinsLocker,
    IArtCoinsMevSkim
} from "../src/interfaces/ArtCoins.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemBuilder} from "./Builder.sol";
import {Report} from "./Report.sol";

/// @notice reads a launched system back and compares it with the config. read only, safe against mainnet any time.
/// run it right after the launch: the supply and rate rows are exact at launch and tolerant once trading started
abstract contract PostflightChecks is SystemBuilder, Report {
    using PositionInfoLibrary for PositionInfo;

    /// @dev the locker keeps rounding dust of the supply
    uint256 internal constant LOCKER_DUST_MAX = 1e6;

    /// @dev a staticcall that never reverts. ok is false when the call failed or returned less than a word
    function _word(address target, bytes memory data) internal view returns (bool ok, uint256 w) {
        bytes memory out;
        (ok, out) = target.staticcall(data);
        if (ok && out.length >= 32) w = abi.decode(out, (uint256));
        else ok = false;
    }

    function postflight(LaunchConfig memory c, address core_) internal {
        _reset();
        _code("code: core", core_);
        if (core_.code.length == 0) return;
        Core core = Core(payable(core_));
        _postCore(c, core);
        address coin = core.COIN();
        _code("code: coin", coin);
        if (coin.code.length == 0) return;
        PoolKey memory key = poolKeyOf(coin, c.stack);
        bytes32 id = keccak256(abi.encode(key));
        _postCoin(c, core, IArtCoinsToken(coin), id);
        _postPool(c, core, key, id);
        _postHook(c, core_, id);
        _postTax(c, core_, IArtCoinsToken(coin), id);
        _postLocker(c, coin, key);
        _postMev(c, id);
        _postPosition(c, core, coin, id);
        _postUnreadable(c);
    }

    /// @notice the constructor arguments of a deployed core, read back from its immutables, in the encoding etherscan
    /// wants for verification: `(owner, coin, controller, stack, rateStart, econ)`
    function coreConstructorArgs(Core core) internal view returns (bytes memory) {
        Stack memory s = Stack({
            poolManager: address(core.MANAGER()),
            hook: core.HOOK(),
            tickSpacing: core.TICK_SPACING(),
            poolFee: core.POOL_FEE(),
            factory: core.FACTORY(),
            locker: core.LOCKER(),
            escrow: core.ESCROW()
        });
        Econ memory e = Econ({
            auctionStartX: core.AUCTION_START_X(),
            auctionFloorX: core.AUCTION_FLOOR_X(),
            dropBps: core.DROP_BPS(),
            inventoryGate: core.INVENTORY_GATE()
        });
        return abi.encode(core.OWNER(), core.COIN(), core.controller(), s, core.RATE_START(), e);
    }

    function _postCore(LaunchConfig memory c, Core core) private {
        _eq("core: owner", core.OWNER(), c.owner);
        _eq("core: SUPPLY constant equals the config supply", core.SUPPLY(), c.supply);
        _eq("core: RATE_START", core.RATE_START(), c.rateStart);
        _eq("core: AUCTION_START_X", core.AUCTION_START_X(), c.econ.auctionStartX);
        _eq("core: AUCTION_FLOOR_X", core.AUCTION_FLOOR_X(), c.econ.auctionFloorX);
        _eq("core: DROP_BPS", core.DROP_BPS(), c.econ.dropBps);
        _eq("core: INVENTORY_GATE", core.INVENTORY_GATE(), c.econ.inventoryGate);
        _eq("core: pool manager", address(core.MANAGER()), c.stack.poolManager);
        _eq("core: hook", core.HOOK(), c.stack.hook);
        _eq("core: tick spacing", uint256(int256(core.TICK_SPACING())), uint256(int256(c.stack.tickSpacing)));
        _eq("core: pool fee", uint256(core.POOL_FEE()), uint256(c.stack.poolFee));
        _eq("core: factory", core.FACTORY(), c.stack.factory);
        _eq("core: locker", core.LOCKER(), c.stack.locker);
        _eq("core: escrow", core.ESCROW(), c.stack.escrow);
        _check(
            "code: stack addresses",
            c.stack.poolManager.code.length != 0 && c.stack.hook.code.length != 0 && c.stack.factory.code.length != 0
                && c.stack.locker.code.length != 0 && c.stack.escrow.code.length != 0,
            "pool manager, hook, factory, locker, escrow"
        );
        address ctl = core.controller();
        _code("code: controller", ctl);
        if (ctl.code.length != 0) _eq("controller: core", address(ControllerV1(ctl).CORE()), address(core));
        _check(
            "core: allowed targets",
            core.allowedTarget(Mainnet.SEAPORT) && core.allowedTarget(Mainnet.CREDIT_STRATEGY)
                && !core.allowedTarget(c.stack.hook) && !core.allowedTarget(c.stack.factory)
                && !core.allowedTarget(c.stack.locker) && !core.allowedTarget(c.stack.escrow)
                && !core.allowedTarget(c.stack.poolManager) && !core.allowedTarget(core.COIN()),
            "seaport and CreditStrategy only"
        );
        _check(
            "core: no controller freeze, no exit module",
            !core.frozen() && core.exitModule() == address(0),
            "launch state"
        );
        _check(
            "core: pots covered by balance",
            core.ethPot() + core.ethToBuyback() <= address(core).balance,
            string.concat("balance ", vm.toString(address(core).balance))
        );
        // the live rate moves once the pot is funded or a credit is bought, so it is exact only while the pot is empty
        if (core.ethPot() == 0) {
            _eq("core: ethRate is rateStart", core.ethRate(), c.rateStart);
        } else {
            _check(
                "core: ethRate is rateStart", core.ethRate() != 0, "pot not empty, rate has moved, immutable checked"
            );
        }
    }

    function _postCoin(LaunchConfig memory c, Core core, IArtCoinsToken coin, bytes32 id) private {
        _eq("coin: name", coin.name(), c.name);
        _eq("coin: symbol", coin.symbol(), c.symbol);
        _eq("coin: supply", coin.totalSupply(), c.supply);
        _eq("coin: admin is owner", coin.admin(), c.owner);
        _eq("coin: pool id", coin.canonicalPoolId(), id);
        _eq("coin: held by core", coin.balanceOf(address(core)), 0);
        if (vm.exists(c.tokenCodeFile)) {
            _eq("coin: equals prediction", predictCoin(c, coin.originalAdmin(), address(core)), address(coin));
        }
        uint256 pm = coin.balanceOf(c.stack.poolManager);
        uint256 dust = coin.balanceOf(c.stack.locker);
        (, int24 tick,,) = StateLibrary.getSlot0(core.MANAGER(), PoolId.wrap(id));
        bool untraded = tick == -c.startTick;
        bool inPool = dust < LOCKER_DUST_MAX && (untraded ? pm + dust == c.supply : pm + dust <= c.supply && pm != 0);
        _check(
            "coin: supply sits in the pool",
            inPool,
            string.concat(
                "pool ", vm.toString(pm), " locker dust ", vm.toString(dust), untraded ? " untraded" : " traded"
            )
        );
    }

    function _postPool(LaunchConfig memory c, Core core, PoolKey memory key, bytes32 id) private {
        _eq("pool: key hook", address(key.hooks), c.stack.hook);
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(core.MANAGER(), PoolId.wrap(id));
        // the launch position is single sided at the pool edge, so the active liquidity can be zero at the start
        _check("pool: initialized", sqrtPrice != 0, vm.toString(id));
    }

    function _postHook(LaunchConfig memory c, address core, bytes32 id) private {
        IArtCoinsSkimHook hook = IArtCoinsSkimHook(c.stack.hook);
        (
            uint24 base,
            uint16 bounty,
            uint24 maxRef,
            uint24 lpFee,
            address bountyTo,
            address protoTo,
            address refTo,
            address quote
        ) = hook.skimConfig(id);
        _eq("skim: baseline bps", uint256(base), uint256(c.baselineSkimBps));
        _eq("skim: bounty bps", uint256(bounty), uint256(c.bountyBps));
        _eq("skim: referral cap", uint256(maxRef), uint256(c.maxReferralBps));
        _eq("skim: lp fee", uint256(lpFee), uint256(c.lpFee));
        _eq("skim: bounty recipient", bountyTo, core);
        _eq("skim: protocol recipient", protoTo, c.creator);
        _eq("skim: referral payout", refTo, core);
        _eq("skim: quote token", quote, address(0));
        _check(
            "hook: tax attested, mev module on",
            hook.poolTaxEnabled(id) && hook.mevModuleEnabled(id),
            "poolTaxEnabled, mevModuleEnabled"
        );
        _check(
            "hook: extension slot locked and empty",
            hook.poolExtensionLocked(id) && hook.poolExtension(id) == address(0),
            "locked"
        );
    }

    function _postTax(LaunchConfig memory c, address core, IArtCoinsToken coin, bytes32) private {
        _check("tax: enabled", coin.taxEnabled(), "taxEnabled");
        _eq("tax: bps", uint256(coin.taxBps()), uint256(c.taxBps));
        _eq("tax: bps max", uint256(coin.taxBpsMax()), uint256(c.taxBpsMax));
        _eq("tax: burn address", coin.taxBurnAddress(), c.taxBurn);
        _eq("tax: canonical hook", coin.canonicalHook(), c.stack.hook);
        _eq("tax: pool manager", coin.taxPoolManager(), c.stack.poolManager);
        _check("tax: core exempt", coin.isTaxExempt(core), "core is exempt");
        _check("tax: pool manager is a venue", coin.isTaxVenue(c.stack.poolManager), "v4");
        IArtCoinsFactory.TaxVenue[] memory venues = buildTaxConfig(c, core).venues;
        uint256 missing;
        for (uint256 i; i < venues.length; ++i) {
            IArtCoinsFactory.TaxVenue memory v = venues[i];
            (address t0, address t1) =
                address(coin) < v.counterToken ? (address(coin), v.counterToken) : (v.counterToken, address(coin));
            bytes32 salt = v.kind == 1 ? keccak256(abi.encodePacked(t0, t1)) : keccak256(abi.encode(t0, t1, v.v3Fee));
            if (!coin.isTaxVenue(vm.computeCreate2Address(salt, v.initCodeHash, v.factory))) ++missing;
        }
        _eq("tax: venues registered", missing, 0);
    }

    function _postLocker(LaunchConfig memory c, address coin, PoolKey memory key) private {
        IArtCoinsLocker.TokenRewardInfo memory info = IArtCoinsLocker(c.stack.locker).tokenRewards(coin);
        _check(
            "locker: one position, one reward slot",
            info.numPositions == 1 && info.rewardBps.length == 1 && info.rewardBps[0] == 10_000,
            "positions and bps"
        );
        if (info.rewardBps.length != 1) return;
        _eq("locker: reward recipient", info.rewardRecipients[0], c.creator);
        _eq("locker: reward admin", info.rewardAdmins[0], Mainnet.DEAD);
        _check(
            "locker: pool key",
            keccak256(abi.encode(info.poolKey)) == keccak256(abi.encode(key)),
            "tokenRewards poolKey"
        );
    }

    /// @dev the mev module exposes only `currentSkimBps(poolId)`, a function of the stored start, end and duration and
    /// of the time since the pool was created. inside the window one read pins the three values together (the formula is
    /// the module's `start - (start - end) * elapsed / duration`), after the window it reads the end value only
    function _postMev(LaunchConfig memory c, bytes32 id) private {
        uint256 created = IArtCoinsSkimHook(c.stack.hook).poolCreationTimestamp(id);
        (bool ok, uint256 cur) = _word(c.mevModule, abi.encodeCall(IArtCoinsMevSkim.currentSkimBps, (id)));
        uint256 elapsed = block.timestamp > created ? block.timestamp - created : 0;
        uint256 start = c.sniperStartBps;
        uint256 end = c.sniperEndBps;
        if (elapsed < c.sniperSeconds && start >= end) {
            uint256 want = start - (start - end) * elapsed / c.sniperSeconds;
            _check(
                "mev: skim now matches start, end and duration",
                ok && cur + 1 >= want && cur <= want + 1,
                string.concat(
                    "inside the window at ",
                    vm.toString(elapsed),
                    "s, module ",
                    vm.toString(cur),
                    " want ",
                    vm.toString(want)
                )
            );
        } else {
            _check(
                "mev: skim now equals the end bps",
                ok && cur == end,
                string.concat(
                    "window over, module ",
                    vm.toString(cur),
                    " want ",
                    vm.toString(end),
                    ". start bps and duration cannot be read after the window, run postflight inside it"
                )
            );
        }
    }

    /// @dev the launch position as the position manager stores it. the pool is eth against the coin, so the pool ticks
    /// are the negated config ticks. the start tick is read from the pool while untraded
    function _postPosition(LaunchConfig memory c, Core core, address coin, bytes32 id) private {
        IArtCoinsLocker.TokenRewardInfo memory info = IArtCoinsLocker(c.stack.locker).tokenRewards(coin);
        (bool ok, uint256 w) =
            _word(Mainnet.POSITION_MANAGER, abi.encodeWithSignature("positionInfo(uint256)", info.positionId));
        PositionInfo pi = PositionInfo.wrap(w);
        _check(
            "position: ticks equal the config",
            ok && pi.tickLower() == -c.positionUpper && pi.tickUpper() == -c.positionLower,
            string.concat(
                "pool ticks ",
                vm.toString(int256(pi.tickLower())),
                " to ",
                vm.toString(int256(pi.tickUpper())),
                ", config ",
                vm.toString(int256(-c.positionUpper)),
                " to ",
                vm.toString(int256(-c.positionLower))
            )
        );
        (bool ok2, uint256 holder) =
            _word(Mainnet.POSITION_MANAGER, abi.encodeWithSignature("ownerOf(uint256)", info.positionId));
        _check("position: held by the locker", ok2 && address(uint160(holder)) == c.stack.locker, "ownerOf");
        (, int24 tick,,) = StateLibrary.getSlot0(core.MANAGER(), PoolId.wrap(id));
        bool inRange = tick >= pi.tickLower() && tick <= pi.tickUpper();
        _check(
            "pool: start tick",
            inRange && (tick == -c.startTick || tick < -c.startTick),
            tick == -c.startTick
                ? "untraded, the pool sits at the start tick"
                : "traded, the start tick itself is no longer readable, the pool is inside the position"
        );
    }

    /// @dev what a read back cannot cover, said in the output
    function _postUnreadable(LaunchConfig memory c) private {
        _info(
            "not readable on chain",
            "protocolBps argument (0), sniper fee config, token image metadata context, locker data, the deploy fee paid, the salt itself (bound by coin: equals prediction)"
        );
        _info("signoff: CONFIG_HASH", vm.toString(configHash(c)));
    }
}
