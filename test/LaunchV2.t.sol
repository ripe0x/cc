// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {IArtCoinsHookV2, IArtCoinsLpLockerV2, IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";

/// the launch the builder makes on the live v2 stack, read back from the real factory, hook, locker and coin
/// (docs/FLOW.md 10.1 with the 10.6 amendment). the fixture launches through `deploySystem`
contract LaunchV2Test is Fixture {
    function test_theCoinIsRestrictedAndOnlyTheCoreIsAllowed() public view {
        assertTrue(coin.restricted(), "restricted");
        assertTrue(coin.isAllowed(address(core)), "the core is on the allowlist");
        assertFalse(coin.isAllowed(address(feeRouter)), "the router is not");
        assertEq(coin.admin(), owner, "the token admin is the owner");
        assertEq(coin.canonicalHook(), lc.stack.hook);
        assertEq(coin.totalSupply(), lc.supply);
    }

    function test_skimIsSixPointNineWithNoLpFeeAndTheRouterIsTheBountyRecipient() public view {
        IArtCoinsHookV2.SkimConfig memory k = IArtCoinsHookV2(lc.stack.hook).skimConfig(poolId);
        assertEq(k.baselineSkimBps, 690);
        assertEq(k.bountyBps, 9_638);
        assertEq(k.lpFeePips, 0);
        assertEq(k.maxReferralBpsOfVolume, 0);
        assertEq(k.bountyRecipient, address(feeRouter));
        assertEq(k.protocolRecipient, FACTORY.protocolRecipient());
        assertEq(launchKey.fee, lc.stack.poolFee);
    }

    function test_theHookPoolInfoNamesTheCoinLockerAndMevModule() public view {
        IArtCoinsHookV2.PoolInfo memory p = IArtCoinsHookV2(lc.stack.hook).poolInfo(poolId);
        assertTrue(p.restricted);
        assertEq(p.token, address(coin));
        assertEq(p.locker, lc.stack.locker);
        assertEq(p.mevModule, lc.mevModule);
        assertTrue(IArtCoinsHookV2(lc.stack.hook).isOfficialPool(poolId));
        assertTrue(FACTORY.isCoin(address(coin)));
    }

    function test_theProjectLockerSlotIsTheCreatorAndTheProtocolSlotIsTheFactoryFloor() public view {
        IArtCoinsLpLockerV2.TokenRewardInfoV2 memory r = IArtCoinsLpLockerV2(lc.stack.locker).tokenRewards(address(coin));
        assertEq(r.rewardRecipients.length, 2, "project slot plus the protocol slot");
        assertEq(r.rewardRecipients[0], lc.creator, "the project slot goes to the creator");
        assertEq(r.rewardBps[0], 10_000 - lc.protocolBps);
        assertEq(r.rewardBps[1], lc.protocolBps);
        assertEq(uint256(r.rewardBps[0]) + r.rewardBps[1], 10_000);
    }

    function test_theWholeSupplyStartsInThePool() public view {
        assertGe(coin.balanceOf(address(PM)), lc.supply - 1e6, "the supply sits in the pool manager");
        assertEq(coin.balanceOf(address(core)), 0);
        assertEq(coin.balanceOf(address(feeRouter)), 0);
    }

    function test_theRouterIsWiredAndOpenForTheOwner() public view {
        assertEq(feeRouter.engine(), address(core));
        assertFalse(feeRouter.locked(), "not locked by the deploy");
        assertFalse(feeRouter.splitOn(), "the split starts when the window ends");
        assertEq(feeRouter.splitStart(), launchTime + lc.sniperSeconds);
        (address[] memory who, uint32[] memory ppm) = feeRouter.payees();
        assertEq(who.length, 1);
        assertEq(who[0], lc.creatorPayee);
        assertEq(ppm[0], lc.payeePpm);
        assertEq(core.FEE_SOURCE(), address(feeRouter));
    }

    function test_theAntiSniperSkimStartsHighAndFallsToTheBaseline() public {
        IArtCoinsHookV2.SkimConfig memory k = IArtCoinsHookV2(lc.stack.hook).skimConfig(poolId);
        autoFlush = false; // keep the skim in the router so it can be read
        uint256 bal = address(feeRouter).balance;
        _buyCoin(trader(), 1 ether);
        uint256 early = address(feeRouter).balance - bal;
        // the first block pays about the start rate, 90 points of the volume, 90 percent of it to the bounty leg
        assertGt(early, 0.7 ether, "the window skim is far above the baseline");
        _skipSniperWindow();
        bal = address(feeRouter).balance;
        _buyCoin(trader(), 1 ether);
        uint256 late = address(feeRouter).balance - bal;
        assertApproxEqRel(late, uint256(1 ether) * k.baselineSkimBps * k.bountyBps / 10_000 / 10_000, 0.01e18);
    }

    function _trader() internal returns (address) {
        return _user("launch trader");
    }

    function trader() internal returns (address t) {
        t = _trader();
        vm.deal(t, 100 ether);
    }
}
