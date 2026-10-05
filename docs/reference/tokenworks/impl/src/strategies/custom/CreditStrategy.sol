// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {NFTStrategy} from "../NFTStrategy.sol";

/// @title CreditStrategy - A custom NFTStrategy for Credits
/// @author TokenWorks (https://token.works/)
contract CreditStrategy is NFTStrategy {
    /// @notice Sets the maximum buy price increment per block.
    /// @dev Only callable by the owner. Preserves lastBuyBlock.
    /// @param _buyIncrement The new buy increment in wei.
    function setBuyIncrement(uint256 _buyIncrement) external onlyOwner {
        require(_buyIncrement > 0, "Invalid buy increment");
        buyIncrement = _buyIncrement;
    }
}
