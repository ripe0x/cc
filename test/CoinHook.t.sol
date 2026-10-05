// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {Coin} from "../src/Coin.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {Launcher} from "../src/Launcher.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {MockExitToken} from "./mocks/MockExitToken.sol";
import {MockWiring, Wired} from "./utils/MockWiring.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";

/// @dev creator whose receive always reverts
contract RevertingCreator {
    receive() external payable {
        revert("no");
    }
}

/// @dev creator whose receive burns all gas it is given
contract GasBurnerCreator {
    receive() external payable {
        while (true) {}
    }
}

abstract contract CoinHookBase is Test, MockWiring {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    enum Kind {
        BuyIn,
        BuyOut,
        SellIn,
        SellOut
    }

    /// @dev a pool under test. `feeIs0` is true when currency0 is the fee currency
    struct Ctx {
        PoolKey key;
        bool feeIs0;
        bool exit;
    }

    IPoolManager internal constant PM = IPoolManager(Mainnet.POOL_MANAGER);
    IPositionManager internal constant POSM = IPositionManager(Mainnet.POSITION_MANAGER);
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    Wired internal w;
    TestSwapRouter internal router;
    TestLiquidityHelper internal lp;

    address internal creator = makeAddr("fx.creator.9c1e");
    address internal alice = makeAddr("fx.alice.9c1e");
    address internal bob = makeAddr("fx.bob.9c1e");

    uint256 internal firstTokenId;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        router = new TestSwapRouter();
        lp = new TestLiquidityHelper();
        firstTokenId = POSM.nextTokenId();
        w = _wireAndLaunch(creator);
        _approveAll(alice);
        _approveAll(bob);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    /// @dev the test wiring: real Coin, FeeHook and Launcher around the MockCore, then the launch
    function _wireAndLaunch(address creator_) internal returns (Wired memory x) {
        x = wireWithMockCore(address(this), creator_);
        x.launcher.launch(address(x.coin), address(x.hook));
    }

    function _approveAll(address user) internal {
        vm.startPrank(user);
        w.coin.approve(address(router), type(uint256).max);
        w.coin.approve(address(lp), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ swap helpers

    function _swapAmounts() internal returns (int128 a0, int128 a1) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(PM) && logs[i].topics[0] == SWAP_TOPIC) {
                return abi.decode(logs[i].data, (int128, int128));
            }
        }
        revert("no swap event");
    }

    function _buyIn(address user, uint256 eth) internal {
        vm.prank(user);
        router.swap{value: eth}(w.launchKey, true, -int256(eth), user);
    }

    function _coinOf(address user) internal view returns (uint256) {
        return w.coin.balanceOf(user);
    }

    /// @dev buys coin with eth on the launch pool so the user has coin to trade
    function _fundCoin(address user, uint256 eth) internal returns (uint256) {
        _buyIn(user, eth);
        return _coinOf(user);
    }

    function _launchCtx() internal view returns (Ctx memory) {
        return Ctx({key: w.launchKey, feeIs0: true, exit: false});
    }

    /// @dev runs one swap of the given kind on the pool and returns the pool level deltas from the swap event
    function _exec(Ctx memory c, Kind k, address user, uint256 amt) internal returns (int128 a0, int128 a1) {
        bool buy = k == Kind.BuyIn || k == Kind.BuyOut;
        bool zeroForOne = buy ? c.feeIs0 : !c.feeIs0;
        int256 spec = (k == Kind.BuyIn || k == Kind.SellIn) ? -int256(amt) : int256(amt);
        uint256 value;
        if (!c.exit && buy) value = k == Kind.BuyIn ? amt : 500 ether;
        vm.recordLogs();
        vm.prank(user);
        router.swap{value: value}(c.key, zeroForOne, spec, user);
        (a0, a1) = _swapAmounts();
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return uint256(uint128(x < 0 ? -x : x));
    }

    function _splitLegs(Ctx memory c, int128 a0, int128 a1) internal pure returns (int128 feeLeg, int128 coinLeg) {
        return c.feeIs0 ? (a0, a1) : (a1, a0);
    }

    // ------------------------------------------------------------------ exit pool

    MockExitToken internal xt;
    bool internal exitIs0;
    PoolKey internal xKey;

    /// @dev opens the coin/exitToken pool. `exitFirst` puts the exit token at currency0
    function _openExitPool(bool exitFirst) internal {
        exitIs0 = exitFirst;
        address xaddr =
            exitFirst ? address(uint160(address(w.coin)) - 0x10000) : address(uint160(address(w.coin)) + 0x10000);
        deployCodeTo("MockExitToken.sol:MockExitToken", abi.encode("Mock Exit Token", "MXT"), xaddr);
        xt = MockExitToken(xaddr);
        (address a0, address a1) = exitFirst ? (xaddr, address(w.coin)) : (address(w.coin), xaddr);
        xKey = PoolKey({
            currency0: Currency.wrap(a0),
            currency1: Currency.wrap(a1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(w.hook))
        });
        w.core.setExit(PoolId.unwrap(xKey.toId()), xaddr);
        vm.prank(alice);
        PM.initialize(xKey, SQRT_PRICE_1_1);
        xt.mint(alice, 1e30);
        xt.mint(bob, 1e30);
        vm.startPrank(alice);
        xt.approve(address(router), type(uint256).max);
        xt.approve(address(lp), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        xt.approve(address(router), type(uint256).max);
        xt.approve(address(lp), type(uint256).max);
        vm.stopPrank();
    }

    function _exitCtx() internal view returns (Ctx memory) {
        return Ctx({key: xKey, feeIs0: exitIs0, exit: true});
    }

    function _exitClaims() internal view returns (uint256) {
        return IERC6909Claims(address(PM)).balanceOf(address(w.hook), uint256(uint160(address(xt))));
    }

    function _expectHookRevert(bytes4 hookSelector, bytes memory inner) internal {
        _expectHookRevert(address(w.hook), hookSelector, inner);
    }

    function _expectHookRevert(address hook, bytes4 hookSelector, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hook,
                hookSelector,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}

contract CoinHookLaunchTest is CoinHookBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint128 internal constant REFERENCE_LIQUIDITY = 158372218983990412488087;

    // ------------------------------------------------------------------ launch

    function test_hookAddressFlags() public view {
        assertEq(uint160(address(w.hook)) & Hooks.ALL_HOOK_MASK, 0x25CC);
        Hooks.Permissions memory p = w.hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.afterAddLiquidity && p.afterRemoveLiquidity);
        assertTrue(p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(
            p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
    }

    function test_launch_poolPriceAndSupply() public view {
        (uint160 sqrtPrice, int24 tick, uint24 protocolFee, uint24 lpFee) = PM.getSlot0(w.launchKey.toId());
        assertEq(sqrtPrice, 501082896750095888663770159906816);
        assertEq(tick, TickMath.getTickAtSqrtPrice(sqrtPrice));
        assertEq(protocolFee, 0);
        assertEq(lpFee, 0);
        assertEq(PM.getLiquidity(w.launchKey.toId()), 0, "the position sits below the price");

        uint256 supply = w.coin.SUPPLY();
        assertEq(w.coin.totalSupply(), supply);
        uint256 dust = w.coin.balanceOf(Mainnet.DEAD);
        assertEq(w.coin.balanceOf(address(PM)) + dust, supply, "everything is in the pool manager or dead");
        assertLt(dust, 1e12, "only rounding dust goes to dead");
        assertEq(w.coin.balanceOf(address(w.launcher)), 0);
    }

    function test_launch_positionOwnedByDead() public view {
        uint256 tokenId = firstTokenId;
        assertEq(POSM.nextTokenId(), tokenId + 1, "one position minted");
        assertEq(_ownerOf(tokenId), Mainnet.DEAD);
        assertEq(POSM.getPositionLiquidity(tokenId), REFERENCE_LIQUIDITY, "same liquidity as the reference launch");
        (PoolKey memory key,) = POSM.getPoolAndPositionInfo(tokenId);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(w.launchKey.toId()));
    }

    function _ownerOf(uint256 tokenId) internal view returns (address o) {
        (bool ok, bytes memory ret) = address(POSM).staticcall(abi.encodeWithSignature("ownerOf(uint256)", tokenId));
        require(ok);
        o = abi.decode(ret, (address));
    }

    function test_launch_lockedAndOneShot() public {
        assertFalse(w.launcher.launching());
        assertTrue(w.launcher.launched());
        vm.expectRevert(Launcher.AlreadyLaunched.selector);
        w.launcher.launch(address(w.coin), address(w.hook));
    }

    function test_launch_deployerOnly() public {
        Wired memory x = wireWithMockCore(address(this), creator);
        vm.prank(alice);
        vm.expectRevert(Launcher.OnlyDeployer.selector);
        x.launcher.launch(address(x.coin), address(x.hook));
        // still works for the deployer afterwards
        x.launcher.launch(address(x.coin), address(x.hook));
    }

    function test_launch_rejectsForeignHook() public {
        Wired memory x = wireWithMockCore(address(this), creator);
        vm.expectRevert(Launcher.WrongHook.selector);
        x.launcher.launch(address(x.coin), address(w.hook));
    }

    function test_launch_emitsEvent() public {
        Wired memory x = wireWithMockCore(address(this), creator);
        vm.expectEmit(true, true, false, false, address(x.launcher));
        emit Launcher.Launched(address(x.coin), address(x.hook), bytes32(0), 0, 0);
        x.launcher.launch(address(x.coin), address(x.hook));
    }

    // ------------------------------------------------------------------ pool gating

    function test_init_launchPoolNotOpenBeforeLaunch() public {
        Wired memory x = wireWithMockCore(address(this), creator);
        _expectHookRevert(
            address(x.hook), IHooks.beforeInitialize.selector, abi.encodeWithSelector(FeeHook.NotLaunching.selector)
        );
        PM.initialize(x.launchKey, SQRT_PRICE_1_1);
    }

    function test_init_launchPoolAlreadyInitialized() public {
        vm.expectRevert();
        vm.prank(alice);
        PM.initialize(w.launchKey, SQRT_PRICE_1_1);
    }

    function test_init_otherShapesWithThisHookRevert() public {
        Currency c0 = Currency.wrap(address(0));
        Currency c1 = Currency.wrap(address(w.coin));
        PoolKey[4] memory keys = [
            PoolKey(c0, c1, 3000, 60, IHooks(address(w.hook))),
            PoolKey(c0, c1, 0, 10, IHooks(address(w.hook))),
            PoolKey(c0, c1, 100, 1, IHooks(address(w.hook))),
            PoolKey(
                Currency.wrap(address(w.coin)),
                Currency.wrap(address(uint160(address(w.coin)) + 1)),
                0,
                60,
                IHooks(address(w.hook))
            )
        ];
        for (uint256 i; i < keys.length; i++) {
            _expectHookRevert(IHooks.beforeInitialize.selector, abi.encodeWithSelector(FeeHook.PoolNotAllowed.selector));
            vm.prank(alice);
            PM.initialize(keys[i], SQRT_PRICE_1_1);
        }
    }

    function test_init_exitPoolNotOpenUntilCoreSetsIt() public {
        MockExitToken token = new MockExitToken("Mock Exit Token", "MXT");
        (address a0, address a1) =
            address(token) < address(w.coin) ? (address(token), address(w.coin)) : (address(w.coin), address(token));
        PoolKey memory k = PoolKey(Currency.wrap(a0), Currency.wrap(a1), 0, 60, IHooks(address(w.hook)));
        _expectHookRevert(IHooks.beforeInitialize.selector, abi.encodeWithSelector(FeeHook.PoolNotAllowed.selector));
        PM.initialize(k, SQRT_PRICE_1_1);
    }

    function test_launchPool_nobodyCanAddLiquidity() public {
        _fundCoin(alice, 1 ether);
        // coin only range below the price and eth only range above it
        int24[2][2] memory ranges = [[int24(60000), int24(120000)], [int24(180000), int24(186000)]];
        for (uint256 i; i < 2; i++) {
            _expectHookRevert(IHooks.afterAddLiquidity.selector, abi.encodeWithSelector(FeeHook.NotLaunching.selector));
            vm.prank(alice);
            lp.modify{value: 10 ether}(w.launchKey, ranges[i][0], ranges[i][1], 1e18);
        }
        assertEq(w.coin.transferAllowance(), 0);
    }

    function test_launchPool_deadPositionCannotBeTouched() public {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(firstTokenId, uint256(1e18), uint128(0), uint128(0), "");
        params[1] = abi.encode(w.launchKey.currency0, w.launchKey.currency1, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, alice));
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @dev the dead address has no key. if it somehow did, the hook still refuses to release the position
    function test_launchPool_removeIsLockedEvenForTheOwner() public {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(firstTokenId, uint256(REFERENCE_LIQUIDITY), uint128(0), uint128(0), "");
        params[1] = abi.encode(w.launchKey.currency0, w.launchKey.currency1, Mainnet.DEAD);
        bytes memory unlockData = abi.encode(actions, params);
        vm.prank(Mainnet.DEAD);
        _expectHookRevert(
            IHooks.afterRemoveLiquidity.selector, abi.encodeWithSelector(FeeHook.LaunchPoolLocked.selector)
        );
        POSM.modifyLiquidities(unlockData, block.timestamp);
    }

    // ------------------------------------------------------------------ transfer restriction

    function test_transfer_walletToWalletReverts() public {
        _fundCoin(alice, 1 ether);
        uint256 bal = _coinOf(alice);
        vm.prank(alice);
        vm.expectRevert(Coin.InvalidTransfer.selector);
        w.coin.transfer(bob, 1);
        vm.prank(alice);
        w.coin.approve(bob, bal);
        vm.prank(bob);
        vm.expectRevert(Coin.InvalidTransfer.selector);
        w.coin.transferFrom(alice, bob, 1);
    }

    function test_transfer_hooklessPoolRejectsCoin() public {
        _fundCoin(alice, 2 ether);
        PoolKey memory side =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(w.coin)), 3000, 60, IHooks(address(0)));
        vm.prank(alice);
        PM.initialize(side, SQRT_PRICE_1_1);

        // adding liquidity that needs coin fails
        vm.prank(alice);
        vm.expectRevert(Coin.InvalidTransfer.selector);
        lp.modify{value: 10 ether}(side, -600, 600, 1e18);

        // eth only liquidity above the price is allowed because no coin moves
        vm.prank(alice);
        lp.modify{value: 5 ether}(side, 600, 6000, 1e18);

        // selling coin into it fails at the coin transfer
        vm.prank(alice);
        vm.expectRevert(Coin.InvalidTransfer.selector);
        router.swap(side, false, -1e18, alice);
        assertEq(w.coin.transferAllowance(), 0);
    }

    function test_transfer_allowlist() public {
        _fundCoin(alice, 1 ether);
        address dead = Mainnet.DEAD;
        address core = address(w.core);

        vm.prank(alice);
        w.coin.transfer(core, 1000);
        assertEq(_coinOf(core), 1000);
        vm.prank(core);
        w.coin.transfer(bob, 400);
        assertEq(_coinOf(bob), 400);
        vm.prank(alice);
        w.coin.transfer(dead, 5);
        vm.prank(dead);
        w.coin.transfer(alice, 5);
        // bob still cannot move what he got from the core
        vm.prank(bob);
        vm.expectRevert(Coin.InvalidTransfer.selector);
        w.coin.transfer(alice, 1);
        vm.prank(bob);
        w.coin.transfer(core, 400);
    }

    /// @dev the core buys back by swapping eth in and taking the coin straight to the dead address
    function test_transfer_buybackToDeadConsumesTheGrant() public {
        uint256 dead0 = w.coin.balanceOf(Mainnet.DEAD);
        vm.prank(alice);
        router.swap{value: 2 ether}(w.launchKey, true, -2 ether, Mainnet.DEAD);
        assertGt(w.coin.balanceOf(Mainnet.DEAD), dead0);
        assertEq(w.coin.transferAllowance(), 0);
        assertEq(_coinOf(alice), 0);
        assertEq(w.coin.totalSupply(), w.coin.SUPPLY());
    }

    function test_transfer_onlyHookCanGrant() public {
        vm.prank(alice);
        vm.expectRevert(Coin.OnlyHook.selector);
        w.coin.increaseTransferAllowance(1);
        assertEq(w.coin.transferAllowance(), 0);
    }

    function test_transfer_noMintEntryPoint() public {
        (bool ok,) = address(w.coin).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        (ok,) = address(w.coin).call(abi.encodeWithSignature("burn(address,uint256)", alice, 1));
        assertFalse(ok);
        assertEq(w.coin.totalSupply(), w.coin.SUPPLY());
    }

    function test_transfer_supplyConstantAndNoAllowanceLeftAfterTrading() public {
        _fundCoin(alice, 5 ether);
        _fundCoin(bob, 3 ether);
        uint256 half = _coinOf(alice) / 2;
        vm.prank(alice);
        router.swap(w.launchKey, false, -int256(half), alice);
        assertEq(w.coin.transferAllowance(), 0);
        assertEq(w.coin.totalSupply(), w.coin.SUPPLY());
        assertEq(
            w.coin.balanceOf(address(PM)) + _coinOf(alice) + _coinOf(bob) + w.coin.balanceOf(Mainnet.DEAD),
            w.coin.SUPPLY()
        );
    }

    // ------------------------------------------------------------------ fee: launch pool

    struct Snap {
        uint256 userEth;
        uint256 userCoin;
        uint256 creator;
        uint256 core;
        uint256 booked;
        uint256 calls;
        uint256 pmEth;
        uint256 pmCoin;
    }

    function _snap() internal view returns (Snap memory s) {
        s.userEth = alice.balance;
        s.userCoin = _coinOf(alice);
        s.creator = creator.balance;
        s.core = address(w.core).balance;
        s.booked = w.core.ethFees();
        s.calls = w.core.ethFeeCalls();
        s.pmEth = address(PM).balance;
        s.pmCoin = w.coin.balanceOf(address(PM));
    }

    /// @dev the fee expected for a swap kind, from the notional that kind of swap is expressed in
    function _expectedFee(Kind k, uint256 amt, int128 feeLeg) internal pure returns (uint256 fee) {
        if (k == Kind.BuyIn) {
            fee = amt * 1000 / 10_000;
            assertEq(_abs(feeLeg), amt - fee, "pool swapped the amount net of the fee");
        } else if (k == Kind.SellOut) {
            fee = amt * 1000 / 10_000;
            assertEq(_abs(feeLeg), amt + fee, "pool paid the amount plus the fee");
        } else {
            fee = _abs(feeLeg) * 1000 / 10_000;
        }
    }

    function _feeCase(Ctx memory c, Kind k, uint256 amt) internal {
        Snap memory a = _snap();
        (int128 a0, int128 a1) = _exec(c, k, alice, amt);
        Snap memory b = _snap();
        (int128 feeLeg, int128 coinLeg) = _splitLegs(c, a0, a1);
        uint256 fee = _expectedFee(k, amt, feeLeg);

        uint256 creatorCut = fee * 50 / 1000;
        assertEq(b.creator - a.creator, creatorCut, "creator share");
        assertEq(b.core - a.core, fee - creatorCut, "core share");
        assertEq(b.booked - a.booked, fee - creatorCut, "core booked what it got");
        assertEq(b.calls - a.calls, fee == 0 ? 0 : 1);

        _checkUser(k, amt, a, b, feeLeg, coinLeg, fee);

        assertEq(address(w.hook).balance, 0, "hook keeps nothing");
        assertEq(w.coin.balanceOf(address(w.hook)), 0);
        assertEq(w.coin.transferAllowance(), 0, "no allowance left behind");
        assertEq(w.coin.totalSupply(), w.coin.SUPPLY());
        int256 ethNet = int256(b.userEth) - int256(a.userEth) + int256(b.creator - a.creator) + int256(b.core - a.core)
            + int256(b.pmEth) - int256(a.pmEth);
        assertEq(ethNet, 0, "eth reconciles across user, creator, core and pool manager");
        assertEq(int256(b.pmCoin) - int256(a.pmCoin), int256(a.userCoin) - int256(b.userCoin));
    }

    /// @dev user balances reconcile to the wei
    function _checkUser(Kind k, uint256 amt, Snap memory a, Snap memory b, int128 feeLeg, int128 coinLeg, uint256 fee)
        internal
        pure
    {
        if (k == Kind.BuyIn) {
            assertEq(a.userEth - b.userEth, amt, "user paid exactly the amount");
            assertEq(b.userCoin - a.userCoin, _abs(coinLeg));
        } else if (k == Kind.BuyOut) {
            assertEq(b.userCoin - a.userCoin, amt, "user got exactly the coin asked for");
            assertEq(a.userEth - b.userEth, _abs(feeLeg) + fee, "user paid pool eth plus the fee");
        } else if (k == Kind.SellIn) {
            assertEq(a.userCoin - b.userCoin, amt, "user sold exactly the coin offered");
            assertEq(b.userEth - a.userEth, _abs(feeLeg) - fee, "user got pool eth minus the fee");
        } else {
            assertEq(b.userEth - a.userEth, amt, "user got exactly the eth asked for");
            assertEq(a.userCoin - b.userCoin, _abs(coinLeg));
        }
    }

    function test_fee_buyExactIn() public {
        _feeCase(_launchCtx(), Kind.BuyIn, 7 ether + 123456789);
    }

    function test_fee_buyExactOut() public {
        _feeCase(_launchCtx(), Kind.BuyOut, 3_000_000e18 + 77);
    }

    function test_fee_sellExactIn() public {
        _fundCoin(alice, 10 ether);
        _feeCase(_launchCtx(), Kind.SellIn, _coinOf(alice) / 3);
    }

    function test_fee_sellExactOut() public {
        _fundCoin(alice, 10 ether);
        _feeCase(_launchCtx(), Kind.SellOut, 2 ether + 999);
    }

    function test_fee_split() public {
        _buyIn(alice, 100 ether);
        // 100 eth in: fee 10 eth, creator 0.5 eth, core 9.5 eth
        assertEq(creator.balance, 0.5 ether);
        assertEq(address(w.core).balance, 9.5 ether);
        assertEq(w.core.ethFees(), 9.5 ether);
    }

    function test_fee_zeroFeeOnDust() public {
        _feeCase(_launchCtx(), Kind.BuyIn, 9);
        assertEq(w.core.ethFeeCalls(), 0);
    }

    function test_fee_eventEmitted() public {
        vm.expectEmit(true, true, false, true, address(w.hook));
        emit FeeHook.FeesTaken(PoolId.unwrap(w.launchKey.toId()), address(0), 0.05 ether, 0.95 ether);
        _buyIn(alice, 10 ether);
    }

    function test_fee_creatorRevertingCannotBrickSwaps() public {
        RevertingCreator hostile = new RevertingCreator();
        Wired memory saved = w;
        w = _wireAndLaunch(address(hostile));
        _approveAll(alice);
        uint256 before = address(hostile).balance;
        _buyIn(alice, 10 ether);
        assertEq(address(hostile).balance - before, 0.05 ether, "the creator share arrives by force send");
        uint256 coin1 = _coinOf(alice);
        vm.prank(alice);
        router.swap(w.launchKey, false, -int256(coin1 / 2), alice);
        assertGt(address(hostile).balance - before, 0.05 ether);
        w = saved;
    }

    function test_fee_creatorBurningGasCannotBrickSwaps() public {
        // reference swap gas with an ordinary creator
        uint256 g0 = gasleft();
        _buyIn(alice, 10 ether);
        uint256 base = g0 - gasleft();

        GasBurnerCreator burner = new GasBurnerCreator();
        w = _wireAndLaunch(address(burner));
        _approveAll(alice);
        uint256 g1 = gasleft();
        _buyIn(alice, 10 ether);
        uint256 hostile = g1 - gasleft();
        assertEq(address(burner).balance, 0.05 ether, "creator share arrives");
        assertLt(hostile, base + 150_000, "the creator can only burn its stipend");
    }

    function test_fee_receiveOnlyFromPoolManager() public {
        (bool ok,) = address(w.hook).call{value: 1}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_launchFees(uint8 kindRaw, uint256 raw) public {
        Kind k = Kind(bound(kindRaw, 0, 3));
        _fundCoin(alice, 10 ether);
        uint256 amt;
        if (k == Kind.BuyIn) amt = bound(raw, 1, 20 ether);
        else if (k == Kind.BuyOut) amt = bound(raw, 1, 1e26);
        else if (k == Kind.SellIn) amt = bound(raw, 1, _coinOf(alice));
        else amt = bound(raw, 1, 3 ether);
        _feeCase(_launchCtx(), k, amt);
    }

    function testFuzz_launchRoundTrip(uint256 buyRaw, uint256 sellFraction) public {
        uint256 eth = bound(buyRaw, 1e6, 50 ether);
        _buyIn(alice, eth);
        uint256 coinBal = _coinOf(alice);
        uint256 sell = bound(sellFraction, 1, coinBal);
        _feeCase(_launchCtx(), Kind.SellIn, sell);
        assertEq(w.coin.transferAllowance(), 0);
        assertEq(w.coin.totalSupply(), w.coin.SUPPLY());
    }
}

contract CoinHookExitPoolTest is CoinHookBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function _seed(bool exitFirst) internal {
        _openExitPool(exitFirst);
        _fundCoin(alice, 5 ether);
        _fundCoin(bob, 5 ether);
        vm.prank(alice);
        lp.modify(xKey, -6000, 6000, 1e24);
    }

    function _runKind(bool exitFirst, Kind k, uint256 amt) internal {
        _seed(exitFirst);
        _exitFeeCase(k, amt);
    }

    function _exitFeeCase(Kind k, uint256 amt) internal {
        Ctx memory c = _exitCtx();
        address user = bob;
        uint256 x0 = xt.balanceOf(user);
        uint256 coin0 = _coinOf(user);
        uint256 claims0 = _exitClaims();
        uint256 owed0 = w.hook.creatorExitOwed();
        uint256 pmX0 = xt.balanceOf(address(PM));
        uint256 pmCoin0 = w.coin.balanceOf(address(PM));
        uint256 ethCalls0 = w.core.ethFeeCalls();

        (int128 a0, int128 a1) = _exec(c, k, user, amt);
        (int128 feeLeg, int128 coinLeg) = _splitLegs(c, a0, a1);

        uint256 fee;
        if (k == Kind.BuyIn) {
            fee = amt * 1000 / 10_000;
            assertEq(_abs(feeLeg), amt - fee);
        } else if (k == Kind.BuyOut) {
            fee = _abs(feeLeg) * 1000 / 10_000;
        } else if (k == Kind.SellIn) {
            fee = _abs(feeLeg) * 1000 / 10_000;
        } else {
            fee = amt * 1000 / 10_000;
            assertEq(_abs(feeLeg), amt + fee);
        }
        uint256 creatorCut = fee * 50 / 1000;

        // the fee sits as claims in the pool manager, split between creator and core
        assertEq(_exitClaims() - claims0, fee, "claims hold the whole fee");
        assertEq(w.hook.creatorExitOwed() - owed0, creatorCut, "creator share accrued");
        assertEq(w.core.ethFeeCalls(), ethCalls0, "no eth fee in the exit pool");

        // user reconciles in both tokens
        if (k == Kind.BuyIn) {
            assertEq(x0 - xt.balanceOf(user), amt);
            assertEq(_coinOf(user) - coin0, _abs(coinLeg));
        } else if (k == Kind.BuyOut) {
            assertEq(_coinOf(user) - coin0, amt);
            assertEq(x0 - xt.balanceOf(user), _abs(feeLeg) + fee);
        } else if (k == Kind.SellIn) {
            assertEq(coin0 - _coinOf(user), amt);
            assertEq(xt.balanceOf(user) - x0, _abs(feeLeg) - fee);
        } else {
            assertEq(xt.balanceOf(user) - x0, amt);
            assertEq(coin0 - _coinOf(user), _abs(coinLeg));
        }
        assertEq(w.coin.transferAllowance(), 0, "no allowance left behind");
        assertEq(w.coin.totalSupply(), w.coin.SUPPLY());
        // the exit token never leaves the pool manager until the claim functions run
        assertEq(int256(xt.balanceOf(address(PM))) - int256(pmX0), int256(x0) - int256(xt.balanceOf(user)));
        assertEq(int256(w.coin.balanceOf(address(PM))) - int256(pmCoin0), int256(coin0) - int256(_coinOf(user)));
        assertEq(xt.balanceOf(address(w.hook)), 0);
    }

    function test_exit_anyoneInitializes_bothOrders() public {
        _openExitPool(true);
        assertTrue(Currency.unwrap(xKey.currency0) < Currency.unwrap(xKey.currency1));
        (uint160 sp,,,) = PM.getSlot0(xKey.toId());
        assertEq(sp, SQRT_PRICE_1_1);
    }

    function test_exit_thirdPoolCannotBeInitialized() public {
        _openExitPool(false);
        // another fee tier of the same two tokens
        PoolKey memory other = xKey;
        other.fee = 3000;
        _expectHookRevert(IHooks.beforeInitialize.selector, abi.encodeWithSelector(FeeHook.PoolNotAllowed.selector));
        vm.prank(alice);
        PM.initialize(other, SQRT_PRICE_1_1);
        // another tick spacing
        other = xKey;
        other.tickSpacing = 10;
        _expectHookRevert(IHooks.beforeInitialize.selector, abi.encodeWithSelector(FeeHook.PoolNotAllowed.selector));
        vm.prank(alice);
        PM.initialize(other, SQRT_PRICE_1_1);
        // the same pool again
        vm.expectRevert();
        vm.prank(alice);
        PM.initialize(xKey, SQRT_PRICE_1_1);
    }

    function _liquidityByAnyone(bool exitFirst) internal {
        _openExitPool(exitFirst);
        _fundCoin(alice, 5 ether);
        _fundCoin(bob, 5 ether);
        uint256 coinBefore = _coinOf(bob);
        uint256 xBefore = xt.balanceOf(bob);
        vm.prank(bob);
        lp.modify(xKey, -3000, 3000, 5e23);
        assertLt(_coinOf(bob), coinBefore);
        assertLt(xt.balanceOf(bob), xBefore);
        assertEq(w.coin.transferAllowance(), 0);
        // alice can add too
        vm.prank(alice);
        lp.modify(xKey, -600, 600, 1e22);
        assertEq(w.coin.transferAllowance(), 0);
        // bob takes his position out again, coin comes back to his wallet
        uint256 coinMid = _coinOf(bob);
        vm.prank(bob);
        lp.modify(xKey, -3000, 3000, -5e23);
        assertGt(_coinOf(bob), coinMid);
        assertEq(w.coin.transferAllowance(), 0);
        // no fee is charged on liquidity changes
        assertEq(_exitClaims(), 0);
    }

    function test_exit_liquidityAddRemoveByAnyone() public {
        _liquidityByAnyone(true);
    }

    function test_exit_liquidityAddRemoveByAnyone_otherOrder() public {
        _liquidityByAnyone(false);
    }

    function test_exit_feeBuyExactIn() public {
        _runKind(true, Kind.BuyIn, 1e21 + 12345);
    }

    function test_exit_feeBuyExactOut() public {
        _runKind(true, Kind.BuyOut, 5e20 + 7);
    }

    function test_exit_feeSellExactIn() public {
        _runKind(true, Kind.SellIn, 1e21 + 3);
    }

    function test_exit_feeSellExactOut() public {
        _runKind(true, Kind.SellOut, 4e20 + 11);
    }

    function test_exit_feeBuyExactIn_otherOrder() public {
        _runKind(false, Kind.BuyIn, 1e21 + 12345);
    }

    function test_exit_feeBuyExactOut_otherOrder() public {
        _runKind(false, Kind.BuyOut, 5e20 + 7);
    }

    function test_exit_feeSellExactIn_otherOrder() public {
        _runKind(false, Kind.SellIn, 1e21 + 3);
    }

    function test_exit_feeSellExactOut_otherOrder() public {
        _runKind(false, Kind.SellOut, 4e20 + 11);
    }

    function test_exit_claimsPaidOut() public {
        _seed(true);
        _exitFeeCase(Kind.BuyIn, 1e21);
        _exitFeeCase(Kind.SellIn, 5e20);
        uint256 claims = _exitClaims();
        uint256 owed = w.hook.creatorExitOwed();
        assertGt(claims, owed);

        uint256 creator0 = xt.balanceOf(creator);
        w.hook.claimCreator();
        assertEq(xt.balanceOf(creator) - creator0, owed, "creator is paid in exit token");
        assertEq(w.hook.creatorExitOwed(), 0);
        assertEq(_exitClaims(), claims - owed);

        vm.expectRevert(FeeHook.NothingToClaim.selector);
        w.hook.claimCreator();

        w.hook.sendExitFeesToCore();
        assertEq(xt.balanceOf(address(w.core)), claims - owed, "core got the rest");
        assertEq(w.core.exitFees(), claims - owed, "and was told about it");
        assertEq(w.core.exitFeeCalls(), 1);
        assertEq(_exitClaims(), 0);
        assertEq(xt.balanceOf(address(w.hook)), 0);

        vm.expectRevert(FeeHook.NothingToClaim.selector);
        w.hook.sendExitFeesToCore();
    }

    function test_exit_claimNeedsAnExitToken() public {
        _seed(true);
        _exitFeeCase(Kind.BuyIn, 1e21);
        w.core.setExit(PoolId.unwrap(xKey.toId()), address(0));
        vm.expectRevert(FeeHook.NoExitToken.selector);
        w.hook.claimCreator();
        vm.expectRevert(FeeHook.NoExitToken.selector);
        w.hook.sendExitFeesToCore();
    }

    function test_exit_unlockCallbackOnlyPoolManager() public {
        vm.expectRevert();
        w.hook.unlockCallback(abi.encode(Currency.wrap(address(xt)), alice, uint256(1)));
    }

    function test_exit_buyIntoSinglySidedPool() public {
        // the pool manager holds none of the exit token and the only liquidity is coin
        _openExitPool(true);
        _fundCoin(alice, 5 ether);
        _fundCoin(bob, 5 ether);
        assertEq(xt.balanceOf(address(PM)), 0);
        // exit token is currency0, coin is currency1: a range below the price holds coin only
        vm.prank(alice);
        lp.modify(xKey, -6000, -60, 1e24);
        assertEq(xt.balanceOf(address(PM)), 0);
        _exitFeeCase(Kind.BuyIn, 1e22);
        _exitFeeCase(Kind.BuyOut, 1e20);
    }

    function test_exit_buyIntoSinglySidedPool_otherOrder() public {
        _openExitPool(false);
        _fundCoin(alice, 5 ether);
        _fundCoin(bob, 5 ether);
        // coin is currency0, so a range above the price holds coin only
        vm.prank(alice);
        lp.modify(xKey, 60, 6000, 1e24);
        _exitFeeCase(Kind.BuyIn, 1e22);
        _exitFeeCase(Kind.BuyOut, 1e20);
    }

    function test_exit_coinStillRestrictedElsewhere() public {
        _seed(true);
        _exitFeeCase(Kind.BuyIn, 1e21);
        vm.prank(bob);
        vm.expectRevert(Coin.InvalidTransfer.selector);
        w.coin.transfer(alice, 1);
    }

    function testFuzz_exitFees(uint8 kindRaw, uint256 raw, bool exitFirst) public {
        Kind k = Kind(bound(kindRaw, 0, 3));
        _seed(exitFirst);
        uint256 amt;
        if (k == Kind.BuyIn) amt = bound(raw, 1, 1e23);
        else if (k == Kind.BuyOut) amt = bound(raw, 1, 1e23);
        else if (k == Kind.SellIn) amt = bound(raw, 1, 1e23);
        else amt = bound(raw, 1, 1e23);
        _exitFeeCase(k, amt);
    }
}
