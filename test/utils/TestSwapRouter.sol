// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolActor} from "./PoolActor.sol";

/// @notice minimal swap router for tests. exact in and exact out, both directions, through the real pool manager.
/// negative `amountSpecified` is exact in and positive is exact out, as in the pool manager
contract TestSwapRouter is PoolActor {
    struct Job {
        address payer;
        address receiver;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    /// @notice swaps on behalf of the caller. eth sent along pays the eth legs and the unused part is refunded
    /// @return delta the caller delta the pool manager reported
    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, address receiver)
        external
        payable
        returns (BalanceDelta delta)
    {
        return _swap(key, zeroForOne, amountSpecified, receiver, "");
    }

    /// @notice the same with hook data, which is how a swap carries a referrer to the skim hook
    function swapWithData(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        address receiver,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        return _swap(key, zeroForOne, amountSpecified, receiver, hookData);
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, address receiver, bytes memory hookData)
        private
        returns (BalanceDelta delta)
    {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 balanceBefore = address(this).balance - msg.value;
        delta = abi.decode(
            PM.unlock(
                abi.encode(Job({payer: msg.sender, receiver: receiver, key: key, params: params, hookData: hookData}))
            ),
            (BalanceDelta)
        );
        _refund(msg.sender, balanceBefore);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(PM)) revert NotPoolManager();
        Job memory job = abi.decode(data, (Job));
        BalanceDelta delta = PM.swap(job.key, job.params, job.hookData);
        _resolve(job.key.currency0, delta.amount0(), job.payer, job.receiver);
        _resolve(job.key.currency1, delta.amount1(), job.payer, job.receiver);
        return abi.encode(delta);
    }

    receive() external payable {}
}
