// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LaunchConfig} from "./LaunchConfig.sol";
import {SystemDeployer, Deployed} from "./SystemDeployer.sol";

/// @notice how far a deploy got. read from the chain, never from a file
/// TODO(v2 port stage 3): the stages of the v2 deploy are: router, Core, launch, router setup. the v2 launch is one
/// transaction (no extension lock, no admin handover), so a resume is the router setup only
enum Stage {
    NoCore, // no code at the core address, nothing to resume
    CoreOnly, // core deployed, the launch through the factory is not sent
    Launched, // coin launched, the router is not set up
    Locked, // unused until stage 3
    Done // router set up
}

/// @notice finishes a deploy that stopped half way. TODO(v2 port stage 3): not ported, every call reverts
abstract contract SystemResumer is SystemDeployer {
    /// @notice the resume is not ported to the v2 stack yet
    error ResumeNotPorted();
    /// @notice the core at the given address was not built from this config
    error CoreMismatch(string what);
    /// @notice the caller is not the token admin, so it cannot lock or hand over
    error NotTokenAdmin(address admin, address caller);

    function detectStage(LaunchConfig memory, address) internal pure returns (Stage) {
        revert ResumeNotPorted();
    }

    function resumeSystem(address, LaunchConfig memory, address) internal pure returns (Stage, Deployed memory) {
        revert ResumeNotPorted();
    }
}
