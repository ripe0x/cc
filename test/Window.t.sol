// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {CoreBase} from "./CoreUnit.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane} from "../src/interfaces/Interfaces.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";

/// @notice the hourly spend window on the real stack. the window pot is the pot at the first spend of the hour plus
/// every eth amount booked into the pot since: fee pulls at the doors, `receive`, `skim` and sale proceeds. the room is
/// `windowPot * spendCapBps / 10_000 - spent`. spending is counted in `spent`, and a buyback draws on the separate
/// buyback pot, so neither lowers the window pot
contract WindowTest is CoreBase {
    uint256 internal constant BPS = 10_000;

    function setUp() public override {
        super.setUp();
        _spendCap(2_000);
        _skipToSplitStart();
        vm.deal(address(feeRouter), 1 gwei);
        _flush();
    }

    function _cap() internal view returns (uint256) {
        return core.settings().spendCapBps;
    }

    /// @dev the eth the Core booked into the pot from `FeesAdded` events of the recorded logs
    function _potInflow(Vm.Log[] memory logs) internal view returns (uint256 inflow) {
        uint256 feeBps = core.settings().feeToBuybackBps;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != ICore.FeesAdded.selector) continue;
            uint256 v = abi.decode(logs[i].data, (uint256));
            inflow += v - v * feeBps / BPS;
        }
    }

    /// @dev sells `ids` as the seller. returns the pot booked by the pull inside the call and the eth the pot paid out
    function _sell(uint256[] memory ids) internal returns (uint256 inflow, uint256 spent) {
        uint256 pot0 = core.ethPot();
        vm.recordLogs();
        vm.prank(seller);
        core.sellForEth(ids);
        inflow = _potInflow(vm.getRecordedLogs());
        spent = pot0 + inflow - core.ethPot();
    }

    /// a window opened at a pot of 0.05 eth, then 100 eth reach the router and are booked by the pull inside the next
    /// sell. the sell of ten credits fits the room of the grown pot and the room is the cap of the pot at open plus the
    /// inflow, minus everything spent
    function test_pullInsideASellRaisesTheRoomOfTheOpenWindow() public {
        _fund(0.05 ether - core.ethPot());
        assertEq(core.ethPot(), 0.05 ether);
        uint256[] memory ids = _credits(seller, 11);
        (, uint256 s1) = _sell(_one(ids[0]));
        assertGt(s1, 0);
        assertEq(core.hourlyRoom(), 0.05 ether * _cap() / BPS - s1, "room of the window at open");

        uint256[] memory batch = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            batch[i] = ids[i + 1];
        }
        _warp(1);
        vm.deal(address(feeRouter), 100 ether);
        (uint256 inflow, uint256 s2) = _sell(batch);
        assertGt(inflow, 10 ether, "the pull booked the fee eth");
        assertGt(s2, 0.01 ether, "the batch is larger than the room of the pot at open");
        assertEq(core.hourlyRoom(), (0.05 ether + inflow) * _cap() / BPS - s1 - s2, "room follows the inflow");
    }

    /// without the router eth a batch of one hundred credits exceeds the room of the small pot
    function test_theSameBatchWithoutInflowReverts() public {
        _fund(0.05 ether - core.ethPot());
        uint256[] memory ids = _credits(seller, 101);
        _sell(_one(ids[0]));
        _warp(1);
        uint256[] memory batch = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            batch[i] = ids[i + 1];
        }
        vm.prank(seller);
        vm.expectRevert(ICore.HourlyCap.selector);
        core.sellForEth(batch);
    }

    /// eth that `skim` books and the pot share of sale proceeds raise the room of an open window by the booked amount
    function test_skimAndSaleProceedsRaiseTheRoom() public {
        _fund(5 ether - core.ethPot());
        _sellStatement(address(0xB1D));
        uint256[] memory ids = _credits(seller, 1);
        _sell(ids);
        uint256 room0 = core.hourlyRoom();

        vm.deal(address(core), address(core).balance + 3 ether);
        core.skim();
        uint256 room1 = core.hourlyRoom();
        assertEq(room1, room0 + 3 ether * _cap() / BPS, "skim");

        uint256 pot1 = core.ethPot();
        uint256 owed = _collectSales();
        assertGt(owed, 0);
        uint256 added = core.ethPot() - pot1;
        assertEq(added, owed - owed * core.settings().saleToBuybackBps / BPS);
        assertApproxEqAbs(core.hourlyRoom(), room1 + added * _cap() / BPS, 1, "sale proceeds");
    }

    /// a buyback spends the separate buyback pot: the window pot and the room are unchanged
    function test_buybackLeavesTheRoom() public {
        _fund(5 ether - core.ethPot());
        _sellStatement(address(0xB1D));
        _sell(_credits(seller, 1));
        _collectSales();
        assertGt(core.ethToBuyback(), 0);
        uint256 room0 = core.hourlyRoom();
        uint256 pot0 = core.ethPot();
        vm.roll(block.number + core.settings().buybackDelay + 1);
        core.buyback();
        assertEq(core.ethPot(), pot0, "the buyback left the pot");
        assertEq(core.hourlyRoom(), room0, "and the room");
    }

    /// the window closes after an hour and the next spend opens one on the pot it finds
    function test_windowClosesAndReopensOnTheCurrentPot() public {
        _fund(0.05 ether - core.ethPot());
        uint256[] memory ids = _credits(seller, 3);
        _sell(_one(ids[0]));
        vm.deal(address(feeRouter), 100 ether);
        _flush();
        uint256 pot = core.ethPot();
        _warp(1 hours - 1);
        assertLt(core.hourlyRoom(), pot * _cap() / BPS, "still the open window, less the spend");
        _warp(1);
        assertEq(core.hourlyRoom(), pot * _cap() / BPS, "a new hour reads the pot now");
        (, uint256 s2) = _sell(_one(ids[1]));
        assertEq(core.hourlyRoom(), pot * _cap() / BPS - s2, "reopened on the pot found at the spend");
    }

    /// launch: a bot sells one credit in the first block at a tiny pot, the sniper window brings fee eth, then credits
    /// are sold every minute. every sale buys at the bid and none reverts with `HourlyCap`
    function test_launchFirstBlockSellThenInflowThenMinuteSells() public {
        _fund(0.01 ether - core.ethPot());
        uint256[] memory ids = _credits(seller, 41);
        (, uint256 first) = _sell(_one(ids[0]));
        assertLt(first, 0.01 ether * _cap() / BPS + 1, "the first sale fits the thin room");

        // fee eth of the sniper window
        vm.deal(address(feeRouter), 200 ether);
        _warp(60);
        (uint256 inflow,) = _sell(_one(ids[1]));
        assertGt(inflow, 10 ether);
        uint256 potBase = 0.01 ether + inflow;
        uint256 totalSpent = first;
        for (uint256 i = 2; i < 41; ++i) {
            _warp(60);
            uint256 bid = core.ceilingOf(ids[i]);
            uint256 before = seller.balance;
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
            assertEq(seller.balance - before, bid, "the sale buys at the bid read before");
            totalSpent += bid;
        }
        // the sales from the second on are not capped by the room of the thin pot at open
        assertGt(totalSpent, 0.01 ether * _cap() / BPS * 2, "bought past the room of the tiny pot");
        assertLe(totalSpent, potBase * _cap() / BPS, "and within the room of the grown pot");
    }

    /// @dev books `eth` through `skim`
    function _skim(uint256 eth) internal {
        vm.deal(address(core), address(core).balance + eth);
        core.skim();
    }

    /// eth booked after the hour ended and before the next spend: the room is the cap of the live pot, and the sell
    /// that opens the next window reads that pot once
    function test_inflowAfterTheHourBeforeTheNextSpend() public {
        _fund(1 ether - core.ethPot());
        uint256[] memory ids = _credits(seller, 2);
        _sell(_one(ids[0]));
        _warp(1 hours + 5);
        _skim(3 ether);
        uint256 pot = core.ethPot();
        assertEq(core.hourlyRoom(), pot * _cap() / BPS, "the live pot, no double count");
        (, uint256 s) = _sell(_one(ids[1]));
        assertEq(core.hourlyRoom(), pot * _cap() / BPS - s, "the window opened on the pot with the inflow once");
    }

    /// at windowStart + 1 hours the window is closed and an inflow is not added; one second earlier it is
    function test_inflowAtTheHourBoundary() public {
        _fund(1 ether - core.ethPot());
        uint256[] memory ids = _credits(seller, 2);
        uint256 t0 = block.timestamp;
        (, uint256 s1) = _sell(_one(ids[0]));
        vm.warp(t0 + 1 hours - 1);
        _skim(3 ether);
        assertEq(core.hourlyRoom(), (1 ether + 3 ether) * _cap() / BPS - s1, "one second before the end: counted");
        vm.warp(t0 + 1 hours);
        _skim(2 ether);
        uint256 pot = core.ethPot();
        assertEq(core.hourlyRoom(), pot * _cap() / BPS, "at the boundary the window is closed: the live pot");
        (, uint256 s2) = _sell(_one(ids[1]));
        assertEq(core.hourlyRoom(), pot * _cap() / BPS - s2, "the next window opened on the pot with both inflows once");
    }

    /// after `migrate` the window start is zero: an inflow is not added and the next spend opens on the pot it finds
    function test_inflowAfterMigrate() public {
        MigrationSink sink = new MigrationSink();
        _fund(1 ether - core.ethPot());
        uint256[] memory ids = _credits(seller, 1);
        _sell(ids);
        vm.prank(owner);
        core.setSuccessor(address(sink));
        vm.prank(owner);
        core.migrate(10, 10);
        assertEq(core.ethPot(), 0);
        _skim(2 ether);
        assertEq(core.hourlyRoom(), 2 ether * _cap() / BPS, "the live pot");
        (, uint256 s) = _sell(_credits(seller, 1));
        assertEq(core.hourlyRoom(), 2 ether * _cap() / BPS - s, "opened on the pot found");
    }

    /// an inflow before the opening spend of the same timestamp is read once in the window pot, and one after it is
    /// added once
    function test_inflowInTheBlockThatOpensTheWindow() public {
        _fund(1 ether - core.ethPot());
        uint256[] memory ids = _credits(seller, 2);
        _warp(1 hours + 1);
        _skim(2 ether);
        uint256 pot = core.ethPot();
        (, uint256 s1) = _sell(_one(ids[0]));
        assertEq(core.hourlyRoom(), pot * _cap() / BPS - s1, "inflow before the opening spend: once");
        _skim(1 ether);
        assertEq(core.hourlyRoom(), (pot + 1 ether) * _cap() / BPS - s1, "inflow after it, same timestamp: once");
    }
}
