// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";

/// @notice the config file, the placeholder guard, the preflight and the postflight on the pinned fork
contract ConfigTest is Fixture {
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
        assertEq(f.rateStart, 5.6e12);
        assertEq(f.supply, 1_000_000_000e18);
        assertEq(f.stack.factory, Mainnet.ARTCOINS_FACTORY);
        assertEq(f.factoryOwner, Mainnet.ARTCOINS_FACTORY_OWNER);
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
        // the predicted addresses are already taken: rewind the fixture deployer to the nonce it launched at
        vm.resetNonce(deployer);
        preflight(lc, deployer);
        assertEq(_failedNames(), "predicted controller is empty, predicted core is empty, predicted coin is empty");
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
            abi.encode(owner, address(coin), address(ctl), lc.stack, lc.rateStart, lc.econ),
            "etherscan constructor args"
        );
    }

    function test_postflightCatchesEveryMismatch() public {
        LaunchConfig memory c = lc;
        c.rateStart = lc.rateStart + 1;
        postflight(c, address(core));
        assertEq(_failedNames(), "core: RATE_START, core: ethRate is rateStart");

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

        postflight(lc, address(0xBEEF));
        assertEq(_failedNames(), "code: core");
    }

    string internal constant RECOMMENDED_CONFIG_FILE = "script/config/mainnet.recommended.json";

    /// the default json has the default dials, the recommended json is the gate20constants row of the simulation
    function test_econInTheTwoConfigFiles() public view {
        LaunchConfig memory f = loadConfig(DEFAULT_CONFIG_FILE);
        assertEq(f.econ.auctionStartX, 40_000);
        assertEq(f.econ.auctionFloorX, 12_000);
        assertEq(f.econ.dropBps, 1000);
        assertEq(f.econ.inventoryGate, 0);
        LaunchConfig memory r = loadConfig(RECOMMENDED_CONFIG_FILE);
        assertEq(r.econ.auctionStartX, 20_000);
        assertEq(r.econ.auctionFloorX, 8_000);
        assertEq(r.econ.dropBps, 2000);
        assertEq(r.econ.inventoryGate, 20);
        assertTrue(econInBounds(f) && econInBounds(r));
    }

    /// the two files differ in the four econ values and nothing else, and so do their hashes
    function test_recommendedDiffersOnlyInTheEconKeys() public view {
        LaunchConfig memory f = loadConfig(DEFAULT_CONFIG_FILE);
        LaunchConfig memory r = loadConfig(RECOMMENDED_CONFIG_FILE);
        assertTrue(configHash(f) != configHash(r), "the hash covers econ");
        r.econ = f.econ;
        assertTrue(_same(f, r), "the files differ outside econ");
    }

    function test_econBoundsInThePreflightRows() public {
        LaunchConfig memory c = lc;
        assertTrue(econInBounds(c));
        c.econ.auctionStartX = 14_999;
        assertFalse(auctionInBounds(c));
        c = lc;
        c.econ.auctionStartX = 40_001;
        assertFalse(auctionInBounds(c));
        c = lc;
        c.econ.auctionFloorX = 5_999;
        assertFalse(auctionInBounds(c));
        c = lc;
        c.econ.auctionFloorX = 12_001;
        assertFalse(auctionInBounds(c));
        c = lc;
        c.econ.auctionStartX = 15_000;
        c.econ.auctionFloorX = 12_000;
        assertTrue(auctionInBounds(c));
        c.econ.auctionFloorX = 15_000;
        assertFalse(auctionInBounds(c), "floor must be strictly below the start");
        c = lc;
        c.econ.dropBps = 999;
        assertFalse(dropInBounds(c));
        c.econ.dropBps = 4_001;
        assertFalse(dropInBounds(c));
        c.econ.dropBps = 4_000;
        assertTrue(dropInBounds(c));
        c = lc;
        for (uint256 g; g < 4; ++g) {
            c.econ.inventoryGate = g;
            assertEq(gateInBounds(c), g == 0, "0 is off, 1 to 4 are refused");
        }
        c.econ.inventoryGate = 5;
        assertTrue(gateInBounds(c));
        c.econ.inventoryGate = 200;
        assertTrue(gateInBounds(c));
        c.econ.inventoryGate = 201;
        assertFalse(gateInBounds(c));
        // the preflight names the failing row
        address d2 = _enabledDeployer();
        c = lc;
        c.econ.dropBps = 5_000;
        preflight(c, d2);
        assertEq(_failedNames(), "DROP_BPS in bounds");
        c = lc;
        c.econ.inventoryGate = 3;
        preflight(c, d2);
        assertEq(_failedNames(), "INVENTORY_GATE in bounds");
        c = lc;
        c.econ.auctionFloorX = c.econ.auctionStartX;
        preflight(c, d2);
        assertEq(_failedNames(), "AUCTION_START_X and AUCTION_FLOOR_X in bounds, floor below start");
    }

    /// the deploy refuses an out of bounds dial, the same way as rateStart
    function test_deployRefusesBadEcon() public {
        LaunchConfig memory c = lc;
        c.econ.auctionStartX = 14_000;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "AUCTION_START_X, AUCTION_FLOOR_X"));
        this.requireExt(c);
        c = lc;
        c.econ.dropBps = 0;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "DROP_BPS"));
        this.requireExt(c);
        c = lc;
        c.econ.inventoryGate = 4;
        vm.expectRevert(abi.encodeWithSelector(ConfigUnset.selector, "INVENTORY_GATE"));
        this.requireExt(c);
        this.requireExt(lc);
    }

    /// postflight reads the four dials back and names each one that differs
    function test_postflightReadsBackTheEcon() public {
        LaunchConfig memory c = lc;
        c.econ.auctionStartX = 30_000;
        postflight(c, address(core));
        assertEq(_failedNames(), "core: AUCTION_START_X");
        c = lc;
        c.econ.auctionFloorX = 10_000;
        postflight(c, address(core));
        assertEq(_failedNames(), "core: AUCTION_FLOOR_X");
        c = lc;
        c.econ.dropBps = 2_000;
        postflight(c, address(core));
        assertEq(_failedNames(), "core: DROP_BPS");
        c = lc;
        c.econ.inventoryGate = 20;
        postflight(c, address(core));
        assertEq(_failedNames(), "core: INVENTORY_GATE");
    }
}
