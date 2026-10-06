// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// our own minimal view of the live pnd auction house (v2, factory 0x77aB853543286C9Cdd7dd6c01222A7cC4Ac93d63). only the
/// calls this repo makes. the field order of `Auction` and every selector were checked against the live contracts on a
/// mainnet fork. the verified source is kept for reference under docs/reference/pnd and is not compiled here
interface IAuctionFactory {
    /// deploys a house owned forever by the caller. one per address
    function createAuctionHouse() external returns (address house);
    function houseOf(address owner) external view returns (address);
    function predictHouseAddress(address owner) external view returns (address);
    function defaultProtocolFeeBps() external view returns (uint16);
}

interface IAuctionHouse {
    // the house reverts with these. declared so callers and tests can name the selectors
    error AuctionDoesNotExist();
    error AuctionAlreadyStarted();
    error AuctionExpired();
    error AuctionNotEnded();
    error AuctionHasNoBids();
    error BidBelowReserve();
    error BidBelowMinimum();
    error BidMustBePositive();
    error AuctionAlreadySettled();
    error UnwindTooEarly();
    error NoPendingDelivery();

    struct Auction {
        uint256 tokenId;
        address tokenContract;
        uint64 firstBidTime;
        uint256 amount;
        uint256 reservePrice;
        address tokenOwner;
        address payable fundsRecipient;
        uint64 endTime;
        address payable bidder;
        uint64 duration;
        uint256 quantity;
        uint8 standard;
    }

    function owner() external view returns (address);
    function protocolFeeBps() external view returns (uint16);
    function createAuction(
        uint256 tokenId,
        address tokenContract,
        uint256 duration,
        uint256 reservePrice,
        uint64 listingExpiry
    ) external returns (uint256 auctionId);
    function cancelAuction(uint256 auctionId) external;
    function setAuctionReservePrice(uint256 auctionId, uint256 reservePrice) external;
    function setAuctionDuration(uint256 auctionId, uint256 duration) external;
    function createBid(uint256 auctionId) external payable;
    function endAuction(uint256 auctionId) external;
    function unwindStuckLot(uint256 auctionId) external;
    function claimLot(uint256 auctionId, address to) external;
    function returnUnwoundLot(uint256 auctionId) external;
    function withdrawRefund() external;
    function withdrawRefundTo(address payable recipient) external;
    function pendingRefunds(address who) external view returns (uint256);
    function pendingDelivery(uint256 auctionId) external view returns (bool);
    function pendingReturn(uint256 auctionId) external view returns (bool);
    function getAuction(uint256 auctionId) external view returns (Auction memory);
    function getAuctionFor(address tokenContract, uint256 tokenId)
        external
        view
        returns (bool exists, uint256 auctionId);
}
