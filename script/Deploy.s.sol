// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CommonBase} from "forge-std/Base.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Core} from "../src/Core.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactory, IArtCoinsToken, IArtCoinsSkimHook} from "../src/interfaces/ArtCoins.sol";

/// @notice everything the deploy creates
struct Deployed {
    address core;
    address coin;
    address controller;
    PoolKey launchKey;
    bytes32 poolId;
}

/// @notice the deploy routine, shared by the script and by tests. call it from a broadcast or from a prank of
/// `deployer`. the controller and core addresses are predicted from the deployer nonce, the coin address from the
/// factory create2 formula, and every prediction is checked after creation. the deployer must be allowed to launch
/// on the live factory (it is deprecated, so only its owner or an address it marks admin may launch) and must hold
/// the factory deploy fee.
abstract contract SystemDeployer is CommonBase {
    // ------------------------------------------------------------------ launch parameters (docs/ARCHITECTURE.md section 2)

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    /// @dev tickIfToken0IsArtCoins. the coin is always currency1 against native eth, so the pool opens at the
    /// mirrored tick, about 40M coin per eth
    int24 internal constant START_TICK = -175_000;
    /// @dev the one position runs from the start tick to the highest tick that is a multiple of the spacing
    int24 internal constant POSITION_LOWER = -175_000;
    int24 internal constant POSITION_UPPER = 887_200;
    uint24 internal constant BASELINE_SKIM_BPS = 10_000; // of 100_000, so 10 points of volume
    uint16 internal constant BOUNTY_BPS = 9500; // of 10_000, so 9.5 points to the core and 0.5 to the creator
    uint24 internal constant MAX_REFERRAL_BPS = 0;
    uint24 internal constant LP_FEE = 0;
    uint24 internal constant SNIPER_START_BPS = 90_000;
    uint24 internal constant SNIPER_END_BPS = 10_000;
    uint32 internal constant SNIPER_SECONDS = 1800;
    uint16 internal constant TAX_BPS = 1500;
    uint16 internal constant TAX_BPS_MAX = 2000;
    string internal constant TOKEN_CODE_FILE = "script/data/ArtCoinsToken.creation.hex";

    /// @notice a created contract did not land at its predicted address
    error AddressMismatch(string what);
    /// @notice a read back value of the launched system is not what was configured
    error LaunchMismatch(string what);

    /// @notice deploys and launches the whole system
    /// @param deployer the address that sends every transaction. must be the broadcaster or the active prank
    /// @param owner the core owner and, after the launch, the token admin
    /// @param creator receives the creator share of every fee (0.5 points of volume) and the locker reward slot
    /// @param name coin name
    /// @param symbol coin symbol
    /// @param userSalt salt of the coin address. the coin address depends on it, the deployer and the tax config
    function deploySystem(
        address deployer,
        address owner,
        address creator,
        string memory name,
        string memory symbol,
        bytes32 userSalt
    ) internal returns (Deployed memory d) {
        uint64 nonce = vm.getNonce(deployer);
        address controllerAt = vm.computeCreateAddress(deployer, nonce);
        address coreAt = vm.computeCreateAddress(deployer, nonce + 1);
        address coinAt = predictCoin(deployer, coreAt, name, symbol, userSalt);

        d.controller = address(new ControllerV1(coreAt));
        d.core = address(new Core(owner, coinAt, d.controller));
        if (d.controller != controllerAt) revert AddressMismatch("controller");
        if (d.core != coreAt) revert AddressMismatch("core");

        IArtCoinsFactory factory = IArtCoinsFactory(Mainnet.ARTCOINS_FACTORY);
        d.coin = factory.deployTokenWithProtocolBpsAndTax{value: factory.deployFee()}(
            buildConfig(deployer, coreAt, creator, name, symbol, userSalt), 0, buildTaxConfig(coreAt)
        );
        if (d.coin != coinAt) revert AddressMismatch("coin");

        d.launchKey = poolKeyOf(d.coin);
        d.poolId = keccak256(abi.encode(d.launchKey));

        // the extension slot is empty and locked for good, then the owner takes the token admin role
        IArtCoinsSkimHook(Mainnet.SKIM_HOOK).lockPoolExtension(d.launchKey);
        IArtCoinsToken(d.coin).updateAdmin(owner);
        verifyLaunch(d, owner, creator);
    }

    // ------------------------------------------------------------------ the config builder, used by script and tests

    /// @notice the pool key of a coin: native eth against the coin, dynamic fee flag, spacing 200, the skim hook
    function poolKeyOf(address coin) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: Mainnet.POOL_FEE,
            tickSpacing: Mainnet.TICK_SPACING,
            hooks: IHooks(Mainnet.SKIM_HOOK)
        });
    }

    /// @notice the factory config of the launch. the token admin is the deployer until the launch is done
    function buildConfig(
        address tokenAdmin,
        address core,
        address creator,
        string memory name,
        string memory symbol,
        bytes32 userSalt
    ) internal pure returns (IArtCoinsFactory.DeploymentConfig memory c) {
        c.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: name,
            symbol: symbol,
            salt: userSalt,
            image: "",
            metadata: "",
            context: "",
            totalSupply: SUPPLY,
            renderer: address(0)
        });
        // SkimHookFeeData. the referral payout is the core, which takes a payable `notify` and books the eth later
        bytes memory feeData =
            abi.encode(BASELINE_SKIM_BPS, BOUNTY_BPS, MAX_REFERRAL_BPS, LP_FEE, core, creator, core, address(0));
        c.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: Mainnet.SKIM_HOOK,
            pairedToken: address(0),
            tickIfToken0IsArtCoins: START_TICK,
            tickSpacing: Mainnet.TICK_SPACING,
            poolData: abi.encode(address(0), bytes(""), feeData)
        });
        address[] memory admins = new address[](1);
        admins[0] = Mainnet.DEAD;
        address[] memory recipients = new address[](1);
        recipients[0] = creator;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000;
        int24[] memory lower = new int24[](1);
        lower[0] = POSITION_LOWER;
        int24[] memory upper = new int24[](1);
        upper[0] = POSITION_UPPER;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;
        c.lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: Mainnet.LP_LOCKER,
            rewardAdmins: admins,
            rewardRecipients: recipients,
            rewardBps: rewardBps,
            tickLower: lower,
            tickUpper: upper,
            positionBps: positionBps,
            lockerData: ""
        });
        c.mevModuleConfig = IArtCoinsFactory.MevModuleConfig({
            mevModule: Mainnet.MEV_LINEAR_SKIM,
            mevModuleData: abi.encode(SNIPER_START_BPS, SNIPER_END_BPS, SNIPER_SECONDS)
        });
        c.sniperFeeConfig = IArtCoinsFactory.SniperFeeConfig({recipient: address(0), lockRecipient: false});
        c.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](0);
    }

    /// @notice the venue tax config of the coin, the same 44 venues as the live 111 coin. the core is exempt
    function buildTaxConfig(address core) internal pure returns (IArtCoinsFactory.TaxConfig memory t) {
        t.enabled = true;
        t.taxBps = TAX_BPS;
        t.taxBpsMax = TAX_BPS_MAX;
        t.burnAddress = Mainnet.DEAD;
        t.poolManager = Mainnet.POOL_MANAGER;
        t.canonicalHook = Mainnet.SKIM_HOOK;
        t.pairedToken = address(0);
        t.canonicalPoolFee = Mainnet.POOL_FEE;
        t.canonicalTickSpacing = Mainnet.TICK_SPACING;
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
    function tokenCreationCode() internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(TOKEN_CODE_FILE));
    }

    /// @notice the address the factory will give the coin: create2 from the factory with the salt
    /// `keccak256(abi.encode(tokenAdmin, userSalt))` and the token creation code plus its constructor arguments
    /// (which include the whole tax config, so the core address is an input)
    function predictCoin(address tokenAdmin, address core, string memory name, string memory symbol, bytes32 userSalt)
        internal
        view
        returns (address)
    {
        bytes memory initcode = abi.encodePacked(
            tokenCreationCode(),
            abi.encode(name, symbol, SUPPLY, tokenAdmin, "", "", "", address(0), buildTaxConfig(core))
        );
        bytes32 salt = keccak256(abi.encode(tokenAdmin, userSalt));
        return vm.computeCreate2Address(salt, keccak256(initcode), Mainnet.ARTCOINS_FACTORY);
    }

    // ------------------------------------------------------------------ read back

    /// @notice checks the launched system against the config. reverts on any difference
    function verifyLaunch(Deployed memory d, address owner, address creator) internal view {
        IArtCoinsToken token = IArtCoinsToken(d.coin);
        IArtCoinsSkimHook hook = IArtCoinsSkimHook(Mainnet.SKIM_HOOK);
        if (token.totalSupply() != SUPPLY) revert LaunchMismatch("supply");
        if (token.admin() != owner) revert LaunchMismatch("admin");
        if (token.canonicalPoolId() != d.poolId) revert LaunchMismatch("pool id");
        if (!token.isTaxExempt(d.core)) revert LaunchMismatch("core exempt");
        if (token.taxBps() != TAX_BPS || token.taxBpsMax() != TAX_BPS_MAX) revert LaunchMismatch("tax");
        if (!hook.poolExtensionLocked(d.poolId)) revert LaunchMismatch("extension slot");
        (uint24 base, uint16 bounty, uint24 maxRef, uint24 lpFee, address bountyTo, address protoTo,,) =
            hook.skimConfig(d.poolId);
        if (base != BASELINE_SKIM_BPS || bounty != BOUNTY_BPS || maxRef != MAX_REFERRAL_BPS || lpFee != LP_FEE) {
            revert LaunchMismatch("skim config");
        }
        if (bountyTo != d.core || protoTo != creator) revert LaunchMismatch("skim recipients");
    }
}

/// @notice `forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast` with OWNER, CREATOR,
/// COIN_NAME, COIN_SYMBOL and COIN_SALT in the environment. the broadcaster must be allowed to launch on the
/// artcoins factory and hold its deploy fee
///
/// launch runbook (the predicted coin address ignores the pool config, so a copy of the launch made first by
/// anyone else would leave the Core bound to a pool that never pays it):
/// 1. keep the artcoins factory deprecated. a stranger cannot launch while it is.
/// 2. the factory owner enables only the deployer address with `setAdmin(deployer, true)`.
/// 3. broadcast through a private relay, never a public mempool.
/// 4. verify the returned coin equals the prediction (the script reverts on a mismatch) and read back the config.
/// 5. the factory owner revokes the deployer with `setAdmin(deployer, false)`, because an admin can also change
///    hooks, lockers and mev modules and claim team fees.
contract Deploy is Script, SystemDeployer {
    /// @dev the predicted coin address already has code, so someone launched first or the salt was reused
    error CoinAlreadyDeployed(address coin);

    /// @notice runs the deploy as the broadcaster
    function run() external returns (Deployed memory d) {
        address owner = vm.envAddress("OWNER");
        address creator = vm.envAddress("CREATOR");
        string memory name = vm.envString("COIN_NAME");
        string memory symbol = vm.envString("COIN_SYMBOL");
        bytes32 userSalt = vm.envBytes32("COIN_SALT");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        // preflight: refuse to deploy a Core against a coin address that is already taken
        address coreAt = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        address coinAt = predictCoin(deployer, coreAt, name, symbol, userSalt);
        if (coinAt.code.length != 0) revert CoinAlreadyDeployed(coinAt);
        d = deploySystem(deployer, owner, creator, name, symbol, userSalt);
        vm.stopBroadcast();

        console.log("core", d.core);
        console.log("coin", d.coin);
        console.log("controller", d.controller);
    }
}
