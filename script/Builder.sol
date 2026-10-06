// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Stack, Mainnet} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactory} from "../src/interfaces/ArtCoins.sol";
import {LaunchConfig, ConfigReader} from "./LaunchConfig.sol";

/// @notice builds the factory config, the tax config and the coin address prediction of a launch from a
/// `LaunchConfig`. pure of any live state, shared by the deploy, the preflight, the postflight and the tests
abstract contract SystemBuilder is ConfigReader {
    // ------------------------------------------------------------------ the config builder, used by script and tests

    /// @notice the pool key of a coin: native eth against the coin, dynamic fee flag, spacing 200, the skim hook
    function poolKeyOf(address coin, Stack memory s) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: s.poolFee,
            tickSpacing: s.tickSpacing,
            hooks: IHooks(s.hook)
        });
    }

    /// @notice the factory config of the launch. the token admin is the deployer until the launch is done
    function buildConfig(LaunchConfig memory l, address tokenAdmin, address core)
        internal
        pure
        returns (IArtCoinsFactory.DeploymentConfig memory c)
    {
        address creator = l.creator;
        c.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: l.name,
            symbol: l.symbol,
            salt: l.salt,
            image: "",
            metadata: "",
            context: "",
            totalSupply: l.supply,
            renderer: address(0)
        });
        // SkimHookFeeData. the referral payout is the core, which takes a payable `notify` and books the eth later
        bytes memory feeData =
            abi.encode(l.baselineSkimBps, l.bountyBps, l.maxReferralBps, l.lpFee, core, creator, core, address(0));
        c.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: l.stack.hook,
            pairedToken: address(0),
            tickIfToken0IsArtCoins: l.startTick,
            tickSpacing: l.stack.tickSpacing,
            poolData: abi.encode(address(0), bytes(""), feeData)
        });
        address[] memory admins = new address[](1);
        admins[0] = Mainnet.DEAD;
        address[] memory recipients = new address[](1);
        recipients[0] = creator;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000;
        int24[] memory lower = new int24[](1);
        lower[0] = l.positionLower;
        int24[] memory upper = new int24[](1);
        upper[0] = l.positionUpper;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;
        c.lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: l.stack.locker,
            rewardAdmins: admins,
            rewardRecipients: recipients,
            rewardBps: rewardBps,
            tickLower: lower,
            tickUpper: upper,
            positionBps: positionBps,
            lockerData: ""
        });
        c.mevModuleConfig = IArtCoinsFactory.MevModuleConfig({
            mevModule: l.mevModule, mevModuleData: abi.encode(l.sniperStartBps, l.sniperEndBps, l.sniperSeconds)
        });
        c.sniperFeeConfig = IArtCoinsFactory.SniperFeeConfig({recipient: address(0), lockRecipient: false});
        c.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](0);
    }

    /// @notice the venue tax config of the coin, the same 44 venues as the live 111 coin. the core is exempt
    function buildTaxConfig(LaunchConfig memory l, address core)
        internal
        pure
        returns (IArtCoinsFactory.TaxConfig memory t)
    {
        t.enabled = true;
        t.taxBps = l.taxBps;
        t.taxBpsMax = l.taxBpsMax;
        t.burnAddress = l.taxBurn;
        t.poolManager = l.stack.poolManager;
        t.canonicalHook = l.stack.hook;
        t.pairedToken = address(0);
        t.canonicalPoolFee = l.stack.poolFee;
        t.canonicalTickSpacing = l.stack.tickSpacing;
        t.exempt = new address[](1);
        t.exempt[0] = core;

        t.venues = _venues();
    }

    /// @dev the 44 venues: for each counter token (weth, usdc, usdt, dai) three v2 factories (uniswap, sushiswap,
    /// pancakeswap) and two v3 factories (uniswap with tiers 100, 500, 3000, 10000, pancake pool deployer with
    /// tiers 100, 500, 2500, 10000)
    function _venues() private pure returns (IArtCoinsFactory.TaxVenue[] memory v) {
        v = new IArtCoinsFactory.TaxVenue[](44);
        uint256 n;
        for (uint256 c; c < 4; ++c) {
            address counter = _counter(c);
            for (uint256 f; f < 3; ++f) {
                (address factory, bytes32 hash) = _v2(f);
                v[n++] = IArtCoinsFactory.TaxVenue(1, factory, hash, counter, 0);
            }
            for (uint256 f; f < 2; ++f) {
                (address factory, bytes32 hash) = _v3(f);
                for (uint256 i; i < 4; ++i) {
                    v[n++] = IArtCoinsFactory.TaxVenue(2, factory, hash, counter, _tier(f, i));
                }
            }
        }
    }

    function _counter(uint256 i) private pure returns (address) {
        if (i == 0) return Mainnet.WETH;
        if (i == 1) return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // usdc
        if (i == 2) return 0xdAC17F958D2ee523a2206206994597C13D831ec7; // usdt
        return 0x6B175474E89094C44Da98b954EedeAC495271d0F; // dai
    }

    function _v2(uint256 i) private pure returns (address factory, bytes32 initCodeHash) {
        if (i == 0) {
            return (
                0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f, // uniswap v2
                0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f
            );
        }
        if (i == 1) {
            return (
                0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac, // sushiswap
                0xe18a34eb0e04b04f7a0ac29a6e80748dca96319b42c54d679cb821dca90c6303
            );
        }
        return (
            0x1097053Fd2ea711dad45caCcc45EfF7548fCB362, // pancakeswap v2
            0x57224589c67f3f30a6b0d7a1b54cf3153ab84563bc609ef41dfb34f8b2974d2d
        );
    }

    function _v3(uint256 i) private pure returns (address factory, bytes32 initCodeHash) {
        if (i == 0) {
            return (
                0x1F98431c8aD98523631AE4a59f267346ea31F984, // uniswap v3 factory
                0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54
            );
        }
        return (
            0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9, // pancakeswap v3 pool deployer
            0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2
        );
    }

    function _tier(uint256 factory, uint256 i) private pure returns (uint24) {
        if (i == 0) return 100;
        if (i == 1) return 500;
        if (i == 2) return factory == 0 ? 3000 : 2500;
        return 10_000;
    }

    // ------------------------------------------------------------------ prediction

    /// @notice the exact creation bytecode of the live `ArtCoinsToken` implementation, without constructor
    /// arguments. it is read from script/data/ArtCoinsToken.creation.hex. that file is the prefix of the initcode of
    /// the live 111 coin's launch (the coin at 0x61C9d89fe1212F6b55fF888816A151463287B8ae, built from the sourcify
    /// verified creation bytecode, with the 111 constructor arguments stripped). the same bytecode is checked by
    /// every launch: the prediction below must equal the address the real factory returns
    function tokenCreationCode(string memory file) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(file));
    }

    /// @notice the address the factory will give the coin: create2 from the factory with the salt
    /// `keccak256(abi.encode(tokenAdmin, userSalt))` and the token creation code plus its constructor arguments
    /// (which include the whole tax config, so the core address is an input)
    function predictCoin(LaunchConfig memory l, address tokenAdmin, address core) internal view returns (address) {
        return vm.computeCreate2Address(
            keccak256(abi.encode(tokenAdmin, l.salt)), keccak256(coinInitcode(l, tokenAdmin, core)), l.stack.factory
        );
    }

    /// @notice the full initcode of the coin: creation code plus the constructor arguments
    function coinInitcode(LaunchConfig memory l, address tokenAdmin, address core)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            tokenCreationCode(l.tokenCodeFile),
            abi.encode(l.name, l.symbol, l.supply, tokenAdmin, "", "", "", address(0), buildTaxConfig(l, core))
        );
    }
}
