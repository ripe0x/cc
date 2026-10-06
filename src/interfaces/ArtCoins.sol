// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// local copies of the live artcoins factory structs and the minimal interfaces this repo calls. artcoins is not a
/// dependency. every struct and selector here was executed against the live contracts on a mainnet fork, and the
/// field order must match the live ABI exactly, so do not reorder anything.

/// @notice factory entry point and the structs it takes
interface IArtCoinsFactory {
    struct TokenConfig {
        address tokenAdmin;
        string name;
        string symbol;
        bytes32 salt;
        string image;
        string metadata;
        string context;
        uint256 totalSupply;
        address renderer;
    }

    struct PoolConfig {
        address hook;
        address pairedToken;
        int24 tickIfToken0IsArtCoins;
        int24 tickSpacing;
        bytes poolData;
    }

    struct LockerConfig {
        address locker;
        address[] rewardAdmins;
        address[] rewardRecipients;
        uint16[] rewardBps;
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionBps;
        bytes lockerData;
    }

    struct MevModuleConfig {
        address mevModule;
        bytes mevModuleData;
    }

    struct SniperFeeConfig {
        address recipient;
        bool lockRecipient;
    }

    struct ExtensionConfig {
        address extension;
        uint256 msgValue;
        uint16 extensionBps;
        bytes extensionData;
    }

    struct DeploymentConfig {
        TokenConfig tokenConfig;
        PoolConfig poolConfig;
        LockerConfig lockerConfig;
        MevModuleConfig mevModuleConfig;
        SniperFeeConfig sniperFeeConfig;
        ExtensionConfig[] extensionConfigs;
    }

    struct TaxVenue {
        uint8 kind;
        address factory;
        bytes32 initCodeHash;
        address counterToken;
        uint24 v3Fee;
    }

    struct TaxConfig {
        bool enabled;
        uint16 taxBps;
        uint16 taxBpsMax;
        address burnAddress;
        address poolManager;
        address canonicalHook;
        address pairedToken;
        uint24 canonicalPoolFee;
        int24 canonicalTickSpacing;
        address[] exempt;
        TaxVenue[] venues;
    }

    function deprecated() external view returns (bool);
    function deployFee() external view returns (uint256);
    function owner() external view returns (address);
    function admins(address who) external view returns (bool);
    function enabledHooks(address hook) external view returns (bool);
    function enabledLockers(address locker, address hook) external view returns (bool);
    function enabledMevModules(address mevModule) external view returns (bool);
    function setAdmin(address admin, bool isAdmin) external;

    function deployTokenWithProtocolBpsAndTax(DeploymentConfig memory cfg, uint16 protocolBps, TaxConfig memory tax)
        external
        payable
        returns (address token);
}

/// @notice the part of the token the core and the deploy use
interface IArtCoinsToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;

    function admin() external view returns (address);
    function originalAdmin() external view returns (address);
    function updateAdmin(address newAdmin) external;
    function setTaxBps(uint16 newBps) external;

    function taxEnabled() external view returns (bool);
    function taxBps() external view returns (uint16);
    function taxBpsMax() external view returns (uint16);
    function taxBurnAddress() external view returns (address);
    function canonicalHook() external view returns (address);
    function canonicalPoolId() external view returns (bytes32);
    function taxPoolManager() external view returns (address);
    function isTaxVenue(address account) external view returns (bool);
    function isTaxExempt(address account) external view returns (bool);
}

/// @notice the skim hook views and the token admin calls this repo uses
interface IArtCoinsSkimHook {
    function skimConfig(bytes32 poolId)
        external
        view
        returns (
            uint24 baselineSkimBps,
            uint16 bountyBps,
            uint24 maxReferralBpsOfVolume,
            uint24 lpFee,
            address bountyRecipient,
            address protocolRecipient,
            address referralPayout,
            address quoteToken
        );

    function poolTaxEnabled(bytes32 poolId) external view returns (bool);
    function poolExtensionLocked(bytes32 poolId) external view returns (bool);
    function poolExtension(bytes32 poolId) external view returns (address);
    function mevModuleEnabled(bytes32 poolId) external view returns (bool);
    function poolCreationTimestamp(bytes32 poolId) external view returns (uint256);
    function lockPoolExtension(PoolKey calldata key) external;
    function setMaxReferralBpsOfVolume(PoolKey calldata key, uint24 newCap) external;
}

/// @notice the hook may call this on the bounty recipient before every swap once its balance is 0.01 eth or more.
/// the core deliberately does not implement it, so the call reverts and the hook catches that
interface IPreSwapStream {
    function streamForward() external returns (uint256);
}

/// @notice referral payout target of the skim hook
interface IReferralPayout {
    function notify(address referrer) external payable;
}

interface IArtCoinsLocker {
    struct TokenRewardInfo {
        address token;
        PoolKey poolKey;
        uint256 positionId;
        uint256 numPositions;
        uint16[] rewardBps;
        address[] rewardAdmins;
        address[] rewardRecipients;
    }

    function collectRewards(address token) external;
    function tokenRewards(address token) external view returns (TokenRewardInfo memory);
}

interface IArtCoinsFeeEscrow {
    function availableFees(address feeOwner, address token) external view returns (uint256);
    function claim(address feeOwner, address token) external;
}

interface IArtCoinsMevSkim {
    function currentSkimBps(bytes32 poolId) external view returns (uint24);
}
