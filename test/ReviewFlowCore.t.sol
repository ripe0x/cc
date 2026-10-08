// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICoreLib} from "../src/interfaces/ICoreLib.sol";
import {
    Lane,
    Settings,
    Mainnet,
    IStatements,
    RATE_START_MIN_WEI,
    RATE_START_MAX_WEI
} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";

/// @notice independent review of the flow rework, settings and the library split (docs/REVIEW-flow-core.md).
/// every test_POC_ test passes and shows the bad outcome on the fork
contract ReviewFlowCoreTest is Fixture {
    /// @dev what one credit costs on the open market at the pin, used only to price what an accomplice paid
    uint256 internal constant MARKET = 0.0089 ether;

    function _hot(uint256 spendCap, uint256 drop, uint256 avg) internal view returns (Settings memory h) {
        h = core.settings();
        h.spendCapBps = uint16(spendCap);
        h.dropBps = uint16(drop);
        h.avgScore = uint32(avg);
    }

    /// the owner raises the rate cap and sets the hot (but in bounds) settings: spend cap, drop and score at their
    /// loosest. the rate is then set to the top of the rate bounds
    function _hotSettings() internal view returns (Settings memory h) {
        h = _hot(5_000, 500, 6_000_000);
        h.rateCap = uint64(RATE_START_MAX_WEI);
    }

    /// FC-1 (accepted by the owner): the owner sets the price the engine pays, so an accomplice seller can be overpaid.
    /// the bounds limit the speed, not the price per credit. this measures the worst case under the bounds in
    /// docs/FLOW.md: per transaction (one block) and per day, as a share of the pot. the numbers in docs/ARCHITECTURE.md
    /// and docs/REVIEW-flow-core.md are these
    function test_ACCEPTED_ownerCanOverpayAnAccompliceSeller() public {
        _skipSniperWindow();
        _fundPot(10 ether);
        uint256 pot = core.ethPot();
        vm.warp(block.timestamp + 2 hours);

        // per transaction: every lever at its loosest, in one block, then everything put back
        Settings memory launch = core.settings();
        uint256 rate0 = core.ethRate();
        vm.startPrank(owner);
        core.setSettings(_hotSettings());
        core.setRate(RATE_START_MAX_WEI);
        vm.stopPrank();
        uint256 price = core.ceilingOf(_credits(seller, 1)[0]);
        assertEq(price, 0.6 ether, "0.6 eth for one average credit at the rate top and avgScore 6M");
        uint256 n = pot * 5_000 / 10_000 / price;
        uint256[] memory ids = _credits(seller, n);
        uint256 b = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        uint256 got = seller.balance - b;
        vm.startPrank(owner);
        core.setSettings(launch);
        core.setRate(rate0);
        vm.stopPrank();
        emit log_named_uint("per tx: pot before (wei)", pot);
        emit log_named_uint("per tx: paid to the accomplice (wei)", got);
        emit log_named_uint("per tx: share of the pot, bps", got * 10_000 / pot);
        emit log_named_uint("per tx: market value of the credits (wei)", n * MARKET);
        assertLe(got, pot / 2, "never above the spend cap of 50 percent");
        assertGe(got, pot * 45 / 100, "at least 45 percent in one block");
        assertGt(got, n * MARKET * 50, "paid 50x market");
        _solvent();
    }

    /// FC-1 per day: the owner acts every hour for 24 hours, at the loosest settings and at the launch settings
    function test_ACCEPTED_ownerPerDayWorstCase() public {
        _skipSniperWindow();
        _fundPot(10 ether);
        uint256 pot0 = core.ethPot();
        uint256 snap = vm.snapshotState();
        for (uint256 mode; mode < 2; ++mode) {
            if (mode == 1) {
                vm.revertToState(snap);
            } else {
                Settings memory hot = _hotSettings();
                vm.prank(owner);
                core.setSettings(hot);
            }
            Settings memory cur = core.settings();
            uint256 total;
            uint256 credits;
            for (uint256 h; h < 24; ++h) {
                vm.warp(block.timestamp + 1 hours + 1);
                uint256 room = core.ethPot() * cur.spendCapBps / 10_000;
                uint256 r = room * 1e4 / cur.avgScore;
                if (r > cur.rateCap) r = cur.rateCap;
                if (r < RATE_START_MIN_WEI) break;
                vm.prank(owner);
                core.setRate(r);
                uint256 k = room / (r * cur.avgScore / 1e4);
                if (k == 0) break;
                credits += k;
                uint256[] memory ids = _credits(seller, k);
                uint256 b = seller.balance;
                vm.prank(seller);
                core.sellForEth(ids);
                total += seller.balance - b;
                if (h == 0) {
                    emit log_named_uint(
                        mode == 0
                            ? "first window, loosest: share of the pot, bps"
                            : "first window, launch: share of the pot, bps",
                        total * 10_000 / pot0
                    );
                }
            }
            emit log_named_uint(
                mode == 0 ? "per day, loosest settings: paid (wei)" : "per day, launch settings: paid (wei)", total
            );
            emit log_named_uint("per day: share of the pot, bps", total * 10_000 / pot0);
            emit log_named_uint("per day: market value of the credits (wei)", credits * MARKET);
            assertGt(total, pot0 * (mode == 0 ? 99 : 95) / 100, "the seller took it");
            _solvent();
        }
    }

    function _expectBad(Settings memory s, bytes32 field) internal {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, field));
        core.setSettings(s);
    }

    /// FC-2 (fixed by bounds): saleFloorBps now starts at 1_000 and auctionDuration at 6 hours. at the floor an accomplice
    /// that bids the reserve still buys at 10 percent of cost, but a stranger has six hours to bid over it
    function test_FIXED_reserveAndAuctionDurationFloors() public {
        _skipSniperWindow();
        _fillEthPile(80);
        Settings memory s = core.settings();
        s.saleFloorBps = 999;
        _expectBad(s, "saleFloorBps");
        s.saleFloorBps = 1_000;
        s.auctionDuration = 6 hours - 1;
        _expectBad(s, "auctionDuration");
        s.auctionDuration = 6 hours;
        _setSettings(s);
        // the controller asks the floor too
        vm.startPrank(owner);
        ctl.setFloorBps(1_000);
        ctl.setStartBps(1_000);
        vm.stopPrank();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        (,, uint256 cost,) = core.statementInfo(sid);
        Live memory l = _live(sid);
        assertEq(l.reserve, cost * 1_000 / 10_000, "reserve at the floor is 10 percent of cost");
        address accomplice = _user("accomplice");
        _bid(accomplice, sid, l.reserve);
        // a stranger has six hours: +5 percent takes the lot
        address stranger = _user("stranger");
        _bid(stranger, sid, l.reserve * 105 / 100 + 1);
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), stranger, "the stranger won inside the window");
        assertEq(_collectSales(), l.reserve * 105 / 100 + 1);
    }

    /// FC-7 (fixed by bounds): exitAfter 0 is refused, the floor is one hour, and an exit inside it reverts
    function test_FIXED_exitAfterFloorKeepsTheListingOpen() public {
        _enterPhase2();
        Settings memory s = core.settings();
        s.exitAfter = 0;
        _expectBad(s, "exitAfter");
        s.exitAfter = 1 hours;
        _setSettings(s);
        Composed memory c = _composeOnce();
        assertEq(uint8(_live(c.sid).status), uint8(ICore.StatementStatus.Listed));
        vm.expectRevert(ICore.TooEarly.selector);
        core.exitStatement(c.sid);
        _warp(1 hours);
        core.exitStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "after the hour the module holds the statement");
    }

    /// held: a constructor against a library address with no code reverts (the delegatecall has a code check)
    function test_constructorRefusesAnEmptyLibraryAddress() public {
        address lib = findLibrary(address(core).code);
        assertTrue(lib != address(0), "library found");
        // control: the same construction works while the library has code
        ICore ok = Prod.newCore(owner, address(coin), address(ctl), lc.stack, lc.rateStart, lc.settings);
        assertEq(ok.settings().avgScore, lc.settings.avgScore, "control builds");
        vm.etch(lib, "");
        bool built;
        try this.buildCore() returns (ICore c2) {
            built = true;
            emit log("constructed against an empty library");
            emit log_named_uint("avgScore stored", c2.settings().avgScore);
        } catch {
            emit log("constructor reverted");
        }
        assertFalse(built, "an empty library address must stop the constructor");
    }

    /// @dev an external wrapper so `try` can catch a constructor revert of the artifact deploy
    function buildCore() external returns (ICore) {
        return Prod.newCore(owner, address(coin), address(ctl), lc.stack, lc.rateStart, lc.settings);
    }

    function _allMin() internal pure returns (Settings memory m) {
        m.avgScore = 800_000;
        m.climbDoubleEvery = 1 hours;
        m.dropBps = 500;
        m.spendCapBps = 100;
        m.saleFloorBps = 1_000;
        m.auctionDuration = 6 hours;
        m.exitAfter = 1 hours;
        m.rateCap = uint64(RATE_START_MIN_WEI);
        m.buybackSlice = 0.01 ether;
        m.buybackDelay = 1;
        m.xAuctionHalfLife = 10 minutes;
        m.exitSliceCredits = 1;
    }

    function _allMax() internal pure returns (Settings memory m) {
        m = Settings(
            10_000,
            6_000_000,
            1_000,
            30 days,
            2_000,
            5_000,
            5_000,
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
            5 ether,
            7_200,
            500,
            10_000,
            10_000,
            1_000,
            1_000,
            30 days,
            1_000,
            uint64(RATE_START_MAX_WEI),
            10_000,
            10_000
        );
    }

    /// the library is never usable directly, and the packed words round trip at both ends of every bound
    function test_libraryDirectCallsRevertAndPackingRoundTrips() public {
        address lib = findLibrary(address(core).code);
        (bool ok,) = lib.call(abi.encodeWithSelector(bytes4(keccak256("setSettings(Settings)")), _allMax()));
        assertFalse(ok, "setSettings direct");
        (ok,) = lib.call(
            abi.encodeWithSelector(
                ICoreLib.swapIn.selector, Mainnet.POOL_MANAGER, address(coin), uint24(0), int24(200), address(0), 1
            )
        );
        assertFalse(ok, "swapIn direct");
        assertEq(lib.code.length > 0, true);
        Settings[2] memory two = [_allMin(), _allMax()];
        for (uint256 i; i < 2; ++i) {
            _setSettings(two[i]);
            assertEq(keccak256(abi.encode(core.settings())), keccak256(abi.encode(two[i])), "round trip");
            // the three raw words hold exactly the values and nothing else
            bytes32 slot = 0xb5805f89ef62cd999f965a45fb6f4c11141caa04e5c4acba9c2552ef76902804;
            uint256 w0 = uint256(vm.load(address(core), slot));
            assertEq(w0 >> 240, 0, "slot 0 top bits clear");
            uint256 w2 = uint256(vm.load(address(core), bytes32(uint256(slot) + 2)));
            assertEq(w2 >> 208, 0, "slot 2 top bits clear");
            assertEq(uint16(w2 >> 192), two[i].feeToBuybackBps, "the fee share sits at bits 192 to 207");
            assertEq(uint64(w2 >> 112), two[i].rateCap, "the rate cap sits at bits 112 to 175");
            assertEq(uint16(w2 >> 176), two[i].exitLaneToBuybackBps, "the exit lane share sits at bits 176 to 191");
        }
    }

    function _hostileMix() internal pure returns (Settings memory m) {
        m = _allMax();
        m.avgScore = 800_000;
        m.climbDoubleEvery = 1 hours;
        m.xAuctionHalfLife = 10 minutes;
        m.xRateFloor = 0;
        m.xRateCap = 0;
        m.saleFloorBps = 3_000;
    }

    /// no combination at either end of the bounds stops the hook from paying the core, whatever the gap
    function test_extremeSettingsNeverBrickReceive() public {
        _skipSniperWindow();
        Settings[3] memory three = [_allMin(), _allMax(), _hostileMix()];
        for (uint256 i; i < 3; ++i) {
            _setSettings(three[i]);
            for (uint256 g; g < 3; ++g) {
                vm.warp(block.timestamp + (g == 0 ? 1 hours : (g == 1 ? 40 days : 3_650 days)));
                uint256 pot = core.ethPot() + core.ethToBuyback();
                _buyCoin(funder, 2 ether);
                assertGt(core.ethPot() + core.ethToBuyback(), pot, "the hook's push was booked");
                core.ethRate();
                _solvent();
            }
            uint256[] memory ids = _credits(seller, 1);
            vm.prank(seller);
            try core.sellForEth(ids) {} catch {}
        }
    }

    /// the exit auction and the exit rate at the extremes, and a half life change on a live auction
    function test_extremeSettingsPhase2() public {
        _skipSniperWindow();
        _enterPhase2();
        _fillExitBuyback();
        assertGt(core.xToBuyback(), 0);
        Settings[3] memory three = [_allMin(), _allMax(), _hostileMix()];
        for (uint256 i; i < 3; ++i) {
            uint256 p0 = core.exitAuctionPrice();
            _setSettings(three[i]);
            assertApproxEqRel(core.exitAuctionPrice(), p0, 1e15, "price continuous over the change");
            vm.warp(block.timestamp + (i == 0 ? 1 hours : 100 days));
            core.exitAuctionPrice();
            core.exitAuctionQuote();
            core.xRate();
            core.skim();
        }
    }

    function _idle(uint256 potEth) internal returns (uint256 hrs, uint256 price, uint256 pot) {
        _skipSniperWindow();
        _fundPot(potEth);
        pot = core.ethPot();
        uint256[] memory ids = _credits(seller, 1);
        uint256 last;
        for (; hrs < 24 * 40; ++hrs) {
            price = core.ceilingOf(ids[0]);
            if (price == last) break;
            last = price;
            vm.warp(block.timestamp + 1 hours);
        }
        // a single seller takes one credit at the clamp
        uint256 b = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        price = seller.balance - b;
    }

    /// FC-5 (fixed with the `rateCap` setting): flat mode, no seller at all. the limit climbs only up to the rate cap,
    /// so what one seller can take stays at the cap price however long the market is dead
    function test_FIXED_idleClimbStopsAtTheRateCap() public {
        uint256[3] memory pots = [uint256(1 ether), 5 ether, 20 ether];
        uint256 capPrice = uint256(core.settings().rateCap) * core.settings().avgScore / 1e4;
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            (uint256 hrs, uint256 took, uint256 pot) = _idle(pots[i]);
            emit log_named_uint("pot (wei)", pot);
            emit log_named_uint("hours until the limit stops climbing", hrs);
            emit log_named_uint("one seller took (wei)", took);
            emit log_named_uint("cap price of one average credit (wei)", capPrice);
            assertEq(core.ethRate() <= core.settings().rateCap, true, "the rate never passes the cap");
            assertLe(took, capPrice, "one credit never pays more than the cap price");
            assertLe(took, pot * 2_000 / 10_000, "never above the hourly cap");
            vm.revertToState(snap);
        }
    }

    /// the rate cap is a hard ceiling: setRate refuses above it, the cap is bounded like the rate, a lower cap pulls
    /// the rate down at the checkpoint, and a higher cap lets the climb go on
    function test_FIXED_rateCapIsAHardCeiling() public {
        Settings memory s = core.settings();
        assertEq(s.rateCap, 123_200_000_000_000, "launch value");
        vm.prank(owner);
        vm.expectRevert(ICore.BadRate.selector);
        core.setRate(uint256(s.rateCap) + 1);
        vm.prank(owner);
        core.setRate(s.rateCap);
        assertEq(core.ethRate(), s.rateCap);
        // bounds of the cap itself
        s.rateCap = uint64(RATE_START_MIN_WEI - 1);
        _expectBad(s, "rateCap");
        s.rateCap = uint64(RATE_START_MAX_WEI + 1);
        _expectBad(s, "rateCap");
        // lowering the cap below the live rate pulls the rate down to it
        s.rateCap = 5e13;
        _setSettings(s);
        assertEq(core.ethRate(), 5e13, "the rate follows the cap down");
        assertEq(core.rateAtCheckpoint(), 5e13);
        // a rate cap above the rate does not touch the rate
        s.rateCap = 2e14;
        _setSettings(s);
        assertEq(core.ethRate(), 5e13);
        vm.prank(owner);
        core.setRate(2e14);
        assertEq(core.ethRate(), 2e14);
    }

    /// the climb clamps at the cap even with a large pot
    function test_FIXED_climbClampsAtTheRateCap() public {
        _skipSniperWindow();
        _fundPot(50 ether);
        _warp(60 days);
        assertEq(core.ethRate(), core.settings().rateCap, "clamped by the cap, not by the pot");
        Settings memory s = core.settings();
        s.rateCap = 5e14;
        _setSettings(s);
        _warp(60 days);
        assertEq(core.ethRate(), 5e14, "a higher cap lets the climb continue to it");
    }

    /// FC-3 (fixed by bounds): the buyback slice tops out at 5 eth. a sandwich around the 1 eth launch slice loses money
    /// for the attacker after both skims, at the 5 eth cap it nets a small bounded gain at the 6.9 point skim (the 100 eth
    /// slice that paid 46 eth is no longer reachable)
    function test_FIXED_buybackSliceCapStopsTheSandwich() public {
        _skipSniperWindow();
        Settings memory big = core.settings();
        big.buybackSlice = 5 ether + 1;
        _expectBad(big, "buybackSlice");
        uint256[2] memory slices = [uint256(1 ether), 5 ether];
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            vm.deal(address(core), address(core).balance + slices[i]);
            vm.store(address(core), bytes32(uint256(7)), bytes32(slices[i]));
            Settings memory s = core.settings();
            s.buybackSlice = uint128(slices[i]);
            s.buybackDelay = 1;
            _setSettings(s);
            vm.roll(block.number + 100);
            address mev = _user("mev");
            uint256 front = slices[i] * 3;
            uint256 got = _buyCoin(mev, front);
            vm.prank(keeper);
            core.buyback();
            uint256 back = _sellCoin(mev, got);
            emit log_named_uint("slice", slices[i]);
            emit log_named_int("attacker net (wei)", int256(back) - int256(front));
            if (slices[i] == 1 ether) {
                assertLt(back, front, "the sandwich loses money at the launch slice");
            } else {
                // v2 launch: a trader pays 6.9 points each way (it was about 10), so at the 5 eth cap a 3x front run
                // nets a few points of its stake. bounded by a fifth of the slice, far from the 46 eth outlier
                assertLt(back, front + slices[i] / 5, "the sandwich at the cap stays small");
            }
            vm.revertToState(snap);
        }
    }

    /// a word with bits above the field width is refused by the library, never truncated into bounds
    function test_dirtyCalldataWordsAreRefused() public {
        Settings memory base = core.settings();
        bytes memory good = abi.encodeCall(ICore.setSettings, (base));
        assertEq(good.length, 4 + 29 * 32);
        for (uint256 i; i < 29; ++i) {
            bytes memory bad = bytes.concat(good);
            uint256 off = 32 + 4 + i * 32;
            uint256 w;
            assembly ("memory-safe") {
                w := mload(add(bad, off))
            }
            // a 1 far above any field width keeps the low bits equal to the live (in bounds) value
            uint256 dirty = w | (uint256(1) << 200);
            assembly ("memory-safe") {
                mstore(add(bad, off), dirty)
            }
            vm.prank(owner);
            (bool ok,) = address(core).call(bad);
            assertFalse(ok, "dirty word accepted");
        }
        // the clean call works, and extra trailing bytes are ignored
        vm.prank(owner);
        (bool ok2,) = address(core).call(bytes.concat(good, hex"deadbeef"));
        assertTrue(ok2);
        // not the owner
        (bool ok3,) = address(core).call(good);
        assertFalse(ok3);
    }

    /// gas of the hook's push into receive() after idle gaps, at launch settings and at the slowest doubling
    function test_receiveGasByGap() public {
        _skipSniperWindow();
        _fundPot(5 ether);
        address hook = core.FEE_SOURCE();
        uint256[4] memory gaps = [uint256(1 hours), 5 days, 400 days, 36_500 days];
        for (uint256 j; j < 2; ++j) {
            if (j == 1) {
                Settings memory s = core.settings();
                s.climbDoubleEvery = 1 hours;
                s.climbBaseBps = 1;
                s.climbMaxBps = 2_000;
                _setSettings(s);
            }
            for (uint256 i; i < 4; ++i) {
                uint256 snap = vm.snapshotState();
                vm.warp(block.timestamp + gaps[i]);
                vm.deal(hook, 1 ether);
                vm.prank(hook);
                uint256 g = gasleft();
                (bool ok,) = address(core).call{value: 0.01 ether}("");
                g -= gasleft();
                assertTrue(ok);
                emit log_named_uint(j == 0 ? "launch settings, gap" : "dbl 1h base 1, gap", gaps[i]);
                emit log_named_uint("gas", g);
                vm.revertToState(snap);
            }
        }
    }

    /// what the reimbursement pays at the cap, default and maximum
    function test_reimbursementAtTheCap() public {
        _skipSniperWindow();
        _fillEthPile(80);
        uint256 snap = vm.snapshotState();
        for (uint256 j; j < 2; ++j) {
            if (j == 1) {
                Settings memory s = core.settings();
                s.reimburseBps = 15_000;
                s.reimburseCapBps = 1_000;
                _setSettings(s);
            }
            vm.fee(50 gwei);
            uint256 b = keeper.balance;
            vm.prank(keeper);
            core.compose();
            uint256 sid = STATEMENTS.supply();
            (,, uint256 cost,) = core.statementInfo(sid);
            emit log_named_uint("reimbursement (wei)", keeper.balance - b);
            emit log_named_uint("statement cost incl reimbursement (wei)", cost);
            vm.revertToState(snap);
        }
    }

    /// the real cost of ControllerV1.nextPage for a full page, which sizes the fixed gas cap of the core's read
    function test_measure_controllerV1PageGas() public {
        _fillEthPile(80);
        uint256 g = gasleft();
        (bool ready,,) = ctl.nextPage(Lane.Eth);
        uint256 used = g - gasleft();
        assertTrue(ready);
        emit log_named_uint("ControllerV1.nextPage gas, full page, cold", used);
        // the core's read of nextPage is capped at 500,000 gas (PAGE_GAS): at least 5 times what a full page costs
        assertLt(used * 5, 500_000, "ample room under the gas cap of the core's read");
        g = gasleft();
        ctl.nextPage(Lane.Eth);
        emit log_named_uint("ControllerV1.nextPage gas, full page, warm", g - gasleft());
    }

    /// FC-4 (fixed): the exit lane reimbursement is capped by the notional cost of an average statement at the immutable
    /// RATE_START, and the controller's nextPage read has a fixed gas cap. a controller that burns gas cannot farm the
    /// pot: past the cap its page is refused, below it the refund is held at the notional cap
    function test_FIXED_gasBurningControllerCannotFarmTheExitLaneReimbursement() public {
        _skipSniperWindow();
        _enterPhase2();
        _fundPot(3 ether);
        // the eth rate is as high as the owner can set it, which used to lift the cap with it
        Settings memory s = core.settings();
        s.rateCap = uint64(RATE_START_MAX_WEI);
        s.reimburseBps = 15_000;
        s.reimburseCapBps = 1_000;
        _setSettings(s);
        vm.prank(owner);
        core.setRate(RATE_START_MAX_WEI);
        xt.mint(address(core), 1e20);
        core.skim();
        uint256[] memory ids = _credits(seller, 80);
        vm.prank(seller);
        core.sellForExitToken(ids);
        assertEq(core.pileSize(Lane.Exit), 80);

        // 20M gas of burning is far past the cap (500,000): the read fails and the page is not ready
        BurnController bc = new BurnController(address(core), 20_000_000);
        _setController(address(bc));
        vm.fee(20 gwei);
        vm.prank(keeper);
        vm.expectRevert(ICore.NotReady.selector);
        core.composeExit{gas: 30_000_000}();

        // burning 300,000 (under the cap with the page read) is answered, and the refund is held at the notional cap of the launch rate
        uint256 snap = vm.snapshotState();
        bc = new BurnController(address(core), 300_000);
        _setController(address(bc));
        uint256 notional = 80 * uint256(s.avgScore) * core.RATE_START() / 1e4 * s.reimburseCapBps / 10_000;
        uint256 potBefore = core.ethPot();
        uint256 b = keeper.balance;
        vm.prank(keeper);
        core.composeExit{gas: 30_000_000}();
        uint256 refunded = keeper.balance - b;
        emit log_named_uint("notional cap at RATE_START (wei)", notional);
        emit log_named_uint("caller refunded (wei)", refunded);
        assertEq(potBefore - core.ethPot(), refunded);
        assertLe(refunded, notional, "never above the notional cap at RATE_START");
        assertLt(refunded, 0.06 ether, "was 0.82 eth for the same page before the fix");
        vm.revertToState(snap);
    }

    /// held: at the clamp the flat ceiling equals the hourly cap, so a bonus on top makes the credit unsellable
    /// (HourlyCap). the cap is never passed
    function test_bonusAtTheClampCannotPassTheHourlyCap() public {
        _skipSniperWindow();
        // the launch rate cap (8 times the opening rate) sits below the funded clamp: raise it to the bounds
        Settings memory cs = core.settings();
        cs.rateCap = uint64(RATE_START_MAX_WEI);
        _setSettings(cs);
        _fundPotNear(2 ether);
        ScriptedController sc = new ScriptedController();
        _setController(address(sc));
        // the eth rate climbs lazily: a week at the climb settings reaches the clamp
        _warp(7 days);
        uint256[] memory ids = _credits(seller, 2);
        sc.setWants(ids[0], 2_500);
        uint256 flat = core.ceilingOf(ids[1]);
        assertApproxEqRel(flat, core.ethPot() * 2_000 / 10_000, 1e9, "at the clamp the flat ceiling is the hourly cap");
        assertApproxEqRel(core.ceilingOf(ids[0]), flat * 12_500 / 10_000, 1e9, "bonus on top");
        vm.prank(seller);
        vm.expectRevert(ICore.HourlyCap.selector);
        core.sellForEth(_one(ids[0]));
        vm.prank(seller);
        core.sellForEth(_one(ids[1]));
    }

    /// held: the exit bid at 100 percent of score pays exactly what the module pays back for the same credits, so
    /// selling credits for exit token and exiting them leaves the exit pot whole (the eth pot pays the compose refund)
    function test_exitBidAtParIsAWash() public {
        _skipSniperWindow();
        _enterPhase2();
        _fundPot(3 ether);
        Settings memory s = core.settings();
        s.xRateCap = 10_000;
        s.xRateFloor = 10_000;
        s.xRateDropPerCredit = 0;
        _setSettings(s);
        vm.prank(owner);
        core.setXRate(10_000);
        xt.mint(address(core), 1e20);
        core.skim();
        uint256 xBefore = core.xPot();
        uint256[] memory ids = _credits(seller, 80);
        vm.prank(seller);
        core.sellForExitToken(ids);
        uint256 paid = xBefore - core.xPot();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.composeExit();
        uint256 sid = STATEMENTS.supply();
        core.exitStatement(sid);
        emit log_named_uint("paid to the seller (exit token)", paid);
        emit log_named_uint("exit pot before", xBefore);
        emit log_named_uint("exit pot after the exit", core.xPot());
        assertEq(core.xPot(), xBefore, "the pot is whole");
    }
}

/// a controller that answers like ControllerV1 but burns gas first (a staticcall can do that and nothing else)
contract BurnController {
    ICore internal immutable CORE;
    uint256 internal immutable BURN;

    constructor(address core_, uint256 burn_) {
        CORE = ICore(payable(core_));
        BURN = burn_;
    }

    function wants(uint256) external pure returns (uint16) {
        return 0;
    }

    function nextPage(Lane lane) external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        uint256 stop = gasleft() - BURN;
        uint256 h;
        while (gasleft() > stop) {
            h = uint256(keccak256(abi.encode(h)));
        }
        if (h == 1) return (false, ids, 0);
        uint256[] memory page = CORE.pilePage(lane, 0, 80);
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        return (true, ids, 0);
    }

    function nextOverprint() external pure returns (bool, uint256, uint256) {
        return (false, 0, 0);
    }

    function statementPrice(uint256, uint256 cost, uint64) external pure returns (uint256) {
        return cost * 11_000 / 10_000;
    }
}
