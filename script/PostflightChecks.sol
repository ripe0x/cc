// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Mainnet, Stack, Settings, IStatements} from "../src/interfaces/Interfaces.sol";
import {IAuctionHouse, IAuctionFactory} from "../src/interfaces/AuctionHouse.sol";
import {ICoreLib} from "../src/interfaces/ICoreLib.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {ICoreLens} from "../src/interfaces/ICoreLens.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {PostflightPool} from "./PostflightPool.sol";

/// @notice reads a launched system back and compares it with the config. read only, safe against mainnet any time.
/// run it right after the launch: the supply and rate rows are exact at launch and tolerant once trading started.
/// the rows that the owner can change afterwards (settings, locks, owner, the coin, the router) turn into warnings when the
/// operator names the change: SETTINGS_CHANGED, LOCKS_CHANGED, OWNER_CHANGED, COIN_CHANGED, ROUTER_CHANGED = 1
abstract contract PostflightChecks is PostflightPool {
    /// @notice the deployer of the launch from the environment (DEPLOYER), zero when not given. a test overrides it
    function _deployerEnv() internal view virtual returns (address) {
        return vm.envOr("DEPLOYER", address(0));
    }

    function postflight(LaunchConfig memory c, address core_) internal {
        postflightAs(c, core_, _deployerEnv());
    }

    /// @notice every postflight row. `deployer` (zero when unknown) adds the rows that need the creation nonces: the router
    /// and the controller were created by it right before the Core, and the coin equals the factory prediction
    function postflightAs(LaunchConfig memory c, address core_, address deployer) internal {
        _reset();
        _code("code: core", core_);
        if (core_.code.length == 0) return;
        ICore core = ICore(payable(core_));
        // derived, never signed: the fee source is an immutable of the Core, and the config hash leaves it out
        c.stack.feeSource = core.FEE_SOURCE();
        _postCore(c, core);
        address coin = core.COIN();
        _code("code: coin", coin);
        if (coin.code.length == 0) return;
        bytes32 poolId = _postPool(c, coin);
        _postCoin(c, core_, coin, poolId);
        _postRouter(c, core, deployer, coin);
        _postLens(core);
        _postPrediction(c, coin, deployer, core_);
        _postUnreadable(c);
    }

    /// @dev the coin equals the factory's prediction for the deployer. the prediction reads mutable factory state (the
    /// default allowlist, the hook escrow), so a later change of it is a warning, never a failure. it proves the allowlist
    /// the coin was built with when the factory state is still the launch state
    function _postPrediction(LaunchConfig memory c, address coin, address deployer, address core_) private {
        if (deployer == address(0)) return;
        (bool ok, uint256 n) = _coreNonce(core_, deployer);
        if (!ok) return;
        address routerAt = vm.computeCreateAddress(deployer, n - 1);
        (bool okp, address want) = _predict(c, deployer, routerAt);
        _warn("warn: coin equals the factory prediction for the deployer", okp && want == coin, vm.toString(want));
    }

    /// @dev the deterministic deployer that `forge script` sends the library and the lens through (CREATE2)
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev the CREATE2 salt of the lens
    bytes32 internal constant LENS_SALT = keccak256("credits.core.lens.v1");

    /// @notice the address of the lens of `core_`: CREATE2 through the deterministic deployer with `LENS_SALT` and the
    /// creation code of `CoreLens` with the Core as constructor argument. a function of the Core address and the
    /// compiled lens, so postflight and resume derive it without the deployer or its nonce
    function lensAddress(address core_) internal view returns (address) {
        bytes memory init = abi.encodePacked(vm.getCode("CoreLens.sol:CoreLens"), abi.encode(core_));
        return vm.computeCreate2Address(LENS_SALT, keccak256(init), CREATE2_DEPLOYER);
    }

    /// @dev the lens at `lensAddress(core)` has code of the compiled size, points at this Core and at the router and house
    /// the Core names, uses the Credits and Statements of mainnet, and answers `snapshot`. its controller is the Core's,
    /// read on every call
    function _postLens(ICore core) private {
        address lensAt = lensAddress(address(core));
        _code("code: lens", lensAt);
        if (lensAt.code.length == 0) return;
        ICoreLens lens = ICoreLens(lensAt);
        bool sized = lensAt.code.length == vm.getDeployedCode("CoreLens.sol:CoreLens").length;
        _check("lens: code size is the compiled CoreLens", sized, vm.toString(lensAt));
        if (!sized) return;
        _eq("lens: core", lens.CORE(), address(core));
        _eq("lens: router is the Core fee source", lens.ROUTER(), core.FEE_SOURCE());
        _eq("lens: house is the Core house", lens.HOUSE(), address(core.HOUSE()));
        _eq("lens: credits", lens.CREDITS(), Mainnet.CREDITS);
        _eq("lens: statements", lens.STATEMENTS(), Mainnet.STATEMENTS);
        _eq("lens: controller is the Core controller", lens.controller(), core.controller());
        (bool ok,) = lensAt.staticcall(abi.encodeCall(ICoreLens.snapshot, ()));
        _check("lens: snapshot answers", ok, vm.toString(lensAt));
    }

    /// @notice the postflight of a run that has not set the split start yet (the Deploy script, a Resume that launches)
    /// reports a split start of zero as a warning, not a failure. the split start is set by the next Resume, after the
    /// launch is mined
    bool internal splitStartPending;

    /// @dev nonces to scan down from the deployer nonce when looking for the creation of the Core
    uint256 internal constant NONCE_SCAN = 4096;

    /// @notice the operator names the first controller by hand (FIRST_CONTROLLER) when the deployer is unknown. a test
    /// overrides it
    function _firstControllerEnv() internal view virtual returns (address) {
        return vm.envOr("FIRST_CONTROLLER", address(0));
    }

    /// @notice the controller the Core was created with, never read from the Core: the deploy creates the controller at
    /// the deployer nonce n, the router at n + 1 and the Core at n + 2 (`SystemDeployer.deploySystem`), so it is the create
    /// address two nonces before the one that gives `core_`. scans down from the deployer nonce. `found` is false when the deployer is
    /// unknown and FIRST_CONTROLLER is not set, or the scan finds nothing
    function firstController(address core_, address deployer) internal view returns (address ctl, bool found) {
        address named = _firstControllerEnv();
        if (named != address(0)) return (named, true);
        (bool ok, uint256 n) = _coreNonce(core_, deployer);
        if (!ok) return (address(0), false);
        return (vm.computeCreateAddress(deployer, n - 2), true);
    }

    /// @notice the deployer nonce the Core was created at, scanning down from the deployer nonce. the deploy creates the
    /// controller at n - 2, the router at n - 1 and the Core at n (`SystemDeployer.deploySystem`)
    function _coreNonce(address core_, address deployer) internal view returns (bool, uint256) {
        if (deployer == address(0)) return (false, 0);
        uint256 top = vm.getNonce(deployer);
        uint256 stop = top > NONCE_SCAN ? top - NONCE_SCAN : 2;
        if (stop < 2) stop = 2;
        for (uint256 n = top; n >= stop; --n) {
            if (vm.computeCreateAddress(deployer, n) == core_) return (true, n);
        }
        return (false, 0);
    }

    /// @notice the constructor arguments of the Core as its creation transaction carried them, in the encoding etherscan
    /// wants for verification: `(owner, coin, controller, stack, rateStart, settings)`. built only from the signed launch
    /// config and the first controller: the original owner `c.owner`, `c.stack`, `c.rateStart` and `c.settings`. the coin
    /// is the Core immutable `COIN`, which cannot change. nothing here reads the live `owner`, `controller` or `settings`,
    /// all of which the owner can change after launch (audit finding A02)
    function coreConstructorArgs(ICore core, LaunchConfig memory c, address firstController_)
        internal
        view
        returns (bytes memory)
    {
        // the fee source is an immutable of the Core: it cannot drift, so it is read from the Core (the config file has none)
        c.stack.feeSource = core.FEE_SOURCE();
        return abi.encode(c.owner, core.COIN(), firstController_, c.stack, c.rateStart, c.settings);
    }

    /// @notice prints what etherscan verification needs: the library address and the exact `--libraries` flag, the
    /// constructor arguments of the Core (from the config, see `coreConstructorArgs`) and of the controller, then the
    /// live controller and settings on separate lines labelled as live. docs/DEPLOY.md section 3. `deployer` is the
    /// address that sent the deploy, it finds the first controller
    function printVerifyInputs(ICore core, LaunchConfig memory c, address deployer) internal view {
        address lib = findLibrary(address(core).code);
        console.log("verify: library CoreLib at", lib);
        console.log(string.concat("verify: flag  --libraries src/lib/CoreLib.sol:CoreLib:", vm.toString(lib)));
        (address first, bool found) = firstController(address(core), deployer);
        if (found) {
            console.log("verify: first controller (creation input)", first);
            console.log("verify: core constructor args");
            console.logBytes(coreConstructorArgs(core, c, first));
            console.log("verify: controller constructor args");
            console.logBytes(abi.encode(address(core), c.sale));
        } else {
            console.log(
                "verify: core constructor args NOT printed: set DEPLOYER (the deploy signer) or FIRST_CONTROLLER"
            );
        }
        // the live values are not constructor inputs: the owner can change them at any time
        console.log("verify: router (the fee source) at", core.FEE_SOURCE());
        console.log("verify: router constructor args (the owner)");
        console.logBytes(abi.encode(c.owner));
        console.log("verify: LIVE controller now, NOT a constructor input", core.controller());
        console.log("verify: LIVE settings now, NOT a constructor input, abi encoded");
        console.logBytes(abi.encode(core.settings()));
        console.log("verify: LIVE owner now, NOT a constructor input", core.owner());
        if (found && core.controller() != first) console.log("verify: note the live controller is not the first one");
    }

    function _postCore(LaunchConfig memory c, ICore core) private {
        // after a handover the live owner is the new one: OWNER_CHANGED=1 turns the row into a warning
        if (_ownerChanged()) {
            _warn("warn: owner equals the config", core.owner() == c.owner, "OWNER_CHANGED=1, a handover ran");
        } else {
            _eq("core: owner", core.owner(), c.owner);
        }
        _eq("core: SUPPLY constant equals the config supply", core.SUPPLY(), c.supply);
        _eq("core: RATE_START", core.RATE_START(), c.rateStart);
        _eq("core: auction factory", core.AUCTION_FACTORY(), c.stack.auctionFactory);
        _postSettings(c, core);
        _postHouse(c, core);
        _postLibrary(core);
        _eq("core: pool manager", address(core.MANAGER()), c.stack.poolManager);
        _eq("core: hook", core.HOOK(), c.stack.hook);
        _eq("core: tick spacing", uint256(int256(core.TICK_SPACING())), uint256(int256(c.stack.tickSpacing)));
        _eq("core: pool fee", uint256(core.POOL_FEE()), uint256(c.stack.poolFee));
        _eq("core: factory", core.FACTORY(), c.stack.factory);
        _eq("core: locker", core.LOCKER(), c.stack.locker);
        _eq("core: escrow", core.ESCROW(), c.stack.escrow);
        _check(
            "code: stack addresses",
            c.stack.poolManager.code.length != 0 && c.stack.hook.code.length != 0 && c.stack.factory.code.length != 0
                && c.stack.locker.code.length != 0 && c.stack.escrow.code.length != 0
                && c.stack.auctionFactory.code.length != 0,
            "pool manager, hook, factory, locker, escrow, auction factory"
        );
        address ctl = core.controller();
        _code("code: controller", ctl);
        if (ctl.code.length != 0) _eq("controller: core", address(IControllerV1(ctl).CORE()), address(core));
        _check(
            "core: allowed targets",
            core.allowedTarget(Mainnet.SEAPORT) && core.allowedTarget(Mainnet.CREDIT_STRATEGY)
                && !core.allowedTarget(c.stack.hook) && !core.allowedTarget(c.stack.factory)
                && !core.allowedTarget(c.stack.locker) && !core.allowedTarget(c.stack.escrow)
                && !core.allowedTarget(c.stack.poolManager) && !core.allowedTarget(core.COIN())
                && !core.allowedTarget(address(core.HOUSE())) && !core.allowedTarget(c.stack.auctionFactory)
                && !core.allowedTarget(core.FEE_SOURCE()),
            "seaport and CreditStrategy only, the router is not a target"
        );
        _code("code: fee source (the router)", core.FEE_SOURCE());
        _check(
            "core: runtime code is the compiled Core (immutables and the library address masked)",
            runtimeMatchesArtifact(address(core), "Core"),
            vm.toString(address(core))
        );
        _check(
            "controller: runtime code is the compiled ControllerV1 (immutables masked)",
            runtimeMatchesArtifact(ctl, "ControllerV1"),
            vm.toString(ctl)
        );
        // after launch the owner may lock or set the exit module: LOCKS_CHANGED=1 turns the row into a report line
        bool launchState = !core.controllerLocked() && !core.exitModuleLocked() && !core.targetsLocked()
            && core.exitModule() == address(0);
        if (_locksChanged()) {
            _warn("warn: no locks, no exit module", launchState, "LOCKS_CHANGED=1, the owner changed them");
        } else {
            _check("core: no locks, no exit module", launchState, "launch state");
        }
        _warn("warn: no pending owner", core.pendingOwner() == address(0), "an owner handover is offered");
        _postSale(c, ctl);
        _check(
            "core: pots covered by balance",
            core.ethPot() + core.ethToBuyback() <= address(core).balance,
            string.concat("balance ", vm.toString(address(core).balance))
        );
        // the stored price state moves once the pot is funded or a credit is bought, and the owner may reset it with
        // `setRate`, so it is exact only at launch: a difference is a warning. the read `ethRate()` is zero while the pot is
        // empty
        _warn(
            "warn: price state is rateStart",
            core.ethPot() != 0 || core.rateAtCheckpoint() == c.rateStart,
            string.concat(
                "rateAtCheckpoint ", vm.toString(core.rateAtCheckpoint()), " rateStart ", vm.toString(c.rateStart)
            )
        );
    }

    /// @notice the operator says the owner locked a setter or set the exit module since launch (LOCKS_CHANGED=1). a test
    /// overrides it
    function _locksChanged() internal view virtual returns (bool) {
        return vm.envOr("LOCKS_CHANGED", uint256(0)) == 1;
    }

    /// @notice the operator says the owner role was handed over since launch (OWNER_CHANGED=1). a test overrides it
    function _ownerChanged() internal view virtual returns (bool) {
        return vm.envOr("OWNER_CHANGED", uint256(0)) == 1;
    }

    /// @dev the sale settings of the controller must equal the config, like the core settings (SETTINGS_CHANGED=1 turns
    /// the row into a warning once the owner changed them)
    function _postSale(LaunchConfig memory c, address ctl) private {
        if (ctl.code.length == 0) return;
        IControllerV1 k = IControllerV1(ctl);
        bool same = k.buyOnly() == c.sale.buyOnly && k.startBps() == c.sale.startBps && k.stepBps() == c.sale.stepBps
            && k.stepEvery() == c.sale.stepEvery && k.floorBps() == c.sale.floorBps;
        if (_settingsChanged()) {
            _warn(
                "warn: sale settings equal the config", same, "SETTINGS_CHANGED=1, the owner changed them since launch"
            );
        } else {
            _check("controller: sale settings equal the config", same, "buyOnly startBps stepBps stepEvery floorBps");
        }
        _info(
            "controller: sale",
            string.concat(
                k.buyOnly() ? "buy only" : "auction mode",
                " start ",
                vm.toString(k.startBps()),
                " step ",
                vm.toString(k.stepBps()),
                " every ",
                vm.toString(k.stepEvery()),
                "s floor ",
                vm.toString(k.floorBps())
            )
        );
    }

    /// @notice the operator says the owner changed the settings since launch (SETTINGS_CHANGED=1). a test overrides it
    function _settingsChanged() internal view virtual returns (bool) {
        return vm.envOr("SETTINGS_CHANGED", uint256(0)) == 1;
    }

    /// @dev the settings are owner adjustable after launch. right after the deploy they must equal the config field by
    /// field, so a Core built with other values fails. once the owner has called `setSettings` the live values differ
    /// on purpose: run with SETTINGS_CHANGED=1 and the row turns into a warning that prints the difference
    function _postSettings(LaunchConfig memory c, ICore core) private {
        Settings memory live = core.settings();
        bytes32 bad = SettingsBounds.firstViolation(live);
        _check("core: settings inside the bounds", bad == 0, bad == 0 ? "all fields" : string(abi.encodePacked(bad)));
        bool same = keccak256(abi.encode(live)) == keccak256(abi.encode(c.settings));
        if (_settingsChanged()) {
            _warn("warn: settings equal the config", same, "SETTINGS_CHANGED=1, the owner changed them since launch");
        } else {
            _check(
                "core: settings equal the config",
                same,
                "set SETTINGS_CHANGED=1 only after the owner called setSettings"
            );
        }
        _info(
            "core: flat share and average score",
            string.concat(
                "flatBps ",
                vm.toString(live.flatBps),
                " avgScore ",
                vm.toString(live.avgScore),
                " rateCap ",
                vm.toString(live.rateCap)
            )
        );
        _check("core: ethRate at most rateCap", core.ethRate() <= live.rateCap, vm.toString(core.ethRate()));
        _info(
            "core: reserve and auction",
            string.concat(
                "saleFloorBps ", vm.toString(live.saleFloorBps), " duration ", vm.toString(live.auctionDuration), "s"
            )
        );
        _info(
            "core: splits",
            string.concat(
                "sale to buyback ",
                vm.toString(live.saleToBuybackBps),
                " exit to buyback ",
                vm.toString(live.exitToBuybackBps),
                " exit lane to buyback ",
                vm.toString(live.exitLaneToBuybackBps),
                " fee to buyback ",
                vm.toString(live.feeToBuybackBps),
                " exitAfter ",
                vm.toString(live.exitAfter),
                "s"
            )
        );
    }

    /// @dev the auction house the core created in its constructor: the factory knows it, the core owns it, its fee is
    /// zero and it may take statements
    function _postHouse(LaunchConfig memory c, ICore core) private {
        address house = address(core.HOUSE());
        _code("code: house", house);
        if (house.code.length == 0) return;
        (bool okh, uint256 recorded) =
            _word(c.stack.auctionFactory, abi.encodeCall(IAuctionFactory.houseOf, (address(core))));
        _check(
            "house: factory houseOf(core)",
            okh && address(uint160(recorded)) == house,
            string.concat("got ", vm.toString(address(uint160(recorded))), " want ", vm.toString(house))
        );
        _eq("house: owner is the core", IAuctionHouse(house).owner(), address(core));
        (bool ok, uint256 fee) = _word(house, abi.encodeCall(IAuctionHouse.protocolFeeBps, ()));
        _check("house: protocol fee is zero", ok && fee == 0, string.concat("protocolFeeBps ", vm.toString(fee)));
        _check(
            "house: approved for all statements of the core",
            IStatements(Mainnet.STATEMENTS).isApprovedForAll(address(core), house),
            "Statements.isApprovedForAll(core, house)"
        );
    }

    /// @dev the Core is linked against `CoreLib`. its address sits in the Core runtime code as a push20. the row finds
    /// a push20 operand whose code is the compiled library (its own address masked out)
    function _postLibrary(ICore core) private {
        address found = findLibrary(address(core).code);
        _check(
            "core: linked library is the compiled CoreLib",
            found != address(0),
            string.concat("library at ", vm.toString(found))
        );
    }

    /// @notice the address of the compiled `CoreLib` inside a Core runtime code (a push20 whose target has the library
    /// runtime code, own address masked out), zero when there is none
    function findLibrary(bytes memory code) internal view returns (address found) {
        bytes memory expected = vm.getDeployedCode("CoreLib.sol:CoreLib");
        bytes32 want = _tailHash(expected);
        for (uint256 i; i + 21 <= code.length; ++i) {
            if (code[i] != 0x73) continue;
            address cand;
            assembly ("memory-safe") {
                cand := shr(96, mload(add(add(code, 0x21), i)))
            }
            // the size is read without copying the code: only a candidate of the right size is copied and hashed
            if (cand.code.length == expected.length && expected.length >= 39 && _tailHash(cand.code) == want) return cand;
        }
    }

    /// @notice whether `lc` is the runtime code of the compiled `CoreLib`, its own address masked out
    function isCompiledLibrary(bytes memory lc) internal view returns (bool) {
        bytes memory expected = vm.getDeployedCode("CoreLib.sol:CoreLib");
        return lc.length == expected.length && lc.length >= 39 && _tailHash(lc) == _tailHash(expected);
    }

    /// @dev hash of library runtime code with its own address masked out. a library starts with
    /// `PUSH1 0x80 PUSH1 0x40 MSTORE ADDRESS PUSH32 <its own address>` (the guard against a direct call), the 32 bytes
    /// at offset 7 differ between the compiled code and a deployed copy
    function _tailHash(bytes memory b) private pure returns (bytes32 h) {
        bytes memory c = bytes.concat(b);
        assembly ("memory-safe") {
            mstore(add(add(c, 0x20), 7), 0)
            h := keccak256(add(c, 0x20), mload(c))
        }
    }

    /// @dev the router: the compiled code, created by the deployer right before the Core, the engine is the Core, the
    /// owner is the config owner, payees and tip as signed, the split start exactly the launch time plus the anti sniper window, not locked by the
    /// deploy. the owner can change every setting afterwards: ROUTER_CHANGED=1 turns those rows into warnings
    function _postRouter(LaunchConfig memory c, ICore core, address deployer, address coin_) private {
        IFeeRouter r = IFeeRouter(payable(core.FEE_SOURCE()));
        address ra = address(r);
        if (ra.code.length == 0) return;
        _check(
            "router: runtime code is the compiled FeeRouter",
            keccak256(ra.code) == keccak256(vm.getDeployedCode("FeeRouter.sol:FeeRouter")),
            vm.toString(ra)
        );
        if (deployer != address(0)) {
            (bool ok, uint256 n) = _coreNonce(address(core), deployer);
            _check(
                "router: created by the deployer one nonce before the Core",
                ok && vm.computeCreateAddress(deployer, n - 1) == ra,
                vm.toString(ra)
            );
        }
        bool ch = _routerChanged();
        _soft(ch, "router: engine is the Core", r.engine() == address(core), vm.toString(r.engine()), "ROUTER_CHANGED=1");
        _soft(ch, "router: owner is the config owner", r.owner() == c.owner, vm.toString(r.owner()), "ROUTER_CHANGED=1");
        _soft(ch, "router: not locked", !r.locked(), "the deploy does not lock the router", "ROUTER_CHANGED=1");
        _warn("warn: router has no pending owner", r.pendingOwner() == address(0), "an owner handover is offered");
        _postRouterSettings(c, r, ch, coin_);
    }

    function _postRouterSettings(LaunchConfig memory c, IFeeRouter r, bool ch, address coin_) private {
        (address[] memory who, uint32[] memory ppm) = r.payees();
        bool payees = who.length == 1 && who[0] == c.creatorPayee && ppm[0] == c.payeePpm;
        _soft(ch, "router: payee and share equal the config", payees, string.concat("payees ", vm.toString(who.length)), "ROUTER_CHANGED=1");
        _postSplitStart(c, r, ch, coin_);
        _info("router: split", r.splitOn() ? "on" : "not started, everything goes to the engine");
        _info("router: eth held", string.concat(vm.toString(address(r).balance), " wei, owed to payees ", vm.toString(r.totalOwed())));
    }

    /// @dev the split start is the launch time recorded by the factory plus the anti sniper window, exactly. a difference
    /// is a failure and is printed. zero (not set yet) is a warning only in a run that has not set it, i.e. the Deploy
    /// script and a Resume that sent the launch (`splitStartPending`): the next Resume sets it from the mined launch time
    function _postSplitStart(LaunchConfig memory c, IFeeRouter r, bool ch, address coin_) private {
        (, IArtCoinsFactoryV2.DeploymentInfoV2 memory info) = _deployment(c.stack.factory, coin_);
        uint256 want = uint256(info.launchedAt) + c.sniperSeconds;
        uint256 got = r.splitStart();
        string memory detail = string.concat("splitStart ", vm.toString(got), " want launchedAt plus window ", vm.toString(want));
        if (got != want && got != 0) {
            detail = string.concat(detail, got > want ? ", late by " : ", early by ", vm.toString(got > want ? got - want : want - got));
        }
        if (got == 0 && splitStartPending) {
            _warn("warn: router split start is not set yet, run Resume after the launch is mined", false, detail);
            return;
        }
        _soft(
            ch || r.splitOn(),
            "router: split start is the launch time plus the anti sniper window, exactly",
            info.launchedAt != 0 && got == want,
            detail,
            "ROUTER_CHANGED=1 or the split is on"
        );
    }

    /// @dev what a read back cannot cover, said in the output
    function _postUnreadable(LaunchConfig memory c) private {
        _info(
            "not readable on chain",
            "protocolBps argument, sniper fee config, the deploy fee paid, the salt itself"
        );
        _info("signoff: CONFIG_HASH", vm.toString(configHash(c)));
    }
}
