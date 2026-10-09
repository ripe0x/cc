// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FeeBase} from "./Fees.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsLpLockerV2} from "../src/interfaces/ArtCoinsV2.sol";
import {ClaimMidListing, ClaimMidExit} from "./attackers/V2Port.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";

interface IEscrowStore {
    function storeFeesNative(address feeOwner) external payable;
}

/// the fee path of the v2 port: router, flush, escrow credits and the places the v2 hook can put eth that the Core
/// does not book. every number is from the real v2 hook and pool on the fork
contract V2PortFeeTest is FeeBase {
    using FixedPointMathLib for uint256;

    function _share(uint16 bps) internal {
        Settings memory s = core.settings();
        s.feeToBuybackBps = bps;
        _setSettings(s);
    }

    /// @dev the hook (a real escrow depositor) credits `amount` to the Core, the way a partial fill refund of the Core's
    /// own buyback is stored (D58)
    function _creditCore(uint256 amount) internal {
        assertTrue(ESCROW.isDepositor(v2.hook), "the hook is a depositor");
        vm.deal(v2.hook, v2.hook.balance + amount);
        vm.prank(v2.hook);
        IEscrowStore(address(ESCROW)).storeFeesNative{value: amount}(address(core));
    }

    /// 1 eth buy in steady state at each split. 6.9 points of skim (0.069 eth) split by bountyBps 9_638: the router gets
    /// 0.069 * 9_638 / 10_000 = 0.0665022 eth (6.65022 points), the protocol recipient 0.069 less 0.0665022 = 0.0024978 eth
    /// (0.24978 points). of the router's 66_502_200_000_000_000 wei: payee 112_778 ppm =
    /// 7_499_985_111_600_000 (0.7499985 points), engine the rest = 59_002_214_888_400_000 (5.9002215 points). the engine part splits between the pot and the buyback by the share setting
    function test_exactNumbersAtEachSplit() public {
        _stock();
        uint256[3] memory bps = [uint256(0), 5_000, 10_000];
        uint256[3] memory toBb = [uint256(0), 29_501_107_444_200_000, 59_002_214_888_400_000];
        for (uint256 i; i < 3; ++i) {
            _share(uint16(bps[i]));
            uint256 payee0 = lc.creatorPayee.balance;
            uint256 flusher0 = flusher.balance;
            uint256 pot0 = core.ethPot();
            uint256 bb0 = core.ethToBuyback();
            Flow memory f = _flow(Kind.BuyExactIn, 1 ether, "");
            assertEq(f.skimVolume, 0.931 ether, "volume net of the skim");
            assertEq(f.skimBounty, 0.0665022 ether, "6.65022 points to the router");
            assertEq(f.skimProtocol, 0.0024978 ether, "0.24978 points to the protocol recipient");
            assertEq(f.routerRise, 0.0665022 ether);
            assertEq(flusher.balance, flusher0, "the flusher receives nothing");
            assertEq(f.toPayees, 7_499_985_111_600_000, "the single payee");
            assertEq(lc.creatorPayee.balance - payee0, 7_499_985_111_600_000);
            assertEq(f.balanceRise, 59_002_214_888_400_000, "5.9002215 points to the engine");
            assertEq(core.ethToBuyback() - bb0, toBb[i]);
            assertEq(core.ethPot() - pot0, 59_002_214_888_400_000 - toBb[i]);
            assertEq(address(feeRouter).balance, 0, "the router is empty");
            _solvent();
        }
    }

    /// eth that reaches the Core from anyone but the router (the hook, the escrow) is left for `skim()`, which books it
    /// to the pot whatever the buyback share is
    function test_directEthWaitsForSkimAndGoesToThePot() public {
        _share(10_000);
        address[2] memory from = [v2.hook, v2.escrow];
        for (uint256 i; i < 2; ++i) {
            vm.deal(from[i], 1 ether);
            vm.prank(from[i]);
            (bool ok,) = address(core).call{value: 1 ether}("");
            assertTrue(ok);
        }
        assertEq(core.ethPot(), 0);
        assertEq(core.ethToBuyback(), 0);
        assertEq(address(core).balance, 2 ether);
        vm.expectEmit(address(core));
        emit ICore.Skimmed(2 ether, 0);
        core.skim();
        assertEq(core.ethPot(), 2 ether, "all of it to the pot");
        assertEq(core.ethToBuyback(), 0, "none of it to the buyback, whatever the share");
        _solvent();
    }

    /// a refund credited to the Core in the escrow (the shape of a partial fill refund of its own buyback): anyone can
    /// claim it into the Core, nobody can send it elsewhere, and `skim()` books it to the pot. a partial fill itself
    /// cannot be made on the launch pool (it needs about 3e42 wei, over the int128 range of a pool amount)
    function test_escrowCreditOfTheCoreIsClaimedByAnyoneThenSkimmed() public {
        _share(5_000);
        _creditCore(0.3 ether);
        assertEq(ESCROW.balances(address(core), address(0)), 0.3 ether);
        assertFalse(ESCROW.selfClaimOnly(address(core)));
        address stranger = _user("stranger");
        vm.startPrank(stranger);
        vm.expectRevert();
        ESCROW.claimTo(address(core), address(0), payable(stranger));
        ESCROW.claim(address(core), address(0));
        vm.stopPrank();
        assertEq(ESCROW.balances(address(core), address(0)), 0);
        assertEq(address(core).balance, 0.3 ether, "paid to the Core");
        assertEq(core.ethPot(), 0, "not booked by the claim (the sender is the escrow)");
        vm.prank(stranger);
        core.skim();
        assertEq(core.ethPot(), 0.3 ether);
        assertEq(core.ethToBuyback(), 0);
        _solvent();
    }

    /// the credit claimed in the middle of `buyListing`: the Core sees less spent, books nothing, and stays consistent
    function test_claimMidBuyListingKeepsThePotsConsistent() public {
        ClaimMidListing t = new ClaimMidListing(v2.escrow, address(core));
        _allow(address(t));
        _stock();
        _fundPot(1 ether);
        uint256 id = _credits(address(t), 1)[0];
        uint256 ceiling = core.ceilingOf(id);
        uint256 e = ceiling / 3;
        _creditCore(e);
        t.arm(id);
        uint256 pot = core.ethPot();
        uint256 bal = address(core).balance;
        uint256 cost = ceiling - e;
        uint256 tip = (1000 * (ceiling - cost) / 10_000).min(200 * cost / 10_000);
        vm.prank(keeper);
        core.buyListing(ceiling, hex"deadbeef", id, address(t));
        assertEq(CREDITS.ownerOf(id), address(core));
        assertEq(core.ethPot(), pot - cost - tip, "the pot paid the measured cost, which the claim lowered");
        assertEq(address(core).balance, bal - cost - tip, "balance and pot moved together");
        _solvent();
    }

    /// a claim worth the whole price makes the measured cost zero: the buy reverts, nothing is booked wrong
    function test_claimOfTheWholePriceMidBuyListingReverts() public {
        ClaimMidListing t = new ClaimMidListing(v2.escrow, address(core));
        _allow(address(t));
        _stock();
        _fundPot(1 ether);
        uint256 id = _credits(address(t), 1)[0];
        uint256 ceiling = core.ceilingOf(id);
        _creditCore(ceiling);
        t.arm(id);
        uint256 pot = core.ethPot();
        vm.prank(keeper);
        vm.expectRevert(ICore.BadCost.selector);
        core.buyListing(ceiling, hex"deadbeef", id, address(t));
        assertEq(core.ethPot(), pot);
        assertEq(CREDITS.ownerOf(id), address(t), "the credit never moved");
    }

    /// the same during `exitStatement`: the pot only falls by the gas repay, the claimed eth is left unbooked for skim
    function test_claimMidExitKeepsThePotsConsistent() public {
        _stock();
        MockExitToken token = new MockExitToken("Exit Token", "XT");
        ClaimMidExit m = new ClaimMidExit(token, UNIT, v2.escrow, address(core));
        _setExitModule(address(m));
        Composed memory c = _composeOnce();
        vm.warp(block.timestamp + core.settings().exitAfter);
        _creditCore(0.2 ether);
        uint256 pot = core.ethPot();
        uint256 gas0 = address(this).balance;
        core.exitStatement(c.sid);
        assertEq(core.ethPot(), pot - (address(this).balance - gas0), "only the gas repay left the pot");
        assertEq(address(core).balance - core.ethPot() - core.ethToBuyback(), 0.2 ether, "the claim is unbooked");
        _solvent();
        core.skim();
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback());
    }

    /// lpFee is 0 at launch: the locker has nothing to pay and no reward slot reaches the router or the Core
    function test_noLpIncomeAtLpFeeZero() public {
        _stock();
        for (uint256 i; i < 3; ++i) {
            _buyCoin(trader, 2 ether);
        }
        IArtCoinsLpLockerV2 locker = IArtCoinsLpLockerV2(v2.locker);
        address[] memory rec = locker.rewardRecipients(address(coin));
        uint16[] memory bps = locker.rewardBps(address(coin));
        assertEq(rec.length, 2, "the project slot and the factory protocol slot");
        assertEq(rec[0], creator, "the project slot is the creator address");
        assertEq(bps[0], 8_000);
        assertEq(bps[1], 2_000, "the protocol slot is the factory default");
        assertTrue(rec[1] != address(core) && rec[1] != address(feeRouter), "no slot reaches the engine");
        uint256 core0 = address(core).balance;
        uint256 router0 = address(feeRouter).balance;
        uint256 creator0 = creator.balance;
        uint256 coin0 = coin.balanceOf(creator);
        locker.collectRewards(address(coin));
        assertEq(address(core).balance, core0);
        assertEq(address(feeRouter).balance, router0);
        assertEq(creator.balance, creator0, "no lp fee eth accrued");
        assertEq(coin.balanceOf(creator), coin0, "no lp fee coin accrued");
    }
}
