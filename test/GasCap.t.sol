// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane, ICreditStrategy, IStatements, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../src/interfaces/AuctionHouse.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {MockExitToken} from "./standins/MockExitToken.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";
import {SeaportBase} from "./Seaport.t.sol";
import {OrderComponents} from "./utils/SeaportTypes.sol";

/// @notice every transaction this system needs, against the per transaction gas cap of mainnet (EIP-7825, since the
/// fusaka upgrade): 16,777,216 gas. one test per transaction, real contracts on the pinned fork, from an EOA style
/// prank. each number is a `gasleft()` delta around the one top level external call, with the touched accounts and
/// slots cooled first, so the first access of every slot is charged the cold price like in a fresh transaction.
/// ESTIMATE: the transaction gas is that delta plus 21,000 intrinsic plus the calldata cost (4 per zero byte, 16 per
/// other byte, or the EIP-7623 floor of 10 per token when that is larger). it ignores the access list, the gas refund
/// (the cap counts gas before refunds) and a few hundred gas of call overhead inside the delta. `exitModule` and
/// `exitToken` are test stand ins: what a real `exitModule` costs inside `exit` is not measured here
contract GasCapTest is SeaportBase {
    uint256 internal constant CAP = 16_777_216;
    /// @dev above this share of the cap a row is flagged
    uint256 internal constant FLAG_PCT = 60;
    uint256 internal constant PAGE_GAS = 500_000;
    uint256 internal constant READ_GAS = 200_000;

    address internal bidder;
    address internal bidder2;
    address internal taker;
    address internal stranger;

    function setUp() public override {
        super.setUp();
        bidder = _user("gas bidder");
        bidder2 = _user("gas bidder two");
        taker = _user("gas taker");
        stranger = _user("gas stranger");
        vm.fee(composeBasefee);
    }

    // ------------------------------------------------------------------ measuring helpers

    function _calldataGas(bytes memory data) internal pure returns (uint256 std, uint256 floor_) {
        uint256 z;
        uint256 nz;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == 0) ++z;
            else ++nz;
        }
        std = 4 * z + 16 * nz;
        floor_ = 10 * (z + 4 * nz);
    }

    function _pct(uint256 g) internal pure returns (string memory) {
        uint256 p = g * 1000 / CAP;
        return string.concat(vm.toString(p / 10), ".", vm.toString(p % 10));
    }

    function _txGas(uint256 exec, bytes memory data, uint256 extra) internal pure returns (uint256 total) {
        (uint256 std, uint256 floor_) = _calldataGas(data);
        total = 21_000 + exec + extra + std;
        if (21_000 + floor_ > total) total = 21_000 + floor_;
    }

    /// @dev logs one table row for an estimated transaction gas and asserts it is below the cap
    function _log(string memory name, uint256 exec, uint256 total) internal {
        string memory flag = total * 100 > CAP * FLAG_PCT ? " | FLAG above 60 percent" : "";
        if (total >= CAP) flag = " | LAUNCH BLOCKER above the cap";
        string memory head = string.concat("GAS | ", name, " | exec ", vm.toString(exec));
        console.log(string.concat(head, " | tx ", vm.toString(total), " | pct ", _pct(total), flag));
        assertLt(total, CAP, name);
    }

    /// @dev `extra` is execution gas the delta cannot see (the proxy of a create2 deploy). returns the estimate
    function _row(string memory name, uint256 exec, bytes memory data, uint256 extra) internal returns (uint256 total) {
        total = _txGas(exec, data, extra);
        _log(name, exec, total);
    }

    function _row(string memory name, uint256 exec, bytes memory data) internal returns (uint256) {
        return _row(name, exec, data, 0);
    }

    /// @dev marks every account the system touches as cold, with its slots, then warms only the account of `target`
    /// (a transaction starts with its target warm). the sender is not cooled
    function _cool(address target) internal {
        address[18] memory a = [
            address(core),
            address(ctl),
            address(house),
            address(STATEMENTS),
            address(CREDITS),
            Mainnet.CREDIT_SCORE,
            STRATEGY,
            Mainnet.SEAPORT,
            address(PM),
            v2.hook,
            address(coin),
            v2.locker,
            v2.escrow,
            v2.factory,
            v2.mev,
            address(feeRouter),
            address(mod),
            address(xt)
        ];
        for (uint256 i; i < a.length; ++i) {
            if (a[i] != address(0)) vm.cool(a[i]);
        }
        if (target.code.length == 0) revert("target has no code");
    }

    // ------------------------------------------------------------------ the deploy transactions of script/SystemDeployer.sol

    /// @dev tx 1, the linked library through the create2 deployer: 32 byte salt plus the creation code, plus the proxy
    function test_gas_deploy_1_library() public {
        bytes memory code = vm.getCode("CoreLib.sol:CoreLib");
        uint256 g = gasleft();
        deployCode("CoreLib.sol:CoreLib");
        g -= gasleft();
        _row("deploy 1 library CoreLib (create2 deployer)", g, bytes.concat(bytes32(0), code), 512);
    }

    function test_gas_deploy_2_controller() public {
        bytes memory args = abi.encode(address(core), lc.sale);
        bytes memory code = bytes.concat(vm.getCode("ControllerV1.sol:ControllerV1"), args);
        _cool(address(this));
        uint256 g = gasleft();
        deployCode("ControllerV1.sol:ControllerV1", args);
        g -= gasleft();
        _row("deploy 2 controller", g, code);
    }

    /// @dev tx 3, a second Core: the constructor creates its auction house through the real factory
    function test_gas_deploy_3_core() public {
        bytes memory args = abi.encode(owner, address(coin), address(ctl), lc.stack, lc.rateStart, lc.settings);
        bytes memory code = bytes.concat(vm.getCode("Core.sol:Core"), args);
        _cool(address(this));
        uint256 g = gasleft();
        address c2 = deployCode("Core.sol:Core", args);
        g -= gasleft();
        assertTrue(address(ICore(payable(c2)).HOUSE()) != address(house), "a new house");
        console.log("core initcode bytes", code.length, "runtime bytes", c2.code.length);
        _row("deploy 3 core (house creation inside)", g, code);
    }

    /// @dev tx 4 and 5 on a fresh launch (new salt), as the owner: `deployTokenAsOwner`, then the router setup (a second
    /// router, so the set up transactions are the first ones)
    function test_gas_deploy_4_5_launchAndRouterSetup() public {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg =
            buildConfig(owner, address(core), creator, "Gas Coin", "GASC", keccak256("gas cap coin"));
        uint256 fee = FACTORY.deployFee();
        bytes memory data = abi.encodeCall(IArtCoinsFactoryV2.deployTokenAsOwner, (cfg, lc.protocolBps));
        vm.deal(owner, 1 ether);
        _cool(address(FACTORY));
        vm.prank(owner);
        uint256 g = gasleft();
        FACTORY.deployTokenAsOwner{value: fee}(cfg, lc.protocolBps);
        g -= gasleft();
        _row("deploy 4 launch through the factory (deployTokenAsOwner)", g, data);

        // the router set up: engine, payees, tip, split start (four owner transactions)
        IFeeRouter r2 = IFeeRouter(payable(deployCode("FeeRouter.sol:FeeRouter", abi.encode(owner))));
        address[] memory who = new address[](1);
        who[0] = lc.creatorPayee;
        uint32[] memory ppm = new uint32[](1);
        ppm[0] = lc.payeePpm;
        data = abi.encodeCall(IFeeRouter.setEngine, (address(core)));
        _cool(address(r2));
        vm.prank(owner);
        g = gasleft();
        r2.setEngine(address(core));
        g -= gasleft();
        _row("deploy 5a router setEngine", g, data);
        data = abi.encodeCall(IFeeRouter.setPayees, (who, ppm));
        _cool(address(r2));
        vm.prank(owner);
        g = gasleft();
        r2.setPayees(who, ppm);
        g -= gasleft();
        _row("deploy 5b router setPayees", g, data);
        data = abi.encodeCall(IFeeRouter.lock, ());
        _cool(address(r2));
        vm.prank(owner);
        g = gasleft();
        r2.lock();
        g -= gasleft();
        _row("deploy 5c router lock", g, data);
    }

    /// @dev `flush` with the split on and two payees, cold, the call that moves the pool fees into the Core
    function test_gas_routerFlush() public {
        _skipToSplitStart();
        _buyCoin(funder, 20 ether);
        autoFlush = false;
        _buyCoin(funder, 5 ether);
        _flush();
        _buyCoin(funder, 5 ether);
        assertTrue(feeRouter.splitOn(), "the split is on");
        // launch has one payee. measure the heavier case of two, set by the owner
        address[] memory who = new address[](2);
        who[0] = lc.creatorPayee;
        who[1] = makeAddr("secondPayee");
        uint32[] memory ppm = new uint32[](2);
        ppm[0] = 80_515;
        ppm[1] = 80_515;
        vm.prank(owner);
        feeRouter.setPayees(who, ppm);
        bytes memory data = abi.encodeCall(IFeeRouter.flush, ());
        _cool(address(feeRouter));
        vm.prank(flusher);
        uint256 g = gasleft();
        feeRouter.flush();
        g -= gasleft();
        _row("flush with the split on (tip, two payees, the Core books the fees)", g, data);
    }

    /// @dev the first flush at or after the split start: sends everything to the engine and turns the split on
    function test_gas_routerFlush_firstAtSplitStart() public {
        _skipToSplitStart();
        autoFlush = false;
        _buyCoin(funder, 5 ether);
        assertFalse(feeRouter.splitOn());
        bytes memory data = abi.encodeCall(IFeeRouter.flush, ());
        _cool(address(feeRouter));
        vm.prank(flusher);
        uint256 g = gasleft();
        feeRouter.flush();
        g -= gasleft();
        assertTrue(feeRouter.splitOn());
        _row("flush that turns the split on (tip, engine only)", g, data);
    }

    /// @dev the keeper calls the v2 escrow adds: claim the Core's credit (anyone), `skim()` books it, a payee claim on the
    /// router, `rescueCoin` and `setTip`
    function test_gas_escrowClaim_skim_rescue_routerClaim() public {
        _skipToSplitStart();
        _buyCoin(funder, 5 ether);
        vm.deal(v2.hook, 1 ether);
        vm.prank(v2.hook);
        (bool ok,) = v2.escrow.call{value: 0.3 ether}(abi.encodeWithSignature("storeFeesNative(address)", address(core)));
        assertTrue(ok);
        bytes memory data = abi.encodeCall(ESCROW.claim, (address(core), address(0)));
        _cool(v2.escrow);
        vm.prank(stranger);
        uint256 g = gasleft();
        ESCROW.claim(address(core), address(0));
        g -= gasleft();
        _row("escrow claim of the Core credit (pays the Core, not booked)", g, data);

        data = abi.encodeCall(core.skim, ());
        _cool(address(core));
        vm.prank(stranger);
        g = gasleft();
        core.skim();
        g -= gasleft();
        _row("skim books the claimed eth", g, data);

        vm.prank(funder);
        coin.transfer(address(core), 1_000e18);
        data = abi.encodeCall(core.rescueCoin, (creator, 1_000e18));
        _cool(address(core));
        vm.prank(owner);
        g = gasleft();
        core.rescueCoin(creator, 1_000e18);
        g -= gasleft();
        _row("rescueCoin", g, data);

        data = abi.encodeCall(IFeeRouter.setTip, (4_000, 0.004 ether));
        _cool(address(feeRouter));
        vm.prank(owner);
        g = gasleft();
        feeRouter.setTip(4_000, 0.004 ether);
        g -= gasleft();
        _row("router setTip", g, data);
    }

    // ------------------------------------------------------------------ compose, exit, overprint

    function _measureCompose(string memory name) internal returns (uint256 g) {
        uint256 held = core.heldStatements().length;
        uint256 kb = keeper.balance;
        vm.prank(keeper);
        g = gasleft();
        core.compose();
        g -= gasleft();
        assertEq(core.heldStatements().length, held + 1, "composed");
        assertGt(keeper.balance, kb, "reimbursement paid");
        _row(name, g, abi.encodeCall(core.compose, ()));
    }

    /// @dev full page of 80, listing on the house and the reimbursement included, nothing warmed by earlier work
    function test_gas_compose_ethLane_firstCold() public {
        _fillEthPile(80);
        _cool(address(core));
        _measureCompose("compose eth lane, 80 credits, first compose, cold");
    }

    function test_gas_compose_ethLane_secondWarmAndCold() public {
        _composeOnce();
        _fillEthPile(80);
        uint256 snap = vm.snapshotState();
        _measureCompose("compose eth lane, 80 credits, second compose, warm (no cooling)");
        vm.revertToState(snap);
        _cool(address(core));
        _measureCompose("compose eth lane, 80 credits, second compose, cold");
    }

    /// @dev phase 2 with the exit pot funded and 80 credits sold into the exit bid, so the exit pile is full
    function _exitPile() internal {
        _enterPhase2();
        _fillExitBuyback();
        xt.mint(address(core), 100e18);
        core.skim();
        uint256[] memory ids = _credits(seller, 80);
        vm.prank(seller);
        core.sellForExitToken(ids);
        assertEq(core.pileSize(Lane.Exit), 80);
    }

    function test_gas_composeExit_andExitStatement_exitLane() public {
        _exitPile();
        _cool(address(core));
        vm.prank(keeper);
        uint256 g = gasleft();
        core.composeExit();
        g -= gasleft();
        _row("composeExit, 80 credits, cold", g, abi.encodeCall(core.composeExit, ()));
        uint256 sid = STATEMENTS.supply();
        _cool(address(core));
        vm.prank(keeper);
        g = gasleft();
        core.exitStatement(sid);
        g -= gasleft();
        _row("exitStatement, exit lane (stand in exitModule), cold", g, abi.encodeCall(core.exitStatement, (sid)));
    }

    function test_gas_exitStatement_ethLane() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _warp(core.settings().exitAfter);
        _cool(address(core));
        vm.prank(keeper);
        uint256 g = gasleft();
        core.exitStatement(sid);
        g -= gasleft();
        _row(
            "exitStatement, eth lane (cancels the listing, stand in exitModule), cold",
            g,
            abi.encodeCall(core.exitStatement, (sid))
        );
    }

    function _composeMore() internal returns (uint256 sid) {
        _fillEthPile(80);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
    }

    /// @dev ControllerV1.nextOverprint never answers ready, so the shipped controller cannot trigger an overprint. the
    /// scripted controller of the tests does. the base grows by 80 credits per merge: the cost is measured as it grows
    function test_gas_overprint_scriptedController_andGrowth() public {
        uint256[] memory sids = new uint256[](7);
        sids[0] = _composeOnce().sid;
        for (uint256 i = 1; i < 7; ++i) {
            sids[i] = _composeMore();
        }
        ScriptedController sc = new ScriptedController();
        _setController(address(sc));
        for (uint256 i = 1; i < 7; ++i) {
            sc.setOverprint(true, sids[0], sids[i]);
            _cool(address(core));
            vm.prank(stranger);
            uint256 g = gasleft();
            core.overprint();
            g -= gasleft();
            string memory n = string.concat(
                "overprint merge ",
                vm.toString(i),
                ", base now ",
                vm.toString(STATEMENTS.creditsOf(sids[0])),
                " credits, cold"
            );
            _row(n, g, abi.encodeCall(core.overprint, ()));
        }
        _enterPhase2();
        _warp(core.settings().exitAfter);
        _cool(address(core));
        vm.prank(keeper);
        uint256 e = gasleft();
        core.exitStatement(sids[0]);
        e -= gasleft();
        _row(
            "exitStatement of the merged base (480 credits), eth lane, cold",
            e,
            abi.encodeCall(core.exitStatement, (sids[0]))
        );
    }

    // ------------------------------------------------------------------ the sell doors, batch size

    /// @dev a sell of `n` fresh credits by `seller`, measured, then the state is rolled back. returns the exec gas and
    /// the estimated transaction gas
    function _sellBatch(bool exit_, uint256 n) internal returns (uint256 g, uint256 total) {
        // two runs, the larger counts: repeated runs of one size differ by a few thousand gas
        (uint256 g1, uint256 t1) = _sellOnce(exit_, n);
        (uint256 g2, uint256 t2) = _sellOnce(exit_, n);
        return t1 > t2 ? (g1, t1) : (g2, t2);
    }

    function _sellOnce(bool exit_, uint256 n) internal returns (uint256 g, uint256 total) {
        uint256 snap = vm.snapshotState();
        uint256[] memory ids = _credits(seller, n);
        bytes memory data =
            abi.encodeWithSignature(exit_ ? "sellForExitToken(uint256[])" : "sellForEth(uint256[])", ids);
        _cool(address(core));
        vm.prank(seller);
        g = gasleft();
        if (exit_) core.sellForExitToken(ids);
        else core.sellForEth(ids);
        g -= gasleft();
        total = _txGas(g, data, 0);
        vm.revertToState(snap);
    }

    /// @dev the core does not bound the batch. the largest `n` whose transaction stays under the cap is found by a
    /// linear fit on three sizes, then walked to the exact edge
    function _searchBatch(string memory label, bool exit_) internal {
        (uint256 g1, uint256 t1) = _sellBatch(exit_, 1);
        _row(string.concat(label, ", 1 credit, cold"), g1, abi.encodeWithSignature("sellForEth(uint256[])", _one(1)));
        (uint256 g10,) = _sellBatch(exit_, 10);
        (uint256 g40, uint256 t40) = _sellBatch(exit_, 40);
        uint256 slope = (t40 - t1) / 39;
        console.log(string.concat(label, ": marginal tx gas per credit (fit 1 to 40)"), slope);
        console.log(string.concat(label, ": exec gas for 10 credits"), g10);
        uint256 n = (CAP - t1) / slope + 1;
        while (n > 1) {
            (, uint256 t) = _sellBatch(exit_, n);
            if (t < CAP) break;
            --n;
        }
        while (n < 600) {
            (, uint256 t) = _sellBatch(exit_, n + 1);
            if (t >= CAP) break;
            ++n;
        }
        (uint256 gn, uint256 tn) = _sellBatch(exit_, n);
        (, uint256 tn1) = _sellBatch(exit_, n + 1);
        console.log(string.concat(label, ": LARGEST BATCH under the cap"), n);
        console.log(string.concat(label, ": gas per credit at the largest batch"), tn / n);
        string memory big = string.concat(label, ", largest batch ", vm.toString(n), ", cold");
        _log(big, gn, tn);
        console.log(string.concat(label, ": next size is over the cap, tx gas"), tn1);
        assertGe(tn1, CAP, "the search found the edge");
        assertGt(g40, g10);
    }

    function test_gas_sellForEth_batch_launchSettings() public {
        _fundPot(30 ether);
        _warp(1 hours + 1);
        _searchBatch("sellForEth flat bid (launch)", false);
    }

    /// @dev the owner can set `flatBps` below 10,000, then the score contract is read for every credit
    function test_gas_sellForEth_batch_perPointBid() public {
        Settings memory s = core.settings();
        s.flatBps = 0;
        _setSettings(s);
        _fundPot(30 ether);
        _warp(1 hours + 1);
        _searchBatch("sellForEth score bid (flatBps 0)", false);
    }

    function test_gas_sellForExitToken_batch() public {
        _enterPhase2();
        _fillExitBuyback();
        xt.mint(address(core), 1_000_000e18);
        core.skim();
        _searchBatch("sellForExitToken", true);
    }

    // ------------------------------------------------------------------ buyListing, sales proceeds, buybacks

    function test_gas_buyListing_creditStrategy() public {
        _fundPot(10 ether);
        uint256 price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _warpUntilCeiling(LISTED_A, price);
        bytes memory listing = abi.encodeCall(ICreditStrategy.sellTargetNFT, (LISTED_A));
        bytes memory data = abi.encodeCall(core.buyListing, (price, listing, LISTED_A, STRATEGY));
        _cool(address(core));
        vm.prank(keeper);
        uint256 g = gasleft();
        core.buyListing(price, listing, LISTED_A, STRATEGY);
        g -= gasleft();
        assertEq(CREDITS.ownerOf(LISTED_A), address(core));
        _row("buyListing through the CreditStrategy target, cold", g, data);
    }

    function _seaportBuy(string memory name, uint256 mode) internal {
        _fundPot(10 ether);
        uint256 id = _list();
        uint256 price = core.ceilingOf(id) * 9 / 10;
        OrderComponents memory c = mode == 1 ? _open(id, price - price / 100, price / 100) : _open(id, price, 0);
        bytes memory order = mode == 2 ? _advancedData(c, "", address(core)) : _basicData(c);
        bytes memory data = abi.encodeCall(core.buyListing, (price, order, id, Mainnet.SEAPORT));
        _cool(address(core));
        vm.prank(keeper);
        uint256 g = gasleft();
        core.buyListing(price, order, id, Mainnet.SEAPORT);
        g -= gasleft();
        assertEq(CREDITS.ownerOf(id), address(core));
        _row(name, g, data);
    }

    function test_gas_buyListing_seaport_basic() public {
        _seaportBuy("buyListing through seaport, basic order, cold", 0);
    }

    function test_gas_buyListing_seaport_basicWithFee() public {
        _seaportBuy("buyListing through seaport, basic order with a fee recipient, cold", 1);
    }

    function test_gas_buyListing_seaport_advanced() public {
        _seaportBuy("buyListing through seaport, advanced order, cold", 2);
    }

    /// @dev a statement sold on the house, the proceeds still in the house: collectSales alone, and buyback that collects
    /// first and then swaps in the real pool, and buyback after a collect
    function test_gas_collectSales_andBuyback() public {
        _sellStatement(bidder);
        vm.roll(block.number + 1);
        uint256 snap = vm.snapshotState();
        _cool(address(core));
        vm.prank(stranger);
        uint256 g = gasleft();
        core.collectSales();
        g -= gasleft();
        _row("collectSales, cold", g, abi.encodeCall(core.collectSales, ()));
        vm.revertToState(snap);

        snap = vm.snapshotState();
        _cool(address(core));
        vm.prank(keeper);
        g = gasleft();
        core.buyback();
        g -= gasleft();
        _row(
            "buyback with sale proceeds waiting in the house (collects, swaps, burns), cold",
            g,
            abi.encodeCall(core.buyback, ())
        );
        vm.revertToState(snap);

        _collectSales();
        _cool(address(core));
        vm.prank(keeper);
        g = gasleft();
        core.buyback();
        g -= gasleft();
        _row("buyback (swaps, burns), proceeds already collected, cold", g, abi.encodeCall(core.buyback, ()));
    }

    function test_gas_buybackExit() public {
        _enterPhase2();
        _fillExitBuyback();
        _buyCoin(taker, 20 ether);
        vm.prank(taker);
        coin.approve(address(core), type(uint256).max);
        uint256 coinIn;
        for (uint256 i; i < 2000; ++i) {
            (, coinIn) = core.exitAuctionQuote();
            if (coinIn <= coin.balanceOf(taker)) break;
            _warp(1 hours);
        }
        assertLe(coinIn, coin.balanceOf(taker), "affordable");
        _cool(address(core));
        vm.prank(taker);
        uint256 g = gasleft();
        core.buybackExit(coinIn);
        g -= gasleft();
        _row("buybackExit, cold", g, abi.encodeCall(core.buybackExit, (coinIn)));
    }

    // ------------------------------------------------------------------ statements: reprice, sync, sellTo, the house

    function test_gas_repriceStatement() public {
        uint256 sid = _composeOnce().sid;
        Settings memory s = core.settings();
        s.saleFloorBps = 12_000;
        _setSettings(s);
        _cool(address(core));
        vm.prank(stranger);
        uint256 g = gasleft();
        core.repriceStatement(sid);
        g -= gasleft();
        assertEq(_live(sid).reserve, _cost(sid) * 12_000 / 10_000);
        _row("repriceStatement, cold", g, abi.encodeCall(core.repriceStatement, (sid)));
        console.log("listings one multisig batch of setSettings plus reprices can hold (tx gas / reprice)", CAP / g);
    }

    function _cost(uint256 sid) internal view returns (uint256 c) {
        (,, c,) = core.statementInfo(sid);
    }

    function test_gas_syncStatement_soldPath() public {
        (uint256 sid,) = _sellStatement(bidder);
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Sold));
        _cool(address(core));
        vm.prank(stranger);
        uint256 g = gasleft();
        core.syncStatement(sid);
        g -= gasleft();
        _row("syncStatement, sold (clears the record), cold", g, abi.encodeCall(core.syncStatement, (sid)));
    }

    /// @dev the sale delivery to the winner fails (mocked, the real Statements never refuses), the lot is unwound after
    /// 30 days and comes back to the core, which lists it again
    function test_gas_syncStatement_relistPath() public {
        uint256 sid = _composeOnce().sid;
        Live memory l = _live(sid);
        _bid(bidder, sid, l.reserve);
        vm.mockCallRevert(
            address(STATEMENTS),
            abi.encodeWithSelector(IStatements.transferFrom.selector, address(house), bidder, sid),
            "cannot receive"
        );
        _endAuction(sid);
        _warp(30 days + 1);
        house.unwindStuckLot{gas: END_GAS}(l.auctionId);
        vm.clearMockedCalls();
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Returned));
        _cool(address(core));
        vm.prank(stranger);
        uint256 g = gasleft();
        core.syncStatement(sid);
        g -= gasleft();
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Listed));
        _row("syncStatement, relist after an unwound sale, cold", g, abi.encodeCall(core.syncStatement, (sid)));
    }

    /// @dev buy only mode: ControllerV1.buy pays the asking price and takes the statement through Core.sellTo
    function test_gas_sellTo_throughControllerBuy() public {
        uint256 sid = _composeOnce().sid;
        vm.prank(owner);
        ctl.setBuyOnly(true);
        uint256 price = ctl.priceOf(sid);
        vm.deal(bidder, price);
        _cool(address(ctl));
        vm.prank(bidder);
        uint256 g = gasleft();
        ctl.buy{value: price}(sid);
        g -= gasleft();
        assertEq(STATEMENTS.ownerOf(sid), bidder);
        _row("sellTo through ControllerV1.buy (cancels the listing), cold", g, abi.encodeCall(ctl.buy, (sid)));
    }

    function test_gas_house_createBid_andEndAuction() public {
        uint256 sid = _composeOnce().sid;
        Live memory l = _live(sid);
        vm.deal(bidder, l.reserve * 2);
        vm.deal(bidder2, l.reserve * 2);
        bytes memory data = abi.encodeCall(house.createBid, (l.auctionId));
        _cool(address(house));
        vm.prank(bidder);
        uint256 g = gasleft();
        house.createBid{value: l.reserve}(l.auctionId);
        g -= gasleft();
        _row("house createBid, first bid on a statement, cold", g, data);

        _cool(address(house));
        vm.prank(bidder2);
        g = gasleft();
        house.createBid{value: l.reserve * 12 / 10}(l.auctionId);
        g -= gasleft();
        _row("house createBid, outbid (refunds the first bidder), cold", g, data);

        l = _live(sid);
        vm.warp(l.endTime);
        _cool(address(house));
        vm.prank(stranger);
        g = gasleft();
        house.endAuction{gas: END_GAS}(l.auctionId);
        g -= gasleft();
        assertEq(STATEMENTS.ownerOf(sid), bidder2);
        _row("house endAuction of a statement (delivers it), cold", g, abi.encodeCall(house.endAuction, (l.auctionId)));
    }

    // ------------------------------------------------------------------ owner doors

    /// @dev phase 2 on, an exit buyback running: setSettings then takes its longest path (re anchors the exit auction
    /// when the half life changes) and every field is rewritten
    function test_gas_setSettings() public {
        _enterPhase2();
        _fillExitBuyback();
        Settings memory s = core.settings();
        s.flatBps = 9_000;
        s.avgScore = 4_000_000;
        s.climbPerMinBps = 90;
        s.dropPerCreditBps = 150;
        s.saleFloorBps = 8_000;
        s.auctionDuration = 2 days;
        s.saleToBuybackBps = 4_000;
        s.buybackSlice = 2 ether;
        s.xAuctionHalfLife = 12 hours;
        s.xRateFloor = 3_500;
        bytes memory data = abi.encodeCall(core.setSettings, (s));
        _cool(address(core));
        vm.prank(owner);
        uint256 g = gasleft();
        core.setSettings(s);
        g -= gasleft();
        assertEq(core.settings().saleFloorBps, 8_000);
        _row("setSettings (phase 2, exit auction re anchored), cold", g, data);
    }

    function test_gas_setController() public {
        ScriptedController sc = new ScriptedController();
        _cool(address(core));
        vm.prank(owner);
        uint256 g = gasleft();
        core.setController(address(sc));
        g -= gasleft();
        assertEq(core.controller(), address(sc));
        _row("setController, cold", g, abi.encodeCall(core.setController, (address(sc))));
    }

    function test_gas_setExitModule_firstAndReplace() public {
        xt = new MockExitToken("XT", "XT");
        mod = new MockExitModule(address(xt), UNIT);
        _cool(address(core));
        vm.prank(owner);
        uint256 g = gasleft();
        core.setExitModule(address(mod));
        g -= gasleft();
        _row("setExitModule, first set, cold", g, abi.encodeCall(core.setExitModule, (address(mod))));
        MockExitModule mod2 = new MockExitModule(address(xt), UNIT * 2);
        _cool(address(core));
        vm.prank(owner);
        g = gasleft();
        core.setExitModule(address(mod2));
        g -= gasleft();
        _row(
            "setExitModule, replace with a module of the same exitToken, cold",
            g,
            abi.encodeCall(core.setExitModule, (address(mod2)))
        );
    }

    // ------------------------------------------------------------------ the gas capped reads inside the core

    /// @dev the core reads `nextPage` with 500,000 gas and `statementPrice` with 200,000. a full pile, cold access
    function test_gas_readCaps_nextPageAndStatementPrice() public {
        _fillEthPile(80);
        _cool(address(ctl));
        uint256 g = gasleft();
        (bool ready,,) = ctl.nextPage(Lane.Eth);
        g -= gasleft();
        assertTrue(ready);
        console.log("READ ControllerV1.nextPage, full eth pile, cold, gas", g, "cap", PAGE_GAS);
        console.log("READ nextPage share of the cap in percent", g * 100 / PAGE_GAS);
        assertLt(g, PAGE_GAS);
        uint256 sid = _composeOnce().sid;
        (,, uint256 cost, uint64 at) = core.statementInfo(sid);
        _cool(address(ctl));
        uint256 p = gasleft();
        ctl.statementPrice(sid, cost, at);
        p -= gasleft();
        console.log("READ ControllerV1.statementPrice, cold, gas", p, "cap", READ_GAS);
        console.log("READ statementPrice share of the cap in percent", p * 100 / READ_GAS);
        assertLt(p, READ_GAS);
    }

    /// @dev the same read for the exit lane pile, and for a pile far larger than a page (the read takes the head page)
    function test_gas_readCaps_nextPage_exitLaneAndDeepPile() public {
        _enterPhase2();
        _fillExitBuyback();
        xt.mint(address(core), 1_000_000e18);
        core.skim();
        uint256[] memory ids = _credits(seller, 400);
        // in batches of 100: a cold sale of 400 credits in one call exceeds the gas of one call
        for (uint256 from; from < 400; from += 100) {
            uint256[] memory batch = new uint256[](100);
            for (uint256 j; j < 100; ++j) {
                batch[j] = ids[from + j];
            }
            vm.prank(seller);
            core.sellForExitToken(batch);
        }
        assertEq(core.pileSize(Lane.Exit), 400);
        _cool(address(ctl));
        uint256 g = gasleft();
        (bool ready,,) = ctl.nextPage(Lane.Exit);
        g -= gasleft();
        assertTrue(ready);
        console.log("READ ControllerV1.nextPage, exit lane, pile of 400, cold, gas", g, "cap", PAGE_GAS);
        assertLt(g, PAGE_GAS);
    }

    /// @dev a policy module may choose a format from 0 to 7. the shipped controller always answers 0. what each format
    /// costs the compose, with a scripted controller
    function test_gas_compose_everyFormat() public {
        _fillEthPile(80);
        uint256[] memory page = core.pilePage(Lane.Eth, 0, 80);
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        ScriptedController sc = new ScriptedController();
        _setController(address(sc));
        for (uint8 f; f < 8; ++f) {
            uint256 snap = vm.snapshotState();
            sc.setPage(Lane.Eth, true, ids, f);
            _cool(address(core));
            _measureCompose(
                string.concat("compose eth lane, scripted controller, format ", vm.toString(uint256(f)), ", cold")
            );
            vm.revertToState(snap);
        }
    }

    /// @dev how much the compose cost depends on which credits are composed: the live Statements contract directly, with
    /// pages of 80 real credits taken from different id ranges (first minted to latest), cold.
    /// measured once on the pin: 7,900,110 to 8,067,758 for the Statements call alone, so the page changes it by about 2 percent
    function test_gas_compose_pageVariance_liveStatements() public {
        // scans real credit owners over the rpc, minutes on a cold cache: runs only with GAS_VARIANCE=1
        if (!vm.envOr("GAS_VARIANCE", false)) vm.skip(true);
        address holder = _user("gas holder");
        vm.prank(holder);
        CREDITS.setApprovalForAll(address(STATEMENTS), true);
        uint256 worst;
        uint256 best = type(uint256).max;
        uint256[6] memory bases = [uint256(1), 6_000, 14_000, 22_000, 30_000, 38_000];
        for (uint256 b; b < bases.length; ++b) {
            uint256[80] memory ids;
            uint256 got;
            for (uint256 id = bases[b]; id < bases[b] + 2_000 && got < 80; ++id) {
                try CREDITS.ownerOf(id) returns (address o) {
                    if (o == holder) continue;
                    vm.prank(o);
                    CREDITS.transferFrom(o, holder, id);
                    ids[got++] = id;
                } catch {}
            }
            if (got < 80) {
                console.log("page base with fewer than 80 credits in range, skipped", bases[b]);
                continue;
            }
            vm.cool(address(STATEMENTS));
            vm.cool(address(CREDITS));
            vm.prank(holder);
            uint256 g = gasleft();
            STATEMENTS.compose(ids, 0);
            g -= gasleft();
            console.log("STATEMENTS.compose, 80 real credits from id", bases[b], "gas", g);
            if (g > worst) worst = g;
            if (g < best) best = g;
        }
        console.log("STATEMENTS.compose spread: best", best, "worst", worst);
        assertGt(worst, 0);
    }
}
