// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Core} from "../src/Core.sol";
import {Coin} from "../src/Coin.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {Lane, ICreditStrategy, Mainnet} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {HostileTarget} from "./mocks/HostileTarget.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

/// the full system on a fork, with the real hook and the real pool. swaps, the coin restriction and the rate.
contract LifecycleSwapsTest is Fixture {
    address internal trader;
    address internal other;

    function setUp() public override {
        super.setUp();
        trader = _user("trader");
        other = _user("other");
    }

    /// buys and sells through the pool feed the pot with 9.5 of the 10 points and the creator with 0.5.
    function test_swaps_feedThePotWithTheSplit() public {
        uint256 creator0 = creator.balance;

        // a hundred eth in: fee 10, the pot gets 9.5 and the creator 0.5
        uint256 coinOut = _buyCoin(trader, 100 ether);
        assertEq(core.ethPot(), 9.5 ether);
        assertEq(creator.balance - creator0, 0.5 ether);
        assertEq(core.ethToBuyback(), 0, "swap fees never touch the buyback pot");
        assertEq(address(core).balance, 9.5 ether);
        assertEq(address(hook).balance, 0);

        // half of the coin back out: the fee is a tenth of what the pool paid out, split the same way
        uint256 pot0 = core.ethPot();
        creator0 = creator.balance;
        uint256 net = _sellCoin(trader, coinOut / 2);
        uint256 potGain = core.ethPot() - pot0;
        uint256 creatorGain = creator.balance - creator0;
        uint256 fee = potGain + creatorGain;
        assertEq(creatorGain, fee * 50 / 1000, "creator share");
        assertEq(potGain, fee - fee * 50 / 1000, "pot share");
        assertApproxEqAbs(fee, net * 1000 / 9000, 1, "the trader netted 90 percent of the gross");
        assertApproxEqAbs(fee, (net + fee) / 10, 1, "fee is a tenth of the gross");
        assertEq(core.ethToBuyback(), 0);
        assertEq(address(core).balance, core.ethPot());
        assertEq(coin.pendingDelta(), 0);
        assertEq(coin.totalSupply(), coin.SUPPLY());
        _solvent();
    }

    /// the rate does not climb while the pot cannot afford one average credit, and does not climb retroactively.
    function test_swaps_rateClimbsOnlyOnceFunded() public {
        assertEq(core.ethRate(), core.RATE_START());

        // one average credit costs 1.732e15 wei at the start rate. 0.01 eth in leaves 9.5e14 in the pot.
        _buyCoin(trader, 0.01 ether);
        assertEq(core.ethPot(), 0.00095 ether);
        assertFalse(core.funded());
        _warp(200 hours);
        assertEq(core.ethRate(), core.RATE_START(), "unfunded, no climb");

        // the pot passes the threshold
        _buyCoin(trader, 0.1 ether);
        assertTrue(core.funded());
        assertEq(core.ethRate(), core.RATE_START(), "no retroactive climb");
        _warp(10 hours);
        assertGt(core.ethRate(), core.RATE_START());
        assertApproxEqRel(core.ethRate(), 8_635_699_989_091, 1e9, "ten hours at the top tier after a long wait");

        // a sell that drains nothing keeps climbing, and the climb stops where the pot buys one average credit
        _warp(1000 hours);
        assertEq(core.ethRate(), core.ethPot() * 1e4 / core.AVG_SCORE());
    }

    /// the coin moves only inside pool flows the hook granted, or to and from the core and the dead address.
    function test_coin_transferRestrictionWithTheRealCore() public {
        uint256 bal = _buyCoin(trader, 5 ether);
        assertEq(coin.core(), address(core));
        assertEq(coin.hook(), address(hook));

        address[13] memory refused = [
            other,
            address(hook),
            creator,
            owner,
            address(ctl),
            address(launcher),
            address(router),
            address(lp),
            Mainnet.CREDIT_STRATEGY,
            Mainnet.SEAPORT,
            Mainnet.STATEMENTS,
            Mainnet.CREDITS,
            address(PM)
        ];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(trader);
            vm.expectRevert(Coin.InvalidTransfer.selector);
            coin.transfer(refused[i], 1);
        }

        // an approved spender cannot move it wallet to wallet either
        vm.prank(trader);
        coin.approve(other, bal);
        vm.prank(other);
        vm.expectRevert(Coin.InvalidTransfer.selector);
        coin.transferFrom(trader, creator, 1);

        // the core and the dead address are the only allowlisted parties
        vm.prank(trader);
        coin.transfer(address(core), 1000);
        vm.prank(trader);
        coin.transfer(DEAD, 5);
        assertEq(coin.balanceOf(address(core)), 1000);
        vm.prank(address(core));
        coin.transfer(other, 400);
        vm.prank(DEAD);
        coin.transfer(trader, 5);
        assertEq(coin.balanceOf(other), 400);

        // what the core handed out is stuck again
        vm.prank(other);
        vm.expectRevert(Coin.InvalidTransfer.selector);
        coin.transfer(trader, 1);
        vm.prank(other);
        coin.transfer(address(core), 400);

        // nobody but the hook can grant allowance, not even the core
        vm.prank(address(core));
        vm.expectRevert(Coin.OnlyHook.selector);
        coin.noteDelta(1);
        assertEq(coin.pendingDelta(), 0);
        assertEq(coin.totalSupply(), coin.SUPPLY());
    }

    /// phase 2 doors are shut while the exit module slot is empty.
    function test_phase1_exitDoorsAreClosed() public {
        vm.expectRevert(Core.NoExitModule.selector);
        core.exitStatement(1);
        vm.expectRevert(Core.Dormant.selector);
        core.buybackExit();
        vm.expectRevert(Core.NoExitModule.selector);
        core.sellForExitToken(_one(1));
        vm.expectRevert(Core.NotReady.selector);
        core.composeExit();
        assertEq(core.exitToken(), address(0));
        assertEq(core.exitPoolId(), bytes32(0));
    }
}

/// credit doors against a pot filled by real fees.
contract LifecycleDoorsTest is Fixture {
    using FixedPointMathLib for uint256;

    HostileTarget internal hostile;

    function setUp() public override {
        super.setUp();
        // the owner action waits seven days, which must pass while the pot is empty and the rate cannot climb
        hostile = new HostileTarget();
        _allow(address(hostile));
        _fundPot(20 ether);
    }

    function _dropped(uint256 r, uint256 x, uint256 p) internal pure returns (uint256) {
        return r - r * 1000 * x / (10_000 * p);
    }

    /// sellForEth pays the climbed ceiling out of a pot that real swaps filled, drops the rate per credit, and the
    /// next real swap adds to the same pot.
    function test_sellForEth_againstThePotRealFeesFilled() public {
        uint256[] memory ids = _credits(seller, 3);
        _warp(30 hours);
        uint256 pot = core.ethPot();
        uint256 rate = core.ethRate();
        assertGt(rate, core.RATE_START(), "funded, so the rate climbed");
        assertEq(core.ceilingOf(ids[0]), core.scoreOf(ids[0]) * rate / 1e4);

        uint256[3] memory prices;
        uint256 total;
        uint256 r = rate;
        uint256 p = pot;
        for (uint256 i; i < 3; ++i) {
            prices[i] = core.scoreOf(ids[i]) * r / 1e4;
            total += prices[i];
            r = _dropped(r, prices[i], p);
            p -= prices[i];
        }

        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);

        assertEq(seller.balance - before, total, "paid the sum of the ceilings");
        assertEq(core.ethPot(), pot - total);
        assertEq(core.rateAtCheckpoint(), r, "dropped once per credit");
        assertLt(r, rate);
        assertEq(core.lastFillTime(), block.timestamp);
        assertEq(core.pileSize(Lane.Eth), 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(CREDITS.ownerOf(ids[i]), address(core));
            (bool inPile, Lane lane, uint256 cost,) = core.creditInfo(ids[i]);
            assertTrue(inPile);
            assertEq(uint8(lane), uint8(Lane.Eth));
            assertEq(cost, prices[i]);
        }
        _solvent();

        // a real buy afterwards adds 9.5 percent of its eth to the pot
        _buyCoin(funder, 10 ether);
        assertEq(core.ethPot(), pot - total + 0.95 ether);
        _solvent();
    }

    /// the buyer cannot be front run into a worse price: minOut reverts when the total falls short.
    function test_sellForEth_minOutProtectsTheSeller() public {
        uint256[] memory ids = _credits(seller, 2);
        _warp(10 hours);
        uint256 first = core.ceilingOf(ids[0]);
        uint256 sum = first + core.scoreOf(ids[1]) * _dropped(core.ethRate(), first, core.ethPot()) / 1e4;
        vm.prank(seller);
        vm.expectRevert(Core.Slippage.selector);
        core.sellForEth(ids, sum + 1);
        vm.prank(seller);
        core.sellForEth(ids, sum);
        assertEq(seller.balance, sum);
    }

    struct Snapshot {
        uint256 ethPot;
        uint256 ethToBuyback;
        uint256 balance;
        uint256 rate;
        uint64 checkpointTime;
        uint64 lastFillTime;
        bool funded;
        uint256 pile;
        uint256 saleA;
        uint256 saleB;
        address ownerA;
        address ownerB;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.ethPot = core.ethPot();
        s.ethToBuyback = core.ethToBuyback();
        s.balance = address(core).balance;
        s.rate = core.rateAtCheckpoint();
        s.checkpointTime = core.checkpointTime();
        s.lastFillTime = core.lastFillTime();
        s.funded = core.funded();
        s.pile = core.pileSize(Lane.Eth);
        s.saleA = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        s.saleB = ICreditStrategy(STRATEGY).nftForSale(LISTED_B);
        s.ownerA = CREDITS.ownerOf(LISTED_A);
        s.ownerB = CREDITS.ownerOf(LISTED_B);
    }

    function _assertUnchanged(Snapshot memory s) internal view {
        assertEq(keccak256(abi.encode(_snapshot())), keccak256(abi.encode(s)), "state moved");
    }

    function _buyData(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeCall(ICreditStrategy.sellTargetNFT, (id));
    }

    function _checkListingBuy(uint256 id, uint256 price, bool tipCapBinds) internal {
        uint256 ceiling = core.ceilingOf(id);
        uint256 rate = core.ethRate();
        uint256 pot = core.ethPot();
        uint256 balance = address(core).balance;
        uint256 savings = (ceiling - price) * 1000 / 10_000;
        uint256 capTip = price * 200 / 10_000;
        assertEq(savings > capTip, tipCapBinds, "which bound applies");
        uint256 tip = savings.min(capTip);
        uint256 keeper0 = keeper.balance;

        vm.prank(keeper);
        core.buyListing(price, _buyData(id), id, STRATEGY);

        assertEq(keeper.balance - keeper0, tip, "the caller earns the tip");
        assertEq(CREDITS.ownerOf(id), address(core));
        assertEq(ICreditStrategy(STRATEGY).nftForSale(id), 0, "the strategy sold it");
        assertEq(core.ethPot(), pot - price - tip);
        assertEq(address(core).balance, balance - price - tip);
        assertEq(core.rateAtCheckpoint(), _dropped(rate, price + tip, pot));
        assertEq(core.lastFillTime(), block.timestamp);
        (bool inPile, Lane lane, uint256 cost,) = core.creditInfo(id);
        assertTrue(inPile);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(cost, price + tip, "cost basis includes the tip");
        assertLe(tip * 10_000, price * 200, "tip is at most 2 percent of cost");
        _solvent();
    }

    /// a real CreditStrategy listing bought with the real pot, right where the ceiling first clears the price.
    function test_buyListing_realStrategy_savingsBoundTip() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        assertEq(price, 0.036 ether);
        assertGt(price, core.ceilingOf(LISTED_A), "the start rate is far below the listing");
        vm.prank(keeper);
        vm.expectRevert(Core.AboveCeiling.selector);
        core.buyListing(price, _buyData(LISTED_A), LISTED_A, STRATEGY);

        _warpUntilCeiling(LISTED_A, price);
        _checkListingBuy(LISTED_A, price, false);
    }

    /// far above the price the tip stops at 2 percent of what the core paid.
    function test_buyListing_realStrategy_capBoundTip() public {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _warpUntilCeiling(LISTED_A, price);
        _warp(30 hours);
        _checkListingBuy(LISTED_A, price, true);
    }

    /// a CreditStrategy call that fails reverts only that buy, and the state is exactly what it was.
    function test_buyListing_failingStrategyCallRevertsOnlyThatBuy() public {
        uint256 priceA = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        uint256 priceB = ICreditStrategy(STRATEGY).nftForSale(LISTED_B);
        _warpUntilCeiling(LISTED_A, priceA);
        _warpUntilCeiling(LISTED_B, priceB);
        Snapshot memory s0 = _snapshot();

        // wrong value, the strategy refuses
        vm.prank(keeper);
        vm.expectRevert(Core.CallFailed.selector);
        core.buyListing(priceA - 1, _buyData(LISTED_A), LISTED_A, STRATEGY);
        _assertUnchanged(s0);

        // wrong calldata for the value
        vm.prank(keeper);
        vm.expectRevert(Core.CallFailed.selector);
        core.buyListing(priceA, _buyData(LISTED_B), LISTED_A, STRATEGY);
        _assertUnchanged(s0);

        // the call works but delivers another credit than the one asked for
        vm.prank(keeper);
        vm.expectRevert(Core.NoCredit.selector);
        core.buyListing(priceB, _buyData(LISTED_B), LISTED_A, STRATEGY);
        _assertUnchanged(s0);

        // a credit the strategy holds but does not list
        uint256 unlisted = CreditIds.at(5);
        vm.prank(keeper);
        vm.expectRevert(Core.CallFailed.selector);
        core.buyListing(1, _buyData(unlisted), unlisted, STRATEGY);
        _assertUnchanged(s0);

        // another listing still goes through, and the first one stays for sale
        vm.prank(keeper);
        core.buyListing(priceB, _buyData(LISTED_B), LISTED_B, STRATEGY);
        assertEq(CREDITS.ownerOf(LISTED_B), address(core));
        assertEq(CREDITS.ownerOf(LISTED_A), STRATEGY);
        assertEq(ICreditStrategy(STRATEGY).nftForSale(LISTED_A), priceA);

        // the core never buys a credit it already owns
        vm.prank(keeper);
        vm.expectRevert(Core.AlreadyOwned.selector);
        core.buyListing(priceB, _buyData(LISTED_B), LISTED_B, STRATEGY);
        _solvent();
    }

    /// a target that takes the eth and returns no credit reverts, and nothing moves.
    function test_buyListing_hostileTargetReverts() public {
        Snapshot memory s0 = _snapshot();

        vm.prank(keeper);
        vm.expectRevert(Core.NoCredit.selector);
        core.buyListing(1 gwei, "", LISTED_A, address(hostile));
        _assertUnchanged(s0);
        assertEq(address(hostile).balance, 0, "the eth came back with the revert");

        // not on the list at all
        address stranger = address(new HostileTarget());
        vm.prank(keeper);
        vm.expectRevert(Core.TargetNotAllowed.selector);
        core.buyListing(1 gwei, "", LISTED_A, stranger);

        // removal is immediate
        vm.prank(owner);
        core.removeTarget(address(hostile));
        vm.prank(keeper);
        vm.expectRevert(Core.TargetNotAllowed.selector);
        core.buyListing(1 gwei, "", LISTED_A, address(hostile));
        _assertUnchanged(s0);
    }

    /// the system's own contracts can never become targets, even through the timelock.
    function test_buyListing_forbiddenTargetsCannotBeAdded() public {
        address[6] memory forbidden =
            [address(hook), address(coin), address(PM), address(core), Mainnet.CREDITS, Mainnet.STATEMENTS];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.startPrank(owner);
            core.queue(Core.Action.AddTarget, abi.encode(forbidden[i]));
            vm.warp(block.timestamp + 7 days);
            vm.expectRevert(Core.ForbiddenTarget.selector);
            core.execute(Core.Action.AddTarget, abi.encode(forbidden[i]));
            vm.stopPrank();
            assertFalse(core.allowedTarget(forbidden[i]));
        }
        vm.prank(keeper);
        vm.expectRevert(Core.TargetNotAllowed.selector);
        core.buyListing(1, "", LISTED_A, address(hook));
    }
}

/// the self dealing tip test from section 5.4 of the spec.
contract LifecycleTipTest is Fixture {
    MockMarket internal market;
    address internal lister;

    function setUp() public override {
        super.setUp();
        lister = _user("lister");
        market = new MockMarket();
        // the owner action waits seven days, which must pass while the pot is empty and the rate cannot climb
        _allow(address(market));
        _fundPot(20 ether);
    }

    /// lists the credit on the market at `price`, then has the lister fill it into the core. returns the lister's eth
    function _selfDeal(uint256 id, uint256 price) internal returns (uint256 gained) {
        vm.startPrank(lister);
        CREDITS.setApprovalForAll(address(market), true);
        market.list(id, price);
        vm.stopPrank();
        uint256 before = lister.balance;
        vm.prank(lister);
        core.buyListing(price, abi.encodeCall(MockMarket.fill, (id)), id, address(market));
        gained = lister.balance - before;
        assertEq(CREDITS.ownerOf(id), address(core));
    }

    function _sellThroughTheDoor(uint256 id) internal returns (uint256 gained) {
        uint256 before = lister.balance;
        vm.prank(lister);
        core.sellForEth(_one(id));
        gained = lister.balance - before;
    }

    /// for any listing price up to the ceiling the lister ends with strictly less eth than the sell door pays,
    /// and the tip stays within 2 percent of the cost. at exactly the ceiling the tip is zero and it is break even.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_selfDealingTipNeverPays(uint256 priceSeed, uint256 warpHours) public {
        _warp(bound(warpHours, 0, 100) * 1 hours);
        uint256 id = _credits(lister, 1)[0];
        uint256 ceiling = core.ceilingOf(id);
        uint256 price = bound(priceSeed, 1, ceiling);
        uint256 snap = vm.snapshotState();

        uint256 viaListing = _selfDeal(id, price);
        uint256 tip = viaListing - price;
        assertLe(tip * 10_000, price * 200, "tip within 2 percent of cost");
        assertLe(tip * 10_000, (ceiling - price) * 1000, "tip within a tenth of the savings");

        vm.revertToState(snap);
        uint256 viaDoor = _sellThroughTheDoor(id);
        assertEq(viaDoor, ceiling, "the door pays the ceiling");

        if (price < ceiling) {
            assertLt(viaListing, viaDoor, "self dealing loses against the sell door");
        } else {
            assertEq(tip, 0, "no savings, no tip");
            assertEq(viaListing, viaDoor, "break even at the ceiling");
        }
    }

    /// the edges: a price of one wei, one wei under the ceiling, and the ceiling.
    function test_selfDealing_edges() public {
        _warp(40 hours);
        uint256 id = _credits(lister, 1)[0];
        uint256 ceiling = core.ceilingOf(id);
        uint256[3] memory prices = [uint256(1), ceiling - 1, ceiling];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 3; ++i) {
            uint256 viaListing = _selfDeal(id, prices[i]);
            assertLe((viaListing - prices[i]) * 10_000, prices[i] * 200);
            vm.revertToState(snap);
            uint256 viaDoor = _sellThroughTheDoor(id);
            vm.revertToState(snap);
            assertEq(viaDoor, ceiling);
            if (i < 2) assertLt(viaListing, viaDoor);
            else assertEq(viaListing, viaDoor);
        }
    }
}

/// compose, the auction, the buyback and phase 2 with the real hook and the real pools.
contract LifecycleComposeTest is Fixture {
    using FixedPointMathLib for uint256;

    address internal buyer;
    address internal buybacker;
    address internal xseller;
    address internal xtrader;

    function setUp() public override {
        super.setUp();
        buyer = _user("buyer");
        buybacker = _user("buybacker");
        xseller = _user("xseller");
        xtrader = _user("xtrader");
    }

    /// a funded pot, then 90 hours so the rate climbs to about 21 times the start. an average credit then costs
    /// about 0.036 eth and a page of 80 about 2.9 eth, against the hourly cap of 4 eth
    function _prepare() internal {
        _fundPot(20 ether);
        _warp(90 hours);
    }

    // ------------------------------------------------------------------ compose

    /// compose through ControllerV1: the 80 oldest credits, format 0, the id is the new supply, cost basis, refund.
    function test_compose_throughControllerV1() public {
        _prepare();
        uint256[] memory sold = _fillEthPile(85);
        assertEq(core.pileSize(Lane.Eth), 85);
        Composed memory c = _composeOnce();

        for (uint256 i; i < 80; ++i) {
            assertEq(c.ids[i], sold[i], "the 80 oldest, in pile order");
        }
        assertEq(c.sid, STATEMENTS.supply(), "the statement id equals the supply");
        assertEq(c.sid, c.supplyBefore + 1);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core));
        assertEq(STATEMENTS.creditsOf(c.sid), 80);
        uint256[] memory page = new uint256[](80);
        for (uint256 i; i < 80; ++i) {
            page[i] = c.ids[i];
        }
        assertEq(STATEMENTS.creditScoreOf(c.sid), _sumScores(page));

        // cost basis is the credits plus the gas refund
        (bool held, Lane lane, uint256 basis, uint64 clockStart) = core.statementInfo(c.sid);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(basis, c.cost + c.reimb);
        assertEq(clockStart, c.at);
        uint256[] memory heldIds = core.heldStatements();
        assertEq(heldIds.length, 1);
        assertEq(heldIds[0], c.sid);

        // the five newest credits are still in the pile and in the core, the 80 are gone into the statement
        assertEq(core.pileSize(Lane.Eth), 5);
        assertEq(core.pileHead(Lane.Eth), sold[80]);
        assertEq(CREDITS.balanceOf(address(core)), 5);
        for (uint256 i; i < 80; ++i) {
            (bool inPile,,,) = core.creditInfo(c.ids[i]);
            assertFalse(inPile);
        }

        // gas reimbursement: positive, never above 5 percent of the credits' cost, never above the pot,
        // and here (a low basefee) it tracks the gas of the call at 110 percent of the basefee
        assertGt(c.reimb, 0);
        assertLe(c.reimb, c.cost * 500 / 10_000);
        assertLe(c.reimb, c.potBefore);
        assertEq(keeper.balance, c.reimb);
        assertEq(core.ethPot(), c.potBefore - c.reimb);
        assertGe(c.reimb, (c.gasUsed - 400_000) * composeBasefee * 11 / 10, "at least the gas of the call");
        assertLe(c.reimb, (c.gasUsed + 100_000) * composeBasefee * 11 / 10, "and not more");
        _solvent();

        // the same page at a basefee far above the cap is paid exactly 5 percent of the credits' cost
        uint256 snap = preComposeSnap;
        vm.revertToState(snap);
        composeBasefee = 1000 gwei;
        Composed memory capped = _composeOnce();
        assertEq(capped.sid, c.sid);
        assertEq(capped.cost, c.cost);
        assertEq(capped.reimb, c.cost * 500 / 10_000, "the cap binds exactly");
        (,, uint256 basis2,) = core.statementInfo(capped.sid);
        assertEq(basis2, c.cost + capped.reimb);

        // the controller cannot be asked again, there is no full page left
        vm.expectRevert(Core.NotReady.selector);
        core.compose();
    }

    // ------------------------------------------------------------------ auction and buyback

    function _slice(uint256 pool) internal pure returns (uint256) {
        return pool.min(1 ether);
    }

    struct Before {
        uint256 pool;
        uint256 slice;
        uint256 tip;
        uint256 fee;
        uint256 dead;
        uint256 pmCoin;
        uint256 pmEth;
        uint256 supply;
        uint256 pot;
        uint256 balance;
        uint256 creator;
        uint256 caller;
    }

    /// one buyback with every effect checked against the real pool
    function _buybackAndCheck(address caller) internal returns (uint256) {
        Before memory b;
        b.pool = core.ethToBuyback();
        b.slice = _slice(b.pool);
        b.tip = b.slice * 50 / 10_000;
        b.fee = (b.slice - b.tip) * 1000 / 10_000;
        b.dead = coin.balanceOf(DEAD);
        b.pmCoin = coin.balanceOf(address(PM));
        b.pmEth = address(PM).balance;
        b.supply = coin.totalSupply();
        b.pot = core.ethPot();
        b.balance = address(core).balance;
        b.creator = creator.balance;
        b.caller = caller.balance;

        vm.prank(caller);
        core.buyback();

        _checkBuyback(b, caller);
        return b.slice;
    }

    function _checkBuyback(Before memory b, address caller) internal view {
        uint256 creatorCut = b.fee * 50 / 1000;
        uint256 coreCut = b.fee - creatorCut;
        uint256 coinBurned = coin.balanceOf(DEAD) - b.dead;
        assertGt(coinBurned, 0, "coin arrived at the dead address");
        assertEq(b.pmCoin - coin.balanceOf(address(PM)), coinBurned, "and left the pool");
        assertEq(coin.totalSupply(), b.supply, "supply unchanged");
        assertEq(coin.balanceOf(address(core)), 0, "the core never holds the coin");
        assertEq(core.ethToBuyback(), b.pool - b.slice, "the pot fell by the slice");
        assertEq(caller.balance - b.caller, b.tip, "the caller got the 0.5 percent tip");
        assertEq(creator.balance - b.creator, creatorCut, "creator took 0.5 points of the swap");
        assertEq(core.ethPot() - b.pot, coreCut, "the pot got 9.5 points of the swap back");
        assertEq(address(PM).balance - b.pmEth, b.slice - b.tip - b.fee, "the pool took the swap net of the fee");
        assertEq(address(core).balance, b.balance - b.slice + coreCut);
        assertEq(address(hook).balance, 0);
        assertEq(coin.pendingDelta(), 0, "no allowance left behind");
        assertEq(core.lastBuybackBlock(), block.number);
        _solvent();
    }

    /// buyStatement mid auction, then the buyback against the real pool
    function test_auction_buyStatementThenBuyback() public {
        _prepare();
        Composed memory c = _composeOnce();
        (,, uint256 basis,) = core.statementInfo(c.sid);

        // the price curve, half way down
        uint256 elapsed = 36 hours;
        vm.warp(c.at + elapsed);
        uint256 length = 72 hours;
        uint256 expected = basis.mulDivUp(40_000 * length - 28_000 * elapsed, length * 10_000);
        uint256 price = core.priceOf(c.sid);
        assertEq(price, expected);
        assertGt(price, basis * 12_000 / 10_000);
        assertLt(price, basis * 40_000 / 10_000);

        // buy it, overpaying by one eth that comes back
        vm.deal(buyer, price + 1 ether);
        uint256 pot0 = core.ethPot();
        uint256 toBuyback0 = core.ethToBuyback();
        vm.prank(buyer);
        core.buyStatement{value: price + 1 ether}(c.sid);

        assertEq(STATEMENTS.ownerOf(c.sid), buyer);
        assertEq(buyer.balance, 1 ether, "the excess was refunded");
        assertEq(core.ethToBuyback() - toBuyback0, price / 2, "half to the buyback pot");
        assertEq(core.ethPot() - pot0, price - price / 2, "half to the buying pot");
        (bool held,,,) = core.statementInfo(c.sid);
        assertFalse(held);
        assertEq(core.heldStatements().length, 0);
        vm.expectRevert(Core.NotForSale.selector);
        core.priceOf(c.sid);
        _solvent();

        // the buyback: more than one slice is waiting, so the delay shows
        assertGt(core.ethToBuyback(), 2 ether);
        uint256 first = _buybackAndCheck(buybacker);
        assertEq(first, 1 ether);

        // 25 blocks between calls
        vm.prank(buybacker);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 24);
        vm.prank(buybacker);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 1);
        _buybackAndCheck(buybacker);

        // drained down to the last partial slice
        uint256 last;
        for (uint256 i; i < 10 && core.ethToBuyback() != 0; ++i) {
            vm.roll(block.number + 25);
            uint256 rest = core.ethToBuyback();
            last = _buybackAndCheck(buybacker);
            assertEq(last, _slice(rest));
        }
        assertEq(core.ethToBuyback(), 0);
        assertLt(last, 1 ether, "the last slice was partial");
        vm.roll(block.number + 25);
        vm.expectRevert(Core.NothingToBuy.selector);
        core.buyback();
    }

    // ------------------------------------------------------------------ phase 2

    /// phase 2 on the real hook: exit, buyback through the real exit pool, fees to the pot, the exit token bid, the
    /// exit lane statement and its immediate exit, which compounds the pot.
    function test_phase2_fullLoopOnTheRealHook() public {
        // the owner actions wait seven days, which must pass while the pot is empty and the rate cannot climb
        _enterPhase2();
        _prepare();
        assertEq(core.exitToken(), address(xt));
        assertEq(core.exitModule(), address(mod));
        assertTrue(core.exitPoolId() != bytes32(0));

        // an eth lane statement exits only after the whole auction length
        Composed memory c = _composeOnce();
        vm.expectRevert(Core.AuctionRunning.selector);
        core.exitStatement(c.sid);
        vm.warp(c.at + 72 hours - 1);
        vm.expectRevert(Core.AuctionRunning.selector);
        core.exitStatement(c.sid);
        vm.warp(c.at + 72 hours);

        uint256 required = STATEMENTS.creditScoreOf(c.sid) * UNIT;
        assertEq(core.xPot() + core.xToBuyback(), 0);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "the module has the statement");
        assertEq(xt.balanceOf(address(core)), required);
        assertEq(core.xToBuyback(), required / 2, "half to the buyback");
        assertEq(core.xPot(), required - required / 2, "half to the bid");
        (bool held,,,) = core.statementInfo(c.sid);
        assertFalse(held);
        _solvent();

        _phase2Buyback();
        _phase2Fees();
        _phase2BidAndExitLane();
    }

    function _phase2Buyback() internal {
        uint256 pool = core.xToBuyback();
        uint256 slice = pool.min(20 * core.AVG_SCORE() * UNIT);
        assertLt(slice, pool, "more than one slice is waiting");
        uint256 tip = slice * 50 / 10_000;
        uint256 fee = (slice - tip) * 1000 / 10_000;
        uint256 dead0 = coin.balanceOf(DEAD);
        uint256 pmCoin0 = coin.balanceOf(address(PM));
        uint256 supply0 = coin.totalSupply();
        uint256 claims0 = _hookClaims();
        uint256 owed0 = hook.creatorExitOwed();
        uint256 xPot0 = core.xPot();

        vm.prank(buybacker);
        core.buybackExit();

        uint256 burned = coin.balanceOf(DEAD) - dead0;
        assertGt(burned, 0, "coin to the dead address");
        assertEq(pmCoin0 - coin.balanceOf(address(PM)), burned);
        assertEq(coin.totalSupply(), supply0);
        assertEq(core.xToBuyback(), pool - slice);
        assertEq(xt.balanceOf(buybacker), tip, "the tip is paid in the exit token");
        assertEq(_hookClaims() - claims0, fee, "the hook holds the exit pool fee as claims");
        assertEq(hook.creatorExitOwed() - owed0, fee * 50 / 1000);
        assertEq(core.xPot(), xPot0, "fees reach the pot only when sent");
        assertEq(coin.pendingDelta(), 0);
        assertEq(coin.balanceOf(address(core)), 0);
        _solvent();

        // the delay is its own, 25 blocks
        vm.prank(buybacker);
        vm.expectRevert(Core.TooSoon.selector);
        core.buybackExit();
        vm.roll(block.number + 24);
        vm.prank(buybacker);
        vm.expectRevert(Core.TooSoon.selector);
        core.buybackExit();
        vm.roll(block.number + 1);
        uint256 second = (pool - slice).min(20 * core.AVG_SCORE() * UNIT);
        vm.prank(buybacker);
        core.buybackExit();
        assertEq(core.xToBuyback(), pool - slice - second);
    }

    function _phase2Fees() internal {
        // trades in the exit pool add fees in the exit token
        uint256 coinGot = _buyCoinWithExit(xtrader, 40e18);
        _sellCoinForExit(xtrader, coinGot / 2);
        uint256 claims = _hookClaims();
        uint256 owed = hook.creatorExitOwed();
        assertGt(owed, 0);
        assertGt(claims, owed);
        assertEq(xt.balanceOf(address(hook)), 0, "the hook never holds the token itself");

        // the creator's share
        uint256 creator0 = xt.balanceOf(creator);
        hook.claimCreator();
        assertEq(xt.balanceOf(creator) - creator0, owed);
        assertEq(hook.creatorExitOwed(), 0);

        // the core's share reaches xPot
        uint256 coreShare = claims - owed;
        assertEq(_hookClaims(), coreShare);
        uint256 xPot0 = core.xPot();
        uint256 balance0 = xt.balanceOf(address(core));
        hook.sendExitFeesToCore();
        assertEq(core.xPot() - xPot0, coreShare, "the fees reached xPot");
        assertEq(xt.balanceOf(address(core)) - balance0, coreShare);
        assertEq(_hookClaims(), 0);
        _solvent();

        vm.expectRevert(FeeHook.NothingToClaim.selector);
        hook.sendExitFeesToCore();
    }

    function _phase2BidAndExitLane() internal {
        // the bid climbs while funded
        _warp(10 hours);
        uint256 r = core.xRate();
        assertEq(r, 7000, "6000 plus ten hours at 100 basis points");

        uint256[] memory ids = _credits(xseller, 80);
        uint256 xPotBeforeBids = core.xPot();
        uint256 total;
        uint256[] memory prices = new uint256[](80);
        for (uint256 i; i < 80; ++i) {
            prices[i] = core.scoreOf(ids[i]) * r * UNIT / 10_000;
            total += prices[i];
            r = r.zeroFloorSub(20).max(3000);
        }
        assertLt(total, xPotBeforeBids, "the pot carries the whole page");

        vm.prank(xseller);
        core.sellForExitToken(ids);
        assertEq(xt.balanceOf(xseller), total, "paid in the exit token");
        assertEq(core.xPot(), xPotBeforeBids - total);
        assertEq(core.xRate(), r, "20 basis points down per credit");
        assertEq(core.pileSize(Lane.Exit), 80);
        for (uint256 i; i < 80; ++i) {
            (bool inPile, Lane bidLane, uint256 cost,) = core.creditInfo(ids[i]);
            assertTrue(inPile);
            assertEq(uint8(bidLane), uint8(Lane.Exit));
            assertEq(cost, prices[i]);
            assertEq(CREDITS.ownerOf(ids[i]), address(core));
        }
        _solvent();

        // compose the exit lane. the refund comes from the eth pot, is capped at a notional 5 percent and is not
        // added to the cost basis, which is in the exit token
        uint256 supply0 = STATEMENTS.supply();
        uint256 ethPot0 = core.ethPot();
        uint256 keeper0 = keeper.balance;
        uint256 cap = 80 * core.AVG_SCORE() * core.ethRate() / 1e4;
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.composeExit();
        uint256 reimb = keeper.balance - keeper0;
        uint256 sid = supply0 + 1;
        assertEq(STATEMENTS.supply(), sid);
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        assertEq(core.pileSize(Lane.Exit), 0);
        (bool held, Lane lane, uint256 basis,) = core.statementInfo(sid);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Exit));
        assertEq(basis, total, "the basis is the exit token paid, no refund in it");
        assertGt(reimb, 0);
        assertLe(reimb, cap * 500 / 10_000);
        assertEq(core.ethPot(), ethPot0 - reimb);

        // no auction in the exit lane
        vm.expectRevert(Core.NotForSale.selector);
        core.priceOf(sid);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        vm.expectRevert(Core.NotForSale.selector);
        core.buyStatement{value: 100 ether}(sid);

        // immediate exit, everything to xPot, nothing to the buyback
        uint256 required = STATEMENTS.creditScoreOf(sid) * UNIT;
        uint256 xPot1 = core.xPot();
        uint256 toBuyback1 = core.xToBuyback();
        core.exitStatement(sid);
        assertEq(core.xPot(), xPot1 + required, "all of it back to xPot");
        assertEq(core.xToBuyback(), toBuyback1, "no buyback share in the exit lane");
        assertEq(STATEMENTS.ownerOf(sid), address(mod));

        // compounding: the pot ends above where it stood before the bids were paid
        assertEq(core.xPot(), xPotBeforeBids - total + required);
        assertGt(core.xPot(), xPotBeforeBids, "compounded");
        assertGt(required, total);
        _solvent();
    }

    // ------------------------------------------------------------------ hostile exit module

    /// a module that underpays reverts the exit and changes nothing. a module that cannot be priced reverts too.
    function test_phase2_hostileExitModuleUnderpaysReverts() public {
        _enterPhase2();
        _prepare();
        Composed memory c = _composeOnce();
        vm.warp(c.at + 72 hours);
        bytes32 before = keccak256(abi.encode(core.xPot(), core.xToBuyback(), xt.balanceOf(address(core))));

        // one basis point short
        mod.setShortfallBps(1);
        vm.expectRevert(Core.Underpaid.selector);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core), "the statement never left");
        (bool held,,,) = core.statementInfo(c.sid);
        assertTrue(held);

        // all of it withheld
        mod.setShortfallBps(10_000);
        vm.expectRevert(Core.Underpaid.selector);
        core.exitStatement(c.sid);

        // a module that lowers the unit it pays by after it was set. the core holds the unit from set time
        mod.setShortfallBps(0);
        mod.setUnitPerPoint(1);
        vm.expectRevert(Core.Underpaid.selector);
        core.exitStatement(c.sid);

        assertEq(keccak256(abi.encode(core.xPot(), core.xToBuyback(), xt.balanceOf(address(core)))), before);
        assertEq(STATEMENTS.ownerOf(c.sid), address(core));
        (held,,,) = core.statementInfo(c.sid);
        assertTrue(held);

        // an honest module goes through afterwards
        mod.setUnitPerPoint(UNIT);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod));
        _solvent();
    }
}
