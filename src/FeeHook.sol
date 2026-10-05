// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ICoin, ICoreFees, ILauncher, Mainnet} from "./interfaces/Interfaces.sol";

/// @notice the swap fee hook. serves the coin/eth launch pool and, once the core names it, one coin/exitToken pool.
/// @dev the fee is always taken in the non coin currency of the pool, as a share of the swap notional measured in
/// that currency. the coin never touches the hook. every swap and liquidity change grants the coin exactly the
/// transient allowance the pool manager needs to move the coin legs of that action, and nothing more.
contract FeeHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice swap fee in basis points of the notional
    uint256 public constant FEE_BPS = 1000;
    /// @notice the creator's share of the notional in basis points. the core gets the rest of the fee
    uint256 public constant CREATOR_BPS = 50;

    uint256 private constant BPS = 10_000;
    uint24 private constant LAUNCH_FEE = 0;
    int24 private constant LAUNCH_TICK_SPACING = 60;
    /// @dev gas given to the creator on eth payouts. anything it cannot take is force sent
    uint256 private constant CREATOR_GAS_STIPEND = 30_000;

    /// @notice the coin this hook serves
    address public immutable coin;
    /// @notice the core, receiver of fees and source of the exit pool id
    address public immutable core;
    /// @notice receives the creator share of every fee
    address public immutable creator;
    /// @notice the launcher whose launching flag gates the launch pool
    address public immutable launcher;
    /// @notice id of the coin/eth launch pool
    bytes32 public immutable launchPoolId;

    /// @notice exit token fee claims owed to the creator. the core share is the rest of the hook's claim balance
    uint256 public creatorExitOwed;

    /// @notice a fee was taken from a swap
    /// @param poolId the pool the swap ran in
    /// @param currency the fee currency, zero for eth
    /// @param creatorCut the creator share
    /// @param coreCut the core share
    event FeesTaken(bytes32 indexed poolId, address indexed currency, uint256 creatorCut, uint256 coreCut);
    /// @notice the creator claimed exit token fees
    event CreatorClaimed(uint256 amount);
    /// @notice exit token fees were sent to the core
    event ExitFeesSent(uint256 amount);

    /// @notice the pool is not served by this hook
    error PoolNotAllowed();
    /// @notice the launch pool only changes while the launcher is launching
    error NotLaunching();
    /// @notice the launch pool liquidity can never be removed
    error LaunchPoolLocked();
    /// @notice the exit pool has no coin leg
    error NotACoinPool();
    /// @notice a constructor address was zero
    error ZeroAddress();
    /// @notice nothing to pay out
    error NothingToClaim();
    /// @notice the core has no exitToken yet
    error NoExitToken();

    /// @param coin_ the coin
    /// @param core_ the core
    /// @param creator_ the creator payout address
    /// @param launcher_ the launcher
    constructor(address coin_, address core_, address creator_, address launcher_)
        BaseHook(IPoolManager(Mainnet.POOL_MANAGER))
    {
        if (coin_ == address(0) || core_ == address(0) || creator_ == address(0) || launcher_ == address(0)) {
            revert ZeroAddress();
        }
        coin = coin_;
        core = core_;
        creator = creator_;
        launcher = launcher_;
        launchPoolId = PoolId.unwrap(
            PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(coin_),
                    fee: LAUNCH_FEE,
                    tickSpacing: LAUNCH_TICK_SPACING,
                    hooks: this
                }).toId()
        );
    }

    /// @notice only the pool manager sends eth here, when the hook takes an eth fee
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice pays the accrued exit token creator share to the creator. anyone may call
    function claimCreator() external {
        uint256 amount = creatorExitOwed;
        if (amount == 0) revert NothingToClaim();
        creatorExitOwed = 0;
        poolManager.unlock(abi.encode(_exitCurrency(), creator, amount));
        emit CreatorClaimed(amount);
    }

    /// @notice pays the accrued exit token core share to the core and reports it. anyone may call
    function sendExitFeesToCore() external {
        Currency currency = _exitCurrency();
        uint256 amount =
            IERC6909Claims(address(poolManager)).balanceOf(address(this), currency.toId()) - creatorExitOwed;
        if (amount == 0) revert NothingToClaim();
        poolManager.unlock(abi.encode(currency, core, amount));
        ICoreFees(core).addExitFees(amount);
        emit ExitFeesSent(amount);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
        return "";
    }

    /// @dev the launch pool only while launching, the exit pool only under the id the core holds
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        bytes32 id = PoolId.unwrap(key.toId());
        if (id == launchPoolId) {
            if (!ILauncher(launcher).launching()) revert NotLaunching();
        } else {
            bytes32 exitId = ICoreFees(core).exitPoolId();
            if (exitId == bytes32(0) || id != exitId) revert PoolNotAllowed();
            if (Currency.unwrap(key.currency0) != coin && Currency.unwrap(key.currency1) != coin) {
                revert NotACoinPool();
            }
        }
        return this.beforeInitialize.selector;
    }

    /// @dev launch pool liquidity only while launching. the exit pool is open to everyone
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (PoolId.unwrap(key.toId()) == launchPoolId && !ILauncher(launcher).launching()) {
            revert NotLaunching();
        }
        _grant(key, delta);
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev the launch position belongs to the dead address and never leaves. the exit pool is open to everyone
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (PoolId.unwrap(key.toId()) == launchPoolId) revert LaunchPoolLocked();
        _grant(key, delta);
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev when the fee currency is the specified currency the fee comes off the specified amount here.
    /// the positive specified delta shrinks an exact in swap and grows an exact out swap by the fee
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool feeIs0 = Currency.unwrap(key.currency1) == coin;
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        if (specifiedIs0 == feeIs0) {
            uint256 amount =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 fee = amount * FEE_BPS / BPS;
            if (fee != 0) {
                _collect(key, feeIs0 ? key.currency0 : key.currency1, fee);
                return (this.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
            }
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev grants the coin allowance for the swap, then takes the fee when the fee currency is the unspecified one.
    /// the returned fee is a positive unspecified delta, so the swapper receives less or pays more by the fee
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _grant(key, delta);
        bool feeIs0 = Currency.unwrap(key.currency1) == coin;
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        if (specifiedIs0 != feeIs0) {
            int128 feeLeg = feeIs0 ? delta.amount0() : delta.amount1();
            uint256 fee = uint256(uint128(feeLeg < 0 ? -feeLeg : feeLeg)) * FEE_BPS / BPS;
            if (fee != 0) {
                _collect(key, feeIs0 ? key.currency0 : key.currency1, fee);
                return (this.afterSwap.selector, fee.toInt128());
            }
        }
        return (this.afterSwap.selector, 0);
    }

    /// @dev grants exactly the coin the pool manager moves for this action, in either direction
    function _grant(PoolKey calldata key, BalanceDelta delta) private {
        int128 coinLeg = Currency.unwrap(key.currency0) == coin ? delta.amount0() : delta.amount1();
        if (coinLeg != 0) ICoin(coin).increaseTransferAllowance(uint256(uint128(coinLeg < 0 ? -coinLeg : coinLeg)));
    }

    /// @dev eth is taken and paid out at once. the exit token is kept as pool manager claims, because a buyer
    /// has not paid yet and the pool manager may hold none of the token. claims are paid out by the claim functions
    function _collect(PoolKey calldata key, Currency currency, uint256 fee) private {
        uint256 creatorCut = fee * CREATOR_BPS / FEE_BPS;
        uint256 coreCut = fee - creatorCut;
        if (currency.isAddressZero()) {
            poolManager.take(currency, address(this), fee);
            if (creatorCut != 0) SafeTransferLib.forceSafeTransferETH(creator, creatorCut, CREATOR_GAS_STIPEND);
            ICoreFees(core).addFees{value: coreCut}();
        } else {
            poolManager.mint(address(this), currency.toId(), fee);
            creatorExitOwed += creatorCut;
        }
        emit FeesTaken(PoolId.unwrap(key.toId()), Currency.unwrap(currency), creatorCut, coreCut);
    }

    function _exitCurrency() private view returns (Currency) {
        address token = ICoreFees(core).exitToken();
        if (token == address(0)) revert NoExitToken();
        return Currency.wrap(token);
    }
}
