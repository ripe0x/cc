// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {ControllerV1} from "../src/ControllerV1.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactory, IArtCoinsToken, IArtCoinsSkimHook} from "../src/interfaces/ArtCoins.sol";
import {Deployed} from "../script/Deploy.s.sol";
import {SystemResumer, Stage} from "../script/Resume.s.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {Report} from "../script/Report.sol";

/// @notice `script/Resume.s.sol` on the pinned fork: a deploy stopped after each of the first four transactions is
/// finished by sending only the missing steps, as the original deployer
contract ResumeTest is Test, SystemResumer {
    address internal deployer;
    address internal owner;
    address internal creator;
    LaunchConfig internal base;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        deployer = makeAddr("resume.deployer");
        owner = makeAddr("resume.owner");
        creator = makeAddr("resume.creator");
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        IArtCoinsFactory(Mainnet.ARTCOINS_FACTORY).setAdmin(deployer, true);
        vm.deal(deployer, 2 ether);
        base = defaultConfig();
        base.owner = owner;
        base.creator = creator;
        base.name = "Resume Coin";
        base.symbol = "RSM";
        base.salt = keccak256("resume");
    }

    /// @dev the first `n` of the five transactions, by hand, as the deployer
    function _steps(uint256 n) internal returns (address core, address coin) {
        uint64 nonce = vm.getNonce(deployer);
        core = vm.computeCreateAddress(deployer, nonce + 1);
        address coinAt = predictCoin(base, deployer, core);
        vm.startPrank(deployer);
        address ctl = address(new ControllerV1(core));
        if (n >= 2) new Core(owner, coinAt, ctl, base.stack, base.rateStart, base.econ);
        if (n >= 3) coin = _launch(base, deployer, coinAt, core);
        if (n >= 4) _lock(base, poolKeyOf(coin, base.stack));
        vm.stopPrank();
    }

    function stageOf(address core) external view returns (Stage) {
        return detectStage(base, core);
    }

    function resume(address who, LaunchConfig memory c, address core) external returns (Stage from) {
        vm.stopPrank();
        vm.startPrank(who);
        (from,) = resumeSystem(who, c, core);
        vm.stopPrank();
    }

    function _assertDone(address core, Stage expectFrom) internal {
        Stage from = this.resume(deployer, base, core);
        assertEq(uint256(from), uint256(expectFrom), "stage found");
        assertEq(uint256(detectStage(base, core)), uint256(Stage.Done));
        address coin = Core(payable(core)).COIN();
        assertEq(IArtCoinsToken(coin).admin(), owner, "the owner is the token admin");
        postflight(base, core);
        (string memory list,) = _failed();
        assertEq(list, "", "postflight is clean");
    }

    function test_resumeAfterTheCore() public {
        (address core,) = _steps(2);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.CoreOnly));
        _assertDone(core, Stage.CoreOnly);
    }

    function test_resumeAfterTheLaunch() public {
        (address core,) = _steps(3);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Launched));
        _assertDone(core, Stage.Launched);
    }

    function test_resumeAfterTheLock() public {
        (address core,) = _steps(4);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Locked));
        _assertDone(core, Stage.Locked);
    }

    /// a finished deploy: nothing is sent, the nonce does not move
    function test_resumeWhenDoneSendsNothing() public {
        (address core,) = _steps(4);
        address coin = Core(payable(core)).COIN();
        vm.prank(deployer);
        IArtCoinsToken(coin).updateAdmin(owner);
        uint64 nonce = vm.getNonce(deployer);
        uint256 bal = deployer.balance;
        _assertDone(core, Stage.Done);
        assertEq(vm.getNonce(deployer), nonce);
        assertEq(deployer.balance, bal);
    }

    function test_resumeRefusesWhatItCannotFinish() public {
        // no core
        vm.expectRevert(
            abi.encodeWithSelector(CoreMismatch.selector, "no code at the core address, run Deploy instead")
        );
        this.resume(deployer, base, makeAddr("nothing"));

        (address core,) = _steps(3);
        // a core built from another config
        LaunchConfig memory c = base;
        c.owner = creator;
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "owner"));
        this.resume(deployer, c, core);
        c = base;
        c.rateStart = base.rateStart + 1;
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "rateStart"));
        this.resume(deployer, c, core);
        // another name changes the coin prediction
        c = base;
        c.name = "Other";
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "coin prediction (config or deployer)"));
        this.resume(deployer, c, core);
        // a stranger is not the deployer of the run: the prediction does not hold, and it cannot lock or hand over
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "coin prediction (config or deployer)"));
        this.resume(stranger, base, core);
        // the real deployer still finishes it
        _assertDone(core, Stage.Launched);
    }

    /// the launch step needs the deployer to still be allowed on the factory
    function test_resumeLaunchNeedsTheDeployerEnabled() public {
        (address core,) = _steps(2);
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        IArtCoinsFactory(Mainnet.ARTCOINS_FACTORY).setAdmin(deployer, false);
        vm.expectRevert(abi.encodeWithSelector(Report.ChecksFailed.selector, "factory: deployer may launch"));
        this.resume(deployer, base, core);
        // after the lock the factory is no longer needed: a revoked deployer can still hand over
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        IArtCoinsFactory(Mainnet.ARTCOINS_FACTORY).setAdmin(deployer, true);
        this.resume(deployer, base, core);
        assertEq(uint256(detectStage(base, core)), uint256(Stage.Done));
    }

    function test_resumeHandoverNeedsNoFactory() public {
        (address core,) = _steps(4);
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        IArtCoinsFactory(Mainnet.ARTCOINS_FACTORY).setAdmin(deployer, false);
        _assertDone(core, Stage.Locked);
        // the hook slot stays locked and empty
        bytes32 id = keccak256(abi.encode(poolKeyOf(Core(payable(core)).COIN(), base.stack)));
        assertTrue(IArtCoinsSkimHook(base.stack.hook).poolExtensionLocked(id));
    }
}
