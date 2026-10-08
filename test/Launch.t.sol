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
    IArtCoinsFactoryV2,
    IArtCoinsHookV2,
    IArtCoinsLpLockerV2,
    IArtCoinsMevSkimV2,
    IArtCoinsTokenV2
} from "../src/interfaces/ArtCoinsV2.sol";

/// the launch of the coin through the v2 factory as its owner and everything it must read back as
contract LaunchTest is Fixture {
    IArtCoinsHookV2 internal HOOK;

    function setUp() public override {
        super.setUp();
        HOOK = IArtCoinsHookV2(lc.stack.hook);
    }

    function test_predictedCoinEqualsDeployed() public view {
        assertEq(predictCoin(owner, address(core), "Fixture Coin", "FIXT", FIXTURE_SALT), address(coin));
        // the prediction depends on the token admin, the salt, the Core (it is on the allowlist) and the name
        assertTrue(predictCoin(creator, address(core), "Fixture Coin", "FIXT", FIXTURE_SALT) != address(coin));
        assertTrue(predictCoin(owner, address(core), "Fixture Coin", "FIXT", bytes32(0)) != address(coin));
        assertTrue(predictCoin(owner, address(ctl), "Fixture Coin", "FIXT", FIXTURE_SALT) != address(coin));
        assertTrue(predictCoin(owner, address(core), "Other", "FIXT", FIXTURE_SALT) != address(coin));
    }

    function test_predictionDependsOnTheSender() public view {
        LaunchConfigView memory v = _view();
        assertEq(FACTORY.predictToken(owner, v.cfg), address(coin));
        assertTrue(FACTORY.predictToken(creator, v.cfg) != address(coin), "the sender is part of the salt");
    }

    function test_wiring() public view {
        assertEq(core.COIN(), address(coin));
        assertEq(core.owner(), owner);
        assertEq(core.controller(), address(ctl));
        assertEq(address(ctl.CORE()), address(core));
        assertEq(core.HOOK(), lc.stack.hook);
        assertEq(core.FACTORY(), lc.stack.factory);
        assertEq(core.FEE_SOURCE(), address(feeRouter));
        assertEq(feeRouter.engine(), address(core));
        assertEq(feeRouter.owner(), owner);
    }

    function test_supplyAllInThePool() public view {
        assertApproxEqAbs(coin.totalSupply(), 1_000_000_000e18, 1e6, "the locker burns its rounding dust");
        // the pool manager holds the supply as the one locker position, less liquidity rounding dust that stays in
        // the locker. nobody else holds any
        uint256 dust = coin.balanceOf(lc.stack.locker);
        assertLt(dust, 1e6, "rounding dust only");
        assertApproxEqAbs(coin.balanceOf(address(PM)) + dust, 1_000_000_000e18, 1e6);
        assertEq(coin.balanceOf(owner), 0);
        assertEq(coin.balanceOf(address(core)), 0);
        assertEq(coin.balanceOf(address(feeRouter)), 0);
        assertEq(coin.balanceOf(lc.stack.factory), 0);

        IArtCoinsLpLockerV2.TokenRewardInfoV2 memory info = IArtCoinsLpLockerV2(lc.stack.locker).tokenRewards(address(coin));
        assertEq(info.numPositions, 1, "one position");
        assertEq(info.rewardBps.length, 2, "the project slot and the protocol slot");
        assertEq(info.rewardRecipients[0], creator);
        assertEq(info.rewardBps[0], 8_000);
        assertEq(info.rewardBps[1], 2_000);
        assertEq(abi.encode(info.poolKey), abi.encode(launchKey));
    }

    function test_poolKeyAndId() public view {
        assertEq(Currency.unwrap(launchKey.currency0), address(0));
        assertEq(Currency.unwrap(launchKey.currency1), address(coin));
        assertEq(launchKey.fee, 0x800000);
        assertEq(launchKey.tickSpacing, 200);
        assertEq(address(launchKey.hooks), lc.stack.hook);
        assertEq(poolId, keccak256(abi.encode(launchKey)));
        assertEq(coin.canonicalPoolId(), poolId, "the token computed the same pool id");
        (uint160 sqrtPrice, int24 tick,,) = StateLibrary.getSlot0(PM, PoolId.wrap(poolId));
        assertTrue(sqrtPrice != 0, "pool initialized");
        // the coin is currency1 against eth, so the pool opens at the mirrored tick
        assertEq(tick, 175_000);
    }

    function test_skimConfigReadBack() public {
        IArtCoinsHookV2.SkimConfig memory k = HOOK.skimConfig(poolId);
        assertEq(k.baselineSkimBps, 6_900);
        assertEq(k.bountyBps, 9_000);
        assertEq(k.maxReferralBpsOfVolume, 0);
        assertEq(k.lpFee, 0);
        assertEq(k.bountyRecipient, address(feeRouter), "the bounty goes to the router");
        assertEq(k.protocolRecipient, FACTORY.protocolRecipient(), "the protocol leg is the launcher protocol");
        assertEq(k.referralPayout, FACTORY.referralPayout());
        assertEq(k.quoteToken, address(0));
        assertTrue(HOOK.isOfficialPool(poolId));
        // the anti sniper schedule: 90 points at the first block, the baseline once the window is over
        IArtCoinsMevSkimV2 mev = IArtCoinsMevSkimV2(lc.mevModule);
        IArtCoinsMevSkimV2.SkimSchedule memory s = mev.schedule(poolId);
        assertEq(s.startingSkimBps, 90_000);
        assertEq(s.endSkimBps, 6_900, "the baseline is the end value");
        assertEq(s.windowSeconds, 1800);
        assertEq(s.startTime, launchTime);
        (uint24 now_, bool active) = mev.currentSkimBps(poolId);
        assertEq(now_, 90_000);
        assertTrue(active);
        _skipSniperWindow();
        (now_, active) = mev.currentSkimBps(poolId);
        assertEq(now_, 6_900);
        assertFalse(active);
    }

    function test_coinConfigReadBack() public view {
        assertTrue(coin.restricted());
        assertEq(coin.canonicalHook(), lc.stack.hook);
        assertEq(coin.poolManager(), Mainnet.POOL_MANAGER);
        assertEq(coin.launcher(), lc.stack.factory);
        assertTrue(coin.isAllowed(address(core)), "the Core is on the allowlist");
        assertTrue(coin.isAllowed(lc.stack.locker) && coin.isPinned(lc.stack.locker), "the locker is pinned");
        assertTrue(coin.isAllowed(lc.stack.escrow) && coin.isPinned(lc.stack.escrow), "the escrow is pinned");
        assertFalse(coin.isPinned(address(core)), "the Core entry is the admin's to manage");
        address[7] memory off = [
            address(feeRouter),
            owner,
            creator,
            lc.creatorPayee,
            lc.stack.hook,
            lc.stack.factory,
            address(ctl)
        ];
        for (uint256 i; i < off.length; ++i) {
            assertFalse(coin.isAllowed(off[i]), "nothing else is on the allowlist");
        }
        assertFalse(coin.isAllowed(address(core.HOUSE())));
        assertFalse(coin.locked());
    }

    function test_noExtensionAndTheTokenAdminIsTheOwner() public {
        IArtCoinsFactoryV2.DeploymentInfoV2 memory info = FACTORY.deploymentInfo(address(coin));
        assertEq(info.extensions.length, 0);
        assertEq(info.token, address(coin));
        assertEq(info.hook, lc.stack.hook);
        assertEq(info.locker, lc.stack.locker);
        assertEq(info.mevModule, lc.mevModule);
        assertEq(info.poolId, poolId);
        assertEq(info.launchedAt, launchTime);
        assertEq(info.version, FACTORY.STACK_VERSION());
        assertEq(HOOK.poolInfo(poolId).extension, address(0));
        assertEq(coin.admin(), owner, "token admin is the owner from the first block");
        assertEq(IArtCoinsTokenV2(address(coin)).originalAdmin(), owner);
        // nobody else holds an admin power
        vm.startPrank(creator);
        vm.expectRevert();
        coin.setAllowed(creator, true);
        vm.expectRevert();
        coin.unrestrict();
        vm.stopPrank();
        // the owner manages the allowlist and can leave the restriction
        vm.prank(owner);
        coin.setAllowed(creator, true);
        assertTrue(coin.isAllowed(creator));
    }

    // ------------------------------------------------------------------ launch failures

    struct LaunchConfigView {
        IArtCoinsFactoryV2.DeploymentConfigV2 cfg;
    }

    function _view() internal view returns (LaunchConfigView memory v) {
        v.cfg = buildConfig(owner, address(core), creator, "Fixture Coin", "FIXT", FIXTURE_SALT);
    }

    function _config(address admin, bytes32 salt) internal view returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory) {
        return buildConfig(admin, address(core), creator, "Fixture Coin", "FIXT", salt);
    }

    function test_secondLaunchWithSameSaltFails() public {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = _config(owner, FIXTURE_SALT);
        uint256 fee = FACTORY.deployFee();
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert();
        FACTORY.deployTokenAsOwner{value: fee}(cfg, lc.protocolBps);
        // a new salt works, which proves the config itself is fine
        cfg = _config(owner, keccak256("another salt"));
        vm.prank(owner);
        address second = FACTORY.deployTokenAsOwner{value: fee}(cfg, lc.protocolBps);
        assertTrue(second != address(coin) && second.code.length != 0);
    }

    function test_onlyTheFactoryOwnerCanLaunchOnADeprecatedFactory() public {
        address outsider = _user("outsider");
        vm.deal(outsider, 1 ether);
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = _config(outsider, bytes32(uint256(1)));
        uint256 fee = FACTORY.deployFee();
        assertTrue(FACTORY.deprecated(), "the factory is deprecated");
        vm.startPrank(outsider);
        vm.expectRevert(bytes4(keccak256("Deprecated()")));
        FACTORY.deployToken{value: fee}(cfg);
        vm.expectRevert();
        FACTORY.deployTokenAsOwner{value: fee}(cfg, 0);
        vm.stopPrank();
    }

    function test_launchNeedsTheDeployFee() public {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = _config(owner, bytes32(uint256(3)));
        uint256 fee = FACTORY.deployFee();
        assertGt(fee, 0);
        vm.deal(owner, 2 ether);
        address team = _user("team");
        vm.startPrank(owner);
        FACTORY.setTeamFeeRecipient(team);
        vm.expectRevert();
        FACTORY.deployTokenAsOwner{value: fee - 1}(cfg, lc.protocolBps);
        // more than the fee is refunded
        uint256 before = owner.balance;
        FACTORY.deployTokenAsOwner{value: fee + 0.1 ether}(cfg, lc.protocolBps);
        vm.stopPrank();
        assertEq(before - owner.balance, fee, "only the fee is kept");
        assertEq(team.balance, fee, "the fee goes to the team fee recipient");
    }

    /// the owner command of the launch: the factory floors the lp fee, the config needs it at 0
    function test_launchWithLpFeeZeroNeedsTheMinLpFeeAtZero() public {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = _config(owner, bytes32(uint256(5)));
        uint256 fee = FACTORY.deployFee();
        vm.startPrank(owner);
        FACTORY.setMinLpFee(3_000);
        vm.expectRevert(bytes4(keccak256("LpFeeBelowMinimum()")));
        FACTORY.deployTokenAsOwner{value: fee}(cfg, lc.protocolBps);
        FACTORY.setMinLpFee(0);
        address c2 = FACTORY.deployTokenAsOwner{value: fee}(cfg, lc.protocolBps);
        vm.stopPrank();
        assertTrue(c2.code.length != 0);
    }

    function test_bountyAboveTheProtocolFloorReverts() public {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = _config(owner, bytes32(uint256(6)));
        cfg.fee.bountyBps = 9_500;
        uint256 fee = FACTORY.deployFee();
        vm.prank(owner);
        vm.expectRevert();
        FACTORY.deployTokenAsOwner{value: fee}(cfg, lc.protocolBps);
    }

    // ------------------------------------------------------------------ referral, open point of the brief

    /// finding: with the cap at zero no referral slice is ever carved, so a swap that names a referrer does not revert
    function test_referralWithTheCapAtZeroDoesNotRevert() public {
        _skipSniperWindow();
        address buyer = _user("buyer");
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        router.swapWithData{value: 1 ether}(launchKey, true, -1 ether, buyer, _referralData(_user("ref"), 250));
        assertGt(coin.balanceOf(buyer), 0);
    }
}

/// the pieces of the launch that the Core itself creates: its auction house and its linked library
contract LaunchWiringTest is Fixture {
    /// the Core created its own pnd auction house in its constructor, through the live factory
    function test_coreOwnsItsHouse() public view {
        IAuctionHouse h = IAuctionHouse(core.HOUSE());
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
