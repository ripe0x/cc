// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "solady/tokens/ERC721.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {BaseStrategy} from "./BaseStrategy.sol";
import {
    ISeaport,
    ItemType,
    OrderType,
    OfferItem,
    ConsiderationItem,
    OrderParameters,
    OrderComponents,
    Order
} from "../Interfaces.sol";

/// @title NFTStrategy - An ERC20 token that constantly churns NFTs from a collection
/// @author TokenWorks (https://token.works/)
/// @notice This contract implements an ERC20 token backed by another token.
///         Users can trade the token on Uniswap V4, and the contract uses trading fees to buy bags of the underlying token.
/// @dev Uses ERC1967 proxy pattern with immutable args for gas-efficient upgrades
contract NFTStrategy is BaseStrategy {
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™                ™™™™™™™™™™™                ™™™™™™™™™™™ */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™               ™™™™™™™™™™™™™              ™™™™™™™™™™  */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™              ™™™™™™™™™™™™™              ™™™™™™™™™™™  */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™             ™™™™™™™™™™™™™™            ™™™™™™™™™™™   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™            ™™™™™™™™™™™™™™™            ™™™™™™™™™™™   */
    /*                ™™™™™™™™™™™            ™™™™™™™™™™™           ™™™™™™™™™™™™™™™           ™™™™™™™™™™™    */
    /*                ™™™™™™™™™™™             ™™™™™™™™™™          ™™™™™™™™™™™™™™™™™          ™™™™™™™™™™™    */
    /*                ™™™™™™™™™™™             ™™™™™™™™™™          ™™™™™™™™™™™™™™™™™          ™™™™™™™™™™     */
    /*                ™™™™™™™™™™™              ™™™™™™™™™™        ™™™™™™™™™™™™™™™™™™™        ™™™™™™™™™™™     */
    /*                ™™™™™™™™™™™              ™™™™™™™™™™™       ™™™™™™™™™ ™™™™™™™™™       ™™™™™™™™™™™      */
    /*                ™™™™™™™™™™™               ™™™™™™™™™™      ™™™™™™™™™™ ™™™™™™™™™™      ™™™™™™™™™™™      */
    /*                ™™™™™™™™™™™               ™™™™™™™™™™      ™™™™™™™™™   ™™™™™™™™™      ™™™™™™™™™™       */
    /*                ™™™™™™™™™™™                ™™™™™™™™™™    ™™™™™™™™™™    ™™™™™™™™™    ™™™™™™™™™™        */
    /*                ™™™™™™™™™™™                 ™™™™™™™™™™   ™™™™™™™™™     ™™™™™™™™™™  ™™™™™™™™™™™        */
    /*                ™™™™™™™™™™™                 ™™™™™™™™™™  ™™™™™™™™™™     ™™™™™™™™™™  ™™™™™™™™™™         */
    /*                ™™™™™™™™™™™                  ™™™™™™™™™™™™™™™™™™™™       ™™™™™™™™™™™™™™™™™™™™          */
    /*                ™™™™™™™™™™™                   ™™™™™™™™™™™™™™™™™™         ™™™™™™™™™™™™™™™™™™           */
    /*                ™™™™™™™™™™™                   ™™™™™™™™™™™™™™™™™™         ™™™™™™™™™™™™™™™™™™           */
    /*                ™™™™™™™™™™™                    ™™™™™™™™™™™™™™™™           ™™™™™™™™™™™™™™™™            */
    /*                ™™™™™™™™™™™                     ™™™™™™™™™™™™™™             ™™™™™™™™™™™™™™             */
    /*                ™™™™™™™™™™™                     ™™™™™™™™™™™™™™             ™™™™™™™™™™™™™™             */
    /*                ™™™™™™™™™™™                      ™™™™™™™™™™™™               ™™™™™™™™™™™™              */

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                     CONSTANTS                       */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice The NFT collection this strategy is tied to
    ERC721 public collection;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                   STATE VARIABLES                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Mapping of NFT token IDs to their sale prices
    mapping(uint256 => uint256) public nftForSale;

    /// @notice Mapping from token ID to order hash
    mapping(uint256 => bytes32) public tokenIdToOrderHash;

    /// @notice Struct to store additional Seaport consideration config (platform fee, royalty, etc.)
    struct SeaportFeeRecipient {
        uint96 feeBps;
        address recipient;
    }

    /// @notice Struct to store fee recipient with actual amount for listings
    struct ListingFeeRecipient {
        uint256 amount;
        address recipient;
    }

    /// @notice Struct to store Seaport listing details for cancellation
    struct SeaportListing {
        uint256 salt;
        uint256 proceeds;
        uint48 startTime;
        uint48 endTime;
        uint8 numFeeRecipients;
        ListingFeeRecipient[2] feeRecipients;
    }

    /// @notice Mapping from token ID to Seaport listing details
    mapping(uint256 => SeaportListing) public seaportListings;

    /// @notice Whether Seaport integration is disabled
    bool public seaportDisabled;

    /// @notice ETH currently held as rewards for syncing listings
    uint256 public syncListingReward;

    /// @notice Number of active fee recipients (0-2)
    uint8 public numSeaportFeeRecipients;

    /// @notice Additional fee recipients for Seaport listings (platform fee, royalty, etc.)
    SeaportFeeRecipient[2] public seaportFeeRecipients;

    /// @notice Storage gap for future upgrades (prevents storage collisions)
    uint256[40] private __gap;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                 SEAPORT CONSTANTS                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Max duration for Seaport listings
    uint256 public constant SEAPORT_MAX_LISTING_DURATION = 180 days;

    /// @notice Seaport contract address
    ISeaport public constant SEAPORT = ISeaport(0x0000000000000068F116a894984e2DB1123eB395);

    /// @notice OpenSea conduit key for Seaport
    bytes32 public constant CONDUIT_KEY = 0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000;

    /// @notice OpenSea conduit address
    address public constant OPENSEA_CONDUIT_ADDRESS = 0x1E0049783F008A0085193E00003D00cd54003c71;

    /// @notice OpenSea zone address for restricted orders
    address public constant SEAPORT_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                   CUSTOM EVENTS                     */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Emitted when the protocol buys an NFT
    event NFTBoughtByProtocol(
        uint256 indexed tokenId,
        uint256 purchasePrice,
        uint256 listPrice
    );

    /// @notice Emitted when the protocol sells an NFT
    event NFTSoldByProtocol(
        uint256 indexed tokenId,
        uint256 price,
        address buyer
    );

    /// @notice Emitted when a Seaport listing is created
    event SeaportListingCreated(uint256 indexed tokenId, uint256 price, bytes32 orderHash);

    /// @notice Emitted when a Seaport listing is cancelled
    event SeaportListingCancelled(uint256 indexed tokenId, bytes32 orderHash);

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    CUSTOM ERRORS                    */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice NFT is not currently for sale
    error NFTNotForSale();
    /// @notice Sent ETH amount is less than the NFT sale price
    error NFTPriceTooLow();
    /// @notice Call didn't result in buying the right amount of the token
    error NeedToBuyNFT();
    /// @notice Contract already owns this NFT
    error AlreadyNFTOwner();
    /// @notice Contract doesn't own the specified NFT
    error NotNFTOwner();
    /// @notice triggered when target is collection
    error InvalidTarget();
    /// @notice triggered when the external call fails when buying an NFT
    error ExternalCallFailed(bytes reason);
    /// @notice Contract is invalid
    error InvalidCollection();
    /// @notice Active Seaport listing already exists for this token
    error SeaportListingAlreadyExists();
    /// @notice Seaport integration is disabled
    error SeaportIsDisabled();
    /// @notice Invalid parameters provided
    error InvalidParams();

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    CONSTRUCTOR                      */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Constructor calls BaseStrategy() to disable initializers
    /// @dev This is required for the proxy pattern to work correctly
    constructor() BaseStrategy() {}

    /// @notice Initializes the contract with required addresses and permissions
    /// @param _collection Address of the underlying ERC721 contract
    /// @param _hook Address of the StrategyHook contract
    /// @param _tokenName Name of the token
    /// @param _tokenSymbol Symbol of the token
    /// @param _buyIncrement Buy increment for the token
    /// @param _owner Owner of the contract
    function initialize(
        address _collection,
        address _hook,
        string memory _tokenName,
        string memory _tokenSymbol,
        uint256 _buyIncrement,
        address _owner
    ) external initializer {
        if (_collection == address(0)) revert InvalidCollection();

        collection = ERC721(_collection);

        __BaseStrategy_init(
            _hook,
            _tokenName,
            _tokenSymbol,
            _buyIncrement,
            _owner
        );
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                       GETTERS                       */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @dev this must be incremented whenever there is any change in BaseStrategy or this strategy
    function VERSION() public pure override returns (uint256) {
        return 1;
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                 MECHANISM FUNCTIONS                 */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Buys a specific NFT using accumulated fees
    /// @param value Amount of ETH to spend on the NFT purchase
    /// @param data Calldata for the external marketplace call
    /// @param expectedId The token ID expected to be acquired
    /// @param target The marketplace contract to call
    /// @dev Protected against reentrancy, validates NFT acquisition
    function buyTargetNFT(
        uint256 value,
        bytes calldata data,
        uint256 expectedId,
        address target
    ) external virtual nonReentrant {
        // Store both balance and nft amount before calling external
        uint256 ethBalanceBefore = address(this).balance;
        uint256 nftBalanceBefore = collection.balanceOf(address(this));

        // Make sure we are not owner of the expected id
        if (collection.ownerOf(expectedId) == address(this)) {
            revert AlreadyNFTOwner();
        }

        // Ensure value is not more than currentFees
        if (value > currentFees) {
            revert NotEnoughEth();
        }

        // Ensure value doesn't exceed the time-based maximum price
        if (value > getMaxPriceForBuy()) {
            revert PriceTooHigh();
        }

        // Ensure target is not the collection itself
        if (target == address(collection)) revert InvalidTarget();

        // Call external
        (bool success, bytes memory reason) = target.call{value: value}(data);
        if (!success) {
            revert ExternalCallFailed(reason);
        }

        // Ensure we now have one more NFT
        uint256 nftBalanceAfter = collection.balanceOf(address(this));

        if (nftBalanceAfter != nftBalanceBefore + 1) {
            revert NeedToBuyNFT();
        }

        // Ensure we are now owner of expectedId
        if (collection.ownerOf(expectedId) != address(this)) {
            revert NotNFTOwner();
        }

        // Calculate actual cost of the NFT to base new price on
        uint256 cost = ethBalanceBefore - address(this).balance;
        currentFees -= cost;

        // List NFT for sale at priceMultiplier times the cost
        uint256 salePrice = (cost * priceMultiplier) / 1000;
        nftForSale[expectedId] = salePrice;

        // Update last buy block to reset max price calculation
        lastBuyBlock = block.number;

        // Create Seaport listing if seaport is enabled and fee recipients configured
        if (!seaportDisabled && numSeaportFeeRecipients > 0) {
            _createSeaportListing(expectedId, salePrice);
        }

        emit NFTBoughtByProtocol(expectedId, cost, salePrice);
    }

    /// @notice Sells an NFT owned by the contract for the listed price
    /// @param tokenId The ID of the NFT to sell
    function sellTargetNFT(
        uint256 tokenId
    ) external payable virtual nonReentrant {
        // Get sale price
        uint256 salePrice = nftForSale[tokenId];

        // Verify NFT is for sale
        if (salePrice == 0) revert NFTNotForSale();

        // Verify sent ETH matches sale price
        if (msg.value != salePrice) revert NFTPriceTooLow();

        // Verify contract owns the NFT
        if (collection.ownerOf(tokenId) != address(this)) revert NotNFTOwner();

        // Cancel Seaport listing if exists
        _cancelSeaportListingIfExists(tokenId);

        // Transfer NFT to buyer
        collection.transferFrom(address(this), msg.sender, tokenId);

        // Remove NFT from sale
        delete nftForSale[tokenId];

        // Add sale price to fees
        ethToTwap += salePrice;

        emit NFTSoldByProtocol(tokenId, salePrice, msg.sender);
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                 SEAPORT FUNCTIONS                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Creates Seaport listings for NFTs that are already in nftForSale
    /// @param tokenIds Array of token IDs to list on Seaport
    function createSeaportListing(uint256[] calldata tokenIds) external nonReentrant {
        if (seaportDisabled || numSeaportFeeRecipients == 0) revert SeaportIsDisabled();

        for (uint256 i; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 price = nftForSale[tokenId];

            if (price == 0) revert NFTNotForSale();
            if (collection.ownerOf(tokenId) != address(this)) revert NotNFTOwner();

            // Check if listing already exists
            SeaportListing memory existing = seaportListings[tokenId];
            if (existing.endTime > 0) {
                // Listing exists - only allow if expired
                if (existing.endTime > block.timestamp) {
                    revert SeaportListingAlreadyExists();
                }
                // Expired - clear old data before creating new
                delete tokenIdToOrderHash[tokenId];
            }

            _createSeaportListing(tokenId, price);
        }
    }

    /// @notice Syncs the order status for tokens that were sold via Seaport
    /// @param tokenIds Array of token IDs to sync
    /// @dev Caller receives 0.5% of proceeds (price minus fees) for each successful sync
    function syncOrderStatus(uint256[] calldata tokenIds) external nonReentrant {
        uint256 totalReward;

        for (uint256 i; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            bytes32 orderHash = tokenIdToOrderHash[tokenId];
            if (orderHash == bytes32(0)) continue;

            // Skip if we still own the NFT
            if (collection.ownerOf(tokenId) == address(this)) continue;

            // Read all needed values before delete
            uint256 price = nftForSale[tokenId];
            uint256 proceeds = seaportListings[tokenId].proceeds;

            // Clean up state
            delete nftForSale[tokenId];
            delete seaportListings[tokenId];
            delete tokenIdToOrderHash[tokenId];

            // Calculate reward for this sync (0.5% of proceeds, from syncListingReward pool)
            uint256 reward = (proceeds * 5) / 1000;
            totalReward += reward;

            emit NFTSoldByProtocol(tokenId, price, address(SEAPORT));
        }

        // should not happen, but we never know
        if (totalReward > syncListingReward) {
            totalReward = syncListingReward;
        }

        // Pay out accumulated reward to caller
        if (totalReward > 0) {
            syncListingReward -= totalReward;
            SafeTransferLib.forceSafeTransferETH(msg.sender, totalReward);
        }
    }

    /// @notice Enables or disables Seaport integration and sets approval accordingly
    /// @dev When disabled, createSeaportListing will revert
    function setSeaport(bool enabled) external onlyOwnerOrManager {
        seaportDisabled = !enabled;
        collection.setApprovalForAll(OPENSEA_CONDUIT_ADDRESS, enabled);
    }

    /// @notice Sets the additional fee recipients for Seaport listings
    /// @param recipients Array of fee recipients (fee in bps, recipient address). Max 2 recipients.
    /// @dev Total fees cannot exceed 600 bps (6%). Only callable by owner or manager.
    function setSeaportFeeRecipients(SeaportFeeRecipient[] calldata recipients) external onlyOwnerOrManager {
        uint256 length = recipients.length;
        if (length > 2) revert InvalidParams();

        // Calculate total fees and validate
        uint256 totalFeeBps;
        for (uint256 i; i < length; i++) {
            totalFeeBps += recipients[i].feeBps;
        }
        if (totalFeeBps > 600) revert InvalidParams();

        // Set new recipients
        numSeaportFeeRecipients = uint8(length);
        for (uint256 i; i < length; i++) {
            seaportFeeRecipients[i] = recipients[i];
        }
        // Clear unused slots
        for (uint256 i = length; i < 2; i++) {
            delete seaportFeeRecipients[i];
        }
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                  INTERNAL FUNCTIONS                 */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Internal function to create a Seaport listing
    /// @param tokenId The token ID to list
    /// @param price The price in ETH
    function _createSeaportListing(uint256 tokenId, uint256 price) internal {
        // Approve OpenSea conduit if not already approved
        if (!collection.isApprovedForAll(address(this), OPENSEA_CONDUIT_ADDRESS)) {
            collection.setApprovalForAll(OPENSEA_CONDUIT_ADDRESS, true);
        }

        uint256 salt = uint256(keccak256(abi.encodePacked(tokenId, block.timestamp)));
        uint48 startTime = uint48(block.timestamp);
        uint48 endTime = uint48(block.timestamp + SEAPORT_MAX_LISTING_DURATION);

        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC721,
            token: address(collection),
            identifierOrCriteria: tokenId,
            startAmount: 1,
            endAmount: 1
        });

        // Build consideration array and store listing in single loop
        uint8 numFees = numSeaportFeeRecipients;
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1 + numFees);
        SeaportListing storage listing = seaportListings[tokenId];

        uint256 totalFeeAmount;
        for (uint256 i; i < numFees; i++) {
            uint256 feeAmount = (price * seaportFeeRecipients[i].feeBps) / 10000;
            totalFeeAmount += feeAmount;

            // Build consideration item
            consideration[1 + i] = ConsiderationItem({
                itemType: ItemType.NATIVE,
                token: address(0),
                identifierOrCriteria: 0,
                startAmount: feeAmount,
                endAmount: feeAmount,
                recipient: payable(seaportFeeRecipients[i].recipient)
            });

            // Store fee recipient with actual amount
            listing.feeRecipients[i] = ListingFeeRecipient({
                amount: feeAmount,
                recipient: seaportFeeRecipients[i].recipient
            });
        }

        // Our proceeds (price minus fees)
        uint256 ourProceeds = price - totalFeeAmount;
        consideration[0] = ConsiderationItem({
            itemType: ItemType.NATIVE,
            token: address(0),
            identifierOrCriteria: 0,
            startAmount: ourProceeds,
            endAmount: ourProceeds,
            recipient: payable(address(this))
        });

        OrderComponents memory orderComponents = OrderComponents({
            offerer: address(this),
            zone: SEAPORT_ZONE,
            offer: offer,
            consideration: consideration,
            orderType: OrderType.FULL_RESTRICTED,
            startTime: startTime,
            endTime: endTime,
            zoneHash: bytes32(0),
            salt: salt,
            conduitKey: CONDUIT_KEY,
            counter: SEAPORT.getCounter(address(this))
        });

        bytes32 orderHash = SEAPORT.getOrderHash(orderComponents);

        OrderParameters memory params = OrderParameters({
            offerer: address(this),
            zone: SEAPORT_ZONE,
            offer: offer,
            consideration: consideration,
            orderType: OrderType.FULL_RESTRICTED,
            startTime: startTime,
            endTime: endTime,
            zoneHash: bytes32(0),
            salt: salt,
            conduitKey: CONDUIT_KEY,
            totalOriginalConsiderationItems: 1 + numFees
        });

        Order[] memory orders = new Order[](1);
        orders[0] = Order({parameters: params, signature: ""});

        SEAPORT.validate(orders);

        // Store remaining listing details
        listing.salt = salt;
        listing.proceeds = ourProceeds;
        listing.startTime = startTime;
        listing.endTime = endTime;
        listing.numFeeRecipients = numFees;

        tokenIdToOrderHash[tokenId] = orderHash;

        emit SeaportListingCreated(tokenId, price, orderHash);
    }

    /// @notice Internal function to cancel a Seaport listing if one exists
    /// @param tokenId The token ID to cancel listing for
    function _cancelSeaportListingIfExists(uint256 tokenId) internal {
        bytes32 orderHash = tokenIdToOrderHash[tokenId];
        if (orderHash == bytes32(0)) return;

        SeaportListing memory listing = seaportListings[tokenId];

        // Read all needed values before delete
        uint256 salt = listing.salt;
        uint256 proceeds = listing.proceeds;
        uint48 startTime = listing.startTime;
        uint48 endTime = listing.endTime;
        uint8 numFees = listing.numFeeRecipients;

        // Reconstruct offer
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC721,
            token: address(collection),
            identifierOrCriteria: tokenId,
            startAmount: 1,
            endAmount: 1
        });

        // Reconstruct consideration using stored amounts (no recalculation needed)
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1 + numFees);

        for (uint256 i; i < numFees; i++) {
            ListingFeeRecipient memory fee = listing.feeRecipients[i];
            consideration[1 + i] = ConsiderationItem({
                itemType: ItemType.NATIVE,
                token: address(0),
                identifierOrCriteria: 0,
                startAmount: fee.amount,
                endAmount: fee.amount,
                recipient: payable(fee.recipient)
            });
        }

        consideration[0] = ConsiderationItem({
            itemType: ItemType.NATIVE,
            token: address(0),
            identifierOrCriteria: 0,
            startAmount: proceeds,
            endAmount: proceeds,
            recipient: payable(address(this))
        });

        // Reconstruct OrderComponents
        OrderComponents[] memory ordersToCancel = new OrderComponents[](1);
        ordersToCancel[0] = OrderComponents({
            offerer: address(this),
            zone: SEAPORT_ZONE,
            offer: offer,
            consideration: consideration,
            orderType: OrderType.FULL_RESTRICTED,
            startTime: startTime,
            endTime: endTime,
            zoneHash: bytes32(0),
            salt: salt,
            conduitKey: CONDUIT_KEY,
            counter: SEAPORT.getCounter(address(this))
        });

        // Cancel on Seaport
        SEAPORT.cancel(ordersToCancel);

        // Clear storage
        delete seaportListings[tokenId];
        delete tokenIdToOrderHash[tokenId];

        emit SeaportListingCancelled(tokenId, orderHash);
    }

    /// @notice Allows the contract to receive ETH
    /// @dev If ETH is from Seaport, add to ethToTwap for buyback
    receive() external payable override {
        if (msg.sender == address(SEAPORT)) {
            uint256 reward = (msg.value * 5) / 1000; // 0.5%
            syncListingReward += reward;
            ethToTwap += (msg.value - reward);
        }
    }
}
