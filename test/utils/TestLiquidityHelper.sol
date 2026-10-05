// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolActor} from "./PoolActor.sol";

/// @notice minimal liquidity helper for tests. positions are keyed by the caller through the salt
contract TestLiquidityHelper is PoolActor {
    struct Job {
        address payer;
        PoolKey key;
        ModifyLiquidityParams params;
    }

    /// @notice adds (positive) or removes (negative) liquidity for the caller. the caller pays and is paid directly
    /// @return delta the caller delta the pool manager reported
    function modify(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        payable
        returns (BalanceDelta delta)
    {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: bytes32(uint256(uint160(msg.sender)))
        });
        uint256 balanceBefore = address(this).balance - msg.value;
        delta = abi.decode(PM.unlock(abi.encode(Job({payer: msg.sender, key: key, params: params}))), (BalanceDelta));
        _refund(msg.sender, balanceBefore);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(PM)) revert NotPoolManager();
        Job memory job = abi.decode(data, (Job));
        (BalanceDelta delta,) = PM.modifyLiquidity(job.key, job.params, "");
        _resolve(job.key.currency0, delta.amount0(), job.payer, job.payer);
        _resolve(job.key.currency1, delta.amount1(), job.payer, job.payer);
        return abi.encode(delta);
    }

    receive() external payable {}
}
