// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Core} from "../../src/Core.sol";
import {Lane, ICredits, ICreditScore, ICreditStrategy, IStatements, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {IArtCoinsToken, IArtCoinsMevSkim} from "../../src/interfaces/ArtCoins.sol";
import {MockExitModule} from "../standins/MockExitModule.sol";
import {MockExitToken} from "../standins/MockExitToken.sol";
import {ProbeTarget} from "../attackers/ProbeTarget.sol";
import {FuzzController} from "../attackers/FuzzController.sol";
import {TestSwapRouter} from "../utils/TestSwapRouter.sol";

/// everything the handler needs to know about the system under test.
struct Wiring {
    Core core;
    IArtCoinsToken coin;
    TestSwapRouter router;
    PoolKey launchKey;
    PoolKey sideKey;
    bytes32 poolId;
    address owner;
    address v1;
    FuzzController fuzz;
    ProbeTarget probe;
    MockExitModule module;
    MockExitToken exitToken;
    bool canSwapController;
    string tag;
}

/// @notice handler for the SPEC section 10 invariant suites. every action is bounded, never reverts, and keeps
/// ghost accounting that the invariant functions check. a violation is written to the `viol` counters and never
/// asserted here, because under `fail_on_revert = false` a reverting handler would hide it.
///
/// actors hold real credits moved out of the CreditStrategy by prank in the fixture. coin trades go through the
/// real launch pool on the real PoolManager under the live skim hook, which pays its bounty into the core's
/// `receive()`. the anti sniper window skims up to 90 percent of a swap, so the fee model reads the live skim rate.
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
    uint8 internal constant A_LISTING_HOSTILE = 4;
    uint8 internal constant A_WARP = 5;
    uint8 internal constant A_ROLL = 6;
    uint8 internal constant A_COMPOSE = 7;
    uint8 internal constant A_BUY_STATEMENT = 8;
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
    uint8 internal constant A_SIDE_BUY = 21;
    uint256 internal constant N_ACTIONS = 22;

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
    uint256 internal constant V_RECEIVE = 24; // the core's receive() reverted, or a swap failed for an unexplained reason
    uint256 internal constant V_SUPPLY = 25; // coin supply differs from the ghost, or rose
    uint256 internal constant V_AUCTION = 26; // the exit token auction broke its price, slice or restart rules
    uint256 internal constant N_VIOL = 27;

    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;
    IPoolManager internal constant PM = IPoolManager(Mainnet.POOL_MANAGER);
    address internal constant DEAD = Mainnet.DEAD;
    address internal constant HOOK = Mainnet.SKIM_HOOK;
    bytes32 internal constant SKIM_SPLIT = keccak256("SkimSplit(bytes32,uint256,uint256,uint256,uint256)");
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    // core storage slots of windowStart (offset 17 in slot 10), windowPot and windowSpent.
    // from `forge inspect Core storage-layout`. the fixture proves them against public getters.
    uint256 internal constant SLOT_WINDOW_START = 10;
    uint256 internal constant WINDOW_START_SHIFT = 136;
    uint256 internal constant SLOT_WINDOW_POT = 11;
    uint256 internal constant SLOT_WINDOW_SPENT = 12;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    Core public core;
    IArtCoinsToken public coin;
    TestSwapRouter public router;
    PoolKey public launchKey;
    /// a hookless side pool of the coin in the real pool manager, a tax venue
    PoolKey public sideKey;
    bytes32 public poolId;
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
    /// the eth each controller held when the run began
    mapping(address => uint256) public ethBase;

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
    /// coin taxed to the burn address in side pool buys
    uint256 public sideTaxed;
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
    uint256 internal pendingTargetEta;

    // ghost totals for the summary
    uint256 public totalSpentEth;
    uint256 public biggestSpendBps;

    constructor(Wiring memory w) {
        core = w.core;
        coin = w.coin;
        router = w.router;
        launchKey = w.launchKey;
        sideKey = w.sideKey;
        poolId = w.poolId;
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
            "sideBuy"
        ];
        names = n;
        controllers.push(w.v1);
        controllers.push(address(w.fuzz));
        // a contract created at an address that already holds eth on the fork starts with that eth
        ethBase[w.v1] = w.v1.balance;
        ethBase[address(w.fuzz)] = address(w.fuzz).balance;
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

    /// the hostile target is queued for the allow list at the start of a run that begins inside the sniper
    /// window, and the handler executes it once the timelock has run
    function seedPendingTarget(uint256 eta) external {
        pendingTargetEta = eta;
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
    /// launch, falling linearly to the 10 percent baseline over the window
    function _skimBps() internal view returns (uint256 bps) {
        bps = IArtCoinsMevSkim(Mainnet.MEV_LINEAR_SKIM).currentSkimBps(poolId);
        if (bps < 10_000) bps = 10_000;
    }

    /// the legs of the skim on `volume` eth at `bps`, from the rules of the hook written out independently. an
    /// exact input swap skims volume * bps, an exact output swap grosses it up. 95 percent of the baseline goes to
    /// the core with the whole extra, the rest of the baseline to the creator
    function _expectSkim(uint256 volume, bool exactIn, uint256 bps)
        internal
        pure
        returns (uint256 bounty, uint256 protocol)
    {
        uint256 total = exactIn ? volume * bps / 100_000 : volume * bps / (100_000 - bps);
        uint256 base = exactIn ? volume * 10_000 / 100_000 : volume * 10_000 / (100_000 - bps);
        if (base > total) base = total;
        uint256 share = base * 9500 / 10_000;
        protocol = base - share;
        bounty = share + (total - base);
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

    modifier checked() {
        _;
        _coinCheck();
    }

    /*//////////////////////////////////////////////////////////////
                              POOL ACTIONS
    //////////////////////////////////////////////////////////////*/

    struct SwapPre {
        uint256 bal;
        uint256 pot;
        uint256 rate;
        uint256 bps;
        bool exactIn;
    }

    /// buys coin with eth through the launch pool. exact in or exact out. the skim of the live hook goes into the
    /// core's receive() and funds the pot. inside the sniper window that is most of the swap
    function buyCoin(uint256 aSeed, uint256 amtSeed, uint256 mode) external checked {
        uint8 a = A_BUY_COIN;
        address who = _actor(aSeed);
        uint256 eth = _logBound(amtSeed, 1e13, 25 ether);
        SwapPre memory p;
        p.exactIn = mode % 3 != 0;
        p.bps = _skimBps();
        // an exact out buy pays the gross up of the skim on top, which is large inside the window
        uint256 value = p.exactIn ? eth : eth * 2 * 100_000 / (100_000 - p.bps) + 1e12;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 spec = p.exactIn ? -int256(eth) : int256(_coinFor(eth * 8 / 10));
        p.bal = address(core).balance;
        p.pot = core.ethPot();
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

    /// buys coin out of the hookless side pool, which is a venue of the coin's buy tax. 15 percent of the coin goes
    /// to the burn address, which holds it: that is a transfer, not a burn, so the supply must not move. the side
    /// pool pays no skim, so the core's books must not move either
    function sideBuy(uint256 aSeed, uint256 amtSeed) external checked {
        uint8 a = A_SIDE_BUY;
        address who = _actor(aSeed);
        uint256 eth = _logBound(amtSeed, 1e13, 0.2 ether);
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        uint256 dead0 = coin.balanceOf(DEAD);
        uint256 coin0 = coin.balanceOf(who);
        uint256 supply0 = coin.totalSupply();
        vm.deal(who, who.balance + eth);
        _att(a);
        vm.prank(who);
        try router.swap{value: eth}(sideKey, true, -int256(eth), who) returns (BalanceDelta d) {
            _ok(a);
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 gross = uint256(uint128(d.amount1()));
            uint256 tax = gross * coin.taxBps() / 10_000;
            if (coin.balanceOf(who) - coin0 != gross - tax) {
                _flag(V_SUPPLY, "the side pool buyer did not get 85 percent");
            }
            if (coin.balanceOf(DEAD) - dead0 != tax) _flag(V_SUPPLY, "the buy tax did not go to the burn address");
            if (coin.totalSupply() != supply0) _flag(V_SUPPLY, "a taxed buy moved the coin supply");
            _eth(b0, 0, 0, "sideBuy");
            if (core.ethPot() != pot0) _flag(V_POT, "a hookless pool swap changed the pot");
            if (tax != 0) sideTaxed += tax;
        } catch (bytes memory why) {
            _failed(b0, pot0, rate0, "sideBuy");
            if (swapFails[_rootSelector(why)]++ == 0) swapFailSels.push(_rootSelector(why));
        }
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
        if (p.bps > 10_000) windowSwaps++;
        _eth(p.bal, 0, bounty, what);
        if (core.ethPot() != p.pot + bounty) _flag(V_POT, "swap skim not booked to the pot");
        if (volume != 0) {
            (uint256 eb, uint256 ep) = _expectSkim(volume, p.exactIn, p.bps);
            if (bounty != eb) _flag(V_POT, "skim bounty differs from the hook rules at the live rate");
            if (protocol != ep) _flag(V_POT, "skim creator leg differs from the hook rules at the live rate");
        }
        if (exactVolume != 0 && volume != exactVolume) _flag(V_POT, "skim volume is not the eth the swap spent");
        // the whole skim is at most 90 percent of the gross eth of the swap. an exact output swap grosses the
        // skim up on top of the eth the pool moved
        uint256 gross = p.exactIn ? volume : volume + bounty + protocol;
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
        uint256 sellerBal;
        uint256[] ceil;
        uint256[] score;
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
            // a hostile controller may answer differently each time it is asked, which moves the ceiling
            if (!overshoot && !dup && !_hostileNow()) _unexpected(a, why);
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
            // the keeper tip is booked as spend on top of the price, up to 2 percent of it
            if (core.ceilingOf(cand) >= p && p * 10_200 / 10_000 <= _budget()) {
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
    function buyStatement(uint256 sIdx, uint256 aSeed, uint256 overSeed, uint256 mode) external checked {
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
    function overprint() external checked {
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
    }

    /// the eth buyback: the core swaps a slice of the buyback pot for coin in the real pool and burns the coin on
    /// the token. the hook's skim of that swap comes back into the core's receive() as an inflow. the supply ghost
    /// falls by the coin the pool handed to the core, measured from the token's transfer events
    function buyback(uint256 aSeed) external checked {
        uint8 a = A_BUYBACK;
        address who = _actor(aSeed);
        BbPre memory p;
        p.pool = core.ethToBuyback();
        if (p.pool == 0 || (block.number < core.lastBuybackBlock() + 25 && aSeed % 5 != 0)) return _skip(a);
        p.slice = p.pool < 1 ether ? p.pool : 1 ether;
        p.tip0 = p.slice * 50 / 10_000;
        p.bal = address(core).balance;
        p.pot = core.ethPot();
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
            _failed(p.bal, p.pot, p.rate, "buyback");
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
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == Core.Buyback.selector) {
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
        if (p.bps > 10_000) windowSwaps++;
        if (bought == 0) _flag(V_BUYBACK, "buyback bought no coin");
        if (burned != bought) _flag(V_BUYBACK, "buyback did not burn exactly the coin it bought");
        if (spent == 0 || spent > budget) _flag(V_BUYBACK, "buyback spent more than the slice less the tip");
        if (evTip != tip) _flag(V_BUYBACK, "buyback tip event differs from what the caller received");
        if (tip != p.tip0 * spent / budget) _flag(V_BUYBACK, "buyback tip is not 0.5 percent of the slice, scaled");
        if (core.ethToBuyback() != p.pool - spent - tip) {
            _flag(V_BUYBACK, "buyback pot is not the pot less what was spent and tipped");
        }
        // eth leaves as the swap input plus the tip. the skim of the swap comes back as an inflow
        _eth(p.bal, spent + tip, bounty, "buyback");
        if (core.ethPot() != p.pot + bounty) _flag(V_POT, "buyback skim not booked to the pot");
        if (volume != spent) _flag(V_BUYBACK, "buyback skim volume is not the eth spent");
        (uint256 eb, uint256 ep) = _expectSkim(volume, true, p.bps);
        if (bounty != eb || protocol != ep) _flag(V_BUYBACK, "buyback skim differs from the hook rules");
        if (coin.balanceOf(DEAD) != p.dead) _flag(V_BUYBACK, "the exempt buyback take was taxed to the burn address");
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
    /// booked, the core books it only through skim. now and then the send is made from the hook's address, which
    /// the core books into the pot at once. receive() must accept every one of them
    function donate(uint256 aSeed, uint256 amtSeed) external checked {
        uint8 a = A_DONATE;
        address who = _actor(aSeed);
        uint256 amt = _logBound(amtSeed, 1, 5 ether);
        bool fromHook = amtSeed % 4 == 1;
        address sender = fromHook ? HOOK : who;
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        vm.deal(sender, sender.balance + amt);
        _att(a);
        receiveSends++;
        vm.prank(sender);
        (bool ok,) = address(core).call{value: amt}("");
        if (ok) {
            _ok(a);
            _eth(b0, 0, amt, "donate");
            if (core.ethPot() != pot0 + (fromHook ? amt : 0)) _flag(V_POT, "a donation was booked wrongly");
        } else {
            receiveFails++;
            _flag(V_RECEIVE, "a direct send to the core receive() reverted");
            _failed(b0, pot0, rate0, "donate");
        }
        if (phase2() && amtSeed % 3 == 0) _xt().mint(address(core), amt * 1000);
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

    /// queues a controller change through the owner timelock, and executes a queued one once it is ripe.
    function controllerSwap(uint256 which) external checked {
        uint8 a = A_CONTROLLER_SWAP;
        // a run that began inside the sniper window could not wait a week for the owner, so the hostile target
        // sits in the timelock queue and is allowed here once it is ripe
        if (pendingTargetEta != 0 && block.timestamp >= pendingTargetEta) {
            pendingTargetEta = 0;
            _att(a);
            vm.prank(owner);
            try core.execute(Core.Action.AddTarget, abi.encode(address(probe))) {
                _ok(a);
            } catch {}
            return;
        }
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
            uint256 paid = _xBal(who) - p.actorX;
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
        uint256 startPrice;
        uint256 startTime;
        uint256 priceNow;
        uint8 lane;
        bool ripe;
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
        p.lane = uint8(lane);
        p.ripe = lane == Lane.Exit || block.timestamp >= uint256(clock) + 72 hours;
        // an unripe eth lane statement is only tried now and then, to see the refusal
        if (!p.ripe && aSeed % 6 != 0) return _skip(a);
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
        uint256 received = _xBal(address(core)) - p.xbal;
        if (received < p.required) _flag(V_EXIT_SHORT, "exit returned less than rating * unitPerPoint");
        if (p.unit == 0) _flag(V_EXIT_SHORT, "exit with an unreadable unit per point");
        uint256 toBuyback = p.lane == uint8(Lane.Eth) ? received * 5000 / 10_000 : 0;
        if (core.xToBuyback() != p.xto + toBuyback) _flag(V_POT, "exit buyback share wrong");
        if (core.xPot() != p.xpot + received - toBuyback) _flag(V_POT, "exit pot share wrong");
        _x(p.xbal, 0, received, "exitStatement");
        _eth(p.b0, 0, 0, "exitStatement");
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
        g.status = 3;
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

    /// the auction price written out again: the start price halved once per whole half life (6 hours) elapsed, and
    /// the part of a half life left over taken off with a plain exponential
    function _modelPrice(uint256 startPrice, uint256 dt) internal pure returns (uint256 p) {
        uint256 hl = 6 hours;
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
            if (need > _coinFor(2 ether) || !_buyExact(who, need)) return _skip(a);
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
            if (logs[i].emitter == address(core) && logs[i].topics[0] == Core.ExitBuyback.selector) {
                (slice, coinIn) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        if (p.maxIn < p.coinIn) _flag(V_AUCTION, "a fill went through above the caller's maxCoinIn");
        // the slice is one full slice or what is left
        uint256 full = 20 * core.AVG_SCORE() * core.unitPerPoint();
        if (slice != (p.xto < full ? p.xto : full) || slice != p.slice) {
            _flag(V_AUCTION, "auction slice is not min(pot, 20 average credits of exit token)");
        }
        // the price: the quote read before, and the halving model written out again
        uint256 model = _modelPrice(p.startPrice, block.timestamp - p.startTime);
        uint256 dp = model > p.price ? model - p.price : p.price - model;
        if (dp > p.price / 1e9 + 2) _flag(V_AUCTION, "auction price is not the start price halved every 6 hours");
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
