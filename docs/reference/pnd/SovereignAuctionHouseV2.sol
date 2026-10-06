// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

import {ISovereignAuctionHouseV2} from "./ISovereignAuctionHouseV2.sol";

/// @title Sovereign Auction House V2
/// @notice ERC721 and ERC1155 reserve auctions. Settlement pays the seller
///         only after the winner provably holds the lot: endAuction attempts
///         delivery through a try/catch self-call capped at a fixed gas
///         stipend, and pays the protocol fee and seller only if that
///         delivery succeeds. A failed delivery pays nobody; both the ETH and
///         the lot stay escrowed and the delivery is retryable by anyone
///         through claimLot. If the lot is still undelivered
///         PENDING_DELIVERY_TIMEOUT after deferral, unwindStuckLot retries
///         delivery once more and, on a second failure, unwinds the sale:
///         the winner's bid is credited to pendingRefunds for withdrawal and
///         the lot is returned to the seller. If that return also fails, the
///         lot stays locked until returnUnwoundLot succeeds. The token
///         transfer is always the last external interaction before any
///         payout takes effect, so no seller-controlled callback can run
///         after the lot has moved and before the seller is paid. V1 clones
///         are immutable and remain governed by their original
///         implementation.
contract SovereignAuctionHouseV2 is
    ISovereignAuctionHouseV2,
    IERC1155Receiver,
    Initializable,
    ReentrancyGuard,
    OwnableUpgradeable
{
    bytes4 private constant ERC721_INTERFACE_ID = 0x80ac58cd;
    bytes4 private constant ERC1155_INTERFACE_ID = 0xd9b67a26;

    uint256 public constant TIME_BUFFER = 15 minutes;
    uint16 public constant MIN_BID_INCREMENT_BPS = 500;
    uint256 public constant MAX_DURATION = 365 days * 100;

    error AuctionDoesNotExist();
    error AuctionAlreadyStarted();
    error AuctionExpired();
    error AuctionNotEnded();
    error AuctionHasNoBids();
    error AuctionAlreadyExistsForToken();
    error BidBelowReserve();
    error BidBelowMinimum();
    error BidMustBePositive();
    error EscrowFailed();
    error DeliveryFailed();
    error FundsRecipientRequired();
    error OnlySelf();
    error OwnershipLocked();
    error AuctionAlreadySettled();
    error NoPendingDelivery();
    error NoPendingReturn();
    error NotWinner();
    error InsufficientGas();
    error UnwindTooEarly();

    uint256 internal constant DELIVER_GAS_LIMIT = 500_000;

    /// @notice A deferred lot still undelivered after this timeout becomes
    ///         eligible for unwindStuckLot, which retries delivery once more
    ///         and, if that also fails, unwinds the sale.
    uint64 public constant PENDING_DELIVERY_TIMEOUT = 30 days;

    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => uint64) public listingExpiry;

    /// @notice True for an auction whose delivery attempt at endAuction
    ///         failed. Neither the seller nor the protocol fee has been
    ///         paid. The auction record, and its `_auctionIdByToken` entry,
    ///         stay in storage until claimLot or unwindStuckLot resolves it.
    mapping(uint256 => bool) public pendingDelivery;

    /// @notice Timestamp a lot entered pendingDelivery, keyed by auctionId.
    ///         Set in endAuction's deferral branch; read by unwindStuckLot to
    ///         enforce PENDING_DELIVERY_TIMEOUT.
    mapping(uint256 => uint64) public deliveryDeferredAt;

    /// @notice True for an auction that unwindStuckLot unwound but whose lot
    ///         return to the seller failed. The winner's bid is already
    ///         credited to pendingRefunds; the auction record and its
    ///         `_auctionIdByToken` entry stay in storage, locking the lot,
    ///         until returnUnwoundLot delivers it to the seller.
    mapping(uint256 => bool) public pendingReturn;

    // A settled-but-undelivered lot keeps its entry here, which blocks a
    // duplicate listing and stuck-token recovery for the same token until
    // claimLot, unwindStuckLot, or returnUnwoundLot clears it.
    mapping(address => mapping(uint256 => uint256)) private _auctionIdByToken;
    mapping(address => uint256) public pendingRefunds;

    uint16 public protocolFeeBps;
    address payable public feeRecipient;
    uint256 private _nextAuctionId;

    // A safe ERC1155 transfer invokes the receiver. Bind that callback to the
    // exact pull underway so an unrelated token cannot be sent into custody.
    address private _pull1155Token;
    uint256 private _pull1155Id;
    uint256 private _pull1155Quantity;

    modifier auctionExists(uint256 auctionId) {
        if (!_exists(auctionId)) revert AuctionDoesNotExist();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address payable feeRecipient_,
        uint16 protocolFeeBps_
    ) external initializer {
        require(initialOwner != address(0), "owner required");
        require(protocolFeeBps_ <= 500, "fee above cap");
        require(
            protocolFeeBps_ == 0 || feeRecipient_ != address(0),
            "fee recipient required when fee > 0"
        );
        __Ownable_init(initialOwner);
        feeRecipient = feeRecipient_;
        protocolFeeBps = protocolFeeBps_;
    }

    function transferOwnership(address) public pure override {
        revert OwnershipLocked();
    }

    function renounceOwnership() public pure override {
        revert OwnershipLocked();
    }

    function createAuction(
        uint256 tokenId,
        address tokenContract,
        uint256 duration,
        uint256 reservePrice,
        uint64 listingExpiry_
    ) external override nonReentrant onlyOwner returns (uint256) {
        return _createAuction(tokenId, tokenContract, duration, reservePrice, listingExpiry_);
    }

    /// @notice One listingExpiry_ applies to every auction created in the batch.
    function bulkCreateAuctions(
        address tokenContract,
        uint256[] calldata tokenIds,
        uint256 reservePrice,
        uint256 duration,
        uint64 listingExpiry_
    ) external nonReentrant onlyOwner returns (uint256[] memory auctionIds) {
        auctionIds = new uint256[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            auctionIds[i] = _createAuction(tokenIds[i], tokenContract, duration, reservePrice, listingExpiry_);
        }
    }

    function _createAuction(
        uint256 tokenId,
        address tokenContract,
        uint256 duration,
        uint256 reservePrice,
        uint64 listingExpiry_
    ) internal returns (uint256 auctionId) {
        require(IERC165(tokenContract).supportsInterface(ERC721_INTERFACE_ID), "tokenContract is not ERC721");
        _validateDuration(duration);
        require(listingExpiry_ == 0 || listingExpiry_ > block.timestamp, "expiry must be future");
        if (_auctionIdByToken[tokenContract][tokenId] != 0) revert AuctionAlreadyExistsForToken();

        address tokenOwner = IERC721(tokenContract).ownerOf(tokenId);
        require(
            msg.sender == tokenOwner ||
                msg.sender == IERC721(tokenContract).getApproved(tokenId) ||
                IERC721(tokenContract).isApprovedForAll(tokenOwner, msg.sender),
            "Not token owner or approved"
        );

        auctionId = _nextAuctionId++;
        auctions[auctionId] = Auction({
            tokenId: tokenId,
            tokenContract: tokenContract,
            firstBidTime: 0,
            amount: 0,
            reservePrice: reservePrice,
            tokenOwner: tokenOwner,
            fundsRecipient: payable(tokenOwner),
            endTime: 0,
            bidder: payable(address(0)),
            duration: uint64(duration),
            quantity: 1,
            standard: TokenStandard.ERC721
        });
        _auctionIdByToken[tokenContract][tokenId] = auctionId + 1;
        if (listingExpiry_ != 0) listingExpiry[auctionId] = listingExpiry_;

        IERC721(tokenContract).transferFrom(tokenOwner, address(this), tokenId);
        if (IERC721(tokenContract).ownerOf(tokenId) != address(this)) revert EscrowFailed();

        emit AuctionCreated(
            auctionId,
            tokenId,
            tokenContract,
            duration,
            reservePrice,
            tokenOwner,
            tokenOwner,
            listingExpiry_
        );
    }

    /// @notice Escrows one indivisible ERC1155 lot. Unlike ERC721, ERC1155
    ///         has no ownerOf, so only this house's owner may list its balance.
    function create1155Auction(
        uint256 tokenId,
        address tokenContract,
        uint256 quantity,
        uint256 duration,
        uint256 reservePrice,
        uint64 listingExpiry_
    ) external override onlyOwner nonReentrant returns (uint256 auctionId) {
        require(IERC165(tokenContract).supportsInterface(ERC1155_INTERFACE_ID), "tokenContract is not ERC1155");
        require(quantity != 0, "quantity zero");
        _validateDuration(duration);
        require(listingExpiry_ == 0 || listingExpiry_ > block.timestamp, "expiry must be future");
        if (_auctionIdByToken[tokenContract][tokenId] != 0) revert AuctionAlreadyExistsForToken();
        require(IERC1155(tokenContract).balanceOf(msg.sender, tokenId) >= quantity, "insufficient balance");
        require(IERC1155(tokenContract).isApprovedForAll(msg.sender, address(this)), "house not approved");

        auctionId = _nextAuctionId++;
        auctions[auctionId] = Auction({
            tokenId: tokenId,
            tokenContract: tokenContract,
            firstBidTime: 0,
            amount: 0,
            reservePrice: reservePrice,
            tokenOwner: msg.sender,
            fundsRecipient: payable(msg.sender),
            endTime: 0,
            bidder: payable(address(0)),
            duration: uint64(duration),
            quantity: quantity,
            standard: TokenStandard.ERC1155
        });
        _auctionIdByToken[tokenContract][tokenId] = auctionId + 1;
        if (listingExpiry_ != 0) listingExpiry[auctionId] = listingExpiry_;
        _pull1155(tokenContract, tokenId, quantity, msg.sender);
        emit Auction1155Created(
            auctionId, tokenId, tokenContract, quantity, duration, reservePrice, msg.sender, msg.sender, listingExpiry_
        );
    }

    function setAuctionReservePrice(uint256 auctionId, uint256 reservePrice)
        external
        override
        nonReentrant
        auctionExists(auctionId)
    {
        Auction storage a = auctions[auctionId];
        require(msg.sender == a.tokenOwner, "Not token owner");
        if (a.firstBidTime != 0) revert AuctionAlreadyStarted();
        a.reservePrice = reservePrice;
        emit AuctionReservePriceUpdated(auctionId, reservePrice);
    }

    /// @notice Lets the captured NFT owner choose any bounded duration before
    ///         bidding starts. The duration is immutable once a bid lands.
    function setAuctionDuration(uint256 auctionId, uint256 duration)
        external
        override
        nonReentrant
        auctionExists(auctionId)
    {
        Auction storage a = auctions[auctionId];
        require(msg.sender == a.tokenOwner, "Not token owner");
        if (a.firstBidTime != 0) revert AuctionAlreadyStarted();
        _validateDuration(duration);
        a.duration = uint64(duration);
        emit AuctionDurationUpdated(auctionId, duration);
    }

    /// @notice Direct sale proceeds before bidding starts. An approved house
    ///         owner cannot redirect a third-party token owner's proceeds.
    function setAuctionFundsRecipient(uint256 auctionId, address payable fundsRecipient)
        external
        override
        nonReentrant
        auctionExists(auctionId)
    {
        Auction storage a = auctions[auctionId];
        require(msg.sender == a.tokenOwner, "Not token owner");
        if (a.firstBidTime != 0) revert AuctionAlreadyStarted();
        if (fundsRecipient == address(0)) revert FundsRecipientRequired();
        a.fundsRecipient = fundsRecipient;
        emit AuctionFundsRecipientUpdated(auctionId, fundsRecipient);
    }

    /// @notice Optionally lets the captured owner set a no-bid listing expiry.
    ///         Zero means the listing stays open until canceled by its owner.
    function setAuctionListingExpiry(uint256 auctionId, uint64 expiry)
        external
        override
        nonReentrant
        auctionExists(auctionId)
    {
        Auction storage a = auctions[auctionId];
        require(msg.sender == a.tokenOwner, "Not token owner");
        if (a.firstBidTime != 0) revert AuctionAlreadyStarted();
        require(expiry == 0 || expiry > block.timestamp, "expiry must be future");
        listingExpiry[auctionId] = expiry;
        emit AuctionListingExpiryUpdated(auctionId, expiry);
    }

    function createBid(uint256 auctionId)
        external
        payable
        override
        auctionExists(auctionId)
        nonReentrant
    {
        Auction storage a = auctions[auctionId];
        uint64 expiry = listingExpiry[auctionId];
        if (a.firstBidTime == 0 && expiry != 0 && block.timestamp >= expiry) revert AuctionExpired();
        uint256 amount = msg.value;
        if (amount == 0) revert BidMustBePositive();
        if (a.firstBidTime != 0 && block.timestamp >= a.endTime) revert AuctionExpired();
        if (amount < a.reservePrice) revert BidBelowReserve();
        if (a.amount != 0) {
            uint256 increment = (a.amount * MIN_BID_INCREMENT_BPS) / 10_000;
            if (increment == 0) increment = 1;
            if (amount < a.amount + increment) revert BidBelowMinimum();
        }

        bool firstBid = a.firstBidTime == 0;
        address payable lastBidder = a.bidder;
        uint256 previousAmount = a.amount;
        if (firstBid) {
            a.firstBidTime = uint64(block.timestamp);
            a.endTime = uint64(block.timestamp + a.duration);
        }
        a.amount = amount;
        a.bidder = payable(msg.sender);
        if (!firstBid) {
            _sendOrCredit(lastBidder, previousAmount);
        }

        bool extended;
        if (a.endTime - block.timestamp < TIME_BUFFER) {
            a.endTime = uint64(block.timestamp + TIME_BUFFER);
            extended = true;
        }
        emit AuctionBid(auctionId, msg.sender, amount, firstBid, extended);
        if (extended) emit AuctionEndTimeUpdated(auctionId, a.endTime);
    }

    /// @notice Resolves every ended auction. Attempts token delivery through
    ///         a try/catch self-call capped at DELIVER_GAS_LIMIT gas, so the
    ///         outcome cannot depend on how much gas the caller of endAuction
    ///         supplied. The protocol fee and seller are paid only if that
    ///         delivery succeeds, through _finalizeSale. A failed delivery
    ///         pays nobody: the auction is marked pendingDelivery for a
    ///         permissionless retry via claimLot, and the winning bid stays
    ///         in the contract. Because delivery is attempted before any
    ///         payout, no seller-controlled callback can run between the lot
    ///         leaving escrow and the seller being paid.
    function endAuction(uint256 auctionId)
        external
        override
        auctionExists(auctionId)
        nonReentrant
    {
        Auction memory a = auctions[auctionId];
        if (a.firstBidTime == 0) revert AuctionHasNoBids();
        if (block.timestamp < a.endTime) revert AuctionNotEnded();
        if (pendingDelivery[auctionId]) revert AuctionAlreadySettled();
        if (pendingReturn[auctionId]) revert AuctionAlreadySettled();

        // EIP-150 forwards at most 63/64 of remaining gas, so a gas-starved
        // call could hand delivery less than DELIVER_GAS_LIMIT and defer a
        // transfer that would have succeeded. Require enough headroom that
        // the stipend is always honored in full.
        if (gasleft() < DELIVER_GAS_LIMIT + 80_000) revert InsufficientGas();

        bool delivered;
        if (a.standard == TokenStandard.ERC721) {
            try this.deliverERC721{gas: DELIVER_GAS_LIMIT}(a.tokenContract, a.tokenId, a.bidder) {
                delivered = true;
            } catch {}
        } else {
            try this.deliverERC1155{gas: DELIVER_GAS_LIMIT}(a.tokenContract, a.tokenId, a.quantity, a.bidder) {
                delivered = true;
            } catch {}
        }

        if (delivered) {
            _finalizeSale(auctionId, a);
        } else {
            pendingDelivery[auctionId] = true;
            deliveryDeferredAt[auctionId] = uint64(block.timestamp);
            emit DeliveryDeferred(auctionId, a.bidder);
        }
    }

    /// @dev Runs only once delivery has been verified. Deletes all per-lot
    ///      storage first, then pays the protocol fee and seller through
    ///      _payout. Deleting state before paying means a reentrant call
    ///      during the payout sees a cleared auction record, not a settled
    ///      one it could act on again.
    function _finalizeSale(uint256 auctionId, Auction memory a) internal {
        delete auctions[auctionId];
        delete _auctionIdByToken[a.tokenContract][a.tokenId];
        delete listingExpiry[auctionId];
        delete pendingDelivery[auctionId];
        delete deliveryDeferredAt[auctionId];
        delete pendingReturn[auctionId];

        uint256 protocolFee;
        if (protocolFeeBps != 0) {
            protocolFee = (a.amount * protocolFeeBps) / 10_000;
            _payout(feeRecipient, protocolFee);
        }
        uint256 sellerProceeds = a.amount - protocolFee;
        _payout(a.fundsRecipient, sellerProceeds);
        emit AuctionEnded(auctionId, a.tokenOwner, a.bidder, sellerProceeds, protocolFee);
    }

    /// @dev Delivery target for endAuction's and unwindStuckLot's gas-capped
    ///      try/catch self-calls. Used both to deliver to the winner and,
    ///      from unwindStuckLot, to return the lot to the seller: `to` is
    ///      whichever recipient the caller supplies, not necessarily the
    ///      auction's recorded winner. Reverting here rolls back the
    ///      transfer and its ownerOf verification together.
    function deliverERC721(address tokenContract, uint256 tokenId, address to) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC721(tokenContract).transferFrom(address(this), to, tokenId);
        if (IERC721(tokenContract).ownerOf(tokenId) != to) revert DeliveryFailed();
    }

    function deliverERC1155(address tokenContract, uint256 tokenId, uint256 quantity, address to) external {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 beforeBalance = IERC1155(tokenContract).balanceOf(to, tokenId);
        IERC1155(tokenContract).safeTransferFrom(address(this), to, tokenId, quantity, "");
        if (IERC1155(tokenContract).balanceOf(to, tokenId) < beforeBalance + quantity) revert DeliveryFailed();
    }

    /// @notice Delivery of a lot deferred by endAuction. Anyone may call this
    ///         to trigger delivery to the recorded winner (`to` must be
    ///         address(0) in that case), which lets a keeper rescue a winner
    ///         that has no way to call this itself. Only the recorded winner
    ///         may redirect delivery elsewhere via a nonzero `to`. Runs with
    ///         full gas and no try/catch, so a revert rolls back the whole
    ///         call and leaves the claim retryable. Delivery happens before
    ///         the auction record is cleared and the seller is paid, so no
    ///         external code runs between the lot moving and the seller's
    ///         payout except the payout call itself. The redirect is
    ///         best-effort: the pending state is consumed by whichever call
    ///         succeeds first, so a third party triggering delivery to the
    ///         winner with `to == address(0)` before the winner redirects
    ///         permanently forecloses that redirect. The token always still
    ///         reaches the winner's own bid address in that case.
    function claimLot(uint256 auctionId, address to) external override nonReentrant {
        if (!pendingDelivery[auctionId]) revert NoPendingDelivery();
        Auction memory a = auctions[auctionId];
        if (msg.sender != a.bidder && to != address(0)) revert NotWinner();

        address recipient = to == address(0) ? a.bidder : to;

        if (a.standard == TokenStandard.ERC721) {
            IERC721(a.tokenContract).transferFrom(address(this), recipient, a.tokenId);
            if (IERC721(a.tokenContract).ownerOf(a.tokenId) != recipient) revert DeliveryFailed();
        } else {
            uint256 beforeBalance = IERC1155(a.tokenContract).balanceOf(recipient, a.tokenId);
            IERC1155(a.tokenContract).safeTransferFrom(address(this), recipient, a.tokenId, a.quantity, "");
            if (IERC1155(a.tokenContract).balanceOf(recipient, a.tokenId) < beforeBalance + a.quantity) {
                revert DeliveryFailed();
            }
        }

        _finalizeSale(auctionId, a);
        emit LotClaimed(auctionId, a.bidder, recipient);
    }

    /// @notice Resolves a lot still pendingDelivery PENDING_DELIVERY_TIMEOUT
    ///         after deferral. Anyone may call this. It first retries capped
    ///         delivery to the recorded winner, exactly as endAuction did: a
    ///         delivery failure can be temporary (a paused collection
    ///         unpauses, a receiver later becomes compatible), so this is not
    ///         a straight unwind. If that retry succeeds, the sale finalizes
    ///         normally and the seller is paid. If it fails again, the sale
    ///         unwinds: the winner's full bid is credited to pendingRefunds
    ///         for withdrawal, unconditionally, before any token movement is
    ///         attempted, and a capped attempt returns the lot to the seller.
    ///         If that return also fails, the lot stays locked, escrowed and
    ///         un-relistable, until returnUnwoundLot succeeds. Nobody is paid
    ///         from this function unless the winner ends up holding the lot.
    /// @dev Sized for two capped self-calls (retry-to-winner, then
    ///      return-to-seller) so a gas-starved caller cannot force either
    ///      attempt to run under-stipend and be misclassified as a genuine
    ///      delivery failure.
    function unwindStuckLot(uint256 auctionId) external nonReentrant auctionExists(auctionId) {
        if (!pendingDelivery[auctionId]) revert NoPendingDelivery();
        if (block.timestamp <= deliveryDeferredAt[auctionId] + PENDING_DELIVERY_TIMEOUT) revert UnwindTooEarly();
        Auction memory a = auctions[auctionId];

        if (gasleft() < 2 * DELIVER_GAS_LIMIT + 100_000) revert InsufficientGas();

        bool delivered;
        if (a.standard == TokenStandard.ERC721) {
            try this.deliverERC721{gas: DELIVER_GAS_LIMIT}(a.tokenContract, a.tokenId, a.bidder) {
                delivered = true;
            } catch {}
        } else {
            try this.deliverERC1155{gas: DELIVER_GAS_LIMIT}(a.tokenContract, a.tokenId, a.quantity, a.bidder) {
                delivered = true;
            } catch {}
        }

        if (delivered) {
            _finalizeSale(auctionId, a);
            emit LotClaimed(auctionId, a.bidder, a.bidder);
            return;
        }

        delete pendingDelivery[auctionId];
        delete deliveryDeferredAt[auctionId];

        // Credited before any token movement is attempted: the winner's
        // refund never depends on whether the lot can be returned.
        pendingRefunds[a.bidder] += a.amount;
        emit RefundCredited(a.bidder, a.amount);

        bool returned;
        if (a.standard == TokenStandard.ERC721) {
            try this.deliverERC721{gas: DELIVER_GAS_LIMIT}(a.tokenContract, a.tokenId, a.tokenOwner) {
                returned = true;
            } catch {}
        } else {
            try this.deliverERC1155{gas: DELIVER_GAS_LIMIT}(a.tokenContract, a.tokenId, a.quantity, a.tokenOwner) {
                returned = true;
            } catch {}
        }

        if (returned) {
            delete auctions[auctionId];
            delete _auctionIdByToken[a.tokenContract][a.tokenId];
            delete listingExpiry[auctionId];
        } else {
            pendingReturn[auctionId] = true;
            emit LotReturnDeferred(auctionId, a.tokenOwner);
        }

        emit LotUnwound(auctionId, a.bidder, a.amount, a.tokenOwner);
    }

    /// @notice Delivers a lot whose return to the seller failed during
    ///         unwindStuckLot. Anyone may call this; it only ever delivers to
    ///         the auction's recorded tokenOwner. Runs with full gas and no
    ///         try/catch, so a revert rolls back the whole call and leaves
    ///         the return retryable.
    function returnUnwoundLot(uint256 auctionId) external nonReentrant auctionExists(auctionId) {
        if (!pendingReturn[auctionId]) revert NoPendingReturn();
        Auction memory a = auctions[auctionId];

        if (a.standard == TokenStandard.ERC721) {
            IERC721(a.tokenContract).transferFrom(address(this), a.tokenOwner, a.tokenId);
            if (IERC721(a.tokenContract).ownerOf(a.tokenId) != a.tokenOwner) revert DeliveryFailed();
        } else {
            uint256 beforeBalance = IERC1155(a.tokenContract).balanceOf(a.tokenOwner, a.tokenId);
            IERC1155(a.tokenContract).safeTransferFrom(address(this), a.tokenOwner, a.tokenId, a.quantity, "");
            if (IERC1155(a.tokenContract).balanceOf(a.tokenOwner, a.tokenId) < beforeBalance + a.quantity) {
                revert DeliveryFailed();
            }
        }

        delete pendingReturn[auctionId];
        delete auctions[auctionId];
        delete _auctionIdByToken[a.tokenContract][a.tokenId];
        delete listingExpiry[auctionId];
        emit LotReturned(auctionId, a.tokenOwner);
    }

    function cancelAuction(uint256 auctionId)
        external
        override
        nonReentrant
        auctionExists(auctionId)
    {
        Auction memory a = auctions[auctionId];
        require(msg.sender == a.tokenOwner, "Not token owner");
        if (a.firstBidTime != 0) revert AuctionAlreadyStarted();
        if (a.standard == TokenStandard.ERC721) {
            IERC721(a.tokenContract).transferFrom(address(this), a.tokenOwner, a.tokenId);
            if (IERC721(a.tokenContract).ownerOf(a.tokenId) != a.tokenOwner) revert DeliveryFailed();
        } else {
            uint256 beforeBalance = IERC1155(a.tokenContract).balanceOf(a.tokenOwner, a.tokenId);
            IERC1155(a.tokenContract).safeTransferFrom(address(this), a.tokenOwner, a.tokenId, a.quantity, "");
            if (IERC1155(a.tokenContract).balanceOf(a.tokenOwner, a.tokenId) < beforeBalance + a.quantity) {
                revert DeliveryFailed();
            }
        }
        delete _auctionIdByToken[a.tokenContract][a.tokenId];
        delete auctions[auctionId];
        delete listingExpiry[auctionId];
        emit AuctionCanceled(auctionId);
    }

    /// @notice Anyone may clear a no-bid listing once its owner-selected
    ///         expiry has passed. The lot is always returned to that owner.
    function expireAuction(uint256 auctionId) external override nonReentrant auctionExists(auctionId) {
        Auction memory a = auctions[auctionId];
        uint64 expiry = listingExpiry[auctionId];
        if (a.firstBidTime != 0 || expiry == 0 || block.timestamp < expiry) revert AuctionNotEnded();
        if (a.standard == TokenStandard.ERC721) {
            IERC721(a.tokenContract).transferFrom(address(this), a.tokenOwner, a.tokenId);
            if (IERC721(a.tokenContract).ownerOf(a.tokenId) != a.tokenOwner) revert DeliveryFailed();
        } else {
            uint256 beforeBalance = IERC1155(a.tokenContract).balanceOf(a.tokenOwner, a.tokenId);
            IERC1155(a.tokenContract).safeTransferFrom(address(this), a.tokenOwner, a.tokenId, a.quantity, "");
            if (IERC1155(a.tokenContract).balanceOf(a.tokenOwner, a.tokenId) < beforeBalance + a.quantity) {
                revert DeliveryFailed();
            }
        }
        delete _auctionIdByToken[a.tokenContract][a.tokenId];
        delete auctions[auctionId];
        delete listingExpiry[auctionId];
        emit AuctionCanceled(auctionId);
    }

    function withdrawRefund() external override nonReentrant {
        _withdrawRefund(payable(msg.sender));
    }

    function withdrawRefundTo(address payable recipient) external override nonReentrant {
        if (recipient == address(0)) revert FundsRecipientRequired();
        _withdrawRefund(recipient);
    }

    function _withdrawRefund(address payable recipient) internal {
        uint256 amount = pendingRefunds[msg.sender];
        require(amount != 0, "No refund available");
        pendingRefunds[msg.sender] = 0;
        (bool sent,) = recipient.call{value: amount}("");
        require(sent, "Withdraw failed");
        emit RefundWithdrawn(msg.sender, recipient, amount);
    }

    function recoverStuckERC721(address tokenContract, uint256 tokenId, address to)
        external
        onlyOwner
        nonReentrant
    {
        require(to != address(0), "to required");
        if (_auctionIdByToken[tokenContract][tokenId] != 0) revert AuctionAlreadyExistsForToken();
        IERC721(tokenContract).transferFrom(address(this), to, tokenId);
        emit StuckERC721Recovered(tokenContract, tokenId, to);
    }

    function recoverStuckERC1155(address tokenContract, uint256 tokenId, uint256 quantity, address to)
        external
        onlyOwner
        nonReentrant
    {
        require(to != address(0), "to required");
        if (_auctionIdByToken[tokenContract][tokenId] != 0) revert AuctionAlreadyExistsForToken();
        uint256 beforeBalance = IERC1155(tokenContract).balanceOf(to, tokenId);
        IERC1155(tokenContract).safeTransferFrom(address(this), to, tokenId, quantity, "");
        if (IERC1155(tokenContract).balanceOf(to, tokenId) < beforeBalance + quantity) revert DeliveryFailed();
        emit StuckERC1155Recovered(tokenContract, tokenId, quantity, to);
    }

    /// @inheritdoc ISovereignAuctionHouseV2
    function getAuction(uint256 auctionId) external view override returns (Auction memory) {
        return auctions[auctionId];
    }

    function getAuctionFor(address tokenContract, uint256 tokenId) external view returns (bool exists, uint256 auctionId) {
        uint256 stored = _auctionIdByToken[tokenContract][tokenId];
        return stored == 0 ? (false, 0) : (true, stored - 1);
    }

    function nextAuctionId() external view returns (uint256) {
        return _nextAuctionId;
    }

    /// @notice Distinguishes V2 tuple layout from the immutable V1 ABI.
    function auctionVersion() external pure returns (uint8) {
        return 2;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function onERC1155Received(address, address, uint256 id, uint256 value, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (msg.sender != _pull1155Token || id != _pull1155Id || value != _pull1155Quantity) revert EscrowFailed();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert EscrowFailed();
    }

    /// @dev Outbid-refund path in createBid only. Runs before any delivery
    ///      has been attempted, so the recipient's code, if any, cannot use
    ///      this callback to affect the lot. Pushes with a 30_000 gas
    ///      stipend and credits pendingRefunds on failure.
    function _sendOrCredit(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool sent,) = to.call{value: amount, gas: 30_000}("");
        if (!sent) {
            pendingRefunds[to] += amount;
            emit RefundCredited(to, amount);
        }
    }

    /// @dev Seller-proceeds and protocol-fee payout leg of settlement, used
    ///      only after delivery has been verified. An EOA recipient (no
    ///      code) is pushed a 30_000 gas call; a contract recipient
    ///      (including an EIP-7702-delegated account, which has code) is
    ///      never called at all and is instead credited to pendingRefunds
    ///      for a pull withdrawal. Settlement runs after delivery, so no
    ///      external code may execute after the lot has moved: routing every
    ///      contract recipient through a pull, rather than a push callback
    ///      that could run at this point, closes that off without needing to
    ///      pay before delivery.
    function _payout(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to.code.length == 0) {
            (bool sent,) = to.call{value: amount, gas: 30_000}("");
            if (sent) return;
        }
        pendingRefunds[to] += amount;
        emit RefundCredited(to, amount);
    }

    function _pull1155(address tokenContract, uint256 tokenId, uint256 quantity, address from) internal {
        uint256 beforeBalance = IERC1155(tokenContract).balanceOf(address(this), tokenId);
        _pull1155Token = tokenContract;
        _pull1155Id = tokenId;
        _pull1155Quantity = quantity;
        IERC1155(tokenContract).safeTransferFrom(from, address(this), tokenId, quantity, "");
        _pull1155Token = address(0);
        _pull1155Id = 0;
        _pull1155Quantity = 0;
        if (IERC1155(tokenContract).balanceOf(address(this), tokenId) < beforeBalance + quantity) revert EscrowFailed();
    }

    function _validateDuration(uint256 duration) internal pure {
        require(duration != 0, "duration zero");
        require(duration <= MAX_DURATION, "duration too large");
    }

    function _exists(uint256 auctionId) internal view returns (bool) {
        return auctions[auctionId].tokenOwner != address(0);
    }

    receive() external payable {
        revert("Direct ETH not accepted");
    }
}
