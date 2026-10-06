// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ReviewHarness, IFactoryAdmin} from "./utils/ReviewHarness.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {CreditIds} from "./utils/CreditIds.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Mainnet, Stack, Settings} from "../src/interfaces/Interfaces.sol";
import {IAuctionFactory, IAuctionHouse} from "../src/interfaces/AuctionHouse.sol";
import {IArtCoinsFactory, IArtCoinsToken, IArtCoinsSkimHook, IArtCoinsMevSkim} from "../src/interfaces/ArtCoins.sol";
import {SystemDeployer, Deployed} from "../script/Deploy.s.sol";
import {LaunchConfig, ConfigReader} from "../script/LaunchConfig.sol";
import {Report} from "../script/Report.sol";

/// @notice independent review of the deploy package (docs/REVIEW-deploy.md), rebuilt for the flow rework: the state
/// mutations that need their own assertions (deployer swap, library, house fee), proofs of the readbacks and a fuzz of the
/// funded rule. the mutation matrix is in test/ReviewMatrix.t.sol. forks mainnet at FORK_BLOCK
contract ReviewDeployTest is ReviewHarness {
    /// a deployer swap: the signer is another address than DEPLOYER (even an enabled one): the script stops at once
    function test_deployerSwapRevertsSafely() public {
        address other = makeAddr("review.other.deployer");
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        IArtCoinsFactory(Mainnet.ARTCOINS_FACTORY).setAdmin(other, true);
        this.requireDeployerExt(deployer, deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, deployer, other));
        this.requireDeployerExt(deployer, other);
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, address(0), deployer));
        this.requireDeployerExt(address(0), deployer);
        console.log(
            "MUT deployer swap (another enabled signer than DEPLOYER) || SAFE REVERT at deploy || DeployerMismatch"
        );
        // the coin address depends on the deployer, so the swap would have launched somewhere else
        assertTrue(predictCoin(base, deployer, _coreAt()) != predictCoin(base, other, _coreAt()));
    }

    /// the live default fee of the auction factory is zero and the preflight row says so. a non zero fee is a warning in
    /// preflight, never a failure there, and the in script postflight stops the deploy on the house that reports it
    function test_houseFeeWarningAndGate() public {
        address af = base.stack.auctionFactory;
        assertEq(IAuctionFactory(af).defaultProtocolFeeBps(), 0, "the live default fee");
        this.runPre(base);
        (bool found, bool ok, string memory detail) = _row("warn: auction factory default fee is zero");
        assertTrue(found && ok, "the live fee row is clean");
        (,, detail) = _row("auction factory: default fee readable");
        assertEq(detail, "0");
        _patchFactoryFee(af, 250);
        assertEq(this.runPre(base), "", "a warning never fails the preflight");
        (found, ok, detail) = _row("warn: auction factory default fee is zero");
        assertTrue(found && !ok, "the warning row fires");
        (,, detail) = _row("auction factory: default fee readable");
        assertEq(detail, "250");
        vm.expectRevert(abi.encodeWithSelector(Report.ChecksFailed.selector, "house: protocol fee is zero"));
        this.tryDeploy(base);
    }

    /// the script rehearsal of the library: it goes through the deterministic deployer from the deployer, so it takes one
    /// deployer nonce when it is not on chain yet and none when it is. the preflight predictions follow
    function test_libraryAndTheNonce() public {
        scriptMode = true;
        uint64 n = vm.getNonce(deployer);
        address lib = libraryAddress();
        assertEq(lib.code.length, 0, "not deployed");
        assertTrue(_libraryTxPending());
        assertEq(_controllerNonce(deployer), n + 1);
        assertEq(this.runPre(base), "", "preflight clean with the library still to send");
        (bool found, bool ok, string memory detail) = _row("signoff: skim bounty and referral payout point to the core");
        assertTrue(found && ok);
        assertEq(detail, vm.toString(vm.computeCreateAddress(deployer, n + 2)), "core at nonce + 2");
        (,, detail) = _row("library: CoreLib at its create2 address is the compiled code or absent");
        assertTrue(vm.contains(detail, "not deployed"));

        // the library goes out: the same CREATE2 call forge sends, from the deployer
        vm.prank(deployer);
        (bool sent,) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(0), vm.getCode("CoreLib.sol:CoreLib")));
        assertTrue(sent);
        vm.setNonce(deployer, n + 1);
        assertTrue(isCompiledLibrary(lib.code), "the create2 address holds the compiled code");
        assertFalse(_libraryTxPending());
        assertEq(this.runPre(base), "");
        (found, ok, detail) = _row("signoff: skim bounty and referral payout point to the core");
        assertEq(detail, vm.toString(vm.computeCreateAddress(deployer, n + 2)), "the same core address");
        (,, detail) = _row("library: CoreLib at its create2 address is the compiled code or absent");
        assertTrue(vm.contains(detail, "skips it"));

        // other code at that address cannot be made by create2 with the same initcode. if it were there, preflight stops
        vm.etch(lib, hex"00");
        assertEq(this.runPre(base), "library: CoreLib at its create2 address is the compiled code or absent");
        console.log("MUT other code at the library create2 address || CAUGHT by preflight (impossible by construction)");
    }

    /// the Core address is a function of the deployer and its nonce only: another library, at another address or with
    /// other code, changes the creation code of the Core but not where it lands
    function test_coreAddressIgnoresTheLibrary() public {
        uint64 n = vm.getNonce(deployer);
        address want = vm.computeCreateAddress(deployer, n + 1);
        uint256 snap = vm.snapshotState();
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        assertEq(d.core, want);
        vm.revertToState(snap);
        vm.etch(_linked(), bytes.concat(_linked().code, hex"00"));
        // the postflight fails on the library row, the Core itself was created at the predicted address before that
        vm.expectRevert(
            abi.encodeWithSelector(Report.ChecksFailed.selector, "core: linked library is the compiled CoreLib")
        );
        this.tryDeploy(base);
    }

    // ------------------------------------------------------------------ partial failure states

    struct Steps {
        address controller;
        address core;
        address coin;
        PoolKey key;
    }

    function _newCore(LaunchConfig memory c, address coinAt, address controller) private returns (address) {
        return address(_make(c, coinAt, controller));
    }

    /// @dev a frame of its own for the constructor call: the 27 field settings struct leaves no room for more locals
    function _make(LaunchConfig memory c, address coinAt, address controller) private returns (Core) {
        return new Core(c.owner, coinAt, controller, c.stack, c.rateStart, c.settings);
    }

    function _launchTx(LaunchConfig memory c, address coreAt) private returns (address) {
        IArtCoinsFactory f = IArtCoinsFactory(c.stack.factory);
        return f.deployTokenWithProtocolBpsAndTax{value: f.deployFee()}(
            buildConfig(c, deployer, coreAt), 0, buildTaxConfig(c, coreAt)
        );
    }

    /// @dev runs the first `n` of the five deploy transactions after the library, by hand, as the deployer
    function _steps(LaunchConfig memory c, uint256 n) internal returns (Steps memory st) {
        uint64 nonce = vm.getNonce(deployer);
        address coreAt = vm.computeCreateAddress(deployer, nonce + 1);
        address coinAt = predictCoin(c, deployer, coreAt);
        vm.startPrank(deployer);
        st.controller = address(new ControllerV1(coreAt));
        if (n >= 2) st.core = _newCore(c, coinAt, st.controller);
        if (n >= 3) {
            st.coin = _launchTx(c, coreAt);
            st.key = poolKeyOf(st.coin, c.stack);
        }
        if (n >= 4) IArtCoinsSkimHook(c.stack.hook).lockPoolExtension(st.key);
        if (n >= 5) IArtCoinsToken(st.coin).updateAdmin(c.owner);
        vm.stopPrank();
    }

    /// strangers cannot launch to the predicted coin or touch the admin role at any half way state
    function test_partialStatesStayClosedToStrangers() public {
        uint256 snap = vm.snapshotState();
        address watcher = makeAddr("review.watcher");
        vm.deal(watcher, 1 ether);
        // after the core, before the launch: nothing at the coin address, the core holds nothing and is inert
        Steps memory st = _steps(base, 2);
        IArtCoinsFactory f = IArtCoinsFactory(base.stack.factory);
        uint256 fee = f.deployFee();
        assertEq(Core(payable(st.core)).COIN().code.length, 0, "no coin yet");
        assertEq(st.core.balance, 0, "the core holds nothing");
        vm.prank(watcher);
        vm.expectRevert();
        f.deployTokenWithProtocolBpsAndTax{value: fee}(
            buildConfig(base, deployer, st.core), 0, buildTaxConfig(base, st.core)
        );
        vm.revertToState(snap);

        // after the launch, before the lock: the deployer is still the token admin and the slot is open
        st = _steps(base, 3);
        vm.prank(watcher);
        vm.expectRevert();
        IArtCoinsSkimHook(base.stack.hook).lockPoolExtension(st.key);
        vm.prank(watcher);
        vm.expectRevert();
        IArtCoinsToken(st.coin).updateAdmin(watcher);
        vm.revertToState(snap);
    }

    /// a second run of the signed config by the same deployer is a second, independent system, not a collision: the coin
    /// address includes the core address, so the same salt gives another coin. it is no mutation of the config. the
    /// runbook says never rerun Deploy, this is what a rerun costs
    function test_secondRunOfTheSameConfigIsAnotherSystem() public {
        vm.startPrank(deployer);
        Deployed memory d1 = deploySystem(deployer, base);
        Deployed memory d2 = deploySystem(deployer, base);
        vm.stopPrank();
        assertTrue(d1.core != d2.core && d1.coin != d2.coin, "two systems");
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

    /// the postflight reads the position back from the position manager, so a launch whose position is not the
    /// config's fails even when every config rule was bypassed
    function test_postflightReadsThePositionBack() public {
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

    /// the sniper parameters are read back through the mev module. inside the window one read pins start, end and
    /// duration together, after it only the end value is readable and the output says so
    function test_postflightReadsTheSniperParamsBack() public {
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

    /// postflight reads back every launch input it can. one deployed system, each field of the config changed
    function test_postflightFailsOnEveryReadableMismatch() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        string[11] memory names = [
            "owner", "creator", "name", "symbol", "bounty", "referral", "lpFee", "baseline", "taxBps", "taxBurn", "rate"
        ];
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
            else if (i == 9) c.taxBurn = creator;
            else c.rateStart = base.rateStart + 1;
            postflight(c, d.core);
            assertTrue(bytes(_failedNames()).length != 0, names[i]);
        }
    }

    /// sign off row: at the launch block the whole 90 points of a buy minus the creator 0.5 reach the core
    function test_signoffSniperExtraGoesToTheCore() public {
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        TestSwapRouter r = new TestSwapRouter();
        address buyer = makeAddr("review.buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        r.swap{value: 1 ether}(d.launchKey, true, -1 ether, buyer);
        assertEq(Core(payable(d.core)).ethPot(), 0.895 ether);
    }

    function _hookView(address hook, string memory sig) internal view returns (address a) {
        (bool ok, bytes memory out) = hook.staticcall(abi.encodeWithSignature(sig));
        require(ok && out.length == 32, sig);
        a = abi.decode(out, (address));
    }

    /// the pool manager, the factory and the escrow are compared with what the hook reports, the factory and the
    /// position manager with what the locker reports
    function test_stackIsCrossCheckedAgainstTheHook() public {
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

    /// the constructor refuses a stack member without code, the coin is exempt (it does not exist yet). the auction
    /// factory is one of them: without code, and as a contract that is not a factory
    function test_coreRejectsAStackWithoutCode() public {
        Settings memory s = Mainnet.defaultSettings();
        Stack memory st = base.stack;
        st.hook = makeAddr("hook");
        vm.expectRevert(abi.encodeWithSelector(Core.NoCode.selector, st.hook));
        new Core(owner, makeAddr("coin"), makeAddr("ctl"), st, 4e12, s);
        st = base.stack;
        st.escrow = makeAddr("escrow");
        vm.expectRevert(abi.encodeWithSelector(Core.NoCode.selector, st.escrow));
        new Core(owner, makeAddr("coin"), makeAddr("ctl"), st, 4e12, s);
        st = base.stack;
        st.auctionFactory = makeAddr("auction factory");
        vm.expectRevert(abi.encodeWithSelector(Core.NoCode.selector, st.auctionFactory));
        new Core(owner, makeAddr("coin"), makeAddr("ctl"), st, 4e12, s);
        st.auctionFactory = Mainnet.PERMIT2;
        vm.expectRevert();
        new Core(owner, makeAddr("coin"), makeAddr("ctl"), st, 4e12, s);
        new Core(owner, makeAddr("coin"), makeAddr("ctl"), base.stack, 4e12, s);
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
        assertEq(this.parse(j).bountyBps, 9500, "the untouched file parses");
        string[12] memory from = [
            '"bountyBps": 9500',
            '"taxBps": 1500',
            '"taxBpsMax": 2000',
            '"baselineSkimBps": 10000',
            '"sniperSeconds": 1800',
            '"startTick": -175000',
            '"positionUpper": 887200',
            '"poolFee": 8388608',
            '"flatBps": 10000',
            '"avgScore": 4330000',
            '"climbDoubleEvery": 86400',
            '"buybackSlice": 1000000000000000000'
        ];
        string[12] memory to = [
            '"bountyBps": 65536',
            '"taxBps": 65536',
            '"taxBpsMax": 65536',
            '"baselineSkimBps": 16777216',
            '"sniperSeconds": 4294967296',
            '"startTick": -8388609',
            '"positionUpper": 8388608',
            '"poolFee": 16777216',
            '"flatBps": 65536',
            '"avgScore": 4294967296',
            '"climbDoubleEvery": 4294967296',
            '"buybackSlice": 340282366920938463463374607431768211456'
        ];
        string[12] memory keys = [
            ".launch.bountyBps",
            ".launch.taxBps",
            ".launch.taxBpsMax",
            ".launch.baselineSkimBps",
            ".launch.sniperSeconds",
            ".launch.startTick",
            ".launch.positionUpper",
            ".stack.poolFee",
            ".settings.flatBps",
            ".settings.avgScore",
            ".settings.climbDoubleEvery",
            ".settings.buybackSlice"
        ];
        for (uint256 i; i < from.length; ++i) {
            assertTrue(vm.contains(j, from[i]), from[i]);
            vm.expectRevert(abi.encodeWithSelector(ConfigReader.ConfigOutOfRange.selector, keys[i]));
            this.parse(vm.replace(j, from[i], to[i]));
        }
        // the largest value that fits is accepted
        assertEq(this.parse(vm.replace(j, from[0], '"bountyBps": 65535')).bountyBps, 65_535);
        assertEq(this.parse(vm.replace(j, from[5], '"startTick": -8388608')).startTick, -8_388_608);
        // a key that is missing or misspelled is an error, not a zero
        vm.expectRevert();
        this.parse(vm.replace(j, '"exitSliceCredits"', '"exitSliceCreditz"'));
        vm.expectRevert();
        this.parse(vm.replace(j, '"auctionFactory"', '"auctionFactoryy"'));
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

    /// the one value the operator signs. preflight and postflight print the same hash, Deploy needs it and every change
    /// of the config changes it
    function test_configHashIsTheSignOffValue() public {
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

    /// an open factory fails preflight unless the config says so
    function test_openFactoryFailsPreflight() public {
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        IFactoryAdmin(Mainnet.ARTCOINS_FACTORY).setDeprecated(false);
        this.runPre(base);
        assertEq(_failedNames(), "factory: deprecated, only the owner and admins can launch");
        LaunchConfig memory c = base;
        c.allowOpenFactory = true;
        this.runPre(c);
        assertEq(_failedNames(), "");
    }

    /// DEPLOY.md says the token admin can raise the tax to its cap and the referral cap to 1000
    function test_signoffAdminCanRaiseTaxAndReferralCap() public {
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
}

/// @notice the funded rule and the climb clamp, fuzzed on standalone cores with any rateStart in bounds, plus the
/// sign off table rows that need a live pool to check
contract ReviewFundedTest is Fixture {
    uint256 internal constant AVG = 4_330_000;
    uint256 internal cursor;

    function _newCore(uint256 rate) internal returns (Core c) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        ControllerV1 ctl2 = new ControllerV1(predicted);
        Settings memory s = Mainnet.defaultSettings();
        // any opening rate in the bounds needs a rate cap at or above it
        s.rateCap = uint64(1e15);
        c = _make(rate, address(ctl2), s);
        assertEq(address(c), predicted);
    }

    function _fees(Core c, uint256 amt) internal {
        vm.deal(Mainnet.SKIM_HOOK, amt);
        vm.prank(Mainnet.SKIM_HOOK);
        (bool ok,) = address(c).call{value: amt}("");
        assertTrue(ok);
    }

    function _make(uint256 rate, address controller, Settings memory s) internal returns (Core) {
        return new Core(owner, address(coin), controller, Mainnet.defaultStack(), rate, s);
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
        new Core(owner, address(coin), predicted, st, 1e11 - 1, Mainnet.defaultSettings());
        vm.expectRevert(Core.BadRate.selector);
        new Core(owner, address(coin), predicted, st, 1e15 + 1, Mainnet.defaultSettings());
        // the opening rate may not sit above the rate cap (1.232e14 at the launch values)
        vm.expectRevert(Core.BadRate.selector);
        new Core(owner, address(coin), predicted, st, 1.233e14, Mainnet.defaultSettings());
        Settings memory top = Mainnet.defaultSettings();
        top.rateCap = uint64(1e15);
        Core lo = new Core(owner, address(coin), predicted, st, 1e11, top);
        Core hi = new Core(owner, address(coin), address(1), st, 1e15, top);
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

