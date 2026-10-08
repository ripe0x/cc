// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ProdDeployer} from "./utils/ProdDeployer.sol";
import {Prod} from "./utils/Prod.sol";
import {Test} from "forge-std/Test.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {IArtCoinsFactory, IArtCoinsToken, IArtCoinsSkimHook} from "../src/interfaces/ArtCoins.sol";
import {Deployed} from "../script/SystemDeployer.sol";
import {SystemResumer, Stage} from "../script/SystemResumer.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {Report} from "../script/Report.sol";

interface IHouseFactoryR {
    function houseOf(address owner) external view returns (address);
}

/// @notice `script/SystemResumer.sol` on the pinned fork: a deploy stopped after each of the transactions (the library, the
/// controller, the core with its house, the launch, the lock, the handover) is finished by sending only the missing
/// steps, as the original deployer. the library goes through the deterministic deployer in a broadcast and takes one
/// deployer nonce, so the tests send it through that deployer too and bump the nonce by hand (a test prank sends no
/// transaction)
contract ResumeTest is Test, SystemResumer, ProdDeployer {
    bool internal scriptMode;
    /// @dev SETTINGS_CHANGED of the operator, a flag here so parallel tests never share an environment variable
    bool internal changedFlag;

    function _settingsChanged() internal view override returns (bool) {
        return changedFlag;
    }

    /// @dev OWNER_CHANGED of the operator, a flag here for the same reason
    bool internal ownerFlag;

    function _ownerChanged() internal view override returns (bool) {
        return ownerFlag;
    }

    function _scriptContext() internal view override returns (bool) {
        return scriptMode;
    }

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

    /// @dev the first `n` of the six transactions, by hand, as the deployer: 1 library, 2 controller, 3 core, 4 launch,
    /// 5 lock. the handover is the sixth
    function _steps(uint256 n) internal returns (address core, address coin) {
        scriptMode = true;
        if (n >= 1) _sendLibrary();
        uint64 nonce = vm.getNonce(deployer);
        core = vm.computeCreateAddress(deployer, nonce + 1);
        address coinAt = predictCoin(base, deployer, core);
        vm.startPrank(deployer);
        if (n >= 2) address(Prod.newController(core, base.sale));
        if (n >= 3) {
            Prod.newCore(owner, coinAt, vm.computeCreateAddress(deployer, nonce), base.stack, base.rateStart, base.settings);
        }
        if (n >= 4) coin = _launch(base, deployer, coinAt, core);
        if (n >= 5) _lock(base, poolKeyOf(coin, base.stack));
        vm.stopPrank();
        scriptMode = false;
    }

    /// @dev the first transaction of a broadcast: the library through the deterministic deployer, from the deployer
    function _sendLibrary() internal {
        assertTrue(_libraryTxPending(), "the library is not on chain yet");
        vm.prank(deployer);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(0), vm.getCode("CoreLib.sol:CoreLib")));
        assertTrue(ok, "the library create2 failed");
        vm.setNonce(deployer, vm.getNonce(deployer) + 1);
        assertFalse(_libraryTxPending(), "the library is on chain now");
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
        address coin = ICore(payable(core)).COIN();
        assertEq(IArtCoinsToken(coin).admin(), owner, "the owner is the token admin");
        postflight(base, core);
        (string memory list,) = _failed();
        assertEq(list, "", "postflight is clean");
    }

    function test_resumeAfterTheCore() public {
        (address core,) = _steps(3);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.CoreOnly));
        _assertDone(core, Stage.CoreOnly);
    }

    function test_resumeAfterTheLaunch() public {
        (address core,) = _steps(4);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Launched));
        _assertDone(core, Stage.Launched);
    }

    function test_resumeAfterTheLock() public {
        (address core,) = _steps(5);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Locked));
        _assertDone(core, Stage.Locked);
    }

    /// a finished deploy: nothing is sent, the nonce does not move
    function test_resumeWhenDoneSendsNothing() public {
        (address core,) = _steps(5);
        address coin = ICore(payable(core)).COIN();
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

        (address core,) = _steps(4);
        // a core built from another config
        LaunchConfig memory c = base;
        c.owner = creator;
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "owner (OWNER_CHANGED=1 after a handover)"));
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
        (address core,) = _steps(3);
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

    /// S-6: after the owner role and the token admin both moved on, OWNER_CHANGED=1 counts the admin as handed over
    function test_resumeOwnerChangedTreatsAHandedOverAdminAsDone() public {
        (address core,) = _steps(5);
        _assertDone(core, Stage.Locked);
        address next = makeAddr("resume.next");
        address coin = ICore(payable(core)).COIN();
        vm.startPrank(owner);
        ICore(payable(core)).transferOwnership(next);
        IArtCoinsToken(coin).updateAdmin(next);
        vm.stopPrank();
        vm.prank(next);
        ICore(payable(core)).acceptOwnership();
        assertEq(uint256(detectStage(base, core)), uint256(Stage.Locked), "no flag, the admin looks unfinished");
        ownerFlag = true;
        assertEq(uint256(detectStage(base, core)), uint256(Stage.Done), "flag set, the handover is done");
        Stage from = this.resume(deployer, base, core);
        assertEq(uint256(from), uint256(Stage.Done), "nothing is sent");
        postflight(base, core);
        (string memory list,) = _failed();
        assertEq(list, "", "postflight reports the handover as warnings only");
    }

    function test_resumeHandoverNeedsNoFactory() public {
        (address core,) = _steps(5);
        vm.prank(Mainnet.ARTCOINS_FACTORY_OWNER);
        IArtCoinsFactory(Mainnet.ARTCOINS_FACTORY).setAdmin(deployer, false);
        _assertDone(core, Stage.Locked);
        // the hook slot stays locked and empty
        bytes32 id = keccak256(abi.encode(poolKeyOf(ICore(payable(core)).COIN(), base.stack)));
        assertTrue(IArtCoinsSkimHook(base.stack.hook).poolExtensionLocked(id));
    }

    function requireDeployerExt(address want, address got) external pure {
        _requireDeployer(want, got);
    }

    /// the core created its own house in its constructor: it is there at the first resume point, owned by the core
    function test_theHouseExistsFromTheCoreOn() public {
        (address core,) = _steps(3);
        address house = IHouseFactoryR(base.stack.auctionFactory).houseOf(core);
        assertTrue(house != address(0) && house.code.length != 0, "no house");
        assertEq(address(ICore(payable(core)).HOUSE()), house);
        _assertDone(core, Stage.CoreOnly);
    }

    /// resume point 0: only the library is on chain. nothing to resume (no core), rerunning Deploy is safe: the library
    /// is skipped and takes no second nonce, so the addresses of a rerun are the ones preflight predicts now
    function test_libraryOnlyThenRerunDeploy() public {
        _steps(1);
        address someCore = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(CoreMismatch.selector, "no code at the core address, run Deploy instead")
        );
        this.resume(deployer, base, someCore);
        scriptMode = true;
        assertFalse(_libraryTxPending(), "a rerun skips the library");
        assertEq(_controllerNonce(deployer), vm.getNonce(deployer), "and takes no nonce");
        scriptMode = false;
        vm.startPrank(deployer);
        Deployed memory d = deploySystem(deployer, base);
        vm.stopPrank();
        assertEq(d.core, someCore, "the rerun lands where the preflight said");
    }

    /// resume point 0b: library and controller are on chain, the core is not. the controller is inert. no resume, the
    /// way on is a rerun of Deploy (new controller, new core) or the saved core transaction at its own nonce
    function test_orphanControllerIsInert() public {
        (address core,) = _steps(2);
        assertEq(core.code.length, 0, "no core");
        address controller = vm.computeCreateAddress(deployer, vm.getNonce(deployer) - 1);
        assertEq(address(IControllerV1(controller).CORE()), core, "it points at the core that never came");
        assertEq(controller.balance, 0);
        vm.expectRevert(
            abi.encodeWithSelector(CoreMismatch.selector, "no code at the core address, run Deploy instead")
        );
        this.resume(deployer, base, core);
        // sending the saved core creation at the next nonce gives the predicted core, and Resume goes on from there
        address coinAt = predictCoin(base, deployer, core);
        vm.startPrank(deployer);
        address c2 = address(Prod.newCore(owner, coinAt, controller, base.stack, base.rateStart, base.settings));
        vm.stopPrank();
        assertEq(c2, core, "the saved creation lands on the predicted core");
        _assertDone(core, Stage.CoreOnly);
    }

    /// the owner can call setSettings the moment the core exists: Resume does not finish a core whose settings are not
    /// the signed ones unless the operator says so
    function test_resumeRefusesChangedSettings() public {
        (address core,) = _steps(4);
        Settings memory s = ICore(payable(core)).settings();
        s.saleFloorBps = 8_000;
        vm.prank(owner);
        ICore(payable(core)).setSettings(s);
        vm.expectRevert(
            abi.encodeWithSelector(CoreMismatch.selector, "settings (SETTINGS_CHANGED=1 if the owner changed them)")
        );
        this.resume(deployer, base, core);
        // on purpose: the rest is sent, and postflight reads the difference as a warning
        changedFlag = true;
        Stage from = this.resume(deployer, base, core);
        assertEq(uint256(from), uint256(Stage.Launched));
        assertEq(uint256(detectStage(base, core)), uint256(Stage.Done));
    }

    /// the signer must be the deployer the operator named
    function test_deployerMustBeTheNamedOne() public {
        this.requireDeployerExt(deployer, deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, owner, deployer));
        this.requireDeployerExt(owner, deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, address(0), deployer));
        this.requireDeployerExt(address(0), deployer);
    }
}
