// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VmSafe} from "forge-std/Vm.sol";
import {Stack, Mainnet, ICredits, ICreditScore, IStatements} from "../src/interfaces/Interfaces.sol";
import {IAuctionFactory} from "../src/interfaces/AuctionHouse.sol";
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
        _prePredictions(c, deployer);
        _preV2Todo();
        _preLive();
        _preSignoff(c, deployer);
    }

    /// @dev TODO(v2 port stage 3): the v2 factory, stack and prediction rows (restriction on, bounty recipient the router,
    /// bounty bps, lp fee and the factory minimum, mev values, locker slots, router engine and owner, allowlist holds the
    /// Core only, the predicted coin and Core empty, the factory accepts the config). until they exist this row fails
    /// every preflight, so no deploy script can pass
    function _preV2Todo() private {
        _check("v2 factory, stack and prediction checks", false, "TODO(v2 port stage 3): not ported yet");
    }

    /// @notice the checks that still make sense after the core exists, for `Resume.s.sol`. the prediction rows are left
    /// out (the addresses are taken by now) and the factory rows only run when the launch is still to be sent
    function preflightResume(LaunchConfig memory c, address deployer, bool launching) internal {
        _reset();
        _preConfig(c);
        _preRules(c, deployer);
        _preCode(c);
        launching;
        _preV2Todo();
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
        address[4] memory who = [c.owner, c.creator, c.creatorPayee, c.artistPayee];
        bool bad;
        for (uint256 i; i < 4; ++i) {
            address a = who[i];
            if (a == address(0)) continue; // the placeholder row reports it
            bad = bad || a == Mainnet.DEAD || a == c.stack.poolManager || a == c.stack.hook || a == c.stack.factory
                || a == c.stack.locker || a == c.stack.escrow || a == c.stack.auctionFactory || a == c.mevModule;
        }
        _check("rule: owner, creator and payees are not dead or stack addresses", !bad, "dead, stack, mev module");
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

    /// @dev TODO(v2 port stage 3): the router sits at the deployer nonce first, so the controller and Core nonces move by
    /// one, and the predicted coin (the factory `predictToken`) is checked empty
    function _prePredictions(LaunchConfig memory c, address deployer) private {
        uint64 nonce = _controllerNonce(deployer);
        address coreAt = vm.computeCreateAddress(deployer, nonce + 2);
        _noCode("predicted core is empty", coreAt);
        _preHouse(c, coreAt);
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
        address core = vm.computeCreateAddress(deployer, _controllerNonce(deployer) + 2);
        _info("signoff: owner (core owner and token admin)", vm.toString(c.owner));
        _info("signoff: creator (0.5 point leg and lp rewards)", vm.toString(c.creator));
        _info("signoff: deployer (sends the transactions)", vm.toString(deployer));
        _info("signoff: core address (the fee router flushes to it)", vm.toString(core));
        _info("signoff: payees (creator, artist)", string.concat(vm.toString(c.creatorPayee), " ", vm.toString(c.artistPayee)));
        _info("signoff: locker reward slot goes to the creator", vm.toString(c.creator));
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
