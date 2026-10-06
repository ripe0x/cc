// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Lane, Sale, IController, ICoreViews, ICoreSale} from "./interfaces/Interfaces.sol";

/// first policy module. no bonus for any credit, composes the oldest 80 of a lane with format 0, never overprints.
/// it prices and sells statements: the asking price starts at `startBps` of the statement cost and falls `stepBps` every
/// `stepEvery` down to `floorBps`. in auction mode the core uses it as the house reserve, so the first bid at the asking
/// price opens the english auction. in buy only mode `buy` sells the statement at once at the asking price.
/// it holds no funds between calls. its settings belong to the live owner of the core (`core.owner()`), there is no
/// second owner. the core enforces its own hard floor whatever this contract answers
contract ControllerV1 is IController {
    uint256 private constant PAGE = 80;
    uint256 private constant BPS = 10_000;

    error OnlyOwner();
    error BadSetting(bytes32 field);
    error NotBuyOnly();
    error NotForSale();
    error Underpaid();
    error Reentrant();

    event BuyOnlySet(bool buyOnly);
    event StartBpsSet(uint16 startBps);
    event StepBpsSet(uint16 stepBps);
    event StepEverySet(uint32 stepEvery);
    event FloorBpsSet(uint16 floorBps);
    event Bought(uint256 indexed sid, address indexed buyer, uint256 price);

    ICoreViews public immutable CORE;

    /// buy only mode: `statementPrice` returns the start price without decay (the house reserve is not walked down) and
    /// `buy` sells at the decayed asking price
    bool public buyOnly;
    uint16 public startBps;
    uint16 public stepBps;
    uint32 public stepEvery;
    uint16 public floorBps;
    bool private _busy;

    constructor(address core, Sale memory sale) {
        CORE = ICoreViews(core);
        buyOnly = sale.buyOnly;
        if (sale.startBps < 1_000 || sale.startBps > 40_000) revert BadSetting("startBps");
        startBps = sale.startBps;
        if (sale.stepBps > 5_000) revert BadSetting("stepBps");
        stepBps = sale.stepBps;
        if (sale.stepEvery < 1 minutes || sale.stepEvery > 30 days) revert BadSetting("stepEvery");
        stepEvery = sale.stepEvery;
        if (sale.floorBps < 1_000 || sale.floorBps > sale.startBps) revert BadSetting("floorBps");
        floorBps = sale.floorBps;
    }

    modifier onlyOwner() {
        if (msg.sender != ICoreSale(address(CORE)).owner()) revert OnlyOwner();
        _;
    }

    // ------------------------------------------------------------------ sale settings, owner, at once

    function setBuyOnly(bool on) external onlyOwner {
        buyOnly = on;
        emit BuyOnlySet(on);
    }

    /// 1_000 to 40_000, and not below `floorBps`
    function setStartBps(uint16 v) external onlyOwner {
        if (v < 1_000 || v > 40_000 || v < floorBps) revert BadSetting("startBps");
        startBps = v;
        emit StartBpsSet(v);
    }

    /// 0 to 5_000
    function setStepBps(uint16 v) external onlyOwner {
        if (v > 5_000) revert BadSetting("stepBps");
        stepBps = v;
        emit StepBpsSet(v);
    }

    /// 1 minute to 30 days
    function setStepEvery(uint32 v) external onlyOwner {
        if (v < 1 minutes || v > 30 days) revert BadSetting("stepEvery");
        stepEvery = v;
        emit StepEverySet(v);
    }

    /// 1_000 to `startBps`
    function setFloorBps(uint16 v) external onlyOwner {
        if (v < 1_000 || v > startBps) revert BadSetting("floorBps");
        floorBps = v;
        emit FloorBpsSet(v);
    }

    // ------------------------------------------------------------------ pricing and sale

    /// the price the core uses as the house reserve, in wei. falls with the age of the listing in auction mode, stays at
    /// the start price in buy only mode so the reserve is not walked down
    function statementPrice(uint256, uint256 cost, uint64 listedAt) external view returns (uint256) {
        return cost * _bps(buyOnly ? 0 : block.timestamp - listedAt) / BPS;
    }

    /// the asking price of statement `sid` now, in either mode, read from the core
    function priceOf(uint256 sid) public view returns (uint256) {
        (bool held, Lane lane, uint256 cost, uint64 listedAt) = CORE.statementInfo(sid);
        if (!held || lane != Lane.Eth || listedAt == 0) revert NotForSale();
        return cost * _bps(block.timestamp - listedAt) / BPS;
    }

    /// buy only mode: pays the decayed asking price, gets the statement at once. the excess of `msg.value` is refunded
    /// to the caller last. reverts while a bid is live on the house
    function buy(uint256 sid) external payable {
        if (_busy) revert Reentrant();
        if (!buyOnly) revert NotBuyOnly();
        _busy = true;
        uint256 price = priceOf(sid);
        if (msg.value < price) revert Underpaid();
        ICoreSale(address(CORE)).sellTo{value: price}(sid, msg.sender);
        emit Bought(sid, msg.sender, price);
        if (msg.value > price) SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
        _busy = false;
    }

    /// the asking price in bps of cost after `age` seconds: `startBps` less `stepBps` per `stepEvery`, not below `floorBps`
    function _bps(uint256 age) private view returns (uint256) {
        uint256 start = startBps;
        uint256 drop = age / stepEvery * stepBps;
        uint256 bps = start - (drop < start ? drop : start);
        return bps > floorBps ? bps : floorBps;
    }

    // ------------------------------------------------------------------ credit picking, unchanged

    /// returns zero for every credit.
    function wants(uint256) external pure returns (uint16) {
        return 0;
    }

    /// ready when the lane pile holds a full page. the page is the 80 oldest credits with format 0.
    function nextPage(Lane lane) external view returns (bool ready, uint256[80] memory ids, uint8 format) {
        if (CORE.pileSize(lane) < PAGE) return (false, ids, 0);
        uint256[] memory page = CORE.pilePage(lane, 0, PAGE);
        for (uint256 i; i < PAGE; ++i) {
            ids[i] = page[i];
        }
        return (true, ids, 0);
    }

    /// never ready.
    function nextOverprint() external pure returns (bool, uint256, uint256) {
        return (false, 0, 0);
    }
}
