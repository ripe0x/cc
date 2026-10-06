// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

/// @title Sovereign Auction House V2 interface
/// @notice ETH reserve auctions for ERC721 and ERC1155 tokens. Settlement
///         pays the seller only after the winner's delivery is verified.
///         Delivery is attempted with a fixed gas stipend; on failure,
///         neither the seller nor the protocol fee is paid, and both the
///         winning bid and the lot stay escrowed for a permissionless retry
///         via claimLot. If the lot is still undelivered
///         PENDING_DELIVERY_TIMEOUT after deferral, unwindStuckLot retries
///         delivery once more and, on a second failure, unwinds the sale:
///         the winner's bid is credited to pendingRefunds for withdrawal and
///         the lot is returned to the seller. If that return also fails, the
///         lot stays locked until returnUnwoundLot succeeds.
interface ISovereignAuctionHouseV2 {
    enum TokenStandard {
        ERC721,
        ERC1155
    }

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
        TokenStandard standard;
    }

    event AuctionCreated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        uint256 duration,
        uint256 reservePrice,
        address tokenOwner,
        address fundsRecipient,
        uint64 listingExpiry
    );
    event Auction1155Created(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        uint256 quantity,
        uint256 duration,
        uint256 reservePrice,
        address tokenOwner,
        address fundsRecipient,
        uint64 listingExpiry
    );
    event AuctionReservePriceUpdated(uint256 indexed auctionId, uint256 reservePrice);
    event AuctionDurationUpdated(uint256 indexed auctionId, uint256 duration);
    event AuctionFundsRecipientUpdated(uint256 indexed auctionId, address fundsRecipient);
    event AuctionListingExpiryUpdated(uint256 indexed auctionId, uint64 listingExpiry);
    event AuctionBid(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount,
        bool firstBid,
        bool extended
    );
    event AuctionEndTimeUpdated(uint256 indexed auctionId, uint64 newEndTime);
    event AuctionEnded(
        uint256 indexed auctionId,
        address tokenOwner,
        address winner,
        uint256 sellerProceeds,
        uint256 protocolFee
    );
    /// @notice Emitted when the token transfer attempted during endAuction
    ///         fails. Neither the seller nor the protocol fee has been paid;
    ///         the winning bid stays escrowed. The lot is retryable by
    ///         anyone via claimLot.
    event DeliveryDeferred(uint256 indexed auctionId, address indexed winner);
    /// @notice Emitted when claimLot or unwindStuckLot delivers a deferred
    ///         lot to the winner. Settlement (state cleanup and the seller
    ///         and protocol fee payout) happens in the same call.
    event LotClaimed(uint256 indexed auctionId, address indexed winner, address recipient);
    /// @notice Emitted when unwindStuckLot's retry to the winner still fails
    ///         PENDING_DELIVERY_TIMEOUT after deferral and the sale unwinds:
    ///         `refundAmount`, the winner's full bid, is credited to
    ///         pendingRefunds for withdrawal. Neither the seller nor the
    ///         protocol was ever paid on this auction. If the same call also
    ///         succeeds at returning the lot to `tokenOwner`, no further
    ///         event follows; if that return fails, LotReturnDeferred is
    ///         emitted alongside this one.
    event LotUnwound(uint256 indexed auctionId, address indexed winner, uint256 refundAmount, address tokenOwner);
    /// @notice Emitted alongside LotUnwound when the attempt to return the
    ///         lot to `tokenOwner` fails. The lot stays locked until
    ///         returnUnwoundLot succeeds.
    event LotReturnDeferred(uint256 indexed auctionId, address indexed tokenOwner);
    /// @notice Emitted when returnUnwoundLot delivers a previously deferred
    ///         return to `tokenOwner`.
    event LotReturned(uint256 indexed auctionId, address indexed tokenOwner);
    event AuctionCanceled(uint256 indexed auctionId);
    event RefundCredited(address indexed to, uint256 amount);
    event RefundWithdrawn(address indexed account, address indexed recipient, uint256 amount);
    event StuckERC721Recovered(address indexed tokenContract, uint256 indexed tokenId, address to);
    event StuckERC1155Recovered(address indexed tokenContract, uint256 indexed tokenId, uint256 quantity, address to);

    /// @notice Lists an ERC721 for auction. The house owner may list a
    ///         third party's token (consignment): `tokenOwner` is read from
    ///         the token itself and proceeds go to that owner's
    ///         `fundsRecipient`, not the house owner. `listingExpiry_` sets
    ///         the no-bid close date for the listing: 0 means no expiry, a
    ///         nonzero value must be strictly in the future and is stored
    ///         in `listingExpiry`. A bid placed before the expiry starts the
    ///         normal auction clock and the expiry no longer applies;
    ///         `createBid` only checks it while `firstBidTime` is unset. The
    ///         token owner can still change or clear it pre-bid via
    ///         `setAuctionListingExpiry`, or cancel entirely via
    ///         `cancelAuction`.
    function createAuction(
        uint256 tokenId,
        address tokenContract,
        uint256 duration,
        uint256 reservePrice,
        uint64 listingExpiry_
    ) external returns (uint256 auctionId);

    function create1155Auction(
        uint256 tokenId,
        address tokenContract,
        uint256 quantity,
        uint256 duration,
        uint256 reservePrice,
        uint64 listingExpiry_
    ) external returns (uint256 auctionId);

    /// @notice Returns the full auction record as a struct. The mapping's
    ///         auto-generated getter returns the same data as a flat tuple;
    ///         this exists so callers that need the whole record can decode
    ///         one struct instead of the full field list.
    function getAuction(uint256 auctionId) external view returns (Auction memory);

    function createBid(uint256 auctionId) external payable;

    /// @notice Settle a finished auction. Attempts token delivery to the
    ///         winner with a fixed gas stipend so the outcome cannot depend
    ///         on caller-supplied gas. The protocol fee and seller are paid
    ///         only if that delivery succeeds. On delivery failure nobody is
    ///         paid; the lot is deferred to claimLot instead. Reverts if the
    ///         auction is already settled or unwound, or with
    ///         InsufficientGas when called without enough gas to honor the
    ///         delivery stipend.
    function endAuction(uint256 auctionId) external;
    function cancelAuction(uint256 auctionId) external;
    function setAuctionReservePrice(uint256 auctionId, uint256 reservePrice) external;
    function setAuctionDuration(uint256 auctionId, uint256 duration) external;
    function setAuctionFundsRecipient(uint256 auctionId, address payable fundsRecipient) external;
    function setAuctionListingExpiry(uint256 auctionId, uint64 expiry) external;
    function expireAuction(uint256 auctionId) external;
    function withdrawRefund() external;
    function withdrawRefundTo(address payable recipient) external;

    /// @notice Claims a lot whose delivery was deferred at settlement.
    ///         Anyone may call this with `to == address(0)` to trigger
    ///         delivery to the recorded winner; only that winner may redirect
    ///         delivery elsewhere via a nonzero `to`. Reverts if the auction
    ///         has no deferred delivery, or if a non-winner passes a nonzero
    ///         `to`. A revert during delivery reverts the whole call, leaving
    ///         the claim retryable. Settlement (state cleanup and the seller
    ///         and protocol fee payout) happens in this call, after delivery
    ///         succeeds. The redirect is best-effort: the pending state is
    ///         consumed by whichever call succeeds first, so a third party
    ///         triggering delivery to the winner with `to == address(0)`
    ///         before the winner redirects permanently forecloses that
    ///         redirect. The token always still reaches the winner's own bid
    ///         address in that case.
    function claimLot(uint256 auctionId, address to) external;

    /// @notice Resolves a lot still pending delivery PENDING_DELIVERY_TIMEOUT
    ///         after deferral. Anyone may call this. It first retries
    ///         delivery to the recorded winner; if that succeeds, the sale
    ///         finalizes normally and the seller is paid. If it fails again,
    ///         the sale unwinds: the winner's full bid is credited to
    ///         pendingRefunds and the lot is returned to the seller. If that
    ///         return also fails, the lot stays locked until
    ///         returnUnwoundLot succeeds.
    function unwindStuckLot(uint256 auctionId) external;

    /// @notice Delivers a lot whose return to the seller failed during
    ///         unwindStuckLot. Anyone may call this; it only ever delivers to
    ///         the auction's recorded tokenOwner. Reverts if the auction has
    ///         no deferred return.
    function returnUnwoundLot(uint256 auctionId) external;
}
