// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {IAuctionFactory, IAuctionHouse} from "../src/interfaces/AuctionHouse.sol";
import {
    IArtCoinsFactory,
    IArtCoinsSkimHook,
    IArtCoinsLocker,
    IArtCoinsMevSkim,
    IArtCoinsToken
} from "../src/interfaces/ArtCoins.sol";

/// the launch of the coin through the live artcoins factory and everything it must read back as
contract LaunchTest is Fixture {
    IArtCoinsSkimHook internal constant HOOK = IArtCoinsSkimHook(Mainnet.SKIM_HOOK);

    function test_predictedCoinEqualsDeployed() public view {
        assertEq(predictCoin(deployer, address(core), "Fixture Coin", "FIXT", FIXTURE_SALT), address(coin));
        // the prediction depends on the admin, the salt, the core (tax exempt list) and the name
        assertTrue(predictCoin(owner, address(core), "Fixture Coin", "FIXT", FIXTURE_SALT) != address(coin));
        assertTrue(predictCoin(deployer, address(core), "Fixture Coin", "FIXT", bytes32(0)) != address(coin));
        assertTrue(predictCoin(deployer, address(ctl), "Fixture Coin", "FIXT", FIXTURE_SALT) != address(coin));
        assertTrue(predictCoin(deployer, address(core), "Other", "FIXT", FIXTURE_SALT) != address(coin));
    }

    function test_wiring() public view {
        assertEq(core.COIN(), address(coin));
        assertEq(core.OWNER(), owner);
        assertEq(core.controller(), address(ctl));
        assertEq(address(ctl.CORE()), address(core));
        assertEq(core.HOOK(), Mainnet.SKIM_HOOK);
    }

    function test_supplyAllInThePool() public view {
        assertEq(coin.totalSupply(), 1_000_000_000e18);
        // the pool manager holds the supply as the one locker position, less liquidity rounding dust that stays in
        // the locker (3551 wei at the pin). nobody else holds any
        uint256 dust = coin.balanceOf(Mainnet.LP_LOCKER);
        assertLt(dust, 1e6, "rounding dust only");
        assertEq(coin.balanceOf(Mainnet.POOL_MANAGER) + dust, 1_000_000_000e18);
        assertEq(coin.balanceOf(deployer), 0);
        assertEq(coin.balanceOf(address(core)), 0);
        assertEq(coin.balanceOf(Mainnet.ARTCOINS_FACTORY), 0);

        IArtCoinsLocker.TokenRewardInfo memory info = IArtCoinsLocker(Mainnet.LP_LOCKER).tokenRewards(address(coin));
        assertEq(info.numPositions, 1, "one position");
        assertEq(info.rewardBps.length, 1);
        assertEq(info.rewardBps[0], 10_000);
        assertEq(info.rewardRecipients[0], creator);
        assertEq(info.rewardAdmins[0], DEAD, "recipient is permanent");
        assertEq(abi.encode(info.poolKey), abi.encode(launchKey));
    }

    function test_poolKeyAndId() public view {
        assertEq(Currency.unwrap(launchKey.currency0), address(0));
        assertEq(Currency.unwrap(launchKey.currency1), address(coin));
        assertEq(launchKey.fee, 0x800000);
        assertEq(launchKey.tickSpacing, 200);
        assertEq(address(launchKey.hooks), Mainnet.SKIM_HOOK);
        assertEq(poolId, keccak256(abi.encode(launchKey)));
        assertEq(coin.canonicalPoolId(), poolId, "the token computed the same pool id");
        (uint160 sqrtPrice, int24 tick,,) = StateLibrary.getSlot0(PM, PoolId.wrap(poolId));
        assertTrue(sqrtPrice != 0, "pool initialized");
        // the coin is currency1 against eth, so the pool opens at the mirrored tick
        assertEq(tick, 175_000);
    }

    function test_skimConfigReadBack() public {
        (
            uint24 base,
            uint16 bounty,
            uint24 maxRef,
            uint24 lpFee,
            address bountyTo,
            address protocolTo,
            address referralTo,
            address quote
        ) = HOOK.skimConfig(poolId);
        assertEq(base, 10_000);
        assertEq(bounty, 9500);
        assertEq(maxRef, 0);
        assertEq(lpFee, 0);
        assertEq(bountyTo, address(core), "bounty goes to the core");
        assertEq(protocolTo, creator, "protocol leg goes to the creator escrow");
        assertEq(referralTo, address(core), "referral payout is the core");
        assertEq(quote, address(0));
        assertTrue(HOOK.poolTaxEnabled(poolId), "canonical pool attests the tax budget");
        assertTrue(HOOK.mevModuleEnabled(poolId));
        // the anti sniper module is at the start of its decay: 90 percent of volume in the first block
        assertEq(IArtCoinsMevSkim(Mainnet.MEV_LINEAR_SKIM).currentSkimBps(poolId), 90_000);
        _skipSniperWindow();
        assertEq(IArtCoinsMevSkim(Mainnet.MEV_LINEAR_SKIM).currentSkimBps(poolId), 10_000);
    }

    function test_taxConfigReadBack() public view {
        assertTrue(coin.taxEnabled());
        assertEq(coin.taxBps(), 1500);
        assertEq(coin.taxBpsMax(), 2000);
        assertEq(coin.taxBurnAddress(), DEAD);
        assertEq(coin.canonicalHook(), Mainnet.SKIM_HOOK);
        assertEq(coin.taxPoolManager(), Mainnet.POOL_MANAGER);
        assertTrue(coin.isTaxExempt(address(core)), "core is exempt");
        assertFalse(coin.isTaxExempt(creator));
        assertFalse(coin.isTaxExempt(owner));
        assertTrue(coin.isTaxVenue(Mainnet.POOL_MANAGER), "every v4 pool is a venue");
        assertFalse(coin.isTaxVenue(address(core)));
    }

    /// the 44 venues of the live 111 coin, each derived here from its factory, init code hash and counter token
    function test_taxVenues() public view {
        IArtCoinsFactory.TaxVenue[] memory venues = buildTaxConfig(address(core)).venues;
        assertEq(venues.length, 44);
        for (uint256 i; i < venues.length; ++i) {
            IArtCoinsFactory.TaxVenue memory v = venues[i];
            (address t0, address t1) =
                address(coin) < v.counterToken ? (address(coin), v.counterToken) : (v.counterToken, address(coin));
            bytes32 salt = v.kind == 1 ? keccak256(abi.encodePacked(t0, t1)) : keccak256(abi.encode(t0, t1, v.v3Fee));
            address pair = vm.computeCreate2Address(salt, v.initCodeHash, v.factory);
            assertTrue(coin.isTaxVenue(pair), "venue not registered");
        }
    }

    function test_adminHandover() public {
        assertEq(coin.admin(), owner, "token admin ends as the owner");
        assertEq(coin.originalAdmin(), deployer);
        // the deployer no longer has any admin power
        vm.startPrank(deployer);
        vm.expectRevert();
        coin.setTaxBps(0);
        vm.expectRevert();
        HOOK.setMaxReferralBpsOfVolume(launchKey, 100);
        vm.stopPrank();
        // the owner keeps the tax rate and the referral cap
        vm.startPrank(owner);
        coin.setTaxBps(1000);
        assertEq(coin.taxBps(), 1000);
        vm.expectRevert();
        coin.setTaxBps(2001);
        HOOK.setMaxReferralBpsOfVolume(launchKey, 100);
        vm.stopPrank();
    }

    function test_extensionSlotLocked() public {
        assertTrue(HOOK.poolExtensionLocked(poolId));
        assertEq(HOOK.poolExtension(poolId), address(0));
        // not even the token admin can fill it, whatever address it names
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("PoolExtensionLockedErr()")));
        IArtCoinsExtensionSetter(address(HOOK)).setPoolExtension(launchKey, address(0xBEEF), "");
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("PoolExtensionLockedErr()")));
        HOOK.lockPoolExtension(launchKey);
    }

    // ------------------------------------------------------------------ launch failures

    function _config(address admin, bytes32 salt)
        internal
        view
        returns (IArtCoinsFactory.DeploymentConfig memory cfg, IArtCoinsFactory.TaxConfig memory tax)
    {
        cfg = buildConfig(admin, address(core), creator, "Fixture Coin", "FIXT", salt);
        tax = buildTaxConfig(address(core));
    }

    function test_secondLaunchWithSameSaltFails() public {
        (IArtCoinsFactory.DeploymentConfig memory cfg, IArtCoinsFactory.TaxConfig memory tax) =
            _config(deployer, FIXTURE_SALT);
        uint256 fee = FACTORY.deployFee();
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        vm.expectRevert();
        FACTORY.deployTokenWithProtocolBpsAndTax{value: fee}(cfg, 0, tax);
        // a new salt works, which proves the config itself is fine
        (cfg, tax) = _config(deployer, keccak256("another salt"));
        vm.prank(deployer);
        address second = FACTORY.deployTokenWithProtocolBpsAndTax{value: fee}(cfg, 0, tax);
        assertTrue(second != address(coin) && second.code.length != 0);
    }

    function test_launchWithoutFactoryOwnerEnablementReverts() public {
        address outsider = _user("outsider");
        vm.deal(outsider, 1 ether);
        (IArtCoinsFactory.DeploymentConfig memory cfg, IArtCoinsFactory.TaxConfig memory tax) =
            _config(outsider, bytes32(uint256(1)));
        uint256 fee = FACTORY.deployFee();
        assertTrue(FACTORY.deprecated(), "the factory is deprecated at the pin");
        vm.prank(outsider);
        vm.expectRevert(bytes4(keccak256("Deprecated()")));
        FACTORY.deployTokenWithProtocolBpsAndTax{value: fee}(cfg, 0, tax);

        // the owner takes the enablement away again and the fixture deployer is locked out too
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        FACTORY.setAdmin(deployer, false);
        (cfg, tax) = _config(deployer, bytes32(uint256(2)));
        vm.prank(deployer);
        vm.expectRevert(bytes4(keccak256("Deprecated()")));
        FACTORY.deployTokenWithProtocolBpsAndTax{value: fee}(cfg, 0, tax);
    }

    function test_launchNeedsTheExactDeployFee() public {
        (IArtCoinsFactory.DeploymentConfig memory cfg, IArtCoinsFactory.TaxConfig memory tax) =
            _config(deployer, bytes32(uint256(3)));
        uint256 fee = FACTORY.deployFee();
        assertGt(fee, 0);
        vm.deal(deployer, 2 ether);
        vm.startPrank(deployer);
        vm.expectRevert();
        FACTORY.deployTokenWithProtocolBpsAndTax{value: fee - 1}(cfg, 0, tax);
        vm.expectRevert();
        FACTORY.deployTokenWithProtocolBpsAndTax{value: fee + 1}(cfg, 0, tax);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ referral payout, open point of the brief

    /// finding: with the cap at zero no referral slice is ever carved, so the payout contract is never called and
    /// even an EOA payout cannot brick a swap that names a referrer. the config still points the payout at the
    /// core, because the token admin may raise the cap later and an EOA payout would then revert such swaps
    function test_referralWithEoaPayoutAndCapZeroDoesNotRevert() public {
        (IArtCoinsFactory.DeploymentConfig memory cfg, IArtCoinsFactory.TaxConfig memory tax) =
            _config(deployer, bytes32(uint256(4)));
        address eoaPayout = _user("payout");
        cfg.poolConfig.poolData = abi.encode(
            address(0),
            bytes(""),
            abi.encode(
                uint24(10_000), uint16(9500), uint24(0), uint24(0), address(core), creator, eoaPayout, address(0)
            )
        );
        uint256 fee = FACTORY.deployFee();
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        address c2 = FACTORY.deployTokenWithProtocolBpsAndTax{value: fee}(cfg, 0, tax);
        PoolKey memory key = poolKeyOf(c2);
        _skipSniperWindow();
        address buyer = _user("buyer");
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        router.swapWithData{value: 1 ether}(key, true, -1 ether, buyer, _referralData(_user("ref"), 250));
        assertGt(IArtCoinsToken(c2).balanceOf(buyer), 0);

        // the risk the core payout removes: once the admin raises the cap, an EOA payout bricks referred swaps
        vm.prank(deployer);
        HOOK.setMaxReferralBpsOfVolume(key, 250);
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        vm.expectRevert();
        router.swapWithData{value: 1 ether}(key, true, -1 ether, buyer, _referralData(_user("ref"), 250));
    }
}

interface IArtCoinsExtensionSetter {
    function setPoolExtension(PoolKey calldata key, address extension, bytes calldata data) external;
}

/// the pieces of the launch that the Core itself creates: its auction house and its linked library
contract LaunchWiringTest is Fixture {
    /// the core created its own pnd auction house in its constructor, through the live factory
    function test_coreOwnsItsHouse() public view {
        IAuctionHouse h = core.HOUSE();
        assertEq(IAuctionFactory(Mainnet.AUCTION_FACTORY).houseOf(address(core)), address(h), "the factory knows it");
        assertEq(h.owner(), address(core), "the core owns it for good");
        assertEq(h.protocolFeeBps(), 0, "no fee at the pin");
        assertTrue(STATEMENTS.isApprovedForAll(address(core), address(h)), "it may take statements");
        assertEq(core.AUCTION_FACTORY(), Mainnet.AUCTION_FACTORY);
    }

    /// the linked library: its address is in the Core code, its code is the compiled CoreLib, and the settings the
    /// constructor wrote through it read back as the config
    function test_coreIsLinkedToTheCompiledLibrary() public view {
        address lib = findLibrary(address(core).code);
        assertTrue(lib != address(0), "no library in the core code");
        assertTrue(isCompiledLibrary(lib.code));
        assertEq(abi.encode(core.settings()), abi.encode(lc.settings), "the settings through the library");
        // the library address is the one forge test linked, never the address of a CREATE2 deployer deployment here
        assertTrue(lib != libraryAddress());
    }
}
