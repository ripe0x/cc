// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Settings} from "../interfaces/Interfaces.sol";
import {SettingsBounds} from "./SettingsBounds.sol";
import {SettingsStore} from "./SettingsStore.sol";

/// the one linked library of the Core: the settings write (validation, storage, event), the two pieces of
/// transcendental math (the eth rate climb and the exit auction decay) and the pool manager swap of the coin buyback.
/// it holds no state of its own and is called by delegatecall, so it works on the Core's storage and balance, and the
/// Core keeps its runtime under the size limit. deployed once before the Core (docs/DEPLOY.md)
library CoreLib {
    using FixedPointMathLib for uint256;

    /// the same declarations as the Core, so the library's reverts and logs decode against the Core abi
    error BadSetting(bytes32 field);
    event SettingsSet(Settings settings);
    error BadSwap();

    /// @notice validates the settings, stores them and logs them. the Core forwards its own `setSettings` call here
    /// untouched (same selector), after it checkpointed both rates. the constructor calls it too
    function setSettings(Settings calldata ns) external {
        bytes32 bad = SettingsBounds.firstViolation(ns);
        if (bad != 0) revert BadSetting(bad);
        Settings storage s = SettingsStore.load();
        s.flatBps = ns.flatBps;
        s.avgScore = ns.avgScore;
        s.climbBaseBps = ns.climbBaseBps;
        s.climbDoubleEvery = ns.climbDoubleEvery;
        s.climbMaxBps = ns.climbMaxBps;
        s.dropBps = ns.dropBps;
        s.spendCapBps = ns.spendCapBps;
        s.bonusCapBps = ns.bonusCapBps;
        s.tipSavingsBps = ns.tipSavingsBps;
        s.tipCapBps = ns.tipCapBps;
        s.reimburseBps = ns.reimburseBps;
        s.reimburseCapBps = ns.reimburseCapBps;
        s.reserveBps = ns.reserveBps;
        s.auctionDuration = ns.auctionDuration;
        s.exitAfter = ns.exitAfter;
        s.saleToBuybackBps = ns.saleToBuybackBps;
        s.exitToBuybackBps = ns.exitToBuybackBps;
        s.buybackSlice = ns.buybackSlice;
        s.buybackDelay = ns.buybackDelay;
        s.keeperTipBps = ns.keeperTipBps;
        s.xRateCap = ns.xRateCap;
        s.xRateFloor = ns.xRateFloor;
        s.xRateClimbPerHour = ns.xRateClimbPerHour;
        s.xRateDropPerCredit = ns.xRateDropPerCredit;
        s.xAuctionHalfLife = ns.xAuctionHalfLife;
        s.exitSliceCredits = ns.exitSliceCredits;
        s.rateCap = ns.rateCap;
        emit SettingsSet(ns);
    }

    /// @notice the settings as a struct, from the three packed storage words they sit in. the layout is the one the
    /// compiler gives `Settings` (fields packed in order, a field never straddles a slot), which test/Flow.t.sol
    /// checks against a write and a read
    function unpack(uint256 a, uint256 b, uint256 c) external pure returns (Settings memory s) {
        // forge-lint: disable-start(unsafe-typecast)
        s.flatBps = uint16(a);
        s.avgScore = uint32(a >> 16);
        s.climbBaseBps = uint16(a >> 48);
        s.climbDoubleEvery = uint32(a >> 64);
        s.climbMaxBps = uint16(a >> 96);
        s.dropBps = uint16(a >> 112);
        s.spendCapBps = uint16(a >> 128);
        s.bonusCapBps = uint16(a >> 144);
        s.tipSavingsBps = uint16(a >> 160);
        s.tipCapBps = uint16(a >> 176);
        s.reimburseBps = uint16(a >> 192);
        s.reimburseCapBps = uint16(a >> 208);
        s.reserveBps = uint16(a >> 224);
        s.auctionDuration = uint32(b);
        s.exitAfter = uint32(b >> 32);
        s.saleToBuybackBps = uint16(b >> 64);
        s.exitToBuybackBps = uint16(b >> 80);
        s.buybackSlice = uint128(b >> 96);
        s.buybackDelay = uint16(b >> 224);
        s.keeperTipBps = uint16(b >> 240);
        s.xRateCap = uint16(c);
        s.xRateFloor = uint16(c >> 16);
        s.xRateClimbPerHour = uint16(c >> 32);
        s.xRateDropPerCredit = uint16(c >> 48);
        s.xAuctionHalfLife = uint32(c >> 64);
        s.exitSliceCredits = uint16(c >> 96);
        s.rateCap = uint64(c >> 112);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice the eth rate after climbing from checkpoint time `t` to `nowTs`, clamped at `cap`. `last` is the time of
    /// the last fill. the climb per hour starts at `base` bps and doubles every `dbl` seconds since the last fill, up to
    /// `maxBps`. at most 12 steps whatever the gap, and it never reverts: the Core calls it from `receive()`
    function climb(
        uint256 r,
        uint256 cap,
        uint256 last,
        uint256 t,
        uint256 nowTs,
        uint256 base,
        uint256 maxBps,
        uint256 dbl
    ) external pure returns (uint256) {
        if (base == 0 || r == 0 || cap <= r) return r;
        while (t < nowTs && r < cap) {
            uint256 k = t > last ? (t - last) / dbl : 0;
            uint256 bps = (base << k.min(16)).min(maxBps);
            // from step 11 on the climb is at its maximum for good, so one step covers the rest
            uint256 end = k >= 11 ? nowTs : nowTs.min(last + (k + 1) * dbl);
            if (bps != 0) {
                // forge-lint: disable-start(unsafe-typecast)
                int256 x =
                    FixedPointMathLib.lnWad(int256(1e18 + bps * 1e14)) * int256((end - t) * 1e18 / 1 hours) / 1e18;
                // growing past the cap: the clamp decides, and the exponential cannot overflow
                if (x >= FixedPointMathLib.lnWad(int256(cap * 1e18 / r))) return cap;
                r = r.mulWad(uint256(FixedPointMathLib.expWad(x)));
                // forge-lint: disable-end(unsafe-typecast)
            }
            t = end;
        }
        return r.min(cap);
    }

    /// @notice `start` halved `elapsed / halfLife` times, with the fraction of a half life by the exponential. zero
    /// after 256 half lives
    function decay(uint256 start, uint256 elapsed, uint256 halfLife) external pure returns (uint256 p) {
        uint256 halvings = elapsed / halfLife;
        if (halvings >= 256) return 0;
        p = start >> halvings;
        uint256 rest = elapsed % halfLife;
        if (rest != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 factor = FixedPointMathLib.powWad(0.5e18, int256(rest * 1e18 / halfLife));
            // forge-lint: disable-next-line(unsafe-typecast)
            p = p * uint256(factor) / 1e18;
        }
    }

    /// @notice the swap of the coin buyback, run inside the pool manager unlock callback of the Core: exact eth in for
    /// coin on the canonical pool, the eth settled from the Core balance and the coin taken to the Core. returns the eth
    /// spent, skim included, and the coin bought. the pool took no more than it was given
    function swapIn(address manager, address coin, uint24 fee, int24 spacing, address hook, uint256 amountIn)
        external
        returns (uint256 owed, uint256 bought)
    {
        IPoolManager pm = IPoolManager(manager);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hook)
        });
        // forge-lint: disable-start(unsafe-typecast)
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        if (d.amount0() > 0 || d.amount1() < 0) revert BadSwap();
        owed = uint256(uint128(-d.amount0()));
        if (owed > amountIn) revert BadSwap();
        pm.settle{value: owed}();
        bought = uint256(uint128(d.amount1()));
        pm.take(key.currency1, address(this), bought);
        // forge-lint: disable-end(unsafe-typecast)
    }
}
