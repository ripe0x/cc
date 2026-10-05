// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Core} from "../../src/Core.sol";
import {Coin} from "../../src/Coin.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {ControllerV1} from "../../src/ControllerV1.sol";
import {Launcher} from "../../src/Launcher.sol";
import {Lane, ICredits, IStatements, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {SystemDeployer, Deployed} from "../../script/Deploy.s.sol";
import {MockExitToken} from "../mocks/MockExitToken.sol";
import {MockExitModule} from "../mocks/MockExitModule.sol";
import {CreditIds} from "./CreditIds.sol";
import {TestSwapRouter} from "./TestSwapRouter.sol";
import {TestLiquidityHelper} from "./TestLiquidityHelper.sol";

/// @notice the full system on a mainnet fork. the real Core, Coin, FeeHook, ControllerV1 and Launcher are deployed
/// through `SystemDeployer.deploySystem` and the launch pool lives in the real pool manager. only the exit module and
/// the exit token are test doubles, and they appear only after `_enterPhase2`.
/// @dev every address is namespaced because common labels are delegated accounts on mainnet that sweep eth
abstract contract Fixture is Test, SystemDeployer {
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IStatements internal constant STATEMENTS = IStatements(Mainnet.STATEMENTS);
    IPoolManager internal constant PM = IPoolManager(Mainnet.POOL_MANAGER);
    address internal constant STRATEGY = Mainnet.CREDIT_STRATEGY;
    address internal constant DEAD = Mainnet.DEAD;

    /// @dev credits the CreditStrategy lists for sale at the pinned block. they are never handed out as plain credits
    uint256 internal constant LISTED_A = 35377;
    uint256 internal constant LISTED_B = 28352;
    uint256 internal constant LISTED_C = 18683;

    /// @dev exit token base units per 1e4 scaled score point reported by the mock exit module
    uint256 internal constant UNIT = 1e10;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // ------------------------------------------------------------------ the system

    Core internal core;
    Coin internal coin;
    FeeHook internal hook;
    ControllerV1 internal ctl;
    Launcher internal launcher;
    PoolKey internal launchKey;
    TestSwapRouter internal router;
    TestLiquidityHelper internal lp;

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
    PoolKey internal xKey;
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

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        deployer = _user("deployer");
        owner = _user("owner");
        creator = _user("creator");
        keeper = _user("keeper");
        seller = _user("seller");
        funder = _user("funder");
        router = new TestSwapRouter();
        lp = new TestLiquidityHelper();

        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, owner, creator, "Lifecycle Coin", "LIFE");
        vm.stopPrank();

        core = Core(payable(d.core));
        coin = Coin(d.coin);
        hook = FeeHook(payable(d.hook));
        ctl = ControllerV1(d.controller);
        launcher = Launcher(d.launcher);
        launchKey = d.launchKey;
    }

    /// @notice a namespaced account with no code
    function _user(string memory label) internal returns (address a) {
        a = makeAddr(string.concat("lifecycle.", label, ".4b1d"));
        assertEq(a.code.length, 0, "account has code on the fork");
    }

    // ------------------------------------------------------------------ swaps through the launch pool

    /// @notice buys coin with `ethIn` eth, exact in, through the real launch pool. `who` is funded for it
    /// @return coinOut the coin `who` received
    function _buyCoin(address who, uint256 ethIn) internal returns (uint256 coinOut) {
        vm.deal(who, who.balance + ethIn);
        uint256 before = coin.balanceOf(who);
        vm.prank(who);
        router.swap{value: ethIn}(launchKey, true, -int256(ethIn), who);
        coinOut = coin.balanceOf(who) - before;
    }

    /// @notice sells `coinIn` coin for eth, exact in, through the real launch pool
    /// @return ethOut the eth `who` received after the fee
    function _sellCoin(address who, uint256 coinIn) internal returns (uint256 ethOut) {
        vm.prank(who);
        coin.approve(address(router), type(uint256).max);
        uint256 before = who.balance;
        vm.prank(who);
        router.swap(launchKey, false, -int256(coinIn), who);
        ethOut = who.balance - before;
    }

    /// @notice generates fees through real buys until the eth pot holds at least `eth`
    function _fundPot(uint256 eth) internal {
        for (uint256 i; i < 8 && core.ethPot() < eth; ++i) {
            uint256 need = eth - core.ethPot();
            // 9.5 percent of every buy reaches the pot
            _buyCoin(funder, need * 10_000 / 950 + 2);
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

    /// @notice warps an hour at a time until the ceiling of credit `id` reaches `price`
    function _warpUntilCeiling(uint256 id, uint256 price) internal {
        for (uint256 i; i < 400; ++i) {
            if (core.ceilingOf(id) >= price) return;
            vm.warp(block.timestamp + 1 hours);
        }
        revert("ceiling never cleared");
    }

    /// @notice sells `n` fresh credits into the eth bid, which puts them in the eth pile in the order returned.
    /// funds the pot first when it cannot carry the sale, and moves past the hourly cap window if it must
    function _fillEthPile(uint256 n) internal returns (uint256[] memory ids) {
        ids = _credits(seller, n);
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

    // ------------------------------------------------------------------ owner actions

    function _timelock(Core.Action action, bytes memory data) internal {
        vm.startPrank(owner);
        core.queue(action, data);
        vm.warp(block.timestamp + 7 days);
        core.execute(action, data);
        vm.stopPrank();
    }

    /// @notice adds a target to the core allowlist through the timelock
    function _allow(address target) internal {
        _timelock(Core.Action.AddTarget, abi.encode(target));
    }

    // ------------------------------------------------------------------ phase 2

    /// @notice fills the exit module slot and the exit pool key through the timelock, with the mock exit module and
    /// mock exit token, then initializes the coin and exit token pool on the same hook and adds two sided
    /// liquidity. the liquidity provider first buys the coin it needs in the launch pool
    function _enterPhase2() internal {
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), UNIT);
        (address a0, address a1) =
            address(xt) < address(coin) ? (address(xt), address(coin)) : (address(coin), address(xt));
        xKey = PoolKey({
            currency0: Currency.wrap(a0),
            currency1: Currency.wrap(a1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.startPrank(owner);
        core.queue(Core.Action.SetExitModule, abi.encode(address(mod)));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(xKey));
        vm.warp(block.timestamp + 7 days);
        core.execute(Core.Action.SetExitModule, abi.encode(address(mod)));
        core.execute(Core.Action.SetExitPoolKey, abi.encode(xKey));
        vm.stopPrank();

        PM.initialize(xKey, SQRT_PRICE_1_1);

        address lper = _user("lper");
        uint256 coinBal = _buyCoin(lper, 20 ether);
        xt.mint(lper, 1e30);
        vm.startPrank(lper);
        coin.approve(address(lp), type(uint256).max);
        xt.approve(address(lp), type(uint256).max);
        // about a quarter of the liquidity is paid in each token over this range at a one to one price
        lp.modify(xKey, -6000, 6000, int256(coinBal * 3));
        vm.stopPrank();
        inPhase2 = true;
    }

    function _exitIs0() internal view returns (bool) {
        return Currency.unwrap(xKey.currency0) == address(xt);
    }

    /// @notice buys coin with `xIn` exit token, exact in, through the exit pool. `who` is funded for it
    function _buyCoinWithExit(address who, uint256 xIn) internal returns (uint256 coinOut) {
        xt.mint(who, xIn);
        vm.prank(who);
        xt.approve(address(router), type(uint256).max);
        uint256 before = coin.balanceOf(who);
        vm.prank(who);
        router.swap(xKey, _exitIs0(), -int256(xIn), who);
        coinOut = coin.balanceOf(who) - before;
    }

    /// @notice sells `coinIn` coin for exit token, exact in, through the exit pool. `who` must hold the coin
    function _sellCoinForExit(address who, uint256 coinIn) internal returns (uint256 xOut) {
        vm.prank(who);
        coin.approve(address(router), type(uint256).max);
        uint256 before = xt.balanceOf(who);
        vm.prank(who);
        router.swap(xKey, !_exitIs0(), -int256(coinIn), who);
        xOut = xt.balanceOf(who) - before;
    }

    /// @notice the exit token claims the hook holds in the pool manager
    function _hookClaims() internal view returns (uint256) {
        return IERC6909Claims(address(PM)).balanceOf(address(hook), uint256(uint160(address(xt))));
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
