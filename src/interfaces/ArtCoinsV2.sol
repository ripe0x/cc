// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// local copies of the artcoins v2 structs and the minimal interfaces this repo calls (v2 repo commit d4aa46b,
/// src/v2/interfaces). artcoins is not a dependency. the field order must match the v2 abi exactly, so do not
/// reorder anything. members the v2 interface files lack but the v2 contracts expose are marked.

interface IArtCoinsFactoryV2 {
    struct TokenConfigV2 {
        address tokenAdmin;
        string name;
        string symbol;
        bytes32 salt;
        string image;
        string description;
        uint256 totalSupply;
        address renderer;
    }

    struct PoolConfigV2 {
        address hook;
        int24 tickIfToken0IsCoin;
        int24 tickSpacing;
        address extension;
        bytes extensionData;
    }

    struct FeeConfigV2 {
        uint24 lpFeePips;
        uint24 baselineSkimBps;
        uint16 bountyBps;
        uint24 maxReferralBpsOfVolume;
        address payable bountyRecipient;
    }

    struct LockerConfigV2 {
        address locker;
        address[] rewardRecipients;
        uint16[] rewardBps;
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionBps;
    }

    struct MevConfigV2 {
        address module;
        uint24 startingSkimBps;
        uint32 windowSeconds;
    }

    struct RestrictionConfigV2 {
        bool restricted;
        address[] allowed;
    }

    struct ExtensionConfigV2 {
        address extension;
        uint256 msgValue;
        uint16 extensionBps;
        bytes extensionData;
    }

    struct DeploymentConfigV2 {
        TokenConfigV2 token;
        PoolConfigV2 pool;
        FeeConfigV2 fee;
        LockerConfigV2 locker;
        MevConfigV2 mev;
        RestrictionConfigV2 restriction;
        ExtensionConfigV2[] extensions;
    }

    struct DeploymentInfoV2 {
        address token;
        address hook;
        address locker;
        address mevModule;
        address escrow;
        bytes32 poolId;
        bytes32 configHash;
        uint16 version;
        uint40 launchedAt;
        bool restricted;
        address[] extensions;
    }

    function deployToken(DeploymentConfigV2 calldata c) external payable returns (address token);
    function deployTokenAsOwner(DeploymentConfigV2 calldata c, uint16 protocolBps)
        external
        payable
        returns (address token);
    function predictToken(address sender, DeploymentConfigV2 calldata c) external view returns (address);
    function configHash(DeploymentConfigV2 calldata c) external pure returns (bytes32);

    function STACK_VERSION() external view returns (uint16);
    function owner() external view returns (address);
    function poolManager() external view returns (address);
    function tokenDeployer() external view returns (address);
    function isCoin(address token) external view returns (bool);
    function deploymentInfo(address token) external view returns (DeploymentInfoV2 memory);
    function deprecated() external view returns (bool);
    function deployFee() external view returns (uint256);
    function defaultProtocolFeeBps() external view returns (uint16);
    function minProtocolSkimShareBps() external view returns (uint16);
    function protocolRecipient() external view returns (address payable);
    function teamFeeRecipient() external view returns (address);
    function enabledHooks(address hook) external view returns (bool);
    function enabledLockers(address locker) external view returns (bool);
    function enabledMevModules(address module) external view returns (bool);
    function enabledExtensions(address extension) external view returns (bool);
    function defaultAllowed() external view returns (address[] memory);

    function setHook(address hook, bool enabled) external;
    function setLocker(address locker, bool enabled) external;
    function setMevModule(address module, bool enabled) external;
    function setExtension(address extension, bool enabled) external;
    function setDeprecated(bool deprecated_) external;
    function setDeployFee(uint256 fee) external;
    function setDefaultProtocolFeeBps(uint16 bps) external;
    function setMinProtocolSkimShareBps(uint16 bps) external;
    function setProtocolRecipient(address payable recipient) external;
    function setTeamFeeRecipient(address recipient) external;
    function setDefaultAllowed(address[] calldata accounts) external;
    function setTokenDeployer(address deployer) external; // not in the v2 interface file, on the contract
}

interface IArtCoinsHookV2 {
    struct PoolInfo {
        uint16 version;
        bool restricted;
        uint40 createdAt;
        address launcher;
        address token;
        address locker;
        address mevModule;
        address extension;
    }

    struct SkimConfig {
        uint24 baselineSkimBps;
        uint16 bountyBps;
        uint24 maxReferralBpsOfVolume;
        uint24 lpFeePips;
        address payable bountyRecipient;
        address payable protocolRecipient;
    }

    struct HookGlobals {
        address feeEscrow;
        address extensionAllowlist;
    }

    function poolInfo(bytes32 poolId) external view returns (PoolInfo memory);
    function isOfficialPool(bytes32 poolId) external view returns (bool);
    function skimConfig(bytes32 poolId) external view returns (SkimConfig memory);
    function minProtocolShareBps(bytes32 poolId) external view returns (uint16);
    function globals() external view returns (HookGlobals memory);
    function isLauncher(address launcher) external view returns (bool);
    function constantsHash() external pure returns (bytes32);
    function poolManager() external view returns (address); // BaseHook getter, not in the v2 interface file
    function setLauncher(address launcher, bool enabled) external;
    function setFeeEscrow(address escrow) external;
    function setExtensionAllowlist(address allowlist) external;
    function setBountyRecipient(bytes32 poolId, address payable newRecipient) external;
}

interface IArtCoinsTokenV2 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function restricted() external view returns (bool);
    function isAllowed(address account) external view returns (bool);
    function isPinned(address account) external view returns (bool);
    function transferAllowance() external view returns (uint256);
    function canonicalHook() external view returns (address);
    function canonicalPoolId() external view returns (bytes32);
    function poolManager() external view returns (address);
    function admin() external view returns (address);
    function launcher() external view returns (address);
    function setAllowed(address account, bool allowed) external;
    function unrestrict() external;
    function lockAllowlist() external;
    function lockRecipients() external;
    function allowlistLocked() external view returns (bool);
    function recipientsLocked() external view returns (bool);
    function updateDescription(string calldata description_) external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function imageUrl() external view returns (string memory);
    function description() external view returns (string memory);
    function metadataRenderer() external view returns (address);
}

interface IArtCoinsLpLockerV2 {
    struct TokenRewardInfoV2 {
        address token;
        PoolKey poolKey;
        uint256 positionId;
        uint256 numPositions;
        uint16[] rewardBps;
        address[] rewardRecipients;
    }

    function collectRewards(address token) external;
    function tokenRewards(address token) external view returns (TokenRewardInfoV2 memory);
    function rewardRecipients(address token) external view returns (address[] memory);
    function rewardBps(address token) external view returns (uint16[] memory);
    function keeperRewardBps() external view returns (uint256);
    function feeEscrow() external view returns (address);
    function isLauncher(address launcher) external view returns (bool);
    function setRewardRecipient(address token, uint256 index, address newRecipient) external;
    function protocolSlotIndex(address token) external view returns (bool exists, uint256 index);
}

interface IArtCoinsFeeEscrowV2 {
    function claim(address feeOwner, address token) external;
    function claimTo(address feeOwner, address token, address payable recipient) external;
    function setSelfClaimOnly(bool on) external;
    function balances(address feeOwner, address token) external view returns (uint256);
    function totalOwed(address token) external view returns (uint256);
    function selfClaimOnly(address feeOwner) external view returns (bool);
    function isDepositor(address depositor) external view returns (bool);
    function isCoreDepositor(address depositor) external view returns (bool);
    function addDepositor(address depositor, bool core) external;
    function removeDepositor(address depositor) external;
}

interface IArtCoinsMevSkimV2 {
    /// the frozen per pool schedule. `schedule` is on the contract, not in the v2 interface file
    struct SkimSchedule {
        uint24 startingSkimBps;
        uint24 endSkimBps;
        uint32 windowSeconds;
        uint40 startTime;
    }

    function schedule(bytes32 poolId) external view returns (SkimSchedule memory);
    function currentSkimBps(bytes32 poolId) external view returns (uint24 skimBps, bool active);
    function windowEnd(bytes32 poolId) external view returns (uint40);
    function hook() external view returns (address);
}

interface IFeeAutoSwapperV2 {
    /// constructor bundle, declared on the FeeAutoSwapperV2 contract (not in the v2 interface file)
    struct Config {
        address owner;
        address poolManager;
        address feeEscrow;
        address hook;
        uint24 poolFee;
        int24 tickSpacing;
        address endRecipient;
        address coin;
        uint256 maxSlippageBps;
        uint256 minBlocksBetweenConverts;
        uint256 maxStepIn;
    }

    function convert(uint256 minOut) external returns (uint256 pairedOut);
    function flushPaired() external returns (uint256 pairedOut);
    function setup(address coin_) external;
    function setupFinalized() external view returns (bool);
    function coin() external view returns (address);
    function endRecipient() external view returns (address);
    function feeEscrow() external view returns (address);
}

interface IArtCoinsKeeperV2 {
    function collectAndForward(address token, bool doConvert, uint256 minOut) external;
    function factory() external view returns (address);
}

/// @dev OpenZeppelin Ownable2Step surface of the v2 escrow, hook, locker, factory, controller, router
interface IOwnable2StepV2 {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
