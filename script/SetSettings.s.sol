// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {SettingsBounds} from "../src/lib/SettingsBounds.sol";
import {SettingsFields} from "./SettingsFields.sol";

/// @notice the owner functions of the Core this script talks to
interface ICoreOwner {
    function owner() external view returns (address);
    function settings() external view returns (Settings memory);
    function setSettings(Settings calldata s) external;
    function ethRate() external view returns (uint256);
    function setRate(uint256 rate) external;
    function xRate() external view returns (uint256);
    function setXRate(uint256 rate) external;
    function heldStatements() external view returns (uint256[] memory);
    function statementStatus(uint256 sid)
        external
        view
        returns (uint8 status, uint256 auctionId, uint256 reserve, uint256 bid, uint64 endTime);
    function repriceStatement(uint256 sid) external;
    function controller() external view returns (address);
    function statementInfo(uint256 sid) external view returns (bool held, uint8 lane, uint256 cost, uint64 clockStart);
}

/// @notice the price read of the controller the Core asks for a reserve
interface IPriceController {
    function statementPrice(uint256 sid, uint256 cost, uint64 listedAt) external view returns (uint256);
}

/// @notice changes the settings of a live Core without touching the fields you do not name. it reads the live struct, applies
/// your overrides, checks the sanity bounds, prints a before and after table and the calldata, and sends nothing
/// unless SEND=1 and the run has `--broadcast` and a signer that is the Core owner. docs/DEPLOY.md section 7.
///
/// overrides, both may be used, the patch is applied first and the single variables win:
/// * `SET_<field>=<value>`, one variable per field of `Settings`, for example `SET_saleFloorBps=8000`
/// * `SETTINGS_PATCH`, a json object as text or the path of a json file, for example `{"saleFloorBps":8000}`
/// `SET_RATE=<wei per point>` also prepares `setRate`, `SET_XRATE=<bps>` also prepares `setXRate`.
/// `REPRICE=1` also reprices the open listings after the settings call (docs/DEPLOY.md section 4). raising `saleFloorBps`
/// is NOT atomic for an EOA owner: a listing keeps its old reserve until it is repriced, and a bid that lands at the old
/// reserve before its reprice does wins the statement at that price. what the script does: it reads `heldStatements()`
/// before the owner transaction, and after `setSettings` it reads it AGAIN and reprices every listing without a bid whose
/// house reserve is below what `repriceStatement` would set now, then reads again, for at most `MAX_PASSES` passes.
/// it ends with a table of every listing still below the new floor and why (a bid, a listing that appeared during the
/// run, a controller that cannot price). inside one forge run the reads after `setSettings` see the run's own simulated
/// state, so a statement composed on chain after the run started is not seen: RERUN THE SAME COMMAND once the batch is
/// mined, the rerun reads the chain fresh and reprices what is left. an owner that is a multisig can batch `setSettings`
/// and the reprices in one transaction (a bid cannot land between them) but still cannot include a statement composed
/// after its snapshot, so it reruns once after as well. `STRICT=1` makes a dry run revert while anything remains
///
/// `CORE=0x... SET_saleFloorBps=8000 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL`
/// (add `SEND=1 --broadcast --ledger` or `--account <name>` to send, as the owner)
contract SetSettings is Script {
    /// @dev a patch names a field that `Settings` does not have
    error UnknownField(string name);
    /// @dev a value does not fit the width of its field
    error ValueTooWide(string name);
    /// @dev the new struct is outside the bounds the Core enforces, `field` is the first one out
    error OutOfBounds(bytes32 field);
    /// @dev the signer is not the Core owner
    error NotOwner(address owner, address signer);
    /// @dev STRICT=1 and `count` listings are still below the new floor
    error FloorNotRaised(uint256 count);

    string internal constant TUPLE =
        "(uint16,uint32,uint16,uint32,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint32,uint16,uint16,uint128,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint16,uint64,uint16,uint16)";

    function run() external {
        ICoreOwner core = ICoreOwner(_core());
        Settings memory before_ = core.settings();
        // the first read of the held statements, before any owner transaction
        uint256[] memory first = core.heldStatements();
        Settings memory next = _apply(before_);
        bytes32 bad = SettingsBounds.firstViolation(next);
        if (bad != 0) revert OutOfBounds(bad);

        _table(before_, next);
        bool settingsChanged = keccak256(abi.encode(before_)) != keccak256(abi.encode(next));
        console.log("setSettings calldata");
        console.logBytes(abi.encodeCall(ICoreOwner.setSettings, (next)));
        console.log(
            string.concat(
                "cast send ", vm.toString(address(core)), " \"setSettings(", TUPLE, ")\" \"", _tuple(next), "\""
            )
        );
        if (!settingsChanged) console.log("the settings are unchanged, setSettings is not needed");

        uint256 rate = vm.envOr("SET_RATE", uint256(0));
        uint256 xRate = vm.envOr("SET_XRATE", uint256(0));
        if (rate != 0) {
            console.log("ethRate now", core.ethRate());
            console.log("setRate calldata");
            console.logBytes(abi.encodeCall(ICoreOwner.setRate, (rate)));
            console.log(
                string.concat("cast send ", vm.toString(address(core)), " \"setRate(uint256)\" ", vm.toString(rate))
            );
        }
        if (xRate != 0) {
            console.log("xRate now", core.xRate());
            console.log("setXRate calldata");
            console.logBytes(abi.encodeCall(ICoreOwner.setXRate, (xRate)));
            console.log(
                string.concat("cast send ", vm.toString(address(core)), " \"setXRate(uint256)\" ", vm.toString(xRate))
            );
        }

        bool reprice = _reprice();
        if (!reprice && next.saleFloorBps > before_.saleFloorBps) {
            console.log("WARNING saleFloorBps rises and REPRICE=1 is not set: open listings keep their old reserve");
        }
        if (reprice) {
            console.log("plan: reprice every listing without a bid whose reserve is below the new asking price");
            _finish(_sweep(core, next.saleFloorBps, first, false), false);
        }

        if (!_send()) {
            console.log("nothing sent. add SEND=1 and --broadcast with the owner as signer to send");
            return;
        }
        vm.startBroadcast();
        (, address signer,) = vm.readCallers();
        if (signer != core.owner()) revert NotOwner(core.owner(), signer);
        if (settingsChanged) core.setSettings(next);
        if (rate != 0) core.setRate(rate);
        if (xRate != 0) core.setXRate(xRate);
        // the second read: after setSettings, listings that were not in the first read are found and repriced too
        if (reprice) _finish(_sweep(core, next.saleFloorBps, first, true), true);
        vm.stopBroadcast();
        console.log("sent. read it back with settings(), ethRate() and the SettingsSet event");
    }

    /// @dev one listing that is still below the new floor after the sweep, and why
    struct Left {
        uint256 sid;
        uint8 status;
        uint256 reserve;
        uint256 bid;
        uint256 target;
        string reason;
    }

    /// @dev passes of read, reprice, read again before the sweep gives up
    uint256 internal constant MAX_PASSES = 4;

    /// @dev the reserve `repriceStatement` would set now: the controller's asking price floored at `cost * floorBps`.
    /// `ok` is false when the statement is not held or the controller cannot price it (the Core call would revert)
    function _target(ICoreOwner core, uint256 sid, uint256 floorBps) internal view returns (bool ok, uint256 target) {
        (bool held,, uint256 cost, uint64 at) = core.statementInfo(sid);
        if (!held) return (false, 0);
        (bool called, bytes memory out) =
            core.controller().staticcall{gas: 200_000}(abi.encodeCall(IPriceController.statementPrice, (sid, cost, at)));
        if (!called || out.length < 32) return (false, 0);
        uint256 price = abi.decode(out, (uint256));
        uint256 floor_ = cost * floorBps / 10_000;
        return (true, price > floor_ ? price : floor_);
    }

    function _inList(uint256[] memory list, uint256 x) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == x) return true;
        }
        return false;
    }

    /// @dev the sweep. up to `MAX_PASSES` times: read `heldStatements()`, reprice every listing with no bid whose house
    /// reserve is below `_target`, and read again. `exec` false only plans: it prints the calls and sends none.
    /// `first` is the list read before the owner transaction. returns every listing still below the new floor
    function _sweep(ICoreOwner core, uint256 floorBps, uint256[] memory first, bool exec)
        internal
        returns (Left[] memory)
    {
        for (uint256 pass; pass < MAX_PASSES; ++pass) {
            uint256[] memory held = core.heldStatements();
            uint256 n;
            for (uint256 i; i < held.length; ++i) {
                (uint8 status,, uint256 reserve,,) = core.statementStatus(held[i]);
                (bool ok, uint256 target) = _target(core, held[i], floorBps);
                if (status != 2 || !ok || reserve >= target) continue;
                ++n;
                string memory verb = exec ? "reprice " : "would reprice ";
                console.log(
                    string.concat(verb, vm.toString(held[i]), ", reserve and new asking price:"), reserve, target
                );
                if (exec) core.repriceStatement(held[i]);
                else _cast(core, held[i]);
            }
            console.log(string.concat("pass ", vm.toString(pass + 1), ", reprices"), n);
            if (n == 0 || !exec) break;
        }
        return _left(core, floorBps, first, exec);
    }

    function _cast(ICoreOwner core, uint256 sid) internal view {
        string memory c = vm.toString(address(core));
        console.log(string.concat("cast send ", c, " \"repriceStatement(uint256)\" ", vm.toString(sid)));
    }

    /// @dev every listing that is still below the new floor after the sweep. in a plan (`exec` false) the listings the
    /// plan will reprice are not counted
    function _left(ICoreOwner core, uint256 floorBps, uint256[] memory first, bool exec)
        internal
        view
        returns (Left[] memory out)
    {
        uint256[] memory held = core.heldStatements();
        Left[] memory tmp = new Left[](held.length);
        uint256 n;
        for (uint256 i; i < held.length; ++i) {
            (uint8 status,, uint256 reserve, uint256 bid,) = core.statementStatus(held[i]);
            if (status < 2 || status > 4) continue;
            (bool ok, uint256 target) = _target(core, held[i], floorBps);
            (,, uint256 cost,) = core.statementInfo(held[i]);
            string memory why;
            if (status == 2) {
                if (ok && (reserve >= target || !exec)) continue;
                why = !ok ? "controller cannot price it" : "still below after the passes";
            } else {
                // a bid at or above the new floor sells at or above it
                if (bid >= cost * floorBps / 10_000) continue;
                why = "has a bid below the new floor";
            }
            if (!_inList(first, held[i])) why = string.concat(why, ", appeared during the run");
            tmp[n++] = Left(held[i], status, reserve, bid, ok ? target : 0, why);
        }
        out = new Left[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tmp[i];
        }
    }

    /// @dev prints the final table and a loud warning when anything is left. in a send run it never reverts, a revert
    /// would drop the broadcast. `STRICT=1` makes a dry run revert
    function _finish(Left[] memory left, bool sending) internal view {
        if (left.length == 0) {
            console.log("every listing is at or above the new floor, or will be after the planned reprices");
            return;
        }
        console.log("WARNING listings still below the new floor: sid | status | reserve | top bid | asking | why");
        for (uint256 i; i < left.length; ++i) {
            Left memory l = left[i];
            string memory row = string.concat(vm.toString(l.sid), " | ", vm.toString(uint256(l.status)), " | ");
            row = string.concat(row, vm.toString(l.reserve), " | ", vm.toString(l.bid), " | ", vm.toString(l.target));
            console.log(string.concat(row, " | ", l.reason));
        }
        console.log(
            "WARNING a listing with a bid, or one that gets a bid before its reprice lands, sells at its old price"
        );
        console.log("RERUN the same command once the transactions are mined: the rerun reads the chain fresh");
        if (!sending && vm.envOr("STRICT", uint256(0)) == 1) revert FloorNotRaised(left.length);
    }

    /// @dev the Core to change (CORE), the broadcast flag (SEND=1) and the optional rate changes. a test overrides them
    function _core() internal view virtual returns (address) {
        return vm.envAddress("CORE");
    }

    function _send() internal view virtual returns (bool) {
        return vm.envOr("SEND", uint256(0)) == 1;
    }

    /// @dev REPRICE=1 adds a `repriceStatement` for every listed statement without a bid. a test overrides it
    function _reprice() internal view virtual returns (bool) {
        return vm.envOr("REPRICE", uint256(0)) == 1;
    }

    /// @dev the statements the Core holds that are listed on the house with no bid yet (status Listed, 2), the only
    /// ones `repriceStatement` accepts. `heldStatements` may hold sold statements until synced, those are skipped
    function _openListings(ICoreOwner core) internal view returns (uint256[] memory out) {
        uint256[] memory held = core.heldStatements();
        uint256[] memory tmp = new uint256[](held.length);
        uint256 n;
        for (uint256 i; i < held.length; ++i) {
            (uint8 status,,,,) = core.statementStatus(held[i]);
            if (status == 2) tmp[n++] = held[i];
        }
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tmp[i];
        }
    }

    /// @dev the patch text or file path, empty when there is none. a test overrides it
    function _patch() internal view virtual returns (string memory) {
        return vm.envOr("SETTINGS_PATCH", string(""));
    }

    /// @dev the single variable of a field, `has` false when it is not set. a test overrides it
    function _single(string memory name) internal view virtual returns (bool has, uint256 v) {
        string memory key = string.concat("SET_", name);
        if (!vm.envExists(key)) return (false, 0);
        return (true, vm.envUint(key));
    }

    /// @dev the live struct with the patch, then the single variables, applied
    function _apply(Settings memory live) internal view returns (Settings memory s) {
        // a copy, so the live struct stays what it is for the before and after table
        s = abi.decode(abi.encode(live), (Settings));
        string memory patch = _patch();
        if (bytes(patch).length != 0) {
            string memory json = bytes(patch)[0] == "{" ? patch : vm.readFile(patch);
            string[] memory keys = vm.parseJsonKeys(json, "$");
            for (uint256 k; k < keys.length; ++k) {
                _set(s, keys[k], vm.parseJsonUint(json, string.concat(".", keys[k])));
            }
        }
        bytes32[29] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            string memory name = _name(names[i]);
            (bool has, uint256 v) = _single(name);
            if (has) _set(s, name, v);
        }
    }

    function _set(Settings memory s, string memory name, uint256 v) internal pure {
        bytes32[29] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            if (keccak256(bytes(_name(names[i]))) != keccak256(bytes(name))) continue;
            SettingsFields.set(s, i, v);
            // the setter narrows to the field width: a value that did not fit reads back different
            if (SettingsFields.get(s, i) != v) revert ValueTooWide(name);
            return;
        }
        revert UnknownField(name);
    }

    function _name(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) ++n;
        bytes memory out = new bytes(n);
        for (uint256 j; j < n; ++j) {
            out[j] = b[j];
        }
        return string(out);
    }

    /// @dev one line per field: name, live value, new value, a mark when it changes, the bounds
    function _table(Settings memory a, Settings memory b) internal pure {
        console.log(
            "settings: field | live | new | bounds (a * marks a change; climbMaxBps >= climbBaseBps, xRateFloor <= xRateCap)"
        );
        uint256[29] memory lo = SettingsFields.lo();
        uint256[29] memory hi = SettingsFields.hi();
        bytes32[29] memory names = SettingsFields.names();
        for (uint256 i; i < SettingsFields.N; ++i) {
            uint256 x = SettingsFields.get(a, i);
            uint256 y = SettingsFields.get(b, i);
            console.log(
                string.concat(
                    x == y ? "  " : "* ",
                    _name(names[i]),
                    " | ",
                    vm.toString(x),
                    " | ",
                    vm.toString(y),
                    " | ",
                    vm.toString(lo[i]),
                    " to ",
                    vm.toString(hi[i])
                )
            );
        }
    }

    /// @dev the struct as the tuple literal `cast send` takes
    function _tuple(Settings memory s) internal pure returns (string memory out) {
        out = "(";
        for (uint256 i; i < SettingsFields.N; ++i) {
            out = string.concat(out, i == 0 ? "" : ",", vm.toString(SettingsFields.get(s, i)));
        }
        out = string.concat(out, ")");
    }
}
