// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {Stack, Settings, Mainnet, RATE_START_MIN_WEI, RATE_START_MAX_WEI} from "../src/interfaces/Interfaces.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";

/// @notice everything a launch needs. one struct, loaded from script/config/mainnet.json by the scripts and built in
/// memory by the tests. nothing here is read by `src/`: the Core takes `stack`, `rateStart` and `settings` as constructor
/// arguments
struct LaunchConfig {
    // the artcoins stack. the only block that changes when a new artcoins version ships
    Stack stack;
    address mevModule;
    address factoryOwner;
    // placeholders that must be filled before a launch
    address owner;
    address creator;
    string name;
    string symbol;
    bytes32 salt;
    // core
    uint256 rateStart;
    /// every economic setting at launch. owner adjustable afterwards, so the launch rules only check bounds
    Settings settings;
    // launch parameters
    uint256 supply;
    int24 startTick;
    int24 positionLower;
    int24 positionUpper;
    uint24 baselineSkimBps;
    uint16 bountyBps;
    uint24 maxReferralBps;
    uint24 lpFee;
    uint24 sniperStartBps;
    uint24 sniperEndBps;
    uint32 sniperSeconds;
    uint16 taxBps;
    uint16 taxBpsMax;
    address taxBurn;
    // explicit overrides of pinned preflight rules. all false by default. each one is part of the config hash
    /// allow a bountyBps other than 9500
    bool allowBounty;
    /// allow a tax recipient other than the dead address
    bool allowTaxBurn;
    /// allow launching while the factory is not deprecated (a future public factory)
    bool allowOpenFactory;
    /// creation bytecode of the token implementation of this artcoins version, without constructor arguments
    string tokenCodeFile;
}

/// @notice reads and checks a `LaunchConfig`
abstract contract ConfigReader is CommonBase {
    string internal constant DEFAULT_CONFIG_FILE = "script/config/mainnet.json";
    /// @dev a json number does not fit the field it is cut into
    error ConfigOutOfRange(string key);

    /// @dev the bounds of the Core constructor argument, one shared definition with the Core, so they cannot drift
    uint256 internal constant RATE_START_MIN = RATE_START_MIN_WEI;
    uint256 internal constant RATE_START_MAX = RATE_START_MAX_WEI;

    /// @notice the default config in memory: the live artcoins stack and the launch parameters of
    /// docs/ARCHITECTURE.md section 2, with owner, creator, name, symbol and salt left unset. tests fill them
    function defaultConfig() internal pure returns (LaunchConfig memory c) {
        c.stack = Mainnet.defaultStack();
        c.mevModule = Mainnet.MEV_LINEAR_SKIM;
        c.factoryOwner = Mainnet.ARTCOINS_FACTORY_OWNER;
        c.rateStart = 15_400_000_000_000;
        c.settings = Mainnet.defaultSettings();
        c.supply = 1_000_000_000e18;
        c.startTick = -175_000;
        c.positionLower = -175_000;
        c.positionUpper = 887_200;
        c.baselineSkimBps = 10_000;
        c.bountyBps = 9500;
        c.maxReferralBps = 0;
        c.lpFee = 0;
        c.sniperStartBps = 90_000;
        c.sniperEndBps = 10_000;
        c.sniperSeconds = 1800;
        c.taxBps = 1500;
        c.taxBpsMax = 2000;
        c.taxBurn = Mainnet.DEAD;
        c.tokenCodeFile = "script/data/ArtCoinsToken.creation.hex";
    }

    /// @notice parses a config file. a missing key reverts inside the cheatcode, a number that does not fit its field
    /// reverts with `ConfigOutOfRange`
    function loadConfig(string memory file) internal view returns (LaunchConfig memory) {
        return parseConfig(vm.readFile(file));
    }

    /// @notice parses a config given as json text
    function parseConfig(string memory j) internal view returns (LaunchConfig memory c) {
        c.stack = Stack({
            poolManager: vm.parseJsonAddress(j, ".stack.poolManager"),
            hook: vm.parseJsonAddress(j, ".stack.hook"),
            tickSpacing: _i24(j, ".stack.tickSpacing"),
            poolFee: _u24(j, ".stack.poolFee"),
            factory: vm.parseJsonAddress(j, ".stack.factory"),
            locker: vm.parseJsonAddress(j, ".stack.locker"),
            escrow: vm.parseJsonAddress(j, ".stack.escrow"),
            auctionFactory: vm.parseJsonAddress(j, ".stack.auctionFactory")
        });
        c.mevModule = vm.parseJsonAddress(j, ".stack.mevModule");
        c.factoryOwner = vm.parseJsonAddress(j, ".factoryOwner");
        c.owner = vm.parseJsonAddress(j, ".owner");
        c.creator = vm.parseJsonAddress(j, ".creator");
        c.name = vm.parseJsonString(j, ".name");
        c.symbol = vm.parseJsonString(j, ".symbol");
        c.salt = vm.parseJsonBytes32(j, ".salt");
        c.rateStart = vm.parseJsonUint(j, ".rateStart");
        _loadSettings(c, j);
        _loadLaunch(c, j);
        // the overrides are optional, a missing key means false
        c.allowBounty = _flag(j, ".overrides.bounty");
        c.allowTaxBurn = _flag(j, ".overrides.taxBurn");
        c.allowOpenFactory = _flag(j, ".overrides.openFactory");
    }

    function _loadSettings(LaunchConfig memory c, string memory j) private pure {
        Settings memory s = c.settings;
        s.flatBps = _u16(j, ".settings.flatBps");
        s.avgScore = _u32(j, ".settings.avgScore");
        s.climbBaseBps = _u16(j, ".settings.climbBaseBps");
        s.climbDoubleEvery = _u32(j, ".settings.climbDoubleEvery");
        s.climbMaxBps = _u16(j, ".settings.climbMaxBps");
        s.dropBps = _u16(j, ".settings.dropBps");
        s.spendCapBps = _u16(j, ".settings.spendCapBps");
        s.bonusCapBps = _u16(j, ".settings.bonusCapBps");
        s.tipSavingsBps = _u16(j, ".settings.tipSavingsBps");
        s.tipCapBps = _u16(j, ".settings.tipCapBps");
        s.reimburseBps = _u16(j, ".settings.reimburseBps");
        s.reimburseCapBps = _u16(j, ".settings.reimburseCapBps");
        s.reserveBps = _u16(j, ".settings.reserveBps");
        s.auctionDuration = _u32(j, ".settings.auctionDuration");
        s.exitAfter = _u32(j, ".settings.exitAfter");
        s.saleToBuybackBps = _u16(j, ".settings.saleToBuybackBps");
        s.exitToBuybackBps = _u16(j, ".settings.exitToBuybackBps");
        // forge-lint: disable-next-line(unsafe-typecast)
        s.buybackSlice = uint128(_uint(j, ".settings.buybackSlice", type(uint128).max));
        s.buybackDelay = _u16(j, ".settings.buybackDelay");
        s.keeperTipBps = _u16(j, ".settings.keeperTipBps");
        s.xRateCap = _u16(j, ".settings.xRateCap");
        s.xRateFloor = _u16(j, ".settings.xRateFloor");
        s.xRateClimbPerHour = _u16(j, ".settings.xRateClimbPerHour");
        s.xRateDropPerCredit = _u16(j, ".settings.xRateDropPerCredit");
        s.xAuctionHalfLife = _u32(j, ".settings.xAuctionHalfLife");
        s.exitSliceCredits = _u16(j, ".settings.exitSliceCredits");
        // forge-lint: disable-next-line(unsafe-typecast)
        s.rateCap = uint64(_uint(j, ".settings.rateCap", type(uint64).max));
        s.exitLaneToBuybackBps = _u16(j, ".settings.exitLaneToBuybackBps");
    }

    function _loadLaunch(LaunchConfig memory c, string memory j) private pure {
        // the supply is a decimal string, it does not fit a json number
        c.supply = vm.parseJsonUint(j, ".launch.supply");
        c.startTick = _i24(j, ".launch.startTick");
        c.positionLower = _i24(j, ".launch.positionLower");
        c.positionUpper = _i24(j, ".launch.positionUpper");
        c.baselineSkimBps = _u24(j, ".launch.baselineSkimBps");
        c.bountyBps = _u16(j, ".launch.bountyBps");
        c.maxReferralBps = _u24(j, ".launch.maxReferralBps");
        c.lpFee = _u24(j, ".launch.lpFee");
        c.sniperStartBps = _u24(j, ".launch.sniperStartBps");
        c.sniperEndBps = _u24(j, ".launch.sniperEndBps");
        c.sniperSeconds = _u32(j, ".launch.sniperSeconds");
        c.taxBps = _u16(j, ".launch.taxBps");
        c.taxBpsMax = _u16(j, ".launch.taxBpsMax");
        c.taxBurn = vm.parseJsonAddress(j, ".launch.taxBurn");
        c.tokenCodeFile = vm.parseJsonString(j, ".launch.tokenCodeFile");
    }

    // every narrowing below follows a bounds check, so the casts cannot truncate
    function _uint(string memory j, string memory key, uint256 max) private pure returns (uint256 v) {
        v = vm.parseJsonUint(j, key);
        if (v > max) revert ConfigOutOfRange(key);
    }

    function _u16(string memory j, string memory key) private pure returns (uint16) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(_uint(j, key, type(uint16).max));
    }

    function _u24(string memory j, string memory key) private pure returns (uint24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(_uint(j, key, type(uint24).max));
    }

    function _u32(string memory j, string memory key) private pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(_uint(j, key, type(uint32).max));
    }

    function _i24(string memory j, string memory key) private pure returns (int24) {
        int256 v = vm.parseJsonInt(j, key);
        if (v < type(int24).min || v > type(int24).max) revert ConfigOutOfRange(key);
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(v);
    }

    function _flag(string memory j, string memory key) private view returns (bool) {
        return vm.keyExistsJson(j, key) && vm.parseJsonBool(j, key);
    }

    /// @notice the placeholders every launch must fill: returns the names of those still unset
    function unsetFields(LaunchConfig memory c) internal pure returns (string[] memory out) {
        string[] memory tmp = new string[](5);
        uint256 n;
        if (c.owner == address(0)) tmp[n++] = "owner";
        if (c.creator == address(0)) tmp[n++] = "creator";
        if (bytes(c.name).length == 0) tmp[n++] = "name";
        if (bytes(c.symbol).length == 0) tmp[n++] = "symbol";
        if (c.salt == bytes32(0)) tmp[n++] = "salt";
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tmp[i];
        }
    }

    function rateInBounds(LaunchConfig memory c) internal pure returns (bool) {
        return c.rateStart >= RATE_START_MIN && c.rateStart <= RATE_START_MAX && c.rateStart <= c.settings.rateCap;
    }

    /// @notice the name of the first launch setting outside the bounds the Core enforces, zero when all are inside
    function settingsViolation(LaunchConfig memory c) internal pure returns (bytes32) {
        return SettingsBounds.firstViolation(c.settings);
    }
}
