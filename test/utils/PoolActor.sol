// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Mainnet} from "../../src/interfaces/Interfaces.sol";

/// @notice base for the test routers. it settles what the caller owes from the payer's wallet and sends what the
/// caller is owed to the receiver. the payer must approve the router for erc20 legs
abstract contract PoolActor is IUnlockCallback {
    IPoolManager internal constant PM = IPoolManager(Mainnet.POOL_MANAGER);

    error NotPoolManager();
    error EthRefundFailed();

    /// @dev pays a negative delta from the payer or takes a positive delta to the receiver
    function _resolve(Currency currency, int128 amount, address payer, address receiver) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                PM.settle{value: owed}();
            } else {
                PM.sync(currency);
                ERC20(Currency.unwrap(currency)).transferFrom(payer, address(PM), owed);
                PM.settle();
            }
        } else if (amount > 0) {
            PM.take(currency, receiver, uint256(uint128(amount)));
        }
    }

    /// @dev sends back the eth this call left over. eth that sat here before the call is not touched, because a
    /// contract created at a well known test address can already hold some on a fork
    function _refund(address to, uint256 balanceBefore) internal {
        uint256 left = address(this).balance - balanceBefore;
        if (left != 0) {
            (bool ok,) = to.call{value: left}("");
            if (!ok) revert EthRefundFailed();
        }
    }
}
