// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {CommonBase} from "forge-std/Base.sol";

/// @notice collects named checks, prints them as a table and reports the failed ones
abstract contract Report is CommonBase {
    struct Row {
        string name;
        bool ok;
        string detail;
        /// a warning row never fails the run. `ok` false on a warning row means the warning applies
        bool warn;
    }

    /// @notice at least one check failed. `failed` lists their names
    error ChecksFailed(string failed);

    Row[] internal rows;

    function _reset() internal {
        delete rows;
    }

    function _check(string memory name, bool ok, string memory detail) internal {
        rows.push(Row(name, ok, detail, false));
    }

    /// @notice a row that never fails the run. printed as WARN when the condition is false
    function _warn(string memory name, bool fine, string memory detail) internal {
        rows.push(Row(name, fine, detail, true));
    }

    /// @notice an information row, always ok
    function _info(string memory name, string memory detail) internal {
        rows.push(Row(name, true, detail, false));
    }

    function _eq(string memory name, address got, address want) internal {
        _check(name, got == want, string.concat("got ", vm.toString(got), " want ", vm.toString(want)));
    }

    function _eq(string memory name, uint256 got, uint256 want) internal {
        _check(name, got == want, string.concat("got ", vm.toString(got), " want ", vm.toString(want)));
    }

    function _eq(string memory name, bytes32 got, bytes32 want) internal {
        _check(name, got == want, string.concat("got ", vm.toString(got), " want ", vm.toString(want)));
    }

    function _eq(string memory name, string memory got, string memory want) internal {
        _check(name, keccak256(bytes(got)) == keccak256(bytes(want)), string.concat("got ", got, " want ", want));
    }

    function _code(string memory name, address who) internal {
        _check(name, who.code.length != 0, string.concat(vm.toString(who), " code ", vm.toString(who.code.length)));
    }

    function _noCode(string memory name, address who) internal {
        _check(name, who.code.length == 0, string.concat(vm.toString(who), " code ", vm.toString(who.code.length)));
    }

    /// @notice the names of the failed checks joined with commas, and their count
    function _failed() internal view returns (string memory list, uint256 n) {
        for (uint256 i; i < rows.length; ++i) {
            if (!rows[i].ok && !rows[i].warn) {
                list = n == 0 ? rows[i].name : string.concat(list, ", ", rows[i].name);
                ++n;
            }
        }
    }

    function _print(string memory title) internal view {
        console.log(title);
        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            string memory tag = r.ok ? "  ok    " : (r.warn ? "  WARN  " : "  FAIL  ");
            console.log(string.concat(tag, r.name, "  |  ", r.detail));
        }
        (string memory list, uint256 n) = _failed();
        console.log(string.concat(vm.toString(rows.length - n), " of ", vm.toString(rows.length), " checks passed"));
        if (n != 0) console.log(string.concat("failed: ", list));
    }

    /// @notice reverts with the failed names when any check failed. prints nothing
    function _require() internal view {
        (string memory list, uint256 n) = _failed();
        if (n != 0) revert ChecksFailed(list);
    }

    /// @notice prints the table and reverts with the failed names when any check failed
    function _finish(string memory title) internal view {
        _print(title);
        (string memory list, uint256 n) = _failed();
        if (n != 0) revert ChecksFailed(list);
    }
}
