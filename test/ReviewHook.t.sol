// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Test} from "forge-std/Test.sol";
import {Launcher} from "../src/Launcher.sol";
import {Coin} from "../src/Coin.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {SystemDeployer, Deployed} from "../script/Deploy.s.sol";
import {Core} from "../src/Core.sol";
import {MockExitToken} from "./mocks/MockExitToken.sol";
import {MockExitModule} from "./mocks/MockExitModule.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";

/// @notice scriptable pool manager actor for the review proofs. one unlock runs a list of ops, then refunds eth
contract Actor is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal constant PM = IPoolManager(Mainnet.POOL_MANAGER);

    enum Kind {
        SWAP,
        MODIFY,
        SETTLE,
        TAKE,
        MINT,
        BURN,
        RAW
    }

    struct Op {
        Kind kind;
        bytes data;
    }

    /// @dev claims owned by this actor can be burned. users hand claims to the actor with `PM.transfer`
    function run(Op[] memory ops) external payable returns (bytes[] memory outs) {
        uint256 before = address(this).balance - msg.value;
        outs = abi.decode(PM.unlock(abi.encode(ops)), (bytes[]));
        uint256 left = address(this).balance - before;
        if (left != 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            require(ok, "refund");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "pm");
        Op[] memory ops = abi.decode(data, (Op[]));
        bytes[] memory outs = new bytes[](ops.length);
        for (uint256 i; i < ops.length; ++i) {
            outs[i] = _exec(ops[i]);
        }
        return abi.encode(outs);
    }

    function _exec(Op memory op) internal returns (bytes memory) {
        if (op.kind == Kind.SWAP) {
            (PoolKey memory k, SwapParams memory p) = abi.decode(op.data, (PoolKey, SwapParams));
            return abi.encode(PM.swap(k, p, ""));
        }
        if (op.kind == Kind.MODIFY) {
            (PoolKey memory k, ModifyLiquidityParams memory p) = abi.decode(op.data, (PoolKey, ModifyLiquidityParams));
            (BalanceDelta d,) = PM.modifyLiquidity(k, p, "");
            return abi.encode(d);
        }
        if (op.kind == Kind.SETTLE) {
            // pays what the actor owes in a currency, from `payer`'s erc20 balance or from the actor's eth
            (Currency c, address payer) = abi.decode(op.data, (Currency, address));
            int256 d = PM.currencyDelta(address(this), c);
            if (d >= 0) return "";
            uint256 owed = uint256(-d);
            if (Currency.unwrap(c) == address(0)) {
                PM.settle{value: owed}();
            } else {
                PM.sync(c);
                ERC20(Currency.unwrap(c)).transferFrom(payer, address(PM), owed);
                PM.settle();
            }
            return abi.encode(owed);
        }
        return _exec2(op);
    }

    function _exec2(Op memory op) internal returns (bytes memory) {
        if (op.kind == Kind.TAKE) {
            (Currency c, address to) = abi.decode(op.data, (Currency, address));
            int256 d = PM.currencyDelta(address(this), c);
            if (d <= 0) return "";
            PM.take(c, to, uint256(d));
            return abi.encode(uint256(d));
        }
        if (op.kind == Kind.MINT) {
            (Currency c, address to) = abi.decode(op.data, (Currency, address));
            int256 d = PM.currencyDelta(address(this), c);
            if (d <= 0) return "";
            PM.mint(to, c.toId(), uint256(d));
            return abi.encode(uint256(d));
        }
        if (op.kind == Kind.BURN) {
            (Currency c, address from, uint256 amount) = abi.decode(op.data, (Currency, address, uint256));
            PM.burn(from, c.toId(), amount);
            return "";
        }
        (address target, bytes memory cd) = abi.decode(op.data, (address, bytes));
        (bool ok, bytes memory ret) = target.call(cd);
        require(ok, "raw");
        return ret;
    }

    receive() external payable {}
}

/// @notice shared helpers for the proofs. every proof starts from the real system on the fork
abstract contract ReviewBase is Fixture {
    using StateLibrary for IPoolManager;

    Actor internal actor;
    address internal mallory;
    address internal carol;

    function setUp() public virtual override {
        super.setUp();
        actor = new Actor();
        mallory = _user("mallory");
        carol = _user("carol");
    }

    function _op(Actor.Kind k, bytes memory data) internal pure returns (Actor.Op memory) {
        return Actor.Op({kind: k, data: data});
    }

    function _raw(address target, bytes memory cd) internal pure returns (Actor.Op memory) {
        return _op(Actor.Kind.RAW, abi.encode(target, cd));
    }

    function _expectHookRevert(bytes4 hookSelector, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookSelector,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _coinCur() internal view returns (Currency) {
        return Currency.wrap(address(coin));
    }

    /// @dev two ops that add then remove `liq` liquidity in `key`. nothing is paid or received
    function _addRemove(PoolKey memory key, uint256 liq) internal pure returns (Actor.Op[] memory ops) {
        ops = new Actor.Op[](2);
        ops[0] = _op(
            Actor.Kind.MODIFY,
            abi.encode(
                key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: int256(liq), salt: 0})
            )
        );
        ops[1] = _op(
            Actor.Kind.MODIFY,
            abi.encode(
                key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -int256(liq), salt: 0})
            )
        );
    }

    function _concat(Actor.Op[] memory a, Actor.Op[] memory b) internal pure returns (Actor.Op[] memory c) {
        c = new Actor.Op[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            c[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            c[a.length + i] = b[i];
        }
    }

    function _settleBoth(PoolKey memory key, address payer) internal pure returns (Actor.Op[] memory ops) {
        ops = new Actor.Op[](2);
        ops[0] = _op(Actor.Kind.SETTLE, abi.encode(key.currency0, payer));
        ops[1] = _op(Actor.Kind.SETTLE, abi.encode(key.currency1, payer));
    }

    /// @dev a hookless eth/coin pool at the launch pool price with eth only liquidity above it, so coin can be sold
    function _openHooklessPool() internal returns (PoolKey memory hk) {
        hk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: _coinCur(),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        (uint160 sqrtP, int24 tick,,) = StateLibrary.getSlot0(PM, PoolId.wrap(launchId()));
        PM.initialize(hk, sqrtP);
        int24 lo = (tick / 10) * 10 + 10;
        int24 hi = lo + 6000;
        address lper = _user("sideLp");
        vm.deal(lper, 300 ether);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), 100 ether
        );
        vm.prank(lper);
        lp.modify{value: 250 ether}(hk, lo, hi, int256(uint256(liq)));
    }

    function launchId() internal view returns (bytes32 id) {
        id = keccak256(abi.encode(launchKey));
    }

    /// @dev ops that move `amt` coin from a wallet to `to` through the pool manager: pay in, take out
    function _pmTransfer(address from, address to, uint256 amt) internal view returns (Actor.Op[] memory ops) {
        ops = new Actor.Op[](4);
        ops[0] = _raw(Mainnet.POOL_MANAGER, abi.encodeCall(IPoolManager.sync, (_coinCur())));
        ops[1] = _raw(address(coin), abi.encodeCall(ERC20.transferFrom, (from, Mainnet.POOL_MANAGER, amt)));
        ops[2] = _raw(Mainnet.POOL_MANAGER, abi.encodeCall(IPoolManager.settle, ()));
        ops[3] = _op(Actor.Kind.TAKE, abi.encode(_coinCur(), to));
    }
}

contract ReviewFreeGrantTest is ReviewBase {
    /// H1 regression: adding then removing exit pool liquidity in one unlock used to mint unlimited transient coin
    /// allowance. the signed counter nets the two legs, so the grant is a few wei of rounding at most and the pool
    /// manager can no longer move coin wallet to wallet
    function test_FIXED_freeAllowanceMakesCoinTransferable() public {
        _enterPhase2();
        uint256 bal = _buyCoin(mallory, 10 ether);
        vm.prank(mallory);
        coin.approve(address(actor), type(uint256).max);

        // plain wallet to wallet transfer is blocked, as designed
        vm.prank(mallory);
        vm.expectRevert();
        coin.transfer(carol, 1);

        // add then remove, then push the whole balance through the pool manager. the pay in leg is not covered
        xt.mint(mallory, 100);
        vm.prank(mallory);
        xt.approve(address(actor), type(uint256).max);
        Actor.Op[] memory ops = _concat(_addRemove(xKey, 1e30), _pmTransfer(mallory, carol, bal - 10));
        ops = _concat(ops, _settleBoth(xKey, mallory));
        vm.prank(mallory);
        vm.expectRevert();
        actor.run(ops);

        assertEq(coin.balanceOf(carol), 0, "carol got nothing");
        assertEq(coin.balanceOf(mallory), bal, "mallory still holds everything");
        assertEq(_hookClaims(), 0);
    }

    /// H1 regression: the counter after an add and a remove of the same size is zero up to rounding dust, and never
    /// positive, so no coin can be taken out of the pool manager on it
    function test_FIXED_addThenRemoveNetsToZero() public {
        _enterPhase2();
        _buyCoin(mallory, 10 ether);
        vm.prank(mallory);
        coin.approve(address(actor), type(uint256).max);
        xt.mint(mallory, 100);
        vm.prank(mallory);
        xt.approve(address(actor), type(uint256).max);

        Actor.Op[] memory ops = _addRemove(xKey, 1e30);
        Actor.Op[] memory read = new Actor.Op[](1);
        read[0] = _raw(address(coin), abi.encodeCall(Coin.pendingDelta, ()));
        ops = _concat(ops, read);
        ops = _concat(ops, _settleBoth(xKey, mallory));
        vm.prank(mallory);
        bytes[] memory outs = actor.run(ops);
        int256 d = abi.decode(outs[2], (int256));
        assertLe(d, 0, "never owed out");
        assertGe(d, -4, "only rounding dust is left");
    }

    /// H1 regression: the free hookless sale no longer works, the sale leg cannot be paid in
    function test_FIXED_freeAllowanceSellsInHooklessPool() public {
        _enterPhase2();
        uint256 bal = _buyCoin(mallory, 20 ether);
        PoolKey memory hk = _openHooklessPool();

        vm.prank(mallory);
        coin.approve(address(actor), type(uint256).max);
        xt.mint(mallory, 100);
        vm.prank(mallory);
        xt.approve(address(actor), type(uint256).max);

        Actor.Op[] memory ops = _addRemove(xKey, 1e30);
        Actor.Op[] memory sw = new Actor.Op[](1);
        sw[0] = _op(
            Actor.Kind.SWAP,
            abi.encode(
                hk,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(bal - 10),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                })
            )
        );
        ops = _concat(ops, sw);
        Actor.Op[] memory settle = new Actor.Op[](5);
        settle[0] = _op(Actor.Kind.SETTLE, abi.encode(_coinCur(), mallory));
        settle[1] = _op(Actor.Kind.TAKE, abi.encode(Currency.wrap(address(0)), mallory));
        settle[2] = _op(Actor.Kind.SETTLE, abi.encode(xKey.currency0, mallory));
        settle[3] = _op(Actor.Kind.SETTLE, abi.encode(xKey.currency1, mallory));
        settle[4] = _op(Actor.Kind.SETTLE, abi.encode(_coinCur(), mallory));
        ops = _concat(ops, settle);

        uint256 ethBefore = mallory.balance;
        vm.prank(mallory);
        vm.expectRevert();
        actor.run(ops);
        assertEq(mallory.balance, ethBefore, "nothing was sold");
        assertEq(coin.balanceOf(mallory), bal, "the bag is still there");
    }
}

contract ReviewSideMarketTest is ReviewBase {
    IERC6909Claims internal constant CL = IERC6909Claims(Mainnet.POOL_MANAGER);

    function _swapOp(PoolKey memory k, bool z, int256 amt) internal pure returns (Actor.Op memory) {
        return _op(
            Actor.Kind.SWAP,
            abi.encode(
                k,
                SwapParams({
                    zeroForOne: z,
                    amountSpecified: amt,
                    sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                })
            )
        );
    }

    /// @dev forge runs a whole test as one transaction, so the transient delta of an earlier step would still be
    /// there. this moves the leftover through the pool manager, which is what the end of a real transaction does
    function _endTransaction() internal {
        int256 d = coin.pendingDelta();
        if (d == 0) return;
        if (d > 0) {
            vm.prank(Mainnet.POOL_MANAGER);
            coin.transfer(carol, uint256(d));
        } else {
            deal(address(coin), carol, uint256(-d));
            vm.prank(carol);
            coin.transfer(Mainnet.POOL_MANAGER, uint256(-d));
        }
        assertEq(coin.pendingDelta(), 0);
    }

    function _claims(address who) internal view returns (uint256) {
        return CL.balanceOf(who, uint256(uint160(address(coin))));
    }

    /// F4 quantified: coin held as pool manager claims trades in a hookless pool with no hook fee. entry costs the
    /// 10 percent once, every later cycle and the exit to eth cost nothing to the protocol
    function test_POC_claimsSideMarketEndToEnd() public {
        address bob = _user("bob");
        vm.deal(mallory, 100 ether);
        vm.deal(bob, 100 ether);

        // 1. entry: mallory buys 20 eth of coin in the launch pool and keeps it as claims. the hook takes its fee
        Actor.Op[] memory ops = new Actor.Op[](3);
        ops[0] = _swapOp(launchKey, true, -20 ether);
        ops[1] = _op(Actor.Kind.SETTLE, abi.encode(Currency.wrap(address(0)), mallory));
        ops[2] = _op(Actor.Kind.MINT, abi.encode(_coinCur(), mallory));
        uint256 potBefore = core.ethPot();
        vm.prank(mallory);
        actor.run{value: 20 ether}(ops);
        uint256 entryFee = core.ethPot() - potBefore;
        uint256 bag = _claims(mallory);
        assertEq(coin.balanceOf(mallory), 0, "no erc20 ever moved");
        assertGt(bag, 0);

        // 2. claims move wallet to wallet with a plain erc6909 transfer
        vm.prank(mallory);
        CL.transfer(bob, uint256(uint160(address(coin))), bag);
        assertEq(_claims(bob), bag);

        // 3. a hookless eth/coin pool trades the claims. bob sells to it, buys back, sells again, five cycles
        PoolKey memory hk = _openHooklessPool();
        vm.prank(bob);
        IPoolManager(Mainnet.POOL_MANAGER).setOperator(address(actor), true);
        uint256 volume;
        for (uint256 i; i < 5; ++i) {
            uint256 have = _claims(bob);
            Actor.Op[] memory s = new Actor.Op[](4);
            s[0] = _op(Actor.Kind.BURN, abi.encode(_coinCur(), bob, have));
            s[1] = _swapOp(hk, false, -int256(have));
            s[2] = _op(Actor.Kind.TAKE, abi.encode(Currency.wrap(address(0)), bob));
            s[3] = _op(Actor.Kind.MINT, abi.encode(_coinCur(), bob));
            uint256 e0 = bob.balance;
            vm.prank(bob);
            actor.run(s);
            volume += bob.balance - e0;
            // buy it all back with the eth, as claims again
            Actor.Op[] memory b = new Actor.Op[](3);
            b[0] = _swapOp(hk, true, -int256(bob.balance - e0 > 0 ? bob.balance - e0 : 0));
            b[1] = _op(Actor.Kind.SETTLE, abi.encode(Currency.wrap(address(0)), bob));
            b[2] = _op(Actor.Kind.MINT, abi.encode(_coinCur(), bob));
            vm.prank(bob);
            actor.run{value: bob.balance - e0}(b);
        }
        emit log_named_decimal_uint("fee paid to the protocol at entry", entryFee, 18);
        emit log_named_decimal_uint("eth volume sold in the side pool", volume, 18);
        assertEq(core.ethPot(), potBefore + entryFee, "five cycles added no fee");
        assertGt(volume, 5 * 10 ether);
    }

    /// F4 exit: claims cannot become erc20 coin without a hook grant, and a grant costs a hooked swap, so leaving
    /// the side market to a wallet pays the 10 percent again. leaving to eth through a hookless pool is free
    function test_POC_claimsExitToErc20NeedsAHookedSwap() public {
        vm.deal(mallory, 100 ether);
        Actor.Op[] memory ops = new Actor.Op[](3);
        ops[0] = _swapOp(launchKey, true, -2 ether);
        ops[1] = _op(Actor.Kind.SETTLE, abi.encode(Currency.wrap(address(0)), mallory));
        ops[2] = _op(Actor.Kind.MINT, abi.encode(_coinCur(), mallory));
        vm.prank(mallory);
        actor.run{value: 2 ether}(ops);
        uint256 bag = _claims(mallory);
        _endTransaction();
        vm.prank(mallory);
        IPoolManager(Mainnet.POOL_MANAGER).setOperator(address(actor), true);

        // burn claims and take the erc20 with no grant: the coin refuses
        Actor.Op[] memory t = new Actor.Op[](2);
        t[0] = _op(Actor.Kind.BURN, abi.encode(_coinCur(), mallory, bag));
        t[1] = _op(Actor.Kind.TAKE, abi.encode(_coinCur(), mallory));
        vm.prank(mallory);
        vm.expectRevert();
        actor.run(t);

        // the same, with a hooked buy of the same size in the same unlock providing the grant. fee is 10 percent
        Actor.Op[] memory g = new Actor.Op[](5);
        g[0] = _swapOp(launchKey, true, -5 ether);
        g[1] = _op(Actor.Kind.SETTLE, abi.encode(Currency.wrap(address(0)), mallory));
        g[2] = _op(Actor.Kind.MINT, abi.encode(_coinCur(), mallory));
        g[3] = _op(Actor.Kind.BURN, abi.encode(_coinCur(), mallory, bag));
        g[4] = _op(Actor.Kind.TAKE, abi.encode(_coinCur(), mallory));
        uint256 potBefore = core.ethPot();
        vm.prank(mallory);
        actor.run{value: 5 ether}(g);
        assertEq(coin.balanceOf(mallory), bag, "the whole bag left as erc20");
        assertGt(_claims(mallory), 0, "and she still holds the claims the grant swap bought");
        assertEq(core.ethPot() - potBefore, 0.475 ether, "the grant cost one more 10 percent fee on a 5 eth buy");
    }
}

contract ReviewFeeTest is ReviewBase {
    function _swapLimit(PoolKey memory k, bool z, int256 amt, uint160 limit) internal pure returns (Actor.Op memory) {
        return _op(
            Actor.Kind.SWAP, abi.encode(k, SwapParams({zeroForOne: z, amountSpecified: amt, sqrtPriceLimitX96: limit}))
        );
    }

    /// H2 regression: an exact in buy with a price limit that would fill only a sliver used to pay 10 percent of the
    /// whole offered amount. the hook now reverts a partial fill when it took the fee in beforeSwap
    function test_FIXED_partialFillRevertsInsteadOfPayingFeeOnTheUnfilledAmount() public {
        vm.deal(mallory, 20 ether);
        _buyCoin(funder, 1 ether);
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(PM, PoolId.wrap(launchId()));
        uint160 limit = uint160(uint256(sqrtP) * 9990 / 10_000);

        Actor.Op[] memory ops = new Actor.Op[](3);
        ops[0] = _swapLimit(launchKey, true, -10 ether, limit);
        ops[1] = _op(Actor.Kind.SETTLE, abi.encode(Currency.wrap(address(0)), mallory));
        ops[2] = _op(Actor.Kind.TAKE, abi.encode(_coinCur(), mallory));

        uint256 potBefore = core.ethPot();
        uint256 ethBefore = mallory.balance;
        vm.prank(mallory);
        _expectHookRevert(IHooks.afterSwap.selector, abi.encodePacked(FeeHook.PartialFill.selector));
        actor.run{value: 10 ether}(ops);
        assertEq(core.ethPot(), potBefore, "no fee was booked");
        assertEq(mallory.balance, ethBefore, "nothing was paid");

        // the same swap with a limit it can reach in full still goes through and pays exactly 10 percent
        ops[0] = _swapLimit(launchKey, true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.prank(mallory);
        actor.run{value: 1 ether}(ops);
        assertEq(core.ethPot() - potBefore, 0.095 ether, "core share of a 1 eth buy");
    }

    /// H2 regression, the exact out sell: the pool pays the wanted amount plus the fee in eth, and a limit that
    /// stops it early reverts as well
    function test_FIXED_partialFillOnExactOutSellReverts() public {
        uint256 bal = _buyCoin(mallory, 10 ether);
        vm.prank(mallory);
        coin.approve(address(actor), type(uint256).max);
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(PM, PoolId.wrap(launchId()));
        uint160 limit = uint160(uint256(sqrtP) * 10_010 / 10_000);

        Actor.Op[] memory ops = new Actor.Op[](3);
        ops[0] = _swapLimit(launchKey, false, int256(5 ether), limit);
        ops[1] = _op(Actor.Kind.SETTLE, abi.encode(_coinCur(), mallory));
        ops[2] = _op(Actor.Kind.TAKE, abi.encode(Currency.wrap(address(0)), mallory));
        vm.prank(mallory);
        _expectHookRevert(IHooks.afterSwap.selector, abi.encodePacked(FeeHook.PartialFill.selector));
        actor.run(ops);
        assertEq(coin.balanceOf(mallory), bal, "nothing moved");
    }

    /// H9 regression: in phase 1 a buy and an exact sell of the same coin in one unlock net to zero coin and now
    /// leave no allowance behind. it still costs both fees, about 19 percent of the notional
    function test_FIXED_roundTripLeavesNoAllowanceAndCostsBothFees() public {
        vm.deal(mallory, 50 ether);
        _buyCoin(funder, 1 ether);
        uint256 snap = vm.snapshotState();
        uint256 x = _buyCoin(carol, 10 ether);
        vm.revertToState(snap);

        Actor.Op[] memory ops = new Actor.Op[](3);
        ops[0] = _swapLimit(launchKey, true, -10 ether, TickMath.MIN_SQRT_PRICE + 1);
        ops[1] = _swapLimit(launchKey, false, -int256(x), TickMath.MAX_SQRT_PRICE - 1);
        ops[2] = _op(Actor.Kind.SETTLE, abi.encode(Currency.wrap(address(0)), mallory));
        uint256 potBefore = core.ethPot();
        uint256 creatorBefore = creator.balance;
        vm.prank(mallory);
        actor.run{value: 10 ether}(ops);

        uint256 fees = (core.ethPot() - potBefore) + (creator.balance - creatorBefore);
        emit log_named_decimal_uint("fees paid for the round trip on 10 eth", fees, 18);
        assertApproxEqAbs(coin.pendingDelta(), 0, 2, "the round trip nets to zero, no allowance is left");
        assertGt(fees, 1.85 ether, "both fees were paid");
    }
}

contract ReviewBuybackTest is ReviewBase {
    using stdStorage for StdStorage;

    /// @dev a sane limit: about 10 percent from the 1 to 1 start in the direction the core sells, 1000 ticks
    function _bandLimit() internal view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(address(xt) < address(coin) ? int24(-1000) : int24(1000));
    }

    /// @dev phase 2 as the owner sets it, but with no liquidity in the exit pool, and an exit pool nobody has seeded
    function _phase2Bare() internal {
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
        core.queue(Core.Action.SetExitPoolKey, abi.encode(xKey, _bandLimit()));
        vm.warp(block.timestamp + 7 days);
        core.execute(Core.Action.SetExitModule, abi.encode(address(mod)));
        core.execute(Core.Action.SetExitPoolKey, abi.encode(xKey, _bandLimit()));
        vm.stopPrank();
        PM.initialize(xKey, SQRT_PRICE_1_1);
        inPhase2 = true;
    }

    /// @dev books `amount` exit token as the buyback pot, as exits of eth lane statements do
    function _giveBuybackPot(uint256 amount) internal {
        xt.mint(address(core), amount);
        stdstore.target(address(core)).sig("xToBuyback()").checked_write(amount);
    }

    function _sliceOf() internal pure returns (uint256) {
        return 20 * 4_330_000 * UNIT;
    }

    /// @dev a position of coin only, priced far above the market for the coin, in the direction the core buys into
    function _hostileRange(uint256 coinAmt) internal view returns (int24 lo, int24 hi, uint128 liq) {
        bool coin0 = address(coin) < address(xt);
        // coin as token0 sits above the 1 to 1 price, coin as token1 below it. 1e6 exit token per coin
        (lo, hi) = coin0 ? (int24(138_000), int24(138_600)) : (int24(-138_600), int24(-138_000));
        uint160 a = TickMath.getSqrtPriceAtTick(lo);
        uint160 b = TickMath.getSqrtPriceAtTick(hi);
        liq = coin0
            ? LiquidityAmounts.getLiquidityForAmount0(a, b, coinAmt)
            : LiquidityAmounts.getLiquidityForAmount1(a, b, coinAmt);
    }

    function _modifyOp(int24 lo, int24 hi, int256 liq) internal view returns (Actor.Op memory) {
        return _op(
            Actor.Kind.MODIFY,
            abi.encode(xKey, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: liq, salt: 0}))
        );
    }

    function _addHostile(int24 lo, int24 hi, uint128 liq) internal {
        Actor.Op[] memory add = new Actor.Op[](3);
        add[0] = _modifyOp(lo, hi, int256(uint256(liq)));
        add[1] = _op(Actor.Kind.SETTLE, abi.encode(_coinCur(), mallory));
        add[2] = _op(Actor.Kind.SETTLE, abi.encode(Currency.wrap(address(xt)), mallory));
        vm.prank(mallory);
        actor.run(add);
    }

    function _approveActor() internal {
        vm.startPrank(mallory);
        coin.approve(address(actor), type(uint256).max);
        xt.approve(address(actor), type(uint256).max);
        vm.stopPrank();
    }

    /// H3 regression: a hostile provider places a sliver of coin at an absurd price far beyond the fixed limit. the
    /// swap stops at the limit before it reaches that range, buys nothing, and the call reverts. nothing is booked
    function test_FIXED_buybackExitHostileLiquidityBeyondTheLimitBuysNothing() public {
        _phase2Bare();
        _buyCoin(mallory, 0.01 ether);
        _approveActor();
        uint256 slice = _sliceOf();
        _giveBuybackPot(slice * 4);
        vm.roll(block.number + 100);
        (int24 lo, int24 hi, uint128 liq) = _hostileRange(2e12);
        _addHostile(lo, hi, liq);

        uint256 coreX = xt.balanceOf(address(core));
        vm.prank(mallory);
        vm.expectRevert(Core.NothingBought.selector);
        core.buybackExit();
        assertEq(xt.balanceOf(address(core)), coreX, "the core kept everything");
        assertEq(core.xToBuyback(), slice * 4, "the buyback pot is whole");
        assertEq(_hookClaims(), 0, "no fee was paid for nothing");
    }

    /// H3 regression: the same dust provider moves inside the band. the swap stops at the limit, so the core can
    /// only spend what that dust range can absorb, the rest of the slice returns to the buyback pot, and the
    /// pot is fully booked
    function test_FIXED_buybackExitHostileLiquidityInsideTheBandIsBounded() public {
        _phase2Bare();
        _buyCoin(mallory, 0.01 ether);
        _approveActor();
        uint256 slice = _sliceOf();
        _giveBuybackPot(slice * 4);
        vm.roll(block.number + 100);
        bool coin0 = address(coin) < address(xt);
        (int24 lo, int24 hi) = coin0 ? (int24(720), int24(780)) : (int24(-780), int24(-720));
        uint160 a = TickMath.getSqrtPriceAtTick(lo);
        uint160 b = TickMath.getSqrtPriceAtTick(hi);
        uint128 liq = coin0
            ? LiquidityAmounts.getLiquidityForAmount0(a, b, 2e12)
            : LiquidityAmounts.getLiquidityForAmount1(a, b, 2e12);
        _addHostile(lo, hi, liq);

        uint256 xBefore = xt.balanceOf(mallory);
        uint256 deadBefore = coin.balanceOf(DEAD);
        vm.prank(carol);
        core.buybackExit();
        uint256 burned = coin.balanceOf(DEAD) - deadBefore;
        assertGt(burned, 0, "the dust range was bought");
        assertLe(burned, 2e12, "no more than the dust the range held");
        assertLt(slice * 4 - core.xToBuyback(), 1e14, "only dust worth of exit token left the pot");
        assertEq(xt.balanceOf(address(core)), core.xPot() + core.xToBuyback(), "nothing is left unbooked");

        Actor.Op[] memory rm = new Actor.Op[](3);
        rm[0] = _modifyOp(lo, hi, -int256(uint256(liq)));
        rm[1] = _op(Actor.Kind.TAKE, abi.encode(Currency.wrap(address(xt)), mallory));
        rm[2] = _op(Actor.Kind.TAKE, abi.encode(_coinCur(), mallory));
        vm.prank(mallory);
        actor.run(rm);
        assertLt(xt.balanceOf(mallory) - xBefore, 1e14, "the attacker took dust, not the slice");
    }

    /// H4 regression: the first public buyback in an exit pool nobody has seeded reverts, books nothing, and pays
    /// no fee and no tip
    function test_FIXED_buybackExitIntoEmptyPoolRevertsAndBooksNothing() public {
        _phase2Bare();
        uint256 slice = _sliceOf();
        _giveBuybackPot(slice);
        vm.roll(block.number + 100);
        uint256 coreXBefore = xt.balanceOf(address(core));
        (uint160 priceBefore,,,) = StateLibrary.getSlot0(PM, PoolId.wrap(core.exitPoolId()));
        vm.prank(mallory);
        vm.expectRevert(Core.NothingBought.selector);
        core.buybackExit();
        assertEq(xt.balanceOf(address(core)), coreXBefore);
        assertEq(core.xToBuyback(), slice);
        assertEq(xt.balanceOf(mallory), 0, "no tip");
        assertEq(_hookClaims(), 0, "no fee");
        (uint160 priceAfter,,,) = StateLibrary.getSlot0(PM, PoolId.wrap(core.exitPoolId()));
        assertEq(priceAfter, priceBefore, "and the price did not move");
    }

    /// F8: an exit pool with no liquidity has a price anyone can set for free. a one wei exact out swap with a price
    /// limit moves it anywhere at no cost (an exact in swap in the fee currency now reverts as a partial fill), so the
    /// price at first liquidity is whatever the last griefer chose
    function test_POC_emptyExitPoolPriceIsFreeToMove() public {
        _phase2Bare();
        (uint160 before_,,,) = StateLibrary.getSlot0(PM, PoolId.wrap(core.exitPoolId()));
        bool coin0 = address(coin) < address(xt);
        // push the price to a tick near the top (coin as token0 gets pricey) or bottom
        uint160 target = TickMath.getSqrtPriceAtTick(coin0 ? int24(600_000) : int24(-600_000));
        Actor.Op[] memory ops = new Actor.Op[](1);
        ops[0] = _op(
            Actor.Kind.SWAP,
            abi.encode(xKey, SwapParams({zeroForOne: !coin0, amountSpecified: 1, sqrtPriceLimitX96: target}))
        );
        vm.prank(mallory);
        actor.run(ops);
        (uint160 after_,,,) = StateLibrary.getSlot0(PM, PoolId.wrap(core.exitPoolId()));
        assertTrue(after_ != before_, "price moved");
        assertEq(after_, target, "to exactly the attacker's chosen price, for a swap of one wei");
        assertEq(_hookClaims(), 0, "and no fee was due");
    }

    function _shape(address a0, address a1, uint24 lpFee, int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(a0), Currency.wrap(a1), lpFee, spacing, IHooks(address(hook)));
    }

    /// H5 regression: a key the pool manager can never initialize is rejected when the owner action executes, so it
    /// cannot lock the exit pool. the same holds for a static lp fee and for a limit outside the price bounds
    function test_FIXED_unusableExitKeyIsRejected() public {
        xt = new MockExitToken("Exit Token", "XT");
        mod = new MockExitModule(address(xt), UNIT);
        (address a0, address a1) =
            address(xt) < address(coin) ? (address(xt), address(coin)) : (address(coin), address(xt));
        PoolKey memory bad = _shape(a0, a1, 0, 0);
        PoolKey memory fee = _shape(a0, a1, 3000, 60);
        PoolKey memory good = _shape(a0, a1, 0, 60);
        uint160 lim = _bandLimit();

        vm.startPrank(owner);
        core.queue(Core.Action.SetExitModule, abi.encode(address(mod)));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(bad, lim));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(fee, lim));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(good, uint160(TickMath.MIN_SQRT_PRICE)));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(good, uint160(TickMath.MAX_SQRT_PRICE)));
        core.queue(Core.Action.SetExitPoolKey, abi.encode(good, lim));
        vm.warp(block.timestamp + 7 days);
        core.execute(Core.Action.SetExitModule, abi.encode(address(mod)));
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(bad, lim));
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(fee, lim));
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(good, uint160(TickMath.MIN_SQRT_PRICE)));
        vm.expectRevert(Core.BadKey.selector);
        core.execute(Core.Action.SetExitPoolKey, abi.encode(good, uint160(TickMath.MAX_SQRT_PRICE)));
        assertEq(core.exitPoolId(), bytes32(0), "nothing was locked in");
        core.execute(Core.Action.SetExitPoolKey, abi.encode(good, lim));
        vm.stopPrank();
        assertTrue(core.exitPoolId() != bytes32(0));
        assertEq(core.exitSqrtPriceLimit(), lim);
        PM.initialize(good, SQRT_PRICE_1_1);
    }

    /// the weakness of a static limit: anyone can move an empty or thin exit pool past it at no cost, and the
    /// buyback then reverts until the price comes back. the unspent pot is untouched
    function test_limit_pricePushedBeyondTheLimitStallsTheBuyback() public {
        _phase2Bare();
        _giveBuybackPot(_sliceOf());
        vm.roll(block.number + 100);
        bool coin0 = address(coin) < address(xt);
        // the push goes the direction the core sells in, to five times past the limit
        Actor.Op[] memory ops = new Actor.Op[](1);
        ops[0] = _op(
            Actor.Kind.SWAP,
            abi.encode(
                xKey,
                SwapParams({
                    zeroForOne: !coin0,
                    amountSpecified: 1,
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(coin0 ? int24(5000) : int24(-5000))
                })
            )
        );
        vm.prank(mallory);
        actor.run(ops);
        vm.expectRevert(Core.PriceBeyondLimit.selector);
        core.buybackExit();
        assertEq(core.xToBuyback(), _sliceOf(), "the pot waits");
    }
}

/// @notice deploy script behavior under a front run of the create2 step
contract ReviewDeployTest is Test, SystemDeployer {
    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
    }

    /// H6 regression: anyone who knows the predicted addresses can deploy the same hook initcode with the same salt
    /// first. the hook that lands is identical, and the deploy routine now treats it as done and goes on to launch
    function test_FIXED_create2FrontRunNoLongerAbortsTheDeploy() public {
        address dep = makeAddr("review.deployer.77");
        address owner = makeAddr("review.owner.77");
        address creator = makeAddr("review.creator.77");
        uint64 n = vm.getNonce(dep);
        address launcher = vm.computeCreateAddress(dep, n);
        address core = vm.computeCreateAddress(dep, n + 1);
        address coin = vm.computeCreateAddress(dep, n + 2);
        (address hook, bytes32 salt) = mineHook(coin, core, creator, launcher);

        // the attacker front runs with the public initcode and the public salt
        address got = create2Hook(salt, coin, core, creator, launcher);
        assertEq(got, hook, "the same hook lands at the predicted address");

        vm.startPrank(dep);
        Deployed memory d = deploySystemWithSalt(dep, owner, creator, "Review Coin", "RVW", hook, salt);
        vm.stopPrank();
        assertEq(d.hook, hook);
        assertTrue(Launcher(d.launcher).launched(), "the launch step ran");
        assertEq(Coin(d.coin).balanceOf(d.launcher), 0, "the supply left the launcher");
    }
}

/// @notice attacks that were tried and held
contract ReviewHeldTest is ReviewBase {
    function test_held_initializeBeforeTheHookHasCode() public {
        address ghost = address(uint160(HOOK_FLAGS) | (uint160(0xBEEF) << 20));
        assertEq(ghost.code.length, 0);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)), currency1: _coinCur(), fee: 0, tickSpacing: 60, hooks: IHooks(ghost)
        });
        vm.expectRevert();
        PM.initialize(k, SQRT_PRICE_1_1);
    }

    function test_held_hookUnlockCallbackRejectsEveryoneButPoolManager() public {
        vm.prank(mallory);
        vm.expectRevert();
        hook.unlockCallback(abi.encode(_coinCur(), mallory, uint256(1)));
    }

    function test_held_zeroAndSelfTransfersStayBlocked() public {
        _buyCoin(mallory, 1 ether);
        vm.startPrank(mallory);
        vm.expectRevert();
        coin.transfer(carol, 0);
        vm.expectRevert();
        coin.transfer(mallory, 1);
        vm.stopPrank();
    }

    function test_held_launchPoolRejectsLiquidityAndPokes() public {
        vm.deal(mallory, 1 ether);
        vm.startPrank(mallory);
        vm.expectRevert();
        lp.modify{value: 1 ether}(launchKey, -60, 60, 1e18);
        vm.expectRevert();
        lp.modify(launchKey, -887_220, 175_020, 0);
        vm.stopPrank();
    }

    function test_held_noPermit2ShortcutAndNoGrantFromOutsiders() public {
        assertEq(coin.allowance(mallory, Mainnet.PERMIT2), 0);
        vm.prank(mallory);
        vm.expectRevert();
        coin.noteDelta(1);
    }
}
