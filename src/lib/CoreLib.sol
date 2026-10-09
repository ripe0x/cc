// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
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
import {RateStore} from "./RateStore.sol";

/// the one linked library of the Core: the settings write (validation, storage, event), the eth rate (the climb with its
/// clamp and ceiling, and the drop on a fill), the exit auction decay and the pool manager swap of the coin buyback.
/// it holds no state of its own and is called by delegatecall, so it works on the Core's storage and balance, and the
/// Core keeps its runtime under the size limit. deployed once before the Core (docs/DEPLOY.md)
library CoreLib {
    using FixedPointMathLib for uint256;

    /// the same declarations as the Core, so the library's reverts and logs decode against the Core abi
    error BadSetting(bytes32 field);
    event SettingsSet(Settings settings);
    error BadSwap();
    error ZeroAddress();
    error OnlyOwner();
    event CoinRescued(address indexed to, uint256 amount);

    /// @notice validates the settings, stores them and logs them. the Core forwards its own `setSettings` call here
    /// untouched (same selector), after it checkpointed both rates. the constructor calls it too
    function setSettings(Settings calldata ns) external {
        bytes32 bad = SettingsBounds.firstViolation(ns);
        if (bad != 0) revert BadSetting(bad);
        Settings storage s = SettingsStore.load();
        s.flatBps = ns.flatBps;
        s.avgScore = ns.avgScore;
        s.dropPerCreditBps = ns.dropPerCreditBps;
        s.dropFloorBps = ns.dropFloorBps;
        s.climbPerMinBps = ns.climbPerMinBps;
        s.ceilBps = ns.ceilBps;
        s.idleLoosenBps = ns.idleLoosenBps;
        s.clampCredits = ns.clampCredits;
        s.spendCapBps = ns.spendCapBps;
        s.bonusCapBps = ns.bonusCapBps;
        s.tipSavingsBps = ns.tipSavingsBps;
        s.tipCapBps = ns.tipCapBps;
        s.reimburseBps = ns.reimburseBps;
        s.reimburseCapBps = ns.reimburseCapBps;
        s.saleFloorBps = ns.saleFloorBps;
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
        s.exitLaneToBuybackBps = ns.exitLaneToBuybackBps;
        s.feeToBuybackBps = ns.feeToBuybackBps;
        emit SettingsSet(ns);
    }

    /// @notice the settings as a struct, from the three packed storage words they sit in. the layout is the one the
    /// compiler gives `Settings` (fields packed in order, a field never straddles a slot), which test/Flow.t.sol
    /// checks against a write and a read
    function unpack(uint256 a, uint256 b, uint256 c) external pure returns (Settings memory s) {
        // forge-lint: disable-start(unsafe-typecast)
        s.flatBps = uint16(a);
        s.avgScore = uint32(a >> 16);
        s.dropPerCreditBps = uint16(a >> 48);
        s.dropFloorBps = uint16(a >> 64);
        s.climbPerMinBps = uint16(a >> 80);
        s.ceilBps = uint16(a >> 96);
        s.idleLoosenBps = uint16(a >> 112);
        s.clampCredits = uint16(a >> 128);
        s.spendCapBps = uint16(a >> 144);
        s.bonusCapBps = uint16(a >> 160);
        s.tipSavingsBps = uint16(a >> 176);
        s.tipCapBps = uint16(a >> 192);
        s.reimburseBps = uint16(a >> 208);
        s.reimburseCapBps = uint16(a >> 224);
        s.saleFloorBps = uint16(a >> 240);
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
        s.exitLaneToBuybackBps = uint16(c >> 176);
        s.feeToBuybackBps = uint16(c >> 192);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice the price state and the read of the eth rate (wei per whole point) at `nowTs`, from the stored rate `r` of
    /// checkpoint time `t`. The price state never exceeds `rateCap` or the ceiling `ceilBps` of the anchor. The anchor is
    /// the rate of the last fill, grown by `idleLoosenBps` per full 10 minutes since the last fill at `anchorTime`. While
    /// funded (the hourly cap `pot * spendCapBps` affords one average credit at `r`) the price state compounds
    /// `climbPerMinBps` per minute, a fractional minute as a fractional exponent, and stops climbing at the funded
    /// threshold `pot * spendCapBps / avgScore`. The read is the price state, lowered while funded to the clamp
    /// `pot * spendCapBps / (avgScore * clampCredits)`, the rate the hourly room affords. The clamp lowers the read only
    /// and never enters the price state, which the Core stores. Never reverts: the Core calls it from `receive()`
    function climb(uint256 r, uint256 pot, uint256 anchorTime, uint256 t, uint256 nowTs)
        external
        view
        returns (uint256 price, uint256 read)
    {
        Settings storage s = SettingsStore.load();
        uint256 room = pot * s.spendCapBps;
        bool funded = room >= uint256(s.avgScore) * r;
        uint256 loosened = 10_000 + uint256(s.idleLoosenBps) * (nowTs.zeroFloorSub(anchorTime) / 10 minutes);
        uint256 cap = RateStore.load().lastFillRate * loosened * s.ceilBps / 1e8;
        cap = cap.min(s.rateCap);
        price = r;
        if (r >= cap) {
            price = cap;
        } else if (funded && nowTs > t && r != 0) {
            uint256 target = cap.min(room / s.avgScore);
            // forge-lint: disable-start(unsafe-typecast)
            int256 x = FixedPointMathLib.lnWad(int256(1e18 + uint256(s.climbPerMinBps) * 1e14))
                * int256((nowTs - t) * 1e18 / 1 minutes) / 1e18;
            // growing past the target: the target decides, and the exponential cannot overflow
            price = x >= FixedPointMathLib.lnWad(int256(target * 1e18 / r))
                ? target
                : r.mulWad(uint256(FixedPointMathLib.expWad(x))).min(target);
            // forge-lint: disable-end(unsafe-typecast)
        }
        read = price;
        if (funded) read = read.min(room / (uint256(s.avgScore) * s.clampCredits));
    }

    /// @notice the rate after one credit is bought at `paid`, and the anchor update of that fill. The rate falls
    /// `dropPerCreditBps` below `paid`, and stays at or above `dropFloorBps` of the rate paid at the first fill of the
    /// current minute bucket (`nowTs / 60`). `paid` becomes the ceiling anchor
    function drop(uint256 paid, uint256 nowTs) external returns (uint256) {
        Settings storage s = SettingsStore.load();
        RateStore.Anchor storage a = RateStore.load();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 bucket = uint64(nowTs / 1 minutes);
        if (bucket != a.minuteBucket) {
            a.minuteBucket = bucket;
            a.minuteStartRate = paid;
        }
        a.lastFillRate = paid;
        return
            (paid * (10_000 - s.dropPerCreditBps) / 10_000).max((a.minuteStartRate * s.dropFloorBps / 10_000).min(paid));
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

    /// @notice sends coin the Core holds to `to`. the Core's `rescueCoin` forwards its call here untouched, so the owner
    /// check and the reentrancy guard are here: `msg.sender` is the caller of the Core and the guard is the Core's own
    /// (solady's storage guard, the same slot and values: a nonzero value other than the address is "free")
    function rescueCoin(address to, uint256 amount) external {
        ICoinOf core = ICoinOf(address(this));
        if (msg.sender != core.owner()) revert OnlyOwner();
        if (to == address(0)) revert ZeroAddress();
        assembly {
            if eq(sload(0x929eee149b4bd21268), address()) {
                mstore(0x00, 0xab143c06) // `Reentrancy()`
                revert(0x1c, 0x04)
            }
            sstore(0x929eee149b4bd21268, address())
        }
        SafeTransferLib.safeTransfer(core.COIN(), to, amount);
        assembly {
            sstore(0x929eee149b4bd21268, codesize())
        }
        emit CoinRescued(to, amount);
    }
}

interface ICoinOf {
    function COIN() external view returns (address);
    function owner() external view returns (address);
}
