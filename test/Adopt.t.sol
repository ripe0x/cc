// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {Prod} from "./utils/Prod.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Lane, Mainnet, Settings, ICreditScore} from "../src/interfaces/Interfaces.sol";

/// a listing target that delivers the credit and then tries to adopt it inside the guarded call
contract AdoptingTarget {
    address public immutable core;
    bool public adoptOk;
    bytes public adoptOut;

    constructor(address core_) {
        core = core_;
    }

    function fill(uint256 id) external payable {
        (bool ok,) = Mainnet.CREDITS.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), msg.sender, id)
        );
        require(ok, "deliver");
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        (adoptOk, adoptOut) = core.call(abi.encodeWithSignature("adopt(uint256[])", ids));
    }

    receive() external payable {}
}

/// `adopt` of the Core on the fork: the real Core, Credits, Statements, house and controller. credits are sent to the
/// Core outside its doors with a plain `transferFrom`
contract AdoptTest is Fixture {
    address internal stranger = address(0xAD0);

    /// `n` fresh credits transferred straight to the Core
    function _gift(uint256 n) internal returns (uint256[] memory ids) {
        ids = _credits(seller, n);
        for (uint256 i; i < n; ++i) {
            vm.prank(seller);
            CREDITS.transferFrom(seller, address(core), ids[i]);
        }
    }

    function _basis(uint256 id) internal view returns (uint256) {
        return core.ethPrice() * core.scoreOf(id) / 1e4;
    }

    function _adopt(uint256[] memory ids) internal {
        vm.prank(stranger);
        core.adopt(ids);
    }

    function test_OK_aCreditSentStraightToTheCoreIsAdoptedAtThePriceStateTimesItsScore() public {
        uint256[] memory ids = _gift(1);
        uint256 id = ids[0];
        (bool inPile,, uint256 cost0,) = core.creditInfo(id);
        assertFalse(inPile);
        assertEq(cost0, 0, "no record");
        // the pot is empty: the read is clamped to zero while the price state is the opening rate
        assertEq(core.ethRate(), 0, "the clamped read is zero");
        assertEq(core.ethPrice(), core.RATE_START(), "the price state is the opening rate");
        uint256 want = _basis(id);
        assertGt(want, 0);
        assertEq(want, core.RATE_START() * core.scoreOf(id) / 1e4);

        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.CreditAdopted(id, want);
        _adopt(ids);

        (bool inPile1, Lane lane, uint256 cost, uint64 at) = core.creditInfo(id);
        assertTrue(inPile1, "in the pile");
        assertEq(uint8(lane), uint8(Lane.Eth), "eth lane");
        assertEq(cost, want, "cost basis");
        assertEq(at, block.timestamp, "acquiredAt");
        assertEq(core.pileSize(Lane.Eth), 1);
        assertEq(core.pileHead(Lane.Eth), id);
        assertEq(CREDITS.ownerOf(id), address(core));
        assertEq(core.pileSize(Lane.Exit), 0, "the exit pile is untouched");
    }

    function test_OK_theBasisFollowsThePriceStateAfterTheMarketMoved() public {
        _fundPot(2 ether);
        _warp(3 hours);
        uint256[] memory ids = _gift(3);
        uint256 price = core.ethPrice();
        assertGe(price, core.ethRate());
        _adopt(ids);
        for (uint256 i; i < 3; ++i) {
            (,, uint256 cost,) = core.creditInfo(ids[i]);
            assertEq(cost, price * core.scoreOf(ids[i]) / 1e4, "basis from the price state at that moment");
            assertGt(cost, 0);
        }
        // order of the pile is the order of the call
        assertEq(core.pileHead(Lane.Eth), ids[0]);
        assertEq(core.pileNext(ids[0]), ids[1]);
        assertEq(core.pileNext(ids[1]), ids[2]);
        assertEq(core.pileNext(ids[2]), 0);
    }

    function test_REVERT_adoptTwiceInOneCallOrTwoCalls() public {
        uint256[] memory ids = _gift(1);
        _adopt(ids);
        vm.expectRevert(abi.encodeWithSignature("InPile()"));
        _adopt(ids);
        uint256[] memory twice = _gift(1);
        uint256[] memory both = new uint256[](2);
        both[0] = twice[0];
        both[1] = twice[0];
        vm.expectRevert(abi.encodeWithSignature("InPile()"));
        _adopt(both);
        assertEq(core.pileSize(Lane.Eth), 1, "the failed call changed nothing");
    }

    function test_REVERT_aCreditTheCoreDoesNotHold() public {
        uint256[] memory ids = _credits(seller, 1);
        vm.expectRevert(abi.encodeWithSignature("NotHolder()"));
        _adopt(ids);
        uint256[] memory gone = new uint256[](1);
        gone[0] = type(uint128).max;
        vm.expectRevert();
        _adopt(gone);
        assertEq(core.pileSize(Lane.Eth), 0);
    }

    function test_REVERT_emptyAndZero() public {
        vm.expectRevert(abi.encodeWithSignature("Empty()"));
        _adopt(new uint256[](0));
        vm.expectRevert(abi.encodeWithSignature("ZeroId()"));
        _adopt(new uint256[](1));
    }

    function test_REVERT_aCreditSoldThroughTheDoorIsInThePile() public {
        _fundPot(1 ether);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        core.sellForEth(ids);
        vm.expectRevert(abi.encodeWithSignature("InPile()"));
        _adopt(ids);
    }

    function test_REVERT_aBatchWithOneBadIdChangesNothing() public {
        uint256[] memory good = _gift(2);
        uint256[] memory foreign = _credits(seller, 1);
        uint256[] memory mixed = new uint256[](3);
        mixed[0] = good[0];
        mixed[1] = good[1];
        mixed[2] = foreign[0];
        vm.expectRevert(abi.encodeWithSignature("NotHolder()"));
        _adopt(mixed);
        assertEq(core.pileSize(Lane.Eth), 0);
        (bool inPile,,,) = core.creditInfo(good[0]);
        assertFalse(inPile);
    }

    /// the rate state, the hourly window and the pots, as one value to compare
    struct State {
        uint256 rate;
        uint256 price;
        uint256 stored;
        uint64 checkpointTime;
        uint64 fillTime;
        uint256 room;
        uint256 pot;
        uint256 buyback;
        uint256 balance;
        uint256 lastFill;
        uint256 minuteStart;
        uint256 bucket;
    }

    function _state() internal view returns (State memory s) {
        s.rate = core.ethRate();
        s.price = core.ethPrice();
        s.stored = core.rateAtCheckpoint();
        s.checkpointTime = core.checkpointTime();
        s.fillTime = core.lastFillTime();
        s.room = core.hourlyRoom();
        s.pot = core.ethPot();
        s.buyback = core.ethToBuyback();
        s.balance = address(core).balance;
        (s.lastFill, s.minuteStart, s.bucket) = _anchor();
    }

    function test_OK_theRateStateTheWindowAndThePotsAreUnchanged() public {
        _fundPot(2 ether);
        // one sale opens a window and moves the rate state
        uint256[] memory sold = _credits(seller, 4);
        vm.prank(seller);
        core.sellForEth(sold);
        _warp(10 minutes);
        uint256[] memory ids = _gift(5);

        State memory a = _state();
        _adopt(ids);
        State memory b = _state();

        assertEq(b.rate, a.rate, "ethRate");
        assertEq(b.price, a.price, "ethPrice");
        assertEq(b.stored, a.stored, "stored rate, no checkpoint written");
        assertEq(b.checkpointTime, a.checkpointTime, "checkpoint time");
        assertEq(b.fillTime, a.fillTime, "fill time");
        assertEq(b.room, a.room, "no hourly room consumed");
        assertEq(b.pot, a.pot, "pot");
        assertEq(b.buyback, a.buyback, "buyback pot");
        assertEq(b.balance, a.balance, "no eth moves");
        assertEq(b.lastFill, a.lastFill, "ceiling anchor");
        assertEq(b.minuteStart, a.minuteStart, "minute floor");
        assertEq(b.bucket, a.bucket, "minute bucket");
        assertEq(core.pileSize(Lane.Eth), 4 + 5, "the sold and the adopted credits are in the pile");
    }

    function test_OK_aPageOfAdoptedCreditsComposesIntoAStatementWorthTheirBases() public {
        _fundPot(1 ether);
        uint256[] memory ids = _gift(80);
        _adopt(ids);
        assertEq(core.pileSize(Lane.Eth), 80);
        uint256 sum;
        for (uint256 i; i < 80; ++i) {
            (,, uint256 cost,) = core.creditInfo(ids[i]);
            sum += cost;
        }
        assertGt(sum, 0);
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = supply + 1;
        (bool held, Lane lane, uint256 cost,) = core.statementInfo(sid);
        assertTrue(held);
        assertEq(uint8(lane), uint8(Lane.Eth));
        assertEq(cost, sum, "statement cost is the sum of the bases");
        assertEq(core.pileSize(Lane.Eth), 0);
        // the listing is priced from that cost
        assertEq(_live(sid).reserve, _reserveFor(cost), "reserve");
        assertGe(_live(sid).reserve, cost * core.settings().saleFloorBps / 10_000, "at or above the floor");
    }

    /// a successor Core with its own controller (the controller holds the address of its Core, so both addresses are
    /// computed from the next two nonces of this contract)
    function _successor() internal returns (ICore succ) {
        uint64 n = vm.getNonce(address(this));
        address coreAt = vm.computeCreateAddress(address(this), n + 1);
        IControllerV1 ctl2 = Prod.newController(coreAt, lc.sale);
        succ = Prod.newCore(owner, address(coin), address(ctl2), lc.stack, lc.rateStart, _settings());
        assertEq(address(succ), coreAt, "predicted successor address");
    }

    /// `adopt` on the successor for `ids`, from a stranger. returns the sum of the bases after checking each one
    function _adoptOnSuccessor(ICore succ, uint256[] memory ids) internal returns (uint256 sum) {
        // the successor prices the credits with its own price state: its opening rate
        uint256 price = succ.ethPrice();
        assertEq(price, lc.rateStart);
        vm.prank(stranger);
        succ.adopt(ids);
        assertEq(succ.pileSize(Lane.Eth), ids.length, "the pile is restored");
        assertEq(succ.pileHead(Lane.Eth), ids[0], "in the order of the call");
        for (uint256 i; i < ids.length; ++i) {
            (bool p, Lane lane, uint256 cost,) = succ.creditInfo(ids[i]);
            assertTrue(p);
            assertEq(uint8(lane), uint8(Lane.Eth));
            assertEq(cost, price * succ.scoreOf(ids[i]) / 1e4);
            sum += cost;
        }
    }

    /// `migrate` moves the credits of the old Core to a second Core, and `adopt` on that Core puts them back into a
    /// pile that composes
    function test_OK_migrateThenAdoptOnTheSuccessorRestoresThePile() public {
        _fillEthPile(80);
        uint256[] memory ids = core.pilePage(Lane.Eth, 0, 80);
        assertEq(ids.length, 80);
        ICore succ = _successor();

        vm.startPrank(owner);
        core.setSuccessor(address(succ));
        core.migrate(100);
        vm.stopPrank();
        assertEq(core.pileSize(Lane.Eth), 0, "the old pile is empty");
        for (uint256 i; i < 80; ++i) {
            assertEq(CREDITS.ownerOf(ids[i]), address(succ), "moved to the successor");
        }
        (bool inPile,,,) = succ.creditInfo(ids[0]);
        assertFalse(inPile, "the successor has no record yet");
        assertEq(succ.pileSize(Lane.Eth), 0);

        uint256 sum = _adoptOnSuccessor(succ, ids);

        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        succ.compose();
        (bool held,, uint256 stCost,) = succ.statementInfo(supply + 1);
        assertTrue(held);
        assertEq(stCost, sum, "the pot of the successor is empty, so the cost is the sum of the bases");
        assertEq(succ.pileSize(Lane.Eth), 0);
    }

    /// a credit that left through `migrate` keeps its old record with the pile flag cleared. it can come back and be
    /// adopted again, which writes a new record
    function test_OK_aMigratedCreditThatComesBackCanBeAdoptedAgain() public {
        uint256[] memory ids = _fillEthPile(3);
        (,, uint256 oldCost,) = core.creditInfo(ids[0]);
        assertGt(oldCost, 0);
        address sink = address(0xA11CE);
        vm.etch(sink, hex"00");
        vm.startPrank(owner);
        core.setSuccessor(sink);
        core.migrate(10);
        vm.stopPrank();
        (bool inPile,, uint256 stale,) = core.creditInfo(ids[0]);
        assertFalse(inPile);
        assertEq(stale, oldCost, "the record stays");
        vm.prank(sink);
        CREDITS.transferFrom(sink, address(core), ids[0]);
        _warp(1 days);
        uint256[] memory one = _one(ids[0]);
        _adopt(one);
        (bool p,, uint256 fresh, uint64 at) = core.creditInfo(ids[0]);
        assertTrue(p);
        assertEq(fresh, core.ethPrice() * core.scoreOf(ids[0]) / 1e4);
        assertEq(at, block.timestamp);
        assertEq(core.pileSize(Lane.Eth), 1);
    }

    /// inside a guarded call (a listing target mid buy) `adopt` is refused, so a credit being bought cannot be put in
    /// the pile twice
    function test_REVERT_adoptInsideAGuardedCall() public {
        _fundPot(1 ether);
        uint256 id = LISTED_A;
        AdoptingTarget t = new AdoptingTarget(address(core));
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, address(t), id);
        _allow(address(t));
        uint256 value = core.ceilingOf(id) / 2;
        vm.prank(keeper);
        core.buyListing(value, abi.encodeCall(AdoptingTarget.fill, (id)), id, address(t));
        assertFalse(t.adoptOk(), "adopt inside the buy failed");
        assertEq(bytes4(t.adoptOut()), bytes4(0xab143c06), "Reentrancy()");
        assertEq(core.pileSize(Lane.Eth), 1, "the credit is in the pile once");
        assertEq(core.pileHead(Lane.Eth), id);
        (bool p,,,) = core.creditInfo(id);
        assertTrue(p);
    }

    /// the fee router is pulled before the price is read, like at every door that spends from the pot: pending fee eth is
    /// booked
    function test_OK_adoptPullsTheFeeRouterFirst() public {
        autoFlush = false;
        _buyCoin(funder, 3 ether);
        assertGt(address(feeRouter).balance, 0, "the router holds fees");
        uint256 pot = core.ethPot();
        uint256[] memory ids = _gift(1);
        vm.expectEmit(false, false, false, false, address(core));
        emit ICore.FeesAdded(0);
        _adopt(ids);
        assertEq(address(feeRouter).balance, 0, "the router was flushed");
        assertGt(core.ethPot(), pot, "the fees are in the pot");
        (,, uint256 cost,) = core.creditInfo(ids[0]);
        assertEq(cost, core.ethPrice() * core.scoreOf(ids[0]) / 1e4, "the basis is read after the pull");
    }

    /// a router that reverts does not block adopt
    function test_OK_adoptWorksWithABrokenRouter() public {
        vm.etch(address(feeRouter), hex"fe");
        uint256[] memory ids = _gift(1);
        _adopt(ids);
        assertEq(core.pileSize(Lane.Eth), 1);
    }

    /// `ethPrice()` is the value a real checkpoint stores: skim with 1 wei above the pots checkpoints
    function test_OK_ethPriceIsWhatARealCheckpointStores() public {
        _fundPot(2 ether);
        uint256[] memory sold = _credits(seller, 6);
        vm.prank(seller);
        core.sellForEth(sold);
        _warp(20 minutes);
        uint256 read = core.ethPrice();
        assertGt(read, core.rateAtCheckpoint(), "the price state climbed since the last checkpoint");
        vm.deal(address(core), address(core).balance + 1);
        core.skim();
        assertEq(core.rateAtCheckpoint(), read, "the checkpoint stored the value ethPrice read");
        assertEq(core.ethPrice(), read);
    }

    /// a credit whose score is 0 (a mocked score contract) takes the floor of 1 wei
    function test_OK_aCreditOfScoreZeroTakesTheFloorOfOneWei() public {
        uint256[] memory ids = _gift(2);
        vm.mockCall(Mainnet.CREDIT_SCORE, abi.encodeWithSelector(ICreditScore.scoreOf.selector), abi.encode(uint256(0)));
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.CreditAdopted(ids[0], 1);
        _adopt(ids);
        vm.clearMockedCalls();
        for (uint256 i; i < 2; ++i) {
            (bool p,, uint256 cost,) = core.creditInfo(ids[i]);
            assertTrue(p);
            assertEq(cost, 1, "1 wei");
        }
    }

    /// a stored rate above `rateCap` gives the cap as the price state, so the basis is at the cap
    function test_OK_aStoredRateAboveTheRateCapGivesTheCapAsTheBasis() public {
        Settings memory st = core.settings();
        uint256 stored = core.rateAtCheckpoint();
        st.rateCap = uint64(stored / 4);
        _setSettings(st);
        assertEq(core.rateAtCheckpoint(), stored, "the stored rate is above the new cap");
        assertEq(core.ethPrice(), st.rateCap, "the price state is the cap");
        uint256[] memory ids = _gift(2);
        _adopt(ids);
        for (uint256 i; i < 2; ++i) {
            (,, uint256 cost,) = core.creditInfo(ids[i]);
            assertEq(cost, st.rateCap * core.scoreOf(ids[i]) / 1e4, "basis at the cap");
        }
    }

    /// a stored rate above the ceiling (the ceiling was lowered after the price climbed) gives the ceiling as the basis
    function test_OK_aStoredRateAboveTheCeilingGivesTheCeilingAsTheBasis() public {
        _fundPot(2 ether);
        _warp(1 hours);
        vm.deal(address(core), address(core).balance + 1);
        core.skim();
        Settings memory st = core.settings();
        st.ceilBps = 10_000;
        _setSettings(st);
        (uint256 lastFill,,) = _anchor();
        uint256 loosened = 10_000 + uint256(st.idleLoosenBps) * ((block.timestamp - core.lastFillTime()) / 10 minutes);
        uint256 bound = lastFill * loosened * st.ceilBps / 1e8;
        assertGt(core.rateAtCheckpoint(), bound, "the stored rate is above the lowered ceiling");
        assertEq(core.ethPrice(), bound, "the price state is the ceiling");
        uint256[] memory ids = _gift(1);
        _adopt(ids);
        (,, uint256 cost,) = core.creditInfo(ids[0]);
        assertEq(cost, bound * core.scoreOf(ids[0]) / 1e4, "basis at the ceiling");
    }

    /// after a fill the stored rate is stale once time passes: the basis uses the climbed price state, with the pot refilled
    function test_OK_aStaleStoredRateAfterAFillIsClimbedForTheBasis() public {
        _fundPot(1 ether);
        uint256[] memory sold = _credits(seller, 5);
        vm.prank(seller);
        core.sellForEth(sold);
        _fundPot(core.ethPot() + 2 ether);
        _warp(10 minutes);
        uint256 stored = core.rateAtCheckpoint();
        uint256 price = core.ethPrice();
        assertGt(price, stored, "the stored rate is stale");
        uint256[] memory ids = _gift(1);
        _adopt(ids);
        (,, uint256 cost,) = core.creditInfo(ids[0]);
        assertEq(cost, price * core.scoreOf(ids[0]) / 1e4, "the climbed state");
        assertTrue(cost != stored * core.scoreOf(ids[0]) / 1e4);
        assertEq(core.rateAtCheckpoint(), stored, "nothing was checkpointed by the adopt");
    }

    /// gas of `adopt` for one credit and for a page of 80, with an empty router. docs/INTEGRATION.md section 13 quotes
    /// both figures: 242,489 and 10,552,467. the bound is 5 percent around each
    function test_GAS_adopt() public {
        uint256[] memory one = _gift(1);
        uint256 g = gasleft();
        _adopt(one);
        uint256 gasOne = g - gasleft();
        uint256[] memory page = _gift(80);
        g = gasleft();
        _adopt(page);
        uint256 gasPage = g - gasleft();
        emit log_named_uint("adopt, 1 credit", gasOne);
        emit log_named_uint("adopt, 80 credits", gasPage);
        emit log_named_uint("adopt, per credit at 80", gasPage / 80);
        assertApproxEqRel(gasOne, 242_489, 0.05e18, "one credit");
        assertApproxEqRel(gasPage, 10_552_467, 0.05e18, "80 credits");
    }

    function test_FUZZ_theBasisIsThePriceStateTimesTheScore(uint256 wait, uint8 count) public {
        wait = bound(wait, 0, 30 days);
        count = uint8(bound(count, 1, 6));
        _fundPot(1 ether);
        _warp(wait);
        uint256[] memory ids = _gift(count);
        uint256 price = core.ethPrice();
        _adopt(ids);
        for (uint256 i; i < count; ++i) {
            (,, uint256 cost,) = core.creditInfo(ids[i]);
            assertEq(cost, price * core.scoreOf(ids[i]) / 1e4, "basis");
            assertGt(cost, 0);
        }
    }
}
