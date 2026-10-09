// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {Lane} from "../src/interfaces/Interfaces.sol";

/// `CoreState` in src/lib/CoreLib.sol mirrors the state variables of the Core in declaration order, and the library
/// reaches the Core's storage through it. every field with a public getter is compared with the raw storage word the
/// mirror assumes, the mappings and the held list by the slot arithmetic the compiler uses
contract CoreLayoutTest is Fixture {
    uint256 internal constant S_PILES = 19;
    uint256 internal constant S_CREDITS = 20;
    uint256 internal constant S_STATEMENTS = 21;
    uint256 internal constant S_HELD = 22;

    /// the bytes `[offset, offset + size)` of storage slot `slot` of the core
    function _field(uint256 slot, uint256 offset, uint256 size) internal view returns (uint256) {
        uint256 word = uint256(vm.load(address(core), bytes32(slot)));
        if (size == 32) return word;
        return (word >> (offset * 8)) & ((1 << (size * 8)) - 1);
    }

    function _mapSlot(uint256 key, uint256 base) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key, base)));
    }

    function test_OK_scalarFieldsSitWhereTheMirrorSays() public {
        _enterPhase2();
        // the sale opens the hourly window on the pot it finds and spends the cost bases of the three credits in it
        _fundPot(3 ether);
        uint256[] memory sold = _credits(seller, 3);
        uint256 potBefore = core.ethPot();
        vm.prank(seller);
        core.sellForEth(sold);
        uint256 spent;
        for (uint256 i; i < 3; ++i) {
            (,, uint256 cost,) = core.creditInfo(sold[i]);
            spent += cost;
        }
        // xFunded is true: a large exit token balance is booked into the exit pot, which funds the bid
        xt.mint(address(core), 1_000_000_000e18);
        core.skim();
        vm.startPrank(owner);
        core.addTarget(address(0xA110C));
        vm.stopPrank();
        assertTrue(core.allowedTarget(address(0xA110C)), "setup: the target is allowed");
        assertEq(uint256(vm.load(address(core), keccak256(abi.encode(address(0xA110C), uint256(3))))), 1, "allowedTarget");
        assertEq(uint256(vm.load(address(core), keccak256(abi.encode(address(0xA110D), uint256(3))))), 0, "unset target");
        vm.prank(owner);
        core.transferOwnership(address(0xBEEF));
        vm.startPrank(owner);
        core.lockController();
        core.lockExitModule();
        core.lockTargets();
        core.setSuccessor(address(this));
        core.lockSuccessor();
        vm.stopPrank();

        assertEq(_field(0, 0, 20), uint256(uint160(core.controller())), "controller");
        assertEq(_field(0, 20, 1), core.controllerLocked() ? 1 : 0, "controllerLocked");
        assertEq(_field(0, 21, 1), core.exitModuleLocked() ? 1 : 0, "exitModuleLocked");
        assertEq(_field(0, 22, 1), core.targetsLocked() ? 1 : 0, "targetsLocked");
        assertEq(_field(1, 0, 20), uint256(uint160(core.exitModule())), "exitModule");
        assertEq(_field(2, 0, 20), uint256(uint160(core.exitToken())), "exitToken");
        assertEq(_field(4, 0, 20), uint256(uint160(core.owner())), "owner");
        assertEq(_field(5, 0, 20), uint256(uint160(core.pendingOwner())), "pendingOwner");
        assertEq(_field(6, 0, 32), core.ethPot(), "ethPot");
        assertEq(_field(7, 0, 32), core.ethToBuyback(), "ethToBuyback");
        assertEq(_field(8, 0, 32), core.xPot(), "xPot");
        assertEq(_field(9, 0, 32), core.xToBuyback(), "xToBuyback");
        assertEq(_field(10, 0, 32), core.rateAtCheckpoint(), "rateAtCheckpoint");
        assertEq(_field(11, 0, 8), core.checkpointTime(), "checkpointTime");
        assertEq(_field(11, 8, 8), core.lastFillTime(), "lastFillTime");
        assertEq(_field(11, 16, 8), block.timestamp, "windowStart");
        assertEq(_field(12, 0, 32), potBefore, "windowPot");
        assertEq(_field(13, 0, 32), spent, "windowSpent");
        assertEq(_field(15, 8, 1), 1, "xFunded is true");
        assertEq(_field(16, 0, 32), core.lastBuybackBlock(), "lastBuybackBlock");
        assertEq(_field(17, 0, 32), core.overprintDay(), "overprintDay");
        assertEq(_field(18, 0, 32), core.overprintCount(), "overprintCount");
        assertEq(_field(23, 0, 32), core.unitPerPoint(), "unitPerPoint");
        assertEq(_field(24, 0, 32), core.xStartPrice(), "xStartPrice");
        assertEq(_field(25, 0, 8), core.xStartTime(), "xStartTime");
        assertEq(_field(25, 8, 20), uint256(uint160(core.successor())), "successor");
        assertEq(_field(25, 28, 1), core.successorLocked() ? 1 : 0, "successorLocked");
        assertEq(core.successor(), address(this), "successor value");
        assertTrue(core.successorLocked(), "successorLocked value");
        assertTrue(core.controllerLocked() && core.exitModuleLocked() && core.targetsLocked(), "locks");
    }

    function test_OK_exitRateWordsSitWhereTheMirrorSays() public {
        _enterPhase2();
        // a fresh exit rate is stored by `setXRate`; the exit pot funds it, so `xRate()` reads the stored word
        vm.prank(owner);
        core.setXRate(4321);
        assertEq(_field(14, 0, 32), 4321, "xRateAtCheckpoint");
        assertEq(_field(15, 0, 8), block.timestamp, "xCheckpointTime");
        assertEq(_field(15, 8, 1), 0, "xFunded is false with an empty exit pot");
    }

    function test_OK_pilesCreditsAndStatementsSitWhereTheMirrorSays() public {
        uint256[] memory ids = _fillEthPile(5);
        // pile: head, tail, size
        uint256 pile = _mapSlot(uint256(uint8(Lane.Eth)), S_PILES);
        assertEq(uint256(vm.load(address(core), bytes32(pile))), core.pileHead(Lane.Eth), "pile head");
        assertEq(uint256(vm.load(address(core), bytes32(pile + 1))), ids[4], "pile tail");
        assertEq(uint256(vm.load(address(core), bytes32(pile + 2))), core.pileSize(Lane.Eth), "pile size");
        // credit: cost, prev, next, then acquiredAt | lane | inPile
        for (uint256 i; i < 5; ++i) {
            uint256 base = _mapSlot(ids[i], S_CREDITS);
            (bool inPile, Lane lane, uint256 cost, uint64 at) = core.creditInfo(ids[i]);
            assertEq(uint256(vm.load(address(core), bytes32(base))), cost, "credit cost");
            assertEq(uint256(vm.load(address(core), bytes32(base + 1))), i == 0 ? 0 : ids[i - 1], "credit prev");
            assertEq(uint256(vm.load(address(core), bytes32(base + 2))), core.pileNext(ids[i]), "credit next");
            uint256 word = uint256(vm.load(address(core), bytes32(base + 3)));
            assertEq(word & type(uint64).max, at, "credit acquiredAt");
            assertEq((word >> 64) & 0xff, uint256(uint8(lane)), "credit lane");
            assertEq((word >> 72) & 0xff, inPile ? 1 : 0, "credit inPile");
        }
        // statement: cost, auctionId, then listedAt | slot | lane | held | listed; the held list at S_HELD
        Composed memory c = _composeOnce();
        (bool held, Lane lane, uint256 cost, uint64 listedAt) = core.statementInfo(c.sid);
        uint256 sbase = _mapSlot(c.sid, S_STATEMENTS);
        assertEq(uint256(vm.load(address(core), bytes32(sbase))), cost, "statement cost");
        uint256 sword = uint256(vm.load(address(core), bytes32(sbase + 2)));
        assertEq(sword & type(uint64).max, listedAt, "statement listedAt");
        uint256[] memory held_ = core.heldStatements();
        uint256 at;
        for (uint256 i; i < held_.length; ++i) {
            if (held_[i] == c.sid) at = i;
        }
        assertEq((sword >> 64) & type(uint64).max, at, "statement slot");
        assertEq((sword >> 128) & 0xff, uint256(uint8(lane)), "statement lane");
        assertEq((sword >> 136) & 0xff, held ? 1 : 0, "statement held");
        assertEq((sword >> 144) & 0xff, 1, "statement listed");
        (, uint256 aid,,,) = core.statementStatus(c.sid);
        assertEq(uint256(vm.load(address(core), bytes32(sbase + 1))), aid, "statement auctionId");
        assertEq(uint256(vm.load(address(core), bytes32(S_HELD))), core.heldStatements().length, "held length");
        assertEq(
            uint256(vm.load(address(core), bytes32(uint256(keccak256(abi.encode(S_HELD)))))),
            c.sid,
            "first held id"
        );
        // a second statement sits at index 1 of the held list, so a wrong offset of `slot` cannot read as zero
        _fillEthPile(80);
        uint256 second = STATEMENTS.supply() + 1;
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sword2 = uint256(vm.load(address(core), bytes32(_mapSlot(second, S_STATEMENTS) + 2)));
        assertEq(core.heldStatements()[1], second, "the second statement is second in the list");
        assertEq((sword2 >> 64) & type(uint64).max, 1, "statement slot of the second statement");
    }
}
