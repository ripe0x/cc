// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InvariantsBase} from "./Invariants.t.sol";

/// phase 2: setUp has executed SetExitModule through the real timelock, with MockExitModule and MockExitToken. the
/// extra actions are sellForExitToken, composeExit, exitStatement, the dutch auction fill buybackExit (an actor buys
/// coin in the real pool, approves the core and fills), and a module switch that makes it underpay, fail its unit
/// read or change its unit. there is no exit pool. all invariants run again, with the exit token legs of 1, 4 and 5
/// live and the supply of invariant 9 falling by auction burns as well as buyback burns.
/// run it with `forge test --match-path test/invariant/InvariantsPhase2.t.sol -vv`. see Invariants.t.sol.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsPhase2 is InvariantsBase {
    function setUp() public virtual override {
        _build(true, false, true, false, "p2");
    }
}

/// the same suite for deep runs. no inline config, skipped unless INVARIANT_DEEP is set.
contract InvariantsPhase2Deep is InvariantsPhase2 {
    function setUp() public override {
        vm.skip(!vm.envOr("INVARIANT_DEEP", false));
        super.setUp();
    }
}

/// invariant 8 under attack. the controller is the fuzz controller in hostile mode for the whole run, in phase 2.
/// it answers `wants` out of range, reverts, returns short data or burns gas. it answers `nextPage` with ids that
/// are not in the pile, duplicates, zero ids, the other lane's pile, bad formats, a flag other than one, short
/// and long return data. it names overprints between statements the core does not hold, equal ids, mixed lanes.
/// every time it is asked it tries state changing calls into the core, the credits, the statements, the coin and the
/// pool manager. the core reads it with staticcall, so those calls cannot succeed. the handler also makes the
/// controller run its whole attack list outside a staticcall, as the controller's own account, and none may
/// succeed. every other invariant must keep holding under it.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
contract InvariantsHostileController is InvariantsBase {
    function setUp() public virtual override {
        _build(true, true, false, false, "hc");
    }
}

/// the same suite for deep runs. no inline config, skipped unless INVARIANT_DEEP is set.
contract InvariantsHostileControllerDeep is InvariantsHostileController {
    function setUp() public override {
        vm.skip(!vm.envOr("INVARIANT_DEEP", false));
        super.setUp();
    }
}
