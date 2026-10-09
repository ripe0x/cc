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
import {Lane, ICredits, ICreditScore, IStatements, Settings, Mainnet} from "../interfaces/Interfaces.sol";
import {IAuctionHouse} from "../interfaces/AuctionHouse.sol";
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
    address successor;
    bool successorLocked;
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
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    // word positions in the house's auction record
    uint256 internal constant W_FIRST = 2;
    uint256 internal constant W_AMOUNT = 3;
    uint256 internal constant W_RESERVE = 4;
    uint256 internal constant W_OWNER = 5;
    uint256 internal constant W_END = 7;

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
    /// the credit is in a pile of the Core
    error InPile();
    /// the statement is on the books of the Core
    error Held();
    /// the Core is not the holder of the token, or the token is not an ERC721
    error NotHolder();
    event NftRescued(address indexed token, uint256 indexed id, address indexed to);
    error Locked(bytes32 what);
    error NoCode(address who);
    error NoSuccessor();
    /// the successor is the Core or a contract the Core works with
    error BadSuccessor(address who);
    error CallFailed();
    event SuccessorSet(address successor);
    event SuccessorLocked();
    event CreditAdopted(uint256 indexed id, uint256 cost);
    event Migrated(
        address indexed successor,
        uint256 eth,
        uint256 credits,
        uint256 statements,
        uint256 exitTokens,
        uint256 skippedStatements
    );

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
        return _climb(r, pot, anchorTime, t, nowTs);
    }

    function _climb(uint256 r, uint256 pot, uint256 anchorTime, uint256 t, uint256 nowTs)
        private
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
    /// (solady's storage guard, the same slot: the word holds the Core's address while a guarded call runs and the
    /// library's `codesize()` after it, and any nonzero value other than the Core's address counts as free)
    function rescueCoin(address to, uint256 amount) external {
        _onlyOwner();
        if (to == address(0)) revert ZeroAddress();
        _enter();
        SafeTransferLib.safeTransfer(ICoinOf(address(this)).COIN(), to, amount);
        _leave();
        emit CoinRescued(to, amount);
    }

    /// @notice sends the ERC721 token `id` of `token` that the Core holds to `to` with `transferFrom`. a credit leaves only
    /// while it is not in a pile (`Credit.inPile`), a statement only while the Core has no record of it
    /// (`Statement.held`), every other ERC721 leaves. `ownerOf` must answer with the Core, which an ERC20 or an
    /// address without code cannot. the Core forwards its call here untouched, the owner check and the reentrancy
    /// guard are here
    function rescueNft(address token, uint256 id, address to) external {
        _onlyOwner();
        if (to == address(0)) revert ZeroAddress();
        _enter();
        CoreState storage c = state();
        if (token == address(CREDITS)) {
            if (c.credits[id].inPile) revert InPile();
        } else if (token == Mainnet.STATEMENTS) {
            if (c.statements[id].held) revert Held();
        }
        (bool ok, bytes memory out) = token.staticcall(abi.encodeCall(ICredits.ownerOf, (id)));
        if (!ok || out.length != 32 || abi.decode(out, (address)) != address(this)) revert NotHolder();
        ICredits(token).transferFrom(address(this), to, id);
        _leave();
        emit NftRescued(token, id, to);
    }

    /// @notice puts credits the Core holds without a record into the eth pile, anyone may call. The cost basis of a
    /// credit is the price state per whole point at `block.timestamp` (`climb`, before the clamp, no checkpoint is
    /// written) times the score of the credit, at least 1 wei. The price state is what the engine pays with a funded
    /// pot, so statements built from adopted credits are priced at that level; the clamp of a thin pot would book a
    /// basis of 1 wei. A donor who inflates the basis of a statement gives credits away. The basis is booked and the
    /// eth pile grows: the rate state, the hourly window and the pots keep their values. `acquiredAt` is the current
    /// time. Reverts `Empty` for an empty list, `ZeroId` for id zero, `InPile` for a credit that is in a pile (the same
    /// id twice included), and `NotHolder` for a credit the Core does not hold. The Core pulls the fee router, then
    /// forwards its call here untouched, under its own reentrancy guard
    function adopt(uint256[] calldata ids) external {
        if (ids.length == 0) revert Empty();
        CoreState storage c = state();
        (uint256 price,) = _climb(c.rateAtCheckpoint, c.ethPot, c.lastFillTime, c.checkpointTime, block.timestamp);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (id == 0) revert ZeroId();
            if (c.credits[id].inPile) revert InPile();
            if (CREDITS.ownerOf(id) != address(this)) revert NotHolder();
            uint256 cost = (price * scoreOf(id) / 1e4).max(1);
            push(c.piles[Lane.Eth], c.credits, Lane.Eth, id, cost);
            emit CreditAdopted(id, cost);
        }
    }

    /// @notice sets the successor to which `migrate` sends the assets. the zero address means no migration. reverts
    /// after `lockSuccessor`, and for the Core itself, the exit module, the exit token, the house, the fee source, the
    /// coin, Credits and Statements. the Core forwards its call here untouched
    function setSuccessor(address next) external {
        _onlyOwner();
        CoreState storage c = state();
        if (c.successorLocked) revert Locked("successor");
        if (next != address(0)) {
            if (next.code.length == 0) revert NoCode(next);
            ICoinOf core = ICoinOf(address(this));
            if (
                next == address(this) || next == c.exitModule || next == c.exitToken || next == core.HOUSE()
                    || next == core.FEE_SOURCE() || next == core.COIN() || next == address(CREDITS)
                    || next == address(STATEMENTS)
            ) revert BadSuccessor(next);
        }
        c.successor = next;
        emit SuccessorSet(next);
    }

    /// @notice closes `setSuccessor`. allowed while the successor is zero, which disables `migrate`
    function lockSuccessor() external {
        _onlyOwner();
        state().successorLocked = true;
        emit SuccessorLocked();
    }

    /// @notice moves the assets the Core tracks to the successor, in batches. the Core forwards its call here untouched,
    /// the owner check and the reentrancy guard are here.
    /// eth: `ethPot + ethToBuyback`, by one plain call, the trackers zeroed. eth above the trackers stays.
    /// credits: up to `maxCredits` from the head of each pile, by `transferFrom`, the pile membership cleared (the
    /// cost, lane and arrival time of the record stay).
    /// statements: the held list is scanned from its end, and the scan stops after `maxStatements` moved or after
    /// `maxStatements` skipped, whichever comes first, so a call makes at most 2 * `maxStatements` house reads. a listed
    /// statement is taken back from the house first. a statement with a bid, a sold one whose record is not settled
    /// yet, and one the house refuses to return are skipped and counted. the record of a moved statement is deleted.
    /// when `maxStatements` or more statements at the end of the list are skipped, the scan never reaches the ones
    /// before them, so `maxStatements` must exceed the number of skipped statements.
    /// exit token: `xPot + xToBuyback`, by `transfer`, the trackers zeroed. the coin stays.
    /// the rates are checkpointed before a pot is zeroed. the hourly spend window is closed with the eth pot. a call with
    /// nothing left to move logs zeros
    function migrate(uint256 maxCredits, uint256 maxStatements) external {
        _onlyOwner();
        CoreState storage c = state();
        address to = c.successor;
        if (to == address(0)) revert NoSuccessor();
        _enter();
        uint256 eth = _moveEth(c, to);
        uint256 credits = _moveCredits(c, to, maxCredits);
        (uint256 statements, uint256 skipped) = _moveStatements(c, to, maxStatements);
        uint256 exitTokens = _moveExitToken(c, to);
        _leave();
        emit Migrated(to, eth, credits, statements, exitTokens, skipped);
    }

    function _moveEth(CoreState storage c, address to) private returns (uint256 eth) {
        eth = c.ethPot + c.ethToBuyback;
        if (eth == 0) return 0;
        (c.rateAtCheckpoint,) = _climb(c.rateAtCheckpoint, c.ethPot, c.lastFillTime, c.checkpointTime, block.timestamp);
        c.checkpointTime = uint64(block.timestamp);
        c.ethPot = 0;
        c.ethToBuyback = 0;
        // the hourly spend window of the old pot is closed: the next spend opens one on the pot it finds
        c.windowStart = 0;
        c.windowPot = 0;
        c.windowSpent = 0;
        (bool ok,) = to.call{value: eth}("");
        if (!ok) revert CallFailed();
    }

    function _moveExitToken(CoreState storage c, address to) private returns (uint256 amount) {
        amount = c.xPot + c.xToBuyback;
        if (amount == 0) return 0;
        Settings storage s = SettingsStore.load();
        uint256 unit = c.unitPerPoint;
        c.xRateAtCheckpoint = xRateOf(c.xRateAtCheckpoint, c.xFunded, c.xPot, unit, c.xCheckpointTime, s);
        c.xCheckpointTime = uint64(block.timestamp);
        c.xPot = 0;
        c.xToBuyback = 0;
        c.xFunded = xFundedOf(0, c.xRateAtCheckpoint, unit, s);
        SafeTransferLib.safeTransfer(c.exitToken, to, amount);
    }

    /// pops up to `max` credits from the head of each pile
    function _moveCredits(CoreState storage c, address to, uint256 max) private returns (uint256 moved) {
        for (uint256 l; l < 2; ++l) {
            Pile storage p = c.piles[Lane(l)];
            uint256 id = p.head;
            uint256 k;
            while (id != 0 && k < max) {
                Credit storage cr = c.credits[id];
                uint256 next = cr.next;
                cr.next = 0;
                cr.prev = 0;
                cr.inPile = false;
                CREDITS.transferFrom(address(this), to, id);
                id = next;
                ++k;
            }
            if (k != 0) {
                p.head = id;
                p.size -= k;
                if (id == 0) p.tail = 0;
                else c.credits[id].prev = 0;
                moved += k;
            }
        }
    }

    function _moveStatements(CoreState storage c, address to, uint256 max)
        private
        returns (uint256 moved, uint256 skipped)
    {
        address house = ICoinOf(address(this)).HOUSE();
        uint256 i = c.heldIds.length;
        while (i != 0 && moved < max && skipped < max) {
            --i;
            uint256 sid = c.heldIds[i];
            if (!_release(house, c.statements[sid], sid)) {
                ++skipped;
                continue;
            }
            uint256 last = c.heldIds[c.heldIds.length - 1];
            c.heldIds[i] = last;
            c.statements[last].slot = uint64(i);
            c.heldIds.pop();
            delete c.statements[sid];
            STATEMENTS.transferFrom(address(this), to, sid);
            ++moved;
        }
    }

    /// makes sure the Core holds statement `sid` of its books, taking it back from the house when it is listed without a
    /// bid. false when the statement has a bid on the house, or the listing is gone and a buyer holds it
    function _release(address house, Statement storage st, uint256 sid) private returns (bool) {
        if (st.listed) {
            (bool ok, uint256[12] memory w) = auctionWords(house, st.auctionId);
            if (!ok) return false;
            if (w[W_OWNER] != 0) {
                if (w[W_FIRST] != 0) return false;
                try IAuctionHouse(house).cancelAuction(st.auctionId) {}
                catch {
                    return false;
                }
            }
        }
        return holderOf(sid) == address(this);
    }

    /// the twelve words of the house's auction record `id` (`IAuctionHouse.Auction`, static words), all zero when the
    /// auction is gone. false when the house does not answer with them
    function auctionWords(address house, uint256 id) internal view returns (bool ok, uint256[12] memory w) {
        bytes memory out;
        (ok, out) = house.staticcall(abi.encodeCall(IAuctionHouse.getAuction, (id)));
        if (!ok || out.length != 384) return (false, w);
        w = abi.decode(out, (uint256[12]));
    }

    /// the owner of a statement, or zero when it does not exist
    function holderOf(uint256 sid) internal view returns (address who) {
        (bool ok, bytes memory out) = address(STATEMENTS).staticcall(abi.encodeCall(IStatements.ownerOf, (sid)));
        if (ok && out.length == 32) who = abi.decode(out, (address));
    }

    /// the caller of an owner function the Core forwarded here: `msg.sender` is the caller of the Core
    function _onlyOwner() private view {
        if (msg.sender != state().owner) revert OnlyOwner();
    }

    /// takes the reentrancy guard of the Core (solady's storage guard: the word holds the Core's address while a guarded
    /// call runs and the library's `codesize()` after it; any nonzero value other than the Core's address counts as free)
    function _enter() private {
        assembly {
            if eq(sload(0x929eee149b4bd21268), address()) {
                mstore(0x00, 0xab143c06) // `Reentrancy()`
                revert(0x1c, 0x04)
            }
            sstore(0x929eee149b4bd21268, address())
        }
    }

    function _leave() private {
        assembly {
            sstore(0x929eee149b4bd21268, codesize())
        }
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
    function HOUSE() external view returns (address);
    function FEE_SOURCE() external view returns (address);
}
