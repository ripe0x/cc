// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Mainnet} from "../../src/interfaces/Interfaces.sol";
import {
    IArtCoinsFactoryV2,
    IArtCoinsHookV2,
    IArtCoinsLpLockerV2,
    IArtCoinsFeeEscrowV2,
    IArtCoinsMevSkimV2,
    IArtCoinsKeeperV2,
    IFeeAutoSwapperV2,
    IOwnable2StepV2
} from "../../src/interfaces/ArtCoinsV2.sol";

/// reads that exist on the v2 contracts but not in the engine interfaces
interface IV2Reads {
    function getHookPermissions() external pure returns (Hooks.Permissions memory);
    function constantsHash() external pure returns (bytes32);
    function factory() external view returns (address);
    function feeEscrow() external view returns (address);
    function treasury() external view returns (address);
    function treasuryBps() external view returns (uint16);
    function burnRouter() external view returns (address);
    function poolManager() external view returns (address);
    function coin() external view returns (address);
}

/// @notice the live artcoins v2 stack on the pinned fork. addresses come from script/config/v2-mainnet.json, the record
/// the scripts read as well. nothing here imitates a v2 contract. the factory owner of the record is the owner of the
/// whole stack and stays a deprecated factory (only the owner launches, through `deployTokenAsOwner`)
library V2Stack {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant RECORD = "script/config/v2-mainnet.json";
    uint160 internal constant HOOK_LOW_BITS = 0x28CC;
    uint256 internal constant EIP170 = 24_576;

    /// values of the live stack (script/v2/env/mainnet.env of the launcher)
    address internal constant MAINNET_TREASURY = 0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4;
    uint16 internal constant MAINNET_TREASURY_BPS = 8667;
    uint256 internal constant MAINNET_DEPLOY_FEE = 0.069 ether;
    uint16 internal constant MAINNET_PROTOCOL_BPS = 2000;
    uint16 internal constant MAINNET_MIN_PROTOCOL_SKIM_SHARE_BPS = 1000;

    struct Params {
        address owner;
        address treasury;
        uint16 treasuryBps;
        uint256 deployFee;
        uint16 protocolBps;
        uint16 minProtocolSkimShareBps;
    }

    struct Stack {
        address owner;
        address escrow;
        address allowlist;
        address hook;
        address locker;
        address mev;
        address factory;
        address tokenDeployer;
        address burnRouter;
        address controller;
        address keeper;
    }

    /// @notice the mainnet.env values with `owner` as the factory, escrow, hook and locker owner
    function mainnetParams(address owner) internal pure returns (Params memory p) {
        p.owner = owner;
        p.treasury = MAINNET_TREASURY;
        p.treasuryBps = MAINNET_TREASURY_BPS;
        p.deployFee = MAINNET_DEPLOY_FEE;
        p.protocolBps = MAINNET_PROTOCOL_BPS;
        p.minProtocolSkimShareBps = MAINNET_MIN_PROTOCOL_SKIM_SHARE_BPS;
    }

    /// @notice the stack of the record, read from script/config/v2-mainnet.json
    function live() internal view returns (Stack memory s) {
        string memory j = vm.readFile(RECORD);
        s.owner = vm.parseJsonAddress(j, ".owner");
        s.escrow = vm.parseJsonAddress(j, ".escrow");
        s.allowlist = vm.parseJsonAddress(j, ".allowlist");
        s.hook = vm.parseJsonAddress(j, ".hook");
        s.locker = vm.parseJsonAddress(j, ".locker");
        s.mev = vm.parseJsonAddress(j, ".mevModule");
        s.factory = vm.parseJsonAddress(j, ".factory");
        s.tokenDeployer = vm.parseJsonAddress(j, ".tokenDeployer");
        s.burnRouter = vm.parseJsonAddress(j, ".burnRouter");
        s.controller = vm.parseJsonAddress(j, ".feeController");
        s.keeper = vm.parseJsonAddress(j, ".keeper");
    }

    /// @notice the live stack after `check` against the values of the record. run before any owner command changes a
    /// factory knob (`setMinProtocolSkimShareBps` moves the minimum share off the value `check` expects)
    function attach() internal view returns (Stack memory s) {
        s = live();
        check(s, mainnetParams(s.owner));
    }

    /// @notice the post deploy requires of DeployV2Lib.check against the live stack. constantsHash is compared across
    /// the stack and to the hook (the engine does not carry v2's Constants library). owners are checked as direct (no
    /// handover)
    function check(Stack memory s, Params memory p) internal view {
        bytes32 ch = IV2Reads(s.hook).constantsHash();
        require(ch != bytes32(0), "v2: constantsHash zero");
        address[8] memory bound = [s.escrow, s.hook, s.locker, s.mev, s.factory, s.tokenDeployer, s.burnRouter, s.controller];
        for (uint256 i; i < 8; ++i) require(IV2Reads(bound[i]).constantsHash() == ch, "v2: constantsHash");

        require(uint160(s.hook) & Hooks.ALL_HOOK_MASK == HOOK_LOW_BITS, "v2: hook low bits");
        Hooks.Permissions memory perms = IV2Reads(s.hook).getHookPermissions();
        Hooks.validateHookPermissions(IHooks(s.hook), perms);
        require(
            perms.beforeInitialize && !perms.afterInitialize && perms.beforeAddLiquidity && !perms.afterAddLiquidity
                && !perms.beforeRemoveLiquidity && !perms.afterRemoveLiquidity && perms.beforeSwap && perms.afterSwap
                && !perms.beforeDonate && !perms.afterDonate && perms.beforeSwapReturnDelta
                && perms.afterSwapReturnDelta && !perms.afterAddLiquidityReturnDelta
                && !perms.afterRemoveLiquidityReturnDelta,
            "v2: hook permissions"
        );
        require(IV2Reads(s.hook).poolManager() == Mainnet.POOL_MANAGER, "v2: hook PoolManager");
        IArtCoinsHookV2.HookGlobals memory g = IArtCoinsHookV2(s.hook).globals();
        require(g.feeEscrow == s.escrow, "v2: hook escrow");
        require(g.extensionAllowlist == s.allowlist, "v2: hook allowlist");
        require(IArtCoinsHookV2(s.hook).isLauncher(s.factory), "v2: hook launcher");

        IArtCoinsFeeEscrowV2 e = IArtCoinsFeeEscrowV2(s.escrow);
        require(e.isDepositor(s.hook) && e.isCoreDepositor(s.hook), "v2: hook dep");
        require(e.isDepositor(s.locker) && e.isCoreDepositor(s.locker), "v2: locker dep");
        require(e.isDepositor(s.controller) && !e.isCoreDepositor(s.controller), "v2: controller dep");

        IArtCoinsLpLockerV2 l = IArtCoinsLpLockerV2(s.locker);
        require(l.feeEscrow() == s.escrow, "v2: locker escrow");
        require(l.isLauncher(s.factory), "v2: locker launcher");
        require(l.keeperRewardBps() == 0, "v2: locker keeper reward");
        _checkFactory(s, p);

        require(IArtCoinsMevSkimV2(s.mev).hook() == s.hook, "v2: mev hook");
        require(IArtCoinsKeeperV2(s.keeper).factory() == s.factory, "v2: keeper factory");
        IV2Reads c = IV2Reads(s.controller);
        require(c.feeEscrow() == s.escrow && c.treasury() == p.treasury, "v2: controller escrow or treasury");
        require(c.burnRouter() == s.burnRouter && c.treasuryBps() == p.treasuryBps, "v2: controller router or split");
        require(IV2Reads(s.burnRouter).feeEscrow() == s.escrow, "v2: router escrow");
        require(IV2Reads(s.burnRouter).poolManager() == Mainnet.POOL_MANAGER, "v2: router PoolManager");
        require(IV2Reads(s.burnRouter).coin() == address(0), "v2: router initialized early");

        address[4] memory owned = [s.escrow, s.hook, s.locker, s.factory];
        for (uint256 i; i < 4; ++i) {
            require(
                IOwnable2StepV2(owned[i]).owner() == p.owner && IOwnable2StepV2(owned[i]).pendingOwner() == address(0),
                "v2: owner"
            );
        }
        require(IOwnable2StepV2(s.allowlist).owner() == p.owner, "v2: allowlist owner");
        require(IOwnable2StepV2(s.burnRouter).owner() == p.owner, "v2: router owner");
        require(IOwnable2StepV2(s.controller).owner() == p.owner, "v2: controller owner");

        address[10] memory all = [
            s.escrow, s.allowlist, s.hook, s.locker, s.mev, s.factory, s.tokenDeployer, s.burnRouter, s.controller,
            s.keeper
        ];
        for (uint256 i; i < 10; ++i) {
            require(all[i].code.length != 0 && all[i].code.length <= EIP170, "v2: runtime size");
        }
    }

    function _checkFactory(Stack memory s, Params memory p) private view {
        IArtCoinsFactoryV2 f = IArtCoinsFactoryV2(s.factory);
        require(f.poolManager() == Mainnet.POOL_MANAGER, "v2: factory PoolManager");
        require(f.tokenDeployer() == s.tokenDeployer, "v2: factory deployer");
        require(IV2Reads(s.tokenDeployer).factory() == s.factory, "v2: deployer binding");
        require(f.enabledHooks(s.hook) && f.enabledLockers(s.locker), "v2: factory hook or locker");
        require(f.enabledMevModules(s.mev), "v2: factory mev");
        require(f.protocolRecipient() == s.controller, "v2: protocol recipient");
        require(f.teamFeeRecipient() == p.owner, "v2: team fee recipient");
        require(f.deployFee() == p.deployFee && f.defaultProtocolFeeBps() == p.protocolBps, "v2: fees");
        require(f.minProtocolSkimShareBps() == p.minProtocolSkimShareBps, "v2: min skim share");
        require(f.defaultAllowed().length == 0, "v2: default allowed must ship empty");
        require(f.deprecated(), "v2: factory must ship deprecated");
        require(f.STACK_VERSION() == 2, "v2: stack version");
    }

    /// @notice the FeeAutoSwapperV2 for one coin, as the v2 docs deploy it: end recipient `endRecipient`, owner `owner`,
    /// the coin bound later by `setup`. it is deployed per coin and is not part of the live stack, so its build output
    /// is vendored (test/v2-artifacts). the caller still registers it as an escrow depositor
    /// (`escrow.addDepositor(swapper, false)`, owner only) and calls `setup(coin)` as the deployer
    function deploySwapper(Stack memory s, address owner, address endRecipient, address coin_)
        internal
        returns (address swapper)
    {
        IFeeAutoSwapperV2.Config memory c = IFeeAutoSwapperV2.Config({
            owner: owner,
            poolManager: Mainnet.POOL_MANAGER,
            feeEscrow: s.escrow,
            hook: s.hook,
            poolFee: Mainnet.POOL_FEE,
            tickSpacing: Mainnet.TICK_SPACING,
            endRecipient: endRecipient,
            coin: coin_,
            maxSlippageBps: 500,
            minBlocksBetweenConverts: 5,
            maxStepIn: 1000 ether
        });
        bytes memory code = abi.encodePacked(vm.getCode("test/v2-artifacts/FeeAutoSwapperV2.json"), abi.encode(c));
        assembly {
            swapper := create(0, add(code, 0x20), mload(code))
        }
        require(swapper != address(0), "v2: swapper create failed");
    }
}
