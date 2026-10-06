// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {Lane, Settings, Mainnet, IStatements, Stack} from "../src/interfaces/Interfaces.sol";
import {IAuctionHouse, IAuctionFactory} from "../src/interfaces/AuctionHouse.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {DeafBidder} from "./attackers/StatementBuyers.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";

/// @notice the flow rework (docs/FLOW.md) on the real stack: settings, the flat bid, statement sales on the live pnd
/// auction house, collection of proceeds, sync and reprice, the phase 2 exit by cancel, overprint, forbidden targets,
/// and the hard rule that the owner can never move assets out under any settings
contract FlowTest is Fixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant N = 26;

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

    /// @dev field i of the settings struct, in declaration order
    function _get(Settings memory s, uint256 i) internal pure returns (uint256) {
        uint256[26] memory f = [
            uint256(s.flatBps),
            s.avgScore,
            s.climbBaseBps,
            s.climbDoubleEvery,
            s.climbMaxBps,
            s.dropBps,
            s.spendCapBps,
            s.bonusCapBps,
            s.tipSavingsBps,
            s.tipCapBps,
            s.reimburseBps,
            s.reimburseCapBps,
            s.reserveBps,
            s.auctionDuration,
            s.exitAfter,
            s.saleToBuybackBps,
            s.exitToBuybackBps,
            s.buybackSlice,
            s.buybackDelay,
            s.keeperTipBps,
            s.xRateCap,
            s.xRateFloor,
            s.xRateClimbPerHour,
            s.xRateDropPerCredit,
            s.xAuctionHalfLife,
            s.exitSliceCredits
        ];
        return f[i];
    }

    /// @dev sets field i, narrowing the value (callers stay inside the width of the field)
    function _set(Settings memory s, uint256 i, uint256 v) internal pure {
        // forge-lint: disable-start(unsafe-typecast)
        if (i == 0) s.flatBps = uint16(v);
        else if (i == 1) s.avgScore = uint32(v);
        else if (i == 2) s.climbBaseBps = uint16(v);
        else if (i == 3) s.climbDoubleEvery = uint32(v);
        else if (i == 4) s.climbMaxBps = uint16(v);
        else if (i == 5) s.dropBps = uint16(v);
        else if (i == 6) s.spendCapBps = uint16(v);
        else if (i == 7) s.bonusCapBps = uint16(v);
        else if (i == 8) s.tipSavingsBps = uint16(v);
        else if (i == 9) s.tipCapBps = uint16(v);
        else if (i == 10) s.reimburseBps = uint16(v);
        else if (i == 11) s.reimburseCapBps = uint16(v);
        else if (i == 12) s.reserveBps = uint16(v);
        else if (i == 13) s.auctionDuration = uint32(v);
        else if (i == 14) s.exitAfter = uint32(v);
        else if (i == 15) s.saleToBuybackBps = uint16(v);
        else if (i == 16) s.exitToBuybackBps = uint16(v);
        else if (i == 17) s.buybackSlice = uint128(v);
        else if (i == 18) s.buybackDelay = uint16(v);
        else if (i == 19) s.keeperTipBps = uint16(v);
        else if (i == 20) s.xRateCap = uint16(v);
        else if (i == 21) s.xRateFloor = uint16(v);
        else if (i == 22) s.xRateClimbPerHour = uint16(v);
        else if (i == 23) s.xRateDropPerCredit = uint16(v);
        else if (i == 24) s.xAuctionHalfLife = uint32(v);
        else s.exitSliceCredits = uint16(v);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev the documented lower bound of every field. climbMaxBps is bounded below by climbBaseBps and xRateFloor and
    /// xRateCap by each other, those three are handled by the callers
    function _lo() internal pure returns (uint256[26] memory) {
        return [
            uint256(0),
            800_000,
            0,
            1 hours,
            0,
            0,
            100,
            0,
            0,
            0,
            0,
            0,
            1_000,
            1 hours,
            0,
            0,
            0,
            0.01 ether,
            1,
            0,
            0,
            0,
            0,
            0,
            10 minutes,
            1
        ];
    }

    function _hi() internal pure returns (uint256[26] memory) {
        return [
            uint256(10_000),
            8_000_000,
            1_000,
            30 days,
            2_000,
            5_000,
            10_000,
            5_000,
            2_500,
            500,
            15_000,
            1_000,
            40_000,
            30 days,
            365 days,
            10_000,
            10_000,
            100 ether,
            7_200,
            500,
            10_000,
            10_000,
            1_000,
            1_000,
            30 days,
            1_000
        ];
    }

    function _names() internal pure returns (bytes32[26] memory) {
        return [
            bytes32("flatBps"),
            "avgScore",
            "climbBaseBps",
            "climbDoubleEvery",
            "climbMaxBps",
            "dropBps",
            "spendCapBps",
            "bonusCapBps",
            "tipSavingsBps",
            "tipCapBps",
            "reimburseBps",
            "reimburseCapBps",
            "reserveBps",
            "auctionDuration",
            "exitAfter",
            "saleToBuybackBps",
            "exitToBuybackBps",
            "buybackSlice",
            "buybackDelay",
            "keeperTipBps",
            "xRateCap",
            "xRateFloor",
            "xRateClimbPerHour",
            "xRateDropPerCredit",
            "xAuctionHalfLife",
            "exitSliceCredits"
        ];
    }

    /// @dev a valid settings struct derived from a seed, inside every bound and the two orderings
    function _valid(uint256 seed) internal pure returns (Settings memory s) {
        uint256[26] memory lo = _lo();
        uint256[26] memory hi = _hi();
        for (uint256 i; i < N; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            uint256 a = lo[i];
            uint256 b = hi[i];
            if (i == 4) a = s.climbBaseBps;
            if (i == 21) b = s.xRateCap;
            _set(s, i, a + (b > a ? x % (b - a + 1) : 0));
        }
    }

    // ------------------------------------------------------------------ settings: values, bounds, access

    function test_settings_launchValues() public view {
        assertEq(_hash(core.settings()), _hash(Mainnet.defaultSettings()), "launch values");
        Settings memory s = core.settings();
        assertEq(s.flatBps, 10_000);
        assertEq(s.avgScore, 4_330_000);
        assertEq(s.climbBaseBps, 100);
        assertEq(s.climbDoubleEvery, 24 hours);
        assertEq(s.climbMaxBps, 800);
        assertEq(s.dropBps, 2_000);
        assertEq(s.spendCapBps, 2_000);
        assertEq(s.bonusCapBps, 2_500);
        assertEq(s.tipSavingsBps, 1_000);
        assertEq(s.tipCapBps, 200);
        assertEq(s.reimburseBps, 11_000);
        assertEq(s.reimburseCapBps, 500);
        assertEq(s.reserveBps, 9_000);
        assertEq(s.auctionDuration, 24 hours);
        assertEq(s.exitAfter, 72 hours);
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
    }

    /// @dev write then read of random valid settings: the packed layout the library unpacks matches the compiler's
    function testFuzz_settings_roundTrip(uint256 seed) public {
        Settings memory s = _valid(seed);
        vm.expectEmit(address(core));
        emit Core.SettingsSet(s);
        _owner(s);
        assertEq(_hash(core.settings()), _hash(s), "round trip");
    }

    function test_settings_everyBoundEdgeIsAccepted() public {
        uint256[26] memory lo = _lo();
        uint256[26] memory hi = _hi();
        for (uint256 i; i < N; ++i) {
            for (uint256 k; k < 2; ++k) {
                Settings memory s = Mainnet.defaultSettings();
                uint256 v = k == 0 ? lo[i] : hi[i];
                // the three fields bounded by another field
                if (i == 4 && k == 0) v = s.climbBaseBps;
                if (i == 2 && k == 1) s.climbMaxBps = 2_000;
                if (i == 20 && k == 0) s.xRateFloor = 0;
                if (i == 21 && k == 1) v = s.xRateCap;
                _set(s, i, v);
                _owner(s);
                assertEq(_get(core.settings(), i), v, "edge stored");
            }
        }
    }

    function test_settings_everyBoundViolationReverts() public {
        uint256[26] memory lo = _lo();
        uint256[26] memory hi = _hi();
        bytes32[26] memory names = _names();
        for (uint256 i; i < N; ++i) {
            Settings memory s = Mainnet.defaultSettings();
            // above the top
            _set(s, i, hi[i] + 1);
            // an xRateFloor above the cap names the floor
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(Core.BadSetting.selector, names[i]));
            core.setSettings(s);
            // below the bottom (fields whose bottom is zero have none)
            if (lo[i] == 0 && i != 4 && i != 21) continue;
            s = Mainnet.defaultSettings();
            if (i == 4) {
                _set(s, 4, s.climbBaseBps - 1);
            } else if (i == 21) {
                // the floor is bounded by the cap, so a cap below the floor is the violation, and it names the floor
                _set(s, 20, s.xRateFloor - 1);
                names[i] = "xRateFloor";
            } else {
                _set(s, i, lo[i] - 1);
            }
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(Core.BadSetting.selector, names[i]));
            core.setSettings(s);
        }
    }

    function test_settings_failedWriteChangesNothing() public {
        bytes32 before = _hash(core.settings());
        Settings memory s = Mainnet.defaultSettings();
        s.reserveBps = 999;
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
            vm.expectRevert(Core.OnlyOwner.selector);
            core.setSettings(s);
            vm.expectRevert(Core.OnlyOwner.selector);
            core.setRate(5e12);
            vm.expectRevert(Core.OnlyOwner.selector);
            core.setXRate(5_000);
            vm.stopPrank();
        }
    }

    function test_setRate_boundsEventAndReset() public {
        vm.startPrank(owner);
        vm.expectRevert(Core.BadRate.selector);
        core.setRate(1e11 - 1);
        vm.expectRevert(Core.BadRate.selector);
        core.setRate(1e15 + 1);
        vm.expectEmit(address(core));
        emit Core.RateSet(2e13);
        core.setRate(2e13);
        assertEq(core.ethRate(), 2e13);
        assertEq(core.rateAtCheckpoint(), 2e13);
        assertEq(core.checkpointTime(), block.timestamp);
        core.setRate(1e11);
        core.setRate(1e15);
        vm.stopPrank();
    }

    function test_setRate_resyncsFundedFlag() public {
        _potTo(1e16);
        assertTrue(core.funded(), "funded at the opening rate");
        vm.prank(owner);
        core.setRate(1e15);
        assertFalse(core.funded(), "a pot of five average credits at 4e12 cannot fund 1e15");
        vm.prank(owner);
        core.setRate(4e12);
        assertTrue(core.funded());
    }

    function test_setXRate_boundsAndEvent() public {
        vm.startPrank(owner);
        vm.expectRevert(Core.BadRate.selector);
        core.setXRate(2_999);
        vm.expectRevert(Core.BadRate.selector);
        core.setXRate(9_701);
        vm.expectEmit(address(core));
        emit Core.XRateSet(8_000);
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
        vm.expectRevert(Core.BadRate.selector);
        core.setXRate(4_001);
        core.setXRate(1_000);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ a settings change checkpoints

    /// @dev the eth rate after `hrs` whole hours of climb at `bps` per hour from `r`, the formula of the Core
    function _climbed(uint256 r, uint256 bps, uint256 hrs) internal pure returns (uint256) {
        return r.mulWad(uint256(FixedPointMathLib.powWad(int256(1e18 + bps * 1e14), int256(hrs * 1e18))));
    }

    function test_checkpoint_ethRateKeepsOldClimb() public {
        _potTo(0.2 ether);
        assertEq(core.ethRate(), 4e12);
        _warp(10 hours);
        uint256 old = _climbed(4e12, 100, 10);
        assertEq(core.ethRate(), old, "10 hours at 100 bps");
        Settings memory s = core.settings();
        s.climbBaseBps = 400;
        _owner(s);
        // nothing is credited at the new numbers for the 10 hours already gone
        assertEq(core.rateAtCheckpoint(), old, "stored at the old climb");
        assertEq(core.checkpointTime(), block.timestamp);
        assertEq(core.ethRate(), old);
        _warp(3 hours);
        assertEq(core.ethRate(), _climbed(old, 400, 3), "3 hours at 400 bps");
        // without the checkpoint the whole 13 hours would have been priced at the new climb
        assertTrue(core.ethRate() != _climbed(4e12, 400, 13));
    }

    function test_checkpoint_climbOffFreezesTheRate() public {
        _potTo(0.2 ether);
        _warp(10 hours);
        uint256 old = _climbed(4e12, 100, 10);
        Settings memory s = core.settings();
        s.climbBaseBps = 0;
        s.climbMaxBps = 0;
        _owner(s);
        _warp(500 hours);
        assertEq(core.ethRate(), old, "no climb, and none credited later");
    }

    function test_checkpoint_fundedFlagFollowsTheNewNumbers() public {
        _potTo(1e16);
        assertTrue(core.funded());
        _warp(5 hours);
        uint256 old = _climbed(4e12, 100, 5);
        Settings memory s = core.settings();
        s.avgScore = 8_000_000;
        _owner(s);
        // the pot of 1e16 cannot afford one 8M credit at 4e12 under a 20 percent cap: 2e19 is below 3.2e19
        assertFalse(core.funded(), "unfunded at the new average score");
        _warp(100 hours);
        assertEq(core.ethRate(), old, "unfunded, flat");
        s.avgScore = 4_330_000;
        _owner(s);
        assertTrue(core.funded());
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
        _timelock(Core.Action.SetController, abi.encode(address(sc)));
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
        _timelock(Core.Action.SetController, abi.encode(address(sc)));
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
        assertEq(uint256(l.status), uint256(Core.StatementStatus.Listed));
        assertEq(l.reserve, cost * 9_000 / 10_000, "ninety percent of cost");
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
        s.reserveBps = 15_000;
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
            if (logs[i].emitter == address(core) && logs[i].topics[0] == Core.StatementListed.selector) {
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
        assertEq(uint256(l.status), uint256(Core.StatementStatus.Held));
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
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Listed), "still no bid");
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
        assertEq(uint256(l.status), uint256(Core.StatementStatus.Bid));
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
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Sold), "the record is stale");
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
        emit Core.SalesCollected(price, toBuyback);
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
        emit Core.SalesCollected(owed, owed / 2);
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
        emit Core.Skimmed(0, 0);
        core.skim();
        assertEq(_booked(), booked, "the house balance is not the core balance");
        _collectSales();
        assertEq(_booked(), booked + price, "booked once by collectSales");
        vm.expectEmit(address(core));
        emit Core.Skimmed(0, 0);
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
        emit Core.Skimmed(1 ether, 0);
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
        emit Core.StatementSold(sid, aid, alice);
        vm.prank(bob);
        core.syncStatement(sid);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.None));
        (bool held,,,) = core.statementInfo(sid);
        assertFalse(held);
        assertEq(core.heldStatements().length, 0);
        vm.expectRevert(Core.NotListed.selector);
        core.syncStatement(sid);
    }

    function test_sync_refusesWhileTheAuctionExists() public {
        uint256 sid = _composeOnce().sid;
        vm.expectRevert(Core.AuctionLive.selector);
        core.syncStatement(sid);
        _bid(alice, sid, _live(sid).reserve);
        vm.expectRevert(Core.AuctionLive.selector);
        core.syncStatement(sid);
        vm.warp(_live(sid).endTime);
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Ended));
        vm.expectRevert(Core.AuctionLive.selector);
        core.syncStatement(sid);
        vm.expectRevert(Core.NotListed.selector);
        core.syncStatement(999_999);
    }

    function test_sync_aWinnerThatBurnedTheStatementStillSettles() public {
        (uint256 sid,) = _sellStatement(alice);
        vm.mockCallRevert(address(STATEMENTS), abi.encodeWithSelector(IStatements.ownerOf.selector, sid), "burned");
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Sold));
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
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Ended));
        assertEq(_owedByHouse(), 0, "a deferred sale pays nobody");
        vm.expectRevert(IAuctionHouse.AuctionAlreadySettled.selector);
        house.endAuction{gas: END_GAS}(aid);
        vm.expectRevert(Core.AuctionLive.selector);
        core.syncStatement(sid);
        vm.expectRevert(IAuctionHouse.UnwindTooEarly.selector);
        house.unwindStuckLot{gas: END_GAS}(aid);

        _warp(30 days + 1);
        house.unwindStuckLot{gas: END_GAS}(aid);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "returned to the core by the unwind");
        assertEq(house.pendingRefunds(alice), price, "the winner is refunded");
        assertEq(_owedByHouse(), 0, "no proceeds for the core");
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Returned));

        Settings memory s = core.settings();
        s.reserveBps = 12_000;
        _owner(s);
        (,, uint256 cost,) = core.statementInfo(sid);
        vm.expectEmit(address(core));
        emit Core.StatementListed(sid, aid + 1, cost * 12_000 / 10_000);
        vm.prank(bob);
        core.syncStatement(sid);
        Live memory l = _live(sid);
        assertEq(uint256(l.status), uint256(Core.StatementStatus.Listed));
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
        assertEq(uint256(_live(sid).status), uint256(Core.StatementStatus.Sold));
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
        s.reserveBps = 12_000;
        _owner(s);
        assertEq(_live(sid).reserve, old, "a settings change does not touch the listing by itself");
        vm.expectEmit(address(core));
        emit Core.StatementRepriced(sid, cost * 12_000 / 10_000);
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
        s.reserveBps = 2_000;
        _owner(s);
        core.repriceStatement(sid);
        assertEq(_live(sid).reserve, cost * 2_000 / 10_000, "and down again");
    }

    function test_reprice_refusedWithABidOrWithoutAListing() public {
        uint256 sid = _composeOnce().sid;
        _bid(alice, sid, _live(sid).reserve);
        vm.expectRevert(Core.HasBid.selector);
        core.repriceStatement(sid);
        vm.expectRevert(Core.NotListed.selector);
        core.repriceStatement(424_242);
        _endAuction(sid);
        vm.expectRevert(Core.NotListed.selector);
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
        vm.warp(listedAt + 72 hours - 1);
        vm.expectRevert(Core.TooEarly.selector);
        core.exitStatement(c.sid);
        vm.warp(listedAt + 72 hours);
        uint256 rating = STATEMENTS.creditScoreOf(c.sid);
        uint256 before = xt.balanceOf(address(core));
        uint256 pot = core.xPot();
        vm.expectEmit(address(core));
        emit Core.StatementExited(c.sid, Lane.Eth, rating * UNIT);
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
        _warp(72 hours);
        _bid(alice, sid, _live(sid).reserve);
        vm.expectRevert(Core.HasBid.selector);
        core.exitStatement(sid);
        vm.warp(_live(sid).endTime + 1 days);
        vm.expectRevert(Core.HasBid.selector);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(house), "nothing moved");
        _endAuction(sid);
        vm.expectRevert(Core.NotListed.selector);
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
        vm.expectRevert(Core.TooEarly.selector);
        core.exitStatement(sid);
        s.exitAfter = 0;
        _owner(s);
        core.exitStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }

    function test_exit_needsTheModule() public {
        uint256 sid = _composeOnce().sid;
        _warp(72 hours);
        vm.expectRevert(Core.NoExitModule.selector);
        core.exitStatement(sid);
    }

    function test_exit_staleRecordOfASoldStatementIsNotExited() public {
        _enterPhase2();
        (uint256 sid,) = _sellStatement(alice);
        _warp(72 hours);
        vm.expectRevert(Core.NotListed.selector);
        core.exitStatement(sid);
    }

    function test_exit_returnedStatementMustBeRelistedFirst() public {
        _enterPhase2();
        (uint256 sid, uint256 aid,) = _failedDelivery();
        _warp(30 days + 1);
        house.unwindStuckLot{gas: END_GAS}(aid);
        vm.expectRevert(Core.NotListed.selector);
        core.exitStatement(sid);
        core.syncStatement(sid);
        (,,, uint64 listedAt) = core.statementInfo(sid);
        vm.warp(listedAt + 72 hours);
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
        _timelock(Core.Action.SetController, abi.encode(address(ovc)));
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
        emit Core.Overprinted(a, b, costA + costB);
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
        assertEq(uint256(l.status), uint256(Core.StatementStatus.Listed));
        assertTrue(l.auctionId != aidA && l.auctionId != aidB, "a new auction");
        assertEq(l.reserve, (costA + costB) * 9_000 / 10_000, "reserve on the summed cost");
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
        vm.expectRevert(Core.HasBid.selector);
        core.overprint();
        vm.revertToState(snap);
        _bid(alice, a, _live(a).reserve);
        vm.expectRevert(Core.HasBid.selector);
        core.overprint();
        assertEq(STATEMENTS.ownerOf(b), address(house), "atomic: the other listing is untouched");
    }

    function test_overprint_refusedWhenOneWasSoldAndNotSynced() public {
        (uint256 a, uint256 b) = _twoStatements();
        _bid(alice, b, _live(b).reserve);
        _endAuction(b);
        vm.expectRevert(Core.NotListed.selector);
        core.overprint();
        assertEq(STATEMENTS.ownerOf(a), address(house));
    }

    // ------------------------------------------------------------------ forbidden targets and the constructor

    function test_forbidden_theHouseAndItsFactoryCannotBeTargets() public {
        address[2] memory t = [address(house), Mainnet.AUCTION_FACTORY];
        for (uint256 i; i < 2; ++i) {
            bytes memory data = abi.encode(t[i]);
            vm.startPrank(owner);
            core.queue(Core.Action.AddTarget, data);
            vm.warp(block.timestamp + 7 days);
            vm.expectRevert(Core.ForbiddenTarget.selector);
            core.execute(Core.Action.AddTarget, data);
            vm.stopPrank();
            vm.expectRevert(Core.TargetNotAllowed.selector);
            core.buyListing(0, "", 1, t[i]);
            assertFalse(core.allowedTarget(t[i]));
        }
    }

    function _newCore(Settings memory s, address factory) internal returns (Core) {
        return new Core(owner, address(coin), address(ctl), _stack(factory), 4e12, s);
    }

    function _stack(address factory) internal view returns (Stack memory st) {
        st = lc.stack;
        st.auctionFactory = factory;
    }

    function test_constructor_createsItsOwnHouse() public {
        Core c2 = _newCore(Mainnet.defaultSettings(), Mainnet.AUCTION_FACTORY);
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
        vm.expectRevert(abi.encodeWithSelector(Core.BadSetting.selector, bytes32("avgScore")));
        this.newCoreExternal(s, Mainnet.AUCTION_FACTORY);
        vm.expectRevert(Core.ZeroAddress.selector);
        this.newCoreExternal(Mainnet.defaultSettings(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Core.NoCode.selector, address(0xBEEF)));
        this.newCoreExternal(Mainnet.defaultSettings(), address(0xBEEF));
    }

    function newCoreExternal(Settings memory s, address factory) external returns (Core) {
        return _newCore(s, factory);
    }

    // ------------------------------------------------------------------ the rate never reverts, however long the gap

    function _longGap(uint256 base, uint256 maxBps, uint256 dbl, uint256 gap) internal {
        Settings memory s = core.settings();
        s.climbBaseBps = uint16(base);
        s.climbMaxBps = uint16(maxBps);
        s.climbDoubleEvery = uint32(dbl);
        _owner(s);
        _potTo(1 ether);
        _warp(gap);
        uint256 g = gasleft();
        uint256 r = core.ethRate();
        assertLt(g - gasleft(), 400_000, "bounded work");
        assertLe(r, uint256(1 ether) * 2_000 / 4_330_000, "clamped at the hourly cap");
        vm.deal(core.HOOK(), 1 ether);
        uint256 pot = core.ethPot();
        vm.prank(core.HOOK());
        (bool ok,) = address(core).call{value: 1e15}("");
        assertTrue(ok, "receive does not revert");
        assertEq(core.ethPot(), pot + 1e15, "booked");
    }

    function test_rate_hourlyDoublingOverTwentyYears() public {
        _longGap(1, 2_000, 1 hours, 20 * 365 days);
    }

    function test_rate_slowestClimbOverACentury() public {
        _longGap(1, 1, 30 days, 100 * 365 days);
    }

    function test_rate_fastestClimbOverACentury() public {
        _longGap(1_000, 2_000, 1 hours, 100 * 365 days);
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
    /// (paid to the seller, exactly the quoted ceiling) or by the buyback (at most one slice)
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_rule8_noSettingsOrOwnerCallMovesAssetsOut(uint256 seed) public {
        if (seed % 2 == 1) _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _potTo(1 ether);
        ScriptedController hostile = new ScriptedController();
        _timelock(Core.Action.SetController, abi.encode(address(hostile)));
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
                if (l.status == Core.StatementStatus.Listed) _bid(alice, sid, l.reserve);
                else if (l.status == Core.StatementStatus.Bid) _bid(bob, sid, l.bid * 105 / 100);
            } else if (kind == 7) {
                _warp(1 hours + (r >> 8) % 3 days);
            } else if (kind == 8) {
                if (_live(sid).status == Core.StatementStatus.Ended) _endAuction(sid);
            } else if (kind == 9) {
                _sellMaybe(ids[(r >> 8) % 6]);
            } else {
                vm.prank(owner);
                try core.exitStatement(sid) {} catch {}
            }
            for (uint256 i; i < 3; ++i) {
                _noGain(watched[i], base[i], "owner or controller gained");
            }
            _solvent();
        }
    }

    function _ownerCall(uint256 kind, uint256 r) internal {
        vm.startPrank(owner);
        if (kind == 0) {
            core.setSettings(_valid(r));
        } else if (kind == 1) {
            core.setRate(bound(r >> 8, 1e11, 1e15));
        } else if (kind == 2) {
            Settings memory s = core.settings();
            core.setXRate(bound(r >> 8, s.xRateFloor, s.xRateCap));
        } else if (kind == 3) {
            address t = address(uint160(r >> 8));
            try core.queue(Core.Action.AddTarget, abi.encode(t)) {} catch {}
            try core.cancel(Core.Action.AddTarget, abi.encode(t)) {} catch {}
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
        if (pick == 0) try core.skim() {} catch {} else if (pick == 1) try core.collectSales() {}
            catch {} else if (pick == 2) try core.syncStatement(sid) {} catch {} else if (pick == 3) try core.repriceStatement(
            sid
        ) {}
            catch {} else if (pick == 4) try core.buyback() {} catch {} else try core.overprint() {} catch {}
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
