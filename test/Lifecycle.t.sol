// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane, ICreditStrategy, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../src/interfaces/AuctionHouse.sol";
import {Fixture} from "./utils/Fixture.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {BidModel} from "./utils/BidModel.sol";
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
        _skipSniperWindow();
        assertEq(core.rateAtCheckpoint(), core.RATE_START());
        assertEq(core.ethRate(), 0, "an empty pot reads zero");

        // one average credit costs 1.732e15 wei at the start rate (4e12) and funded needs the hourly cap (20 percent of
        // the pot) to afford it, so a pot of 8.66e15. a small buy leaves less than one average credit in the pot
        _buyCoin(trader, 0.01 ether);
        assertLt(core.ethPot(), 1.7e15);
        assertFalse(core.funded());
        _warp(200 hours);
        assertEq(core.ethRate(), core.ethPot() * 2000 / (core.settings().avgScore * 20), "a small pot reads the clamp");

        // the pot passes the threshold
        _buyCoin(trader, 0.2 ether);
        assertTrue(core.funded());
        assertLe(core.ethRate(), core.RATE_START(), "no retroactive climb");
        assertEq(core.rateAtCheckpoint(), core.RATE_START(), "the price state waited at the opening rate");
        // a pot with room for 20 average credits lets the climb start
        _buyCoin(trader, 10 ether);
        _warp(10 hours);
        assertGt(core.ethRate(), core.RATE_START());

        // the climb stops where the hourly cap (20 percent of the pot) buys 20 average credits
        _warp(2000 hours);
        assertEq(core.ethRate(), core.ethPot() * 2000 / (core.settings().avgScore * 20));
    }

    /// phase 2 doors are shut while the exit module slot is empty
    function test_phase1_exitDoorsAreClosed() public {
        vm.expectRevert(ICore.NoExitModule.selector);
        core.exitStatement(1);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.buybackExit(type(uint256).max);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.sellForExitToken(_one(1));
        vm.expectRevert(ICore.NotReady.selector);
        core.composeExit();
        // the statement door of phase 1 is the house, and it needs no module
        vm.expectRevert(ICore.NotListed.selector);
        core.syncStatement(1);
        core.collectSales();
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

    /// the average credit of the flat bid, the score every credit is priced as at the launch settings
    uint256 internal constant AVG = 4_330_000;

    /// @dev the rate after one credit bought at `r`, where `start` is the rate of the first fill of the same minute
    function _dropped(uint256 r, uint256 start) internal view returns (uint256) {
        return BidModel.dropOnce(core.settings(), r, start);
    }

    /// sellForEth pays the climbed ceiling out of a pot that real swaps filled, drops the rate per credit, and the
    /// next real swap adds to the same pot.
    function test_sellForEth_againstThePotRealFeesFilled() public {
        uint256[] memory ids = _credits(seller, 3);
        _warp(30 hours);
        uint256 pot = core.ethPot();
        uint256 rate = core.ethRate();
        assertGt(rate, core.RATE_START(), "funded, so the rate climbed");
        // flat: every credit is priced as the average one, whatever its own score
        assertEq(core.ceilingOf(ids[0]), AVG * rate / 1e4);
        assertEq(core.ceilingOf(ids[1]), core.ceilingOf(ids[0]));
        assertEq(core.ceilingOf(ids[2]), core.ceilingOf(ids[0]));

        uint256[3] memory prices;
        uint256 total;
        uint256 r = rate;
        uint256 p = pot;
        for (uint256 i; i < 3; ++i) {
            prices[i] = AVG * r / 1e4;
            total += prices[i];
            r = _dropped(r, rate);
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
        uint256 sum = first + AVG * _dropped(core.ethRate(), core.ethRate()) / 1e4;
        vm.prank(seller);
        vm.expectRevert(ICore.Slippage.selector);
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
        uint256 savings = (ceiling - price) * core.settings().tipSavingsBps / 10_000;
        uint256 capTip = price * core.settings().tipCapBps / 10_000;
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
        assertEq(core.rateAtCheckpoint(), _dropped(rate, rate));
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
        vm.expectRevert(ICore.AboveCeiling.selector);
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
        vm.expectRevert(ICore.CallFailed.selector);
        core.buyListing(priceA - 1, _buyData(LISTED_A), LISTED_A, STRATEGY);
        _assertUnchanged(s0);

        // wrong calldata for the value
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
        core.buyListing(priceA, _buyData(LISTED_B), LISTED_A, STRATEGY);
        _assertUnchanged(s0);

        // the call works but delivers another credit than the one asked for
        vm.prank(keeper);
        vm.expectRevert(ICore.NoCredit.selector);
        core.buyListing(priceB, _buyData(LISTED_B), LISTED_A, STRATEGY);
        _assertUnchanged(s0);

        // a credit the strategy holds but does not list
        uint256 unlisted = CreditIds.at(5);
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
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
        vm.expectRevert(ICore.AlreadyOwned.selector);
        core.buyListing(priceB, _buyData(LISTED_B), LISTED_B, STRATEGY);
        _solvent();
    }

    /// a target that takes the eth and returns no credit reverts, and nothing moves.
    function test_buyListing_hostileTargetReverts() public {
        Snapshot memory s0 = _snapshot();
        uint256 hostile0 = address(hostile).balance;

        vm.prank(keeper);
        vm.expectRevert(ICore.NoCredit.selector);
        core.buyListing(1 gwei, "", LISTED_A, address(hostile));
        _assertUnchanged(s0);
        assertEq(address(hostile).balance, hostile0, "the eth came back with the revert");

        // not on the list at all
        address stranger = address(new HostileTarget());
        vm.prank(keeper);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(1 gwei, "", LISTED_A, stranger);

        // removal is immediate
        vm.prank(owner);
        core.removeTarget(address(hostile));
        vm.prank(keeper);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(1 gwei, "", LISTED_A, address(hostile));
        _assertUnchanged(s0);
    }

    /// the system's own contracts can never become targets, even by the owner.
    function test_buyListing_forbiddenTargetsCannotBeAdded() public {
        address[11] memory forbidden = [
            lc.stack.hook,
            address(coin),
            address(PM),
            address(core),
            Mainnet.CREDITS,
            Mainnet.STATEMENTS,
            lc.stack.factory,
            lc.stack.locker,
            lc.stack.escrow,
            address(house),
            Mainnet.AUCTION_FACTORY
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addTarget(forbidden[i]);
            assertFalse(core.allowedTarget(forbidden[i]));
        }
        vm.prank(keeper);
        vm.expectRevert(ICore.TargetNotAllowed.selector);
        core.buyListing(1, "", LISTED_A, lc.stack.hook);
    }
}

/// compose, the sale on the real auction house and the real buyback against the real pool
contract LifecycleComposeTest is Fixture {
    using FixedPointMathLib for uint256;

    address internal alice;
    address internal bob;
    address internal buybacker;

    function setUp() public override {
        super.setUp();
        alice = _user("alice");
        bob = _user("bob");
        buybacker = _user("buybacker");
        _skipSniperWindow();
    }

    /// a funded pot, then 90 hours so the rate climbs to about 21 times the start. a flat credit then costs about
    /// 0.036 eth and a page of 80 about 2.9 eth, against the hourly cap of 4 eth
    function _prepare() internal {
        _fundPot(20 ether);
        _warp(90 hours);
    }

    // ------------------------------------------------------------------ compose

    /// compose through ControllerV1: the 80 oldest credits, format 0, the id is the new supply, cost basis, refund,
    /// and the statement is listed on the house at 110 percent of its cost
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
        assertEq(STATEMENTS.ownerOf(c.sid), address(house), "listed: the house holds it for the auction");
        assertEq(STATEMENTS.creditsOf(c.sid), 80);
        uint256[] memory page = new uint256[](80);
        for (uint256 i; i < 80; ++i) {
            page[i] = c.ids[i];
        }
        assertEq(STATEMENTS.creditScoreOf(c.sid), _sumScores(page));

        // cost basis is the credits plus the gas refund, and the reserve is 110 percent of it (the opening ask)
        (bool held, Lane lane, uint256 basis, uint64 listedAt) = core.statementInfo(c.sid);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(basis, c.cost + c.reimb);
        assertEq(listedAt, c.at);
        Live memory l = _live(c.sid);
        assertEq(uint8(l.status), uint8(ICore.StatementStatus.Listed));
        assertEq(l.reserve, basis * 11_000 / 10_000, "110 percent of cost");
        assertEq(_auctionOf(c.sid).duration, 24 hours);
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
        // basefee it tracks the net gas of the call (the listing on the house included): the core repays 80 percent of the
        // metered gross gas and the refund cap returns up to 20 percent of the gross to the caller
        assertGt(c.reimb, 0);
        assertLe(c.reimb, c.cost * 500 / 10_000);
        assertLe(c.reimb, c.potBefore);
        assertEq(keeper.balance, c.reimb);
        assertEq(core.ethPot(), c.potBefore - c.reimb);
        assertGe(c.reimb, (c.gasUsed - 100_000) * composeBasefee, "at least the net gas of the call");
        assertLe(c.reimb, (c.gasUsed + 450_000) * composeBasefee, "and not more than the fixed allowance");
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
        assertEq(_live(capped.sid).reserve, basis2 * 11_000 / 10_000, "the reserve follows the basis");

        // the controller cannot be asked again, there is no full page left
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
    }

    /// statements that get no bid stay listed, for as long as it takes: nothing expires, nothing moves
    function test_compose_unbidStatementStaysListed() public {
        _prepare();
        Composed memory c = _composeOnce();
        Live memory l0 = _live(c.sid);
        uint256 pot = core.ethPot();
        _warp(60 days);
        Live memory l = _live(c.sid);
        assertEq(uint8(l.status), uint8(ICore.StatementStatus.Listed));
        assertEq(l.auctionId, l0.auctionId);
        assertEq(l.reserve, l0.reserve);
        assertEq(STATEMENTS.ownerOf(c.sid), address(house));
        assertEq(core.heldStatements().length, 1);
        assertEq(core.ethPot(), pot, "an unsold statement costs nothing and books nothing");
        // two months later a first bid at the reserve still starts the clock
        _bid(alice, c.sid, l.reserve);
        assertEq(uint8(_live(c.sid).status), uint8(ICore.StatementStatus.Bid));
        assertEq(_live(c.sid).endTime, block.timestamp + 24 hours);
        _solvent();
    }

    // ------------------------------------------------------------------ auction, collection and buyback

    struct Before {
        uint256 pool;
        uint256 slice;
        uint256 supply;
        uint256 pot;
        uint256 balance;
        uint256 caller;
        uint256 pmCoin;
        uint256 dead;
    }

    /// one real buyback with its effects checked against the real pool. the skim on the swap returns to the pot
    function _buybackAndCheck(address caller) internal returns (uint256) {
        Settings memory s = core.settings();
        Before memory b;
        b.pool = core.ethToBuyback();
        b.slice = b.pool.min(s.buybackSlice);
        b.supply = coin.totalSupply();
        b.pot = core.ethPot();
        b.balance = address(core).balance;
        b.caller = caller.balance;
        b.pmCoin = coin.balanceOf(address(PM));
        b.dead = coin.balanceOf(DEAD);

        vm.prank(caller);
        core.buyback();

        uint256 burned = b.supply - coin.totalSupply();
        assertGt(burned, 0, "real burn: the total supply fell");
        assertEq(b.pmCoin - coin.balanceOf(address(PM)), burned, "the coin came out of the pool and was burned");
        assertEq(coin.balanceOf(address(core)), 0, "the core never holds the coin");
        assertEq(coin.balanceOf(DEAD), b.dead, "burned, not parked");
        assertEq(caller.balance - b.caller, b.slice * s.keeperTipBps / 10_000, "the caller got the tip");
        assertEq(core.ethToBuyback(), b.pool - b.slice, "the pot fell by one slice");
        _flush();
        assertGt(core.ethPot(), b.pot, "the skim of the swap came back into the pot");
        assertEq(core.lastBuybackBlock(), block.number);
        assertLe(address(core).balance, b.balance, "the swap spent eth net of what came back");
        _solvent();
        return b.slice;
    }

    /// a real bidder wins the statement, anyone settles, the core collects, the split is exact, the buyback burns
    function test_auction_bidSettleCollectBuyback() public {
        _prepare();
        Composed memory c = _composeOnce();
        (,, uint256 basis,) = core.statementInfo(c.sid);
        Live memory l = _live(c.sid);
        assertEq(l.reserve, basis * 11_000 / 10_000);

        // alice bids the reserve, bob outbids by the five percent step. alice is refunded in the same call
        _bid(alice, c.sid, l.reserve);
        uint256 step = l.reserve * 10_500 / 10_000;
        uint256 aliceBefore = alice.balance;
        _bid(bob, c.sid, step);
        assertEq(alice.balance - aliceBefore, l.reserve, "the outbid bidder is paid back at once");
        assertEq(_live(c.sid).bid, step);
        assertEq(core.ethPot() + core.ethToBuyback(), address(core).balance, "the core has booked nothing of it");

        // nothing settles early, then a stranger settles
        vm.warp(_live(c.sid).endTime - 1);
        uint256 aid = _live(c.sid).auctionId;
        vm.expectRevert(IAuctionHouse.AuctionNotEnded.selector);
        house.endAuction(aid);
        uint256 pot0 = core.ethPot();
        uint256 back0 = core.ethToBuyback();
        _endAuction(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), bob, "the winner holds the statement");
        assertEq(_owedByHouse(), step, "the proceeds are the core's, on the house");
        assertEq(core.ethPot(), pot0, "not booked until collected");
        assertEq(uint8(_live(c.sid).status), uint8(ICore.StatementStatus.Sold));
        vm.expectEmit(address(core));
        emit ICore.StatementSold(c.sid, _live(c.sid).auctionId, bob);
        core.syncStatement(c.sid);
        assertEq(core.heldStatements().length, 0);

        // the split: half to the buyback, half to the pot
        assertEq(_collectSales(), step);
        assertEq(core.ethToBuyback() - back0, step / 2);
        assertEq(core.ethPot() - pot0, step - step / 2);
        assertEq(_owedByHouse(), 0);
        assertGt(step, basis * 11_000 / 10_000, "sold above the reserve");
        _solvent();

        // the buyback burns what the share buys: one slice of 1 eth, then the delay of 25 blocks, then the rest
        assertGt(core.ethToBuyback(), 1 ether, "a page sells for more than two slices of the share");
        vm.roll(block.number + 1);
        assertEq(_buybackAndCheck(buybacker), 1 ether);
        vm.prank(buybacker);
        vm.expectRevert(ICore.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 24);
        vm.prank(buybacker);
        vm.expectRevert(ICore.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 1);
        assertEq(_buybackAndCheck(buybacker), step / 2 - 1 ether, "the last slice is what is left");
        assertEq(core.ethToBuyback(), 0);
        vm.roll(block.number + 25);
        vm.expectRevert(ICore.NothingToBuy.selector);
        core.buyback();
    }

    /// the owner lowers the slice, so one sale is bought back over several calls, with the delay between them
    function test_auction_multiSliceBuybackAfterTheOwnerLowersTheSlice() public {
        _prepare();
        Settings memory s = core.settings();
        s.buybackSlice = 0.02 ether;
        s.buybackDelay = 3;
        _setSettings(s);
        (, uint256 price) = _sellStatement(alice);
        _collectSales();
        assertGt(core.ethToBuyback(), 2 * 0.02 ether);
        assertEq(core.ethToBuyback(), price / 2);
        assertEq(_buybackAndCheck(buybacker), 0.02 ether);

        vm.prank(buybacker);
        vm.expectRevert(ICore.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 2);
        vm.prank(buybacker);
        vm.expectRevert(ICore.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 1);
        _buybackAndCheck(buybacker);

        // drained down to the last partial slice
        uint256 last;
        for (uint256 i; i < 10 && core.ethToBuyback() != 0; ++i) {
            vm.roll(block.number + 3);
            uint256 rest = core.ethToBuyback();
            last = _buybackAndCheck(buybacker);
            assertEq(last, rest.min(0.02 ether));
        }
        assertEq(core.ethToBuyback(), 0);
        assertLt(last, 0.02 ether, "the last slice was partial");
        vm.roll(block.number + 3);
        vm.expectRevert(ICore.NothingToBuy.selector);
        core.buyback();
    }
}

/// phase 2 with the stand in exit module and exit token: exit of unbid statements by cancelling their listing, the
/// split, the dutch auction against the real coin, the exit token bid and the exit lane
contract LifecyclePhase2Test is Fixture {
    using FixedPointMathLib for uint256;

    address internal taker;
    address internal xseller;
    address internal alice;

    function setUp() public override {
        super.setUp();
        taker = _user("taker");
        xseller = _user("xseller");
        alice = _user("alice");
        // the owner action waits seven days, which must pass while the pot is empty and the rate cannot climb
        _enterPhase2();
        _skipSniperWindow();
        _fundPot(20 ether);
        _warp(90 hours);
    }

    function _fullSlice() internal view returns (uint256) {
        return uint256(core.settings().exitSliceCredits) * core.settings().avgScore * UNIT;
    }

    /// an eth lane statement exits only after it was listed without a bid for `exitAfter`: its listing is cancelled and
    /// half of what the module pays goes to the buyback share, half to the bid
    function _exitTheStatement() internal returns (Composed memory c, uint256 required) {
        assertEq(core.exitToken(), address(xt));
        assertEq(core.exitModule(), address(mod));
        c = _composeOnce();
        uint256 aid = _live(c.sid).auctionId;
        vm.expectRevert(ICore.TooEarly.selector);
        core.exitStatement(c.sid);
        vm.warp(c.at + 105 hours - 1);
        vm.expectRevert(ICore.TooEarly.selector);
        core.exitStatement(c.sid);
        vm.warp(c.at + 105 hours);

        required = STATEMENTS.creditScoreOf(c.sid) * UNIT;
        assertEq(core.xPot() + core.xToBuyback(), 0);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "the module has the statement");
        assertEq(house.getAuction(aid).tokenOwner, address(0), "the listing was cancelled");
        assertEq(xt.balanceOf(address(core)), required);
        assertEq(core.xToBuyback(), required / 2, "half to the buyback");
        assertEq(core.xPot(), required - required / 2, "half to the bid");
        (bool held,,,) = core.statementInfo(c.sid);
        assertFalse(held);
        assertEq(core.heldStatements().length, 0);
        _solvent();
    }

    function test_phase2_exitStatementThenDutchAuctionFill() public {
        (, uint256 required) = _exitTheStatement();
        uint256 pool = core.xToBuyback();
        uint256 fullSlice = _fullSlice();
        assertLt(fullSlice, pool, "more than one slice is waiting");

        // a taker buys coin in the real pool and waits for the price to fall to what the coin can pay
        _buyCoin(taker, 40 ether);
        vm.prank(taker);
        coin.approve(address(core), type(uint256).max);
        uint256 slice;
        uint256 coinIn;
        for (uint256 i; i < 2000; ++i) {
            (slice, coinIn) = core.exitAuctionQuote();
            if (coinIn <= coin.balanceOf(taker)) break;
            _warp(1 hours);
        }
        assertEq(slice, fullSlice);
        assertGt(coinIn, 0);
        uint256 price = core.exitAuctionPrice();
        uint256 startBefore = core.xStartPrice();
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
        assertEq(core.xStartPrice(), (2 * price).max(startBefore / 4), "restart at max(2 * clearing, start / 4)");
        assertEq(core.xStartTime(), block.timestamp);
        assertEq(coin.balanceOf(address(core)), 0);
        _solvent();

        // the restart price is far above what the taker holds now, so an immediate second fill cannot be paid
        (, uint256 again) = core.exitAuctionQuote();
        assertGt(again, coin.balanceOf(taker));
        uint256 held = coin.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert(ICore.Slippage.selector);
        core.buybackExit(held);
        _solvent();
    }

    /// a statement that got a bid is not the module's: the bid blocks the exit, the sale goes through, and a sold
    /// statement can never be exited
    function test_phase2_aBidBlocksTheExitAndTheSaleWins() public {
        Composed memory c = _composeOnce();
        vm.warp(c.at + 105 hours);
        _bid(alice, c.sid, _live(c.sid).reserve);
        vm.expectRevert(ICore.HasBid.selector);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(house), "nothing moved");
        _endAuction(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), alice);
        vm.expectRevert(ICore.NotListed.selector);
        core.exitStatement(c.sid);
        assertEq(core.xPot() + core.xToBuyback(), 0, "no exit token came in");
        _collectSales();
        _solvent();
    }

    /// the exit token bid pays for credits, the exit lane composes them, and its statement exits at once with
    /// everything back to xPot, so the pot compounds. the exit lane statement is never listed on the house
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
            r = r.zeroFloorSub(core.settings().xRateDropPerCredit).max(core.settings().xRateFloor);
        }
        assertLt(total, xPotBefore, "the pot carries the whole page");

        vm.prank(xseller);
        core.sellForExitToken(ids);
        assertEq(xt.balanceOf(xseller), total, "paid in the exit token, by the credit's own rating");
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
        uint256 cap = 80 * uint256(core.settings().avgScore) * core.ethRate() / 1e4;
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.composeExit();
        uint256 sid = supply0 + 1;
        {
            uint256 reimb = keeper.balance - keeper0;
            assertEq(STATEMENTS.supply(), sid);
            assertEq(STATEMENTS.ownerOf(sid), address(core), "held by the core, never listed");
            assertEq(core.pileSize(Lane.Exit), 0);
            (bool held, Lane lane, uint256 basis,) = core.statementInfo(sid);
            assertTrue(held);
            assertEq(uint8(lane), uint8(Lane.Exit));
            assertEq(basis, total, "the basis is the exit token paid, no refund in it");
            assertGt(reimb, 0);
            assertLe(reimb, cap * 500 / 10_000);
            assertEq(core.ethPot(), ethPot0 - reimb);

            // no auction in the exit lane
            Live memory l = _live(sid);
            assertEq(uint8(l.status), uint8(ICore.StatementStatus.Held));
            assertEq(l.auctionId, 0);
            (bool listed,) = house.getAuctionFor(address(STATEMENTS), sid);
            assertFalse(listed);
            vm.expectRevert(ICore.NotListed.selector);
            core.repriceStatement(sid);
            vm.expectRevert(ICore.NotListed.selector);
            core.syncStatement(sid);
        }

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

    /// a module that underpays reverts the exit and changes nothing, however little it is short. the statement is
    /// still listed on the house afterwards, as if nothing happened
    function test_phase2_hostileExitModuleUnderpaysReverts() public {
        Composed memory c = _composeOnce();
        vm.warp(c.at + 105 hours);
        uint256 aid = _live(c.sid).auctionId;
        bytes32 before = keccak256(abi.encode(core.xPot(), core.xToBuyback(), xt.balanceOf(address(core))));

        // one basis point short
        mod.setShortfallBps(1);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(house), "the statement never left the house");
        (bool held,,,) = core.statementInfo(c.sid);
        assertTrue(held);
        assertEq(uint8(_live(c.sid).status), uint8(ICore.StatementStatus.Listed), "still listed");
        assertEq(_live(c.sid).auctionId, aid);

        // all of it withheld
        mod.setShortfallBps(10_000);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(c.sid);

        // a module that lowers the unit it pays by after it was set. the core holds the unit from set time
        mod.setShortfallBps(0);
        mod.setUnitPerPoint(1);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(c.sid);

        assertEq(keccak256(abi.encode(core.xPot(), core.xToBuyback(), xt.balanceOf(address(core)))), before);
        assertEq(uint8(_live(c.sid).status), uint8(ICore.StatementStatus.Listed));
        // the listing is still good: a bidder could win it right now
        uint256 snap = vm.snapshotState();
        _bid(alice, c.sid, _live(c.sid).reserve);
        vm.revertToState(snap);

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
    address internal alice;
    address internal bob;
    address internal buybacker;

    uint256 internal lastSupply;
    uint256 internal steps;
    uint256 internal burnedByBuyback;
    uint256 internal burnedByAuction;

    function setUp() public override {
        super.setUp();
        taker = _user("taker");
        xseller = _user("xseller");
        alice = _user("alice");
        bob = _user("bob");
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

    /// credits sold through the eth door at the flat limit: every credit is paid the same
    function _sellAtTheFlatLimit(uint256 n) internal {
        uint256[] memory ids = _credits(seller, n);
        uint256 each = core.ceilingOf(ids[0]);
        assertEq(each, uint256(core.settings().avgScore) * core.ethRate() / 1e4, "the flat limit");
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        // every credit of the batch is paid the flat price at its own point of the falling rate, never above the first
        assertLe(seller.balance - before, each * n);
        assertGt(seller.balance - before, each * n * 8 / 10);
        _check();
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
        assertEq(STATEMENTS.ownerOf(sid), address(house), "listed on the house");
        (,, uint256 cost,) = core.statementInfo(sid);
        assertEq(_live(sid).reserve, cost * 11_000 / 10_000, "at 110 percent of cost");
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

    /// a real bidder wins, a second one outbids, a stranger settles, the core collects, the split is exact
    function _sale(uint256 sid) internal {
        _bid(alice, sid, _live(sid).reserve);
        _bid(bob, sid, _live(sid).reserve * 106 / 100);
        _check();
        uint256 price = _live(sid).bid;
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), bob);
        _check();
        core.syncStatement(sid);
        uint256 pot0 = core.ethPot();
        uint256 back0 = core.ethToBuyback();
        assertEq(_collectSales(), price);
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

    /// the statement nobody bid on: still listed after the sale of the other, redeemed after `exitAfter`
    function _exit(uint256 sid, uint64 at) internal {
        assertEq(uint8(_live(sid).status), uint8(ICore.StatementStatus.Listed), "no bid, so still listed");
        vm.warp(at + core.settings().exitAfter);
        uint256 required = STATEMENTS.creditScoreOf(sid) * UNIT;
        uint256 back0 = core.xToBuyback();
        uint256 pot0 = core.xPot();
        core.exitStatement(sid);
        assertEq(core.xToBuyback() - back0, required / 2);
        assertEq(core.xPot() - pot0, required - required / 2);
        _check();
    }

    function _bidForCredits() internal {
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
        for (uint256 i; i < 2000; ++i) {
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
            // the long waits of the first round let the limit climb to what the pot can carry (a flat credit would cost
            // eth, not milli eth). the owner puts it back to the opening price of the launch
            if (round == 1) {
                uint256 opening = core.RATE_START();
                assertGt(core.ethRate(), 10 * opening);
                vm.prank(owner);
                core.setRate(opening);
                _check();
            }
            // buys at the flat limit through both doors: the bid, then the strategy listing
            _sellAtTheFlatLimit(10);
            _buyListing(listed[round]);
            // two statements, both listed: one gets bidders, one gets none
            (uint256 sold,) = _composeNow();
            (uint256 aged, uint64 agedAt) = _composeNow();
            assertEq(core.heldStatements().length, 2);
            _sale(sold);
            assertEq(uint8(_live(aged).status), uint8(ICore.StatementStatus.Listed));
            _buybacks();
            _exit(aged, agedAt);
            _bidForCredits();
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

/// the owner adapts the system live: the flat share of the bid, the auction reserve and the sale split change in the
/// middle of a run. old listings are repriced by anyone, and old and new statements behave by the new numbers
contract LifecycleOwnerAdaptsTest is Fixture {
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public override {
        super.setUp();
        alice = _user("alice");
        bob = _user("bob");
        carol = _user("carol");
        _skipSniperWindow();
    }

    function _composeFresh() internal returns (uint256 sid, uint256 cost) {
        uint256 size = core.pileSize(Lane.Eth);
        if (size < 80) _fillEthPile(80 - size);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
        (,, cost,) = core.statementInfo(sid);
        _solvent();
    }

    /// what the door pays for credit id at the flat share `flat` and the rate now, no bonus
    function _blend(uint256 id, uint256 flat) internal view returns (uint256) {
        return (flat * core.settings().avgScore + (10_000 - flat) * core.scoreOf(id)) * core.ethRate() / 1e8;
    }

    function test_narrative_theOwnerAdaptsTheSystemLive() public {
        _fundPot(20 ether);
        _warp(90 hours);

        // old numbers: a flat bid, a 75 percent floor and a 110 percent ask, an even split of the sale
        Settings memory old = core.settings();
        assertEq(old.flatBps, 10_000);
        assertEq(old.saleFloorBps, 7_500);
        assertEq(old.saleToBuybackBps, 5_000);
        uint256[] memory first = _credits(seller, 2);
        assertEq(core.ceilingOf(first[0]), core.ceilingOf(first[1]), "flat: both credits are worth the same");
        assertEq(core.ceilingOf(first[0]), _blend(first[0], 10_000));

        // two statements listed under the old numbers
        (uint256 s1, uint256 cost1) = _composeFresh();
        (uint256 s2, uint256 cost2) = _composeFresh();
        assertEq(_live(s1).reserve, cost1 * 11_000 / 10_000);
        assertEq(_live(s2).reserve, cost2 * 11_000 / 10_000);
        // s1 gets a bidder at the old reserve before the change, s2 gets none
        uint256 oldReserve1 = _live(s1).reserve;
        _bid(alice, s1, oldReserve1);

        // the owner changes three numbers in one call, effective at once
        Settings memory s = core.settings();
        s.flatBps = 5_000;
        s.saleFloorBps = 12_000;
        s.saleToBuybackBps = 8_000;
        vm.expectEmit(address(core));
        emit ICore.SettingsSet(s);
        _setSettings(s);
        _solvent();

        // the bid now follows the score by half, for old and new credits alike
        uint256[] memory fresh = _credits(seller, 2);
        for (uint256 i; i < 2; ++i) {
            assertEq(core.ceilingOf(fresh[i]), _blend(fresh[i], 5_000), "half flat, half score");
        }
        {
            uint256 quote = core.ceilingOf(fresh[0]);
            uint256 before = seller.balance;
            vm.prank(seller);
            core.sellForEth(_one(fresh[0]));
            assertEq(seller.balance - before, quote, "paid by the new numbers");
        }

        // the old listings are untouched until someone reprices them. a listing with a bid cannot be repriced at all
        assertEq(_live(s1).reserve, oldReserve1);
        assertEq(_live(s2).reserve, cost2 * 11_000 / 10_000);
        vm.expectRevert(ICore.HasBid.selector);
        core.repriceStatement(s1);
        vm.prank(carol);
        core.repriceStatement(s2);
        assertEq(_live(s2).reserve, cost2 * 12_000 / 10_000, "the old listing now reserves 120 percent of its cost");
        assertEq(_auctionOf(s2).reservePrice, cost2 * 12_000 / 10_000);

        // a statement composed after the change is listed at the new reserve, from the credits bought on both numbers
        (uint256 s3, uint256 cost3) = _composeFresh();
        assertEq(_live(s3).reserve, cost3 * 12_000 / 10_000);
        assertEq(core.heldStatements().length, 3);

        // sales: s1 clears at its old reserve, s2 at the new one, which a bid under the old reserve could not meet
        {
            uint256 pot0 = core.ethPot();
            uint256 back0 = core.ethToBuyback();
            _endAuction(s1);
            assertEq(STATEMENTS.ownerOf(s1), alice);
            uint256 price2 = _live(s2).reserve;
            assertGt(price2, cost2 * 11_000 / 10_000);
            _bid(bob, s2, price2);
            _endAuction(s2);
            uint256 price3 = _live(s3).reserve;
            _bid(carol, s3, price3);
            _endAuction(s3);
            assertEq(STATEMENTS.ownerOf(s2), bob);
            assertEq(STATEMENTS.ownerOf(s3), carol);
            assertEq(_owedByHouse(), oldReserve1 + price2 + price3);

            // one collection under the new split: 80 percent of every sale, old statements included
            assertEq(_collectSales(), oldReserve1 + price2 + price3);
            uint256 total = oldReserve1 + price2 + price3;
            assertEq(core.ethToBuyback() - back0, total * 8_000 / 10_000, "80 percent to the buyback");
            assertEq(core.ethPot() - pot0, total - total * 8_000 / 10_000, "the rest to the pot");
        }
        for (uint256 i; i < 3; ++i) {
            core.syncStatement(i == 0 ? s1 : i == 1 ? s2 : s3);
        }
        assertEq(core.heldStatements().length, 0);
        _solvent();

        // and the buyback burns the larger share
        uint256 supply = coin.totalSupply();
        vm.roll(block.number + 25);
        vm.prank(keeper);
        core.buyback();
        assertLt(coin.totalSupply(), supply);
        _solvent();
    }
}
