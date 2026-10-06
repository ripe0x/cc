// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {Lane, Mainnet, Econ} from "../src/interfaces/Interfaces.sol";

function econ(uint256 startX, uint256 floorX, uint256 drop, uint256 gate) pure returns (Econ memory) {
    return Econ({auctionStartX: startX, auctionFloorX: floorX, dropBps: drop, inventoryGate: gate});
}

/// @notice the four economic dials of the Core: auction start and floor, rate drop, inventory gate. bounds, views,
/// and the effect of each, then the gate (see `GateTest`)
contract EconBoundsTest is Fixture {
    function _core(Econ memory e) internal returns (Core) {
        return new Core(owner, address(coin), address(ctl), lc.stack, lc.rateStart, e);
    }

    function test_defaultsAreTheEngineAsSpecified() public view {
        assertEq(core.AUCTION_START_X(), 40_000);
        assertEq(core.AUCTION_FLOOR_X(), 12_000);
        assertEq(core.DROP_BPS(), 1000);
        assertEq(core.INVENTORY_GATE(), 0);
        assertEq(core.ethHeld(), 0);
    }

    function test_viewsReturnTheConstructorValues() public {
        Core c = _core(econ(25_000, 9_000, 3_000, 40));
        assertEq(c.AUCTION_START_X(), 25_000);
        assertEq(c.AUCTION_FLOOR_X(), 9_000);
        assertEq(c.DROP_BPS(), 3_000);
        assertEq(c.INVENTORY_GATE(), 40);
    }

    function test_auctionStartBounds() public {
        vm.expectRevert(Core.BadAuction.selector);
        _core(econ(14_999, 12_000, 1000, 0));
        vm.expectRevert(Core.BadAuction.selector);
        _core(econ(40_001, 12_000, 1000, 0));
        assertEq(_core(econ(15_000, 12_000, 1000, 0)).AUCTION_START_X(), 15_000);
        assertEq(_core(econ(40_000, 12_000, 1000, 0)).AUCTION_START_X(), 40_000);
    }

    function test_auctionFloorBounds() public {
        vm.expectRevert(Core.BadAuction.selector);
        _core(econ(40_000, 5_999, 1000, 0));
        vm.expectRevert(Core.BadAuction.selector);
        _core(econ(40_000, 12_001, 1000, 0));
        vm.expectRevert(Core.BadAuction.selector);
        _core(econ(40_000, 0, 1000, 0));
        assertEq(_core(econ(40_000, 6_000, 1000, 0)).AUCTION_FLOOR_X(), 6_000);
        assertEq(_core(econ(15_000, 12_000, 1000, 0)).AUCTION_FLOOR_X(), 12_000);
    }

    function test_dropBounds() public {
        vm.expectRevert(Core.BadDrop.selector);
        _core(econ(40_000, 12_000, 999, 0));
        vm.expectRevert(Core.BadDrop.selector);
        _core(econ(40_000, 12_000, 4_001, 0));
        vm.expectRevert(Core.BadDrop.selector);
        _core(econ(40_000, 12_000, 0, 0));
        assertEq(_core(econ(40_000, 12_000, 1_000, 0)).DROP_BPS(), 1_000);
        assertEq(_core(econ(40_000, 12_000, 4_000, 0)).DROP_BPS(), 4_000);
    }

    function test_gateBounds() public {
        assertEq(_core(econ(40_000, 12_000, 1000, 0)).INVENTORY_GATE(), 0);
        for (uint256 g = 1; g < 5; ++g) {
            vm.expectRevert(Core.BadGate.selector);
            _core(econ(40_000, 12_000, 1000, g));
        }
        assertEq(_core(econ(40_000, 12_000, 1000, 5)).INVENTORY_GATE(), 5);
        assertEq(_core(econ(40_000, 12_000, 1000, 200)).INVENTORY_GATE(), 200);
        vm.expectRevert(Core.BadGate.selector);
        _core(econ(40_000, 12_000, 1000, 201));
        vm.expectRevert(Core.BadGate.selector);
        _core(econ(40_000, 12_000, 1000, type(uint256).max));
    }
}

/// @notice the auction curve and the rate drop under other dials than the defaults: start 2x, floor 0.8x, drop 20 percent
contract EconCurveTest is Fixture {
    using FixedPointMathLib for uint256;

    function _econ() internal pure override returns (Econ memory) {
        return econ(20_000, 8_000, 2_000, 0);
    }

    function _expected(uint256 cost, uint256 elapsed) internal pure returns (uint256) {
        uint256 len = 72 hours;
        return cost.mulDivUp(20_000 * len - 12_000 * elapsed.min(len), len * 10_000);
    }

    function test_priceCurveUsesTheConfiguredStartAndFloor() public {
        Composed memory c = _composeOnce();
        (,, uint256 cost,) = core.statementInfo(c.sid);
        assertEq(core.priceOf(c.sid), cost * 2, "opens at the configured start");
        _warp(36 hours);
        assertEq(core.priceOf(c.sid), cost.mulDivUp(14_000, 10_000), "half way between 2x and 0.8x");
        _warp(36 hours);
        assertEq(core.priceOf(c.sid), cost.mulDivUp(8_000, 10_000), "the configured floor at the end");
        _warp(5000 hours);
        assertEq(core.priceOf(c.sid), cost.mulDivUp(8_000, 10_000), "flat at the configured floor");
    }

    /// invariant 3 with the configured floor: no statement is sold below AUCTION_FLOOR_X of its cost, and the floor
    /// here is below the cost, so the sale is under cost
    function test_saleAtTheFloorIsBelowCostAndAboveTheFloor() public {
        Composed memory c = _composeOnce();
        (,, uint256 cost,) = core.statementInfo(c.sid);
        _warp(100 hours);
        uint256 price = core.priceOf(c.sid);
        assertGe(price * 10_000, cost * core.AUCTION_FLOOR_X());
        assertLt(price, cost, "sold under cost");
        address buyer = _user("buyer");
        vm.deal(buyer, price);
        uint256 pot = core.ethPot();
        vm.prank(buyer);
        core.buyStatement{value: price}(c.sid);
        assertEq(core.ethToBuyback(), price * 5000 / 10_000);
        assertEq(core.ethPot(), pot + price - price * 5000 / 10_000);
        _solvent();
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_priceBoundsFollowTheDials(uint256 dt) public {
        Composed memory c = _composeOnce();
        (,, uint256 cost,) = core.statementInfo(c.sid);
        dt = bound(dt, 0, 400 hours);
        _warp(dt);
        uint256 p = core.priceOf(c.sid);
        assertEq(p, _expected(cost, dt));
        assertGe(p * 10_000, cost * 8_000);
        assertLe(p, cost * 2);
    }

    /// a fill of x from a pot of p drops the rate by rate * 20% * x / p
    function test_dropFollowsDropBps() public {
        _fundPot(3 ether);
        uint256 id = _credits(seller, 1)[0];
        uint256 r0 = core.ethRate();
        uint256 x = core.ceilingOf(id);
        uint256 p = core.ethPot();
        vm.prank(seller);
        core.sellForEth(_one(id));
        assertEq(core.ethRate(), r0 - r0 * 2_000 * x / (10_000 * p));
        assertLt(core.ethRate(), r0 - r0 * 1_000 * x / (10_000 * p), "a bigger drop than the default");
    }
}
