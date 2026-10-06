// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {Stack, Mainnet} from "../src/interfaces/Interfaces.sol";

/// @notice everything a launch needs. one struct, loaded from script/config/mainnet.json by the scripts and built in
/// memory by the tests. nothing here is read by `src/`: the Core takes `stack` and `rateStart` as constructor arguments
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
    /// creation bytecode of the token implementation of this artcoins version, without constructor arguments
    string tokenCodeFile;
}

/// @notice reads and checks a `LaunchConfig`
abstract contract ConfigReader is CommonBase {
    string internal constant DEFAULT_CONFIG_FILE = "script/config/mainnet.json";
    uint256 internal constant RATE_START_MIN = 1e11;
    uint256 internal constant RATE_START_MAX = 1e15;

    /// @notice the default config in memory: the live artcoins stack and the launch parameters of
    /// docs/ARCHITECTURE.md section 2, with owner, creator, name, symbol and salt left unset. tests fill them
    function defaultConfig() internal pure returns (LaunchConfig memory c) {
        c.stack = Mainnet.defaultStack();
        c.mevModule = Mainnet.MEV_LINEAR_SKIM;
        c.factoryOwner = Mainnet.ARTCOINS_FACTORY_OWNER;
        c.rateStart = 4e12;
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

    /// @notice parses a config file. a missing key reverts inside the cheatcode
    function loadConfig(string memory file) internal view returns (LaunchConfig memory c) {
        string memory j = vm.readFile(file);
        c.stack = Stack({
            poolManager: vm.parseJsonAddress(j, ".stack.poolManager"),
            hook: vm.parseJsonAddress(j, ".stack.hook"),
            // forge-lint: disable-next-line(unsafe-typecast)
            tickSpacing: int24(vm.parseJsonInt(j, ".stack.tickSpacing")),
            // forge-lint: disable-next-line(unsafe-typecast)
            poolFee: uint24(vm.parseJsonUint(j, ".stack.poolFee")),
            factory: vm.parseJsonAddress(j, ".stack.factory"),
            locker: vm.parseJsonAddress(j, ".stack.locker"),
            escrow: vm.parseJsonAddress(j, ".stack.escrow")
        });
        c.mevModule = vm.parseJsonAddress(j, ".stack.mevModule");
        c.factoryOwner = vm.parseJsonAddress(j, ".factoryOwner");
        c.owner = vm.parseJsonAddress(j, ".owner");
        c.creator = vm.parseJsonAddress(j, ".creator");
        c.name = vm.parseJsonString(j, ".name");
        c.symbol = vm.parseJsonString(j, ".symbol");
        c.salt = vm.parseJsonBytes32(j, ".salt");
        c.rateStart = vm.parseJsonUint(j, ".rateStart");
        _loadLaunch(c, j);
    }

    function _loadLaunch(LaunchConfig memory c, string memory j) private pure {
        // the supply is a decimal string, it does not fit a json number
        c.supply = vm.parseJsonUint(j, ".launch.supply");
        // forge-lint: disable-start(unsafe-typecast)
        c.startTick = int24(vm.parseJsonInt(j, ".launch.startTick"));
        c.positionLower = int24(vm.parseJsonInt(j, ".launch.positionLower"));
        c.positionUpper = int24(vm.parseJsonInt(j, ".launch.positionUpper"));
        c.baselineSkimBps = uint24(vm.parseJsonUint(j, ".launch.baselineSkimBps"));
        c.bountyBps = uint16(vm.parseJsonUint(j, ".launch.bountyBps"));
        c.maxReferralBps = uint24(vm.parseJsonUint(j, ".launch.maxReferralBps"));
        c.lpFee = uint24(vm.parseJsonUint(j, ".launch.lpFee"));
        c.sniperStartBps = uint24(vm.parseJsonUint(j, ".launch.sniperStartBps"));
        c.sniperEndBps = uint24(vm.parseJsonUint(j, ".launch.sniperEndBps"));
        c.sniperSeconds = uint32(vm.parseJsonUint(j, ".launch.sniperSeconds"));
        c.taxBps = uint16(vm.parseJsonUint(j, ".launch.taxBps"));
        c.taxBpsMax = uint16(vm.parseJsonUint(j, ".launch.taxBpsMax"));
        // forge-lint: disable-end(unsafe-typecast)
        c.taxBurn = vm.parseJsonAddress(j, ".launch.taxBurn");
        c.tokenCodeFile = vm.parseJsonString(j, ".launch.tokenCodeFile");
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
        return c.rateStart >= RATE_START_MIN && c.rateStart <= RATE_START_MAX;
    }
}
