// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "../utils/LiveFixture.sol";
import {IControllerV2} from "../../src/interfaces/IControllerV2.sol";
import {CreditSale, Quote} from "../../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ControllerV2Floor} from "./ControllerV2Floor.sol";

/// the fork replay of docs/reviews/PRICING-REVIEW-2026-10-23.md: the recorded sale of Credits 46817, 109607 and 29255
/// to the bot at block 26,252,999, replayed on a fork pinned at 26,252,994 (29255 was taken at 26,252,995, the other two at 26,252,999) against the live Core and ControllerV2, then
/// the same purchase under the proposed Credit floor reference (docs/specs/PRICING.md) on a controller that differs from
/// the live one only by that term. the suite pins itself at 26,252,994 and skips on a node that cannot serve that block
contract PricingReplayTest is LiveFixture {
    address internal constant BOT = 0x1F353219a4080268f2c8e5ba48880aBEb2714B9E;
    uint256 internal constant PAID = 0.00794 ether;
    /// the WETH the three fetched from OpenSea collection offers within the hour, less the 1 percent fee
    uint256 internal constant RESALE_GROSS = 0.0259 ether;
    uint256 internal constant RESALE_NET = 0.025641 ether;
    /// the top collection offer at the time: the three resales filled at 0.0086, 0.0087 and 0.0086 WETH
    uint256 internal constant FLOOR_THEN = 0.0086 ether;
    IControllerV2 internal live;

    uint256 internal constant PIN = 26252994;

    /// the replay needs its own pin. a node that cannot serve it (the CI anvil forks at the LiveFixture pin) skips the
    /// suite instead of failing it; the evidence run is local against the Tenderly gateway
    function setUp() public override {
        try vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), PIN) returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        vm.setEnv("LIVE_FORK_BLOCK", vm.toString(PIN));
        super.setUp();
        live = IControllerV2(core.controller());
        assertEq(address(live), 0xCD64e368b3d7033B2E2B22Fa5F67f554aB807d36, "ControllerV2 is live at the pin");
    }

    function _ids() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        ids[0] = 46817;
        ids[1] = 109607;
        ids[2] = 29255;
    }

    // promise: the live design sold the three at their booked cost, 0.00794 ETH in all, a third of the OpenSea offers
    function test_liveDesignSoldAtCost() public {
        uint256[] memory ids = _ids();
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            (, uint256 cost,) = core.creditInfo(ids[i]);
            uint256 price = live.creditPrice(ids[i]);
            assertEq(price, cost, "the ask rests on the Core cost floor");
            total += price;
        }
        assertEq(total, 7939114092313716, "the recorded total");
        vm.deal(BOT, 1 ether);
        vm.prank(BOT);
        live.buyCredits{value: total}(ids);
        for (uint256 i; i < 3; ++i) {
            assertEq(CREDITS.ownerOf(ids[i]), BOT);
        }
        assertLt(total * 3, RESALE_NET, "the engine took under a third of what the market paid within the hour");
    }

    // promise: with the Credit floor reference the same purchase is refused at 0.00794 and the asks sum above the resale
    function test_floorReferenceKeepsTheAskAtTheMarket() public {
        uint256[] memory ids = _ids();
        ControllerV2Floor c = _floorController();
        vm.prank(owner);
        c.setFloorBounds(
            ControllerV2Floor.FloorBounds({
                minWei: 0.005 ether, maxWei: 0.03 ether, stepBps: 1_000, minSeconds: 600, spreadBps: 300
            })
        );
        vm.prank(owner);
        c.postCreditFloor(FLOOR_THEN);
        assertEq(c.creditFloorAsk(), FLOOR_THEN * 10_300 / 10_000);
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            uint256 price = c.creditPrice(ids[i]);
            assertEq(price, c.creditFloorAsk(), "every small Credit asks the market floor plus the spread");
            total += price;
        }
        emit log_named_decimal_uint("asks under the floor reference, ETH", total, 18);
        emit log_named_decimal_uint("recorded sale, ETH", PAID, 18);
        emit log_named_decimal_uint("OpenSea resale net of fee, ETH", RESALE_NET, 18);
        assertGt(total, RESALE_NET, "the bot's round trip no longer pays");
        vm.deal(BOT, 1 ether);
        vm.prank(BOT);
        vm.expectRevert(ControllerV2Floor.Underpaid.selector);
        c.buyCredits{value: PAID}(ids);
        // a buyer who pays the ask gives the engine more than three times the recorded sale
        uint256 potBefore = core.ethPot() + core.ethToBuyback();
        vm.prank(BOT);
        c.buyCredits{value: total}(ids);
        uint256 kept = core.ethPot() + core.ethToBuyback() - potBefore;
        emit log_named_decimal_uint("engine pot and buyback after artist cut, ETH", kept, 18);
        assertGt(kept, PAID * 3);
    }

    // promise: a big Credit's ask is unchanged by the floor reference: its per point floor already sits above it
    function test_floorReferenceLeavesBigCreditsAlone() public {
        ControllerV2Floor c = _floorController();
        vm.prank(owner);
        c.setFloorBounds(
            ControllerV2Floor.FloorBounds({
                minWei: 0.005 ether, maxWei: 0.03 ether, stepBps: 1_000, minSeconds: 600, spreadBps: 300
            })
        );
        vm.prank(owner);
        c.postCreditFloor(FLOOR_THEN);
        // 105192, 751.9 points, in the pile at cost 0.0207 ETH
        assertEq(c.creditPrice(105192), live.creditPrice(105192));
    }

    // promise: the poster is bounded: a post outside the band is clamped and a jump beyond the step is cut to the step
    function test_posterIsBounded() public {
        ControllerV2Floor c = _floorController();
        vm.prank(owner);
        c.setFloorBounds(
            ControllerV2Floor.FloorBounds({
                minWei: 0.005 ether, maxWei: 0.03 ether, stepBps: 1_000, minSeconds: 600, spreadBps: 300
            })
        );
        address keeper = address(0xBEEF);
        vm.prank(owner);
        c.setFloorPoster(keeper);
        vm.prank(keeper);
        c.postCreditFloor(1 ether);
        assertEq(c.creditFloorWei(), 0.03 ether, "clamped to the band top");
        _warp(600);
        vm.prank(keeper);
        c.postCreditFloor(0.001 ether);
        assertEq(c.creditFloorWei(), 0.027 ether, "one step down at most");
        vm.prank(keeper);
        vm.expectRevert();
        c.postCreditFloor(0.02 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        c.postCreditFloor(0.02 ether);
    }

    /// a floor controller with the live ControllerV2 settings, selected by the owner, its reference seeded at the spot
    function _floorController() internal returns (ControllerV2Floor c) {
        CreditSale memory credit = CreditSale({
            saleOn: live.creditSaleOn(),
            window: live.creditWindow(),
            spreadBps: live.creditSpreadBps(),
            startBps: live.creditStartBps()
        });
        Quote memory q;
        (
            q.referenceRateBpsPerHour,
            q.referenceStepBps,
            q.tolBps,
            q.referenceMaxStale,
            q.referenceMinSeconds,
            q.minLiquidity
        ) = live.quote();
        c = new ControllerV2Floor(
            address(core), credit, q, live.statementSaleMultiplierBps(), live.statementRedeemDelaySeconds()
        );
        (IControllerV2.Currency c0, IControllerV2.Currency c1, uint24 fee, int24 spacing, address hooks) =
            live.balancePoolKey();
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(IControllerV2.Currency.unwrap(c0)),
            currency1: Currency.wrap(IControllerV2.Currency.unwrap(c1)),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hooks)
        });
        (uint256 spot,) = live.spotPrice();
        vm.prank(owner);
        c.setBalancePoolKey(key, spot);
        vm.prank(owner);
        c.setStatementSales(true);
        _setController(address(c));
        (uint256 v, bool ok) = c.valuePerPoint(true);
        assertTrue(ok && v != 0, "the fresh controller prices");
    }
}
