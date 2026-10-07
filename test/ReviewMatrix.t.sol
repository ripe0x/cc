// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReviewHarness, IFactoryAdmin} from "./utils/ReviewHarness.sol";
import {SettingsFields} from "../script/SettingsFields.sol";
import {Core} from "../src/Core.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {IAuctionFactory} from "../src/interfaces/AuctionHouse.sol";
import {IArtCoinsFactory} from "../src/interfaces/ArtCoins.sol";

/// @notice the config mutation matrix, part one: the stack, the launch fields, the rate, the token code file and the
/// people. every mutation says which outcome it must have, `runOne` runs it in its own call frame
contract ReviewMatrixConfigTest is ReviewHarness {
    uint256 internal constant N_STACK = 19;

    function _mutStack(uint256 i) internal view returns (Mut memory m) {
        address other = Mainnet.PERMIT2; // a contract that is not part of the stack
        if (i == 0) {
            m = _m("hook = a contract that is not the hook", Class.Pre);
            m.c.stack.hook = other;
        } else if (i == 1) {
            m = _m("hook = an EOA", Class.Pre);
            m.c.stack.hook = address(0xE0A1);
        } else if (i == 2) {
            m = _m("locker = the escrow", Class.Pre);
            m.c.stack.locker = m.c.stack.escrow;
        } else if (i == 3) {
            m = _m("poolManager = a contract that is not v4", Class.Pre);
            m.c.stack.poolManager = other;
        } else if (i == 4) {
            m = _m("escrow = a contract that is not the escrow", Class.Pre);
            m.c.stack.escrow = other;
        } else if (i == 5) {
            m = _m("factory = a contract that is not the factory", Class.Pre);
            m.c.stack.factory = other;
        } else if (i == 6) {
            m = _m("tickSpacing 60", Class.Pre);
            m.c.stack.tickSpacing = 60;
        } else if (i == 7) {
            m = _m("tickSpacing 400", Class.Pre);
            m.c.stack.tickSpacing = 400;
        } else if (i == 8) {
            m = _m("poolFee 3000 instead of the dynamic flag", Class.Pre);
            m.c.stack.poolFee = 3000;
        } else if (i == 9) {
            m = _m("tickSpacing 0", Class.Pre);
            m.c.stack.tickSpacing = 0;
        } else if (i == 10) {
            m = _m("auctionFactory = an EOA", Class.Pre);
            m.c.stack.auctionFactory = address(0xE0A2);
        } else if (i == 11) {
            m = _m("auctionFactory = a contract that is not the factory (Permit2)", Class.Pre);
            m.c.stack.auctionFactory = other;
        } else if (i == 12) {
            m = _m("auctionFactory = the artcoins factory", Class.Pre);
            m.c.stack.auctionFactory = m.c.stack.factory;
        } else if (i == 13) {
            m = _m("auctionFactory = the zero address", Class.Pre);
            m.c.stack.auctionFactory = address(0);
        } else if (i == 14) {
            m = _m("auctionFactory = the locker", Class.Pre);
            m.c.stack.auctionFactory = m.c.stack.locker;
        } else if (i == 15) {
            m = _m("mevModule = a contract that is not the module", Class.Pre);
            m.c.mevModule = other;
        } else if (i == 16) {
            m = _m("factoryOwner mismatch", Class.Pre);
            m.c.factoryOwner = creator;
        } else if (i == 17) {
            m = _m("poolManager = the zero address", Class.Pre);
            m.c.stack.poolManager = address(0);
        } else {
            m = _m("auctionFactory = the hook", Class.Pre);
            m.c.stack.auctionFactory = m.c.stack.hook;
        }
    }

    // ------------------------------------------------------------------ group B: the launch fields

    uint256 internal constant N_LAUNCH = 45;

    function _mutLaunch(uint256 i) internal view returns (Mut memory m) {
        if (i < 16) return _launchA(i);
        if (i < 32) return _launchB(i - 16);
        return _launchC(i - 32);
    }

    function _launchA(uint256 i) private view returns (Mut memory m) {
        if (i == 0) {
            m = _m("taxBps 2100 above taxBpsMax 2000", Class.Pre);
            m.c.taxBps = 2100;
        } else if (i == 1) {
            m = _m("taxBps = taxBpsMax = 9999", Class.Pre);
            (m.c.taxBps, m.c.taxBpsMax) = (9999, 9999);
        } else if (i == 2) {
            m = _m("taxBurn = creator instead of 0xdEaD", Class.Pre);
            m.c.taxBurn = creator;
        } else if (i == 3) {
            m = _m("bountyBps 9999", Class.Pre);
            m.c.bountyBps = 9999;
        } else if (i == 4) {
            m = _m("bountyBps 10000", Class.Pre);
            m.c.bountyBps = 10_000;
        } else if (i == 5) {
            m = _m("startTick +1 spacing (-174800)", Class.Pre);
            m.c.startTick = -174_800;
        } else if (i == 6) {
            m = _m("startTick -1 spacing (-175200)", Class.Pre);
            m.c.startTick = -175_200;
        } else if (i == 7) {
            m = _m("startTick sign flipped (+175000)", Class.Pre);
            m.c.startTick = 175_000;
        } else if (i == 8) {
            m = _m("startTick not a multiple of spacing (-175001)", Class.Pre);
            m.c.startTick = -175_001;
        } else if (i == 9) {
            m = _m("positionLower -175001", Class.Pre);
            m.c.positionLower = -175_001;
        } else if (i == 10) {
            m = _m("positionUpper 887201", Class.Pre);
            m.c.positionUpper = 887_201;
        } else if (i == 11) {
            m = _m("positionUpper 887400 beyond max tick", Class.Pre);
            m.c.positionUpper = 887_400;
        } else if (i == 12) {
            m = _m("positionUpper 600000 aligned but narrower", Class.Pre);
            m.c.positionUpper = 600_000;
        } else if (i == 13) {
            m = _m("positionLower -170000, start tick below range", Class.Pre);
            m.c.positionLower = -170_000;
        } else if (i == 14) {
            m = _m("salt zero", Class.Pre);
            m.c.salt = bytes32(0);
        } else {
            m = _m("supply 1e27 + 1", Class.Pre);
            m.c.supply = 1_000_000_000e18 + 1;
        }
    }

    function _launchB(uint256 i) private view returns (Mut memory m) {
        if (i == 0) {
            m = _m("supply 1e28", Class.Pre);
            m.c.supply = 10_000_000_000e18;
        } else if (i == 1) {
            m = _m("name empty", Class.Pre);
            m.c.name = "";
        } else if (i == 2) {
            m = _m("sniperSeconds 0", Class.Pre);
            m.c.sniperSeconds = 0;
        } else if (i == 3) {
            m = _m("sniperStartBps 5000 below sniperEndBps 10000", Class.Pre);
            m.c.sniperStartBps = 5000;
        } else if (i == 4) {
            m = _m("maxReferralBps 1000", Class.Pre);
            m.c.maxReferralBps = 1000;
        } else if (i == 5) {
            m = _m("lpFee 5000", Class.Pre);
            m.c.lpFee = 5000;
        } else if (i == 6) {
            m = _m("baselineSkimBps 60000", Class.Pre);
            m.c.baselineSkimBps = 60_000;
        } else if (i == 7) {
            m = _m("sniperSeconds 86400", Class.Pre);
            m.c.sniperSeconds = 86_400;
        } else if (i == 8) {
            m = _m("bountyBps 0 (creator gets all of baseline)", Class.Pre);
            m.c.bountyBps = 0;
        } else if (i == 9) {
            m = _m("supply 0", Class.Pre);
            m.c.supply = 0;
        } else if (i == 10) {
            m = _m("taxBurn zero address", Class.Pre);
            m.c.taxBurn = address(0);
        } else if (i == 11) {
            m = _m("sniperStartBps 20000 (below the module rule)", Class.Pre);
            m.c.sniperStartBps = 20_000;
        } else if (i == 12) {
            m = _m("sniperSeconds 300", Class.Pre);
            m.c.sniperSeconds = 300;
        } else if (i == 13) {
            m = _m("sniperStartBps 90001 above the module limit", Class.Pre);
            m.c.sniperStartBps = 90_001;
        } else if (i == 14) {
            m = _m("sniperEndBps 5000 not the baseline skim", Class.Pre);
            m.c.sniperEndBps = 5000;
        } else {
            m = _m("taxBpsMax 2500", Class.Pre);
            m.c.taxBpsMax = 2500;
        }
    }

    function _launchC(uint256 i) private view returns (Mut memory m) {
        if (i == 0) {
            m = _m("symbol empty", Class.Pre);
            m.c.symbol = "";
        } else if (i == 1) {
            m = _m("startTick and positionLower both -170000 (another start price)", Class.Hash);
            (m.c.startTick, m.c.positionLower) = (-170_000, -170_000);
        } else if (i == 2) {
            m = _m("bountyBps 9999 with the override flag on", Class.Hash);
            (m.c.bountyBps, m.c.allowBounty) = (9999, true);
        } else if (i == 3) {
            m = _m("bountyBps 9000 with the override flag on", Class.Hash);
            (m.c.bountyBps, m.c.allowBounty) = (9000, true);
        } else if (i == 4) {
            m = _m("sniperSeconds 3600 (valid, wrong)", Class.Hash);
            m.c.sniperSeconds = 3600;
        } else if (i == 5) {
            m = _m("sniperSeconds 900 (valid, wrong)", Class.Hash);
            m.c.sniperSeconds = 900;
        } else if (i == 6) {
            m = _m("sniperStartBps 50000 (valid, wrong)", Class.Hash);
            m.c.sniperStartBps = 50_000;
        } else if (i == 7) {
            m = _m("taxBps 0 (valid, wrong)", Class.Hash);
            m.c.taxBps = 0;
        } else if (i == 8) {
            m = _m("taxBps 2000 (valid, wrong)", Class.Hash);
            m.c.taxBps = 2000;
        } else if (i == 9) {
            m = _m("taxBurn = creator with the override flag on", Class.Hash);
            (m.c.taxBurn, m.c.allowTaxBurn) = (creator, true);
        } else if (i == 10) {
            m = _m("name changed", Class.Hash);
            m.c.name = "Review Coin Two";
        } else if (i == 11) {
            m = _m("symbol changed", Class.Hash);
            m.c.symbol = "REV2";
        } else {
            m = _m("salt changed (any nonzero value is accepted)", Class.Hash);
            m.c.salt = keccak256("another salt");
        }
    }

    // ------------------------------------------------------------------ group D: rate, token code, people

    uint256 internal constant N_MISC = 30;

    function _mutMisc(uint256 i) internal view returns (Mut memory m) {
        if (i < 12) return _miscRate(i);
        return _miscPeople(i - 12);
    }

    function _miscRate(uint256 i) private view returns (Mut memory m) {
        if (i == 0) {
            m = _m("rateStart 1e10 below min", Class.Pre);
            m.c.rateStart = 1e10;
        } else if (i == 1) {
            m = _m("rateStart 1e16 above max", Class.Pre);
            m.c.rateStart = 1e16;
        } else if (i == 2) {
            m = _m("rateStart 0", Class.Pre);
            m.c.rateStart = 0;
        } else if (i == 3) {
            m = _m("rateStart 4e15 (4x above max)", Class.Pre);
            m.c.rateStart = 4e15;
        } else if (i == 4) {
            m = _m("rateStart 1e12 (in bounds, not the signed value)", Class.Hash);
            m.c.rateStart = 1e12;
        } else if (i == 5) {
            m = _m("rateStart 1.54e14 (10x the launch day value, in bounds)", Class.Hash);
            m.c.rateStart = 1.54e14;
            m.c.settings.rateCap = 1.54e14;
        } else if (i == 6) {
            m = _m("rateStart 1e11 (the lowest edge)", Class.Hash);
            m.c.rateStart = 1e11;
        } else if (i == 7) {
            m = _m("rateStart 1e15 (the highest edge)", Class.Hash);
            m.c.rateStart = 1e15;
            m.c.settings.rateCap = 1e15;
        } else if (i == 8) {
            m = _m("token creation code, one byte changed", Class.Revert);
            m.c.tokenCodeFile = MUT_TOKEN;
        } else if (i == 9) {
            m = _m("token creation code file is empty", Class.Revert);
            m.c.tokenCodeFile = EMPTY_TOKEN;
        } else if (i == 10) {
            m = _m("token creation code file is not hex", Class.Pre);
            m.c.tokenCodeFile = GARBAGE_TOKEN;
        } else {
            m = _m("token creation code file does not exist", Class.Pre);
            m.c.tokenCodeFile = "test/data/NoSuchFile.hex";
        }
    }

    function _miscPeople(uint256 i) private view returns (Mut memory m) {
        if (i < 9) return _peopleA(i);
        return _peopleB(i - 9);
    }

    function _peopleA(uint256 i) private view returns (Mut memory m) {
        if (i == 0) {
            m = _m("owner and creator swapped", Class.Hash);
            (m.c.owner, m.c.creator) = (creator, owner);
        } else if (i == 1) {
            m = _m("owner = creator (one party, two roles)", Class.Hash);
            m.c.owner = creator;
        } else if (i == 2) {
            m = _m("owner = the deployer", Class.Hash);
            m.c.owner = deployer;
        } else if (i == 3) {
            m = _m("creator = the deployer", Class.Hash);
            m.c.creator = deployer;
        } else if (i == 4) {
            m = _m("owner = a contract that is not part of the stack (Permit2)", Class.Hash);
            m.c.owner = Mainnet.PERMIT2;
        } else if (i == 5) {
            m = _m("owner = the hook", Class.Pre);
            m.c.owner = m.c.stack.hook;
        } else if (i == 6) {
            m = _m("owner = the dead address", Class.Pre);
            m.c.owner = Mainnet.DEAD;
        } else if (i == 7) {
            m = _m("owner = the factory owner (a warning, not a failure)", Class.Hash);
            m.c.owner = m.c.factoryOwner;
        } else {
            m = _m("owner = the auction factory", Class.Pre);
            m.c.owner = m.c.stack.auctionFactory;
        }
    }

    function _peopleB(uint256 i) private view returns (Mut memory m) {
        if (i == 0) {
            m = _m("creator = the auction factory", Class.Pre);
            m.c.creator = m.c.stack.auctionFactory;
        } else if (i == 1) {
            m = _m("creator = the dead address", Class.Pre);
            m.c.creator = Mainnet.DEAD;
        } else if (i == 2) {
            m = _m("owner = the zero address", Class.Pre);
            m.c.owner = address(0);
        } else if (i == 3) {
            m = _m("creator = the zero address", Class.Pre);
            m.c.creator = address(0);
        } else if (i == 4) {
            m = _m("owner = the mev module", Class.Pre);
            m.c.owner = m.c.mevModule;
        } else if (i == 5) {
            m = _m("owner = the pool manager", Class.Pre);
            m.c.owner = m.c.stack.poolManager;
        } else if (i == 6) {
            m = _m("overrides.openFactory on while the factory is deprecated", Class.Hash);
            m.c.allowOpenFactory = true;
        } else if (i == 7) {
            m = _m("creator = the factory owner (a warning, not a failure)", Class.Hash);
            m.c.creator = m.c.factoryOwner;
        } else {
            m = _m("creator = the pool manager", Class.Pre);
            m.c.creator = m.c.stack.poolManager;
        }
    }

    function _mut(uint256 g, uint256 i) internal view override returns (Mut memory) {
        if (g == 0) return _mutStack(i);
        if (g == 1) return _mutLaunch(i);
        return _mutMisc(i);
    }

    function test_matrix_stack() public {
        _matrix(0, 0, N_STACK);
    }

    function test_matrix_launch() public {
        _matrix(1, 0, N_LAUNCH);
    }

    function test_matrix_rateFilesPeople() public {
        _matrix(3, 0, N_MISC);
    }
}

/// @notice the config mutation matrix, part two: every field of the settings, above the top, below the bottom, a plausible
/// wrong value and both edges
contract ReviewMatrixSettingsTest is ReviewHarness {
    // ------------------------------------------------------------------ group C: every settings field

    uint256 internal constant N_SETTINGS = 145;

    /// @dev a plausible value that is not the launch value, inside the bounds, for each field
    function _wrong() internal pure returns (uint256[29] memory) {
        return [
            uint256(5000),
            3_000_000,
            200,
            12 hours,
            1200,
            1000,
            3000,
            1000,
            500,
            100,
            10_000,
            300,
            5000,
            48 hours,
            24 hours,
            8000,
            0,
            2 ether,
            50,
            100,
            9000,
            2000,
            200,
            40,
            12 hours,
            40,
            100_000_000_000_000,
            5000,
            5000
        ];
    }

    function _trim(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) ++n;
        bytes memory out = new bytes(n);
        for (uint256 j; j < n; ++j) {
            out[j] = b[j];
        }
        return string(out);
    }

    /// @dev kinds: 0 above the top, 1 below the bottom, 2 a plausible wrong value, 3 the top edge, 4 the bottom edge.
    /// an empty label means the field has no such case
    function _mutSettings(uint256 k) internal view returns (Mut memory m) {
        uint256 f = k % 29;
        uint256 kind = k / 29;
        uint256[29] memory lo = SettingsFields.lo();
        uint256[29] memory hi = SettingsFields.hi();
        string memory nm = _trim(SettingsFields.names()[f]);
        m = _m("", kind <= 1 ? Class.Pre : Class.Hash);
        Settings memory s = m.c.settings;
        if (kind == 0) {
            SettingsFields.set(s, f, hi[f] + 1);
            m.label = string.concat("settings.", nm, " ", vm.toString(hi[f] + 1), " above the top");
        } else if (kind == 1) {
            if (lo[f] == 0 && f != 4 && f != 21) return m;
            if (f == 4) SettingsFields.set(s, 4, s.climbBaseBps - 1);
            else if (f == 21) SettingsFields.set(s, 20, s.xRateFloor - 1);
            else SettingsFields.set(s, f, lo[f] - 1);
            m.label = string.concat("settings.", nm, " one below the bottom");
        } else if (kind == 2) {
            SettingsFields.set(s, f, _wrong()[f]);
            m.label = string.concat("settings.", nm, " ", vm.toString(_wrong()[f]), " (valid, wrong)");
        } else if (kind == 3) {
            if (f == 2) s.climbMaxBps = 2000;
            if (f == 21) s.xRateFloor = s.xRateCap;
            else SettingsFields.set(s, f, hi[f]);
            m.label = string.concat("settings.", nm, " ", vm.toString(hi[f]), " the top edge");
        } else {
            if (lo[f] == 0 && f != 4 && f != 20) return m;
            if (f == 4) s.climbMaxBps = s.climbBaseBps;
            else if (f == 20) s.xRateCap = s.xRateFloor;
            // the lowest rate cap that still holds the launch rate
            else if (f == 26) s.rateCap = uint64(base.rateStart);
            else SettingsFields.set(s, f, lo[f]);
            m.label = string.concat("settings.", nm, " the bottom edge");
        }
        // an edge that is the launch value is no mutation
        if (keccak256(abi.encode(s)) == keccak256(abi.encode(base.settings))) m.label = "";
    }

    function _mut(uint256, uint256 i) internal view override returns (Mut memory) {
        return _mutSettings(i);
    }

    /// the settings group in parts: every field above the top and below the bottom, a plausible wrong value for every
    /// field, then the edges that must still be accepted
    function test_matrix_settingsViolations() public {
        _matrix(2, 0, 58);
    }

    function test_matrix_settingsWrongValues() public {
        _matrix(2, 58, 87);
    }

    function test_matrix_settingsTopEdges() public {
        _matrix(2, 87, 116);
    }

    function test_matrix_settingsBottomEdges() public {
        _matrix(2, 116, N_SETTINGS);
    }
}

/// @notice the matrix, part three: the chain state differs from the one that was signed off (factory, house, library)
contract ReviewMatrixStateTest is ReviewHarness {
    uint256 internal constant N_STATE = 13;

    /// @dev applies state mutation `i` on the current fork state and returns its label and expected class
    function _state(uint256 i) internal override returns (string memory l, Class w) {
        address af = base.stack.auctionFactory;
        if (i == 0) {
            (l, w) = ("factory not deprecated (open)", Class.Pre);
            vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
            IFactoryAdmin(Mainnet.ARTCOINS_FACTORY).setDeprecated(false);
        } else if (i == 1) {
            (l, w) = ("deployer not enabled by the factory owner", Class.Pre);
            vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
            IArtCoinsFactory(Mainnet.ARTCOINS_FACTORY).setAdmin(deployer, false);
        } else if (i == 2) {
            (l, w) = ("deployer balance 0.05 eth (below the 0.069 fee)", Class.Pre);
            vm.deal(deployer, 0.05 ether);
        } else if (i == 3) {
            (l, w) = ("deployer balance 0.07 eth (the fee, no gas at 1 gwei)", Class.Pre);
            vm.deal(deployer, 0.07 ether);
            vm.fee(1 gwei);
        } else if (i == 4) {
            (l, w) = ("a house already exists for the predicted core", Class.Pre);
            vm.prank(_coreAt());
            IAuctionFactory(af).createAuctionHouse();
        } else if (i == 5) {
            (l, w) = ("the predicted coin address has code (salt reuse, a copycat)", Class.Pre);
            vm.etch(predictCoin(base, deployer, _coreAt()), hex"00");
        } else if (i == 6) {
            (l, w) = ("the predicted controller address has code", Class.Pre);
            vm.etch(vm.computeCreateAddress(deployer, vm.getNonce(deployer)), hex"00");
        } else if (i == 7) {
            (l, w) = ("the predicted core address has code", Class.Pre);
            vm.etch(_coreAt(), hex"00");
        } else if (i == 8) {
            (l, w) = ("the house address of the core has code", Class.Pre);
            vm.etch(IAuctionFactory(af).predictHouseAddress(_coreAt()), hex"00");
        } else if (i == 9) {
            (l, w) = ("auction factory default fee 250 bps (the live code, fee immutable patched)", Class.Post);
            _patchFactoryFee(af, 250);
        } else if (i == 10) {
            (l, w) = ("the linked library has no code", Class.Revert);
            vm.etch(_linked(), "");
        } else if (i == 11) {
            (l, w) = ("different code at the linked library (a STOP)", Class.Revert);
            vm.etch(_linked(), hex"00");
        } else {
            (l, w) = ("the linked library plus one trailing byte", Class.Post);
            vm.etch(_linked(), bytes.concat(_linked().code, hex"00"));
        }
    }

    function test_matrix_chainState() public {
        _matrix(4, 0, N_STATE);
        // the baseline launches clean: the signed config deploys with every check passing and the signed hash
        bytes32 signed = configHash(base);
        assertTrue(this.runBaseline(signed) == Class.Slip, "the baseline launches clean");
    }

    function runBaseline(bytes32 signed) external returns (Class) {
        return _run("baseline", base, signed);
    }
}
