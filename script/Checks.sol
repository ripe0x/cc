// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VmSafe} from "forge-std/Vm.sol";
import {Stack, Mainnet, ICredits, ICreditScore, IStatements} from "../src/interfaces/Interfaces.sol";
import {IAuctionFactory} from "../src/interfaces/AuctionHouse.sol";
import {
    IArtCoinsFactoryV2,
    IArtCoinsHookV2,
    IArtCoinsLpLockerV2,
    IArtCoinsFeeEscrowV2,
    IArtCoinsMevSkimV2
} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {PostflightChecks} from "./PostflightChecks.sol";

interface ISupply {
    function supply() external view returns (uint256);
}

/// @notice the read only checks run before a launch (`preflight`) and after it (`postflight`). they only read state,
/// so they are safe to run against mainnet at any time
abstract contract LaunchChecks is PostflightChecks {
    /// @dev gas units of the six deploy transactions (the library, router, controller, core, launch, router setup) plus margin
    uint256 internal constant DEPLOY_GAS_ESTIMATE = 13_500_000;
    /// @dev the Core SUPPLY constant, the coin supply its exit auction is priced against. test/Config.t.sol checks it
    uint256 internal constant CORE_SUPPLY = 1_000_000_000e18;
    /// @dev credit 1 exists and its score is a pure function of its seed and timestamp
    uint256 internal constant KNOWN_CREDIT = 1;
    uint256 internal constant KNOWN_SCORE = 1_324_012;
    // the pinned launch rules (docs/DEPLOY.md section 2). a value outside them fails preflight. the three overrides in
    // the config file open exactly the rules that say so, and are part of the config hash
    uint24 internal constant PIN_BASELINE_SKIM = 6_900;
    uint16 internal constant PIN_BOUNTY_BPS = 9000;
    uint16 internal constant PIN_PROTOCOL_BPS = 2000;
    /// @dev the FeeRouter bounds (src/FeeRouter.sol), restated here so a bad config stops at preflight
    uint32 internal constant ROUTER_MAX_PAYEE_PPM = 200_000;
    uint32 internal constant ROUTER_MAX_TIP_PPM = 20_000;
    uint96 internal constant ROUTER_MAX_TIP_CAP = 0.05 ether;
    uint24 internal constant SNIPER_START_MIN = 50_000;
    uint24 internal constant SNIPER_START_MAX = 90_000;
    uint32 internal constant SNIPER_SECONDS_MIN = 600;
    uint32 internal constant SNIPER_SECONDS_MAX = 3600;
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    /// @dev the v2 hook address carries its permission flags in the low 14 bits: beforeInitialize, beforeAddLiquidity,
    /// beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta (0x28CC, v2 `DeployV2Lib`)
    uint160 internal constant HOOK_FLAG_MASK = 0x3FFF;
    uint160 internal constant HOOK_FLAGS = 0x28CC;
    int24 internal constant MAX_TICK = 887_272;
    /// @dev v4 limit of the tick spacing
    int24 internal constant MAX_TICK_SPACING = 32_767;
    /// @dev supplies at block 26127622. both only grow
    uint256 internal constant CREDITS_SUPPLY_MIN = 122_154;
    uint256 internal constant STATEMENTS_SUPPLY_MIN = 148;
    /// @dev the deterministic deployer that `forge script` sends the library through (CREATE2, salt zero)
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice true when running under `forge script`. a test overrides it to rehearse the script behaviour
    function _scriptContext() internal view virtual returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptGroup);
    }

    /// @notice the address `forge script` gives the linked library `CoreLib`: CREATE2 through the deterministic deployer,
    /// salt zero, the creation code of the compiled library. it depends on the compiler output only
    function libraryAddress() internal view returns (address) {
        return vm.computeCreate2Address(bytes32(0), keccak256(vm.getCode("CoreLib.sol:CoreLib")), CREATE2_DEPLOYER);
    }

    /// @notice whether the broadcast will send a library transaction before the controller. the library goes through the
    /// deterministic deployer as an ordinary transaction FROM THE DEPLOYER, so it takes one deployer nonce, but only
    /// when no code sits at its address yet (a deployed library is skipped). a test run deploys no library through
    /// the deterministic deployer, so it never takes a nonce there
    function _libraryTxPending() internal view returns (bool) {
        return _scriptContext() && libraryAddress().code.length == 0;
    }

    /// @notice the deployer nonce the controller will be created at: the live nonce plus the library transaction that
    /// still precedes it. inside `Deploy` the library is already on chain by the time `run` starts, so the live nonce
    /// already counts it. the core is created at this nonce plus one
    function _controllerNonce(address deployer) internal view returns (uint64) {
        return vm.getNonce(deployer) + (_libraryTxPending() ? 1 : 0);
    }

    /// @notice runs every preflight check and records it in the report
    function preflight(LaunchConfig memory c, address deployer) internal {
        _reset();
        _preConfig(c);
        _preRules(c, deployer);
        _preCode(c);
        _preLibrary();
        _preStack(c);
        _preFactory(c, deployer);
        _prePredictions(c, deployer);
        _preLive();
        _preSignoff(c, deployer);
    }

    /// @notice the checks of `Resume.s.sol` before it sends the missing steps. the prediction rows are left out (the
    /// addresses are taken by now) and the factory rows run only while the launch is still to be sent
    function preflightResume(LaunchConfig memory c, address deployer, bool launching) internal {
        _reset();
        _preConfig(c);
        _preRules(c, deployer);
        _preCode(c);
        _preStack(c);
        if (launching) _preFactory(c, deployer);
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
            badSale == 0 ? "buyOnly startBps stepBps stepEvery floorBps" : string(abi.encodePacked("out of bounds: ", badSale))
        );
        _warn(
            "warn: sale floor below the core hard floor",
            c.sale.floorBps >= c.settings.saleFloorBps,
            "the core floors every reserve and sale at saleFloorBps, so the lower asking price is never reached"
        );
        _eq("supply equals the Core SUPPLY constant", c.supply, CORE_SUPPLY);
    }

    /// @dev the pinned rules. each is one row, so a failure names the rule
    function _preRules(LaunchConfig memory c, address deployer) private {
        _ruleTicks(c);
        _ruleEconomics(c);
        _ruleSniper(c);
        _ruleLaunch(c);
        _rulePeople(c, deployer);
    }

    /// @dev the coin and router values that are pinned or bounded (docs/FLOW.md 10.6): restricted with the Core as the only
    /// listed account, the factory default protocol slot, the router bounds
    function _ruleLaunch(LaunchConfig memory c) private {
        _check(
            "rule: coin is restricted with no extra allowlist entry",
            c.restricted && c.allowed.length == 0,
            string.concat("restricted ", c.restricted ? "yes" : "no", " extra entries ", vm.toString(c.allowed.length))
        );
        _eq("rule: protocol bps is 2000", uint256(c.protocolBps), PIN_PROTOCOL_BPS);
        bool routerOk = c.payeePpm != 0 && c.payeePpm <= ROUTER_MAX_PAYEE_PPM && c.tipPpm <= ROUTER_MAX_TIP_PPM
            && c.tipCap <= ROUTER_MAX_TIP_CAP;
        _check(
            "rule: router payee share, tip and tip cap inside the router bounds",
            routerOk,
            string.concat(
                "payee ppm ",
                vm.toString(c.payeePpm),
                " tip ppm ",
                vm.toString(c.tipPpm),
                " tip cap ",
                vm.toString(c.tipCap)
            )
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
        _eq("rule: baseline skim bps is 6900", uint256(c.baselineSkimBps), PIN_BASELINE_SKIM);
        bool bountyOk = c.bountyBps == PIN_BOUNTY_BPS || (c.allowBounty && c.bountyBps <= 9999);
        _check(
            "rule: bounty bps is 9000",
            bountyOk,
            string.concat("bounty ", vm.toString(c.bountyBps), c.allowBounty ? " (override on)" : "")
        );
        _check(
            "rule: referral cap and lp fee are zero",
            c.maxReferralBps == 0 && c.lpFee == 0,
            string.concat("referral ", vm.toString(c.maxReferralBps), " lp fee ", vm.toString(c.lpFee))
        );
    }

    function _ruleSniper(LaunchConfig memory c) private {
        _check(
            "rule: sniper start bps in 50000 to 90000 and above the baseline",
            c.sniperStartBps >= SNIPER_START_MIN && c.sniperStartBps <= SNIPER_START_MAX
                && c.sniperStartBps > c.baselineSkimBps,
            vm.toString(c.sniperStartBps)
        );
        _check(
            "rule: sniper seconds in 600 to 3600",
            c.sniperSeconds >= SNIPER_SECONDS_MIN && c.sniperSeconds <= SNIPER_SECONDS_MAX,
            vm.toString(c.sniperSeconds)
        );
    }

    function _rulePeople(LaunchConfig memory c, address deployer) private {
        address[3] memory who = [c.owner, c.creator, c.creatorPayee];
        bool bad;
        for (uint256 i; i < 3; ++i) {
            address a = who[i];
            if (a == address(0)) continue; // the placeholder row reports it
            bad = bad || a == Mainnet.DEAD || a == c.stack.poolManager || a == c.stack.hook || a == c.stack.factory
                || a == c.stack.locker || a == c.stack.escrow || a == c.stack.auctionFactory || a == c.mevModule;
        }
        _check("rule: owner, creator and payees are not dead or stack addresses", !bad, "dead, stack, mev module");
        bool set = c.owner != address(0) && c.creator != address(0);
        _warn("warn: owner differs from creator", !set || c.owner != c.creator, "one party takes both roles");
        deployer;
    }

    function _preCode(LaunchConfig memory c) private {
        _code("code: pool manager", c.stack.poolManager);
        _code("code: hook", c.stack.hook);
        _code("code: factory", c.stack.factory);
        _code("code: locker", c.stack.locker);
        _code("code: escrow", c.stack.escrow);
        _code("code: auction factory", c.stack.auctionFactory);
        _code("code: mev module", c.mevModule);
        _code("code: Credits", Mainnet.CREDITS);
        _code("code: Statements", Mainnet.STATEMENTS);
        _code("code: CreditScore", Mainnet.CREDIT_SCORE);
        _code("code: CreditStrategy", Mainnet.CREDIT_STRATEGY);
        _code("code: Seaport", Mainnet.SEAPORT);
        _code("code: Permit2", Mainnet.PERMIT2);
        _code("code: position manager", Mainnet.POSITION_MANAGER);
        _code("code: universal router", Mainnet.UNIVERSAL_ROUTER);
    }

    /// @dev the linked library. a deployed copy at the create2 address is the compiled code by construction (the address
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
                deployed
                    ? " on chain, the broadcast skips it and takes no deployer nonce"
                    : " not deployed, the first transaction deploys it and takes one deployer nonce"
            )
        );
    }

    /// @dev the deploy order is router, controller, Core: the router takes the deployer nonce after the library (when
    /// the library still has to go out), the controller the next, the Core the one after. the coin comes from the
    /// factory's own `predictToken` for the deployer and the full config, read through a call that cannot revert here
    function _prePredictions(LaunchConfig memory c, address deployer) private {
        uint64 nonce = _controllerNonce(deployer);
        address routerAt = vm.computeCreateAddress(deployer, nonce + 1);
        address coreAt = vm.computeCreateAddress(deployer, nonce + 2);
        _noCode("predicted router is empty", routerAt);
        _noCode("predicted controller is empty", vm.computeCreateAddress(deployer, nonce));
        _noCode("predicted core is empty", coreAt);
        (bool ok, address coinAt) = _predict(c, deployer, routerAt, coreAt);
        _check(
            "predicted coin is empty",
            ok && coinAt.code.length == 0,
            ok ? string.concat(vm.toString(coinAt), " code ", vm.toString(coinAt.code.length)) : "predictToken failed"
        );
        _preHouse(c, coreAt);
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
        (ok, a) = _addr(s.locker, abi.encodeCall(IArtCoinsLpLockerV2.feeEscrow, ()));
        _check("locker: reports the fee escrow", ok && a == s.escrow, vm.toString(a));
        (ok, b) = _bool(s.locker, abi.encodeCall(IArtCoinsLpLockerV2.isLauncher, (s.factory)));
        _check("locker: the factory is a launcher", ok && b, "isLauncher(factory)");
        (ok, a) = _addr(c.mevModule, abi.encodeCall(IArtCoinsMevSkimV2.hook, ()));
        _check("mev: module is bound to the hook", ok && a == s.hook, vm.toString(a));
        (ok, b) = _bool(s.escrow, abi.encodeCall(IArtCoinsFeeEscrowV2.isCoreDepositor, (s.hook)));
        _check("escrow: the hook is a core depositor", ok && b, "isCoreDepositor(hook)");
        (ok, b) = _bool(s.escrow, abi.encodeCall(IArtCoinsFeeEscrowV2.isDepositor, (s.locker)));
        _check("escrow: the locker is a depositor", ok && b, "isDepositor(locker)");
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
        (ok, b) = _bool(fa, abi.encodeCall(IArtCoinsFactoryV2.enabledEscrows, (c.stack.escrow)));
        _check("factory: escrow enabled", ok && b, "enabledEscrows(escrow)");
    }

    /// @dev the fee knobs of the factory against the config: the deploy fee and the deployer balance, the lp fee floor
    /// (`setMinLpFee(0)` is the owner command that opens lpFee 0), the protocol skim share floor against the bounty
    function _preFees(LaunchConfig memory c, address deployer) private {
        address fa = c.stack.factory;
        (bool ok, uint256 fee) = _word(fa, abi.encodeCall(IArtCoinsFactoryV2.deployFee, ()));
        uint256 need = fee + DEPLOY_GAS_ESTIMATE * block.basefee;
        _check(
            "deployer: balance covers the deploy fee and the gas",
            ok && deployer.balance >= need,
            string.concat("balance ", vm.toString(deployer.balance), " need ", vm.toString(need))
        );
        uint256 minLp;
        (ok, minLp) = _word(fa, abi.encodeCall(IArtCoinsFactoryV2.minLpFee, ()));
        _check(
            "factory: min lp fee is at most the config lp fee",
            ok && minLp <= c.lpFee,
            string.concat("minLpFee ", vm.toString(minLp), " lpFee ", vm.toString(c.lpFee), " (owner: setMinLpFee)")
        );
        uint256 minShare;
        (ok, minShare) = _word(fa, abi.encodeCall(IArtCoinsFactoryV2.minProtocolSkimShareBps, ()));
        _check(
            "factory: min protocol skim share leaves room for the bounty",
            ok && uint256(c.bountyBps) + minShare <= 10_000 && c.bountyBps <= 9999,
            string.concat("bounty ", vm.toString(c.bountyBps), " min share ", vm.toString(minShare))
        );
        uint256 room = uint256(c.bountyBps) + minShare <= 10_000 ? 10_000 - uint256(c.bountyBps) - minShare : 0;
        _check(
            "factory: referral cap fits above the protocol floor",
            ok && uint256(c.maxReferralBps) * 10_000 <= uint256(c.baselineSkimBps) * room,
            string.concat("referral cap ", vm.toString(c.maxReferralBps))
        );
        _preRecipients(c);
    }

    function _preRecipients(LaunchConfig memory c) private {
        address fa = c.stack.factory;
        (bool ok, address p) = _addr(fa, abi.encodeCall(IArtCoinsFactoryV2.protocolRecipient, ()));
        _check("factory: protocol recipient set (the launcher protocol, not the engine owner)", ok && p != address(0), vm.toString(p));
        address r;
        (ok, r) = _addr(fa, abi.encodeCall(IArtCoinsFactoryV2.referralPayout, ()));
        _check("factory: referral payout is a contract", ok && r.code.length != 0, vm.toString(r));
        (bool okf, uint256 fee) = _word(fa, abi.encodeCall(IArtCoinsFactoryV2.deployFee, ()));
        _info("factory: deploy fee paid by the launch", okf ? vm.toString(fee) : "unreadable");
        (ok, p) = _addr(fa, abi.encodeCall(IArtCoinsFactoryV2.teamFeeRecipient, ()));
        _info("factory: the deploy fee goes to the team fee recipient", vm.toString(p));
        (bool okp, uint256 fb) = _word(fa, abi.encodeCall(IArtCoinsFactoryV2.defaultProtocolFeeBps, ()));
        _warn(
            "warn: protocol bps differs from the factory default",
            okp && fb == c.protocolBps,
            string.concat("config ", vm.toString(c.protocolBps), " factory default ", vm.toString(fb))
        );
        (bool oka, bytes memory out) = fa.staticcall(abi.encodeCall(IArtCoinsFactoryV2.defaultAllowed, ()));
        uint256 n = oka && out.length >= 64 ? abi.decode(out, (address[])).length : type(uint256).max;
        _check(
            "factory: default allowlist is empty",
            n == 0,
            "the coin allowlist then holds the stack seeds and the Core only (owner: setDefaultAllowed([]))"
        );
    }

    /// @dev runs the launch as the factory owner on a snapshot and reverts the state again: the owner path works, the
    /// factory and the hook accept the config (bounds, minimums, enabled stack, mev values, recipients). the router and
    /// the Core need no code for it. the deployer gets the fee for the simulation only
    function _preSimulate(LaunchConfig memory c, address deployer) private {
        uint64 nonce = _controllerNonce(deployer);
        address routerAt = vm.computeCreateAddress(deployer, nonce + 1);
        address coreAt = vm.computeCreateAddress(deployer, nonce + 2);
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = buildConfig(c, c.owner, routerAt, coreAt);
        (bool ok, address coin, uint256 gas, bytes memory why) = _simulateLaunch(c, deployer, cfg);
        _check(
            "factory: deployTokenAsOwner accepts the config (simulated)",
            ok,
            ok
                ? string.concat("coin ", vm.toString(coin), " launch gas ", vm.toString(gas))
                : string.concat("reverts with ", vm.toString(why))
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
        bytes memory data = abi.encodeCall(IArtCoinsFactoryV2.deployTokenAsOwner, (cfg, c.protocolBps));
        uint256 g = gasleft();
        (ok, out) = c.stack.factory.call{value: fee}(data);
        gas = g - gasleft();
    }

    /// @dev the Core creates its auction house in its constructor, one house per owner address, so a house must not
    /// exist yet for the predicted core address. the factory default fee is fixed at the factory: it is paid out of
    /// every sale, so a non zero fee is a loud warning here, and the deploy stops at its postflight (house: protocol fee is zero)
    function _preHouse(LaunchConfig memory c, address coreAt) private {
        address f = c.stack.auctionFactory;
        (bool ok1, uint256 existing) = _word(f, abi.encodeCall(IAuctionFactory.houseOf, (coreAt)));
        _check("auction factory: no house yet for the predicted core", ok1 && existing == 0, "houseOf(core)");
        (bool okp, uint256 predicted) = _word(f, abi.encodeCall(IAuctionFactory.predictHouseAddress, (coreAt)));
        _check(
            "auction factory: the house address of the core is free",
            okp && address(uint160(predicted)).code.length == 0,
            string.concat("predictHouseAddress(core) ", vm.toString(address(uint160(predicted))))
        );
        (bool ok2, uint256 fee) = _word(f, abi.encodeCall(IAuctionFactory.defaultProtocolFeeBps, ()));
        _check("auction factory: default fee readable", ok2, vm.toString(fee));
        _warn(
            "warn: auction factory default fee is zero",
            ok2 && fee == 0,
            string.concat(
                "fee ",
                vm.toString(fee),
                " bps is taken from every statement sale. the deploy stops at postflight: house fee"
            )
        );
    }

    function _preLive() private {
        (bool ok1, uint256 cs) = _word(Mainnet.CREDITS, abi.encodeCall(ISupply.supply, ()));
        _check("Credits supply", ok1 && cs >= CREDITS_SUPPLY_MIN, vm.toString(cs));
        (bool ok2, uint256 ss) = _word(Mainnet.STATEMENTS, abi.encodeCall(IStatements.supply, ()));
        _check("Statements supply", ok2 && ss >= STATEMENTS_SUPPLY_MIN, vm.toString(ss));
        if (Mainnet.CREDITS.code.length == 0 || Mainnet.CREDIT_SCORE.code.length == 0) return;
        ICredits credits = ICredits(Mainnet.CREDITS);
        uint256 score =
            ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(credits.seedOf(KNOWN_CREDIT), credits.timestampOf(KNOWN_CREDIT));
        _eq("CreditScore of credit 1", score, KNOWN_SCORE);
    }

    /// @dev the table the owner signs. every row restates one launch input in the words of what it does, then the hash
    /// of the whole config is the single value the deploy needs back in CONFIG_HASH
    function _preSignoff(LaunchConfig memory c, address deployer) private {
        uint64 nonce = _controllerNonce(deployer);
        _info("signoff: owner (core owner, token admin, router owner, factory owner)", vm.toString(c.owner));
        _info("signoff: creator (the one project locker reward slot, 80 percent of the lp rewards, none at lp fee 0)", vm.toString(c.creator));
        _info("signoff: deployer (sends the transactions, must be the factory owner)", vm.toString(deployer));
        _info("signoff: router address (the bounty recipient of the pool)", vm.toString(vm.computeCreateAddress(deployer, nonce + 1)));
        _info("signoff: core address (the router flushes to it)", vm.toString(vm.computeCreateAddress(deployer, nonce + 2)));
        _info(
            "signoff: router payee (one at launch, owner replaces it later with setPayees)",
            string.concat(vm.toString(c.creatorPayee), " ppm ", vm.toString(c.payeePpm), " of a flush after the tip")
        );
        _info(
            "signoff: router tip and split",
            string.concat(
                "tip ppm ",
                vm.toString(c.tipPpm),
                " cap ",
                vm.toString(c.tipCap),
                " wei, the split starts at the first flush after the anti sniper window, router not locked by the deploy"
            )
        );
        _info(
            "signoff: opening bid",
            string.concat(
                "rateStart ",
                vm.toString(c.rateStart),
                " wei per point, a flat credit opens at about ",
                vm.toString(c.rateStart * c.settings.avgScore / 1e4),
                " wei (launch day rule: 0.75 times the market price of a credit)"
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
                "s lp fee ",
                vm.toString(c.lpFee)
            )
        );
        _info(
            "signoff: protocol leg",
            "the factory floor (10 percent of the skim, 0.69 points of volume) and the protocol locker slot belong to the launcher protocol, a separate business from this engine and its owner"
        );
        _preSettingsRows(c);
        _info("signoff: CONFIG_HASH", vm.toString(configHash(c)));
    }

    /// @dev the settings are adjustable by the owner after launch, so these rows print them for sign off
    function _preSettingsRows(LaunchConfig memory c) private {
        _info(
            "signoff: bid",
            string.concat(
                "flatBps ",
                vm.toString(c.settings.flatBps),
                " avgScore ",
                vm.toString(c.settings.avgScore),
                " spendCapBps ",
                vm.toString(c.settings.spendCapBps),
                " dropBps ",
                vm.toString(c.settings.dropBps),
                " rateCap ",
                vm.toString(c.settings.rateCap)
            )
        );
        _info(
            "signoff: climb",
            string.concat(
                "base ",
                vm.toString(c.settings.climbBaseBps),
                " max ",
                vm.toString(c.settings.climbMaxBps),
                " bps per hour, doubling every ",
                vm.toString(c.settings.climbDoubleEvery),
                "s"
            )
        );
        _info(
            "signoff: statement auction",
            string.concat(
                "saleFloorBps ",
                vm.toString(c.settings.saleFloorBps),
                " duration ",
                vm.toString(c.settings.auctionDuration),
                "s exitAfter ",
                vm.toString(c.settings.exitAfter),
                "s"
            )
        );
        _info(
            "signoff: splits",
            string.concat(
                "sale to buyback ",
                vm.toString(c.settings.saleToBuybackBps),
                " exit to buyback ",
                vm.toString(c.settings.exitToBuybackBps),
                " exit lane to buyback ",
                vm.toString(c.settings.exitLaneToBuybackBps),
                " fee to buyback ",
                vm.toString(c.settings.feeToBuybackBps),
                " buyback slice ",
                vm.toString(c.settings.buybackSlice)
            )
        );
        _info(
            "signoff: sale controller",
            string.concat(
                c.sale.buyOnly ? "buy only" : "auction mode",
                " start ",
                vm.toString(c.sale.startBps),
                " step ",
                vm.toString(c.sale.stepBps),
                " every ",
                vm.toString(c.sale.stepEvery),
                "s floor ",
                vm.toString(c.sale.floorBps)
            )
        );
        _info("signoff: settings are adjustable", "the owner can change every setting at once after launch");
    }
}
