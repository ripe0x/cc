// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Core} from "../src/Core.sol";
import {Lane, Mainnet} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsSkimHook, IPreSwapStream, IArtCoinsMevSkim} from "../src/interfaces/ArtCoins.sol";
import {SwapMidListing, SwapMidExit} from "./attackers/SwapMidCall.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";

/// shared helpers for the fee, buyback, auction and tax suites. every swap goes through the real pool
abstract contract FeeBase is Fixture {
    using stdStorage for StdStorage;

    enum Kind {
        BuyExactIn,
        BuyExactOut,
        SellExactIn,
        SellExactOut
    }

    /// @dev what one swap did to the core, the creator escrow and the pool manager
    struct Flow {
        uint256 gross;
        uint256 potRise;
        uint256 balanceRise;
        uint256 escrowRise;
        uint256 skimVolume;
        uint256 skimBounty;
        uint256 skimProtocol;
        uint256 skimReferral;
    }

    address internal trader;

    function setUp() public virtual override {
        super.setUp();
        trader = _user("trader");
        vm.deal(trader, 1000 ether);
    }

    /// @dev runs one swap of `kind`. `amount` is eth in for BuyExactIn, coin out for BuyExactOut, coin in for
    /// SellExactIn and eth out for SellExactOut. the gross eth notional is measured from the swap, not from the hook
    function _flow(Kind kind, uint256 amount, bytes memory data) internal returns (Flow memory f) {
        uint256 pot = core.ethPot();
        uint256 bal = address(core).balance;
        uint256 esc = ESCROW.availableFees(creator, address(0));
        uint256 pm = address(PM).balance;
        if (kind == Kind.SellExactIn || kind == Kind.SellExactOut) {
            vm.prank(trader);
            coin.approve(address(router), type(uint256).max);
        }
        vm.recordLogs();
        vm.startPrank(trader);
        if (kind == Kind.BuyExactIn) {
            router.swapWithData{value: amount}(launchKey, true, -int256(amount), trader, data);
            f.gross = amount;
        } else if (kind == Kind.BuyExactOut) {
            BalanceDelta d = router.swapWithData{value: 500 ether}(launchKey, true, int256(amount), trader, data);
            f.gross = uint256(uint128(-d.amount0()));
        } else if (kind == Kind.SellExactIn) {
            router.swapWithData(launchKey, false, -int256(amount), trader, data);
            f.gross = pm - address(PM).balance;
        } else {
            router.swapWithData(launchKey, false, int256(amount), trader, data);
            f.gross = pm - address(PM).balance;
        }
        vm.stopPrank();
        f.potRise = core.ethPot() - pot;
        f.balanceRise = address(core).balance - bal;
        f.escrowRise = ESCROW.availableFees(creator, address(0)) - esc;
        _readSkim(f, vm.getRecordedLogs());
    }

    function _readSkim(Flow memory f, Vm.Log[] memory logs) internal pure {
        bytes32 sig = keccak256("SkimSplit(bytes32,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == Mainnet.SKIM_HOOK && logs[i].topics[0] == sig) {
                (f.skimVolume, f.skimBounty, f.skimProtocol, f.skimReferral) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
    }

    /// @dev steady state expectation for a gross eth notional: 10 points of skim, 95 percent of it to the core
    function _expected(uint256 gross) internal pure returns (uint256 toCore, uint256 toCreator) {
        uint256 skim = gross * 10_000 / 100_000;
        toCore = skim * 9500 / 10_000;
        toCreator = skim - toCore;
    }

    /// @dev moves past the sniper window, then gives the trader coin and the pool about 18 eth of depth
    function _stock() internal {
        _skipSniperWindow();
        _buyCoin(trader, 20 ether);
    }

    /// @dev the eth buyback pot gets filled the real way: the core sells a composed statement at auction
    function _fillEthBuyback() internal returns (uint256 toBuyback) {
        Composed memory c = _composeOnce();
        uint256 price = core.priceOf(c.sid);
        address buyer = _user("statement buyer");
        vm.deal(buyer, price);
        uint256 before = core.ethToBuyback();
        vm.prank(buyer);
        core.buyStatement{value: price}(c.sid);
        toBuyback = core.ethToBuyback() - before;
    }
}

/// fee flow of the real skim hook into the core and the creator escrow
contract FeeFlowTest is FeeBase {
    function _checkSteady(Kind kind, uint256 amount) internal {
        Flow memory f = _flow(kind, amount, "");
        (uint256 toCore, uint256 toCreator) = _expected(f.gross);
        // the formulas round down in two steps and the exact out kinds measure the notional after the skim
        assertApproxEqAbs(f.potRise, toCore, 2, "pot is 9.5 points of the gross eth notional");
        assertApproxEqAbs(f.escrowRise, toCreator, 2, "creator escrow is 0.5 points");
        // the hook's own books agree to the wei, and nothing reaches the core unbooked
        assertEq(f.potRise, f.skimBounty, "pot equals the hook bounty leg");
        assertEq(f.escrowRise, f.skimProtocol, "escrow equals the hook protocol leg");
        assertEq(f.balanceRise, f.potRise, "nothing unbooked");
        assertEq(f.skimReferral, 0);
        assertGt(f.potRise, 0);
    }

    function test_feesBuyExactIn() public {
        _stock();
        _checkSteady(Kind.BuyExactIn, 3 ether);
        // an exact figure: 1 eth in is 0.095 to the core and 0.005 to the creator
        Flow memory f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertEq(f.potRise, 0.095 ether);
        assertEq(f.escrowRise, 0.005 ether);
    }

    function test_feesBuyExactOut() public {
        _stock();
        _checkSteady(Kind.BuyExactOut, 1_000_000e18);
    }

    function test_feesSellExactIn() public {
        _stock();
        _checkSteady(Kind.SellExactIn, coin.balanceOf(trader) / 4);
    }

    function test_feesSellExactOut() public {
        _stock();
        _checkSteady(Kind.SellExactOut, 0.5 ether);
    }

    function test_creatorClaimsFromTheRealEscrow() public {
        _stock();
        _flow(Kind.BuyExactIn, 10 ether, "");
        uint256 owed = ESCROW.availableFees(creator, address(0));
        assertGe(owed, 0.05 ether);
        uint256 before = creator.balance;
        ESCROW.claim(creator, address(0));
        assertEq(creator.balance - before, owed, "claim pays the creator");
        assertEq(ESCROW.availableFees(creator, address(0)), 0);
    }

    /// the extra of the anti sniper window lands in the pot, the creator keeps exactly 0.5 points
    function test_sniperWindowExtraLandsInThePot() public {
        uint256 bps = IArtCoinsMevSkim(Mainnet.MEV_LINEAR_SKIM).currentSkimBps(poolId);
        assertEq(bps, 90_000);
        Flow memory f = _flow(Kind.BuyExactIn, 1 ether, "");
        uint256 base = 1 ether * 10_000 / 100_000;
        uint256 creatorShare = base - base * 9500 / 10_000;
        assertEq(f.escrowRise, creatorShare, "creator share does not grow in the window");
        assertEq(f.potRise, 1 ether * bps / 100_000 - creatorShare, "the whole extra goes to the pot");
        assertEq(f.potRise, 0.895 ether);

        // halfway through the window the rate has decayed to 50 percent
        vm.warp(launchTime + SNIPER_WINDOW / 2);
        bps = IArtCoinsMevSkim(Mainnet.MEV_LINEAR_SKIM).currentSkimBps(poolId);
        assertEq(bps, 50_000);
        f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertEq(f.potRise, 1 ether * bps / 100_000 - creatorShare);

        // sells pay the extra too
        f = _flow(Kind.SellExactIn, coin.balanceOf(trader) / 4, "");
        bps = IArtCoinsMevSkim(Mainnet.MEV_LINEAR_SKIM).currentSkimBps(poolId);
        assertApproxEqAbs(f.potRise, f.gross * bps / 100_000 - (f.gross / 10 - f.gross / 10 * 9500 / 10_000), 2);

        _skipSniperWindow();
        f = _flow(Kind.BuyExactIn, 1 ether, "");
        assertEq(f.potRise, 0.095 ether, "steady state after the window");
    }

    /// the rate is checkpointed when the fee arrives, before the pot grows
    function test_rateCheckpointsOnFeeReceipt() public {
        _stock();
        _fundPot(1 ether);
        vm.warp(block.timestamp + 6 hours);
        uint256 rateBefore = core.ethRate();
        assertGt(rateBefore, core.RATE_START(), "the rate climbed while funded");
        assertLt(core.checkpointTime(), block.timestamp);
        _flow(Kind.BuyExactIn, 1 ether, "");
        assertEq(core.checkpointTime(), block.timestamp, "checkpoint time moved to the fee");
        assertEq(core.rateAtCheckpoint(), rateBefore, "the climbed rate was locked in before the pot grew");
        assertTrue(core.funded());
    }

    /// a swap that carries a referrer cannot brick and cannot reduce the core's share, whatever the cap
    function test_referralCannotBrickOrReduceTheCoreShare() public {
        _stock();
        address ref = _user("referrer");
        Flow memory plain = _flow(Kind.BuyExactIn, 2 ether, "");
        // cap is zero at launch: the referrer gets nothing and nothing changes
        Flow memory f = _flow(Kind.BuyExactIn, 2 ether, _referralData(ref, 250));
        assertEq(f.potRise, plain.potRise);
        assertEq(f.escrowRise, plain.escrowRise);
        assertEq(f.skimReferral, 0);
        // garbage hook data is ignored, not reverted
        f = _flow(Kind.BuyExactIn, 2 ether, hex"deadbeef");
        assertEq(f.potRise, plain.potRise);

        // the token admin raises the cap to the hook maximum. the referral comes out of the creator leg only and
        // lands in the core's notify, as unbooked eth that `skim` books later
        vm.prank(owner);
        IArtCoinsSkimHook(Mainnet.SKIM_HOOK).setMaxReferralBpsOfVolume(launchKey, 1000);
        f = _flow(Kind.BuyExactIn, 2 ether, _referralData(ref, 250));
        assertEq(f.skimReferral, 2 ether * 250 / 100_000, "0.25 percent of volume");
        assertEq(f.potRise, plain.potRise, "the core share is untouched");
        assertEq(f.escrowRise, plain.escrowRise - f.skimReferral, "the creator leg paid the referral");
        assertEq(f.balanceRise, f.potRise + f.skimReferral, "the referral sits unbooked in the core");
        core.skim();
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "skim books it");

        // a request above the creator leg is clamped to it, still without touching the core
        f = _flow(Kind.SellExactIn, coin.balanceOf(trader) / 4, _referralData(ref, 1000));
        assertEq(f.potRise, f.skimBounty);
        assertEq(f.escrowRise, 0, "the whole creator leg went to the referral");
        assertEq(f.skimProtocol, 0);
        assertGt(f.skimReferral, 0);
    }
}

/// `receive()` is the hook's push target. a revert there bricks every swap in the pool, so it must never revert
contract ReceiveTest is FeeBase {
    using stdStorage for StdStorage;
    using FixedPointMathLib for uint256;

    uint256 internal constant TWENTY_YEARS = 20 * 365 days;

    function _hookSend(uint256 amount) internal returns (bool ok) {
        vm.deal(Mainnet.SKIM_HOOK, Mainnet.SKIM_HOOK.balance + amount);
        vm.prank(Mainnet.SKIM_HOOK);
        (ok,) = address(core).call{value: amount}("");
    }

    function _solventNow() internal view {
        assertLe(core.ethPot() + core.ethToBuyback(), address(core).balance);
    }

    /// pots of any size, any gap in time, funded or not: the hook push is always accepted and booked in full
    function testFuzz_receiveNeverReverts(uint96 a, uint32 gap1, uint96 b, uint256 gap2, uint96 c) public {
        gap2 = bound(gap2, 0, TWENTY_YEARS);
        uint256 booked;
        assertTrue(_hookSend(a));
        booked += a;
        vm.warp(block.timestamp + gap1);
        assertTrue(_hookSend(b));
        booked += b;
        vm.warp(block.timestamp + gap2);
        assertTrue(_hookSend(c));
        booked += c;
        assertEq(core.ethPot(), booked, "every push booked");
        assertEq(core.checkpointTime(), block.timestamp);
        _solventNow();
    }

    /// the worst case for the rate loop: a huge pot, the rate pushed down to its smallest value, twenty years
    /// without a checkpoint. the climb stops at the cap after a few dozen day long steps
    function test_receiveGasAfterTwentyYearsAtTheWorstRate() public {
        assertTrue(_hookSend(1 ether));
        assertTrue(core.funded());
        uint256 slot = stdstore.target(address(core)).sig("rateAtCheckpoint()").find();
        vm.store(address(core), bytes32(slot), bytes32(uint256(1)));
        assertTrue(_hookSend(100_000_000 ether));
        vm.warp(block.timestamp + TWENTY_YEARS);
        vm.deal(Mainnet.SKIM_HOOK, 1 ether);
        vm.prank(Mainnet.SKIM_HOOK);
        uint256 g = gasleft();
        (bool ok,) = address(core).call{value: 1 ether}("");
        g -= gasleft();
        assertTrue(ok);
        emit log_named_uint("receive gas, 20 years, rate 1, pot 1e8 eth", g);
        assertLt(g, 400_000);
        assertEq(core.rateAtCheckpoint(), (core.ethPot() - 1 ether) * 10_000 / core.AVG_SCORE(), "climbed to the cap");
    }

    function test_receiveGasRoutine() public {
        assertTrue(_hookSend(1 ether));
        vm.warp(block.timestamp + 1 hours);
        vm.deal(Mainnet.SKIM_HOOK, 1 ether);
        vm.prank(Mainnet.SKIM_HOOK);
        uint256 g = gasleft();
        (bool ok,) = address(core).call{value: 0.1 ether}("");
        g -= gasleft();
        assertTrue(ok);
        emit log_named_uint("receive gas, one hour since checkpoint", g);
        vm.prank(Mainnet.SKIM_HOOK);
        g = gasleft();
        (ok,) = address(core).call{value: 0.1 ether}("");
        g -= gasleft();
        emit log_named_uint("receive gas, same block", g);
        assertLt(g, 100_000);
    }

    /// what `receive()` adds to a swap, measured as the same swap against a core replaced by a bare `receive(){}`.
    /// the core is made cold first, as in a fresh transaction
    function test_receiveGasAddedToASwap() public {
        _stock();
        _fundPot(1 ether);
        vm.warp(block.timestamp + 1 hours);
        uint256 snap = vm.snapshotState();
        vm.cool(address(core));
        uint256 withCore = _swapGas();
        vm.revertToState(snap);
        vm.etch(address(core), address(new BareReceiver()).code);
        vm.cool(address(core));
        uint256 bare = _swapGas();
        emit log_named_uint("swap gas with the core", withCore);
        emit log_named_uint("swap gas with a bare receive", bare);
        emit log_named_uint("added by the core", withCore - bare);
        assertLt(withCore - bare, 60_000);
    }

    function _swapGas() internal returns (uint256 g) {
        vm.deal(trader, 2 ether);
        vm.prank(trader);
        g = gasleft();
        router.swap{value: 1 ether}(launchKey, true, -1 ether, trader);
        g -= gasleft();
    }

    /// anything that is not the hook is accepted and books nothing until `skim`
    function test_nonHookEthIsAcceptedButNotBooked() public {
        address anyone = _user("anyone");
        vm.deal(anyone, 5 ether);
        vm.prank(anyone);
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(core.ethPot(), 0);
        assertEq(address(core).balance, 1 ether);
        core.skim();
        assertEq(core.ethPot(), 1 ether);
        // zero value sends from anyone are fine too
        vm.prank(anyone);
        (ok,) = address(core).call("");
        assertTrue(ok);
    }

    /// the core has no fallback, so the hook's pre swap `streamForward` call reverts, which the hook catches
    function test_streamForwardProbeReverts() public {
        vm.deal(address(core), 5 ether);
        (bool ok,) = address(core).call(abi.encodeCall(IPreSwapStream.streamForward, ()));
        assertFalse(ok);
        (ok,) = address(core).call(hex"deadbeef");
        assertFalse(ok);
    }

    /// the hook calls `streamForward` on its bounty recipient before every swap once it holds 0.01 eth. swaps keep
    /// working at 0.01 eth, at the pot a real run builds, and at 1000 eth
    function test_swapsKeepWorkingWithALargeCoreBalance() public {
        _skipSniperWindow();
        uint256[3] memory held = [uint256(0.01 ether), 0.5 ether, 1000 ether];
        for (uint256 i; i < held.length; ++i) {
            vm.deal(address(core), held[i]);
            Flow memory f = _flow(Kind.BuyExactIn, 1 ether, "");
            assertEq(f.potRise, 0.095 ether);
            uint256 coinBal = coin.balanceOf(trader);
            f = _flow(Kind.SellExactIn, coinBal / 10, "");
            assertGt(f.potRise, 0);
            assertGe(address(core).balance, held[i], "nothing left the core");
        }
        core.skim();
        _solventNow();
        assertEq(address(core).balance, core.ethPot(), "everything is booked");
    }

    /// the hook pushes eth into the core while `buyListing` is measuring the cost. nothing is booked then, the
    /// eth just lowers the measured cost, which keeps the pot and the balance consistent
    function test_receiveMidBuyListing() public {
        SwapMidListing t = new SwapMidListing(router, address(core), launchKey);
        _allow(address(t));
        _stock();
        _fundPot(1 ether);
        uint256 id = _credits(address(t), 1)[0];
        uint256 ceiling = core.ceilingOf(id);
        uint256 swapEth = ceiling * 5;
        vm.deal(address(t), swapEth);
        t.arm(id, swapEth);

        uint256 pot = core.ethPot();
        uint256 balance = address(core).balance;
        uint256 bounty = swapEth * 10_000 / 100_000 * 9500 / 10_000;
        uint256 cost = ceiling - bounty;
        uint256 tip = (1000 * (ceiling - cost) / 10_000).min(200 * cost / 10_000);
        vm.prank(keeper);
        core.buyListing(ceiling, hex"deadbeef", id, address(t));
        assertEq(CREDITS.ownerOf(id), address(core));
        assertEq(core.ethPot(), pot - cost - tip, "the hook push was not booked mid measurement");
        // the push lowered the measured cost, so pot and balance moved together and nothing is left unbooked
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "consistent");
        assertEq(address(core).balance, balance - cost - tip);
    }

    /// the same during `exitStatement`
    function test_receiveMidExit() public {
        _stock();
        MockExitToken token = new MockExitToken("Exit Token", "XT");
        SwapMidExit m = new SwapMidExit(token, UNIT, router, launchKey, 1 ether);
        vm.deal(address(m), 1 ether);
        _timelock(Core.Action.SetExitModule, abi.encode(address(m)));
        Composed memory c = _composeOnce();
        vm.warp(block.timestamp + core.AUCTION_LENGTH());
        uint256 pot = core.ethPot();
        core.exitStatement(c.sid);
        assertEq(core.ethPot(), pot, "nothing booked mid exit");
        assertEq(address(core).balance - core.ethPot() - core.ethToBuyback(), 0.095 ether);
        assertGt(core.xToBuyback(), 0);
        core.skim();
        assertEq(core.ethPot() + core.ethToBuyback(), address(core).balance);
    }
}

contract BareReceiver {
    receive() external payable {}
}

/// the eth buyback of the core against the real pool: it buys coin and burns it on the token
contract BuybackTest is FeeBase {
    using stdStorage for StdStorage;
    using FixedPointMathLib for uint256;

    struct Before {
        uint256 supply;
        uint256 pmCoin;
        uint256 deadCoin;
        uint256 pot;
        uint256 pool;
        uint256 escrow;
        uint256 keeperEth;
    }

    function _before() internal view returns (Before memory b) {
        b.supply = coin.totalSupply();
        b.pmCoin = coin.balanceOf(Mainnet.POOL_MANAGER);
        b.deadCoin = coin.balanceOf(DEAD);
        b.pot = core.ethPot();
        b.pool = core.ethToBuyback();
        b.escrow = ESCROW.availableFees(creator, address(0));
        b.keeperEth = keeper.balance;
    }

    /// @dev puts `eth` into the buyback pot directly, backed by real eth in the core. only for sizing tests
    function _forcePot(uint256 eth) internal {
        vm.deal(address(core), address(core).balance + eth);
        uint256 slot = stdstore.target(address(core)).sig("ethToBuyback()").find();
        vm.store(address(core), bytes32(slot), bytes32(core.ethToBuyback() + eth));
    }

    function test_buybackBurnsTheCoinBoughtAndBooksTheSkim() public {
        _stock();
        uint256 toBuyback = _fillEthBuyback();
        assertGt(toBuyback, 0);
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "clean books before");
        Before memory b = _before();
        uint256 slice = b.pool.min(core.BUYBACK_SLICE());
        uint256 tip0 = slice * core.KEEPER_TIP_BPS() / 10_000;
        uint256 budget = slice - tip0;

        vm.recordLogs();
        vm.prank(keeper);
        core.buyback();
        Flow memory f;
        _readSkim(f, vm.getRecordedLogs());

        // the coin left the pool and was burned: total supply fell by exactly what the pool gave up
        uint256 bought = b.pmCoin - coin.balanceOf(Mainnet.POOL_MANAGER);
        assertGt(bought, 0);
        assertEq(b.supply - coin.totalSupply(), bought, "supply fell by exactly the coin bought");
        assertEq(coin.balanceOf(address(core)), 0, "the core holds no coin");
        assertEq(coin.balanceOf(DEAD), b.deadCoin, "the buyback take is untaxed");
        // eth side: the slice left the pot, the tip went to the caller
        assertEq(core.ethToBuyback(), b.pool - slice, "buyback pot fell by the slice");
        assertEq(keeper.balance - b.keeperEth, tip0, "tip to the caller");
        assertEq(tip0, slice * 50 / 10_000);
        // skim on the buyback comes back to the pot, 9.5 points of the eth spent
        (uint256 toCore, uint256 toCreator) = _expected(budget);
        assertEq(core.ethPot() - b.pot, toCore, "9.5 points returned to the pot");
        assertEq(core.ethPot() - b.pot, f.skimBounty);
        assertEq(ESCROW.availableFees(creator, address(0)) - b.escrow, toCreator);
        assertEq(f.skimVolume, budget);
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "nothing left unbooked");
    }

    function test_buybackDelayAndSliceCap() public {
        _stock();
        _forcePot(2.5 ether);
        Before memory b = _before();
        vm.prank(keeper);
        core.buyback();
        assertEq(core.ethToBuyback(), b.pool - 1 ether, "one slice of 1 eth");
        assertEq(core.lastBuybackBlock(), block.number);

        vm.prank(keeper);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + core.BUYBACK_DELAY() - 1);
        vm.prank(keeper);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 1);
        vm.prank(keeper);
        core.buyback();
        assertEq(core.ethToBuyback(), b.pool - 2 ether);

        // the last slice is what is left
        vm.roll(block.number + core.BUYBACK_DELAY());
        vm.prank(keeper);
        core.buyback();
        assertEq(core.ethToBuyback(), 0);
        vm.roll(block.number + core.BUYBACK_DELAY());
        vm.expectRevert(Core.NothingToBuy.selector);
        core.buyback();
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback());
    }

    /// inside the sniper window the buyback still burns and books, and the skim returns almost all of the spend
    function test_buybackInTheSniperWindowStillBurnsAndBooks() public {
        _forcePot(1 ether);
        Before memory b = _before();
        vm.prank(keeper);
        core.buyback();
        assertGt(b.supply - coin.totalSupply(), 0);
        assertEq(coin.balanceOf(DEAD), b.deadCoin);
        // inside the window 90 points of the spend return, less the creator's 0.5
        assertGt(core.ethPot() - b.pot, 0.8 ether);
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback());
    }
}

/// the dutch auction that sells the exit token buyback pot for coin, which it burns. phase 2, with the stand ins
contract AuctionTest is FeeBase {
    using FixedPointMathLib for uint256;

    address internal taker;

    function setUp() public override {
        super.setUp();
        taker = _user("taker");
    }

    /// @dev phase 2 with `xToBuyback` filled by a real compose, auction and exit of a statement
    function _auction() internal returns (uint256 received) {
        _enterPhase2();
        _stock();
        received = _fillExitBuyback();
        assertGt(core.xToBuyback(), 0);
    }

    function _fullSlice() internal view returns (uint256) {
        return 20 * core.AVG_SCORE() * UNIT;
    }

    /// @dev the taker buys coin in the real pool and approves the core
    function _equipTaker(uint256 ethIn) internal {
        _buyCoin(taker, ethIn);
        vm.prank(taker);
        coin.approve(address(core), type(uint256).max);
    }

    /// @dev warps an hour at a time until a fill costs no more than what the taker holds
    function _waitUntilAffordable() internal returns (uint256 slice, uint256 coinIn) {
        for (uint256 i; i < 2000; ++i) {
            (slice, coinIn) = core.exitAuctionQuote();
            if (coinIn <= coin.balanceOf(taker)) return (slice, coinIn);
            vm.warp(block.timestamp + 1 hours);
        }
        revert("never affordable");
    }

    function _fill(uint256 maxCoinIn) internal {
        vm.prank(taker);
        core.buybackExit(maxCoinIn);
    }

    // ------------------------------------------------------------------ price

    function test_openingPriceAsksTheWholeSupplyForOneSlice() public {
        _auction();
        assertEq(core.xStartPrice(), 1_000_000_000e18 * 1e18 / _fullSlice());
        (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
        assertEq(slice, _fullSlice().min(core.xToBuyback()));
        // a full slice costs the whole coin supply at the opening price
        assertApproxEqRel(coinIn, 1_000_000_000e18 * slice / _fullSlice(), 1e9);
    }

    function test_priceHalvesEverySixHours() public {
        _auction();
        uint256 p0 = core.exitAuctionPrice();
        assertEq(p0, core.xStartPrice(), "no time has passed since the pot filled");
        vm.warp(block.timestamp + 6 hours);
        assertEq(core.exitAuctionPrice(), p0 >> 1);
        vm.warp(block.timestamp + 6 hours);
        assertEq(core.exitAuctionPrice(), p0 >> 2);
        vm.warp(block.timestamp + 36 hours);
        assertEq(core.exitAuctionPrice(), p0 >> 8);
        // continuous in between: three hours is a factor of 2^-0.5
        vm.warp(block.timestamp + 3 hours);
        assertApproxEqRel(core.exitAuctionPrice(), (p0 >> 8) * 707_106_781_186_547_524 / 1e18, 1e9);
        // strictly decreasing minute by minute
        uint256 last = core.exitAuctionPrice();
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 1 minutes);
            assertLt(core.exitAuctionPrice(), last);
            last = core.exitAuctionPrice();
        }
    }

    // ------------------------------------------------------------------ fills

    function test_fillQuoteMatchesExecutionAndBurnsTheTakersCoin() public {
        _auction();
        _equipTaker(40 ether);
        (uint256 slice, uint256 coinIn) = _waitUntilAffordable();
        assertGt(coinIn, 0);
        uint256 coinBefore = coin.balanceOf(taker);
        uint256 supplyBefore = coin.totalSupply();
        uint256 deadBefore = coin.balanceOf(DEAD);
        uint256 poolBefore = core.xToBuyback();
        _fill(coinIn);
        assertEq(coinBefore - coin.balanceOf(taker), coinIn, "burnFrom took the quoted coin from the taker");
        assertEq(supplyBefore - coin.totalSupply(), coinIn, "it was burned, total supply fell");
        assertEq(coin.balanceOf(DEAD), deadBefore, "not sent to the dead address");
        assertEq(xt.balanceOf(taker), slice, "the taker got the slice");
        assertEq(core.xToBuyback(), poolBefore - slice);
        assertEq(coin.balanceOf(address(core)), 0);
        _solvent();
    }

    function test_maxCoinInGuard() public {
        _auction();
        _equipTaker(40 ether);
        (, uint256 coinIn) = _waitUntilAffordable();
        vm.prank(taker);
        vm.expectRevert(Core.Slippage.selector);
        core.buybackExit(coinIn - 1);
        // the quote only falls with time, so a stale cap stays safe, and it fills at exactly the quote
        _fill(coinIn);

        // another fill restarts the auction at twice its clearing price, so the old cap no longer covers it
        (, uint256 next) = core.exitAuctionQuote();
        assertGt(next, coinIn, "restart is above the last price");
        vm.prank(taker);
        vm.expectRevert(Core.Slippage.selector);
        core.buybackExit(coinIn);
    }

    function test_takerNeedsToApproveAndOnlyTheCallersCoinIsBurned() public {
        _auction();
        _buyCoin(taker, 40 ether);
        address victim = _user("victim");
        _buyCoin(victim, 40 ether);
        vm.prank(victim);
        coin.approve(address(core), type(uint256).max);
        (, uint256 coinIn) = _waitUntilAffordable();
        uint256 victimBefore = coin.balanceOf(victim);
        // the taker never approved the core: the fill reverts, and the victim's approval does not help the taker
        vm.prank(taker);
        vm.expectRevert();
        core.buybackExit(coinIn);
        assertEq(coin.balanceOf(victim), victimBefore);
        // a taker with no coin cannot fill at a non zero price
        address broke = _user("broke");
        vm.prank(broke);
        vm.expectRevert();
        core.buybackExit(type(uint256).max);
    }

    function test_sliceSizing() public {
        _auction();
        _equipTaker(60 ether);
        uint256 full = _fullSlice();
        uint256 pool = core.xToBuyback();
        assertGt(pool, full, "the fixture pot is more than one slice");
        uint256 sliced;
        for (uint256 i; i < 6 && core.xToBuyback() != 0; ++i) {
            (uint256 slice, uint256 coinIn) = _waitUntilAffordable();
            assertEq(slice, full.min(core.xToBuyback()), "min(pot, 20 average credits)");
            _fill(coinIn);
            sliced += slice;
        }
        assertEq(core.xToBuyback(), 0);
        assertEq(sliced, pool);
        assertEq(xt.balanceOf(taker), pool);
        vm.prank(taker);
        vm.expectRevert(Core.NothingToBuy.selector);
        core.buybackExit(type(uint256).max);
    }

    function test_restartAtDoubleTheClearingPrice() public {
        _auction();
        _equipTaker(60 ether);
        _waitUntilAffordable();
        uint256 clearing = core.exitAuctionPrice();
        uint256 prevStart = core.xStartPrice();
        assertGt(2 * clearing, prevStart / 4, "a fill near a fair price, so the double wins over the quarter");
        (, uint256 coinIn) = core.exitAuctionQuote();
        _fill(coinIn);
        assertEq(core.xStartPrice(), 2 * clearing);
        assertEq(core.xStartTime(), block.timestamp);
        assertEq(core.exitAuctionPrice(), 2 * clearing, "restarts at twice the price it just cleared at");
        vm.warp(block.timestamp + 6 hours);
        assertEq(core.exitAuctionPrice(), clearing, "and halves again from there");
    }

    function test_noExitModuleOrNothingToSell() public {
        vm.expectRevert(Core.NoExitModule.selector);
        core.buybackExit(type(uint256).max);
        _enterPhase2();
        vm.expectRevert(Core.NothingToBuy.selector);
        core.buybackExit(type(uint256).max);
        (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
        assertEq(slice, 0);
        assertEq(coinIn, 0);
    }

    // ------------------------------------------------------------------ the clock and long gaps

    /// @dev composes and exits a second statement, which refills the exit buyback pot
    function _refill() internal {
        _fillEthPile(80);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        vm.warp(block.timestamp + core.AUCTION_LENGTH());
        core.exitStatement(sid);
    }

    /// the clock does not run while nothing is for sale. fund, drain, wait a week, refund: the price restarts from
    /// the stored start price and not from nearly zero
    function test_clockStopsWhileThePotIsEmpty() public {
        _auction();
        _equipTaker(60 ether);
        for (uint256 i; i < 8 && core.xToBuyback() != 0; ++i) {
            (, uint256 coinIn) = _waitUntilAffordable();
            _fill(coinIn);
        }
        assertEq(core.xToBuyback(), 0, "drained");
        uint256 stored = core.xStartPrice();
        uint256 storedAt = core.xStartTime();
        assertGt(stored, 0);

        vm.warp(block.timestamp + 7 days);
        assertEq(core.exitAuctionPrice(), stored, "an empty auction shows its start price");
        assertEq(core.xStartPrice(), stored);
        _refill();
        assertGt(core.xToBuyback(), 0);
        assertGt(core.xStartTime(), storedAt + 7 days, "the clock restarted when the pot went from empty");
        assertEq(core.xStartTime(), block.timestamp);
        assertEq(core.xStartPrice(), stored, "the start price is kept");
        assertEq(core.exitAuctionPrice(), stored, "price restarts from the stored start price, not near zero");
        vm.warp(block.timestamp + 6 hours);
        assertEq(core.exitAuctionPrice(), stored >> 1);
    }

    /// a refill while the pot is not empty re anchors the curve at max(price now, start / 4) and restarts the clock,
    /// so the new funds never inherit a decayed clock
    function test_refillOnANonEmptyPotReanchorsTheCurve() public {
        _auction();
        uint256 price = core.xStartPrice();
        vm.warp(block.timestamp + 3 hours);
        uint256 now0 = core.exitAuctionPrice();
        assertLt(now0, price);
        // a statement exit adds exit token after its own 72 hour auction wait
        _fillEthPile(80);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        vm.warp(block.timestamp + core.AUCTION_LENGTH());
        uint256 priceBefore = core.exitAuctionPrice();
        assertLt(priceBefore, price / 4, "the clock ran far enough to pass the quarter floor");
        core.exitStatement(sid);
        assertEq(core.xStartTime(), block.timestamp);
        assertEq(core.xStartPrice(), price / 4, "floored at a quarter");
        assertEq(core.exitAuctionPrice(), price / 4);
    }

    /// after decades the price is zero. a fill then costs nothing, and the auction restarts above zero
    function test_longGapsNeverRevertAndAZeroPriceFillRestartsAboveZero() public {
        _auction();
        uint256 start0 = core.xStartPrice();
        vm.warp(block.timestamp + 20 * 365 days);
        assertEq(core.exitAuctionPrice(), 0);
        (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
        assertGt(slice, 0);
        assertEq(coinIn, 0);
        uint256 supply = coin.totalSupply();
        vm.prank(taker);
        core.buybackExit(0);
        assertEq(coin.totalSupply(), supply, "nothing to burn at price zero");
        assertEq(xt.balanceOf(taker), slice);
        assertEq(core.xStartPrice(), start0 / 4, "the restart is a quarter of the last start, never dust");
        assertEq(core.exitAuctionPrice(), start0 / 4);
    }

    // ------------------------------------------------------------------ the restart rule

    uint256 private constant DUST = 1e15;

    function _warpUntilDust() internal returns (uint256 waited) {
        for (uint256 i; i < 3000; ++i) {
            (, uint256 coinIn) = core.exitAuctionQuote();
            if (coinIn <= DUST) return waited;
            vm.warp(block.timestamp + 1 hours);
            waited += 1 hours;
        }
        revert("never dust");
    }

    /// (a) a fill at a decayed dust price restarts the next auction at a quarter of the last start, not at dust
    function test_restartAfterADustFillIsAQuarterOfThePreviousStart() public {
        _auction();
        _equipTaker(1 ether);
        uint256 start0 = core.xStartPrice();
        vm.warp(block.timestamp + 360 hours);
        uint256 dust = core.exitAuctionPrice();
        assertGt(dust, 0);
        assertLt(dust, start0 >> 59, "sixty halvings: dust");
        (, uint256 coinIn) = core.exitAuctionQuote();
        _fill(coinIn);
        assertEq(core.xStartPrice(), start0 / 4, "a quarter of the previous start, not twice the dust price");
        assertEq(core.xStartTime(), block.timestamp);
        assertEq(core.exitAuctionPrice(), start0 / 4);
        (, uint256 next) = core.exitAuctionQuote();
        assertGt(next, 1e24, "the next slice is not cheap");
    }

    /// (b) draining slices at dust needs a separate long decay for every slice
    function test_drainingSlicesAtDustNeedsSeparateDecays() public {
        _auction();
        while (core.xToBuyback() < 3 * _fullSlice()) _refill();
        _equipTaker(1 ether);
        uint256 start0 = core.xStartPrice();
        uint256 t0 = core.xStartTime();
        uint256[3] memory decay;
        for (uint256 i; i < 3; ++i) {
            _warpUntilDust();
            decay[i] = block.timestamp - core.xStartTime();
            (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
            assertEq(slice, _fullSlice(), "a full slice at dust");
            _fill(coinIn);
            assertEq(core.xStartPrice(), start0 >> (2 * (i + 1)), "each restart is a quarter of the last start");
        }
        // the first slice needs about 40 halvings (240 hours) from the opening price. the refills above each pulled the
        // start down toward a quarter, so from there it needs a little less. every later one starts 2 halvings
        // (12 hours) lower
        assertGe(decay[0], 200 hours);
        assertLe(decay[0], 245 hours);
        assertApproxEqAbs(decay[1], decay[0] - 12 hours, 1 hours);
        assertApproxEqAbs(decay[2], decay[0] - 24 hours, 1 hours);
        uint256 total = block.timestamp - t0;
        assertApproxEqAbs(total, 3 * decay[0] - 36 hours, 2 hours);
        assertGe(total, 600 hours, "three slices at dust take about 25 days, not one decay");
    }

    /// (c) fills near a fair price: restart at twice the clearing price, one slice per half life
    function test_fairPriceTakersGetOneSlicePerHalfLife() public {
        _auction();
        while (core.xToBuyback() < 4 * _fullSlice()) _refill();
        _equipTaker(2000 ether);
        // the first fill takes whatever the long wait left and sets the baseline start price
        _warpUntilDust();
        (, uint256 first) = core.exitAuctionQuote();
        _fill(first);
        uint256 base = core.xStartPrice();
        uint256 hl = core.XAUCTION_HALF_LIFE();
        // three half lives later the price is an eighth of the baseline, the lowest price where twice the clearing price
        // still equals the quarter floor: the fair price the taker now pays, with the least coin this can take
        vm.warp(block.timestamp + 3 * hl);
        uint256 clearing = base >> 3;
        for (uint256 i; i < 3; ++i) {
            if (i != 0) vm.warp(block.timestamp + hl);
            // at the quarter floor the restart can sit a few wei above twice the clearing price, from the rounding
            assertApproxEqAbs(core.exitAuctionPrice(), clearing, 8, "one half life after the restart the price is back");
            (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
            assertEq(slice, _fullSlice());
            assertGt(coinIn, 1e24, "a real price, not dust");
            _fill(coinIn);
            assertApproxEqAbs(core.xStartPrice(), 2 * clearing, 8, "restart at twice the clearing price");
            assertEq(core.xStartTime(), block.timestamp);
        }
        assertEq(xt.balanceOf(taker), 4 * _fullSlice(), "four slices: the first, then one per half life");
    }

    /// (d) gaps of any length never revert and never underflow
    function test_longGapsNeverRevertOrUnderflow() public {
        _auction();
        uint256 start0 = core.xStartPrice();
        uint256 t0 = block.timestamp;
        uint256 hl = core.XAUCTION_HALF_LIFE();
        uint256[9] memory gaps =
            [uint256(0), 1, hl - 1, hl, 255 * hl, 256 * hl - 1, 256 * hl, 256 * hl + 1, uint256(1) << 60];
        uint256 last = type(uint256).max;
        for (uint256 i; i < gaps.length; ++i) {
            vm.warp(t0 + gaps[i]);
            uint256 p = core.exitAuctionPrice();
            assertLe(p, last);
            last = p;
            (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
            assertGt(slice, 0);
            assertEq(coinIn, slice.mulDivUp(p, 1e18));
        }
        assertEq(last, 0, "gone after 256 halvings");
        _fill(0);
        assertEq(core.xStartPrice(), start0 / 4, "the fill did not revert and restarted at a quarter");
    }

    /// the restart price is never zero, even from a start of one or three wei
    function test_restartNeverZero() public {
        _auction();
        vm.warp(block.timestamp + 300 * core.XAUCTION_HALF_LIFE());
        assertEq(core.exitAuctionPrice(), 0);
        vm.store(address(core), bytes32(uint256(23)), bytes32(uint256(3)));
        _fill(0);
        assertEq(core.xStartPrice(), 1, "3 / 4 is zero, the floor keeps one");
        vm.warp(block.timestamp + 300 * core.XAUCTION_HALF_LIFE());
        _fill(0);
        assertEq(core.xStartPrice(), 1, "one stays one");
        assertEq(core.exitAuctionPrice(), 1);
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_priceNeverRevertsAndNeverRises(uint64 gap1, uint64 gap2) public {
        _auction();
        uint256 p0 = core.exitAuctionPrice();
        vm.warp(block.timestamp + gap1);
        uint256 p1 = core.exitAuctionPrice();
        assertLe(p1, p0);
        vm.warp(block.timestamp + gap2);
        assertLe(core.exitAuctionPrice(), p1);
        core.exitAuctionQuote();
    }
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// the venue scoped transfer tax of the real token, as far as the credits engine depends on it
contract TaxTest is FeeBase {
    TestLiquidityHelper internal lp;

    function setUp() public override {
        super.setUp();
        lp = new TestLiquidityHelper();
        _stock();
    }

    /// canonical buys of every kind reach the buyer in full, and sells put the full amount into the pool
    function test_canonicalSwapsAreUntaxed() public {
        uint256 dead = coin.balanceOf(DEAD);
        uint256 before = coin.balanceOf(trader);
        vm.prank(trader);
        BalanceDelta d = router.swap{value: 3 ether}(launchKey, true, -3 ether, trader);
        assertEq(coin.balanceOf(trader) - before, uint256(uint128(d.amount1())), "exact in buy paid out in full");

        before = coin.balanceOf(trader);
        vm.prank(trader);
        router.swap{value: 50 ether}(launchKey, true, int256(1_000_000e18), trader);
        assertEq(coin.balanceOf(trader) - before, 1_000_000e18, "exact out buy paid out in full");

        uint256 poolBefore = coin.balanceOf(Mainnet.POOL_MANAGER);
        before = coin.balanceOf(trader);
        _sellCoin(trader, 5_000_000e18);
        assertEq(before - coin.balanceOf(trader), 5_000_000e18);
        assertEq(coin.balanceOf(Mainnet.POOL_MANAGER) - poolBefore, 5_000_000e18, "sell fully reaches the pool");
        assertEq(coin.balanceOf(DEAD), dead, "nothing went to the burn address");
    }

    /// a hookless v4 side pool of the coin is a venue: buying out of it pays 15 percent to the burn address, and
    /// pays no skim, which is the deterrent the tax is
    function test_buyOutOfAHooklessSidePoolIsTaxed() public {
        PoolKey memory side = PoolKey(CurrencyLib.eth(), CurrencyLib.token(address(coin)), 3000, 60, IHooks(address(0)));
        PM.initialize(side, TickMath.getSqrtPriceAtTick(175_020));
        vm.startPrank(trader);
        coin.approve(address(lp), type(uint256).max);
        lp.modify{value: 5 ether}(side, 174_000, 176_040, 1e23);
        vm.stopPrank();

        uint256 dead = coin.balanceOf(DEAD);
        uint256 pot = core.ethPot();
        address buyer = _user("side buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        BalanceDelta d = router.swap{value: 0.05 ether}(side, true, -0.05 ether, buyer);
        uint256 gross = uint256(uint128(d.amount1()));
        assertGt(gross, 0);
        uint256 tax = gross * 1500 / 10_000;
        assertEq(coin.balanceOf(buyer), gross - tax, "the buyer receives 85 percent");
        assertEq(coin.balanceOf(DEAD) - dead, tax, "15 percent to the burn address");
        assertEq(core.ethPot(), pot, "no skim in a hookless pool");
    }

    /// documented gap: a plain transfer is neither taxed nor skimmed
    function test_walletToWalletIsUntaxed() public {
        address friend = _user("friend");
        uint256 dead = coin.balanceOf(DEAD);
        vm.prank(trader);
        coin.transfer(friend, 1_234_567e18);
        assertEq(coin.balanceOf(friend), 1_234_567e18);
        vm.prank(friend);
        coin.transfer(trader, 1e18);
        assertEq(coin.balanceOf(DEAD), dead);
        assertEq(coin.balanceOf(friend), 1_234_566e18);
    }

    /// the core is exempt, so coin leaving a venue to the core is never taxed even without a canonical swap
    function test_coreIsExemptFromTheVenueTax() public {
        assertTrue(coin.isTaxExempt(address(core)));
        // take coin out of a hookless side pool straight into the core: no tax
        PoolKey memory side = PoolKey(CurrencyLib.eth(), CurrencyLib.token(address(coin)), 500, 10, IHooks(address(0)));
        PM.initialize(side, TickMath.getSqrtPriceAtTick(175_020));
        vm.startPrank(trader);
        coin.approve(address(lp), type(uint256).max);
        lp.modify{value: 5 ether}(side, 174_000, 176_040, 1e23);
        vm.stopPrank();
        uint256 dead = coin.balanceOf(DEAD);
        vm.prank(trader);
        BalanceDelta d = router.swap{value: 0.05 ether}(side, true, -0.05 ether, address(core));
        assertEq(coin.balanceOf(address(core)), uint256(uint128(d.amount1())));
        assertEq(coin.balanceOf(DEAD), dead);
    }
}

library CurrencyLib {
    function eth() internal pure returns (Currency) {
        return Currency.wrap(address(0));
    }

    function token(address t) internal pure returns (Currency) {
        return Currency.wrap(t);
    }
}

/// one buy and one sell through the real universal router, the way a wallet or aggregator would trade the coin
contract UniversalRouterTest is FeeBase {
    IUniversalRouter internal constant UR = IUniversalRouter(Mainnet.UNIVERSAL_ROUTER);
    IPermit2 internal constant PERMIT2 = IPermit2(Mainnet.PERMIT2);

    function _v4Swap(bool zeroForOne, uint256 amountIn) internal view returns (bytes[] memory inputs) {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        Currency cIn = zeroForOne ? launchKey.currency0 : launchKey.currency1;
        Currency cOut = zeroForOne ? launchKey.currency1 : launchKey.currency0;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(launchKey, zeroForOne, uint128(amountIn), 0, ""));
        params[1] = abi.encode(cIn, amountIn);
        params[2] = abi.encode(cOut, uint256(0));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function test_buyAndSellThroughTheUniversalRouter() public {
        _skipSniperWindow();
        uint256 dead = coin.balanceOf(DEAD);
        uint256 pot = core.ethPot();
        uint256 esc = ESCROW.availableFees(creator, address(0));
        vm.deal(trader, 10 ether);

        // the same buy through the test router in a snapshot gives the reference amount out
        uint256 snap = vm.snapshotState();
        uint256 viaRouter = _buyCoin(funder, 1 ether);
        vm.revertToState(snap);

        vm.prank(trader);
        UR.execute{value: 1 ether}(hex"10", _v4Swap(true, 1 ether), block.timestamp + 1 hours);
        uint256 bought = coin.balanceOf(trader);
        assertEq(bought, viaRouter, "same amount out as the plain swapper, so no tax was taken");
        assertEq(core.ethPot() - pot, 0.095 ether, "skim on the buy: 9.5 points to the pot");
        assertEq(ESCROW.availableFees(creator, address(0)) - esc, 0.005 ether, "0.5 points to the creator");
        assertEq(coin.balanceOf(DEAD), dead, "no tax");

        // sell half through permit2, the way the router pulls erc20 input
        uint256 sellIn = bought / 2;
        snap = vm.snapshotState();
        uint256 ethViaRouter = _sellCoin(trader, sellIn);
        vm.revertToState(snap);

        vm.startPrank(trader);
        coin.approve(Mainnet.PERMIT2, type(uint256).max);
        PERMIT2.approve(address(coin), address(UR), uint160(sellIn), uint48(block.timestamp + 1 hours));
        uint256 ethBefore = trader.balance;
        pot = core.ethPot();
        esc = ESCROW.availableFees(creator, address(0));
        UR.execute(hex"10", _v4Swap(false, sellIn), block.timestamp + 1 hours);
        vm.stopPrank();
        uint256 ethOut = trader.balance - ethBefore;
        assertEq(ethOut, ethViaRouter, "same eth out as the plain swapper");
        assertEq(coin.balanceOf(trader), bought - sellIn);
        // a sell skims 10 points of the pool eth out, taken from the seller
        uint256 gross = ethOut * 10 / 9;
        assertApproxEqAbs(core.ethPot() - pot, gross * 10 / 100 * 95 / 100, 3, "skim on the sell");
        assertApproxEqAbs(ESCROW.availableFees(creator, address(0)) - esc, gross * 10 / 100 * 5 / 100, 3);
        assertEq(coin.balanceOf(DEAD), dead, "no tax on the sell either");
    }
}
