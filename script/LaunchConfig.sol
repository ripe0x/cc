// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {Stack, Settings, Sale, Mainnet, RATE_START_MIN_WEI, RATE_START_MAX_WEI} from "../src/interfaces/Interfaces.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";

/// @notice everything a launch needs. one struct, loaded from script/config/mainnet.json by the scripts and built in
/// memory by the tests. nothing here is read by `src/`: the Core takes `stack`, `rateStart` and `settings` as constructor
/// arguments
struct LaunchConfig {
    // the artcoins stack. the only block that changes when a new artcoins version ships
    /// `feeSource` is not read from the config file: the deploy creates the fee router and fills it in
    Stack stack;
    address mevModule;
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
    /// the sale settings of the controller at launch (its constructor argument). owner adjustable afterwards
    Sale sale;
    // launch parameters
    uint256 supply;
    int24 startTick;
    int24 positionLower;
    int24 positionUpper;
    uint24 baselineSkimBps;
    /// the engine's share of the baseline skim, bps. the protocol keeps the rest
    uint16 bountyBps;
    uint24 maxReferralBps;
    /// pips (1e6). the v2 factory floors it at its `minLpFee`
    uint24 lpFee;
    /// the anti sniper skim at the first block, falling to the baseline (v2 has no end value) over `sniperSeconds`
    uint24 sniperStartBps;
    uint32 sniperSeconds;
    /// the protocol's share of the locker rewards, bps. 0 appends no protocol slot. the factory default is 2_000
    uint16 protocolBps;
    /// the coin is launched restricted (docs/FLOW.md 18) and the extra allowlist entries beyond the factory's own seeds
    /// and the Core, which the builder always adds (docs/FLOW.md 29)
    bool restricted;
    address[] allowed;
    // the fee router (docs/FLOW.md 10.6): one payee at launch, by parts per million of a flush, the tip of the caller of
    // `flush`. later payees are set through `setPayees`
    address creatorPayee;
    /// the payee's share of the gross flush, ppm. the router receives 6.21 points of 6.9, so 161_031 is 1.0 point of volume
    uint32 payeePpm;
    uint32 tipPpm;
    uint96 tipCap;
    // explicit overrides of pinned preflight rules. all false by default. each one is part of the config hash
    /// allow a bountyBps other than 9000
    bool allowBounty;
    /// allow launching while the factory is not deprecated (a future public factory)
    bool allowOpenFactory;
}

/// @notice reads and checks a `LaunchConfig`
abstract contract ConfigReader is CommonBase {
    string internal constant DEFAULT_CONFIG_FILE = "script/config/mainnet.json";
    /// @dev a json number does not fit the field it is cut into
    error ConfigOutOfRange(string key);

    /// @dev the bounds of the Core constructor argument, one shared definition with the Core, so they cannot drift
    uint256 internal constant RATE_START_MIN = RATE_START_MIN_WEI;
    uint256 internal constant RATE_START_MAX = RATE_START_MAX_WEI;

    /// @notice the default config in memory: the fixed mainnet parts and the launch parameters of
    /// docs/FLOW.md sections 10.1 and 10.6, with the v2 stack addresses, owner, creator, payees, name and salt left unset (the symbol is CC). tests fill them
    function defaultConfig() internal pure returns (LaunchConfig memory c) {
        c.stack = Mainnet.defaultStack();
        c.symbol = "CC";
        c.rateStart = 15_400_000_000_000;
        c.settings = Mainnet.defaultSettings();
        c.sale = Mainnet.defaultSale();
        c.supply = 1_000_000_000e18;
        c.startTick = -175_000;
        c.positionLower = -175_000;
        c.positionUpper = 887_200;
        c.baselineSkimBps = 6_900;
        c.bountyBps = 9000;
        c.maxReferralBps = 0;
        c.lpFee = 0;
        c.sniperStartBps = 90_000;
        c.sniperSeconds = 1800;
        c.protocolBps = 2000;
        c.restricted = true;
        c.payeePpm = 161_031;
        c.tipPpm = 5_000;
        c.tipCap = 0.005 ether;
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
            auctionFactory: vm.parseJsonAddress(j, ".stack.auctionFactory"),
            feeSource: address(0)
        });
        c.mevModule = vm.parseJsonAddress(j, ".stack.mevModule");
        c.owner = vm.parseJsonAddress(j, ".owner");
        c.creator = vm.parseJsonAddress(j, ".creator");
        c.name = vm.parseJsonString(j, ".name");
        c.symbol = vm.parseJsonString(j, ".symbol");
        c.salt = vm.parseJsonBytes32(j, ".salt");
        c.rateStart = vm.parseJsonUint(j, ".rateStart");
        _loadSettings(c, j);
        _loadSale(c, j);
        _loadLaunch(c, j);
        // the overrides are optional, a missing key means false
        c.allowBounty = _flag(j, ".overrides.bounty");
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
        s.saleFloorBps = _u16(j, ".settings.saleFloorBps");
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
        s.feeToBuybackBps = _u16(j, ".settings.feeToBuybackBps");
    }

    function _loadSale(LaunchConfig memory c, string memory j) private pure {
        c.sale = Sale({
            buyOnly: vm.parseJsonBool(j, ".sale.buyOnly"),
            startBps: _u16(j, ".sale.startBps"),
            stepBps: _u16(j, ".sale.stepBps"),
            stepEvery: _u32(j, ".sale.stepEvery"),
            floorBps: _u16(j, ".sale.floorBps")
        });
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
        c.sniperSeconds = _u32(j, ".launch.sniperSeconds");
        c.protocolBps = _u16(j, ".launch.protocolBps");
        c.restricted = vm.parseJsonBool(j, ".launch.restricted");
        c.allowed = vm.parseJsonAddressArray(j, ".launch.allowed");
        c.creatorPayee = vm.parseJsonAddress(j, ".router.creatorPayee");
        c.payeePpm = _u32(j, ".router.payeePpm");
        c.tipPpm = _u32(j, ".router.tipPpm");
        // forge-lint: disable-next-line(unsafe-typecast)
        c.tipCap = uint96(_uint(j, ".router.tipCap", type(uint96).max));
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
        string[] memory tmp = new string[](12);
        uint256 n;
        if (c.owner == address(0)) tmp[n++] = "owner";
        if (c.creator == address(0)) tmp[n++] = "creator";
        if (bytes(c.name).length == 0) tmp[n++] = "name";
        if (bytes(c.symbol).length == 0) tmp[n++] = "symbol";
        if (c.salt == bytes32(0)) tmp[n++] = "salt";
        if (c.creatorPayee == address(0)) tmp[n++] = "router.creatorPayee";
        // the v2 stack is not live yet: its addresses are zero placeholders until it is
        if (c.stack.hook == address(0)) tmp[n++] = "stack.hook";
        if (c.stack.factory == address(0)) tmp[n++] = "stack.factory";
        if (c.stack.locker == address(0)) tmp[n++] = "stack.locker";
        if (c.stack.escrow == address(0)) tmp[n++] = "stack.escrow";
        if (c.mevModule == address(0)) tmp[n++] = "stack.mevModule";
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tmp[i];
        }
    }

    function rateInBounds(LaunchConfig memory c) internal pure returns (bool) {
        return c.rateStart >= RATE_START_MIN && c.rateStart <= RATE_START_MAX && c.rateStart <= c.settings.rateCap;
    }

    /// @notice the name of the first launch sale setting outside the bounds the controller enforces, zero when all are inside
    function saleViolation(LaunchConfig memory c) internal pure returns (bytes32) {
        Sale memory k = c.sale;
        if (k.startBps < 1_000 || k.startBps > 40_000) return "startBps";
        if (k.stepBps > 5_000) return "stepBps";
        if (k.stepEvery < 1 minutes || k.stepEvery > 30 days) return "stepEvery";
        if (k.floorBps < 1_000 || k.floorBps > k.startBps) return "floorBps";
        return bytes32(0);
    }

    /// @notice the name of the first launch setting outside the bounds the Core enforces, zero when all are inside
    function settingsViolation(LaunchConfig memory c) internal pure returns (bytes32) {
        return SettingsBounds.firstViolation(c.settings);
    }
}
