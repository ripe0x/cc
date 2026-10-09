// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, Mainnet, ICreditStrategy} from "../src/interfaces/Interfaces.sol";

/// @notice the credit bid rule on the real stack: the drop per credit with its minute floor, the compounded climb per
/// minute, the ceiling at a share of the last rate paid with its idle loosening, the funded clamp over 20 credits of
/// hourly room, the settings bounds, and the recovery after a gap in the market price. exact numbers at the launch
/// settings, hand arithmetic throughout
contract BidRuleTest is Fixture {
    uint256 internal constant START = 4e12;

    /// @dev books `eth` into the buying pot through the real `skim` door
    function _potTo(uint256 eth) internal {
        uint256 have = core.ethPot();
        if (have >= eth) return;
        vm.deal(address(core), address(core).balance + (eth - have));
        core.skim();
    }

    function _with(function(Settings memory) pure f) internal {
        Settings memory s = core.settings();
        f(s);
        _setSettings(s);
    }

    function _sellOne() internal returns (uint256 price) {
        uint256 id = _credits(seller, 1)[0];
        price = core.ceilingOf(id);
        vm.prank(seller);
        core.sellForEth(_one(id));
    }

    // ------------------------------------------------------------------ drop

    function test_oneFillDropsHalfAPercent() public {
        _potTo(10 ether);
        uint256 r0 = core.ethRate();
        assertEq(r0, START);
        uint256 price = _sellOne();
        assertEq(price, 4_330_000 * r0 / 1e4, "the flat price at the rate before the fill");
        assertEq(core.rateAtCheckpoint(), r0 * 9_950 / 10_000, "0.5 percent below the rate paid");
        (uint256 anchor, uint256 start, uint256 bucket) = _anchor();
        assertEq(anchor, r0, "the rate paid is the anchor");
        assertEq(start, r0, "and the start of the minute");
        assertEq(bucket, block.timestamp / 60);
        assertEq(core.lastFillTime(), block.timestamp);
    }

    /// 30 fills in one minute at 1 percent each stop at the 80 percent floor of the first rate paid
    function test_thirtyFillsInOneMinuteStopAtTheFloor() public {
        _with(_onePercentDrop);
        _potTo(20 ether);
        uint256 r0 = core.ethRate();
        uint256[] memory ids = _credits(seller, 30);
        uint256 floorRate = r0 * 8_000 / 10_000;
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
            uint256 r = core.rateAtCheckpoint();
            assertGe(r, floorRate, "never below the minute floor");
            // 0.99^i of the first rate until the floor
            if (i < 22) assertEq(r, _walk(r0, i + 1, 100));
        }
        assertEq(core.rateAtCheckpoint(), floorRate, "sits on the floor");
        (, uint256 start,) = _anchor();
        assertEq(start, r0);
    }

    /// at the launch drop of 0.5 percent the floor is reached after 45 fills in one minute
    function test_launchDropReachesTheFloorAfterFortyFiveFills() public {
        _potTo(40 ether);
        uint256 r0 = core.ethRate();
        uint256[] memory ids = _credits(seller, 50);
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
            if (i == 43) assertGt(core.rateAtCheckpoint(), r0 * 8_000 / 10_000, "44 fills are above the floor");
        }
        assertEq(core.rateAtCheckpoint(), r0 * 8_000 / 10_000, "50 fills sit on the floor");
    }

    /// a new minute starts the floor from the first rate paid in it
    function test_nextMinuteStartsANewFloor() public {
        _with(_onePercentDrop);
        _potTo(20 ether);
        uint256[] memory ids = _credits(seller, 40);
        for (uint256 i; i < 30; ++i) {
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
        }
        uint256 first = core.rateAtCheckpoint();
        _warp(60);
        uint256 paid = core.ethRate();
        assertGt(paid, first, "the rate climbed during the minute");
        vm.prank(seller);
        core.sellForEth(_one(ids[30]));
        (uint256 anchor, uint256 start, uint256 bucket) = _anchor();
        assertEq(anchor, paid);
        assertEq(start, paid, "the first fill of the new minute starts the floor");
        assertEq(bucket, block.timestamp / 60);
        assertEq(core.rateAtCheckpoint(), paid * 9_900 / 10_000);
    }

    function _onePercentDrop(Settings memory s) internal pure {
        s.dropPerCreditBps = 100;
    }

    /// @dev the rate after `n` fills of `bps` each from `r`, rounded down at every fill
    function _walk(uint256 r, uint256 n, uint256 bps) internal pure returns (uint256) {
        for (uint256 i; i < n; ++i) {
            r = r * (10_000 - bps) / 10_000;
        }
        return r;
    }

    // ------------------------------------------------------------------ climb

    /// after a fill the rate climbs 0.5 percent a minute compounded, 10 minutes is 1.005^10
    function test_climbAfterTenMinutesMatchesTheFormula() public {
        _potTo(20 ether);
        _sellOne();
        uint256 r1 = core.rateAtCheckpoint();
        _warp(10 minutes);
        // 1.005^10 = 1.0511401320407896
        assertApproxEqRel(core.ethRate(), r1 * 1_051_140_132_040_790_000 / 1e18, 1e9);
        _warp(10 minutes);
        assertApproxEqRel(core.ethRate(), r1 * 1_104_895_577_186_790_000 / 1e18, 1e9, "20 minutes is 1.005^20");
    }

    /// the climb does not move while the pot cannot afford one average credit at the stored rate
    function test_climbWaitsForAFundedPot() public {
        _potTo(1e15);
        assertFalse(core.funded());
        _warp(2 hours);
        assertEq(core.ethRate(), START);
    }

    // ------------------------------------------------------------------ ceiling

    /// the rate stops at 125 percent of the rate paid at the last fill, with the loosening off
    function test_ceilingHoldsAt125PercentOfTheAnchor() public {
        _with(_noLoosening);
        _potTo(20 ether);
        _warp(1 hours);
        uint256 r0 = core.ethRate();
        assertEq(r0, START * 12_500 / 10_000, "before any fill the anchor is the opening rate");
        _sellOne();
        (uint256 anchor,,) = _anchor();
        assertEq(anchor, r0);
        _warp(3 hours);
        assertEq(core.ethRate(), r0 * 12_500 / 10_000, "125 percent of the rate paid, the climb stopped there");
        _warp(30 days);
        assertEq(core.ethRate(), r0 * 12_500 / 10_000);
        assertEq(core.rateAtCheckpoint(), r0 * 9_950 / 10_000, "stored until the next checkpoint");
    }

    function _noLoosening(Settings memory s) internal pure {
        s.idleLoosenBps = 0;
    }

    /// the anchor grows 2 percent per full 10 idle minutes: 2 percent after 10 minutes, 4 percent after 20
    function test_anchorLoosensTwoPercentPerTenIdleMinutes() public {
        _with(_fastClimb);
        _potTo(20 ether);
        _sellOne();
        (uint256 anchor,,) = _anchor();
        _warp(9 minutes + 59);
        assertEq(core.ethRate(), anchor * 12_500 / 10_000, "no loosening before 10 idle minutes");
        _warp(1);
        assertEq(core.ethRate(), anchor * 10_200 * 12_500 / 1e8, "2 percent after 10 minutes");
        _warp(10 minutes - 1);
        assertEq(core.ethRate(), anchor * 10_200 * 12_500 / 1e8, "and until 20 minutes");
        _warp(1);
        assertEq(core.ethRate(), anchor * 10_400 * 12_500 / 1e8, "4 percent after 20 minutes");
        _warp(100 minutes);
        assertEq(core.ethRate(), anchor * 12_400 * 12_500 / 1e8, "24 percent after 120 minutes");
    }

    function _fastClimb(Settings memory s) internal pure {
        s.climbPerMinBps = 1_000;
    }

    /// a fill resets the idle clock: the anchor is the rate paid then
    function test_aFillResetsTheLoosening() public {
        _with(_fastClimb);
        _potTo(20 ether);
        _sellOne();
        _warp(40 minutes);
        uint256 r = core.ethRate();
        (uint256 anchorBefore,,) = _anchor();
        assertEq(r, anchorBefore * 10_800 * 12_500 / 1e8, "loosened 8 percent");
        _sellOne();
        (uint256 anchor,,) = _anchor();
        assertEq(anchor, r, "the rate paid is the new anchor");
        _warp(5 minutes);
        assertEq(core.ethRate(), r * 12_500 / 10_000, "idle clock restarted, no loosening yet");
    }

    // ------------------------------------------------------------------ clamp

    /// the rate never exceeds the hourly room over 20 credits: pot * spendCapBps / (avgScore * 20)
    function test_clampHoldsAtHourlyRoomOverTwentyCredits() public {
        _with(_openCeiling);
        _potTo(0.5 ether);
        _warp(3 days);
        Settings memory s = core.settings();
        uint256 clamp = uint256(0.5 ether) * s.spendCapBps / (uint256(s.avgScore) * 20);
        assertEq(clamp, 11_547_344_110_854);
        assertEq(core.ethRate(), clamp, "held at the clamp");
        // twenty average credits cost no more than the hourly room, and a rate one wei higher would exceed it
        uint256 room = core.ethPot() * s.spendCapBps / 10_000;
        assertLe(20 * (uint256(s.avgScore) * clamp / 1e4), room);
        assertGt(20 * (uint256(s.avgScore) * (clamp + 20) / 1e4), room);
        _warp(30 days);
        assertEq(core.ethRate(), clamp);
        // more fees lift the clamp, the climb resumes from the stored rate
        _potTo(1 ether);
        uint256 clamp2 = core.ethPot() * s.spendCapBps / (uint256(s.avgScore) * 20);
        assertGt(clamp2, clamp);
        _warp(1 days);
        assertEq(core.ethRate(), clamp2);
    }

    function _openCeiling(Settings memory s) internal pure {
        s.ceilBps = 30_000;
        s.climbPerMinBps = 1_000;
    }

    /// the clamp divisor follows the setting
    function test_clampCreditsChangesTheClamp() public {
        _with(_openCeiling);
        _potTo(0.5 ether);
        Settings memory s = core.settings();
        s.clampCredits = 5;
        _setSettings(s);
        _warp(3 days);
        assertEq(core.ethRate(), uint256(0.5 ether) * s.spendCapBps / (uint256(s.avgScore) * 5));
    }

    // ------------------------------------------------------------------ bounds

    function _expectBad(Settings memory s, bytes32 field) internal {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, field));
        core.setSettings(s);
    }

    function test_boundsRevertOnEveryOutOfRangeValue() public {
        Settings memory s = Mainnet.defaultSettings();
        s.dropPerCreditBps = 0;
        _expectBad(s, "dropPerCreditBps");
        s = Mainnet.defaultSettings();
        s.dropPerCreditBps = 1_001;
        _expectBad(s, "dropPerCreditBps");
        s = Mainnet.defaultSettings();
        s.dropFloorBps = 4_999;
        _expectBad(s, "dropFloorBps");
        s = Mainnet.defaultSettings();
        s.dropFloorBps = 10_001;
        _expectBad(s, "dropFloorBps");
        s = Mainnet.defaultSettings();
        s.climbPerMinBps = 0;
        _expectBad(s, "climbPerMinBps");
        s = Mainnet.defaultSettings();
        s.climbPerMinBps = 1_001;
        _expectBad(s, "climbPerMinBps");
        s = Mainnet.defaultSettings();
        s.ceilBps = 9_999;
        _expectBad(s, "ceilBps");
        s = Mainnet.defaultSettings();
        s.ceilBps = 30_001;
        _expectBad(s, "ceilBps");
        s = Mainnet.defaultSettings();
        s.idleLoosenBps = 2_001;
        _expectBad(s, "idleLoosenBps");
        s = Mainnet.defaultSettings();
        s.clampCredits = 0;
        _expectBad(s, "clampCredits");
        s = Mainnet.defaultSettings();
        s.clampCredits = 1_001;
        _expectBad(s, "clampCredits");
    }

    function test_boundEdgesAreAccepted() public {
        Settings memory s = Mainnet.defaultSettings();
        s.dropPerCreditBps = 1;
        s.dropFloorBps = 5_000;
        s.climbPerMinBps = 1;
        s.ceilBps = 10_000;
        s.idleLoosenBps = 0;
        s.clampCredits = 1;
        _setSettings(s);
        assertEq(abi.encode(core.settings()), abi.encode(s));
        s.dropPerCreditBps = 1_000;
        s.dropFloorBps = 10_000;
        s.climbPerMinBps = 1_000;
        s.ceilBps = 30_000;
        s.idleLoosenBps = 2_000;
        s.clampCredits = 1_000;
        _setSettings(s);
        assertEq(abi.encode(core.settings()), abi.encode(s));
    }

    // ------------------------------------------------------------------ hard bounds

    /// a fill shrinks the pot until the clamp of 20 credits sits below the dropped rate: the read is the clamp
    function test_clampBoundsTheReadAfterAFillShrinksThePot() public {
        // 20 credits of hourly room at the opening rate: pot * 2000 / (4.33e6 * 20) = 4e12
        _potTo(20 * uint256(4_330_000) * START / 2_000);
        assertEq(core.ethRate(), START);
        _sellOne();
        uint256 pot = core.ethPot();
        uint256 clamp = pot * 2_000 / (4_330_000 * 20);
        assertGt(core.rateAtCheckpoint(), clamp, "the stored rate is above the clamp");
        assertTrue(core.funded());
        assertEq(core.ethRate(), clamp, "and the read is the clamp");
    }

    /// the owner lowers `ceilBps` below the stored rate: the read is the new ceiling
    function test_loweredCeilBpsBoundsTheRead() public {
        _with(_fastClimb);
        _potTo(20 ether);
        _sellOne();
        (uint256 anchor,,) = _anchor();
        _warp(5 minutes);
        assertEq(core.ethRate(), anchor * 12_500 / 10_000);
        Settings memory s = core.settings();
        s.ceilBps = 10_000;
        _setSettings(s);
        assertEq(core.rateAtCheckpoint(), anchor * 12_500 / 10_000, "setSettings stores the rate it found");
        assertEq(core.ethRate(), anchor, "the new ceiling is 100 percent of the anchor");
    }

    /// a year of idle loosening never takes the rate above `rateCap`
    function test_loosenedCeilingNeverPassesTheRateCap() public {
        _potTo(20 ether);
        _sellOne();
        _warp(365 days);
        assertEq(core.ethRate(), core.settings().rateCap);
    }

    // ------------------------------------------------------------------ fills and the anchor

    function _listingData(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeCall(ICreditStrategy.sellTargetNFT, (id));
    }

    function _forListing() internal returns (uint256 price) {
        _with(_openCeiling);
        _potTo(30 ether);
        price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _liftRateCap();
        _warpUntilCeiling(LISTED_A, price);
    }

    /// `buyListing` is one fill: the rate drops once and the anchor is the bid rate at that moment, not the cost
    function test_buyListingIsOneFillAndTheAnchorIsTheBidRate() public {
        uint256 price = _forListing();
        uint256 rate = core.ethRate();
        vm.prank(keeper);
        core.buyListing(price, _listingData(LISTED_A), LISTED_A, STRATEGY);
        (uint256 anchor, uint256 start,) = _anchor();
        assertEq(anchor, rate, "the anchor is the bid rate");
        assertEq(start, rate);
        assertTrue(anchor != price * 1e4 / 4_330_000, "not derived from the cost");
        assertEq(core.rateAtCheckpoint(), rate * 9_950 / 10_000, "one drop of 0.5 percent");
        assertEq(core.lastFillTime(), block.timestamp);
    }

    /// a reverted buy and a sell of no credit change neither the rate nor the anchor
    function test_revertedBuyAndEmptySellLeaveTheRateAndTheAnchor() public {
        uint256 price = _forListing();
        uint256 rate = core.rateAtCheckpoint();
        (uint256 a0, uint256 s0, uint256 b0) = _anchor();
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
        core.buyListing(price - 1, _listingData(LISTED_A), LISTED_A, STRATEGY);
        vm.prank(seller);
        vm.expectRevert(ICore.Empty.selector);
        core.sellForEth(new uint256[](0));
        vm.prank(seller);
        vm.expectRevert(ICore.ZeroId.selector);
        core.sellForEth(_one(0));
        (uint256 a1, uint256 s1, uint256 b1) = _anchor();
        assertEq(core.rateAtCheckpoint(), rate);
        assertTrue(a0 == a1 && s0 == s1 && b0 == b1, "the anchor state is unchanged");
    }

    /// a second fill in the minute bucket, after the climb took the rate above the first rate of the bucket: the floor
    /// still counts from the first rate, the anchor is the new rate paid
    function test_secondFillInTheBucketAfterTheClimbRaisedTheRate() public {
        _with(_fastClimb);
        _potTo(20 ether);
        _warp(1 hours);
        vm.warp((block.timestamp / 60 + 1) * 60 + 5);
        uint256[] memory ids = _credits(seller, 2);
        uint256 r0 = core.ethRate();
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        _warp(50);
        uint256 paid = core.ethRate();
        assertGt(paid, r0, "the climb took the rate above the first rate of the bucket");
        vm.prank(seller);
        core.sellForEth(_one(ids[1]));
        (uint256 anchor, uint256 start,) = _anchor();
        assertEq(start, r0, "the minute still starts at the first rate paid");
        assertEq(anchor, paid, "the anchor is the second rate paid");
        assertEq(
            core.rateAtCheckpoint(), paid * 9_950 / 10_000, "the floor of 80 percent of the first rate is not reached"
        );
    }

    /// `setRate` restates the price: the stored rate and the ceiling anchor are both the new rate, the fill clock and
    /// the minute start stay
    function test_setRateRestatesTheRateAndTheAnchorAndKeepsTheFillClock() public {
        _potTo(20 ether);
        _sellOne();
        uint64 fillTime = core.lastFillTime();
        (, uint256 start0, uint256 bucket0) = _anchor();
        _warp(30 minutes);
        vm.prank(owner);
        core.setRate(6e12);
        (uint256 anchor, uint256 start, uint256 bucket) = _anchor();
        assertEq(core.rateAtCheckpoint(), 6e12);
        assertEq(anchor, 6e12);
        assertEq(core.lastFillTime(), fillTime);
        assertTrue(start == start0 && bucket == bucket0, "the minute state is unchanged");
        assertEq(core.ethRate(), 6e12);
        // the ceiling follows the restated anchor: 125 percent, plus 3 intervals of 2 percent after 30 idle minutes
        _warp(1 days);
        assertEq(core.ethRate(), 6e12 * (10_000 + 200 * 147) * 12_500 / 1e8);
    }

    /// `setSettings` keeps the anchor, the minute state and the fill clock
    function test_setSettingsKeepsTheAnchor() public {
        _potTo(20 ether);
        _sellOne();
        (uint256 a0, uint256 s0, uint256 b0) = _anchor();
        uint64 fillTime = core.lastFillTime();
        _warp(7 minutes);
        _with(_fastClimb);
        (uint256 a1, uint256 s1, uint256 b1) = _anchor();
        assertTrue(a0 == a1 && s0 == s1 && b0 == b1, "the anchor state is unchanged");
        assertEq(core.lastFillTime(), fillTime);
    }

    // ------------------------------------------------------------------ gap in the market price

    /// @dev the first minute after a jump of the market at which the bid reaches the cheapest ask, `askMultiple` bps of
    /// the rate paid at the last fill, with the loosening on (`loosen` true) or off. a 20 eth pot, one fill before the jump
    function _minutesToFirstFill(uint256 askMultiple, bool loosen) internal returns (uint256 minutes_, uint256 anchor) {
        if (!loosen) _with(_noLoosening);
        _potTo(20 ether);
        _warp(30 hours);
        _sellOne();
        (anchor,,) = _anchor();
        uint256 ask = anchor * askMultiple / 10_000;
        for (uint256 m = 1; m <= 600; ++m) {
            _warp(60);
            if (core.ethRate() >= ask) return (m, anchor);
        }
    }

    /// the market price doubles between two fills. the cheapest seller asks 60 percent of the new price, 120 percent of
    /// the old one. the bid reaches it in 38 minutes, inside the 125 percent ceiling
    function test_gapUp100Percent_cheapestAskAt120PercentFillsWithinAnHour() public {
        (uint256 m, uint256 anchor) = _minutesToFirstFill(12_000, true);
        emit log_named_uint("minutes to the first fill after a +100 percent gap", m);
        assertGt(m, 0, "filled");
        assertLe(m, 60, "within an hour");
        assertLe(core.ethRate(), anchor * (10_000 + 200 * (m / 10)) * 12_500 / 1e8, "inside the ceiling");
        // 0.995 * 1.005^m >= 1.2 first at minute 38
        assertEq(m, 38);
    }

    /// every seller asks the full new price, 200 percent of the old one: only the loosening of the ceiling lifts the
    /// bid there, 125 percent * (1 + 2 percent * k) reaches 200 percent at k = 30, 300 idle minutes
    function test_gapUp100Percent_everyAskAtTheNewPriceWaitsForTheLoosening() public {
        (uint256 m,) = _minutesToFirstFill(20_000, true);
        emit log_named_uint("minutes to the first fill, no cheap ask", m);
        assertEq(m, 300);
    }

    /// with the loosening at zero the bid parks at 125 percent of the last rate paid for good
    function test_gapUp100Percent_withoutLooseningTheBidParks() public {
        (uint256 m, uint256 anchor) = _minutesToFirstFill(20_000, false);
        assertEq(m, 0, "no fill in 600 minutes");
        assertEq(core.ethRate(), anchor * 12_500 / 10_000);
    }
}
