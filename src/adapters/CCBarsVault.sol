// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// the deployed Bars contract (BalanceEdition, 0x7d9EdeA03dD97361c3e21389B95bc327e22752aE): Bar #n holds n BALANCE in
/// its own vault; `mintUpTo` pulls from the caller's allowance and may mint none; `meltBatch` opens at `mintEnd` and
/// sends each Bar vault's whole token balance to the caller
interface IBars {
    function mintUpTo(address to, uint256 maxQuantity, uint256 maxTotal)
        external
        returns (uint256 first, uint256 quantity, uint256 total);
    function meltBatch(uint256[] calldata ids) external returns (uint256 total);
    function ownerOf(uint256 id) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function safeTransferFrom(address from, address to, uint256 id) external;
}

interface IOwned {
    function owner() external view returns (address);
}

/// @notice holds Bars bought with CC treasury BALANCE. the Core's current owner alone mints, moves, melts and returns.
/// funded by the owner's `withdrawWorking` on the treasury: this contract can pull nothing from the treasury and
/// spends only the BALANCE it holds. melting and returning pay the treasury, never another address. no deadline gates
/// anything here; the Bars contract's own mint window and melt opening apply
contract CCBarsVault {
    error OnlyOwner();
    error NothingMinted();
    error SpendMismatch();
    error NotOwnedHere(uint256 id);
    error OnlyBars();

    event BarsMinted(uint256 first, uint256 quantity, uint256 total);
    event BarsTransferred(address indexed to, uint256[] ids);
    event BarsMelted(uint256[] ids, uint256 recovered);
    event BalanceReturned(uint256 amount);

    address public immutable core;
    address public immutable treasury;
    address public immutable balance;
    IBars public immutable bars;

    /// the BALANCE paid into Bar vaults by `mintBars`, summed over every call. never decreases: the execution script
    /// reads it, with the BALANCE and Bars held here, as proof this vault was already funded
    uint256 public spent;

    constructor(address core_, address treasury_, address balance_, IBars bars_) {
        core = core_;
        treasury = treasury_;
        balance = balance_;
        bars = bars_;
    }

    modifier onlyOwner() {
        if (msg.sender != IOwned(core).owner()) revert OnlyOwner();
        _;
    }

    /// mints up to `maxQuantity` (at most 10, the Bars contract's batch cap) of the next Bars into this vault, paying
    /// at most `maxTotal` from the BALANCE held here. the allowance lives only inside this call. reverts when none fit
    function mintBars(uint256 maxQuantity, uint256 maxTotal)
        external
        onlyOwner
        returns (uint256 first, uint256 quantity, uint256 total)
    {
        uint256 before = SafeTransferLib.balanceOf(balance, address(this));
        SafeTransferLib.safeApprove(balance, address(bars), maxTotal);
        (first, quantity, total) = bars.mintUpTo(address(this), maxQuantity, maxTotal);
        SafeTransferLib.safeApprove(balance, address(bars), 0);
        if (quantity == 0) revert NothingMinted();
        if (before - SafeTransferLib.balanceOf(balance, address(this)) != total) revert SpendMismatch();
        for (uint256 i; i < quantity; ++i) {
            if (bars.ownerOf(first + i) != address(this)) revert NotOwnedHere(first + i);
        }
        spent += total;
        emit BarsMinted(first, quantity, total);
    }

    /// moves Bars held here to `to` by safe transfer, so a contract recipient must accept ERC721
    function transferBars(address to, uint256[] calldata ids) external onlyOwner {
        for (uint256 i; i < ids.length; ++i) {
            bars.safeTransferFrom(address(this), to, ids[i]);
        }
        emit BarsTransferred(to, ids);
    }

    /// melts Bars held here (at most 10, the Bars contract's cap) and sends everything their vaults released,
    /// including any BALANCE beyond their deposits, to the treasury. BALANCE already held here stays for `returnBalance`
    function meltBars(uint256[] calldata ids) external onlyOwner returns (uint256 recovered) {
        uint256 before = SafeTransferLib.balanceOf(balance, address(this));
        bars.meltBatch(ids);
        recovered = SafeTransferLib.balanceOf(balance, address(this)) - before;
        SafeTransferLib.safeTransfer(balance, treasury, recovered);
        emit BarsMelted(ids, recovered);
    }

    /// sends every BALANCE held here to the treasury
    function returnBalance() external onlyOwner returns (uint256 amount) {
        amount = SafeTransferLib.balanceOf(balance, address(this));
        SafeTransferLib.safeTransfer(balance, treasury, amount);
        emit BalanceReturned(amount);
    }

    /// accepts Bars only; any other ERC721 would be stranded here
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(bars)) revert OnlyBars();
        return this.onERC721Received.selector;
    }
}
