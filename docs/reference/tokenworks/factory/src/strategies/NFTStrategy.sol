// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "solady/tokens/ERC721.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {BaseStrategy} from "./BaseStrategy.sol";

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

    /// @notice Storage gap for future upgrades (prevents storage collisions)
    uint256[50] private __gap;

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
    ) external nonReentrant {
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

        emit NFTBoughtByProtocol(expectedId, cost, salePrice);
    }

    /// @notice Sells an NFT owned by the contract for the listed price
    /// @param tokenId The ID of the NFT to sell
    function sellTargetNFT(uint256 tokenId) external payable nonReentrant {
        // Get sale price
        uint256 salePrice = nftForSale[tokenId];

        // Verify NFT is for sale
        if (salePrice == 0) revert NFTNotForSale();

        // Verify sent ETH matches sale price
        if (msg.value != salePrice) revert NFTPriceTooLow();

        // Verify contract owns the NFT
        if (collection.ownerOf(tokenId) != address(this)) revert NotNFTOwner();

        // Transfer NFT to buyer
        collection.transferFrom(address(this), msg.sender, tokenId);

        // Remove NFT from sale
        delete nftForSale[tokenId];

        // Add sale price to fees
        ethToTwap += salePrice;

        emit NFTSoldByProtocol(tokenId, salePrice, msg.sender);
    }
}
