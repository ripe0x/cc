// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICore} from "../../src/interfaces/ICore.sol";
import {ICredits, IStatements, IExitModule, Mainnet} from "../../src/interfaces/Interfaces.sol";
import {IArtCoinsFeeEscrowV2, IArtCoinsTokenV2} from "../../src/interfaces/ArtCoinsV2.sol";
import {MockExitToken} from "../standins/MockExitToken.sol";

/// a listing target that claims the escrow credit of the Core in the middle of the Core's `buyListing` measurement
/// (anyone may claim for the Core), then delivers its credit. the claimed eth lands in the Core with the escrow as sender
contract ClaimMidListing {
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);
    IArtCoinsFeeEscrowV2 public immutable ESCROW;
    address public immutable CORE;
    uint256 public creditId;

    constructor(address escrow_, address core_) {
        ESCROW = IArtCoinsFeeEscrowV2(escrow_);
        CORE = core_;
    }

    function arm(uint256 id) external {
        creditId = id;
    }

    fallback() external payable {
        ESCROW.claim(CORE, address(0));
        CREDITS.transferFrom(address(this), CORE, creditId);
    }

    receive() external payable {}
}

/// an exit module that claims the Core's escrow credit in the middle of `exitStatement`, then pays like the stand in
contract ClaimMidExit is IExitModule {
    MockExitToken public immutable token;
    uint256 public immutable unit;
    IArtCoinsFeeEscrowV2 public immutable ESCROW;
    address public immutable CORE;

    constructor(MockExitToken token_, uint256 unit_, address escrow_, address core_) {
        token = token_;
        unit = unit_;
        ESCROW = IArtCoinsFeeEscrowV2(escrow_);
        CORE = core_;
    }

    function exitToken() external view returns (address) {
        return address(token);
    }

    function unitPerPoint() external view returns (uint256) {
        return unit;
    }

    function exit(uint256 statementId) external returns (uint256 out) {
        ESCROW.claim(CORE, address(0));
        out = IStatements(Mainnet.STATEMENTS).creditScoreOf(statementId) * unit;
        token.mint(msg.sender, out);
    }

    receive() external payable {}
}

/// a stranger holding coin that calls the Core's `buyback` and, in the same transaction, tries to spend the transfer
/// allowance the hook granted for the buyback's take. the Core is not on the allowlist, so the take consumes the whole allowance
contract LeftoverSpender {
    IArtCoinsTokenV2 public immutable COIN;
    ICore public immutable CORE;
    address public immutable POOL_MANAGER;
    uint256 public leftover;
    bool public spent;

    constructor(address coin_, address core_, address pm_) {
        COIN = IArtCoinsTokenV2(coin_);
        CORE = ICore(payable(core_));
        POOL_MANAGER = pm_;
    }

    function run(uint256 amount) external {
        CORE.buyback();
        leftover = COIN.transferAllowance();
        // a wallet to pool manager move is allowed only against that allowance
        try COIN.transfer(POOL_MANAGER, amount) returns (bool ok) {
            spent = ok;
        } catch {}
    }

    receive() external payable {}

    function spendAlone(uint256 amount) external returns (bool ok) {
        try COIN.transfer(POOL_MANAGER, amount) returns (bool r) {
            ok = r;
        } catch {}
    }
}
