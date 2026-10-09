// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFeeRouter} from "../../src/interfaces/IFeeRouter.sol";

/// engines the fee router flushes into, for the router unit tests. attacker side doubles, not v2 contracts

/// takes eth and counts the calls
contract CountingEngine {
    uint256 public calls;
    uint256 public received;

    receive() external payable {
        ++calls;
        received += msg.value;
    }
}

/// refuses every eth transfer
contract RefusingEngine {
    receive() external payable {
        revert("no");
    }
}

/// calls `flush` again while the router flush is in flight, and forwards eth it gets in between back to the router so a
/// second send would be visible. records whether the nested flush reverted
contract ReenteringEngine {
    IFeeRouter public immutable ROUTER;
    bool public nestedReverted;
    bool public nestedDone;
    uint256 public received;
    uint256 public calls;

    constructor(IFeeRouter router_) {
        ROUTER = router_;
    }

    receive() external payable {
        ++calls;
        received += msg.value;
        if (nestedDone) return;
        nestedDone = true;
        // a donation lands in the router mid flush: a broken guard would send it out in the nested call
        (bool ok,) = address(ROUTER).call{value: 0}(abi.encodeCall(IFeeRouter.flush, (address(this))));
        nestedReverted = !ok;
    }
}

/// burns all gas it is given
contract GasBurnerEngine {
    uint256 public sink;

    receive() external payable {
        for (uint256 i; i < type(uint256).max; ++i) {
            sink = i;
        }
    }
}

/// a contract that calls `flush` and refuses the tip it is paid, and can pull a claim for itself
contract RefusingCaller {
    receive() external payable {
        revert("no tip");
    }

    function go(IFeeRouter r) external {
        r.flush(address(this));
    }
}

/// a payee that refuses eth until `open` is set, then takes it
contract GatePayee {
    bool public open;

    function setOpen(bool v) external {
        open = v;
    }

    receive() external payable {
        require(open, "closed");
    }
}
