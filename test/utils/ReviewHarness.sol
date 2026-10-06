// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Core} from "../../src/Core.sol";
import {ControllerV1} from "../../src/ControllerV1.sol";
import {SettingsFields} from "../../script/SettingsFields.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Mainnet, Stack, Settings} from "../../src/interfaces/Interfaces.sol";
import {IAuctionFactory, IAuctionHouse} from "../../src/interfaces/AuctionHouse.sol";
import {IArtCoinsFactory, IArtCoinsToken, IArtCoinsSkimHook, IArtCoinsMevSkim} from "../../src/interfaces/ArtCoins.sol";
import {SystemDeployer, Deployed} from "../../script/Deploy.s.sol";
import {LaunchConfig, ConfigReader} from "../../script/LaunchConfig.sol";
import {Report} from "../../script/Report.sol";

interface IFactoryAdmin {
    function setDeprecated(bool d) external;
}

/// @notice independent review of the deploy package (docs/REVIEW-deploy.md), rebuilt for the flow rework: the config
/// mutation matrix, the state mutations (factory, house, library, deployer), proofs of the readbacks and a fuzz of the
/// funded rule. forks mainnet at FORK_BLOCK
abstract contract ReviewHarness is Test, SystemDeployer {
    string internal constant MUT_TOKEN = "test/data/ReviewMutatedToken.creation.hex";
    string internal constant EMPTY_TOKEN = "test/data/ReviewEmptyToken.creation.hex";
    string internal constant GARBAGE_TOKEN = "test/data/ReviewGarbageToken.creation.hex";
    address internal deployer;
    address internal owner;
    address internal creator;
    LaunchConfig internal base;
    /// @dev what `_scriptContext` answers: false is a test run (no library transaction), true rehearses `forge script`
    bool internal scriptMode;

    function _scriptContext() internal view override returns (bool) {
        return scriptMode;
    }

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
        if (sel == Report.ChecksFailed.selector) return string.concat("postflight: ", abi.decode(body, (string)));
        if (sel == SystemDeployer.AddressMismatch.selector) {
            return string.concat("AddressMismatch(", abi.decode(body, (string)), ")");
        }
        if (sel == SystemDeployer.ConfigUnset.selector) {
            return string.concat("ConfigUnset(", abi.decode(body, (string)), ")");
        }
        return string.concat("revert ", vm.toString(sel));
    }

    /// the outcomes of one mutation, in the order the operator meets them. a slip is a launch that passed every check
    /// with a hash equal to the signed one: nothing may be a slip
    enum Class {
        Pre, // preflight fails (or the script stops reading the config), Deploy stops before anything is sent
        Revert, // preflight clean, the deploy reverts in the simulation (factory, core, prediction, deployer): safe
        Post, // preflight clean, the in script postflight reverts the deploy
        Hash, // launches and every check passes, but the config hash differs from the signed one: Deploy refuses it
        Slip // launches, every check passes and the hash is the signed one
    }

    struct Mut {
        string label;
        LaunchConfig c;
        Class want;
    }

    function _className(Class k) internal pure returns (string memory) {
        if (k == Class.Pre) return "CAUGHT by preflight";
        if (k == Class.Revert) return "SAFE REVERT at deploy";
        if (k == Class.Post) return "CAUGHT by postflight";
        if (k == Class.Hash) return "CAUGHT ONLY by the config hash";
        return "SLIP";
    }

    function runPre(LaunchConfig memory c) external returns (string memory) {
        preflight(c, deployer);
        return _failedNames();
    }

    /// @dev runs preflight, then the deploy, on a snapshot, as `Deploy.run` does: the hash gate first (a stale hash
    /// stops everything), then preflight, then the deploy. logs one matrix row. `signed` is the hash of the base config
    function _run(string memory label, LaunchConfig memory c, bytes32 signed) internal returns (Class k) {
        uint256 snap = vm.snapshotState();
        vm.stopPrank();
        string memory detail;
        // a config that cannot even be hashed (a token file that is not hex) stops the script reading it
        bool readable = true;
        bool hashSame;
        try this.hashOf(c) returns (bytes32 h) {
            hashSame = h == signed;
        } catch {
            readable = false;
        }
        try this.runPre(c) returns (string memory names) {
            detail = names;
        } catch {
            require(!readable, "preflight reverted on a config that can be read");
            detail = "the script reverts while reading the config";
        }
        if (bytes(detail).length != 0) {
            k = Class.Pre;
        } else {
            try this.tryDeploy(c) returns (Deployed memory) {
                (k, detail) = (hashSame ? Class.Slip : Class.Hash, "DEPLOYED, every check passed");
            } catch (bytes memory why) {
                detail = _reason(why);
                k = bytes4(why) == Report.ChecksFailed.selector ? Class.Post : Class.Revert;
            }
        }
        console.log(string.concat("MUT ", label, " || ", _className(k), " || ", detail));
        vm.stopPrank();
        vm.revertToState(snap);
    }

    function _m(string memory l, Class w) internal view returns (Mut memory m) {
        m.label = l;
        m.c = base;
        m.want = w;
    }

    /// @dev the mutation of group `g` (0 stack, 1 launch, 2 settings, 3 rate, files and people), an empty label when none
    function _mut(uint256, uint256) internal view virtual returns (Mut memory m) {}

    /// @dev group 4: applies chain state mutation `i` and returns its label and the class it must land in
    function _state(uint256) internal virtual returns (string memory l, Class w) {
        revert("no state group here");
    }

    function _coreAt() internal view returns (address) {
        return vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
    }

    /// @dev the library address the test build links the Core against
    function _linked() internal view returns (address lib) {
        lib = findLibrary(type(Core).creationCode);
        assertTrue(lib != address(0), "no linked library found in the Core creation code");
    }

    /// @dev the live auction factory with a default fee: its runtime code with every all zero 32 byte immutable word
    /// (PUSH32 of zero) set to `bps`. the default fee and the fee recipient are immutables of the factory and both are
    /// zero today, so both read `bps` afterwards. no mock contract: the real code, one value changed
    function _patchFactoryFee(address af, uint16 bps) internal {
        bytes memory code = af.code;
        uint256 patched;
        for (uint256 pc; pc < code.length;) {
            uint8 op = uint8(code[pc]);
            if (op == 0x7f && pc + 33 <= code.length) {
                bool zero = true;
                for (uint256 j = 1; j <= 32; ++j) {
                    if (code[pc + j] != 0) zero = false;
                }
                if (zero) {
                    code[pc + 31] = bytes1(uint8(bps >> 8));
                    code[pc + 32] = bytes1(uint8(bps));
                    ++patched;
                }
            }
            pc += op >= 0x60 && op <= 0x7f ? 2 + (op - 0x60) : 1;
        }
        assertGt(patched, 0, "no immutable word found");
        vm.etch(af, code);
        assertEq(IAuctionFactory(af).defaultProtocolFeeBps(), bps, "the patched default fee");
    }

    function _count(Class got, Class want, string memory label, uint256[5] memory counts) internal pure {
        require(got == want, string.concat("unexpected outcome (", _className(got), "): ", label));
        ++counts[uint256(got)];
    }

    /// @dev one mutation, run in its own call frame (the memory of a deploy is freed when it returns, a whole matrix in
    /// one frame runs out of the 128 MB the EVM gives a test). group 4 is the chain state group. a config mutation must
    /// change the hash (unless the file cannot even be read), then it runs through preflight and the deploy
    function runOne(uint256 g, uint256 i, bytes32 signed) external returns (Class k, string memory label, Class want) {
        if (g == 4) {
            uint256 snap = vm.snapshotState();
            (label, want) = _state(i);
            k = _run(label, base, signed);
            vm.revertToState(snap);
            return (k, label, want);
        }
        Mut memory m = _mut(g, i);
        if (bytes(m.label).length == 0) return (Class.Slip, "", Class.Slip);
        // a config that cannot even be hashed (a token file that is not hex) stops the script reading it
        try this.hashOf(m.c) returns (bytes32 h) {
            assertTrue(h != signed, string.concat("the hash must change: ", m.label));
        } catch {}
        return (_run(m.label, m.c, signed), m.label, m.want);
    }

    /// the mutation matrix on the fixed package. every mutation is caught by a preflight rule, reverts safely at
    /// deploy, is caught by the postflight, or changes the config hash (Deploy refuses a stale hash). nothing slips
    function _matrix(uint256 g, uint256 from, uint256 to) internal {
        bytes32 signed = configHash(base);
        uint256[5] memory counts;
        for (uint256 i = from; i < to; ++i) {
            (Class k, string memory label, Class want) = this.runOne(g, i, signed);
            if (bytes(label).length != 0) _count(k, want, label, counts);
        }
        _report(counts);
    }

    function _report(uint256[5] memory counts) internal pure {
        uint256 total = counts[0] + counts[1] + counts[2] + counts[3] + counts[4];
        console.log("MATRIX mutations", total);
        console.log("MATRIX caught by preflight", counts[uint256(Class.Pre)]);
        console.log("MATRIX safe revert at deploy", counts[uint256(Class.Revert)]);
        console.log("MATRIX caught by postflight", counts[uint256(Class.Post)]);
        console.log("MATRIX caught only by the config hash", counts[uint256(Class.Hash)]);
        console.log("MATRIX slips", counts[uint256(Class.Slip)]);
        assertEq(counts[uint256(Class.Slip)], 0, "something slipped");
    }

    function hashOf(LaunchConfig memory c) external view returns (bytes32) {
        return configHash(c);
    }

    function requireDeployerExt(address want, address got) external pure {
        _requireDeployer(want, got);
    }

    function _row(string memory name) internal view returns (bool found, bool ok, string memory detail) {
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].name)) == keccak256(bytes(name))) return (true, rows[i].ok, rows[i].detail);
        }
    }
}
