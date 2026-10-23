// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VmSafe} from "forge-std/Vm.sol";
import {Stack, Mainnet, IStatements} from "../src/interfaces/Interfaces.sol";
import {
    IArtCoinsFactoryV2,
    IArtCoinsHookV2,
    IArtCoinsLpLockerV2,
    IArtCoinsFeeEscrowV2,
    IArtCoinsMevSkimV2
} from "../src/interfaces/ArtCoinsV2.sol";
import {
    LaunchConfig,
    V2_CONSTANTS_HASH,
    V2_PIN_BLOCK,
    V2_CODEHASH_HOOK,
    V2_CODEHASH_FACTORY,
    V2_CODEHASH_LOCKER,
    V2_CODEHASH_ESCROW,
    V2_CODEHASH_MEV_MODULE,
    V2_CODEHASH_TOKEN_DEPLOYER,
    V2_CODEHASH_ALLOWLIST,
    V2_CODEHASH_FEE_CONTROLLER,
    V2_CODEHASH_BURN_ROUTER,
    OWNER_DELEGATION_CODE,
    OWNER_DELEGATE,
    OWNER_DELEGATE_CODEHASH
} from "./LaunchConfig.sol";
import {PostflightChecks} from "./PostflightChecks.sol";

interface ISupply {
    function supply() external view returns (uint256);
}

interface IKeyRegistry {
    function keyCount() external view returns (uint256);
}

interface IFeeControllerV2 {
    function burnRouter() external view returns (address);
    function treasury() external view returns (address);
}

/// @notice the read only checks run before a launch (`preflight`) and after it (`postflight`). they only read state,
/// so they are safe to run against mainnet at any time
abstract contract LaunchChecks is PostflightChecks {
    /// @dev the per transaction gas cap of the target chain (EIP 7825, 2^24). the launch is simulated with what is left of
    /// it, so a launch that does not fit fails the simulation row, and a collision cannot burn more than that
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    /// @dev the gas budget for the twelve deploy transactions, including both linked libraries. the frozen candidate
    /// rehearsal must measure the total again; `test/Rehearsal.t.sol` asserts that it stays under this budget
    uint256 internal constant DEPLOY_GAS_ESTIMATE = 22_000_000;
    /// @dev the coin supply of the launch. test/Config.t.sol checks the config against it
    uint256 internal constant COIN_SUPPLY = 1_000_000_000e18;
    /// @dev the byte caps of the coin's `image` and `description` (`ArtCoinsTokenV2.MAX_IMAGE_BYTES` and
    /// `MAX_DESCRIPTION_BYTES`, the factory reverts above them)
    uint256 internal constant MAX_IMAGE_BYTES = 2048;
    uint256 internal constant MAX_DESCRIPTION_BYTES = 4096;
    /// @dev the name of the metadata row. test/Config.t.sol and test/Rehearsal.t.sol compare against it
    string internal constant METADATA_ROW = "rule: image and description are empty or real values, not placeholders";
    /// @dev the text the rehearsal config holds in `image` and `description`. on chain id 1 the metadata row fails for a
    /// non empty value that is only whitespace (spaces, tabs, newlines, carriage returns, NBSP), that contains
    /// `placeholder` in any letter case, or is `todo` or `tbd`, and for a non empty `image` that does not start with a
    /// lowercase `ipfs://`, `https://`, `ar://` or `data:` scheme with content past it and no surrounding whitespace
    string internal constant PLACEHOLDER_MARKER = "PLACEHOLDER";
    // the pinned launch rules (docs/RUNBOOK.md section 2). a value outside them fails preflight. the three overrides in
    // the config file open exactly the rules that say so, and are part of the config hash
    uint24 internal constant PIN_BASELINE_SKIM = 690;
    uint16 internal constant PIN_BOUNTY_BPS = 9000;
    /// @dev the most the launch pays the factory. a fee above it is a factory state change the signed config never saw
    uint256 internal constant PIN_DEPLOY_FEE_MAX = 0.1 ether;
    /// @dev the pinned build: the keccak256 of the runtime code of each production artifact in `out/`, the immutable slots
    /// and both library address slots zeroed (the mask of `artifactHash`), and the keccak256 of both library creation
    /// codes. computed from the sources at the frozen candidate recorded in the freeze table of docs/STATUS.md. a change of a
    /// production contract on purpose updates these in the same commit as the sizes of test/BuildIdentity.t.sol
    bytes32 internal constant BUILD_HASH_CORE = 0x81181a41500dd286fb11c16f949cc7dc75913ad4500ce087c5b7e1d8fa0e9e3e;
    bytes32 internal constant BUILD_HASH_CORELIB = 0xdb52c68a102911882c83712ff22b35c9282c613442ea4e7ae1f5ad83dacd9d82;
    bytes32 internal constant BUILD_HASH_COREOPSLIB =
        0x3e6f70200864a45e22ec7242fa57a0412dc5ee8c0d7a97fbfa9fba0f410c9b1e;
    bytes32 internal constant BUILD_HASH_CONTROLLER =
        0x03359cd845473b5053e5d0c46b7ad1b388b4d9a06b6318e0e46f5be449a8b98b;
    bytes32 internal constant BUILD_HASH_SEAPORT_ADAPTER =
        0xf5c8fd4b675f717f11908ff47d000431035956c15a5f38d74b63a3d40310d30c;
    bytes32 internal constant BUILD_HASH_STRATEGY_ADAPTER =
        0xa17a41dc8c02dcbab13b02cd12d9b460efa6f8df6587144ea47d24c67da04a38;
    bytes32 internal constant BUILD_HASH_RENDERER = 0x789770d6ad6b21255e6aa816a264650ed079691ad3ee36359a2972b75b7d9be9;
    /// @dev the phase 2 artifacts (ControllerV2, Phase2BalanceTreasury, ProRataRedemptionPolicy), pinned the same way.
    /// none of them is part of the launch deployment; the phase 2 deploy and readback scripts compare against them
    bytes32 internal constant BUILD_HASH_CONTROLLER_V2 =
        0x711de842ffd952f36ffae03d261a92d339c1cf3efa0b7b0441bdd9c8a263644e;
    bytes32 internal constant BUILD_HASH_PHASE2_TREASURY =
        0xbf53bfbc3d964c1506556712022a4fe9e31ec523d65cef37b69f2d984fb4fe44;
    bytes32 internal constant BUILD_HASH_PRO_RATA_POLICY =
        0x5f6faabee10ccfb5ac36719d4cad193d7dc70ca4c56946cdf6dc6fa919ccf2ae;
    /// @dev the phase 3 artifacts (ControllerV3, BalanceTreasuryV2, ProRataRedeemer, MarketRedeemer), pinned the same way
    bytes32 internal constant BUILD_HASH_CONTROLLER_V3 =
        0xc8d6e17e5dc91f96ae94eb9fb717545de83d7b632523f36f11f1f7f914090c82;
    bytes32 internal constant BUILD_HASH_TREASURY_V2 =
        0x1626384252b77cd4080b76915fa46f77ca56d219c6fc28af48b7c247460fcd22;
    bytes32 internal constant BUILD_HASH_PRO_RATA_REDEEMER =
        0x6b3fd5f451dbdabb462a8a663f1fc25dc2e351353124578fb6cc2d45f2d8097d;
    bytes32 internal constant BUILD_HASH_MARKET_REDEEMER = 0x0db377f228014847f589654f557474af5a15481e9307752ff7e32a1be860c475;
    bytes32 internal constant BUILD_CREATION_HASH_CORELIB =
        0x78ce8391ad8231ed4eb1cc80a783918ce33ae558b72a28558bb20014f96c46c8;
    bytes32 internal constant BUILD_CREATION_HASH_COREOPSLIB =
        0x38d25f5c67998d7e8ca2c117217bfa94f499cf77dfddf8c84a5fda1a2718c829;
    /// @dev the bound of `settings.payeePpm` (`SettingsBounds`), restated so the launch rule row names it
    uint24 internal constant PAYEE_MAX_PPM = 1_000_000;
    uint24 internal constant PIN_SNIPER_START = 6_900;
    uint32 internal constant PIN_SNIPER_SECONDS = 4_140;
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    /// @dev the v2 hook address carries its permission flags in the low 14 bits: beforeInitialize, beforeAddLiquidity,
    /// beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta (0x28CC, v2 `DeployV2Lib`)
    uint160 internal constant HOOK_FLAG_MASK = 0x3FFF;
    uint160 internal constant HOOK_FLAGS = 0x28CC;
    /// @dev the factory error `Deprecated()`: the first statement of the factory's `_launch` reverts with it for every
    /// caller but the owner while `deprecated` is true
    bytes4 internal constant DEPRECATED_SELECTOR = bytes4(keccak256("Deprecated()"));
    int24 internal constant MAX_TICK = 887_272;
    /// @dev v4 limit of the tick spacing
    int24 internal constant MAX_TICK_SPACING = 32_767;
    /// @dev supplies at block 26158000. both only grow
    uint256 internal constant CREDITS_SUPPLY_MIN = 122_154;
    uint256 internal constant STATEMENTS_SUPPLY_MIN = 176;

    /// @dev STACK=master runs the preflight and postflight against the master stack fork, whose owner is an anvil
    /// account with no production 7702 delegation. the owner delegation rows are mainnet security pins, so they drop
    /// to info rows on the fork
    function _master() internal view returns (bool) {
        return keccak256(bytes(vm.envOr("STACK", string("")))) == keccak256("master");
    }

    /// @notice runs every preflight check and records it in the report
    function preflight(LaunchConfig memory c, address deployer) internal {
        _reset();
        _preConfig(c);
        _preRules(c, deployer);
        _preCode(c);
        _preBuild();
        _preLibrary();
        _preStack(c);
        _preFactory(c, deployer);
        _preOwner(c);
        _prePredictions(c, deployer);
        _preSeaportRecipients(c, deployer);
        _preLive();
        _preSignoff(c, deployer);
    }

    /// @notice the checks of `Resume.s.sol` before it sends missing steps. prediction rows are left out after the Core
    /// is deployed; the current owner delegation, delegate code and key registry are checked again
    function preflightResume(LaunchConfig memory c, address deployer) internal {
        _reset();
        _preConfig(c);
        _preRules(c, deployer);
        _preCode(c);
        _preBuild();
        _preStack(c);
        _preFactory(c, deployer);
        _preOwner(c);
        _preLive();
    }

    function _preConfig(LaunchConfig memory c) private {
        _eq("chain id", block.chainid, 1);
        string[] memory unset = unsetFields(c);
        string memory names;
        for (uint256 i; i < unset.length; ++i) {
            names = i == 0 ? unset[i] : string.concat(names, ",", unset[i]);
        }
        _check(
            "placeholders filled", unset.length == 0, unset.length == 0 ? "owner creator name symbol salt set" : names
        );
        _check(
            "rateStart in bounds and at most rateCap",
            rateInBounds(c),
            string.concat("rateStart ", vm.toString(c.rateStart), " rateCap ", vm.toString(c.settings.rateCap))
        );
        _check(
            "rateCap is 3 times rateStart",
            c.settings.rateCap == 3 * c.rateStart,
            string.concat(
                "rateStart ",
                vm.toString(c.rateStart),
                " rateCap ",
                vm.toString(c.settings.rateCap),
                " ratio x10000 ",
                c.rateStart == 0 ? "n/a" : vm.toString(uint256(c.settings.rateCap) * 10_000 / c.rateStart)
            )
        );
        bytes32 bad = settingsViolation(c);
        _check(
            "settings inside the bounds",
            bad == 0,
            bad == 0 ? "every field of the settings block" : string(abi.encodePacked("out of bounds: ", bad))
        );
        bytes32 badSale = saleViolation(c);
        _check(
            "sale settings inside the bounds",
            badSale == 0,
            badSale == 0
                ? "markupBps startCapBps decayHours anchorHalfLife anchorMinCost, reference referenceStepBps tolBps"
                : string(abi.encodePacked("out of bounds: ", badSale))
        );
        // the reference price settings (decision 154): tolBps and referenceMinSeconds are launch values, the other three
        // are owner inputs set once the balance token pool exists and its depth is known. at 0 the reference price is
        // unusable, so value mode fails closed to NoQuote; the launch keeps value mode off, so the row warns and never fails
        _warn(
            "warn: reference price inputs pending the balance token pool",
            c.quote.referenceRateBpsPerHour != 0 && c.quote.referenceStepBps != 0 && c.quote.referenceMaxStale != 0
                && c.quote.minLiquidity != 0,
            string.concat(
                "tolBps ",
                vm.toString(c.quote.tolBps),
                "; referenceRateBpsPerHour ",
                vm.toString(c.quote.referenceRateBpsPerHour),
                " referenceStepBps ",
                vm.toString(c.quote.referenceStepBps),
                " referenceMaxStale ",
                vm.toString(c.quote.referenceMaxStale),
                " referenceMinSeconds ",
                vm.toString(c.quote.referenceMinSeconds),
                " minLiquidity ",
                vm.toString(c.quote.minLiquidity),
                " are set with setQuote before the switch; valueModeOn ",
                c.settings.valueModeOn ? "true" : "false"
            )
        );
        bytes32 badCredit = creditViolation(c);
        _check(
            "credit settings inside the bounds",
            badCredit == 0,
            badCredit == 0
                ? "creditCostToPotBps creditWindow creditStartBps (creditSpreadBps at least max(200, loop bound))"
                : string(abi.encodePacked("out of bounds: ", badCredit))
        );
        _eq("supply equals the launch coin supply", c.supply, COIN_SUPPLY);
    }

    /// @dev the pinned rules. each is one row, so a failure names the rule
    function _preRules(LaunchConfig memory c, address deployer) private {
        _ruleTicks(c);
        _ruleEconomics(c);
        _ruleSniper(c);
        _ruleLaunch(c);
        _rulePeople(c, deployer);
    }

    /// @dev the coin and payee values that are pinned or bounded (docs/DECISIONS.md 10.6): restricted with the Core as the only
    /// listed account, the payee share bound
    function _ruleLaunch(LaunchConfig memory c) private {
        _check(
            "rule: coin is restricted with no extra allowlist entry",
            c.restricted && c.allowed.length == 0,
            string.concat("restricted ", c.restricted ? "yes" : "no", " extra entries ", vm.toString(c.allowed.length))
        );
        bool payeeOk = c.settings.payeePpm <= PAYEE_MAX_PPM;
        _check(
            "rule: payee share is inside its bound",
            payeeOk,
            string.concat("payee ppm ", vm.toString(c.settings.payeePpm))
        );
    }

    function _ruleTicks(LaunchConfig memory c) private {
        int24 sp = c.stack.tickSpacing;
        bool spOk = sp > 0 && sp <= MAX_TICK_SPACING;
        _check("rule: tick spacing in 1 to 32767", spOk, vm.toString(int256(sp)));
        _check("rule: pool fee is the dynamic fee flag", c.stack.poolFee == DYNAMIC_FEE_FLAG, "0x800000");
        _check(
            "rule: position lower equals the start tick",
            c.positionLower == c.startTick,
            string.concat("start ", vm.toString(int256(c.startTick)), " lower ", vm.toString(int256(c.positionLower)))
        );
        // the highest multiple of the spacing at or below the max usable tick
        int24 top = spOk ? (MAX_TICK / sp) * sp : int24(0);
        _check(
            "rule: position upper is the highest usable tick",
            spOk && c.positionUpper == top,
            string.concat("upper ", vm.toString(int256(c.positionUpper)), " want ", vm.toString(int256(top)))
        );
        _check(
            "rule: ticks are multiples of the spacing",
            spOk && c.startTick % sp == 0 && c.positionLower % sp == 0 && c.positionUpper % sp == 0,
            "start tick, position lower, position upper"
        );
        _check("rule: position lower below upper", c.positionLower < c.positionUpper, "range is not empty");
    }

    function _ruleEconomics(LaunchConfig memory c) private {
        _eq("rule: baseline skim bps is 690", uint256(c.baselineSkimBps), PIN_BASELINE_SKIM);
        bool bountyOk = c.bountyBps == PIN_BOUNTY_BPS || (c.allowBounty && c.bountyBps <= 9999);
        _check(
            "rule: bounty bps is 9000",
            bountyOk,
            string.concat("bounty ", vm.toString(c.bountyBps), c.allowBounty ? " (override on)" : "")
        );
    }

    function _ruleSniper(LaunchConfig memory c) private {
        _eq("rule: sniper start bps is 6900", uint256(c.sniperStartBps), PIN_SNIPER_START);
        _eq("rule: sniper seconds is 4140", uint256(c.sniperSeconds), PIN_SNIPER_SECONDS);
        _check(
            "rule: settings.sniperSeconds equals launch.sniperSeconds",
            c.settings.sniperSeconds == c.sniperSeconds,
            string.concat("settings ", vm.toString(c.settings.sniperSeconds), " launch ", vm.toString(c.sniperSeconds))
        );
    }

    function _rulePeople(LaunchConfig memory c, address deployer) private {
        address[3] memory who = [c.owner, c.creator, c.payee];
        bool bad;
        for (uint256 i; i < 3; ++i) {
            address a = who[i];
            if (a == address(0)) continue; // the placeholder row reports it
            bad = bad || a == Mainnet.DEAD || a == c.stack.poolManager || a == c.stack.hook || a == c.stack.factory
                || a == c.stack.locker || a == c.stack.escrow || a == c.mevModule;
        }
        _check("rule: owner, creator and payee are not dead or stack addresses", !bad, "dead, stack, mev module");
        _check(
            "rule: image at most 2048 bytes, description at most 4096 bytes",
            bytes(c.image).length <= MAX_IMAGE_BYTES && bytes(c.description).length <= MAX_DESCRIPTION_BYTES,
            string.concat(
                "image ",
                vm.toString(bytes(c.image).length),
                " bytes description ",
                vm.toString(bytes(c.description).length),
                " bytes"
            )
        );
        (bool metaOk, string memory filledDetail) = _metadataRow(c.image, c.description);
        string memory filledName = METADATA_ROW;
        if (block.chainid == 1) _check(filledName, metaOk, filledDetail);
        else _warn(filledName, metaOk, filledDetail);
        bool set = c.owner != address(0) && c.creator != address(0);
        _warn("warn: owner differs from creator", !set || c.owner != c.creator, "one party takes both roles");
        deployer;
    }

    /// @notice whether `image` and `description` pass the metadata row. the coin renderer draws the image and reads the
    /// description from the coin, so each may be empty. a non empty value must not be blank after trimming or hold a
    /// placeholder marker, and a non empty `image` must start with a known scheme. the deploy test, the rehearsal and the
    /// preflight share this one rule
    function metadataRowPasses(string memory image, string memory description) public view returns (bool) {
        (bool ok,) = _metadataRow(image, description);
        return ok;
    }

    /// @dev the detail names the first reason the row fails
    function _metadataRow(string memory image, string memory description)
        private
        view
        returns (bool ok, string memory detail)
    {
        bool blankValue =
            (bytes(image).length != 0 && _blank(image)) || (bytes(description).length != 0 && _blank(description));
        bool marked = _marked(image) || _marked(description);
        bool scheme = bytes(image).length == 0 || _hasScheme(image);
        ok = !blankValue && !marked && scheme;
        detail = blankValue
            ? "a value is only whitespace: leave it empty or fill it"
            : marked
                ? "a value contains placeholder or is todo or tbd"
                : !scheme
                    ? "image must be empty or start with a lowercase ipfs://, https://, ar:// or data: scheme with content past it and no surrounding whitespace"
                    : "empty or set in the launch transaction";
    }

    /// @dev true when `s` is empty or trims to nothing. `vm.trim` strips spaces, tabs, newlines, carriage returns and
    /// NBSP. a value whose only content after trim is a zero width character (U+200B and the like) is not caught and
    /// stays the admin's to repair with `updateImage` and `updateDescription`
    function _blank(string memory s) private pure returns (bool) {
        return bytes(vm.trim(s)).length == 0;
    }

    /// @dev true when `s` contains `placeholder` in any letter case, or is `todo` or `tbd` after trimming. the short
    /// markers match the whole value, so a real ipfs cid that holds the letters is accepted
    function _marked(string memory s) private view returns (bool) {
        string memory l = vm.trim(vm.toLowercase(s));
        return vm.contains(l, "placeholder") || keccak256(bytes(l)) == keccak256("todo")
            || keccak256(bytes(l)) == keccak256("tbd");
    }

    /// @dev true when `s` starts with a lowercase `ipfs://`, `https://`, `ar://` or `data:` scheme, holds at least one
    /// byte past the scheme, and carries no surrounding whitespace, so a scheme with no content (for example `ipfs://`)
    /// is refused. the match is on the raw bytes that go on chain: an upper case scheme or leading whitespace is
    /// refused, and `http://` is refused
    function _hasScheme(string memory s) private view returns (bool) {
        if (keccak256(bytes(s)) != keccak256(bytes(vm.trim(s)))) return false;
        bytes memory b = bytes(s);
        return _startsPastPrefix(b, "ipfs://") || _startsPastPrefix(b, "https://") || _startsPastPrefix(b, "ar://")
            || _startsPastPrefix(b, "data:");
    }

    function _startsPastPrefix(bytes memory b, bytes memory p) private pure returns (bool) {
        if (b.length <= p.length) return false;
        for (uint256 i; i < p.length; ++i) {
            if (b[i] != p[i]) return false;
        }
        return true;
    }

    /// @dev the owner account is an EIP 7702 delegation. the delegation code, the delegate code hash and an empty key
    /// registry are pinned, so only the owner key acts as the owner. a redelegation after this run is not covered
    function _preOwner(LaunchConfig memory c) private {
        if (_master()) {
            _info(
                "owner: master stack fork, the owner is an anvil account with no production delegation",
                string.concat(vm.toString(c.owner), " code ", vm.toString(c.owner.code))
            );
            return;
        }
        _check(
            "owner: code is the pinned EIP 7702 delegation",
            keccak256(c.owner.code) == keccak256(OWNER_DELEGATION_CODE),
            string.concat(vm.toString(c.owner), " code ", vm.toString(c.owner.code))
        );
        bytes32 got = OWNER_DELEGATE.code.length == 0 ? bytes32(0) : OWNER_DELEGATE.codehash;
        _eq("owner: delegate code hash is the pinned Calibur", got, OWNER_DELEGATE_CODEHASH);
        (bool ok, uint256 n) = _word(c.owner, abi.encodeCall(IKeyRegistry.keyCount, ()));
        _check("owner: no registered keys", ok && n == 0, string.concat("keyCount ", vm.toString(n)));
    }

    function _preCode(LaunchConfig memory c) private {
        // the hook, factory, locker, escrow and mev module have a code hash row each (`_preStackCode`)
        _code("code: pool manager", c.stack.poolManager);
        _code("code: Credits", Mainnet.CREDITS);
        _code("code: Statements", Mainnet.STATEMENTS);
        _code("code: CreditStrategy", Mainnet.CREDIT_STRATEGY);
        _code("code: Seaport", Mainnet.SEAPORT);
        _code("code: Permit2", Mainnet.PERMIT2);
        _code("code: position manager", Mainnet.POSITION_MANAGER);
        _code("code: universal router", Mainnet.UNIVERSAL_ROUTER);
    }

    /// @dev the local `out/` artifacts against the pinned build. the system is created from the compiled tree and the
    /// postflight compares the chain with `out/`, so a modified tree or a stale `out/` fails here before anything is sent
    function _preBuild() private {
        _pinBuild("Core", BUILD_HASH_CORE);
        _pinBuild("CoreLib", BUILD_HASH_CORELIB);
        _pinBuild("CoreOpsLib", BUILD_HASH_COREOPSLIB);
        _pinBuild("ControllerV1", BUILD_HASH_CONTROLLER);
        _pinBuild("SeaportBasicAdapter", BUILD_HASH_SEAPORT_ADAPTER);
        _pinBuild("CreditStrategyAdapter", BUILD_HASH_STRATEGY_ADAPTER);
        _pinBuild("LogoCoinRenderer", BUILD_HASH_RENDERER);
        bytes32 got = keccak256(vm.getCode("CoreLib.sol:CoreLib"));
        _check(
            "build: CoreLib creation code hash equals the pinned build",
            got == BUILD_CREATION_HASH_CORELIB,
            vm.toString(got)
        );
        got = keccak256(vm.getCode("CoreOpsLib.sol:CoreOpsLib"));
        _check(
            "build: CoreOpsLib creation code hash equals the pinned build",
            got == BUILD_CREATION_HASH_COREOPSLIB,
            vm.toString(got)
        );
    }

    function _pinBuild(string memory name, bytes32 want) private {
        bytes32 got = artifactHash(name);
        _check(
            string.concat("build: ", name, " runtime code hash equals the pinned build"),
            got == want,
            string.concat("out/ ", vm.toString(got))
        );
    }

    /// @dev the linked libraries. a deployed copy at its create2 address is the compiled code by construction (the address
    /// is the hash of the creation code), the row says so and reads the code anyway
    function _preLibrary() private {
        _code("code: deterministic deployer", CREATE2_DEPLOYER);
        address lib = libraryAddress();
        bool deployed = lib.code.length != 0;
        _check(
            "library: CoreLib at its create2 address is the compiled code or absent",
            !deployed || isCompiledLibrary(lib.code),
            string.concat(
                vm.toString(lib),
                deployed ? " on chain, the broadcast skips it" : " not deployed, the first transaction deploys it"
            )
        );
        address ops = opsLibraryAddress();
        bool opsDeployed = ops.code.length != 0;
        _check(
            "library: CoreOpsLib at its create2 address is the compiled code or absent",
            !opsDeployed || isCompiledOpsLibrary(ops.code),
            string.concat(
                vm.toString(ops),
                opsDeployed ? " on chain, the broadcast skips it" : " not deployed, the next transaction deploys it"
            )
        );
    }

    /// @dev the Core is the only contract of the deploy whose address depends on the sender. the other contracts are
    /// created when they have no code, so a copy that is there already is the same code. the coin comes from the
    /// factory's own `predictToken` for the deployer and the full config with the Core as bounty recipient, read through
    /// a call that cannot revert here
    function _prePredictions(LaunchConfig memory c, address deployer) private {
        address coreAt = coreAddress(c, deployer);
        _noCode("predicted core is empty", coreAt);
        _noCode("predicted renderer is empty", rendererAddress(c));
        (bool ok, address coinAt) = _predict(c, deployer, coreAt);
        _check(
            "predicted coin is empty",
            ok && coinAt.code.length == 0,
            ok ? string.concat(vm.toString(coinAt), " code ", vm.toString(coinAt.code.length)) : "predictToken failed"
        );
    }

    /// @dev the Seaport adapter takes the list at construction and the lock freezes additions, so an entry is a permanent
    /// payout address. none may be zero, repeated, or an address of the system (Core, controller, owner, payee, stack)
    function _preSeaportRecipients(LaunchConfig memory c, address deployer) private {
        address coreAt = coreAddress(c, deployer);
        Stack memory s = c.stack;
        address[9] memory system = [
            coreAt, controllerAddress(coreAt, c), c.owner, c.payee, s.poolManager, s.hook, s.factory, s.locker, s.escrow
        ];
        address[] memory r = c.seaportRecipients;
        bool zero;
        bool dup;
        bool sys;
        for (uint256 i; i < r.length; ++i) {
            zero = zero || r[i] == address(0);
            for (uint256 j; j < i; ++j) {
                dup = dup || r[i] == r[j];
            }
            for (uint256 k; k < system.length; ++k) {
                sys = sys || r[i] == system[k];
            }
        }
        _check("seaport recipients: at least one", r.length != 0, vm.toString(r.length));
        _check("seaport recipients: none is the zero address", !zero, "a zero entry pays nobody");
        _check("seaport recipients: no duplicates", !dup, "each entry once");
        _check(
            "seaport recipients: none is the Core, controller, owner, payee or a stack address",
            !sys,
            "see the signoff list"
        );
    }

    /// @dev the hook, locker, mev module and escrow checked against each other and against the stack of the config
    function _preStack(LaunchConfig memory c) private {
        Stack memory s = c.stack;
        _check(
            "hook: address carries the v2 permission flags",
            uint160(s.hook) & HOOK_FLAG_MASK == HOOK_FLAGS,
            vm.toString(s.hook)
        );
        (bool ok, address a) = _addr(s.hook, abi.encodeCall(IArtCoinsHookV2.poolManager, ()));
        _check("hook: reports the pool manager", ok && a == s.poolManager, vm.toString(a));
        _eq("hook: reports the fee escrow", _hookGlobals(s.hook).feeEscrow, s.escrow);
        bool b;
        (ok, b) = _bool(s.hook, abi.encodeCall(IArtCoinsHookV2.isLauncher, (s.factory)));
        _check("hook: the factory is a launcher", ok && b, "isLauncher(factory)");
        (ok, b) = _bool(s.locker, abi.encodeCall(IArtCoinsLpLockerV2.isLauncher, (s.factory)));
        _check("locker: the factory is a launcher", ok && b, "isLauncher(factory)");
        (ok, a) = _addr(c.mevModule, abi.encodeCall(IArtCoinsMevSkimV2.hook, ()));
        _check("mev: module is bound to the hook", ok && a == s.hook, vm.toString(a));
        (ok, b) = _bool(s.escrow, abi.encodeCall(IArtCoinsFeeEscrowV2.isCoreDepositor, (s.hook)));
        _check("escrow: the hook is a core depositor", ok && b, "isCoreDepositor(hook)");
        address controller_;
        (, controller_) = _addr(s.factory, abi.encodeCall(IArtCoinsFactoryV2.protocolRecipient, ()));
        (ok, b) = _bool(s.escrow, abi.encodeCall(IArtCoinsFeeEscrowV2.isDepositor, (controller_)));
        _check("escrow: the protocol fee controller is a depositor", ok && b, "isDepositor(controller)");
        _preStackVersion(c);
        _preStackCode(c);
    }

    /// @dev the runtime code hash of each live v2 contract the launch reaches, against the hashes read from the live
    /// stack at `V2_PIN_BLOCK`: the five contracts of the config, the token deployer and protocol recipient the factory
    /// points at, the extension allowlist of the hook and the burn router of the fee controller
    function _preStackCode(LaunchConfig memory c) private {
        Stack memory s = c.stack;
        (, address deployer_) = _addr(s.factory, abi.encodeCall(IArtCoinsFactoryV2.tokenDeployer, ()));
        (, address controller) = _addr(s.factory, abi.encodeCall(IArtCoinsFactoryV2.protocolRecipient, ()));
        (, address router) = _addr(controller, abi.encodeCall(IFeeControllerV2.burnRouter, ()));
        _pin("hook", s.hook, V2_CODEHASH_HOOK);
        _pin("factory", s.factory, V2_CODEHASH_FACTORY);
        _pin("locker", s.locker, V2_CODEHASH_LOCKER);
        _pin("escrow", s.escrow, V2_CODEHASH_ESCROW);
        _pin("mev module", c.mevModule, V2_CODEHASH_MEV_MODULE);
        _pin("token deployer", deployer_, V2_CODEHASH_TOKEN_DEPLOYER);
        _pin("extension allowlist", _hookGlobals(s.hook).extensionAllowlist, V2_CODEHASH_ALLOWLIST);
        _pin("protocol fee controller", controller, V2_CODEHASH_FEE_CONTROLLER);
        // the treasury is owner settable on the controller; the record holds the value read at the pin
        (, address treasury) = _addr(controller, abi.encodeCall(IFeeControllerV2.treasury, ()));
        bool master = keccak256(bytes(vm.envOr("STACK", string("")))) == keccak256("master");
        address want = master ? c.owner : vm.parseJsonAddress(vm.readFile("script/config/v2-mainnet.json"), ".treasury");
        _eq("protocol fee controller: treasury is the recorded treasury", treasury, want);
        _pin("burn router", router, V2_CODEHASH_BURN_ROUTER);
    }

    function _pin(string memory name, address who, bytes32 want) private {
        bytes32 got = who.code.length == 0 ? bytes32(0) : who.codehash;
        _check(
            string.concat("code hash: ", name, " is the live v2 contract"),
            got == want,
            string.concat(vm.toString(who), " ", vm.toString(got), " pinned at block ", vm.toString(V2_PIN_BLOCK))
        );
    }

    /// @dev the stack version of the factory and the constants hash of the stack: the hook reports `V2_CONSTANTS_HASH`
    /// and the hook, factory, locker, escrow and mev module report the same hash
    function _preStackVersion(LaunchConfig memory c) private {
        Stack memory s = c.stack;
        (bool ok, uint256 v) = _word(s.factory, abi.encodeCall(IArtCoinsFactoryV2.STACK_VERSION, ()));
        _check("factory: STACK_VERSION is 2", ok && v == 2, string.concat("STACK_VERSION ", vm.toString(v)));
        bytes memory q = abi.encodeCall(IArtCoinsHookV2.constantsHash, ());
        (bool okh, uint256 h) = _word(s.hook, q);
        _check(
            "v2: hook constantsHash equals the pinned live value",
            okh && bytes32(h) == V2_CONSTANTS_HASH,
            string.concat("hook ", vm.toString(bytes32(h)), " pinned ", vm.toString(V2_CONSTANTS_HASH))
        );
        address[4] memory rest = [s.factory, s.locker, s.escrow, c.mevModule];
        bool same = okh;
        for (uint256 i; i < rest.length; ++i) {
            (bool okr, uint256 r) = _word(rest[i], q);
            same = same && okr && r == h;
        }
        _check(
            "v2: constantsHash is equal across hook, factory, locker, escrow and mev module", same, "constantsHash()"
        );
    }

    /// @dev the v2 factory: who may launch, what is enabled, the fees and floors the config meets, and a simulated launch
    function _preFactory(LaunchConfig memory c, address deployer) private {
        address fa = c.stack.factory;
        (bool ok, address a) = _addr(fa, abi.encodeCall(IArtCoinsFactoryV2.owner, ()));
        _check("factory: owner is the config owner", ok && a == c.owner, string.concat("owner ", vm.toString(a)));
        _check("factory: owner is the deployer", ok && a == deployer, string.concat("owner ", vm.toString(a)));
        bool b;
        (ok, b) = _bool(fa, abi.encodeCall(IArtCoinsFactoryV2.deprecated, ()));
        _check(
            "factory: deprecated, only the owner can launch",
            ok && (b || c.allowOpenFactory),
            string.concat("deprecated ", b ? "yes" : "no", c.allowOpenFactory ? " (override on)" : "")
        );
        (ok, a) = _addr(fa, abi.encodeCall(IArtCoinsFactoryV2.poolManager, ()));
        _check("factory: reports the pool manager", ok && a == c.stack.poolManager, vm.toString(a));
        (ok, a) = _addr(fa, abi.encodeCall(IArtCoinsFactoryV2.tokenDeployer, ()));
        _check("factory: token deployer is set", ok && a.code.length != 0, vm.toString(a));
        _preEnabled(c);
        _preFees(c, deployer);
        _preSimulate(c, deployer);
    }

    function _preEnabled(LaunchConfig memory c) private {
        address fa = c.stack.factory;
        (bool ok, bool b) = _bool(fa, abi.encodeCall(IArtCoinsFactoryV2.enabledHooks, (c.stack.hook)));
        _check("factory: hook enabled", ok && b, "enabledHooks(hook)");
        (ok, b) = _bool(fa, abi.encodeCall(IArtCoinsFactoryV2.enabledLockers, (c.stack.locker)));
        _check("factory: locker enabled", ok && b, "enabledLockers(locker)");
        (ok, b) = _bool(fa, abi.encodeCall(IArtCoinsFactoryV2.enabledMevModules, (c.mevModule)));
        _check("factory: mev module enabled", ok && b, "enabledMevModules(module)");
    }

    /// @dev the fee knobs of the factory against the config: the deploy fee and the deployer balance. the protocol
    /// share on master is `10_000 - bountyBps` of the baseline skim, no factory floor sets it
    function _preFees(LaunchConfig memory c, address deployer) private {
        address fa = c.stack.factory;
        (bool ok, uint256 fee) = _word(fa, abi.encodeCall(IArtCoinsFactoryV2.deployFee, ()));
        uint256 need = fee + DEPLOY_GAS_ESTIMATE * block.basefee;
        _check(
            "deployer: balance covers the deploy fee and the gas",
            ok && deployer.balance >= need,
            string.concat("balance ", vm.toString(deployer.balance), " need ", vm.toString(need))
        );
        _check(
            "rule: the factory deploy fee is at most 0.1 ether",
            ok && fee <= PIN_DEPLOY_FEE_MAX,
            string.concat("fee ", vm.toString(fee), " (the master launch fee is 0)")
        );
        _preRecipients(c);
    }

    function _preRecipients(LaunchConfig memory c) private {
        address fa = c.stack.factory;
        (bool ok, address p) = _addr(fa, abi.encodeCall(IArtCoinsFactoryV2.protocolRecipient, ()));
        _check(
            "factory: protocol recipient set (the launcher protocol, not the engine owner)",
            ok && p != address(0),
            vm.toString(p)
        );
        (bool okf, uint256 fee) = _word(fa, abi.encodeCall(IArtCoinsFactoryV2.deployFee, ()));
        (ok, p) = _addr(fa, abi.encodeCall(IArtCoinsFactoryV2.teamFeeRecipient, ()));
        if (okf && fee != 0) {
            _check(
                "factory: the deploy fee goes to the config owner (team fee recipient)",
                ok && p == c.owner,
                string.concat("team fee recipient ", vm.toString(p), " owner ", vm.toString(c.owner))
            );
        } else {
            _info("factory: the deploy fee is zero, no team fee recipient check", vm.toString(p));
        }
    }

    /// @dev runs the launch as the factory owner on a snapshot and reverts the state again: the owner path works, the
    /// factory and the hook accept the config (bounds, minimums, enabled stack, mev values, recipients). the Core needs no
    /// code for it. the deployer gets the fee for the simulation only
    function _preSimulate(LaunchConfig memory c, address deployer) private {
        address coreAt = coreAddress(c, deployer);
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = buildConfig(c, c.owner, coreAt);
        (bool ok, address coin, uint256 gas, bytes memory why) = _simulateLaunch(c, deployer, cfg);
        _check(
            "factory: deployToken accepts the config (simulated)",
            ok,
            ok
                ? string.concat("coin ", vm.toString(coin), " launch gas ", vm.toString(gas))
                : string.concat("reverts with ", vm.toString(why))
        );
        _preDeprecatedGate(c, cfg);
    }

    /// @dev the deprecated state of the factory admits the owner and refuses every other caller. the owner half is the
    /// simulation above (`deployToken` by the owner reaches `_launch` while deprecated). the refusal half is a launch by
    /// an account that is not the owner through `deployToken`, which reverts with `Deprecated()` at the first statement
    /// of `_launch`, before any config validation
    function _preDeprecatedGate(LaunchConfig memory c, IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg) private {
        address fa = c.stack.factory;
        (bool ok, bool dep) = _bool(fa, abi.encodeCall(IArtCoinsFactoryV2.deprecated, ()));
        if (!ok) {
            _check("factory: deprecated() is readable", false, "the deprecated flag could not be read");
            return;
        }
        if (!dep) {
            _info("factory: not deprecated, no deprecated gate", "public launches are open");
            return;
        }
        (, uint256 fee) = _word(fa, abi.encodeCall(IArtCoinsFactoryV2.deployFee, ()));
        address stranger = address(uint160(uint256(keccak256("credits.preflight.stranger"))));
        uint256 snap = vm.snapshotState();
        vm.deal(stranger, fee);
        vm.prank(stranger);
        bytes memory out;
        (ok, out) = fa.call{value: fee, gas: TX_GAS_CAP - 21_000}(abi.encodeCall(IArtCoinsFactoryV2.deployToken, (cfg)));
        vm.revertToState(snap);
        bool refused = !ok && out.length == 4 && bytes4(out) == DEPRECATED_SELECTOR;
        _check(
            "factory: deprecated, the owner launches and any other caller reverts Deprecated()",
            refused,
            refused
                ? "deployToken by a stranger reverts Deprecated(). deployToken by the owner is the owner path (simulated above)"
                : string.concat("deployToken by a stranger ", ok ? "succeeded" : "reverted with ", vm.toString(out))
        );
    }

    /// @notice the launch on a snapshot. returns whether it passed, the coin, the execution gas and the revert data
    function _simulateLaunch(LaunchConfig memory c, address deployer, IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg)
        internal
        returns (bool ok, address coin, uint256 gas, bytes memory why)
    {
        (bool okf, uint256 fee) = _word(c.stack.factory, abi.encodeCall(IArtCoinsFactoryV2.deployFee, ()));
        if (!okf || c.stack.factory.code.length == 0) return (false, address(0), 0, "no factory");
        uint256 snap = vm.snapshotState();
        // the token config names the renderer, which the launch deploys before it. the simulation places its code
        address renderer = cfg.token.renderer;
        if (renderer.code.length == 0) vm.etch(renderer, vm.getDeployedCode("LogoCoinRenderer.sol:LogoCoinRenderer"));
        vm.deal(deployer, deployer.balance + fee);
        vm.prank(deployer);
        bytes memory out;
        (ok, out, gas) = _callLaunch(c, fee, cfg);
        if (ok && out.length >= 32) coin = abi.decode(out, (address));
        else why = out;
        vm.revertToState(snap);
    }

    function _callLaunch(LaunchConfig memory c, uint256 fee, IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg)
        private
        returns (bool ok, bytes memory out, uint256 gas)
    {
        bytes memory data = abi.encodeCall(IArtCoinsFactoryV2.deployToken, (cfg));
        uint256 g = gasleft();
        (ok, out) = c.stack.factory.call{value: fee, gas: TX_GAS_CAP - 21_000}(data);
        gas = g - gasleft();
    }

    function _preLive() private {
        (bool ok1, uint256 cs) = _word(Mainnet.CREDITS, abi.encodeCall(ISupply.supply, ()));
        _check("Credits supply", ok1 && cs >= CREDITS_SUPPLY_MIN, vm.toString(cs));
        (bool ok2, uint256 ss) = _word(Mainnet.STATEMENTS, abi.encodeCall(IStatements.supply, ()));
        _check("Statements supply", ok2 && ss >= STATEMENTS_SUPPLY_MIN, vm.toString(ss));
    }

    /// @dev the table the owner signs. every row restates one launch input in the words of what it does, then the hash
    /// of the whole config is the single value the deploy needs back in CONFIG_HASH
    function _preSignoff(LaunchConfig memory c, address deployer) private {
        address coreAt = coreAddress(c, deployer);
        _info("signoff: owner (core owner, token admin, factory owner)", vm.toString(c.owner));
        _info(
            "signoff: creator (named for the launch record, not a pool recipient; the pool charges no lp fee)",
            vm.toString(c.creator)
        );
        _info("signoff: deployer (sends the transactions, must be the factory owner)", vm.toString(deployer));
        _info("signoff: core address (the bounty recipient of the pool)", vm.toString(coreAt));
        _info(
            "signoff: other addresses",
            string.concat(
                "controller ",
                vm.toString(controllerAddress(coreAt, c)),
                " seaport adapter ",
                vm.toString(seaportAdapterAddress(coreAt, c.seaportRecipients)),
                " strategy adapter ",
                vm.toString(strategyAdapterAddress())
            )
        );
        _info(
            "signoff: payee (one address, owner replaces it later with setPayee)",
            string.concat(vm.toString(c.payee), " ppm ", vm.toString(c.settings.payeePpm), " of the fee income")
        );
        string memory list;
        for (uint256 i; i < c.seaportRecipients.length; ++i) {
            list = string.concat(list, i == 0 ? "" : " ", vm.toString(c.seaportRecipients[i]));
        }
        _info("signoff: seaport recipients (permanent payout addresses once the adapters are locked)", list);
        _info(
            "signoff: payee share",
            "starts at the first book with income after the anti sniper window, the recipients are not locked by the deploy"
        );
        _info(
            "signoff: opening bid",
            string.concat(
                "rateStart ",
                vm.toString(c.rateStart),
                " wei per 100 points, pointsPerPage ",
                vm.toString(c.settings.pointsPerPage),
                " (launch day rule: the market price of 100 points)"
            )
        );
        _info(
            "signoff: economics",
            string.concat(
                "skim ",
                vm.toString(c.baselineSkimBps),
                " bounty ",
                vm.toString(c.bountyBps),
                " sniper ",
                vm.toString(c.sniperStartBps),
                "->",
                vm.toString(c.baselineSkimBps),
                " over ",
                vm.toString(c.sniperSeconds),
                "s lp fee 0"
            )
        );
        _info(
            "signoff: protocol leg",
            "the protocol leg (10_000 minus bountyBps of the baseline skim, 0.69 percent of volume at bounty 9000) lands at the launcher protocol fee controller, a separate business from this engine and its owner"
        );
        _preSettingsRows(c);
        _info(
            "signoff: build (runtime code hashes of out/, slots masked)",
            string.concat(
                "Core ",
                vm.toString(BUILD_HASH_CORE),
                " CoreLib ",
                vm.toString(BUILD_HASH_CORELIB),
                " CoreOpsLib ",
                vm.toString(BUILD_HASH_COREOPSLIB),
                " ControllerV1 ",
                vm.toString(BUILD_HASH_CONTROLLER),
                " SeaportBasicAdapter ",
                vm.toString(BUILD_HASH_SEAPORT_ADAPTER),
                " CreditStrategyAdapter ",
                vm.toString(BUILD_HASH_STRATEGY_ADAPTER),
                " LogoCoinRenderer ",
                vm.toString(BUILD_HASH_RENDERER),
                " CoreLib creation ",
                vm.toString(BUILD_CREATION_HASH_CORELIB),
                " CoreOpsLib creation ",
                vm.toString(BUILD_CREATION_HASH_COREOPSLIB)
            )
        );
        _info("signoff: CONFIG_HASH", vm.toString(configHash(c)));
    }

    /// @dev the settings are adjustable by the owner after launch, so these rows print them for sign off
    function _preSettingsRows(LaunchConfig memory c) private {
        _info("signoff: bid", string.concat("rateCap ", vm.toString(c.settings.rateCap)));
        _info(
            "signoff: drop and climb",
            string.concat(
                "drop per 100 points ",
                vm.toString(c.settings.dropPer100PointsBps),
                " floor ",
                vm.toString(c.settings.dropFloorBps),
                " climb per minute ",
                vm.toString(c.settings.climbPerMinBps),
                " ceiling ",
                vm.toString(c.settings.ceilBps),
                " loosen per 10 minutes ",
                vm.toString(c.settings.idleLoosenBps),
                " (bps)"
            )
        );
        _info("signoff: statement sale", string.concat("saleFloorBps ", vm.toString(c.settings.saleFloorBps)));
        _info(
            "signoff: reserve and return lock",
            string.concat(
                "reserveWei ",
                vm.toString(c.settings.reserveWei),
                " (the reserve is the larger of it and 1.5 times the queued compose and redeem payments), returnLockSeconds ",
                vm.toString(c.settings.returnLockSeconds)
            )
        );
        _info(
            "signoff: credit swap",
            string.concat("swapFeeCc ", vm.toString(c.settings.swapFeeCc), " coin burned per swapCredit")
        );
        _info(
            "signoff: balance side",
            string.concat(
                "redeemOn ",
                c.settings.redeemOn ? "true" : "false",
                " balanceBidOn ",
                c.settings.balanceBidOn ? "true" : "false",
                " redeem slippage ",
                vm.toString(c.settings.redeemSlippageBps),
                " balance bid margin ",
                vm.toString(c.settings.balanceBidMarginBps),
                " redeem burn ",
                vm.toString(c.settings.redeemBurnBps),
                " fee to redeem burn ",
                vm.toString(c.settings.feeToRedeemBurnBps),
                " (bps)"
            )
        );
        _info(
            "signoff: splits",
            string.concat(
                "sale to buyback ",
                vm.toString(c.settings.saleToBuybackBps),
                " buyback slice ",
                vm.toString(c.settings.buybackSlice),
                " keeper fee ",
                vm.toString(c.settings.keeperFee),
                " keeper base fee ceiling ",
                vm.toString(c.settings.keeperMaxBaseFee)
            )
        );
        _info(
            "signoff: sale controller",
            string.concat(
                "markup ",
                vm.toString(c.sale.markupBps),
                " start cap ",
                vm.toString(c.sale.startCapBps),
                " falling in a straight line over ",
                vm.toString(c.sale.decayHours),
                " hours to saleFloorBps ",
                vm.toString(c.settings.saleFloorBps),
                " anchor half life ",
                vm.toString(c.sale.anchorHalfLife),
                "s, the anchor moves on statements costing at least ",
                vm.toString(c.sale.anchorMinCost),
                " wei"
            )
        );
        _info(
            "signoff: credit sale",
            string.concat(
                "sale ",
                c.credit.saleOn ? "on" : "off",
                " window ",
                vm.toString(c.credit.window),
                "s spread over the bid's hard cap ",
                vm.toString(c.credit.spreadBps),
                " start ",
                vm.toString(c.credit.startBps),
                " bps, cost to pot ",
                vm.toString(c.credit.costToPotBps),
                " bps, pointsPerPage ",
                vm.toString(c.settings.pointsPerPage)
            )
        );
        _info(
            "signoff: nft sale cuts",
            string.concat(
                "saleToArtistBps ",
                vm.toString(c.settings.saleToArtistBps),
                " to artist ",
                vm.toString(c.artist),
                ", saleToOperatorBps ",
                vm.toString(c.settings.saleToOperatorBps),
                " to the payee"
            )
        );
        _info(
            "signoff: chosen composition",
            string.concat(
                "chosen compose ",
                c.credit.chosenComposeOn ? "on" : "off",
                " min coin to choose ",
                vm.toString(uint256(c.credit.minCcToChoose)),
                " base units (1e18 is 1 coin)"
            )
        );
        _info("signoff: settings are adjustable", "the owner can change every setting at once after launch");
    }
}
