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

/// @notice deploys the real artcoins v2 stack onto the pinned fork from the vendored artifacts (test/v2-artifacts)
/// and wires it as script/v2/DeployV2Lib.sol does (v2 commit 87a7522), with the mainnet values of
/// script/v2/env/mainnet.env. nothing here imitates a v2 contract: all code comes from the artifacts.
/// the caller is the owner for the whole deploy (the broadcaster equals the owner, so no ownership handover).
/// `deprecated` stays true, as DeployV2Lib leaves it: only the owner can launch, through `deployTokenAsOwner`
library V2Stack {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant HOOK_LOW_BITS = 0x28CC;
    uint256 internal constant MAX_MINE = 400_000;
    uint256 internal constant EIP170 = 24_576;

    /// values of script/v2/env/mainnet.env
    address internal constant MAINNET_TREASURY = 0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4;
    uint16 internal constant MAINNET_TREASURY_BPS = 8667;
    uint256 internal constant MAINNET_DEPLOY_FEE = 0.069 ether;
    uint16 internal constant MAINNET_PROTOCOL_BPS = 2000;
    uint16 internal constant MAINNET_MIN_PROTOCOL_SKIM_SHARE_BPS = 1000;
    uint24 internal constant MAINNET_MIN_LP_FEE = 3000;

    struct Params {
        address owner;
        address treasury;
        uint16 treasuryBps;
        address referralPayout; // 0 = the escrow, as DeployV2Lib
        uint256 deployFee;
        uint16 protocolBps;
        uint16 minProtocolSkimShareBps;
        uint24 minLpFee;
    }

    struct Stack {
        address escrow;
        address allowlist;
        address hook;
        bytes32 hookSalt;
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
        p.minLpFee = MAINNET_MIN_LP_FEE;
    }

    /// @notice deploys, wires and checks the stack. gas of the whole run is the caller's to measure
    function deploy(Params memory p) internal returns (Stack memory s) {
        require(p.owner != address(0) && p.treasury != address(0), "v2: zero owner or treasury");
        require(CREATE2_DEPLOYER.code.length != 0, "v2: no CREATE2 deployer");
        vm.startPrank(p.owner);
        s.escrow = _create("ArtCoinsFeeEscrowV2", abi.encode(p.owner));
        s.allowlist = _create("ArtCoinsPoolExtensionAllowlist", abi.encode(p.owner));
        (s.hook, s.hookSalt) = _deployHook(p.owner, s.escrow, s.allowlist);
        s.locker = _create(
            "ArtCoinsLpLockerV2", abi.encode(p.owner, Mainnet.POSITION_MANAGER, Mainnet.PERMIT2, s.escrow)
        );
        s.mev = _create("ArtCoinsMevLinearSkimV2", abi.encode(s.hook));
        s.factory = _create(
            "ArtCoinsFactoryV2", abi.encode(p.owner, Mainnet.POOL_MANAGER, p.protocolBps, p.deployFee)
        );
        s.tokenDeployer = _create("ArtCoinsDeployerV2", abi.encode(s.factory));
        IArtCoinsFactoryV2(s.factory).setTokenDeployer(s.tokenDeployer);
        s.burnRouter = _create("BurnRouterV2", abi.encode(p.owner, Mainnet.POOL_MANAGER, s.escrow));
        s.controller = _create(
            "ProtocolFeeControllerV2", abi.encode(p.owner, s.escrow, p.treasury, s.burnRouter, p.treasuryBps)
        );
        s.keeper = _create("ArtCoinsKeeperV2", abi.encode(s.factory));
        _wire(s, p);
        vm.stopPrank();
        check(s, p);
    }

    function _create(string memory name, bytes memory args) private returns (address a) {
        bytes memory code = abi.encodePacked(vm.getCode(string.concat("test/v2-artifacts/", name, ".json")), args);
        assembly {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), string.concat("v2: create failed ", name));
    }

    function _deployHook(address owner, address escrow, address allowlist) private returns (address hook, bytes32 salt) {
        bytes memory initCode = abi.encodePacked(
            vm.getCode("test/v2-artifacts/ArtCoinsHookV2.json"),
            abi.encode(Mainnet.POOL_MANAGER, owner, escrow, allowlist)
        );
        bytes32 h = keccak256(initCode);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bool found;
        for (uint256 i; i < MAX_MINE; ++i) {
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), CREATE2_DEPLOYER, i, h)))));
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == flags && hook.code.length == 0) {
                salt = bytes32(i);
                found = true;
                break;
            }
        }
        require(found, "v2: no hook salt");
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && ret.length == 20 && address(bytes20(ret)) == hook, "v2: hook CREATE2");
    }

    /// @dev DeployV2Lib step 11: escrow depositors first, then hook, locker, factory
    function _wire(Stack memory s, Params memory p) private {
        IArtCoinsFeeEscrowV2 e = IArtCoinsFeeEscrowV2(s.escrow);
        e.addDepositor(s.hook, true);
        e.addDepositor(s.locker, true);
        e.addDepositor(s.controller, false);

        IArtCoinsHookV2 h = IArtCoinsHookV2(s.hook);
        h.setFeeEscrow(s.escrow);
        h.setExtensionAllowlist(s.allowlist);
        h.setLauncher(s.factory, true);

        // the locker setters are not in the engine interface
        _call(s.locker, abi.encodeWithSignature("setFeeEscrow(address)", s.escrow));
        _call(s.locker, abi.encodeWithSignature("setLauncher(address,bool)", s.factory, true));
        _call(s.locker, abi.encodeWithSignature("setKeeperRewardBps(uint256)", 0));

        address payout = p.referralPayout == address(0) ? s.escrow : p.referralPayout;
        IArtCoinsFactoryV2 f = IArtCoinsFactoryV2(s.factory);
        f.setHook(s.hook, true);
        f.setLocker(s.locker, true);
        f.setMevModule(s.mev, true);
        f.setEscrow(s.escrow, true);
        f.setProtocolRecipient(payable(s.controller));
        f.setReferralPayout(payable(payout));
        f.setTeamFeeRecipient(p.owner);
        f.setDeployFee(p.deployFee);
        f.setDefaultProtocolFeeBps(p.protocolBps);
        f.setMinProtocolSkimShareBps(p.minProtocolSkimShareBps);
        f.setMinLpFee(p.minLpFee);
        // defaultAllowed ships empty, the factory stays deprecated, as DeployV2Lib leaves them
    }

    function _call(address to, bytes memory data) private {
        (bool ok,) = to.call(data);
        require(ok, "v2: wiring call");
    }

    /// @notice the post deploy requires of DeployV2Lib.check. constantsHash is compared across the stack and to the
    /// hook (the engine does not carry v2's Constants library). owners are checked as direct (no handover)
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
        address payout = p.referralPayout == address(0) ? s.escrow : p.referralPayout;
        require(f.poolManager() == Mainnet.POOL_MANAGER, "v2: factory PoolManager");
        require(f.tokenDeployer() == s.tokenDeployer, "v2: factory deployer");
        require(IV2Reads(s.tokenDeployer).factory() == s.factory, "v2: deployer binding");
        require(f.enabledHooks(s.hook) && f.enabledLockers(s.locker), "v2: factory hook or locker");
        require(f.enabledMevModules(s.mev) && f.enabledEscrows(s.escrow), "v2: factory mev or escrow");
        require(f.protocolRecipient() == s.controller, "v2: protocol recipient");
        require(f.referralPayout() == payout && payout.code.length != 0, "v2: referral payout");
        require(f.teamFeeRecipient() == p.owner, "v2: team fee recipient");
        require(f.deployFee() == p.deployFee && f.defaultProtocolFeeBps() == p.protocolBps, "v2: fees");
        require(f.minProtocolSkimShareBps() == p.minProtocolSkimShareBps, "v2: min skim share");
        require(f.minLpFee() == p.minLpFee, "v2: min lp fee");
        require(f.defaultAllowed().length == 0, "v2: default allowed must ship empty");
        require(f.deprecated(), "v2: factory must ship deprecated");
    }

    /// @notice the vendored FeeAutoSwapperV2 for one coin, as the v2 docs deploy it: end recipient `endRecipient`,
    /// owner `owner`, the coin bound later by `setup`. the caller still registers it as an escrow depositor
    /// (`escrow.addDepositor(swapper, false)`, owner only) and calls `setup(coin)` as the deployer
    function deploySwapper(Stack memory s, address owner, address endRecipient, address artCoin)
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
            artCoin: artCoin,
            maxSlippageBps: 500,
            minBlocksBetweenConverts: 5,
            maxStepIn: 1000 ether
        });
        swapper = _create("FeeAutoSwapperV2", abi.encode(c));
    }
}
