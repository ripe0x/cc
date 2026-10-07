// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Core} from "../../src/Core.sol";
import {Lane, ICreditScore, ICreditStrategy, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../../src/interfaces/AuctionHouse.sol";
import {Fixture} from "../utils/Fixture.sol";
import {CreditIds} from "../utils/CreditIds.sol";
import {MockExitModule} from "../standins/MockExitModule.sol";
import {MockExitToken} from "../standins/MockExitToken.sol";
import {ProbeTarget} from "../attackers/ProbeTarget.sol";
import {FuzzController} from "../attackers/FuzzController.sol";
import {TestLiquidityHelper} from "../utils/TestLiquidityHelper.sol";
import {Handler} from "./Handler.sol";
import {Wiring, HandlerBase} from "./HandlerBase.sol";
import {HandlerHouse} from "./HandlerHouse.sol";
import {HandlerOwner} from "./HandlerOwner.sol";
import {HandlerSale} from "./HandlerSale.sol";

/// @notice builds the real system on the fork for the invariant suites on top of the single real stack `Fixture`:
/// the real Core and ControllerV1 deployed through the deploy path, the coin launched through the live artcoins
/// factory, the live skim hook, locker, mev module and pool manager, and the live Credits, CreditScore, Statements
/// and CreditStrategy. the only stand ins are the exit module and exit token of phase 2. the attack contracts are
/// the fuzz controller and the hostile listing target. the owner adds the hostile target, the fuzz controller and,
/// in phase 2, the exit module at once. the eth pot is funded by real swap fees, the piles are
/// pre filled with real credits so that composes happen, and the clock is moved so that the rate has climbed far
/// enough for the real CreditStrategy listings to fit under the ceiling.
///
/// every statement of the prefill is listed on the real pnd auction house the core owns, and two of them are sold
/// before the run (outside the sniper window variant, where an auction cannot finish in time): one collected and
/// one not, neither synced, so the run starts with a stale record and with proceeds owed by the house.
///
/// two start states: after the sniper window (a week passes before the owner setup) and inside it (the run starts a
/// few seconds after launch, the skim is 90 percent).
abstract contract InvariantFixture is Fixture {
    /// eth the whale spends on coin. in steady state 9.5 percent of it becomes pot
    uint256 internal constant FUND_ETH = 40 ether;
    /// credits that stay in the eth pile after the pre filled composes, so two more fill it to 80
    uint256 internal constant LEFT_IN_PILE = 78;
    /// statements composed and listed before the run
    uint256 internal constant COMPOSES = 4;
    /// real listings are read from this index of the strategy list, after the credits that move
    uint256 internal constant CANDIDATE_START = 600;

    /// @dev the credit budget (the first 600 of the 640 ids) is kept in the phase 2 suites, which also sell 80 credits
    /// into the exit lane, by giving the four actors 25 credits each
    uint256 internal constant ACTOR_CREDITS = 25;

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
        _ownerSetup(phase2, hostile, inWindow);
        _fundWhale();
        _sidePool();

        Wiring memory w = Wiring({
            core: core,
            house: house,
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
        // built from its artifact: the handler is large and no test contract may embed its creation code
        handler = Handler(deployCode("Handler.sol:Handler", abi.encode(w)));
        _saleParts();
        _actors();
        _prefill(phase2, inWindow);
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

    /// the controller that sells for the owner and the heirs of the handover chain, handed to the handler. the selling
    /// controller is built from its artifact. the owner installs it only when the handler's hostile owner does
    function _saleParts() internal {
        address selling = deployCode("SaleAttackers.sol:SellingController", abi.encode(address(core)));
        address[] memory heirs = new address[](4);
        for (uint256 i; i < 4; ++i) {
            heirs[i] = _user(string.concat("inv.heir", vm.toString(i)));
        }
        handler.setSaleParts(selling, heirs);
    }

    /// the suites that list the sale and owner actions of `HandlerSale` override this
    function _saleActions() internal pure virtual returns (bool) {
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                                  STEPS
    //////////////////////////////////////////////////////////////*/

    /// the owner allows the hostile target, and in the suites that need it sets the fuzz controller and the exit module.
    /// everything is at once. outside the sniper window variant a week passes first, so the run starts past the
    /// window; inside it the run starts a few seconds after launch
    function _ownerSetup(bool phase2, bool hostile, bool inWindow) internal {
        if (!inWindow) vm.warp(block.timestamp + 7 days + 1);
        vm.startPrank(owner);
        core.addTarget(address(probeTarget));
        if (hostile) core.setController(address(fuzz));
        if (phase2) core.setExitModule(address(mod));
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
            handler.giveCredits(a, _credits(a, ACTOR_CREDITS));
        }
    }

    /// the statements the prefill sold on the house before the run, with the price. the first was collected, the second
    /// was not, and neither was synced
    uint256 internal sold1;
    uint256 internal sold2;
    uint256 internal price1;
    uint256 internal price2;

    /// real credits sold into the piles, four composes so statements exist for the auction, the exit and the overprint,
    /// all listed on the house. outside the sniper window two of them are sold: the whale bids the reserve, the
    /// auction runs out and is settled by a stranger, the first is collected so the buyback pot is not empty when the
    /// run starts, the second is left owed by the house. in phase 2 the exit token bid is funded and 80 more credits are
    /// sold into it, so the exit lane has a full page
    function _prefill(bool phase2, bool inWindow) internal {
        uint256 ethN = COMPOSES * 80 + LEFT_IN_PILE;
        uint256[] memory ids = _credits(filler, ethN + (phase2 ? 80 : 0));
        vm.fee(1 gwei);
        uint256[] memory ethIds = new uint256[](ethN);
        for (uint256 i; i < ethN; ++i) {
            ethIds[i] = ids[i];
        }
        vm.prank(filler);
        core.sellForEth(ethIds);
        uint256 firstStatement = STATEMENTS.supply() + 1;
        for (uint256 i; i < COMPOSES; ++i) {
            vm.prank(keeper);
            core.compose();
        }
        assertEq(core.pileSize(Lane.Eth), LEFT_IN_PILE);
        if (!inWindow) {
            (sold1, price1) = _saleOf(firstStatement);
            assertGt(_collectSales(), 0);
            assertGt(core.ethToBuyback(), 0);
            (sold2, price2) = _saleOf(firstStatement + 1);
            assertGt(_owedByHouse(), 0, "the second sale is left uncollected");
        }
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

    /// the whale bids the reserve on `sid`, the auction runs out and a stranger settles it
    function _saleOf(uint256 sid) internal returns (uint256, uint256) {
        uint256 price = _live(sid).reserve;
        _bid(whale, sid, price);
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), whale);
        return (sid, price);
    }

    /// credits held by the hostile target
    function _holders() internal {
        handler.setProbeIds(_credits(address(probeTarget), 16));
        vm.deal(address(probeTarget), 100 ether);
    }

    /// the cheapest real listings, so the ceiling reaches them first. the bid is flat per credit by default, so the
    /// price alone decides, whatever the score
    function _candidates() internal {
        uint256 n = 40;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory key = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 id = CreditIds.at(CANDIDATE_START + i);
            ids[i] = id;
            uint256 price = ICreditStrategy(Mainnet.CREDIT_STRATEGY).nftForSale(id);
            uint256 score = ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
            // the price, larger is worse. unlisted ids sort last. the score is read to keep the candidate real
            key[i] = price == 0 || score == 0 ? type(uint256).max : price;
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
            if (held[i] == sold1 && sold1 != 0) handler.seedGhostStatement(held[i], whale, price1, true);
            else if (held[i] == sold2 && sold2 != 0) handler.seedGhostStatement(held[i], whale, price2, false);
            else handler.seedGhostStatement(held[i], address(0), 0, false);
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
    // byte 17 of slot 11, windowPot is slot 12 and windowSpent is slot 13
    function _windowStart() internal view returns (uint256) {
        return (uint256(vm.load(address(core), bytes32(uint256(11)))) >> 136) & type(uint64).max;
    }

    function _windowPot() internal view returns (uint256) {
        return uint256(vm.load(address(core), bytes32(uint256(12))));
    }

    function _windowSpent() internal view returns (uint256) {
        return uint256(vm.load(address(core), bytes32(uint256(13))));
    }

    /// how many times each owner action appears in the fuzzer's list. the hostile owner suite raises it
    function _ownerWeight() internal pure virtual returns (uint256) {
        return 1;
    }

    /// the actions the fuzzer may call. the setters of the handler are left out. an action listed twice is called
    /// twice as often
    function _targets(bool phase2) internal virtual {
        bytes4[] memory s = new bytes4[](200);
        uint256 n;
        s[n++] = HandlerBase.buyCoin.selector;
        s[n++] = HandlerBase.buyCoin.selector;
        s[n++] = HandlerBase.sellCoin.selector;
        s[n++] = HandlerBase.sideBuy.selector;
        s[n++] = HandlerBase.sellForEth.selector;
        s[n++] = HandlerBase.sellForEth.selector;
        s[n++] = HandlerBase.listingStrategy.selector;
        s[n++] = HandlerBase.listingHostile.selector;
        s[n++] = HandlerBase.warp.selector;
        s[n++] = HandlerBase.warp.selector;
        s[n++] = HandlerBase.roll.selector;
        s[n++] = HandlerBase.compose.selector;
        s[n++] = HandlerHouse.bid.selector;
        s[n++] = HandlerHouse.bid.selector;
        s[n++] = HandlerHouse.endAuction.selector;
        s[n++] = HandlerHouse.collectSales.selector;
        s[n++] = HandlerHouse.syncStatement.selector;
        s[n++] = HandlerHouse.repriceStatement.selector;
        s[n++] = HandlerBase.buyback.selector;
        s[n++] = HandlerBase.skim.selector;
        s[n++] = HandlerBase.donate.selector;
        s[n++] = HandlerBase.controllerSeed.selector;
        s[n++] = HandlerBase.controllerSwap.selector;
        s[n++] = HandlerBase.overprint.selector;
        s[n++] = HandlerBase.probeController.selector;
        // the exit module is set in the phase 2 suites before the run starts, so the exit actions are listed only there
        if (phase2) {
            s[n++] = HandlerBase.sellForExit.selector;
            s[n++] = HandlerBase.composeExit.selector;
            s[n++] = HandlerBase.exitStatement.selector;
            s[n++] = HandlerBase.buybackExit.selector;
            s[n++] = HandlerBase.buybackExit.selector;
            s[n++] = HandlerBase.moduleMode.selector;
        }
        if (_saleActions()) {
            s[n++] = HandlerSale.buyOnlyBuy.selector;
            s[n++] = HandlerSale.buyOnlyBuy.selector;
            s[n++] = HandlerSale.ownerSell.selector;
            s[n++] = HandlerSale.repriceBid.selector;
            s[n++] = HandlerSale.repriceBid.selector;
            s[n++] = HandlerSale.saleSettings.selector;
            s[n++] = HandlerSale.flipMode.selector;
            s[n++] = HandlerSale.flipMode.selector;
            s[n++] = HandlerSale.hostileOwner.selector;
            s[n++] = HandlerSale.lockDoor.selector;
            s[n++] = HandlerSale.handover.selector;
        }
        // the owner as an adversary: settings anywhere in the bounds, rates, invalid calls, the other owner doors
        for (uint256 k; k < _ownerWeight(); ++k) {
            s[n++] = HandlerOwner.setSettings.selector;
            s[n++] = HandlerOwner.setSettingsInvalid.selector;
            s[n++] = HandlerOwner.setRate.selector;
            s[n++] = HandlerOwner.setXRate.selector;
            s[n++] = HandlerOwner.ownerMisc.selector;
            if (phase2) s[n++] = HandlerOwner.replaceModule.selector;
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
