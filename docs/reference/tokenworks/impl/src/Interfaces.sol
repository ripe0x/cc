// SPDX-License-Identifier: MIT
pragma solidity >=0.7.5;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IUniswapV4Router04} from "v4-router/interfaces/IUniswapV4Router04.sol";

/// @title Interfaces - Core interfaces for the strategy ecosystem
/// @author TokenWorks (https://token.works/)
/// @notice This file contains all the interfaces used by the strategy contracts

/// @notice Interface for Universal Router (legacy, kept for compatibility)
interface IUniversalRouter {
    /// @notice Thrown when a required command has failed
    error ExecutionFailed(uint256 commandIndex, bytes message);

    /// @notice Thrown when attempting to send ETH directly to the contract
    error ETHNotAccepted();

    /// @notice Thrown when executing commands with an expired deadline
    error TransactionDeadlinePassed();

    /// @notice Thrown when attempting to execute commands and an incorrect number of inputs are provided
    error LengthMismatch();

    // @notice Thrown when an address that isn't WETH tries to send ETH to the router without calldata
    error InvalidEthSender();

    /// @notice Executes encoded commands along with provided inputs. Reverts if deadline has expired.
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    /// @param deadline The deadline by which the transaction must be executed
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Parameters for exact input single swaps (legacy, kept for compatibility)
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @notice Interface for PunkStrategy contracts
/// @dev Interface for the original PunkStrategy token contract
interface IPunkStrategy {
    // View functions
    function loadingLiquidity() external view returns (bool);
    function owner() external view returns (address);
    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function hookAddress() external view returns (address);
    function currentFees() external view returns (uint256);
    function reward() external view returns (uint256);
    function lastPunkSalePrice() external view returns (uint256);
    function priceMultiplier() external view returns (uint256);
    function canProcessPunkSale() external view returns (bool);

    // Admin functions
    function loadLiquidity(address _hook) external payable;
    function transferEther(address _to, uint256 _amount) external payable;
    function setReward(uint256 _newReward) external;
    function setPriceMultiplier(uint256 _newMultiplier) external;
    function transferOwnership(address newOwner) external;

    // Mechanism functions
    function addFees() external payable;
    function buyPunkAndRelist(uint256 punkId) external returns (uint256);
    function processPunkSale() external returns (uint256);

    // Constants
    function MAX_SUPPLY() external pure returns (uint256);
    function DEADADDRESS() external pure returns (address);
}

/// @notice Interface for PunkStrategyHook contracts
interface IPunkStrategyHook {
    // View functions
    function feeBips() external view returns (uint128);
    function prePunkSellBips() external view returns (uint128);
    function feeSplit() external view returns (IFeeSplit);
    function calculateFee(bool isBuying) external view returns (uint128);
    function getHookPermissions() external pure returns (Hooks.Permissions memory);

    // Admin functions
    function transferToken(address _token, address _to, uint256 _amount) external payable;
    function updateFeeBips(uint128 _feeBips) external;
    function updateManualFees(bool _manuallyProcessFees) external;
    function updateFeeSplit(IFeeSplit _feeSplit) external;

    // Mechanism functions
    function feeCooldown() external;
    function punksAreAccumulating() external;
    function processAccumulatedFees() external;
}

/// @notice Interface for fee splitting contracts
interface IFeeSplit {
    function processDeposit() external payable;
}

/// @notice Offer struct for CryptoPunks marketplace
struct Offer {
    bool isForSale;
    uint256 punkIndex;
    address seller;
    uint256 minValue;
    address onlySellTo;
}

/// @notice Interface for CryptoPunks contract
/// @dev Interface for interacting with the original CryptoPunks contract
interface IPunks {
    function buyPunk(uint256 punkIndex) external payable;
    function offerPunkForSale(uint256 punkIndex, uint256 minSalePriceInWei) external;
    function punksOfferedForSale(uint256 punkId)
        external
        view
        returns (bool isForSale, uint256 punkIndex, address seller, uint256 minValue, address onlySellTo);
    function balanceOf(address owner) external view returns (uint256);
    function punkIndexToAddress(uint256 punkIndex) external view returns (address);
    function withdraw() external;
    function pendingWithdrawals(address owner) external view returns (uint256);
    function transferPunk(address to, uint256 punkIndex) external;
}

/// @notice Interface for ERC20 tokens (standard interface) with owner()
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function owner() external view returns (address);
}

/// @notice Interface for ERC721 NFT collections
/// @dev Standard ERC721 interface with additional owner() function for collection ownership and optional burn() function
interface IERC721 {
    function balanceOf(address owner) external view returns (uint256 balance);
    function ownerOf(uint256 tokenId) external view returns (address owner);
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function getApproved(uint256 tokenId) external view returns (address operator);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function owner() external view returns (address);
    function burn(uint256 tokenId) external;
}

interface IStrategy {
    function factory() external view returns (address);
    function router() external view returns (address);
    function poolManager() external view returns (address);
    function owner() external view returns (address);
    function addFees() external payable;
    function setPriceMultiplier(uint256 _newMultiplier) external;
    function updateName(string memory _tokenName) external;
    function updateSymbol(string memory _tokenSymbol) external;
    function updateHookAddress(address _hookAddress) external;
    function increaseTransferAllowance(uint256 amountAllowed) external;
    function getTransferAllowance() external view returns (uint256);
    function getImplementation() external view returns (address);
    function upgradeToAndCall(address newImplementation, bytes memory data) external;
    function setGlobalDistributor(address distributor) external;
}

/// @notice Interface for NFTStrategy contracts
/// @dev Core interface for NFT-backed ERC20 strategy tokens
interface INFTStrategy is IStrategy {
    function initialize(
        address _collection,
        address _hook,
        string memory _tokenName,
        string memory _tokenSymbol,
        uint256 _buyIncrement,
        address _owner
    ) external;
    function nftForSale(uint256 tokenId) external view returns (uint256);
    function sellTargetNFT(uint256 tokenId) external payable;
}

/// @notice Interface for BaseStrategyFactory contracts
/// @dev Factory interface for deploying and managing NFTStrategy contracts
interface IBaseStrategyFactory {
    function loadingLiquidity() external view returns (bool);
    function owner() external view returns (address);
    function strategyImplementation() external view returns (address);
    function setStrategyImplementation(address _strategyImplementation) external returns (address);
    function updateHookAddress(address _hookAddress) external returns (address);
    function disableLaunchUpgradeable() external;
    function updateLauncher(address _launcher, bool _authorized) external;
}

/// @notice Interface for NFTStrategyFactory contracts
/// @dev Factory interface for deploying and managing NFTStrategy contracts
interface INFTStrategyFactory is IBaseStrategyFactory {
    function nftStrategyImplementation() external view returns (address);
    function collectionToNFTStrategy(address collection) external view returns (address);
    function nftStrategyToCollection(address collection) external view returns (address);
    function setNftStrategyImplementation(address _nftStrategyImplementation) external returns (address);
    function ownerLaunchNFTStrategy(
        address collection,
        string memory tokenName,
        string memory tokenSymbol,
        address collectionOwner,
        uint256 buyIncrement
    ) external payable returns (address);
}

/// @notice Interface for NFTStrategyHook contracts
/// @dev Hook interface for fee management and distribution
interface INFTStrategyHook {
    function adminUpdateFeeAddress(address collection, address destination) external;
}

/// @notice Interface for NFTStrategyRange contracts
interface INFTStrategyRange {
    function addFees() external payable;
    function setPriceMultiplier(uint256 _newMultiplier) external;
    function updateName(string memory _tokenName) external;
    function updateSymbol(string memory _tokenSymbol) external;
    function nftForSale(uint256 tokenId) external view returns (uint256);
    function midSwap() external view returns (bool);
    function setMidSwap(bool value) external;
    function sellTargetNFT(uint256 tokenId) external payable;
    function increaseTransferAllowance(uint256 amountAllowed) external;
    function getTransferAllowance() external view returns (uint256);
}

/// @notice Interface for NFTStrategyRangeFactory contracts
interface INFTStrategyRangeFactory {
    function poolManager() external view returns (address);
    function loadingLiquidity() external view returns (bool);
    function deployerBuying() external view returns (bool);
    function owner() external view returns (address);
    function setRouter(address _router, bool status) external;
    function collectionToNFTStrategy(address collection) external view returns (address);
    function nftStrategyToCollection(address collection) external view returns (address);
    function routerRestrict() external view returns (bool);
    function setRouterRestrict(bool status) external;
    function validTransfer(address to, address from, address tokenAddress) external view returns (bool);
}

/// @notice Interface for NFTStrategyRangeHook contracts
interface INFTStrategyRangeHook {
    function adminUpdateFeeAddress(address collection, address destination) external;
}

/// @notice Interface for router validation
interface IValidRouter {
    function msgSender() external view returns (address);
}

/// @notice Interface for PunkStrategyPatch contracts
/// @dev Interface for patch contracts that manage PunkStrategy operations
interface IPunkStrategyPatch {
    function updateFeeBips(uint128 _feeBips) external;
    function setPriceMultiplier(uint256 _newMultiplier) external;
    function transferOwnership(address newOwner) external;
    function transferEther(address _to, uint256 _amount) external payable;
    function setReward(uint256 _newReward) external;
    function setTwapIncrement(uint256 _newIncrement) external;
    function setTwapDelayInBlocks(uint256 _newDelay) external;
    function buyPunkAndRelist(uint256 punkId) external returns (uint256);
    function processPunkSale() external returns (uint256);
    function processTokenTwap() external;
    function transferPunkStrategyOwnership(address newOwner) external;
    function addFees() external payable;
    function transferToken(address _token, address _to, uint256 _amount) external payable;
    function updateManualFees(bool _manuallyProcessFees) external;
    function updateFeeSplit(IFeeSplit _feeSplit) external;
    function owner() external view returns (address);
}

interface IGlobalDistributor {
    function isGlobalDistributor(address) external view returns (bool);
}

interface IERC20Strategy is IStrategy {
    function initialize(
        address _collection,
        uint256 _bagSize,
        address _hook,
        string memory _tokenName,
        string memory _tokenSymbol,
        uint256 _buyIncrement,
        address _owner
    ) external;
}

interface IERC20StrategyFactory is IBaseStrategyFactory {
    function tokenToStrategy(address token) external view returns (address);
    function startegyToToken(address strategy) external view returns (address);
    function ownerLaunchStrategy(
        address token,
        uint256 bagSize,
        string memory tokenName,
        string memory tokenSymbol,
        address strategyFeeAddress,
        uint256 buyIncrement
    ) external payable returns (address);
}

interface IERC1155Strategy is IStrategy {
    enum StrategyType {
        Range,
        List,
        All
    }

    function initialize(
        address _collection,
        StrategyType _strategyType,
        uint256[] memory _ids,
        address _hook,
        string memory _tokenName,
        string memory _tokenSymbol,
        uint256 _buyIncrement,
        address _owner
    ) external;
}

interface IERC1155StrategyFactory {
    function ownerLaunchStrategy(
        address collection,
        IERC1155Strategy.StrategyType strategyType,
        uint256[] memory ids,
        string memory tokenName,
        string memory tokenSymbol,
        address collectionOwner,
        uint256 buyIncrement
    ) external payable returns (address);
}

interface IRecursiveStrategyFactory {
    function ownerLaunchStrategy(
        string memory tokenName,
        string memory tokenSymbol,
        string memory metadata,
        address feeAddress
    ) external payable returns (address);
}

/* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
/*                  SEAPORT TYPES                      */
/* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

enum ItemType {
    NATIVE,
    ERC20,
    ERC721,
    ERC1155,
    ERC721_WITH_CRITERIA,
    ERC1155_WITH_CRITERIA
}

enum OrderType {
    FULL_OPEN,
    PARTIAL_OPEN,
    FULL_RESTRICTED,
    PARTIAL_RESTRICTED,
    CONTRACT
}

struct OfferItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
}

struct ConsiderationItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
    address payable recipient;
}

struct OrderParameters {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 totalOriginalConsiderationItems;
}

struct OrderComponents {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 counter;
}

struct Order {
    OrderParameters parameters;
    bytes signature;
}

interface ISeaport {
    function validate(Order[] calldata orders) external returns (bool);
    function cancel(OrderComponents[] calldata orders) external returns (bool);
    function incrementCounter() external returns (uint256 newCounter);
    function getCounter(address offerer) external view returns (uint256);
    function getOrderHash(OrderComponents calldata order) external view returns (bytes32);
    function getOrderStatus(bytes32 orderHash) external view returns (
        bool isValidated,
        bool isCancelled,
        uint256 totalFilled,
        uint256 totalSize
    );
    function information() external view returns (
        string memory version,
        bytes32 domainSeparator,
        address conduitController
    );
}
