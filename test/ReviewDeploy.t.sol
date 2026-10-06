// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {Fixture} from "./utils/Fixture.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Mainnet, Stack} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactory, IArtCoinsToken, IArtCoinsSkimHook, IArtCoinsMevSkim} from "../src/interfaces/ArtCoins.sol";
import {SystemDeployer, Deployed} from "../script/Deploy.s.sol";
import {LaunchConfig, ConfigReader} from "../script/LaunchConfig.sol";
import {Report} from "../script/Report.sol";

interface IFactoryAdmin {
    function setDeprecated(bool d) external;
}

/// @notice independent review of the deploy package (docs/REVIEW-deploy.md): the config mutation matrix, proofs of
/// the findings and a fuzz of the funded rule. forks mainnet at FORK_BLOCK
contract ReviewDeployTest is Test, SystemDeployer {
    string internal constant MUT_TOKEN = "test/data/ReviewMutatedToken.creation.hex";
    address internal deployer;
    address internal owner;
    address internal creator;
    LaunchConfig internal base;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        deployer = makeAddr("review.deployer");
        owner = makeAddr("review.owner");
        creator = makeAddr("review.creator");
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        IArtCoinsFactory(Mainnet.ARTCOINS_FACTORY).setAdmin(deployer, true);
        vm.deal(deployer, 2 ether);
        base = defaultConfig();
        base.owner = owner;
        base.creator = creator;
        base.name = "Review Coin";
        base.symbol = "REV";
        base.salt = keccak256("review deploy");
    }

    // ------------------------------------------------------------------ matrix harness

    /// @dev external so a revert of the whole deploy can be caught and classified
    function tryDeploy(LaunchConfig memory c) external returns (Deployed memory d) {
        vm.startPrank(deployer);
        d = deploySystem(deployer, c);
        vm.stopPrank();
    }

    function _failedNames() internal view returns (string memory list) {
        (list,) = _failed();
    }

    function _reason(bytes memory why) internal pure returns (string memory) {
        if (why.length < 4) return "empty revert";
        bytes4 sel = bytes4(why);
        bytes memory body = new bytes(why.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = why[i + 4];
        }
        if (sel == Report.ChecksFailed.selector) {
            return string.concat("postflight: ", abi.decode(body, (string)));
        }
        if (sel == SystemDeployer.AddressMismatch.selector) {
            return string.concat("AddressMismatch(", abi.decode(body, (string)), ")");
        }
        if (sel == SystemDeployer.ConfigUnset.selector) {
            return string.concat("ConfigUnset(", abi.decode(body, (string)), ")");
        }
        return string.concat("revert ", vm.toString(sel));
    }

    /// the four outcomes of one mutation. a slip is a launch that passed every check
    enum Class {
        Pre, // preflight fails, Deploy stops before anything is sent
        Revert, // preflight clean, the deploy reverts (factory, core, prediction): safe, nothing is broadcast
        Post, // preflight clean, the in script postflight reverts the deploy
        Slip // launches and every check passes. only the config hash tells it from the signed config
    }

    /// @dev runs preflight, then the deploy, on a snapshot. logs one matrix row and counts the class. the deploy is
    /// skipped when preflight fails, as `Deploy.run` does
    function _run(string memory label, LaunchConfig memory c) internal returns (Class k, string memory detail) {
        uint256 snap = vm.snapshotState();
        vm.stopPrank();
        string memory pre;
        try this.runPre(c) returns (string memory names) {
            pre = names;
        } catch {
            pre = "PREFLIGHT PANICS";
        }
        if (bytes(pre).length != 0) {
            (k, detail) = (Class.Pre, pre);
        } else {
            try this.tryDeploy(c) returns (Deployed memory) {
                (k, detail) = (Class.Slip, "DEPLOYED, every check passed");
            } catch (bytes memory why) {
                detail = _reason(why);
                k = bytes4(why) == Report.ChecksFailed.selector ? Class.Post : Class.Revert;
            }
        }
        console.log(string.concat("MUT ", label, " || ", _className(k), " || ", detail));
        vm.stopPrank();
        vm.revertToState(snap);
    }

    function _className(Class k) internal pure returns (string memory) {
        if (k == Class.Pre) return "CAUGHT by preflight";
        if (k == Class.Revert) return "SAFE REVERT at deploy";
        if (k == Class.Post) return "CAUGHT by postflight";
        return "SLIP, hash only";
    }

    function runPre(LaunchConfig memory c) external returns (string memory) {
        preflight(c, deployer);
        return _failedNames();
    }

    // ------------------------------------------------------------------ the mutations

    uint256 internal constant MUTATIONS = 57;

    function _mut(uint256 i) internal returns (string memory l, LaunchConfig memory c) {
        c = base;
        address other = Mainnet.PERMIT2; // a contract that is not part of the stack
        if (i == 0) {
            l = "baseline";
        } else if (i == 1) {
            (l, c.stack.hook) = ("hook = a contract that is not the hook", other);
        } else if (i == 2) {
            (l, c.stack.hook) = ("hook = an EOA", makeAddr("review.eoa.hook.91c2"));
        } else if (i == 3) {
            (l, c.stack.locker) = ("locker = the escrow", c.stack.escrow);
        } else if (i == 4) {
            (l, c.stack.poolManager) = ("poolManager = a contract that is not v4", other);
        } else if (i == 5) {
            (l, c.stack.escrow) = ("escrow = a contract that is not the escrow", other);
        } else if (i == 6) {
            (l, c.stack.factory) = ("factory = a contract that is not the factory", other);
        } else if (i == 7) {
            (l, c.stack.tickSpacing) = ("tickSpacing 60", 60);
        } else if (i == 8) {
            (l, c.stack.tickSpacing) = ("tickSpacing 200 -> 400 (positions still aligned)", 400);
        } else if (i == 9) {
            (l, c.stack.poolFee) = ("poolFee 3000 instead of the dynamic flag", 3000);
        } else if (i == 10) {
            (l, c.owner, c.creator) = ("owner and creator swapped", creator, owner);
        } else if (i == 11) {
            (l, c.taxBps) = ("taxBps 2100 above taxBpsMax 2000", 2100);
        } else if (i == 12) {
            (l, c.taxBps, c.taxBpsMax) = ("taxBps = taxBpsMax = 9999", 9999, 9999);
        } else if (i == 13) {
            (l, c.taxBurn) = ("taxBurn = creator instead of 0xdEaD", creator);
        } else if (i == 14) {
            (l, c.bountyBps) = ("bountyBps 9999", 9999);
        } else if (i == 15) {
            (l, c.bountyBps) = ("bountyBps 10000", 10_000);
        } else if (i == 16) {
            (l, c.startTick) = ("startTick +1 spacing (-174800)", -174_800);
        } else if (i == 17) {
            (l, c.startTick) = ("startTick -1 spacing (-175200)", -175_200);
        } else if (i == 18) {
            (l, c.startTick) = ("startTick sign flipped (+175000)", 175_000);
        } else if (i == 19) {
            (l, c.startTick) = ("startTick not a multiple of spacing (-175001)", -175_001);
        } else if (i == 20) {
            (l, c.positionLower) = ("positionLower -175001", -175_001);
        } else if (i == 21) {
            (l, c.positionUpper) = ("positionUpper 887201", 887_201);
        } else if (i == 22) {
            (l, c.positionUpper) = ("positionUpper 887400 beyond max tick", 887_400);
        } else if (i == 23) {
            (l, c.positionUpper) = ("positionUpper 600000 aligned but narrower", 600_000);
        } else if (i == 24) {
            (l, c.positionLower) = ("positionLower -170000, start tick below range", -170_000);
        } else if (i == 25) {
            (l, c.salt) = ("salt zero", bytes32(0));
        } else if (i == 26) {
            (l, c.rateStart) = ("rateStart 1e10 below min", 1e10);
        } else if (i == 27) {
            (l, c.rateStart) = ("rateStart 1e16 above max", 1e16);
        } else if (i == 28) {
            (l, c.rateStart) = ("rateStart 0", 0);
        } else if (i == 29) {
            (l, c.rateStart) = ("rateStart 4e15 (a typo, 1000x too high but 4x above max)", 4e15);
        } else if (i == 30) {
            (l, c.supply) = ("supply 1e27 + 1", 1_000_000_000e18 + 1);
        } else if (i == 31) {
            (l, c.supply) = ("supply 1e28", 10_000_000_000e18);
        } else if (i == 32) {
            (l, c.tokenCodeFile) = ("token creation code, one byte changed", MUT_TOKEN);
        } else if (i == 33) {
            (l, c.name) = ("name empty", "");
        } else if (i == 34) {
            (l, c.sniperSeconds) = ("sniperSeconds 0", 0);
        } else if (i == 35) {
            (l, c.sniperStartBps) = ("sniperStartBps 5000 below sniperEndBps 10000", 5000);
        } else if (i == 36) {
            (l, c.maxReferralBps) = ("maxReferralBps 1000", 1000);
        } else if (i == 37) {
            (l, c.lpFee) = ("lpFee 5000", 5000);
        } else if (i == 38) {
            (l, c.baselineSkimBps) = ("baselineSkimBps 60000", 60_000);
        } else if (i == 39) {
            (l, c.mevModule) = ("mevModule = a contract that is not the module", other);
        } else if (i == 40) {
            (l, c.factoryOwner) = ("factoryOwner mismatch", creator);
        } else if (i == 41) {
            (l, c.sniperSeconds) = ("sniperSeconds 86400", 86_400);
        } else if (i == 42) {
            (l, c.bountyBps) = ("bountyBps 0 (creator gets all of baseline)", 0);
        } else if (i == 43) {
            (l, c.supply) = ("supply 0", 0);
        } else if (i == 44) {
            (l, c.stack.tickSpacing) = ("tickSpacing 0", 0);
        } else if (i == 45) {
            (l, c.taxBurn) = ("taxBurn zero address", address(0));
        } else if (i == 46) {
            (l, c.sniperStartBps) = ("sniperStartBps 20000 (valid, wrong)", 20_000);
        } else if (i == 47) {
            (l, c.sniperSeconds) = ("sniperSeconds 300 (valid, wrong)", 300);
        } else if (i == 48) {
            (l, c.sniperStartBps) = ("sniperStartBps 90001 above the module limit", 90_001);
        } else if (i == 49) {
            (l, c.sniperEndBps) = ("sniperEndBps 5000 not the baseline skim", 5000);
        } else if (i == 50) {
            (l, c.taxBpsMax) = ("taxBpsMax 2500", 2500);
        } else if (i == 51) {
            (l, c.owner) = ("owner = the deployer", deployer);
        } else if (i == 52) {
            (l, c.owner) = ("owner = creator (one party, two roles)", creator);
        } else if (i == 53) {
            l = "startTick and positionLower both -170000 (another start price)";
            (c.startTick, c.positionLower) = (-170_000, -170_000);
        } else if (i == 54) {
            (l, c.rateStart) = ("rateStart 1e12 (in bounds, not the signed value)", 1e12);
        } else if (i == 55) {
            (l, c.owner) = ("owner = the hook", c.stack.hook);
        } else if (i == 56) {
            l = "bountyBps 9999 with the override flag on";
            (c.bountyBps, c.allowBounty) = (9999, true);
        }
    }

    /// @dev mutations that only the config hash can tell from the signed config: another value that is a plausible
    /// choice, or one party in both roles. every other mutation is stopped by a rule, a safe revert or the postflight
    function _hashOnly(uint256 i) internal pure returns (bool) {
        return i == 10 || i == 51 || i == 52 || i == 53 || i == 54 || i == 56;
    }

    /// the reviewer's mutation matrix on the fixed package. every mutation is caught by a preflight rule, reverts safely
    /// at deploy or is caught by the postflight, except the ones only the config hash can tell (`_hashOnly`). for those
    /// the hash differs from the signed one, so `Deploy` refuses them
    function test_FIXED_matrix() public {
        bytes32 signed = configHash(base);
        uint256 hashOnly;
        uint256[4] memory counts;
        for (uint256 i; i < MUTATIONS; ++i) {
            (string memory l, LaunchConfig memory c) = _mut(i);
            (Class k, string memory detail) = _run(l, c);
            if (i == 0) {
                assertTrue(k == Class.Slip, "the baseline launches clean");
                continue;
            }
            ++counts[uint256(k)];
            assertTrue(keccak256(bytes(detail)) != keccak256("PREFLIGHT PANICS"), l);
            assertTrue(configHash(c) != signed, string.concat("the hash must change: ", l));
            if (_hashOnly(i)) {
                assertTrue(k == Class.Slip, string.concat("expected a hash only mutation: ", l));
                ++hashOnly;
            } else {
                assertTrue(k != Class.Slip, string.concat("SLIPPED through every check: ", l));
            }
        }
        console.log("MATRIX mutations", MUTATIONS - 1);
        console.log("MATRIX caught by preflight", counts[uint256(Class.Pre)]);
        console.log("MATRIX safe revert at deploy", counts[uint256(Class.Revert)]);
        console.log("MATRIX caught by postflight", counts[uint256(Class.Post)]);
        console.log("MATRIX hash only", hashOnly);
        assertEq(hashOnly, 6);
        assertEq(
            counts[uint256(Class.Pre)] + counts[uint256(Class.Revert)] + counts[uint256(Class.Post)],
            MUTATIONS - 1 - hashOnly
        );
    }

    // ------------------------------------------------------------------ partial failure states

    struct Steps {
        address controller;
        address core;
        address coin;
        PoolKey key;
    }

    /// @dev runs the first `n` of the five deploy transactions by hand, as the deployer
    function _steps(LaunchConfig memory c, uint256 n) internal returns (Steps memory st) {
        uint64 nonce = vm.getNonce(deployer);
        address coreAt = vm.computeCreateAddress(deployer, nonce + 1);
        address coinAt = predictCoin(c, deployer, coreAt);
        vm.startPrank(deployer);
        st.controller = address(new ControllerV1(coreAt));
        if (n >= 2) st.core = address(new Core(c.owner, coinAt, st.controller, c.stack, c.rateStart, c.econ));
        IArtCoinsFactory f = IArtCoinsFactory(c.stack.factory);
        if (n >= 3) {
            st.coin = f.deployTokenWithProtocolBpsAndTax{value: f.deployFee()}(
                buildConfig(c, deployer, coreAt), 0, buildTaxConfig(c, coreAt)
            );
            st.key = poolKeyOf(st.coin, c.stack);
        }
        if (n >= 4) IArtCoinsSkimHook(c.stack.hook).lockPoolExtension(st.key);
        if (n >= 5) IArtCoinsToken(st.coin).updateAdmin(c.owner);
        vm.stopPrank();
    }

    function test_partialStates() public {
        uint256 snap = vm.snapshotState();
        // after the core, before the launch: nothing at the coin address, the core holds nothing and is inert
        Steps memory st = _steps(base, 2);
        address coinAt = Core(payable(st.core)).COIN();
        console.log("after tx2: coin code", coinAt.code.length, "core balance", st.core.balance);
        // a stranger cannot launch to the predicted coin while the factory is deprecated
        IArtCoinsFactory f = IArtCoinsFactory(base.stack.factory);
        uint256 fee = f.deployFee();
        vm.deal(makeAddr("watcher"), 1 ether);
        vm.prank(makeAddr("watcher"));
        vm.expectRevert();
        f.deployTokenWithProtocolBpsAndTax{value: fee}(
            buildConfig(base, deployer, st.core), 0, buildTaxConfig(base, st.core)
        );
        postflight(base, st.core);
        console.log("postflight after tx2:", _failedNames());
        vm.revertToState(snap);

        // after the launch, before the lock: the deployer is still the token admin and the slot is open
        st = _steps(base, 3);
        postflight(base, st.core);
        console.log("postflight after tx3:", _failedNames());
        vm.prank(makeAddr("watcher"));
        vm.expectRevert();
        IArtCoinsSkimHook(base.stack.hook).lockPoolExtension(st.key);
        vm.prank(makeAddr("watcher"));
        vm.expectRevert();
        IArtCoinsToken(st.coin).updateAdmin(makeAddr("watcher"));
        vm.revertToState(snap);

        // after the lock, before the handover
        st = _steps(base, 4);
        postflight(base, st.core);
        console.log("postflight after tx4:", _failedNames());
        vm.revertToState(snap);
    }

    /// @dev deploys `c` on a snapshot, skips the sniper window, buys 1 eth. returns the coin bought and whether the
    /// postflight and preflight were clean
    function _buyOneEth(LaunchConfig memory c) internal returns (uint256 coinOut, string memory post) {
        uint256 snap = vm.snapshotState();
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, c);
        vm.stopPrank();
        postflight(c, d.core);
        post = _failedNames();
        vm.warp(block.timestamp + c.sniperSeconds + 1);
        TestSwapRouter r = new TestSwapRouter();
        address buyer = makeAddr("review.buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        r.swap{value: 1 ether}(d.launchKey, true, -1 ether, buyer);
        coinOut = IArtCoinsToken(d.coin).balanceOf(buyer);
        vm.revertToState(snap);
    }

    /// D-2: a shifted, narrower or off edge position no longer passes preflight
    function test_FIXED_wrongPositionIsStoppedByPreflight() public {
        LaunchConfig memory c = base;
        c.positionLower = -170_000;
        this.runPre(c);
        assertEq(_failedNames(), "rule: position lower equals the start tick");
        c = base;
        c.positionUpper = 600_000;
        this.runPre(c);
        assertEq(_failedNames(), "rule: position upper is the highest usable tick");
        c = base;
        c.startTick = -175_200;
        this.runPre(c);
        assertEq(_failedNames(), "rule: position lower equals the start tick");
        // the highest multiple of the spacing at or below the max tick, for another spacing
        c = base;
        c.stack.tickSpacing = 60;
        c.startTick = c.positionLower = -174_960;
        c.positionUpper = 887_220;
        this.runPre(c);
        assertFalse(vm.contains(_failedNames(), "rule:"), "the tick rules follow the spacing of the config");
    }

    /// D-2: the postflight reads the position back from the position manager, so a launch whose position is not the
    /// config's fails even when every config rule was bypassed
    function test_FIXED_postflightReadsThePositionBack() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        postflight(base, d.core);
        assertEq(_failedNames(), "");
        LaunchConfig memory c = base;
        c.startTick = c.positionLower = -170_000;
        postflight(c, d.core);
        assertEq(_failedNames(), "position: ticks equal the config, pool: start tick");
        c = base;
        c.positionUpper = 600_000;
        postflight(c, d.core);
        assertEq(_failedNames(), "position: ticks equal the config");
        // after the first trade the start tick itself is gone, the position rows still hold
        vm.warp(block.timestamp + base.sniperSeconds + 1);
        TestSwapRouter r = new TestSwapRouter();
        address buyer = makeAddr("review.buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        r.swap{value: 1 ether}(d.launchKey, true, -1 ether, buyer);
        postflight(base, d.core);
        assertEq(_failedNames(), "");
    }

    /// D-2: the sniper parameters are read back through the mev module. inside the window one read pins start, end
    /// and duration together, after it only the end value is readable and the output says so
    function test_FIXED_postflightReadsTheSniperParamsBack() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        postflight(base, d.core);
        assertEq(_failedNames(), "");
        assertEq(IArtCoinsMevSkim(base.mevModule).currentSkimBps(d.poolId), 90_000, "readable at the launch block");
        vm.warp(block.timestamp + 900);
        postflight(base, d.core);
        assertEq(_failedNames(), "");
        LaunchConfig memory c = base;
        c.sniperStartBps = 80_000;
        postflight(c, d.core);
        assertEq(_failedNames(), "mev: skim now matches start, end and duration");
        c = base;
        c.sniperSeconds = 3000;
        postflight(c, d.core);
        assertEq(_failedNames(), "mev: skim now matches start, end and duration");
        vm.warp(block.timestamp + 901);
        postflight(base, d.core);
        assertEq(_failedNames(), "", "window over, the end value");
        c = base;
        c.sniperEndBps = 5000;
        postflight(c, d.core);
        assertEq(_failedNames(), "mev: skim now equals the end bps");
    }

    /// D-2: postflight reads back every launch input it can. one deployed system, each field of the config changed
    function test_FIXED_postflightFailsOnEveryReadableMismatch() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        string[10] memory names =
            ["owner", "creator", "name", "symbol", "bounty", "referral", "lpFee", "baseline", "taxBps", "taxBurn"];
        for (uint256 i; i < names.length; ++i) {
            LaunchConfig memory c = base;
            if (i == 0) c.owner = creator;
            else if (i == 1) c.creator = owner;
            else if (i == 2) c.name = "Other";
            else if (i == 3) c.symbol = "OTH";
            else if (i == 4) c.bountyBps = 9000;
            else if (i == 5) c.maxReferralBps = 100;
            else if (i == 6) c.lpFee = 100;
            else if (i == 7) c.baselineSkimBps = 20_000;
            else if (i == 8) c.taxBps = 1000;
            else c.taxBurn = creator;
            postflight(c, d.core);
            assertTrue(bytes(_failedNames()).length != 0, names[i]);
        }
    }

    /// sign off row: at the launch block the whole 90 points of a buy minus the creator 0.5 reach the core
    function test_signoff_sniperExtraGoesToTheCore() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        TestSwapRouter r = new TestSwapRouter();
        address buyer = makeAddr("review.buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        r.swap{value: 1 ether}(d.launchKey, true, -1 ether, buyer);
        console.log("core pot after a 1 eth buy in the launch block", Core(payable(d.core)).ethPot());
        assertEq(Core(payable(d.core)).ethPot(), 0.895 ether);
    }

    function _hookView(address hook, string memory sig) internal view returns (address a) {
        (bool ok, bytes memory out) = hook.staticcall(abi.encodeWithSignature(sig));
        require(ok && out.length == 32, sig);
        a = abi.decode(out, (address));
    }

    /// D-3: the pool manager, the factory and the escrow are compared with what the hook reports, the factory and the
    /// position manager with what the locker reports
    function test_FIXED_stackIsCrossCheckedAgainstTheHook() public {
        address hook = base.stack.hook;
        assertEq(_hookView(hook, "feeEscrow()"), base.stack.escrow);
        assertEq(_hookView(hook, "poolManager()"), base.stack.poolManager);
        assertEq(_hookView(hook, "factory()"), base.stack.factory);
        assertEq(_hookView(base.stack.locker, "factory()"), base.stack.factory);
        this.runPre(base);
        assertEq(_failedNames(), "");
        LaunchConfig memory c = base;
        c.stack.escrow = Mainnet.PERMIT2;
        this.runPre(c);
        assertEq(_failedNames(), "hook reports fee escrow");
        c = base;
        c.stack.poolManager = Mainnet.PERMIT2;
        this.runPre(c);
        assertEq(_failedNames(), "hook reports pool manager");
        c = base;
        c.stack.locker = makeAddr("other locker");
        vm.etch(c.stack.locker, hex"00");
        this.runPre(c);
        assertEq(
            _failedNames(), "factory: locker enabled for hook, locker reports factory, locker reports position manager"
        );
        c = base;
        c.mevModule = Mainnet.PERMIT2;
        this.runPre(c);
        assertEq(_failedNames(), "factory: mev module enabled");
    }

    /// D-4: the constructor refuses a stack member without code, the coin is exempt (it does not exist yet)
    function test_FIXED_coreRejectsAStackWithoutCode() public {
        Stack memory st = base.stack;
        st.hook = makeAddr("hook");
        vm.expectRevert(abi.encodeWithSelector(Core.NoCode.selector, st.hook));
        new Core(owner, makeAddr("coin"), makeAddr("ctl"), st, 4e12, Mainnet.defaultEcon());
        st = base.stack;
        st.escrow = makeAddr("escrow");
        vm.expectRevert(abi.encodeWithSelector(Core.NoCode.selector, st.escrow));
        new Core(owner, makeAddr("coin"), makeAddr("ctl"), st, 4e12, Mainnet.defaultEcon());
        new Core(owner, makeAddr("coin"), makeAddr("ctl"), base.stack, 4e12, Mainnet.defaultEcon());
    }

    function parse(string memory j) external view returns (LaunchConfig memory) {
        return parseConfig(j);
    }

    function load(string memory file) external view returns (LaunchConfig memory) {
        return loadConfig(file);
    }

    /// D-9: a json number that does not fit its field is rejected, never cut
    function test_FIXED_jsonNumbersAreRejected() public {
        vm.expectRevert(abi.encodeWithSelector(ConfigReader.ConfigOutOfRange.selector, ".stack.tickSpacing"));
        this.load("test/data/ReviewTruncated.json");
        string memory j = vm.readFile(DEFAULT_CONFIG_FILE);
        assertEq(this.parse(j).bountyBps, 9500, "the untouched file parses");
        string[8] memory from = [
            '"bountyBps": 9500',
            '"taxBps": 1500',
            '"taxBpsMax": 2000',
            '"baselineSkimBps": 10000',
            '"sniperSeconds": 1800',
            '"startTick": -175000',
            '"positionUpper": 887200',
            '"poolFee": 8388608'
        ];
        string[8] memory to = [
            '"bountyBps": 65536',
            '"taxBps": 65536',
            '"taxBpsMax": 65536',
            '"baselineSkimBps": 16777216',
            '"sniperSeconds": 4294967296',
            '"startTick": -8388609',
            '"positionUpper": 8388608',
            '"poolFee": 16777216'
        ];
        string[8] memory keys = [
            ".launch.bountyBps",
            ".launch.taxBps",
            ".launch.taxBpsMax",
            ".launch.baselineSkimBps",
            ".launch.sniperSeconds",
            ".launch.startTick",
            ".launch.positionUpper",
            ".stack.poolFee"
        ];
        for (uint256 i; i < from.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ConfigReader.ConfigOutOfRange.selector, keys[i]));
            this.parse(vm.replace(j, from[i], to[i]));
        }
        // the largest value that fits is accepted
        assertEq(this.parse(vm.replace(j, from[0], '"bountyBps": 65535')).bountyBps, 65_535);
        assertEq(this.parse(vm.replace(j, from[5], '"startTick": -8388608')).startTick, -8_388_608);
        // the overrides are optional and default to false
        LaunchConfig memory c = this.parse(vm.replace(j, '"overrides"', '"unused"'));
        assertFalse(c.allowBounty || c.allowTaxBurn || c.allowOpenFactory);
        c = this.parse(vm.replace(j, '"bounty": false', '"bounty": true'));
        assertTrue(c.allowBounty);
    }

    function requireHash(LaunchConfig memory c, bytes32 h) external view {
        _requireConfigHash(c, h);
    }

    function _hashRow() internal view returns (string memory) {
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].name)) == keccak256("signoff: CONFIG_HASH")) return rows[i].detail;
        }
        revert("no hash row");
    }

    /// D-2: the one value the operator signs. preflight and postflight print the same hash, Deploy needs it and every
    /// change of the config changes it
    function test_FIXED_configHashIsTheSignOffValue() public {
        bytes32 h = configHash(base);
        this.runPre(base);
        assertEq(_hashRow(), vm.toString(h), "preflight prints it");
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        postflight(base, d.core);
        assertEq(_hashRow(), vm.toString(h), "postflight prints the same value");
        this.requireHash(base, h);
        vm.expectRevert(abi.encodeWithSelector(SystemDeployer.ConfigHashMismatch.selector, bytes32(0), h));
        this.requireHash(base, bytes32(0));
        LaunchConfig memory c = base;
        c.rateStart = base.rateStart + 1;
        vm.expectRevert(abi.encodeWithSelector(SystemDeployer.ConfigHashMismatch.selector, h, configHash(c)));
        this.requireHash(c, h);
        // the hash does not depend on the machine: same content from a file and from the struct
        LaunchConfig memory f = loadConfig(DEFAULT_CONFIG_FILE);
        assertEq(configHash(f), configHash(defaultConfig()));
        // a changed token creation code changes it too
        c = base;
        c.tokenCodeFile = MUT_TOKEN;
        assertTrue(configHash(c) != h);
    }

    /// D-5: an open factory fails preflight unless the config says so
    function test_FIXED_openFactoryFailsPreflight() public {
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        IFactoryAdmin(Mainnet.ARTCOINS_FACTORY).setDeprecated(false);
        this.runPre(base);
        assertEq(_failedNames(), "factory: deprecated, only the owner and admins can launch");
        LaunchConfig memory c = base;
        c.allowOpenFactory = true;
        this.runPre(c);
        assertEq(_failedNames(), "");
    }

    /// DEPLOY.md says the token admin can only lower the tax and the referral cap. it can raise both
    function test_signoff_adminCanRaiseTaxAndReferralCap() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        IArtCoinsToken coin = IArtCoinsToken(d.coin);
        assertEq(coin.admin(), owner);
        vm.startPrank(owner);
        coin.setTaxBps(2000);
        assertEq(coin.taxBps(), 2000, "tax raised from 1500 to the 2000 cap");
        IArtCoinsSkimHook(base.stack.hook).setMaxReferralBpsOfVolume(d.launchKey, 1000);
        (,, uint24 maxRef,,,,,) = IArtCoinsSkimHook(base.stack.hook).skimConfig(d.poolId);
        vm.stopPrank();
        assertEq(maxRef, 1000, "referral cap raised from 0 to 1000");
    }

    /// the runs of the matrix that change chain state instead of the config
    function test_FIXED_matrixState() public {
        Class k;
        string memory out;
        // factory not deprecated: anyone may launch to the predicted coin
        uint256 snap = vm.snapshotState();
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        IFactoryAdmin(Mainnet.ARTCOINS_FACTORY).setDeprecated(false);
        (k, out) = _run("factory not deprecated (open)", base);
        assertTrue(k == Class.Pre, out);
        assertEq(out, "factory: deprecated, only the owner and admins can launch");
        // the config override opens exactly that rule
        LaunchConfig memory open_ = base;
        open_.allowOpenFactory = true;
        this.runPre(open_);
        assertEq(_failedNames(), "", "the override opens the rule");
        vm.revertToState(snap);

        // deployer not enabled by the factory owner
        snap = vm.snapshotState();
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        IArtCoinsFactory(Mainnet.ARTCOINS_FACTORY).setAdmin(deployer, false);
        (k, out) = _run("deployer not enabled", base);
        assertTrue(k == Class.Pre, out);
        vm.revertToState(snap);

        // balance below the fee, and between fee and fee plus gas
        snap = vm.snapshotState();
        vm.deal(deployer, 0.05 ether);
        (k, out) = _run("deployer balance 0.05 eth (below the 0.069 fee)", base);
        assertTrue(k == Class.Pre, out);
        vm.deal(deployer, 0.07 ether);
        vm.fee(1 gwei);
        (k, out) = _run("deployer balance 0.07 eth (fee but no gas)", base);
        assertTrue(k == Class.Pre, out);
        vm.revertToState(snap);

        // salt reuse: deploy once, deploy again with the same config and salt. benign: the coin address includes the
        // core address, so the second launch is a new coin
        vm.startPrank(deployer);
        Deployed memory d1 = deploySystem(deployer, base);
        vm.stopPrank();
        (k, out) = _run("salt reuse after a first launch", base);
        assertTrue(k == Class.Slip, out);
        console.log("first coin", d1.coin);
    }
}

/// @notice the funded rule and the climb clamp, fuzzed on standalone cores with any rateStart in bounds, plus the
/// sign off table rows that need a live pool to check
contract ReviewFundedTest is Fixture {
    uint256 internal constant AVG = 4_330_000;
    uint256 internal cursor;

    function _newCore(uint256 rate) internal returns (Core c) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        ControllerV1 ctl2 = new ControllerV1(predicted);
        c = new Core(owner, address(coin), address(ctl2), Mainnet.defaultStack(), rate, Mainnet.defaultEcon());
        assertEq(address(c), predicted);
    }

    function _fees(Core c, uint256 amt) internal {
        vm.deal(Mainnet.SKIM_HOOK, amt);
        vm.prank(Mainnet.SKIM_HOOK);
        (bool ok,) = address(c).call{value: amt}("");
        assertTrue(ok);
    }

    function _check(Core c) internal view {
        uint256 pot = c.ethPot();
        uint256 stored = c.rateAtCheckpoint();
        // the flag is exactly the definition: the hourly cap affords one average credit at the stored rate
        assertEq(c.funded(), pot * 2000 >= AVG * stored, "funded flag equals its definition");
        uint256 r = c.ethRate();
        if (c.funded()) {
            assertLe(AVG * r, pot * 2000, "funded: the hourly cap affords an average credit at the live rate");
        }
        // the rate never climbs while the cap cannot afford an average credit
        if (pot * 2000 < AVG * stored) assertEq(r, stored, "no climb while unaffordable");
    }

    /// forge-config: default.fuzz.runs = 400
    function testFuzz_fundedRuleAndClamp(uint256 rateSeed, uint256[10] memory ops) public {
        uint256 rate = bound(rateSeed, 1e11, 1e15);
        Core c = _newCore(rate);
        address who = makeAddr("fuzz.seller");
        for (uint256 i; i < ops.length; ++i) {
            uint256 op = ops[i] % 4;
            uint256 arg = ops[i] >> 8;
            if (op == 0) {
                _fees(c, bound(arg, 1e9, 20 ether));
            } else if (op == 1) {
                bool was = c.funded();
                uint256 r0 = c.ethRate();
                uint256 pot = c.ethPot();
                vm.warp(block.timestamp + bound(arg, 1, 400 hours));
                uint256 r1 = c.ethRate();
                if (!was) assertEq(r1, r0, "unfunded rate moved");
                else assertGe(r1, r0, "funded rate fell without a fill");
                uint256 cap = pot * 2000 / AVG;
                assertLe(r1, r0 > cap ? r0 : cap, "climbed above the clamp");
            } else if (op == 2) {
                uint256 id = CreditIds.at(cursor++);
                vm.prank(Mainnet.CREDIT_STRATEGY);
                CREDITS.transferFrom(Mainnet.CREDIT_STRATEGY, who, id);
                vm.startPrank(who);
                CREDITS.setApprovalForAll(address(c), true);
                uint256[] memory ids = new uint256[](1);
                ids[0] = id;
                try c.sellForEth(ids) {}
                catch (bytes memory why) {
                    bytes4 sel = bytes4(why);
                    assertTrue(sel == Core.HourlyCap.selector || sel == Core.PotTooSmall.selector, "unexpected revert");
                }
                vm.stopPrank();
            } else {
                c.skim();
            }
            _check(c);
        }
    }

    /// the bounds of rateStart, at and beside both edges
    function test_rateStartBounds() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        Stack memory st = Mainnet.defaultStack();
        vm.expectRevert(Core.BadRate.selector);
        new Core(owner, address(coin), predicted, st, 1e11 - 1, Mainnet.defaultEcon());
        vm.expectRevert(Core.BadRate.selector);
        new Core(owner, address(coin), predicted, st, 1e15 + 1, Mainnet.defaultEcon());
        Core lo = new Core(owner, address(coin), predicted, st, 1e11, Mainnet.defaultEcon());
        Core hi = new Core(owner, address(coin), address(1), st, 1e15, Mainnet.defaultEcon());
        assertEq(lo.ethRate(), 1e11);
        assertEq(hi.ethRate(), 1e15);
        // funded thresholds: five average credits at the rate
        _fees(lo, 2.165e14 - 1);
        assertFalse(lo.funded());
        _fees(lo, 1);
        assertTrue(lo.funded());
        _fees(hi, 2.165e18 - 1);
        assertFalse(hi.funded());
        _fees(hi, 1);
        assertTrue(hi.funded());
    }
}
