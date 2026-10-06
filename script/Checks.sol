// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Stack, Mainnet, ICredits, ICreditScore, IStatements} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactory, IArtCoinsLocker, IArtCoinsSkimHook} from "../src/interfaces/ArtCoins.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {PostflightChecks} from "./PostflightChecks.sol";

interface ISupply {
    function supply() external view returns (uint256);
}

/// @notice the read only checks run before a launch (`preflight`) and after it (`postflight`). they only read state,
/// so they are safe to run against mainnet at any time
abstract contract LaunchChecks is PostflightChecks {
    /// @dev gas units of the five deploy transactions (about 10.1M measured by test/Rehearsal.t.sol) plus margin
    uint256 internal constant DEPLOY_GAS_ESTIMATE = 11_000_000;
    /// @dev the Core SUPPLY constant, the coin supply its exit auction is priced against. test/Config.t.sol checks it
    uint256 internal constant CORE_SUPPLY = 1_000_000_000e18;
    /// @dev credit 1 exists and its score is a pure function of its seed and timestamp
    uint256 internal constant KNOWN_CREDIT = 1;
    uint256 internal constant KNOWN_SCORE = 1_324_012;
    // the pinned launch rules (docs/DEPLOY.md section 2). a value outside them fails preflight. the three overrides in
    // the config file open exactly the rules that say so, and are part of the config hash
    uint24 internal constant PIN_BASELINE_SKIM = 10_000;
    uint16 internal constant PIN_BOUNTY_BPS = 9500;
    uint16 internal constant PIN_TAX_BPS_MAX = 2000;
    uint24 internal constant SNIPER_START_MIN = 50_000;
    uint24 internal constant SNIPER_START_MAX = 90_000;
    uint32 internal constant SNIPER_SECONDS_MIN = 600;
    uint32 internal constant SNIPER_SECONDS_MAX = 3600;
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    int24 internal constant MAX_TICK = 887_272;
    /// @dev v4 limit of the tick spacing
    int24 internal constant MAX_TICK_SPACING = 32_767;
    /// @dev supplies at block 26127622. both only grow
    uint256 internal constant CREDITS_SUPPLY_MIN = 122_154;
    uint256 internal constant STATEMENTS_SUPPLY_MIN = 148;

    /// @notice runs every preflight check and records it in the report
    function preflight(LaunchConfig memory c, address deployer) internal {
        _reset();
        _preConfig(c);
        _preRules(c, deployer);
        _preCode(c);
        _preFactory(c, deployer);
        _preStack(c);
        _prePredictions(c, deployer);
        _preLive();
        _preSignoff(c, deployer);
    }

    /// @notice the checks that still make sense after the core exists, for `Resume.s.sol`. the prediction rows are left
    /// out (the addresses are taken by now) and the factory rows only run when the launch is still to be sent
    function preflightResume(LaunchConfig memory c, address deployer, bool launching) internal {
        _reset();
        _preConfig(c);
        _preRules(c, deployer);
        _preCode(c);
        if (launching) _preFactory(c, deployer);
        _preStack(c);
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
        _check("rateStart in bounds", rateInBounds(c), string.concat("rateStart ", vm.toString(c.rateStart)));
        _check(
            "AUCTION_START_X and AUCTION_FLOOR_X in bounds, floor below start",
            auctionInBounds(c),
            string.concat(
                "start ",
                vm.toString(c.econ.auctionStartX),
                " floor ",
                vm.toString(c.econ.auctionFloorX),
                " bps of cost"
            )
        );
        _check("DROP_BPS in bounds", dropInBounds(c), string.concat("DROP_BPS ", vm.toString(c.econ.dropBps)));
        _check(
            "INVENTORY_GATE in bounds",
            gateInBounds(c),
            c.econ.inventoryGate == 0
                ? "0, gate off"
                : string.concat("gate on at ", vm.toString(c.econ.inventoryGate), " statements")
        );
        _eq("supply equals the Core SUPPLY constant", c.supply, CORE_SUPPLY);
        _check("token code file exists", vm.exists(c.tokenCodeFile), c.tokenCodeFile);
    }

    /// @dev the pinned rules. each is one row, so a failure names the rule
    function _preRules(LaunchConfig memory c, address deployer) private {
        _ruleTicks(c);
        _ruleEconomics(c);
        _ruleSniper(c);
        _ruleTax(c);
        _rulePeople(c, deployer);
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
        _eq("rule: baseline skim bps is 10000", uint256(c.baselineSkimBps), PIN_BASELINE_SKIM);
        bool bountyOk = c.bountyBps == PIN_BOUNTY_BPS || (c.allowBounty && c.bountyBps <= 9999);
        _check(
            "rule: bounty bps is 9500",
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
        _eq("rule: sniper end bps equals the baseline skim", uint256(c.sniperEndBps), uint256(c.baselineSkimBps));
        _check(
            "rule: sniper start bps in 50000 to 90000",
            c.sniperStartBps >= SNIPER_START_MIN && c.sniperStartBps <= SNIPER_START_MAX
                && c.sniperStartBps > c.sniperEndBps,
            vm.toString(c.sniperStartBps)
        );
        _check(
            "rule: sniper seconds in 600 to 3600",
            c.sniperSeconds >= SNIPER_SECONDS_MIN && c.sniperSeconds <= SNIPER_SECONDS_MAX,
            vm.toString(c.sniperSeconds)
        );
    }

    function _ruleTax(LaunchConfig memory c) private {
        _check(
            "rule: tax bps within 0 and a 2000 cap",
            c.taxBpsMax == PIN_TAX_BPS_MAX && c.taxBps <= c.taxBpsMax,
            string.concat("tax ", vm.toString(c.taxBps), " max ", vm.toString(c.taxBpsMax))
        );
        bool burnOk = c.taxBurn == Mainnet.DEAD || (c.allowTaxBurn && c.taxBurn != address(0));
        _check(
            "rule: tax burn is the dead address",
            burnOk,
            string.concat(vm.toString(c.taxBurn), c.allowTaxBurn ? " (override on)" : "")
        );
    }

    function _rulePeople(LaunchConfig memory c, address deployer) private {
        address[2] memory who = [c.owner, c.creator];
        bool bad;
        for (uint256 i; i < 2; ++i) {
            address a = who[i];
            if (a == address(0)) continue; // the placeholder row reports it
            bad = bad || a == Mainnet.DEAD || a == c.stack.poolManager || a == c.stack.hook || a == c.stack.factory
                || a == c.stack.locker || a == c.stack.escrow || a == c.mevModule || a == c.factoryOwner;
        }
        _check(
            "rule: owner and creator are not dead or stack addresses", !bad, "dead, stack, mev module, factory owner"
        );
        bool set = c.owner != address(0) && c.creator != address(0);
        _warn("warn: owner differs from creator", !set || c.owner != c.creator, "one party takes both roles");
        _warn("warn: owner differs from the deployer", c.owner != deployer, "the throwaway key would own the Core");
        _warn("warn: creator differs from the deployer", c.creator != deployer, "the throwaway key would earn");
    }

    function _preCode(LaunchConfig memory c) private {
        _code("code: pool manager", c.stack.poolManager);
        _code("code: hook", c.stack.hook);
        _code("code: factory", c.stack.factory);
        _code("code: locker", c.stack.locker);
        _code("code: escrow", c.stack.escrow);
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

    function _preFactory(LaunchConfig memory c, address deployer) private {
        address f = c.stack.factory;
        (bool ok1, uint256 hookOn) = _word(f, abi.encodeCall(IArtCoinsFactory.enabledHooks, (c.stack.hook)));
        _check("factory: hook enabled", ok1 && hookOn == 1, "enabledHooks(hook)");
        (bool ok2, uint256 lockOn) =
            _word(f, abi.encodeCall(IArtCoinsFactory.enabledLockers, (c.stack.locker, c.stack.hook)));
        _check("factory: locker enabled for hook", ok2 && lockOn == 1, "enabledLockers(locker, hook)");
        (bool ok3, uint256 mevOn) = _word(f, abi.encodeCall(IArtCoinsFactory.enabledMevModules, (c.mevModule)));
        _check("factory: mev module enabled", ok3 && mevOn == 1, "enabledMevModules(module)");
        (bool ok4, uint256 dep) = _word(f, abi.encodeCall(IArtCoinsFactory.deprecated, ()));
        _check("factory: deprecated readable", ok4, dep == 1 ? "deprecated true" : "deprecated false");
        _check(
            "factory: deprecated, only the owner and admins can launch",
            ok4 && (dep == 1 || c.allowOpenFactory),
            dep == 1 ? "deprecated" : (c.allowOpenFactory ? "OPEN, override on" : "OPEN, anyone could launch")
        );
        (bool ok5, uint256 own) = _word(f, abi.encodeCall(IArtCoinsFactory.owner, ()));
        _check(
            "factory: owner matches config",
            ok5 && address(uint160(own)) == c.factoryOwner,
            vm.toString(address(uint160(own)))
        );
        (bool ok6, uint256 adm) = _word(f, abi.encodeCall(IArtCoinsFactory.admins, (deployer)));
        bool may = ok4 && ok5 && (dep == 0 || address(uint160(own)) == deployer || (ok6 && adm == 1));
        _check("factory: deployer may launch", may, string.concat("deployer ", vm.toString(deployer)));
        (bool ok7, uint256 fee) = _word(f, abi.encodeCall(IArtCoinsFactory.deployFee, ()));
        uint256 need = fee + DEPLOY_GAS_ESTIMATE * block.basefee * 2;
        _check(
            "deployer balance covers fee and gas",
            ok7 && deployer.balance >= need,
            string.concat(
                "fee ", vm.toString(fee), " need ", vm.toString(need), " have ", vm.toString(deployer.balance)
            )
        );
    }

    /// @dev the stack members must agree with what the hook and the locker report about themselves, and the locker and
    /// the mev module must be the ones the factory enabled. a wrong value in the config file fails here
    function _preStack(LaunchConfig memory c) private {
        address hook = c.stack.hook;
        _addrView("hook reports pool manager", hook, "poolManager()", c.stack.poolManager);
        _addrView("hook reports factory", hook, "factory()", c.stack.factory);
        _addrView("hook reports fee escrow", hook, "feeEscrow()", c.stack.escrow);
        _addrView("locker reports factory", c.stack.locker, "factory()", c.stack.factory);
        _addrView("locker reports position manager", c.stack.locker, "positionManager()", Mainnet.POSITION_MANAGER);
    }

    function _addrView(string memory name, address target, string memory sig, address want) private {
        (bool ok, uint256 w) = _word(target, abi.encodeWithSignature(sig));
        address got = address(uint160(w));
        _check(name, ok && got == want, string.concat("got ", vm.toString(got), " want ", vm.toString(want)));
    }

    function _prePredictions(LaunchConfig memory c, address deployer) private {
        uint64 nonce = vm.getNonce(deployer);
        address controllerAt = vm.computeCreateAddress(deployer, nonce);
        address coreAt = vm.computeCreateAddress(deployer, nonce + 1);
        _noCode("predicted controller is empty", controllerAt);
        _noCode("predicted core is empty", coreAt);
        if (!vm.exists(c.tokenCodeFile)) return;
        address coinAt = predictCoin(c, deployer, coreAt);
        _noCode("predicted coin is empty", coinAt);
        _check(
            "coin prediction inputs", true, string.concat("salt ", vm.toString(c.salt), " nonce ", vm.toString(nonce))
        );
        _check(
            "coin prediction hashes",
            true,
            string.concat(
                "taxConfig ",
                vm.toString(keccak256(abi.encode(buildTaxConfig(c, coreAt)))),
                " initcode ",
                vm.toString(keccak256(coinInitcode(c, deployer, coreAt)))
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
        address core = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        _info("signoff: owner (core owner and token admin)", vm.toString(c.owner));
        _info("signoff: creator (0.5 point leg and lp rewards)", vm.toString(c.creator));
        _info("signoff: deployer (sends the five transactions)", vm.toString(deployer));
        _info("signoff: skim bounty and referral payout point to the core", vm.toString(core));
        _info("signoff: skim protocol leg and locker rewards point to the creator", vm.toString(c.creator));
        _info("signoff: tax and burn address", vm.toString(c.taxBurn));
        _info(
            "signoff: opening bid",
            string.concat(
                "rateStart ",
                vm.toString(c.rateStart),
                " wei per point, flat price about ",
                vm.toString(c.rateStart * 1600),
                " wei"
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
                vm.toString(c.sniperEndBps),
                " over ",
                vm.toString(c.sniperSeconds),
                "s tax ",
                vm.toString(c.taxBps),
                "/",
                vm.toString(c.taxBpsMax)
            )
        );
        _info(
            "signoff: auction",
            string.concat(
                "AUCTION_START_X ",
                vm.toString(c.econ.auctionStartX),
                " AUCTION_FLOOR_X ",
                vm.toString(c.econ.auctionFloorX),
                " bps of cost, no statement sells below the floor"
            )
        );
        _info(
            "signoff: rate drop",
            string.concat("DROP_BPS ", vm.toString(c.econ.dropBps), " of the rate when a whole pot is spent")
        );
        _info(
            "signoff: inventory gate",
            c.econ.inventoryGate == 0
                ? "INVENTORY_GATE 0, off: the eth bid never closes"
                : string.concat(
                    "INVENTORY_GATE ",
                    vm.toString(c.econ.inventoryGate),
                    ": the eth bid closes and the rate stops climbing while the core holds this many eth lane statements"
                )
        );
        _info("signoff: CONFIG_HASH", vm.toString(configHash(c)));
    }
}
