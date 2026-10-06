// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICredits, Mainnet} from "../../src/interfaces/Interfaces.sol";

/// a listing target with several hostile behaviours, selected by `mode`. it holds credits so it can deliver the
/// right one, a wrong one or two at once. modes 0 to 4 and 6 must make the core revert the buy. modes 5, 7 and 8
/// end in an honest delivery and may succeed, after attempts to reenter the core or to pull the credit back,
/// which the core and the credits must refuse.
contract ProbeTarget {
    ICredits internal constant CREDITS = ICredits(Mainnet.CREDITS);

    address public immutable core;
    uint256 public mode;
    /// reentry attempts that unexpectedly succeeded. must stay zero.
    uint256 public reentered;
    /// reentry attempts made
    uint256 public attempts;

    constructor(address core_) {
        core = core_;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    /// true when a success of the buy is acceptable for this mode.
    function honest(uint256 m) public pure returns (bool) {
        return m == 5 || m == 7 || m == 8;
    }

    /// 0 keeps the eth. 1 sends the wrong credit. 2 sends the right credit and a second one. 3 reenters the core
    /// and keeps the eth. 4 sends the right credit and returns more eth than it was paid. 5 sends the right credit
    /// and refunds half. 6 reverts. 7 sends the right credit after failed reentry attempts. 8 sends the right
    /// credit and then tries to pull it back out of the core.
    function fill(uint256 id, uint256 wrongId) external payable {
        uint256 m = mode;
        if (m == 0) return;
        if (m == 1) {
            CREDITS.transferFrom(address(this), msg.sender, wrongId);
            return;
        }
        if (m == 2) {
            CREDITS.transferFrom(address(this), msg.sender, id);
            CREDITS.transferFrom(address(this), msg.sender, wrongId);
            return;
        }
        if (m == 3) {
            _reenter();
            return;
        }
        if (m == 4) {
            CREDITS.transferFrom(address(this), msg.sender, id);
            (bool ok,) = msg.sender.call{value: msg.value + 1}("");
            require(ok, "send");
            return;
        }
        if (m == 5) {
            CREDITS.transferFrom(address(this), msg.sender, id);
            (bool ok,) = msg.sender.call{value: msg.value / 2}("");
            require(ok, "send");
            return;
        }
        if (m == 6) revert("hostile");
        if (m == 7) {
            _reenter();
            CREDITS.transferFrom(address(this), msg.sender, id);
            return;
        }
        // 8: deliver the credit, then try to pull the credit straight back out of the core.
        CREDITS.transferFrom(address(this), msg.sender, id);
        (bool pulled,) = address(CREDITS).call(abi.encodeCall(ICredits.transferFrom, (msg.sender, address(this), id)));
        if (pulled) reentered++;
        attempts++;
    }

    function _reenter() internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        bytes[8] memory calls = [
            abi.encodeWithSignature("sellForEth(uint256[])", ids),
            abi.encodeWithSignature("compose()"),
            abi.encodeWithSignature("skim()"),
            abi.encodeWithSignature("buyback()"),
            abi.encodeWithSignature("collectSales()"),
            abi.encodeWithSignature("syncStatement(uint256)", uint256(1)),
            abi.encodeWithSignature("repriceStatement(uint256)", uint256(1)),
            abi.encodeWithSignature(
                "buyListing(uint256,bytes,uint256,address)", uint256(1), bytes(""), uint256(1), address(this)
            )
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = core.call(calls[i]);
            attempts++;
            if (ok) reentered++;
        }
        // the exit token auction is a guarded door like the rest and must refuse a call from inside a buy.
        (bool ok2,) = core.call(abi.encodeWithSignature("buybackExit(uint256)", uint256(type(uint256).max)));
        attempts++;
        if (ok2) reentered++;
    }

    receive() external payable {}
}
