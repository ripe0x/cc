// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Core} from "../../src/Core.sol";

/// a buyer that cannot receive statements, so the core's transfer to it must revert.
contract DeafBuyer {
    function buy(Core c, uint256 sid) external payable {
        c.buyStatement{value: msg.value}(sid);
    }

    receive() external payable {}
}

/// tries to re enter the core while it receives the statement.
contract ReentrantBuyer {
    Core internal core;

    constructor(Core c) {
        core = c;
    }

    function buy(uint256 sid) external payable {
        core.buyStatement{value: address(this).balance}(sid);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        core.skim();
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
