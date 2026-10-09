// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Stack} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig, ConfigReader} from "./LaunchConfig.sol";

/// @notice builds the v2 factory config and the coin address prediction of a launch from a `LaunchConfig`
/// (docs/FLOW.md 10.4). shared by the deploy, the preflight, the postflight and the tests
abstract contract SystemBuilder is ConfigReader {
    /// @notice the pool key of a coin: native eth against the coin, dynamic fee flag, spacing 200, the v2 hook
    function poolKeyOf(address coin, Stack memory s) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: s.poolFee,
            tickSpacing: s.tickSpacing,
            hooks: IHooks(s.hook)
        });
    }

    /// @notice the v2 factory config of the launch. the token admin is the owner. the bounty recipient is the fee
    /// router and the one project locker slot is the creator (the lp fee is 0, so it earns nothing today). the protocol
    /// slot is appended by the factory, so the project slot is `10_000 - protocolBps`. the coin is restricted and its
    /// allowlist holds the Core (docs/FLOW.md 29) and `l.allowed`, nothing else
    function buildConfig(LaunchConfig memory l, address tokenAdmin, address router, address core)
        internal
        pure
        returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory c)
    {
        c.token = IArtCoinsFactoryV2.TokenConfigV2({
            tokenAdmin: tokenAdmin,
            name: l.name,
            symbol: l.symbol,
            salt: l.salt,
            image: "",
            description: "",
            totalSupply: l.supply,
            renderer: address(0)
        });
        c.pool = IArtCoinsFactoryV2.PoolConfigV2({
            hook: l.stack.hook,
            tickIfToken0IsCoin: l.startTick,
            tickSpacing: l.stack.tickSpacing,
            extension: address(0),
            extensionData: ""
        });
        c.fee = IArtCoinsFactoryV2.FeeConfigV2({
            lpFeePips: l.lpFeePips,
            baselineSkimBps: l.baselineSkimBps,
            bountyBps: l.bountyBps,
            maxReferralBpsOfVolume: l.maxReferralBps,
            bountyRecipient: payable(router)
        });
        address[] memory recipients = new address[](1);
        recipients[0] = l.creator;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000 - l.protocolBps;
        int24[] memory lower = new int24[](1);
        lower[0] = l.positionLower;
        int24[] memory upper = new int24[](1);
        upper[0] = l.positionUpper;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;
        c.locker = IArtCoinsFactoryV2.LockerConfigV2({
            locker: l.stack.locker,
            rewardRecipients: recipients,
            rewardBps: rewardBps,
            tickLower: lower,
            tickUpper: upper,
            positionBps: positionBps
        });
        c.mev = IArtCoinsFactoryV2.MevConfigV2({
            module: l.mevModule, startingSkimBps: l.sniperStartBps, windowSeconds: l.sniperSeconds
        });
        address[] memory allowed = new address[](l.allowed.length + 1);
        allowed[0] = core;
        for (uint256 i; i < l.allowed.length; ++i) {
            allowed[i + 1] = l.allowed[i];
        }
        c.restriction = IArtCoinsFactoryV2.RestrictionConfigV2({restricted: l.restricted, allowed: allowed});
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](0);
    }

    /// @notice keccak256 of the canonical abi encoding of the whole launch config. it covers every value the launch
    /// depends on (the overrides included) and none of the machine (not the deployer). the operator signs off this
    /// one value: preflight prints it, `Deploy` needs it in CONFIG_HASH and postflight prints it again
    function configHash(LaunchConfig memory l) internal pure returns (bytes32 h) {
        // `stack.feeSource` is the router the deploy creates: derived, never signed, so the hash leaves it out
        address fs = l.stack.feeSource;
        l.stack.feeSource = address(0);
        h = keccak256(abi.encode(l));
        l.stack.feeSource = fs;
    }

    /// @notice the address the v2 factory will give the coin, from its own `predictToken`. it depends on the sender
    /// (the owner, who signs the launch), the whole config (router and Core included) and mutable factory state
    /// (the default allowlist and the hook escrow), so read it right before the launch
    function predictCoin(LaunchConfig memory l, address sender, address router, address core)
        internal
        view
        returns (address)
    {
        return IArtCoinsFactoryV2(l.stack.factory).predictToken(sender, buildConfig(l, l.owner, router, core));
    }
}
