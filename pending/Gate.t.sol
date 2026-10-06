// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {Lane, Mainnet, Econ} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {econ} from "./Econ.t.sol";

/// @notice the inventory gate. gate 5, so five eth lane statements held for sale close the eth bid. setUp composes
/// four statements: one below the gate. everything runs on the real stack of the Fixture
abstract contract GateBase is Fixture {
    uint256 internal constant GATE = 5;

    function _econ() internal pure virtual override returns (Econ memory) {
        return econ(40_000, 12_000, 1_000, GATE);
    }

    function setUp() public virtual override {
        super.setUp();
        _skipSniperWindow();
        for (uint256 i; i < GATE - 1; ++i) {
            _composeNext();
        }
        assertEq(core.ethHeld(), GATE - 1);
    }

    /// fills the eth pile to 80 and composes it, with a nonzero basefee so the reimbursement path runs too
    function _composeNext() internal returns (uint256 sid) {
        sid = STATEMENTS.supply() + 1;
        uint256 size = core.pileSize(Lane.Eth);
        if (size < 80) _fillEthPile(80 - size);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        assertEq(STATEMENTS.supply(), sid);
    }

    function _countEth() internal view returns (uint256 n) {
        uint256[] memory h = core.heldStatements();
        for (uint256 i; i < h.length; ++i) {
            (, Lane lane,,) = core.statementInfo(h[i]);
            if (lane == Lane.Eth) ++n;
        }
    }

    function _gated() internal view returns (bool) {
        return core.INVENTORY_GATE() != 0 && core.ethHeld() >= core.INVENTORY_GATE();
    }

    function _buy(uint256 sid) internal {
        uint256 price = core.priceOf(sid);
        address buyer = _user("statement buyer");
        vm.deal(buyer, price);
        vm.prank(buyer);
        core.buyStatement{value: price}(sid);
    }

    /// the rate after `dt` seconds at `bps` an hour from `r`, the way the core compounds a segment
    function _climbed(uint256 r, uint256 bps, uint256 dt) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 f = FixedPointMathLib.powWad(int256(1e18 + bps * 1e14), int256(dt * 1e18 / 1 hours));
        // forge-lint: disable-next-line(unsafe-typecast)
        return r * uint256(f) / 1e18;
    }

    function _sellOne() internal {
        uint256[] memory ids = _credits(seller, 1);
        _fundPot(core.ethPot() + 0.2 ether);
        vm.prank(seller);
        core.sellForEth(ids);
    }

    function _expectClosed() internal {
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        vm.expectRevert(Core.GateClosed.selector);
        core.sellForEth(ids);
        vm.prank(seller);
        vm.expectRevert(Core.GateClosed.selector);
        core.sellForEth(ids, 0);
        vm.prank(keeper);
        vm.expectRevert(Core.GateClosed.selector);
        core.buyListing(0, "", ids[0], Mainnet.SEAPORT);
    }
}

contract GateTest is GateBase {
    function test_belowTheGateTheBidIsOpen() public {
        assertEq(core.INVENTORY_GATE(), GATE);
        assertFalse(_gated());
        _sellOne();
        assertEq(core.ethHeld(), GATE - 1);
    }

    /// the bid closes at the threshold and not before: the fifth statement closes it
    function test_bidClosesAtTheThreshold() public {
        _fillEthPile(160);
        _composeNext();
        assertEq(core.ethHeld(), GATE);
        assertTrue(_gated());
        _expectClosed();
    }

    /// composing is never gated: a sixth and a seventh statement compose while the bid is closed
    function test_composeIsNeverGated() public {
        _fillEthPile(240);
        _composeNext();
        _composeNext();
        _composeNext();
        assertEq(core.ethHeld(), GATE + 2);
        _expectClosed();
        assertEq(core.heldStatements().length, GATE + 2);
    }

    /// a statement sale at the threshold reopens the bid, and one above it does not
    function test_saleReopensTheBid() public {
        _fillEthPile(160);
        uint256 s5 = _composeNext();
        uint256 s6 = _composeNext();
        assertEq(core.ethHeld(), GATE + 1);
        _buy(s5);
        assertEq(core.ethHeld(), GATE);
        _expectClosed();
        _buy(s6);
        assertEq(core.ethHeld(), GATE - 1);
        assertFalse(_gated());
        _sellOne();
    }

    /// an exit of an eth lane statement reopens the bid
    function test_exitReopensTheBid() public {
        _fillEthPile(80);
        uint256 s5 = _composeNext();
        assertTrue(_gated());
        _enterPhase2();
        _expectClosed();
        core.exitStatement(s5);
        assertEq(core.ethHeld(), GATE - 1);
        assertFalse(_gated());
        _sellOne();
    }

    /// an overprint of two eth lane statements reopens the bid. the base stays, the top goes
    function test_overprintReopensTheBid() public {
        _fillEthPile(160);
        uint256 s5 = _composeNext();
        uint256 s6 = _composeNext();
        uint256[] memory h = core.heldStatements();
        assertEq(h.length, GATE + 1);
        ScriptedController scripted = new ScriptedController();
        _timelock(Core.Action.SetController, abi.encode(address(scripted)));
        scripted.setOverprint(true, s5, s6);
        core.overprint();
        assertEq(core.ethHeld(), GATE);
        assertTrue(_gated());
        scripted.setOverprint(true, h[0], s5);
        core.overprint();
        assertEq(core.ethHeld(), GATE - 1);
        assertFalse(_gated());
        assertEq(core.heldStatements().length, GATE - 1);
        _sellOne();
    }

    /// the counter follows the held list on every path: it equals the number of held eth lane statements
    function test_counterEqualsTheHeldEthLaneStatements() public {
        _fillEthPile(160);
        uint256 s5 = _composeNext();
        _composeNext();
        _buy(s5);
        assertEq(core.ethHeld(), _countEth());
        assertEq(core.ethHeld(), GATE);
    }

    /// the exit token lane is never gated, and exit lane statements never move the counter
    function test_exitLaneIsNeverGated() public {
        _fillEthPile(80);
        _composeNext();
        assertTrue(_gated());
        _enterPhase2();
        xt.mint(address(core), 1_000_000e18);
        core.skim();
        uint256[] memory ids = _credits(seller, 80);
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.prank(keeper);
        core.composeExit();
        assertEq(core.ethHeld(), GATE, "an exit lane statement is not counted");
        uint256[] memory h = core.heldStatements();
        uint256 sid = h[h.length - 1];
        core.exitStatement(sid);
        assertEq(core.ethHeld(), GATE, "its exit does not move the counter");
        assertTrue(_gated());
        _expectClosed();
    }

    /// no climb is credited while gated, with exact numbers. five hours of climb before the closing compose are
    /// credited at 100 bps an hour, ten days gated credit nothing, and after the reopening the climb restarts at the
    /// reopening time on the tier of the time since the last fill (800 bps an hour after ten days)
    function test_noClimbWhileGatedExactNumbers() public {
        _fillEthPile(80);
        assertTrue(core.funded());
        uint256 r0 = core.rateAtCheckpoint();
        uint256 t0 = core.checkpointTime();
        assertLt(block.timestamp - core.lastFillTime(), 1 hours, "inside the first tier");
        _warp(5 hours);
        uint256 want = _climbed(r0, 100, block.timestamp - t0);
        assertEq(core.ethRate(), want, "five hours credited before the gate");
        uint256 s5 = _composeNext();
        assertTrue(_gated());
        assertEq(core.rateAtCheckpoint(), want, "the climb up to the crossing was credited");
        assertEq(core.checkpointTime(), block.timestamp);
        uint256 cap = core.ethPot() * 2000 / core.AVG_SCORE();
        assertLt(want, cap, "there was room to climb");
        // ten days gated: the rate holds exactly, fees keep booking and the pot grows
        uint256 pot = core.ethPot();
        _warp(5 days);
        assertEq(core.ethRate(), want);
        _buyCoin(funder, 1 ether);
        assertGt(core.ethPot(), pot);
        assertEq(core.ethRate(), want, "a fee while gated does not move the rate");
        _warp(5 days);
        assertEq(core.ethRate(), want);
        _expectClosed();
        // the reopening sale checkpoints at that time and the climb restarts from there
        _buy(s5);
        assertFalse(_gated());
        assertEq(core.rateAtCheckpoint(), want, "nothing was credited for the gated days");
        assertEq(core.checkpointTime(), block.timestamp);
        _warp(1 hours);
        assertEq(core.ethRate(), _climbed(want, 800, 1 hours), "800 bps an hour after ten days without a fill");
        assertLt(core.ethRate(), core.ethPot() * 2000 / core.AVG_SCORE());
    }
}

/// @notice with the gate off (0, the default) nothing changes however many statements are held
contract GateOffTest is Fixture {
    function _composeNext() internal returns (uint256 sid) {
        sid = STATEMENTS.supply() + 1;
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
    }

    function test_gateZeroNeverClosesTheBidNorStopsTheClimb() public {
        _skipSniperWindow();
        assertEq(core.INVENTORY_GATE(), 0);
        for (uint256 i; i < 6; ++i) {
            _composeNext();
        }
        assertEq(core.ethHeld(), 6, "the counter still counts");
        // the bid is open at six statements
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        core.sellForEth(ids);
        // and the rate climbs as for any funded core: the first tier, ten hours, from the stored checkpoint
        assertTrue(core.funded());
        uint256 r0 = core.rateAtCheckpoint();
        uint256 t0 = core.checkpointTime();
        _warp(10 hours);
        uint256 dt = block.timestamp - t0;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 f = FixedPointMathLib.powWad(1.01e18, int256(dt * 1e18 / 1 hours));
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(core.ethRate(), r0 * uint256(f) / 1e18);
        assertGt(core.ethRate(), r0);
        // a statement sale and the next sell go through as before
        uint256[] memory h = core.heldStatements();
        uint256 price = core.priceOf(h[0]);
        vm.deal(address(this), price);
        core.buyStatement{value: price}(h[0]);
        assertEq(core.ethHeld(), 5);
        ids = _credits(seller, 1);
        vm.prank(seller);
        core.sellForEth(ids);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @notice a random walk over the doors, the clock and the fees. every step checks that the rate never rose across
/// an interval that was gated or unfunded at its start, that the bid is closed exactly while gated, and that the
/// counter equals the held eth lane statements
contract GateFuzzTest is GateBase {
    function setUp() public override {
        super.setUp();
        _fillEthPile(80);
    }

    function _try(uint256 op, uint256 seed) internal {
        bool closed = _gated();
        if (op == 3) {
            _buyCoin(funder, 0.05 ether + seed % 0.5 ether);
        } else if (op == 4) {
            uint256[] memory ids = _credits(seller, 1);
            vm.prank(seller);
            try core.sellForEth(ids) {
                assertFalse(closed, "sold into a closed bid");
            } catch (bytes memory why) {
                assertEq(closed, bytes4(why) == Core.GateClosed.selector, "closed exactly while gated");
            }
        } else if (op == 5) {
            vm.fee(composeBasefee);
            vm.prank(keeper);
            try core.compose() {} catch {}
        } else if (op == 6) {
            uint256[] memory h = core.heldStatements();
            if (h.length == 0) return;
            uint256 sid = h[(seed >> 8) % h.length];
            (, Lane lane,,) = core.statementInfo(sid);
            if (lane == Lane.Eth) _buy(sid);
        } else {
            vm.deal(funder, funder.balance + 0.02 ether);
            vm.prank(funder);
            (bool ok,) = address(core).call{value: 0.02 ether}("");
            assertTrue(ok);
            core.skim();
        }
    }

    /// forge-config: default.fuzz.runs = 40
    function testFuzz_rateNeverRisesAcrossAGatedOrUnfundedInterval(uint256 seed) public {
        for (uint256 i; i < 14; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = seed % 8;
            bool still = !core.funded() || _gated();
            uint256 r0 = core.ethRate();
            if (op < 3) _warp(bound(seed >> 8, 1 minutes, 3 days));
            else _try(op, seed);
            if (still) assertLe(core.ethRate(), r0, "the rate rose across a gated or unfunded interval");
            assertEq(core.ethHeld(), _countEth(), "counter equals the held eth lane statements");
        }
    }
}
