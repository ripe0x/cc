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
import {Lane, ICredits, ICreditScore, Settings, Mainnet} from "../interfaces/Interfaces.sol";
import {SettingsBounds} from "./SettingsBounds.sol";
import {SettingsStore} from "./SettingsStore.sol";
import {RateStore} from "./RateStore.sol";

/// the Core's state variables in declaration order. read at slot 0 (`CoreLib.state`), it addresses the same storage as the
/// Core's own variables, because a struct in storage is laid out by the same rules as the state variables of a contract.
/// test/CoreLayout.t.sol compares both views
struct CoreState {
    address controller;
    bool controllerLocked;
    bool exitModuleLocked;
    bool targetsLocked;
    address exitModule;
    address exitToken;
    mapping(address => bool) allowedTarget;
    address owner;
    address pendingOwner;
    uint256 ethPot;
    uint256 ethToBuyback;
    uint256 xPot;
    uint256 xToBuyback;
    uint256 rateAtCheckpoint;
    uint64 checkpointTime;
    uint64 lastFillTime;
    uint64 windowStart;
    uint256 windowPot;
    uint256 windowSpent;
    uint256 xRateAtCheckpoint;
    uint64 xCheckpointTime;
    bool xFunded;
    uint256 lastBuybackBlock;
    uint256 overprintDay;
    uint256 overprintCount;
    mapping(Lane => CoreLib.Pile) piles;
    mapping(uint256 => CoreLib.Credit) credits;
    mapping(uint256 => CoreLib.Statement) statements;
    uint256[] heldIds;
    uint256 unitPerPoint;
    uint256 xStartPrice;
    uint64 xStartTime;
}

/// the one linked library of the Core: the settings write (validation, storage, event), the eth rate (the climb with its
/// clamp and ceiling, and the drop on a fill), the exit auction decay, the pool manager swap of the coin buyback, the
/// pull of the fee router's balance and the sale of credits into the exit token bid.
/// it holds no state of its own and is called by delegatecall, so it works on the Core's storage and balance, and the
/// Core keeps its runtime under the size limit. deployed once before the Core (docs/DEPLOY.md)
library CoreLib {
    using FixedPointMathLib for uint256;

    struct Pile {
        uint256 head;
        uint256 tail;
        uint256 size;
    }

    struct Credit {
        uint256 cost;
        uint256 prev;
        uint256 next;
        uint64 acquiredAt;
        Lane lane;
        bool inPile;
    }

    /// `listed` means the record says the statement sits on the house under `auctionId`. the house is the truth, the
    /// record is settled lazily by `syncStatement`. an exit lane statement is held and never listed
    struct Statement {
        uint256 cost;
        uint256 auctionId;
        uint64 listedAt;
        uint64 slot;
        Lane lane;
        bool held;
        bool listed;
    }

    uint256 internal constant BPS = 10_000;
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);

    /// the same declarations as the Core, so the library's reverts and logs decode against the Core abi
    error Empty();
    error NoExitModule();
    error ZeroId();
    error NotOwner();
    error ZeroAmount();
    error PotTooSmall();
    error Slippage();
    event CreditBought(uint256 indexed id, address indexed from, Lane lane, uint256 cost);
    event ExitRateFill(uint256 rate, uint256 pot);
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
    /// checkpoint time `t`. The price state compounds `climbPerMinBps` per minute up to min(`rateCap`, ceiling, clamp)
    /// and holds a value above that bound. The ceiling is `ceilBps` of the last fill rate grown by `idleLoosenBps` per
    /// full 10 minutes since `anchorTime`. The clamp is `pot * spendCapBps / (avgScore * clampCredits)`. The read is
    /// min(price state, clamp). Never reverts: the Core calls it from `receive()`
    function climb(uint256 r, uint256 pot, uint256 anchorTime, uint256 t, uint256 nowTs)
        external
        view
        returns (uint256 price, uint256 read)
    {
        Settings storage s = SettingsStore.load();
        uint256 room = pot * s.spendCapBps;
        uint256 clamp = room / (uint256(s.avgScore) * s.clampCredits);
        uint256 loosened = 10_000 + uint256(s.idleLoosenBps) * (nowTs.zeroFloorSub(anchorTime) / 10 minutes);
        uint256 cap = RateStore.load().lastFillRate * loosened * s.ceilBps / 1e8;
        cap = cap.min(s.rateCap);
        price = r;
        if (r >= cap) {
            price = cap;
        } else if (nowTs > t && r != 0 && r < cap.min(clamp)) {
            uint256 target = cap.min(clamp);
            // forge-lint: disable-start(unsafe-typecast)
            int256 x = FixedPointMathLib.lnWad(int256(1e18 + uint256(s.climbPerMinBps) * 1e14))
                * int256((nowTs - t) * 1e18 / 1 minutes) / 1e18;
            // growing past the target: the target decides, and the exponential cannot overflow
            price = x >= FixedPointMathLib.lnWad(int256(target * 1e18 / r))
                ? target
                : r.mulWad(uint256(FixedPointMathLib.expWad(x))).min(target);
            // forge-lint: disable-end(unsafe-typecast)
        }
        read = price.min(clamp);
    }

    /// @notice the rate after one credit is bought with the price state `price` at the fill, and the anchor update of
    /// that fill. The rate falls `dropPerCreditBps` below `price` and stays at or above `dropFloorBps` of the price state
    /// at the first fill of the current minute bucket (`nowTs / 60`). A `price` already below that floor (restated by
    /// `setRate` or lowered by a bound) starts a new floor at `price`. `price` becomes the ceiling anchor
    function drop(uint256 price, uint256 nowTs) external returns (uint256) {
        Settings storage s = SettingsStore.load();
        RateStore.Anchor storage a = RateStore.load();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 bucket = uint64(nowTs / 1 minutes);
        if (bucket != a.minuteBucket || price < a.minuteStartRate * s.dropFloorBps / 10_000) {
            a.minuteBucket = bucket;
            a.minuteStartRate = price;
        }
        a.lastFillRate = price;
        return (price * (10_000 - s.dropPerCreditBps) / 10_000).max(a.minuteStartRate * s.dropFloorBps / 10_000);
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

    /// @notice the Core's state variables, by name
    function state() internal pure returns (CoreState storage c) {
        assembly ("memory-safe") {
            c.slot := 0
        }
    }

    /// appends credit `id` with cost basis `cost` to the pile `p` of `lane`
    function push(Pile storage p, mapping(uint256 => Credit) storage credits, Lane lane, uint256 id, uint256 cost)
        internal
    {
        uint256 tail = p.tail;
        Credit storage c = credits[id];
        c.cost = cost;
        c.prev = tail;
        c.next = 0;
        c.acquiredAt = uint64(block.timestamp);
        c.lane = lane;
        c.inPile = true;
        if (tail == 0) p.head = id;
        else credits[tail].next = id;
        p.tail = id;
        p.size += 1;
    }

    /// the caller must own credit `id`, which is not the zero sentinel
    function owned(uint256 id) internal view returns (uint256) {
        if (id == 0) revert ZeroId();
        if (CREDITS.ownerOf(id) != msg.sender) revert NotOwner();
        return id;
    }

    /// score of a credit in 1e4 scale, read from the score contract
    function scoreOf(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    /// the exit token bid in bps of score: the stored rate `r` climbs `xRateClimbPerHour` per hour since `since`, up to
    /// the cap `min(xRateCap, pot * BPS / (avgScore * unit))`, while the pot funds the bid (`funded`)
    function xRateOf(uint256 r, bool funded, uint256 pot, uint256 unit, uint256 since, Settings storage s)
        internal
        view
        returns (uint256)
    {
        if (!funded) return r;
        uint256 cap = uint256(s.xRateCap).min(pot * BPS / (uint256(s.avgScore) * unit));
        if (cap <= r) return r;
        return (r + uint256(s.xRateClimbPerHour) * (block.timestamp - since) / 1 hours).min(cap);
    }

    /// whether the exit pot `pot` pays one average credit at the exit rate `r`
    function xFundedOf(uint256 pot, uint256 r, uint256 unit, Settings storage s) internal view returns (bool) {
        return pot * BPS >= uint256(s.avgScore) * r * unit;
    }

    /// @notice sells the credits `ids` of the caller into the exit token bid. the Core's `sellForExitToken` forwards its
    /// call here untouched, under its own reentrancy guard
    function sellForExitToken(uint256[] calldata ids) external {
        _sellForExitToken(ids, 0);
    }

    /// @notice same as the one argument form with a floor on the total paid
    function sellForExitToken(uint256[] calldata ids, uint256 minOut) external {
        _sellForExitToken(ids, minOut);
    }

    function _sellForExitToken(uint256[] calldata ids, uint256 minOut) private {
        CoreState storage c = state();
        Settings storage s = SettingsStore.load();
        if (ids.length == 0) revert Empty();
        if (c.exitModule == address(0)) revert NoExitModule();
        uint256 unit = c.unitPerPoint;
        uint256 dropBps = s.xRateDropPerCredit;
        uint256 floor = s.xRateFloor;
        c.xRateAtCheckpoint = xRateOf(c.xRateAtCheckpoint, c.xFunded, c.xPot, unit, c.xCheckpointTime, s);
        c.xCheckpointTime = uint64(block.timestamp);
        uint256 r = c.xRateAtCheckpoint;
        uint256 pot = c.xPot;
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = owned(ids[i]);
            uint256 price = scoreOf(id) * r * unit / BPS;
            if (price == 0) revert ZeroAmount();
            if (price > pot) revert PotTooSmall();
            pot -= price;
            total += price;
            r = r.zeroFloorSub(dropBps).max(floor);
            push(c.piles[Lane.Exit], c.credits, Lane.Exit, id, price);
            CREDITS.transferFrom(msg.sender, address(this), id);
            emit CreditBought(id, msg.sender, Lane.Exit, price);
        }
        c.xPot = pot;
        c.xRateAtCheckpoint = r;
        c.xFunded = xFundedOf(pot, r, unit, s);
        emit ExitRateFill(r, pot);
        if (total < minOut) revert Slippage();
        SafeTransferLib.safeTransfer(c.exitToken, msg.sender, total);
    }

    /// gas forwarded to the router flush of `pullFees`. the most expensive flush (four payees and a tip recipient that
    /// burn all their gas, the split on) measures 706,000 gas in test/PullFees.t.sol
    uint256 internal constant PULL_GAS = 1_000_000;

    /// @notice calls `flush(tipTo)` on the fee router with at most `PULL_GAS` and ignores the outcome. the router sends
    /// the fee eth to `Core.receive`, which books it. a router that reverts, burns its gas or has no code leaves the
    /// caller's entry point unaffected and the fees in the router
    function pullFees(address router, address tipTo) external {
        bytes memory data = abi.encodeCall(IRouterFlush.flush, (tipTo));
        assembly ("memory-safe") {
            pop(call(PULL_GAS, router, 0, add(data, 0x20), mload(data), 0, 0))
        }
    }
}

interface IRouterFlush {
    function flush(address tipTo) external;
}

interface ICoinOf {
    function COIN() external view returns (address);
    function owner() external view returns (address);
}
