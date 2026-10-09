// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {Lane, ICredits, IStatements, Mainnet, Settings} from "../../src/interfaces/Interfaces.sol";
import {IAuctionHouse, IAuctionFactory} from "../../src/interfaces/AuctionHouse.sol";
import {IFeeRouter} from "../../src/interfaces/IFeeRouter.sol";
import {ICoreLens} from "../../src/interfaces/ICoreLens.sol";
import {
    IArtCoinsFactoryV2,
    IArtCoinsTokenV2,
    IArtCoinsFeeEscrowV2,
    IArtCoinsHookV2
} from "../../src/interfaces/ArtCoinsV2.sol";
import {V2Stack} from "./V2Stack.sol";
import {Deployed} from "../../script/SystemDeployer.sol";
import {ProdDeployer} from "./ProdDeployer.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";
import {MockExitToken} from "../standins/MockExitToken.sol";
import {MockExitModule} from "../standins/MockExitModule.sol";
import {CreditIds} from "./CreditIds.sol";
import {TestSwapRouter} from "./TestSwapRouter.sol";
import {RateStore} from "../../src/lib/RateStore.sol";

/// @notice the full system on a mainnet fork, built only from real contracts. the artcoins v2 stack is the live one
/// (`V2Stack`, script/config/v2-mainnet.json), the factory owner (`owner`, who is also the engine owner) sets the
/// factory minimum protocol skim share to 362 as the launch needs, then Core, ControllerV1 and the fee router are
/// deployed through `SystemDeployer.deploySystem` and the coin is launched with `deployTokenAsOwner`. the pool lives in
/// the live pool manager under the v2 hook. fees reach the Core through the fee router: `_buyCoin` and `_sellCoin`
/// flush it right after the swap (set `autoFlush` false to hold the eth in the router), `_flush` does it on demand.
/// the only stand ins are the exit module and exit token, which appear only after `_enterPhase2`.
/// the sniper window is OPEN after setUp (the pool was just born). call `_skipSniperWindow` for steady state fees.
/// @dev every address is namespaced because common labels are delegated accounts on mainnet that sweep eth
abstract contract Fixture is Test, ProdDeployer {
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    IPoolManager internal constant PM = IPoolManager(Mainnet.POOL_MANAGER);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;
    address internal constant DEAD = Mainnet.DEAD;

    /// @dev credits the CreditStrategy lists for sale at the pinned block. they are never handed out as plain credits
    uint256 internal constant LISTED_A = 35377;
    uint256 internal constant LISTED_B = 28352;
    uint256 internal constant LISTED_C = 18683;

    /// @dev exit token base units per 1e4 scaled score point reported by the stand in exit module
    uint256 internal constant UNIT = 1e10;
    /// @dev the real house is called with at least this gas by `_endAuction` (it needs 580k to honor its delivery stipend)
    uint256 internal constant END_GAS = 2_000_000;
    /// @dev the sniper window of the launch, seconds
    uint256 internal constant SNIPER_WINDOW = 1800;
    bytes32 internal constant FIXTURE_SALT = keccak256("credits-engine fixture coin");

    // ------------------------------------------------------------------ swap attribution hook data (same encoding on v2)

    struct PoolSwapData {
        bytes mevModuleSwapData;
        bytes poolExtensionSwapData;
    }

    struct PCAttribution {
        bytes32 sourceId;
        address referrer;
        bytes16 campaignId;
        uint24 referralBps;
    }

    struct PCSwapData {
        PCAttribution attribution;
        bytes extensionPayload;
    }

    // ------------------------------------------------------------------ the system

    /// @dev the launch config of the fixture: the default (live artcoins stack) with the placeholders filled
    LaunchConfig internal lc;
    ICore internal core;
    IArtCoinsTokenV2 internal coin;
    /// @dev the v2 stack the fixture deployed on the fork, and its factory and escrow
    V2Stack.Stack internal v2;
    IArtCoinsFactoryV2 internal FACTORY;
    IArtCoinsFeeEscrowV2 internal ESCROW;
    /// @dev the fee router: the pool's bounty recipient. `_flush` forwards its eth to the Core
    IFeeRouter internal feeRouter;
    /// @dev the account that calls `flush` in the helpers
    address internal flusher;
    /// @dev when true the swap helpers flush the router right after the swap, so the Core books the fees at once
    bool internal autoFlush = true;
    IControllerV1 internal ctl;
    /// @dev the read only lens `deploySystem` created for the Core
    ICoreLens internal lens;
    /// @dev the pnd auction house the core created in its constructor, through the real live factory
    IAuctionHouse internal house;
    PoolKey internal launchKey;
    bytes32 internal poolId;
    TestSwapRouter internal router;
    uint256 internal launchTime;

    address internal deployer;
    address internal owner;
    address internal creator;
    address internal keeper;
    address internal seller;
    address internal funder;

    uint256 internal creditCursor;

    // ------------------------------------------------------------------ phase 2

    MockExitToken internal xt;
    MockExitModule internal mod;
    bool internal inPhase2;

    // ------------------------------------------------------------------ compose

    /// @notice what one real compose did
    struct Composed {
        uint256 sid;
        uint256 supplyBefore;
        uint256[80] ids;
        /// @dev sum of the cost bases of the credits
        uint256 cost;
        /// @dev gas reimbursement paid to the caller
        uint256 reimb;
        uint256 potBefore;
        uint64 at;
        /// @dev gas of the whole call as the caller saw it
        uint256 gasUsed;
    }

    /// @notice basefee of the compose call. low enough that the 5 percent cap does not bind
    uint256 internal composeBasefee = 0.2 gwei;
    Composed internal composed;
    bool internal isComposed;
    /// @notice state right before the compose, valid while `isComposed`. revert to it to compose again
    uint256 internal preComposeSnap;

    /// @notice the settings the fixture core is deployed with. the default is the launch values of docs/FLOW.md. a
    /// suite that tests another set overrides this
    function _settings() internal view virtual returns (Settings memory) {
        return Mainnet.defaultSettings();
    }

    /// @dev the test contract is a caller of the doors that repay gas (compose, exitStatement), so it takes eth
    receive() external payable {}

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        // the live v2 stack. its factory owner is the owner of the engine in every test
        v2 = V2Stack.attach();
        owner = v2.owner;
        deployer = _user("deployer");
        creator = _user("creator");
        keeper = _user("keeper");
        seller = _user("seller");
        funder = _user("funder");
        flusher = _user("flusher");
        router = new TestSwapRouter();

        // the launch bounty needs the factory minimum protocol skim share at 362: the owner command of docs/DEPLOY.md step 3
        FACTORY = IArtCoinsFactoryV2(v2.factory);
        ESCROW = IArtCoinsFeeEscrowV2(v2.escrow);
        vm.startPrank(owner);
        FACTORY.setMinProtocolSkimShareBps(362);
        vm.stopPrank();
        vm.deal(owner, 1 ether);

        lc = defaultConfig();
        // the core tests are written against this opening bid, whatever the launch default is
        lc.rateStart = 4e12;
        lc.settings = _settings();
        lc.owner = owner;
        lc.creator = creator;
        lc.creatorPayee = _user("creatorPayee");
        lc.name = "Fixture Coin";
        lc.symbol = "FIXT";
        lc.salt = FIXTURE_SALT;
        lc.stack.hook = v2.hook;
        lc.stack.factory = v2.factory;
        lc.stack.locker = v2.locker;
        lc.stack.escrow = v2.escrow;
        lc.mevModule = v2.mev;
        vm.startPrank(owner);
        Deployed memory d = deploySystem(owner, lc);
        // the launch is mined in this block: the split starts when the anti sniper window ends
        startSplitAfterLaunch(lc, d.router, d.coin);
        vm.stopPrank();

        // `deploySystem` filled the router into its own copy of the config
        lc.stack.feeSource = d.router;
        core = ICore(payable(d.core));
        coin = IArtCoinsTokenV2(d.coin);
        ctl = IControllerV1(d.controller);
        lens = ICoreLens(d.lens);
        feeRouter = IFeeRouter(payable(d.router));
        house = IAuctionHouse(core.HOUSE());
        launchKey = d.launchKey;
        poolId = d.poolId;
        launchTime = block.timestamp;
    }

    // ------------------------------------------------------------------ builders on the fixture config

    function _cfg(string memory name, string memory symbol, bytes32 salt) private view returns (LaunchConfig memory l) {
        l = lc;
        l.name = name;
        l.symbol = symbol;
        l.salt = salt;
    }

    function predictCoin(address tokenAdmin, string memory name, string memory symbol, bytes32 salt)
        internal
        view
        returns (address)
    {
        LaunchConfig memory l = _cfg(name, symbol, salt);
        l.owner = tokenAdmin;
        return predictCoin(l, owner, address(feeRouter));
    }

    function buildConfig(
        address tokenAdmin,
        address creator_,
        string memory name,
        string memory symbol,
        bytes32 salt
    ) internal view returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory) {
        LaunchConfig memory l = _cfg(name, symbol, salt);
        l.creator = creator_;
        return buildConfig(l, tokenAdmin, address(feeRouter));
    }

    function poolKeyOf(address coin_) internal view returns (PoolKey memory) {
        return poolKeyOf(coin_, lc.stack);
    }

    /// @notice a namespaced account with no code
    function _user(string memory label) internal returns (address a) {
        a = makeAddr(string.concat("lifecycle.", label, ".4b1d"));
        assertEq(a.code.length, 0, "account has code on the fork");
    }

    // ------------------------------------------------------------------ swaps through the real pool

    /// @notice buys coin with `ethIn` eth, exact in, through the real pool. `who` is funded for it
    /// @return coinOut the coin `who` received
    function _buyCoin(address who, uint256 ethIn) internal returns (uint256 coinOut) {
        vm.deal(who, who.balance + ethIn);
        uint256 before = coin.balanceOf(who);
        vm.prank(who);
        router.swap{value: ethIn}(launchKey, true, -int256(ethIn), who);
        coinOut = coin.balanceOf(who) - before;
        if (autoFlush) _flush();
    }

    /// @notice sells `coinIn` coin for eth, exact in, through the real pool
    /// @return ethOut the eth `who` received after the skim
    function _sellCoin(address who, uint256 coinIn) internal returns (uint256 ethOut) {
        vm.prank(who);
        coin.approve(address(router), type(uint256).max);
        uint256 before = who.balance;
        vm.prank(who);
        router.swap(launchKey, false, -int256(coinIn), who);
        ethOut = who.balance - before;
        if (autoFlush) _flush();
    }

    /// @notice flushes the fee router as `flusher`. the Core books what the router sends.
    /// returns the eth the Core received from the router (zero when the router held nothing)
    function _flush() internal returns (uint256 toCore) {
        uint256 before = address(core).balance;
        vm.prank(flusher);
        feeRouter.flush();
        toCore = address(core).balance - before;
    }

    /// @notice sends `amount` eth to the Core from the fee source (the router address), the way a flush does. the Core
    /// books it as fees. for tests that need an exact amount booked
    function _feePays(uint256 amount) internal {
        address src = core.FEE_SOURCE();
        vm.deal(src, src.balance + amount);
        vm.prank(src);
        (bool ok,) = address(core).call{value: amount}("");
        require(ok, "fee push failed");
    }

    /// @notice swap hook data that names `referrer` and asks for `bps` of volume (100k denominator)
    function _referralData(address referrer, uint24 bps) internal pure returns (bytes memory) {
        PCSwapData memory inner = PCSwapData(PCAttribution(bytes32(0), referrer, bytes16(0), bps), "");
        return abi.encode(PoolSwapData("", abi.encode(inner)));
    }

    /// @notice moves past the anti sniper window, so skim is the 10 points baseline
    function _skipSniperWindow() internal {
        uint256 end = launchTime + SNIPER_WINDOW + 1;
        if (block.timestamp < end) vm.warp(end);
    }

    /// @notice moves past the sniper window and the router split start (the window end plus the deploy margin). the first
    /// flush at or after the start turns the split on
    function _skipToSplitStart() internal {
        _skipSniperWindow();
        uint256 at = feeRouter.splitStart();
        if (block.timestamp < at) vm.warp(at);
    }

    /// @notice generates fees through real buys until the eth pot holds at least `eth`. in steady state about 5.90 percent
    /// of every buy reaches the pot (6.9 points of skim, 96.38 percent to the router, minus the payee), inside
    /// the sniper window more
    function _fundPot(uint256 eth) internal {
        for (uint256 i; i < 8 && core.ethPot() < eth; ++i) {
            uint256 need = eth - core.ethPot();
            _buyCoin(funder, need * 10_000 / 510 + 1000);
        }
        assertGe(core.ethPot(), eth, "pot not funded");
    }

    /// @notice like `_fundPot` but never buys more than the gap needs (the guess is the first flush rate, the highest one),
    /// so the pot lands just over `eth`. for tests that need a pot close to an exact figure
    function _fundPotNear(uint256 eth) internal {
        for (uint256 i; i < 12 && core.ethPot() < eth; ++i) {
            _buyCoin(funder, (eth - core.ethPot()) * 10_000 / 665 + 1e12);
        }
        assertGe(core.ethPot(), eth, "pot not funded");
    }

    // ------------------------------------------------------------------ credits

    /// @notice moves `n` real credits from the CreditStrategy to `to` and approves the core for them
    /// @return ids the credit ids
    function _credits(address to, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        uint256 got;
        while (got < n) {
            uint256 id = CreditIds.at(creditCursor++);
            if (id == LISTED_A || id == LISTED_B || id == LISTED_C) continue;
            vm.prank(STRATEGY);
            CREDITS.transferFrom(STRATEGY, to, id);
            ids[got++] = id;
        }
        vm.prank(to);
        CREDITS.setApprovalForAll(address(core), true);
    }

    /// @notice warps an hour at a time until the ceiling of credit `id` reaches `price`. the real listings cost more
    /// than the launch `rateCap` allows the bid to reach, so the owner lifts the cap to its bound first
    function _warpUntilCeiling(uint256 id, uint256 price) internal {
        _liftRateCap();
        for (uint256 i; i < 400; ++i) {
            if (core.ceilingOf(id) >= price) return;
            vm.warp(block.timestamp + 1 hours);
        }
        revert("ceiling never cleared");
    }

    /// @notice the smallest pot at which the clamp of the eth rate is not below the stored rate:
    /// `rate * avgScore / spendCapBps`
    function _unclampedPot() internal view returns (uint256) {
        Settings memory s = core.settings();
        return core.rateAtCheckpoint() * s.avgScore / s.spendCapBps;
    }

    /// @notice sells `n` fresh credits into the eth bid, which puts them in the eth pile in the order returned.
    /// funds the pot first when it cannot carry the sale, and moves past the hourly cap window if it must
    function _fillEthPile(uint256 n) internal returns (uint256[] memory ids) {
        ids = _credits(seller, n);
        // a price state that idle time loosened above the opening rate is restated to the opening rate
        uint256 opening = core.RATE_START();
        if (core.rateAtCheckpoint() > opening) {
            vm.prank(owner);
            core.setRate(opening);
        }
        uint256 room = _unclampedPot();
        if (core.ethPot() < room) _fundPot(room);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            total += core.ceilingOf(ids[i]);
        }
        if (core.ethPot() < total * 6) _fundPot(total * 6);
        vm.prank(seller);
        try core.sellForEth(ids) {}
        catch {
            vm.warp(block.timestamp + 1 hours + 1);
            vm.prank(seller);
            core.sellForEth(ids);
        }
    }

    /// @notice composes the eth pile through the real controller, once per state lineage. fills the pile to 80
    /// first. the call checks that the core hands Statements the 80 oldest credits with format 0. the state before the
    /// compose is kept in `preComposeSnap`, so a test can revert to it and compose again under other conditions
    function _composeOnce() internal returns (Composed memory c) {
        if (isComposed) return composed;
        uint256 size = core.pileSize(Lane.Eth);
        if (size < 80) _fillEthPile(80 - size);

        uint256[] memory page = core.pilePage(Lane.Eth, 0, 80);
        for (uint256 i; i < 80; ++i) {
            c.ids[i] = page[i];
            (,, uint256 cost,) = core.creditInfo(page[i]);
            c.cost += cost;
        }
        c.potBefore = core.ethPot();
        c.supplyBefore = STATEMENTS.supply();
        vm.fee(composeBasefee);
        preComposeSnap = vm.snapshotState();

        vm.expectCall(address(STATEMENTS), abi.encodeWithSelector(IStatements.compose.selector, c.ids, uint8(0)));
        uint256 keeperBefore = keeper.balance;
        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        core.compose();
        c.gasUsed = gasBefore - gasleft();
        c.reimb = keeper.balance - keeperBefore;
        c.sid = c.supplyBefore + 1;
        c.at = uint64(block.timestamp);

        composed = c;
        isComposed = true;
    }

    // ------------------------------------------------------------------ statement auctions on the real house

    /// @notice the live status of a statement as the core reads it from the house
    struct Live {
        ICore.StatementStatus status;
        uint256 auctionId;
        uint256 reserve;
        uint256 bid;
        uint64 endTime;
    }

    /// @notice the live status of a statement (see `Core.statementStatus`)
    function _live(uint256 sid) internal view returns (Live memory l) {
        (l.status, l.auctionId, l.reserve, l.bid, l.endTime) = core.statementStatus(sid);
    }

    /// @notice the raw auction record of a statement on the house, empty when there is none
    function _auctionOf(uint256 sid) internal view returns (IAuctionHouse.Auction memory) {
        return house.getAuction(_live(sid).auctionId);
    }

    /// @notice `who` bids `amount` eth on the auction of statement `sid`, directly on the house. `who` is funded for it
    function _bid(address who, uint256 sid, uint256 amount) internal {
        uint256 id = _live(sid).auctionId;
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        house.createBid{value: amount}(id);
    }

    /// @notice warps to the end of the auction of statement `sid` and settles it as a stranger on the house. the
    /// statement goes to the winner, the proceeds are credited to the core on the house until `collectSales`
    function _endAuction(uint256 sid) internal {
        Live memory l = _live(sid);
        vm.warp(l.endTime);
        vm.prank(address(0xE4D));
        house.endAuction{gas: END_GAS}(l.auctionId);
    }

    /// @notice the eth the house owes the core: sale proceeds not yet collected
    function _owedByHouse() internal view returns (uint256) {
        return house.pendingRefunds(address(core));
    }

    /// @notice a stranger collects the sale proceeds. returns the eth the house owed
    function _collectSales() internal returns (uint256 owed) {
        owed = _owedByHouse();
        vm.prank(address(0xC011));
        core.collectSales();
    }

    /// @notice the reserve a statement of `cost` gets when it is listed: the controller's start price, never below the
    /// hard floor (the fixture controller is built from `lc.sale`)
    function _reserveFor(uint256 cost) internal view returns (uint256) {
        uint256 floor = cost * core.settings().saleFloorBps / 10_000;
        uint256 ask = cost * lc.sale.startBps / 10_000;
        return ask > floor ? ask : floor;
    }

    /// @notice the owner lifts `rateCap` to its upper bound, for suites that climb past the launch cap
    function _liftRateCap() internal {
        Settings memory s = core.settings();
        if (s.rateCap < 1e15) {
            s.rateCap = 1e15;
            _setSettings(s);
        }
    }

    /// @notice the bid anchor state of the Core, read from its storage: the rate of the last fill, the rate of the first fill
    /// in the current minute bucket and that bucket
    function _anchor() internal view returns (uint256 lastFillRate, uint256 minuteStartRate, uint256 minuteBucket) {
        bytes32 slot = RateStore.SLOT;
        lastFillRate = uint256(vm.load(address(core), slot));
        minuteStartRate = uint256(vm.load(address(core), bytes32(uint256(slot) + 1)));
        minuteBucket = uint64(uint256(vm.load(address(core), bytes32(uint256(slot) + 2))));
    }

    /// @notice the owner changes the settings
    function _setSettings(Settings memory s) internal {
        vm.prank(owner);
        core.setSettings(s);
    }

    /// @notice composes, bids the reserve with `bidder`, ends the auction and returns the statement id. the winner now
    /// holds the statement, the proceeds sit in the house
    function _sellStatement(address bidder) internal returns (uint256 sid, uint256 price) {
        sid = _composeOnce().sid;
        price = _live(sid).reserve;
        _bid(bidder, sid, price);
        _endAuction(sid);
    }

    // ------------------------------------------------------------------ owner actions

    /// @notice the owner sets the controller at once
    function _setController(address c) internal {
        vm.prank(owner);
        core.setController(c);
    }

    /// @notice the owner sets the exit module at once
    function _setExitModule(address m) internal {
        vm.prank(owner);
        core.setExitModule(m);
    }

    /// @notice adds a target to the core allowlist
    function _allow(address target) internal {
        vm.prank(owner);
        core.addTarget(target);
    }

    // ------------------------------------------------------------------ phase 2

    /// @notice sets the stand in exit module and exit token at once. there is no exit pool: the coin
    /// buyback of the exit token is a dutch auction inside the core
    function _enterPhase2() internal {
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), UNIT);
        _setExitModule(address(mod));
        inPhase2 = true;
    }

    /// @notice composes the eth pile, lets its auction run out and exits the statement, which puts half of the
    /// exit token into `xToBuyback`. needs phase 2. returns the exit token the core received
    function _fillExitBuyback() internal returns (uint256 received) {
        Composed memory c = _composeOnce();
        vm.warp(block.timestamp + core.settings().exitAfter);
        uint256 before = xt.balanceOf(address(core));
        core.exitStatement(c.sid);
        received = xt.balanceOf(address(core)) - before;
    }

    // ------------------------------------------------------------------ checks and small helpers

    /// @notice invariant 5 of the spec: the pots never exceed what the core holds
    function _solvent() internal view {
        assertLe(core.ethPot() + core.ethToBuyback(), address(core).balance, "eth pots exceed balance");
        address t = core.exitToken();
        if (t != address(0)) {
            assertLe(core.xPot() + core.xToBuyback(), MockExitToken(t).balanceOf(address(core)), "exit pots exceed");
        }
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _sumScores(uint256[] memory ids) internal view returns (uint256 t) {
        for (uint256 i; i < ids.length; ++i) {
            t += core.scoreOf(ids[i]);
        }
    }

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }
}
