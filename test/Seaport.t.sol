// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {CoreBase} from "./CoreUnit.t.sol";
import {Core} from "../src/Core.sol";
import {Lane, Mainnet} from "../src/interfaces/Interfaces.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {
    ISeaport,
    ItemType,
    OrderType,
    BasicOrderType,
    OfferItem,
    ConsiderationItem,
    OrderParameters,
    OrderComponents,
    Order,
    AdvancedOrder,
    CriteriaResolver,
    AdditionalRecipient,
    BasicOrderParameters,
    ZoneParameters
} from "./utils/SeaportTypes.sol";

/// a restricted order zone that accepts a fill only when the caller supplied the extra data it expects.
/// it stands in for the server signed extra data a live restricted listing needs. seaport 1.6 asks the zone twice,
/// `authorizeOrder` before the transfers and `validateOrder` after them.
contract ExtraDataZone {
    bytes public constant EXPECTED = hex"c0ffee";

    function authorizeOrder(ZoneParameters calldata p) external pure returns (bytes4) {
        require(keccak256(p.extraData) == keccak256(EXPECTED), "extra data");
        return this.authorizeOrder.selector;
    }

    function validateOrder(ZoneParameters calldata p) external pure returns (bytes4) {
        require(keccak256(p.extraData) == keccak256(EXPECTED), "extra data");
        return this.validateOrder.selector;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// proves that `Core.buyListing` fulfills genuine Seaport 1.6 orders on the fork. every order is built here:
/// a seller key receives a real credit, approves Seaport directly on Credits (no conduit), and signs the eip 712
/// digest of the order hash that Seaport itself computes, under the domain separator Seaport itself reports.
contract SeaportTest is CoreBase {
    using stdStorage for StdStorage;
    using FixedPointMathLib for uint256;

    ISeaport internal constant SEAPORT = ISeaport(Mainnet.SEAPORT);

    /// the pot is large enough that the hourly cap clears every ceiling the tests use.
    uint256 internal constant POT = 100 ether;
    /// wei per whole point. the highest scoring credit then has a ceiling near 1.5 ether.
    uint256 internal constant TARGET_RATE = 2e15;

    address internal seller;
    uint256 internal sellerKey;
    address internal feeTaker;
    uint256 internal salt;
    uint256 internal pick;

    struct Snap {
        uint256 pot;
        uint256 balance;
        uint256 toBuyback;
        uint256 rate;
        uint256 fillTime;
        uint256 pile;
        uint256 credits;
        uint256 keeper;
        uint256 seller;
        uint256 feeTaker;
    }

    function setUp() public override {
        super.setUp();
        (seller, sellerKey) = makeAddrAndKey("creditsengine.seaport.seller");
        feeTaker = makeAddr("creditsengine.seaport.fees");
        assertEq(seller.code.length + feeTaker.code.length, 0);

        _fund(POT);
        for (uint256 i; i < 600 && core.ethRate() < TARGET_RATE; ++i) {
            _warp(1 hours);
        }
        assertGe(core.ethRate(), TARGET_RATE, "rate cleared");
    }

    /*//////////////////////////////////////////////////////////////
                                helpers
    //////////////////////////////////////////////////////////////*/

    /// hands the next usable credit to the seller and approves Seaport itself as operator, no conduit.
    function _list() internal returns (uint256 id) {
        do {
            id = CreditIds.at(100 + pick++);
        } while (id == LISTED_A || id == LISTED_B || id == 18683);
        vm.prank(STRATEGY);
        CREDITS.transferFrom(STRATEGY, seller, id);
        vm.prank(seller);
        CREDITS.setApprovalForAll(address(SEAPORT), true);
        assertEq(CREDITS.ownerOf(id), seller);
        assertTrue(CREDITS.isApprovedForAll(seller, address(SEAPORT)));
    }

    function _components(uint256 id, uint256 sellerAmount, uint256 feeAmount, address zone, OrderType orderType)
        internal
        returns (OrderComponents memory c)
    {
        c.offerer = seller;
        c.zone = zone;
        c.offer = new OfferItem[](1);
        c.offer[0] = OfferItem(ItemType.ERC721, address(CREDITS), id, 1, 1);
        c.consideration = new ConsiderationItem[](feeAmount == 0 ? 1 : 2);
        c.consideration[0] =
            ConsiderationItem(ItemType.NATIVE, address(0), 0, sellerAmount, sellerAmount, payable(seller));
        if (feeAmount != 0) {
            c.consideration[1] =
                ConsiderationItem(ItemType.NATIVE, address(0), 0, feeAmount, feeAmount, payable(feeTaker));
        }
        c.orderType = orderType;
        c.startTime = block.timestamp - 1;
        c.endTime = block.timestamp + 7 days;
        c.zoneHash = bytes32(0);
        c.salt = ++salt;
        c.conduitKey = bytes32(0);
        c.counter = SEAPORT.getCounter(seller);
    }

    function _open(uint256 id, uint256 sellerAmount, uint256 feeAmount) internal returns (OrderComponents memory) {
        return _components(id, sellerAmount, feeAmount, address(0), OrderType.FULL_OPEN);
    }

    /// the real domain separator from `information()` and the real order hash from `getOrderHash`.
    function _digest(OrderComponents memory c) internal view returns (bytes32) {
        (string memory version, bytes32 domainSeparator,) = SEAPORT.information();
        assertEq(version, "1.6");
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, SEAPORT.getOrderHash(c)));
    }

    function _sign(OrderComponents memory c, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(c));
        return abi.encodePacked(r, s, v);
    }

    function _total(OrderComponents memory c) internal pure returns (uint256 sum) {
        for (uint256 i; i < c.consideration.length; ++i) {
            sum += c.consideration[i].startAmount;
        }
    }

    function _params(OrderComponents memory c) internal pure returns (OrderParameters memory p) {
        p = OrderParameters(
            c.offerer,
            c.zone,
            c.offer,
            c.consideration,
            c.orderType,
            c.startTime,
            c.endTime,
            c.zoneHash,
            c.salt,
            c.conduitKey,
            c.consideration.length
        );
    }

    function _basicData(OrderComponents memory c, bytes memory sig) internal pure returns (bytes memory) {
        AdditionalRecipient[] memory extra = new AdditionalRecipient[](c.consideration.length - 1);
        for (uint256 i; i < extra.length; ++i) {
            extra[i] = AdditionalRecipient(c.consideration[i + 1].startAmount, c.consideration[i + 1].recipient);
        }
        BasicOrderParameters memory b = BasicOrderParameters({
            considerationToken: address(0),
            considerationIdentifier: 0,
            considerationAmount: c.consideration[0].startAmount,
            offerer: payable(c.offerer),
            zone: c.zone,
            offerToken: c.offer[0].token,
            offerIdentifier: c.offer[0].identifierOrCriteria,
            offerAmount: 1,
            basicOrderType: BasicOrderType(uint8(c.orderType)),
            startTime: c.startTime,
            endTime: c.endTime,
            zoneHash: c.zoneHash,
            salt: c.salt,
            offererConduitKey: c.conduitKey,
            fulfillerConduitKey: bytes32(0),
            totalOriginalAdditionalRecipients: extra.length,
            additionalRecipients: extra,
            signature: sig
        });
        return abi.encodeCall(ISeaport.fulfillBasicOrder_efficient_6GL6yc, (b));
    }

    function _basicData(OrderComponents memory c) internal view returns (bytes memory) {
        return _basicData(c, _sign(c, sellerKey));
    }

    /// standard path. there is no recipient argument, the credit goes to the caller.
    function _orderData(OrderComponents memory c) internal view returns (bytes memory) {
        return abi.encodeCall(ISeaport.fulfillOrder, (Order(_params(c), _sign(c, sellerKey)), bytes32(0)));
    }

    function _advancedData(OrderComponents memory c, bytes memory extraData, address recipient)
        internal
        view
        returns (bytes memory)
    {
        AdvancedOrder memory a = AdvancedOrder(_params(c), 1, 1, _sign(c, sellerKey), extraData);
        return abi.encodeCall(ISeaport.fulfillAdvancedOrder, (a, new CriteriaResolver[](0), bytes32(0), recipient));
    }

    function _snap() internal view returns (Snap memory s) {
        s.pot = core.ethPot();
        s.balance = address(core).balance;
        s.toBuyback = core.ethToBuyback();
        s.rate = core.rateAtCheckpoint();
        s.fillTime = core.lastFillTime();
        s.pile = core.pileSize(Lane.Eth);
        s.credits = CREDITS.balanceOf(address(core));
        s.keeper = keeper.balance;
        s.seller = seller.balance;
        s.feeTaker = feeTaker.balance;
    }

    function _assertSame(Snap memory a, Snap memory b) internal pure {
        assertEq(a.pot, b.pot, "pot");
        assertEq(a.balance, b.balance, "balance");
        assertEq(a.toBuyback, b.toBuyback, "toBuyback");
        assertEq(a.rate, b.rate, "rate");
        assertEq(a.fillTime, b.fillTime, "fillTime");
        assertEq(a.pile, b.pile, "pile");
        assertEq(a.credits, b.credits, "credits");
        assertEq(a.keeper, b.keeper, "keeper");
        assertEq(a.seller, b.seller, "seller");
        assertEq(a.feeTaker, b.feeTaker, "feeTaker");
    }

    function _tip(uint256 ceiling, uint256 cost) internal pure returns (uint256) {
        return ((ceiling - cost) * 1000 / 10_000).min(cost * 200 / 10_000);
    }

    /// calls the door as the keeper and checks everything a successful buy must leave behind.
    /// `cost` is the exact net eth the order takes from the core.
    function _buy(uint256 id, uint256 value, bytes memory data, uint256 cost) internal returns (uint256 tip) {
        uint256 ceiling = core.ceilingOf(id);
        tip = _tip(ceiling, cost);
        Snap memory before = _snap();
        uint256 rate = core.ethRate();

        vm.prank(keeper);
        core.buyListing(value, data, id, Mainnet.SEAPORT);

        assertEq(CREDITS.ownerOf(id), address(core), "core owns the credit");
        assertEq(CREDITS.balanceOf(address(core)), before.credits + 1);
        (bool inPile, Lane lane, uint256 booked,) = core.creditInfo(id);
        assertTrue(inPile, "in the pile");
        assertEq(uint8(lane), uint8(Lane.Eth), "eth lane");
        assertEq(booked, cost + tip, "costOf is cost plus tip");
        assertEq(core.pileSize(Lane.Eth), before.pile + 1);
        assertEq(keeper.balance - before.keeper, tip, "tip paid to caller");
        assertEq(core.ethPot(), before.pot - cost - tip, "pot down by exactly cost and tip");
        assertEq(address(core).balance, before.balance - cost - tip, "balance down by exactly cost and tip");
        assertEq(core.ethToBuyback(), before.toBuyback);
        assertEq(core.rateAtCheckpoint(), rate - rate * 1000 * (cost + tip) / (10_000 * before.pot), "rate drop");
        assertEq(core.lastFillTime(), block.timestamp);
        assertLe(cost + tip, ceiling, "never above the ceiling");
        assertLe(tip, cost * 200 / 10_000, "tip within two percent of cost");
        _solvent();
        assertEq(address(core).balance - core.ethPot() - core.ethToBuyback(), 0, "no surplus");
    }

    function _expectFail(uint256 id, uint256 value, bytes memory data, bytes4 err) internal {
        Snap memory before = _snap();
        address owner_ = CREDITS.ownerOf(id);
        vm.prank(keeper);
        vm.expectRevert(err);
        core.buyListing(value, data, id, Mainnet.SEAPORT);
        _assertSame(before, _snap());
        assertEq(CREDITS.ownerOf(id), owner_, "credit did not move");
    }

    /*//////////////////////////////////////////////////////////////
                    1 and 2. fulfillBasicOrder_efficient
    //////////////////////////////////////////////////////////////*/

    function test_basic_singleConsiderationToSeller() public {
        uint256 id = _list();
        uint256 ceiling = core.ceilingOf(id);
        uint256 price = ceiling * 9 / 10;
        // at 90 percent of the ceiling the savings bound is the active one.
        assertLt((ceiling - price) / 10, price * 200 / 10_000);
        OrderComponents memory c = _open(id, price, 0);
        assertEq(c.consideration.length, 1);

        uint256 sellerBefore = seller.balance;
        uint256 tip = _buy(id, price, _basicData(c), price);

        assertEq(tip, (ceiling - price) * 1000 / 10_000, "tip is a tenth of the savings");
        assertEq(seller.balance - sellerBefore, price, "seller received the price");
    }

    function test_basic_tipIsCappedAtTwoPercentOfCost() public {
        uint256 id = _list();
        uint256 ceiling = core.ceilingOf(id);
        uint256 price = ceiling / 2;
        OrderComponents memory c = _open(id, price, 0);

        uint256 tip = _buy(id, price, _basicData(c), price);
        assertEq(tip, price * 200 / 10_000, "cap branch");
    }

    function test_basic_additionalRecipient() public {
        uint256 id = _list();
        uint256 total = core.ceilingOf(id) * 7 / 10;
        uint256 fee = total / 100;
        OrderComponents memory c = _open(id, total - fee, fee);
        assertEq(c.consideration.length, 2);
        assertEq(_total(c), total);

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeTaker.balance;
        _buy(id, total, _basicData(c), total);

        assertEq(seller.balance - sellerBefore, total - fee, "seller got the price less the fee");
        assertEq(feeTaker.balance - feeBefore, fee, "fee recipient got one percent");
        (,, uint256 booked,) = core.creditInfo(id);
        assertEq(booked, total + total * 200 / 10_000, "cost is the sum of every payout");
    }

    /*//////////////////////////////////////////////////////////////
                         3. fulfillOrder, standard path
    //////////////////////////////////////////////////////////////*/

    function test_fulfillOrder_recipientDefaultsToCaller() public {
        uint256 id = _list();
        uint256 total = core.ceilingOf(id) * 6 / 10;
        uint256 fee = total / 50;
        OrderComponents memory c = _open(id, total - fee, fee);

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeTaker.balance;
        bytes memory data = _orderData(c);
        assertEq(bytes4(data), ISeaport.fulfillOrder.selector);
        _buy(id, total, data, total);

        assertEq(CREDITS.ownerOf(id), address(core), "msg.sender, the core, received the credit");
        assertEq(seller.balance - sellerBefore, total - fee);
        assertEq(feeTaker.balance - feeBefore, fee);
    }

    /*//////////////////////////////////////////////////////////////
                  4. fulfillAdvancedOrder, explicit recipient
    //////////////////////////////////////////////////////////////*/

    function test_fulfillAdvancedOrder_explicitRecipientIsCore() public {
        uint256 id = _list();
        uint256 price = core.ceilingOf(id) * 8 / 10;
        OrderComponents memory c = _open(id, price, 0);

        uint256 sellerBefore = seller.balance;
        bytes memory data = _advancedData(c, "", address(core));
        assertEq(bytes4(data), ISeaport.fulfillAdvancedOrder.selector);
        _buy(id, price, data, price);
        assertEq(seller.balance - sellerBefore, price);
    }

    /*//////////////////////////////////////////////////////////////
                           5. overpayment refund
    //////////////////////////////////////////////////////////////*/

    function _overpay(uint256 path) internal {
        uint256 id = _list();
        uint256 ceiling = core.ceilingOf(id);
        uint256 total = ceiling * 6 / 10;
        uint256 fee = total / 100;
        OrderComponents memory c = _open(id, total - fee, fee);
        bytes memory data = path == 0 ? _basicData(c) : path == 1 ? _orderData(c) : _advancedData(c, "", address(core));
        // value is above the order total and at the ceiling, so the door lets it through.
        uint256 value = ceiling;
        assertGt(value, total);

        uint256 balanceBefore = address(core).balance;
        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeTaker.balance;
        uint256 tip = _buy(id, value, data, total);

        // the excess came back to the core mid call: the balance fell by cost and tip only, not by value.
        assertEq(balanceBefore - address(core).balance, total + tip, "refund came back");
        assertEq(seller.balance - sellerBefore, total - fee);
        assertEq(feeTaker.balance - feeBefore, fee);
        (,, uint256 booked,) = core.creditInfo(id);
        assertEq(booked, total + tip, "cost is the order total, not value");

        // the refund is not revenue: nothing for skim to book, pot and buyback pot unchanged by it.
        uint256 pot = core.ethPot();
        core.skim();
        assertEq(core.ethPot(), pot, "skim books nothing");
        assertEq(core.ethToBuyback(), 0);
        assertLe(core.ethPot() + core.ethToBuyback(), address(core).balance);
    }

    function test_overpay_basic() public {
        _overpay(0);
    }

    function test_overpay_fulfillOrder() public {
        _overpay(1);
    }

    function test_overpay_fulfillAdvancedOrder() public {
        _overpay(2);
    }

    /*//////////////////////////////////////////////////////////////
                              6. failures
    //////////////////////////////////////////////////////////////*/

    function test_fail_orderForDifferentCredit() public {
        uint256 listed = _list();
        uint256 asked = CreditIds.at(300);
        assertEq(CREDITS.ownerOf(asked), STRATEGY);
        uint256 price = core.ceilingOf(asked).min(core.ceilingOf(listed)) / 2;
        OrderComponents memory c = _open(listed, price, 0);
        // the call delivers a credit, just not the one the caller asked for.
        _expectFail(asked, price, _basicData(c), Core.NoCredit.selector);
        _expectFail(asked, price, _orderData(c), Core.NoCredit.selector);
        assertEq(CREDITS.ownerOf(listed), seller);
    }

    function test_fail_recipientIsNotTheCore() public {
        uint256 id = _list();
        uint256 price = core.ceilingOf(id) / 2;
        OrderComponents memory c = _open(id, price, 0);
        // the order fills, the credit goes to the keeper, the core gets nothing and the whole buy unwinds.
        _expectFail(id, price, _advancedData(c, "", keeper), Core.NoCredit.selector);
    }

    function test_fail_cancelledOrder() public {
        uint256 id = _list();
        uint256 price = core.ceilingOf(id) / 2;
        OrderComponents memory c = _open(id, price, 0);
        bytes memory data = _basicData(c);

        // control: the same order fills before the cancel.
        uint256 snap = vm.snapshotState();
        _buy(id, price, data, price);
        vm.revertToState(snap);

        OrderComponents[] memory orders = new OrderComponents[](1);
        orders[0] = c;
        vm.prank(seller);
        assertTrue(SEAPORT.cancel(orders));

        _expectFail(id, price, data, Core.CallFailed.selector);
        _expectFail(id, price, _orderData(c), Core.CallFailed.selector);
    }

    function test_fail_badSignature() public {
        uint256 id = _list();
        uint256 price = core.ceilingOf(id) / 2;
        OrderComponents memory c = _open(id, price, 0);
        (, uint256 otherKey) = makeAddrAndKey("creditsengine.seaport.impostor");
        _expectFail(id, price, _basicData(c, _sign(c, otherKey)), Core.CallFailed.selector);

        // a signature made over a different order does not carry over either.
        OrderComponents memory other = _open(id, price + 1, 0);
        _expectFail(id, price, _basicData(c, _sign(other, sellerKey)), Core.CallFailed.selector);

        // and the genuine one still works afterwards.
        _buy(id, price, _basicData(c), price);
    }

    function test_fail_valueAboveCeiling() public {
        uint256 id = _list();
        uint256 ceiling = core.ceilingOf(id);
        OrderComponents memory c = _open(id, ceiling, 0);
        // the order itself is fine at exactly the ceiling.
        _expectFail(id, ceiling + 1, _basicData(c), Core.AboveCeiling.selector);
        _expectFail(id, ceiling + 1, _orderData(c), Core.AboveCeiling.selector);
        uint256 tip = _buy(id, ceiling, _basicData(c), ceiling);
        assertEq(tip, 0, "no savings, no tip");
    }

    function test_fail_valueAbovePot() public {
        uint256 id = _list();
        uint256 price = core.ceilingOf(id) / 2;
        OrderComponents memory c = _open(id, price, 0);
        bytes memory data = _basicData(c);
        stdstore.target(address(core)).sig("ethPot()").checked_write(price - 1);
        _expectFail(id, price, data, Core.PotTooSmall.selector);
    }

    function test_fail_hourlyCap() public {
        uint256 id = _list();
        uint256 price = core.ceilingOf(id) / 2;
        OrderComponents memory c = _open(id, price, 0);
        bytes memory data = _basicData(c);
        // pot of three prices: the order is affordable but is above a fifth of the pot.
        stdstore.target(address(core)).sig("ethPot()").checked_write(price * 3);
        _expectFail(id, price, data, Core.HourlyCap.selector);
    }

    function test_fail_orderPaysOutMoreThanValue() public {
        uint256 id = _list();
        uint256 total = core.ceilingOf(id) / 2;
        uint256 fee = total / 100;
        OrderComponents memory c = _open(id, total - fee, fee);
        // seaport needs the full sum of every payout in msg.value. one wei short reverts the whole fill.
        _expectFail(id, total - 1, _basicData(c), Core.CallFailed.selector);
        _expectFail(id, total - 1, _orderData(c), Core.CallFailed.selector);
        _expectFail(id, total - 1, _advancedData(c, "", address(core)), Core.CallFailed.selector);
        _expectFail(id, 0, _basicData(c), Core.CallFailed.selector);
        // the full sum goes through.
        _buy(id, total, _basicData(c), total);
    }

    function test_fail_extraConsiderationCannotBeFundedFromThePot() public {
        // the core only ever sends `value`. an order whose payouts exceed it cannot reach into the rest of the pot.
        uint256 id = _list();
        uint256 value = core.ceilingOf(id) / 4;
        OrderComponents memory c = _open(id, value, value);
        assertEq(_total(c), value * 2);
        // control: the same order fills when value covers every payout.
        uint256 snap = vm.snapshotState();
        _buy(id, value * 2, _basicData(c), value * 2);
        vm.revertToState(snap);
        _expectFail(id, value, _basicData(c), Core.CallFailed.selector);
        _expectFail(id, value, _orderData(c), Core.CallFailed.selector);
    }

    function test_fail_targetGuards() public {
        uint256 id = _list();
        uint256 price = core.ceilingOf(id) / 2;
        bytes memory data = _basicData(_open(id, price, 0));
        vm.prank(keeper);
        vm.expectRevert(Core.TargetNotAllowed.selector);
        core.buyListing(price, data, id, makeAddr("creditsengine.seaport.notatarget"));
        vm.prank(keeper);
        vm.expectRevert(Core.TargetNotAllowed.selector);
        core.buyListing(price, data, id, address(CREDITS));
    }

    /*//////////////////////////////////////////////////////////////
                         7. restricted orders
    //////////////////////////////////////////////////////////////*/

    function test_restricted_eoaZoneReverts() public {
        uint256 id = _list();
        uint256 price = core.ceilingOf(id) / 2;
        address zone = makeAddr("creditsengine.seaport.zone");
        assertEq(zone.code.length, 0);
        OrderComponents memory c = _components(id, price, 0, zone, OrderType.FULL_RESTRICTED);

        // a restricted order needs its zone to approve the fill, and the core is not the zone. the door only
        // forwards what the caller supplies, it adds nothing, so the whole buy reverts.
        _expectFail(id, price, _basicData(c), Core.CallFailed.selector);
        _expectFail(id, price, _orderData(c), Core.CallFailed.selector);
        _expectFail(id, price, _advancedData(c, hex"c0ffee", address(core)), Core.CallFailed.selector);

        // control: the order is otherwise genuine. when the zone is the caller itself seaport skips the zone
        // callbacks and the same fill goes through, so the revert above comes from the zone and nothing else.
        OrderComponents memory own = _components(id, price, 0, address(core), OrderType.FULL_RESTRICTED);
        _buy(id, price, _basicData(own), price);
    }

    function test_restricted_zoneNeedsTheCallersExtraData() public {
        uint256 id = _list();
        uint256 price = core.ceilingOf(id) / 2;
        ExtraDataZone zone = new ExtraDataZone();
        OrderComponents memory c = _components(id, price, 0, address(zone), OrderType.FULL_RESTRICTED);

        // no extra data, and the basic path has no way to carry any: the zone says no.
        _expectFail(id, price, _basicData(c), Core.CallFailed.selector);
        _expectFail(id, price, _advancedData(c, "", address(core)), Core.CallFailed.selector);
        _expectFail(id, price, _advancedData(c, hex"deadbeef", address(core)), Core.CallFailed.selector);

        // the door forwards whatever bytes the caller supplies, so the right extra data makes the same order fill.
        _buy(id, price, _advancedData(c, hex"c0ffee", address(core)), price);
    }

    /*//////////////////////////////////////////////////////////////
                         8. fuzz the listing price
    //////////////////////////////////////////////////////////////*/

    function testFuzz_priceFromOneWeiToCeiling(uint256 price) public {
        uint256 id = _list();
        uint256 ceiling = core.ceilingOf(id);
        assertLe(ceiling, core.ethPot() * 2000 / 10_000, "the hourly cap clears every ceiling here");
        price = bound(price, 1, ceiling);
        OrderComponents memory c = _open(id, price, 0);

        uint256 sellerBefore = seller.balance;
        uint256 tip = _buy(id, price, _basicData(c), price);

        (,, uint256 booked,) = core.creditInfo(id);
        assertEq(booked, price + tip);
        assertLe(booked, ceiling, "cost plus tip never exceeds the ceiling");
        assertLe(tip, price * 200 / 10_000, "tip at most 2% of cost");
        assertLe(tip, (ceiling - price) * 1000 / 10_000, "tip at most 10% of savings");
        assertEq(seller.balance - sellerBefore, price);
    }
}
