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
    function meltBatch(uint256[] calldata ids) external returns (uint256 total);
}

interface ICoreForBarsSale {
    function owner() external view returns (address);
    function controller() external view returns (address);
    function balanceModule() external view returns (address);
    function balanceToken() external view returns (address);
    function fund() external payable;
}

/// the live controller's balance token price, wei per 1e18 base units (ControllerV2 and ControllerV3)
interface IBalancePrice {
    function referencePrice() external view returns (uint256);
    function spotPrice() external view returns (uint256 spot, bool ok);
}

/// @notice sells CC treasury Bars for ETH and pays every wei of the proceeds into the Core's pot (`Core.fund`), which
/// funds the Credit bid. the Core's current owner alone sets the multipliers, melts Bars and moves Bars out. melting
/// pays the Core's balance module read at the melt, so a treasury migration needs no change here.
///
/// the ask follows the BALANCE price, like the Core's Credit and Statement asks: a Bar asks its BALANCE value times a
/// multiplier that falls in a straight line from `startBps` at the Bar's arrival here to `floorBps` at arrival plus
/// `window`, and rests at `floorBps` after. `floorBps` is at least 10_000, so no Bar sells for less ETH than its BALANCE
/// is worth. the value is the BALANCE in the Bar's vault at the larger of the controller's rate-limited reference and
/// the live pool spot: a spot pushed up raises the ask at once, a spot pushed down leaves the reference, which this
/// contract never refreshes. no quote (no reference, no priced spot) means no sale. a Bar that arrived by a plain
/// `transferFrom` has no arrival time and asks `floorBps`; `transferBars` clears a Bar's arrival time, so a Bar that
/// leaves and comes back by plain transfer asks `floorBps` too. pricing and melting refuse while the Core's balance
/// token differs from this sale's: the controller would price another token and a melt would pay a module that does
/// not hold BALANCE. the owner then moves the Bars out with `transferBars`
contract CCBarsSale {
    error OnlyOwner();
    error OnlyBars();
    error SaleOff();
    error NotForSale(uint256 id);
    error NoQuote();
    error Underpaid();
    error BadSetting();
    error Reentrant();
    error NoModule();
    error TokenChanged();

    event SaleSet(uint256 startBps, uint256 floorBps, uint256 window);
    event SaleOn(bool on);
    event BarsSold(address indexed buyer, uint256[] ids, uint256 paid);
    event BarsTransferred(address indexed to, uint256[] ids);
    event BarsMelted(uint256[] ids, address indexed module, uint256 recovered);

    uint256 internal constant BPS = 10_000;

    ICoreForBarsSale public immutable core;
    address public immutable balance;
    IBarsForSale public immutable bars;

    /// the multiplier on a Bar's BALANCE value at its arrival and after `window`, bps. start >= floor >= 10_000
    uint32 public startBps;
    uint32 public floorBps;
    /// the seconds the multiplier falls over, at least 1
    uint32 public window;
    bool public on;
    bool private _busy;
    /// when each Bar arrived here by safe transfer; the start of its fall
    mapping(uint256 id => uint256) public arrivedAt;

    constructor(
        ICoreForBarsSale core_,
        address balance_,
        IBarsForSale bars_,
        uint32 startBps_,
        uint32 floorBps_,
        uint32 window_
    ) {
        core = core_;
        balance = balance_;
        bars = bars_;
        _setSale(startBps_, floorBps_, window_);
    }

    modifier onlyOwner() {
        if (msg.sender != core.owner()) revert OnlyOwner();
        _;
    }

    /// sets the multipliers and the window. each Bar keeps its arrival time
    function setSale(uint32 startBps_, uint32 floorBps_, uint32 window_) external onlyOwner {
        _setSale(startBps_, floorBps_, window_);
    }

    function _setSale(uint32 startBps_, uint32 floorBps_, uint32 window_) private {
        if (floorBps_ < BPS || startBps_ < floorBps_ || window_ == 0) revert BadSetting();
        startBps = startBps_;
        floorBps = floorBps_;
        window = window_;
        emit SaleSet(startBps_, floorBps_, window_);
    }

    /// sales start off; the owner switches them on once the Bars are here
    function setOn(bool on_) external onlyOwner {
        on = on_;
        emit SaleOn(on_);
    }

    /// the multiplier of Bar `id` now, bps
    function multiplierOf(uint256 id) public view returns (uint256) {
        uint256 t = arrivedAt[id];
        uint256 age = t == 0 ? type(uint256).max : block.timestamp - t;
        if (age >= window) return floorBps;
        return startBps - (startBps - floorBps) * age / window;
    }

    /// the wei value of the BALANCE in Bar `id`'s vault at the larger of the reference and the live spot, rounded up.
    /// reverts `NoQuote` without a reference or a priced spot
    function backingOf(uint256 id) public view returns (uint256) {
        if (core.balanceToken() != balance) revert TokenChanged();
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
        return FixedPointMathLib.mulDivUp(backingOf(id), multiplierOf(id), BPS);
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

    /// melts Bars held here (at most 10, the Bars contract's cap) and sends everything their vaults released to the
    /// Core's balance module now. BALANCE held here before the call stays here
    function meltBars(uint256[] calldata ids) external onlyOwner returns (uint256 recovered) {
        address module = core.balanceModule();
        if (module == address(0)) revert NoModule();
        if (core.balanceToken() != balance) revert TokenChanged();
        uint256 before = SafeTransferLib.balanceOf(balance, address(this));
        bars.meltBatch(ids);
        recovered = SafeTransferLib.balanceOf(balance, address(this)) - before;
        SafeTransferLib.safeTransfer(balance, module, recovered);
        emit BarsMelted(ids, module, recovered);
    }

    /// moves Bars held here to `to` by safe transfer and clears their arrival times. a transfer to this contract
    /// itself records a new arrival through `onERC721Received`, restarting the fall
    function transferBars(address to, uint256[] calldata ids) external onlyOwner {
        for (uint256 i; i < ids.length; ++i) {
            delete arrivedAt[ids[i]];
            bars.safeTransferFrom(address(this), to, ids[i]);
        }
        emit BarsTransferred(to, ids);
    }

    /// accepts Bars only, any other ERC721 would be stranded here, and starts the Bar's fall
    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(bars)) revert OnlyBars();
        arrivedAt[id] = block.timestamp;
        return this.onERC721Received.selector;
    }
}
