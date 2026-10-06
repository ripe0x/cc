// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {Lane, Settings} from "../src/interfaces/Interfaces.sol";

/// @notice the inventory gate is gone (docs/FLOW.md decision 2): the engine never stops buying because statements are
/// unsold. what is left of its suite is the rate property that never depended on the gate (the rate does not rise
/// across an interval that was unfunded at its start) under a random walk over the doors, the clock, the fees, the
/// sales on the house and the settings, and a proof that held and unsold statements change nothing about the bid
contract GateTest is Fixture {
    using FixedPointMathLib for uint256;

    function _composeNext() internal returns (uint256 sid) {
        sid = STATEMENTS.supply() + 1;
        uint256 size = core.pileSize(Lane.Eth);
        if (size < 80) _fillEthPile(80 - size);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.supply(), sid);
    }

    function _sellOne() internal {
        uint256[] memory ids = _credits(seller, 1);
        _fundPot(core.ethPot() + 0.2 ether);
        vm.prank(seller);
        core.sellForEth(ids);
    }

    /// two statements sit unsold on the house and nothing closes: the bid is open, the climb restarts at the base tier
    /// after a fill and runs on, a statement sale changes none of it, and the pot is never gated on inventory
    function test_unsoldStatementsNeverStopTheBidOrTheClimb() public {
        _skipSniperWindow();
        uint256 s1 = _composeNext();
        uint256 s2 = _composeNext();
        assertEq(core.heldStatements().length, 2);
        assertEq(uint256(_live(s1).status), uint256(Core.StatementStatus.Listed));
        assertEq(uint256(_live(s2).status), uint256(Core.StatementStatus.Listed));
        // the bid is open at two held statements, however long they sit
        _warp(30 days);
        _sellOne();
        assertEq(core.heldStatements().length, 2, "still unsold");
        assertTrue(core.funded());
        uint256 r0 = core.rateAtCheckpoint();
        uint256 t0 = core.checkpointTime();
        _warp(10 hours);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 want =
            r0.mulWad(uint256(FixedPointMathLib.powWad(1.01e18, int256((block.timestamp - t0) * 1e18 / 1 hours))));
        assertApproxEqRel(core.ethRate(), want, 1e12, "base tier right after a fill, ten hours");
        assertGt(core.ethRate(), r0);
        // one of them sells on the house: nothing about the bid changes, and the other keeps waiting
        _bid(funder, s1, _live(s1).reserve);
        _endAuction(s1);
        uint256 rateBefore = core.ethRate();
        _collectSales();
        assertEq(core.ethRate(), rateBefore, "booking the proceeds does not touch the rate");
        _sellOne();
        assertEq(uint256(_live(s2).status), uint256(Core.StatementStatus.Listed));
        _solvent();
    }
}

/// @notice a random walk over the doors, the clock, the fees, the sales on the house and the owner's settings. every
/// step checks that the rate never rose across an interval that was unfunded at its start, and that the books stay
/// solvent
contract GateFuzzTest is Fixture {
    function setUp() public override {
        super.setUp();
        _skipSniperWindow();
        _fillEthPile(80);
    }

    function _settingsWalk(uint256 seed) internal {
        Settings memory s = core.settings();
        uint256 pick = seed >> 8;
        // forge-lint: disable-start(unsafe-typecast)
        if (pick % 4 == 0) s.avgScore = uint32(800_000 + (seed >> 16) % 7_200_000);
        if (pick % 4 == 1) s.spendCapBps = uint16(100 + (seed >> 16) % 9_900);
        if (pick % 4 == 2) s.flatBps = uint16((seed >> 16) % 10_001);
        if (pick % 4 == 3) {
            s.climbBaseBps = uint16((seed >> 16) % 1_001);
            s.climbMaxBps = uint16(uint256(s.climbBaseBps) + (seed >> 32) % 1_000);
            s.climbDoubleEvery = uint32(1 hours + (seed >> 48) % 10 days);
        }
        // forge-lint: disable-end(unsafe-typecast)
        _setSettings(s);
    }

    function _sellOnTheHouse(uint256 seed) internal {
        uint256[] memory h = core.heldStatements();
        if (h.length == 0) return;
        uint256 sid = h[(seed >> 8) % h.length];
        if (_live(sid).status != Core.StatementStatus.Listed) return;
        _bid(funder, sid, _live(sid).reserve);
        _endAuction(sid);
        try core.collectSales() {} catch {}
        try core.syncStatement(sid) {} catch {}
    }

    function _try(uint256 op, uint256 seed) internal {
        if (op == 3) {
            _buyCoin(funder, 0.05 ether + seed % 0.5 ether);
        } else if (op == 4) {
            uint256[] memory ids = _credits(seller, 1);
            vm.prank(seller);
            try core.sellForEth(ids) {} catch {}
        } else if (op == 5) {
            vm.fee(composeBasefee);
            vm.prank(keeper);
            try core.compose() {} catch {}
        } else if (op == 6) {
            _sellOnTheHouse(seed);
        } else if (op == 7) {
            vm.deal(funder, funder.balance + 0.02 ether);
            vm.prank(funder);
            (bool ok,) = address(core).call{value: 0.02 ether}("");
            assertTrue(ok);
            core.skim();
        } else {
            _settingsWalk(seed);
        }
    }

    /// forge-config: default.fuzz.runs = 40
    function testFuzz_rateNeverRisesAcrossAnUnfundedInterval(uint256 seed) public {
        for (uint256 i; i < 14; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = seed % 9;
            bool unfunded = !core.funded();
            uint256 r0 = core.ethRate();
            if (op < 3) _warp(bound(seed >> 8, 1 minutes, 3 days));
            else _try(op, seed);
            if (unfunded) {
                assertLe(core.ethRate(), r0, "the rate rose across an interval that was unfunded at its start");
            }
            _solvent();
        }
    }
}
