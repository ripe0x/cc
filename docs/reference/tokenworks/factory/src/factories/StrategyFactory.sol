// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {
    IPositionManager
} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {
    IAllowanceTransfer
} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUniswapV4Router04} from "v4-router/interfaces/IUniswapV4Router04.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "../Interfaces.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

/// @title BaseFactory - Shared code betweens factories
/// @author TokenWorks (https://token.works/)
contract StrategyFactory is Ownable, ReentrancyGuard {
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™                ™™™™™™™™™™™                ™™™™™™™™™™™ */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™               ™™™™™™™™™™™™               ™™™™™™™™™™  */
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
    /*                      CONSTANTS                      */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice ETH amount used for initial liquidity pairing
    uint256 internal constant ethToPair = 2 wei;
    /// @notice Uniswap V4 Position Manager for liquidity operations
    IPositionManager internal immutable posm;
    /// @notice Permit2 contract for token approvals
    IAllowanceTransfer internal immutable permit2;
    /// @notice Uniswap V4 Router for token swaps
    IUniswapV4Router04 internal immutable router;
    /// @notice Uniswap V4 Pool Manager for pool operations
    IPoolManager internal immutable poolManager;

    /// @notice PunkStrategy token contract address
    address public constant PNKSTR_ADDRESS =
        0xc50673EDb3A7b94E8CAD8a7d4E0cD68864E33eDF;
    /// @notice PunkStrategy hook contract address
    address public constant PNKSTR_HOOK_ADDRESS =
        0xfAaad5B731F52cDc9746F2414c823eca9B06E844;
    /// @notice Dead address for burning tokens
    address public constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                   STATE VARIABLES                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Mapping of addresses that can launch strategies
    mapping(address => bool) public launchers;
    /// @notice The Uniswap V4 hook that controls the logic of new deployments
    address public hookAddress;
    /// @notice Gates the NFTStrategyHook to only when we're loading a new token
    bool public loadingLiquidity;
    /// @notice Controls upgradeability of new strategy contracts
    bool public launchUpgradeable;
    /// @notice The address to send deployment fees to
    address public feeAddress;
    /// @notice TWAP increment when buying PNKSTR tokens
    uint256 public twapIncrement = 1 ether;
    /// @notice TWAP delay in blocks when buying PNKSTR tokens
    uint256 public twapDelayInBlocks = 1;
    /// @notice Last block number when TWAP was executed
    uint256 public lastTwapBlock;
    /// @notice strategy implementation
    address public strategyImplementation;
    /// @notice global distributor set on strategies
    address public globalDistributor;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    CUSTOM ERRORS                    */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Hook address has not been set
    error HookNotSet();
    /// @notice No ETH available for TWAP operations
    error NoETHToTwap();
    /// @notice Not enough blocks have passed since last TWAP
    error TwapDelayNotMet();
    /// @notice triggered when withdraw fails
    error WithdrawFailed();

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                     CONSTRUCTOR                     */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Constructor initializes the factory with required dependencies
    /// @param _posm Uniswap V4 Position Manager address
    /// @param _permit2 Permit2 contract address
    /// @param _router Uniswap V4 Router address
    /// @param _poolManager Uniswap V4 Pool Manager address
    /// @param _feeAddress Address to receive deployment fees
    /// @param _globalDistributor global distributor
    /// @param _owner the contract owner
    /// @dev Sets up immutable references
    constructor(
        address _posm,
        address _permit2,
        address payable _router,
        address _poolManager,
        address _feeAddress,
        address _globalDistributor,
        address _owner
    ) {
        posm = IPositionManager(_posm);
        permit2 = IAllowanceTransfer(_permit2);
        router = IUniswapV4Router04(_router);
        poolManager = IPoolManager(_poolManager);
        feeAddress = _feeAddress;
        globalDistributor = _globalDistributor;

        // Enable upgradeability by default
        launchUpgradeable = true;

        _initializeOwner(_owner);
    }

    /// @notice Restricts function access to authorized launchers or owner
    modifier onlyLauncher() {
        if (!launchers[msg.sender] && msg.sender != Ownable.owner())
            revert Unauthorized();
        _;
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    ADMIN FUNCTIONS                  */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Sets the implementation of the strategy contract
    /// @param _strategyImplementation Address of the strategy implementation contract
    /// @dev Only callable by owner
    function setStrategyImplementation(
        address _strategyImplementation
    ) external onlyOwner {
        strategyImplementation = _strategyImplementation;
    }

    /// @notice Disables the upgradeability of new strategy launches
    /// @dev Only callable by owner
    function disableLaunchUpgradeable() external onlyOwner {
        launchUpgradeable = false;
    }

    /// @notice Updates the hook attached to new strategy pools
    /// @param _hookAddress New Uniswap v4 hook address
    /// @dev Only callable by owner
    function updateHookAddress(address _hookAddress) external onlyOwner {
        hookAddress = _hookAddress;
    }

    /// @notice Updates whether an address is authorized as a launcher
    /// @param _launcher Address to update launcher status for
    /// @param _authorized Whether the address should be authorized as a launcher
    /// @dev Only callable by owner
    function updateLauncher(
        address _launcher,
        bool _authorized
    ) external onlyOwner {
        launchers[_launcher] = _authorized;
    }

    /// @notice Updates the name of a specific strategy token
    /// @param strategy Address of the Strategy contract
    /// @param tokenName New name for the token
    function updateTokenName(
        address strategy,
        string memory tokenName
    ) external onlyOwner {
        IStrategy(strategy).updateName(tokenName);
    }

    /// @notice Updates the symbol of a specific strategy token
    /// @param strategy Address of the Strategy contract
    /// @param tokenSymbol New symbol for the token
    function updateTokenSymbol(
        address strategy,
        string memory tokenSymbol
    ) external onlyOwner {
        IStrategy(strategy).updateSymbol(tokenSymbol);
    }

    /// @notice Updates the price multiplier for a specific strategy
    /// @param strategy Address of the strategy contract
    /// @param newMultiplier New multiplier in basis points (1100 = 1.1x)
    function updatePriceMultiplier(
        address strategy,
        uint256 newMultiplier
    ) external onlyOwner {
        IStrategy(strategy).setPriceMultiplier(newMultiplier);
    }

    /// @notice Updates the global distributor for a specific strategy
    /// @param strategy the strategy
    /// @param distributor the new distributor
    function updateGlobalDistributor(
        address strategy,
        address distributor
    ) external onlyOwner {
        IStrategy(strategy).setGlobalDistributor(distributor);
    }

    /// @notice Updates the global distributor in storage
    function setGlobalDistributor(address distributor) external onlyOwner {
        globalDistributor = distributor;
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                  INTERNAL FUNCTIONS                 */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Internal function to load initial liquidity into the Uniswap V4 pool
    /// @param _token Address of the strategy ERC20 token
    /// @dev Creates pool, initializes with starting price, and adds liquidity
    function _loadLiquidity(address _token) internal {
        loadingLiquidity = true;

        // Create the pool with ETH (currency0) and TOKEN (currency1)
        Currency currency0 = Currency.wrap(address(0)); // ETH
        Currency currency1 = Currency.wrap(_token); // strategy Token

        uint24 lpFee = 0;
        int24 tickSpacing = 60;

        uint256 token0Amount = 1; // 1 wei
        uint256 token1Amount = 1_000_000_000 * 10 ** 18; // 1B TOKEN

        // 10e18 ETH = 1_000_000_000e18 TOKEN
        uint160 startingPrice = 501082896750095888663770159906816;

        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = int24(175020);

        PoolKey memory key = PoolKey(
            currency0,
            currency1,
            lpFee,
            tickSpacing,
            IHooks(hookAddress)
        );
        bytes memory hookData = new bytes(0);

        // Hardcoded from LiquidityAmounts.getLiquidityForAmounts
        uint128 liquidity = 158372218983990412488087;

        uint256 amount0Max = token0Amount + 1 wei;
        uint256 amount1Max = token1Amount + 1 wei;

        (
            bytes memory actions,
            bytes[] memory mintParams
        ) = _mintLiquidityParams(
                key,
                tickLower,
                tickUpper,
                liquidity,
                amount0Max,
                amount1Max,
                DEAD_ADDRESS,
                hookData
            );

        bytes[] memory params = new bytes[](2);

        params[0] = abi.encodeWithSelector(
            posm.initializePool.selector,
            key,
            startingPrice,
            hookData
        );

        params[1] = abi.encodeWithSelector(
            posm.modifyLiquidities.selector,
            abi.encode(actions, mintParams),
            block.timestamp + 60
        );

        uint256 valueToPass = amount0Max;
        permit2.approve(
            _token,
            address(posm),
            type(uint160).max,
            type(uint48).max
        );

        posm.multicall{value: valueToPass}(params);

        loadingLiquidity = false;
    }

    /// @notice Creates parameters for minting liquidity in Uniswap V4
    /// @param poolKey The pool key for the liquidity position
    /// @param _tickLower Lower tick boundary
    /// @param _tickUpper Upper tick boundary
    /// @param liquidity Amount of liquidity to mint
    /// @param amount0Max Maximum amount of token0 to use
    /// @param amount1Max Maximum amount of token1 to use
    /// @param recipient Address to receive the liquidity position
    /// @param hookData Additional data for hooks
    /// @return Encoded actions and parameters for position manager
    /// @dev Internal helper for liquidity operations
    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory, bytes[] memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            _tickLower,
            _tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            recipient,
            hookData
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        return (actions, params);
    }

    /// @notice Buys PNKSTR tokens with ETH and burns them by sending to dead address
    /// @param amountIn The amount of ETH to spend on PNKSTR tokens
    /// @dev Uses PunkStrategy pool to swap ETH for PNKSTR and burn
    function _buyAndBurnPNKSTR(uint256 amountIn) internal {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(PNKSTR_ADDRESS),
            0,
            60,
            IHooks(PNKSTR_HOOK_ADDRESS)
        );

        router.swapExactTokensForTokens{value: amountIn}(
            amountIn,
            0,
            true,
            key,
            "",
            DEAD_ADDRESS,
            block.timestamp
        );
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    USER FUNCTIONS                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Processes PNKSTR token buyback using TWAP mechanism
    /// @dev Can be called once every twapDelayInBlocks, caller receives 0.5% reward
    /// @dev Uses contract's ETH balance to buy and burn PNKSTR tokens
    function processTokenTwap() external nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoETHToTwap();

        // Check if enough blocks have passed since last TWAP
        if (block.number < lastTwapBlock + twapDelayInBlocks)
            revert TwapDelayNotMet();

        // Calculate amount to burn - either twapIncrement or remaining ethToTwap
        uint256 burnAmount = twapIncrement;
        if (balance < twapIncrement) {
            burnAmount = balance;
        }

        // Set reward to 0.5% of burnAmount
        uint256 reward = (burnAmount * 5) / 1000;
        burnAmount -= reward;

        // Update state
        lastTwapBlock = block.number;

        _buyAndBurnPNKSTR(burnAmount);

        // Send reward to caller
        SafeTransferLib.forceSafeTransferETH(msg.sender, reward);
    }

    /// @notice Allows the contract to receive ETH for twap
    receive() external payable {}

    function withdraw(address to) external onlyOwner {
        (bool ok, ) = to.call{value: address(this).balance}("");
        if (!ok) {
            revert WithdrawFailed();
        }
    }
}
