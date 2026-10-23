// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IRedeemer} from "../interfaces/Interfaces.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

interface IMarketCore {
    function owner() external view returns (address);
    function controller() external view returns (address);
}

/// the ControllerV3 views this redeemer reads
interface IMarketController {
    function ccPrice() external view returns (uint256 price, bool ok);
    function ccPriorSample() external view returns (uint256);
    function ccPoolKey()
        external
        view
        returns (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks);
    function referencePrice() external view returns (uint256);
    function balancePriorSample() external view returns (uint256);
    function spotPrice() external view returns (uint256 spot, bool ok);
    function valuePerPoint(bool forSale) external view returns (uint256 value, bool ok);
}

/// redeemer 2 of treasury v2: a burn of `ccIn` CC is paid BALANCE at once at the market rate plus `premiumBps`:
///
///   amount = ccIn * P_cc / P_bal * (10_000 + premiumBps) / 10_000
///
/// with `P_cc = min(the controller's CC reference, its prior block CC spot sample, the live CC spot)` and `P_bal =
/// max(the controller's BALANCE reference, its prior block BALANCE spot sample, the live BALANCE spot)`, both wei per
/// 1e18 base units and read at the burn. a one block move of either pool can only lower the payout: the CC side never
/// rises above its reference or its prior block sample, and the BALANCE side never falls below its reference or its
/// prior block sample. the samples close the lagging reference case: after a CC fall (or a BALANCE rise) the reference
/// moves only under its rate and step bounds, but the first refresh after the move records the new spot, so a later
/// same block swap of the live spot back to the lagging reference still prices at the sample. the window left is the
/// time between the move and the next refresh. an unusable CC reference
/// (stale, thin pool, no pool key) or an unusable BALANCE quote (`valuePerPoint(true)` not ok) refuses the burn. the
/// treasury enforces the bucket, the caps, the burn, the recipient and its own epoch; this redeemer pins its premium
/// with `configEpoch`, passed by the caller as the 32 byte `data`. the controller is the Core's current one, read at
/// each use
contract MarketRedeemer is IRedeemer {
    using StateLibrary for IPoolManager;

    uint256 private constant BPS = 10_000;
    uint16 public constant MAX_PREMIUM_BPS = 1_500;
    IPoolManager private constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    address public immutable core;
    uint16 public premiumBps;
    /// advances on every premium change; a redemption passes it as `data`
    uint64 public configEpoch;

    error OnlyOwner();
    error BadPremium();
    error StaleEpoch();
    error Unpriced();

    event PremiumSet(uint16 premiumBps, uint64 configEpoch);

    constructor(address core_, uint16 premiumBps_) {
        core = core_;
        _setPremium(premiumBps_);
    }

    /// 0 to `MAX_PREMIUM_BPS`, by the Core's owner. the epoch advances
    function setPremiumBps(uint16 v) external {
        if (msg.sender != IMarketCore(core).owner()) revert OnlyOwner();
        _setPremium(v);
    }

    function _setPremium(uint16 v) private {
        if (v > MAX_PREMIUM_BPS) revert BadPremium();
        premiumBps = v;
        ++configEpoch;
        emit PremiumSet(v, configEpoch);
    }

    /// the protected CC and BALANCE prices now, wei per 1e18 base units, and whether both are usable
    function prices() public view returns (uint256 ccPrice, uint256 balancePrice, bool ok) {
        IMarketController c = IMarketController(IMarketCore(core).controller());
        (uint256 ccRef, bool okCc) = c.ccPrice();
        (, bool okBal) = c.valuePerPoint(true);
        (uint256 balSpot, bool okSpot) = c.spotPrice();
        if (!okCc || !okBal || !okSpot) return (0, 0, false);
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks hooks) = c.ccPoolKey();
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(
            PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: spacing, hooks: hooks}).toId()
        );
        if (sqrtP == 0) return (0, 0, false);
        uint256 q = FixedPoint96.Q96;
        uint256 ccSpot = (1e18 * q / sqrtP) * q / sqrtP;
        uint256 balRef = c.referencePrice();
        uint256 sample = c.ccPriorSample();
        ccPrice = ccRef < ccSpot ? ccRef : ccSpot;
        if (sample < ccPrice) ccPrice = sample;
        balancePrice = balRef > balSpot ? balRef : balSpot;
        uint256 balSample = c.balancePriorSample();
        if (balSample > balancePrice) balancePrice = balSample;
        ok = ccPrice != 0 && balancePrice != 0;
    }

    /// the BALANCE a burn of `ccIn` would be paid now, before the treasury's bucket and caps, and whether it is priced
    function preview(uint256 ccIn) public view returns (uint256 amount, bool ok) {
        uint256 pCc;
        uint256 pBal;
        (pCc, pBal, ok) = prices();
        if (!ok) return (0, false);
        amount = FixedPointMathLib.fullMulDiv(ccIn * (BPS + premiumBps), pCc, pBal * BPS);
    }

    /// the treasury's call: refuses a stale `configEpoch` in `data` and an unusable price, else the immediate payout
    function quote(address, uint256 ccIn, uint256, uint256, bytes calldata data)
        external
        view
        override
        returns (uint256 amount, uint8 mode, uint32 duration)
    {
        if (data.length != 32 || abi.decode(data, (uint64)) != configEpoch) revert StaleEpoch();
        bool ok;
        (amount, ok) = preview(ccIn);
        if (!ok) revert Unpriced();
        return (amount, 0, 0);
    }
}
