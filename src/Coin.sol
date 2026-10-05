// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Mainnet} from "./interfaces/Interfaces.sol";

/// @notice fixed supply erc20 whose transfers only work inside hook approved pool flows.
/// @dev a transfer is allowed when it mints, when it moves to or from the pool manager and the hook granted
/// enough transient allowance in the same transaction, or when either side is the core or the dead address.
/// every other transfer reverts, so there is no way to trade the coin in a pool the hook does not serve.
contract Coin is ERC20 {
    /// @notice total supply, minted once in the constructor
    uint256 public constant SUPPLY = 1_000_000_000e18;

    /// @notice transient slot holding the unspent allowance granted by the hook
    bytes32 private constant ALLOWANCE_SLOT = keccak256("coin.transient.allowance");

    /// @notice the v4 pool manager
    address public constant POOL_MANAGER = Mainnet.POOL_MANAGER;
    /// @notice the burn address
    address public constant DEAD = Mainnet.DEAD;

    /// @notice the core, always allowed to send and receive
    address public immutable core;
    /// @notice the only address that may grant transient allowance
    address public immutable hook;

    string private _tokenName;
    string private _tokenSymbol;

    /// @notice a transfer outside the allowed flows
    error InvalidTransfer();
    /// @notice caller is not the hook
    error OnlyHook();
    /// @notice a constructor address was zero
    error ZeroAddress();

    /// @param name_ token name
    /// @param symbol_ token symbol
    /// @param core_ the core, allowlisted
    /// @param hook_ the fee hook, the only granter of allowance
    /// @param supplyReceiver receives the whole supply
    constructor(string memory name_, string memory symbol_, address core_, address hook_, address supplyReceiver) {
        if (core_ == address(0) || hook_ == address(0) || supplyReceiver == address(0)) revert ZeroAddress();
        _tokenName = name_;
        _tokenSymbol = symbol_;
        core = core_;
        hook = hook_;
        _mint(supplyReceiver, SUPPLY);
    }

    /// @notice token name
    function name() public view override returns (string memory) {
        return _tokenName;
    }

    /// @notice token symbol
    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @notice adds to the transient allowance that pool manager transfers can spend. hook only
    /// @param amount coin units the next pool manager transfers may move
    function increaseTransferAllowance(uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        bytes32 slot = ALLOWANCE_SLOT;
        assembly {
            tstore(slot, add(tload(slot), amount))
        }
    }

    /// @notice the transient allowance left in the current transaction
    function transferAllowance() public view returns (uint256 allowance) {
        bytes32 slot = ALLOWANCE_SLOT;
        assembly {
            allowance := tload(slot)
        }
    }

    /// @dev runs after balances move. the grant is checked before the allowlist so a grant is always consumed.
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from == address(0)) return;
        if (from == POOL_MANAGER || to == POOL_MANAGER) {
            uint256 allowance = transferAllowance();
            if (allowance >= amount) {
                bytes32 slot = ALLOWANCE_SLOT;
                assembly {
                    tstore(slot, sub(allowance, amount))
                }
                return;
            }
        }
        if (from == core || to == core || from == DEAD || to == DEAD) return;
        revert InvalidTransfer();
    }

    /// @dev the permit2 shortcut is off so no address gets an allowance the holder did not grant
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}
