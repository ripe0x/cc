// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Core} from "../../src/Core.sol";
import {Coin} from "../../src/Coin.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {Lane, ICredits, ICreditScore, ICreditStrategy, IStatements, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {MockExitModule} from "../mocks/MockExitModule.sol";
import {MockExitToken} from "../mocks/MockExitToken.sol";
import {MockSeller} from "../mocks/MockSeller.sol";
import {ProbeTarget} from "../mocks/ProbeTarget.sol";
import {FuzzController} from "../mocks/FuzzController.sol";
import {TestSwapRouter} from "../utils/TestSwapRouter.sol";

/// everything the handler needs to know about the system under test.
struct Wiring {
    Core core;
    Coin coin;
    FeeHook hook;
    TestSwapRouter router;
    PoolKey launchKey;
    PoolKey exitKey;
    address owner;
    address v1;
    FuzzController fuzz;
    MockSeller seller;
    ProbeTarget probe;
    MockExitModule module;
    MockExitToken exitToken;
    bool phase2;
    bool canSwapController;
    string tag;
}

/// @notice handler for the SPEC section 10 invariant suites. every action is bounded, never reverts, and keeps
/// ghost accounting that the invariant functions check. a violation is written to the `viol` counters and never
/// asserted here, because under `fail_on_revert = false` a reverting handler would hide it.
///
/// actors hold real credits moved out of the CreditStrategy by prank in the fixture. coin trades go through the
/// real launch pool on the real PoolManager, so the swap fees that fund the pot are real hook fees.
contract Handler is Test {
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
    uint8 internal constant A_LISTING_MOCK = 4;
    uint8 internal constant A_LISTING_HOSTILE = 5;
    uint8 internal constant A_WARP = 6;
    uint8 internal constant A_ROLL = 7;
    uint8 internal constant A_COMPOSE = 8;
    uint8 internal constant A_BUY_STATEMENT = 9;
    uint8 internal constant A_BUYBACK = 10;
    uint8 internal constant A_SKIM = 11;
    uint8 internal constant A_DONATE = 12;
    uint8 internal constant A_CONTROLLER_SEED = 13;
    uint8 internal constant A_CONTROLLER_SWAP = 14;
    uint8 internal constant A_OVERPRINT = 15;
    uint8 internal constant A_PROBE_CONTROLLER = 16;
    uint8 internal constant A_SELL_FOR_EXIT = 17;
    uint8 internal constant A_COMPOSE_EXIT = 18;
    uint8 internal constant A_EXIT_STATEMENT = 19;
    uint8 internal constant A_BUYBACK_EXIT = 20;
    uint8 internal constant A_MODULE_MODE = 21;
    uint8 internal constant A_SEND_EXIT_FEES = 22;
    uint8 internal constant A_EXIT_POOL_SWAP = 23;
    uint256 internal constant N_ACTIONS = 24;

    // violation codes
    uint256 internal constant V_ETH_OUT = 1; // eth left the core beyond what the action explains
    uint256 internal constant V_ETH_IN = 2; // eth arrived in the core beyond what the action explains
    uint256 internal constant V_X_OUT = 3; // exit token left the core beyond what the action explains
    uint256 internal constant V_X_IN = 4; // exit token arrived in the core beyond what the action explains
    uint256 internal constant V_ABOVE_CAP = 5; // a credit was bought above score * rate * (1 + bonus cap)
    uint256 internal constant V_TIP = 6; // a tip above min(10% of savings, 2% of cost)
    uint256 internal constant V_SALE_FLOOR = 7; // a statement sold below 1.2x its cost
    uint256 internal constant V_DEPART = 8; // a statement left the core without a recorded legal exit
    uint256 internal constant V_EXIT_SHORT = 9; // an exit that returned less than rating * unit per point
    uint256 internal constant V_MODEL = 10; // the core disagrees with the handler's ghost model
    uint256 internal constant V_RATE_UNFUNDED = 11; // the rate rose in an interval that began unfunded
    uint256 internal constant V_RATE_BOUND = 12; // the rate climbed faster or slower than the rules allow
    uint256 internal constant V_FUNDED_STALE = 13; // the stored funded flag disagrees with pot and rate
    uint256 internal constant V_WINDOW = 14; // hourly spend above the cap in the ghost window
    uint256 internal constant V_HOSTILE_OK = 15; // a hostile listing target got through
    uint256 internal constant V_PROBE_OK = 16; // a controller attack call succeeded
    uint256 internal constant V_REENTER = 17; // a reentry attempt succeeded
    uint256 internal constant V_REVERT_CHANGED = 18; // a reverted action changed core state
    uint256 internal constant V_OVERPRINT = 19; // an overprint outside the rules
    uint256 internal constant V_BUYBACK = 20; // a buyback slice or tip outside the rules
    uint256 internal constant V_COMPOSE = 21; // a compose outside the rules or a reimbursement above its cap
    uint256 internal constant V_POT = 22; // pot bookkeeping off from the action's flows
    uint256 internal constant V_REFUND = 23; // an overpayment refund that is not msg.value minus price
    uint256 internal constant N_VIOL = 24;

    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;
    IPoolManager internal constant PM = IPoolManager(Mainnet.POOL_MANAGER);
    address internal constant DEAD = Mainnet.DEAD;

    // core storage slots of windowStart (offset 17 in slot 14), windowPot and windowSpent.
    // from `forge inspect Core storage-layout`. the fixture proves them against public getters.
    uint256 internal constant SLOT_WINDOW_START = 14;
    uint256 internal constant WINDOW_START_SHIFT = 136;
    uint256 internal constant SLOT_WINDOW_POT = 15;
    uint256 internal constant SLOT_WINDOW_SPENT = 16;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    Core public core;
    Coin public coin;
    FeeHook public hook;
    TestSwapRouter public router;
    PoolKey public launchKey;
    PoolKey public exitKey;
    address public owner;
    address public v1;
    FuzzController public fuzz;
    MockSeller public seller;
    ProbeTarget public probe;
    MockExitModule public module;
    MockExitToken public exitToken;
    bool public phase2;
    bool public canSwapController;
    string public tag;

    address[] public actors;
    address public keeper;
    mapping(address => uint256[]) internal inventory;
    uint256[] internal candidates;
    uint256[] internal sellerIds;
    uint256[] internal probeIds;
    mapping(uint256 => bool) internal gone;
    /// every controller that was ever installed or probed. none may hold anything.
    address[] public controllers;

    // per action counters. the handler never reverts, so these survive failing core calls.
    uint256[24] public attempts;
    uint256[24] public successes;
    uint256[24] public skips;
    /// attempts the ghost model expected to succeed that reverted anyway
    uint256[24] public unexpectedFails;
    /// the selector of the latest unexpected revert of each action
    bytes4[24] public lastUnexpected;
    string[24] internal names;

    uint256[24] public viol;
    string[24] public violMsg;

    // ghost credits
    struct CG {
        bool inPile;
        uint8 lane;
        uint256 cost;
    }

    mapping(uint256 => CG) public cg;
    uint256[] internal cgList;
    uint256[2] public pileCount;

    // ghost statements
    struct SG {
        uint8 status; // 0 unknown, 1 held, 2 sold, 3 exited, 4 overprint top
        uint8 lane;
        uint256 cost;
        uint256 price; // sale: paid
        uint256 quote; // sale: priceOf at the time
        uint256 required; // exit: rating times unit per point
        uint256 received; // exit: exit token the core received
        uint256 base; // overprint top: the base it went into
        uint256 ratingSum; // overprint top: rating of base plus rating of top before
        address module; // exit: the module that took it
    }

    mapping(uint256 => SG) internal _sg;
    uint256[] public everHeld;

    // ghost hourly window
    uint256 public gWinStart;
    uint256 public gWinPot;
    uint256 public gWinSpent;
    uint256 public gSpendEvents;

    // overprint day counter in the ghost model
    uint256 internal gOpDay;
    uint256 internal gOpCount;

    // controller swap queue
    address internal pendingController;
    uint256 internal pendingEta;

    // ghost totals for the summary
    uint256 public totalSpentEth;
    uint256 public biggestSpendBps;

    constructor(Wiring memory w) {
        core = w.core;
        coin = w.coin;
        hook = w.hook;
        router = w.router;
        launchKey = w.launchKey;
        exitKey = w.exitKey;
        owner = w.owner;
        v1 = w.v1;
        fuzz = w.fuzz;
        seller = w.seller;
        probe = w.probe;
        module = w.module;
        exitToken = w.exitToken;
        phase2 = w.phase2;
        canSwapController = w.canSwapController;
        tag = w.tag;
        keeper = makeAddr("credeng.inv.keeper");
        string[24] memory n = [
            "buyCoin",
            "sellCoin",
            "sellForEth",
            "listingStrategy",
            "listingMock",
            "listingHostile",
            "warp",
            "roll",
            "compose",
            "buyStatement",
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
            "sendExitFees",
            "exitPoolSwap"
        ];
        names = n;
        controllers.push(w.v1);
        controllers.push(address(w.fuzz));
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

    function setSellerIds(uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            sellerIds.push(ids[i]);
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

    function seedGhostStatement(uint256 sid, uint8 lane, uint256 cost) external {
        _sg[sid] = SG(1, lane, cost, 0, 0, 0, 0, 0, 0, address(0));
        everHeld.push(sid);
    }

    function seedGhostWindow(uint256 start, uint256 pot, uint256 spent) external {
        gWinStart = start;
        gWinPot = pot;
        gWinSpent = spent;
    }

    function seedPendingController(address c, uint256 eta) external {
        pendingController = c;
        pendingEta = eta;
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

    function _xBal(address who) internal view returns (uint256) {
        return address(exitToken) == address(0) ? 0 : exitToken.balanceOf(who);
    }

    /// pool price helpers, coin and eth in raw units at the current launch pool price.
    function _sqrtP() internal view returns (uint160 p) {
        (p,,,) = PM.getSlot0(launchKey.toId());
    }

    function _coinFor(uint256 eth) internal view returns (uint256) {
        uint160 p = _sqrtP();
        return FullMath.mulDiv(FullMath.mulDiv(eth, 1 << 96, p), 1 << 96, p);
    }

    function _ethFor(uint256 coinAmt) internal view returns (uint256) {
        uint160 p = _sqrtP();
        return FullMath.mulDiv(FullMath.mulDiv(coinAmt, p, 1 << 96), p, 1 << 96);
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
        uint256 cap = wp * 2000 / 10_000;
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
        if (address(exitToken) == address(0)) return;
        uint256 b1 = exitToken.balanceOf(address(core));
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
        uint256 rate;
        uint256 pot;
        bool funded;
    }

    function _rs() internal view returns (RS memory s) {
        s.rate = core.ethRate();
        s.pot = core.ethPot();
        s.funded = s.pot * 10_000 >= core.AVG_SCORE() * s.rate;
    }

    /// invariant 6 and its companions. the rate may not rise in an interval that began unfunded. across a
    /// warp it may not climb faster than 8 percent an hour and, while funded and under the clamp, not slower
    /// than 1 percent an hour. the stored funded flag must agree with the pot and the rate.
    function _rsCheck(RS memory s, uint256 dt) internal {
        uint256 rate1 = core.ethRate();
        if (!s.funded && rate1 > s.rate) _flag(V_RATE_UNFUNDED, "rate rose in an interval that began unfunded");
        if (dt == 0) {
            if (rate1 > s.rate) _flag(V_RATE_BOUND, "rate rose with no time passing");
        } else {
            uint256 hoursWad = dt * 1e18 / 3600;
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 maxR = s.rate * uint256(FixedPointMathLib.powWad(1.08e18, int256(hoursWad))) / 1e18;
            if (rate1 > maxR + maxR / 1e9 + 4) _flag(V_RATE_BOUND, "rate climbed above 8 percent an hour");
            if (s.funded) {
                uint256 cap = s.pot * 10_000 / core.AVG_SCORE();
                uint256 minR = s.rate;
                if (s.rate < cap) {
                    // forge-lint: disable-next-line(unsafe-typecast)
                    minR = s.rate * uint256(FixedPointMathLib.powWad(1.01e18, int256(hoursWad))) / 1e18;
                    if (minR > cap) minR = cap;
                }
                if (rate1 + rate1 / 1e9 + 4 < minR) _flag(V_RATE_BOUND, "funded rate climbed below 1 percent an hour");
            } else if (rate1 != s.rate) {
                _flag(V_RATE_UNFUNDED, "unfunded rate moved");
            }
        }
        if (core.funded() != (core.ethPot() * 10_000 >= core.AVG_SCORE() * rate1)) {
            _flag(V_FUNDED_STALE, "funded flag disagrees with pot and rate");
        }
    }

    /// independent hourly window ghost. a spend after the window expired opens a new window whose pot is the
    /// pot as it stood before the action. every spend adds to the window.
    function _recordSpend(uint256 x, uint256 potPre) internal {
        if (block.timestamp >= gWinStart + 1 hours) {
            gWinStart = block.timestamp;
            gWinPot = potPre;
            gWinSpent = 0;
        }
        gWinSpent += x;
        gSpendEvents++;
        totalSpentEth += x;
        if (gWinPot != 0) {
            uint256 bps = gWinSpent * 10_000 / gWinPot;
            if (bps > biggestSpendBps) biggestSpendBps = bps;
        }
        if (gWinSpent * 10_000 > gWinPot * 2000) _flag(V_WINDOW, "ghost window spend above 20 percent of its pot");
    }

    /// true while the controller in charge answers hostilely. its answers may depend on gas and on warm or cold
    /// storage, so the same question asked twice in one transaction can get two answers. the ceiling read before an
    /// action is then not what the core will use, and only the bonus cap bound holds.
    function _hostileNow() internal view returns (bool) {
        return core.controller() == address(fuzz) && fuzz.hostile();
    }

    /// the ceiling bound to check against: the exact one read before for a controller that answers the same way
    /// twice, the bonus cap bound for a hostile one.
    function _ceilBound(uint256 readBefore, uint256 score, uint256 rate) internal view returns (uint256) {
        return _hostileNow() ? score * rate * 12_500 / 1e8 : readBefore;
    }

    /// what the rate becomes after a spend of x from pot p.
    function _dropped(uint256 r, uint256 x, uint256 p) internal pure returns (uint256) {
        return r - r * 1000 * x / (10_000 * p);
    }

    /*//////////////////////////////////////////////////////////////
                               LOG PARSING
    //////////////////////////////////////////////////////////////*/

    function _fees(Vm.Log[] memory logs, address currency) internal view returns (uint256 creatorCut, uint256 coreCut) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != FeeHook.FeesTaken.selector) continue;
            if (logs[i].topics[2] != bytes32(uint256(uint160(currency)))) continue;
            (uint256 c, uint256 k) = abi.decode(logs[i].data, (uint256, uint256));
            creatorCut += c;
            coreCut += k;
        }
    }

    /*//////////////////////////////////////////////////////////////
                              POOL ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// buys coin with eth through the launch pool. exact in or exact out. the fee funds the eth pot.
    function buyCoin(uint256 aSeed, uint256 amtSeed, uint256 mode) external {
        uint8 a = A_BUY_COIN;
        address who = _actor(aSeed);
        uint256 eth = _logBound(amtSeed, 1e13, 25 ether);
        bool exactOut = mode % 3 == 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 spec = exactOut ? int256(_coinFor(eth * 8 / 10)) : -int256(eth);
        uint256 value = exactOut ? eth * 2 : eth;
        RS memory rs = _rs();
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        vm.deal(who, who.balance + value);
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try router.swap{value: value}(launchKey, true, spec, who) {
            _ok(a);
            (uint256 creatorCut, uint256 coreCut) = _fees(vm.getRecordedLogs(), address(0));
            _eth(b0, 0, coreCut, "buyCoin");
            if (core.ethPot() != pot0 + coreCut) _flag(V_POT, "buyCoin fee not booked to the pot");
            if (creatorCut != (creatorCut + coreCut) * 50 / 1000) _flag(V_POT, "creator share off");
            if (!exactOut && creatorCut + coreCut != eth * 1000 / 10_000) _flag(V_POT, "buy fee is not 10 percent");
        } catch {
            _failed(b0, pot0, rs.rate, "buyCoin");
        }
        _rsCheck(rs, 0);
    }

    /// sells coin for eth through the launch pool. exact in or exact out.
    function sellCoin(uint256 aSeed, uint256 fracSeed, uint256 mode) external {
        uint8 a = A_SELL_COIN;
        address who = _actor(aSeed);
        uint256 bal = coin.balanceOf(who);
        if (bal < 1e6) return _skip(a);
        bool exactOut = mode % 4 == 0;
        uint256 part = bal * bound(fracSeed, 1, 100) / 100;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 spec = exactOut ? int256(_ethFor(part / 3)) : -int256(part);
        if (spec == 0) return _skip(a);
        RS memory rs = _rs();
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try router.swap(launchKey, false, spec, who) {
            _ok(a);
            (uint256 creatorCut, uint256 coreCut) = _fees(vm.getRecordedLogs(), address(0));
            _eth(b0, 0, coreCut, "sellCoin");
            if (core.ethPot() != pot0 + coreCut) _flag(V_POT, "sellCoin fee not booked to the pot");
            if (creatorCut != (creatorCut + coreCut) * 50 / 1000) _flag(V_POT, "creator share off");
        } catch {
            _failed(b0, pot0, rs.rate, "sellCoin");
        }
        _rsCheck(rs, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              BUYING CREDITS
    //////////////////////////////////////////////////////////////*/

    struct SellPre {
        uint256 bal;
        uint256 pot;
        uint256 rate;
        uint256 sellerBal;
        uint256[] ceil;
        uint256[] score;
    }

    /// sells credits the actor holds into the eth bid. ids are picked to fit the budget, so most calls pass,
    /// and now and then the call is made oversized or with a duplicate id to prove the core refuses it.
    function sellForEth(uint256 aSeed, uint256 nSeed, uint256 pick, uint256 mode) external {
        uint8 a = A_SELL_FOR_ETH;
        address who = _actor(aSeed);
        uint256 len = inventory[who].length;
        if (len == 0) return _skip(a);
        uint256 want = bound(nSeed, 1, 10);
        bool overshoot = mode % 9 == 0;
        uint256[] memory ids = new uint256[](want);
        uint256 n;
        {
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
            _afterSell(who, ids, p);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "sellForEth");
            if (!overshoot && !dup) _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    function _afterSell(address who, uint256[] memory ids, SellPre memory p) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[] memory costs = new uint256[](ids.length);
        uint256 total;
        uint256 count;
        uint256 ceilSum;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != Core.CreditBought.selector) continue;
            uint256 id = uint256(logs[i].topics[1]);
            (uint256 lane, uint256 cost) = abi.decode(logs[i].data, (uint256, uint256));
            if (lane != 0) _flag(V_MODEL, "sellForEth bought into the wrong lane");
            for (uint256 j; j < ids.length; ++j) {
                if (ids[j] == id) {
                    costs[j] = cost;
                    // invariant 2: score * rate * (1 + bonus cap), rate read just before the action
                    if (cost > p.score[j] * p.rate * 12_500 / 1e8) {
                        _flag(V_ABOVE_CAP, "sellForEth above the bonus cap");
                    }
                    uint256 limit = _ceilBound(p.ceil[j], p.score[j], p.rate);
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

        // the drop on each fill, independently: r -= r * 10% * x / pot, pot measured before each spend
        uint256 r = p.rate;
        uint256 pot = p.pot;
        for (uint256 i; i < ids.length; ++i) {
            _recordSpend(costs[i], p.pot);
            r = _dropped(r, costs[i], pot);
            pot -= costs[i];
            _addCredit(ids[i], 0, costs[i]);
            _removeFrom(inventory[who], ids[i]);
        }
        if (core.ethRate() != r) _flag(V_RATE_BOUND, "drop on fill is not proportional to the share spent");
        if (core.lastFillTime() != block.timestamp) _flag(V_RATE_BOUND, "fill did not reset the fill clock");
    }

    /// buy a listed credit from the real CreditStrategy when the ceiling allows. now and then the call is made
    /// with a wrong value or wrong calldata or above the ceiling, and must revert without moving eth.
    function listingStrategy(uint256 pick, uint256 mode) external {
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
            if (core.ceilingOf(cand) >= p && p <= _budget()) {
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

    /// buy a credit from a seller mock at a chosen price and refund. covers the tip rules and the cost basis.
    function listingMock(uint256 pick, uint256 priceSeed, uint256 refundSeed, uint256 mode) external {
        uint8 a = A_LISTING_MOCK;
        uint256 n = sellerIds.length;
        if (n == 0) return _skip(a);
        uint256 id = sellerIds[pick % n];
        if (gone[id]) return _skip(a);
        uint256 ceiling = core.ceilingOf(id);
        uint256 budget = _budget();
        uint256 cap = ceiling < budget ? ceiling : budget;
        if (cap < 100) return _skip(a);
        // a price from a tiny share of the ceiling up to a bit above it
        uint256 price = _logBound(priceSeed, cap / 1000 + 1, cap + cap / 4);
        uint256 kind = refundSeed % 5;
        uint256 refund = kind == 0 ? 0 : kind == 1 ? price / 2 : kind == 2 ? price - 1 : kind == 3 ? price : price + 1;
        seller.setRefund(refund);
        bytes memory data = abi.encodeCall(MockSeller.fill, (id, price));
        // success needs 0 < price - refund and price within the ceiling and budget. the tip may push the spend
        // above the room by a hair, which is a legal revert, so it is not treated as unexpected
        bool expect = refund < price && price <= cap && mode % 5 != 0;
        uint256 expectCost = refund < price ? price - refund : 0;
        _listing(a, id, price, data, address(seller), expectCost, expect);
    }

    /// buy through a hostile target. only the honest modes may succeed, every other mode must revert and leave
    /// the core's eth where it was.
    function listingHostile(uint256 pick, uint256 modeSeed) external {
        uint8 a = A_LISTING_HOSTILE;
        uint256 n = probeIds.length;
        if (n < 2) return _skip(a);
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
        p.keeperBal = keeper.balance;
        p.ceiling = core.ceilingOf(id);
        p.score = _score(id);
        RS memory rs = _rs();
        _att(a);
        vm.prank(keeper);
        try core.buyListing(value, data, id, target) {
            _ok(a);
            _afterListing(a, id, value, expectCost, p);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "buyListing");
            if (expect) _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    function _afterListing(uint8 a, uint256 id, uint256 value, uint256 expectCost, LPre memory p) internal {
        if (a == A_LISTING_HOSTILE && !probe.honest(probe.mode())) {
            _flag(V_HOSTILE_OK, "a hostile listing target got a buy through");
        }
        uint256 tip = keeper.balance - p.keeperBal;
        uint256 outflow = p.bal - address(core).balance;
        uint256 cost = outflow - tip;
        if (cost != expectCost) _flag(V_ETH_OUT, "listing cost differs from what the target should charge");
        // the ceiling was read before the action. the bonus cap and the tip rules are checked against it
        uint256 ceiling = _ceilBound(p.ceiling, p.score, p.rate);
        if (value > ceiling) _flag(V_ABOVE_CAP, "listing value above the ceiling");
        if (cost > value) _flag(V_ABOVE_CAP, "listing cost above the value");
        if (cost + tip > p.score * p.rate * 12_500 / 1e8) _flag(V_ABOVE_CAP, "listing above the bonus cap");
        if (cost + tip > ceiling) _flag(V_ABOVE_CAP, "listing cost plus tip above the ceiling");
        if (tip * 10_000 > 1000 * (ceiling > cost ? ceiling - cost : 0) || tip * 10_000 > 200 * cost) {
            _flag(V_TIP, "tip above min(10 percent of savings, 2 percent of cost)");
        }
        _eth(p.bal, tip + expectCost, 0, "buyListing");
        if (core.ethPot() != p.pot - cost - tip) _flag(V_POT, "listing pot not reduced by cost and tip");
        _recordSpend(cost + tip, p.pot);
        if (core.ethRate() != _dropped(p.rate, cost + tip, p.pot)) {
            _flag(V_RATE_BOUND, "drop on fill is not proportional to the share spent");
        }
        if (CREDITS.ownerOf(id) != address(core)) _flag(V_MODEL, "listing did not deliver the credit");
        gone[id] = true;
        _addCredit(id, 0, cost + tip);
    }

    /*//////////////////////////////////////////////////////////////
                                  TIME
    //////////////////////////////////////////////////////////////*/

    /// mostly minutes to hours, now and then days. the rate climbs 1 to 8 percent an hour while funded, so a
    /// fuzz that warps days at a time pins it at the funded clamp, where the hourly cap refuses every fill.
    function warp(uint256 dtSeed) external {
        _att(A_WARP);
        _advance(dtSeed % 10 == 0 ? _logBound(dtSeed / 10, 1 hours, 3 days) : _logBound(dtSeed / 10, 60, 6 hours), 0);
        _ok(A_WARP);
    }

    function roll(uint256 nSeed) external {
        _att(A_ROLL);
        uint256 n = bound(nSeed, 1, 300);
        _advance(n * 12, n);
        _ok(A_ROLL);
    }

    function _advance(uint256 dt, uint256 blocks_) internal {
        RS memory s = _rs();
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + (blocks_ == 0 ? dt / 12 + 1 : blocks_));
        _rsCheck(s, dt);
    }

    /*//////////////////////////////////////////////////////////////
                         COMPOSE, SALE, OVERPRINT
    //////////////////////////////////////////////////////////////*/

    /// the page the controller would answer, asked the way the core asks it.
    function _peekPage(Lane lane) internal view returns (bool ready, uint256[] memory ids, uint256 format) {
        ids = new uint256[](80);
        (bool ok, bytes memory out) =
            core.controller().staticcall(abi.encodeWithSignature("nextPage(uint8)", uint8(lane)));
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
        bool valid;
    }

    /// composes the controller's page. rare by gate, because it costs about 8m gas.
    function compose(uint256 gate, uint256 feeSeed) external {
        _compose(A_COMPOSE, Lane.Eth, gate, feeSeed);
    }

    function composeExit(uint256 gate, uint256 feeSeed) external {
        _compose(A_COMPOSE_EXIT, Lane.Exit, gate, feeSeed);
    }

    function _compose(uint8 a, Lane lane, uint256 gate, uint256 feeSeed) internal {
        if (lane == Lane.Exit && !phase2) return _skip(a);
        (bool ready, uint256[] memory ids, uint256 format) = _peekPage(lane);
        // a pile of 80 is composed on one gate in two. a short pile only now and then, to see NotReady
        if (ready ? gate % 2 != 0 : gate % 13 != 0) return _skip(a);
        CPre memory p;
        p.valid = ready && _validPage(lane, ids, format);
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
        if (p.valid) _unexpected(a, why);
    }

    function _afterCompose(Lane lane, uint256[] memory ids, CPre memory p) internal {
        vm.getRecordedLogs();
        if (!p.valid) _flag(V_COMPOSE, "composed a page the ghost model considers invalid");
        uint256 sid = STATEMENTS.supply();
        if (sid != p.supply + 1 || STATEMENTS.ownerOf(sid) != address(core)) {
            _flag(V_COMPOSE, "new statement id is not supply + 1 or not owned by the core");
        }
        uint256 reimb = keeper.balance - p.callerBal;
        // gas reimbursement: min(gas * basefee * 110%, 5% of the statement cost). the exit lane caps against
        // 80 average credits at the eth rate. the gas used is what the handler saw, which is at least what
        // the core measured, plus its fixed overhead
        uint256 gasCap = (p.gasUsed + 50_000) * p.basefee * 110 / 100;
        uint256 costCap = lane == Lane.Eth ? p.sum * 500 / 10_000 : 80 * core.AVG_SCORE() * p.rate / 1e4 * 500 / 10_000;
        uint256 cap = gasCap < costCap ? gasCap : costCap;
        if (reimb > cap) _flag(V_COMPOSE, "gas reimbursement above min(gas * basefee * 110%, 5% of cost)");
        if (reimb > p.pot) _flag(V_COMPOSE, "gas reimbursement above the pot");
        _eth(p.bal, reimb, 0, "compose");
        if (core.ethPot() != p.pot - reimb) _flag(V_POT, "compose pot not reduced by the reimbursement");
        uint256 cost = lane == Lane.Eth ? p.sum + reimb : p.sum;
        (bool held, Lane l, uint256 coreCost,) = core.statementInfo(sid);
        if (!held || l != lane || coreCost != cost) _flag(V_MODEL, "statement cost basis differs from the ghost sum");
        for (uint256 i; i < 80; ++i) {
            cg[ids[i]].inPile = false;
        }
        pileCount[uint8(lane)] -= 80;
        _sg[sid] = SG(1, uint8(lane), cost, 0, 0, 0, 0, 0, 0, address(0));
        everHeld.push(sid);
    }

    struct BPre {
        uint256 bal;
        uint256 pot;
        uint256 toBuyback;
        uint256 rate;
        uint256 buyerBal;
        uint256 price;
        uint256 cost;
        uint256 value;
    }

    /// buys an eth lane statement at its auction price with a random overpayment.
    function buyStatement(uint256 sIdx, uint256 aSeed, uint256 overSeed, uint256 mode) external {
        uint8 a = A_BUY_STATEMENT;
        uint256[] memory held = core.heldStatements();
        if (held.length == 0) return _skip(a);
        uint256 sid = held[sIdx % held.length];
        (, Lane lane, uint256 cost,) = core.statementInfo(sid);
        address who = _actor(aSeed);
        BPre memory p;
        p.cost = cost;
        if (lane == Lane.Eth) {
            p.price = core.priceOf(sid);
        } else {
            // an exit lane statement is not for sale. a call with eth must revert
            p.price = 1 ether;
        }
        uint256 over = mode % 4 == 0 ? 0 : _logBound(overSeed, 1, 20 ether);
        p.value = p.price + over;
        bool under = mode % 11 == 0;
        if (under) p.value = p.price - 1;
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.toBuyback = core.ethToBuyback();
        p.rate = core.ethRate();
        vm.deal(who, who.balance + p.value);
        p.buyerBal = who.balance;
        RS memory rs = _rs();
        _att(a);
        vm.prank(who);
        try core.buyStatement{value: p.value}(sid) {
            _ok(a);
            _afterBuy(sid, who, lane, p);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "buyStatement");
            if (lane == Lane.Eth && !under) _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    function _afterBuy(uint256 sid, address who, Lane lane, BPre memory p) internal {
        if (lane != Lane.Eth) _flag(V_SALE_FLOOR, "an exit lane statement was sold for eth");
        if (p.value < p.price) _flag(V_SALE_FLOOR, "sold for less than the price");
        uint256 paid = p.buyerBal - who.balance;
        // refund is msg.value minus price, so the buyer is out exactly the price
        if (paid != p.price) _flag(V_REFUND, "buyer paid something other than the price, refund is off");
        _eth(p.bal, 0, paid, "buyStatement");
        SG storage g = _sg[sid];
        // invariant 3: the price paid against the ghost cost basis
        if (paid * 10_000 < g.cost * 12_000) _flag(V_SALE_FLOOR, "statement sold below 1.2x its cost");
        if (paid * 10_000 > g.cost * 40_000 + 10_000) _flag(V_SALE_FLOOR, "statement sold above 4x its cost");
        if (g.cost != p.cost) _flag(V_MODEL, "statement cost basis differs from the ghost");
        uint256 toBuyback = paid * 5000 / 10_000;
        if (core.ethToBuyback() != p.toBuyback + toBuyback) _flag(V_POT, "sale buyback share is not half");
        if (core.ethPot() != p.pot + paid - toBuyback) _flag(V_POT, "sale pot share is not the other half");
        if (STATEMENTS.ownerOf(sid) != who) _flag(V_MODEL, "buyer does not own the statement");
        g.status = 2;
        g.price = paid;
        g.quote = p.price;
    }

    /// overprint as the controller asks. the cap, the pair rules and the rating sum are checked against ghosts.
    function overprint() external {
        uint8 a = A_OVERPRINT;
        (bool ok, bytes memory out) = core.controller().staticcall(abi.encodeWithSignature("nextOverprint()"));
        if (!ok || out.length < 96) return _skip(a);
        (uint256 flag, uint256 base, uint256 top) = abi.decode(out, (uint256, uint256, uint256));
        if (flag != 1 && block.number % 7 != 0) return _skip(a);
        bool valid = flag == 1 && base != top && _sg[base].status == 1 && _sg[top].status == 1
            && _sg[base].lane == _sg[top].lane;
        uint256 day = block.timestamp / 1 days;
        uint256 countToday = day == gOpDay ? gOpCount : 0;
        bool capped = countToday >= 8;
        uint256 rb = valid ? STATEMENTS.creditScoreOf(base) : 0;
        uint256 rt = valid ? STATEMENTS.creditScoreOf(top) : 0;
        uint256 pot0 = core.ethPot();
        uint256 b0 = address(core).balance;
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        _att(a);
        vm.prank(keeper);
        try core.overprint() {
            _ok(a);
            if (!valid) _flag(V_OVERPRINT, "overprint of a pair the ghost model considers invalid");
            if (capped) _flag(V_OVERPRINT, "ninth overprint of the day succeeded");
            if (day != gOpDay) {
                gOpDay = day;
                gOpCount = 0;
            }
            gOpCount++;
            _sg[base].cost += _sg[top].cost;
            _sg[top].status = 4;
            _sg[top].base = base;
            _sg[top].ratingSum = rb + rt;
            (bool held, Lane lane, uint256 cost, uint64 clockStart) = core.statementInfo(base);
            if (!held || uint8(lane) != _sg[base].lane || cost != _sg[base].cost || clockStart != block.timestamp) {
                _flag(V_MODEL, "overprint cost basis or clock differs from the ghost");
            }
            if (STATEMENTS.creditScoreOf(base) != rb + rt) _flag(V_OVERPRINT, "overprint rating is not the sum");
            if (_ownerOf(top) != address(0)) _flag(V_OVERPRINT, "overprint top still exists");
            _eth(b0, 0, 0, "overprint");
        } catch (bytes memory why) {
            _failed(b0, pot0, rate0, "overprint");
            if (valid && !capped) _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           BUYBACK, SKIM, DONATE
    //////////////////////////////////////////////////////////////*/

    function buyback(uint256 aSeed) external {
        uint8 a = A_BUYBACK;
        address who = _actor(aSeed);
        uint256 pool0 = core.ethToBuyback();
        if (pool0 == 0 || (block.number < core.lastBuybackBlock() + 25 && aSeed % 5 != 0)) return _skip(a);
        uint256 slice = pool0 < 1 ether ? pool0 : 1 ether;
        uint256 tipExp = slice * 50 / 10_000;
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        uint256 whoBal = who.balance;
        uint256 dead0 = coin.balanceOf(DEAD);
        uint256 supply0 = coin.totalSupply();
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try core.buyback() {
            _ok(a);
            uint256 tip = who.balance - whoBal;
            (, uint256 coreCut) = _fees(vm.getRecordedLogs(), address(0));
            if (tip != tipExp) _flag(V_BUYBACK, "buyback tip is not 0.5 percent of the slice");
            if (core.ethToBuyback() != pool0 - slice) _flag(V_BUYBACK, "buyback slice is not min(1 ether, pot)");
            // the swap pays the same fee as anyone, the core share comes back to the pot
            uint256 fee = (slice - tip) * 1000 / 10_000;
            if (coreCut != fee - fee * 50 / 1000) _flag(V_BUYBACK, "buyback fee share off");
            _eth(b0, slice, coreCut, "buyback");
            if (core.ethPot() != pot0 + coreCut) _flag(V_POT, "buyback fee not booked to the pot");
            if (coin.balanceOf(DEAD) <= dead0) _flag(V_BUYBACK, "buyback sent no coin to the dead address");
            if (coin.totalSupply() != supply0) _flag(V_BUYBACK, "coin supply moved in a buyback");
        } catch {
            _failed(b0, pot0, rate0, "buyback");
        }
        _rsCheck(rs, 0);
    }

    function skim(uint256 aSeed) external {
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
            if (address(exitToken) != address(0)) {
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

    /// sends eth, and in phase 2 exit token, to the core without booking. the core books it only through skim.
    function donate(uint256 aSeed, uint256 amtSeed) external {
        uint8 a = A_DONATE;
        address who = _actor(aSeed);
        uint256 amt = _logBound(amtSeed, 1, 5 ether);
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        vm.deal(who, who.balance + amt);
        _att(a);
        vm.prank(who);
        (bool ok,) = address(core).call{value: amt}("");
        if (ok) {
            _ok(a);
            _eth(b0, 0, amt, "donate");
            if (core.ethPot() != pot0) _flag(V_POT, "a plain eth transfer was booked");
        } else {
            _failed(b0, pot0, rate0, "donate");
        }
        if (phase2 && amtSeed % 3 == 0) exitToken.mint(address(core), amt * 1000);
        _rsCheck(rs, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                CONTROLLER
    //////////////////////////////////////////////////////////////*/

    /// changes the answers of the fuzz controller. in the hostile suite it stays hostile.
    function controllerSeed(uint256 seed) external {
        _att(A_CONTROLLER_SEED);
        fuzz.setSeed(seed);
        _ok(A_CONTROLLER_SEED);
    }

    /// queues a controller change through the owner timelock, and executes a queued one once it is ripe.
    function controllerSwap(uint256 which) external {
        uint8 a = A_CONTROLLER_SWAP;
        if (!canSwapController) return _skip(a);
        if (pendingController != address(0)) {
            if (block.timestamp < pendingEta) return _skip(a);
            _att(a);
            address next = pendingController;
            pendingController = address(0);
            vm.prank(owner);
            try core.execute(Core.Action.SetController, abi.encode(next)) {
                if (core.controller() != next) _flag(V_MODEL, "controller not set by execute");
                _ok(a);
            } catch {}
            return;
        }
        address target = which % 2 == 0 ? v1 : address(fuzz);
        if (target == core.controller()) return _skip(a);
        _att(a);
        vm.prank(owner);
        try core.queue(Core.Action.SetController, abi.encode(target)) {
            pendingController = target;
            pendingEta = block.timestamp + 7 days;
            _ok(a);
        } catch {}
    }

    /// the controller address makes calls that need an authority or an asset it does not have, outside any
    /// staticcall. none may succeed.
    function probeController(uint256 r) external {
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

    /// sells credits into the exit token bid. ids are picked so the prices fit the pot.
    function sellForExit(uint256 aSeed, uint256 nSeed, uint256 pick) external {
        uint8 a = A_SELL_FOR_EXIT;
        if (!phase2) return _skip(a);
        address who = _actor(aSeed);
        uint256 len = inventory[who].length;
        if (len == 0) return _skip(a);
        uint256 unit = _unitOf();
        if (unit == 0) return _skip(a);
        uint256 want = bound(nSeed, 1, 10);
        uint256[] memory ids = new uint256[](want);
        uint256 n;
        {
            uint256 pot = core.xPot();
            uint256 r = core.xRate();
            for (uint256 k; k < len && k < want * 3 + 4 && n < want; ++k) {
                uint256 id = inventory[who][(pick % len + k) % len];
                uint256 price = _score(id) * r * unit / 10_000;
                if (price <= pot) {
                    pot -= price;
                    r = r >= 3020 ? r - 20 : 3000;
                    ids[n++] = id;
                }
            }
        }
        if (n == 0) return _skip(a);
        assembly {
            mstore(ids, n)
        }
        XPre memory p;
        p.xbal = exitToken.balanceOf(address(core));
        p.xpot = core.xPot();
        p.xto = core.xToBuyback();
        p.unit = unit;
        p.rate = core.xRate();
        p.actorX = exitToken.balanceOf(who);
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
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 total;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != address(core) || logs[i].topics[0] != Core.CreditBought.selector) continue;
                (uint256 lane, uint256 cost) = abi.decode(logs[i].data, (uint256, uint256));
                uint256 id = uint256(logs[i].topics[1]);
                if (lane != 1) _flag(V_MODEL, "sellForExit bought into the wrong lane");
                total += cost;
                _addCredit(id, 1, cost);
                _removeFrom(inventory[who], id);
            }
            uint256 paid = exitToken.balanceOf(who) - p.actorX;
            if (paid != total) _flag(V_MODEL, "sellForExit paid differs from the sum of its events");
            // no credit is bought above score * xRate * unit read before, the rate only falls within the call
            if (paid > bound_) _flag(V_ABOVE_CAP, "sellForExit paid above score * xRate * unit read before");
            _x(p.xbal, paid, 0, "sellForExit");
            if (core.xPot() != p.xpot - paid) _flag(V_POT, "sellForExit exit pot not reduced by the price");
            _eth(b0, 0, 0, "sellForExit");
        } catch (bytes memory why) {
            _failed(b0, pot0, rate0, "sellForExit");
            _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    /// the unit the core stored when the module was set. the module can change what it reports, the core never
    /// reads it again
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
        uint8 lane;
        bool ripe;
    }

    /// exits a held statement through the module. eth lane statements only after their auction ran its length.
    /// the module may be set to underpay, and then the exit must revert.
    function exitStatement(uint256 sIdx, uint256 aSeed) external {
        uint8 a = A_EXIT_STATEMENT;
        if (!phase2) return _skip(a);
        uint256[] memory held = core.heldStatements();
        if (held.length == 0) return _skip(a);
        uint256 sid = held[sIdx % held.length];
        (, Lane lane,, uint64 clock) = core.statementInfo(sid);
        EPre memory p;
        p.lane = uint8(lane);
        p.ripe = lane == Lane.Exit || block.timestamp >= uint256(clock) + 72 hours;
        // an unripe eth lane statement is only tried now and then, to see the refusal
        if (!p.ripe && aSeed % 6 != 0) return _skip(a);
        p.xbal = exitToken.balanceOf(address(core));
        p.xpot = core.xPot();
        p.xto = core.xToBuyback();
        p.b0 = address(core).balance;
        p.pot0 = core.ethPot();
        p.rate0 = core.ethRate();
        p.rating = STATEMENTS.creditScoreOf(sid);
        p.unit = _unitOf();
        p.required = p.rating * p.unit;
        RS memory rs = _rs();
        _att(a);
        vm.prank(keeper);
        try core.exitStatement(sid) {
            _ok(a);
            _afterExit(sid, p);
        } catch (bytes memory why) {
            _failed(p.b0, p.pot0, p.rate0, "exitStatement");
            if (_ownerOf(sid) != address(core)) _flag(V_DEPART, "an exit reverted but the statement left the core");
            // the module pays by what it reports now. a payout below the stored unit must be refused
            if (p.ripe && p.unit != 0 && module.shortfallBps() == 0 && module.currentUnit() >= p.unit) {
                _unexpected(a, why);
            }
        }
        _rsCheck(rs, 0);
    }

    function _afterExit(uint256 sid, EPre memory p) internal {
        if (!p.ripe) _flag(V_DEPART, "an eth lane statement exited before its auction ran its length");
        uint256 received = exitToken.balanceOf(address(core)) - p.xbal;
        if (received < p.required) _flag(V_EXIT_SHORT, "exit returned less than rating * unitPerPoint");
        if (p.unit == 0) _flag(V_EXIT_SHORT, "exit with an unreadable unit per point");
        uint256 toBuyback = p.lane == uint8(Lane.Eth) ? received * 5000 / 10_000 : 0;
        if (core.xToBuyback() != p.xto + toBuyback) _flag(V_POT, "exit buyback share wrong");
        if (core.xPot() != p.xpot + received - toBuyback) _flag(V_POT, "exit pot share wrong");
        _x(p.xbal, 0, received, "exitStatement");
        _eth(p.b0, 0, 0, "exitStatement");
        if (_ownerOf(sid) != address(module)) _flag(V_DEPART, "exited statement is not with the module");
        SG storage g = _sg[sid];
        g.status = 3;
        g.required = p.required;
        g.received = received;
        g.module = address(module);
    }

    /// the exit token buyback through the coin and exit token pool.
    function buybackExit(uint256 aSeed) external {
        uint8 a = A_BUYBACK_EXIT;
        if (!phase2) return _skip(a);
        address who = _actor(aSeed);
        uint256 pool0 = core.xToBuyback();
        uint256 unit = _unitOf();
        if (pool0 == 0 || unit == 0) return _skip(a);
        uint256 maxSlice = 20 * core.AVG_SCORE() * unit;
        uint256 slice = pool0 < maxSlice ? pool0 : maxSlice;
        // the swap amount leaves room for the hook fee, which is taken on what the swap actually spent
        uint256 tip0 = slice * 50 / 10_000;
        uint256 budget = slice - tip0;
        uint256 swapIn = budget * 9000 / 10_000;
        uint256 fee = swapIn * 1000 / 9000;
        uint256 spentExp = swapIn + fee;
        uint256 tipExp = tip0 * spentExp / budget;
        uint256 xb0 = exitToken.balanceOf(address(core));
        uint256 whoX = exitToken.balanceOf(who);
        uint256 dead0 = coin.balanceOf(DEAD);
        uint256 supply0 = coin.totalSupply();
        uint256 owed0 = hook.creatorExitOwed();
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        _att(a);
        vm.prank(who);
        try core.buybackExit() {
            _ok(a);
            uint256 tip = exitToken.balanceOf(who) - whoX;
            if (tip != tipExp) _flag(V_BUYBACK, "exit buyback tip is not 0.5 percent of the slice");
            if (core.xToBuyback() != pool0 - spentExp - tipExp) {
                _flag(V_BUYBACK, "exit buyback pot is not the pot less what was spent and tipped");
            }
            _x(xb0, spentExp + tipExp, 0, "buybackExit");
            _eth(b0, 0, 0, "buybackExit");
            if (coin.balanceOf(DEAD) <= dead0) _flag(V_BUYBACK, "exit buyback sent no coin to the dead address");
            if (coin.totalSupply() != supply0) _flag(V_BUYBACK, "coin supply moved in an exit buyback");
            if (hook.creatorExitOwed() != owed0 + fee * 50 / 1000) _flag(V_BUYBACK, "exit buyback creator share off");
        } catch {
            _failed(b0, pot0, rate0, "buybackExit");
        }
        _rsCheck(rs, 0);
    }

    /// sets the module to underpay, to fail unit reads, to change its unit, or back to normal.
    function moduleMode(uint256 s) external {
        uint8 a = A_MODULE_MODE;
        if (!phase2) return _skip(a);
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
            module.setUnitPerPoint(_logBound(s >> 8, 5e13, 2e14));
        }
        _ok(a);
    }

    /// pays the hook's accrued exit token fees to the core, and sometimes the creator's share to the creator.
    function sendExitFees(uint256 s) external {
        uint8 a = A_SEND_EXIT_FEES;
        if (!phase2) return _skip(a);
        uint256 id = uint256(uint160(address(exitToken)));
        uint256 claims = IERC6909Claims(address(PM)).balanceOf(address(hook), id);
        uint256 owed = hook.creatorExitOwed();
        if (claims < owed) _flag(V_MODEL, "hook claims below creator owed");
        uint256 xb0 = exitToken.balanceOf(address(core));
        uint256 xp0 = core.xPot();
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        _att(a);
        if (s % 3 == 0 && owed != 0) {
            try hook.claimCreator() {
                if (hook.creatorExitOwed() != 0) _flag(V_MODEL, "claimCreator left owed");
            } catch {}
        }
        uint256 amount = claims > owed ? claims - owed : 0;
        vm.prank(keeper);
        try hook.sendExitFeesToCore() {
            _ok(a);
            _x(xb0, 0, amount, "sendExitFees");
            if (core.xPot() != xp0 + amount) _flag(V_POT, "exit fees not booked to the exit pot");
        } catch (bytes memory why) {
            if (amount != 0) _unexpected(a, why);
        }
        _eth(b0, 0, 0, "sendExitFees");
        _failed(b0, pot0, rate0, "sendExitFees");
        _rsCheck(rs, 0);
    }

    /// trades coin and the exit token in the exit pool. the fee is taken in the exit token and accrues at the hook.
    function exitPoolSwap(uint256 aSeed, uint256 amtSeed, uint256 dirSeed) external {
        uint8 a = A_EXIT_POOL_SWAP;
        if (!phase2) return _skip(a);
        address who = _actor(aSeed);
        bool exitIs0 = Currency.unwrap(exitKey.currency0) == address(exitToken);
        bool exitIn = dirSeed % 2 == 0;
        address tokenIn = exitIn ? address(exitToken) : address(coin);
        uint256 bal = ERC20Like(tokenIn).balanceOf(who);
        if (bal < 1e6) return _skip(a);
        uint256 amt = bal * bound(amtSeed, 1, 60) / 100;
        bool zeroForOne = exitIn ? exitIs0 : !exitIs0;
        uint256 xb0 = exitToken.balanceOf(address(core));
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        _att(a);
        vm.prank(who);
        try router.swap(exitKey, zeroForOne, -int256(amt), who) {
            _ok(a);
            _x(xb0, 0, 0, "exitPoolSwap");
            _eth(b0, 0, 0, "exitPoolSwap");
        } catch {
            _failed(b0, pot0, rate0, "exitPoolSwap");
        }
        _rsCheck(rs, 0);
    }
}

interface ERC20Like {
    function balanceOf(address) external view returns (uint256);
}
