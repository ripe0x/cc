// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IUniswapV4Router04} from "v4-router/interfaces/IUniswapV4Router04.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {IGlobalDistributor} from "../Interfaces.sol";

/// @title BaseStrategy - An ERC20 token
/// @author TokenWorks (https://token.works/)
/// @notice This contract implements an ERC20 token backed by another token.
///         Users can trade the token on Uniswap V4, and the contract uses trading fees to buy bags of the underlying token.
/// @dev Uses ERC1967 proxy pattern with immutable args for gas-efficient upgrades
abstract contract BaseStrategy is
    Initializable,
    UUPSUpgradeable,
    Ownable,
    ReentrancyGuard,
    ERC20
{
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

    /// @notice Maximum token supply (1 billion tokens)
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;
    /// @notice Dead address for burning tokens
    address public constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;
    /// @notice Address of the Global Distribution Handler
    address public constant GLOBAL_DISTRIBUTION_HANDLER =
        0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D;
    /// @notice ETH amount increment for maximum buy price calculation
    uint256 public buyIncrement;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                   STATE VARIABLES                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice The name of the ERC20 token
    string tokenName;
    /// @notice The symbol of the ERC20 token
    string tokenSymbol;
    /// @notice Address of the Uniswap V4 hook contract
    address public hookAddress;
    /// @notice Multiplier for tokens resale price (in basis points, e.g., 1200 = 1.2x)
    uint256 public priceMultiplier;
    /// @notice Current accumulated fees available for tokens purchases
    uint256 public currentFees;
    /// @notice ETH accumulated from tokens sales, waiting to be used for token buyback
    uint256 public ethToTwap;
    /// @notice Amount of ETH to use per TWAP buyback operation
    uint256 public twapIncrement;
    /// @notice Number of blocks to wait between TWAP operations
    uint256 public twapDelayInBlocks;
    /// @notice Block number of the last TWAP operation
    uint256 public lastTwapBlock;
    /// @notice Block number when the last tokens was bought
    uint256 public lastBuyBlock;
    /// @notice Mapping of addresses that can distribute tokens freely (team wallets, airdrop contracts)
    mapping(address => bool) public isDistributor;
    /// @notice address of the globalDistributor
    address public globalDistributor;

    /// @notice Storage gap for future upgrades (prevents storage collisions)
    uint256[49] private __gap;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                   CUSTOM EVENTS                     */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Emitted when transfer allowance is increased by the hook
    event AllowanceIncreased(uint256 amount);
    /// @notice Emitted when transfer allowance is spent
    event AllowanceSpent(
        address indexed from,
        address indexed to,
        uint256 amount
    );
    /// @notice Emitted when the contract implementation is upgraded
    event ContractUpgraded(
        address indexed oldImplementation,
        address indexed newImplementation,
        uint256 version
    );
    /// @notice Emitted when a distributor's whitelist status is updated
    event DistributorUpdated(address indexed distributor, bool status);
    /// @notice Emitted when _buyAndBurnTokens is called
    event BoughtAndBurned(int256 eth, int256 burned);

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    CUSTOM ERRORS                    */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Price multiplier is outside valid range
    error InvalidMultiplier();
    /// @notice No ETH available for TWAP operations
    error NoETHToTwap();
    /// @notice Not enough blocks have passed since last TWAP
    error TwapDelayNotMet();
    /// @notice Not enough ETH in fees to make purchase
    error NotEnoughEth();
    /// @notice Purchase price exceeds time-based maximum
    error PriceTooHigh();
    /// @notice Caller is not the factory contract
    error NotFactory();
    /// @notice Caller is not the authorized hook contract
    error OnlyHook();
    /// @notice Token transfer not authorized
    error InvalidTransfer();

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    CONSTRUCTOR                      */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /// @notice Constructor disables initializers to prevent implementation contract initialization
    /// @dev This is required for the proxy pattern to work correctly
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract with required addresses and permissions
    /// @param _hook Address of the StrategyHook contract
    /// @param _tokenName Name of the token
    /// @param _tokenSymbol Symbol of the token
    /// @param _buyIncrement Buy increment for the token
    /// @param _owner Owner of the contract
    function __BaseStrategy_init(
        address _hook,
        string memory _tokenName,
        string memory _tokenSymbol,
        uint256 _buyIncrement,
        address _owner
    ) internal {
        require(bytes(_tokenName).length > 0, "Empty name");
        require(bytes(_tokenSymbol).length > 0, "Empty symbol");

        hookAddress = _hook;
        tokenName = _tokenName;
        tokenSymbol = _tokenSymbol;
        lastBuyBlock = block.number;
        buyIncrement = _buyIncrement;

        // Initialize owner without validation in-case we want to disable upgradeability
        _initializeOwner(_owner);

        // Initialize state variables that have default values
        priceMultiplier = 1200; // 1.2x
        twapIncrement = 1 ether;
        twapDelayInBlocks = 1;

        _mint(factory(), MAX_SUPPLY);
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                     MODIFIERS                       */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Restricts function access to the factory contract only
    modifier onlyFactory() {
        if (msg.sender != factory()) revert NotFactory();
        _;
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                   ADMIN FUNCTIONS                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice version of the strategy
    function VERSION() public pure virtual returns (uint256);

    /// @notice Authorizes contract upgrades (UUPS pattern)
    /// @param newImplementation Address of the new implementation contract
    /// @dev Only callable by contract owner, validates implementation is a contract
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {
        require(newImplementation != address(0), "Invalid implementation");
        require(
            newImplementation.code.length > 0,
            "Implementation must be contract"
        );
        emit ContractUpgraded(address(this), newImplementation, VERSION());
    }

    /// @notice Updates the hook address
    /// @dev Can only be called by the owner
    /// @param _hookAddress New hook address
    function updateHookAddress(address _hookAddress) external onlyOwner {
        hookAddress = _hookAddress;
    }

    /// @notice Returns the name of the token
    /// @return The token name as a string
    function name() public view override returns (string memory) {
        return tokenName;
    }

    /// @notice Returns the symbol of the token
    /// @return The token symbol as a string
    function symbol() public view override returns (string memory) {
        return tokenSymbol;
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                   FACTORY FUNCTIONS                 */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Updates the name of the token
    /// @dev Can only be called by the factory
    /// @param _tokenName New name for the token
    function updateName(string memory _tokenName) external onlyFactory {
        tokenName = _tokenName;
    }

    /// @notice Updates the symbol of the token
    /// @dev Can only be called by the factory
    /// @param _tokenSymbol New symbol for the token
    function updateSymbol(string memory _tokenSymbol) external onlyFactory {
        tokenSymbol = _tokenSymbol;
    }

    /// @notice Updates the price multiplier for relisting punks
    /// @param _newMultiplier New multiplier in basis points (1100 = 1.1x, 10000 = 10.0x)
    /// @dev Only callable by factory. Must be between 1.1x (1100) and 10.0x (10000)
    function setPriceMultiplier(uint256 _newMultiplier) external onlyFactory {
        if (_newMultiplier < 1100 || _newMultiplier > 10000)
            revert InvalidMultiplier();
        priceMultiplier = _newMultiplier;
    }

    /// @notice Allows factory to whitelist addresses that can distribute tokens freely
    /// @param distributor Address to whitelist
    /// @param status True to whitelist, false to remove from whitelist
    /// @dev Only callable by factory. Enables fee-free token distribution for whitelisted addresses
    function setDistributor(
        address distributor,
        bool status
    ) external onlyFactory {
        isDistributor[distributor] = status;
        emit DistributorUpdated(distributor, status);
    }

    /// @notice allows factory to set the global distributor
    function setGlobalDistributor(address distributor) external onlyFactory {
        globalDistributor = distributor;
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                 MECHANISM FUNCTIONS                 */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Returns the maximum price allowed for buying the next batch of tokens, increasing over time
    /// @return The maximum price in ETH (wei) that can be used for buying
    /// @dev Increases by buyIncrement per block from last buy
    function getMaxPriceForBuy() public view returns (uint256) {
        // Calculate blocks since last buy
        uint256 blocksSinceLastBuy = block.number - lastBuyBlock;

        // Return buyIncrement for each block, starting at 1 block minimum
        return (blocksSinceLastBuy + 1) * buyIncrement;
    }

    /// @notice Allows the hook to deposit trading fees into the contract
    /// @dev Only callable by the authorized hook contract, uses msg.value for fee amount
    function addFees() external payable virtual {
        if (msg.sender != hookAddress) revert OnlyHook();

        // If we're adding more than buyIncrement and currentFees < getMaxPriceForBuy, backset lastBuyBlock so the max it will pay is the previous currentFees.
        if (msg.value > buyIncrement) {
            uint256 currentMaxBuy = getMaxPriceForBuy();
            if (currentFees + msg.value < currentMaxBuy) {
                // Calculate lastBuyBlock such that getMaxPriceForBuy() returns currentFees
                lastBuyBlock = block.number - (currentFees / buyIncrement);
            }
        }

        currentFees += msg.value;
    }

    /// @notice Increases the transient transfer allowance for pool operations
    /// @param amountAllowed Amount to add to the current allowance
    /// @dev Only callable by the hook contract, uses transient storage
    function increaseTransferAllowance(uint256 amountAllowed) external {
        if (msg.sender != hookAddress) revert OnlyHook();
        uint256 currentAllowance = getTransferAllowance();
        assembly {
            tstore(0, add(currentAllowance, amountAllowed))
        }
        emit AllowanceIncreased(amountAllowed);
    }

    //// @notice Returns the currently available funds to buy a new bag of tokens
    /// @return The available funds
    function availableFunds() public view returns (uint256) {
        uint256 fees = currentFees;
        uint256 maxBuy = getMaxPriceForBuy();

        return maxBuy < fees ? maxBuy : fees;
    }

    /// @notice Processes token buyback using TWAP mechanism
    /// @dev Can be called once every twapDelayInBlocks, uses ethToTwap for buyback
    /// @dev Caller receives 0.5% reward, remaining ETH is used to buy and burn tokens
    function processTokenTwap() external nonReentrant {
        if (ethToTwap == 0) revert NoETHToTwap();

        // Check if enough blocks have passed since last TWAP
        if (block.number < lastTwapBlock + twapDelayInBlocks)
            revert TwapDelayNotMet();

        // Calculate amount to burn - either twapIncrement or remaining ethToTwap
        uint256 burnAmount = twapIncrement;
        if (ethToTwap < twapIncrement) {
            burnAmount = ethToTwap;
        }

        // Set reward to 0.5% of burnAmount
        uint256 reward = (burnAmount * 5) / 1000;
        burnAmount -= reward;

        // Update state
        ethToTwap -= burnAmount + reward;
        lastTwapBlock = block.number;

        _buyAndBurnTokens(burnAmount);

        // Send reward to caller
        SafeTransferLib.forceSafeTransferETH(msg.sender, reward);
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                  INTERNAL FUNCTIONS                 */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Buys tokens with ETH and burns them by sending to dead address
    /// @param amountIn The amount of ETH to spend on tokens that will be burned
    /// @dev Creates a pool key and swaps ETH for tokens, sending tokens to dead address
    function _buyAndBurnTokens(uint256 amountIn) internal {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(this)),
            0,
            60,
            IHooks(hookAddress)
        );

        BalanceDelta delta = router().swapExactTokensForTokens{value: amountIn}(
            amountIn,
            0,
            true,
            key,
            "",
            DEAD_ADDRESS,
            block.timestamp
        );

        emit BoughtAndBurned(int256(delta.amount0()), int256(delta.amount1()));
    }

    /// @notice Validates token transfers using a transient allowance system
    /// @param from The address sending tokens
    /// @param to The address receiving tokens
    /// @param amount The amount of tokens being transferred
    /// @dev Reverts if transfer isn't through the hook
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // On strategy launch, we need to allow for supply mint transfer
        if (from == address(0)) {
            return;
        }

        address distributor = _globalDistributor();

        // Allow globally whitelisted distributors to send tokens freely
        if (distributor != address(0)) {
            if (
                IGlobalDistributor(distributor).isGlobalDistributor(from) || // Check if a router is sending tokens
                IGlobalDistributor(distributor).isGlobalDistributor(to) // or router is receiving
            ) {
                return;
            }
        }

        // Allow whitelisted distributors to send tokens freely
        // Check if a local distributor is sending tokens or if a user is sending tokens to a local distributor
        if (isDistributor[from] || isDistributor[to]) {
            return;
        }

        // Transfers to and from the poolManager require a transient allowance thats set by the hook
        if ((from == address(poolManager()) || to == address(poolManager()))) {
            uint256 transferAllowance = getTransferAllowance();
            require(transferAllowance >= amount, InvalidTransfer());
            assembly {
                let newAllowance := sub(transferAllowance, amount)
                tstore(0, newAllowance)
            }
            emit AllowanceSpent(from, to, amount);
            return;
        }
        revert InvalidTransfer();
    }

    /// @notice Gets the current transient transfer allowance
    /// @return transferAllowance The current allowance amount
    /// @dev Reads from transient storage slot 0
    function getTransferAllowance()
        public
        view
        returns (uint256 transferAllowance)
    {
        assembly {
            transferAllowance := tload(0)
        }
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                  GETTER FUNCTIONS                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Returns the factory address from proxy bytecode
    /// @return The factory contract address
    /// @dev Reads from bytes 0-20 of the proxy's immutable args
    function factory() public view returns (address) {
        bytes memory args = LibClone.argsOnERC1967(address(this), 0, 20);
        return address(bytes20(args));
    }

    /// @notice Returns the router address from proxy bytecode
    /// @return The Uniswap V4 router contract interface
    /// @dev Reads from bytes 20-40 of the proxy's immutable args
    function router() public view returns (IUniswapV4Router04) {
        bytes memory args = LibClone.argsOnERC1967(address(this), 20, 40);
        return IUniswapV4Router04(payable(address(bytes20(args))));
    }

    /// @notice Returns the pool manager address from proxy bytecode
    /// @return The Uniswap V4 pool manager contract interface
    /// @dev Reads from bytes 40-60 of the proxy's immutable args
    function poolManager() public view returns (IPoolManager) {
        bytes memory args = LibClone.argsOnERC1967(address(this), 40, 60);
        return IPoolManager(address(bytes20(args)));
    }

    /// @notice Returns the current implementation address
    /// @return result The address of the current implementation contract
    /// @dev Reads from the ERC1967 implementation slot
    function getImplementation() external view returns (address result) {
        assembly {
            result := sload(_ERC1967_IMPLEMENTATION_SLOT)
        }
    }

    function _globalDistributor() internal view returns (address) {
        if (block.chainid == 1) {
            return GLOBAL_DISTRIBUTION_HANDLER;
        } else {
            return globalDistributor;
        }
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {}
}
