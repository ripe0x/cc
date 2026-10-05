// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ILauncher, Mainnet} from "./interfaces/Interfaces.sol";
import {Coin} from "./Coin.sol";

/// @notice one shot launcher. it holds the whole coin supply, opens the coin/eth pool and puts the supply into a single
/// sided position owned by the dead address. the deployer can call it once, and the pool hook only lets the pool
/// be created and filled while `launching` is true.
contract Launcher is ILauncher {
    using PoolIdLibrary for PoolKey;

    /// @notice pool fee of the launch pool
    uint24 public constant POOL_FEE = 0;
    /// @notice tick spacing of the launch pool
    int24 public constant TICK_SPACING = 60;
    /// @notice opening price, 40 million coin per eth
    uint160 public constant START_SQRT_PRICE_X96 = 501082896750095888663770159906816;
    /// @notice upper tick of the position, just below the opening price so the position holds only coin
    int24 public constant TICK_UPPER = 175020;
    /// @notice most eth the mint may pull. the position is coin only, so it pulls none
    uint256 public constant MAX_ETH = 2 wei;

    /// @notice the only address that may call `launch`
    address public immutable deployer;

    /// @notice true only while `launch` runs
    bool public launching;
    /// @notice true once `launch` has been called
    bool public launched;

    /// @notice the launch happened
    /// @param coin the coin
    /// @param hook the hook of the pool
    /// @param poolId the pool id
    /// @param liquidity liquidity of the dead owned position
    /// @param dust coin that did not fit the position and was sent to the dead address
    event Launched(address indexed coin, address indexed hook, bytes32 poolId, uint128 liquidity, uint256 dust);

    /// @notice caller is not the deployer
    error OnlyDeployer();
    /// @notice launch was already called
    error AlreadyLaunched();
    /// @notice the hook is not the hook the coin was built with
    error WrongHook();
    /// @notice the launcher does not hold the coin supply
    error NoSupply();
    /// @notice a constructor address was zero
    error ZeroAddress();

    /// @param deployer_ the only address allowed to launch
    constructor(address deployer_) {
        if (deployer_ == address(0)) revert ZeroAddress();
        deployer = deployer_;
    }

    /// @notice opens the pool and locks the whole supply into it. deployer only, once
    /// @param coin the coin, which this contract must hold in full
    /// @param hook the fee hook of the coin
    function launch(address coin, address hook) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (launched) revert AlreadyLaunched();
        launched = true;
        if (Coin(coin).hook() != hook) revert WrongHook();
        uint256 supply = Coin(coin).balanceOf(address(this));
        if (supply == 0) revert NoSupply();

        launching = true;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            START_SQRT_PRICE_X96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            MAX_ETH,
            supply
        );

        SafeTransferLib.safeApprove(coin, Mainnet.PERMIT2, type(uint256).max);
        IAllowanceTransfer(Mainnet.PERMIT2).approve(coin, Mainnet.POSITION_MANAGER, type(uint160).max, type(uint48).max);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory mintParams = new bytes[](2);
        mintParams[0] = abi.encode(key, tickLower, TICK_UPPER, liquidity, MAX_ETH, supply, Mainnet.DEAD, "");
        mintParams[1] = abi.encode(key.currency0, key.currency1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPoolInitializer_v4.initializePool, (key, START_SQRT_PRICE_X96));
        calls[1] =
            abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, mintParams), block.timestamp));
        IPositionManager(Mainnet.POSITION_MANAGER).multicall(calls);

        uint256 dust = Coin(coin).balanceOf(address(this));
        if (dust != 0) SafeTransferLib.safeTransfer(coin, Mainnet.DEAD, dust);

        launching = false;
        emit Launched(coin, hook, PoolId.unwrap(key.toId()), liquidity, dust);
    }
}
