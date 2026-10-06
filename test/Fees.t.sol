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
import {Lane, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsSkimHook, IPreSwapStream, IArtCoinsMevSkim} from "../src/interfaces/ArtCoins.sol";
import {SwapMidListing, SwapMidExit, SwapAroundCollect} from "./attackers/SwapMidCall.sol";
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

    /// @dev the eth buyback pot gets filled the real way: a composed statement is listed on the real house, a real
    /// bidder wins it at the reserve, anyone settles it and the core collects the proceeds, which the split divides
    function _fillEthBuyback() internal returns (uint256 toBuyback) {
        Composed memory c = _composeOnce();
        address buyer = _user("statement buyer");
        uint256 before = core.ethToBuyback();
        _bid(buyer, c.sid, _live(c.sid).reserve);
        _endAuction(c.sid);
        _collectSales();
        toBuyback = core.ethToBuyback() - before;
    }

    /// @dev one more statement sold on the house and collected, the way real fees and sales fill the buyback pot
    function _anotherSale() internal {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid = STATEMENTS.supply();
        _bid(trader, sid, _live(sid).reserve);
        _endAuction(sid);
        _collectSales();
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

    /// the split of a swap fee (9.5 points to the core, 0.5 to the creator) is fixed inside the pool. no setting moves it,
    /// and the core books the whole push into the pot, never into the buyback share, whatever `saleToBuybackBps` says
    function test_feeSplitIsNotASetting() public {
        _stock();
        uint256 back = core.ethToBuyback();
        uint256[3] memory share = [uint256(0), 10_000, 3_333];
        for (uint256 i; i < 3; ++i) {
            Settings memory s = core.settings();
            // forge-lint: disable-next-line(unsafe-typecast)
            s.saleToBuybackBps = uint16(share[i]);
            s.exitToBuybackBps = s.saleToBuybackBps;
            s.reserveBps = 40_000;
            s.flatBps = 0;
            _setSettings(s);
            Flow memory f = _flow(Kind.BuyExactIn, 1 ether, "");
            assertEq(f.potRise, 0.095 ether, "9.5 points to the pot");
            assertEq(f.escrowRise, 0.005 ether, "0.5 points to the creator");
            assertEq(core.ethToBuyback(), back, "nothing to the buyback share");
        }
    }

    /// a settings change checkpoints first, so the fee that arrives later finds the climb at the new numbers only
    /// from the change on
    function test_feeAfterASettingsChangeLocksTheRightRate() public {
        _stock();
        _fundPot(1 ether);
        vm.warp(block.timestamp + 5 hours);
        uint256 old = core.ethRate();
        assertGt(old, core.RATE_START());
        Settings memory s = core.settings();
        s.climbBaseBps = 0;
        s.climbMaxBps = 0;
        _setSettings(s);
        assertEq(core.rateAtCheckpoint(), old);
        vm.warp(block.timestamp + 50 hours);
        assertEq(core.ethRate(), old, "no climb after the change");
        _flow(Kind.BuyExactIn, 1 ether, "");
        assertEq(core.rateAtCheckpoint(), old, "the fee locked the unchanged rate");
        assertEq(core.checkpointTime(), block.timestamp);
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
        uint256 clamp = (core.ethPot() - 1 ether) * 2000 / uint256(core.settings().avgScore);
        assertEq(core.rateAtCheckpoint(), clamp < core.settings().rateCap ? clamp : core.settings().rateCap, "cap");
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
        vm.warp(block.timestamp + core.settings().exitAfter);
        uint256 pot = core.ethPot();
        core.exitStatement(c.sid);
        assertEq(core.ethPot(), pot, "nothing booked mid exit");
        assertEq(address(core).balance - core.ethPot() - core.ethToBuyback(), 0.095 ether);
        assertGt(core.xToBuyback(), 0);
        core.skim();
        assertEq(core.ethPot() + core.ethToBuyback(), address(core).balance);
    }
}

/// `receive()` under every setting the owner can reach, and in the middle of every call that measures
contract ReceiveSettingsTest is FeeBase {
    using FixedPointMathLib for uint256;

    function _hookSend(uint256 amount) internal returns (bool ok) {
        vm.deal(Mainnet.SKIM_HOOK, Mainnet.SKIM_HOOK.balance + amount);
        vm.prank(Mainnet.SKIM_HOOK);
        (ok,) = address(core).call{value: amount}("");
    }

    function _pick(uint256 seed, uint256 i, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + uint256(keccak256(abi.encode(seed, i))) % (hi - lo + 1);
    }

    /// @dev random settings inside the bounds for everything the rate and the pot depend on
    function _randomSettings(uint256 seed) internal view returns (Settings memory s) {
        s = core.settings();
        // forge-lint: disable-start(unsafe-typecast)
        s.flatBps = uint16(_pick(seed, 0, 0, 10_000));
        s.avgScore = uint32(_pick(seed, 1, 800_000, 6_000_000));
        s.climbBaseBps = uint16(_pick(seed, 2, 0, 1_000));
        s.climbDoubleEvery = uint32(_pick(seed, 3, 1 hours, 30 days));
        s.climbMaxBps = uint16(_pick(seed, 4, s.climbBaseBps, 2_000));
        s.dropBps = uint16(_pick(seed, 5, 500, 5_000));
        s.spendCapBps = uint16(_pick(seed, 6, 100, 5_000));
        s.saleToBuybackBps = uint16(_pick(seed, 7, 0, 10_000));
        s.rateCap = uint64(_pick(seed, 8, 1e11, 1e15));
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// pots of any size, settings that change between pushes, gaps of any length: the hook push is always accepted and
    /// booked in full, the rate checkpoint moves to the push, and the books stay solvent
    function testFuzz_receiveNeverRevertsAcrossSettings(uint256 seed, uint96 a, uint32 gap1, uint96 b, uint256 gap2)
        public
    {
        gap2 = bound(gap2, 0, 20 * 365 days);
        uint256[3] memory amounts = [uint256(a), uint256(b), uint256(a) + b];
        uint256[3] memory gaps = [uint256(gap1), gap2, uint256(gap1) + gap2];
        uint256 booked;
        for (uint256 i; i < 3; ++i) {
            _setSettings(_randomSettings(uint256(keccak256(abi.encode(seed, i)))));
            if (i == 1) {
                uint256 newRate = _pick(seed, 99, 1e11, core.settings().rateCap);
                vm.prank(owner);
                core.setRate(newRate);
            }
            vm.warp(block.timestamp + gaps[i]);
            uint256 rate = core.ethRate();
            assertTrue(_hookSend(amounts[i]), "receive does not revert");
            booked += amounts[i];
            assertEq(core.ethPot(), booked, "every push booked");
            assertEq(core.checkpointTime(), block.timestamp, "checkpointed at the push");
            assertEq(core.rateAtCheckpoint(), rate, "the climbed rate was locked in first");
            assertEq(address(core).balance, core.ethPot() + core.ethToBuyback());
        }
    }

    /// the same on the worst rate: a huge pot, the smallest rate, decades of gap, then a settings change that makes
    /// the climb as steep as it can be, then a push
    function test_receiveAfterTheSteepestSettingsAndTheLongestGap() public {
        assertTrue(_hookSend(100_000_000 ether));
        vm.prank(owner);
        core.setRate(1e11);
        Settings memory s = core.settings();
        s.climbBaseBps = 1_000;
        s.climbMaxBps = 2_000;
        s.climbDoubleEvery = 1 hours;
        s.spendCapBps = 5_000;
        s.avgScore = 800_000;
        _setSettings(s);
        _warp(100 * 365 days);
        uint256 g = gasleft();
        assertTrue(_hookSend(1 ether));
        assertLt(g - gasleft(), 400_000, "bounded work");
        assertLe(core.rateAtCheckpoint(), (core.ethPot() - 1 ether) * 10_000 / 800_000, "clamped at the cap");
    }

    /// the hook pushes its skim into the core in the middle of `buyback`, under changed settings. the push is booked
    /// by the receive that runs inside the unlock, and the spend, the tip and the pot stay exact
    function test_receiveMidBuybackAcrossSettings() public {
        _stock();
        uint256[3] memory slice = [uint256(0.02 ether), 0.05 ether, 5 ether];
        uint256[3] memory tips = [uint256(0), 200, 500];
        for (uint256 i; i < 3; ++i) {
            Settings memory s = core.settings();
            s.flatBps = uint16(i * 5_000 > 10_000 ? 10_000 : i * 5_000);
            s.dropBps = uint16(500 * (i + 1));
            s.saleToBuybackBps = 10_000;
            s.buybackDelay = 1;
            // forge-lint: disable-start(unsafe-typecast)
            s.buybackSlice = uint128(slice[i]);
            s.keeperTipBps = uint16(tips[i]);
            // forge-lint: disable-end(unsafe-typecast)
            _setSettings(s);
            _anotherSale();
            vm.roll(block.number + 1);
            uint256 pot = core.ethPot();
            uint256 pool = core.ethToBuyback();
            uint256 take = pool.min(slice[i]);
            uint256 keeper0 = keeper.balance;
            uint256 supply = coin.totalSupply();
            vm.recordLogs();
            vm.prank(keeper);
            core.buyback();
            Flow memory f;
            _readSkim(f, vm.getRecordedLogs());
            assertEq(core.ethPot() - pot, f.skimBounty, "the push inside the unlock was booked");
            assertEq(f.skimVolume, take - take * tips[i] / 10_000, "the swap spent the slice less the tip");
            assertEq(keeper.balance - keeper0, take * tips[i] / 10_000);
            assertEq(core.ethToBuyback(), pool - take);
            assertLt(coin.totalSupply(), supply);
            assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "no surplus, no deficit");
        }
    }

    /// the push inside `buyListing`'s measurement under changed settings (flat share, tip rules). nothing is booked
    /// then, the push only lowers the measured cost, and the tip follows the settings
    function test_receiveMidBuyListingAcrossSettings() public {
        SwapMidListing t = new SwapMidListing(router, address(core), launchKey);
        _allow(address(t));
        _stock();
        _fundPot(1 ether);
        uint256 snap = vm.snapshotState();
        uint256[3] memory flat = [uint256(10_000), 5_000, 0];
        uint256[3] memory tipSav = [uint256(1_000), 2_500, 0];
        uint256[3] memory tipCap = [uint256(200), 500, 100];
        for (uint256 i; i < 3; ++i) {
            vm.revertToState(snap);
            Settings memory s = core.settings();
            // forge-lint: disable-start(unsafe-typecast)
            s.flatBps = uint16(flat[i]);
            s.tipSavingsBps = uint16(tipSav[i]);
            s.tipCapBps = uint16(tipCap[i]);
            // forge-lint: disable-end(unsafe-typecast)
            _setSettings(s);
            uint256 id = _credits(address(t), 1)[0];
            uint256 ceiling = core.ceilingOf(id);
            uint256 swapEth = ceiling * 5;
            vm.deal(address(t), swapEth);
            t.arm(id, swapEth);
            uint256 pot = core.ethPot();
            uint256 bounty = swapEth * 10_000 / 100_000 * 9500 / 10_000;
            uint256 cost = ceiling - bounty;
            uint256 tip = (tipSav[i] * (ceiling - cost) / 10_000).min(tipCap[i] * cost / 10_000);
            uint256 keeper0 = keeper.balance;
            vm.prank(keeper);
            core.buyListing(ceiling, hex"deadbeef", id, address(t));
            assertEq(CREDITS.ownerOf(id), address(core));
            assertEq(keeper.balance - keeper0, tip, "tip by the settings");
            assertEq(core.ethPot(), pot - cost - tip, "the push was not booked mid measurement");
            assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "consistent");
        }
    }

    /// the push inside `exitStatement`'s measurement, with the exit split and the wait taken from the settings
    function test_receiveMidExitAcrossSettings() public {
        _stock();
        MockExitToken token = new MockExitToken("Exit Token", "XT");
        SwapMidExit m = new SwapMidExit(token, UNIT, router, launchKey, 1 ether);
        vm.deal(address(m), 1 ether);
        _timelock(Core.Action.SetExitModule, abi.encode(address(m)));
        Settings memory s = core.settings();
        s.exitAfter = 1 hours;
        s.exitToBuybackBps = 10_000;
        _setSettings(s);
        Composed memory c = _composeOnce();
        vm.warp(c.at + 1 hours - 1);
        vm.expectRevert(Core.TooEarly.selector);
        core.exitStatement(c.sid);
        vm.warp(c.at + 1 hours);
        uint256 pot = core.ethPot();
        core.exitStatement(c.sid);
        assertEq(core.ethPot(), pot, "nothing booked mid exit");
        assertEq(address(core).balance - core.ethPot() - core.ethToBuyback(), 0.095 ether);
        assertEq(core.xPot(), 0);
        assertEq(core.xToBuyback(), STATEMENTS.creditScoreOf(c.sid) * UNIT, "the whole exit went to the buyback");
        core.skim();
        assertEq(core.ethPot() + core.ethToBuyback(), address(core).balance);
    }

    /// two sales are settled on the house and their proceeds wait there. one transaction then swaps in the real pool,
    /// collects, and swaps again, so the hook pushes into `receive` before and after `collectSales` (the house delivers
    /// statements by plain transfer and runs no code of the winner, so this is as close to the middle as a stranger
    /// gets, and the house pays the core only from inside `collectSales`). an unrelated donation sits unbooked
    /// throughout. every wei is booked once, in the right pot
    function test_receiveAroundCollectSalesInOneTransaction() public {
        _stock();
        Settings memory s = core.settings();
        s.saleToBuybackBps = 3_333;
        _setSettings(s);
        uint256 sid1 = _composeOnce().sid;
        uint256 price1 = _live(sid1).reserve;
        _bid(trader, sid1, price1);
        _endAuction(sid1);
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        uint256 sid2 = STATEMENTS.supply();
        uint256 price2 = _live(sid2).reserve;
        _bid(trader, sid2, price2);
        _endAuction(sid2);
        assertEq(_owedByHouse(), price1 + price2);

        vm.deal(address(core), address(core).balance + 0.5 ether);
        SwapAroundCollect w = new SwapAroundCollect(router, address(core), launchKey);
        vm.deal(address(w), 4 ether);
        uint256 pot = core.ethPot();
        uint256 back = core.ethToBuyback();
        uint256 bal = address(core).balance;
        w.run(1 ether);
        uint256 bounty = 1 ether * 10_000 / 100_000 * 9500 / 10_000;
        uint256 owed = price1 + price2;
        assertEq(core.ethToBuyback() - back, owed * 3_333 / 10_000, "the split of the collection");
        assertEq(core.ethPot() - pot, 2 * bounty + owed - owed * 3_333 / 10_000, "two pushes and the rest of the sale");
        assertEq(address(core).balance - bal, 2 * bounty + owed, "the core gained the pushes and the proceeds only");
        assertEq(_owedByHouse(), 0);
        assertEq(address(core).balance - core.ethPot() - core.ethToBuyback(), 0.5 ether, "the donation is unbooked");
        _solvent();
        core.skim();
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback());
    }

    /// the hook push never reverts and is always booked in full, whatever came before it: a random walk over settings
    /// changes, long gaps, collections, buybacks, skims and real swaps, from a state with a sale waiting in the house
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_receiveInterleavedWithEverything(uint256 seed) public {
        _stock();
        (uint256 sid, uint256 price) = _sellStatement(trader);
        assertEq(STATEMENTS.ownerOf(sid), trader);
        assertEq(_owedByHouse(), price);
        for (uint256 step; step < 10; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 kind = r % 7;
            if (kind == 0) {
                Settings memory s = _randomSettings(r >> 8);
                // the buyback numbers stay usable so the walk can reach it
                s.buybackDelay = 1;
                _setSettings(s);
            } else if (kind == 1) {
                _warp(1 + (r >> 8) % (400 days));
            } else if (kind == 2) {
                vm.prank(address(0xC011));
                core.collectSales();
            } else if (kind == 3) {
                vm.roll(block.number + 1);
                vm.prank(keeper);
                try core.buyback() {} catch {}
            } else if (kind == 4) {
                core.skim();
            } else if (kind == 5) {
                vm.deal(trader, trader.balance + 1 ether);
                vm.prank(trader);
                router.swap{value: 1 ether}(launchKey, true, -1 ether, trader);
            } else {
                uint256 newRate = _pick(r, 5, 1e11, core.settings().rateCap);
                vm.prank(owner);
                core.setRate(newRate);
            }
            uint256 pot = core.ethPot();
            assertTrue(_hookSend(0.1 ether), "the push is accepted");
            assertEq(core.ethPot(), pot + 0.1 ether, "and booked in full");
            _solvent();
        }
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

    function test_buybackBurnsTheCoinBoughtAndBooksTheSkim() public {
        _stock();
        uint256 toBuyback = _fillEthBuyback();
        assertGt(toBuyback, 0);
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "clean books before");
        Before memory b = _before();
        uint256 slice = b.pool.min(core.settings().buybackSlice);
        uint256 tip0 = slice * core.settings().keeperTipBps / 10_000;
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

    /// the launch values: a slice of 1 eth cuts the pot, and 25 blocks must pass between two buybacks. the pot a sale
    /// builds is under one slice, so a buyback takes all of it
    function test_buybackDelayAtLaunchValues() public {
        _stock();
        _fillEthBuyback();
        Before memory b = _before();
        assertLt(b.pool, 1 ether, "a sale builds less than one slice");
        vm.prank(keeper);
        core.buyback();
        assertEq(core.ethToBuyback(), 0, "the slice was the whole pot");
        assertEq(core.lastBuybackBlock(), block.number);
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback());

        _anotherSale();
        assertGt(core.ethToBuyback(), 0);
        vm.prank(keeper);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + core.settings().buybackDelay - 1);
        vm.prank(keeper);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 1);
        vm.prank(keeper);
        core.buyback();
        assertEq(core.ethToBuyback(), 0);
        vm.roll(block.number + core.settings().buybackDelay);
        vm.expectRevert(Core.NothingToBuy.selector);
        core.buyback();
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback());
    }

    /// @dev puts `eth` into the buyback pot, backed by real eth in the core: the one seam of this file. an auction needs
    /// an hour from its first bid and the sniper window is 30 minutes, so no real sale can fill the pot inside it
    function _forcePot(uint256 eth) internal {
        vm.deal(address(core), address(core).balance + eth);
        uint256 slot = stdstore.target(address(core)).sig("ethToBuyback()").find();
        vm.store(address(core), bytes32(slot), bytes32(core.ethToBuyback() + eth));
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

/// the buyback reads its slice, its delay and the keeper tip from the settings, effective at once
contract BuybackSettingsTest is FeeBase {
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();
        _stock();
    }

    function _configure(uint256 slice, uint256 delay, uint256 tip) internal {
        Settings memory s = core.settings();
        s.saleToBuybackBps = 10_000;
        // forge-lint: disable-start(unsafe-typecast)
        s.buybackSlice = uint128(slice);
        s.buybackDelay = uint16(delay);
        s.keeperTipBps = uint16(tip);
        // forge-lint: disable-end(unsafe-typecast)
        _setSettings(s);
    }

    /// one buyback by the keeper, checked against the settings. returns the slice taken
    function _buyback() internal returns (uint256 slice) {
        Settings memory s = core.settings();
        uint256 pool = core.ethToBuyback();
        slice = pool.min(s.buybackSlice);
        uint256 supply = coin.totalSupply();
        uint256 keeper0 = keeper.balance;
        uint256 pot = core.ethPot();
        vm.prank(keeper);
        core.buyback();
        assertEq(keeper.balance - keeper0, slice * s.keeperTipBps / 10_000, "tip of the slice at the setting");
        assertEq(core.ethToBuyback(), pool - slice, "the pot fell by the slice at the setting");
        assertLt(coin.totalSupply(), supply, "burned");
        assertGt(core.ethPot(), pot, "the skim of the swap came back through receive");
        assertEq(core.lastBuybackBlock(), block.number);
        assertEq(address(core).balance, core.ethPot() + core.ethToBuyback(), "no surplus, no deficit");
    }

    function test_sliceDelayAndTipFollowTheSettings() public {
        _configure(0.02 ether, 3, 200);
        _fillEthBuyback();
        uint256 pool = core.ethToBuyback();
        assertGt(pool, 0.1 ether);
        assertEq(_buyback(), 0.02 ether);

        vm.prank(keeper);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 2);
        vm.prank(keeper);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 1);
        assertEq(_buyback(), 0.02 ether);

        // a shorter delay, effective at once: one block is enough now
        _configure(0.02 ether, 1, 200);
        vm.prank(keeper);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 1);
        assertEq(_buyback(), 0.02 ether);

        // no tip at zero
        _configure(0.01 ether, 1, 0);
        vm.roll(block.number + 1);
        uint256 keeper0 = keeper.balance;
        assertEq(_buyback(), 0.01 ether);
        assertEq(keeper.balance, keeper0, "tip zero pays nothing");

        // the largest tip is 500 bps of the slice
        _configure(0.01 ether, 1, 500);
        vm.roll(block.number + 1);
        _buyback();

        // a slice above the pot takes the whole pot
        _configure(5 ether, 7_200, 50);
        vm.roll(block.number + 7_200);
        uint256 rest = core.ethToBuyback();
        assertEq(_buyback(), rest);
        assertEq(core.ethToBuyback(), 0);
        // the longest delay binds in blocks
        _anotherSale();
        vm.roll(block.number + 7_199);
        vm.prank(keeper);
        vm.expectRevert(Core.TooSoon.selector);
        core.buyback();
        vm.roll(block.number + 1);
        _buyback();
    }

    /// any slice, delay and tip inside the bounds: one buyback burns, tips and books exactly
    /// forge-config: default.fuzz.runs = 16
    function testFuzz_buybackAnySettings(uint256 slice, uint256 delay, uint256 tip) public {
        _configure(bound(slice, 0.01 ether, 5 ether), bound(delay, 1, 7_200), bound(tip, 0, 500));
        _fillEthBuyback();
        _buyback();
    }
}

/// the dutch auction that sells the exit token buyback pot for coin, which it burns. phase 2, with the stand ins
contract AuctionTest is FeeBase {
    using stdStorage for StdStorage;
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
        return uint256(core.settings().exitSliceCredits) * core.settings().avgScore * UNIT;
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
        vm.warp(block.timestamp + core.settings().exitAfter);
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
        vm.warp(block.timestamp + core.settings().exitAfter);
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
        uint256 hl = core.settings().xAuctionHalfLife;
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
        uint256 hl = core.settings().xAuctionHalfLife;
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
        vm.warp(block.timestamp + 300 * core.settings().xAuctionHalfLife);
        assertEq(core.exitAuctionPrice(), 0);
        vm.store(
            address(core), bytes32(stdstore.target(address(core)).sig("xStartPrice()").find()), bytes32(uint256(3))
        );
        _fill(0);
        assertEq(core.xStartPrice(), 1, "3 / 4 is zero, the floor keeps one");
        vm.warp(block.timestamp + 300 * core.settings().xAuctionHalfLife);
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

    // ------------------------------------------------------------------ the settings of the auction

    function _auctionSettings(uint256 halfLife, uint256 sliceCredits) internal {
        Settings memory s = core.settings();
        // forge-lint: disable-start(unsafe-typecast)
        s.xAuctionHalfLife = uint32(halfLife);
        s.exitSliceCredits = uint16(sliceCredits);
        // forge-lint: disable-end(unsafe-typecast)
        _setSettings(s);
    }

    /// the half life is a setting: the price halves every `hl` from the start, at any value inside the bounds
    function _halfLifeCase(uint256 hl) internal {
        _auctionSettings(hl, 20);
        _auction();
        uint256 p0 = core.exitAuctionPrice();
        assertEq(p0, core.xStartPrice());
        vm.warp(block.timestamp + hl);
        assertEq(core.exitAuctionPrice(), p0 >> 1, "halved after one half life");
        vm.warp(block.timestamp + 2 * hl);
        assertEq(core.exitAuctionPrice(), p0 >> 3);
        vm.warp(block.timestamp + hl / 2);
        assertApproxEqRel(core.exitAuctionPrice(), (p0 >> 4) * 1_414_213_562_373_095_049 / 1e18, 1e9);
    }

    function test_halfLifeTenMinutes() public {
        _halfLifeCase(10 minutes);
    }

    function test_halfLifeOneHour() public {
        _halfLifeCase(1 hours);
    }

    function test_halfLifeThirtyDays() public {
        _halfLifeCase(30 days);
    }

    /// forge-config: default.fuzz.runs = 12
    function testFuzz_halfLifeAnywhereInTheBounds(uint256 hl) public {
        // an even number of seconds, so the half of it is exact
        _halfLifeCase(bound(hl, 10 minutes, 30 days) / 2 * 2);
    }

    /// a fill under a short half life restarts at twice the clearing price, and the clock halves at the new pace
    function test_shortHalfLifeFillRestartsAtItsOwnPace() public {
        _auctionSettings(1 hours, 20);
        _auction();
        _equipTaker(60 ether);
        (, uint256 coinIn) = _waitUntilAffordable();
        uint256 clearing = core.exitAuctionPrice();
        _fill(coinIn);
        assertGe(core.xStartPrice(), 2 * clearing);
        uint256 start = core.xStartPrice();
        vm.warp(block.timestamp + 1 hours);
        assertEq(core.exitAuctionPrice(), start >> 1, "one hour per halving now");
    }

    /// the slice is `exitSliceCredits` average credits, or what is left. the opening price asks the whole supply for
    /// one full slice at the credits in force when the module is set
    function _sliceCase(uint256 credits) internal {
        _auctionSettings(6 hours, credits);
        _auction();
        uint256 full = credits * core.settings().avgScore * UNIT;
        assertEq(core.xStartPrice(), 1_000_000_000e18 * 1e18 / full, "opening price of the slice in force");
        (uint256 slice, uint256 coinIn) = core.exitAuctionQuote();
        assertEq(slice, full.min(core.xToBuyback()));
        assertApproxEqRel(coinIn, 1_000_000_000e18 * slice / full, 1e9);
    }

    function test_sliceOfOneCredit() public {
        _sliceCase(1);
    }

    function test_sliceOfFiveCredits() public {
        _sliceCase(5);
    }

    function test_sliceOfAThousandCredits() public {
        _sliceCase(1_000);
        (uint256 slice,) = core.exitAuctionQuote();
        assertEq(slice, core.xToBuyback(), "the pot is less than a thousand credits: the whole pot is the slice");
    }

    /// the credits per slice change after the module is set: the next quote uses the new size at the same price
    function test_sliceChangesAfterPhase2Started() public {
        _auction();
        _equipTaker(60 ether);
        uint256 price = core.exitAuctionPrice();
        _auctionSettings(6 hours, 3);
        assertEq(core.exitAuctionPrice(), price, "the price is not touched");
        (uint256 slice,) = core.exitAuctionQuote();
        assertEq(slice, 3 * uint256(core.settings().avgScore) * UNIT);
        // the average credit is a setting too
        Settings memory s = core.settings();
        s.avgScore = 6_000_000;
        _setSettings(s);
        (slice,) = core.exitAuctionQuote();
        assertEq(slice, 3 * 6_000_000 * UNIT);
        (, uint256 coinIn) = _waitUntilAffordable();
        uint256 pool = core.xToBuyback();
        _fill(coinIn);
        assertEq(core.xToBuyback(), pool - 3 * 6_000_000 * UNIT);
        assertEq(xt.balanceOf(taker), 3 * 6_000_000 * UNIT);
        _solvent();
    }

    /// changing the half life while an auction runs re anchors it at the price now, so the change never jumps the price
    function test_halfLifeChangeMidAuctionKeepsThePrice() public {
        _auction();
        vm.warp(block.timestamp + 5 hours);
        uint256 price = core.exitAuctionPrice();
        _auctionSettings(10 minutes, 20);
        assertEq(core.exitAuctionPrice(), price);
        vm.warp(block.timestamp + 10 minutes);
        assertApproxEqAbs(core.exitAuctionPrice(), price / 2, price / 1e6);
        _auctionSettings(30 days, 20);
        uint256 now0 = core.exitAuctionPrice();
        vm.warp(block.timestamp + 30 days);
        assertApproxEqAbs(core.exitAuctionPrice(), now0 / 2, now0 / 1e6);
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
