// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {FeeBase} from "./Fees.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";

/// `feeToBuybackBps`: the share of the router's eth that `receive()` books to the coin buyback, the rest to the pot.
/// every number comes from real swaps through the live pool and the live skim hook, which pays its bounty leg into the
/// fee router; a flush sends the engine share to the core. `skim()` books what `receive()` did not, to the pot only
contract FeeShareTest is FeeBase {
    uint256 internal constant BASIS = 10_000;

    function _share(uint16 bps) internal {
        Settings memory s = core.settings();
        s.feeToBuybackBps = bps;
        _setSettings(s);
    }

    struct Books {
        uint256 bounty;
        uint256 inflow;
        uint256 dPot;
        uint256 dBb;
        uint256 dBal;
    }

    /// one swap and a flush, and what they did to the core's books. the bounty is what the hook itself reports it pushed
    /// to the router, the inflow is what the flush sent on to the core (less the payees' parts)
    function _swap(Kind kind, uint256 amount) internal returns (Books memory b) {
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        uint256 bal = address(core).balance;
        Flow memory f = _flow(kind, amount, "");
        b.bounty = f.skimBounty;
        b.inflow = f.balanceRise;
        assertEq(b.inflow, f.routerRise - f.toPayees, "the core got the router inflow less the payees");
        b.dPot = core.ethPot() - pot;
        b.dBb = core.ethToBuyback() - bb;
        b.dBal = address(core).balance - bal;
    }

    function _check(Books memory b, uint16 bps) internal pure {
        uint256 toBb = b.inflow * bps / BASIS;
        assertEq(b.dBb, toBb, "buyback share is floor(inflow * bps / 10000)");
        assertEq(b.dPot, b.inflow - toBb, "the rest is the pot share");
        assertEq(b.dBal, b.inflow, "the balance rose by the inflow");
    }

    function test_split_atZeroHalfAndAllOnExactBuys() public {
        _stock();
        uint16[3] memory bps = [uint16(0), 5_000, 10_000];
        for (uint256 i; i < 3; ++i) {
            _share(bps[i]);
            Books memory b = _swap(Kind.BuyExactIn, 1 ether);
            assertEq(b.bounty, 0.0665022 ether, "6.65022 points of one eth reach the router");
            uint256 want = b.inflow * bps[i] / BASIS;
            assertEq(b.dBb, want, "exact buyback share");
            assertEq(b.dPot, b.inflow - want, "exact pot share");
            assertApproxEqAbs(b.inflow, 0.0590022 ether, 0.00001 ether, "5.9002215 points of the buy reach the engine (router 6.65022 less the payee 0.74999851)");
            _check(b, bps[i]);
            _solvent();
        }
    }

    function test_split_everySwapKindAndAnOddShare() public {
        _stock();
        _share(3_333);
        _check(_swap(Kind.BuyExactIn, 2 ether), 3_333);
        _check(_swap(Kind.BuyExactOut, 500_000e18), 3_333);
        _check(_swap(Kind.SellExactIn, coin.balanceOf(trader) / 5), 3_333);
        _check(_swap(Kind.SellExactOut, 0.3 ether), 3_333);
        _solvent();
    }

    /// inside the anti sniper window the router gets 89.75022 points (the bounty share of the baseline, 6.65022, plus the whole
    /// extra), none of it shared with the payees, and the engine share is split by the setting
    function test_split_insideTheSniperWindowTakesTheWholeBounty() public {
        _share(5_000);
        Books memory b = _swap(Kind.BuyExactIn, 1 ether);
        assertEq(b.bounty, 0.8975022 ether);
        assertEq(b.inflow, 0.8975022 ether);
        assertEq(b.dBb, b.inflow / 2);
        assertEq(b.dPot, b.inflow - b.inflow / 2);
        _check(b, 5_000);
    }

    function test_split_dustAmountsFromTheFeeSource() public {
        address hook = lc.stack.feeSource;
        vm.deal(hook, 10 ether);
        _share(5_000);
        uint256[5] memory v = [uint256(0), 1, 3, 4, 10_001];
        for (uint256 i; i < v.length; ++i) {
            uint256 pot = core.ethPot();
            uint256 bb = core.ethToBuyback();
            vm.prank(hook);
            (bool ok,) = address(core).call{value: v[i]}("");
            assertTrue(ok, "receive never reverts");
            assertEq(core.ethToBuyback() - bb, v[i] * 5_000 / BASIS, "floor to the buyback");
            assertEq(core.ethPot() - pot, v[i] - v[i] * 5_000 / BASIS, "the odd wei stays with the pot");
        }
        _solvent();
    }

    function test_split_aSendFromAnyoneElseIsNotBookedAtAll() public {
        _share(10_000);
        vm.deal(address(this), 5 ether);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok, "accepted");
        assertEq(core.ethPot(), pot, "not booked");
        assertEq(core.ethToBuyback(), bb);
        assertEq(address(core).balance - pot - bb, 1 ether, "it sits unbooked until skim");
    }

    // ------------------------------------------------------------------ skim

    /// `skim` books to the pot only, whatever the share is: the share is for the hook's own pushes
    function test_skim_booksToThePotOnly() public {
        _share(10_000);
        vm.deal(address(this), 5 ether);
        (bool ok,) = address(core).call{value: 1.5 ether}("");
        assertTrue(ok);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        vm.recordLogs();
        core.skim();
        assertEq(core.ethPot() - pot, 1.5 ether, "all of it to the pot");
        assertEq(core.ethToBuyback(), bb, "none to the buyback");
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback());
        // a second skim books nothing
        core.skim();
        assertEq(core.ethPot() - pot, 1.5 ether);
    }

    /// the exit token sent to the core is booked by skim to its own pot, whatever the share
    function test_skim_theExitTokenGoesToItsPotWhateverTheShare() public {
        _enterPhase2();
        _share(10_000);
        xt.mint(address(core), 7e18);
        uint256 xb = core.xToBuyback();
        uint256 xp = core.xPot();
        core.skim();
        assertEq(core.xPot() - xp, 7e18);
        assertEq(core.xToBuyback(), xb);
    }

    // ------------------------------------------------------------------ a change of the setting

    function test_change_takesEffectOnTheNextFeeAndNeverRewritesTheBooks() public {
        _stock();
        _share(0);
        Books memory b = _swap(Kind.BuyExactIn, 1 ether);
        assertEq(b.dBb, 0);
        assertEq(b.dPot, b.inflow);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        _share(10_000);
        assertEq(core.ethPot(), pot, "the change moves no books");
        assertEq(core.ethToBuyback(), bb);
        b = _swap(Kind.BuyExactIn, 1 ether);
        assertEq(b.dBb, b.inflow);
        assertEq(b.dPot, 0);
        _share(2_500);
        b = _swap(Kind.BuyExactIn, 1 ether);
        assertEq(b.dBb, b.inflow * 2_500 / BASIS);
        assertEq(b.dPot, b.inflow - b.inflow * 2_500 / BASIS);
        _share(0);
        b = _swap(Kind.SellExactIn, coin.balanceOf(trader) / 10);
        assertEq(b.dBb, 0);
        assertEq(b.dPot, b.inflow);
        _solvent();
    }

    function test_change_boundIsTenThousand() public {
        Settings memory s = core.settings();
        s.feeToBuybackBps = 10_001;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("feeToBuybackBps")));
        core.setSettings(s);
        s.feeToBuybackBps = 10_000;
        vm.prank(owner);
        core.setSettings(s);
        assertEq(core.settings().feeToBuybackBps, 10_000);
        vm.prank(address(0x5757));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setSettings(s);
    }

    /// with the whole fee going to the buyback the pot gets nothing from swaps, but the rate still checkpoints
    function test_change_allToTheBuybackLeavesThePotAndKeepsTheCheckpoint() public {
        _stock();
        _fundPot(1 ether);
        _share(10_000);
        _warp(6 hours);
        uint256 rate = core.ethRate();
        uint256 pot = core.ethPot();
        _swap(Kind.BuyExactIn, 1 ether);
        assertEq(core.ethPot(), pot, "the pot did not grow");
        assertEq(core.checkpointTime(), block.timestamp, "the fee still checkpoints");
        assertEq(core.rateAtCheckpoint(), rate);
    }
}

/// the fee that comes back to the core during its own `buyback()` swap is split like any other, and the buyback works
contract FeeShareBuybackTest is FeeBase {
    function _share(uint16 bps) internal {
        Settings memory s = core.settings();
        s.feeToBuybackBps = bps;
        _setSettings(s);
    }

    function _event(Vm.Log[] memory logs) internal pure returns (uint256 spent, uint256 tip) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ICore.Buyback.selector) (spent, tip) = abi.decode(logs[i].data, (uint256, uint256));
        }
    }

    function _run(uint16 bps) internal {
        _stock();
        _fillEthBuyback();
        _share(bps);
        uint256 pool = core.ethToBuyback();
        uint256 pot0 = core.ethPot();
        uint256 supply = coin.totalSupply();
        uint256 keeperEth = keeper.balance;
        uint256 slice = pool < 1 ether ? pool : 1 ether;
        assertGt(slice, 0);
        vm.recordLogs();
        vm.prank(keeper);
        core.buyback();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Flow memory f;
        _readSkim(f, logs);
        (uint256 spent, uint256 tip) = _event(logs);
        assertGt(f.skimBounty, 0, "the buyback swap paid the hook");
        assertEq(core.ethPot(), pot0, "the skim of the swap went to the router, not back inside the call");
        // the flush sends the engine share to the core, split by the share
        uint256 inflow = _flush();
        assertGt(inflow, 0);
        uint256 toBb = inflow * bps / 10_000;
        assertEq(core.ethPot() - pot0, inflow - toBb, "pot share of the returning skim");
        assertEq(core.ethToBuyback(), pool - slice + toBb + (slice - spent - tip), "buyback pot");
        assertEq(keeper.balance - keeperEth, tip, "the keeper is tipped as before");
        assertLt(coin.totalSupply(), supply, "coin was bought and burned");
        assertEq(coin.balanceOf(address(core)), 0);
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "no unbooked eth");
        _solvent();
        // and the buyback works again with what came back
        if (core.ethToBuyback() != 0) {
            vm.roll(block.number + core.settings().buybackDelay);
            uint256 s2 = coin.totalSupply();
            vm.prank(keeper);
            core.buyback();
            assertLt(coin.totalSupply(), s2, "the second buyback burns too");
            _solvent();
        }
    }

    function test_buyback_skimReturnSplitAtZero() public {
        _run(0);
    }

    function test_buyback_skimReturnSplitAtHalf() public {
        _run(5_000);
    }

    function test_buyback_skimReturnSplitAtAll() public {
        _run(10_000);
    }

    /// with everything routed back, the buyback pot only shrinks by what the swap really consumed net of the skim
    function test_buyback_allToTheBuybackNetCost() public {
        _stock();
        _fillEthBuyback();
        _share(10_000);
        uint256 pool = core.ethToBuyback();
        uint256 pot0 = core.ethPot();
        vm.recordLogs();
        vm.prank(keeper);
        core.buyback();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Flow memory f;
        _readSkim(f, logs);
        (uint256 spent, uint256 tip) = _event(logs);
        uint256 inflow = _flush();
        assertEq(core.ethPot(), pot0, "the pot did not move");
        uint256 slice = pool < 1 ether ? pool : 1 ether;
        assertEq(core.ethToBuyback(), pool - slice + inflow + (slice - spent - tip));
        assertEq(spent + tip + (slice - spent - tip), slice, "the slice is spent, tipped or returned");
    }
}
