// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICredits, Mainnet} from "../../src/interfaces/Interfaces.sol";

/// a small credit marketplace for tests. a seller lists a credit it owns at an exact price, anyone fills the listing
/// by paying that price, and the seller gets the whole price at once. no fees, no refunds, no signatures.
contract MockMarket {
    struct Listing {
        address seller;
        uint256 price;
    }

    mapping(uint256 => Listing) public listings;

    /// pulls credit id from the caller, who must have approved this contract, and lists it at `price`.
    function list(uint256 id, uint256 price) external {
        ICredits(Mainnet.CREDITS).transferFrom(msg.sender, address(this), id);
        listings[id] = Listing({seller: msg.sender, price: price});
    }

    /// fills a listing. msg.value must equal the price exactly. the credit goes to the caller, the price to the seller.
    function fill(uint256 id) external payable {
        Listing memory l = listings[id];
        require(l.seller != address(0), "not listed");
        require(msg.value == l.price, "price");
        delete listings[id];
        ICredits(Mainnet.CREDITS).transferFrom(address(this), msg.sender, id);
        (bool ok,) = l.seller.call{value: l.price}("");
        require(ok, "pay");
    }
}
