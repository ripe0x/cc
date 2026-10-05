// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Mainnet} from "./interfaces/Interfaces.sol";

/// @notice fixed supply erc20 whose transfers only work inside hook approved pool flows.
/// @dev a transfer is allowed when it mints, when it moves out of the pool manager and the hook noted at least that
/// much coin owed to the locker, when it moves into the pool manager and the hook noted at least that much owed by
/// the locker (a signed, netted transient counter), or when either side is the core or the dead address.
/// every other transfer reverts, so there is no way to trade the coin in a pool the hook does not serve.
contract Coin is ERC20 {
    /// @notice total supply, minted once in the constructor
    uint256 public constant SUPPLY = 1_000_000_000e18;

    /// @notice transient slot holding the signed net coin the pool manager owes (positive) or is owed (negative)
    bytes32 private constant DELTA_SLOT = keccak256("coin.transient.delta");

    /// @notice the v4 pool manager
    address public constant POOL_MANAGER = Mainnet.POOL_MANAGER;
    /// @notice the burn address
    address public constant DEAD = Mainnet.DEAD;

    /// @notice the core, always allowed to send and receive
    address public immutable core;
    /// @notice the only address that may note coin deltas
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
    /// @param hook_ the fee hook, the only noter of coin deltas
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

    /// @notice books the signed coin leg of a hooked action into the transient counter. hook only
    /// @param coinDelta coin the pool manager owes the locker (positive) or is owed by the locker (negative)
    function noteDelta(int256 coinDelta) external {
        if (msg.sender != hook) revert OnlyHook();
        _setDelta(pendingDelta() + coinDelta);
    }

    /// @notice the net coin the pool manager still owes out (positive) or is still owed (negative) this transaction
    function pendingDelta() public view returns (int256 d) {
        bytes32 slot = DELTA_SLOT;
        assembly {
            d := tload(slot)
        }
    }

    function _setDelta(int256 d) private {
        bytes32 slot = DELTA_SLOT;
        assembly {
            tstore(slot, d)
        }
    }

    /// @dev runs after balances move. a pool manager transfer is covered only when it matches the direction and size
    /// of the netted counter, which is consumed first so a grant can never be left over for the allowlist path.
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from == address(0)) return;
        if (from == POOL_MANAGER) {
            int256 d = pendingDelta();
            // forge-lint: disable-next-line(unsafe-typecast)
            if (d >= int256(amount)) {
                // forge-lint: disable-next-line(unsafe-typecast)
                _setDelta(d - int256(amount));
                return;
            }
        } else if (to == POOL_MANAGER) {
            int256 d = pendingDelta();
            // forge-lint: disable-next-line(unsafe-typecast)
            if (d <= -int256(amount)) {
                // forge-lint: disable-next-line(unsafe-typecast)
                _setDelta(d + int256(amount));
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
