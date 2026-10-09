// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Lane, Settings, Sale, Mainnet, IExitModule, IStatements} from "../src/interfaces/Interfaces.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";
import {SettingsFields} from "../script/SettingsFields.sol";
import {SetSettings} from "../script/SetSettings.s.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";

/// a controller that can call sellTo with any statement, buyer and payment
contract SellProbe is ScriptedController {
    ICore internal immutable CORE;

    constructor(ICore c) {
        CORE = c;
    }

    function sell(uint256 sid, address buyer) external payable {
        CORE.sellTo{value: msg.value}(sid, buyer);
    }
}

/// a buyer that records every callback and tries to re enter on the refund
contract EvilBuyer {
    IControllerV1 public ctl;
    ICore public core;
    uint256 public hooks;
    uint256 public refunds;
    uint256 public sid;
    bool public failRefund;
    bytes4 public lastWhy;

    constructor(IControllerV1 c, ICore k) {
        ctl = c;
        core = k;
    }

    function setFail(bool on) external {
        failRefund = on;
    }

    function buy(uint256 id) external payable {
        sid = id;
        ctl.buy{value: msg.value}(id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        ++hooks;
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (failRefund) revert("refused");
        ++refunds;
        try ctl.buy{value: 0}(sid) {}
        catch (bytes memory why) {
            lastWhy = bytes4(why);
        }
        try core.skim() {} catch {}
    }
}

/// an exit module that burns gas before it pays, for the cap of the redeem reimbursement
contract BurnModule is IExitModule {
    address public immutable exitToken;
    uint256 public immutable unit;
    uint256 public immutable burn;

    constructor(address token, uint256 unit_, uint256 burn_) {
        exitToken = token;
        unit = unit_;
        burn = burn_;
    }

    function unitPerPoint() external view returns (uint256) {
        return unit;
    }

    function exit(uint256 sid) external returns (uint256 out) {
        uint256 stop = gasleft() - burn;
        while (gasleft() > stop) {}
        out = IStatements(Mainnet.STATEMENTS).creditScoreOf(sid) * unit;
        MockExitToken(exitToken).mint(msg.sender, out);
    }
}

/// reads the private tuple string of the settings script
contract TupleProbe is SetSettings {
    function tuple() external pure returns (string memory) {
        return TUPLE;
    }
}

/// independent review of the sale controller, the owner doors and the fee share (docs/REVIEW-sale.md). test_FIXED asserts
/// the behavior after the fix of a finding, test_ACCEPTED pins a finding that was accepted or documented, every test_OK
/// confirms a safety property
contract ReviewSaleTest is Fixture {
    address internal alice;
    address internal bob;

    function setUp() public override {
        super.setUp();
        alice = _user("rs.alice");
        bob = _user("rs.bob");
    }

    // ------------------------------------------------------------------ helpers

    function _cost(uint256 sid) internal view returns (uint256 c) {
        (,, c,) = core.statementInfo(sid);
    }

    function _floorOf(uint256 sid) internal view returns (uint256) {
        return _cost(sid) * core.settings().saleFloorBps / 10_000;
    }

    function _buyOnly() internal {
        vm.prank(owner);
        ctl.setBuyOnly(true);
    }

    function _probe() internal returns (SellProbe p) {
        p = new SellProbe(core);
        _setController(address(p));
    }

    function _exitLaneStatement() internal returns (uint256 sid) {
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.composeExit();
        sid = STATEMENTS.supply();
    }

    function _raise(uint16 floorBps) internal {
        Settings memory s = core.settings();
        s.saleFloorBps = floorBps;
        _setSettings(s);
    }

    // ------------------------------------------------------------------ sellTo: who, which states

    function test_OK_sellTo_onlyTheCurrentController() public {
        uint256 sid = _composeOnce().sid;
        uint256 floor = _floorOf(sid);
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo{value: floor}(sid, bob);
        vm.deal(owner, 100 ether);
        vm.prank(owner);
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo{value: floor}(sid, owner);
        // after a controller change the old controller is dead for sales
        _buyOnly();
        SellProbe p = _probe();
        vm.prank(bob);
        vm.expectRevert(ICore.OnlyController.selector);
        ctl.buy{value: 100 ether}(sid);
        p.sell{value: floor}(sid, bob);
        assertEq(STATEMENTS.ownerOf(sid), bob);
    }

    function test_OK_sellTo_unknownRecordReverts() public {
        _composeOnce();
        SellProbe p = _probe();
        vm.expectRevert(ICore.NotListed.selector);
        p.sell{value: 0}(999_999, bob);
        vm.expectRevert(ICore.NotListed.selector);
        p.sell{value: 0}(0, bob);
    }

    function test_OK_sellTo_exitLaneStatementReverts() public {
        _enterPhase2();
        uint256 sid = _exitLaneStatement();
        (bool held, Lane lane,,) = core.statementInfo(sid);
        assertTrue(held);
        assertEq(uint256(lane), uint256(Lane.Exit));
        SellProbe p = _probe();
        vm.deal(address(this), 1000 ether);
        vm.expectRevert(ICore.NotListed.selector);
        p.sell{value: 1000 ether}(sid, bob);
        assertEq(STATEMENTS.ownerOf(sid), address(core));
    }

    function test_OK_sellTo_midAuctionReverts() public {
        uint256 sid = _composeOnce().sid;
        _bid(alice, sid, _live(sid).reserve);
        SellProbe p = _probe();
        vm.deal(address(this), 1000 ether);
        vm.expectRevert(ICore.HasBid.selector);
        p.sell{value: 1000 ether}(sid, bob);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Bid), "auction untouched");
    }

    function test_OK_sellTo_endedButUnsettledAuctionReverts() public {
        uint256 sid = _composeOnce().sid;
        _bid(alice, sid, _live(sid).reserve);
        vm.warp(_live(sid).endTime + 1);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Ended));
        SellProbe p = _probe();
        vm.deal(address(this), 1000 ether);
        vm.expectRevert(ICore.HasBid.selector);
        p.sell{value: 1000 ether}(sid, bob);
    }

    function test_OK_sellTo_afterAnAuctionSaleReverts() public {
        (uint256 sid,) = _sellStatement(alice);
        SellProbe p = _probe();
        vm.deal(address(this), 1000 ether);
        // the record is stale (sold on the house) until syncStatement clears it
        vm.expectRevert(ICore.NotListed.selector);
        p.sell{value: 1000 ether}(sid, bob);
        core.syncStatement(sid);
        vm.expectRevert(ICore.NotListed.selector);
        p.sell{value: 1000 ether}(sid, bob);
        assertEq(STATEMENTS.ownerOf(sid), alice);
    }

    function test_OK_sellTo_alreadySoldReverts() public {
        uint256 sid = _composeOnce().sid;
        uint256 floor = _floorOf(sid);
        SellProbe p = _probe();
        p.sell{value: floor}(sid, bob);
        vm.deal(address(this), 1000 ether);
        vm.expectRevert(ICore.NotListed.selector);
        p.sell{value: 1000 ether}(sid, alice);
        assertEq(STATEMENTS.ownerOf(sid), bob);
        assertEq(core.heldStatements().length, 0);
    }

    function test_OK_sellTo_hardFloorExactAndRounding() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        uint256 floor = _floorOf(sid);
        SellProbe p = _probe();
        vm.deal(address(this), 1000 ether);
        vm.expectRevert(ICore.BelowFloor.selector);
        p.sell{value: floor - 1}(sid, bob);
        vm.expectRevert(ICore.BelowFloor.selector);
        p.sell{value: 0}(sid, bob);
        // the floor rounds down by less than one wei of the exact product
        assertLe(floor * 10_000, cost * core.settings().saleFloorBps);
        assertGt((floor + 1) * 10_000, cost * core.settings().saleFloorBps);
        p.sell{value: floor}(sid, bob);
        assertEq(STATEMENTS.ownerOf(sid), bob);
    }

    function test_OK_sellTo_msgValueBookedOnceNeverDoubleCounted() public {
        uint256 sid = _composeOnce().sid;
        uint256 pay = _cost(sid) * 3;
        SellProbe p = _probe();
        vm.deal(address(this), pay);
        uint256 pot = core.ethPot();
        uint256 bb = core.ethToBuyback();
        uint256 bal = address(core).balance;
        vm.expectEmit(address(core));
        emit ICore.StatementSoldTo(sid, bob, pay);
        p.sell{value: pay}(sid, bob);
        assertEq(address(core).balance - bal, pay, "balance rose by the payment");
        assertEq((core.ethPot() - pot) + (core.ethToBuyback() - bb), pay, "booked exactly once");
        assertEq(core.ethToBuyback() - bb, pay * core.settings().saleToBuybackBps / 10_000);
        // skim, collectSales and a later hook payment add nothing for this payment
        core.skim();
        core.collectSales();
        assertEq((core.ethPot() - pot) + (core.ethToBuyback() - bb), pay, "skim finds nothing to add");
        assertEq(house.pendingRefunds(address(core)), 0);
        _solvent();
    }

    function test_OK_sellTo_buyerGetsNoCallbackAndRefundReentryIsBlocked() public {
        uint256 sid = _composeOnce().sid;
        _buyOnly();
        uint256 price = ctl.priceOf(sid);
        EvilBuyer b = new EvilBuyer(ctl, core);
        vm.deal(address(this), price + 1 ether);
        uint256 dust = address(b).balance;
        b.buy{value: price + 1 ether}(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(b));
        assertEq(b.hooks(), 0, "transferFrom has no callback");
        assertEq(b.refunds(), 1, "the refund arrived once");
        assertEq(b.lastWhy(), IControllerV1.Reentrant.selector, "buy is guarded against the refund");
        assertEq(address(b).balance - dust, 1 ether);
        assertEq(address(ctl).balance, 0, "nothing stays in the controller");
        _solvent();
    }

    function test_OK_buy_revertingRefundRevertsTheWholeBuy() public {
        uint256 sid = _composeOnce().sid;
        _buyOnly();
        uint256 price = ctl.priceOf(sid);
        EvilBuyer b = new EvilBuyer(ctl, core);
        b.setFail(true);
        vm.deal(address(this), price + 1 ether);
        vm.expectRevert();
        b.buy{value: price + 1 ether}(sid);
        (bool held,,,) = core.statementInfo(sid);
        assertTrue(held, "statement still held");
        assertEq(address(ctl).balance, 0);
        b.buy{value: price}(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(b), "exact payment needs no refund");
    }

    function test_OK_buy_ethCannotBeSentToTheController() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok,) = address(ctl).call{value: 1 ether}("");
        assertFalse(ok, "no receive, no fallback");
        assertEq(address(ctl).balance, 0);
    }

    function test_OK_buy_notInAuctionMode() public {
        uint256 sid = _composeOnce().sid;
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(IControllerV1.NotBuyOnly.selector);
        ctl.buy{value: 100 ether}(sid);
    }

    function test_OK_buy_ownerCheckFollowsTheLiveOwner() public {
        vm.prank(owner);
        core.transferOwnership(alice);
        vm.prank(owner);
        ctl.setStepBps(50);
        vm.prank(alice);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setBuyOnly(true);
        vm.prank(alice);
        ctl.setBuyOnly(true);
        assertTrue(ctl.buyOnly());
        assertEq(ctl.stepBps(), 50);
    }

    function test_OK_buy_quoteNeverRisesForAThirdParty() public {
        uint256 sid = _composeOnce().sid;
        _buyOnly();
        uint256 q0 = ctl.priceOf(sid);
        // a stranger runs every permissionless door: none raises the ask
        core.skim();
        core.collectSales();
        core.repriceStatement(sid);
        assertEq(ctl.priceOf(sid), q0);
        _warp(3 hours);
        uint256 q1 = ctl.priceOf(sid);
        assertLt(q1, q0);
        // the buyer pays the quote of an earlier block: still enough, the excess comes back
        _warp(3 hours);
        uint256 q2 = ctl.priceOf(sid);
        vm.deal(bob, q1);
        vm.prank(bob);
        ctl.buy{value: q1}(sid);
        assertEq(bob.balance, q1 - q2, "paid the later, lower price");
        assertEq(STATEMENTS.ownerOf(sid), bob);
    }

    function test_OK_buy_aBidderBlockingABuyPaysAtLeastTheAsk() public {
        uint256 sid = _composeOnce().sid;
        _warp(30 hours);
        core.repriceStatement(sid);
        _buyOnly();
        _warp(1 hours);
        assertGe(_live(sid).reserve, ctl.priceOf(sid), "the reserve never sits under the ask");
        _bid(alice, sid, _live(sid).reserve);
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(ICore.HasBid.selector);
        ctl.buy{value: 100 ether}(sid);
    }

    /// S-1 fixed: the controller floor can sit under the core hard floor (the owner raised only the core floor). the
    /// quote and the payment are clamped at the hard floor, so buy only mode keeps working and the excess comes back
    function test_FIXED_buyOnlyWorksWhileTheAskIsUnderTheCoreFloor() public {
        uint256 sid = _composeOnce().sid;
        _buyOnly();
        _raise(9_000);
        _warp(63 hours);
        uint256 floor = _floorOf(sid);
        assertEq(ctl.priceOf(sid), floor, "the quote is the hard floor");
        vm.deal(bob, 1000 ether);
        vm.prank(bob);
        ctl.buy{value: 1000 ether}(sid);
        assertEq(STATEMENTS.ownerOf(sid), bob, "sold at the floor");
        assertEq(bob.balance, 1000 ether - floor, "the excess came back");
        assertEq(address(ctl).balance, 0);
    }

    // ------------------------------------------------------------------ statementPrice and _reserveFor

    function test_OK_price_extremesDoNotOverflowOrUnderflow() public {
        vm.startPrank(owner);
        ctl.setStepBps(5_000);
        ctl.setStepEvery(1 minutes);
        vm.stopPrank();
        uint256 cost = 10 ether;
        assertEq(ctl.statementPrice(0, cost, 0), cost * 7_500 / 10_000, "ancient listing sits at the floor");
        assertEq(ctl.statementPrice(0, cost, uint64(block.timestamp)), cost * 11_000 / 10_000, "age zero is the start");
        vm.prank(owner);
        ctl.setStartBps(40_000);
        assertEq(ctl.statementPrice(0, type(uint128).max, 0), uint256(type(uint128).max) * 7_500 / 10_000);
        assertEq(ctl.statementPrice(0, 0, 0), 0, "cost zero asks zero");
        // a listing in the future reverts (checked subtraction). the core never passes one: listedAt is set to now
        vm.expectRevert();
        ctl.statementPrice(0, cost, uint64(block.timestamp + 1));
        vm.expectRevert();
        ctl.statementPrice(0, cost, type(uint64).max);
    }

    function test_OK_reserve_floorBindsAControllerThatAsksLess() public {
        uint256 sid = _composeOnce().sid;
        ScriptedController sc = new ScriptedController();
        _setController(address(sc));
        sc.setPriceBps(1);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, _floorOf(sid), "floored at the hard floor");
        sc.setPriceBps(20_000);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, _cost(sid) * 2, "an honest higher ask is kept");
    }

    function test_OK_reserve_badControllerAnswersRevertAndKeepTheStoredReserve() public {
        uint256 sid = _composeOnce().sid;
        uint256 stored = _live(sid).reserve;
        ScriptedController sc = new ScriptedController();
        _setController(address(sc));
        sc.setRevertPrice(true);
        vm.expectRevert(ICore.BadPrice.selector);
        core.repriceStatement(sid);
        sc.setRevertPrice(false);
        sc.setBurnPrice(true);
        vm.expectRevert(ICore.BadPrice.selector);
        core.repriceStatement(sid);
        sc.setBurnPrice(false);
        sc.setShortPrice(true);
        vm.expectRevert(ICore.BadPrice.selector);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, stored, "the stored reserve stands");
    }

    function test_OK_reserve_priceReadGasIsFarUnderTheCap() public {
        uint256 sid = _composeOnce().sid;
        (,, uint256 cost, uint64 at) = core.statementInfo(sid);
        vm.cool(address(ctl));
        uint256 g = gasleft();
        ctl.statementPrice(sid, cost, at);
        uint256 used = g - gasleft();
        emit log_named_uint("cold statementPrice gas", used);
        assertLt(used, 20_000, "the core caps the read at 200_000");
    }

    // ------------------------------------------------------------------ repriceStatement

    function test_OK_reprice_aStrangerCanOnlyWalkTheReserveDownAndLoopsAreHarmless() public {
        uint256 sid = _composeOnce().sid;
        uint256 last = _live(sid).reserve;
        (,,, uint64 at0) = core.statementInfo(sid);
        for (uint256 i; i < 6; ++i) {
            _warp(7 hours);
            vm.prank(bob);
            core.repriceStatement(sid);
            uint256 now_ = _live(sid).reserve;
            assertLe(now_, last, "never raised by a stranger");
            assertEq(now_, ctl.priceOf(sid), "equals the ask now");
            vm.prank(bob);
            core.repriceStatement(sid);
            assertEq(_live(sid).reserve, now_, "a repeat changes nothing");
            last = now_;
        }
        (,,, uint64 at1) = core.statementInfo(sid);
        assertEq(at1, at0, "listedAt untouched by reprice");
    }

    function test_OK_reprice_withABidReverts() public {
        uint256 sid = _composeOnce().sid;
        _bid(alice, sid, _live(sid).reserve);
        vm.expectRevert(ICore.HasBid.selector);
        core.repriceStatement(sid);
        vm.expectRevert(ICore.NotListed.selector);
        core.repriceStatement(424_242);
    }

    function test_OK_reprice_reserveFollowsTheRaisedFloorWhenCalled() public {
        uint256 sid = _composeOnce().sid;
        _raise(12_000);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, _cost(sid) * 12_000 / 10_000);
    }

    /// S-2 accepted, documented in FLOW 9.2 and DEPLOY: raise the floor with `REPRICE=1`. after the owner raises the hard floor, listings keep the old reserve until someone reprices them, and a bid at
    /// the old reserve wins the statement below the new floor. the spec says a reserve must be at least the floor when
    /// it was SET, so this follows the invariant, but not the plain sentence of 9.2
    function test_ACCEPTED_reserveStaysBelowARaisedFloorUntilRepriced() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        uint256 old = _live(sid).reserve;
        _raise(20_000);
        assertLt(old, cost * 20_000 / 10_000);
        _bid(alice, sid, old);
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), alice, "sold under the new hard floor");
        assertEq(_collectSales(), old);
    }

    /// S-7 documented in DEPLOY: the ask rises again under a bidder after an owner change (here the mode flip), and a stranger can apply it
    function test_ACCEPTED_aStrangerCanRaiseTheReserveAfterAnOwnerAskChange() public {
        uint256 sid = _composeOnce().sid;
        _warp(30 hours);
        core.repriceStatement(sid);
        uint256 low = _live(sid).reserve;
        _buyOnly();
        vm.prank(bob);
        core.repriceStatement(sid);
        assertGt(_live(sid).reserve, low, "reserve jumped back to the start price");
        vm.expectRevert();
        this._bidExt(alice, sid, low);
    }

    function _bidExt(address who, uint256 sid, uint256 amount) external {
        _bid(who, sid, amount);
    }

    // ------------------------------------------------------------------ timelock removal and the locks

    function test_OK_noQueuePathOrOldNameRemains() public {
        string[8] memory sigs = [
            "queue(uint8,bytes)",
            "execute(uint8,bytes)",
            "cancel(uint8,bytes)",
            "TIMELOCK()",
            "frozen()",
            "OWNER()",
            "queuedEta(bytes32)",
            "reserveBps()"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(core).call(abi.encodePacked(bytes4(keccak256(bytes(sigs[i])))));
            assertFalse(ok, sigs[i]);
        }
    }

    function test_OK_everyOwnerDoorIsOwnerOnly() public {
        bytes[11] memory calls = [
            abi.encodeCall(ICore.transferOwnership, (bob)),
            abi.encodeCall(ICore.setController, (bob)),
            abi.encodeCall(ICore.setExitModule, (bob)),
            abi.encodeCall(ICore.addTarget, (bob)),
            abi.encodeCall(ICore.removeTarget, (bob)),
            abi.encodeCall(ICore.lockController, ()),
            abi.encodeCall(ICore.lockExitModule, ()),
            abi.encodeCall(ICore.lockTargets, ()),
            abi.encodeCall(ICore.setSettings, (core.settings())),
            abi.encodeCall(ICore.setRate, (4e12)),
            abi.encodeCall(ICore.setXRate, (5_000))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(bob);
            (bool ok, bytes memory why) = address(core).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(why), ICore.OnlyOwner.selector);
        }
        assertFalse(core.controllerLocked() || core.exitModuleLocked() || core.targetsLocked());
        assertEq(core.pendingOwner(), address(0));
    }

    function test_OK_formerActionsKeepTheirValidityChecks() public {
        vm.startPrank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setController(address(0));
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(0xdead));
        address[4] memory bad = [lc.stack.hook, address(core), core.COIN(), address(house)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addTarget(bad[i]);
        }
        vm.stopPrank();
        _enterPhase2();
        vm.startPrank(owner);
        MockExitModule zero = new MockExitModule(address(xt), 0);
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(zero));
        MockExitModule other = new MockExitModule(address(new MockExitToken("O", "O")), 1e10);
        vm.expectRevert(ICore.ExitTokenChanged.selector);
        core.setExitModule(address(other));
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(core));
        // a target flag set before a module is named is cleared when it becomes the module
        MockExitModule m2 = new MockExitModule(address(xt), 2e10);
        core.addTarget(address(m2));
        assertTrue(core.allowedTarget(address(m2)));
        core.setExitModule(address(m2));
        assertFalse(core.allowedTarget(address(m2)));
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.addTarget(address(m2));
        vm.stopPrank();
    }

    function test_OK_lockController_blocksOnlyTheControllerDoor() public {
        _enterPhase2();
        vm.startPrank(owner);
        core.lockController();
        core.lockController();
        assertTrue(core.controllerLocked());
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("controller")));
        core.setController(address(0xC0DE));
        // everything else stays open
        core.setExitModule(address(new MockExitModule(address(xt), 3e10)));
        core.addTarget(address(0x7A9));
        core.removeTarget(address(0x7A9));
        core.transferOwnership(alice);
        vm.stopPrank();
        Settings memory s = core.settings();
        s.tipCapBps = 100;
        _setSettings(s);
        vm.prank(owner);
        ctl.setStepBps(10);
        assertFalse(core.exitModuleLocked() || core.targetsLocked());
    }

    function test_OK_lockExitModule_revertsWhileUnsetThenBlocksOnlyTheModuleDoor() public {
        vm.prank(owner);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.lockExitModule();
        assertFalse(core.exitModuleLocked());
        uint256 sid = _composeOnce().sid;
        _enterPhase2();
        vm.startPrank(owner);
        core.lockExitModule();
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("exitModule")));
        core.setExitModule(address(mod));
        address fresh = address(new MockExitModule(address(xt), 3e10));
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("exitModule")));
        core.setExitModule(fresh);
        core.setController(address(new SellProbe(core)));
        core.addTarget(address(0x7A9));
        vm.stopPrank();
        _warp(105 hours);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod), "redeem still works");
    }

    function test_OK_lockTargets_blocksOnlyAddTarget() public {
        vm.startPrank(owner);
        core.lockTargets();
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("targets")));
        core.addTarget(address(0x7A9));
        core.removeTarget(Mainnet.SEAPORT);
        assertFalse(core.allowedTarget(Mainnet.SEAPORT), "removal still works");
        core.setController(address(new SellProbe(core)));
        vm.stopPrank();
        _enterPhase2();
        assertTrue(core.targetsLocked());
    }

    function test_OK_allThreeLocksLeaveSettingsAndSaleSettingsOpen() public {
        _enterPhase2();
        vm.startPrank(owner);
        core.lockController();
        core.lockExitModule();
        core.lockTargets();
        vm.stopPrank();
        Settings memory s = core.settings();
        s.feeToBuybackBps = 1_234;
        s.saleFloorBps = 8_000;
        _setSettings(s);
        vm.startPrank(owner);
        core.setRate(5e12);
        core.setXRate(5_000);
        ctl.setFloorBps(8_000);
        ctl.setBuyOnly(true);
        vm.stopPrank();
        assertEq(core.settings().feeToBuybackBps, 1_234);
    }

    /// S-3 documented in DEPLOY (lock only a controller proven in use). the owner locks a controller that cannot price: reprice, compose and the relist of an unwound sale revert for
    /// good and the controller can never be replaced. redeem still works because it never reads the controller
    function test_ACCEPTED_lockControllerAcceptsAControllerThatCannotPrice() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        ScriptedController sc = new ScriptedController();
        sc.setRevertPrice(true);
        vm.startPrank(owner);
        core.setController(address(sc));
        core.lockController();
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("controller")));
        core.setController(address(ctl));
        vm.stopPrank();
        vm.expectRevert(ICore.BadPrice.selector);
        core.repriceStatement(sid);
        _warp(105 hours);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod), "redeem does not read the controller");
    }

    // ------------------------------------------------------------------ owner handover

    function test_OK_handover_twoStepAndTheOldOwnerLosesEveryDoor() public {
        vm.prank(owner);
        vm.expectEmit(address(core));
        emit ICore.OwnershipTransferStarted(owner, alice);
        core.transferOwnership(alice);
        assertEq(core.owner(), owner, "still the old owner until accepted");
        vm.prank(bob);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        vm.prank(alice);
        vm.expectEmit(address(core));
        emit ICore.OwnershipTransferred(owner, alice);
        core.acceptOwnership();
        assertEq(core.owner(), alice);
        assertEq(core.pendingOwner(), address(0), "pending cleared");
        vm.startPrank(owner);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setController(address(ctl));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.lockTargets();
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setStepBps(1);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
    }

    function test_OK_handover_replacingOrClearingThePendingOwner() public {
        vm.startPrank(owner);
        core.transferOwnership(alice);
        core.transferOwnership(bob);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        vm.prank(owner);
        core.transferOwnership(address(0));
        assertEq(core.pendingOwner(), address(0));
        vm.prank(bob);
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        assertEq(core.owner(), owner);
    }

    function test_OK_handover_toTheCoreItselfCannotBeAccepted() public {
        vm.prank(owner);
        core.transferOwnership(address(core));
        assertEq(core.pendingOwner(), address(core));
        // the core has no door that calls acceptOwnership, so the owner keeps the role and can overwrite the pending
        vm.prank(owner);
        core.setController(address(ctl));
        vm.prank(owner);
        core.transferOwnership(alice);
        vm.prank(alice);
        core.acceptOwnership();
        assertEq(core.owner(), alice);
    }

    function test_OK_handover_noRenounceDoorExists() public {
        bytes4[3] memory sels = [bytes4(keccak256("renounceOwnership()")), bytes4(keccak256("renounce()")), bytes4(keccak256("setOwner(address)"))];
        for (uint256 i; i < sels.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(core).call(abi.encodePacked(sels[i], bytes32(0)));
            assertFalse(ok);
        }
    }

    /// true when a warning row of that name is in the report and it is currently raised (its condition is false)
    function _warned(string memory name) internal view returns (bool) {
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].warn && !rows[i].ok && vm.contains(rows[i].name, name)) return true;
        }
        return false;
    }

    /// S-5 fixed: a handover offered to an address shows as a warning row, which never fails the run
    function test_FIXED_postflightWarnsOnAPendingOwner() public {
        postflightAs(lc, address(core), owner);
        (, uint256 n0) = _failed();
        assertFalse(_warned("no pending owner"), "clean at launch");
        vm.prank(owner);
        core.transferOwnership(bob);
        postflightAs(lc, address(core), owner);
        (, uint256 n1) = _failed();
        assertEq(n1, n0, "a warning never fails the run");
        assertTrue(_warned("no pending owner"), "the offer shows as a warning");
        assertEq(core.pendingOwner(), bob);
    }

    function test_OK_postflight_readsTheLiveOwnerAndTheLocks() public {
        postflightAs(lc, address(core), owner);
        (, uint256 n0) = _failed();
        vm.startPrank(owner);
        core.transferOwnership(alice);
        vm.stopPrank();
        vm.prank(alice);
        core.acceptOwnership();
        postflightAs(lc, address(core), owner);
        (string memory afterHandover, uint256 n1) = _failed();
        assertGt(n1, n0, "an unannounced handover fails the owner row");
        emit log_string(afterHandover);
        vm.prank(alice);
        core.lockTargets();
        postflightAs(lc, address(core), owner);
        (, uint256 n2) = _failed();
        assertGt(n2, n1, "a lock fails the launch state row");
    }

    // ------------------------------------------------------------------ fee split in receive()

    function _feeShare(uint16 bps) internal {
        Settings memory s = core.settings();
        s.feeToBuybackBps = bps;
        _setSettings(s);
    }

    /// the fee source (the router) pays the core, which is what `receive` books
    function _hookPays(uint256 amount) internal {
        address hook = lc.stack.feeSource;
        vm.deal(hook, hook.balance + amount);
        vm.prank(hook);
        (bool ok,) = address(core).call{value: amount}("");
        assertTrue(ok);
    }

    function test_OK_receive_onlyHookEthIsBookedAndSkimStaysWhole() public {
        _feeShare(5_000);
        vm.deal(bob, 10 ether);
        uint256 pot = core.ethPot();
        vm.prank(bob);
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok, "a stranger may pay, nothing reverts");
        assertEq(core.ethPot(), pot, "not booked by receive");
        assertEq(core.ethToBuyback(), 0);
        core.skim();
        assertEq(core.ethPot() - pot, 1 ether, "skim books the whole amount to the pot, no split");
        assertEq(core.ethToBuyback(), 0);
        _solvent();
    }

    function test_OK_receive_splitConservesEveryWeiAndPotsStayUnderBalance() public {
        _feeShare(3_333);
        uint256[7] memory amounts = [uint256(0), 1, 2, 3, 9_999, 10_001, 1 ether + 7];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 pot = core.ethPot();
            uint256 bb = core.ethToBuyback();
            _hookPays(amounts[i]);
            assertEq((core.ethPot() - pot) + (core.ethToBuyback() - bb), amounts[i], "no dust lost or made");
            assertEq(core.ethToBuyback() - bb, amounts[i] * 3_333 / 10_000, "rounds down, dust to the pot");
            _solvent();
        }
    }

    function test_OK_receive_allToBuybackLeavesThePotAlone() public {
        _feeShare(10_000);
        uint256 pot = core.ethPot();
        _hookPays(2 ether);
        assertEq(core.ethPot(), pot);
        assertEq(core.ethToBuyback(), 2 ether);
        _feeShare(0);
        _hookPays(1 ether);
        assertEq(core.ethPot(), pot + 1 ether);
    }

    function test_OK_receive_theCoreOwnBuybackStaysSolventWithTheShare() public {
        _skipSniperWindow();
        _feeShare(10_000);
        _hookPays(3 ether);
        vm.roll(block.number + 100);
        uint256 pool = core.ethToBuyback();
        vm.prank(keeper);
        core.buyback();
        _solvent();
        assertLt(core.ethToBuyback(), pool, "the slice left the pool");
        // the hook skim of the core's own swap came back through receive and was split by the same setting
        assertGe(address(core).balance, core.ethPot() + core.ethToBuyback());
    }

    // ------------------------------------------------------------------ redeem reimbursement

    function _exitAndMeasure(uint256 sid) internal returns (uint256 got, uint256 gasUsed, uint256 potDrop) {
        uint256 pot = core.ethPot();
        uint256 before_ = keeper.balance;
        uint256 g = gasleft();
        vm.prank(keeper);
        core.exitStatement(sid);
        gasUsed = g - gasleft();
        got = keeper.balance - before_;
        potDrop = pot - core.ethPot();
    }

    function test_OK_exitRepay_paidFromThePotOnceAndCapped() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _warp(105 hours);
        vm.fee(300 gwei);
        (uint256 got,, uint256 drop) = _exitAndMeasure(sid);
        assertEq(got, drop, "paid from the pot, nowhere else");
        assertEq(got, cost * core.settings().reimburseCapBps / 10_000, "a high basefee binds the cap of the statement cost");
        vm.prank(keeper);
        vm.expectRevert(ICore.NotHeld.selector);
        core.exitStatement(sid);
        _solvent();
    }

    function test_OK_exitRepay_gasBurningModuleCannotPassTheGasBound() public {
        xt = new MockExitToken("X", "X");
        BurnModule bm = new BurnModule(address(xt), UNIT, 6_000_000);
        _setExitModule(address(bm));
        uint256 sid = _composeOnce().sid;
        _warp(105 hours);
        vm.fee(composeBasefee);
        uint256 pot = core.ethPot();
        uint256 before_ = keeper.balance;
        vm.prank(keeper);
        core.exitStatement{gas: 9_000_000}(sid);
        uint256 got = keeper.balance - before_;
        // the counted gas stops at 1_500_000, whatever the module burned
        assertEq(got, 1_500_000 * composeBasefee * core.settings().reimburseBps / 10_000);
        assertEq(pot - core.ethPot(), got);
    }

    function test_OK_exitRepay_aRevertingExitPaysNothing() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        mod.setShortfallBps(5_000);
        _warp(105 hours);
        uint256 pot = core.ethPot();
        uint256 bal = keeper.balance;
        vm.prank(keeper);
        vm.expectRevert(ICore.Underpaid.selector);
        core.exitStatement(sid);
        assertEq(keeper.balance, bal);
        assertEq(core.ethPot(), pot);
        (bool held,,,) = core.statementInfo(sid);
        assertTrue(held);
    }

    function test_OK_exitRepay_exitLaneUsesTheNotionalCap() public {
        _enterPhase2();
        _fundPot(1 ether);
        uint256 sid = _exitLaneStatement();
        vm.fee(500 gwei);
        (uint256 got,,) = _exitAndMeasure(sid);
        Settings memory s = core.settings();
        uint256 notional = 80 * uint256(s.avgScore) * lc.rateStart / 1e4;
        assertEq(got, notional * s.reimburseCapBps / 10_000);
    }

    /// S-8. the core meters gross gas plus a fixed 50_000 and repays 80 percent of it (`reimburseBps` 8_000). the
    /// transaction costs the caller its gas net of the EIP-3529 refund, up to 20 percent of the gross, with the 21_000
    /// intrinsic cost included in the measured gas. so the repayment never exceeds the real cost and stays within 10
    /// percent of it. bounded by the cap and one per statement
    function test_exitRepayIsTheNetGasCostAtTheLaunchShare() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _warp(105 hours);
        vm.fee(composeBasefee);
        (uint256 got, uint256 gasUsed,) = _exitAndMeasure(sid);
        uint256 realCost = gasUsed * composeBasefee;
        emit log_named_uint("repaid", got);
        emit log_named_uint("real cost", realCost);
        assertLe(got, realCost, "never more than the net gas the caller paid");
        assertGe(got * 10, realCost * 9, "within 10 percent of the net gas the caller paid");
    }

    // ------------------------------------------------------------------ settings, config, scripts

    function _withAll(bool high) internal view returns (Settings memory s) {
        uint256[30] memory v = high ? SettingsFields.hi() : SettingsFields.lo();
        for (uint256 i; i < SettingsFields.N; ++i) {
            SettingsFields.set(s, i, v[i]);
        }
    }

    function test_OK_settings_packingRoundTripAtEveryMaxAndMin() public {
        for (uint256 k; k < 2; ++k) {
            Settings memory s = _withAll(k == 1);
            assertEq(SettingsBounds.firstViolation(s), bytes32(0), "table values are inside the bounds");
            _setSettings(s);
            Settings memory live = core.settings();
            assertEq(abi.encode(live), abi.encode(s), "every field survives the three packed slots");
            for (uint256 i; i < SettingsFields.N; ++i) {
                assertEq(SettingsFields.get(live, i), SettingsFields.get(s, i));
            }
        }
    }

    function test_OK_settings_everyFieldBoundMatchesTheScriptTable() public {
        bytes32[30] memory names = SettingsFields.names();
        uint256[30] memory lo = SettingsFields.lo();
        uint256[30] memory hi = SettingsFields.hi();
        for (uint256 i; i < SettingsFields.N; ++i) {
            Settings memory s = core.settings();
            SettingsFields.set(s, i, hi[i] + 1);
            assertTrue(SettingsBounds.firstViolation(s) != bytes32(0), string.concat("above ", _nm(names[i])));
            vm.prank(owner);
            vm.expectRevert();
            core.setSettings(s);
            if (lo[i] != 0) {
                s = core.settings();
                SettingsFields.set(s, i, lo[i] - 1);
                assertTrue(SettingsBounds.firstViolation(s) != bytes32(0), string.concat("below ", _nm(names[i])));
                vm.prank(owner);
                vm.expectRevert();
                core.setSettings(s);
            }
        }
    }

    function test_OK_settings_fieldCountAndSelectorAgreeEverywhere() public {
        assertEq(abi.encode(core.settings()).length, SettingsFields.N * 32, "struct has as many words as the table");
        TupleProbe t = new TupleProbe();
        bytes4 fromScript = bytes4(keccak256(abi.encodePacked("setSettings(", t.tuple(), ")")));
        assertEq(fromScript, ICore.setSettings.selector, "SetSettings.s.sol tuple equals the Settings struct");
    }

    function _nm(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) ++n;
        bytes memory o = new bytes(n);
        for (uint256 i; i < n; ++i) {
            o[i] = b[i];
        }
        return string(o);
    }

    function _has(string[] memory keys, string memory k) internal pure returns (bool) {
        for (uint256 i; i < keys.length; ++i) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(k))) return true;
        }
        return false;
    }

    function test_OK_config_jsonCarriesEveryFieldAndTheSaleBlock() public view {
        string memory j = vm.readFile(DEFAULT_CONFIG_FILE);
        string[] memory keys = vm.parseJsonKeys(j, ".settings");
        bytes32[30] memory names = SettingsFields.names();
        assertEq(keys.length, SettingsFields.N, "the settings block has exactly the fields of the struct");
        for (uint256 i; i < SettingsFields.N; ++i) {
            assertTrue(_has(keys, _nm(names[i])), _nm(names[i]));
        }
        assertFalse(_has(keys, "reserveBps"));
        string[] memory sale = vm.parseJsonKeys(j, ".sale");
        assertEq(sale.length, 5);
        LaunchConfig memory f = loadConfig(DEFAULT_CONFIG_FILE);
        assertEq(abi.encode(f.sale), abi.encode(Mainnet.defaultSale()));
        assertEq(abi.encode(f.settings), abi.encode(Mainnet.defaultSettings()));
        assertEq(f.symbol, "CC");
    }

    function test_OK_postflight_comparesEveryFieldOfTheSettingsAndTheSaleBlock() public {
        postflightAs(lc, address(core), owner);
        (string memory clean,) = _failed();
        for (uint256 i; i < SettingsFields.N; ++i) {
            LaunchConfig memory c = lc;
            SettingsFields.set(c.settings, i, SettingsFields.get(c.settings, i) == 0 ? 1 : SettingsFields.get(c.settings, i) - 1);
            postflightAs(c, address(core), owner);
            (string memory dirty,) = _failed();
            assertTrue(keccak256(bytes(dirty)) != keccak256(bytes(clean)), _nm(SettingsFields.names()[i]));
        }
        for (uint256 i; i < 5; ++i) {
            LaunchConfig memory c = lc;
            if (i == 0) c.sale.buyOnly = !c.sale.buyOnly;
            if (i == 1) c.sale.startBps += 1;
            if (i == 2) c.sale.stepBps += 1;
            if (i == 3) c.sale.stepEvery += 1;
            if (i == 4) c.sale.floorBps += 1;
            postflightAs(c, address(core), owner);
            (string memory dirty,) = _failed();
            assertTrue(keccak256(bytes(dirty)) != keccak256(bytes(clean)), "sale field unseen by postflight");
        }
    }

    function tryController(Sale memory k) external returns (bool) {
        try this._ctlExt(k) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    function _ctlExt(Sale memory k) external returns (address) {
        return deployCode("ControllerV1.sol:ControllerV1", abi.encode(address(core), k));
    }

    function test_OK_saleBounds_scriptAndControllerConstructorAgree() public {
        Sale[9] memory v;
        for (uint256 i; i < v.length; ++i) {
            v[i] = Mainnet.defaultSale();
        }
        v[0].startBps = 999;
        v[1].startBps = 40_001;
        v[2].stepBps = 5_001;
        v[3].stepEvery = 59;
        v[4].stepEvery = 30 days + 1;
        v[5].floorBps = 999;
        v[6].floorBps = 11_001;
        v[7].stepBps = 5_000;
        v[7].stepEvery = 1 minutes;
        v[8].floorBps = 11_000;
        for (uint256 i; i < v.length; ++i) {
            LaunchConfig memory c = lc;
            c.sale = v[i];
            assertEq(saleViolation(c) == bytes32(0), this.tryController(v[i]), string.concat("variant ", vm.toString(i)));
        }
    }

    function test_OK_sizeMarginOfTheCore() public {
        uint256 size = vm.getDeployedCode("Core.sol:Core").length;
        emit log_named_uint("core runtime bytes", size);
        // the v2 brief (docs/FLOW.md 10.6) asks for at least 60 bytes of headroom, `rescueCoin` took the old 150 (decision)
        assertGe(24_576 - size, 60, "the brief asks for a margin of at least 60");
    }

    bool internal ownerChangedFlag;
    bool internal coinChangedFlag;

    function _coinChanged() internal view override returns (bool) {
        return coinChangedFlag;
    }

    function _ownerChanged() internal view override returns (bool) {
        return ownerChangedFlag;
    }

    /// S-6 fixed (postflight half, the Resume half is in test/Resume.t.sol): DEPLOY.md hands the Core to a multisig with
    /// OWNER_CHANGED=1 and the token admin with updateAdmin, named by COIN_CHANGED=1 (decision: v2 has its own flag)
    function test_FIXED_ownerChangedFlagRelaxesTheCoinAdminRow() public {
        ownerChangedFlag = true;
        coinChangedFlag = true;
        vm.prank(owner);
        core.transferOwnership(alice);
        vm.prank(alice);
        core.acceptOwnership();
        vm.prank(owner);
        (bool ok,) = address(coin).call(abi.encodeWithSignature("updateAdmin(address)", alice));
        assertTrue(ok, "the coin admin hands over");
        postflightAs(lc, address(core), owner);
        (string memory failed, uint256 n) = _failed();
        assertEq(n, 0, failed);
        coinChangedFlag = false;
        postflightAs(lc, address(core), owner);
        (failed,) = _failed();
        assertTrue(vm.contains(failed, "coin: admin is the config owner"), "without the flag the row still fails");
    }

    bool internal locksChangedFlag;

    function _locksChanged() internal view override returns (bool) {
        return locksChangedFlag;
    }

    /// S-10 fixed: LOCKS_CHANGED=1 turns the launch state row into a report line
    function test_FIXED_locksChangedFlagTurnsTheLockRowIntoAReportLine() public {
        vm.prank(owner);
        core.lockTargets();
        postflightAs(lc, address(core), owner);
        (string memory failed, uint256 n) = _failed();
        assertGt(n, 0);
        assertTrue(vm.contains(failed, "core: no locks, no exit module"), failed);
        locksChangedFlag = true;
        postflightAs(lc, address(core), owner);
        (failed, n) = _failed();
        assertEq(n, 0, failed);
    }

    function test_OK_priceOf_refusesWhatIsNotForSale() public {
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.priceOf(777_777);
        _enterPhase2();
        uint256 x = _exitLaneStatement();
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.priceOf(x);
        (uint256 sid,) = _sellStatement(alice);
        core.syncStatement(sid);
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.priceOf(sid);
    }

    /// S-9 fixed: with nothing pending, the zero address is the pending owner, and a call from it no longer passes
    function test_FIXED_acceptOwnershipRejectsTheZeroCaller() public {
        assertEq(core.pendingOwner(), address(0));
        vm.prank(address(0));
        vm.expectRevert(ICore.OnlyPendingOwner.selector);
        core.acceptOwnership();
        assertEq(core.owner(), owner, "the owner is untouched");
    }

    /// S-4 fixed: a statement that came back from an unwound sale is relisted at the hard floor when the controller
    /// cannot price, so it can be redeemed whatever the controller does. compose and reprice keep reverting
    function test_FIXED_relistFallsBackToTheHardFloorWhenTheControllerFails() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 aid = _live(sid).auctionId;
        _bid(alice, sid, _live(sid).reserve);
        vm.mockCallRevert(
            address(STATEMENTS),
            abi.encodeWithSelector(IStatements.transferFrom.selector, address(house), alice, sid),
            "cannot receive"
        );
        _endAuction(sid);
        _warp(30 days + 1);
        house.unwindStuckLot{gas: END_GAS}(aid);
        vm.clearMockedCalls();
        assertEq(STATEMENTS.ownerOf(sid), address(core), "returned to the core by the unwind");
        ScriptedController sc = new ScriptedController();
        sc.setRevertPrice(true);
        vm.prank(owner);
        core.setController(address(sc));
        core.syncStatement(sid);
        assertEq(_live(sid).reserve, _floorOf(sid), "listed at the hard floor");
        vm.expectRevert(ICore.BadPrice.selector);
        core.repriceStatement(sid);
        _warp(105 hours);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod), "redeemed with a controller that cannot price");
    }

    function test_OK_composeStillRevertsWhenTheControllerCannotPrice() public {
        _fillEthPile(80 - core.pileSize(Lane.Eth));
        ScriptedController sc = new ScriptedController();
        uint256[] memory page = core.pilePage(Lane.Eth, 0, 80);
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        sc.setPage(Lane.Eth, true, ids, 0);
        sc.setRevertPrice(true);
        vm.prank(owner);
        core.setController(address(sc));
        vm.fee(composeBasefee);
        vm.expectRevert(ICore.BadPrice.selector);
        core.compose();
    }
}
