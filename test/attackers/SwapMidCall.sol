// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ICredits, IStatements, IExitModule, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {MockExitToken} from "../standins/MockExitToken.sol";
import {TestSwapRouter} from "../utils/TestSwapRouter.sol";
import {IFeeRouter} from "../../src/interfaces/IFeeRouter.sol";

/// the v2 hook pays the pool fee to the fee router, not to the core: these attackers flush the router right after each
/// swap, which is the call that lands the eth in the core's `receive()`. inside a measured call the core refuses the
/// router (V2R-1), so the flush fails whole and the attacker swallows the failure: `flushes` counts the tries,
/// `flushFailed` the ones that reverted
abstract contract Flushes {
    IFeeRouter public feeRouter;
    uint256 public flushes;
    uint256 public flushFailed;

    function setFeeRouter(address r) external {
        feeRouter = IFeeRouter(payable(r));
    }

    function _flush() internal {
        if (address(feeRouter) == address(0)) return;
        ++flushes;
        try feeRouter.flush(address(this)) {} catch {
            ++flushFailed;
        }
    }
}

/// a listing target that swaps in the real pool in the middle of the core's `buyListing` measurement, so the skim
/// hook pushes eth into the core's `receive()` while the core's measuring flag is set. it then delivers its credit
contract SwapMidListing is Flushes {
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);

    TestSwapRouter public immutable router;
    address public immutable core;
    PoolKey internal key;
    uint256 public creditId;
    uint256 public swapEth;

    constructor(TestSwapRouter router_, address core_, PoolKey memory key_) {
        router = router_;
        core = core_;
        key = key_;
    }

    function arm(uint256 creditId_, uint256 swapEth_) external {
        creditId = creditId_;
        swapEth = swapEth_;
    }

    fallback() external payable {
        router.swap{value: swapEth}(key, true, -int256(swapEth), address(this));
        _flush();
        CREDITS.transferFrom(address(this), core, creditId);
    }

    receive() external payable {}
}

/// an exit module that swaps in the real pool in the middle of the core's `exitStatement` measurement, so the skim
/// hook pushes eth into the core's `receive()` while the core's measuring flag is set. it pays like the stand in
contract SwapMidExit is IExitModule, Flushes {
    MockExitToken public immutable token;
    uint256 public immutable unit;
    TestSwapRouter public immutable router;
    PoolKey internal key;
    uint256 public swapEth;

    constructor(MockExitToken token_, uint256 unit_, TestSwapRouter router_, PoolKey memory key_, uint256 swapEth_) {
        token = token_;
        unit = unit_;
        router = router_;
        key = key_;
        swapEth = swapEth_;
    }

    function exitToken() external view returns (address) {
        return address(token);
    }

    function unitPerPoint() external view returns (uint256) {
        return unit;
    }

    function exit(uint256 statementId) external returns (uint256 out) {
        router.swap{value: swapEth}(key, true, -int256(swapEth), address(this));
        _flush();
        out = IStatements(Mainnet.STATEMENTS).creditScoreOf(statementId) * unit;
        token.mint(msg.sender, out);
    }

    receive() external payable {}
}

interface ICollect {
    function collectSales() external;
}

/// one transaction that swaps in the real pool (the skim hook pushes into the core's `receive`), collects the sale
/// proceeds the house owes the core, and swaps again. the house delivers statements by plain transfer and never runs
/// code of the winner, so this is the closest a stranger gets to interleaving the two
contract SwapAroundCollect is Flushes {
    TestSwapRouter public immutable router;
    ICollect public immutable core;
    PoolKey internal key;

    constructor(TestSwapRouter router_, address core_, PoolKey memory key_) {
        router = router_;
        core = ICollect(core_);
        key = key_;
    }

    function run(uint256 swapEth) external payable {
        router.swap{value: swapEth}(key, true, -int256(swapEth), address(this));
        _flush();
        core.collectSales();
        router.swap{value: swapEth}(key, true, -int256(swapEth), address(this));
        _flush();
        core.collectSales();
    }

    receive() external payable {}
}
