// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Core} from "../src/Core.sol";
import {Lane, ICreditStrategy, Mainnet} from "../src/interfaces/Interfaces.sol";
import {Fixture} from "./utils/Fixture.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {HostileTarget} from "./attackers/HostileTarget.sol";

/// the full system on a fork: the live artcoins stack, the live credits stack, the real core. fees come from real
/// swaps in the real pool. the exact fee split is pinned in Fees.t.sol, here only what the doors do with the pot
contract LifecycleSwapsTest is Fixture {
    address internal trader;

    function setUp() public override {
        super.setUp();
        trader = _user("trader");
        _skipSniperWindow();
    }

    /// real swaps are what feeds the pot, and nothing else moves it
    function test_swaps_feedThePot() public {
        assertEq(core.ethPot(), 0);
        uint256 coinOut = _buyCoin(trader, 100 ether);
        assertGt(coinOut, 0);
        uint256 pot = core.ethPot();
        assertGt(pot, 0, "a buy feeds the pot");
        assertEq(address(core).balance, pot, "every wei of the balance is booked");
        assertEq(core.ethToBuyback(), 0, "swap fees never touch the buyback pot");

        _sellCoin(trader, coinOut / 2);
        assertGt(core.ethPot(), pot, "a sell feeds the pot too");
        assertEq(address(core).balance, core.ethPot());
        assertEq(coin.totalSupply(), 1_000_000_000e18, "swaps burn nothing");
        _solvent();
    }

    /// the rate does not climb while the pot cannot afford one average credit, and does not climb retroactively
    function test_swaps_rateClimbsOnlyOnceFunded() public {
        assertEq(core.ethRate(), core.RATE_START());

        // one average credit costs 1.732e15 wei at the start rate. a small buy leaves less than that in the pot
        _buyCoin(trader, 0.01 ether);
        assertLt(core.ethPot(), 1.7e15);
        assertFalse(core.funded());
        _warp(200 hours);
        assertEq(core.ethRate(), core.RATE_START(), "unfunded, no climb");

        // the pot passes the threshold
        _buyCoin(trader, 0.1 ether);
        assertTrue(core.funded());
        assertEq(core.ethRate(), core.RATE_START(), "no retroactive climb");
        _warp(10 hours);
        assertGt(core.ethRate(), core.RATE_START());

        // the climb stops where the pot buys one average credit
        _warp(2000 hours);
        assertEq(core.ethRate(), core.ethPot() * 1e4 / core.AVG_SCORE());
    }

    /// phase 2 doors are shut while the exit module slot is empty
    function test_phase1_exitDoorsAreClosed() public {
        vm.expectRevert(Core.NoExitModule.selector);
        core.exitStatement(1);
        vm.expectRevert(Core.NoExitModule.selector);
        core.buybackExit(type(uint256).max);
        vm.expectRevert(Core.NoExitModule.selector);
        core.sellForExitToken(_one(1));
        vm.expectRevert(Core.NotReady.selector);
        core.composeExit();
        assertEq(core.exitToken(), address(0));
        assertEq(core.exitModule(), address(0));
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

        // a real buy afterwards adds to the same pot
        _buyCoin(funder, 10 ether);
        assertGt(core.ethPot(), pot - total);
        assertEq(address(core).balance, core.ethPot(), "everything held is booked");
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
        uint256 hostile0 = address(hostile).balance;

        vm.prank(keeper);
        vm.expectRevert(Core.NoCredit.selector);
        core.buyListing(1 gwei, "", LISTED_A, address(hostile));
        _assertUnchanged(s0);
        assertEq(address(hostile).balance, hostile0, "the eth came back with the revert");

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
        address[9] memory forbidden = [
            Mainnet.SKIM_HOOK,
            address(coin),
            address(PM),
            address(core),
            Mainnet.CREDITS,
            Mainnet.STATEMENTS,
            Mainnet.ARTCOINS_FACTORY,
            Mainnet.LP_LOCKER,
            Mainnet.FEE_ESCROW
        ];
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
        core.buyListing(1, "", LISTED_A, Mainnet.SKIM_HOOK);
    }
}

/// compose, the auction and the real buyback against the real pool
contract LifecycleComposeTest is Fixture {
    using FixedPointMathLib for uint256;

    address internal buyer;
    address internal buybacker;

    function setUp() public override {
        super.setUp();
        buyer = _user("buyer");
        buybacker = _user("buybacker");
        _skipSniperWindow();
    }

    /// a funded pot, then 90 hours so the rate climbs to about 21 times the start. an average credit then costs
    /// about 0.036 eth and a page of 80 about 2.9 eth, against the hourly cap of 4 eth
    function _prepare() internal {
        _fundPot(20 ether);
        _warp(90 hours);
    }

    // ------------------------------------------------------------------ compose

    /// compose through ControllerV1: the 80 oldest credits, format 0, the id is the new supply, cost basis, refund
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

        // reimbursement: positive, never above 5 percent of the credits' cost, never above the pot, and at a low
        // basefee it tracks the gas of the call at 110 percent of the basefee
        assertGt(c.reimb, 0);
        assertLe(c.reimb, c.cost * 500 / 10_000);
        assertLe(c.reimb, c.potBefore);
        assertEq(keeper.balance, c.reimb);
        assertEq(core.ethPot(), c.potBefore - c.reimb);
        assertGe(c.reimb, (c.gasUsed - 400_000) * composeBasefee * 11 / 10, "at least the gas of the call");
        assertLe(c.reimb, (c.gasUsed + 100_000) * composeBasefee * 11 / 10, "and not more");
        _solvent();

        // the same page at a basefee far above the cap is paid exactly 5 percent of the credits' cost
        vm.revertToState(preComposeSnap);
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

    struct Before {
        uint256 pool;
        uint256 slice;
        uint256 supply;
        uint256 pot;
        uint256 balance;
        uint256 caller;
        uint256 pmCoin;
    }

    /// one real buyback with its effects checked against the real pool. the skim on the swap returns to the pot
    function _buybackAndCheck(address caller) internal returns (uint256) {
        Before memory b;
        b.pool = core.ethToBuyback();
        b.slice = b.pool.min(1 ether);
        b.supply = coin.totalSupply();
        b.pot = core.ethPot();
        b.balance = address(core).balance;
        b.caller = caller.balance;
        b.pmCoin = coin.balanceOf(address(PM));

        vm.prank(caller);
        core.buyback();

        uint256 burned = b.supply - coin.totalSupply();
        assertGt(burned, 0, "real burn: the total supply fell");
        assertEq(b.pmCoin - coin.balanceOf(address(PM)), burned, "the coin came out of the pool and was burned");
        assertEq(coin.balanceOf(address(core)), 0, "the core never holds the coin");
        assertEq(coin.balanceOf(DEAD), 0, "burned, not parked");
        assertEq(caller.balance - b.caller, b.slice * 50 / 10_000, "the caller got the 0.5 percent tip");
        assertEq(core.ethToBuyback(), b.pool - b.slice, "the pot fell by one slice");
        assertGt(core.ethPot(), b.pot, "the skim of the swap came back into the pot");
        assertEq(core.lastBuybackBlock(), block.number);
        assertLe(address(core).balance, b.balance, "the swap spent eth net of what came back");
        _solvent();
        return b.slice;
    }

    /// buyStatement mid auction, then the real buyback burns coin
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
        assertEq(_buybackAndCheck(buybacker), 1 ether);

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
            assertEq(last, rest.min(1 ether));
        }
        assertEq(core.ethToBuyback(), 0);
        assertLt(last, 1 ether, "the last slice was partial");
        vm.roll(block.number + 25);
        vm.expectRevert(Core.NothingToBuy.selector);
        core.buyback();
    }
}

/// phase 2 with the stand in exit module and exit token: exit, the 50/50 split, the dutch auction against the real
/// coin, the exit token bid and the exit lane
contract LifecyclePhase2Test is Fixture {
    using FixedPointMathLib for uint256;

    address internal taker;
    address internal xseller;
    address internal buyer;

    function setUp() public override {
        super.setUp();
        taker = _user("taker");
        xseller = _user("xseller");
        buyer = _user("buyer");
        // the owner action waits seven days, which must pass while the pot is empty and the rate cannot climb
        _enterPhase2();
        _skipSniperWindow();
        _fundPot(20 ether);
        _warp(90 hours);
    }

    /// an eth lane statement exits only after the whole auction length, and half of what the module pays goes to the
    /// buyback share, half to the bid
    function _exitTheStatement() internal returns (Composed memory c, uint256 required) {
        assertEq(core.exitToken(), address(xt));
        assertEq(core.exitModule(), address(mod));
        c = _composeOnce();
        vm.expectRevert(Core.AuctionRunning.selector);
        core.exitStatement(c.sid);
        vm.warp(c.at + 72 hours - 1);
        vm.expectRevert(Core.AuctionRunning.selector);
        core.exitStatement(c.sid);
        vm.warp(c.at + 72 hours);

        required = STATEMENTS.creditScoreOf(c.sid) * UNIT;
        assertEq(core.xPot() + core.xToBuyback(), 0);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "the module has the statement");
        assertEq(xt.balanceOf(address(core)), required);
        assertEq(core.xToBuyback(), required / 2, "half to the buyback");
        assertEq(core.xPot(), required - required / 2, "half to the bid");
        (bool held,,,) = core.statementInfo(c.sid);
        assertFalse(held);
        _solvent();
    }

    function test_phase2_exitStatementThenDutchAuctionFill() public {
        (, uint256 required) = _exitTheStatement();
        uint256 pool = core.xToBuyback();
        uint256 fullSlice = 20 * core.AVG_SCORE() * UNIT;
        assertLt(fullSlice, pool, "more than one slice is waiting");

        // a taker buys coin in the real pool and waits for the price to fall to what the coin can pay
        _buyCoin(taker, 40 ether);
        vm.prank(taker);
        coin.approve(address(core), type(uint256).max);
        uint256 slice;
        uint256 coinIn;
        for (uint256 i; i < 400; ++i) {
            (slice, coinIn) = core.exitAuctionQuote();
            if (coinIn <= coin.balanceOf(taker)) break;
            _warp(1 hours);
        }
        assertEq(slice, fullSlice);
        assertGt(coinIn, 0);
        uint256 price = core.exitAuctionPrice();
        assertEq(coinIn, slice.mulDivUp(price, 1e18));

        uint256 supply0 = coin.totalSupply();
        uint256 taker0 = coin.balanceOf(taker);
        vm.prank(taker);
        core.buybackExit(coinIn);
        assertEq(taker0 - coin.balanceOf(taker), coinIn, "the taker paid the quote in coin");
        assertEq(supply0 - coin.totalSupply(), coinIn, "and it was burned, total supply fell");
        assertEq(xt.balanceOf(taker), slice, "the taker got the slice");
        assertEq(core.xToBuyback(), pool - slice);
        assertEq(core.xPot(), required - required / 2, "the bid share is untouched");
        assertEq(core.xStartPrice(), 2 * price, "the auction restarts at twice the clearing price");
        assertEq(core.xStartTime(), block.timestamp);
        assertEq(coin.balanceOf(address(core)), 0);
        _solvent();

        // the restart price is far above what the taker holds now, so an immediate second fill cannot be paid
        (, uint256 again) = core.exitAuctionQuote();
        assertGt(again, coin.balanceOf(taker));
        uint256 held = coin.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert(Core.Slippage.selector);
        core.buybackExit(held);
        _solvent();
    }

    /// the exit token bid pays for credits, the exit lane composes them, and its statement exits at once with
    /// everything back to xPot, so the pot compounds
    function test_phase2_bidComposeExitAndCompound() public {
        _exitTheStatement();
        // the exit token bid is thin after the first exit, so top it up the way fees in the exit token would arrive:
        // plain exit token sent to the core and booked by skim
        xt.mint(address(core), 5e18);
        core.skim();
        _solvent();

        _warp(10 hours);
        uint256 r = core.xRate();
        assertGt(r, core.XRATE_START(), "the bid climbed while funded");

        uint256[] memory ids = _credits(xseller, 80);
        uint256 xPotBefore = core.xPot();
        uint256 total;
        uint256[] memory prices = new uint256[](80);
        for (uint256 i; i < 80; ++i) {
            prices[i] = core.scoreOf(ids[i]) * r * UNIT / 10_000;
            total += prices[i];
            r = r.zeroFloorSub(20).max(3000);
        }
        assertLt(total, xPotBefore, "the pot carries the whole page");

        vm.prank(xseller);
        core.sellForExitToken(ids);
        assertEq(xt.balanceOf(xseller), total, "paid in the exit token");
        assertEq(core.xPot(), xPotBefore - total);
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
        assertEq(core.xPot(), xPotBefore - total + required);
        assertGt(core.xPot(), xPotBefore, "compounded");
        assertGt(required, total);
        _solvent();
    }

    /// a module that underpays reverts the exit and changes nothing, however little it is short
    function test_phase2_hostileExitModuleUnderpaysReverts() public {
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

/// the whole loop twice on the real stack, with solvency and a falling coin supply checked after every step
contract LifecycleNarrativeTest is Fixture {
    using FixedPointMathLib for uint256;

    address internal taker;
    address internal xseller;
    address internal buyer;
    address internal buybacker;

    uint256 internal lastSupply;
    uint256 internal steps;
    uint256 internal burnedByBuyback;
    uint256 internal burnedByAuction;

    function setUp() public override {
        super.setUp();
        taker = _user("taker");
        xseller = _user("xseller");
        buyer = _user("buyer");
        buybacker = _user("buybacker");
        // the owner action waits seven days, which must pass while the pot is empty and the rate cannot climb
        _enterPhase2();
        _skipSniperWindow();
        lastSupply = coin.totalSupply();
    }

    /// solvency and a coin supply that never rises, after every step
    function _check() internal {
        _solvent();
        uint256 supply = coin.totalSupply();
        assertLe(supply, lastSupply, "the coin supply only falls");
        lastSupply = supply;
        ++steps;
    }

    function _composeNow() internal returns (uint256 sid, uint64 at) {
        uint256 size = core.pileSize(Lane.Eth);
        if (size < 80) _fillEthPile(80 - size);
        _check();
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = supply + 1;
        assertEq(STATEMENTS.supply(), sid);
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        at = uint64(block.timestamp);
        _check();
    }

    function _buyListing(uint256 id) internal {
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(id);
        _warpUntilCeiling(id, price);
        vm.prank(keeper);
        core.buyListing(price, abi.encodeCall(ICreditStrategy.sellTargetNFT, (id)), id, STRATEGY);
        assertEq(CREDITS.ownerOf(id), address(core));
        _check();
    }

    function _sale(uint256 sid, uint64 at) internal {
        vm.warp(at + 36 hours);
        uint256 price = core.priceOf(sid);
        vm.deal(buyer, price);
        uint256 pot0 = core.ethPot();
        uint256 back0 = core.ethToBuyback();
        vm.prank(buyer);
        core.buyStatement{value: price}(sid);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
        assertEq(core.ethToBuyback() - back0, price / 2);
        assertEq(core.ethPot() - pot0, price - price / 2);
        _check();
    }

    function _buybacks() internal {
        for (uint256 i; i < 3 && core.ethToBuyback() != 0; ++i) {
            vm.roll(block.number + 25);
            uint256 supply0 = coin.totalSupply();
            vm.prank(buybacker);
            core.buyback();
            assertLt(coin.totalSupply(), supply0, "every buyback burns");
            burnedByBuyback += supply0 - coin.totalSupply();
            _check();
        }
    }

    function _exit(uint256 sid, uint64 at) internal {
        vm.warp(at + 72 hours);
        uint256 required = STATEMENTS.creditScoreOf(sid) * UNIT;
        uint256 back0 = core.xToBuyback();
        uint256 pot0 = core.xPot();
        core.exitStatement(sid);
        assertEq(core.xToBuyback() - back0, required / 2);
        assertEq(core.xPot() - pot0, required - required / 2);
        _check();
    }

    function _bid() internal {
        uint256[] memory ids = _credits(xseller, 3);
        vm.prank(xseller);
        core.sellForExitToken(ids);
        assertGt(xt.balanceOf(xseller), 0);
        _check();
    }

    function _dutchFill() internal {
        _buyCoin(taker, 40 ether);
        _check();
        vm.prank(taker);
        coin.approve(address(core), type(uint256).max);
        uint256 slice;
        uint256 coinIn;
        for (uint256 i; i < 400; ++i) {
            (slice, coinIn) = core.exitAuctionQuote();
            if (coinIn <= coin.balanceOf(taker)) break;
            _warp(1 hours);
        }
        uint256 supply0 = coin.totalSupply();
        uint256 got0 = xt.balanceOf(taker);
        vm.prank(taker);
        core.buybackExit(coinIn);
        assertEq(xt.balanceOf(taker) - got0, slice);
        burnedByAuction += supply0 - coin.totalSupply();
        assertEq(supply0 - coin.totalSupply(), coinIn);
        _check();
    }

    function test_narrative_theWholeLoopTwice() public {
        uint256[2] memory listed = [LISTED_A, LISTED_B];
        for (uint256 round; round < 2; ++round) {
            // fees from real swaps
            _fundPot(20 ether);
            _check();
            uint256 pot0 = core.ethPot();
            _buyCoin(funder, 5 ether);
            assertGt(core.ethPot(), pot0, "a real swap fed the pot");
            _check();
            // buys: the strategy listing, then the bid until a page waits
            _buyListing(listed[round]);
            // two statements: one sold mid auction, one left to exit
            (uint256 sold, uint64 soldAt) = _composeNow();
            (uint256 aged, uint64 agedAt) = _composeNow();
            assertEq(core.heldStatements().length, 2);
            _sale(sold, soldAt);
            _buybacks();
            _exit(aged, agedAt);
            _bid();
            _dutchFill();
            assertEq(core.heldStatements().length, 0);
        }
        assertGt(burnedByBuyback, 0);
        assertGt(burnedByAuction, 0);
        assertLt(coin.totalSupply(), 1_000_000_000e18, "the supply fell over the loops");
        assertEq(coin.balanceOf(address(core)), 0);
        assertGt(steps, 25);
    }
}
