// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IArtCoinsFactoryV2, IArtCoinsHookV2, IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemBuilder} from "./Builder.sol";
import {Report} from "./Report.sol";

/// @notice the safe readers and the coin side of the postflight (docs/FLOW.md 10.4): every read is a staticcall that
/// reports a failure instead of reverting, so a wrong address turns into a failed row and never aborts the table
abstract contract PostflightV2 is SystemBuilder, Report {
    /// @dev a staticcall that never reverts. ok is false when the call failed or returned less than a word
    function _word(address target, bytes memory data) internal view returns (bool ok, uint256 w) {
        bytes memory out;
        (ok, out) = target.staticcall(data);
        if (ok && out.length >= 32) w = abi.decode(out, (uint256));
        else ok = false;
    }

    function _addr(address target, bytes memory data) internal view returns (bool ok, address a) {
        uint256 w;
        (ok, w) = _word(target, data);
        if (w > type(uint160).max) ok = false;
        a = address(uint160(w));
    }

    function _bool(address target, bytes memory data) internal view returns (bool ok, bool b) {
        uint256 w;
        (ok, w) = _word(target, data);
        if (w > 1) ok = false;
        b = w == 1;
    }

    function _hookGlobals(address hook) internal view returns (IArtCoinsHookV2.HookGlobals memory g) {
        (bool ok, bytes memory out) = hook.staticcall(abi.encodeCall(IArtCoinsHookV2.globals, ()));
        if (ok && out.length == 160) g = abi.decode(out, (IArtCoinsHookV2.HookGlobals));
    }

    function _hookInfo(address hook, bytes32 poolId) internal view returns (IArtCoinsHookV2.PoolInfo memory p) {
        (bool ok, bytes memory out) = hook.staticcall(abi.encodeCall(IArtCoinsHookV2.poolInfo, (poolId)));
        if (ok && out.length == 256) p = abi.decode(out, (IArtCoinsHookV2.PoolInfo));
    }

    function _hookSkim(address hook, bytes32 poolId) internal view returns (IArtCoinsHookV2.SkimConfig memory k) {
        (bool ok, bytes memory out) = hook.staticcall(abi.encodeCall(IArtCoinsHookV2.skimConfig, (poolId)));
        if (ok && out.length == 256) k = abi.decode(out, (IArtCoinsHookV2.SkimConfig));
    }

    function _deployment(address factory, address coin)
        internal
        view
        returns (bool ok, IArtCoinsFactoryV2.DeploymentInfoV2 memory info)
    {
        bytes memory out;
        (ok, out) = factory.staticcall(abi.encodeCall(IArtCoinsFactoryV2.deploymentInfo, (coin)));
        if (ok && out.length >= 288) info = abi.decode(out, (IArtCoinsFactoryV2.DeploymentInfoV2));
        else ok = false;
    }

    /// @notice the factory's `predictToken` through a staticcall that reports a failure instead of reverting
    function _predict(LaunchConfig memory c, address sender, address router, address core)
        internal
        view
        returns (bool ok, address coin)
    {
        bytes memory data =
            abi.encodeCall(IArtCoinsFactoryV2.predictToken, (sender, buildConfig(c, c.owner, router, core)));
        uint256 w;
        (ok, w) = _word(c.stack.factory, data);
        coin = address(uint160(w));
    }

    /// @notice the operator says the owner changed the coin since launch: unrestrict, lock, a new admin or a changed
    /// allowlist (COIN_CHANGED=1). a test overrides it
    function _coinChanged() internal view virtual returns (bool) {
        return vm.envOr("COIN_CHANGED", uint256(0)) == 1;
    }

    /// @notice the operator says the owner set, repointed, locked or handed over the router since launch
    /// (ROUTER_CHANGED=1). a test overrides it
    function _routerChanged() internal view virtual returns (bool) {
        return vm.envOr("ROUTER_CHANGED", uint256(0)) == 1;
    }

    /// @dev a row that is a failure until the operator names the change, then a warning
    function _soft(bool changed, string memory name, bool ok, string memory detail, string memory flag) internal {
        if (changed) _warn(string.concat("warn: ", name), ok, string.concat(flag, " set: ", detail));
        else _check(name, ok, detail);
    }

    // ------------------------------------------------------------------ the coin

    function _postCoin(LaunchConfig memory c, address core, address coin_, bytes32 poolId) internal {
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin_);
        _eq("coin: name equals the config", t.name(), c.name);
        _eq("coin: symbol equals the config", t.symbol(), c.symbol);
        _check(
            "coin: supply at most the config supply",
            t.totalSupply() <= c.supply,
            string.concat("supply ", vm.toString(t.totalSupply()))
        );
        _warn("warn: coin supply is the config supply", t.totalSupply() == c.supply, "coin was burned since launch");
        _eq("coin: launcher is the factory", t.launcher(), c.stack.factory);
        _eq("coin: canonical hook", t.canonicalHook(), c.stack.hook);
        _eq("coin: canonical pool id", t.canonicalPoolId(), poolId);
        _eq("coin: pool manager", t.poolManager(), c.stack.poolManager);
        _eq("coin: original admin is the config owner", t.originalAdmin(), c.owner);
        bool ch = _coinChanged();
        _soft(ch, "coin: admin is the config owner", t.admin() == c.owner, vm.toString(t.admin()), "COIN_CHANGED=1");
        _soft(ch, "coin: restricted as in the config", t.restricted() == c.restricted, "restricted()", "COIN_CHANGED=1");
        _postAllowlist(c, core, t, ch);
        _warn("warn: coin allowlist is not locked", !t.locked(), "locked(): the admin can no longer change the allowlist");
        _warn("warn: core holds no coin", t.balanceOf(core) == 0, "stray coin, the owner can call rescueCoin");
    }

    /// @dev the allowlist cannot be listed on chain. what is checked: the Core, the locker and the escrow are on it (the
    /// locker and the escrow pinned), every extra entry of the config is, and no other account of the system is
    function _postAllowlist(LaunchConfig memory c, address core, IArtCoinsTokenV2 t, bool ch) private {
        bool listed = t.isAllowed(core) && t.isAllowed(c.stack.locker) && t.isAllowed(c.stack.escrow);
        for (uint256 i; i < c.allowed.length; ++i) {
            listed = listed && t.isAllowed(c.allowed[i]);
        }
        _soft(ch, "coin: allowlist holds the Core, the locker, the escrow and the config entries", listed, "isAllowed", "COIN_CHANGED=1");
        _check(
            "coin: the locker and the escrow are pinned",
            t.isPinned(c.stack.locker) && t.isPinned(c.stack.escrow),
            "isPinned(locker), isPinned(escrow)"
        );
        address[11] memory off = [
            c.stack.feeSource,
            c.owner,
            c.creator,
            c.creatorPayee,
            c.stack.hook,
            c.stack.poolManager,
            c.stack.factory,
            c.mevModule,
            c.stack.auctionFactory,
            address(ICoreHouse(core).HOUSE()),
            ICoreHouse(core).controller()
        ];
        bool none = true;
        for (uint256 i; i < off.length; ++i) {
            none = none && !t.isAllowed(off[i]);
        }
        _soft(ch, "coin: allowlist holds none of router, owner, creator, payee, hook, factory, mev module, house, controller", none, "isAllowed", "COIN_CHANGED=1");
    }
}

interface ICoreHouse {
    function HOUSE() external view returns (address);
    function controller() external view returns (address);
}
