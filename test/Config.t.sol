// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {SettingsFields} from "../script/SettingsFields.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";

/// @notice the config file, the placeholder guard, the preflight and the postflight on the pinned fork
contract ConfigTest is Fixture {
    /// @dev SETTINGS_CHANGED of the operator, a flag here so parallel tests never share an environment variable
    bool internal changedFlag;

    address internal constant SHIPPED_OWNER = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;

    function _settingsChanged() internal view override returns (bool) {
        return changedFlag;
    }

    bool internal coinFlag;

    function _coinChanged() internal view override returns (bool) {
        return coinFlag;
    }

    function _same(LaunchConfig memory a, LaunchConfig memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    /// the json file is the default config plus the launch inputs the owner supplied (owner, creator, name, the creator
    /// payee) and the salt, keccak256 of "CC". the v2 stack addresses are still placeholders
    function test_jsonEqualsDefaultConfig() public view {
        LaunchConfig memory f = loadConfig(DEFAULT_CONFIG_FILE);
        LaunchConfig memory d = defaultConfig();
        d.owner = SHIPPED_OWNER;
        d.creator = SHIPPED_OWNER;
        d.creatorPayee = SHIPPED_OWNER;
        d.name = "CC";
        d.salt = keccak256("CC");
        assertEq(abi.encode(f.stack), abi.encode(d.stack));
        assertTrue(_same(f, d), "script/config/mainnet.json drifted from the default config");
        assertEq(f.owner, SHIPPED_OWNER);
        assertEq(f.creator, SHIPPED_OWNER);
        assertEq(f.name, "CC");
        assertEq(f.symbol, "CC");
        assertEq(f.salt, keccak256("CC"));
        assertEq(f.rateStart, 2.0554e13);
        assertEq(f.supply, 1_000_000_000e18);
        assertEq(f.stack.auctionFactory, Mainnet.AUCTION_FACTORY);
        assertEq(abi.encode(f.settings), abi.encode(Mainnet.defaultSettings()), "settings block is the launch values");
        // the launch values of docs/FLOW.md 10.1 and 10.6
        assertEq(f.baselineSkimBps, 6_900);
        assertEq(f.bountyBps, 9_000);
        assertEq(f.lpFee, 0);
        assertEq(f.maxReferralBps, 0);
        assertEq(f.sniperStartBps, 90_000);
        assertEq(f.sniperSeconds, 1800);
        assertTrue(f.restricted);
        assertEq(f.allowed.length, 0);
        assertEq(f.payeePpm, 161_031);
        assertEq(f.tipPpm, 5_000);
        assertEq(f.tipCap, 0.005 ether);
        // the v2 stack is not live: its addresses are placeholders the deploy refuses
        string[] memory unset = unsetFields(f);
        assertEq(unset.length, 5, "the placeholders left in the shipped file");
        assertEq(unset[0], "stack.hook");
        assertEq(unset[1], "stack.factory");
        assertEq(unset[2], "stack.locker");
        assertEq(unset[3], "stack.escrow");
        assertEq(unset[4], "stack.mevModule");
    }

    function requireExt(LaunchConfig memory c) external pure {
        _requireConfig(c);
    }

    /// the deploy refuses to run while any placeholder is unset or the rate is out of bounds
    function test_deployRefusesPlaceholders() public {
        LaunchConfig memory c = defaultConfig();
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "owner"));
        this.requireExt(c);
        c.owner = owner;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "creator"));
        this.requireExt(c);
        c.creator = creator;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "name"));
        this.requireExt(c);
        c.name = "Name";
        c.symbol = "";
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "symbol"));
        this.requireExt(c);
        c.symbol = "SYM";
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "salt"));
        this.requireExt(c);
        c.salt = FIXTURE_SALT;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "router.creatorPayee"));
        this.requireExt(c);
        c.creatorPayee = creator;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "stack.hook"));
        this.requireExt(c);
        c.stack = lc.stack;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "stack.mevModule"));
        this.requireExt(c);
        c.mevModule = lc.mevModule;
        this.requireExt(c);
        c.rateStart = 1e11 - 1;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "rateStart"));
        this.requireExt(c);
        c.rateStart = 1e15 + 1;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "rateStart"));
        this.requireExt(c);
    }

    /// the shipped file has the v2 placeholders, so it is refused as it stands. with the stack filled
    /// in memory it is complete, and the refusal is proven by blanking each field of it
    function test_shippedFileBlankedIsRefused() public {
        LaunchConfig memory c = loadConfig(DEFAULT_CONFIG_FILE);
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "stack.hook"));
        this.requireExt(c);
        c = _shipped();
        this.requireExt(c);
        c.owner = address(0);
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "owner"));
        this.requireExt(c);
        c = _shipped();
        c.creator = address(0);
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "creator"));
        this.requireExt(c);
        c = _shipped();
        c.name = "";
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "name"));
        this.requireExt(c);
        c = _shipped();
        c.salt = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "salt"));
        this.requireExt(c);
        c = _shipped();
        c.creatorPayee = address(0);
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "router.creatorPayee"));
        this.requireExt(c);
    }

    function _shipped() internal view returns (LaunchConfig memory c) {
        c = loadConfig(DEFAULT_CONFIG_FILE);
        c.stack.hook = lc.stack.hook;
        c.stack.factory = lc.stack.factory;
        c.stack.locker = lc.stack.locker;
        c.stack.escrow = lc.stack.escrow;
        c.mevModule = lc.mevModule;
    }

    /// @dev the owner is the factory owner and the deployer. it holds the fee and the gas
    function _funded() internal returns (address d2) {
        d2 = owner;
        vm.deal(d2, 5 ether);
    }

    function _failedNames() internal view returns (string memory list) {
        (list,) = _failed();
        // a failure prints the whole table, so the detail of every row is in the log
        if (bytes(list).length != 0) _print("rows");
    }

    function _warnClean(string memory name) internal view returns (bool) {
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].name)) == keccak256(bytes(name))) return rows[i].ok;
        }
        revert("row missing");
    }

    function _rowDetail(string memory name) internal view returns (string memory) {
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].name)) == keccak256(bytes(name))) return rows[i].detail;
        }
        revert("row missing");
    }

    function test_preflightPasses() public {
        address d2 = _funded();
        preflight(lc, d2);
        assertEq(_failedNames(), "");
        _print("preflight");
        // every launch input has a row: the count is part of the report
        assertGe(rows.length, 90, "preflight rows");
    }

    function test_preflightSimulatesTheLaunchAndLeavesNoTrace() public {
        address d2 = _funded();
        uint256 nonce = vm.getNonce(d2);
        uint256 bal = d2.balance;
        preflight(lc, d2);
        assertEq(vm.getNonce(d2), nonce, "the simulation is reverted");
        assertEq(d2.balance, bal);
        assertTrue(bytes(_rowDetail("factory: deployTokenAsOwner accepts the config (simulated)")).length > 10);
    }

    /// owner and creator may be one address, a warning and never a failure. a stack address as owner or creator fails
    function test_warnOwnerIsTheCreator() public {
        address d2 = _funded();
        string memory w = "warn: owner differs from creator";
        preflight(lc, d2);
        assertTrue(_warnClean(w), "clean when they differ");
        LaunchConfig memory c = lc;
        c.creator = c.owner;
        preflight(c, d2);
        assertFalse(_warnClean(w), "the warning fires");
        assertEq(_failedNames(), "", "owner = creator passes");
        c = lc;
        c.creator = c.stack.hook;
        preflight(c, d2);
        assertEq(_failedNames(), "rule: owner, creator and payees are not dead or stack addresses, factory: deployTokenAsOwner accepts the config (simulated)");
        c = lc;
        c.creatorPayee = c.stack.escrow;
        preflight(c, d2);
        assertEq(_failedNames(), "rule: owner, creator and payees are not dead or stack addresses");
    }

    function test_preflightFailures() public {
        // the default config: unset placeholders, a deployer that is not the factory owner
        address d2 = _user("second deployer");
        vm.deal(d2, 5 ether);
        LaunchConfig memory c = defaultConfig();
        preflight(c, d2);
        (string memory list, uint256 n) = _failed();
        assertGe(n, 8, list);
        // a poor deployer, an out of bounds rate and a wrong hook
        c = lc;
        c.rateStart = 5;
        c.stack.hook = address(0xBEEF);
        preflight(c, _user("poor deployer"));
        (list, n) = _failed();
        assertGe(n, 8, list);
        // the predicted addresses are already taken: rewind the fixture owner to the nonce it deployed at. the core of the
        // fixture owns a house, so the two house rows fail with the three address rows. the coin is taken by the same
        // salt of the same config, and the launch cannot be simulated
        (bool found, uint256 coreNonce) = _coreNonce(address(core), owner);
        assertTrue(found);
        vm.resetNonce(owner);
        vm.setNonce(owner, uint64(coreNonce - 2));
        vm.deal(owner, 5 ether);
        preflight(lc, owner);
        assertEq(
            _failedNames(),
            "factory: deployTokenAsOwner accepts the config (simulated), predicted router is empty, predicted controller is empty, predicted core is empty, predicted coin is empty, auction factory: no house yet for the predicted core, auction factory: the house address of the core is free"
        );
    }

    // ------------------------------------------------------------------ the owner commands the launch needs on v2

    /// the factory floor of the lp fee: until the owner sets it to 0 the preflight fails, with the command named
    function test_preflightNeedsMinLpFeeZero() public {
        address d2 = _funded();
        vm.prank(owner);
        FACTORY.setMinLpFee(3_000);
        preflight(lc, d2);
        assertEq(
            _failedNames(),
            "factory: min lp fee is at most the config lp fee, factory: deployTokenAsOwner accepts the config (simulated)"
        );
        assertTrue(bytes(_rowDetail("factory: min lp fee is at most the config lp fee")).length > 0);
        vm.prank(owner);
        FACTORY.setMinLpFee(0);
        preflight(lc, d2);
        assertEq(_failedNames(), "");
    }

    function test_preflightProtocolSkimFloorAgainstTheBounty() public {
        address d2 = _funded();
        vm.prank(owner);
        FACTORY.setMinProtocolSkimShareBps(1_500);
        preflight(lc, d2);
        assertEq(
            _failedNames(),
            "factory: min protocol skim share leaves room for the bounty, factory: deployTokenAsOwner accepts the config (simulated)"
        );
        // a smaller floor is fine for a 9000 bounty
        vm.prank(owner);
        FACTORY.setMinProtocolSkimShareBps(500);
        preflight(lc, d2);
        assertEq(_failedNames(), "");
    }

    function test_preflightTheFactoryMustBeDeprecatedAndOwnedByTheDeployer() public {
        address d2 = _funded();
        vm.prank(owner);
        FACTORY.setDeprecated(false);
        preflight(lc, d2);
        assertEq(_failedNames(), "factory: deprecated, only the owner can launch");
        LaunchConfig memory c = lc;
        c.allowOpenFactory = true;
        preflight(c, d2);
        assertEq(_failedNames(), "", "the override opens exactly that rule");
        vm.prank(owner);
        FACTORY.setDeprecated(true);
        address other = _user("other signer");
        vm.deal(other, 5 ether);
        preflight(lc, other);
        (string memory list,) = _failed();
        assertEq(list, "factory: owner is the deployer, factory: deployTokenAsOwner accepts the config (simulated)");
    }

    function test_preflightEnabledStackAndEscrow() public {
        address d2 = _funded();
        vm.startPrank(owner);
        FACTORY.setHook(lc.stack.hook, false);
        vm.stopPrank();
        preflight(lc, d2);
        assertEq(_failedNames(), "factory: hook enabled, factory: deployTokenAsOwner accepts the config (simulated)");
        vm.startPrank(owner);
        FACTORY.setHook(lc.stack.hook, true);
        FACTORY.setEscrow(lc.stack.escrow, false);
        vm.stopPrank();
        preflight(lc, d2);
        assertEq(_failedNames(), "factory: escrow enabled");
        vm.startPrank(owner);
        FACTORY.setEscrow(lc.stack.escrow, true);
        FACTORY.setLocker(lc.stack.locker, false);
        vm.stopPrank();
        preflight(lc, d2);
        assertEq(_failedNames(), "factory: locker enabled, factory: deployTokenAsOwner accepts the config (simulated)");
        vm.startPrank(owner);
        FACTORY.setLocker(lc.stack.locker, true);
        FACTORY.setMevModule(lc.mevModule, false);
        vm.stopPrank();
        preflight(lc, d2);
        assertEq(_failedNames(), "factory: mev module enabled, factory: deployTokenAsOwner accepts the config (simulated)");
    }

    function test_postflightPassesOnTheFixture() public {
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
        // the same after trading started: the exact supply and rate rows turn tolerant, nothing fails
        _skipSniperWindow();
        _buyCoin(funder, 1 ether);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
        _print("postflight");
        assertGe(rows.length, 85, "postflight rows");
    }

    /// V2R-5: the postflight compares the runtime code of the Core and of the controller with the compiled artifacts
    /// (immutables and the library address masked). one changed byte in either fails exactly its row
    function test_FIXED_postflightComparesTheCoreAndControllerRuntime() public {
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
        string memory coreRow = "core: runtime code is the compiled Core (immutables and the library address masked)";
        string memory ctlRow = "controller: runtime code is the compiled ControllerV1 (immutables masked)";
        assertTrue(_warnClean(coreRow) && _warnClean(ctlRow), "both rows pass on the fixture");

        bytes memory c = address(core).code;
        c[c.length - 1] = bytes1(uint8(c[c.length - 1]) ^ 1);
        vm.etch(address(core), c);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), coreRow);
        c[c.length - 1] = bytes1(uint8(c[c.length - 1]) ^ 1);
        vm.etch(address(core), c);

        bytes memory k = address(ctl).code;
        k[k.length - 1] = bytes1(uint8(k[k.length - 1]) ^ 1);
        vm.etch(address(ctl), k);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), ctlRow);
    }

    /// V2R-5: the coin's image, metadata and context are read back. the admin changing them fails the row until the
    /// operator names the change (COIN_CHANGED=1), then it is a warning
    function test_FIXED_postflightReadsTheCoinImageMetadataAndContext() public {
        string memory row = "coin: image, metadata and context are empty as launched";
        postflightAs(lc, address(core), owner);
        assertTrue(_warnClean(row), "empty at launch");
        vm.startPrank(owner);
        (bool ok1,) = address(coin).call(abi.encodeWithSignature("updateImage(string)", "ipfs://img"));
        (bool ok2,) = address(coin).call(abi.encodeWithSignature("updateMetadata(string)", "{}"));
        vm.stopPrank();
        assertTrue(ok1 && ok2, "the admin updates the coin");
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), row);
        assertFalse(_warnClean(row));
        coinFlag = true;
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "");
        assertFalse(_warnClean("warn: coin: image, metadata and context are empty as launched"));
    }

    function test_supplyConstantMatchesCore() public view {
        assertEq(CORE_SUPPLY, core.SUPPLY());
    }

    /// the verification arguments built from the config and the first controller are the arguments the core was built with
    function test_coreConstructorArgsReadBack() public view {
        (address first, bool found) = firstController(address(core), owner);
        assertTrue(found);
        assertEq(first, address(ctl), "the first controller is found from the deployer nonce");
        assertEq(
            coreConstructorArgs(core, lc, first),
            abi.encode(owner, address(coin), address(ctl), lc.stack, lc.rateStart, lc.settings),
            "etherscan constructor args"
        );
    }

    function test_postflightCatchesEveryMismatch() public {
        LaunchConfig memory c = lc;
        c.rateStart = lc.rateStart + 1;
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), "core: RATE_START");

        c = lc;
        c.owner = creator;
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), "core: owner, coin: original admin is the config owner, coin: admin is the config owner, router: owner is the config owner");

        c = lc;
        c.bountyBps = 8000;
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), "hook: skim config equals the config");

        c = lc;
        c.stack.escrow = address(0xE5C);
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), "core: escrow, code: stack addresses, coin: allowlist holds the Core, the locker, the escrow and the config entries, coin: the locker and the escrow are pinned");

        // the auction factory of the config is not the one the core was built with
        c = lc;
        c.stack.auctionFactory = Mainnet.PERMIT2;
        postflightAs(c, address(core), owner);
        assertEq(_failedNames(), "core: auction factory, house: factory houseOf(core)");

        postflightAs(lc, address(0xBEEF), owner);
        assertEq(_failedNames(), "code: core");
    }

    /// the two json files collapsed into one: the settings block is inside the hash, and so is the auction factory
    function test_hashCoversSettingsAndAuctionFactory() public view {
        bytes32 h = configHash(lc);
        for (uint256 i; i < SettingsFields.N; ++i) {
            LaunchConfig memory c = lc;
            uint256 v = SettingsFields.get(c.settings, i);
            SettingsFields.set(c.settings, i, v == 0 ? 1 : v - 1);
            assertTrue(configHash(c) != h, "a settings field is outside the hash");
        }
        LaunchConfig memory a = lc;
        a.stack.auctionFactory = address(0xA11CE);
        assertTrue(configHash(a) != h, "the auction factory is outside the hash");
    }

    // ------------------------------------------------------------------ settings

    /// the bounds of the preflight rows and of the deploy guard are the Core's: every field, both edges
    function test_settingsBoundsEveryFieldBothEdges() public view {
        uint256[31] memory lo = SettingsFields.lo();
        uint256[31] memory hi = SettingsFields.hi();
        bytes32[31] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            Settings memory s = Mainnet.defaultSettings();
            // above the top, and the top itself (the two bound by another field start from a free partner)
            if (i == 23) s.xRateCap = 10_000;
            SettingsFields.set(s, i, hi[i]);
            assertEq(SettingsBounds.firstViolation(s), bytes32(0), "the top edge is inside");
            s = Mainnet.defaultSettings();
            SettingsFields.set(s, i, hi[i] + 1);
            assertEq(SettingsBounds.firstViolation(s), names[i], "above the top");
            // below the bottom, for the fields that have one
            if (lo[i] == 0 && i != 23) continue;
            s = Mainnet.defaultSettings();
            if (i == 23) {
                SettingsFields.set(s, 22, s.xRateFloor - 1);
            } else {
                SettingsFields.set(s, i, lo[i] - 1);
            }
            bytes32 got = SettingsBounds.firstViolation(s);
            // the cap below the floor names the floor, as the Core does
            assertEq(got, i == 23 ? bytes32("xRateFloor") : names[i], "below the bottom");
        }
    }

    /// preflight names the failing settings row, the deploy guard refuses, postflight reads each field back
    function test_settingsRowsAndGuard() public {
        address d2 = _funded();
        LaunchConfig memory c = lc;
        c.settings.saleFloorBps = 999;
        preflight(c, d2);
        assertEq(_failedNames(), "settings inside the bounds");
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "settings"));
        this.requireExt(c);
        c = lc;
        c.settings.xRateFloor = c.settings.xRateCap + 1;
        preflight(c, d2);
        assertEq(_failedNames(), "settings inside the bounds");
        c = lc;
        c.settings.dropFloorBps = 4_999;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "settings"));
        this.requireExt(c);
        // the sale settings of the controller have their own row and guard
        c = lc;
        c.sale.floorBps = c.sale.startBps + 1;
        preflight(c, d2);
        assertEq(_failedNames(), "sale settings inside the bounds");
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "sale"));
        this.requireExt(c);
    }

    function test_postflightReadsBackEverySetting() public {
        for (uint256 i; i < SettingsFields.N; ++i) {
            LaunchConfig memory c = lc;
            uint256 v = SettingsFields.get(c.settings, i);
            SettingsFields.set(c.settings, i, v == 0 ? 1 : v - 1);
            postflightAs(c, address(core), owner);
            assertEq(_failedNames(), "core: settings equal the config", "a settings field slipped the readback");
        }
    }

    /// after the owner changed the settings, postflight fails until the operator says so with SETTINGS_CHANGED=1
    function test_postflightAfterTheOwnerChangedTheSettings() public {
        Settings memory s = core.settings();
        s.saleFloorBps = 8_000;
        _setSettings(s);
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "core: settings equal the config");
        changedFlag = true;
        postflightAs(lc, address(core), owner);
        assertEq(_failedNames(), "", "SETTINGS_CHANGED turns the row into a warning");
    }

    /// the auction factory rows of the preflight: the live factory is clean, a house for the core fails it
    function test_preflightAuctionFactoryRows() public {
        address d2 = _funded();
        preflight(lc, d2);
        assertEq(_failedNames(), "");
        // a house already exists for the predicted core
        address coreAt = vm.computeCreateAddress(d2, vm.getNonce(d2) + 2);
        vm.prank(coreAt);
        IAuctionFactoryProbe(Mainnet.AUCTION_FACTORY).createAuctionHouse();
        preflight(lc, d2);
        assertEq(
            _failedNames(),
            "auction factory: no house yet for the predicted core, auction factory: the house address of the core is free"
        );
    }
}

interface IAuctionFactoryProbe {
    function createAuctionHouse() external returns (address);
}
