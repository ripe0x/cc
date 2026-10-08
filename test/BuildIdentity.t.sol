// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICoreLib} from "../src/interfaces/ICoreLib.sol";

/// @notice proof that the suite exercises the production build. tests and scripts compile on the default profile (no
/// via_ir), the production contracts on the via_ir profile (foundry.toml). this test fails unless
///  1. the runtime code the fixture deployed for the Core, the ControllerV1 and the linked CoreLib equals, byte for byte,
///     the runtime code of the artifact in `out/` (the immutable slots and the library address slots are masked in both:
///     they are the constructor arguments and the link, not compiler output),
///  2. every one of those artifacts records, in its own solc metadata, viaIR true, optimizer 200 runs, cancun, no
///     metadata hash, solc 0.8.30. the artifact cannot claim that by accident: solc writes it from the settings it ran,
///  3. this very test contract was compiled WITHOUT viaIR, so the profile split is live. a config that put everything on
///     one profile fails here (all via_ir) or at 2 (none via_ir), and a split that deployed a different build fails at 1,
///  4. the sizes are the shipped ones. update them in the same commit that changes a production contract on purpose.
/// the generated interfaces are not part of the proof: `script/tools/gen-interfaces.sh --check` covers them, and the
/// two library functions the abi does not list are pinned to the artifact selectors below.
contract BuildIdentityTest is Fixture {
    uint256 internal constant CORE_RUNTIME = 24_483;
    uint256 internal constant CONTROLLER_RUNTIME = 4_464;
    uint256 internal constant LIB_RUNTIME = 11_644;

    function _json(string memory name) internal view returns (string memory) {
        return vm.readFile(string.concat("out/", name, ".sol/", name, ".json"));
    }

    function _metadata(string memory j) internal view {
        assertTrue(vm.parseJsonBool(j, ".metadata.settings.viaIR"), "artifact: viaIR");
        assertEq(vm.parseJsonUint(j, ".metadata.settings.optimizer.runs"), 200, "artifact: optimizer runs");
        assertTrue(vm.parseJsonBool(j, ".metadata.settings.optimizer.enabled"), "artifact: optimizer");
        assertEq(vm.parseJsonString(j, ".metadata.settings.evmVersion"), "cancun", "artifact: evm");
        assertEq(vm.parseJsonString(j, ".metadata.settings.metadata.bytecodeHash"), "none", "artifact: metadata hash");
        string memory v = vm.parseJsonString(j, ".metadata.compiler.version");
        assertTrue(_startsWith(v, "0.8.30+"), "artifact: solc 0.8.30");
    }

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(p);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    /// @dev zeroes `len` bytes at `start` of `code`
    function _zero(bytes memory code, uint256 start, uint256 len) internal pure {
        for (uint256 i; i < len; ++i) {
            code[start + i] = 0;
        }
    }

    /// @dev zeroes every {start, length} entry of the array at `path`
    function _zeroRefs(bytes memory code, string memory j, string memory path) internal view {
        for (uint256 k; vm.keyExistsJson(j, string.concat(path, "[", vm.toString(k), "]")); ++k) {
            string memory e = string.concat(path, "[", vm.toString(k), "]");
            _zero(code, vm.parseJsonUint(j, string.concat(e, ".start")), vm.parseJsonUint(j, string.concat(e, ".length")));
        }
    }

    /// @dev zeroes the immutable slots and the library address slots the artifact lists
    function _mask(bytes memory code, string memory j) internal view {
        string[] memory ids = vm.parseJsonKeys(j, ".deployedBytecode.immutableReferences");
        for (uint256 i; i < ids.length; ++i) {
            _zeroRefs(code, j, string.concat(".deployedBytecode.immutableReferences.", ids[i]));
        }
        string[] memory files = vm.parseJsonKeys(j, ".deployedBytecode.linkReferences");
        for (uint256 i; i < files.length; ++i) {
            string memory fp = string.concat(".deployedBytecode.linkReferences['", files[i], "']");
            string[] memory libs = vm.parseJsonKeys(j, fp);
            for (uint256 m; m < libs.length; ++m) {
                _zeroRefs(code, j, string.concat(fp, ".", libs[m]));
            }
        }
    }

    /// @dev the live runtime code at `at` is the artifact runtime code, masked identically, and has `size` bytes
    function _identical(address at, string memory name, uint256 size) internal view {
        string memory j = _json(name);
        _metadata(j);
        bytes memory live = at.code;
        bytes memory built = vm.getDeployedCode(string.concat(name, ".sol:", name));
        assertEq(live.length, size, string.concat(name, ": shipped size"));
        assertEq(built.length, size, string.concat(name, ": artifact size"));
        _mask(live, j);
        _mask(built, j);
        assertEq(keccak256(live), keccak256(built), string.concat(name, ": deployed code is the via_ir artifact"));
    }

    function test_theFixtureDeploysTheViaIrArtifacts() public view {
        _identical(address(core), "Core", CORE_RUNTIME);
        _identical(address(ctl), "ControllerV1", CONTROLLER_RUNTIME);
        address lib = findLibrary(address(core).code);
        assertTrue(lib != address(0), "the core is linked to a compiled CoreLib");
        _identical(lib, "CoreLib", LIB_RUNTIME);
    }

    /// @dev the comparison is not vacuous: one flipped byte in code that is not an immutable or a link slot fails it
    function test_aSingleChangedByteIsDetected() public {
        bytes memory c = address(core).code;
        c[c.length - 1] = bytes1(uint8(c[c.length - 1]) ^ 1);
        address twin = makeAddr("tampered core");
        vm.etch(twin, c);
        vm.expectRevert();
        this.identical(twin, "Core", CORE_RUNTIME);
    }

    function identical(address at, string memory name, uint256 size) external view {
        _identical(at, name, size);
    }

    /// @dev this contract is a test: it must NOT be on the via_ir profile, or the speed split is not in effect
    function test_testsCompileWithoutViaIr() public view {
        string memory j = vm.readFile("out/BuildIdentity.t.sol/BuildIdentityTest.json");
        assertFalse(vm.keyExistsJson(j, ".metadata.settings.viaIR") && vm.parseJsonBool(j, ".metadata.settings.viaIR"));
    }

    /// @dev the one library function the library abi leaves out (state changing) is in `ICoreLib` by hand, and its
    /// selector is the artifact one. `setSettings` is not in the interface: a library names a struct argument by its
    /// name in the selector (`setSettings(Settings)`), an interface by its tuple, so the interface selector would differ
    function test_libraryInterfaceSelectorsMatchTheArtifact() public view {
        string memory j = _json("CoreLib");
        assertEq(_id(j, "swapIn(address,address,uint24,int24,address,uint256)"), ICoreLib.swapIn.selector, "swapIn");
        assertEq(_id(j, "setSettings(Settings)"), bytes4(keccak256("setSettings(Settings)")), "setSettings");
    }

    function _id(string memory j, string memory sig) internal view returns (bytes4) {
        string memory h = vm.parseJsonString(j, string.concat(".methodIdentifiers['", sig, "']"));
        return bytes4(vm.parseBytes(string.concat("0x", h)));
    }
}
