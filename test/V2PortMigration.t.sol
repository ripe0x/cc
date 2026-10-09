// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeBase} from "./Fees.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {Prod} from "./utils/Prod.sol";
import {RefusingEngine, GasBurnerEngine} from "./attackers/FlushEngines.sol";

/// moving the fee stream to a new engine: a second Core on the same coin and stack with the router as fee source, the
/// router repointed, and a router whose engine is broken. real v2 stack, real pool
contract V2PortMigrationTest is FeeBase {
    ICore internal core2;
    IControllerV1 internal ctl2;

    /// @dev the second engine, deployed by a fresh account the way the first was: controller, then Core. the stack is the
    /// first one's, with the router as fee source. the coin allowlist does not list it
    function _deployCore2() internal {
        address dep = _user("second deployer");
        uint64 n = vm.getNonce(dep);
        address ctlAt = vm.computeCreateAddress(dep, n);
        address coreAt = vm.computeCreateAddress(dep, n + 1);
        vm.startPrank(dep);
        ctl2 = Prod.newController(coreAt, lc.sale);
        core2 = Prod.newCore(owner, address(coin), address(ctl2), lc.stack, lc.rateStart, lc.settings);
        vm.stopPrank();
        assertEq(address(ctl2), ctlAt);
        assertEq(address(core2), coreAt);
        assertEq(core2.FEE_SOURCE(), address(feeRouter));
        assertEq(core2.COIN(), address(coin));
    }

    function _repoint() internal {
        vm.prank(owner);
        feeRouter.setEngine(address(core2));
    }

    /// repointing: fees flow to the new Core and book there, the old Core books nothing more and keeps working on what it
    /// holds, and the router never moved what the old Core already had
    function test_repointMovesTheFeesAndTheOldCoreKeepsWorking() public {
        _stock();
        _fillEthPile(80);
        _deployCore2();
        uint256 pot1 = core.ethPot();
        uint256 bal1 = address(core).balance;
        assertGt(pot1, 0);
        _repoint();

        autoFlush = false;
        _buyCoin(trader, 1 ether);
        (, uint256 toEngine) = _routerSplit(address(feeRouter).balance);
        vm.prank(flusher);
        feeRouter.flush();
        assertEq(core2.ethPot(), toEngine, "the new Core booked the fees");
        assertEq(address(core2).balance, toEngine);
        assertEq(core.ethPot(), pot1, "the old Core books nothing more");
        assertEq(address(core).balance, bal1, "and received nothing");

        // the old Core still composes and sells with what it holds
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        _bid(trader, sid, _live(sid).reserve);
        _endAuction(sid);
        _collectSales();
        _solvent();
        assertEq(core2.ethPot(), toEngine, "the new Core is untouched by the old one's work");
    }

    /// the new Core is not on the coin allowlist and still buys back: the hook grants exactly the allowance the take
    /// needs. nobody can send it coin, which is the point of not listing it
    function test_newCoreWithoutAllowlistBuysBack() public {
        _stock();
        _deployCore2();
        _repoint();
        Settings memory s = core2.settings();
        s.feeToBuybackBps = 10_000;
        vm.prank(owner);
        core2.setSettings(s);
        assertFalse(coin.isAllowed(address(core2)));
        autoFlush = false;
        _buyCoin(trader, 5 ether);
        vm.prank(flusher);
        feeRouter.flush();
        assertGt(core2.ethToBuyback(), 0);
        vm.prank(trader);
        vm.expectRevert();
        coin.transfer(address(core2), 1e18);

        uint256 supply0 = coin.totalSupply();
        uint256 bb0 = core2.ethToBuyback();
        vm.prank(keeper);
        core2.buyback();
        assertLt(coin.totalSupply(), supply0, "bought and burned");
        assertLt(core2.ethToBuyback(), bb0);
        assertEq(coin.balanceOf(address(core2)), 0);
        assertEq(coin.transferAllowance(), 0, "the take consumed the whole allowance");
        assertLe(core2.ethPot() + core2.ethToBuyback(), address(core2).balance);
    }

    /// `lock()` freezes the engine: the stream keeps flowing to the engine set at that time and nobody can repoint it
    function test_lockFreezesTheEngine() public {
        _stock();
        _deployCore2();
        _repoint();
        vm.prank(owner);
        feeRouter.lock();
        vm.prank(owner);
        vm.expectRevert();
        feeRouter.setEngine(address(core));
        autoFlush = false;
        _buyCoin(trader, 1 ether);
        (, uint256 toEngine) = _routerSplit(address(feeRouter).balance);
        uint256 pot1 = core.ethPot();
        vm.prank(flusher);
        feeRouter.flush();
        assertEq(core2.ethPot(), toEngine);
        assertEq(core.ethPot(), pot1);
        assertEq(feeRouter.engine(), address(core2));
    }

    /// an engine that refuses eth: every swap still works (the hook only pushes into the empty `receive`), the fees wait in
    /// the router, `flush` reverts and nothing leaves. the owner repoints and the next flush pays everything out
    function test_refusingEngineNeverBlocksSwapsAndTheEthWaits() public {
        _stock();
        RefusingEngine bad = new RefusingEngine();
        vm.prank(owner);
        feeRouter.setEngine(address(bad));
        autoFlush = false;
        uint256 held0 = address(feeRouter).balance;
        for (uint256 i; i < 3; ++i) {
            _buyCoin(trader, 1 ether);
            _sellCoin(trader, coin.balanceOf(trader) / 10);
        }
        uint256 held = address(feeRouter).balance;
        assertGt(held, held0 + 0.18 ether, "three buys of 1 eth left their router share waiting");
        vm.prank(flusher);
        vm.expectRevert(abi.encodeWithSignature("FlushFailed()"));
        feeRouter.flush();
        assertEq(address(feeRouter).balance, held, "nothing left the router");

        uint256 pot0 = core.ethPot();
        vm.prank(owner);
        feeRouter.setEngine(address(core));
        (, uint256 toEngine) = _routerSplit(held);
        vm.prank(flusher);
        feeRouter.flush();
        assertEq(address(feeRouter).balance, 0);
        assertEq(core.ethPot() - pot0, toEngine, "everything that waited reached the right engine");
        _solvent();
    }

    /// an engine that burns all the gas it is given cannot make a swap fail either, and its flush fails cleanly
    function test_gasBurningEngineNeverBlocksSwaps() public {
        _stock();
        GasBurnerEngine bad = new GasBurnerEngine();
        vm.prank(owner);
        feeRouter.setEngine(address(bad));
        autoFlush = false;
        _buyCoin(trader, 1 ether);
        _sellCoin(trader, coin.balanceOf(trader) / 3);
        uint256 held = address(feeRouter).balance;
        assertGt(held, 0);
        vm.prank(flusher);
        vm.expectRevert();
        feeRouter.flush{gas: 3_000_000}();
        assertEq(address(feeRouter).balance, held);
    }
}
