// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICoreOpsLib} from "../src/interfaces/ICoreOpsLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CreditSale, Quote} from "../src/interfaces/Interfaces.sol";

/// @notice proof that the suite exercises the production build. tests and scripts compile on the default profile (no
/// via_ir), the production contracts on the via_ir profile (foundry.toml). this test fails unless
///  1. the runtime code the fixture deployed for the Core, the ControllerV1, the two listing adapters, the CoinRenderer and both linked libraries equals, byte for byte,
///     the runtime code of the artifact in `out/` (the immutable slots and the library address slots are masked in both:
///     they are the constructor arguments and the link, not compiler output),
///  2. every one of those artifacts records, in its own solc metadata, viaIR true, optimizer 200 runs, cancun, no
///     metadata hash, solc 0.8.30. the artifact cannot claim that by accident: solc writes it from the settings it ran,
///  3. this very test contract was compiled WITHOUT viaIR, so the profile split is live. a config that put everything on
///     one profile fails here (all via_ir) or at 2 (none via_ir), and a split that deployed a different build fails at 1,
///  4. the sizes are the shipped ones, and the masked runtime code hashes of the seven production artifacts and the creation
///     code hashes of both libraries equal the constants of script/Checks.sol that preflight compares with `out/`. update the
///     sizes and the constants in the same commit that changes a production contract on purpose.
/// the generated interfaces are not part of the proof: `script/tools/gen-interfaces.sh --check` covers them, and the
/// the two library functions the abi does not list are pinned to the artifact selectors below.
contract BuildIdentityTest is LiveFixture {
    uint256 internal constant CORE_RUNTIME = 23762;
    uint256 internal constant CONTROLLER_RUNTIME = 17189;
    uint256 internal constant LIB_RUNTIME = 23811;
    uint256 internal constant OPS_LIB_RUNTIME = 4226;
    uint256 internal constant SEAPORT_ADAPTER_RUNTIME = 2_536;
    uint256 internal constant STRATEGY_ADAPTER_RUNTIME = 534;
    uint256 internal constant RENDERER_RUNTIME = 4_464;
    /// the phase 2 artifacts, deployed by the phase 2 scripts and never by the launch
    uint256 internal constant CONTROLLER_V2_RUNTIME = 14_339;
    uint256 internal constant TREASURY_RUNTIME = 12_399;
    uint256 internal constant POLICY_RUNTIME = 656;

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
            _zero(
                code, vm.parseJsonUint(j, string.concat(e, ".start")), vm.parseJsonUint(j, string.concat(e, ".length"))
            );
        }
    }

    /// @dev zeroes the immutable slots and the library address slots the artifact lists
    function _mask(bytes memory code, string memory j) internal view {
        string[] memory ids = vm.keyExistsJson(j, ".deployedBytecode.immutableReferences")
            ? vm.parseJsonKeys(j, ".deployedBytecode.immutableReferences")
            : new string[](0);
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

    /// @dev the masked runtime code hash of an artifact, computed here with `_mask` and not with the script routine
    function _maskedHash(string memory name) internal view returns (bytes32) {
        bytes memory built = vm.getDeployedCode(string.concat(name, ".sol:", name));
        _mask(built, _json(name));
        return keccak256(built);
    }

    /// @dev the build pins preflight checks (script/Checks.sol) are the artifacts of this tree, by two independent
    /// computations of the masked hash
    // promise: the build pins preflight checks (script/Checks.sol) are the artifacts of this tree, by two independent computations of the masked hash
    function test_pinnedBuildHashesEqualTheArtifacts() public {
        string[14] memory names = [
            "Core",
            "CoreLib",
            "CoreOpsLib",
            "ControllerV1",
            "SeaportBasicAdapter",
            "CreditStrategyAdapter",
            "LogoCoinRenderer",
            "ControllerV2",
            "Phase2BalanceTreasury",
            "ProRataRedemptionPolicy",
            "ControllerV3",
            "BalanceTreasuryV2",
            "ProRataRedeemer",
            "MarketRedeemer"
        ];
        bytes32[14] memory pins = [
            BUILD_HASH_CORE,
            BUILD_HASH_CORELIB,
            BUILD_HASH_COREOPSLIB,
            BUILD_HASH_CONTROLLER,
            BUILD_HASH_SEAPORT_ADAPTER,
            BUILD_HASH_STRATEGY_ADAPTER,
            BUILD_HASH_RENDERER,
            BUILD_HASH_CONTROLLER_V2,
            BUILD_HASH_PHASE2_TREASURY,
            BUILD_HASH_PRO_RATA_POLICY,
            BUILD_HASH_CONTROLLER_V3,
            BUILD_HASH_TREASURY_V2,
            BUILD_HASH_PRO_RATA_REDEEMER,
            BUILD_HASH_MARKET_REDEEMER
        ];
        for (uint256 i; i < 14; ++i) {
            assertEq(_maskedHash(names[i]), pins[i], string.concat(names[i], ": masked hash of the artifact"));
            assertEq(artifactHash(names[i]), pins[i], string.concat(names[i], ": hash the preflight row reads"));
        }
        assertEq(keccak256(vm.getCode("CoreLib.sol:CoreLib")), BUILD_CREATION_HASH_CORELIB, "CoreLib creation code");
        assertEq(
            keccak256(vm.getCode("CoreOpsLib.sol:CoreOpsLib")),
            BUILD_CREATION_HASH_COREOPSLIB,
            "CoreOpsLib creation code"
        );
    }

    // promise: the live deployment (the Core, ControllerV1, the two listing adapters, the renderer and both linked libraries at their mainnet addresses) is the via ir artifacts of this tree
    function test_theFixtureDeploysTheViaIrArtifacts() public view {
        _identical(address(core), "Core", CORE_RUNTIME);
        // in stage B the Core's controller is the live ControllerV2 (decision 250 keeps the V1 view surface); check its
        // identity there, the ControllerV1 identity otherwise
        if (_liveStageB()) _identical(address(ctl), "ControllerV2", CONTROLLER_V2_RUNTIME);
        else _identical(address(ctl), "ControllerV1", CONTROLLER_RUNTIME);
        _identical(seaportAdapter, "SeaportBasicAdapter", SEAPORT_ADAPTER_RUNTIME);
        _identical(strategyAdapter, "CreditStrategyAdapter", STRATEGY_ADAPTER_RUNTIME);
        _identical(renderer, "LogoCoinRenderer", RENDERER_RUNTIME);
        address lib = findLibrary(address(core).code);
        assertTrue(lib != address(0), "the core is linked to a compiled CoreLib");
        _identical(lib, "CoreLib", LIB_RUNTIME);
        address ops = findOpsLibrary(address(core).code);
        assertTrue(ops != address(0), "the core is linked to a compiled CoreOpsLib");
        _identical(ops, "CoreOpsLib", OPS_LIB_RUNTIME);
    }

    // promise: the phase 2 contracts a deploy script creates are the via ir artifacts at their shipped sizes, under EIP-170
    function test_phaseTwoArtifactsAreTheViaIrBuild() public {
        address policy = vm.deployCode("ProRataRedemptionPolicy.sol:ProRataRedemptionPolicy");
        // the treasury constructor validates its balance token (statements() is the live Statements, decimals() is 18);
        // the live BALANCE token passes, so no stand in is needed to exercise the phase 2 artifact build
        address treasury = vm.deployCode(
            "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
            abi.encode(address(core), liveBalanceToken, policy, address(0))
        );
        CreditSale memory credit = CreditSale({saleOn: true, window: 14_400, spreadBps: 1_000, startBps: 15_000});
        Quote memory none;
        address v2 = vm.deployCode(
            "ControllerV2.sol:ControllerV2", abi.encode(address(core), credit, none, uint32(30_000), uint32(3_600))
        );
        _identical(policy, "ProRataRedemptionPolicy", POLICY_RUNTIME);
        _identical(treasury, "Phase2BalanceTreasury", TREASURY_RUNTIME);
        _identical(v2, "ControllerV2", CONTROLLER_V2_RUNTIME);
        assertLt(CONTROLLER_V2_RUNTIME, EIP170_LIMIT);
        assertLt(TREASURY_RUNTIME, EIP170_LIMIT);
        emit log_named_uint("ControllerV2 runtime bytes", CONTROLLER_V2_RUNTIME);
        emit log_named_uint("Phase2BalanceTreasury runtime bytes", TREASURY_RUNTIME);
        emit log_named_uint("ProRataRedemptionPolicy runtime bytes", POLICY_RUNTIME);
    }

    /// the deployed code size limit of EIP-170
    uint256 internal constant EIP170_LIMIT = 24_576;

    // promise: Core and both linked libraries stay under the EIP-170 deployed code size limit, with the margin reported
    function test_coreAndCoreLibFitEip170() public {
        emit log_named_uint("Core runtime bytes", CORE_RUNTIME);
        emit log_named_uint("Core margin under EIP-170", EIP170_LIMIT - CORE_RUNTIME);
        emit log_named_uint("CoreLib runtime bytes", LIB_RUNTIME);
        emit log_named_uint("CoreLib margin under EIP-170", EIP170_LIMIT - LIB_RUNTIME);
        emit log_named_uint("CoreOpsLib runtime bytes", OPS_LIB_RUNTIME);
        emit log_named_uint("CoreOpsLib margin under EIP-170", EIP170_LIMIT - OPS_LIB_RUNTIME);
        assertLt(CORE_RUNTIME, EIP170_LIMIT, "Core exceeds the EIP-170 code size limit");
        assertLt(LIB_RUNTIME, EIP170_LIMIT, "CoreLib exceeds the EIP-170 code size limit");
        assertLt(OPS_LIB_RUNTIME, EIP170_LIMIT, "CoreOpsLib exceeds the EIP-170 code size limit");
    }

    /// @dev the comparison is not vacuous: one flipped byte in code that is not an immutable or a link slot fails it
    // promise: the comparison is not vacuous: one flipped byte in code that is not an immutable or a link slot fails it
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
    // promise: this contract is a test: it must NOT be on the via_ir profile, or the speed split is not in effect
    function test_testsCompileWithoutViaIr() public view {
        string memory j = vm.readFile("out/BuildIdentity.t.sol/BuildIdentityTest.json");
        assertFalse(vm.keyExistsJson(j, ".metadata.settings.viaIR") && vm.parseJsonBool(j, ".metadata.settings.viaIR"));
    }

    /// @dev `swapIn` is added to `ICoreOpsLib` by hand because the library abi leaves it out. `setSettings` is not in the interface: a library names a struct argument by its
    /// name in the selector (`setSettings(Settings)`), an interface by its tuple, so the interface selector would differ
    // promise: the hand-added swap selector and the CoreLib setting selector match their artifacts
    function test_libraryInterfaceSelectorsMatchTheArtifact() public view {
        string memory j = _json("CoreOpsLib");
        assertEq(_id(j, "swapIn(address,address,uint24,int24,address,uint256)"), ICoreOpsLib.swapIn.selector, "swapIn");
        j = _json("CoreLib");
        assertEq(_id(j, "setSettings(Settings)"), bytes4(keccak256("setSettings(Settings)")), "setSettings");
        assertEq(_id(j, "adopt(uint256[])"), ICore.adopt.selector, "adopt");
    }

    function _id(string memory j, string memory sig) internal view returns (bytes4) {
        string memory h = vm.parseJsonString(j, string.concat(".methodIdentifiers['", sig, "']"));
        return bytes4(vm.parseBytes(string.concat("0x", h)));
    }
}
