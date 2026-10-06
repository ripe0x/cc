// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Core} from "../../src/Core.sol";
import {IAuctionHouse} from "../../src/interfaces/AuctionHouse.sol";

/// a bidder that cannot receive statements and cannot receive eth, so an outbid refund to it is credited on the house.
/// it has no `onERC721Received`, no `receive` and no fallback
contract DeafBidder {
    function bid(IAuctionHouse house, uint256 auctionId) external payable {
        house.createBid{value: msg.value}(auctionId);
    }

    function pull(IAuctionHouse house, address payable to) external {
        house.withdrawRefundTo(to);
    }
}

/// bids on a statement auction and tries to re enter the core when it receives a statement or eth
contract ReentrantBidder {
    Core internal core;

    constructor(Core c) {
        core = c;
    }

    function bid(IAuctionHouse house, uint256 auctionId) external payable {
        house.createBid{value: msg.value}(auctionId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        core.skim();
        return this.onERC721Received.selector;
    }

    receive() external payable {
        try core.collectSales() {} catch {}
        try core.skim() {} catch {}
    }
}
