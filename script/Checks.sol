// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Stack, Mainnet, ICredits, ICreditScore, IStatements} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactory} from "../src/interfaces/ArtCoins.sol";
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
    /// @dev supplies at block 26127622. both only grow
    uint256 internal constant CREDITS_SUPPLY_MIN = 122_154;
    uint256 internal constant STATEMENTS_SUPPLY_MIN = 148;

    /// @notice runs every preflight check and records it in the report
    function preflight(LaunchConfig memory c, address deployer) internal {
        _reset();
        _preConfig(c);
        _preCode(c);
        _preFactory(c, deployer);
        _prePredictions(c, deployer);
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
            "launch parameters sane",
            c.bountyBps <= 9999 && c.taxBps <= c.taxBpsMax && c.supply >= 1e18
                && c.positionLower % c.stack.tickSpacing == 0 && c.positionUpper % c.stack.tickSpacing == 0
                && c.positionLower < c.positionUpper && c.sniperSeconds != 0,
            "bounty, tax, supply, ticks, sniper window"
        );
        _eq("supply equals the Core SUPPLY constant", c.supply, CORE_SUPPLY);
        _check("token code file exists", vm.exists(c.tokenCodeFile), c.tokenCodeFile);
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

    /// @dev a staticcall that never reverts. ok is false when the call failed or returned less than a word
    function _word(address target, bytes memory data) internal view returns (bool ok, uint256 w) {
        bytes memory out;
        (ok, out) = target.staticcall(data);
        if (ok && out.length >= 32) w = abi.decode(out, (uint256));
        else ok = false;
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
}
