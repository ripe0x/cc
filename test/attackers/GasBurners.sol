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

/// a contract that sells credits to the Core and accepts the payout
contract ContractSeller {
    address public immutable CORE;

    constructor(address core_) {
        CORE = core_;
    }

    function sell(uint256[] calldata ids) external {
        (bool ok,) = CORE.call(abi.encodeWithSignature("sellForEth(uint256[])", ids));
        require(ok, "sell failed");
    }

    receive() external payable {}
}
