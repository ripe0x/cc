// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {LaunchChecks} from "./Checks.sol";

/// @notice sends `coin.lockRecipients()` for the launched system at `CORE`: the hook bounty recipient (the fee router)
/// and the locker reward recipients are frozen. the pool then pays the router from then on, and the engine behind the
/// router changes only through `router.setEngine`. one way. runs the postflight first and stops on any failed row,
/// requires the hook bounty recipient to be the fee router whatever COIN_CHANGED says, sends nothing unless SEND=1 and
/// the run has `--broadcast` and a signer that is the coin admin. the lock read back at the end is read in forge's
/// simulation, the confirmation is Postflight with RECIPIENTS_LOCKED=1 against the chain.
/// `CORE=0x... forge script script/Lock.s.sol --rpc-url $MAINNET_RPC_URL` (add `SEND=1 --broadcast --ledger` or
/// `--account <name>` to send). docs/DEPLOY.md section 4
contract Lock is Script, LaunchChecks {
    /// @dev the signer is not the admin of the coin
    error NotCoinAdmin(address admin, address signer);
    /// @dev the recipients are still unlocked after the simulated transaction
    error NotLocked();
    /// @dev the hook pays another address than the fee router: the lock would freeze it
    error BountyRecipientNotRouter(address recipient, address router);

    function run() external {
        LaunchConfig memory c = _config();
        address core = _core();
        postflight(c, core);
        _print("postflight before the lock");
        _require();
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(ICore(payable(core)).COIN());
        if (t.recipientsLocked()) {
            console.log("the fee recipients are locked already, nothing to send");
            return;
        }
        address router = ICore(payable(core)).FEE_SOURCE();
        address recipient = address(_hookSkim(c.stack.hook, t.canonicalPoolId()).bountyRecipient);
        if (recipient != router) revert BountyRecipientNotRouter(recipient, router);
        console.log("coin", address(t));
        console.log("coin admin", t.admin());
        console.log("lockRecipients calldata");
        console.logBytes(abi.encodeCall(IArtCoinsTokenV2.lockRecipients, ()));
        console.log(string.concat("cast send ", vm.toString(address(t)), " \"lockRecipients()\""));
        if (!_send()) {
            console.log("nothing sent. add SEND=1 and --broadcast with the coin admin as signer to send");
            return;
        }
        address signer = _startBroadcast();
        if (signer != t.admin()) revert NotCoinAdmin(t.admin(), signer);
        t.lockRecipients();
        vm.stopBroadcast();
        if (!t.recipientsLocked()) revert NotLocked();
        console.log("simulated: the fee recipients read as locked after the transaction");
        console.log("confirm on chain once it is mined: Postflight with RECIPIENTS_LOCKED=1");
    }

    /// @dev the launch config (LAUNCH_CONFIG or the shipped file), the Core (CORE), the broadcast flag (SEND=1) and the
    /// start of the broadcast. a test overrides them
    function _config() internal virtual returns (LaunchConfig memory) {
        return loadConfig(vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE));
    }

    function _core() internal view virtual returns (address) {
        return vm.envAddress("CORE");
    }

    function _send() internal view virtual returns (bool) {
        return vm.envOr("SEND", uint256(0)) == 1;
    }

    function _startBroadcast() internal virtual returns (address signer) {
        vm.startBroadcast();
        (, signer,) = vm.readCallers();
    }
}
