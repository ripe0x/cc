// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {Settings, CreditSale} from "../src/interfaces/Interfaces.sol";
import {Phase2Claims} from "../script/Phase2Claims.s.sol";

/// the 2026-10-28 owner session rehearsed on a fork of the live state: the pricing and burn split settings, the
/// credit cost share, then the claim allocate and enable, each followed by the real transaction it changes
contract SettingsRehearsalTest is LiveFixture {
    IControllerV2 internal ctl2;
    address internal user;
    IPhase2BalanceTreasury internal t;
    address internal constant CONTROLLER_V2 = 0xCD64e368b3d7033B2E2B22Fa5F67f554aB807d36;
    address internal constant TREASURY_V1 = 0xB85CF439Ca57b4bfC28fA1Cb8a97Ee85555B0496;

    function setUp() public override {
        super.setUp();
        ctl2 = IControllerV2(CONTROLLER_V2);
        user = _user("rehearsal user");
        t = IPhase2BalanceTreasury(TREASURY_V1);
        // the session is rehearsed against the live stage C state (ControllerV2 and the v1 treasury bound): run with
        // LIVE_FORK_BLOCK at a current block; the default pin predates that stage and the suite skips there
        if (core.controller() != CONTROLLER_V2 || core.balanceModule() != TREASURY_V1) vm.skip(true);
    }

    /// the owner session: SetSettings fields on the Core and V2, the cost share, then the claim steps
    function _session() internal {
        Settings memory cfg = core.settings();
        cfg.saleToBuybackBps = 5_000;
        cfg.feeToRedeemBurnBps = 2_500;
        cfg.redeemBurnBps = 5_000;
        cfg.balanceBidCapBps = 10_000;
        vm.startPrank(owner);
        core.setSettings(cfg);
        ctl2.setCredit(CreditSale({saleOn: true, window: ctl2.creditWindow(), spreadBps: 1_000, startBps: 13_636}));
        ctl2.setStatementSaleMultiplierBps(10_000);
        core.setCreditCostToPotBps(5_000);
        vm.stopPrank();
    }

    function test_pricingAfterTheSession() public {
        // promise: after the session the exchange pays 95 percent of par in balance, a bought credit lists at 1.5 par and decays to 1.1 par, and its eth cost basis sits under that floor
        _session();
        assertEq(ctl2.floorMultBps(), 11_000, "credit floor 1.1 par");
        uint256[] memory ids = _credits(seller, 1);
        uint256 id = ids[0];
        uint256 par = ctl2.valueOf(_scoreOf(id));
        uint256 quote = core.balanceBidOf(id);
        assertApproxEqRel(quote, _scoreOf(id) * 1e14 * 95 / 100, 1e15, "the exchange still pays 95 percent of par in balance");
        vm.prank(seller);
        core.sellForBalance(ids);
        (bool inPile, uint256 cost,) = core.creditInfo(id);
        assertTrue(inPile);
        uint256 start = ctl2.creditPrice(id);
        assertApproxEqRel(start, par * 11_000 / 10_000 * 13_636 / 10_000, 2e16, "lists at about 1.5 par");
        vm.warp(block.timestamp + ctl2.creditWindow() + 1);
        uint256 floor = ctl2.creditPrice(id);
        uint256 expectFloor = par * 11_000 / 10_000;
        if (cost > expectFloor) expectFloor = cost;
        assertEq(floor, expectFloor, "decays to 1.1 par, or the eth cost basis when that is higher");
        emit log_named_decimal_uint("par (eth)", par, 18);
        emit log_named_decimal_uint("start ask (eth)", start, 18);
        emit log_named_decimal_uint("floor ask (eth)", floor, 18);
        emit log_named_decimal_uint("booked cost (eth)", cost, 18);
    }

    function test_creditSaleSplitsHalfTheCostToThePotRestBurns() public {
        // promise: a credit sold in eth sends 3 percent to the artist, half its cost basis to the pot and the rest to the buyback
        _session();
        uint256[] memory ids = _credits(seller, 1);
        uint256 id = ids[0];
        vm.prank(seller);
        core.sellForBalance(ids);
        vm.warp(block.timestamp + ctl2.creditWindow() + 1);
        uint256 price = ctl2.creditPrice(id);
        (, uint256 cost,) = core.creditInfo(id);
        uint256 pot0 = core.ethPot();
        uint256 bb0 = core.ethToBuyback();
        vm.deal(user, price);
        vm.prank(user);
        ctl2.buyCredit{value: price}(id);
        uint256 toArtist = price * 300 / 10_000;
        uint256 rest = price - toArtist;
        uint256 toPot = cost * 5_000 / 10_000;
        if (toPot > rest) toPot = rest;
        assertEq(core.ethPot() - pot0, toPot, "half the cost basis to the pot");
        assertEq(core.ethToBuyback() - bb0, rest - toPot, "the rest to the buyback");
        emit log_named_decimal_uint("sale (eth)", price, 18);
        emit log_named_decimal_uint("to pot (eth)", core.ethPot() - pot0, 18);
        emit log_named_decimal_uint("to buyback (eth)", core.ethToBuyback() - bb0, 18);
    }

    /// fills the pile through the balance exchange, ages the page past the credit window with the reference kept
    /// fresh, composes. returns the statement and the summed eth cost basis of its credits
    function _composeViaExchange() internal returns (uint256 sid, uint256 cost) {
        uint256 size = core.pileSize();
        if (size < 80) {
            uint256[] memory ids = _credits(seller, 80 - size);
            vm.prank(seller);
            core.sellForBalance(ids);
        }
        uint256[] memory page = core.pilePage(0, 80);
        for (uint256 i; i < 80; ++i) {
            (, uint256 ci,) = core.creditInfo(page[i]);
            cost += ci;
        }
        uint256 window = ctl2.creditWindow();
        for (uint256 step; step * 1 hours <= window; ++step) {
            vm.warp(block.timestamp + 1 hours);
            vm.roll(block.number + 1);
            core.refreshReference();
        }
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
        (bool held,,) = core.statementInfo(sid);
        assertTrue(held, "the Core holds the new Statement");
    }

    function test_statementAskAndSaleSplit() public {
        // promise: a composed statement asks 1.1 par or its eth cost when higher, and a sale splits the rest after the artist cut half to the buyback and half to the pot
        _session();
        (uint256 sid, uint256 cost) = _composeViaExchange();
        Composed memory c;
        c.sid = sid;
        c.cost = cost;
        uint256 par = ctl2.valueOf(core.ratingOf(c.sid));
        uint256 ask = ctl2.priceOf(c.sid);
        uint256 expect = par * 11_000 / 10_000;
        if (c.cost > expect) expect = c.cost;
        assertApproxEqRel(ask, expect, 1e14, "statement asks 1.1 par, or its eth cost when higher");
        uint256 pot0 = core.ethPot();
        uint256 bb0 = core.ethToBuyback();
        vm.deal(user, ask);
        vm.prank(user);
        ctl2.buy{value: ask}(c.sid);
        uint256 rest = ask - ask * 300 / 10_000;
        assertEq(core.ethToBuyback() - bb0, rest * 5_000 / 10_000, "half of the rest burns");
        assertEq(core.ethPot() - pot0, rest - rest * 5_000 / 10_000, "half to the pot");
        emit log_named_decimal_uint("statement par (eth)", par, 18);
        emit log_named_decimal_uint("statement ask (eth)", ask, 18);
        emit log_named_decimal_uint("statement cost basis (eth)", c.cost, 18);
    }

    function test_conversionReleasesHalfTheBurnPotAndFundsTheClaim() public {
        // promise: a statement conversion lands at par in balance, 10 percent into the claim reserve, and releases half the redeem burn pot into the buyback
        _session();
        (uint256 sid,) = _composeViaExchange();
        Composed memory c;
        c.sid = sid;
        vm.warp(block.timestamp + 2 hours);
        uint256 burnPot0 = core.ethRedeemBurn();
        uint256 bb0 = core.ethToBuyback();
        uint256 reserve0 = t.claimReserve();
        uint256 custody0 = t.custody();
        core.redeemStatement(c.sid);
        uint256 got = t.custody() - custody0;
        assertGe(got, core.ratingOf(c.sid) * 1e14, "converts at par in balance");
        assertEq(t.claimReserve() - reserve0, got / 10, "10 percent of the conversion into the claim reserve");
        assertEq(burnPot0 - core.ethRedeemBurn(), burnPot0 * 5_000 / 10_000, "half the burn pot released");
        assertEq(core.ethToBuyback() - bb0, burnPot0 * 5_000 / 10_000, "into the buyback");
        emit log_named_decimal_uint("converted (balance)", got, 18);
        emit log_named_decimal_uint("burn pot before (eth)", burnPot0, 18);
    }

    function test_claimAllocateAndEnableThroughTheScript() public {
        // promise: the Phase2Claims allocate and enable steps move the surplus into the claim reserve leaving the cushion working, and a real cc burn pays its pro rata quote
        _session();
        Phase2Claims s = new Phase2Claims();
        uint256 free = t.freeWorking();
        uint256 amount = 363_044 ether;
        assertGe(free, amount, "the surplus is free working funds");
        uint256 reserve0 = t.claimReserve();
        vm.startPrank(owner);
        s.execute(Phase2Claims.Inputs({treasury: TREASURY_V1, step: "allocate", amount: amount, allowEmpty: false}), false);
        vm.stopPrank();
        assertEq(t.claimReserve(), reserve0 + amount, "reserve after allocate");
        assertEq(t.available(), free - amount, "the exchange keeps about 150k working");
        vm.startPrank(owner);
        s.execute(Phase2Claims.Inputs({treasury: TREASURY_V1, step: "enable", amount: 0, allowEmpty: false}), false);
        vm.stopPrank();
        assertTrue(t.ccRedemptionEnabled());
        uint256 supply = coin.totalSupply();
        (uint256 out,,,, bool exec) = t.quoteRedemption(supply / 100);
        assertTrue(exec, "a claim executes");
        assertApproxEqRel(out, t.claimReserve() / 100, 1e12, "burning 1 percent of supply pays 1 percent of the reserve");
        uint256 cc = _buyCoin(user, 0.05 ether);
        vm.startPrank(user);
        coin.approve(TREASURY_V1, cc);
        uint256 held = _balanceOf(user);
        (uint256 q,,, uint64 epoch,) = t.quoteRedemption(cc);
        uint256 paid = t.redeemCC(cc, user, 0, block.timestamp, epoch);
        vm.stopPrank();
        assertEq(paid, q, "paid the quote");
        assertEq(_balanceOf(user) - held, paid, "balance delivered");
        assertEq(coin.totalSupply(), supply - cc, "the cc was burned");
        emit log_named_decimal_uint("claim per 1 percent of supply (balance)", out, 18);
        emit log_named_decimal_uint("balance per cc (x 1e18)", t.claimReserve() * 1e18 / supply, 18);
    }
}
