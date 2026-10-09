// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// a fee router payee whose receive consumes all the gas it is given
contract GasBurningPayee {
    receive() external payable {
        assembly {
            invalid()
        }
    }
}

/// a seller whose receive consumes all gas when it is given the 50,000 gas of a router tip send and accepts the sale
/// payout, which carries all gas
contract BurningTipCaller {
    address public immutable CORE;

    constructor(address core_) {
        CORE = core_;
    }

    function sell(uint256[] calldata ids) external {
        (bool ok,) = CORE.call(abi.encodeWithSignature("sellForEth(uint256[])", ids));
        require(ok, "sell failed");
    }

    receive() external payable {
        if (gasleft() < 60_000) {
            assembly {
                invalid()
            }
        }
    }
}
