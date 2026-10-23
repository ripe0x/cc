// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IControllerV3} from "../src/interfaces/IControllerV3.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {IBalanceTreasuryV2} from "../src/interfaces/IBalanceTreasuryV2.sol";
import {IRedeemer, CcQuote, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Phase3} from "../script/Phase3.s.sol";
import {IMarketRedeemer} from "../src/interfaces/IMarketRedeemer.sol";
import {IdleLoosening, BalanceBid} from "../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

interface IPhase3Coin {
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

/// a fork-only redeemer whose answer the test sets: it exercises the vesting and deferred modes and the treasury's
/// bucket and cap refusals, which the pro-rata redeemer never reaches
contract FixedRedeemer is IRedeemer {
    uint256 internal amount;
    uint8 internal mode;
    uint32 internal duration;

    function set(uint256 a, uint8 m, uint32 d) external {
        (amount, mode, duration) = (a, m, d);
    }

    function quote(address, uint256, uint256, uint256, bytes calldata) external view returns (uint256, uint8, uint32) {
        return (amount, mode, duration);
    }
}

/// phase 3 acceptance (docs/specs/PHASE3.md) on a fork of the head against the live Core, ControllerV2, v1 treasury,
/// BALANCE token and coin, driven through the owner script `script/Phase3.s.sol`
contract Phase3Test is LiveFixture {
    using StateLibrary for IPoolManager;

    /// the spec's pin: block 26,250,700 or later
    uint256 internal constant PIN = 26_251_200;

    Phase3 internal script;
    Phase3.Deployed internal d;
    IBalanceTreasuryV2 internal t;
    IControllerV3 internal v3;
    IPhase2BalanceTreasury internal v1;
    address internal user;

    function _liveForkBlock() internal pure override returns (uint256) {
        return PIN;
    }

    function setUp() public override {
        super.setUp();
        v1 = IPhase2BalanceTreasury(core.balanceModule());
        script = new Phase3();
        d = script.deploy(address(core), script.params(), false);
        t = IBalanceTreasuryV2(d.treasury);
        v3 = IControllerV3(d.controller);
        user = _user("phase3 user");
    }

    /// the owner's migrate run, then the Core settings send `SET_balanceBidCapBps=10000` of the command sequence
    function _migrate() internal {
        script.migrate(address(core), d, script.params(), false);
        ctl = IControllerV1(address(v3));
        Settings memory cfg = core.settings();
        cfg.balanceBidCapBps = 10_000;
        _setSettings(cfg);
    }

    function test_migrationMovesEverythingAndTheCoreRunsAgainstV2() public {
        // promise: the migration moves all BALANCE and the claim reserve to v2, and the Core's exchange and Statement conversion work against v2
        uint256 custody1 = v1.custody();
        uint256 claims1 = v1.claimReserve();
        uint256 owed1 = v1.totalOwed();
        _migrate();
        assertEq(v1.custody(), owed1, "v1 keeps only its debt");
        assertEq(t.custody(), custody1 - owed1, "every other BALANCE is in v2");
        assertEq(_bucket(d.redeemer), claims1, "the claim reserve is the pro-rata bucket");

        uint256[] memory ids = _credits(seller, 1);
        uint256 pay = core.balanceBidOf(ids[0]);
        assertGt(pay, 0, "the Core's exchange quotes against v2");
        uint256 held = _balanceOf(seller);
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(_balanceOf(seller) - held, pay, "the Core's exchange paid from v2");

        uint256 sid = _compose();
        vm.warp(block.timestamp + 7 days);
        uint256 rating = core.ratingOf(sid);
        uint256 before = t.custody();
        uint256 bucketBefore = _bucket(d.redeemer);
        core.redeemStatement(sid);
        uint256 got = t.custody() - before;
        assertGe(got, rating * 1e14, "the conversion returned at least par into v2");
        assertEq(_bucket(d.redeemer) - bucketBefore, got / 10, "10 percent fed the pro-rata bucket");
    }

    function test_bidBuysAdoptsAndRefusesTheResaleLoop() public {
        // promise: a real Credit sold to sellCredit is adopted, composed and converted with BALANCE back in v2, and a credit the engine resold inside the return lock is refused
        _migrate();
        vm.warp(block.timestamp + core.settings().returnLockSeconds + 1);
        script.enableBid(address(core), d, false);
        assertGt(t.bidBudget(), 0, "the sweep funded the bid");

        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.setApprovalForAll(address(t), true);
        (uint256 q, uint256 toArtist) = t.quoteCredit(ids[0]);
        assertGt(q, 0, "the bid quotes a real credit");
        uint256 budget = t.bidBudget();
        uint256 held = _balanceOf(seller);
        uint256 splitHeld = _balanceOf(core.artist());
        vm.prank(seller);
        t.sellCredit(ids, q);
        assertEq(_balanceOf(seller) - held, q, "the seller got the quote");
        assertEq(_balanceOf(core.artist()) - splitHeld, toArtist, "the split got the royalty on top");
        assertEq(budget - t.bidBudget(), q + toArtist, "both came from the bid budget");
        (bool inPile,,) = core.creditInfo(ids[0]);
        assertTrue(inPile, "the credit was adopted");

        uint256 sid = _compose();
        vm.warp(block.timestamp + 7 days);
        uint256 before = t.custody();
        core.redeemStatement(sid);
        assertGe(t.custody() - before, core.ratingOf(sid) * 1e14, "its Statement converted into v2");

        uint256 id = _ethFill(1)[0];
        vm.warp(block.timestamp + 1);
        uint256 price = v3.creditPrice(id);
        vm.deal(user, price);
        vm.prank(user);
        v3.buyCredit{value: price}(id);
        vm.prank(user);
        CREDITS.setApprovalForAll(address(t), true);
        vm.expectRevert(abi.encodeWithSignature("ReturnLocked(uint256)", id));
        vm.prank(user);
        t.sellCredit(_one(id), 0);
    }

    function test_bidNeverPaysAbovePar() public {
        // promise: the v2 bid is bounded at par, refuses a cap above par, and stays under the controller's credit floor multiplier
        _migrate();
        vm.warp(block.timestamp + 1 days);
        script.enableBid(address(core), d, false);
        assertEq(t.bidBpsNow(), 10_000, "the bid climbed to its cap, par");
        assertLt(t.bidBpsNow(), v3.floorMultBps(), "under the resale floor multiplier");
        uint256 id = _credits(seller, 1)[0];
        (uint256 q,) = t.quoteCredit(id);
        assertGt(q, 0, "the bid quotes");
        assertLe(q, _scoreOf(id) * 1e14, "never above par");
        BalanceBid memory b = script.params().bid;
        b.capBps = 10_001;
        vm.expectRevert(abi.encodeWithSignature("BadSetting(bytes32)", bytes32("bidBand")));
        vm.prank(owner);
        t.setBid(b);
    }

    function test_redeemersPayFromTheirBucketInsideTheirCaps() public {
        // promise: redeemer 1 burns CC and pays ccIn * B / S less the fee and reverts on a stale epoch; a test redeemer's vesting and deferred payouts never exceed its bucket or caps
        _migrate();
        uint256 cc = _buyCoin(user, 1 ether);
        vm.prank(user);
        IPhase3Coin(address(coin)).approve(address(t), type(uint256).max);
        vm.prank(owner);
        t.setRedeemerOn(d.redeemer, true);
        uint64 epoch = _epoch(d.redeemer);
        vm.expectRevert(abi.encodeWithSignature("RedemptionOff()"));
        vm.prank(user);
        t.redeemCC(d.redeemer, cc / 4, user, 0, block.timestamp, epoch, "");
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSignature("StaleEpoch()"));
        vm.prank(user);
        t.redeemCC(d.redeemer, cc / 4, user, 0, block.timestamp, epoch + 1, "");

        uint256 b = _bucket(d.redeemer);
        uint256 s = IPhase3Coin(address(coin)).totalSupply();
        uint256 held = _balanceOf(user);
        vm.prank(user);
        (uint256 paid,) = t.redeemCC(d.redeemer, cc / 4, user, 0, block.timestamp, epoch, "");
        assertEq(paid, (cc / 4) * b / s, "ccIn * B / S at a zero fee");
        assertEq(_balanceOf(user) - held, paid, "paid at once to the recipient");
        assertEq(IPhase3Coin(address(coin)).totalSupply(), s - cc / 4, "the CC was burned");

        FixedRedeemer r = new FixedRedeemer();
        vm.startPrank(owner);
        t.registerRedeemer(address(r), 1_000 ether, 1_500 ether, 2_000 ether);
        t.unallocate(address(0), 2_500 ether); // the sweep shared the whole surplus; the bid budget gives some back
        t.allocate(address(r), 2_500 ether);
        t.setRedeemerOn(address(r), true);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        epoch = _epoch(address(r));
        uint256 unit = cc / 16;

        r.set(1_000 ether, 1, 100);
        uint256 committed = t.totalCommitted();
        (, uint256 vestId) = _redeem(address(r), unit, epoch);
        assertEq(t.totalCommitted() - committed, 1_000 ether, "the vesting payout is reserved in full");
        vm.warp(block.timestamp + 50);
        assertEq(t.release(vestId), 500 ether, "half vested at half time");
        r.set(500 ether, 2, 100);
        (, uint256 deferId) = _redeem(address(r), unit, epoch);
        vm.expectRevert(abi.encodeWithSignature("NothingDue()"));
        t.release(deferId);
        vm.warp(block.timestamp + 100);
        assertEq(t.release(vestId), 500 ether, "the rest of the vesting");
        assertEq(t.release(deferId), 500 ether, "the deferred payout at its time");
        assertEq(_balanceOf(user) - held - paid, 1_500 ether, "every committed payout reached the recipient");

        r.set(1, 0, 0);
        vm.expectRevert(abi.encodeWithSignature("OverCap()"));
        _redeem(address(r), unit, epoch); // the period cap of 1,500 is used
        vm.warp(block.timestamp + 1 days);
        r.set(1_000 ether + 1, 0, 0);
        vm.expectRevert(abi.encodeWithSignature("InsufficientBucket()"));
        _redeem(address(r), unit, epoch); // 1,000 left in the bucket
        r.set(501 ether, 0, 0);
        vm.expectRevert(abi.encodeWithSignature("OverCap()"));
        _redeem(address(r), unit, epoch); // the lifetime cap of 2,000 has 500 left
        r.set(500 ether, 0, 0);
        _redeem(address(r), unit, epoch);
        assertEq(_bucket(address(r)), 500 ether, "only its own bucket paid");
    }

    function test_breakEvenRunKeepsWorkingAboveTheCushion() public {
        // promise: a scripted run of bid fills, conversions and redemptions leaves working funds at or above the cushion
        _migrate();
        vm.warp(block.timestamp + 1 days);
        script.enableBid(address(core), d, false);
        vm.prank(owner);
        t.setRedeemerOn(d.redeemer, true);
        uint256 cc = _buyCoin(user, 1 ether);
        vm.prank(user);
        IPhase3Coin(address(coin)).approve(address(t), type(uint256).max);
        vm.prank(seller);
        CREDITS.setApprovalForAll(address(t), true);
        _assertAboveCushion("after the migration");
        for (uint256 round; round < 2; ++round) {
            uint256[] memory ids = _credits(seller, 3);
            vm.prank(seller);
            t.sellCredit(ids, 0);
            _assertAboveCushion("after bid fills");
            uint256 sid = _compose();
            vm.warp(block.timestamp + 7 days);
            core.redeemStatement(sid);
            _assertAboveCushion("after a conversion");
            t.sweep();
            _assertAboveCushion("after a sweep");
            _redeem(d.redeemer, cc / 4, _epoch(d.redeemer));
            _assertAboveCushion("after a redemption");
        }
        assertTrue(t.solvent(), "custody covers every earmark");
    }

    function test_controllerV3BandLooseningAndViews() public {
        // promise: V3 passes the band check at the live parameters with headroom, its idle loosening ships at zero and once enabled is bounded and returns to zero on a purchase, and every view the Core, keeper, indexer and web read answers
        _migrate();
        (uint256 ccRef, bool okcc) = v3.ccPrice();
        assertTrue(v3.ccPoolKeySet() && okcc && ccRef != 0, "the migrate run set the CC reference");
        (, uint16 step, uint16 tol,,,) = v3.quote();
        uint256 margin = core.settings().balanceBidMarginBps;
        assertLt((10_000 + uint256(step)) * (10_000 + tol) * (10_000 - margin), 0.995e12, "at least 50 bps headroom");
        _checkLoosening();
        _checkViews();
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        core.refreshReference();
        (, okcc) = v3.ccPrice();
        assertFalse(okcc, "a stale CC reference pauses");
    }

    /// shipped at cap 0; once the owner sets a cap the loosening stops at it, carries into the buy price and returns to
    /// zero on a purchase
    function _checkLoosening() internal {
        vm.warp(block.timestamp + 30 days);
        assertEq(v3.idleLoosenBps(), 0, "shipped at cap 0: no loosening above value");
        vm.prank(owner);
        v3.setIdleLoosening(IdleLoosening({stepSeconds: 600, bps: 50, capBps: 700}));
        v3.syncFill();
        uint256 l0 = v3.idleLoosenBps();
        (uint256 vb0,) = v3.valuePerPoint(false);
        vm.warp(block.timestamp + 30 days);
        assertEq(v3.idleLoosenBps(), 700, "the loosening stops at its cap");
        (uint256 vb1,) = v3.valuePerPoint(false);
        assertApproxEqRel(vb1 * (10_000 + l0), vb0 * 10_700, 1e12, "the buy price carries the loosening");
        _ethFill(1);
        assertEq(v3.idleLoosenBps(), 0, "a purchase makes the tail unknown: no loosening");
        v3.syncFill();
        assertEq(v3.idleLoosenBps(), 0, "synced to the purchase: no loosening");
    }

    /// every controller view the Core, keeper, indexer and web read
    function _checkViews() internal {
        uint256 id = core.pilePage(0, 1)[0];
        v3.nextPage();
        (,, uint64 acquiredAt) = core.creditInfo(id);
        v3.pastWindow(acquiredAt);
        assertGt(v3.creditPrice(id), 0, "creditPrice");
        (uint256 vb, bool okb) = v3.valuePerPoint(false);
        assertTrue(okb && vb != 0, "valuePerPoint(false)");
        (, bool okc) = v3.balanceClampFor(1_000_000, 1e20);
        assertTrue(okc, "balanceClampFor");
        assertGt(core.ethRate(), 0, "the Core's eth bid reads V3");
        assertGt(core.balanceBidOf(id), 0, "the Core's balance bid reads V3");
        (uint256 spot, bool oks) = v3.spotPrice();
        assertTrue(oks && spot != 0 && v3.referencePrice() != 0 && v3.referenceTime() != 0, "the reference");
        assertTrue(v3.balancePoolKeySet() && v3.creditSaleOn() && v3.statementSalesEnabled(), "flags");
        assertEq(v3.floorMultBps(), 11_000, "floorMultBps at the Core's cap of par");
        assertEq(v3.markupBps(), 11_000, "markupBps");
        assertEq(v3.decayHours(), 1, "decayHours");
        assertEq(v3.startCapBps(), 11_000, "startCapBps");
        assertEq(v3.anchorBps(), 10_000, "anchorBps");
        assertTrue(v3.ageEligibilityOn(), "ageEligibilityOn");
        assertGt(v3.pointRate(), 0, "pointRate");
        assertGt(v3.valueOf(10_000), 0, "valueOf");
    }

    // ------------------------------------------------------------------ redeemer 2 (MarketRedeemer)

    function test_marketRedeemerPaysTheProtectedRatePlusPremium() public {
        // promise: redeemer 2 burns CC and pays at once ccIn * min(CC reference, CC spot) / max(BALANCE reference, BALANCE spot) * 1.05 from its own bucket
        IMarketRedeemer m = _marketOn();
        uint256 cc = _userCc(0.05 ether);
        (uint256 pCc, uint256 pBal, bool ok) = m.prices();
        assertTrue(ok, "priced");
        assertEq(pCc, _lowestCc(), "the CC side is the lowest of reference, prior block sample and spot");
        assertEq(pBal, _highestBalance(), "the BALANCE side is the highest of reference, prior block sample and spot");
        uint256 want = cc * 10_500 * pCc / (pBal * 10_000);
        uint256 bucket = _bucket(d.market);
        uint256 supply = IPhase3Coin(address(coin)).totalSupply();
        uint256 held = _balanceOf(user);
        (uint256 paid,) = _redeemMarket(cc);
        assertEq(paid, want, "the protected rate plus 500 bps");
        assertEq(_balanceOf(user) - held, paid, "paid at once");
        assertEq(bucket - _bucket(d.market), paid, "from redeemer 2's bucket");
        assertEq(IPhase3Coin(address(coin)).totalSupply(), supply - cc, "the CC was burned");
    }

    function test_marketRedeemerOneBlockPumpCannotRaiseThePayout() public {
        // promise: pumping the CC pool up or the BALANCE pool down within a block never raises redeemer 2's payout above its reference bounds
        IMarketRedeemer m = _marketOn();
        uint256 cc = _userCc(0.05 ether);
        (uint256 before,) = m.preview(cc);
        assertGt(before, 0, "priced before the pumps");
        uint256 ccSpot0 = _ccSpot();
        (uint256 balSpot0,) = v3.spotPrice();
        address pumper = _user("pumper");
        _buyCoin(pumper, 5 ether);
        (uint256 afterCc,) = m.preview(cc);
        assertGt(_ccSpot(), ccSpot0 * 11 / 10, "the CC pool rose more than 10 percent");
        assertLe(afterCc, before, "a CC pump does not raise the payout");
        _fundBalance(pumper, 30_000 ether);
        PoolKey memory k = _v3BalanceKey();
        vm.startPrank(pumper);
        IPhase3Coin(liveBalanceToken).approve(address(router), type(uint256).max);
        router.swap(k, false, -int256(30_000 ether), pumper);
        vm.stopPrank();
        (uint256 balSpot1,) = v3.spotPrice();
        assertLt(balSpot1, balSpot0 * 97 / 100, "the BALANCE pool fell more than 3 percent");
        v3.refreshCcReference();
        (uint256 afterBoth,) = m.preview(cc);
        assertLe(afterBoth, before, "a BALANCE dump and a same block refresh do not raise the payout");
        (uint256 paid,) = _redeemMarket(cc);
        assertLe(paid, before, "the burn pays no more than before the pumps");
    }

    function test_marketRedeemerLaggingReferenceCannotBeMetByAPump() public {
        // promise: after a CC fall the reference lags above the price, but a refresh records the fallen spot, so pumping the live spot back to the lagging reference in a later block does not raise redeemer 2's payout above the fallen price
        IMarketRedeemer m = _marketOn();
        uint256 cc = _userCc(0.05 ether);
        address whale = _user("whale");
        uint256 whaleCc = _buyCoin(whale, 10 ether);
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.roll(block.number + 1);
            assertTrue(v3.refreshCcReference(), "the reference follows the rise");
        }
        _sellCoin(whale, whaleCc);
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        assertTrue(v3.refreshCcReference(), "a refresh after the fall");
        (uint256 ccRef, bool ok) = v3.ccPrice();
        uint256 fallen = _ccSpot();
        assertTrue(ok, "the reference is usable");
        assertGt(ccRef, fallen * 120 / 100, "the reference lags more than 20 percent above the fallen price");

        vm.roll(block.number + 1);
        _buyCoin(_user("attacker"), 10 ether);
        assertGt(_ccSpot(), ccRef, "the live spot is pumped past the lagging reference");
        assertEq(v3.ccPriorSample(), fallen, "the prior block sample is the fallen spot");
        (uint256 pCc, uint256 pBal,) = m.prices();
        assertEq(pCc, fallen, "CC is priced at the fallen spot, not the lagging reference");
        (uint256 paid,) = _redeemMarket(cc);
        assertEq(paid, cc * 10_500 * fallen / (pBal * 10_000), "paid at the fallen price plus the premium");
    }

    function test_marketRedeemerLaggingBalanceReferenceCannotBeMetByADump() public {
        // promise: after a BALANCE rise the BALANCE reference lags below the price, but a refresh records the risen spot, so dumping the live spot back below the lagging reference in a later block does not price BALANCE under the risen price
        IMarketRedeemer m = _marketOn();
        uint256 cc = _userCc(0.05 ether);
        address riser = _user("riser");
        PoolKey memory k = _v3BalanceKey();
        vm.deal(riser, 20 ether);
        vm.prank(riser);
        router.swap{value: 20 ether}(k, true, -int256(20 ether), riser);
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        assertTrue(v3.refreshReference(), "a refresh after the rise");
        (uint256 risen,) = v3.spotPrice();
        uint256 balRef = v3.referencePrice();
        assertLt(balRef * 105 / 100, risen, "the reference lags more than 5 percent below the risen price");

        vm.roll(block.number + 1);
        uint256 bal = _balanceOf(riser);
        vm.startPrank(riser);
        IPhase3Coin(liveBalanceToken).approve(address(router), type(uint256).max);
        router.swap(k, false, -int256(bal), riser);
        vm.stopPrank();
        (uint256 live,) = v3.spotPrice();
        assertLt(live, balRef, "the live spot is dumped below the lagging reference");
        assertEq(v3.balancePriorSample(), risen, "the prior block sample is the risen spot");
        (uint256 pCc, uint256 pBal,) = m.prices();
        assertEq(pBal, risen, "BALANCE is priced at the risen spot, not the lagging reference");
        (uint256 paid,) = _redeemMarket(cc);
        assertEq(paid, cc * 10_500 * pCc / (risen * 10_000), "paid at the risen BALANCE price");
    }

    function test_marketRedeemerBucketAndDailyCap() public {
        // promise: redeemer 2 cannot pay past its bucket, its per call cap or its per day cap
        IMarketRedeemer m = _marketOn();
        _userCc(1 ether);
        uint256 per = _ccFor(m, 1_000 ether);
        _redeemMarketReverts(per * 51 / 10, 0, abi.encodeWithSignature("OverCap()")); // 5,100 over the 5,000 per call
        for (uint256 i; i < 4; ++i) {
            _redeemMarket(per * 49 / 10); // 4,900 each, 19,600 of the 20,000 per day
        }
        _redeemMarketReverts(per / 2, 0, abi.encodeWithSignature("OverCap()")); // 500 more passes the day
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        v3.refreshCcReference();
        uint256 bucket = _bucket(d.market);
        vm.startPrank(owner);
        t.setRedeemerOn(d.market, false);
        t.unallocate(d.market, bucket - 1_000 ether);
        t.setRedeemerOn(d.market, true);
        vm.stopPrank();
        per = _ccFor(m, 1_000 ether);
        _redeemMarketReverts(per * 11 / 10, 0, abi.encodeWithSignature("InsufficientBucket()")); // 1,100, 1,000 left
        _redeemMarket(per * 9 / 10);
        assertLt(_bucket(d.market), 1_000 ether, "only the bucket paid");
    }

    function test_marketRedeemerRefusesAStaleEpochOrPrice() public {
        // promise: redeemer 2 reverts on a stale treasury epoch, a stale premium epoch, a premium above its bound and a stale CC reference
        IMarketRedeemer m = _marketOn();
        uint256 cc = _userCc(0.05 ether);
        uint64 epoch = _epoch(d.market);
        uint64 premiumEpoch = m.configEpoch();
        vm.expectRevert(abi.encodeWithSignature("StaleEpoch()"));
        vm.prank(user);
        t.redeemCC(d.market, cc, user, 0, block.timestamp, epoch + 1, abi.encode(premiumEpoch));
        vm.prank(owner);
        m.setPremiumBps(800);
        vm.expectRevert(abi.encodeWithSignature("StaleEpoch()"));
        vm.prank(user);
        t.redeemCC(d.market, cc, user, 0, block.timestamp, epoch, abi.encode(premiumEpoch));
        vm.expectRevert(abi.encodeWithSignature("BadPremium()"));
        vm.prank(owner);
        m.setPremiumBps(1_501);
        (uint256 q,) = m.preview(cc);
        _redeemMarketReverts(cc, q + 1, abi.encodeWithSignature("Slippage()"));
        vm.warp(block.timestamp + 2 hours);
        _redeemMarketReverts(cc, 0, abi.encodeWithSignature("Unpriced()"));
    }

    // ------------------------------------------------------------------ helpers

    function _bucket(address r) internal view returns (uint256 b) {
        b = t.redeemers(r).bucket;
    }

    function _epoch(address r) internal view returns (uint64 e) {
        e = t.redeemers(r).epoch;
    }

    function _redeem(address r, uint256 ccIn, uint64 epoch) internal returns (uint256 amount, uint256 claimId) {
        vm.prank(user);
        (amount, claimId) = t.redeemCC(r, ccIn, user, 0, block.timestamp, epoch, "");
    }

    function _assertAboveCushion(string memory when) internal view {
        assertGe(t.working(), t.cushion(), when);
    }

    /// real credits sold into the Core's eth bid, the pot funded first
    function _ethFill(uint256 n) internal returns (uint256[] memory ids) {
        ids = _credits(seller, n);
        _fundPot(5 ether);
        for (uint256 i; i < n; ++i) {
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
        }
    }

    /// fills the pile to a page through the eth bid, ages it past the credit window and composes. returns the Statement
    function _compose() internal returns (uint256 sid) {
        uint256 size = core.pileSize();
        if (size < 80) _ethFill(80 - size);
        _warpPageReady();
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
        (bool held,,) = core.statementInfo(sid);
        assertTrue(held, "the Core holds the new Statement");
    }

    /// the migrated state with redeemer 2 past its start delay, its CC reference fresh, switched on, and the user's
    /// coin approved to the treasury
    function _marketOn() internal returns (IMarketRedeemer m) {
        _migrate();
        m = IMarketRedeemer(d.market);
        assertGt(_bucket(d.market), 0, "the sweep funded redeemer 2");
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        assertTrue(v3.refreshCcReference(), "the CC reference refreshed");
        vm.prank(owner);
        t.setRedeemerOn(d.market, true);
    }

    /// CC bought by the user for `eth`, approved to the treasury for `burnFrom`
    function _userCc(uint256 eth) internal returns (uint256 cc) {
        cc = _buyCoin(user, eth);
        vm.prank(user);
        IPhase3Coin(address(coin)).approve(address(t), type(uint256).max);
    }

    function _redeemMarket(uint256 ccIn) internal returns (uint256 amount, uint256 claimId) {
        (uint64 e, bytes memory data) = _marketArgs();
        vm.prank(user);
        (amount, claimId) = t.redeemCC(d.market, ccIn, user, 0, block.timestamp, e, data);
    }

    /// a redemption through redeemer 2 that must revert with `err`. the arguments are read before the cheatcodes, so
    /// the prank and the expectation reach the redemption itself
    function _redeemMarketReverts(uint256 ccIn, uint256 minOut, bytes memory err) internal {
        (uint64 e, bytes memory data) = _marketArgs();
        vm.expectRevert(err);
        vm.prank(user);
        t.redeemCC(d.market, ccIn, user, minOut, block.timestamp, e, data);
    }

    /// the treasury epoch of redeemer 2 and its premium epoch as `data`
    function _marketArgs() internal view returns (uint64 e, bytes memory data) {
        e = _epoch(d.market);
        data = abi.encode(IMarketRedeemer(d.market).configEpoch());
    }

    /// the CC that redeemer 2 pays `amount` for now
    function _ccFor(IMarketRedeemer m, uint256 amount) internal view returns (uint256) {
        (uint256 a,) = m.preview(1e24);
        return 1e24 * amount / a;
    }

    function _v3BalanceKey() internal view returns (PoolKey memory k) {
        (IControllerV3.Currency c0, IControllerV3.Currency c1, uint24 fee, int24 spacing, address hooks) =
            v3.balancePoolKey();
        k = PoolKey({
            currency0: Currency.wrap(IControllerV3.Currency.unwrap(c0)),
            currency1: Currency.wrap(IControllerV3.Currency.unwrap(c1)),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hooks)
        });
    }

    function _lowestCc() internal view returns (uint256 low) {
        (uint256 ccRef,) = v3.ccPrice();
        low = _ccSpot();
        if (ccRef < low) low = ccRef;
        uint256 sample = v3.ccPriorSample();
        if (sample < low) low = sample;
    }

    function _highestBalance() internal view returns (uint256 high) {
        (high,) = v3.spotPrice();
        uint256 balRef = v3.referencePrice();
        if (balRef > high) high = balRef;
        uint256 sample = v3.balancePriorSample();
        if (sample > high) high = sample;
    }

    function _ccSpot() internal view returns (uint256) {
        (uint160 p,,,) = IPoolManager(Mainnet.POOL_MANAGER).getSlot0(PoolId.wrap(poolId));
        uint256 q = FixedPoint96.Q96;
        return (1e18 * q / p) * q / p;
    }
}
