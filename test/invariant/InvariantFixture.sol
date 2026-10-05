// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Core} from "../../src/Core.sol";
import {Lane, ICreditScore, ICreditStrategy, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {Fixture} from "../utils/Fixture.sol";
import {CreditIds} from "../utils/CreditIds.sol";
import {MockExitModule} from "../standins/MockExitModule.sol";
import {MockExitToken} from "../standins/MockExitToken.sol";
import {ProbeTarget} from "../attackers/ProbeTarget.sol";
import {FuzzController} from "../attackers/FuzzController.sol";
import {TestLiquidityHelper} from "../utils/TestLiquidityHelper.sol";
import {Handler, Wiring} from "./Handler.sol";

/// @notice builds the real system on the fork for the invariant suites on top of the single real stack `Fixture`:
/// the real Core and ControllerV1 deployed through the deploy path, the coin launched through the live artcoins
/// factory, the live skim hook, locker, mev module and pool manager, and the live Credits, CreditScore, Statements
/// and CreditStrategy. the only stand ins are the exit module and exit token of phase 2. the attack contracts are
/// the fuzz controller and the hostile listing target. the owner adds the hostile target, the fuzz controller and,
/// in phase 2, the exit module through the real timelock. the eth pot is funded by real swap fees, the piles are
/// pre filled with real credits so that composes happen, and the clock is moved so that the rate has climbed far
/// enough for the real CreditStrategy listings to fit under the ceiling.
///
/// two start states: after the sniper window (the owner setup needs the seven day timelock, so everything that
/// needs the owner has run) and inside it (the run starts a few seconds after launch, the owner actions are only
/// queued and the handler executes them once the timelock has run, the skim is 90 percent).
abstract contract InvariantFixture is Fixture {
    /// eth the whale spends on coin. in steady state 9.5 percent of it becomes pot
    uint256 internal constant FUND_ETH = 40 ether;
    /// credits that stay in the eth pile after the pre filled composes, so two more fill it to 80
    uint256 internal constant LEFT_IN_PILE = 78;
    /// real listings are read from this index of the strategy list, after the credits that move
    uint256 internal constant CANDIDATE_START = 600;

    FuzzController internal fuzz;
    ProbeTarget internal probeTarget;
    Handler internal handler;
    address internal filler;
    address internal whale;
    TestLiquidityHelper internal lp;
    PoolKey internal sideKey;

    /// @dev the suites differ in the exit phase, the controller, the start state and the tag of their counters.
    function _build(bool phase2, bool hostile, bool canSwapController, bool inWindow, string memory tag) internal {
        Fixture.setUp();
        filler = _user("inv.filler");
        whale = _user("inv.whale");
        fuzz = new FuzzController(address(core));
        probeTarget = new ProbeTarget(address(core));
        if (phase2) {
            xt = new MockExitToken("Exit Token", "XT");
            mod = new MockExitModule(address(xt), UNIT);
        }
        uint256 targetEta;
        uint256 controllerEta;
        if (inWindow) {
            (targetEta, controllerEta) = _queueOnly();
        } else {
            controllerEta = _ownerSetup(phase2, hostile, canSwapController);
        }
        _fundWhale();
        _sidePool();

        Wiring memory w = Wiring({
            core: core,
            coin: coin,
            router: router,
            launchKey: launchKey,
            sideKey: sideKey,
            poolId: poolId,
            owner: owner,
            v1: address(ctl),
            fuzz: fuzz,
            probe: probeTarget,
            module: mod,
            exitToken: xt,
            canSwapController: canSwapController,
            tag: tag
        });
        handler = new Handler(w);
        if (inWindow) {
            handler.seedPendingTarget(targetEta);
            handler.seedPendingController(address(fuzz), controllerEta);
        } else if (canSwapController) {
            handler.seedPendingController(address(fuzz), controllerEta);
        }
        _actors();
        _prefill(phase2);
        _holders();
        _candidates();
        if (hostile) {
            fuzz.setHostile(true);
            fuzz.setSeed(uint256(keccak256("hostile start")));
        }
        _seedGhosts(phase2);
        if (!inWindow) {
            // four days without a fill let the rate climb about thirtyfold, which puts the cheapest real listings
            // under the ceiling, and the fuzz can warp the rest
            vm.warp(block.timestamp + 4 days);
            vm.roll(block.number + 4 days / 12);
        } else {
            assertLt(block.timestamp, launchTime + SNIPER_WINDOW / 2, "the window start state drifted");
        }
        assertLt(creditCursor, CANDIDATE_START, "the moved credits reach the listing candidates");
        _targets(phase2);
    }

    /*//////////////////////////////////////////////////////////////
                                  STEPS
    //////////////////////////////////////////////////////////////*/

    /// the owner queues the hostile target and the fuzz controller and waits for nothing. returns their etas
    function _queueOnly() internal returns (uint256 targetEta, uint256 controllerEta) {
        vm.startPrank(owner);
        core.queue(Core.Action.AddTarget, abi.encode(address(probeTarget)));
        core.queue(Core.Action.SetController, abi.encode(address(fuzz)));
        vm.stopPrank();
        targetEta = block.timestamp + core.TIMELOCK();
        controllerEta = targetEta;
    }

    /// everything that needs the seven day timelock is queued together and executed after one wait. in the swap
    /// suites the fuzz controller is queued as well and left ripe, so the handler can switch to it at any time.
    /// returns the eta of that queued controller
    function _ownerSetup(bool phase2, bool hostile, bool canSwapController) internal returns (uint256 eta) {
        vm.startPrank(owner);
        core.queue(Core.Action.AddTarget, abi.encode(address(probeTarget)));
        if (hostile || canSwapController) core.queue(Core.Action.SetController, abi.encode(address(fuzz)));
        if (phase2) core.queue(Core.Action.SetExitModule, abi.encode(address(mod)));
        eta = block.timestamp + core.TIMELOCK();
        vm.warp(eta + 1);
        core.execute(Core.Action.AddTarget, abi.encode(address(probeTarget)));
        if (hostile) core.execute(Core.Action.SetController, abi.encode(address(fuzz)));
        if (phase2) core.execute(Core.Action.SetExitModule, abi.encode(address(mod)));
        vm.stopPrank();
        inPhase2 = phase2;
        assertTrue(core.allowedTarget(address(probeTarget)));
    }

    /// the whale buys coin through the real launch pool. the skim funds the eth pot, and the whale holds coin
    function _fundWhale() internal {
        _buyCoin(whale, FUND_ETH);
        vm.prank(whale);
        coin.approve(address(router), type(uint256).max);
        assertGt(core.ethPot(), 3 ether);
        assertEq(address(core).balance, core.ethPot());
    }

    /// a hookless side pool of the coin in the real pool manager, which is a venue of the coin's buy tax, with the
    /// whale's liquidity around the launch price
    function _sidePool() internal {
        lp = new TestLiquidityHelper();
        sideKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(coin)), 3000, 60, IHooks(address(0)));
        PM.initialize(sideKey, TickMath.getSqrtPriceAtTick(175_020));
        vm.deal(whale, whale.balance + 6 ether);
        vm.startPrank(whale);
        coin.approve(address(lp), type(uint256).max);
        lp.modify{value: 5 ether}(sideKey, 174_000, 176_040, 1e23);
        vm.stopPrank();
    }

    /// four actors with credits, eth and coin, all approved for the core and the router. every approval and every
    /// swap is real
    function _actors() internal {
        for (uint256 i; i < 4; ++i) {
            address a = _user(string.concat("inv.actor", vm.toString(i)));
            vm.deal(a, 100 ether);
            vm.prank(a);
            coin.approve(address(router), type(uint256).max);
            _buyCoin(a, 2 ether);
            handler.addActor(a);
            handler.giveCredits(a, _credits(a, 40));
        }
    }

    /// real credits sold into the piles, three composes so statements exist for the auction, the exit and the
    /// overprint, and one statement bought, so the buyback pot is not empty when the run starts. in phase 2 the exit
    /// token bid is funded and 80 more credits are sold into it, so the exit lane has a full page
    function _prefill(bool phase2) internal {
        uint256 ethN = 3 * 80 + LEFT_IN_PILE;
        uint256[] memory ids = _credits(filler, ethN + (phase2 ? 80 : 0));
        vm.fee(1 gwei);
        uint256[] memory ethIds = new uint256[](ethN);
        for (uint256 i; i < ethN; ++i) {
            ethIds[i] = ids[i];
        }
        vm.prank(filler);
        core.sellForEth(ethIds);
        uint256 firstStatement = STATEMENTS.supply() + 1;
        for (uint256 i; i < 3; ++i) {
            vm.prank(keeper);
            core.compose();
        }
        assertEq(core.pileSize(Lane.Eth), LEFT_IN_PILE);
        uint256 price = core.priceOf(firstStatement);
        vm.deal(whale, whale.balance + price);
        vm.prank(whale);
        core.buyStatement{value: price}(firstStatement);
        assertGt(core.ethToBuyback(), 0);
        if (phase2) {
            // the exit token bid is funded the way the module would: exit token arrives and skim books it
            xt.mint(address(core), 1e20);
            core.skim();
            uint256[] memory exitIds = new uint256[](80);
            for (uint256 i; i < 80; ++i) {
                exitIds[i] = ids[ethN + i];
            }
            vm.prank(filler);
            core.sellForExitToken(exitIds);
            assertEq(core.pileSize(Lane.Exit), 80);
        }
    }

    /// credits held by the hostile target
    function _holders() internal {
        handler.setProbeIds(_credits(address(probeTarget), 16));
        vm.deal(address(probeTarget), 100 ether);
    }

    /// the real listings with the most score per eth, so the ceiling reaches them first.
    function _candidates() internal {
        uint256 n = 40;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory key = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 id = CreditIds.at(CANDIDATE_START + i);
            ids[i] = id;
            uint256 price = ICreditStrategy(Mainnet.CREDIT_STRATEGY).nftForSale(id);
            uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
            // price per point, larger is worse. unlisted ids sort last
            key[i] = price == 0 ? type(uint256).max : price * 1e4 / score;
        }
        // keep the best 12 by selection
        uint256 keep = 12;
        uint256[] memory best = new uint256[](keep);
        for (uint256 k; k < keep; ++k) {
            uint256 bi;
            uint256 bk = type(uint256).max;
            for (uint256 i; i < n; ++i) {
                if (key[i] < bk) {
                    bk = key[i];
                    bi = i;
                }
            }
            best[k] = ids[bi];
            key[bi] = type(uint256).max;
        }
        handler.setCandidates(best);
    }

    /// tells the handler what the fixture already did, so the ghost model starts level with the core.
    function _seedGhosts(bool phase2) internal {
        _seedLane(Lane.Eth);
        if (phase2) _seedLane(Lane.Exit);
        uint256[] memory held = core.heldStatements();
        for (uint256 i; i < held.length; ++i) {
            (, Lane lane, uint256 cost,) = core.statementInfo(held[i]);
            handler.seedGhostStatement(held[i], uint8(lane), cost);
        }
        handler.seedGhostWindow(_windowStart(), _windowPot(), _windowSpent());
    }

    function _seedLane(Lane lane) internal {
        uint256[] memory ids = core.pilePage(lane, 0, 200);
        for (uint256 i; i < ids.length; ++i) {
            (,, uint256 cost,) = core.creditInfo(ids[i]);
            handler.seedGhostPile(ids[i], uint8(lane), cost);
        }
    }

    // the hourly window slots of the core, from `forge inspect Core storage-layout`: windowStart is the uint64 at
    // byte 17 of slot 10, windowPot is slot 11 and windowSpent is slot 12
    function _windowStart() internal view returns (uint256) {
        return (uint256(vm.load(address(core), bytes32(uint256(10)))) >> 136) & type(uint64).max;
    }

    function _windowPot() internal view returns (uint256) {
        return uint256(vm.load(address(core), bytes32(uint256(11))));
    }

    function _windowSpent() internal view returns (uint256) {
        return uint256(vm.load(address(core), bytes32(uint256(12))));
    }

    /// the actions the fuzzer may call. the setters of the handler are left out.
    function _targets(bool phase2) internal virtual {
        bytes4[] memory s = new bytes4[](40);
        uint256 n;
        s[n++] = Handler.buyCoin.selector;
        s[n++] = Handler.buyCoin.selector;
        s[n++] = Handler.sellCoin.selector;
        s[n++] = Handler.sideBuy.selector;
        s[n++] = Handler.sellForEth.selector;
        s[n++] = Handler.sellForEth.selector;
        s[n++] = Handler.listingStrategy.selector;
        s[n++] = Handler.listingHostile.selector;
        s[n++] = Handler.warp.selector;
        s[n++] = Handler.warp.selector;
        s[n++] = Handler.roll.selector;
        s[n++] = Handler.compose.selector;
        s[n++] = Handler.buyStatement.selector;
        s[n++] = Handler.buyback.selector;
        s[n++] = Handler.skim.selector;
        s[n++] = Handler.donate.selector;
        s[n++] = Handler.controllerSeed.selector;
        s[n++] = Handler.controllerSwap.selector;
        s[n++] = Handler.overprint.selector;
        s[n++] = Handler.probeController.selector;
        // the exit module is set in the phase 2 suites before the run starts, so the exit actions are listed only there
        if (phase2) {
            s[n++] = Handler.sellForExit.selector;
            s[n++] = Handler.composeExit.selector;
            s[n++] = Handler.exitStatement.selector;
            s[n++] = Handler.buybackExit.selector;
            s[n++] = Handler.buybackExit.selector;
            s[n++] = Handler.moduleMode.selector;
        }
        bytes4[] memory sel = new bytes4[](n);
        for (uint256 i; i < n; ++i) {
            sel[i] = s[i];
        }
        // the fuzzer's own random senders would each cost a slow rpc account lookup on a fork. two fixed ones
        // are cached. the handler pranks every account it needs, so the sender is never used
        targetSender(_user("inv.sender0"));
        targetSender(_user("inv.sender1"));
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }
}
