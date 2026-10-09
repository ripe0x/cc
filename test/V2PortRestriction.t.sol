// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeBase} from "./Fees.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {LeftoverSpender} from "./attackers/V2Port.sol";

/// the restricted v2 coin as the engine meets it: the Core, the router and every holder are off the allowlist (FLOW 29).
/// real coin, real pool, real hook
contract V2PortRestrictionTest is FeeBase {
    error TransferRestricted(address from, address to, uint256 amount);

    function setUp() public override {
        super.setUp();
        _stock();
    }

    function _bought(uint256 pmBefore) internal view returns (uint256) {
        return pmBefore - coin.balanceOf(Mainnet.POOL_MANAGER);
    }

    /// the Core is off the allowlist: the take of the bought coin consumes the whole allowance the hook granted for the swap,
    /// so no allowance is left to spend in the same transaction. the Core ends the buyback holding no coin
    function test_buybackConsumesTheWholeAllowance() public {
        _fillEthBuyback();
        assertFalse(coin.isAllowed(address(core)), "the Core is not on the allowlist");
        LeftoverSpender s = new LeftoverSpender(address(coin), address(core), Mainnet.POOL_MANAGER);
        _buyCoin(address(s), 2 ether);
        uint256 held = coin.balanceOf(address(s));
        assertGt(held, 1_000e18);
        uint256 supply0 = coin.totalSupply();
        s.run(1_000e18);
        assertGt(supply0 - coin.totalSupply(), 0, "the buyback burned");
        assertEq(s.leftover(), 0, "the take consumed the whole allowance");
        assertFalse(s.spent(), "nothing was left to spend");
        assertEq(coin.balanceOf(address(s)), held, "the stranger's coin did not move");
        assertEq(coin.balanceOf(address(core)), 0, "the Core holds no coin after the buyback");
    }

    /// the buyback burns exactly the coin the pool paid out
    function test_buybackBurnsWhatItBought() public {
        _fillEthBuyback();
        uint256 pm0 = coin.balanceOf(Mainnet.POOL_MANAGER);
        uint256 supply0 = coin.totalSupply();
        vm.prank(keeper);
        core.buyback();
        uint256 bought = _bought(pm0);
        assertGt(bought, 0);
        assertEq(supply0 - coin.totalSupply(), bought);
        assertEq(coin.balanceOf(address(core)), 0);
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

    /// a holder that is not on the allowlist cannot send coin to the Core: the Core is not on it either
    function test_aWalletCannotSendCoinToTheCore() public {
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(TransferRestricted.selector, trader, address(core), 1_000e18));
        coin.transfer(address(core), 1_000e18);
        assertEq(coin.balanceOf(address(core)), 0);
        assertEq(core.ethPot(), pot);
        assertEq(core.ethToBuyback(), bb);
        _solvent();
    }

    /// the restriction passes a transfer when either side is on the allowlist. coin sent from a holder the coin admin
    /// lists stays in the Core, outside every book, and the buyback burns only what it bought
    function test_ACCEPTED_coinFromAListedHolderStaysInTheCore() public {
        vm.prank(owner);
        coin.setAllowed(trader, true);
        _fillEthBuyback();
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        vm.prank(trader);
        coin.transfer(address(core), 1_000e18);
        assertEq(coin.balanceOf(address(core)), 1_000e18);
        assertEq(core.ethPot(), pot);
        assertEq(core.ethToBuyback(), bb);
        uint256 pm0 = coin.balanceOf(Mainnet.POOL_MANAGER);
        uint256 supply0 = coin.totalSupply();
        vm.prank(keeper);
        core.buyback();
        assertEq(supply0 - coin.totalSupply(), _bought(pm0), "the buyback burned only what it bought");
        assertEq(coin.balanceOf(address(core)), 1_000e18, "the sent coin was not touched");
        _solvent();
    }

    /// with the restriction turned off by the coin admin, plain transfers work, a transfer to the Core is inert in the same
    /// way, and the buyback behaves as before
    function test_unrestrictedTransferToTheCoreIsInert() public {
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
        assertEq(coin.balanceOf(address(core)), 1e18, "the transferred coin stays");
        _solvent();
    }
}
