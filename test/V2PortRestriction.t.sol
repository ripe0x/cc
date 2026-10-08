// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeBase} from "./Fees.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {LeftoverSpender} from "./attackers/V2Port.sol";

/// the restricted v2 coin as the engine meets it: the Core is on the allowlist (FLOW 29), the router and everyone else
/// are not. real coin, real pool, real hook
contract V2PortRestrictionTest is FeeBase {
    function setUp() public override {
        super.setUp();
        _stock();
    }

    function _bought(uint256 pmBefore) internal view returns (uint256) {
        return pmBefore - coin.balanceOf(Mainnet.POOL_MANAGER);
    }

    /// the allowlisted Core leaves the allowance the hook granted for the take unconsumed: a stranger can spend it
    /// inside the same transaction, on a move to the pool manager, and not without a buyback in the transaction. the
    /// allowance is exactly the coin the buyback bought (transient, gone with the transaction)
    function test_ACCEPTED_buybackLeavesAnAllowanceAStrangerCanSpendInTheSameTransaction() public {
        _fillEthBuyback();
        LeftoverSpender s = new LeftoverSpender(address(coin), address(core), Mainnet.POOL_MANAGER);
        _buyCoin(address(s), 2 ether);
        uint256 held = coin.balanceOf(address(s));
        assertGt(held, 1_000e18);
        uint256 pm0 = coin.balanceOf(Mainnet.POOL_MANAGER);
        uint256 supply0 = coin.totalSupply();
        assertFalse(s.spendAlone(1e18), "without a buyback in the transaction the same move reverts");
        s.run(1_000e18);
        uint256 bought = supply0 - coin.totalSupply();
        assertGt(bought, 0, "the buyback burned");
        assertEq(s.leftover(), bought, "the unconsumed allowance equals the coin bought");
        assertTrue(s.spent(), "the stranger spent it inside the transaction");
        assertEq(coin.balanceOf(address(s)), held - 1_000e18);
        assertEq(coin.balanceOf(Mainnet.POOL_MANAGER) + bought, pm0 + 1_000e18, "the moved coin sits in the pool manager");
        // the allowance is transient storage of the coin: a forge test is one transaction, so its end cannot be shown here
    }

    /// the buyback takes only what the pool paid out, burns exactly that, and leaves coin that is already in the Core
    function test_buybackBurnsWhatItBoughtNotWhatTheCoreHolds() public {
        _fillEthBuyback();
        vm.prank(trader);
        coin.transfer(address(core), 5_000e18);
        uint256 pm0 = coin.balanceOf(Mainnet.POOL_MANAGER);
        uint256 supply0 = coin.totalSupply();
        vm.prank(keeper);
        core.buyback();
        uint256 bought = _bought(pm0);
        assertGt(bought, 0);
        assertEq(supply0 - coin.totalSupply(), bought);
        assertEq(coin.balanceOf(address(core)), 5_000e18, "the donation was not touched");
        _solvent();
    }

    /// `burn` skips the restriction, a holder can always burn
    function test_burnPassesWhileRestricted() public {
        uint256 bal = coin.balanceOf(trader);
        uint256 supply0 = coin.totalSupply();
        vm.prank(trader);
        coin.burn(bal / 2);
        assertEq(coin.totalSupply(), supply0 - bal / 2);
        assertEq(coin.balanceOf(trader), bal - bal / 2);
        assertTrue(coin.restricted());
    }

    /// a buyer acquires coin in the home pool, approves the Core and `buybackExit` burns it from them
    function test_buybackExitBurnsCoinBoughtInTheHomePool() public {
        _enterPhase2();
        _fillExitBuyback();
        assertGt(core.xToBuyback(), 0);
        address taker = _user("exit taker");
        _buyCoin(taker, 5 ether);
        vm.prank(taker);
        coin.approve(address(core), type(uint256).max);
        uint256 slice;
        uint256 coinIn;
        for (uint256 i; i < 3000; ++i) {
            (slice, coinIn) = core.exitAuctionQuote();
            if (coinIn <= coin.balanceOf(taker)) break;
            vm.warp(block.timestamp + 1 hours);
        }
        assertLe(coinIn, coin.balanceOf(taker), "affordable");
        uint256 held = coin.balanceOf(taker);
        uint256 supply0 = coin.totalSupply();
        uint256 dead0 = coin.balanceOf(DEAD);
        vm.prank(taker);
        core.buybackExit(held);
        assertEq(held - coin.balanceOf(taker), coinIn, "the quoted coin left the taker");
        assertEq(supply0 - coin.totalSupply(), coinIn, "and was burned");
        assertEq(coin.balanceOf(DEAD), dead0);
        assertEq(xt.balanceOf(taker), slice, "the taker got the slice");
        _solvent();
    }

    /// the Core is on the allowlist: a wallet can send it coin. it is inert (no pot, no book counts it) until the owner
    /// rescues it. nobody else can move it
    function test_donatedCoinIsInertAndRescuable() public {
        _fillEthBuyback();
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        vm.prank(trader);
        coin.transfer(address(core), 1_000e18);
        assertEq(core.ethPot(), pot);
        assertEq(core.ethToBuyback(), bb);
        _solvent();
        vm.prank(trader);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.rescueCoin(trader, 1);
        vm.prank(owner);
        core.rescueCoin(creator, 1_000e18);
        assertEq(coin.balanceOf(creator), 1_000e18);
        assertEq(coin.balanceOf(address(core)), 0);
    }

    /// with the restriction turned off by the coin admin, plain transfers work, a donation to the Core is inert in the same
    /// way, and the buyback and the rescue behave as before
    function test_unrestrictedDonationIsInert() public {
        vm.prank(owner);
        coin.unrestrict();
        assertFalse(coin.restricted());
        address friend = _user("friend");
        vm.prank(trader);
        coin.transfer(friend, 1e18);
        assertEq(coin.balanceOf(friend), 1e18);
        vm.prank(friend);
        coin.transfer(address(core), 1e18);
        _fillEthBuyback();
        uint256 pm0 = coin.balanceOf(Mainnet.POOL_MANAGER);
        uint256 supply0 = coin.totalSupply();
        vm.prank(keeper);
        core.buyback();
        assertEq(supply0 - coin.totalSupply(), _bought(pm0));
        assertEq(coin.balanceOf(address(core)), 1e18, "the donation stays");
        _solvent();
        vm.prank(owner);
        core.rescueCoin(friend, 1e18);
        assertEq(coin.balanceOf(address(core)), 0);
    }

    /// the coin admin can take the Core off the allowlist again: the buyback's take then consumes exactly the allowance the
    /// hook granted, nothing is left to spend, and nobody can send coin to the Core any more
    function test_buybackWorksAfterTheAdminDelistsTheCore() public {
        _fillEthBuyback();
        vm.prank(owner);
        coin.setAllowed(address(core), false);
        assertFalse(coin.isAllowed(address(core)));
        uint256 supply0 = coin.totalSupply();
        vm.prank(keeper);
        core.buyback();
        assertLt(coin.totalSupply(), supply0, "bought and burned");
        assertEq(coin.transferAllowance(), 0, "the take consumed the whole allowance");
        assertEq(coin.balanceOf(address(core)), 0);
        vm.prank(trader);
        vm.expectRevert();
        coin.transfer(address(core), 1e18);
    }
}
