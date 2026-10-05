// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Lane, ICoreViews, Mainnet} from "../../src/interfaces/Interfaces.sol";

/// a controller for invariant runs. every answer is a pure function of `seed` and the arguments, so the handler can
/// ask the same question the core asks and get the same answer. the core reads it with staticcall, so none of the
/// attacks it tries while answering can change state. benign mode answers within the rules. hostile mode answers
/// out of range, with pages that are not in the pile, duplicate ids, bad formats, short or long return data,
/// overprints that name statements the core does not hold, and it attacks the core while it is asked.
/// the functions are not marked view on purpose, so they may attempt state changing calls.
contract FuzzController {
    uint256 internal constant PAGE = 80;
    uint256 internal constant ATTACKS = 20;

    address public immutable core;
    uint256 public seed;
    bool public hostile;

    constructor(address core_) {
        core = core_;
    }

    function setSeed(uint256 s) external {
        seed = s;
    }

    function setHostile(bool h) external {
        hostile = h;
    }

    function _r(bytes32 tag, uint256 x) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(seed, tag, x)));
    }

    /*//////////////////////////////////////////////////////////////
                                  wants
    //////////////////////////////////////////////////////////////*/

    function wants(uint256 id) external returns (uint256) {
        uint256 r = _r("wants", id);
        if (!hostile) {
            uint256 k = r % 5;
            if (k == 0) return 0;
            if (k == 1) return 2500;
            return (r >> 8) % 2501;
        }
        _attack(r);
        uint256 m = (r >> 16) % 10;
        if (m == 0) revert("hostile wants");
        if (m == 1) return type(uint256).max;
        if (m == 2) return 2501;
        if (m == 3) return 65_535;
        if (m == 4) return 25_000;
        if (m == 5) {
            _burn(150_000);
            return 2500;
        }
        if (m == 6) {
            // short answer, fewer than 32 bytes
            assembly {
                mstore(0, 1)
                return(0, 31)
            }
        }
        if (m == 7) return 0;
        return (r >> 32) % 3000;
    }

    /*//////////////////////////////////////////////////////////////
                                nextPage
    //////////////////////////////////////////////////////////////*/

    function nextPage(uint8 lane) external returns (uint256 ready, uint256[80] memory ids, uint256 format) {
        uint256 r = _r("page", lane);
        Lane l = lane == 0 ? Lane.Eth : Lane.Exit;
        if (!hostile) {
            bool ok;
            (ok, ids) = _honestPage(l, r);
            if (!ok) return (0, ids, 0);
            return (1, ids, (r >> 40) % 8);
        }
        _attack(r);
        uint256 m = (r >> 16) % 14;
        bool okPage;
        (okPage, ids) = _honestPage(l, r);
        uint256 f = (r >> 40) % 8;
        uint256 k = (r >> 48) % PAGE;
        uint256 j = (r >> 64) % PAGE;
        if (m == 0) return (0, ids, 0);
        if (m == 1 || m == 2) return (okPage ? 1 : 0, ids, f);
        if (m == 3) {
            ids[k] = 1 + (r >> 80) % 9;
            return (1, ids, f);
        }
        if (m == 4) {
            ids[k] = ids[(k + 1 + j % 79) % PAGE];
            return (1, ids, f);
        }
        if (m == 5) {
            ids[k] = 0;
            return (1, ids, f);
        }
        if (m == 6) return (1, ids, 8 + (r >> 80) % 248);
        if (m == 7) return (1, ids, type(uint256).max);
        if (m == 8) return (2, ids, f);
        if (m == 9) {
            // the other lane's page
            (okPage, ids) = _honestPage(l == Lane.Eth ? Lane.Exit : Lane.Eth, r);
            return (1, ids, f);
        }
        if (m == 10) _short(81);
        if (m == 11) _short(90);
        if (m == 12) revert("hostile page");
        _burn(1_000_000);
        return (okPage ? 1 : 0, ids, f);
    }

    /// a contiguous run of 80 ids from the lane pile starting at a random offset, or not ok when the pile is short.
    function _honestPage(Lane lane, uint256 r) internal view returns (bool ok, uint256[80] memory ids) {
        uint256 size = ICoreViews(core).pileSize(lane);
        if (size < PAGE) return (false, ids);
        uint256 skip = (r >> 100) % (size - PAGE + 1);
        uint256 id = ICoreViews(core).pileHead(lane);
        for (uint256 i; i < skip; ++i) {
            id = ICoreViews(core).pileNext(id);
        }
        for (uint256 i; i < PAGE; ++i) {
            ids[i] = id;
            id = ICoreViews(core).pileNext(id);
        }
        return (true, ids);
    }

    /*//////////////////////////////////////////////////////////////
                              nextOverprint
    //////////////////////////////////////////////////////////////*/

    function nextOverprint() external returns (uint256 ready, uint256 baseId, uint256 topId) {
        uint256 r = _r("overprint", 0);
        uint256[] memory held = ICoreViews(core).heldStatements();
        if (!hostile) {
            if (held.length < 2 || r % 3 == 0) return (0, 0, 0);
            return _pair(held, r, true);
        }
        _attack(r);
        uint256 m = (r >> 16) % 10;
        if (m == 0) return (0, 0, 0);
        if (m <= 3) {
            if (held.length < 2) return (0, 0, 0);
            return _pair(held, r, true);
        }
        if (m == 4) {
            if (held.length == 0) return (1, 1, 1);
            uint256 x = held[(r >> 24) % held.length];
            return (1, x, x);
        }
        if (m == 5) return (1, (r >> 24) % 12, (r >> 48) % 12);
        if (m == 6) {
            if (held.length == 0) return (1, 7, 8);
            return (1, held[(r >> 24) % held.length], (r >> 48) % 12);
        }
        if (m == 7) {
            if (held.length < 2) return (0, 0, 0);
            return _pair(held, r, false);
        }
        if (m == 8) return (2, held.length > 1 ? held[0] : 1, held.length > 1 ? held[1] : 2);
        if (m == 9) _short(3);
        revert("hostile overprint");
    }

    /// two distinct held statements, from the same lane when `sameLane` and from any lane otherwise.
    function _pair(uint256[] memory held, uint256 r, bool sameLane) internal view returns (uint256, uint256, uint256) {
        uint256 n = held.length;
        uint256 a = (r >> 24) % n;
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                uint256 x = held[(a + i) % n];
                uint256 y = held[(a + i + 1 + j) % n];
                if (x == y) continue;
                (, Lane lx,,) = ICoreViews(core).statementInfo(x);
                (, Lane ly,,) = ICoreViews(core).statementInfo(y);
                if (sameLane == (lx == ly)) return (1, x, y);
            }
        }
        return (0, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 helpers
    //////////////////////////////////////////////////////////////*/

    /// answers with `words` words of data. fewer or more than the core expects.
    function _short(uint256 words) internal pure {
        assembly {
            return(0, mul(words, 32))
        }
    }

    /// spins for about `gas_` gas and no more, so it also ends under a very large gas limit.
    function _burn(uint256 gas_) internal view {
        uint256 start = gasleft();
        while (start - gasleft() < gas_) {}
    }

    /// the calls an attacker controller would try. all of them need an authority or an asset the controller does
    /// not have. in the core's staticcall they also fail for being state changes.
    function _call(uint256 which, uint256 r) internal returns (bool ok) {
        uint256[] memory ids = new uint256[](1);
        // small id ranges, so a fork run reads the same few slots again and again instead of fetching new ones
        ids[0] = 1 + (r >> 8) % 8;
        address credits = Mainnet.CREDITS;
        address statements = Mainnet.STATEMENTS;
        address manager = Mainnet.POOL_MANAGER;
        uint256 sid = 1 + (r >> 24) % 6;
        bytes memory data;
        address target = core;
        if (which == 0) {
            data = abi.encodeWithSignature("sellForEth(uint256[])", ids);
        } else if (which == 1) {
            data = abi.encodeWithSignature("sellForExitToken(uint256[])", ids);
        } else if (which == 2) {
            data = abi.encodeWithSignature("addFees()");
        } else if (which == 3) {
            data = abi.encodeWithSignature("addExitFees(uint256)", uint256(1));
        } else if (which == 4) {
            data = abi.encodeWithSignature("queue(uint8,bytes)", uint8(0), abi.encode(address(this)));
        } else if (which == 5) {
            data = abi.encodeWithSignature("execute(uint8,bytes)", uint8(0), abi.encode(address(this)));
        } else if (which == 6) {
            data = abi.encodeWithSignature("removeTarget(address)", Mainnet.CREDIT_STRATEGY);
        } else if (which == 7) {
            data = abi.encodeWithSignature("unlockCallback(bytes)", bytes(""));
        } else if (which == 8) {
            target = credits;
            data = abi.encodeWithSignature("transferFrom(address,address,uint256)", core, address(this), ids[0]);
        } else if (which == 9) {
            target = credits;
            data = abi.encodeWithSignature("burn(address,uint256[])", core, ids);
        } else if (which == 10) {
            target = statements;
            data = abi.encodeWithSignature("transferFrom(address,address,uint256)", core, address(this), sid);
        } else if (which == 11) {
            target = statements;
            data = abi.encodeWithSignature("overprint(uint256,uint256)", sid, sid + 1);
        } else if (which == 12) {
            target = statements;
            data = abi.encodeWithSignature("setFormat(uint256,uint8)", sid, uint8(3));
        } else if (which == 13) {
            target = _coin();
            data = abi.encodeWithSignature("transferFrom(address,address,uint256)", core, address(this), uint256(1e18));
        } else if (which == 14) {
            target = _coin();
            data = abi.encodeWithSignature("increaseTransferAllowance(uint256)", uint256(1e30));
        } else if (which == 15) {
            target = _exitToken();
            data = abi.encodeWithSignature("transferFrom(address,address,uint256)", core, address(this), uint256(1));
        } else if (which == 16) {
            target = manager;
            data = abi.encodeWithSignature("take(address,address,uint256)", _coin(), address(this), uint256(1));
        } else if (which == 17) {
            data = abi.encodeWithSignature(
                "onERC721Received(address,address,uint256,bytes)", address(this), address(this), sid, bytes("")
            );
        } else if (which == 18) {
            target = credits;
            data = abi.encodeWithSignature("setApprovalForAll(address,bool)", address(this), true);
        } else {
            target = credits;
            data = abi.encodeWithSignature("approve(address,uint256)", address(this), ids[0]);
        }
        if (target == address(0)) return false;
        (ok,) = target.call{gas: 300_000}(data);
    }

    function _coin() internal view returns (address c) {
        (bool ok, bytes memory out) = core.staticcall(abi.encodeWithSignature("COIN()"));
        if (ok && out.length == 32) c = abi.decode(out, (address));
    }

    function _exitToken() internal view returns (address t) {
        (bool ok, bytes memory out) = core.staticcall(abi.encodeWithSignature("exitToken()"));
        if (ok && out.length == 32) t = abi.decode(out, (address));
    }

    /// two or three attempts per answer, picked from the seed.
    function _attack(uint256 r) internal {
        for (uint256 i; i < 3; ++i) {
            _call(uint256(keccak256(abi.encode(r, i))) % ATTACKS, r >> i);
        }
    }

    /// runs every attempt outside a staticcall, as the controller. returns a bitmask of the attempts that
    /// succeeded. the list holds only calls that need an authority or an asset the controller does not have.
    /// the open calls any account may make (compose, skim, buyback and the like) are left out.
    function probe(uint256 r) external returns (uint256 mask) {
        for (uint256 i; i < ATTACKS; ++i) {
            // credits and statements approvals for the controller itself are harmless but must not move an asset.
            // they are made on the controller's own account, so they succeed. they are skipped here.
            if (i == 18 || i == 19) continue;
            if (_call(i, r >> (i % 8))) mask |= 1 << i;
        }
    }
}
