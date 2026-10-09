// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane, Settings, Mainnet, IStatements, Stack} from "../src/interfaces/Interfaces.sol";
import {IAuctionHouse, IAuctionFactory} from "../src/interfaces/AuctionHouse.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {DeafBidder} from "./attackers/StatementBuyers.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {SettingsFields} from "../script/SettingsFields.sol";

/// @notice the flow rework (docs/FLOW.md) on the real stack: settings, the flat bid, statement sales on the live pnd
/// auction house, collection of proceeds, sync and reprice, the phase 2 exit by cancel, overprint, forbidden targets,
/// and the hard rule that the owner can never move assets out under any settings
contract FlowTest is Fixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant N = 31;

    // ------------------------------------------------------------------ helpers

    /// @dev books `eth` into the buying pot through the real `skim` door (a donation of eth to the core)
    function _potTo(uint256 eth) internal {
        uint256 have = core.ethPot();
        if (have >= eth) return;
        vm.deal(address(core), address(core).balance + (eth - have));
        core.skim();
    }

    function _owner(Settings memory s) internal {
        vm.prank(owner);
        core.setSettings(s);
    }

    function _hash(Settings memory s) internal pure returns (bytes32) {
        return keccak256(abi.encode(s));
    }

    /// @dev the field tables are the ones of the scripts (`SettingsFields`), 31 fields in declaration order
    function _get(Settings memory s, uint256 i) internal pure returns (uint256) {
        return SettingsFields.get(s, i);
    }

    function _set(Settings memory s, uint256 i, uint256 v) internal pure {
        SettingsFields.set(s, i, v);
    }

    function _lo() internal pure returns (uint256[31] memory) {
        return SettingsFields.lo();
    }

    function _hi() internal pure returns (uint256[31] memory) {
        return SettingsFields.hi();
    }

    function _names() internal pure returns (bytes32[31] memory) {
        return SettingsFields.names();
    }

    /// @dev a valid settings struct derived from a seed, inside every bound and the two orderings
    function _valid(uint256 seed) internal pure returns (Settings memory s) {
        uint256[31] memory lo = _lo();
        uint256[31] memory hi = _hi();
        for (uint256 i; i < N; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            uint256 a = lo[i];
            uint256 b = hi[i];
            if (i == 23) b = s.xRateCap;
            _set(s, i, a + (b > a ? x % (b - a + 1) : 0));
        }
    }

    // ------------------------------------------------------------------ settings: values, bounds, access

    function test_settings_launchValues() public view {
        assertEq(_hash(core.settings()), _hash(Mainnet.defaultSettings()), "launch values");
        Settings memory s = core.settings();
        assertEq(s.flatBps, 10_000);
        assertEq(s.avgScore, 4_330_000);
        assertEq(s.dropPerCreditBps, 50);
        assertEq(s.dropFloorBps, 8_000);
        assertEq(s.climbPerMinBps, 50);
        assertEq(s.ceilBps, 12_500);
        assertEq(s.idleLoosenBps, 200);
        assertEq(s.clampCredits, 20);
        assertEq(s.spendCapBps, 2_000);
        assertEq(s.bonusCapBps, 2_500);
        assertEq(s.tipSavingsBps, 1_000);
        assertEq(s.tipCapBps, 200);
        assertEq(s.reimburseBps, 8_000);
        assertEq(s.reimburseCapBps, 500);
        assertEq(s.saleFloorBps, 7_500);
        assertEq(s.auctionDuration, 24 hours);
        assertEq(s.exitAfter, 105 hours);
        assertEq(s.saleToBuybackBps, 5_000);
        assertEq(s.exitToBuybackBps, 5_000);
        assertEq(s.buybackSlice, 1 ether);
        assertEq(s.buybackDelay, 25);
        assertEq(s.keeperTipBps, 50);
        assertEq(s.xRateCap, 9_700);
        assertEq(s.xRateFloor, 3_000);
        assertEq(s.xRateClimbPerHour, 100);
        assertEq(s.xRateDropPerCredit, 20);
        assertEq(s.xAuctionHalfLife, 6 hours);
        assertEq(s.exitSliceCredits, 20);
        assertEq(s.rateCap, 123_200_000_000_000);
        assertEq(s.exitLaneToBuybackBps, 0);
        assertEq(s.feeToBuybackBps, 0);
    }

    /// @dev write then read of random valid settings: the packed layout the library unpacks matches the compiler's
    function testFuzz_settings_roundTrip(uint256 seed) public {
        Settings memory s = _valid(seed);
        vm.expectEmit(address(core));
        emit ICore.SettingsSet(s);
        _owner(s);
        assertEq(_hash(core.settings()), _hash(s), "round trip");
    }

    function test_settings_everyBoundEdgeIsAccepted() public {
        uint256[31] memory lo = _lo();
        uint256[31] memory hi = _hi();
        for (uint256 i; i < N; ++i) {
            for (uint256 k; k < 2; ++k) {
                Settings memory s = Mainnet.defaultSettings();
                uint256 v = k == 0 ? lo[i] : hi[i];
                // the two fields bounded by another field
                if (i == 22 && k == 0) s.xRateFloor = 0;
                if (i == 23 && k == 1) v = s.xRateCap;
                _set(s, i, v);
                _owner(s);
                assertEq(_get(core.settings(), i), v, "edge stored");
            }
        }
    }

    function test_settings_everyBoundViolationReverts() public {
        uint256[31] memory lo = _lo();
        uint256[31] memory hi = _hi();
        bytes32[31] memory names = _names();
        for (uint256 i; i < N; ++i) {
            Settings memory s = Mainnet.defaultSettings();
            // above the top
            _set(s, i, hi[i] + 1);
            // an xRateFloor above the cap names the floor
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, names[i]));
            core.setSettings(s);
            // below the bottom (fields whose bottom is zero have none)
            if (lo[i] == 0 && i != 23) continue;
            s = Mainnet.defaultSettings();
            if (i == 23) {
                // the floor is bounded by the cap, so a cap below the floor is the violation, and it names the floor
                _set(s, 22, s.xRateFloor - 1);
                names[i] = "xRateFloor";
            } else {
                _set(s, i, lo[i] - 1);
            }
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, names[i]));
            core.setSettings(s);
        }
    }

    function test_settings_failedWriteChangesNothing() public {
        bytes32 before = _hash(core.settings());
        Settings memory s = Mainnet.defaultSettings();
        s.saleFloorBps = 999;
        vm.prank(owner);
        vm.expectRevert();
        core.setSettings(s);
        assertEq(_hash(core.settings()), before);
    }

    function test_setters_onlyOwner() public {
        address[4] memory nobody = [address(this), address(ctl), deployer, creator];
        Settings memory s = Mainnet.defaultSettings();
        for (uint256 i; i < nobody.length; ++i) {
            vm.startPrank(nobody[i]);
            vm.expectRevert(ICore.OnlyOwner.selector);
            core.setSettings(s);
            vm.expectRevert(ICore.OnlyOwner.selector);
            core.setRate(5e12);
            vm.expectRevert(ICore.OnlyOwner.selector);
            core.setXRate(5_000);
            vm.stopPrank();
        }
    }

    function test_setRate_boundsEventAndReset() public {
        uint256 cap = core.settings().rateCap;
        vm.startPrank(owner);
        vm.expectRevert(ICore.BadRate.selector);
        core.setRate(1e11 - 1);
        vm.expectRevert(ICore.BadRate.selector);
        core.setRate(cap + 1);
        vm.expectEmit(address(core));
        emit ICore.RateSet(2e13);
        core.setRate(2e13);
        assertEq(core.rateAtCheckpoint(), 2e13);
        assertEq(core.checkpointTime(), block.timestamp);
        core.setRate(1e11);
        core.setRate(cap);
        vm.stopPrank();
        // the top of the rate bounds needs the rate cap raised to it, and nothing passes the bounds
        Settings memory s = core.settings();
        s.rateCap = 1e15;
        _owner(s);
        vm.startPrank(owner);
        vm.expectRevert(ICore.BadRate.selector);
        core.setRate(1e15 + 1);
        core.setRate(1e15);
        vm.stopPrank();
    }

    function test_setRate_readStaysAtTheClampOfThePot() public {
        _potTo(1e16);
        uint256 clamp = uint256(1e16) * 2000 / (4_330_000 * 20);
        Settings memory cs = core.settings();
        cs.rateCap = 1e15;
        _owner(cs);
        vm.prank(owner);
        core.setRate(1e15);
        assertEq(core.rateAtCheckpoint(), 1e15);
        assertEq(core.ethRate(), clamp, "a pot of 1e16 reads its clamp under a stored rate of 1e15");
        vm.prank(owner);
        core.setRate(4e12);
        assertEq(core.rateAtCheckpoint(), 4e12);
        assertEq(core.ethRate(), clamp, "and under the opening rate");
    }

    function test_setXRate_boundsAndEvent() public {
        vm.startPrank(owner);
        vm.expectRevert(ICore.BadRate.selector);
        core.setXRate(2_999);
        vm.expectRevert(ICore.BadRate.selector);
        core.setXRate(9_701);
        vm.expectEmit(address(core));
        emit ICore.XRateSet(8_000);
        core.setXRate(8_000);
        assertEq(core.xRate(), 8_000);
        core.setXRate(3_000);
        core.setXRate(9_700);
        vm.stopPrank();
    }

    function test_setXRate_followsTheSettingsBand() public {
        Settings memory s = Mainnet.defaultSettings();
        s.xRateFloor = 1_000;
        s.xRateCap = 4_000;
        _owner(s);
        vm.startPrank(owner);
        vm.expectRevert(ICore.BadRate.selector);
        core.setXRate(4_001);
        core.setXRate(1_000);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ a settings change checkpoints

    /// @dev the eth rate after `mins` minutes of climb at `bps` per minute from `r`, the formula of the Core
    function _climbed(uint256 r, uint256 bps, uint256 mins) internal pure returns (uint256) {
        return r.mulWad(uint256(FixedPointMathLib.powWad(int256(1e18 + bps * 1e14), int256(mins * 1e18))));
    }

    function test_checkpoint_ethRateKeepsOldClimb() public {
        _potTo(20 ether);
        assertEq(core.ethRate(), 4e12);
        _warp(10 minutes);
        uint256 old = _climbed(4e12, 50, 10);
        assertEq(core.ethRate(), old, "10 minutes at 50 bps");
        Settings memory s = core.settings();
        s.climbPerMinBps = 200;
        _owner(s);
        // nothing is credited at the new numbers for the 10 minutes already gone
        assertEq(core.rateAtCheckpoint(), old, "stored at the old climb");
        assertEq(core.checkpointTime(), block.timestamp);
        assertEq(core.ethRate(), old);
        _warp(3 minutes);
        assertEq(core.ethRate(), _climbed(old, 200, 3), "3 minutes at 200 bps");
        // without the checkpoint the whole 13 minutes would have been priced at the new climb
        assertTrue(core.ethRate() != _climbed(4e12, 200, 13));
    }

    function test_checkpoint_slowestClimbCreditsOnlyAfterTheChange() public {
        _potTo(20 ether);
        _warp(10 minutes);
        uint256 old = _climbed(4e12, 50, 10);
        Settings memory s = core.settings();
        s.climbPerMinBps = 1;
        _owner(s);
        assertEq(core.rateAtCheckpoint(), old, "stored at the old climb");
        _warp(60 minutes);
        assertEq(core.ethRate(), _climbed(old, 1, 60), "an hour at 1 bps, the lowest climb");
    }

    function test_checkpoint_clampFollowsTheNewNumbers() public {
        _potTo(1e16);
        _warp(5 hours);
        // 20 credits of room at 1e16 is below the opening rate: the read is the clamp
        uint256 held = uint256(1e16) * 2000 / (4_330_000 * 20);
        assertEq(core.ethRate(), held, "bounded by the clamp");
        Settings memory s = core.settings();
        s.avgScore = 6_000_000;
        s.spendCapBps = 100;
        _owner(s);
        _warp(100 hours);
        assertEq(core.ethRate(), uint256(1e16) * 100 / (6_000_000 * 20), "the clamp of the new numbers");
        assertEq(core.rateAtCheckpoint(), 4e12, "the price state the change stored");
        s.avgScore = 4_330_000;
        s.spendCapBps = 2_000;
        _owner(s);
        assertEq(core.ethRate(), held, "and back on the old numbers");
    }

    function test_checkpoint_exitRateKeepsOldClimb() public {
        _enterPhase2();
        xt.mint(address(core), 1e18);
        core.skim();
        assertEq(core.xRate(), 6_000);
        _warp(5 hours);
        assertEq(core.xRate(), 6_500);
        Settings memory s = core.settings();
        s.xRateClimbPerHour = 300;
        _owner(s);
        assertEq(core.xRate(), 6_500, "stored at the old climb");
        _warp(2 hours);
        assertEq(core.xRate(), 7_100, "2 hours at 300 bps");
    }

    function test_checkpoint_exitRateIsHeldInsideTheNewBand() public {
        Settings memory s = core.settings();
        s.xRateCap = 5_000;
        _owner(s);
        assertEq(core.xRate(), 5_000, "cap below the rate");
        s = core.settings();
        s.xRateCap = 9_700;
        s.xRateFloor = 5_500;
        _owner(s);
        assertEq(core.xRate(), 5_500, "floor above the rate");
    }

    function test_checkpoint_exitAuctionKeepsItsPriceWhenTheHalfLifeChanges() public {
        _enterPhase2();
        xt.mint(address(core), 0);
        uint256 got = _fillExitBuyback();
        assertGt(got, 0);
        _warp(9 hours);
        uint256 price = core.exitAuctionPrice();
        Settings memory s = core.settings();
        s.xAuctionHalfLife = 1 hours;
        _owner(s);
        assertEq(core.exitAuctionPrice(), price, "same price at the moment of the change");
        _warp(1 hours);
        assertApproxEqAbs(core.exitAuctionPrice(), price / 2, price / 1e6, "now halves every hour");
    }

    // ------------------------------------------------------------------ the flat bid

    function _flat(uint256 bps) internal {
        Settings memory s = core.settings();
        s.flatBps = uint16(bps);
        _owner(s);
    }

    /// @dev the Core price of a credit by the brief: rate * (flat * avg + (10000 - flat) * score) / 10000 / 1e4 then
    /// the bonus, as one division
    function _price(uint256 id, uint256 rate, uint256 flat, uint256 bonus) internal view returns (uint256) {
        uint256 blend = flat * 4_330_000 + (10_000 - flat) * core.scoreOf(id);
        return blend * rate * (10_000 + bonus) / (10_000 * 10_000 * 1e4);
    }

    function _sellOne(uint256 id) internal returns (uint256 paid) {
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(id));
        paid = seller.balance - before;
    }

    function test_flat_10000_everyCreditPaysTheAverage() public {
        _potTo(1 ether);
        uint256[] memory ids = _credits(seller, 3);
        _flat(10_000);
        assertEq(core.ceilingOf(ids[0]), 1_732_000_000_000_000, "avg score 4.33M at 4e12");
        assertEq(core.ceilingOf(ids[1]), core.ceilingOf(ids[0]));
        assertEq(core.ceilingOf(ids[2]), core.ceilingOf(ids[0]));
        assertTrue(core.scoreOf(ids[0]) != core.scoreOf(ids[1]) || core.scoreOf(ids[1]) != core.scoreOf(ids[2]));
        // the score contract is not read at all on the eth doors
        vm.expectCall(Mainnet.CREDIT_SCORE, abi.encodeWithSelector(bytes4(keccak256("scoreOf(bytes21,uint64)"))), 0);
        uint256 expect = core.ceilingOf(ids[0]);
        assertEq(_sellOne(ids[0]), expect, "paid the ceiling");
    }

    function test_flat_0_isPerScorePoint() public {
        _potTo(1 ether);
        uint256[] memory ids = _credits(seller, 3);
        _flat(0);
        for (uint256 i; i < 3; ++i) {
            assertEq(core.ceilingOf(ids[i]), core.scoreOf(ids[i]) * 4e12 / 1e4, "score times rate");
            assertEq(core.ceilingOf(ids[i]), _price(ids[i], 4e12, 0, 0));
        }
        uint256 expect = core.ceilingOf(ids[1]);
        assertEq(_sellOne(ids[1]), expect);
    }

    function test_flat_5000_isHalfAndHalf() public {
        _potTo(1 ether);
        uint256[] memory ids = _credits(seller, 3);
        _flat(5_000);
        for (uint256 i; i < 3; ++i) {
            uint256 sc = core.scoreOf(ids[i]);
            assertEq(core.ceilingOf(ids[i]), (5_000 * 4_330_000 + 5_000 * sc) * 4e12 / 1e8, "half flat, half score");
            assertEq(core.ceilingOf(ids[i]), _price(ids[i], 4e12, 5_000, 0));
        }
        uint256 expect = core.ceilingOf(ids[2]);
        assertEq(_sellOne(ids[2]), expect);
    }

    function testFuzz_flat_anyShareMatchesTheFormula(uint256 flat, uint256 seed) public {
        flat = bound(flat, 0, 10_000);
        _potTo(1 ether);
        uint256[] memory ids = _credits(seller, 2);
        _flat(flat);
        uint256 id = ids[seed % 2];
        assertEq(core.ceilingOf(id), _price(id, 4e12, flat, 0));
        uint256 expect = core.ceilingOf(id);
        assertEq(_sellOne(id), expect);
    }

    function test_flat_controllerBonusStillApplies() public {
        _potTo(1 ether);
        ScriptedController sc = new ScriptedController();
        _setController(address(sc));
        vm.prank(owner);
        core.setRate(4e12);
        uint256[] memory ids = _credits(seller, 3);
        sc.setWants(ids[0], 1_000);
        sc.setWants(ids[1], 6_000);
        uint256[3] memory flats = [uint256(10_000), 5_000, 0];
        for (uint256 k; k < 3; ++k) {
            _flat(flats[k]);
            assertEq(core.ceilingOf(ids[0]), _price(ids[0], 4e12, flats[k], 1_000), "ten percent bonus");
            assertEq(core.ceilingOf(ids[1]), _price(ids[1], 4e12, flats[k], 2_500), "capped at the setting");
            assertEq(core.ceilingOf(ids[2]), _price(ids[2], 4e12, flats[k], 0), "no bonus");
        }
        _flat(10_000);
        assertEq(core.ceilingOf(ids[0]), 4_330_000 * 4e12 * 11_000 / (1e4 * 1e4), "1.9052e15");
        uint256 expect = core.ceilingOf(ids[0]);
        assertEq(_sellOne(ids[0]), expect, "the bonus is paid");
    }

    function test_flat_bonusCapIsASetting() public {
        _potTo(1 ether);
        ScriptedController sc = new ScriptedController();
        _setController(address(sc));
        vm.prank(owner);
        core.setRate(4e12);
        uint256[] memory ids = _credits(seller, 1);
        sc.setWants(ids[0], 3_000);
        assertEq(core.ceilingOf(ids[0]), _price(ids[0], 4e12, 10_000, 2_500));
        Settings memory s = core.settings();
        s.bonusCapBps = 5_000;
        _owner(s);
        assertEq(core.ceilingOf(ids[0]), _price(ids[0], 4e12, 10_000, 3_000), "cap raised, full bonus");
        s.bonusCapBps = 0;
        _owner(s);
        assertEq(core.ceilingOf(ids[0]), _price(ids[0], 4e12, 10_000, 0), "cap zero, no bonus");
    }

    // ------------------------------------------------------------------ compose lists on the real house

    function test_house_isOursFromTheConstructor() public view {
        IAuctionFactory f = IAuctionFactory(Mainnet.AUCTION_FACTORY);
        assertEq(f.houseOf(address(core)), address(house));
        assertEq(address(core.HOUSE()), address(house));
        assertEq(core.AUCTION_FACTORY(), Mainnet.AUCTION_FACTORY);
        assertEq(house.owner(), address(core), "the core owns its house");
        assertEq(house.protocolFeeBps(), 0, "no fee");
        assertTrue(STATEMENTS.isApprovedForAll(address(core), address(house)), "approved for all statements");
    }

    function test_compose_listsAtNinetyPercentWithTheConfiguredDuration() public {
        Composed memory c = _composeOnce();
        (bool held, Lane lane, uint256 cost, uint64 listedAt) = core.statementInfo(c.sid);
        assertTrue(held);
        assertEq(uint256(lane), uint256(Lane.Eth));
        assertEq(cost, c.cost + c.reimb, "cost basis is the credits plus the reimbursement");
        assertEq(listedAt, c.at);
        Live memory l = _live(c.sid);
        assertEq(uint256(l.status), uint256(ICore.StatementStatus.Listed));
        assertEq(l.reserve, cost * 11_000 / 10_000, "110 percent of cost");
        IAuctionHouse.Auction memory a = _auctionOf(c.sid);
        assertEq(a.tokenId, c.sid);
        assertEq(a.tokenContract, address(STATEMENTS));
        assertEq(a.tokenOwner, address(core));
        assertEq(a.fundsRecipient, address(core));
        assertEq(a.reservePrice, l.reserve);
        assertEq(a.duration, 24 hours);
        assertEq(a.firstBidTime, 0);
        assertEq(a.amount, 0);
        assertEq(a.bidder, address(0));
        assertEq(STATEMENTS.ownerOf(c.sid), address(house), "the house holds the statement");
        (bool exists, uint256 id) = house.getAuctionFor(address(STATEMENTS), c.sid);
        assertTrue(exists);
        assertEq(id, l.auctionId);
        assertEq(core.heldStatements().length, 1);
    }

    function test_compose_readsTheSettingsAtListing() public {
        Settings memory s = core.settings();
        s.saleFloorBps = 15_000;
        s.auctionDuration = 3 days;
        _owner(s);
        Composed memory c = _composeOnce();
        (,, uint256 cost,) = core.statementInfo(c.sid);
        Live memory l = _live(c.sid);
        assertEq(l.reserve, cost * 15_000 / 10_000);
        assertEq(_auctionOf(c.sid).duration, 3 days);
    }

    function test_compose_emitsListedAndComposed() public {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.recordLogs();
        vm.prank(keeper);
        core.compose();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 sid = STATEMENTS.supply();
        bool listed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == ICore.StatementListed.selector) {
                listed = true;
                assertEq(uint256(logs[i].topics[1]), sid);
                assertEq(uint256(logs[i].topics[2]), _live(sid).auctionId);
                assertEq(abi.decode(logs[i].data, (uint256)), _live(sid).reserve);
            }
        }
        assertTrue(listed, "StatementListed");
    }

    function test_compose_exitLaneIsNeverListed() public {
        _enterPhase2();
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        core.composeExit();
        uint256 sid = STATEMENTS.supply();
        Live memory l = _live(sid);
        assertEq(uint256(l.status), uint256(ICore.StatementStatus.Held));
        assertEq(l.auctionId, 0);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "held by the core, not on the house");
    }

    // ------------------------------------------------------------------ bidding on the house

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function test_bid_belowReserveFails() public {
        uint256 sid = _composeOnce().sid;
        uint256 id = _live(sid).auctionId;
        uint256 reserve = _live(sid).reserve;
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        vm.expectRevert(IAuctionHouse.BidBelowReserve.selector);
        house.createBid{value: reserve - 1}(id);
        vm.expectRevert(IAuctionHouse.BidMustBePositive.selector);
        house.createBid(id);
        vm.stopPrank();
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Listed), "still no bid");
    }

    function test_bid_reserveStartsTheTimer() public {
        uint256 sid = _composeOnce().sid;
        uint256 reserve = _live(sid).reserve;
        _bid(alice, sid, reserve);
        IAuctionHouse.Auction memory a = _auctionOf(sid);
        assertEq(a.firstBidTime, block.timestamp);
        assertEq(a.endTime, block.timestamp + 24 hours);
        assertEq(a.amount, reserve);
        assertEq(a.bidder, alice);
        Live memory l = _live(sid);
        assertEq(uint256(l.status), uint256(ICore.StatementStatus.Bid));
        assertEq(l.bid, reserve);
        assertEq(l.endTime, block.timestamp + 24 hours);
    }

    function test_bid_fivePercentRuleAndRefund() public {
        uint256 sid = _composeOnce().sid;
        uint256 first = _live(sid).reserve;
        _bid(alice, sid, first);
        uint256 id = _live(sid).auctionId;
        uint256 minNext = first + first * 500 / 10_000;
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(IAuctionHouse.BidBelowMinimum.selector);
        house.createBid{value: minNext - 1}(id);
        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        house.createBid{value: minNext}(id);
        assertEq(alice.balance - aliceBefore, first, "the outbid bidder is refunded in the same call");
        assertEq(_auctionOf(sid).bidder, bob);
        assertEq(_auctionOf(sid).amount, minNext);
    }

    function test_bid_aBidderThatCannotReceiveIsCredited() public {
        uint256 sid = _composeOnce().sid;
        uint256 first = _live(sid).reserve;
        DeafBidder deaf = new DeafBidder();
        vm.deal(address(deaf), first);
        deaf.bid{value: first}(house, _live(sid).auctionId);
        _bid(bob, sid, first * 106 / 100);
        assertEq(house.pendingRefunds(address(deaf)), first, "credited on the house, never lost");
        uint256 before = alice.balance;
        deaf.pull(house, payable(alice));
        assertEq(house.pendingRefunds(address(deaf)), 0);
        assertEq(alice.balance - before, first, "pulled");
    }

    function test_bid_lateBidExtendsByFifteenMinutes() public {
        uint256 sid = _composeOnce().sid;
        uint256 first = _live(sid).reserve;
        _bid(alice, sid, first);
        uint64 end = _live(sid).endTime;
        // a bid an hour before the end does not extend
        vm.warp(end - 1 hours);
        _bid(bob, sid, first * 106 / 100);
        assertEq(_live(sid).endTime, end, "not extended");
        // a bid ten minutes before the end moves it to fifteen minutes from now
        vm.warp(end - 10 minutes);
        _bid(alice, sid, _live(sid).bid * 106 / 100);
        assertEq(_live(sid).endTime, block.timestamp + 15 minutes, "extended");
        assertEq(_live(sid).endTime, end + 5 minutes);
    }

    function test_end_strangerSettlesAndTheWinnerGetsTheStatement() public {
        uint256 sid = _composeOnce().sid;
        uint256 price = _live(sid).reserve;
        _bid(alice, sid, price);
        uint256 id = _live(sid).auctionId;
        vm.warp(_live(sid).endTime - 1);
        vm.expectRevert(IAuctionHouse.AuctionNotEnded.selector);
        house.endAuction(id);
        uint256 balance = address(core).balance;
        uint256 pot = core.ethPot();
        uint256 buyback = core.ethToBuyback();
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), alice, "delivered to the winner");
        assertEq(_owedByHouse(), price, "the proceeds are credited to the core on the house");
        assertEq(address(core).balance, balance, "nothing arrived at the core yet");
        assertEq(core.ethPot(), pot, "pot unchanged until collected");
        assertEq(core.ethToBuyback(), buyback);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Sold), "the record is stale");
        assertEq(core.heldStatements().length, 1, "still listed as held until synced");
        assertEq(_auctionOf(sid).tokenOwner, address(0), "the house forgot the auction");
    }

    // ------------------------------------------------------------------ collecting the proceeds

    function _collectSplit(uint256 bps) internal {
        Settings memory s = core.settings();
        s.saleToBuybackBps = uint16(bps);
        _owner(s);
        (uint256 sid, uint256 price) = _sellStatement(alice);
        assertEq(STATEMENTS.ownerOf(sid), alice);
        uint256 balance = address(core).balance;
        uint256 pot = core.ethPot();
        uint256 buyback = core.ethToBuyback();
        uint256 toBuyback = price * bps / 10_000;
        vm.expectEmit(address(core));
        emit ICore.SalesCollected(price, toBuyback);
        assertEq(_collectSales(), price);
        assertEq(address(core).balance, balance + price, "the eth moved from the house to the core");
        assertEq(core.ethToBuyback(), buyback + toBuyback, "buyback share");
        assertEq(core.ethPot(), pot + price - toBuyback, "pot share");
        assertEq(_owedByHouse(), 0);
        _solvent();
    }

    function test_collect_splitHalf() public {
        _collectSplit(5_000);
    }

    function test_collect_splitAllToThePot() public {
        _collectSplit(0);
    }

    function test_collect_splitAllToTheBuyback() public {
        _collectSplit(10_000);
    }

    function test_collect_splitOddShareRoundsDownToTheBuyback() public {
        _collectSplit(3_333);
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_collect_anySplitIsExact(uint256 bps) public {
        _collectSplit(bound(bps, 0, 10_000));
    }

    function test_collect_usesTheSplitOfTheCollectionTime() public {
        (, uint256 price) = _sellStatement(alice);
        Settings memory s = core.settings();
        s.saleToBuybackBps = 2_000;
        _owner(s);
        uint256 buyback = core.ethToBuyback();
        _collectSales();
        assertEq(core.ethToBuyback() - buyback, price * 2_000 / 10_000);
    }

    function test_collect_nothingOwedIsANoOp() public {
        uint256 pot = core.ethPot();
        vm.recordLogs();
        vm.prank(alice);
        core.collectSales();
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        assertEq(core.ethPot(), pot);
    }

    function test_collect_onlyOnce() public {
        (, uint256 price) = _sellStatement(alice);
        _collectSales();
        uint256 pot = core.ethPot();
        uint256 buyback = core.ethToBuyback();
        vm.prank(bob);
        core.collectSales();
        assertEq(core.ethPot(), pot);
        assertEq(core.ethToBuyback(), buyback);
        assertGt(price, 0);
    }

    function test_buyback_collectsTheSalesFirst() public {
        _sellStatement(alice);
        uint256 owed = _owedByHouse();
        assertGt(owed, 0);
        assertEq(core.ethToBuyback(), 0, "nothing booked yet, so nothing to buy without the collection");
        uint256 supply = coin.totalSupply();
        _warp(1);
        vm.expectEmit(address(core));
        emit ICore.SalesCollected(owed, owed / 2);
        vm.prank(keeper);
        core.buyback();
        assertEq(_owedByHouse(), 0, "collected by the buyback");
        assertLt(coin.totalSupply(), supply, "coin was bought and burned");
        assertGt(keeper.balance, 0, "the keeper tip");
        _solvent();
    }

    function test_buyback_stillRunsWhenNothingIsOwed() public {
        _sellStatement(alice);
        _collectSales();
        _warp(1);
        vm.prank(keeper);
        core.buyback();
        assertLt(core.ethToBuyback(), 0.07 ether);
    }

    // ------------------------------------------------------------------ skim never double books sale proceeds

    function _booked() internal view returns (uint256) {
        return core.ethPot() + core.ethToBuyback();
    }

    function test_skim_seesNothingWhileTheProceedsSitInTheHouse() public {
        (, uint256 price) = _sellStatement(alice);
        uint256 booked = _booked();
        vm.expectEmit(address(core));
        emit ICore.Skimmed(0, 0);
        core.skim();
        assertEq(_booked(), booked, "the house balance is not the core balance");
        _collectSales();
        assertEq(_booked(), booked + price, "booked once by collectSales");
        vm.expectEmit(address(core));
        emit ICore.Skimmed(0, 0);
        core.skim();
        assertEq(_booked(), booked + price, "and not again by skim");
        _solvent();
    }

    function test_skim_afterCollectionEvenWithADonationBooksOnlyTheDonation() public {
        (, uint256 price) = _sellStatement(alice);
        uint256 booked = _booked();
        // an unrelated donation sits unbooked in the core
        vm.deal(address(this), 3 ether);
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok);
        _collectSales();
        assertEq(_booked(), booked + price, "collection books the proceeds only, not the donation");
        assertEq(address(core).balance - _booked(), 1 ether, "the donation is still unbooked");
        vm.expectEmit(address(core));
        emit ICore.Skimmed(1 ether, 0);
        core.skim();
        assertEq(_booked(), booked + price + 1 ether);
        core.skim();
        assertEq(_booked(), booked + price + 1 ether, "nothing left to book");
        _solvent();
    }

    function test_skim_beforeAndAfterTheSaleInEveryOrder() public {
        uint256 sid = _composeOnce().sid;
        uint256 price = _live(sid).reserve;
        _bid(alice, sid, price);
        core.skim();
        _endAuction(sid);
        core.skim();
        uint256 booked = _booked();
        core.collectSales();
        core.skim();
        core.collectSales();
        core.skim();
        assertEq(_booked(), booked + price);
        assertEq(address(core).balance - _booked(), address(core).balance - booked - price);
        _solvent();
    }

    // ------------------------------------------------------------------ syncStatement

    function test_sync_soldClearsTheRecord() public {
        (uint256 sid,) = _sellStatement(alice);
        uint256 aid = _live(sid).auctionId;
        vm.expectEmit(address(core));
        emit ICore.StatementSold(sid, aid, alice);
        vm.prank(bob);
        core.syncStatement(sid);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.None));
        (bool held,,,) = core.statementInfo(sid);
        assertFalse(held);
        assertEq(core.heldStatements().length, 0);
        vm.expectRevert(ICore.NotListed.selector);
        core.syncStatement(sid);
    }

    function test_sync_refusesWhileTheAuctionExists() public {
        uint256 sid = _composeOnce().sid;
        vm.expectRevert(ICore.AuctionLive.selector);
        core.syncStatement(sid);
        _bid(alice, sid, _live(sid).reserve);
        vm.expectRevert(ICore.AuctionLive.selector);
        core.syncStatement(sid);
        vm.warp(_live(sid).endTime);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Ended));
        vm.expectRevert(ICore.AuctionLive.selector);
        core.syncStatement(sid);
        vm.expectRevert(ICore.NotListed.selector);
        core.syncStatement(999_999);
    }

    function test_sync_aWinnerThatBurnedTheStatementStillSettles() public {
        (uint256 sid,) = _sellStatement(alice);
        vm.mockCallRevert(address(STATEMENTS), abi.encodeWithSelector(IStatements.ownerOf.selector, sid), "burned");
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Sold));
        core.syncStatement(sid);
        assertEq(core.heldStatements().length, 0);
    }

    /// @dev a sale whose delivery to the winner fails on the house. the real Statements never refuses a transfer, so the
    /// refusal is simulated by a mocked revert of exactly this transfer
    function _failedDelivery() internal returns (uint256 sid, uint256 aid, uint256 price) {
        sid = _composeOnce().sid;
        Live memory l = _live(sid);
        price = l.reserve;
        aid = l.auctionId;
        _bid(alice, sid, price);
        vm.mockCallRevert(
            address(STATEMENTS),
            abi.encodeWithSelector(IStatements.transferFrom.selector, address(house), alice, sid),
            "cannot receive"
        );
        _endAuction(sid);
        assertTrue(house.pendingDelivery(aid), "deferred");
    }

    function test_sync_unwoundSaleRelistsAtTheCurrentReserve() public {
        (uint256 sid, uint256 aid, uint256 price) = _failedDelivery();
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Ended));
        assertEq(_owedByHouse(), 0, "a deferred sale pays nobody");
        vm.expectRevert(IAuctionHouse.AuctionAlreadySettled.selector);
        house.endAuction{gas: END_GAS}(aid);
        vm.expectRevert(ICore.AuctionLive.selector);
        core.syncStatement(sid);
        vm.expectRevert(IAuctionHouse.UnwindTooEarly.selector);
        house.unwindStuckLot{gas: END_GAS}(aid);

        _warp(30 days + 1);
        house.unwindStuckLot{gas: END_GAS}(aid);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "returned to the core by the unwind");
        assertEq(house.pendingRefunds(alice), price, "the winner is refunded");
        assertEq(_owedByHouse(), 0, "no proceeds for the core");
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Returned));

        Settings memory s = core.settings();
        s.saleFloorBps = 12_000;
        _owner(s);
        (,, uint256 cost,) = core.statementInfo(sid);
        vm.expectEmit(address(core));
        emit ICore.StatementListed(sid, aid + 1, cost * 12_000 / 10_000);
        vm.prank(bob);
        core.syncStatement(sid);
        Live memory l = _live(sid);
        assertEq(uint256(l.status), uint256(ICore.StatementStatus.Listed));
        assertEq(l.auctionId, aid + 1, "a new auction");
        assertEq(l.reserve, cost * 12_000 / 10_000, "at the current reserve");
        (,,, uint64 listedAt) = core.statementInfo(sid);
        assertEq(listedAt, block.timestamp, "the listing clock restarted");
        assertEq(STATEMENTS.ownerOf(sid), address(house));

        uint256 before = alice.balance;
        vm.prank(alice);
        house.withdrawRefund();
        assertEq(alice.balance - before, price);
        // nothing of this sale was booked as proceeds
        uint256 booked = _booked();
        core.collectSales();
        assertEq(_booked(), booked);
    }

    function test_sync_deferredThenClaimedIsASale() public {
        (uint256 sid, uint256 aid, uint256 price) = _failedDelivery();
        vm.clearMockedCalls();
        house.claimLot(aid, address(0));
        assertEq(STATEMENTS.ownerOf(sid), alice);
        assertEq(_owedByHouse(), price);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Sold));
        core.syncStatement(sid);
        _collectSales();
        _solvent();
    }

    // ------------------------------------------------------------------ repriceStatement

    function test_reprice_appliesANewReserveToAnOldListing() public {
        uint256 sid = _composeOnce().sid;
        (,, uint256 cost,) = core.statementInfo(sid);
        uint256 old = _live(sid).reserve;
        Settings memory s = core.settings();
        s.saleFloorBps = 12_000;
        _owner(s);
        assertEq(_live(sid).reserve, old, "a settings change does not touch the listing by itself");
        vm.expectEmit(address(core));
        emit ICore.StatementRepriced(sid, cost * 12_000 / 10_000);
        vm.prank(bob);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 12_000 / 10_000);
        assertEq(_auctionOf(sid).reservePrice, cost * 12_000 / 10_000);
        // the new reserve binds the bidders
        uint256 id = _live(sid).auctionId;
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(IAuctionHouse.BidBelowReserve.selector);
        house.createBid{value: old}(id);
        s.saleFloorBps = 3_000;
        _owner(s);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 11_000 / 10_000, "a lower floor leaves the controller ask in force");
    }

    function test_reprice_refusedWithABidOrWithoutAListing() public {
        uint256 sid = _composeOnce().sid;
        _bid(alice, sid, _live(sid).reserve);
        vm.expectRevert(ICore.HasBid.selector);
        core.repriceStatement(sid);
        vm.expectRevert(ICore.NotListed.selector);
        core.repriceStatement(424_242);
        _endAuction(sid);
        vm.expectRevert(ICore.NotListed.selector);
        core.repriceStatement(sid);
    }

    // ------------------------------------------------------------------ phase 2 exit: cancel then exit

    function _exitSplit(uint256 bps) internal {
        Settings memory s = core.settings();
        s.exitToBuybackBps = uint16(bps);
        _owner(s);
        _enterPhase2();
        Composed memory c = _composeOnce();
        (,,, uint64 listedAt) = core.statementInfo(c.sid);
        uint256 aid = _live(c.sid).auctionId;
        vm.warp(listedAt + 105 hours - 1);
        vm.expectRevert(ICore.TooEarly.selector);
        core.exitStatement(c.sid);
        vm.warp(listedAt + 105 hours);
        uint256 rating = STATEMENTS.creditScoreOf(c.sid);
        uint256 before = xt.balanceOf(address(core));
        uint256 pot = core.xPot();
        vm.expectEmit(address(core));
        emit ICore.StatementExited(c.sid, Lane.Eth, rating * UNIT);
        vm.prank(bob);
        core.exitStatement(c.sid);
        uint256 got = xt.balanceOf(address(core)) - before;
        assertEq(got, rating * UNIT, "the module paid rating times the unit");
        assertEq(core.xToBuyback(), got * bps / 10_000, "buyback share of the exit token");
        assertEq(core.xPot() - pot, got - got * bps / 10_000, "bid share of the exit token");
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "in the module");
        assertEq(house.getAuction(aid).tokenOwner, address(0), "the listing was cancelled");
        assertEq(core.heldStatements().length, 0);
        _solvent();
    }

    function test_exit_afterExitAfterCancelsThenExitsSplitHalf() public {
        _exitSplit(5_000);
    }

    function test_exit_splitAllToTheBid() public {
        _exitSplit(0);
    }

    function test_exit_splitAllToTheBuyback() public {
        _exitSplit(10_000);
    }

    function test_exit_splitOddShare() public {
        _exitSplit(3_333);
    }

    function test_exit_refusedWhileABidIsLive() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _warp(105 hours);
        _bid(alice, sid, _live(sid).reserve);
        vm.expectRevert(ICore.HasBid.selector);
        core.exitStatement(sid);
        vm.warp(_live(sid).endTime + 1 days);
        vm.expectRevert(ICore.HasBid.selector);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(house), "nothing moved");
        _endAuction(sid);
        vm.expectRevert(ICore.NotListed.selector);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), alice, "a sold statement cannot be exited");
    }

    function test_exit_exitAfterIsASetting() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        Settings memory s = core.settings();
        s.exitAfter = 365 days;
        _owner(s);
        vm.warp(block.timestamp + 100 days);
        vm.expectRevert(ICore.TooEarly.selector);
        core.exitStatement(sid);
        s.exitAfter = 1 hours;
        _owner(s);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    function test_exit_needsTheModule() public {
        uint256 sid = _composeOnce().sid;
        _warp(105 hours);
        vm.expectRevert(ICore.NoExitModule.selector);
        core.exitStatement(sid);
    }

    function test_exit_staleRecordOfASoldStatementIsNotExited() public {
        _enterPhase2();
        (uint256 sid,) = _sellStatement(alice);
        _warp(105 hours);
        vm.expectRevert(ICore.NotListed.selector);
        core.exitStatement(sid);
    }

    function test_exit_returnedStatementMustBeRelistedFirst() public {
        _enterPhase2();
        (uint256 sid, uint256 aid,) = _failedDelivery();
        _warp(30 days + 1);
        house.unwindStuckLot{gas: END_GAS}(aid);
        vm.expectRevert(ICore.NotListed.selector);
        core.exitStatement(sid);
        core.syncStatement(sid);
        (,,, uint64 listedAt) = core.statementInfo(sid);
        vm.warp(listedAt + 105 hours);
        vm.clearMockedCalls();
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    function test_exit_exitLaneIsUnchanged() public {
        _enterPhase2();
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        core.composeExit();
        uint256 sid = STATEMENTS.supply();
        uint256 rating = STATEMENTS.creditScoreOf(sid);
        uint256 before = xt.balanceOf(address(core));
        uint256 buyback = core.xToBuyback();
        // at once, never listed, no cancel
        vm.recordLogs();
        core.exitStatement(sid);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(house), "the house is not involved");
        }
        assertEq(xt.balanceOf(address(core)) - before, rating * UNIT);
        assertEq(core.xToBuyback(), buyback, "an exit lane exit adds nothing to the buyback");
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    // ------------------------------------------------------------------ overprint

    ScriptedController internal ovc;

    function _composeFresh() internal returns (uint256) {
        uint256 size = core.pileSize(Lane.Eth);
        if (size < 80) _fillEthPile(80 - size);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        return STATEMENTS.supply();
    }

    /// @dev two listed statements and a scripted controller that asks for their overprint
    function _twoStatements() internal returns (uint256 a, uint256 b) {
        a = _composeFresh();
        b = _composeFresh();
        ovc = new ScriptedController();
        _setController(address(ovc));
        ovc.setOverprint(true, a, b);
    }

    function test_overprint_cancelsBothListingsAndRelistsTheBase() public {
        (uint256 a, uint256 b) = _twoStatements();
        (,, uint256 costA,) = core.statementInfo(a);
        (,, uint256 costB,) = core.statementInfo(b);
        uint256 aidA = _live(a).auctionId;
        uint256 aidB = _live(b).auctionId;
        uint256 sum = STATEMENTS.creditScoreOf(a) + STATEMENTS.creditScoreOf(b);
        vm.expectEmit(address(core));
        emit ICore.Overprinted(a, b, costA + costB);
        core.overprint();
        assertEq(house.getAuction(aidA).tokenOwner, address(0), "the base listing was cancelled");
        assertEq(house.getAuction(aidB).tokenOwner, address(0), "the top listing was cancelled");
        vm.expectRevert();
        STATEMENTS.ownerOf(b);
        assertEq(STATEMENTS.creditScoreOf(a), sum, "the rating is the sum");
        (bool held,, uint256 cost, uint64 listedAt) = core.statementInfo(a);
        assertTrue(held);
        assertEq(cost, costA + costB, "costs add");
        assertEq(listedAt, block.timestamp);
        Live memory l = _live(a);
        assertEq(uint256(l.status), uint256(ICore.StatementStatus.Listed));
        assertTrue(l.auctionId != aidA && l.auctionId != aidB, "a new auction");
        assertEq(l.reserve, (costA + costB) * 11_000 / 10_000, "reserve on the summed cost");
        assertEq(_auctionOf(a).duration, 24 hours);
        assertEq(STATEMENTS.ownerOf(a), address(house));
        assertEq(core.heldStatements().length, 1);
        (bool heldTop,,,) = core.statementInfo(b);
        assertFalse(heldTop);
    }

    function test_overprint_refusedWhenEitherListingHasABid() public {
        (uint256 a, uint256 b) = _twoStatements();
        uint256 snap = vm.snapshotState();
        _bid(alice, b, _live(b).reserve);
        vm.expectRevert(ICore.HasBid.selector);
        core.overprint();
        vm.revertToState(snap);
        _bid(alice, a, _live(a).reserve);
        vm.expectRevert(ICore.HasBid.selector);
        core.overprint();
        assertEq(STATEMENTS.ownerOf(b), address(house), "atomic: the other listing is untouched");
    }

    function test_overprint_refusedWhenOneWasSoldAndNotSynced() public {
        (uint256 a, uint256 b) = _twoStatements();
        _bid(alice, b, _live(b).reserve);
        _endAuction(b);
        vm.expectRevert(ICore.NotListed.selector);
        core.overprint();
        assertEq(STATEMENTS.ownerOf(a), address(house));
    }

    // ------------------------------------------------------------------ forbidden targets and the constructor

    function test_forbidden_theHouseAndItsFactoryCannotBeTargets() public {
        address[2] memory t = [address(house), Mainnet.AUCTION_FACTORY];
        for (uint256 i; i < 2; ++i) {
            vm.prank(owner);
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addTarget(t[i]);
            vm.expectRevert(ICore.TargetNotAllowed.selector);
            core.buyListing(0, "", 1, t[i]);
            assertFalse(core.allowedTarget(t[i]));
        }
    }

    function _newCore(Settings memory s, address factory) internal returns (ICore) {
        return Prod.newCore(owner, address(coin), address(ctl), _stack(factory), 4e12, s);
    }

    function _stack(address factory) internal view returns (Stack memory st) {
        st = lc.stack;
        st.auctionFactory = factory;
    }

    function test_constructor_createsItsOwnHouse() public {
        ICore c2 = _newCore(Mainnet.defaultSettings(), Mainnet.AUCTION_FACTORY);
        address h2 = IAuctionFactory(Mainnet.AUCTION_FACTORY).houseOf(address(c2));
        assertTrue(h2 != address(0) && h2 != address(house));
        assertEq(address(c2.HOUSE()), h2);
        assertEq(IAuctionHouse(h2).owner(), address(c2));
        assertTrue(STATEMENTS.isApprovedForAll(address(c2), h2));
        assertEq(_hash(c2.settings()), _hash(Mainnet.defaultSettings()));
    }

    function test_constructor_refusesBadInputs() public {
        Settings memory s = Mainnet.defaultSettings();
        s.avgScore = 799_999;
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("avgScore")));
        this.newCoreExternal(s, Mainnet.AUCTION_FACTORY);
        // the opening rate (4e12) may not sit above the rate cap
        Settings memory capped = Mainnet.defaultSettings();
        capped.rateCap = 3.9e12;
        vm.expectRevert(ICore.BadRate.selector);
        this.newCoreExternal(capped, Mainnet.AUCTION_FACTORY);
        vm.expectRevert(ICore.ZeroAddress.selector);
        this.newCoreExternal(Mainnet.defaultSettings(), address(0));
        vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, address(0xBEEF)));
        this.newCoreExternal(Mainnet.defaultSettings(), address(0xBEEF));
    }

    function newCoreExternal(Settings memory s, address factory) external returns (ICore) {
        return _newCore(s, factory);
    }

    // ------------------------------------------------------------------ the rate never reverts, however long the gap

    function _longGap(uint256 climbPerMin, uint256 ceilBps, uint256 loosen, uint256 gap) internal {
        Settings memory s = core.settings();
        s.climbPerMinBps = uint16(climbPerMin);
        s.ceilBps = uint16(ceilBps);
        s.idleLoosenBps = uint16(loosen);
        _owner(s);
        _potTo(1 ether);
        _warp(gap);
        uint256 g = gasleft();
        uint256 r = core.ethRate();
        assertLt(g - gasleft(), 400_000, "bounded work");
        assertLe(r, uint256(1 ether) * 2_000 / (4_330_000 * 20), "clamped at the hourly room of 20 credits");
        vm.deal(core.FEE_SOURCE(), 1 ether);
        uint256 pot = core.ethPot();
        vm.prank(core.FEE_SOURCE());
        (bool ok,) = address(core).call{value: 1e15}("");
        assertTrue(ok, "receive does not revert");
        assertEq(core.ethPot(), pot + 1e15, "booked");
    }

    function test_rate_fastestLoosenAndClimbOverTwentyYears() public {
        _longGap(1_000, 30_000, 2_000, 20 * 365 days);
    }

    function test_rate_slowestClimbOverACentury() public {
        _longGap(1, 10_000, 0, 100 * 365 days);
    }

    function test_rate_fastestClimbOverACentury() public {
        _longGap(1_000, 30_000, 2_000, 100 * 365 days);
    }

    // ------------------------------------------------------------------ hard rule 8

    /// @dev what an account holds of everything the core could hand out
    function _holdings(address who) internal view returns (uint256[5] memory h) {
        h[0] = who.balance;
        h[1] = coin.balanceOf(who);
        h[2] = CREDITS.balanceOf(who);
        h[3] = STATEMENTS.balanceOf(who);
        h[4] = address(xt) == address(0) ? 0 : xt.balanceOf(who);
    }

    function _noGain(address who, uint256[5] memory base, string memory what) internal view {
        uint256[5] memory now_ = _holdings(who);
        for (uint256 i; i < 5; ++i) {
            assertLe(now_[i], base[i], what);
        }
    }

    /// @dev a random sequence of owner calls under random valid settings, mixed with public doors, bids and time. the
    /// owner and the controller never end up holding more eth, coin, credits, statements or exit token than they
    /// began with, an owner call never changes what the core holds, and eth leaves the core only by a sale of a credit
    /// (paid to the seller, exactly the quoted ceiling) or by the buyback (at most one slice). the exit is a paid door
    /// (it repays its caller's gas from the pot like compose), so it is called by a neutral keeper that is not watched,
    /// and what that keeper receives is at most the reimbursement cap
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_rule8_noSettingsOrOwnerCallMovesAssetsOut(uint256 seed) public {
        if (seed % 2 == 1) _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _potTo(1 ether);
        ScriptedController hostile = new ScriptedController();
        _setController(address(hostile));
        uint256[] memory ids = _credits(seller, 6);
        for (uint256 i; i < 6; ++i) {
            hostile.setWants(ids[i], uint16(uint256(keccak256(abi.encode(seed, i)))));
        }
        address[3] memory watched = [owner, address(hostile), address(ctl)];
        uint256[5][3] memory base;
        for (uint256 i; i < 3; ++i) {
            base[i] = _holdings(watched[i]);
        }
        uint256 next;
        for (uint256 step; step < 12; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, "step", step)));
            uint256 coreEth = address(core).balance;
            uint256 kind = r % 11;
            if (kind <= 4) {
                _ownerCall(kind, r);
                assertEq(address(core).balance, coreEth, "an owner call never moves the core's eth");
            } else if (kind == 5) {
                next = _publicDoor(sid, r, next);
            } else if (kind == 6) {
                Live memory l = _live(sid);
                if (l.status == ICore.StatementStatus.Listed) _bid(alice, sid, l.reserve);
                else if (l.status == ICore.StatementStatus.Bid) _bid(bob, sid, l.bid * 105 / 100);
            } else if (kind == 7) {
                _warp(1 hours + (r >> 8) % 3 days);
            } else if (kind == 8) {
                if (_live(sid).status == ICore.StatementStatus.Ended) _endAuction(sid);
            } else if (kind == 9) {
                _sellMaybe(ids[(r >> 8) % 6]);
            } else {
                _exitAsKeeper(sid);
            }
            for (uint256 i; i < 3; ++i) {
                _noGain(watched[i], base[i], "owner or controller gained");
            }
            _solvent();
        }
    }

    /// @dev a neutral keeper exits the statement. the paid door pays it at most `reimburseCapBps` of the statement cost
    function _exitAsKeeper(uint256 sid) internal {
        address exitKeeper = makeAddr("exitKeeper");
        (,, uint256 cost,) = core.statementInfo(sid);
        uint256 cap = cost * core.settings().reimburseCapBps / 10_000;
        uint256 before = exitKeeper.balance;
        vm.prank(exitKeeper);
        try core.exitStatement(sid) {} catch {}
        assertLe(exitKeeper.balance - before, cap, "the exit reimbursement stays within the cap");
    }

    /// @dev the owner who calls the paid exit door is paid like any keeper: exactly the pot debit, within the cap
    function test_rule8_ownerAsRedeemCallerGetsOnlyTheCappedReimbursement() public {
        _enterPhase2();
        Composed memory c = _composeOnce();
        _potTo(1 ether);
        (,,, uint64 listedAt) = core.statementInfo(c.sid);
        vm.warp(listedAt + 105 hours);
        (,, uint256 cost,) = core.statementInfo(c.sid);
        uint256 cap = cost * core.settings().reimburseCapBps / 10_000;
        uint256 pot = core.ethPot();
        uint256 coreEth = address(core).balance;
        uint256[5] memory base = _holdings(owner);
        vm.fee(composeBasefee);
        vm.prank(owner);
        core.exitStatement(c.sid);
        uint256 gain = owner.balance - base[0];
        assertGt(gain, 0, "the paid door repays its caller");
        assertEq(gain, pot - core.ethPot(), "exactly the pot debit");
        assertEq(gain, coreEth - address(core).balance, "exactly what left the core");
        assertLe(gain, cap, "within the cap");
        assertEq(coin.balanceOf(owner), base[1]);
        assertEq(CREDITS.balanceOf(owner), base[2]);
        assertEq(STATEMENTS.balanceOf(owner), base[3]);
        assertEq(xt.balanceOf(owner), base[4]);
    }

    function _ownerCall(uint256 kind, uint256 r) internal {
        vm.startPrank(owner);
        if (kind == 0) {
            core.setSettings(_valid(r));
        } else if (kind == 1) {
            core.setRate(bound(r >> 8, 1e11, core.settings().rateCap));
        } else if (kind == 2) {
            Settings memory s = core.settings();
            core.setXRate(bound(r >> 8, s.xRateFloor, s.xRateCap));
        } else if (kind == 3) {
            address t = address(uint160(r >> 8));
            try core.addTarget(t) {} catch {}
            core.removeTarget(t);
        } else {
            core.removeTarget(Mainnet.SEAPORT);
        }
        vm.stopPrank();
    }

    /// @dev permissionless doors called by the owner or a stranger. the buyback may spend at most one slice. an owner
    /// who acts as a keeper earns the same capped tips as anyone, which is why the owner does not call the paid doors here
    function _publicDoor(uint256 sid, uint256 r, uint256) internal returns (uint256) {
        uint256 pick = (r >> 8) % 6;
        // the buyback pays its caller a capped keeper tip, like compose, so the owner is not the keeper in this run
        address who = pick != 4 && r % 2 == 0 ? owner : bob;
        uint256 before = address(core).balance;
        uint256 slice =
            core.ethToBuyback() < core.settings().buybackSlice ? core.ethToBuyback() : core.settings().buybackSlice;
        vm.startPrank(who);
        if (pick == 0) {
            try core.skim() {} catch {}
        } else if (pick == 1) {
            try core.collectSales() {} catch {}
        } else if (pick == 2) {
            try core.syncStatement(sid) {} catch {}
        } else if (pick == 3) {
            try core.repriceStatement(sid) {} catch {}
        } else if (pick == 4) {
            try core.buyback() {} catch {}
        } else {
            try core.overprint() {} catch {}
        }
        vm.stopPrank();
        if (address(core).balance < before) {
            assertEq(pick, 4, "only the buyback spends eth here");
            assertLe(before - address(core).balance, slice, "at most one slice");
        }
        return 0;
    }

    /// @dev the seller sells a credit. whatever the settings, the core pays the quoted ceiling and nothing else
    function _sellMaybe(uint256 id) internal {
        if (CREDITS.ownerOf(id) != seller) return;
        uint256 quote = core.ceilingOf(id);
        uint256 coreBefore = address(core).balance;
        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        try core.sellForEth(_one(id)) {
            assertEq(sellerBefore + quote, seller.balance, "paid the quote");
            assertEq(coreBefore - quote, address(core).balance, "the core paid exactly that");
        } catch {}
    }
}
