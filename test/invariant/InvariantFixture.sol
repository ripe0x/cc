// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Core} from "../../src/Core.sol";
import {Coin} from "../../src/Coin.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {Lane, ICredits, ICreditScore, ICreditStrategy, IStatements, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {SystemDeployer, Deployed} from "../../script/Deploy.s.sol";
import {MockExitModule} from "../mocks/MockExitModule.sol";
import {MockExitToken} from "../mocks/MockExitToken.sol";
import {MockSeller} from "../mocks/MockSeller.sol";
import {ProbeTarget} from "../mocks/ProbeTarget.sol";
import {FuzzController} from "../mocks/FuzzController.sol";
import {CreditIds} from "../utils/CreditIds.sol";
import {TestSwapRouter} from "../utils/TestSwapRouter.sol";
import {TestLiquidityHelper} from "../utils/TestLiquidityHelper.sol";
import {Handler, Wiring} from "./Handler.sol";

/// @notice builds the real system on the fork for the invariant suites: real Core, Coin, FeeHook, launch pool,
/// Credits, CreditScore, Statements and CreditStrategy. the owner adds the test targets and, in phase 2, sets
/// the exit module and the exit pool key through the real timelock. the eth pot is funded by real swap fees, the
/// piles are pre filled with real credits so that composes happen, and the clock is moved so that the rate has
/// climbed far enough for the real CreditStrategy listings to fit under the ceiling.
abstract contract InvariantFixture is Test, SystemDeployer {
    /// exit token base units per 1e4 scaled score point
    uint256 internal constant UNIT = 1e14;
    /// eth the whale spends on coin, 10 percent of it becomes fees
    uint256 internal constant FUND_ETH = 40 ether;
    /// credits that stay in the eth pile after the pre filled composes, so two more fill it to 80
    uint256 internal constant LEFT_IN_PILE = 78;
    /// real listings are read from this index of the strategy list, after the credits that move
    uint256 internal constant CANDIDATE_START = 598;

    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    IPoolManager internal constant PM = IPoolManager(Mainnet.POOL_MANAGER);

    Core internal core;
    Coin internal coin;
    FeeHook internal hook;
    address internal v1;
    address internal owner;
    address internal creator;
    TestSwapRouter internal router;
    TestLiquidityHelper internal lp;
    FuzzController internal fuzz;
    MockSeller internal seller;
    ProbeTarget internal probeTarget;
    MockExitToken internal xt;
    MockExitModule internal module;
    Handler internal handler;
    PoolKey internal launchKey;
    PoolKey internal exitKey;
    address internal keeper;
    address internal filler;
    address internal whale;
    uint256 internal cursor;
    bool internal phase2;

    /// @dev the three suites differ in the exit phase, the controller and the tag of their counters.
    function _build(bool phase2_, bool hostile, bool canSwapController, string memory tag) internal {
        phase2 = phase2_;
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        // labels are namespaced because common labels are delegated accounts on mainnet and sweep eth.
        address deployer = makeAddr("credeng.inv.deployer");
        owner = makeAddr("credeng.inv.owner");
        creator = makeAddr("credeng.inv.creator");
        keeper = makeAddr("credeng.inv.keeper");
        filler = makeAddr("credeng.inv.filler");
        whale = makeAddr("credeng.inv.whale");
        assertEq(deployer.code.length + owner.code.length + creator.code.length, 0);
        assertEq(keeper.code.length + filler.code.length + whale.code.length, 0);

        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, owner, creator, "Invariant Coin", "INV");
        vm.stopPrank();
        core = Core(payable(d.core));
        coin = Coin(d.coin);
        hook = FeeHook(payable(d.hook));
        v1 = d.controller;
        launchKey = d.launchKey;
        router = new TestSwapRouter();
        lp = new TestLiquidityHelper();
        fuzz = new FuzzController(address(core));
        seller = new MockSeller();
        probeTarget = new ProbeTarget(address(core));

        if (phase2) {
            xt = new MockExitToken("Exit Token", "XT");
            module = new MockExitModule(address(xt), UNIT);
            (address c0, address c1) =
                address(coin) < address(xt) ? (address(coin), address(xt)) : (address(xt), address(coin));
            exitKey = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
        }
        _ownerSetup(hostile, canSwapController);
        _fundPot();
        if (phase2) _openExitPool();

        Wiring memory w = Wiring({
            core: core,
            coin: coin,
            hook: hook,
            router: router,
            launchKey: launchKey,
            exitKey: exitKey,
            owner: owner,
            v1: v1,
            fuzz: fuzz,
            seller: seller,
            probe: probeTarget,
            module: module,
            exitToken: xt,
            phase2: phase2,
            canSwapController: canSwapController,
            tag: tag
        });
        handler = new Handler(w);
        _handOverQueue(canSwapController);
        _actors();
        _prefill();
        _holders();
        _candidates();
        if (hostile) {
            fuzz.setHostile(true);
            fuzz.setSeed(uint256(keccak256("hostile start")));
        }
        _seedGhosts();
        // four days without a fill let the rate climb about thirtyfold, which puts the cheapest real listings
        // under the ceiling, and the fuzz can warp the rest
        vm.warp(block.timestamp + 4 days);
        vm.roll(block.number + 4 days / 12);
        _targets();
    }

    /*//////////////////////////////////////////////////////////////
                                  STEPS
    //////////////////////////////////////////////////////////////*/

    /// the loosest legal exit buyback limit for the swap direction of the exit key
    function _wideLimit() internal view returns (uint160) {
        bool exitIs0 = Currency.unwrap(exitKey.currency0) == address(xt);
        return exitIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _queue(Core.Action action, bytes memory data) internal {
        vm.prank(owner);
        core.queue(action, data);
    }

    function _execute(Core.Action action, bytes memory data) internal {
        vm.prank(owner);
        core.execute(action, data);
    }

    /// everything that needs the seven day timelock is queued together and executed after one wait.
    function _ownerSetup(bool hostile, bool canSwapController) internal {
        _queue(Core.Action.AddTarget, abi.encode(address(seller)));
        _queue(Core.Action.AddTarget, abi.encode(address(probeTarget)));
        // the prefill needs honest pages, so the fuzz controller starts benign even in the hostile suite
        if (hostile || canSwapController) _queue(Core.Action.SetController, abi.encode(address(fuzz)));
        if (phase2) {
            _queue(Core.Action.SetExitModule, abi.encode(address(module)));
            _queue(Core.Action.SetExitPoolKey, abi.encode(exitKey, _wideLimit()));
        }
        vm.warp(block.timestamp + 7 days + 1);
        _execute(Core.Action.AddTarget, abi.encode(address(seller)));
        _execute(Core.Action.AddTarget, abi.encode(address(probeTarget)));
        if (hostile) _execute(Core.Action.SetController, abi.encode(address(fuzz)));
        if (phase2) {
            _execute(Core.Action.SetExitModule, abi.encode(address(module)));
            _execute(Core.Action.SetExitPoolKey, abi.encode(exitKey, _wideLimit()));
        }
        assertTrue(core.allowedTarget(address(seller)));
        assertTrue(core.allowedTarget(address(probeTarget)));
    }

    /// in the swap suites the fuzz controller is queued and ripe from the start of the run, so the handler can
    /// switch to it at any time. switching back needs a new queue and a new week.
    function _handOverQueue(bool canSwapController) internal {
        if (!canSwapController) return;
        bytes32 id = keccak256(abi.encode(Core.Action.SetController, abi.encode(address(fuzz))));
        handler.seedPendingController(address(fuzz), core.queuedEta(id));
    }

    /// the whale buys coin through the real launch pool. the fees fund the eth pot.
    function _fundPot() internal {
        vm.deal(whale, FUND_ETH + 10 ether);
        vm.startPrank(whale);
        coin.approve(address(router), type(uint256).max);
        coin.approve(address(lp), type(uint256).max);
        router.swap{value: FUND_ETH}(launchKey, true, -int256(FUND_ETH), whale);
        vm.stopPrank();
        assertGt(core.ethPot(), 3 ether);
        assertEq(address(core).balance, core.ethPot());
    }

    /// opens the coin and exit token pool at a one to one price with deep full range liquidity.
    function _openExitPool() internal {
        assertEq(core.exitPoolId(), keccak256(abi.encode(exitKey)));
        PM.initialize(exitKey, 79228162514264337593543950336);
        uint256 amount = 1e25;
        xt.mint(whale, amount * 2);
        vm.startPrank(whale);
        xt.approve(address(lp), type(uint256).max);
        xt.approve(address(router), type(uint256).max);
        lp.modify(exitKey, -887_220, 887_220, int256(amount));
        vm.stopPrank();
    }

    function _creditsTo(address to, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 id = CreditIds.at(cursor++);
            vm.prank(Mainnet.CREDIT_STRATEGY);
            CREDITS.transferFrom(Mainnet.CREDIT_STRATEGY, to, id);
            ids[i] = id;
        }
        vm.startPrank(to);
        CREDITS.setApprovalForAll(address(core), true);
        vm.stopPrank();
    }

    /// four actors with credits, eth, coin and exit token, all approved for the core and the router.
    function _actors() internal {
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("credeng.inv.actor", vm.toString(i)));
            assertEq(a.code.length, 0);
            vm.deal(a, 100 ether);
            vm.startPrank(a);
            coin.approve(address(router), type(uint256).max);
            if (phase2) xt.approve(address(router), type(uint256).max);
            router.swap{value: 2 ether}(launchKey, true, -2 ether, a);
            vm.stopPrank();
            if (phase2) xt.mint(a, 1e24);
            handler.addActor(a);
            handler.giveCredits(a, _creditsTo(a, 40));
        }
    }

    /// real credits sold into the piles, three composes so statements exist for the auction, the exit and the
    /// overprint, and one statement bought, so the buyback pot is not empty when the run starts.
    function _prefill() internal {
        uint256 ethN = 3 * 80 + LEFT_IN_PILE;
        uint256[] memory ids = _creditsTo(filler, ethN + (phase2 ? 80 : 0));
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
            xt.mint(address(core), 1e23);
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

    /// credits held by the two mock targets.
    function _holders() internal {
        uint256[] memory ids = _creditsTo(address(seller), 24);
        handler.setSellerIds(ids);
        ids = _creditsTo(address(probeTarget), 16);
        handler.setProbeIds(ids);
        vm.deal(address(probeTarget), 100 ether);
        vm.deal(address(seller), 100 ether);
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
    function _seedGhosts() internal {
        _seedLane(Lane.Eth);
        if (phase2) _seedLane(Lane.Exit);
        uint256[] memory held = core.heldStatements();
        for (uint256 i; i < held.length; ++i) {
            (, Lane lane, uint256 cost,) = core.statementInfo(held[i]);
            handler.seedGhostStatement(held[i], uint8(lane), cost);
        }
        uint256 ws = (uint256(vm.load(address(core), bytes32(uint256(14)))) >> 136) & type(uint64).max;
        handler.seedGhostWindow(
            ws,
            uint256(vm.load(address(core), bytes32(uint256(15)))),
            uint256(vm.load(address(core), bytes32(uint256(16))))
        );
    }

    function _seedLane(Lane lane) internal {
        uint256[] memory ids = core.pilePage(lane, 0, 200);
        for (uint256 i; i < ids.length; ++i) {
            (,, uint256 cost,) = core.creditInfo(ids[i]);
            handler.seedGhostPile(ids[i], uint8(lane), cost);
        }
    }

    /// the actions the fuzzer may call. the setters of the handler are left out.
    function _targets() internal virtual {
        bytes4[] memory s = new bytes4[](40);
        uint256 n;
        s[n++] = Handler.buyCoin.selector;
        s[n++] = Handler.sellCoin.selector;
        s[n++] = Handler.sellForEth.selector;
        s[n++] = Handler.sellForEth.selector;
        s[n++] = Handler.listingStrategy.selector;
        s[n++] = Handler.listingMock.selector;
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
        if (phase2) {
            s[n++] = Handler.sellForExit.selector;
            s[n++] = Handler.composeExit.selector;
            s[n++] = Handler.exitStatement.selector;
            s[n++] = Handler.buybackExit.selector;
            s[n++] = Handler.moduleMode.selector;
            s[n++] = Handler.sendExitFees.selector;
            s[n++] = Handler.exitPoolSwap.selector;
            s[n++] = Handler.exitPoolSwap.selector;
        }
        bytes4[] memory sel = new bytes4[](n);
        for (uint256 i; i < n; ++i) {
            sel[i] = s[i];
        }
        // the fuzzer's own random senders would each cost a slow rpc account lookup on a fork. two fixed ones
        // are cached. the handler pranks every account it needs, so the sender is never used
        targetSender(makeAddr("credeng.inv.sender0"));
        targetSender(makeAddr("credeng.inv.sender1"));
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }
}
