// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BidModel} from "../utils/BidModel.sol";
import {RateStore} from "../../src/lib/RateStore.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {
    Lane,
    ICredits,
    ICreditScore,
    ICreditStrategy,
    IStatements,
    Mainnet,
    Settings
} from "../../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../../src/interfaces/AuctionHouse.sol";
import {IArtCoinsTokenV2, IArtCoinsMevSkimV2} from "../../src/interfaces/ArtCoinsV2.sol";
import {IFeeRouter} from "../../src/interfaces/IFeeRouter.sol";
import {MockExitModule} from "../standins/MockExitModule.sol";
import {MockExitToken} from "../standins/MockExitToken.sol";
import {ProbeTarget} from "../attackers/ProbeTarget.sol";
import {FuzzController} from "../attackers/FuzzController.sol";
import {TestSwapRouter} from "../utils/TestSwapRouter.sol";

/// everything the handler needs to know about the system under test.
struct Wiring {
    ICore core;
    IAuctionHouse house;
    IArtCoinsTokenV2 coin;
    TestSwapRouter router;
    PoolKey launchKey;
    bytes32 poolId;
    address hook;
    address mev;
    IFeeRouter feeRouter;
    address owner;
    address v1;
    FuzzController fuzz;
    ProbeTarget probe;
    MockExitModule module;
    MockExitToken exitToken;
    bool canSwapController;
    string tag;
}

/// @notice base of the handler for the SPEC section 10 invariant suites, on the flow rework surface. every action is bounded, never reverts, and keeps
/// ghost accounting that the invariant functions check. a violation is written to the `viol` counters and never
/// asserted here, because under `fail_on_revert = false` a reverting handler would hide it.
///
/// actors hold real credits moved out of the CreditStrategy by prank in the fixture. coin trades go through the
/// real launch pool on the real PoolManager under the live skim hook, which pays its bounty into the core's
/// `receive()`. the anti sniper window skims up to 90 percent of a swap, so the fee model reads the live skim rate.
abstract contract HandlerBase is Test {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint8 internal constant A_BUY_COIN = 0;
    uint8 internal constant A_SELL_COIN = 1;
    uint8 internal constant A_SELL_FOR_ETH = 2;
    uint8 internal constant A_LISTING_STRATEGY = 3;
    uint8 internal constant A_LISTING_HOSTILE = 4;
    uint8 internal constant A_WARP = 5;
    uint8 internal constant A_ROLL = 6;
    uint8 internal constant A_COMPOSE = 7;
    uint8 internal constant A_BID = 8;
    uint8 internal constant A_BUYBACK = 9;
    uint8 internal constant A_SKIM = 10;
    uint8 internal constant A_DONATE = 11;
    uint8 internal constant A_CONTROLLER_SEED = 12;
    uint8 internal constant A_CONTROLLER_SWAP = 13;
    uint8 internal constant A_OVERPRINT = 14;
    uint8 internal constant A_PROBE_CONTROLLER = 15;
    uint8 internal constant A_SELL_FOR_EXIT = 16;
    uint8 internal constant A_COMPOSE_EXIT = 17;
    uint8 internal constant A_EXIT_STATEMENT = 18;
    uint8 internal constant A_BUYBACK_EXIT = 19;
    uint8 internal constant A_MODULE_MODE = 20;
    uint8 internal constant A_WALLET_MOVE = 21;
    uint8 internal constant A_END_AUCTION = 22;
    uint8 internal constant A_COLLECT_SALES = 23;
    uint8 internal constant A_SYNC_STATEMENT = 24;
    uint8 internal constant A_REPRICE = 25;
    uint8 internal constant A_SET_SETTINGS = 26;
    uint8 internal constant A_SET_INVALID = 27;
    uint8 internal constant A_SET_RATE = 28;
    uint8 internal constant A_SET_XRATE = 29;
    uint8 internal constant A_OWNER_MISC = 30;
    uint8 internal constant A_REPLACE_MODULE = 31;
    // the sale and owner actions of HandlerSale
    uint8 internal constant A_BUY = 32;
    uint8 internal constant A_OWNER_SELL = 33;
    uint8 internal constant A_REPRICE_BID = 34;
    uint8 internal constant A_SALE_SETTINGS = 35;
    uint8 internal constant A_FLIP_MODE = 36;
    uint8 internal constant A_HOSTILE_OWNER = 37;
    uint8 internal constant A_LOCK = 38;
    uint8 internal constant A_HANDOVER = 39;
    // the fee router: a stranger's flush, and the hostile owner repointing the engine
    uint8 internal constant A_FLUSH = 40;
    uint8 internal constant A_REPOINT = 41;
    uint256 internal constant N_ACTIONS = 42;

    // violation codes
    uint256 internal constant V_ETH_OUT = 1; // eth left the core beyond what the action explains
    uint256 internal constant V_ETH_IN = 2; // eth arrived in the core beyond what the action explains
    uint256 internal constant V_X_OUT = 3; // exit token left the core beyond what the action explains
    uint256 internal constant V_X_IN = 4; // exit token arrived in the core beyond what the action explains
    uint256 internal constant V_ABOVE_CAP = 5; // a credit was bought above the blended ceiling with the bonus cap in force
    uint256 internal constant V_TIP = 6; // a tip above min(tipSavingsBps of savings, tipCapBps of cost)
    uint256 internal constant V_SALE_FLOOR = 7; // a statement sold below the reserve the core set, or a reserve off its rule
    uint256 internal constant V_DEPART = 8; // a statement left the core without a recorded legal exit
    uint256 internal constant V_EXIT_SHORT = 9; // an exit that returned less than rating * unit per point
    uint256 internal constant V_MODEL = 10; // the core disagrees with the handler's ghost model
    uint256 internal constant V_RATE_UNFUNDED = 11; // the rate rose in an interval that began unfunded
    uint256 internal constant V_RATE_BOUND = 12; // the rate moved faster or slower than the settings in force allow
    uint256 internal constant V_FUNDED_STALE = 13; // the stored funded flag disagrees with pot and rate
    uint256 internal constant V_WINDOW = 14; // hourly spend above the cap the core had to apply in the ghost window
    uint256 internal constant V_HOSTILE_OK = 15; // a hostile listing target got through
    uint256 internal constant V_PROBE_OK = 16; // a controller attack call succeeded
    uint256 internal constant V_REENTER = 17; // a reentry attempt succeeded
    uint256 internal constant V_REVERT_CHANGED = 18; // a reverted action changed core state
    uint256 internal constant V_OVERPRINT = 19; // an overprint outside the rules
    uint256 internal constant V_BUYBACK = 20; // a buyback slice or tip outside the rules
    /// share of the metered gross gas the caller pays net of the EIP-3529 refund (the refund is at most 20 percent)
    uint256 internal constant REFUND_FLOOR_BPS = 8_000;
    uint256 internal constant V_COMPOSE = 21; // a compose outside the rules or a reimbursement above its cap
    uint256 internal constant V_POT = 22; // pot bookkeeping off from the action's flows
    uint256 internal constant V_REFUND = 23; // a house refund or payout that is not what the house rules give
    uint256 internal constant V_RECEIVE = 24; // the core's receive() reverted, or a swap failed for an unexplained reason
    uint256 internal constant V_SUPPLY = 25; // coin supply differs from the ghost, or rose
    uint256 internal constant V_AUCTION = 26; // the exit token auction broke its price, slice or restart rules
    uint256 internal constant V_SETTINGS = 27; // settings changed outside the owner's call, or an owner call misbehaved
    uint256 internal constant V_HOUSE = 28; // sale proceeds on the house or their collection are off the ghost
    uint256 internal constant V_OWNER = 29; // an owner action moved assets or the books it must not touch
    uint256 internal constant V_SALE_PATH = 30; // a sellTo or buy sale outside the rules: price, booking, holder or record
    uint256 internal constant V_LOCK = 31; // a one way lock came undone, or a handover left a power behind
    uint256 internal constant V_ROUTER = 32; // router eth went somewhere but the engine set at that time, or a flush broke its rule
    uint256 internal constant N_VIOL = 33;

    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;
    IPoolManager internal constant PM = IPoolManager(Mainnet.POOL_MANAGER);
    address internal constant DEAD = Mainnet.DEAD;
    bytes32 internal constant SKIM_SPLIT = keccak256("SkimSplit(bytes32,uint256,uint256,uint256,uint256)");
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    // core storage slots of windowStart (offset 17 in slot 11), windowPot and windowSpent.
    // from `forge inspect Core storage-layout`. the fixture proves them against public getters.
    uint256 internal constant SLOT_WINDOW_START = 11;
    uint256 internal constant WINDOW_START_SHIFT = 136;
    uint256 internal constant SLOT_WINDOW_POT = 12;
    uint256 internal constant SLOT_WINDOW_SPENT = 13;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    ICore public core;
    IAuctionHouse public house;
    IArtCoinsTokenV2 public coin;
    TestSwapRouter public router;
    PoolKey public launchKey;
    bytes32 public poolId;
    /// the v2 hook, the mev module and the fee router of the launch. the hook pays the router, `flush` pays the core
    address internal HOOK;
    address internal mev;
    IFeeRouter public feeRouter;
    /// the account that flushes the router and collects the tips
    address internal flusher;
    /// the engine the handler last saw the router owner set, and the two other engines the hostile owner can point it at:
    /// one that takes eth and one that refuses it. `parked` is the eth waiting in the router since a flush failed
    address public gEngine;
    address public otherEngine;
    address public refusingEngine;
    uint256 public parked;
    bool public gRouterLocked;
    uint256 public routerFlushes;
    uint256 public routerRepoints;
    address public owner;
    address public v1;
    FuzzController public fuzz;
    ProbeTarget public probe;
    MockExitModule public module;
    MockExitToken public exitToken;
    bool public canSwapController;
    string public tag;

    address[] public actors;
    address public keeper;
    mapping(address => uint256[]) internal inventory;
    uint256[] internal candidates;
    uint256[] internal probeIds;
    mapping(uint256 => bool) internal gone;
    /// every controller that was ever installed or probed. none may hold anything.
    address[] public controllers;

    /// what the owner and every controller held when the run began, per asset. invariant 8: none may ever hold more
    struct Base {
        uint256 eth;
        uint256 coin;
        uint256 credits;
        uint256 statements;
        uint256 exitToken;
    }

    mapping(address => Base) public baseOf;
    address[] public watched;

    // per action counters. the handler never reverts, so these survive failing core calls.
    uint256[N_ACTIONS] public attempts;
    uint256[N_ACTIONS] public successes;
    uint256[N_ACTIONS] public skips;
    /// attempts the ghost model expected to succeed that reverted anyway
    uint256[N_ACTIONS] public unexpectedFails;
    /// the selector of the latest unexpected revert of each action
    bytes4[N_ACTIONS] public lastUnexpected;
    string[N_ACTIONS] internal names;

    uint256[N_VIOL] public viol;
    string[N_VIOL] public violMsg;

    // coin supply ghost. the expected supply falls by the coin the eth buyback bought and burned, and by the coin
    // burned out of a taker in an exit auction fill. coin taxed to the burn address is held there, not burned
    uint256 public gSupply;
    uint256 public gDead;
    uint256 public gBurnedByBuyback;
    uint256 public gBurnedByAuction;
    uint256 internal gSupplyLast;
    /// swaps and buybacks that ran while the anti sniper skim was above the baseline
    uint256 public windowSwaps;

    // the core's receive(). direct sends made, and the ones that failed
    uint256 public receiveSends;
    uint256 public receiveFails;
    /// swaps through the real pool that failed, by revert selector
    mapping(bytes4 => uint256) public swapFails;
    bytes4[] public swapFailSels;

    // ghost credits
    struct CG {
        bool inPile;
        uint8 lane;
        uint256 cost;
    }

    mapping(uint256 => CG) public cg;
    uint256[] internal cgList;
    uint256[2] public pileCount;

    // ghost statements. status: the one place every statement ever composed sits at any time
    uint8 public constant S_LISTED = 1; // eth lane, on the house under `auctionId`
    uint8 public constant S_HELD = 2; // exit lane, held by the core, never listed
    uint8 public constant S_SOLD = 3; // a house auction cleared, the winner holds it
    uint8 public constant S_EXITED = 4; // handed to the exit module
    uint8 public constant S_TOP = 5; // burned as the top of an overprint
    uint8 public constant S_SOLD_TO = 6; // eth lane, sold at once by the controller through `sellTo`, the buyer holds it

    struct SG {
        uint8 status;
        uint8 lane;
        uint256 cost;
        uint256 reserve; // the reserve the core set at the listing or the latest reprice
        uint256 floorAtSet; // the hard floor (cost * saleFloorBps) in force when that reserve was set
        uint256 auctionId;
        uint64 listedAt;
        uint256 bid; // listed: the top bid so far, zero before the first bid
        address bidder;
        uint256 price; // sold: the winning bid
        address winner; // sold: who holds it
        bool synced; // sold: the core cleared its record with syncStatement
        uint256 required; // exit: rating times unit per point
        uint256 received; // exit: exit token the core received
        uint256 base; // overprint top: the base it went into
        uint256 ratingSum; // overprint top: rating of base plus rating of top before
        address module; // exit: the module that took it
    }

    mapping(uint256 => SG) internal _sg;
    uint256[] public everHeld;

    // house money. the sum of the winning bids of the auctions that settled, and the eth collected from the house
    uint256 public gWon;
    uint256 public gCollected;
    /// the keccak of the settings the owner last set, which nobody else can change
    bytes32 public gSettingsHash;

    // ghost hourly window
    uint256 public gWinStart;
    uint256 public gWinPot;
    uint256 public gWinSpent;
    uint256 public gSpendEvents;
    /// the spend cap in bps the window opened under, and whether the owner changed it while the window was open
    uint256 public gWinCap;
    bool public gWinCapChanged;
    /// spends that took a window past the cap it opened under (the owner raised it) or past the cap in force now
    /// (the owner lowered it after the spending). informational: the core applies the cap in force at each spend
    uint256 public gOverOpenCap;
    uint256 public gOverNowCap;

    // overprint day counter in the ghost model
    uint256 internal gOpDay;
    uint256 internal gOpCount;

    // ghost totals for the summary
    uint256 public totalSpentEth;
    uint256 public biggestSpendBps;

    constructor(Wiring memory w) {
        core = w.core;
        house = w.house;
        coin = w.coin;
        router = w.router;
        launchKey = w.launchKey;
        poolId = w.poolId;
        HOOK = w.hook;
        mev = w.mev;
        feeRouter = w.feeRouter;
        flusher = makeAddr("credeng.inv.flusher");
        gEngine = w.feeRouter.engine();
        owner = w.owner;
        v1 = w.v1;
        fuzz = w.fuzz;
        probe = w.probe;
        module = w.module;
        exitToken = w.exitToken;
        canSwapController = w.canSwapController;
        tag = w.tag;
        keeper = makeAddr("credeng.inv.keeper");
        string[N_ACTIONS] memory n = [
            "buyCoin",
            "sellCoin",
            "sellForEth",
            "listingStrategy",
            "listingHostile",
            "warp",
            "roll",
            "compose",
            "bid",
            "buyback",
            "skim",
            "donate",
            "controllerSeed",
            "controllerSwap",
            "overprint",
            "probeController",
            "sellForExit",
            "composeExit",
            "exitStatement",
            "buybackExit",
            "moduleMode",
            "walletMove",
            "endAuction",
            "collectSales",
            "syncStatement",
            "repriceStatement",
            "setSettings",
            "setSettingsInvalid",
            "setRate",
            "setXRate",
            "ownerMisc",
            "replaceModule",
            "buyOnlyBuy",
            "ownerSell",
            "repriceBid",
            "saleSettings",
            "flipMode",
            "hostileOwner",
            "lockDoor",
            "handover",
            "flush",
            "repoint"
        ];
        names = n;
        controllers.push(w.v1);
        controllers.push(address(w.fuzz));
        // the owner and the controllers are watched from the start. a contract created at an address that already
        // holds eth on the fork starts with that eth
        watched.push(w.owner);
        watched.push(w.v1);
        watched.push(address(w.fuzz));
        for (uint256 i; i < watched.length; ++i) {
            _snapBase(watched[i]);
        }
        gSettingsHash = keccak256(abi.encode(core.settings()));
        gSupply = coin.totalSupply();
        gSupplyLast = gSupply;
        gDead = coin.balanceOf(DEAD);
    }

    /// true once the exit module is set in the core
    function phase2() public view returns (bool) {
        return core.exitModule() != address(0);
    }

    /*//////////////////////////////////////////////////////////////
                               FIXTURE HOOKS
    //////////////////////////////////////////////////////////////*/

    function addActor(address a) external {
        actors.push(a);
    }

    function giveCredits(address a, uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            inventory[a].push(ids[i]);
        }
    }

    function setCandidates(uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            candidates.push(ids[i]);
        }
    }

    function setProbeIds(uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            probeIds.push(ids[i]);
        }
    }

    /// the fixture reports credits it sold into the core and statements it composed before the run starts, so
    /// the ghost model starts in step with the core.
    function seedGhostPile(uint256 id, uint8 lane, uint256 cost) external {
        _addCredit(id, lane, cost);
    }

    /// a statement the core held before the run began. a sold one is given with its winner, its winning bid and
    /// whether the proceeds were collected already. a listed one is read back from the house
    function seedGhostStatement(uint256 sid, address winner, uint256 price, bool collected) external {
        (bool held, Lane lane, uint256 cost, uint64 clock) = core.statementInfo(sid);
        SG storage g = _sg[sid];
        g.lane = uint8(lane);
        g.cost = cost;
        g.listedAt = clock;
        (, uint256 aid, uint256 reserve,,) = core.statementStatus(sid);
        g.auctionId = aid;
        g.floorAtSet = cost * core.settings().saleFloorBps / 10_000;
        if (price != 0) {
            g.status = S_SOLD;
            g.reserve = cost * core.settings().saleFloorBps / 10_000;
            g.price = price;
            g.winner = winner;
            g.synced = !held;
            gWon += price;
            if (collected) gCollected += price;
        } else if (lane == Lane.Exit) {
            g.status = S_HELD;
        } else {
            g.status = S_LISTED;
            g.reserve = reserve;
        }
        everHeld.push(sid);
    }

    function seedGhostWindow(uint256 start, uint256 pot, uint256 spent) external {
        gWinStart = start;
        gWinPot = pot;
        gWinSpent = spent;
        gWinCap = core.settings().spendCapBps;
    }

    function numActors() external view returns (uint256) {
        return actors.length;
    }

    function everHeldCount() external view returns (uint256) {
        return everHeld.length;
    }

    function statementGhost(uint256 sid) external view returns (SG memory) {
        return _sg[sid];
    }

    function creditCount() external view returns (uint256) {
        return cgList.length;
    }

    function creditAt(uint256 i) external view returns (uint256) {
        return cgList[i];
    }

    function watchedCount() external view returns (uint256) {
        return watched.length;
    }

    function controllerCount() external view returns (uint256) {
        return controllers.length;
    }

    function actionName(uint256 a) external view returns (string memory) {
        return names[a];
    }

    function actionCount() external pure returns (uint256) {
        return N_ACTIONS;
    }

    function violationCount() external pure returns (uint256) {
        return N_VIOL;
    }

    function tally(uint256 a, string memory kind) public view returns (uint256) {
        return vm.envOr(string.concat("INV_", tag, "_", names[a], "_", kind), uint256(0));
    }

    /*//////////////////////////////////////////////////////////////
                               SMALL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _bump(uint8 a, string memory kind) internal {
        string memory key = string.concat("INV_", tag, "_", names[a], "_", kind);
        vm.setEnv(key, vm.toString(vm.envOr(key, uint256(0)) + 1));
    }

    function _att(uint8 a) internal {
        attempts[a]++;
        _bump(a, "att");
    }

    function _ok(uint8 a) internal {
        successes[a]++;
        _bump(a, "ok");
    }

    function _skip(uint8 a) internal {
        skips[a]++;
        _bump(a, "skip");
    }

    function _unexpected(uint8 a, bytes memory why) internal {
        unexpectedFails[a]++;
        if (why.length >= 4) {
            lastUnexpected[a] = bytes4(why);
            vm.setEnv(string.concat("INV_", tag, "_", names[a], "_lastsel"), vm.toString(bytes32(bytes4(why))));
        }
        _bump(a, "unexpected");
    }

    function _flag(uint256 code, string memory what) internal {
        viol[code]++;
        if (bytes(violMsg[code]).length == 0) violMsg[code] = what;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    /// lo * (hi / lo) ^ f with f taken from x, so small and large values are both common.
    function _logBound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        uint256 f = (x % 1_000_001) * 1e12;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 ratioLn = FixedPointMathLib.lnWad(int256(hi * 1e18 / lo));
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 e = int256(f) * ratioLn / 1e18;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 v = lo * uint256(FixedPointMathLib.expWad(e)) / 1e18;
        return v < lo ? lo : (v > hi ? hi : v);
    }

    function _score(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    function _removeFrom(uint256[] storage list, uint256 id) internal {
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == id) {
                list[i] = list[n - 1];
                list.pop();
                return;
            }
        }
    }

    function _addCredit(uint256 id, uint8 lane, uint256 cost) internal {
        if (!cg[id].inPile && cg[id].cost == 0) cgList.push(id);
        cg[id] = CG(true, lane, cost);
        pileCount[lane]++;
    }

    function _ownerOf(uint256 sid) internal view returns (address o) {
        (bool ok, bytes memory out) = address(STATEMENTS).staticcall(abi.encodeWithSignature("ownerOf(uint256)", sid));
        if (ok && out.length == 32) o = abi.decode(out, (address));
    }

    /// the exit token the core has set, zero before phase 2
    function _xt() internal view returns (MockExitToken) {
        return MockExitToken(core.exitToken());
    }

    function _xBal(address who) internal view returns (uint256) {
        address t = core.exitToken();
        return t == address(0) ? 0 : MockExitToken(t).balanceOf(who);
    }

    /// pool price helpers, coin and eth in raw units at the current launch pool price.
    function _sqrtP() internal view returns (uint160 p) {
        (p,,,) = PM.getSlot0(launchKey.toId());
    }

    /// eth is currency0 and the coin currency1, so the pool price is coin per eth and sqrtP squared is that price
    function _coinFor(uint256 eth) internal view returns (uint256) {
        uint160 p = _sqrtP();
        return FullMath.mulDiv(FullMath.mulDiv(eth, p, 1 << 96), p, 1 << 96);
    }

    function _ethFor(uint256 coinAmt) internal view returns (uint256) {
        uint160 p = _sqrtP();
        return FullMath.mulDiv(FullMath.mulDiv(coinAmt, 1 << 96, p), 1 << 96, p);
    }

    /// the cap room left in the current hourly window, as the core will see it.
    function _room() internal view returns (uint256) {
        uint256 ws =
            (uint256(vm.load(address(core), bytes32(SLOT_WINDOW_START))) >> WINDOW_START_SHIFT) & type(uint64).max;
        uint256 wp = uint256(vm.load(address(core), bytes32(SLOT_WINDOW_POT)));
        uint256 sp = uint256(vm.load(address(core), bytes32(SLOT_WINDOW_SPENT)));
        if (block.timestamp >= ws + 1 hours) {
            wp = core.ethPot();
            sp = 0;
        }
        // the core applies the cap in force now to the pot the window opened with
        uint256 cap = wp * core.settings().spendCapBps / 10_000;
        return cap > sp ? cap - sp : 0;
    }

    function _budget() internal view returns (uint256) {
        uint256 r = _room();
        uint256 p = core.ethPot();
        return r < p ? r : p;
    }

    /*//////////////////////////////////////////////////////////////
                         LEDGER AND RATE GUARDS
    //////////////////////////////////////////////////////////////*/

    /// eth flows of one action. `out` and `in_` are what the action explains, measured at the recipients.
    function _eth(uint256 b0, uint256 out, uint256 in_, string memory what) internal {
        uint256 b1 = address(core).balance;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 expected = int256(b0) + int256(in_) - int256(out);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 actual = int256(b1);
        if (actual < expected) _flag(V_ETH_OUT, what);
        else if (actual > expected) _flag(V_ETH_IN, what);
    }

    function _x(uint256 b0, uint256 out, uint256 in_, string memory what) internal {
        if (core.exitToken() == address(0)) return;
        uint256 b1 = _xBal(address(core));
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 expected = int256(b0) + int256(in_) - int256(out);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 actual = int256(b1);
        if (actual < expected) _flag(V_X_OUT, what);
        else if (actual > expected) _flag(V_X_IN, what);
    }

    /// a reverted action must leave the core's books untouched.
    function _failed(uint256 b0, uint256 pot0, uint256 rate0, string memory what) internal {
        if (address(core).balance != b0 || core.ethPot() != pot0 || core.ethRate() != rate0) {
            _flag(V_REVERT_CHANGED, what);
        }
    }

    struct RS {
        Settings st;
        uint256 rate;
        uint256 pot;
        bool funded;
        uint256 anchor;
        uint256 lastFill;
        uint256 stored;
        uint256 cp;
    }

    function _rs() internal view returns (RS memory s) {
        s.st = core.settings();
        s.rate = core.ethRate();
        s.pot = core.ethPot();
        s.stored = core.rateAtCheckpoint();
        s.cp = core.checkpointTime();
        s.funded = s.pot * s.st.spendCapBps >= uint256(s.st.avgScore) * s.stored;
        (s.anchor,,) = _anchorState();
        s.lastFill = core.lastFillTime();
    }

    /// the bid anchor state of the core, read from its storage: the rate of the last fill, the rate of the first fill in
    /// the current minute bucket, and that bucket
    function _anchorState() internal view returns (uint256 lastFillRate, uint256 minuteStartRate, uint256 bucket) {
        bytes32 slot = RateStore.SLOT;
        lastFillRate = uint256(vm.load(address(core), slot));
        minuteStartRate = uint256(vm.load(address(core), bytes32(uint256(slot) + 1)));
        bucket = uint64(uint256(vm.load(address(core), bytes32(uint256(slot) + 2))));
    }

    /// the rate a fill in the next transaction starts its minute from: the stored start inside the current minute
    /// bucket, `rate` (the rate it pays) when the bucket is new
    function _minuteStartNow(uint256 rate) internal view returns (uint256) {
        (, uint256 start, uint256 bucket) = _anchorState();
        return bucket == block.timestamp / 60 ? start : rate;
    }

    /// the price state of the eth rate right now, from the stored rate and the anchor: bounded by the ceiling and `rateCap`,
    /// climbing up to the clamp
    function _priceNow(Settings memory st) internal view returns (uint256) {
        (uint256 anchor,,) = _anchorState();
        return BidModel.price(
            st,
            core.rateAtCheckpoint(),
            core.ethPot(),
            anchor,
            block.timestamp - core.lastFillTime(),
            block.timestamp - core.checkpointTime()
        );
    }

    /// invariant 6 and its companions, against the settings in force over the interval (they cannot change inside
    /// one action or one warp, only the owner's calls change them and those are checked on their own). across a warp
    /// the read equals the model read from the state the interval started in. in an interval without time passing
    /// (any action except a warp, `setRate` and `setSettings`) the stored rate is at most the larger of the stored rate
    /// and the price state at the start of the interval, and the read is at most the larger of the read at the start
    /// and the clamp of the pot at the end.
    /// the stored funded flag must agree with the pot and the stored rate
    function _rsCheck(RS memory s, uint256 dt) internal {
        uint256 rate1 = core.ethRate();
        uint256 p =
            BidModel.price(s.st, s.stored, s.pot, s.anchor, block.timestamp - s.lastFill, block.timestamp - s.cp);
        if (dt != 0) {
            if (rate1 != BidModel.read(s.st, s.pot, p)) {
                _flag(V_RATE_BOUND, "the rate after a warp differs from the model");
            }
        } else {
            if (core.rateAtCheckpoint() > s.stored.max(p)) {
                _flag(V_RATE_BOUND, "the stored rate rose with no time passing");
            }
            if (rate1 > s.rate.max(BidModel.clamp(s.st, core.ethPot()))) {
                _flag(V_RATE_BOUND, "the rate rose above the previous read and the clamp with no time passing");
            }
        }
        _fundedCheck();
    }

    /// the exit side of the same rule, read from the core's storage (slots 14 and 15, `forge inspect Core
    /// storage-layout`): the stored flag is what the stored rate, the exit pot and the unit say
    function _xFundedCheck() internal {
        Settings memory st = core.settings();
        uint256 rate = uint256(vm.load(address(core), bytes32(uint256(14))));
        bool stored = (uint256(vm.load(address(core), bytes32(uint256(15)))) >> 64) & 0xff != 0;
        bool want = core.xPot() * 10_000 >= uint256(st.avgScore) * rate * core.unitPerPoint();
        if (stored != want) _flag(V_FUNDED_STALE, "exit funded flag disagrees with pot, stored rate and unit");
    }

    function _fundedCheck() internal {
        Settings memory st = core.settings();
        bool want = core.ethPot() * st.spendCapBps >= uint256(st.avgScore) * core.rateAtCheckpoint();
        if (core.funded() != want) _flag(V_FUNDED_STALE, "funded flag disagrees with pot and the stored rate");
    }

    /// independent hourly window ghost. a spend after the window expired opens a new window whose pot is the pot as
    /// it stood before the action. every spend adds to the window. the core compares the window's spend with the
    /// pot the window opened with times the cap in force at the spend, so that is what is checked. a spend that goes
    /// past the cap the window opened under, because the owner raised the cap since, is counted and reported
    function _recordSpend(uint256 x, uint256 potPre) internal {
        uint256 capNow = core.settings().spendCapBps;
        if (block.timestamp >= gWinStart + 1 hours) {
            gWinStart = block.timestamp;
            gWinPot = potPre;
            gWinSpent = 0;
            gWinCap = capNow;
            gWinCapChanged = false;
        }
        gWinSpent += x;
        gSpendEvents++;
        totalSpentEth += x;
        if (gWinPot != 0) {
            uint256 bps = gWinSpent * 10_000 / gWinPot;
            if (bps > biggestSpendBps) biggestSpendBps = bps;
        }
        if (gWinSpent * 10_000 > gWinPot * capNow) _flag(V_WINDOW, "window spend above the cap in force at the spend");
        if (gWinSpent * 10_000 > gWinPot * gWinCap) gOverOpenCap++;
        if (!gWinCapChanged && gWinSpent * 10_000 > gWinPot * gWinCap) {
            _flag(V_WINDOW, "window spend above the cap it opened under with no change of the cap");
        }
    }

    /// true while the controller in charge answers hostilely. its answers may depend on gas and on warm or cold
    /// storage, so the same question asked twice in one transaction can get two answers. the ceiling read before an
    /// action is then not what the core will use, and only the bonus cap bound holds.
    function _hostileNow() internal view returns (bool) {
        return core.controller() == address(fuzz) && fuzz.hostile();
    }

    /// the most the core may pay for a credit of `score` at `rate` under settings `s`: the blend of the flat share
    /// and the score share, with the controller bonus at its cap, written out again from docs/FLOW.md section 3
    function _maxPrice(uint256 score, uint256 rate, Settings memory s) internal pure returns (uint256) {
        uint256 blend = uint256(s.flatBps) * s.avgScore + (10_000 - uint256(s.flatBps)) * score;
        return blend * rate * (10_000 + uint256(s.bonusCapBps)) / (10_000 * 10_000 * 1e4);
    }

    /// the ceiling bound to check against: the exact one read before for a controller that answers the same way
    /// twice, the blended ceiling with the bonus cap for a hostile one. the bonus cap bound is always checked too
    function _ceilBound(uint256 readBefore, uint256 score, uint256 rate, Settings memory s)
        internal
        view
        returns (uint256)
    {
        return _hostileNow() ? _maxPrice(score, rate, s) : readBefore;
    }

    /// the stored price state and the read after the sells of one call at `costs`: each credit drops the price state, and the
    /// read after it is the price state lowered to the clamp of the smaller pot
    function _rateAfterSells(Settings memory st, SellPre memory p, uint256[] memory costs)
        internal
        pure
        returns (uint256 stored, uint256 r)
    {
        stored = p.price;
        uint256 pot = p.pot;
        uint256 start = p.minuteStart;
        for (uint256 i; i < costs.length; ++i) {
            start = BidModel.startAfter(st, stored, start);
            stored = _dropped(st, stored, start);
            pot -= costs[i];
        }
        r = _readAfterFill(st, stored, pot);
    }

    /// the read right after a fill: the stored price state, lowered to the clamp of the pot left
    function _readAfterFill(Settings memory st, uint256 stored, uint256 pot) internal pure returns (uint256) {
        return BidModel.read(st, pot, stored);
    }

    /// the rate after one credit bought with the price state `r`, where `start` is the price state at the first fill of
    /// the minute
    function _dropped(Settings memory st, uint256 r, uint256 start) internal pure returns (uint256) {
        return BidModel.dropOnce(st, r, start);
    }

    /*//////////////////////////////////////////////////////////////
                         LOG PARSING AND SKIM MODEL
    //////////////////////////////////////////////////////////////*/

    /// what the live hook reported for the swaps in `logs`: the eth volume it skimmed on, the core's leg (the
    /// bounty, which the hook pushes into the core's `receive()`) and the creator's leg
    function _skimOf(Vm.Log[] memory logs) internal view returns (uint256 volume, uint256 bounty, uint256 protocol) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != HOOK || logs[i].topics[0] != SKIM_SPLIT) continue;
            if (logs[i].topics.length > 1 && logs[i].topics[1] != poolId) continue;
            (uint256 v, uint256 b, uint256 p,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            volume += v;
            bounty += b;
            protocol += p;
        }
    }

    /// the skim rate the live anti sniper module reports for the next swap, in hundred thousandths. 90 percent at
    /// launch, falling linearly to the 6.9 percent baseline over the window
    function _skimBps() internal view returns (uint256 bps) {
        (uint24 b,) = IArtCoinsMevSkimV2(mev).currentSkimBps(poolId);
        bps = b;
        if (bps < 6_900) bps = 6_900;
    }

    /// the legs of a skim of `skim` eth at the rate `bps`, from the rules of the hook written out independently: the
    /// baseline part of the skim (6.9 points over the live rate) splits 90 percent to the router (the bounty recipient)
    /// and the rest to the protocol, and the whole extra above the baseline goes to the router
    function _expectSkim(uint256 skim, uint256 bps) internal pure returns (uint256 bounty, uint256 protocol) {
        uint256 base = skim * 6_900 / bps;
        if (base > skim) base = skim;
        uint256 share = base * 9000 / 10_000;
        protocol = base - share;
        bounty = share + (skim - base);
    }

    /// whether `skim` is the skim the hook takes on a swap whose pool eth amount was `volume`. a buy (eth in) skims
    /// on top of the pool amount, a sell skims out of it. exact input swaps round down once, so two wei of play
    function _skimTotalOk(uint256 volume, bool buy, uint256 bps, uint256 skim) internal pure returns (bool) {
        // a buy skims on top of the pool amount. a sell reports either the gross eth out (skim = volume * bps / 1e5) or
        // the net one (skim = volume * bps / (1e5 - bps)), by the kind of exact swap. the rounding of the pool amount is
        // scaled by bps / (100_000 - bps), which is 9 at the 90 point start
        uint256 tol = 3 + 2 * bps / (100_000 - bps);
        uint256 onTop = volume * bps / (100_000 - bps);
        if (skim + tol >= onTop && skim <= onTop + tol) return true;
        if (buy) return false;
        uint256 gross = volume * bps / 100_000;
        return skim + 2 >= gross && skim <= gross + 2;
    }

    /// what the router sends to the engine out of `amount`, from its own getters before the flush: the tip and the payees'
    /// parts per million of the gross amount (once the split is on) both come out of it
    function _routerEngine(uint256 amount) internal view returns (uint256) {
        uint256 tip = amount * feeRouter.tipPpm() / 1_000_000;
        if (tip > feeRouter.tipCap()) tip = feeRouter.tipCap();
        uint256 rest = amount - tip;
        if (feeRouter.splitOn()) {
            (, uint32[] memory ppm) = feeRouter.payees();
            for (uint256 i; i < ppm.length; ++i) {
                rest -= amount * ppm[i] / 1_000_000;
            }
        }
        return rest;
    }

    /// flushes the fee router as the flusher. returns the eth that arrived since the last flush (the router held that plus
    /// what a failed flush left waiting) and what the core must receive. the router's eth may only go to the engine set at
    /// that time, by the flush rule: the tip to the caller, the payees' parts, the rest to the engine. an engine that
    /// refuses makes the flush revert and the eth waits
    function _flushRouter() internal returns (uint256 fresh, uint256 toCore) {
        uint256 held = address(feeRouter).balance;
        uint256 owed = feeRouter.totalOwed();
        address eng = feeRouter.engine();
        if (eng != gEngine) _flag(V_ROUTER, "the router engine is not the one the owner set last");
        uint256 want = _routerEngine(held - owed);
        uint256 e0 = eng.balance;
        uint256 w0 = parked;
        vm.prank(flusher);
        try feeRouter.flush() {
            routerFlushes++;
            if (held != owed && eng.balance - e0 != want) {
                _flag(V_ROUTER, "the engine got other than the flush rule gives");
            }
            if (address(feeRouter).balance != owed) _flag(V_ROUTER, "a flush left eth in the router");
            parked = 0;
            toCore = eng == address(core) ? want : 0;
        } catch {
            // only the core and the counting engine are known to take eth: `repoint` also sets an address built from the fuzz
            // seed, which can be any contract of the run
            if (eng == address(core) || eng == otherEngine) {
                _flag(V_ROUTER, "a flush failed against an engine that takes eth");
            }
            if (address(feeRouter).balance != held || eng.balance != e0) _flag(V_ROUTER, "a failed flush moved eth");
            parked = held - owed;
        }
        if (held - owed < w0) {
            _flag(V_ROUTER, "the router holds less than what waited in it");
            return (0, toCore);
        }
        fresh = held - owed - w0;
    }

    /// the selector a failed swap really died of. the pool manager wraps a revert of the hook, so look inside
    function _rootSelector(bytes memory why) internal pure returns (bytes4 sel) {
        if (why.length < 4) return bytes4(0);
        sel = bytes4(why);
        if (sel == bytes4(0x90bfb865) && why.length >= 4 + 4 * 32) {
            bytes memory rest = new bytes(why.length - 4);
            for (uint256 i; i < rest.length; ++i) {
                rest[i] = why[i + 4];
            }
            (,, bytes memory reason,) = abi.decode(rest, (address, bytes4, bytes, bytes));
            if (reason.length >= 4) sel = bytes4(reason);
        }
    }

    /// counts a failed real swap by revert selector. a failed push into the core's `receive()` makes the hook revert
    /// with BidForwardFailed, which is the one reason that must never appear
    function _swapFailed(bytes memory why) internal {
        bytes4 sel = _rootSelector(why);
        if (swapFails[sel]++ == 0) swapFailSels.push(sel);
        if (sel == bytes4(keccak256("BidForwardFailed()"))) {
            receiveFails++;
            _flag(V_RECEIVE, "the core receive() reverted inside a real swap");
        }
    }

    function swapFailSelCount() external view returns (uint256) {
        return swapFailSels.length;
    }

    /// checks the coin after every action: the supply equals the ghost and never rose, the burn address never lost
    /// coin, and the core never holds coin
    function _coinCheck() internal {
        uint256 s = coin.totalSupply();
        if (s != gSupply) _flag(V_SUPPLY, "coin total supply differs from the ghost of buyback and auction burns");
        if (s > gSupplyLast) _flag(V_SUPPLY, "coin total supply rose");
        gSupplyLast = s;
        uint256 d = coin.balanceOf(DEAD);
        if (d < gDead) _flag(V_SUPPLY, "the burn address lost coin");
        gDead = d;
        if (coin.balanceOf(address(core)) != 0) _flag(V_SUPPLY, "the core holds coin");
    }

    /// the settings are the owner's alone: after every action they equal what the owner last set
    function _settingsCheck() internal {
        if (keccak256(abi.encode(core.settings())) != gSettingsHash) {
            _flag(V_SETTINGS, "the settings differ from what the owner last set");
        }
    }

    function _snapBase(address who) internal {
        Base storage b = baseOf[who];
        b.eth = who.balance;
        b.coin = coin.balanceOf(who);
        b.credits = CREDITS.balanceOf(who);
        b.statements = STATEMENTS.balanceOf(who);
        b.exitToken = _xBal(who);
    }

    /// what the house owes the core is the winning bids of the settled auctions less what was collected, always
    function _houseCheck() internal {
        if (house.pendingRefunds(address(core)) != gWon - gCollected) {
            _flag(V_HOUSE, "what the house owes the core differs from the winning bids less the collected");
        }
    }

    modifier checked() {
        _;
        _coinCheck();
        _houseCheck();
        _settingsCheck();
        _fundedCheck();
    }

    /*//////////////////////////////////////////////////////////////
                              POOL ACTIONS
    //////////////////////////////////////////////////////////////*/

    struct SwapPre {
        uint256 bal;
        uint256 pot;
        uint256 tb;
        uint256 rate;
        uint256 bps;
        bool exactIn;
        bool buy;
    }

    /// buys coin with eth through the launch pool. exact in or exact out. the skim of the live hook goes to the fee router
    /// and the flush after the swap books it in the pot. inside the sniper window that is most of the swap
    function buyCoin(uint256 aSeed, uint256 amtSeed, uint256 mode) external checked {
        uint8 a = A_BUY_COIN;
        address who = _actor(aSeed);
        uint256 eth = _logBound(amtSeed, 1e13, 25 ether);
        SwapPre memory p;
        p.exactIn = mode % 3 != 0;
        p.buy = true;
        p.bps = _skimBps();
        // an exact out buy pays the gross up of the skim on top, which is large inside the window
        uint256 value = p.exactIn ? eth : eth * 2 * 100_000 / (100_000 - p.bps) + 1e12;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 spec = p.exactIn ? -int256(eth) : int256(_coinFor(eth * 8 / 10));
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.tb = core.ethToBuyback();
        p.rate = core.ethRate();
        RS memory rs = _rs();
        vm.deal(who, who.balance + value);
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try router.swap{value: value}(launchKey, true, spec, who) {
            _ok(a);
            _afterSwap(p, vm.getRecordedLogs(), p.exactIn ? eth : 0, "buyCoin");
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "buyCoin");
            _swapFailed(why);
        }
        _rsCheck(rs, 0);
    }

    /// tries to move coin between wallets and into a side pool. the coin is restricted: the pool is the only way to
    /// move it, so a wallet to wallet transfer must revert and move nothing. a transfer to the core is the one thing that
    /// passes (the core is on the allowlist), and the owner takes it out again with `rescueCoin`. the books of the core
    /// must not move either way
    function walletMove(uint256 aSeed, uint256 amtSeed) external checked {
        uint8 a = A_WALLET_MOVE;
        address who = _actor(aSeed);
        address other = _actor(aSeed >> 8);
        uint256 bal = coin.balanceOf(who);
        if (bal < 2 || who == other) return _skip(a);
        uint256 amt = bound(amtSeed, 1, bal / 2);
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 supply0 = coin.totalSupply();
        _att(a);
        vm.prank(who);
        try coin.transfer(other, amt) returns (bool) {
            _flag(V_SUPPLY, "a wallet to wallet transfer of the restricted coin went through");
        } catch {
            _ok(a);
        }
        if (amtSeed % 3 == 0) {
            // a gift to the core is accepted and sits there, the owner rescues it. nothing is booked
            vm.prank(who);
            coin.transfer(address(core), amt);
            vm.prank(owner);
            core.rescueCoin(who, amt);
            if (coin.balanceOf(address(core)) != 0) _flag(V_SUPPLY, "rescueCoin left coin in the core");
        }
        _eth(b0, 0, 0, "walletMove");
        if (core.ethPot() != pot0) _flag(V_POT, "a coin move changed the pot");
        if (coin.totalSupply() != supply0) _flag(V_SUPPLY, "a coin move changed the supply");
    }

    /// sells coin for eth through the launch pool. exact in or exact out.
    function sellCoin(uint256 aSeed, uint256 fracSeed, uint256 mode) external checked {
        uint8 a = A_SELL_COIN;
        address who = _actor(aSeed);
        uint256 bal = coin.balanceOf(who);
        if (bal < 1e6) return _skip(a);
        SwapPre memory p;
        p.exactIn = mode % 4 != 0;
        p.bps = _skimBps();
        uint256 part = bal * bound(fracSeed, 1, 100) / 100;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 spec = p.exactIn ? -int256(part) : int256(_ethFor(part / 3));
        if (spec == 0) return _skip(a);
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.tb = core.ethToBuyback();
        p.rate = core.ethRate();
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try router.swap(launchKey, false, spec, who) {
            _ok(a);
            _afterSwap(p, vm.getRecordedLogs(), 0, "sellCoin");
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "sellCoin");
            _swapFailed(why);
        }
        _rsCheck(rs, 0);
    }

    /// the books after a real swap. the core's only inflow is the hook's bounty leg, it must equal what the hook
    /// reported, what the rules of the hook give for the skimmed volume at the rate read before, and it must all
    /// be booked into the pot. `exactVolume` is the eth volume the swap must have skimmed on, when known
    function _afterSwap(SwapPre memory p, Vm.Log[] memory logs, uint256 exactVolume, string memory what) internal {
        (uint256 volume, uint256 bounty, uint256 protocol) = _skimOf(logs);
        if (p.bps > 6_900) windowSwaps++;
        // the hook paid the bounty leg to the router, nothing reached the core yet. the flush books the engine share
        if (core.ethPot() != p.pot || address(core).balance != p.bal) _flag(V_POT, "the core booked before the flush");
        (uint256 held, uint256 toCore) = _flushRouter();
        if (held != bounty) _flag(V_POT, "the router received other than the hook bounty leg");
        _eth(p.bal, 0, toCore, what);
        // the router's eth is split by feeToBuybackBps in the core: that share to the coin buyback, the rest to the pot
        uint256 fee = toCore * core.settings().feeToBuybackBps / 10_000;
        if (core.ethPot() != p.pot + toCore - fee || core.ethToBuyback() != p.tb + fee) {
            _flag(V_POT, "swap skim not booked by the fee split");
        }
        if (volume != 0) {
            (uint256 eb, uint256 ep) = _expectSkim(bounty + protocol, p.bps);
            if (bounty != eb) _flag(V_POT, "skim bounty differs from the hook rules at the live rate");
            if (protocol != ep) _flag(V_POT, "skim creator leg differs from the hook rules at the live rate");
            if (!_skimTotalOk(volume, p.buy, p.bps, bounty + protocol)) {
                _flag(V_POT, "skim total differs from the hook rules at the live rate");
            }
        }
        // the hook reports the pool eth amount, which is the eth spent less the skim on an exact input buy
        if (exactVolume != 0 && (volume + bounty + protocol) + 2 < exactVolume) {
            _flag(V_POT, "skim volume is not the eth the swap spent");
        }
        if (exactVolume != 0 && (volume + bounty + protocol) > exactVolume) {
            _flag(V_POT, "skim volume is not the eth the swap spent");
        }
        // the whole skim is at most 90 percent of the gross eth of the swap. an exact output swap grosses the
        // skim up on top of the eth the pool moved
        uint256 gross = p.buy ? volume + bounty + protocol : volume;
        if ((bounty + protocol) * 100_000 > gross * 90_000 + 100_000) {
            _flag(V_POT, "skim above 90 percent of the swap");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              BUYING CREDITS
    //////////////////////////////////////////////////////////////*/

    struct SellPre {
        uint256 bal;
        uint256 pot;
        uint256 rate;
        uint256 price;
        uint256 minuteStart;
        uint256 sellerBal;
        uint256[] ceil;
        uint256[] score;
    }

    /// @dev the ids `sellForEth` offers: walks the actor inventory from a picked offset, within the budget unless overshoot
    function _pickIds(address who, uint256 len, uint256 want, uint256 pick, bool overshoot)
        internal
        view
        returns (uint256[] memory ids, uint256 n)
    {
        ids = new uint256[](want);
        uint256 budget = _budget();
        uint256 sum;
        for (uint256 k; k < len && k < want * 3 + 4 && n < want; ++k) {
            uint256 id = inventory[who][(pick % len + k) % len];
            uint256 c = core.ceilingOf(id);
            if (sum + c <= budget || overshoot) {
                ids[n++] = id;
                sum += c;
            }
        }
    }

    /// sells credits the actor holds into the eth bid. ids are picked to fit the budget, so most calls pass,
    /// and now and then the call is made oversized or with a duplicate id to prove the core refuses it.
    function sellForEth(uint256 aSeed, uint256 nSeed, uint256 pick, uint256 mode) external checked {
        uint8 a = A_SELL_FOR_ETH;
        address who = _actor(aSeed);
        uint256 len = inventory[who].length;
        if (len == 0) return _skip(a);
        uint256 want = bound(nSeed, 1, 10);
        bool overshoot = mode % 9 == 0;
        (uint256[] memory ids, uint256 n) = _pickIds(who, len, want, pick, overshoot);
        if (n == 0) return _skip(a);
        assembly {
            mstore(ids, n)
        }
        bool dup = mode % 17 == 0 && n > 1;
        if (dup) ids[1] = ids[0];

        SellPre memory p;
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.rate = core.ethRate();
        p.price = _priceNow(core.settings());
        p.minuteStart = _minuteStartNow(p.price);
        p.sellerBal = who.balance;
        p.ceil = new uint256[](n);
        p.score = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            p.ceil[i] = core.ceilingOf(ids[i]);
            p.score[i] = _score(ids[i]);
        }
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try core.sellForEth(ids) {
            _ok(a);
            _afterSell(who, ids, p, rs.st);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "sellForEth");
            // a hostile controller may answer differently each time it is asked, which moves the ceiling
            if (!overshoot && !dup && !_hostileNow()) _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    function _afterSell(address who, uint256[] memory ids, SellPre memory p, Settings memory st) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[] memory costs = new uint256[](ids.length);
        uint256 total;
        uint256 count;
        uint256 ceilSum;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != ICore.CreditBought.selector) continue;
            uint256 id = uint256(logs[i].topics[1]);
            (uint256 lane, uint256 cost) = abi.decode(logs[i].data, (uint256, uint256));
            if (lane != 0) _flag(V_MODEL, "sellForEth bought into the wrong lane");
            for (uint256 j; j < ids.length; ++j) {
                if (ids[j] == id) {
                    costs[j] = cost;
                    // invariant 2: the blended ceiling with the bonus cap in force, rate read just before the action
                    if (cost > _maxPrice(p.score[j], p.rate, st)) _flag(V_ABOVE_CAP, "sellForEth above the bonus cap");
                    uint256 limit = _ceilBound(p.ceil[j], p.score[j], p.rate, st);
                    if (cost > limit) _flag(V_ABOVE_CAP, "sellForEth above the ceiling read before");
                    ceilSum += limit;
                    break;
                }
            }
            total += cost;
            count++;
        }
        if (count != ids.length) _flag(V_MODEL, "sellForEth bought a different number of credits");
        uint256 paid = who.balance - p.sellerBal;
        if (paid != total) _flag(V_MODEL, "sellForEth paid differs from the sum of its events");
        if (paid > ceilSum) _flag(V_ABOVE_CAP, "sellForEth paid above the sum of ceilings");
        _eth(p.bal, paid, 0, "sellForEth");
        if (core.ethPot() != p.pot - total) _flag(V_POT, "sellForEth pot not reduced by the price");

        // the drop on each fill, independently: dropPerCreditBps per credit, no lower than the minute floor
        for (uint256 i; i < ids.length; ++i) {
            _recordSpend(costs[i], p.pot);
            _addCredit(ids[i], 0, costs[i]);
            _removeFrom(inventory[who], ids[i]);
        }
        (uint256 stored, uint256 r) = _rateAfterSells(st, p, costs);
        if (core.rateAtCheckpoint() != stored || core.ethRate() != r) {
            _flag(V_RATE_BOUND, "drop on fill differs from dropPerCreditBps with the minute floor");
        }
        if (core.lastFillTime() != block.timestamp) _flag(V_RATE_BOUND, "fill did not reset the fill clock");
    }

    /// buy a listed credit from the real CreditStrategy when the ceiling allows. now and then the call is made
    /// with a wrong value or wrong calldata or above the ceiling, and must revert without moving eth.
    function listingStrategy(uint256 pick, uint256 mode) external checked {
        uint8 a = A_LISTING_STRATEGY;
        uint256 id;
        uint256 price;
        bool allowed;
        uint256 n = candidates.length;
        for (uint256 k; k < n; ++k) {
            uint256 cand = candidates[(pick % n + k) % n];
            if (gone[cand]) continue;
            uint256 p = ICreditStrategy(STRATEGY).nftForSale(cand);
            if (p == 0) continue;
            // the keeper tip is booked as spend on top of the price, up to tipCapBps of it
            if (core.ceilingOf(cand) >= p && p * (10_000 + core.settings().tipCapBps) / 10_000 <= _budget()) {
                id = cand;
                price = p;
                allowed = true;
                break;
            }
            if (id == 0) {
                id = cand;
                price = p;
            }
        }
        if (id == 0 || (!allowed && mode % 4 != 0)) return _skip(a);
        uint256 variant = mode % 7;
        uint256 value = variant == 0 ? price - 1 : price;
        uint256 dataId = variant == 1 ? candidates[(pick % n + 1) % n] : id;
        bytes memory data = abi.encodeCall(ICreditStrategy.sellTargetNFT, (dataId));
        _listing(a, id, value, data, STRATEGY, price, allowed && variant > 1);
    }

    /// buy through a hostile target. only the honest modes may succeed, every other mode must revert and leave
    /// the core's eth where it was.
    function listingHostile(uint256 pick, uint256 modeSeed) external checked {
        uint8 a = A_LISTING_HOSTILE;
        uint256 n = probeIds.length;
        if (n < 2 || !core.allowedTarget(address(probe))) return _skip(a);
        uint256 id = probeIds[pick % n];
        uint256 wrongId = probeIds[(pick % n + 1) % n];
        if (gone[id] || gone[wrongId]) return _skip(a);
        uint256 ceiling = core.ceilingOf(id);
        uint256 budget = _budget();
        uint256 cap = ceiling < budget ? ceiling : budget;
        if (cap < 100) return _skip(a);
        uint256 m = modeSeed % 9;
        probe.setMode(m);
        uint256 value = cap / 2 + 1;
        bytes memory data = abi.encodeCall(ProbeTarget.fill, (id, wrongId));
        uint256 t0 = address(probe).balance;
        uint256 expectCost = m == 5 ? value - value / 2 : value;
        bool hon = probe.honest(m);
        _listing(a, id, value, data, address(probe), expectCost, hon);
        if (!hon && viol[V_HOSTILE_OK] == 0 && address(probe).balance != t0) {
            // a hostile mode that reverted must also leave the target's eth where it was
            _flag(V_REVERT_CHANGED, "hostile target eth moved without a buy");
        }
        if (probe.reentered() != 0) _flag(V_REENTER, "a reentry attempt succeeded");
    }

    struct LPre {
        uint256 bal;
        uint256 pot;
        uint256 rate;
        uint256 price;
        uint256 minuteStart;
        uint256 keeperBal;
        uint256 ceiling;
        uint256 score;
    }

    /// the shared body of the three listing actions. `expectCost` is the cost the target should produce.
    function _listing(
        uint8 a,
        uint256 id,
        uint256 value,
        bytes memory data,
        address target,
        uint256 expectCost,
        bool expect
    ) internal {
        LPre memory p;
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.rate = core.ethRate();
        p.price = _priceNow(core.settings());
        p.minuteStart = _minuteStartNow(p.price);
        p.keeperBal = keeper.balance;
        p.ceiling = core.ceilingOf(id);
        p.score = _score(id);
        RS memory rs = _rs();
        _att(a);
        vm.prank(keeper);
        try core.buyListing(value, data, id, target) {
            _ok(a);
            _afterListing(a, id, value, expectCost, p, rs.st);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "buyListing");
            if (expect) _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    function _afterListing(uint8 a, uint256 id, uint256 value, uint256 expectCost, LPre memory p, Settings memory st)
        internal
    {
        if (a == A_LISTING_HOSTILE && !probe.honest(probe.mode())) {
            _flag(V_HOSTILE_OK, "a hostile listing target got a buy through");
        }
        uint256 tip = keeper.balance - p.keeperBal;
        uint256 outflow = p.bal - address(core).balance;
        uint256 cost = outflow - tip;
        if (cost != expectCost) _flag(V_ETH_OUT, "listing cost differs from what the target should charge");
        // the ceiling was read before the action. the bonus cap and the tip rules are checked against it
        uint256 ceiling = _ceilBound(p.ceiling, p.score, p.rate, st);
        if (value > ceiling) _flag(V_ABOVE_CAP, "listing value above the ceiling");
        if (cost > value) _flag(V_ABOVE_CAP, "listing cost above the value");
        if (cost + tip > _maxPrice(p.score, p.rate, st)) _flag(V_ABOVE_CAP, "listing above the bonus cap");
        if (cost + tip > ceiling) _flag(V_ABOVE_CAP, "listing cost plus tip above the ceiling");
        if (
            tip * 10_000 > uint256(st.tipSavingsBps) * (ceiling > cost ? ceiling - cost : 0)
                || tip * 10_000 > uint256(st.tipCapBps) * cost
        ) {
            _flag(V_TIP, "tip above min(tipSavingsBps of savings, tipCapBps of cost)");
        }
        _eth(p.bal, tip + expectCost, 0, "buyListing");
        if (core.ethPot() != p.pot - cost - tip) _flag(V_POT, "listing pot not reduced by cost and tip");
        _recordSpend(cost + tip, p.pot);
        uint256 stored = _dropped(st, p.price, p.minuteStart);
        if (core.rateAtCheckpoint() != stored || core.ethRate() != _readAfterFill(st, stored, p.pot - cost - tip)) {
            _flag(V_RATE_BOUND, "drop on fill differs from dropPerCreditBps with the minute floor");
        }
        if (CREDITS.ownerOf(id) != address(core)) _flag(V_MODEL, "listing did not deliver the credit");
        gone[id] = true;
        _addCredit(id, 0, cost + tip);
    }

    /*//////////////////////////////////////////////////////////////
                                  TIME
    //////////////////////////////////////////////////////////////*/

    /// mostly minutes to hours, now and then days. the price state climbs 1 to 8 percent an hour, so a
    /// fuzz that warps days at a time pins it at the clamp.
    function warp(uint256 dtSeed) external checked {
        _att(A_WARP);
        _advance(dtSeed % 10 == 0 ? _logBound(dtSeed / 10, 1 hours, 3 days) : _logBound(dtSeed / 10, 60, 6 hours), 0);
        _ok(A_WARP);
    }

    function roll(uint256 nSeed) external checked {
        _att(A_ROLL);
        uint256 n = bound(nSeed, 1, 300);
        _advance(n * 12, n);
        _ok(A_ROLL);
    }

    function _advance(uint256 dt, uint256 blocks_) internal {
        RS memory s = _rs();
        uint256 xp0 = phase2() ? core.exitAuctionPrice() : 0;
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + (blocks_ == 0 ? dt / 12 + 1 : blocks_));
        _rsCheck(s, dt);
        // time alone never raises the exit token auction price
        if (phase2() && core.exitAuctionPrice() > xp0) _flag(V_AUCTION, "the auction price rose with time alone");
    }

    /*//////////////////////////////////////////////////////////////
                         COMPOSE, SALE, OVERPRINT
    //////////////////////////////////////////////////////////////*/

    /// the page the controller would answer, asked the way the core asks it.
    function _peekPage(Lane lane) internal view returns (bool ready, uint256[] memory ids, uint256 format) {
        ids = new uint256[](80);
        // the core reads the controller under a fixed gas cap of 500_000 in both lanes, and so does the model
        (bool ok, bytes memory out) =
            core.controller().staticcall{gas: 500_000}(abi.encodeWithSignature("nextPage(uint8)", uint8(lane)));
        if (!ok || out.length < 82 * 32) return (false, ids, 0);
        (uint256 flag, uint256[80] memory p, uint256 f) = abi.decode(out, (uint256, uint256[80], uint256));
        for (uint256 i; i < 80; ++i) {
            ids[i] = p[i];
        }
        return (flag == 1, ids, f);
    }

    function _validPage(Lane lane, uint256[] memory ids, uint256 format) internal view returns (bool) {
        if (format > 7) return false;
        for (uint256 i; i < 80; ++i) {
            CG storage c = cg[ids[i]];
            if (!c.inPile || c.lane != uint8(lane)) return false;
            for (uint256 j; j < i; ++j) {
                if (ids[j] == ids[i]) return false;
            }
        }
        return true;
    }

    struct CPre {
        uint256 pot;
        uint256 rate;
        uint256 bal;
        uint256 callerBal;
        uint256 supply;
        uint256 sum;
        uint256 basefee;
        uint256 gasUsed;
        Settings st;
        bool valid;
    }

    /// composes the controller's page. rare by gate, because it costs about 8m gas.
    function compose(uint256 gate, uint256 feeSeed) external checked {
        _compose(A_COMPOSE, Lane.Eth, gate, feeSeed);
    }

    function composeExit(uint256 gate, uint256 feeSeed) external checked {
        _compose(A_COMPOSE_EXIT, Lane.Exit, gate, feeSeed);
    }

    function _compose(uint8 a, Lane lane, uint256 gate, uint256 feeSeed) internal {
        if (lane == Lane.Exit && !phase2()) return _skip(a);
        (bool ready, uint256[] memory ids, uint256 format) = _peekPage(lane);
        // a pile of 80 is composed on one gate in two. a short pile only now and then, to see NotReady
        if (ready ? gate % 2 != 0 : gate % 13 != 0) return _skip(a);
        CPre memory p;
        p.valid = ready && _validPage(lane, ids, format);
        p.st = core.settings();
        p.pot = core.ethPot();
        p.rate = core.ethRate();
        p.bal = address(core).balance;
        p.callerBal = keeper.balance;
        p.supply = STATEMENTS.supply();
        p.basefee = _logBound(feeSeed, 0.05 gwei, 300 gwei);
        vm.fee(p.basefee);
        if (p.valid) {
            for (uint256 i; i < 80; ++i) {
                p.sum += cg[ids[i]].cost;
            }
        }
        uint256 xb0 = _xBal(address(core));
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        uint256 g0 = gasleft();
        vm.prank(keeper);
        if (lane == Lane.Eth) {
            try core.compose() {
                p.gasUsed = g0 - gasleft();
                _ok(a);
                _afterCompose(lane, ids, p);
            } catch (bytes memory why) {
                _composeFailed(a, p, why);
            }
        } else {
            try core.composeExit() {
                p.gasUsed = g0 - gasleft();
                _ok(a);
                _afterCompose(lane, ids, p);
            } catch (bytes memory why) {
                _composeFailed(a, p, why);
            }
        }
        _x(xb0, 0, 0, "compose exit token");
        _rsCheck(rs, 0);
    }

    function _composeFailed(uint8 a, CPre memory p, bytes memory why) internal {
        _failed(p.bal, p.pot, p.rate, "compose");
        // a hostile controller may fail to price the listing, and then the whole compose reverts
        // a hostile controller may also burn the core's 500_000 gas read of its page. the fuzz controller tries its
        // state changing attacks only inside the core's frame (each one halting a static frame burns the 300_000 gas
        // it was given), so the handler's own uncapped looking pre check cannot see that cost and the core answers
        // NotReady for a page the pre check saw as ready
        bool hostileNotReady = bytes4(why) == ICore.NotReady.selector && _mayNotPrice();
        if (p.valid && !(bytes4(why) == ICore.BadPrice.selector && _mayNotPrice()) && !hostileNotReady) {
            _unexpected(a, why);
        }
    }

    /// @dev the reimbursement checks of a compose, returns what the caller was paid (a helper so the locals of
    /// `_afterCompose` fit the stack)
    function _composeReimbursement(Lane lane, CPre memory p) internal returns (uint256 reimb) {
        reimb = keeper.balance - p.callerBal;
        // gas reimbursement: min(net gas * basefee * reimburseBps / REFUND_FLOOR_BPS, reimburseCapBps of the cost). the exit
        // lane caps against 80 average credits at the opening rate RATE_START. the gas used is the net gas the caller paid
        // (isolation: the transaction gas after the EIP-3529 refund), plus the fixed overhead and, on the eth lane, the
        // gas the core counts for the listing. the core meters gross gas and the refund is at most 20 percent of it, so
        // at 8000 bps the repayment is at most the net gas plus the overhead
        uint256 extra = 50_000 + (lane == Lane.Eth ? 350_000 : 0);
        uint256 gasCap = (p.gasUsed + extra) * p.basefee * p.st.reimburseBps / REFUND_FLOOR_BPS;
        uint256 base = lane == Lane.Eth ? p.sum : 80 * uint256(p.st.avgScore) * core.RATE_START() / 1e4;
        uint256 costCap = base * p.st.reimburseCapBps / 10_000;
        uint256 cap = gasCap < costCap ? gasCap : costCap;
        if (reimb > cap) {
            _flag(V_COMPOSE, "gas reimbursement above min(gas * basefee * reimburseBps, reimburseCapBps of cost)");
        }
        if (reimb > p.pot) _flag(V_COMPOSE, "gas reimbursement above the pot");
        _eth(p.bal, reimb, 0, "compose");
        if (core.ethPot() != p.pot - reimb) _flag(V_POT, "compose pot not reduced by the reimbursement");
    }

    function _afterCompose(Lane lane, uint256[] memory ids, CPre memory p) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!p.valid) _flag(V_COMPOSE, "composed a page the ghost model considers invalid");
        uint256 sid = STATEMENTS.supply();
        if (sid != p.supply + 1 || STATEMENTS.ownerOf(sid) != (lane == Lane.Eth ? address(house) : address(core))) {
            _flag(V_COMPOSE, "new statement id is not supply + 1 or not held by the house (eth lane) or the core");
        }
        uint256 reimb = _composeReimbursement(lane, p);
        uint256 cost = lane == Lane.Eth ? p.sum + reimb : p.sum;
        (bool held, Lane l, uint256 coreCost,) = core.statementInfo(sid);
        if (!held || l != lane || coreCost != cost) _flag(V_MODEL, "statement cost basis differs from the ghost sum");
        for (uint256 i; i < 80; ++i) {
            cg[ids[i]].inPile = false;
        }
        pileCount[uint8(lane)] -= 80;
        SG storage g = _sg[sid];
        g.lane = uint8(lane);
        g.cost = cost;
        everHeld.push(sid);
        if (lane == Lane.Exit) {
            g.status = S_HELD;
        } else {
            // the statement sits on the house at the reserve of the settings in force, listed now
            _ghostListed(sid, cost, p.st.saleFloorBps, logs);
        }
    }

    /// the controller in force is the hostile fuzz controller, which may fail or answer short when asked a price
    function _mayNotPrice() internal view returns (bool) {
        return core.controller() == address(fuzz) && fuzz.hostile();
    }

    /// the reserve the core must give a listing of `sid` priced at `listedAt`: the answer of the controller in force,
    /// asked as the core asks (static, 200_000 gas, one word), never below the hard floor. `ok` is false when the
    /// controller cannot answer, and then the core reverts
    function _wantReserve(uint256 sid, uint256 cost, uint64 listedAt, uint256 floorBps)
        internal
        view
        returns (bool ok, uint256 want)
    {
        bytes memory out;
        (ok, out) = core.controller().staticcall{gas: 200_000}(
            abi.encodeWithSignature("statementPrice(uint256,uint256,uint64)", sid, cost, listedAt)
        );
        if (!ok || out.length < 32) return (false, 0);
        want = abi.decode(out, (uint256));
        uint256 floor = cost * floorBps / 10_000;
        if (want < floor) want = floor;
    }

    /// the statement was listed on the house: the core's own event gives the auction id and the reserve, which must
    /// be what the controller in force asks (floored at the hard floor), and the house must hold the statement under
    /// that auction at that reserve
    function _ghostListed(uint256 sid, uint256 cost, uint256 saleFloorBps, Vm.Log[] memory logs) internal {
        SG storage g = _sg[sid];
        uint256 id;
        uint256 reserve;
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != ICore.StatementListed.selector) continue;
            if (uint256(logs[i].topics[1]) != sid) continue;
            id = uint256(logs[i].topics[2]);
            reserve = abi.decode(logs[i].data, (uint256));
            seen++;
        }
        if (seen != 1) _flag(V_MODEL, "a listing did not emit exactly one StatementListed");
        (bool priced, uint256 want) = _wantReserve(sid, cost, uint64(block.timestamp), saleFloorBps);
        if (!priced || reserve != want) {
            _flag(V_SALE_FLOOR, "the listing reserve is not the controller price, floored");
        }
        IAuctionHouse.Auction memory au = house.getAuction(id);
        if (au.reservePrice != reserve || au.tokenOwner != address(core) || au.tokenId != sid || au.amount != 0) {
            _flag(V_SALE_FLOOR, "the house record differs from what the core listed");
        }
        if (_ownerOf(sid) != address(house)) _flag(V_MODEL, "a listed statement is not held by the house");
        // invariant 3: no reserve is ever set below the hard floor of the settings in force at that moment
        g.floorAtSet = cost * saleFloorBps / 10_000;
        if (reserve < g.floorAtSet) _flag(V_SALE_FLOOR, "a listing reserve below the hard floor");
        g.status = S_LISTED;
        g.auctionId = id;
        g.reserve = reserve;
        g.listedAt = uint64(block.timestamp);
        g.bid = 0;
        g.bidder = address(0);
    }

    /// the statement can be named in an overprint: an exit lane statement the core holds, or an eth lane statement
    /// listed on the house with no bid on it
    function _openOrHeld(uint256 sid) internal view returns (bool) {
        SG storage g = _sg[sid];
        return g.status == S_HELD || (g.status == S_LISTED && g.bid == 0);
    }

    /// @dev the ghost bookkeeping and read back of a successful overprint (a helper so the locals fit the stack)
    function _overprintGhost(uint256 base, uint256 top, uint256 day, uint256 rb, uint256 rt, uint256 saleFloorBps)
        internal
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (day != gOpDay) {
            gOpDay = day;
            gOpCount = 0;
        }
        gOpCount++;
        _sg[base].cost += _sg[top].cost;
        _sg[top].status = S_TOP;
        _sg[top].base = base;
        _sg[top].ratingSum = rb + rt;
        // the eth lane base is listed again at the summed cost, its clock restarts. the exit lane is never listed
        bool eth = _sg[base].lane == uint8(Lane.Eth);
        if (eth) _ghostListed(base, _sg[base].cost, saleFloorBps, logs);
        (bool held, Lane lane, uint256 cost, uint64 clockStart) = core.statementInfo(base);
        if (
            !held || uint8(lane) != _sg[base].lane || cost != _sg[base].cost
                || clockStart != (eth ? block.timestamp : 0)
        ) {
            _flag(V_MODEL, "overprint cost basis or clock differs from the ghost");
        }
        if (STATEMENTS.creditScoreOf(base) != rb + rt) _flag(V_OVERPRINT, "overprint rating is not the sum");
        if (_ownerOf(top) != address(0)) _flag(V_OVERPRINT, "overprint top still exists");
    }

    /// overprint as the controller asks. the cap, the pair rules and the rating sum are checked against ghosts.
    function overprint() external checked {
        uint8 a = A_OVERPRINT;
        uint256 base;
        uint256 top;
        bool valid;
        {
            (bool ok, bytes memory out) = core.controller().staticcall(abi.encodeWithSignature("nextOverprint()"));
            if (!ok || out.length < 96) return _skip(a);
            uint256 flag;
            (flag, base, top) = abi.decode(out, (uint256, uint256, uint256));
            if (flag != 1 && block.number % 7 != 0) return _skip(a);
            valid = flag == 1 && base != top && _sg[base].lane == _sg[top].lane && _openOrHeld(base) && _openOrHeld(top);
        }
        uint256 day = block.timestamp / 1 days;
        bool capped = (day == gOpDay ? gOpCount : 0) >= 8;
        uint256 rb = valid ? STATEMENTS.creditScoreOf(base) : 0;
        uint256 rt = valid ? STATEMENTS.creditScoreOf(top) : 0;
        uint256 pot0 = core.ethPot();
        uint256 b0 = address(core).balance;
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(keeper);
        try core.overprint() {
            _ok(a);
            if (!valid) _flag(V_OVERPRINT, "overprint of a pair the ghost model considers invalid");
            if (capped) _flag(V_OVERPRINT, "ninth overprint of the day succeeded");
            _overprintGhost(base, top, day, rb, rt, rs.st.saleFloorBps);
            _eth(b0, 0, 0, "overprint");
        } catch (bytes memory why) {
            _failed(b0, pot0, rate0, "overprint");
            if (valid && !capped && !(bytes4(why) == ICore.BadPrice.selector && _mayNotPrice())) _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           BUYBACK, SKIM, DONATE
    //////////////////////////////////////////////////////////////*/

    struct BbPre {
        uint256 bal;
        uint256 pot;
        uint256 pool;
        uint256 rate;
        uint256 slice;
        uint256 tip0;
        uint256 whoBal;
        uint256 dead;
        uint256 bps;
        uint256 owed;
        uint256 toSales;
        Settings st;
    }

    /// the eth buyback: the core swaps a slice of the buyback pot for coin in the real pool and burns the coin on
    /// the token. the hook's skim of that swap comes back into the core's receive() as an inflow. the supply ghost
    /// falls by the coin the pool handed to the core, measured from the token's transfer events
    function buyback(uint256 aSeed) external checked {
        uint8 a = A_BUYBACK;
        address who = _actor(aSeed);
        BbPre memory p;
        p.st = core.settings();
        // sale proceeds waiting in the house are collected first, split by the settings in force now. the buyback
        // pot and the pot that the action starts from include that collection
        p.owed = house.pendingRefunds(address(core));
        p.toSales = p.owed * p.st.saleToBuybackBps / 10_000;
        p.pool = core.ethToBuyback() + p.toSales;
        if (p.pool == 0 || (block.number < core.lastBuybackBlock() + p.st.buybackDelay && aSeed % 5 != 0)) {
            return _skip(a);
        }
        p.slice = p.pool < p.st.buybackSlice ? p.pool : p.st.buybackSlice;
        p.tip0 = p.slice * p.st.keeperTipBps / 10_000;
        p.bal = address(core).balance;
        p.pot = core.ethPot() + p.owed - p.toSales;
        p.rate = core.ethRate();
        p.whoBal = who.balance;
        p.dead = coin.balanceOf(DEAD);
        p.bps = _skimBps();
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try core.buyback() {
            _ok(a);
            _afterBuyback(who, p, vm.getRecordedLogs());
        } catch (bytes memory why) {
            _failed(p.bal, p.pot + p.toSales - p.owed, p.rate, "buyback");
            _swapFailed(why);
        }
        _rsCheck(rs, 0);
    }

    function _afterBuyback(address who, BbPre memory p, Vm.Log[] memory logs) internal {
        uint256 tip = who.balance - p.whoBal;
        uint256 spent;
        uint256 evTip;
        uint256 bought;
        uint256 burned;
        uint256 collected;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == ICore.SalesCollected.selector) {
                (collected,) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (logs[i].emitter == address(core) && logs[i].topics[0] == ICore.Buyback.selector) {
                (spent, evTip) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (logs[i].emitter == address(coin) && logs[i].topics[0] == TRANSFER) {
                (uint256 amt) = abi.decode(logs[i].data, (uint256));
                if (address(uint160(uint256(logs[i].topics[2]))) == address(core)) bought += amt;
                if (address(uint160(uint256(logs[i].topics[1]))) == address(core) && logs[i].topics[2] == 0) {
                    burned += amt;
                }
            }
        }
        (uint256 volume, uint256 bounty, uint256 protocol) = _skimOf(logs);
        uint256 budget = p.slice - p.tip0;
        if (p.bps > 6_900) windowSwaps++;
        if (bought == 0) _flag(V_BUYBACK, "buyback bought no coin");
        if (burned != bought) _flag(V_BUYBACK, "buyback did not burn exactly the coin it bought");
        if (spent == 0 || spent > budget) _flag(V_BUYBACK, "buyback spent more than the slice less the tip");
        if (evTip != tip) _flag(V_BUYBACK, "buyback tip event differs from what the caller received");
        if (tip != p.tip0 * spent / budget) _flag(V_BUYBACK, "buyback tip is not keeperTipBps of the slice, scaled");
        _buybackPotChecks(p, spent, tip, bounty, collected);
        // a dust swap (the skim of it rounds to nothing) emits no skim event at all, and the fee share can now leave
        // one wei in the buyback pot, so a volume of zero is right when the whole skim rounds to zero
        _buybackSkimChecks(p, volume, bounty, protocol, spent, bought);
    }

    /// @dev the house, router flush and pot checks of a buyback (a helper so the locals of `_afterBuyback` fit the stack)
    function _buybackPotChecks(BbPre memory p, uint256 spent, uint256 tip, uint256 bounty, uint256 collected) internal {
        // the sale proceeds the house owed were collected first, once, by the amount it owed
        if (collected != p.owed) _flag(V_HOUSE, "buyback collected something other than what the house owed");
        gCollected += collected;
        // the skim of the swap went to the router. the flush books its engine share, split by feeToBuybackBps
        (uint256 held, uint256 toCore) = _flushRouter();
        if (held != bounty) _flag(V_BUYBACK, "the router received other than the hook bounty leg");
        uint256 feeShare = toCore * core.settings().feeToBuybackBps / 10_000;
        if (core.ethToBuyback() != p.pool - spent - tip + feeShare) {
            _flag(V_BUYBACK, "buyback pot is not the pot less what was spent and tipped, plus the fee share");
        }
        // eth leaves as the swap input plus the tip. the skim of the swap comes back as an inflow after the flush
        _eth(p.bal, spent + tip, toCore + p.owed, "buyback");
        if (core.ethPot() != p.pot + toCore - feeShare) _flag(V_POT, "buyback skim not booked to the pot");
    }

    /// @dev the skim and burn checks of a buyback (a helper so the locals of `_afterBuyback` fit the stack)
    function _buybackSkimChecks(
        BbPre memory p,
        uint256 volume,
        uint256 bounty,
        uint256 protocol,
        uint256 spent,
        uint256 bought
    ) internal {
        bool dust = volume == 0 && spent * p.bps / 100_000 == 0;
        uint256 sum = volume + bounty + protocol;
        if ((sum != spent) && !dust) _flag(V_BUYBACK, "buyback skim volume plus skim is not the eth spent");
        (uint256 eb, uint256 ep) = _expectSkim(bounty + protocol, p.bps);
        if (bounty != eb || protocol != ep) _flag(V_BUYBACK, "buyback skim differs from the hook rules");
        if (coin.balanceOf(DEAD) != p.dead) _flag(V_BUYBACK, "the buyback moved coin to the burn address");
        gSupply -= bought;
        gBurnedByBuyback += bought;
    }

    function skim(uint256 aSeed) external checked {
        uint8 a = A_SKIM;
        address who = _actor(aSeed);
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 tb0 = core.ethToBuyback();
        uint256 xb0 = _xBal(address(core));
        uint256 xp0 = core.xPot();
        uint256 xt0 = core.xToBuyback();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        _att(a);
        vm.prank(who);
        try core.skim() {
            _ok(a);
            uint256 booked = b0 > pot0 + tb0 ? b0 - pot0 - tb0 : 0;
            if (core.ethPot() != pot0 + booked || core.ethToBuyback() != tb0) {
                _flag(V_POT, "skim booked the wrong eth");
            }
            _eth(b0, 0, 0, "skim");
            if (core.exitToken() != address(0)) {
                uint256 xbooked = xb0 > xp0 + xt0 ? xb0 - xp0 - xt0 : 0;
                if (core.xPot() != xp0 + xbooked || core.xToBuyback() != xt0) {
                    _flag(V_POT, "skim booked the wrong exit token");
                }
                _x(xb0, 0, 0, "skim");
            }
        } catch (bytes memory why) {
            _failed(b0, pot0, rate0, "skim");
            _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    /// sends eth to the core's receive(), and in phase 2 exit token. a send from an account is accepted and not
    /// booked, the core books it only through skim. now and then the eth is sent to the fee router and flushed, which the
    /// core books into the pot at once. receive() must accept every one of them
    function donate(uint256 aSeed, uint256 amtSeed) external checked {
        uint8 a = A_DONATE;
        address who = _actor(aSeed);
        uint256 amt = _logBound(amtSeed, 1, 5 ether);
        bool fromHook = amtSeed % 4 == 1;
        address sender = who;
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 tb0 = core.ethToBuyback();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        vm.deal(sender, sender.balance + amt);
        _att(a);
        receiveSends++;
        uint256 expectIn = amt;
        uint256 fee;
        bool ok;
        if (fromHook) {
            // eth sent to the router and flushed: the engine share is booked as fees
            vm.prank(sender);
            (ok,) = address(feeRouter).call{value: amt}("");
            if (ok) {
                (, expectIn) = _flushRouter();
                fee = expectIn * core.settings().feeToBuybackBps / 10_000;
            }
        } else {
            vm.prank(sender);
            (ok,) = address(core).call{value: amt}("");
        }
        if (ok) {
            _ok(a);
            _eth(b0, 0, expectIn, "donate");
            if (core.ethPot() != pot0 + (fromHook ? expectIn - fee : 0) || core.ethToBuyback() != tb0 + fee) {
                _flag(V_POT, "a donation was booked wrongly");
            }
        } else {
            receiveFails++;
            _flag(V_RECEIVE, "a direct send to the core receive() reverted");
            _failed(b0, pot0, rate0, "donate");
        }
        if (phase2() && amtSeed % 3 == 0) _xt().mint(address(core), amt * 1000);
        _rsCheck(rs, 0);
    }

    /// anyone flushes the fee router, now and then after sending it some eth. whatever the engine is, only the engine set
    /// at that time may receive router eth. with the core as engine the core books the engine share by the fee split, with
    /// another engine the core's books do not move at all, with a refusing one nothing moves
    function flush(uint256 aSeed, uint256 amtSeed) external checked {
        uint8 a = A_FLUSH;
        address who = _actor(aSeed);
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 tb0 = core.ethToBuyback();
        RS memory rs = _rs();
        _att(a);
        if (amtSeed % 3 == 0) {
            uint256 amt = _logBound(amtSeed >> 4, 1, 3 ether);
            vm.deal(who, who.balance + amt);
            vm.prank(who);
            (bool ok,) = address(feeRouter).call{value: amt}("");
            if (!ok) _flag(V_ROUTER, "the router refused plain eth");
        }
        (, uint256 toCore) = _flushRouter();
        uint256 fee = toCore * core.settings().feeToBuybackBps / 10_000;
        _eth(b0, 0, toCore, "flush");
        if (core.ethPot() != pot0 + toCore - fee || core.ethToBuyback() != tb0 + fee) {
            _flag(V_POT, "a flush was booked wrongly");
        }
        _ok(a);
        _rsCheck(rs, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                CONTROLLER
    //////////////////////////////////////////////////////////////*/

    /// changes the answers of the fuzz controller. in the hostile suite it stays hostile.
    function controllerSeed(uint256 seed) external checked {
        _att(A_CONTROLLER_SEED);
        fuzz.setSeed(seed);
        _ok(A_CONTROLLER_SEED);
    }

    /// the owner swaps the controller at once, between the v1 controller and the fuzz controller
    function controllerSwap(uint256 which) external checked {
        uint8 a = A_CONTROLLER_SWAP;
        if (!canSwapController) return _skip(a);
        address target = which % 2 == 0 ? v1 : address(fuzz);
        if (target == core.controller()) return _skip(a);
        _att(a);
        bool locked = core.controllerLocked();
        vm.prank(owner);
        try core.setController(target) {
            if (locked) _flag(V_LOCK, "a locked controller door took a new controller");
            if (core.controller() != target) _flag(V_MODEL, "controller not set at once");
            _ok(a);
        } catch (bytes memory why) {
            if (!locked || bytes4(why) != ICore.Locked.selector) _unexpected(a, why);
            else _ok(a);
        }
    }

    /// the controller address makes calls that need an authority or an asset it does not have, outside any
    /// staticcall. none may succeed.
    function probeController(uint256 r) external checked {
        uint8 a = A_PROBE_CONTROLLER;
        _att(a);
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        uint256 mask = fuzz.probe(r);
        _ok(a);
        if (mask != 0) _flag(V_PROBE_OK, string.concat("controller attack calls succeeded, mask ", vm.toString(mask)));
        _failed(b0, pot0, rate0, "probeController");
    }

    /*//////////////////////////////////////////////////////////////
                                 PHASE 2
    //////////////////////////////////////////////////////////////*/

    struct XPre {
        uint256 xbal;
        uint256 xpot;
        uint256 xto;
        uint256 unit;
        uint256 rate;
        uint256 actorX;
        uint256[] score;
    }

    /// @dev the ids `sellForExit` offers: walks the actor inventory from a picked offset while the exit prices fit the pot
    function _pickExitIds(address who, uint256 len, uint256 want, uint256 pick, uint256 unit)
        internal
        view
        returns (uint256[] memory ids, uint256 n)
    {
        ids = new uint256[](want);
        uint256 pot = core.xPot();
        uint256 r = core.xRate();
        Settings memory st = core.settings();
        for (uint256 k; k < len && k < want * 3 + 4 && n < want; ++k) {
            uint256 id = inventory[who][(pick % len + k) % len];
            uint256 price = _score(id) * r * unit / 10_000;
            // a credit the exit bid prices at zero (an exit rate of zero, which the owner may set) is refused
            if (price != 0 && price <= pot) {
                pot -= price;
                r = r > st.xRateDropPerCredit ? r - st.xRateDropPerCredit : 0;
                if (r < st.xRateFloor) r = st.xRateFloor;
                ids[n++] = id;
            }
        }
    }

    /// sells credits into the exit token bid. ids are picked so the prices fit the pot.
    function sellForExit(uint256 aSeed, uint256 nSeed, uint256 pick) external checked {
        uint8 a = A_SELL_FOR_EXIT;
        if (!phase2()) return _skip(a);
        address who = _actor(aSeed);
        uint256 len = inventory[who].length;
        if (len == 0) return _skip(a);
        uint256 unit = _unitOf();
        if (unit == 0) return _skip(a);
        uint256 want = bound(nSeed, 1, 10);
        (uint256[] memory ids, uint256 n) = _pickExitIds(who, len, want, pick, unit);
        if (n == 0) return _skip(a);
        assembly {
            mstore(ids, n)
        }
        XPre memory p;
        p.xbal = _xBal(address(core));
        p.xpot = core.xPot();
        p.xto = core.xToBuyback();
        p.unit = unit;
        p.rate = core.xRate();
        p.actorX = _xBal(who);
        p.score = new uint256[](n);
        uint256 bound_;
        for (uint256 i; i < n; ++i) {
            p.score[i] = _score(ids[i]);
            bound_ += p.score[i] * p.rate * unit / 10_000;
        }
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try core.sellForExitToken(ids) {
            _ok(a);
            _afterSellExit(who, p, bound_, b0);
        } catch (bytes memory why) {
            _failed(b0, pot0, rate0, "sellForExit");
            _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    /// @dev the checks after a successful `sellForExit` (a helper so the locals fit the stack)
    function _afterSellExit(address who, XPre memory p, uint256 bound_, uint256 b0) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 total;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != ICore.CreditBought.selector) continue;
            (uint256 lane, uint256 cost) = abi.decode(logs[i].data, (uint256, uint256));
            uint256 id = uint256(logs[i].topics[1]);
            if (lane != 1) _flag(V_MODEL, "sellForExit bought into the wrong lane");
            total += cost;
            _addCredit(id, 1, cost);
            _removeFrom(inventory[who], id);
        }
        uint256 paid = _xBal(who) - p.actorX;
        if (paid != total) _flag(V_MODEL, "sellForExit paid differs from the sum of its events");
        // no credit is bought above score * xRate * unit read before, the rate only falls within the call
        if (paid > bound_) _flag(V_ABOVE_CAP, "sellForExit paid above score * xRate * unit read before");
        _x(p.xbal, paid, 0, "sellForExit");
        if (core.xPot() != p.xpot - paid) _flag(V_POT, "sellForExit exit pot not reduced by the price");
        _eth(b0, 0, 0, "sellForExit");
    }

    /// the unit the core stored when the module was last set. the module can change what it reports, the core reads
    /// it again only when a module is set
    function _unitOf() internal view returns (uint256 u) {
        return core.unitPerPoint();
    }

    struct EPre {
        uint256 xbal;
        uint256 xpot;
        uint256 xto;
        uint256 b0;
        uint256 pot0;
        uint256 rate0;
        uint256 rating;
        uint256 unit;
        uint256 required;
        uint256 startPrice;
        uint256 startTime;
        uint256 priceNow;
        uint256 callerBal;
        uint256 gasUsed;
        uint256 cost;
        uint8 lane;
        bool ripe;
        /// the statement is listed with no bid on it (eth lane), or held and never listed (exit lane)
        bool open;
        /// the selector the call must revert with when the model says it reverts, zero when the cause is the module
        bytes4 refusal;
        Settings st;
    }

    /// exits a held statement through the module. eth lane statements only after their auction ran its length.
    /// the module may be set to underpay, and then the exit must revert.
    function exitStatement(uint256 sIdx, uint256 aSeed) external checked {
        uint8 a = A_EXIT_STATEMENT;
        if (!phase2()) return _skip(a);
        uint256[] memory held = core.heldStatements();
        if (held.length == 0) return _skip(a);
        uint256 sid = held[sIdx % held.length];
        (, Lane lane,, uint64 clock) = core.statementInfo(sid);
        EPre memory p;
        p.st = core.settings();
        p.lane = uint8(lane);
        SG storage g = _sg[sid];
        p.ripe = lane == Lane.Exit || block.timestamp >= uint256(clock) + p.st.exitAfter;
        // an eth lane statement exits when it was listed without a bid for exitAfter. a bid makes the cancel revert,
        // and a sold statement the core has not synced is no longer on the house
        p.open = g.status == S_HELD || (g.status == S_LISTED && g.bid == 0);
        if (!p.ripe) p.refusal = ICore.TooEarly.selector;
        else if (g.status == S_SOLD) p.refusal = ICore.NotListed.selector;
        else if (g.status == S_LISTED && g.bid != 0) p.refusal = ICore.HasBid.selector;
        // an unripe or unopen eth lane statement is only tried now and then, to see the refusal
        if ((!p.ripe || !p.open) && aSeed % 6 != 0) return _skip(a);
        p.xbal = _xBal(address(core));
        p.xpot = core.xPot();
        p.xto = core.xToBuyback();
        p.b0 = address(core).balance;
        p.pot0 = core.ethPot();
        p.rate0 = core.ethRate();
        p.startPrice = core.xStartPrice();
        p.startTime = core.xStartTime();
        p.priceNow = core.exitAuctionPrice();
        p.rating = STATEMENTS.creditScoreOf(sid);
        p.unit = _unitOf();
        p.required = p.rating * p.unit;
        p.callerBal = keeper.balance;
        p.cost = g.cost;
        RS memory rs = _rs();
        _att(a);
        uint256 g0 = gasleft();
        vm.prank(keeper);
        try core.exitStatement(sid) {
            p.gasUsed = g0 - gasleft();
            _ok(a);
            _afterExit(sid, p);
        } catch (bytes memory why) {
            _failed(p.b0, p.pot0, p.rate0, "exitStatement");
            if (_ownerOf(sid) == address(0) || _ownerOf(sid) == address(module)) {
                _flag(V_DEPART, "an exit reverted but the statement left the core");
            }
            if (p.refusal != 0 && bytes4(why) != p.refusal) {
                _unexpected(a, why);
            } else if (p.refusal == 0 && p.open && p.unit != 0 && module.shortfallBps() == 0) {
                // the module pays by what it reports now. a payout below the stored unit must be refused
                if (module.currentUnit() >= p.unit) _unexpected(a, why);
            }
        }
        _rsCheck(rs, 0);
    }

    function _afterExit(uint256 sid, EPre memory p) internal {
        if (!p.ripe) _flag(V_DEPART, "an eth lane statement exited before exitAfter");
        if (!p.open) _flag(V_DEPART, "a statement with a bid, or already sold, was exited");
        uint256 received = _xBal(address(core)) - p.xbal;
        if (received < p.required) _flag(V_EXIT_SHORT, "exit returned less than rating * unitPerPoint");
        if (p.unit == 0) _flag(V_EXIT_SHORT, "exit with an unreadable unit per point");
        uint256 share = p.lane == uint8(Lane.Eth) ? p.st.exitToBuybackBps : p.st.exitLaneToBuybackBps;
        uint256 toBuyback = received * share / 10_000;
        if (core.xToBuyback() != p.xto + toBuyback) _flag(V_POT, "exit buyback share wrong");
        if (core.xPot() != p.xpot + received - toBuyback) _flag(V_POT, "exit pot share wrong");
        _x(p.xbal, 0, received, "exitStatement");
        // the caller's gas is repaid from the eth pot: at most reimburseBps of the gas (counted with the fixed overhead
        // and cut at 1.5m gas), reimburseCapBps of the cost (the exit lane: 80 average credits at the opening rate), and
        // the pot. nothing else moves
        uint256 reimb = keeper.balance - p.callerBal;
        // net gas paid plus the overhead, scaled to the metered gross gas by the refund floor, cut at 1.5m metered gas
        uint256 netCap = (p.gasUsed + 50_000) * p.st.reimburseBps / REFUND_FLOOR_BPS;
        uint256 meterCap = 1_500_000 * uint256(p.st.reimburseBps) / 10_000;
        uint256 gasCap = (netCap < meterCap ? netCap : meterCap) * block.basefee;
        uint256 base = p.lane == uint8(Lane.Eth) ? p.cost : 80 * uint256(p.st.avgScore) * core.RATE_START() / 1e4;
        uint256 costCap = base * p.st.reimburseCapBps / 10_000;
        if (reimb > gasCap || reimb > costCap) _flag(V_EXIT_SHORT, "the redeem reimbursement is above its caps");
        if (reimb > p.pot0) _flag(V_EXIT_SHORT, "the redeem reimbursement is above the pot");
        if (core.ethPot() != p.pot0 - reimb) _flag(V_POT, "the eth pot did not fall by the redeem reimbursement");
        _eth(p.b0, reimb, 0, "exitStatement");
        // every injection into the buyback pot re anchors the curve at max(price now, start / 4) and restarts the
        // clock. an exit that adds nothing to the pot changes neither
        uint256 wantPrice = p.startPrice;
        uint256 wantStart = p.startTime;
        if (toBuyback != 0) {
            wantPrice = p.priceNow > p.startPrice / 4 ? p.priceNow : p.startPrice / 4;
            if (wantPrice == 0) wantPrice = 1;
            wantStart = block.timestamp;
        }
        if (core.xStartPrice() != wantPrice) _flag(V_AUCTION, "an exit did not re anchor the auction start price");
        if (core.xStartTime() != wantStart) _flag(V_AUCTION, "an exit did not restart the auction clock on injection");
        if (_ownerOf(sid) != address(module)) _flag(V_DEPART, "exited statement is not with the module");
        SG storage g = _sg[sid];
        if (g.lane == uint8(Lane.Eth) && house.getAuction(g.auctionId).tokenOwner != address(0)) {
            _flag(V_DEPART, "an exit left the listing on the house");
        }
        g.status = S_EXITED;
        g.required = p.required;
        g.received = received;
        g.module = address(module);
    }

    struct XbPre {
        uint256 xbal;
        uint256 xpot;
        uint256 xto;
        uint256 startPrice;
        uint256 startTime;
        uint256 slice;
        uint256 price;
        uint256 coinIn;
        uint256 maxIn;
        uint256 takerCoin;
        uint256 takerX;
        uint256 b0;
        uint256 pot0;
        uint256 rate0;
    }

    /// buys exactly `coinOut` coin for `who` in the real pool, exact out, with the swap books checked like any other
    function _buyExact(address who, uint256 coinOut) internal returns (bool) {
        SwapPre memory p;
        p.bps = _skimBps();
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.tb = core.ethToBuyback();
        p.rate = core.ethRate();
        uint256 value = _ethFor(coinOut) * 3 * 100_000 / (100_000 - p.bps) + 1e12;
        vm.deal(who, who.balance + value);
        vm.recordLogs();
        vm.prank(who);
        // forge-lint: disable-next-line(unsafe-typecast)
        try router.swap{value: value}(launchKey, true, int256(coinOut), who) {
            _afterSwap(p, vm.getRecordedLogs(), 0, "auction coin buy");
            return true;
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "auction coin buy");
            _swapFailed(why);
            return false;
        }
    }

    /// the auction price written out again: the start price halved once per whole half life elapsed, and
    /// the part of a half life left over taken off with a plain exponential
    function _modelPrice(uint256 startPrice, uint256 dt, uint256 hl) internal pure returns (uint256 p) {
        uint256 halvings = dt / hl;
        if (halvings >= 256) return 0;
        p = startPrice >> halvings;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 e = -int256(693_147_180_559_945_309 * (dt % hl) / hl);
        // forge-lint: disable-next-line(unsafe-typecast)
        p = p * uint256(FixedPointMathLib.expWad(e)) / 1e18;
    }

    /// the exit token buyback is a dutch auction. a taker buys coin in the real pool when the price has fallen far
    /// enough for that to be cheap, approves the core and fills. now and then it bounds the fill one wei short
    function buybackExit(uint256 aSeed, uint256 mode) external checked {
        uint8 a = A_BUYBACK_EXIT;
        if (!phase2()) return _skip(a);
        XbPre memory p;
        p.xto = core.xToBuyback();
        if (p.xto == 0) return _skip(a);
        address who = _actor(aSeed);
        (p.slice, p.coinIn) = core.exitAuctionQuote();
        p.price = core.exitAuctionPrice();
        p.takerCoin = coin.balanceOf(who);
        if (p.takerCoin < p.coinIn) {
            uint256 need = p.coinIn - p.takerCoin;
            uint256 afford = _coinFor(2 ether);
            if (need > afford && mode % 2 == 0) {
                // the taker waits for the price to fall to what a little coin from the real pool can pay: one half
                // life per halving
                uint256 h = 1;
                while ((need >> h) > afford && h < 200) ++h;
                uint256 dt = h * core.settings().xAuctionHalfLife;
                _advance(dt > 30 days ? 30 days : dt, 0);
                (p.slice, p.coinIn) = core.exitAuctionQuote();
                p.price = core.exitAuctionPrice();
                need = p.coinIn > p.takerCoin ? p.coinIn - p.takerCoin : 0;
            }
            if (need > afford || (need != 0 && !_buyExact(who, need))) return _skip(a);
            p.takerCoin = coin.balanceOf(who);
        }
        vm.prank(who);
        coin.approve(address(core), type(uint256).max);
        p.maxIn = mode % 5 == 0 && p.coinIn != 0 ? p.coinIn - 1 : (mode % 3 == 0 ? p.coinIn : type(uint256).max);
        p.xbal = _xBal(address(core));
        p.xpot = core.xPot();
        p.startPrice = core.xStartPrice();
        p.startTime = core.xStartTime();
        p.takerX = _xBal(who);
        p.b0 = address(core).balance;
        p.pot0 = core.ethPot();
        p.rate0 = core.ethRate();
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try core.buybackExit(p.maxIn) {
            _ok(a);
            _afterAuction(who, p, vm.getRecordedLogs());
        } catch (bytes memory why) {
            _failed(p.b0, p.pot0, p.rate0, "buybackExit");
            _x(p.xbal, 0, 0, "buybackExit failed");
            if (core.xToBuyback() != p.xto || coin.balanceOf(who) != p.takerCoin) {
                _flag(V_REVERT_CHANGED, "a failed exit auction fill moved the pot or the taker's coin");
            }
            if (p.maxIn >= p.coinIn) _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    function _afterAuction(address who, XbPre memory p, Vm.Log[] memory logs) internal {
        uint256 slice;
        uint256 coinIn;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == ICore.ExitBuyback.selector) {
                (slice, coinIn) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        if (p.maxIn < p.coinIn) _flag(V_AUCTION, "a fill went through above the caller's maxCoinIn");
        // the slice is one full slice or what is left
        Settings memory st = core.settings();
        uint256 full = uint256(st.exitSliceCredits) * st.avgScore * core.unitPerPoint();
        if (slice != (p.xto < full ? p.xto : full) || slice != p.slice) {
            _flag(V_AUCTION, "auction slice is not min(pot, exitSliceCredits average credits of exit token)");
        }
        // the price: the quote read before, and the halving model written out again
        uint256 model = _modelPrice(p.startPrice, block.timestamp - p.startTime, st.xAuctionHalfLife);
        uint256 dp = model > p.price ? model - p.price : p.price - model;
        if (dp > p.price / 1e9 + 2) {
            _flag(V_AUCTION, "auction price is not the start price halved every xAuctionHalfLife");
        }
        // the exit token left the core only as this slice, paid for in coin at or above the quoted price
        uint256 owed = slice.mulDivUp(p.price, 1e18);
        if (coinIn < owed || coinIn != p.coinIn) _flag(V_AUCTION, "auction fill below the quoted coin price");
        if (p.coinIn == 0 && p.price != 0) _flag(V_AUCTION, "a free fill while the price is above zero");
        _x(p.xbal, slice, 0, "buybackExit");
        if (_xBal(who) != p.takerX + slice) _flag(V_X_OUT, "the taker did not receive exactly the slice");
        if (coin.balanceOf(who) != p.takerCoin - coinIn) _flag(V_SUPPLY, "the taker's coin did not fall by the fill");
        if (core.xToBuyback() != p.xto - slice) _flag(V_POT, "auction pot not reduced by the slice");
        if (core.xPot() != p.xpot) _flag(V_POT, "an auction fill touched the exit bid pot");
        // after a fill the auction restarts at max(2 * clearing, previous start / 4), never zero
        uint256 restart = (2 * p.price).max(p.startPrice / 4).max(1);
        if (core.xStartPrice() != restart || core.xStartTime() != block.timestamp) {
            _flag(V_AUCTION, "auction did not restart at max(2 * clearing, previous start / 4)");
        }
        if (core.xStartPrice() < p.startPrice / 4) {
            _flag(V_AUCTION, "auction restarted below a quarter of the last start");
        }
        _eth(p.b0, 0, 0, "buybackExit");
        gSupply -= coinIn;
        gBurnedByAuction += coinIn;
    }

    /// sets the module to underpay, to fail unit reads, to change its unit, or back to normal.
    function moduleMode(uint256 s) external checked {
        uint8 a = A_MODULE_MODE;
        if (!phase2()) return _skip(a);
        _att(a);
        uint256 m = s % 8;
        if (m < 4) {
            module.setShortfallBps(0);
            module.setRevertUnit(false);
        } else if (m == 4) {
            module.setShortfallBps(1 + (s >> 8) % 5000);
        } else if (m == 5) {
            module.setRevertUnit(true);
        } else {
            module.setUnitPerPoint(_logBound(s >> 8, 5e9, 2e10));
        }
        _ok(a);
    }
}
