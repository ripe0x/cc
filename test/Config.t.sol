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

    function _settingsChanged() internal view override returns (bool) {
        return changedFlag;
    }

    function _same(LaunchConfig memory a, LaunchConfig memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    /// the json file is the default config: the live artcoins stack and the launch parameters, placeholders unset
    function test_jsonEqualsDefaultConfig() public view {
        LaunchConfig memory f = loadConfig(DEFAULT_CONFIG_FILE);
        LaunchConfig memory d = defaultConfig();
        assertEq(f.stack.hook, d.stack.hook);
        assertEq(abi.encode(f.stack), abi.encode(d.stack));
        assertTrue(_same(f, d), "script/config/mainnet.json drifted from the default config");
        assertEq(f.owner, address(0));
        assertEq(f.creator, address(0));
        assertEq(bytes(f.name).length, 0);
        assertEq(bytes(f.symbol).length, 0);
        assertEq(f.rateStart, 1.54e13);
        assertEq(f.supply, 1_000_000_000e18);
        assertEq(f.stack.factory, Mainnet.ARTCOINS_FACTORY);
        assertEq(f.stack.auctionFactory, Mainnet.AUCTION_FACTORY);
        assertEq(f.factoryOwner, Mainnet.ARTCOINS_FACTORY_OWNER);
        assertEq(abi.encode(f.settings), abi.encode(Mainnet.defaultSettings()), "settings block is the launch values");
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
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "symbol"));
        this.requireExt(c);
        c.symbol = "SYM";
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "salt"));
        this.requireExt(c);
        c.salt = FIXTURE_SALT;
        this.requireExt(c);
        c.rateStart = 1e11 - 1;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "rateStart"));
        this.requireExt(c);
        c.rateStart = 1e15 + 1;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "rateStart"));
        this.requireExt(c);
    }

    function _enabledDeployer() internal returns (address d2) {
        d2 = _user("second deployer");
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        FACTORY.setAdmin(d2, true);
        vm.deal(d2, 5 ether);
    }

    function _failedNames() internal view returns (string memory list) {
        (list,) = _failed();
    }

    function test_preflightPasses() public {
        address d2 = _enabledDeployer();
        preflight(lc, d2);
        assertEq(_failedNames(), "");
        _print("preflight");
    }

    function test_preflightFailures() public {
        address d2 = _user("second deployer");
        vm.deal(d2, 5 ether);
        LaunchConfig memory c = defaultConfig();
        // a fresh deployer, the factory is deprecated and nobody enabled it, and the placeholders are unset
        preflight(c, d2);
        assertEq(
            _failedNames(),
            "placeholders filled, factory: deployer may launch",
            "unset placeholders and an unenabled deployer"
        );
        // a poor deployer, an out of bounds rate and a wrong hook
        c = lc;
        c.rateStart = 5;
        c.stack.hook = address(0xBEEF);
        preflight(c, _user("poor deployer"));
        (string memory list, uint256 n) = _failed();
        assertGe(n, 5, list);
        // the predicted addresses are already taken: rewind the fixture deployer to the nonce it launched at. the core of
        // the fixture owns a house, so the two house rows fail with the three address rows
        vm.resetNonce(deployer);
        preflight(lc, deployer);
        assertEq(
            _failedNames(),
            "predicted controller is empty, predicted core is empty, auction factory: no house yet for the predicted core, auction factory: the house address of the core is free, predicted coin is empty"
        );
    }

    function test_postflightPassesOnTheFixture() public {
        postflight(lc, address(core));
        assertEq(_failedNames(), "");
        // the same after trading started: the exact supply and rate rows turn tolerant, nothing fails
        _skipSniperWindow();
        _buyCoin(funder, 1 ether);
        postflight(lc, address(core));
        assertEq(_failedNames(), "");
        _print("postflight");
    }

    /// the verification arguments read back from the deployed core are the arguments it was built with
    function test_supplyConstantMatchesCore() public view {
        assertEq(CORE_SUPPLY, core.SUPPLY());
    }

    function test_coreConstructorArgsReadBack() public view {
        assertEq(
            coreConstructorArgs(core),
            abi.encode(owner, address(coin), address(ctl), lc.stack, lc.rateStart, lc.settings),
            "etherscan constructor args"
        );
    }

    function test_postflightCatchesEveryMismatch() public {
        LaunchConfig memory c = lc;
        c.rateStart = lc.rateStart + 1;
        postflight(c, address(core));
        assertEq(_failedNames(), "core: RATE_START");

        c = lc;
        c.owner = creator;
        postflight(c, address(core));
        assertEq(_failedNames(), "core: owner, coin: admin is owner");

        c = lc;
        c.bountyBps = 9000;
        c.taxBps = 1000;
        postflight(c, address(core));
        assertEq(_failedNames(), "coin: equals prediction, skim: bounty bps, tax: bps");

        c = lc;
        c.stack.escrow = address(0xE5C);
        postflight(c, address(core));
        assertEq(_failedNames(), "core: escrow, code: stack addresses");

        // the auction factory of the config is not the one the core was built with
        c = lc;
        c.stack.auctionFactory = Mainnet.PERMIT2;
        postflight(c, address(core));
        assertEq(_failedNames(), "core: auction factory, house: factory houseOf(core)");

        postflight(lc, address(0xBEEF));
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
        uint256[28] memory lo = SettingsFields.lo();
        uint256[28] memory hi = SettingsFields.hi();
        bytes32[28] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            Settings memory s = Mainnet.defaultSettings();
            // above the top, and the top itself (the three bound by another field start from a free partner)
            if (i == 2) s.climbMaxBps = 2_000;
            if (i == 21) s.xRateCap = 10_000;
            SettingsFields.set(s, i, hi[i]);
            assertEq(SettingsBounds.firstViolation(s), bytes32(0), "the top edge is inside");
            s = Mainnet.defaultSettings();
            SettingsFields.set(s, i, hi[i] + 1);
            assertEq(SettingsBounds.firstViolation(s), names[i], "above the top");
            // below the bottom, for the fields that have one
            if (lo[i] == 0 && i != 4 && i != 21) continue;
            s = Mainnet.defaultSettings();
            if (i == 4) {
                SettingsFields.set(s, 4, s.climbBaseBps - 1);
            } else if (i == 21) {
                SettingsFields.set(s, 20, s.xRateFloor - 1);
            } else {
                SettingsFields.set(s, i, lo[i] - 1);
            }
            bytes32 got = SettingsBounds.firstViolation(s);
            // the cap below the floor names the floor, as the Core does
            assertEq(got, i == 21 ? bytes32("xRateFloor") : names[i], "below the bottom");
        }
    }

    /// preflight names the failing settings row, the deploy guard refuses, postflight reads each field back
    function test_settingsRowsAndGuard() public {
        address d2 = _enabledDeployer();
        LaunchConfig memory c = lc;
        c.settings.reserveBps = 999;
        preflight(c, d2);
        assertEq(_failedNames(), "settings inside the bounds");
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "settings"));
        this.requireExt(c);
        c = lc;
        c.settings.xRateFloor = c.settings.xRateCap + 1;
        preflight(c, d2);
        assertEq(_failedNames(), "settings inside the bounds");
        c = lc;
        c.settings.climbMaxBps = c.settings.climbBaseBps - 1;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "settings"));
        this.requireExt(c);
    }

    function test_postflightReadsBackEverySetting() public {
        for (uint256 i; i < SettingsFields.N; ++i) {
            LaunchConfig memory c = lc;
            uint256 v = SettingsFields.get(c.settings, i);
            SettingsFields.set(c.settings, i, v == 0 ? 1 : v - 1);
            postflight(c, address(core));
            assertEq(_failedNames(), "core: settings equal the config", "a settings field slipped the readback");
        }
    }

    /// after the owner changed the settings, postflight fails until the operator says so with SETTINGS_CHANGED=1
    function test_postflightAfterTheOwnerChangedTheSettings() public {
        Settings memory s = core.settings();
        s.reserveBps = 8_000;
        _setSettings(s);
        postflight(lc, address(core));
        assertEq(_failedNames(), "core: settings equal the config");
        changedFlag = true;
        postflight(lc, address(core));
        assertEq(_failedNames(), "", "SETTINGS_CHANGED turns the row into a warning");
    }

    /// the auction factory rows of the preflight: the live factory is clean, a house for the core fails it
    function test_preflightAuctionFactoryRows() public {
        address d2 = _enabledDeployer();
        preflight(lc, d2);
        assertEq(_failedNames(), "");
        // a house already exists for the predicted core
        address coreAt = vm.computeCreateAddress(d2, vm.getNonce(d2) + 1);
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
