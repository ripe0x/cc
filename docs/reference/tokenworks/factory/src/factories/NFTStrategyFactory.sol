// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {NFTStrategy} from "../strategies/NFTStrategy.sol";
import {
    IERC721,
    INFTStrategyHook,
    INFTStrategyFactory
} from "../Interfaces.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {StrategyFactory} from "./StrategyFactory.sol";

/// @title NFTStrategyFactory - Factory for deploying ERC721Strategy contracts
/// @author TokenWorks (https://token.works/)
/// @notice This factory deploys and manages NFTStrategy contracts with Uniswap V4 integration
/// @dev Uses ERC1967 proxy pattern for upgradeable NFTStrategy deployments
contract NFTStrategyFactory is StrategyFactory {
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

    /// @notice Previous factory contract address for migration checks
    address public immutable previousFactory;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                   STATE VARIABLES                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Mapping of NFT collection addresses to their NFTStrategy contracts
    mapping(address => address) public collectionToNFTStrategy;
    /// @notice Mapping of NFTStrategy addresses to their collection contracts
    mapping(address => address) public nftStrategyToCollection;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    CUSTOM ERRORS                    */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Collection already has an NFTStrategy deployed
    error CollectionAlreadyLaunched();
    /// @notice Incorrect ETH amount sent with launch transaction
    error WrongEthAmount();
    /// @notice Contract does not implement ERC721 interface
    error NotERC721();
    /// @notice Buy increment is outside valid range
    error InvalidIncrement();

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    CUSTOM EVENTS                    */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Event emitted when a new NFTStrategy instance is launched
    /// @param collection The NFT collection address
    /// @param nftStrategy The deployed NFTStrategy contract address
    /// @param tokenName The name of the strategy token
    /// @param tokenSymbol The symbol of the strategy token
    event NFTStrategyLaunched(
        address indexed collection,
        address indexed nftStrategy,
        string tokenName,
        string tokenSymbol
    );

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
    /// @dev Sets up immutable references and creates NFTStrategy implementation
    constructor(
        address _previousFactory,
        address implementation,
        address _posm,
        address _permit2,
        address payable _router,
        address _poolManager,
        address _feeAddress,
        address _globalDistributor,
        address _owner
    )
        StrategyFactory(
            _posm,
            _permit2,
            _router,
            _poolManager,
            _feeAddress,
            _globalDistributor,
            _owner
        )
    {
        strategyImplementation = implementation;
        previousFactory = _previousFactory;
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    USER FUNCTIONS                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Launches a new NFTStrategy contract with owner permissions
    /// @param collection Address of the NFT collection contract
    /// @param tokenName Name of the strategy token
    /// @param tokenSymbol Symbol of the strategy token
    /// @param collectionOwner Address that will receive fees from the strategy
    /// @param buyIncrement The buy increment for price calculations
    /// @return The deployed NFTStrategy contract
    /// @dev Only callable by contract owner, deploys NFTStrategy and initializes liquidity
    function ownerLaunchNFTStrategy(
        address collection,
        string memory tokenName,
        string memory tokenSymbol,
        address collectionOwner,
        uint256 buyIncrement
    ) external payable onlyLauncher returns (NFTStrategy) {
        // Validate the parameters passed
        if (hookAddress == address(0)) revert HookNotSet();
        if (checkIfAlreadyLaunched(collection))
            revert CollectionAlreadyLaunched();
        if (buyIncrement < 0.01 ether || buyIncrement > 0.1 ether) {
            revert InvalidIncrement();
        }

        if (!IERC721(collection).supportsInterface(0x80ac58cd))
            revert NotERC721();

        NFTStrategy nftStrategy = _deployUpgradeableNFTStrategy(
            collection,
            hookAddress,
            tokenName,
            tokenSymbol,
            buyIncrement,
            owner()
        );

        collectionToNFTStrategy[collection] = address(nftStrategy);
        nftStrategyToCollection[address(nftStrategy)] = collection;

        // Costs 2 wei
        _loadLiquidity(address(nftStrategy));

        // Set fees to collectionOwner
        INFTStrategyHook(hookAddress).adminUpdateFeeAddress(
            address(nftStrategy),
            collectionOwner
        );

        if (globalDistributor != address(0)) {
            nftStrategy.setGlobalDistributor(globalDistributor);
        }

        emit NFTStrategyLaunched(
            collection,
            address(nftStrategy),
            tokenName,
            tokenSymbol
        );

        return nftStrategy;
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                  INTERNAL FUNCTIONS                 */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Deploys a new upgradeable NFTStrategy contract
    /// @param _collection The NFT collection address
    /// @param _hook The hook contract address
    /// @param _tokenName The name of the strategy token
    /// @param _tokenSymbol The symbol of the strategy token
    /// @param _buyIncrement The buy increment for price calculations
    /// @param _owner The owner of the NFTStrategy contract
    /// @return proxy The deployed NFTStrategy proxy contract
    /// @dev Uses ERC1967 proxy pattern with packed immutable args
    function _deployUpgradeableNFTStrategy(
        address _collection,
        address _hook,
        string memory _tokenName,
        string memory _tokenSymbol,
        uint256 _buyIncrement,
        address _owner
    ) internal returns (NFTStrategy proxy) {
        bytes memory args = abi.encodePacked(
            address(this),
            router,
            poolManager
        );

        proxy = NFTStrategy(
            payable(
                LibClone.deployERC1967(address(strategyImplementation), args)
            )
        );

        proxy.initialize(
            _collection,
            _hook,
            _tokenName,
            _tokenSymbol,
            _buyIncrement,
            launchUpgradeable ? _owner : address(0)
        );
    }

    /// @param collection The address of the NFT collection to check
    /// @return True if collection already has a strategy, false otherwise
    /// @dev Checks both current factory and old factory for existing strategies
    function checkIfAlreadyLaunched(
        address collection
    ) public view returns (bool) {
        if (collectionToNFTStrategy[collection] != address(0)) {
            return true;
        }

        if (previousFactory != address(0)) {
            return
                INFTStrategyFactory(previousFactory).collectionToNFTStrategy(
                    collection
                ) != address(0);
        }

        return false;
    }
}
