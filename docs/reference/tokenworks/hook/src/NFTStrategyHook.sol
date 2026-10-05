// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPunkStrategy, IValidRouter} from "./Interfaces.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import "./Interfaces.sol";

/// @title NFTStrategyHook - Uniswap V4 Hook for NFTStrategy
/// @author TokenWorks (https://token.works/)
/// @notice This hook manages fee collection and distribution for NFTStrategy pools on Uniswap V4
/// @dev Implements dynamic fee structure that decreases over time after deployment
contract NFTStrategyHook is BaseHook, ReentrancyGuard {
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

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using SafeCast for int128;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                      CONSTANTS                      */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Total basis points for percentage calculations
    uint128 private constant TOTAL_BIPS = 10000;
    /// @notice Default fee rate (10%)
    uint128 private constant DEFAULT_FEE = 1000;
    /// @notice Starting buy fee rate (99%) - decreases over time
    uint128 private constant STARTING_BUY_FEE = 9900;
    /// @notice Seconds per minute for time calculations
    uint256 private constant SECONDS_PER_MINUTE = 60;
    /// @notice Maximum price limit for swaps
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    /// @notice Minimum price limit for swaps
    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    /// @notice The PunkStrategy token contract
    IPunkStrategy immutable punkStrategy;
    /// @notice The NFTStrategyFactory contract
    INFTStrategyFactory immutable nftStrategyFactory;
    /// @notice The Uniswap V4 Pool Manager
    IPoolManager immutable manager;
    /// @notice Default address to receive protocol fees
    address public feeAddress;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                   STATE VARIABLES                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Mapping of collection addresses to their deployment timestamps
    mapping(address => uint256) public deploymentTime;
    /// @notice Mapping of collection addresses to custom fee recipient addresses
    mapping(address => address) public feeAddressClaimedByOwner;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    CUSTOM ERRORS                    */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Caller is not an authorized NFTStrategy contract
    error NotNFTStrategy();
    /// @notice Caller is not the NFTStrategyFactory owner
    error NotNFTStrategyFactoryOwner();
    /// @notice Invalid or unrecognized collection address
    error InvalidCollection();
    /// @notice Caller is not the owner of the NFT collection
    error NotCollectionOwner();
    /// @notice Restrict ExactOutput swaps
    error ExactOutputNotAllowed();

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    CUSTOM EVENTS                    */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Emitted when fees are collected from a swap
    event HookFee(bytes32 indexed id, address indexed sender, uint128 feeAmount0, uint128 feeAmount1);
    /// @notice Emitted when a trade occurs in an NFTStrategy pool
    event Trade(address indexed nftStrategy, uint160 sqrtPriceX96, int128 ethAmount, int128 tokenAmount);

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                     CONSTRUCTOR                     */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Constructor initializes the hook with required dependencies
    /// @param _poolManager The Uniswap V4 Pool Manager interface
    /// @param _punkStrategy The PunkStrategy token contract
    /// @param _nftStrategyFactory The NFTStrategyFactory contract
    /// @param _feeAddress Address to send a portion of the fees
    /// @dev Sets up immutable references to core contracts
    constructor(
        IPoolManager _poolManager,
        IPunkStrategy _punkStrategy,
        INFTStrategyFactory _nftStrategyFactory,
        address _feeAddress
    ) BaseHook(_poolManager) {
        manager = _poolManager;
        punkStrategy = _punkStrategy;
        nftStrategyFactory = _nftStrategyFactory;
        feeAddress = _feeAddress;
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                     FUNCTIONS                       */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Updates the fee address for receiving protocol fees
    /// @param _feeAddress New address to receive fees
    /// @dev Only callable by the NFTStrategyFactory owner
    function updateFeeAddress(address _feeAddress) external {
        if (msg.sender != nftStrategyFactory.owner()) revert NotNFTStrategyFactoryOwner();
        feeAddress = _feeAddress;
    }

    /// @notice Updates the fee address for a specific NFT strategy collection
    /// @param nftStrategy The NFT strategy contract address
    /// @param destination New address to receive fees for this collection
    /// @dev Only callable by the NFT collection owner
    function updateFeeAddressForCollection(address nftStrategy, address destination) external {
        address collection = nftStrategyFactory.nftStrategyToCollection(nftStrategy);
        if (collection == address(0)) revert InvalidCollection();
        if (IERC721(collection).owner() != msg.sender) revert NotCollectionOwner();
        feeAddressClaimedByOwner[nftStrategy] = destination;
    }

    /// @notice Updates the fee address for a collection by admin or factory
    /// @param nftStrategy The NFT strategy contract address
    /// @param destination New address to receive fees for this collection
    /// @dev Only callable by NFTStrategyFactory owner or the factory contract itself
    function adminUpdateFeeAddress(address nftStrategy, address destination) external {
        if (msg.sender != nftStrategyFactory.owner() && msg.sender != address(nftStrategyFactory)) {
            revert NotNFTStrategyFactoryOwner();
        }
        feeAddressClaimedByOwner[nftStrategy] = destination;
    }

    /// @notice Process fees directly - distributes immediately
    /// @param collection The NFTStrategy collection address
    /// @param feeAmount Amount of ETH fees to distribute
    /// @dev Distributes 80% to collection, 10% to PunkStrategy, 10% to fee address
    function _processFees(address collection, uint256 feeAmount) internal {
        if (feeAmount == 0) return;

        // Calculate 80% for the specific NFTStrategy, 10% for PunkStrategy, and 10% for feeAddress
        uint256 depositAmount = (feeAmount * 80) / 100;
        uint256 pnkstrAmount = (feeAmount * 10) / 100;
        uint256 ownerAmount = feeAmount - depositAmount - pnkstrAmount;

        // Deposit fees into NFTStrategy collection
        INFTStrategy(collection).addFees{value: depositAmount}();

        // Send fees to nftStrategyFactory to buy and burn PNKSTR
        SafeTransferLib.forceSafeTransferETH(address(nftStrategyFactory), pnkstrAmount);

        // Send remainder to feeAddressClaimedByOwner if claimed, otherwise feeAddress
        SafeTransferLib.forceSafeTransferETH(
            feeAddressClaimedByOwner[collection] == address(0) ? feeAddress : feeAddressClaimedByOwner[collection],
            ownerAmount
        );
    }

    /// @notice Calculates current fee based on deployment timestamp and swap direction
    /// @param collection The NFTStrategy collection address
    /// @param isBuying True if buying tokens (ETH -> tokens), false if selling
    /// @return Current fee in basis points
    /// @dev Buy fees decrease over time from 99% to 10%, sell fees are constant 10%
    function calculateFee(address collection, bool isBuying) public view returns (uint128) {
        if (!isBuying) return DEFAULT_FEE;

        uint256 deployedAt = deploymentTime[collection];
        if (deployedAt == 0) return DEFAULT_FEE;

        uint256 timePassed = block.timestamp - deployedAt;
        uint256 minutesPassed = timePassed / SECONDS_PER_MINUTE;
        uint256 feeReductions = minutesPassed * 100; // 100 bips per minute

        uint256 maxReducible = STARTING_BUY_FEE - DEFAULT_FEE; // assumes invariant holds
        if (feeReductions >= maxReducible) return DEFAULT_FEE;

        return uint128(STARTING_BUY_FEE - feeReductions);
    }

    /// @notice Returns the hook's permissions for the Uniswap V4 pool
    /// @return Hooks.Permissions struct indicating which hooks are enabled
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Validates initialization of a new pool
    /// @param key The pool key containing currency pair and hook information
    /// @return Selector indicating successful hook execution
    /// @dev Only allows ETH/token pools and validates call is from NFTStrategyFactory
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        require(key.currency0.isAddressZero(), "Only ETH/token pools are supported");
        // Ensure the call is coming from NFTStrategyFactory
        if (!nftStrategyFactory.loadingLiquidity()) {
            revert NotNFTStrategy();
        }

        // Get token1 from the pool key and store its deployment timestamp
        address collection = Currency.unwrap(key.currency1);
        deploymentTime[collection] = block.timestamp;

        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Validates liquidity addition to a pool
    /// @param key The pool key containing currency pair information
    /// @param delta The balance changes from the liquidity addition
    /// @return Hook selector and zero delta
    /// @dev Only allows liquidity addition during factory loading, sets transfer allowance
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        // Ensure the call is coming from NFTStrategyFactory
        if (!nftStrategyFactory.loadingLiquidity()) {
            revert NotNFTStrategy();
        } else {
            // we are loading liquidity so admit a transfer allowance
            // safe casting, liquidity additions are -values
            INFTStrategy(Currency.unwrap(key.currency1)).increaseTransferAllowance(uint256(int256(-delta.amount1())));
        }
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Processes swap events and takes the swap fee
    /// @param sender The address initiating the call (router)
    /// @param key The pool key containing token pair and fee information
    /// @param params Swap parameters including direction and amount
    /// @param delta Balance changes resulting from the swap
    /// @return Hook selector and fee amount taken
    /// @dev Calculates dynamic fees, takes fee from swap, and distributes to recipients
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Restrict Exact Out
        if (params.amountSpecified > 0) {
            revert ExactOutputNotAllowed();
        }

        // Calculate fee based on the swap amount
        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) =
            (specifiedTokenIs0) ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());

        if (swapAmount < 0) swapAmount = -swapAmount;

        bool ethFee = Currency.unwrap(feeCurrency) == address(0);
        address collection = Currency.unwrap(key.currency1);

        uint128 currentFee = calculateFee(collection, params.zeroForOne);
        uint256 feeAmount = uint128(swapAmount) * currentFee / TOTAL_BIPS;

        // regardless if NFTSTR is inbound or outbound from PoolManager, we need to set the transfer allowance
        uint256 collectionAmountToTransfer =
            delta.amount1() < 0 ? uint256(int256(-delta.amount1())) : uint256(int256(delta.amount1()));

        if (feeAmount == 0) {
            INFTStrategy(collection).increaseTransferAllowance(collectionAmountToTransfer);
            return (BaseHook.afterSwap.selector, 0);
        }

        // account for "fees-in-NFTSTR" for the transfer allowance
        // for exact inputs (ETH --> ??? NFTSTR) the fee is skimmed from delta.amount1() but its transferred to the hook
        collectionAmountToTransfer += (feeCurrency == key.currency1) ? feeAmount : 0;

        // for exact outputs because we are taking a surplus fee to the hook and then swapping again
        // i.e. PoolManager --feeAmount--> Hook --feeAmount--> PoolManager
        collectionAmountToTransfer += (feeCurrency == key.currency1 && 0 < params.amountSpecified) ? feeAmount * 2 : 0;

        INFTStrategy(collection).increaseTransferAllowance(collectionAmountToTransfer);

        manager.take(feeCurrency, address(this), feeAmount);

        // Emit the HookFee event, after taking the fee
        emit HookFee(
            PoolId.unwrap(key.toId()), sender, ethFee ? uint128(feeAmount) : 0, ethFee ? 0 : uint128(feeAmount)
        );

        // Handle fee token deposit or conversion
        if (!ethFee) {
            uint256 feeInETH = _swapToEth(key, feeAmount);
            _processFees(collection, feeInETH);
        } else {
            // Fee amount is in ETH
            _processFees(collection, feeAmount);
        }

        // Get current price and emit
        emit Trade(collection, _getCurrentPrice(key), delta.amount0(), delta.amount1());

        return (BaseHook.afterSwap.selector, feeAmount.toInt128());
    }

    /// @notice Swaps tokens to ETH for fee processing
    /// @param key The pool key for the swap
    /// @param amount The amount of tokens to swap
    /// @return The amount of ETH received from the swap
    /// @dev Internal function to convert token fees to ETH before distribution
    function _swapToEth(PoolKey memory key, uint256 amount) internal returns (uint256) {
        uint256 ethBefore = address(this).balance;

        BalanceDelta delta = manager.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            bytes("")
        );

        // Handle token settlements, it's ALWAYS a oneForZero swap
        key.currency1.settle(poolManager, address(this), uint256(int256(-delta.amount1())), false);
        key.currency0.take(poolManager, address(this), uint256(int256(delta.amount0())), false);

        return address(this).balance - ethBefore;
    }

    /// @notice Gets the current price of a token pair from the pool
    /// @param key The pool key containing the token pair and pool parameters
    /// @return The current sqrtPriceX96 from slot0
    /// @dev Reads the current price from the pool's slot0 storage
    function _getCurrentPrice(PoolKey calldata key) internal view returns (uint160) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        return sqrtPriceX96;
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {}
}
