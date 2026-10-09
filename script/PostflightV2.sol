// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IArtCoinsFactoryV2, IArtCoinsHookV2, IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemBuilder} from "./Builder.sol";
import {Report} from "./Report.sol";

/// @notice the safe readers and the coin side of the postflight (docs/FLOW.md 10.4): every read is a staticcall that
/// reports a failure instead of reverting, so a wrong address turns into a failed row and never aborts the table
abstract contract PostflightV2 is SystemBuilder, Report {
    // ------------------------------------------------------------------ runtime code identity

    /// @dev json objects decode in key order: length, then start
    struct IdRef {
        uint256 length;
        uint256 start;
    }

    /// @dev the {start, length} pairs (packed start << 128 | length) of the immutable slots and the library address
    /// slots of an artifact. the artifact json is large (a postflight runs hundreds of times in the mutation matrix, and
    /// a snapshot revert would drop contract storage), so the masks, the length and the masked hash of the compiled
    /// runtime code are read once and kept in the process environment, which a snapshot revert does not touch
    function _idCollect(string memory j, string memory path, uint256[] memory acc) private view returns (uint256[] memory) {
        IdRef[] memory refs = abi.decode(vm.parseJson(j, path), (IdRef[]));
        uint256[] memory out = new uint256[](acc.length + refs.length);
        for (uint256 i; i < acc.length; ++i) {
            out[i] = acc[i];
        }
        for (uint256 i; i < refs.length; ++i) {
            out[acc.length + i] = (refs[i].start << 128) | refs[i].length;
        }
        return out;
    }

    function _idKey(string memory name, string memory what) private pure returns (string memory) {
        return string.concat("POSTFLIGHT_CODE_", what, "_", name);
    }

    /// @dev reads the artifact once: the slots to mask and the hash of the masked compiled runtime code
    function _idLoad(string memory name) private {
        string memory j = vm.readFile(string.concat("out/", name, ".sol/", name, ".json"));
        uint256[] memory m = new uint256[](0);
        string[] memory ids = vm.parseJsonKeys(j, ".deployedBytecode.immutableReferences");
        for (uint256 i; i < ids.length; ++i) {
            m = _idCollect(j, string.concat(".deployedBytecode.immutableReferences.", ids[i]), m);
        }
        string[] memory files = vm.parseJsonKeys(j, ".deployedBytecode.linkReferences");
        for (uint256 i; i < files.length; ++i) {
            string memory fp = string.concat(".deployedBytecode.linkReferences['", files[i], "']");
            string[] memory libs = vm.parseJsonKeys(j, fp);
            for (uint256 k; k < libs.length; ++k) {
                m = _idCollect(j, string.concat(fp, ".", libs[k]), m);
            }
        }
        bytes memory built = vm.getDeployedCode(string.concat(name, ".sol:", name));
        _idZero(built, m);
        string memory list;
        for (uint256 i; i < m.length; ++i) {
            list = i == 0 ? vm.toString(m[i]) : string.concat(list, ",", vm.toString(m[i]));
        }
        vm.setEnv(_idKey(name, "LEN"), vm.toString(built.length));
        vm.setEnv(_idKey(name, "HASH"), vm.toString(keccak256(built)));
        vm.setEnv(_idKey(name, "MASK"), list);
    }

    function _idZero(bytes memory code, uint256[] memory m) private pure {
        for (uint256 i; i < m.length; ++i) {
            uint256 start = m[i] >> 128;
            uint256 len = uint128(m[i]);
            require(start + len <= code.length, "mask outside the code");
            // calldata past its end reads as zeros: one copy zeroes the whole range
            assembly {
                calldatacopy(add(add(code, 0x20), start), calldatasize(), len)
            }
        }
    }

    /// @notice whether the runtime code at `at` is the runtime code of the compiled artifact `name` (`Core`,
    /// `ControllerV1`), the immutable slots and the linked library address masked in both (the method of
    /// test/BuildIdentity.t.sol). false when `at` has no code. the artifact side is read once and kept, and the copy
    /// of the live code is released, so a run of hundreds of postflights stays cheap
    function runtimeMatchesArtifact(address at, string memory name) internal returns (bool ok) {
        if (at.code.length == 0) return false;
        if (!vm.envExists(_idKey(name, "HASH"))) _idLoad(name);
        uint256[] memory m = vm.envUint(_idKey(name, "MASK"), ",");
        bytes32 want = vm.envBytes32(_idKey(name, "HASH"));
        uint256 len = vm.envUint(_idKey(name, "LEN"));
        uint256 fmp;
        assembly {
            fmp := mload(0x40)
        }
        bytes memory live = at.code;
        if (live.length == len) {
            _idZero(live, m);
            ok = keccak256(live) == want;
        }
        assembly {
            mstore(0x40, fmp)
        }
    }

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
        if (ok && out.length == 64) g = abi.decode(out, (IArtCoinsHookV2.HookGlobals));
    }

    function _hookInfo(address hook, bytes32 poolId) internal view returns (IArtCoinsHookV2.PoolInfo memory p) {
        (bool ok, bytes memory out) = hook.staticcall(abi.encodeCall(IArtCoinsHookV2.poolInfo, (poolId)));
        if (ok && out.length == 256) p = abi.decode(out, (IArtCoinsHookV2.PoolInfo));
    }

    function _hookSkim(address hook, bytes32 poolId) internal view returns (IArtCoinsHookV2.SkimConfig memory k) {
        (bool ok, bytes memory out) = hook.staticcall(abi.encodeCall(IArtCoinsHookV2.skimConfig, (poolId)));
        if (ok && out.length == 192) k = abi.decode(out, (IArtCoinsHookV2.SkimConfig));
    }

    function _deployment(address factory, address coin)
        internal
        view
        returns (bool ok, IArtCoinsFactoryV2.DeploymentInfoV2 memory info)
    {
        bytes memory out;
        (ok, out) = factory.staticcall(abi.encodeCall(IArtCoinsFactoryV2.deploymentInfo, (coin)));
        if (ok && out.length >= 416) info = abi.decode(out, (IArtCoinsFactoryV2.DeploymentInfoV2));
        else ok = false;
    }

    /// @notice the factory's `predictToken` through a staticcall that reports a failure instead of reverting
    function _predict(LaunchConfig memory c, address sender, address router)
        internal
        view
        returns (bool ok, address coin)
    {
        bytes memory data =
            abi.encodeCall(IArtCoinsFactoryV2.predictToken, (sender, buildConfig(c, c.owner, router)));
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
        _warn(
            "warn: coin supply is the config supply (less the locker dust)",
            t.totalSupply() + 1e6 >= c.supply,
            "coin was burned since launch"
        );
        _eq("coin: launcher is the factory", t.launcher(), c.stack.factory);
        _eq("coin: canonical hook", t.canonicalHook(), c.stack.hook);
        _eq("coin: canonical pool id", t.canonicalPoolId(), poolId);
        _eq("coin: pool manager", t.poolManager(), c.stack.poolManager);
        bool ch = _coinChanged();
        _soft(ch, "coin: admin is the config owner", t.admin() == c.owner, vm.toString(t.admin()), "COIN_CHANGED=1");
        _soft(ch, "coin: restricted as in the config", t.restricted() == c.restricted, "restricted()", "COIN_CHANGED=1");
        _soft(
            ch,
            "coin: image and description are empty as launched",
            bytes(t.imageUrl()).length == 0 && bytes(t.description()).length == 0,
            string.concat("image ", t.imageUrl(), " description ", t.description()),
            "COIN_CHANGED=1"
        );
        _soft(ch, "coin: no metadata renderer", t.metadataRenderer() == address(0), vm.toString(t.metadataRenderer()), "COIN_CHANGED=1");
        _postAllowlist(c, core, t, ch);
        _warn("warn: coin allowlist is not locked", !t.allowlistLocked(), "allowlistLocked(): the admin can no longer change the allowlist");
        _warn(
            "warn: coin fee recipients are not locked",
            !t.recipientsLocked(),
            "recipientsLocked(): the admin can no longer repoint the hook bounty recipient or a locker reward recipient"
        );
    }

    /// @dev the allowlist cannot be listed on chain. what is checked: the locker and the escrow are on it (pinned), every
    /// extra entry of the config is, and no account of the system is: the Core is off it, the buyback take passes the
    /// restriction through the transfer allowance the hook grants
    function _postAllowlist(LaunchConfig memory c, address core, IArtCoinsTokenV2 t, bool ch) private {
        bool listed = t.isAllowed(c.stack.locker) && t.isAllowed(c.stack.escrow);
        for (uint256 i; i < c.allowed.length; ++i) {
            listed = listed && t.isAllowed(c.allowed[i]);
        }
        _soft(ch, "coin: allowlist holds the locker, the escrow and the config entries", listed, "isAllowed", "COIN_CHANGED=1");
        _check(
            "coin: the locker and the escrow are pinned",
            t.isPinned(c.stack.locker) && t.isPinned(c.stack.escrow),
            "isPinned(locker), isPinned(escrow)"
        );
        address[12] memory off = [
            core,
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
        _soft(ch, "coin: allowlist holds none of core, router, owner, creator, payee, hook, factory, mev module, house, controller", none, "isAllowed", "COIN_CHANGED=1");
    }
}

interface ICoreHouse {
    function HOUSE() external view returns (address);
    function controller() external view returns (address);
}
