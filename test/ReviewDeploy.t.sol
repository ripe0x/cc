// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {console} from "forge-std/Test.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ReviewHarness} from "./utils/ReviewHarness.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Mainnet, Stack, Settings} from "../src/interfaces/Interfaces.sol";
import {IAuctionFactory, IAuctionHouse} from "../src/interfaces/AuctionHouse.sol";
import {IArtCoinsFactoryV2, IArtCoinsHookV2, IArtCoinsMevSkimV2, IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {SystemDeployer, Deployed} from "../script/SystemDeployer.sol";
import {LaunchConfig, ConfigReader} from "../script/LaunchConfig.sol";
import {Report} from "../script/Report.sol";

/// @notice independent review of the deploy package (docs/REVIEW-deploy.md), ported to the v2 stack: the state
/// mutations that need their own assertions (deployer swap, library, house fee), proofs of the readbacks and a fuzz of the
/// funded rule. the mutation matrix is in test/ReviewMatrix.t.sol. forks mainnet at FORK_BLOCK
contract ReviewDeployTest is ReviewHarness {
    /// a deployer swap: the signer is another address than DEPLOYER, or than the factory owner: the script stops at once
    function test_deployerSwapRevertsSafely() public {
        address other = makeAddr("review.other.deployer");
        vm.deal(other, 5 ether);
        this.requireDeployerExt(deployer, deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, deployer, other));
        this.requireDeployerExt(deployer, other);
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, address(0), deployer));
        this.requireDeployerExt(address(0), deployer);
        // a signer that is not the factory owner is refused by the deploy itself, and by the preflight
        LaunchConfig memory c = base;
        c.owner = other;
        vm.expectRevert(abi.encodeWithSelector(NotFactoryOwner.selector, deployer, other));
        this.tryDeploy(c, other);
        this.stopPrankExt();
        assertEq(this.runPre(base, other), "factory: owner is the deployer, factory: deployTokenAsOwner accepts the config (simulated)");
        console.log("MUT deployer swap (another signer than the factory owner) || SAFE REVERT at deploy || NotFactoryOwner");
        // the coin address depends on the sender, so the swap would have launched somewhere else
        assertTrue(predictCoin(base, deployer, _routerAt()) != predictCoin(base, other, _routerAt()));
    }

    /// the live default fee of the auction factory is zero and the preflight row says so. a non zero fee is a warning in
    /// preflight, never a failure there, and the in script postflight stops the deploy on the house that reports it
    function test_houseFeeWarningAndGate() public {
        address af = base.stack.auctionFactory;
        assertEq(IAuctionFactory(af).defaultProtocolFeeBps(), 0, "the live default fee");
        this.runPre(base, deployer);
        (bool found, bool ok, string memory detail) = _row("warn: auction factory default fee is zero");
        assertTrue(found && ok, "the live fee row is clean");
        (,, detail) = _row("auction factory: default fee readable");
        assertEq(detail, "0");
        _patchFactoryFee(af, 250);
        assertEq(this.runPre(base, deployer), "", "a warning never fails the preflight");
        (found, ok, detail) = _row("warn: auction factory default fee is zero");
        assertTrue(found && !ok, "the warning row fires");
        (,, detail) = _row("auction factory: default fee readable");
        assertEq(detail, "250");
        vm.expectRevert(abi.encodeWithSelector(Report.ChecksFailed.selector, "house: protocol fee is zero"));
        this.tryDeploy(base, deployer);
    }

    /// the script rehearsal of the library: it goes through the deterministic deployer from the deployer, so it takes one
    /// deployer nonce when it is not on chain yet and none when it is. the preflight predictions follow
    function test_libraryAndTheNonce() public {
        // forge test predeploys the linked CoreLib at libraryAddress(); mainnet has no code there
        vm.etch(libraryAddress(), "");
        vm.resetNonce(libraryAddress());
        scriptMode = true;
        uint64 n = vm.getNonce(deployer);
        address lib = libraryAddress();
        assertEq(lib.code.length, 0, "not deployed");
        assertTrue(_libraryTxPending());
        assertEq(_controllerNonce(deployer), n + 1);
        assertEq(this.runPre(base, deployer), "", "preflight clean with the library still to send");
        (bool found, bool ok, string memory detail) = _row("signoff: core address (the router flushes to it)");
        assertTrue(found && ok);
        assertEq(detail, vm.toString(vm.computeCreateAddress(deployer, n + 3)), "core at nonce + 3 after the library");
        (,, detail) = _row("signoff: router address (the bounty recipient of the pool)");
        assertEq(detail, vm.toString(vm.computeCreateAddress(deployer, n + 2)), "router at nonce + 2 after the library");
        (,, detail) = _row("library: CoreLib at its create2 address is the compiled code or absent");
        assertTrue(vm.contains(detail, "not deployed"));

        // the library goes out: the same CREATE2 call forge sends, from the deployer
        vm.prank(deployer);
        (bool sent,) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(0), vm.getCode("CoreLib.sol:CoreLib")));
        assertTrue(sent);
        vm.setNonce(deployer, n + 1);
        assertTrue(isCompiledLibrary(lib.code), "the create2 address holds the compiled code");
        assertFalse(_libraryTxPending());
        assertEq(this.runPre(base, deployer), "");
        (found, ok, detail) = _row("signoff: core address (the router flushes to it)");
        assertEq(detail, vm.toString(vm.computeCreateAddress(deployer, n + 3)), "the same core address");
        (,, detail) = _row("library: CoreLib at its create2 address is the compiled code or absent");
        assertTrue(vm.contains(detail, "skips it"));

        // other code at that address cannot be made by create2 with the same initcode. if it were there, preflight stops
        vm.etch(lib, hex"00");
        assertEq(this.runPre(base, deployer), "library: CoreLib at its create2 address is the compiled code or absent");
        console.log("MUT other code at the library create2 address || CAUGHT by preflight (impossible by construction)");
    }

    /// the Core address is a function of the deployer and its nonce only: another library, at another address or with
    /// other code, changes the creation code of the Core but not where it lands
    function test_coreAddressIgnoresTheLibrary() public {
        address want = _coreAt();
        address wantRouter = _routerAt();
        uint256 snap = vm.snapshotState();
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        assertEq(d.core, want);
        assertEq(d.router, wantRouter);
        vm.revertToState(snap);
        vm.etch(_linked(), bytes.concat(_linked().code, hex"00"));
        // the postflight fails on the library row, the Core itself was created at the predicted address before that
        vm.expectRevert(
            abi.encodeWithSelector(Report.ChecksFailed.selector, "core: linked library is the compiled CoreLib")
        );
        this.tryDeploy(base, deployer);
    }

    // ------------------------------------------------------------------ partial failure states

    struct Steps {
        address controller;
        address router;
        address core;
        address coin;
        PoolKey key;
    }

    function _newCoreOf(LaunchConfig memory c, address coinAt, address controller) private returns (address) {
        return address(Prod.newCore(c.owner, coinAt, controller, c.stack, c.rateStart, c.settings));
    }

    /// @dev runs the first `n` of the four creating transactions after the library, by hand, as the deployer: 1 the
    /// controller, 2 the router, 3 the core, 4 the launch
    function _steps(LaunchConfig memory c, uint256 n) internal returns (Steps memory st) {
        uint64 nonce = vm.getNonce(deployer);
        address routerAt = vm.computeCreateAddress(deployer, nonce + 1);
        address coreAt = vm.computeCreateAddress(deployer, nonce + 2);
        c.stack.feeSource = routerAt;
        address coinAt = predictCoin(c, deployer, routerAt);
        vm.startPrank(deployer);
        st.controller = address(Prod.newController(coreAt, c.sale));
        if (n >= 2) st.router = address(Prod.newRouter(deployer));
        if (n >= 3) st.core = _newCoreOf(c, coinAt, st.controller);
        if (n >= 4) {
            st.coin = _launch(c, coinAt, st.router);
            st.key = poolKeyOf(st.coin, c.stack);
        }
        vm.stopPrank();
    }

    /// strangers cannot launch to the predicted coin or touch the router at any half way state
    function test_partialStatesStayClosedToStrangers() public {
        uint256 snap = vm.snapshotState();
        address watcher = makeAddr("review.watcher");
        vm.deal(watcher, 1 ether);
        // after the core, before the launch: nothing at the coin address, the core holds nothing and is inert
        Steps memory st = _steps(base, 3);
        uint256 fee = FACTORY.deployFee();
        assertEq(ICore(payable(st.core)).COIN().code.length, 0, "no coin yet");
        assertEq(st.core.balance, 0, "the core holds nothing");
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = buildConfig(base, base.owner, st.router);
        vm.startPrank(watcher);
        vm.expectRevert();
        FACTORY.deployTokenAsOwner{value: fee}(cfg, base.protocolBps);
        vm.expectRevert(IFeeRouter.OnlyOwner.selector);
        IFeeRouter(payable(st.router)).setEngine(st.core);
        vm.stopPrank();
        vm.revertToState(snap);

        // after the launch, before the router setup: the router has no engine, a stranger cannot set one, eth waits
        st = _steps(base, 4);
        IFeeRouter r = IFeeRouter(payable(st.router));
        vm.startPrank(watcher);
        vm.expectRevert(IFeeRouter.OnlyOwner.selector);
        r.setEngine(watcher);
        vm.expectRevert(IFeeRouter.OnlyOwner.selector);
        r.lock();
        vm.expectRevert(IFeeRouter.NoEngine.selector);
        r.flush();
        vm.stopPrank();
        vm.revertToState(snap);
    }

    /// a second run of the signed config by the same deployer is a second, independent system, not a collision: the coin
    /// address includes the router and core addresses, so the same salt gives another coin. it is no mutation of the
    /// config. the runbook says never rerun Deploy, this is what a rerun costs
    function test_secondRunOfTheSameConfigIsAnotherSystem() public {
        vm.startPrank(deployer);
        Deployed memory d1 = deploySystem(deployer, base);
        Deployed memory d2 = deploySystem(deployer, base);
        vm.stopPrank();
        assertTrue(d1.core != d2.core && d1.coin != d2.coin && d1.router != d2.router, "two systems");
        assertTrue(IAuctionFactory(base.stack.auctionFactory).houseOf(d1.core) != address(0));
        assertTrue(IAuctionFactory(base.stack.auctionFactory).houseOf(d2.core) != address(0));
        console.log(
            "NOT A MUTATION a second run of the signed config || two independent systems, both pass every check"
        );
    }

    // ------------------------------------------------------------------ readbacks of the first review, still true

    function test_wrongPositionIsStoppedByPreflight() public {
        LaunchConfig memory c = base;
        c.positionLower = -170_000;
        this.runPre(c, deployer);
        assertEq(_failedNames(), "rule: position lower equals the start tick");
        c = base;
        c.positionUpper = 600_000;
        this.runPre(c, deployer);
        assertEq(_failedNames(), "rule: position upper is the highest usable tick");
        c = base;
        c.startTick = -175_200;
        this.runPre(c, deployer);
        assertEq(_failedNames(), "rule: position lower equals the start tick");
    }

    /// the postflight reads the position back from the position manager, so a launch whose position is not the
    /// config's fails even when every config rule was bypassed
    function test_postflightReadsThePositionBack() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        startSplitAfterLaunch(base, d.router, d.coin);
        vm.stopPrank();
        postflightAs(base, d.core, deployer);
        assertEq(_failedNames(), "");
        LaunchConfig memory c = base;
        c.startTick = c.positionLower = -170_000;
        postflightAs(c, d.core, deployer);
        assertEq(_failedNames(), "position: ticks equal the config (mirrored, the coin is currency1), pool: start tick equals the config while nothing was bought");
        c = base;
        c.positionUpper = 600_000;
        postflightAs(c, d.core, deployer);
        assertEq(_failedNames(), "position: ticks equal the config (mirrored, the coin is currency1)");
        // after the first trade the start tick itself is gone, the position rows still hold
        vm.warp(block.timestamp + base.sniperSeconds + 1);
        TestSwapRouter r = new TestSwapRouter();
        address buyer = makeAddr("review.buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        r.swap{value: 1 ether}(d.launchKey, true, -1 ether, buyer);
        postflightAs(base, d.core, deployer);
        assertEq(_failedNames(), "");
    }

    /// the sniper parameters are read back from the mev module schedule: start, end (the baseline), window, start time
    function test_postflightReadsTheSniperParamsBack() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        startSplitAfterLaunch(base, d.router, d.coin);
        vm.stopPrank();
        postflightAs(base, d.core, deployer);
        assertEq(_failedNames(), "");
        (uint24 now_,) = IArtCoinsMevSkimV2(base.mevModule).currentSkimBps(d.poolId);
        assertEq(now_, 9_000, "readable at the launch block");
        vm.warp(block.timestamp + 900);
        postflightAs(base, d.core, deployer);
        assertEq(_failedNames(), "");
        string memory row = "mev: schedule equals the config (start, end at the baseline, window, start time)";
        LaunchConfig memory c = base;
        c.sniperStartBps = 8_000;
        postflightAs(c, d.core, deployer);
        assertEq(_failedNames(), row);
        c = base;
        c.sniperSeconds = 3000;
        postflightAs(c, d.core, deployer);
        assertEq(_failedNames(), string.concat(row, ", router: split start is the launch time plus the anti sniper window, exactly"));
        c = base;
        c.baselineSkimBps = 500;
        postflightAs(c, d.core, deployer);
        assertEq(_failedNames(), string.concat("hook: skim config equals the config, ", row));
        vm.warp(block.timestamp + 901);
        postflightAs(base, d.core, deployer);
        assertEq(_failedNames(), "", "window over, the schedule is frozen");
    }

    /// postflight reads back every launch input it can. one deployed system, each field of the config changed
    function test_postflightFailsOnEveryReadableMismatch() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        uint256 n = 15;
        for (uint256 i; i < n; ++i) {
            LaunchConfig memory c = base;
            string memory what;
            if (i == 0) (c.owner, what) = (creator, "owner");
            else if (i == 1) (c.creator, what) = (owner, "creator");
            else if (i == 2) (c.name, what) = ("Other", "name");
            else if (i == 3) (c.symbol, what) = ("OTH", "symbol");
            else if (i == 4) (c.bountyBps, what) = (8000, "bounty");
            else if (i == 5) (c.maxReferralBps, what) = (100, "referral");
            else if (i == 6) (c.lpFeePips, what) = (100, "lpFeePips");
            else if (i == 7) (c.baselineSkimBps, what) = (2_000, "baseline");
            else if (i == 8) (c.rateStart, what) = (base.rateStart + 1, "rate");
            else if (i == 9) (c.sniperStartBps, what) = (8_000, "sniper start");
            else if (i == 10) (c.restricted, what) = (false, "restricted");
            else if (i == 11) (c.protocolBps, what) = (1000, "protocolBps");
            else if (i == 12) (c.creatorPayee, what) = (creator, "payee");
            else if (i == 13) (c.payeePpm, what) = (100_000, "payee ppm");
            else (c.supply, what) = (c.supply + 1e7, "supply");
            postflightAs(c, d.core, deployer);
            assertTrue(bytes(_failedNames()).length != 0, what);
        }
    }

    /// sign off row: at the launch block the whole skim of a buy reaches the engine through the router (no payee
    /// share in the window)
    function test_signoffSniperExtraGoesToTheCore() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        TestSwapRouter r = new TestSwapRouter();
        address buyer = makeAddr("review.buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        r.swap{value: 1 ether}(d.launchKey, true, -1 ether, buyer);
        IFeeRouter fr = IFeeRouter(payable(d.router));
        uint256 held = d.router.balance;
        // 90 points of the buy, of which the part above the 6.9 point baseline goes whole to the bounty leg and 96.38 percent
        // of the baseline part (the protocol keeps the rest of the baseline): 0.831 + 0.0665022
        assertApproxEqRel(held, 0.8975022 ether, 0.001e18, "the router holds the bounty leg");
        address keeper2 = makeAddr("review.keeper");
        vm.prank(keeper2);
        fr.flush();
        assertEq(keeper2.balance, 0);
        assertEq(ICore(payable(d.core)).ethPot(), held, "everything else reaches the pot");
        assertFalse(fr.splitOn(), "the window never shares");
    }

    /// the pool manager, the factory and the escrow are compared with what the hook reports, the factory with what the
    /// locker reports, the hook with what the mev module reports
    function test_stackIsCrossCheckedAgainstTheHook() public {
        address hook = base.stack.hook;
        assertEq(IArtCoinsHookV2(hook).globals().feeEscrow, base.stack.escrow);
        assertEq(IArtCoinsHookV2(hook).poolManager(), base.stack.poolManager);
        assertTrue(IArtCoinsHookV2(hook).isLauncher(base.stack.factory));
        this.runPre(base, deployer);
        assertEq(_failedNames(), "");
        LaunchConfig memory c = base;
        c.stack.escrow = Mainnet.PERMIT2;
        this.runPre(c, deployer);
        (string memory list,) = _failed();
        assertTrue(vm.contains(list, "hook: reports the fee escrow"), list);
        c = base;
        c.stack.poolManager = Mainnet.PERMIT2;
        this.runPre(c, deployer);
        (list,) = _failed();
        assertTrue(vm.contains(list, "hook: reports the pool manager"), list);
        c = base;
        c.mevModule = Mainnet.PERMIT2;
        this.runPre(c, deployer);
        (list,) = _failed();
        assertTrue(vm.contains(list, "factory: mev module enabled"), list);
    }

    /// the constructor refuses a stack member without code, the coin is exempt (it does not exist yet). the auction
    /// factory is one of them: without code, and as a contract that is not a factory. the fee source needs code too
    function test_coreRejectsAStackWithoutCode() public {
        Settings memory s = Mainnet.defaultSettings();
        Stack memory st = base.stack;
        st.feeSource = address(new TestSwapRouter());
        Prod.newCore(owner, makeAddr("coin"), makeAddr("ctl"), st, 4e12, s);
        Stack memory bad = st;
        bad.hook = makeAddr("hook");
        vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, bad.hook));
        Prod.newCore(owner, makeAddr("coin"), makeAddr("ctl"), bad, 4e12, s);
        bad = st;
        bad.escrow = makeAddr("escrow");
        vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, bad.escrow));
        Prod.newCore(owner, makeAddr("coin"), makeAddr("ctl"), bad, 4e12, s);
        bad = st;
        bad.feeSource = makeAddr("router");
        vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, bad.feeSource));
        Prod.newCore(owner, makeAddr("coin"), makeAddr("ctl"), bad, 4e12, s);
        bad = st;
        bad.auctionFactory = makeAddr("auction factory");
        vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, bad.auctionFactory));
        Prod.newCore(owner, makeAddr("coin"), makeAddr("ctl"), bad, 4e12, s);
        bad.auctionFactory = Mainnet.PERMIT2;
        vm.expectRevert();
        Prod.newCore(owner, makeAddr("coin"), makeAddr("ctl"), bad, 4e12, s);
    }

    function parse(string memory j) external view returns (LaunchConfig memory) {
        return parseConfig(j);
    }

    function load(string memory file) external view returns (LaunchConfig memory) {
        return loadConfig(file);
    }

    /// a json number that does not fit its field is rejected, never cut
    function test_jsonNumbersAreRejected() public {
        vm.expectRevert(abi.encodeWithSelector(ConfigReader.ConfigOutOfRange.selector, ".stack.tickSpacing"));
        this.load("test/data/ReviewTruncated.json");
        string memory j = vm.readFile(DEFAULT_CONFIG_FILE);
        assertEq(this.parse(j).bountyBps, 9638, "the untouched file parses");
        string[11] memory from = [
            '"bountyBps": 9638',
            '"payeePpm": 112778',
            '"baselineSkimBps": 690',
            '"sniperSeconds": 1800',
            '"startTick": -175000',
            '"positionUpper": 887200',
            '"poolFee": 8388608',
            '"flatBps": 10000',
            '"avgScore": 4330000',
            '"dropFloorBps": 8000',
            '"buybackSlice": 1000000000000000000'
        ];
        string[11] memory to = [
            '"bountyBps": 65536',
            '"payeePpm": 4294967296',
            '"baselineSkimBps": 16777216',
            '"sniperSeconds": 4294967296',
            '"startTick": -8388609',
            '"positionUpper": 8388608',
            '"poolFee": 16777216',
            '"flatBps": 65536',
            '"avgScore": 4294967296',
            '"dropFloorBps": 65536',
            '"buybackSlice": 340282366920938463463374607431768211456'
        ];
        string[11] memory keys = [
            ".launch.bountyBps",
            ".router.payeePpm",
            ".launch.baselineSkimBps",
            ".launch.sniperSeconds",
            ".launch.startTick",
            ".launch.positionUpper",
            ".stack.poolFee",
            ".settings.flatBps",
            ".settings.avgScore",
            ".settings.dropFloorBps",
            ".settings.buybackSlice"
        ];
        for (uint256 i; i < from.length; ++i) {
            assertTrue(vm.contains(j, from[i]), from[i]);
            vm.expectRevert(abi.encodeWithSelector(ConfigReader.ConfigOutOfRange.selector, keys[i]));
            this.parse(vm.replace(j, from[i], to[i]));
        }
        // the largest value that fits is accepted
        assertEq(this.parse(vm.replace(j, from[0], '"bountyBps": 65535')).bountyBps, 65_535);
        assertEq(this.parse(vm.replace(j, from[4], '"startTick": -8388608')).startTick, -8_388_608);
        // a key that is missing or misspelled is an error, not a zero
        vm.expectRevert();
        this.parse(vm.replace(j, '"exitSliceCredits"', '"exitSliceCreditz"'));
        vm.expectRevert();
        this.parse(vm.replace(j, '"auctionFactory"', '"auctionFactoryy"'));
        vm.expectRevert();
        this.parse(vm.replace(j, '"creatorPayee"', '"creatorPayeee"'));
        // the overrides are optional and default to false
        LaunchConfig memory c = this.parse(vm.replace(j, '"overrides"', '"unused"'));
        assertFalse(c.allowBounty || c.allowOpenFactory);
        c = this.parse(vm.replace(j, '"bounty": false', '"bounty": true'));
        assertTrue(c.allowBounty);
    }

    function requireHash(LaunchConfig memory c, bytes32 h) external view {
        _requireConfigHash(c, h);
    }

    /// the default config plus the launch inputs of script/config/mainnet.json (the live v2 stack, owner, creator, payee,
    /// name, salt)
    function _shipped() internal view returns (LaunchConfig memory s) {
        s = defaultConfig();
        s.stack.hook = v2.hook;
        s.stack.factory = v2.factory;
        s.stack.locker = v2.locker;
        s.stack.escrow = v2.escrow;
        s.mevModule = v2.mev;
        s.owner = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;
        s.creator = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;
        s.creatorPayee = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;
        s.name = "CC";
        s.salt = keccak256("CC");
    }

    function _hashRow() internal view returns (string memory) {
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].name)) == keccak256("signoff: CONFIG_HASH")) return rows[i].detail;
        }
        revert("no hash row");
    }

    /// the one value the operator signs. preflight and postflight print the same hash, Deploy needs it and every change
    /// of the config changes it. the router address the deploy creates is derived and not part of it
    function test_configHashIsTheSignOffValue() public {
        bytes32 h = configHash(base);
        this.runPre(base, deployer);
        assertEq(_hashRow(), vm.toString(h), "preflight prints it");
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        postflightAs(base, d.core, deployer);
        assertEq(_hashRow(), vm.toString(h), "postflight prints the same value");
        assertEq(configHash(base), h, "the router the deploy filled in is outside the hash");
        this.requireHash(base, h);
        vm.expectRevert(abi.encodeWithSelector(SystemDeployer.ConfigHashMismatch.selector, bytes32(0), h));
        this.requireHash(base, bytes32(0));
        LaunchConfig memory c = base;
        c.rateStart = base.rateStart + 1;
        vm.expectRevert(abi.encodeWithSelector(SystemDeployer.ConfigHashMismatch.selector, h, configHash(c)));
        this.requireHash(c, h);
        // the hash does not depend on the machine: same content from a file and from the struct
        LaunchConfig memory f = loadConfig(DEFAULT_CONFIG_FILE);
        assertEq(configHash(f), configHash(_shipped()));
    }

    /// an open factory fails preflight unless the config says so
    function test_openFactoryFailsPreflight() public {
        vm.prank(owner);
        FACTORY.setDeprecated(false);
        this.runPre(base, deployer);
        assertEq(_failedNames(), "factory: deprecated, only the owner can launch");
        LaunchConfig memory c = base;
        c.allowOpenFactory = true;
        this.runPre(c, deployer);
        assertEq(_failedNames(), "");
    }

    /// DEPLOY.md: the token admin is the owner from the first block. it can change the allowlist and leave the
    /// restriction (one way). nothing else is its to change: the skim, the referral cap and the lp fee are frozen
    function test_signoffAdminPowers() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        IArtCoinsTokenV2 coin = IArtCoinsTokenV2(d.coin);
        assertEq(coin.admin(), owner);
        vm.startPrank(owner);
        coin.setAllowed(creator, true);
        assertTrue(coin.isAllowed(creator));
        coin.unrestrict();
        assertFalse(coin.restricted());
        vm.stopPrank();
        // the referral cap has no setter on the v2 hook
        (bool ok,) = base.stack.hook.call(abi.encodeWithSignature("setMaxReferralBpsOfVolume(bytes32,uint24)", d.poolId, 100));
        assertFalse(ok, "no referral cap setter");
        IArtCoinsHookV2.SkimConfig memory k = IArtCoinsHookV2(base.stack.hook).skimConfig(d.poolId);
        assertEq(k.maxReferralBpsOfVolume, 0);
    }
}

/// @notice the funded rule and the climb clamp, fuzzed on standalone cores with any rateStart in bounds, plus the
/// sign off table rows that need a live pool to check
contract ReviewFundedTest is Fixture {
    uint256 internal constant AVG = 4_330_000;
    uint256 internal cursor;

    function _newCore(uint256 rate) internal returns (ICore c) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        IControllerV1 ctl2 = Prod.newController(predicted, Mainnet.defaultSale());
        Settings memory s = Mainnet.defaultSettings();
        // any opening rate in the bounds needs a rate cap at or above it
        s.rateCap = uint64(1e15);
        c = _make(rate, address(ctl2), s);
        assertEq(address(c), predicted);
    }

    function _fees(ICore c, uint256 amt) internal {
        address src = lc.stack.feeSource;
        vm.deal(src, src.balance + amt);
        vm.prank(src);
        (bool ok,) = address(c).call{value: amt}("");
        assertTrue(ok);
    }

    function _make(uint256 rate, address controller, Settings memory s) internal returns (ICore) {
        return Prod.newCore(owner, address(coin), controller, lc.stack, rate, s);
    }

    function _check(ICore c) internal view {
        uint256 pot = c.ethPot();
        uint256 stored = c.rateAtCheckpoint();
        uint256 r = c.ethRate();
        uint256 capBps = c.settings().spendCapBps;
        assertLe(AVG * r, pot * capBps, "the hourly cap affords an average credit at the live rate");
        // the price state never climbs while the cap cannot afford an average credit, and the read is the clamp
        if (pot * capBps < AVG * stored) {
            assertEq(r, pot * capBps / AVG, "the read is the clamp while unaffordable");
        }
    }

    /// forge-config: default.fuzz.runs = 400
    function testFuzz_fundedRuleAndClamp(uint256 rateSeed, uint256[10] memory ops) public {
        uint256 rate = bound(rateSeed, 1e11, 1e15);
        ICore c = _newCore(rate);
        address who = makeAddr("fuzz.seller");
        for (uint256 i; i < ops.length; ++i) {
            uint256 op = ops[i] % 4;
            uint256 arg = ops[i] >> 8;
            if (op == 0) {
                _fees(c, bound(arg, 1e9, 20 ether));
            } else if (op == 1) {
                uint256 r0 = c.ethRate();
                uint256 pot = c.ethPot();
                vm.warp(block.timestamp + bound(arg, 1, 400 hours));
                uint256 r1 = c.ethRate();
                assertGe(r1, r0, "the read fell without a fill");
                uint256 cap = pot * c.settings().spendCapBps / AVG;
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
                    assertTrue(
                        sel == ICore.HourlyCap.selector || sel == ICore.PotTooSmall.selector
                            || sel == ICore.ZeroAmount.selector,
                        "unexpected revert"
                    );
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
        Stack memory st = lc.stack;
        vm.expectRevert(ICore.BadRate.selector);
        Prod.newCore(owner, address(coin), predicted, st, 1e11 - 1, Mainnet.defaultSettings());
        vm.expectRevert(ICore.BadRate.selector);
        Prod.newCore(owner, address(coin), predicted, st, 1e15 + 1, Mainnet.defaultSettings());
        // the opening rate may not sit above the rate cap (1.232e14 at the launch values)
        vm.expectRevert(ICore.BadRate.selector);
        Prod.newCore(owner, address(coin), predicted, st, 1.233e14, Mainnet.defaultSettings());
        Settings memory top = Mainnet.defaultSettings();
        top.rateCap = uint64(1e15);
        ICore lo = Prod.newCore(owner, address(coin), predicted, st, 1e11, top);
        ICore hi = Prod.newCore(owner, address(coin), address(1), st, 1e15, top);
        assertEq(lo.rateAtCheckpoint(), 1e11);
        assertEq(hi.rateAtCheckpoint(), 1e15);
        // the pot at which the clamp equals the rate: 100 average credits at the rate
        _fees(lo, 4.33e15 - 1);
        assertEq(lo.ethRate(), 1e11 - 1);
        _fees(lo, 1);
        assertEq(lo.ethRate(), 1e11);
        _fees(hi, 4.33e19 - 1);
        assertEq(hi.ethRate(), 1e15 - 1);
        _fees(hi, 1);
        assertEq(hi.ethRate(), 1e15);
    }
}
