// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {
    IArtCoinsFactoryV2,
    IArtCoinsHookV2,
    IArtCoinsLpLockerV2,
    IArtCoinsMevSkimV2,
    IArtCoinsTokenV2
} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {PostflightV2} from "./PostflightV2.sol";

/// @notice the pool side of the postflight: the factory record, the hook's pool and skim config, the mev schedule, the
/// locker rewards and the position, all read back from the v2 contracts and compared with the signed config
abstract contract PostflightPool is PostflightV2 {
    using PositionInfoLibrary for PositionInfo;

    /// @dev the locker keeps rounding dust of the supply
    uint256 internal constant LOCKER_DUST_MAX = 1e6;

    function _postPool(LaunchConfig memory c, address coin_) internal returns (bytes32 poolId) {
        PoolKey memory key = poolKeyOf(coin_, c.stack);
        poolId = keccak256(abi.encode(key));
        uint40 launchedAt = _postFactoryRecord(c, coin_, poolId);
        _postHook(c, coin_, poolId, launchedAt);
        _postSkim(c, poolId);
        _postMev(c, poolId, launchedAt);
        _postLocker(c, coin_, key);
        _postState(c, coin_, poolId);
    }

    function _postFactoryRecord(LaunchConfig memory c, address coin_, bytes32 poolId) private returns (uint40) {
        address fa = c.stack.factory;
        (bool ok, bool isCoin) = _bool(fa, abi.encodeCall(IArtCoinsFactoryV2.isCoin, (coin_)));
        _check("factory: the coin is a recorded launch", ok && isCoin, "isCoin(coin)");
        (bool okd, IArtCoinsFactoryV2.DeploymentInfoV2 memory info) = _deployment(fa, coin_);
        _check(
            "factory: deploymentInfo names the coin, hook, locker, mev module, escrow and pool of the config",
            okd && info.token == coin_ && info.hook == c.stack.hook && info.locker == c.stack.locker
                && info.mevModule == c.mevModule && info.escrow == c.stack.escrow && info.restricted == c.restricted
                && info.poolId == poolId,
            string.concat("pool id ", vm.toString(info.poolId))
        );
        (bool okv, uint256 ver) = _word(fa, abi.encodeCall(IArtCoinsFactoryV2.STACK_VERSION, ()));
        _check(
            "factory: deploymentInfo version, launch time, no extensions",
            okd && okv && info.version == ver && info.launchedAt != 0 && info.extensions.length == 0,
            string.concat("version ", vm.toString(info.version), " launched ", vm.toString(info.launchedAt))
        );
        return info.launchedAt;
    }

    function _postHook(LaunchConfig memory c, address coin_, bytes32 poolId, uint40 launchedAt) private {
        address hook = c.stack.hook;
        IArtCoinsHookV2.PoolInfo memory p = _hookInfo(hook, poolId);
        _check(
            "hook: poolInfo names the coin, locker, mev module and the factory as launcher, no extension",
            p.token == coin_ && p.locker == c.stack.locker && p.mevModule == c.mevModule
                && p.launcher == c.stack.factory && p.extension == address(0),
            string.concat("token ", vm.toString(p.token), " launcher ", vm.toString(p.launcher))
        );
        _check(
            "hook: poolInfo restricted flag and creation time",
            p.restricted == c.restricted && p.createdAt == launchedAt && launchedAt != 0,
            string.concat("restricted ", p.restricted ? "yes" : "no", " created ", vm.toString(p.createdAt))
        );
        (bool ok, bool official) = _bool(hook, abi.encodeCall(IArtCoinsHookV2.isOfficialPool, (poolId)));
        _check("hook: the pool is an official pool", ok && official, "isOfficialPool(poolId)");
        _check(
            "hook: carries the v2 permission flags",
            uint160(hook) & 0x3FFF == 0x28CC,
            vm.toString(hook)
        );
    }

    /// @dev the skim config of the pool, frozen at init: the bounty goes to the router, the values are the config's
    function _postSkim(LaunchConfig memory c, bytes32 poolId) private {
        IArtCoinsHookV2.SkimConfig memory k = _hookSkim(c.stack.hook, poolId);
        _eq("hook: bounty recipient is the fee router (the Core fee source)", address(k.bountyRecipient), c.stack.feeSource);
        _check(
            "hook: skim config equals the config",
            k.baselineSkimBps == c.baselineSkimBps && k.bountyBps == c.bountyBps
                && k.maxReferralBpsOfVolume == c.maxReferralBps && k.lpFeePips == c.lpFeePips,
            string.concat(
                "baseline ",
                vm.toString(k.baselineSkimBps),
                " bounty ",
                vm.toString(k.bountyBps),
                " referral cap ",
                vm.toString(k.maxReferralBpsOfVolume),
                " lp fee ",
                vm.toString(k.lpFeePips)
            )
        );
        (bool okf, uint256 floor) = _word(c.stack.hook, abi.encodeCall(IArtCoinsHookV2.minProtocolShareBps, (poolId)));
        _check(
            "hook: the pool protocol floor leaves room for the bounty",
            okf && floor + uint256(c.bountyBps) <= 10_000,
            string.concat("minProtocolShareBps ", vm.toString(floor), " bounty ", vm.toString(c.bountyBps))
        );
        address fa = c.stack.factory;
        (bool ok, address live) = _addr(fa, abi.encodeCall(IArtCoinsFactoryV2.protocolRecipient, ()));
        _info("hook: protocol recipient (the launcher protocol, not the engine owner)", vm.toString(k.protocolRecipient));
        _warn("warn: protocol recipient equals the factory protocol recipient", ok && live == k.protocolRecipient, vm.toString(live));
    }

    /// @dev the frozen anti sniper schedule: start, end (the baseline), window, start time
    function _postMev(LaunchConfig memory c, bytes32 poolId, uint40 launchedAt) private {
        (bool ok, bytes memory out) = c.mevModule.staticcall(abi.encodeCall(IArtCoinsMevSkimV2.schedule, (poolId)));
        IArtCoinsMevSkimV2.SkimSchedule memory s;
        ok = ok && out.length == 128;
        if (ok) s = abi.decode(out, (IArtCoinsMevSkimV2.SkimSchedule));
        _check(
            "mev: schedule equals the config (start, end at the baseline, window, start time)",
            ok && s.startingSkimBps == c.sniperStartBps && s.endSkimBps == c.baselineSkimBps
                && s.windowSeconds == c.sniperSeconds && s.startTime == launchedAt,
            string.concat(
                "start ",
                vm.toString(s.startingSkimBps),
                " end ",
                vm.toString(s.endSkimBps),
                " window ",
                vm.toString(s.windowSeconds)
            )
        );
        (uint256 now_, uint256 active) = _skimNow(c.mevModule, poolId);
        _info("mev: skim now", string.concat(vm.toString(now_), active == 1 ? " (window open)" : " (window over)"));
    }

    function _skimNow(address mev, bytes32 poolId) private view returns (uint256 bps, uint256 active) {
        (bool ok, bytes memory out) = mev.staticcall(abi.encodeCall(IArtCoinsMevSkimV2.currentSkimBps, (poolId)));
        if (ok && out.length == 64) (bps, active) = abi.decode(out, (uint256, uint256));
    }

    /// @dev the locker rewards: one project slot to the creator, the protocol slot at the end, summing to 10_000
    function _postLocker(LaunchConfig memory c, address coin_, PoolKey memory key) private {
        IArtCoinsLpLockerV2.TokenRewardInfoV2 memory r = _rewards(c.stack.locker, coin_);
        uint256 slots = c.protocolBps == 0 ? 1 : 2;
        bool ok = r.token == coin_ && r.numPositions == 1 && r.rewardRecipients.length == slots
            && r.rewardBps.length == slots;
        if (ok) {
            ok = r.rewardRecipients[0] == c.creator && r.rewardBps[0] == 10_000 - c.protocolBps;
            if (slots == 2) ok = ok && r.rewardBps[1] == c.protocolBps;
        }
        _check(
            "locker: one position, project reward slot is the creator, the protocol slot follows",
            ok,
            string.concat("slots ", vm.toString(r.rewardRecipients.length), " positions ", vm.toString(r.numPositions))
        );
        _check("locker: pool key equals the launch key", keccak256(abi.encode(r.poolKey)) == keccak256(abi.encode(key)), "poolKey");
        if (slots == 2 && r.rewardRecipients.length == 2) {
            _info("locker: protocol reward slot recipient", vm.toString(r.rewardRecipients[1]));
        }
        _postPosition(c, r);
    }

    function _rewards(address locker, address coin_) private view returns (IArtCoinsLpLockerV2.TokenRewardInfoV2 memory r) {
        (bool ok, bytes memory out) = locker.staticcall(abi.encodeCall(IArtCoinsLpLockerV2.tokenRewards, (coin_)));
        if (ok && out.length >= 416) r = abi.decode(out, (IArtCoinsLpLockerV2.TokenRewardInfoV2));
    }

    /// @dev the launch position read from the position manager: the ticks of the config, held by the locker, liquidity in it
    function _postPosition(LaunchConfig memory c, IArtCoinsLpLockerV2.TokenRewardInfoV2 memory r) private {
        IPositionManager pm = IPositionManager(Mainnet.POSITION_MANAGER);
        (bool ok, PositionInfo info) = _positionInfo(pm, r.positionId);
        _check(
            "position: ticks equal the config (mirrored, the coin is currency1)",
            ok && info.tickLower() == -c.positionUpper && info.tickUpper() == -c.positionLower,
            string.concat("lower ", vm.toString(int256(info.tickLower())), " upper ", vm.toString(int256(info.tickUpper())))
        );
        (bool okl, uint256 liq) = _word(Mainnet.POSITION_MANAGER, abi.encodeCall(IPositionManager.getPositionLiquidity, (r.positionId)));
        (bool oko, address holder) = _addr(Mainnet.POSITION_MANAGER, abi.encodeWithSignature("ownerOf(uint256)", r.positionId));
        _check(
            "position: held by the locker with liquidity",
            okl && oko && liq != 0 && holder == c.stack.locker,
            string.concat("liquidity ", vm.toString(liq), " holder ", vm.toString(holder))
        );
    }

    function _positionInfo(IPositionManager pm, uint256 id) private view returns (bool ok, PositionInfo info) {
        (bool okc, bytes memory out) = address(pm).staticcall(abi.encodeCall(IPositionManager.positionInfo, (id)));
        ok = okc && out.length == 32;
        if (ok) info = abi.decode(out, (PositionInfo));
    }

    /// @dev the pool in the pool manager: initialised, and while nothing was bought (the pool manager still holds the whole
    /// supply bar the locker dust) the price is exactly the start price. the coin is currency1, so the tick is mirrored
    function _postState(LaunchConfig memory c, address coin_, bytes32 poolId) private {
        (uint160 sqrtPrice, int24 tick,,) = StateLibrary.getSlot0(IPoolManager(c.stack.poolManager), PoolId.wrap(poolId));
        _check("pool: initialized", sqrtPrice != 0, vm.toString(uint256(sqrtPrice)));
        bool untouched = IArtCoinsTokenV2(coin_).balanceOf(c.stack.poolManager) + LOCKER_DUST_MAX >= c.supply;
        _check(
            "pool: start tick equals the config while nothing was bought",
            !untouched || tick == -c.startTick,
            string.concat("tick ", vm.toString(int256(tick)), untouched ? " untouched" : " traded")
        );
    }
}
