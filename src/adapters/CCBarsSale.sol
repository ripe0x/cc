// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// the deployed Bars contract (0x7d9EdeA03dD97361c3e21389B95bc327e22752aE). `work(id).vault` holds the BALANCE that
/// melting Bar `id` releases to its owner
interface IBarsForSale {
    struct Work {
        address vault;
        uint96 amount;
        address minter;
        uint64 block;
        bool melted;
        uint256[4] ink;
    }

    function work(uint256 id) external view returns (Work memory);
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
    function safeTransferFrom(address from, address to, uint256 id) external;
}

interface ICoreForBarsSale {
    function owner() external view returns (address);
    function controller() external view returns (address);
    function fund() external payable;
}

/// the live controller's balance token price, wei per 1e18 base units (ControllerV2 and ControllerV3)
interface IBalancePrice {
    function referencePrice() external view returns (uint256);
    function spotPrice() external view returns (uint256 spot, bool ok);
}

/// @notice sells CC treasury Bars for ETH and pays every wei of the proceeds into the Core's pot (`Core.fund`), which
/// funds the Credit bid. the Core's current owner alone sets the price and moves Bars out.
///
/// the ask of a held Bar is the larger of two terms:
/// 1. the curve: one ETH price for every Bar, falling in a straight line from `start` at `since` to `floor` at
///    `since + window`, resting at `floor` after
/// 2. the backing: the BALANCE in the Bar's vault, valued at the larger of the controller's rate-limited reference and
///    the live pool spot, times `(10_000 + marginBps) / 10_000`
///
/// the backing term means a sale never pays less ETH than the Bar's BALANCE is worth at that price, so buying and
/// melting is never cheaper than buying BALANCE. pushing the spot up only raises the ask; pushing it down leaves the
/// reference, which moves at most its rate-limited step per refresh. this contract never refreshes the reference, so a
/// buyer cannot drag it toward a spot it just moved. the reference lags a fast rise in the BALANCE price: while the
/// spot is pushed below a lagging reference, the backing term reads the reference, and `marginBps` is the cushion
/// against that lag. no quote (no reference, no priced spot) means no sale
contract CCBarsSale {
    error OnlyOwner();
    error OnlyBars();
    error SaleOff();
    error NotForSale(uint256 id);
    error NoQuote();
    error Underpaid();
    error BadSetting();
    error Reentrant();

    event SaleSet(uint256 start, uint256 floor, uint256 window, uint256 marginBps, uint256 since);
    event SaleOn(bool on);
    event BarsSold(address indexed buyer, uint256[] ids, uint256 paid);
    event BarsTransferred(address indexed to, uint256[] ids);

    uint256 internal constant BPS = 10_000;

    ICoreForBarsSale public immutable core;
    address public immutable balance;
    IBarsForSale public immutable bars;

    /// the curve's start and floor, wei per Bar. start is at least floor
    uint128 public start;
    uint128 public floor;
    /// the seconds the curve falls over, at least 1
    uint32 public window;
    /// the time the curve started, set by every `setSale`
    uint40 public since;
    /// the margin over the backing, bps. any value: 0 sells at the backing, never under it
    uint32 public marginBps;
    bool public on;
    bool private _busy;

    constructor(
        ICoreForBarsSale core_,
        address balance_,
        IBarsForSale bars_,
        uint128 start_,
        uint128 floor_,
        uint32 window_,
        uint32 marginBps_
    ) {
        core = core_;
        balance = balance_;
        bars = bars_;
        _setSale(start_, floor_, window_, marginBps_);
    }

    modifier onlyOwner() {
        if (msg.sender != core.owner()) revert OnlyOwner();
        _;
    }

    /// sets the curve and the margin and restarts the curve at `start` now
    function setSale(uint128 start_, uint128 floor_, uint32 window_, uint32 marginBps_) external onlyOwner {
        _setSale(start_, floor_, window_, marginBps_);
    }

    function _setSale(uint128 start_, uint128 floor_, uint32 window_, uint32 marginBps_) private {
        if (start_ < floor_ || window_ == 0) revert BadSetting();
        start = start_;
        floor = floor_;
        window = window_;
        marginBps = marginBps_;
        // forge-lint: disable-next-line(unsafe-typecast)
        since = uint40(block.timestamp);
        emit SaleSet(start_, floor_, window_, marginBps_, block.timestamp);
    }

    /// sales start off; the owner switches them on once the Bars are here
    function setOn(bool on_) external onlyOwner {
        on = on_;
        emit SaleOn(on_);
    }

    /// the curve term now, wei
    function curvePrice() public view returns (uint256) {
        uint256 age = block.timestamp - since;
        if (age >= window) return floor;
        return start - (start - floor) * age / window;
    }

    /// the wei value of the BALANCE in Bar `id`'s vault at the larger of the reference and the live spot, rounded up.
    /// reverts `NoQuote` without a reference or a priced spot
    function backingOf(uint256 id) public view returns (uint256) {
        IBalancePrice c = IBalancePrice(core.controller());
        uint256 ref = c.referencePrice();
        (uint256 spot, bool ok) = c.spotPrice();
        if (ref == 0 || !ok || spot == 0) revert NoQuote();
        uint256 held = SafeTransferLib.balanceOf(balance, bars.work(id).vault);
        return FixedPointMathLib.mulDivUp(held, spot > ref ? spot : ref, 1e18);
    }

    /// the ask of a Bar held here, wei. reverts `NotForSale` for any other Bar and `NoQuote` without a quote
    function priceOf(uint256 id) public view returns (uint256) {
        if (bars.ownerOf(id) != address(this)) revert NotForSale(id);
        uint256 backed = FixedPointMathLib.mulDivUp(backingOf(id), BPS + marginBps, BPS);
        uint256 curve = curvePrice();
        return curve > backed ? curve : backed;
    }

    /// buys `ids` at their asks, pays the total into the Core's pot and refunds the excess of `msg.value` last. the
    /// Bars move by plain `transferFrom`: no receiver callback runs inside the sale
    function buy(uint256[] calldata ids) external payable returns (uint256 total) {
        if (!on) revert SaleOff();
        if (_busy) revert Reentrant();
        _busy = true;
        for (uint256 i; i < ids.length; ++i) {
            total += priceOf(ids[i]);
        }
        if (msg.value < total) revert Underpaid();
        for (uint256 i; i < ids.length; ++i) {
            bars.transferFrom(address(this), msg.sender, ids[i]);
        }
        core.fund{value: total}();
        emit BarsSold(msg.sender, ids, total);
        if (msg.value > total) SafeTransferLib.safeTransferETH(msg.sender, msg.value - total);
        _busy = false;
    }

    /// moves Bars held here to `to` by safe transfer, such as back to the CC Bars vault to melt
    function transferBars(address to, uint256[] calldata ids) external onlyOwner {
        for (uint256 i; i < ids.length; ++i) {
            bars.safeTransferFrom(address(this), to, ids[i]);
        }
        emit BarsTransferred(to, ids);
    }

    /// accepts Bars only; any other ERC721 would be stranded here
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(bars)) revert OnlyBars();
        return this.onERC721Received.selector;
    }
}
