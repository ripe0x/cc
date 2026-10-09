// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// independent review of the artcoins port. `test_POC_*` prove a finding on the pinned fork, `test_held_*` are
/// attacks that failed. every number quoted in docs/REVIEW-port.md comes from a log line in this file.
/// a plain receive only bounty recipient, which the hook's `streamForward` probe survives
contract Sink {
    receive() external payable {}
}

/// swaps once in the real pool from inside the eth callback of a core payout, then flushes the fee router, so the
/// router pushes the fees into the core while the core is in the middle of a door
contract SwapOnReceive {
    TestSwapRouter public immutable router;
    PoolKey internal key;
    uint256 public swapEth;
    bool public fired;

    constructor(TestSwapRouter router_, PoolKey memory key_) {
        router = router_;
        key = key_;
    }

    function arm(uint256 eth) external {
        swapEth = eth;
        fired = false;
    }

    function sell(ICore c, uint256[] calldata ids) external {
        c.sellForEth(ids);
    }

    function compose(ICore c) external {
        c.compose();
    }

    function buyback(ICore c) external {
        c.buyback();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    IFeeRouter public feeRouter;

    function setFeeRouter(address r) external {
        feeRouter = IFeeRouter(payable(r));
    }

    receive() external payable {
        if (swapEth != 0 && !fired) {
            fired = true;
            router.swap{value: swapEth}(key, true, -int256(swapEth), address(this));
            // the v2 hook pays the fee router, whose flush is what lands the eth in the core mid door
            if (address(feeRouter) != address(0)) feeRouter.flush(address(this));
        }
    }
}

contract ReviewPort is Fixture {
    using stdStorage for StdStorage;

    address internal attacker;

    function setUp() public override {
        super.setUp();
        attacker = _user("attacker");
    }

    // ------------------------------------------------------------------ helpers

    function _forceBuyback(uint256 eth) internal {
        vm.deal(address(core), address(core).balance + eth);
        uint256 slot = stdstore.target(address(core)).sig("ethToBuyback()").find();
        vm.store(address(core), bytes32(slot), bytes32(core.ethToBuyback() + eth));
    }

    function _stockPool() internal {
        _skipSniperWindow();
        _buyCoin(_user("trader"), 20 ether);
    }

    // ------------------------------------------------------------------ P-1 open pool spoofs fee income (gone on v2)

    /// on v1 anyone could open a second pool on the live hook naming the core as bounty recipient, and the hook's push
    /// was booked as fee income. on v2 only a launcher (the factory) can open a pool on the hook, and the core books eth
    /// from the fee router only. nobody can open a pool on the hook, and eth the hook pushes to the core is not booked
    function test_FIXED_v2HookRefusesAPoolFromAStranger() public {
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(coin)), 0x800000, 60, IHooks(lc.stack.hook));
        vm.prank(attacker);
        vm.expectRevert();
        PM.initialize(k, 79228162514264337593543950336);
        // eth from the hook itself is accepted and left for skim
        vm.deal(lc.stack.hook, 1 ether);
        vm.prank(lc.stack.hook);
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(core.ethPot(), 0, "a hook push is not fee income");
    }

    // ------------------------------------------------------------------ held: sandwich and jit liquidity on the 1 eth slice

    function _burnOneSlice() internal returns (uint256 burned) {
        vm.roll(block.number + 30);
        uint256 supply = coin.totalSupply();
        vm.prank(keeper);
        core.buyback();
        burned = supply - coin.totalSupply();
    }

    function _sandwich(uint256 x) internal returns (int256 pnl, uint256 burnedAttacked, uint256 potGain) {
        vm.deal(attacker, x);
        vm.prank(attacker);
        router.swap{value: x}(launchKey, true, -int256(x), attacker);
        uint256 coinGot = coin.balanceOf(attacker);
        uint256 pot0 = core.ethPot();
        burnedAttacked = _burnOneSlice();
        potGain = core.ethPot() - pot0;
        uint256 out = _sellCoin(attacker, coinGot);
        pnl = int256(out) - int256(x);
    }

    function test_held_sandwichLosesToTheSkim() public {
        _stockPool();
        _forceBuyback(1 ether);
        uint256 snap = vm.snapshotState();
        uint256 base = _burnOneSlice();
        emit log_named_uint("coin burned by one slice, no attacker", base);
        vm.revertToState(snap);
        uint256[3] memory xs = [uint256(5 ether), 20 ether, 100 ether];
        for (uint256 i; i < 3; ++i) {
            snap = vm.snapshotState();
            (int256 pnl, uint256 burned, uint256 gain) = _sandwich(xs[i]);
            emit log_named_uint("front run eth", xs[i]);
            emit log_named_int("attacker net eth", pnl);
            emit log_named_uint("coin burned for the core", burned);
            emit log_named_uint("pot gain during buyback", gain);
            assertLt(pnl, 0, "sandwich loses");
            vm.revertToState(snap);
        }
    }

    function _spot() internal view returns (uint256 coinPerEthWad, int24 tick) {
        (uint160 sqrtP, int24 t,,) = StateLibrary.getSlot0(PM, launchKey.toId());
        coinPerEthWad = FullMath.mulDiv(FullMath.mulDiv(sqrtP, sqrtP, 1 << 64), 1e18, 1 << 128);
        tick = t;
    }

    /// v2 decision: the coin is restricted, so a stranger cannot put the coin into the pool as liquidity at all (the pool
    /// manager is not a holder it may pay). the just in time position that v1 had to price (the burn never got less
    /// coin for the slice) cannot be built, and the slice buys what it bought before
    function test_held_jitLiquidityCannotBeBuiltOnARestrictedCoin() public {
        _stockPool();
        _forceBuyback(1 ether);
        uint256 snap = vm.snapshotState();
        uint256 base = _burnOneSlice();
        vm.revertToState(snap);

        (, int24 tick) = _spot();
        int24 lo = (tick / 200) * 200 - 400;
        int24 hi = lo + 1200;
        TestLiquidityHelper lp = new TestLiquidityHelper();
        vm.deal(attacker, 1000 ether);
        deal(address(coin), attacker, 2e27);
        vm.startPrank(attacker);
        coin.approve(address(lp), type(uint256).max);
        vm.expectRevert();
        lp.modify{value: 500 ether}(launchKey, lo, hi, 4e24);
        vm.stopPrank();
        assertEq(_burnOneSlice(), base, "the slice buys the same coin with the attempt made");
    }

    // ------------------------------------------------------------------ P-2 exit auction: stale clock prices injected funds

    function _composeNext() internal returns (uint256 sid) {
        _fillEthPile(80);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
    }

    function _take(address who) internal returns (uint256 slice, uint256 coinIn) {
        (slice, coinIn) = core.exitAuctionQuote();
        vm.startPrank(who);
        coin.approve(address(core), type(uint256).max);
        core.buybackExit(type(uint256).max);
        vm.stopPrank();
    }

    /// regression for P-2. the clock used to restart only at an exactly empty pot, so an unsold remainder carried a
    /// decayed clock into injected funds. every injection now re anchors the curve at max(price now, start / 4) and
    /// restarts the clock, so the two arms price the injected slice the same
    function test_FIXED_staleClockNoLongerPricesInjectedFunds() public {
        _enterPhase2();
        _stockPool();
        Composed memory c1 = _composeOnce();
        uint256 sid2 = _composeNext();
        address taker = _user("taker");
        _buyCoin(taker, 5 ether);
        vm.warp(block.timestamp + 105 hours);
        core.exitStatement(c1.sid);
        uint256 full = uint256(core.settings().exitSliceCredits) * core.settings().avgScore * core.unitPerPoint();
        emit log_named_uint("xToBuyback after first exit, in slices x1000", core.xToBuyback() * 1000 / full);
        // the taker takes one full slice at an honest decayed price and the remainder stays unsold
        vm.warp(block.timestamp + 200 hours);
        _take(taker);
        uint256 remainder = core.xToBuyback();
        emit log_named_uint("remainder left, in slices x1000", remainder * 1000 / full);
        assertGt(remainder, 0);
        assertLt(remainder, full);
        uint256 snap = vm.snapshotState();

        // arm A: the remainder stays unsold, a matured statement is exited by anyone much later
        vm.warp(block.timestamp + 400 hours);
        uint256 startBefore = core.xStartPrice();
        assertLt(core.exitAuctionPrice(), startBefore / 1e6, "the leftover price decayed far below its start");
        core.exitStatement(sid2);
        assertEq(core.xStartTime(), block.timestamp, "the injection restarted the clock");
        assertEq(core.xStartPrice(), startBefore / 4, "the curve re anchored at the quarter floor");
        (uint256 sliceA, uint256 coinA) = core.exitAuctionQuote();
        emit log_named_uint("arm A: slice", sliceA);
        emit log_named_uint("arm A: coin the taker burns for a full slice", coinA);
        vm.revertToState(snap);

        // arm B: the remainder is sold first, so the pot hits zero and the injection restarts the clock
        vm.warp(block.timestamp + 400 hours);
        _take(taker);
        assertEq(core.xToBuyback(), 0);
        core.exitStatement(sid2);
        (uint256 sliceB, uint256 coinB) = core.exitAuctionQuote();
        emit log_named_uint("arm B: slice", sliceB);
        emit log_named_uint("arm B: coin the taker would burn for a full slice", coinB);
        assertEq(sliceA, sliceB, "same slice");
        assertEq(coinA, coinB, "injected funds are priced the same with or without a leftover remainder");
        assertGt(coinA, 1e24, "no longer sold at the stale decayed price");
    }

    // ------------------------------------------------------------------ P-3 opening price has no floor of precision

    function _phase2With(uint256 unit) internal {
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), unit);
        _setExitModule(address(mod));
    }

    function _setExitModuleReverts(uint256 unit) internal {
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), unit);
        vm.prank(owner);
        vm.expectRevert(ICore.BadModule.selector);
        core.setExitModule(address(mod));
    }

    /// regressions for P-3. the opening price is `SUPPLY * 1e18 / (20 * AVG_SCORE * unit)`. it was zero above unit
    /// 1.15e37 and 11 at 1e36. setting the module now reverts `BadModule` when it is below 1e12
    function test_FIXED_hugeUnitIsRejectedAtSetTime() public {
        _setExitModuleReverts(2e37);
        assertEq(core.exitModule(), address(0));
    }

    function test_FIXED_largeUnitIsRejectedAtSetTime() public {
        _setExitModuleReverts(1e36);
        assertEq(core.exitModule(), address(0));
    }

    function test_FIXED_unitAtTheBoundaryStillWorks() public {
        _phase2With(1e25);
        assertGe(core.xStartPrice(), 1e12);
    }

    /// the bound moves with the slice of the settings: at 1000 credits a slice a unit that was fine is too large
    function test_FIXED_theBoundFollowsTheSliceSetting() public {
        Settings memory s = core.settings();
        s.exitSliceCredits = 1000;
        _setSettings(s);
        // 1e45 / (1000 * 4.33e6 * 1e24) is 2.3e11, below 1e12
        _setExitModuleReverts(1e24);
        s.exitSliceCredits = 1;
        _setSettings(s);
        _phase2With(1e24);
        assertGe(core.xStartPrice(), 1e12);
    }

    // ------------------------------------------------------------------ P-5 forbidden targets

    /// regression for P-5: permit2, the v4 position manager and the universal router cannot become targets
    function test_FIXED_permit2AndRoutersAreForbiddenTargets() public {
        address[3] memory banned = [Mainnet.PERMIT2, Mainnet.POSITION_MANAGER, Mainnet.UNIVERSAL_ROUTER];
        for (uint256 i; i < banned.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addTarget(banned[i]);
            assertFalse(core.allowedTarget(banned[i]));
        }
    }

    // ------------------------------------------------------------------ P-4 launch hijack of the predicted coin (gone on v2)

    /// on v1 the coin address did not depend on the sender, so with an open factory anyone could copy the config, take
    /// the predicted address and bind the core to a pool that never pays it. on v2 `predictToken(sender, config)` folds
    /// the sender into the salt: a copy launched by another account lands elsewhere, and the real launch still lands on
    /// the address the core was built against. while the factory is deprecated a stranger cannot launch at all
    function test_FIXED_launchHijackCannotTakeThePredictedCoin() public {
        bytes32 salt = keccak256("hijack victim");
        address coreAt = vm.computeCreateAddress(owner, vm.getNonce(owner) + 1);
        address coinAt = predictCoin(owner, coreAt, "Victim", "VIC", salt);
        vm.startPrank(owner);
        ICore core2 = Prod.newCore(
            owner, coinAt, address(Prod.newController(coreAt, lc.sale)), lc.stack, lc.rateStart, lc.settings
        );
        vm.stopPrank();
        assertEq(address(core2), coreAt);

        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = buildConfig(owner, coreAt, creator, "Victim", "VIC", salt);
        uint256 fee = FACTORY.deployFee();
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        FACTORY.deployToken{value: fee}(cfg);

        // the factory opens: the copy by the attacker lands on its own address
        vm.prank(owner);
        FACTORY.setDeprecated(false);
        vm.prank(attacker);
        address stolen = FACTORY.deployToken{value: fee}(cfg);
        assertTrue(stolen != coinAt, "the sender is part of the address");

        // and the real launch still gets the predicted address
        vm.prank(owner);
        assertEq(FACTORY.deployTokenAsOwner{value: fee}(cfg, lc.protocolBps), coinAt);
        assertEq(core2.COIN(), coinAt);
    }

    // ------------------------------------------------------------------ held: hook push inside the core's own payouts

    function _assertClean(string memory what) internal view {
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), what);
    }

    /// a swap fired from the eth callback of a sell payout, a compose reimbursement and the keeper tip of the coin buyback. the
    /// hook pushes into `receive()` mid door, it is booked in full, and the books stay exact
    function test_held_swapInsidePayoutCallbacks() public {
        _stockPool();
        SwapOnReceive actor = new SwapOnReceive(router, launchKey);
        actor.setFeeRouter(address(feeRouter));
        vm.deal(address(actor), 50 ether);
        _fundPot(2 ether);
        _assertClean("start");

        uint256[] memory ids = _credits(address(actor), 80);
        vm.warp(block.timestamp + 40 hours);
        actor.arm(1 ether);
        uint256 pot0 = core.ethPot();
        actor.sell(core, _slice(ids, 0, 3));
        assertTrue(actor.fired(), "swap fired inside the payout");
        assertGt(core.ethPot(), pot0 - 1 ether, "bounty booked");
        _assertClean("after sell");

        uint256 sidBase = STATEMENTS.supply();
        _fillEthPile(80);
        vm.fee(0.2 gwei);
        actor.arm(1 ether);
        uint256 potC = core.ethPot();
        actor.compose(core);
        assertTrue(actor.fired(), "swap fired inside the reimbursement");
        assertGt(STATEMENTS.supply(), sidBase);
        assertGt(core.ethPot(), potC - 1, "bounty booked");
        _assertClean("after compose");

        // the keeper tip of the coin buyback is paid to the caller, who swaps from inside it
        _forceBuyback(1 ether);
        vm.roll(block.number + 30);
        actor.arm(1 ether);
        uint256 potB = core.ethPot();
        uint256 tipBefore = address(actor).balance;
        actor.buyback(core);
        assertTrue(actor.fired(), "swap fired inside the keeper tip");
        assertGt(address(actor).balance + 1 ether, tipBefore, "the tip was paid");
        assertGt(core.ethPot(), potB, "bounty booked");
        _assertClean("after buyback tip");
    }

    function _slice(uint256[] memory a, uint256 from, uint256 n) internal pure returns (uint256[] memory r) {
        r = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            r[i] = a[from + i];
        }
    }
}
