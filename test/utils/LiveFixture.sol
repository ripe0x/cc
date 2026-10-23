// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./Fixture.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {IArtCoinsTokenV2} from "../../src/interfaces/ArtCoinsV2.sol";
import {IPhase2BalanceTreasury} from "../../src/interfaces/IPhase2BalanceTreasury.sol";
import {RATE_SCORE} from "../../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TestSwapRouter} from "./TestSwapRouter.sol";
import {V2Stack} from "./V2Stack.sol";
import {LiveStageB} from "./LiveStageB.sol";

/// @notice the owner rule of the phase 2 live fork work: a contract that exists on mainnet is bound at its live
/// address with its live code and state, never redeployed. this fixture forks mainnet at a recent pinned block and
/// binds the live Core, its live ControllerV1, its live coin and the live BALANCE token, so the phase 2 suites run
/// against the real system. only the phase 2 contracts that are not yet on mainnet (Phase2BalanceTreasury,
/// ProRataRedemptionPolicy, ControllerV2, the push split) are created fresh by the suites.
///
/// it reuses the `Fixture` helper surface: `_credits`, `_fundPot`, `_buyCoin`, `_composeOnce`, `_fillEthPile`,
/// `_setSettings`, `_setBalanceModule` and the rest read live mainnet contracts (the CreditStrategy, Credits,
/// Statements, the pool manager) exactly as they do on any mainnet fork, so binding the live Core in `setUp` is enough.
/// the helpers that only the fresh deploy path needs (`predictCoin`, `_launchCore`, `buildConfig`) read `lc`/`v2`,
/// which this fixture leaves unset; the phase 2 suites never call them.
///
/// the live BALANCE token carries an "ink" rule: a balance written by `deal` reverts (`EmptyInk`), so balances must
/// arrive by a real transfer or release. `_fundBalance` impersonates a real holder and transfers, the only way to
/// place live BALANCE on a test account or a fresh treasury.
abstract contract LiveFixture is Fixture {
    // ------------------------------------------------------------------ live mainnet addresses

    address internal constant LIVE_CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;
    address internal constant LIVE_BALANCE_TOKEN = 0x3620540c994433D7B4a628C46d2ED5F92572eA07;
    address internal constant LIVE_SEAPORT_ADAPTER = 0x40302D497436bcC03e0Af2138Ec325C68DF3B0c8;
    address internal constant LIVE_STRATEGY_ADAPTER = 0x5757788D0A6dF507dba064d66532F0b630Be1dc9;
    address internal constant LIVE_RENDERER = 0x0D2022F8D780884A1B46de156CBfc4f36423504c;

    /// the live BALANCE token runtime code hash, asserted in `setUp` so a token that changed between pinning and the
    /// run fails loudly instead of running against the wrong code
    bytes32 internal constant LIVE_BALANCE_TOKEN_CODEHASH =
        0x83c6085628758fb522e28b5abb7c24253b6d8667a8b2b23d2c3542deabc25de7;

    /// @dev the pinned fork block, overridable by `LIVE_FORK_BLOCK`. post launch with the BALANCE token live and its
    /// ordinary transfers already open. re-pinned to a recent block before each owner send, since the public gateway
    /// serves state only within a proof window behind its head
    uint256 internal constant LIVE_FORK_BLOCK = 26242960;

    /// a real BALANCE holder, used by `_fundBalance` to place live tokens respecting the token's ink rule. an auction
    /// withdrawer seen in the launch logs; overridable by `LIVE_BALANCE_HOLDER`
    address internal constant LIVE_BALANCE_HOLDER = 0x5F7a8fb8cc29e795ba19191Dd74D69A90cDADB88;

    /// the live BALANCE token, the module's payout and conversion asset
    address internal liveBalanceToken;

    function setUp() public virtual override {
        uint256 forkBlock = _liveForkBlock();
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);

        core = ICore(payable(LIVE_CORE));
        ctl = IControllerV1(core.controller());
        coin = IArtCoinsTokenV2(core.COIN());
        owner = core.owner();
        liveBalanceToken = LIVE_BALANCE_TOKEN;

        assertGt(LIVE_CORE.code.length, 0, "the live Core has code at the pin");
        assertGt(address(ctl).code.length, 0, "the live controller has code");
        assertGt(address(coin).code.length, 0, "the live coin has code");
        assertTrue(owner != address(0), "the live Core has an owner");
        assertGt(liveBalanceToken.code.length, 0, "the live BALANCE token has code");
        assertEq(
            liveBalanceToken.codehash, LIVE_BALANCE_TOKEN_CODEHASH, "the live BALANCE token runtime equals the pin"
        );

        // the launch adapters and the renderer the Core approves, bound live for the build identity checks
        seaportAdapter = LIVE_SEAPORT_ADAPTER;
        strategyAdapter = LIVE_STRATEGY_ADAPTER;
        renderer = LIVE_RENDERER;

        // namespaced accounts with no code on the fork, as the Fixture helpers expect
        deployer = _user("deployer");
        creator = _user("creator");
        keeper = _user("keeper");
        seller = _user("seller");
        funder = _user("funder");
        router = new TestSwapRouter();
        vm.deal(owner, owner.balance + 1 ether);

        // the test raw listing adapter the owner approves, as the base fixture sets up: a test helper priced by its
        // call data, used by `_buyRaw` and the forbidden target checks
        rawAdapter = _user("rawAdapter");
        vm.etch(rawAdapter, vm.getDeployedCode("RawListingAdapter.sol:RawListingAdapter"));
        vm.prank(owner);
        core.addAdapter(rawAdapter);

        // the live coin pool key (native eth / coin under the coin hook), the route `_buyCoin` and `_fundPot` swap
        launchKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(coin)),
            fee: core.POOL_FEE(),
            tickSpacing: core.TICK_SPACING(),
            hooks: IHooks(core.HOOK())
        });
        poolId = keccak256(abi.encode(launchKey));
        launchTime = block.timestamp;

        // LIVE_STAGE=B: the owner's stage B sends, run through the production scripts, so `ctl` is ControllerV2 and
        // the treasury is the selected module with the settings patch applied
        if (_liveStageB()) {
            LiveStageB.State memory st = LiveStageB.run(address(core), liveBalanceToken);
            ctl = IControllerV1(st.controllerV2);
            treasury = IPhase2BalanceTreasury(st.treasury);
            assertEq(core.controller(), st.controllerV2, "stage B: ControllerV2 is the controller");
            assertEq(core.balanceModule(), st.treasury, "stage B: the treasury is the module");
            assertEq(core.artist(), st.split, "stage B: the split is the artist");
            // the owner's Statement sales switch (a stage C step), so suites that sell Statements run in this state
            vm.prank(owner);
            IStatementSales(st.controllerV2).setStatementSales(true);
        }
    }

    /// @notice the fork block of this suite: `LIVE_FORK_BLOCK` or the pin. a suite pinned elsewhere overrides this;
    /// `vm.setEnv` would leak its block into every later suite of the same forge process
    function _liveForkBlock() internal view virtual returns (uint256) {
        return vm.envOr("LIVE_FORK_BLOCK", LIVE_FORK_BLOCK);
    }

    // ------------------------------------------------------------------ two live states

    /// @notice true when the suite runs the stage B live state (LIVE_STAGE=B): the production stage A and B path is
    /// live at setUp (ControllerV2 selected as `ctl`, the treasury selected, the settings patch applied). a test whose
    /// subject exists only on ControllerV1 skips itself in stage B with `if (_liveStageB()) return;` and a one line reason
    function _liveStageB() internal view returns (bool) {
        return keccak256(bytes(vm.envOr("LIVE_STAGE", string("")))) == keccak256("B");
    }

    /// @notice a Statement purchase. in stage B ControllerV2 starts with Statement sales off (the owner opens them in
    /// stage C), so a test that sells a Statement has the owner open them first, the real setter path
    function _buy(address who, uint256 sid) internal virtual override returns (uint256 price) {
        if (_liveStageB() && !IStatementSales(address(ctl)).statementSalesEnabled()) {
            vm.prank(owner);
            IStatementSales(address(ctl)).setStatementSales(true);
        }
        return super._buy(who, sid);
    }

    // ------------------------------------------------------------------ live BALANCE funding (the ink rule)

    /// @notice places `amount` of live BALANCE on `to` by impersonating a real holder, the only way to fund an account
    /// or a fresh treasury: a balance written by `deal` reverts on this token (`EmptyInk`). transfers are open at the
    /// pin, so the holder's transfer passes the token's lock. the treasury reads `custody()` as its own token balance,
    /// so a transfer into it funds its working balance directly, the same as a mint on the stand in did
    function _fundBalance(address to, uint256 amount) internal {
        address holder = vm.envOr("LIVE_BALANCE_HOLDER", LIVE_BALANCE_HOLDER);
        require(IERC20Lite(liveBalanceToken).balanceOf(holder) >= amount, "the BALANCE holder is short for the test");
        vm.prank(holder);
        IERC20Lite(liveBalanceToken).transfer(to, amount);
    }

    /// @notice the balance of `who` in the live BALANCE token
    function _balanceOf(address who) internal view returns (uint256) {
        return IERC20Lite(liveBalanceToken).balanceOf(who);
    }

    // ------------------------------------------------------------------ pot funding on the live Core

    /// @notice funds the eth pot directly through `fund`, to `eth` spendable above the live reserve. the Fixture funds
    /// by generating swap fees, which undershoots on the live Core: the live reserveWei (0.1 ETH) is locked below every
    /// sale, and the live fee settings route most skim to the buyback and burn pots, so the swap estimate never reaches
    /// the spendable target. a direct `fund` of `eth + reserve` is deterministic and leaves `eth` spendable. the reserve
    /// is a live setting, never zeroed to force a pass
    function _fundPot(uint256 eth) internal virtual override {
        uint256 target = eth + core.reserve();
        if (core.ethPot() < target) {
            uint256 need = target - core.ethPot();
            vm.deal(address(this), address(this).balance + need);
            core.fund{value: need}();
        }
        assertGe(core.ethPot(), target, "pot not funded above the reserve");
    }

    // ------------------------------------------------------------------ live statements and credits

    /// @notice a Statement the live Core holds that the live controller finds eligible (`atFloor`), so a conversion
    /// through a selected treasury runs without composing a fresh page. the live Core holds a steady set of these at
    /// the pin; the first eligible one is returned
    function _eligibleHeldStatement() internal view returns (uint256 sid) {
        uint256[] memory held = core.heldStatements();
        for (uint256 i; i < held.length; ++i) {
            if (ctl.atFloor(held[i])) return held[i];
        }
        revert("no eligible held Statement at the pin: re-pin LIVE_FORK_BLOCK");
    }

    /// @notice idempotent approval of the test RawListingAdapter so `_buyRaw` works. `LiveFixture.setUp` already sets
    /// and approves `rawAdapter`, so this is a no-op there; kept so a suite that calls it in its own setUp stays correct
    function _approveRawAdapter() internal {
        if (rawAdapter != address(0) && core.allowedAdapter(rawAdapter)) return;
        rawAdapter = _user("rawAdapter");
        vm.etch(rawAdapter, vm.getDeployedCode("RawListingAdapter.sol:RawListingAdapter"));
        vm.prank(owner);
        core.addAdapter(rawAdapter);
    }

    // ------------------------------------------------------------------ fresh successor config (brief: a migration successor is not yet deployed)

    /// @notice populates `lc` from the live system so the inherited fresh core helpers (`_successorCore`, `_launchCore`,
    /// `buildConfig`) build a successor of the live coin on the live stack. the source Core stays the live one; only the
    /// not yet deployed successor is fresh. call once in a suite's setUp before a fresh core helper. the salt is distinct
    /// from the live launch so a fresh coin prediction does not collide
    function _initLiveConfig() internal {
        V2Stack.Stack memory st = V2Stack.attach();
        require(st.hook == core.HOOK(), "v2 record hook does not match the live coin hook: wrong STACK record");
        lc = defaultConfig();
        lc.owner = owner;
        lc.creator = creator;
        lc.artist = creator;
        lc.payee = _user("payee");
        lc.name = "Successor Coin";
        lc.symbol = "SUCC";
        lc.salt = keccak256("credits-engine live successor");
        lc.rateStart = core.RATE_START();
        lc.settings = core.settings();
        lc.stack.hook = core.HOOK();
        lc.stack.factory = st.factory;
        lc.stack.locker = st.locker;
        lc.stack.escrow = st.escrow;
        lc.stack.tickSpacing = core.TICK_SPACING();
        lc.stack.poolFee = core.POOL_FEE();
        lc.mevModule = st.mev;
    }

    // ------------------------------------------------------------------ live phase 2 entry (treasury on the live token)

    using StateLibrary for IPoolManager;

    /// the live eth / BALANCE pool the owner selects in stage C: fee 35,000, spacing 350, hookless (docs/RUNBOOK.md,
    /// the phase 2 rehearsal; confirmed deepest hookless of the pools opened in the token's first hour). native eth is
    /// currency0
    uint24 internal constant LIVE_BALANCE_POOL_FEE = 35_000;
    int24 internal constant LIVE_BALANCE_POOL_SPACING = 350;

    /// the default working balance `_enterPhase2` funds into the treasury, from the live holder (full at every setUp
    /// because each test re-forks at the pin). large enough for the ordinary few credit balance fills; a suite that
    /// needs more calls `_fundTreasuryWorking`
    uint256 internal constant LIVE_WORKING_FUND = 10_000 ether;

    /// the fresh phase 2 treasury selected on the live Core, the balance module of every ported balance suite
    IPhase2BalanceTreasury internal treasury;

    /// @notice the live phase 2 balance side, replacing the stand in module and token of the base `_enterPhase2`. a
    /// fresh ProRataRedemptionPolicy and Phase2BalanceTreasury are created on the live BALANCE token from their via_ir
    /// artifacts (the production deploy path, so the test profile does not recompile them), selected by the owner, their
    /// switches set to the launch state (conversions and working payments on, CC redemption off, decision 258), and the
    /// treasury funded a working balance. no balance pool key is set here, so the suites that assert the key-unset state
    /// still see it; a suite that needs the key calls `_setLiveBalancePool`
    function _enterPhase2() internal virtual override {
        // in stage B the production treasury is already selected; a second one would not be the launch state
        if (address(treasury) == address(0)) {
            address policyAddr = vm.deployCode("ProRataRedemptionPolicy.sol:ProRataRedemptionPolicy");
            treasury = IPhase2BalanceTreasury(
                vm.deployCode(
                    "Phase2BalanceTreasury.sol:Phase2BalanceTreasury",
                    abi.encode(address(core), liveBalanceToken, policyAddr, address(0))
                )
            );
            vm.prank(owner);
            core.setBalanceModule(address(treasury));
        }
        _setSwitches(true, true);
        vm.prank(owner);
        treasury.setSwitches(true, true, false);
        _fundTreasuryWorking(LIVE_WORKING_FUND);
    }

    /// @notice the treasury's balance token holding, the base of its working funds (the live analogue of the stand in
    /// module's holding). the Core checks this rose on a redemption and falls on a payout
    function _moduleCustody() internal view returns (uint256) {
        return IERC20Lite(liveBalanceToken).balanceOf(address(treasury));
    }

    /// @notice funds `amount` of live BALANCE into the treasury, raising its working funds (`available`)
    function _fundTreasuryWorking(uint256 amount) internal {
        _acquireBalance(address(treasury), amount);
    }

    /// @notice places `amount` of live BALANCE on `to`, from the live holder when it covers the amount, else by buying
    /// exact out from the live pool with dealt ETH (ETH has no ink rule, so this is unbounded). the only ways to place
    /// the non mintable live token on a test account or the treasury
    function _acquireBalance(address to, uint256 amount) internal {
        if (amount == 0) return;
        address holder = vm.envOr("LIVE_BALANCE_HOLDER", LIVE_BALANCE_HOLDER);
        uint256 have = IERC20Lite(liveBalanceToken).balanceOf(holder);
        if (have >= amount) {
            vm.prank(holder);
            IERC20Lite(liveBalanceToken).transfer(to, amount);
            return;
        }
        // draw the holder dry, then buy any remainder from the pool with dealt ETH (the token's own reserve cannot be
        // a second holder: it carries no transferable ink, so a prank transfer from it reverts)
        if (have > 0) {
            vm.prank(holder);
            IERC20Lite(liveBalanceToken).transfer(to, have);
        }
        _buyBalanceExactOut(to, amount - have);
    }

    /// @notice buys exactly `amount` of live BALANCE from the live pool with dealt ETH and sends it to `to`. unused ETH
    /// is refunded by the router
    function _buyBalanceExactOut(address to, uint256 amount) internal {
        vm.deal(address(this), address(this).balance + 1_000_000 ether);
        router.swap{value: 1_000_000 ether}(_liveBalanceKey(), true, int256(amount), to);
    }

    /// @notice the live eth / BALANCE pool key
    function _liveBalanceKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(liveBalanceToken),
            fee: LIVE_BALANCE_POOL_FEE,
            tickSpacing: LIVE_BALANCE_POOL_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @notice points the controller at the live eth / BALANCE pool at its live spot, the owner's stage C action
    function _setLiveBalancePool() internal {
        (uint160 sp,,,) = PM.getSlot0(_liveBalanceKey().toId());
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(liveBalanceToken),
            fee: LIVE_BALANCE_POOL_FEE,
            tickSpacing: LIVE_BALANCE_POOL_SPACING,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(k, spotOf(sp));
    }

    /// @notice the live pool spot, wei per 1e18 BALANCE base units
    function _liveSpot() internal view returns (uint256) {
        (uint160 sp,,,) = PM.getSlot0(_liveBalanceKey().toId());
        return spotOf(sp);
    }

    // ------------------------------------------------------------------ live overrides of the pile and compose helpers

    /// @notice fills the eth pile against live state. the base helper sizes the pot at `ethRate * n`, which assumes a
    /// 100 point credit; live Credits carry high and varied scores, so the pot is sized from the sum of the score scaled
    /// bids at the restated opening rate instead, and funded past it so no sale in the batch hits `PotTooSmall`
    function _fillEthPile(uint256 n) internal virtual override returns (uint256[] memory ids) {
        ids = _credits(seller, n);
        uint256 opening = core.RATE_START();
        if (core.rateAtCheckpoint() > opening) {
            vm.prank(owner);
            core.setRate(opening);
        }
        uint256 rate = core.rateAtCheckpoint();
        uint256 need = core.reserve();
        for (uint256 i; i < n; ++i) {
            need += rate * _scoreOf(ids[i]) / RATE_SCORE;
        }
        if (core.ethPot() < need * 2) _fundPot(need * 2);
        for (uint256 i; i < n; ++i) {
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
        }
    }

    /// @notice composes one page against live state. the live controller runs with the credit sale on, so `nextPage` is
    /// ready only once the oldest page is past the credit window; the live Core holds a steady pile of pre launch
    /// Credits, so a warp past the window makes it composable. then the base compose runs unchanged
    function _composeOnce() internal virtual override returns (Composed memory c) {
        if (!isComposed) _warpComposeReady();
        return super._composeOnce();
    }

    /// @notice warps hour by hour until the controller's `nextPage` is ready (the oldest page past the credit window),
    /// bounded so a pile that can never compose fails loudly
    function _warpComposeReady() internal {
        for (uint256 i; i < 500; ++i) {
            (bool ready,,) = ctl.nextPage();
            if (ready) return;
            vm.warp(block.timestamp + 1 hours);
        }
        revert("live pile never reaches a composable page: check creditWindow and the live pile");
    }

}

interface IStatementSales {
    function statementSalesEnabled() external view returns (bool);
    function setStatementSales(bool enabled) external;
}

interface IERC20Lite {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}
