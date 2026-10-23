// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IRedeemer} from "../interfaces/Interfaces.sol";

/// redeemer 1 of treasury v2, the phase 2 plan: a burn of `ccIn` out of `ccSupply` is paid `ccIn * bucket / ccSupply`
/// less `feeBps`, at once. stateless; the fee stays in the bucket because the treasury subtracts only the payout. a new
/// fee is a new redeemer
contract ProRataRedeemer is IRedeemer {
    uint256 private constant BPS = 10_000;

    uint16 public immutable feeBps;

    error BadFee();

    constructor(uint16 feeBps_) {
        if (feeBps_ > BPS) revert BadFee();
        feeBps = feeBps_;
    }

    function quote(address, uint256 ccIn, uint256 bucket, uint256 ccSupply, bytes calldata)
        external
        view
        override
        returns (uint256 amount, uint8 mode, uint32 duration)
    {
        amount = FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(ccIn, bucket, ccSupply), BPS - feeBps, BPS);
        return (amount, 0, 0);
    }
}
