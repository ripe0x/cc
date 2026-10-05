// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICredits, ICoreFees, Mainnet} from "../../src/interfaces/Interfaces.sol";

/// a listing for tests. sells a credit it holds for an exact price, optionally refunding part of the payment,
/// and keeps the rest. the refund arrives at the buyer while the buy is still in flight. it can also act as the
/// hook of a core and call addFees mid fill.
contract MockSeller {
    uint256 public refund;
    address public feeder;
    address public feeCore;
    uint256 public feeAmount;

    /// sets how much of each payment is sent straight back to the buyer.
    function setRefund(uint256 amount) external {
        refund = amount;
    }

    /// sets a feeder, another instance of this contract that a core treats as its hook, to call addFees on a core
    /// during fill, with the amount to send.
    function setFee(address feeder_, address core, uint256 amount) external {
        feeder = feeder_;
        feeCore = core;
        feeAmount = amount;
    }

    /// forwards eth into addFees of a core that treats this contract as its hook.
    function feed(address core, uint256 amount) external {
        ICoreFees(core).addFees{value: amount}();
    }

    /// transfers credit id to the caller, refunds part of the payment and optionally calls addFees.
    function fill(uint256 id, uint256 price) external payable {
        require(msg.value == price, "price");
        ICredits(Mainnet.CREDITS).transferFrom(address(this), msg.sender, id);
        if (feeAmount != 0) MockSeller(payable(feeder)).feed(feeCore, feeAmount);
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund");
        }
    }

    receive() external payable {}
}
