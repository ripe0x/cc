// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV2} from "../src/interfaces/IControllerV2.sol";
import {IControllerV3} from "../src/interfaces/IControllerV3.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {IBalanceTreasuryV2} from "../src/interfaces/IBalanceTreasuryV2.sol";
import {IMarketRedeemer} from "../src/interfaces/IMarketRedeemer.sol";
import {CreditSale, Quote, IdleLoosening, BalanceBid, CcQuote, RedeemerState, Mainnet} from "../src/interfaces/Interfaces.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice the phase 3 owner sends (docs/specs/PHASE3.md), one `STEP` per run, each with a preview, the sends and a
/// readback. every send is `vm.startBroadcast`, so the no-keystore dry run (`--sender <owner>`, no `--broadcast`)
/// simulates exactly the sends and prints their gas.
///
/// - `deploy`: ProRataRedeemer (fee 0), BalanceTreasuryV2 (v1 as predecessor), ControllerV3 (the live credit sale,
///   the live quote at step 900, Statement ask 1.1x, Statement redemption delay 1 hour, idle loosening at cap 0) and
///   MarketRedeemer (premium 500 bps). nothing live changes
/// - `migrate` (`TREASURY_V2`, `CONTROLLER_V3`, `MARKET_REDEEMER`): v1 switches off, `setBalanceModule(v2)`, v1
///   `migrateTo(v2)`, the v2 settings, redeemer 2 registered with its caps and sweep share, v2 conversion and working
///   payments on (bid and redeemers off), `sweep`, the V3 pool key, CC reference and Statement sales,
///   `setController(V3)`. the v1 `migrateTo` requires its successor to be the selected module, so the module changes
///   before the funds move
/// - `bid`: v2 bid on. run at least the Core's `returnLockSeconds` after `setController(V3)`: credits ControllerV2 sold
///   before the switch carry no V3 sale record
/// - `readback`: the checks alone
///
/// `STEP=deploy forge script script/Phase3.s.sol --rpc-url https://gateway.tenderly.co/public/mainnet --sender <owner>`
/// is the dry run; the send adds `--broadcast --slow --account ripe0x`
contract Phase3 is Script, LaunchChecks {
    error NotOwner(address owner, address signer);
    error CreateFailed(string name);

    address public constant MAINNET_CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;

    /// the owner's choices: decisions 279 to 288
    struct Params {
        uint256 cushion;
        BalanceBid bid;
        uint16 bidShareBps;
        uint16 proRataShareBps;
        uint128 proRataPerPeriod;
        uint16 statementSaleMultiplierBps;
        uint32 statementRedeemDelaySeconds;
        uint16 quoteStepBps;
        IdleLoosening idle;
        uint16 marketPremiumBps;
        uint128 marketPerCall;
        uint128 marketPerPeriod;
        uint128 marketLifetime;
        uint16 marketShareBps;
        CcQuote ccQuote;
    }

    struct Deployed {
        address redeemer;
        address treasury;
        address controller;
        address market;
    }

    function params() public pure returns (Params memory p) {
        p.cushion = 150_000 ether;
        p.bid = BalanceBid({
            floorBps: 8_000,
            capBps: 10_000,
            climbBps: 50,
            stepSeconds: 600,
            dropPer100PointsBps: 29,
            overEthBps: 500,
            maxPerCall: 20_000 ether,
            maxPerPeriod: 60_000 ether
        });
        p.bidShareBps = 2_500;
        p.proRataShareBps = 0;
        p.proRataPerPeriod = 50_000 ether;
        p.statementSaleMultiplierBps = 11_000;
        p.statementRedeemDelaySeconds = 3_600;
        p.quoteStepBps = 900;
        p.idle = IdleLoosening({stepSeconds: 600, bps: 0, capBps: 0});
        p.marketPremiumBps = 500;
        p.marketPerCall = 5_000 ether;
        p.marketPerPeriod = 20_000 ether;
        p.marketLifetime = type(uint128).max;
        p.marketShareBps = 7_500;
        p.ccQuote = CcQuote({
            rateBpsPerHour: 6_000,
            stepBps: 900,
            maxStale: 3_600,
            minSeconds: 600,
            avgSeconds: 3_600,
            minLiquidity: 1.5e22
        });
    }

    function run() external {
        address core = vm.envOr("CORE", MAINNET_CORE);
        bytes32 step = keccak256(bytes(vm.envString("STEP")));
        Params memory p = params();
        if (step == keccak256("deploy")) {
            deploy(core, p, true);
            return;
        }
        Deployed memory d = Deployed({
            redeemer: address(0),
            treasury: vm.envAddress("TREASURY_V2"),
            controller: vm.envAddress("CONTROLLER_V3"),
            market: vm.envAddress("MARKET_REDEEMER")
        });
        d.redeemer = IBalanceTreasuryV2(d.treasury).proRataRedeemer();
        if (step == keccak256("migrate")) migrate(core, d, p, true);
        else if (step == keccak256("bid")) enableBid(core, d, true);
        else readback(core, d, p);
    }

    /// @notice the sends of `deploy`. `broadcast` false creates from this contract, as a test does
    function deploy(address core, Params memory p, bool broadcast) public returns (Deployed memory d) {
        ICore c = ICore(payable(core));
        IControllerV2 v2c = IControllerV2(c.controller());
        address v1 = c.balanceModule();
        CreditSale memory credit = CreditSale({
            saleOn: v2c.creditSaleOn(),
            window: v2c.creditWindow(),
            spreadBps: v2c.creditSpreadBps(),
            startBps: v2c.creditStartBps()
        });
        Quote memory q;
        (q.referenceRateBpsPerHour, q.referenceStepBps, q.tolBps, q.referenceMaxStale, q.referenceMinSeconds, q.minLiquidity)
        = v2c.quote();
        q.referenceStepBps = p.quoteStepBps;
        _reset();
        _info("preview: chain / block", string.concat(vm.toString(block.chainid), " / ", vm.toString(block.number)));
        _info("preview: owner", vm.toString(c.owner()));
        _code("preview: v1 treasury (the predecessor) has code", v1);
        _check(
            "preview: band (1+step)(1+tol)(1-margin) < 1",
            (10_000 + uint256(q.referenceStepBps)) * (10_000 + q.tolBps) * (10_000 - c.settings().balanceBidMarginBps)
                < 1e12,
            vm.toString(q.referenceStepBps)
        );
        _print("phase 3 deploy preview");
        _require();
        _start(c, broadcast);
        d.redeemer = _create("ProRataRedeemer", abi.encode(uint16(0)));
        d.treasury =
            _create("BalanceTreasuryV2", abi.encode(core, c.balanceToken(), d.redeemer, p.proRataPerPeriod, v1));
        d.controller = _create(
            "ControllerV3",
            abi.encode(core, credit, q, uint32(p.statementSaleMultiplierBps), p.statementRedeemDelaySeconds, p.idle)
        );
        d.market = _create("MarketRedeemer", abi.encode(core, p.marketPremiumBps));
        _stop(broadcast);
        console.log(
            string.concat(
                'record: {"redeemer":"',
                vm.toString(d.redeemer),
                '","treasuryV2":"',
                vm.toString(d.treasury),
                '","controllerV3":"',
                vm.toString(d.controller),
                '","marketRedeemer":"',
                vm.toString(d.market),
                '"}'
            )
        );
    }

    /// @notice the sends of `migrate`, then `readback`
    function migrate(address core, Deployed memory d, Params memory p, bool broadcast) public {
        ICore c = ICore(payable(core));
        _migratePreview(c, d);
        (IControllerV3.PoolKey memory balKey, uint256 balSpot) = _balanceKey(c);
        IControllerV3.PoolKey memory ccKey = IControllerV3.PoolKey({
            currency0: IControllerV3.Currency.wrap(address(0)),
            currency1: IControllerV3.Currency.wrap(c.COIN()),
            fee: c.POOL_FEE(),
            tickSpacing: c.TICK_SPACING(),
            hooks: c.HOOK()
        });
        uint256 ccSpot = _ccSpot(ccKey);
        _start(c, broadcast);
        _moveTreasury(c, d, p);
        IControllerV3 v3 = IControllerV3(d.controller);
        v3.setBalancePoolKey(balKey, balSpot);
        v3.setCcPoolKey(ccKey, ccSpot);
        v3.setCcQuote(p.ccQuote);
        v3.setStatementSales(true);
        c.setController(d.controller);
        _stop(broadcast);
        readback(core, d, p);
    }

    function _migratePreview(ICore c, Deployed memory d) private {
        IPhase2BalanceTreasury v1 = IPhase2BalanceTreasury(c.balanceModule());
        IBalanceTreasuryV2 t = IBalanceTreasuryV2(d.treasury);
        IControllerV3 v3 = IControllerV3(d.controller);
        _reset();
        _eq("preview: v2 core", t.core(), address(c));
        _eq("preview: v2 predecessor is the live module", t.predecessor(), address(v1));
        _eq("preview: V3 CORE", v3.CORE(), address(c));
        _check("preview: v2 switches off", !t.conversionEnabled() && !t.workingPaymentsEnabled() && !t.bidEnabled(), "");
        _check("preview: V3 pool key unset", !v3.balancePoolKeySet(), "");
        _check("preview: Core module and controller unlocked", !c.balanceModuleLocked() && !c.controllerLocked(), "");
        _check("preview: v1 CC redemption off", !v1.ccRedemptionEnabled(), "");
        _eq("preview: MarketRedeemer core", IMarketRedeemer(d.market).core(), address(c));
        _info("preview: v1 custody / claim reserve", string.concat(vm.toString(v1.custody()), " / ", vm.toString(v1.claimReserve())));
        _print("phase 3 migrate preview");
        _require();
    }

    /// @dev the live ControllerV2 pool key and spot, carried to V3
    function _balanceKey(ICore c) private view returns (IControllerV3.PoolKey memory k, uint256 spot) {
        IControllerV2 v2c = IControllerV2(c.controller());
        (IControllerV2.Currency c0, IControllerV2.Currency c1, uint24 fee, int24 spacing, address hooks) =
            v2c.balancePoolKey();
        k = IControllerV3.PoolKey({
            currency0: IControllerV3.Currency.wrap(IControllerV2.Currency.unwrap(c0)),
            currency1: IControllerV3.Currency.wrap(IControllerV2.Currency.unwrap(c1)),
            fee: fee,
            tickSpacing: spacing,
            hooks: hooks
        });
        (spot,) = v2c.spotPrice();
    }

    /// @dev v1 off, the module switch, v1 `migrateTo`, the v2 settings and redeemer 2, v2 on, the sweep
    function _moveTreasury(ICore c, Deployed memory d, Params memory p) private {
        IPhase2BalanceTreasury v1 = IPhase2BalanceTreasury(c.balanceModule());
        IBalanceTreasuryV2 t = IBalanceTreasuryV2(d.treasury);
        v1.setSwitches(false, false, false);
        c.setBalanceModule(d.treasury);
        v1.migrateTo(d.treasury);
        t.setCushion(p.cushion);
        t.setBid(p.bid);
        t.setBidShare(p.bidShareBps);
        if (p.proRataShareBps != 0) t.setRedeemerShare(d.redeemer, p.proRataShareBps);
        t.registerRedeemer(d.market, p.marketPerCall, p.marketPerPeriod, p.marketLifetime);
        t.setRedeemerShare(d.market, p.marketShareBps);
        t.setSwitches(true, true, false);
        t.sweep();
    }

    /// @notice the send of `bid`
    function enableBid(address core, Deployed memory d, bool broadcast) public {
        ICore c = ICore(payable(core));
        _start(c, broadcast);
        IBalanceTreasuryV2(d.treasury).setSwitches(true, true, true);
        _stop(broadcast);
    }

    /// @notice the live state after `migrate`: the module and controller, the moved funds, the v2 settings and every
    /// view the Core, keeper, indexer and web read
    function readback(address core, Deployed memory d, Params memory p) public {
        ICore c = ICore(payable(core));
        IBalanceTreasuryV2 t = IBalanceTreasuryV2(d.treasury);
        IControllerV3 v3 = IControllerV3(d.controller);
        IPhase2BalanceTreasury v1 = IPhase2BalanceTreasury(t.predecessor());
        _reset();
        _pin("ControllerV3", BUILD_HASH_CONTROLLER_V3, d.controller);
        _pin("BalanceTreasuryV2", BUILD_HASH_TREASURY_V2, d.treasury);
        _pin("ProRataRedeemer", BUILD_HASH_PRO_RATA_REDEEMER, d.redeemer);
        _pin("MarketRedeemer", BUILD_HASH_MARKET_REDEEMER, d.market);
        _eq("Core module is v2", c.balanceModule(), d.treasury);
        _eq("Core controller is V3", c.controller(), d.controller);
        _check("v1 migrated, holding only its debt", v1.migrated() && v1.custody() == v1.totalOwed(), vm.toString(v1.custody()));
        _check("v2 solvent", t.solvent(), vm.toString(t.custody()));
        uint256 bucket = t.redeemers(d.redeemer).bucket;
        _info("v2 custody / pro-rata bucket / bid budget", string.concat(vm.toString(t.custody()), " / ", vm.toString(bucket), " / ", vm.toString(t.bidBudget())));
        _eq("v2 cushion", t.cushion(), p.cushion);
        _check("v2 working at or above the cushion", t.working() >= t.cushion(), vm.toString(t.working()));
        _check("v2 conversion and working payments on, redeemers off", t.conversionEnabled() && t.workingPaymentsEnabled() && !t.ccRedemptionEnabled(), "");
        _check("v2 available answers", t.available() == t.working(), vm.toString(t.available()));
        (uint256 vb, bool okb) = v3.valuePerPoint(false);
        (uint256 vs, bool oks) = v3.valuePerPoint(true);
        _check("V3 valuePerPoint answers both sides", okb && oks && vb != 0 && vs >= vb * 10_000 / (10_000 + 700), "");
        _check("Core ethPrice nonzero", c.ethPrice() != 0, vm.toString(c.ethPrice()));
        _check("V3 Statement sales on, ask 1.1x, delay 1 hour", v3.statementSalesEnabled() && v3.statementSaleMultiplierBps() == p.statementSaleMultiplierBps && v3.statementRedeemDelaySeconds() == p.statementRedeemDelaySeconds, "");
        (, uint16 step,,,,) = v3.quote();
        _eq("V3 quote step", step, p.quoteStepBps);
        _check("V3 idle loosening within its cap", v3.idleLoosenBps() <= p.idle.capBps, vm.toString(v3.idleLoosenBps()));
        _check("V3 legacy views", v3.markupBps() == p.statementSaleMultiplierBps && v3.decayHours() == 1 && v3.ageEligibilityOn(), "");
        (bool ready,,) = v3.nextPage();
        _info("V3 nextPage", ready ? "ready" : "not ready");
        _info("v2 bid now (bps of par)", vm.toString(t.bidBpsNow()));
        _readbackRedeemers(t, IControllerV3(d.controller), d, p);
        _print("phase 3 readback");
        _require();
    }

    /// @dev the bid band, the sweep shares, redeemer 2 and the CC reference
    function _readbackRedeemers(IBalanceTreasuryV2 t, IControllerV3 v3, Deployed memory d, Params memory p) private {
        (uint16 floorBps, uint16 capBps,,,,,,) = t.bid();
        _check("v2 bid 8,000 to 10,000 bps of par", floorBps == p.bid.floorBps && capBps == p.bid.capBps, "");
        RedeemerState memory r2 = t.redeemers(d.market);
        _check(
            "v2 sweep shares: bid 2,500, redeemer 2 7,500, redeemer 1 0",
            t.bidShareBps() == p.bidShareBps && r2.shareBps == p.marketShareBps
                && t.redeemers(d.redeemer).shareBps == p.proRataShareBps,
            ""
        );
        _check(
            "redeemer 2 registered, off, caps",
            r2.registered && !r2.on && r2.perCall == p.marketPerCall && r2.perPeriod == p.marketPerPeriod,
            ""
        );
        _info("redeemer 2 bucket", vm.toString(r2.bucket));
        _eq("redeemer 2 premium", IMarketRedeemer(d.market).premiumBps(), p.marketPremiumBps);
        (uint256 ccRef, bool okCc) = v3.ccPrice();
        _check("V3 CC reference set and usable", v3.ccPoolKeySet() && okCc, vm.toString(ccRef));
        (uint256 per1e18, bool okM) = IMarketRedeemer(d.market).preview(1e18);
        _check("redeemer 2 prices a burn", okM && per1e18 != 0, vm.toString(per1e18));
    }

    /// @dev out/ equals the pinned build and the live code equals out/, immutables masked
    function _pin(string memory name, bytes32 want, address at) private {
        _check(string.concat("build: ", name, " out/ equals the pin"), artifactHash(name) == want, name);
        _check(string.concat("build: ", name, " live code is the pinned build"), runtimeMatchesArtifact(at, name), vm.toString(at));
    }

    using StateLibrary for IPoolManager;

    /// @dev the live spot of the CC pool, wei per 1e18 CC, the expected spot of `setCcPoolKey`
    function _ccSpot(IControllerV3.PoolKey memory k) private view returns (uint256) {
        (uint160 sqrtP,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(PoolId.wrap(keccak256(abi.encode(k))));
        uint256 q = FixedPoint96.Q96;
        return (1e18 * q / sqrtP) * q / sqrtP;
    }

    function _start(ICore c, bool broadcast) private {
        if (broadcast) {
            vm.startBroadcast();
            (, address signer,) = vm.readCallers();
            if (signer != c.owner()) revert NotOwner(c.owner(), signer);
        } else {
            vm.startPrank(c.owner());
        }
    }

    function _stop(bool broadcast) private {
        if (broadcast) vm.stopBroadcast();
        else vm.stopPrank();
    }

    /// @dev a plain CREATE of artifact `name`, which `forge script` broadcasts as a deployment of the signer
    function _create(string memory name, bytes memory args) private returns (address at) {
        bytes memory init = abi.encodePacked(vm.getCode(string.concat(name, ".sol:", name)), args);
        assembly {
            at := create(0, add(init, 0x20), mload(init))
        }
        if (at.code.length == 0) revert CreateFailed(name);
    }
}
