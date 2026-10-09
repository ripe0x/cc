// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ProdDeployer} from "./utils/ProdDeployer.sol";
import {Prod} from "./utils/Prod.sol";
import {V2Stack} from "./utils/V2Stack.sol";
import {Test} from "forge-std/Test.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {IArtCoinsFactoryV2, IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {Deployed} from "../script/SystemDeployer.sol";
import {SystemResumer, Stage} from "../script/SystemResumer.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {Report} from "../script/Report.sol";

interface IHouseFactoryR {
    function houseOf(address owner) external view returns (address);
}

/// @notice `script/SystemResumer.sol` on the pinned fork with the v2 stack deployed onto it: a deploy stopped after each of
/// the transactions (the library, the controller, the router, the core with its house, the launch, the router engine,
/// the router payees, the split start) is finished by sending only the missing steps, as the original deployer, who is
/// the factory owner and the config owner. the library goes through the deterministic deployer in a broadcast and takes
/// one deployer nonce, so the tests send it through that deployer too and bump the nonce by hand (a test prank sends no
/// transaction)
contract ResumeTest is Test, SystemResumer, ProdDeployer {
    bool internal scriptMode;
    /// @dev the operator flags as bools here, so parallel tests never share an environment variable
    bool internal changedFlag;
    bool internal ownerFlag;
    bool internal routerFlag;

    function _settingsChanged() internal view override returns (bool) {
        return changedFlag;
    }

    function _ownerChanged() internal view override returns (bool) {
        return ownerFlag;
    }

    function _routerChanged() internal view override returns (bool) {
        return routerFlag;
    }

    function _scriptContext() internal view override returns (bool) {
        return scriptMode;
    }

    V2Stack.Stack internal v2;
    IArtCoinsFactoryV2 internal FACTORY;
    /// @dev the deployer is the factory owner and the config owner
    address internal deployer;
    address internal owner;
    address internal creator;
    LaunchConfig internal base;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        // forge test predeploys the linked CoreLib at libraryAddress() and keeps it across fork selection. mainnet has no
        // code there, so the account is reset to the state the script sees
        vm.etch(libraryAddress(), "");
        vm.resetNonce(libraryAddress());
        deployer = makeAddr("resume.deployer");
        owner = deployer;
        creator = makeAddr("resume.creator");
        v2 = V2Stack.deploy(V2Stack.mainnetParams(owner));
        FACTORY = IArtCoinsFactoryV2(v2.factory);
        vm.startPrank(owner);
        FACTORY.setMinProtocolSkimShareBps(362);
        vm.stopPrank();
        vm.deal(deployer, 5 ether);
        base = defaultConfig();
        base.owner = owner;
        base.creator = creator;
        base.creatorPayee = makeAddr("resume.payee");
        base.name = "Resume Coin";
        base.symbol = "RSM";
        base.salt = keccak256("resume");
        base.stack.hook = v2.hook;
        base.stack.factory = v2.factory;
        base.stack.locker = v2.locker;
        base.stack.escrow = v2.escrow;
        base.mevModule = v2.mev;
    }

    /// @dev the first `n` of the transactions, by hand, as the deployer: 1 library, 2 controller, 3 router, 4 core,
    /// 5 launch, 6 router engine, 7 router payees, 8 router split start from the mined launch time
    /// @dev the lens is sent between the core and the launch, as `deploySystem` does. `skipLens` leaves it out of a
    /// deploy that went on to the launch, `lensEarly` sends it in a deploy that stopped right after it
    bool internal skipLens;
    bool internal lensEarly;

    function _steps(uint256 n) internal returns (address core, address coin, address router) {
        scriptMode = true;
        if (n >= 1) _sendLibrary();
        uint64 nonce = vm.getNonce(deployer);
        router = vm.computeCreateAddress(deployer, nonce + 1);
        core = vm.computeCreateAddress(deployer, nonce + 2);
        base.stack.feeSource = router;
        address coinAt = predictCoin(base, deployer, router);
        vm.startPrank(deployer);
        address controller;
        if (n >= 2) controller = address(Prod.newController(core, base.sale));
        if (n >= 3) address(Prod.newRouter(deployer));
        if (n >= 4) Prod.newCore(owner, coinAt, controller, base.stack, base.rateStart, base.settings);
        if ((n >= 5 && !skipLens) || (n >= 4 && lensEarly)) Prod.newLens(core, LENS_SALT, CREATE2_DEPLOYER);
        if (n >= 5) coin = _launch(base, coinAt, router);
        IFeeRouter r = IFeeRouter(payable(router));
        if (n >= 6) r.setEngine(core);
        if (n >= 7) {
            address[] memory who = new address[](1);
            who[0] = base.creatorPayee;
            uint32[] memory ppm = new uint32[](1);
            ppm[0] = base.payeePpm;
            r.setPayees(who, ppm);
        }
        if (n >= 8) startSplitAfterLaunch(base, router, coin);
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
        // as in the script: the checks simulate the launch on a snapshot and run outside the broadcast
        from = resumeChecks(who, c, core);
        vm.startPrank(who);
        resumeSend(who, c, core, from);
        vm.stopPrank();
    }

    function _assertDone(address core, Stage expectFrom) internal {
        Stage from = this.resume(deployer, base, core);
        assertEq(uint256(from), uint256(expectFrom), "stage found");
        if (expectFrom == Stage.CoreOnly) {
            // the run that sent the launch leaves the split start for the next run, after the launch is mined
            assertEq(uint256(detectStage(base, core)), uint256(Stage.Setup), "only the split start is missing");
            vm.warp(block.timestamp + 1 hours);
            assertEq(uint256(this.resume(deployer, base, core)), uint256(Stage.Setup), "the second run");
        }
        assertEq(uint256(detectStage(base, core)), uint256(Stage.Done));
        address coin = ICore(payable(core)).COIN();
        assertEq(IArtCoinsTokenV2(coin).admin(), owner, "the owner is the token admin");
        postflightAs(base, core, deployer);
        (string memory list,) = _failed();
        assertEq(list, "", "postflight is clean");
    }

    /// the split start needs the mined launch time: a run that sends the launch leaves it for the next run (V2R-7). the
    /// postflight of the first run warns about it, the second run, hours later, sets launchedAt plus the window exactly
    function test_FIXED_resumeAfterTheCoreLeavesTheSplitStartToTheNextRun() public {
        (address core,,) = _steps(4);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.CoreOnly));
        assertEq(uint256(this.resume(deployer, base, core)), uint256(Stage.CoreOnly));
        IFeeRouter r = IFeeRouter(payable(ICore(payable(core)).FEE_SOURCE()));
        assertEq(r.splitStart(), 0, "the launch run does not guess the split start");
        assertEq(uint256(detectStage(base, core)), uint256(Stage.Setup), "only the split start is missing");
        (string memory first,) = _failed();
        assertEq(first, "", "the pending split start is a warning, not a failure");
        vm.warp(block.timestamp + 5 hours);
        _assertDone(core, Stage.Setup);
        (, IArtCoinsFactoryV2.DeploymentInfoV2 memory info) = _deployment(base.stack.factory, ICore(payable(core)).COIN());
        assertEq(r.splitStart(), uint256(info.launchedAt) + base.sniperSeconds, "launch time plus the window, no margin");
        assertLt(r.splitStart(), block.timestamp, "derived from the launch, not from the clock of the run");
    }

    /// V2R-7: the launch mined hours before the setup run: the split start is still the launch time plus the window
    function test_FIXED_aLateRunSetsTheSplitStartFromTheMinedLaunch() public {
        (address core, address coin, address router) = _steps(7);
        (, IArtCoinsFactoryV2.DeploymentInfoV2 memory info) = _deployment(base.stack.factory, coin);
        vm.warp(block.timestamp + 3 hours);
        _assertDone(core, Stage.Setup);
        assertEq(IFeeRouter(payable(router)).splitStart(), uint256(info.launchedAt) + base.sniperSeconds);
    }

    /// a split start that is not launch time plus the window fails the postflight and prints the difference
    function test_FIXED_postflightFailsAWrongSplitStartAndNamesTheDifference() public {
        (address core, address coin, address router) = _steps(7);
        (, IArtCoinsFactoryV2.DeploymentInfoV2 memory info) = _deployment(base.stack.factory, coin);
        uint256 want = uint256(info.launchedAt) + base.sniperSeconds;
        string memory row = "router: split start is the launch time plus the anti sniper window, exactly";
        vm.startPrank(deployer);
        IFeeRouter(payable(router)).setSplitStart(uint64(want + 900));
        vm.stopPrank();
        postflightAs(base, core, deployer);
        (string memory list,) = _failed();
        assertEq(list, row);
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].name)) == keccak256(bytes(row))) {
                assertEq(
                    rows[i].detail,
                    string.concat(
                        "splitStart ", vm.toString(want + 900), " want launchedAt plus window ", vm.toString(want), ", late by 900"
                    )
                );
            }
        }
        vm.prank(deployer);
        IFeeRouter(payable(router)).setSplitStart(uint64(want - 1));
        postflightAs(base, core, deployer);
        (list,) = _failed();
        assertEq(list, row, "early fails too");
    }

    /// a run that stopped right after the core: the lens is the next transaction, then the launch
    function test_resumeCreatesAMissingLensBeforeTheLaunch() public {
        (address core,,) = _steps(4);
        address lensAt = lensAddress(core);
        assertTrue(lensAt != address(0) && lensAt.code.length == 0, "no lens yet");
        _assertDone(core, Stage.CoreOnly);
        assertGt(lensAt.code.length, 0, "the lens sits at the derived address");
    }

    /// a run that stopped after the lens and before the launch finds the lens and leaves it as it is
    function test_resumeKeepsTheLensItFinds() public {
        lensEarly = true;
        (address core,,) = _steps(4);
        address lensAt = lensAddress(core);
        assertGt(lensAt.code.length, 0);
        bytes32 hash = lensAt.code.length == 0 ? bytes32(0) : keccak256(lensAt.code);
        _assertDone(core, Stage.CoreOnly);
        assertEq(keccak256(lensAt.code), hash, "the lens is the one that was there");
    }

    /// a system launched without a lens, with the deployer nonce moved on: the lens is created at the same address
    /// because the address depends on the Core only
    function test_resumeCreatesTheLensAfterTheLaunchAndTheNonceMovedOn() public {
        skipLens = true;
        (address core,,) = _steps(5);
        address lensAt = lensAddress(core);
        assertEq(lensAt.code.length, 0);
        _assertDone(core, Stage.Launched);
        assertGt(lensAt.code.length, 0);
    }

    function test_resumeAfterTheLaunch() public {
        (address core,,) = _steps(5);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Launched));
        _assertDone(core, Stage.Launched);
    }

    function test_resumeAfterTheEngine() public {
        (address core,,) = _steps(6);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Setup));
        _assertDone(core, Stage.Setup);
    }

    function test_resumeAfterThePayees() public {
        (address core,,) = _steps(7);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Setup));
        _assertDone(core, Stage.Setup);
    }

    /// a finished deploy: nothing is sent, the nonce does not move
    function test_resumeWhenDoneSendsNothing() public {
        (address core,,) = _steps(8);
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Done));
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

        (address core,,) = _steps(4);
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
        // another stack address
        c = base;
        c.stack.auctionFactory = Mainnet.PERMIT2;
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "stack"));
        this.resume(deployer, c, core);
        // a stranger is not the deployer of the run: the prediction does not hold
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(CoreMismatch.selector, "coin prediction (config or deployer)"));
        this.resume(stranger, base, core);
        // the real deployer still finishes it
        _assertDone(core, Stage.CoreOnly);
    }

    /// after the launch the factory is no longer needed, but the router owner is
    function test_aStrangerCannotSetUpTheRouter() public {
        (address core,, address router) = _steps(5);
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(NotRouterOwner.selector, deployer, stranger));
        this.resume(stranger, base, core);
        _assertDone(core, Stage.Launched);
        assertEq(IFeeRouter(payable(router)).engine(), core);
    }

    /// the launch step needs the deployer to still be the factory owner
    function test_resumeLaunchNeedsTheFactoryOwner() public {
        (address core,,) = _steps(4);
        address next = makeAddr("next factory owner");
        vm.prank(deployer);
        IArtCoinsFactoryV2Owner(address(FACTORY)).transferOwnership(next);
        vm.prank(next);
        IArtCoinsFactoryV2Owner(address(FACTORY)).acceptOwnership();
        vm.expectRevert(
            abi.encodeWithSelector(
                Report.ChecksFailed.selector,
                "factory: owner is the config owner, factory: owner is the deployer, factory: deployTokenAsOwner accepts the config (simulated)"
            )
        );
        this.resume(deployer, base, core);
        // the owner path is the owner's: after the launch the router steps need no factory
        vm.prank(next);
        IArtCoinsFactoryV2Owner(address(FACTORY)).transferOwnership(deployer);
        vm.prank(deployer);
        IArtCoinsFactoryV2Owner(address(FACTORY)).acceptOwnership();
        _assertDone(core, Stage.CoreOnly);
    }

    /// the factory floor of the protocol skim share is the owner command: the launch step names the failed row when it
    /// is above 362
    function test_resumeLaunchNeedsTheMinProtocolSkimShareAt362() public {
        (address core,,) = _steps(4);
        vm.prank(deployer);
        FACTORY.setMinProtocolSkimShareBps(1_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                Report.ChecksFailed.selector,
                "factory: min protocol skim share leaves room for the bounty, factory: deployTokenAsOwner accepts the config (simulated)"
            )
        );
        this.resume(deployer, base, core);
        vm.prank(deployer);
        FACTORY.setMinProtocolSkimShareBps(362);
        _assertDone(core, Stage.CoreOnly);
    }

    /// S-6 of the old review, ported: the owner moved on after the launch. OWNER_CHANGED=1 says so
    function test_resumeOwnerChangedFinishesTheRouterAndWarns() public {
        (address core,,) = _steps(8);
        _assertDone(core, Stage.Done);
        address next = makeAddr("resume.next");
        vm.startPrank(owner);
        ICore(payable(core)).transferOwnership(next);
        vm.stopPrank();
        vm.prank(next);
        ICore(payable(core)).acceptOwnership();
        ownerFlag = true;
        Stage from = this.resume(deployer, base, core);
        assertEq(uint256(from), uint256(Stage.Done), "nothing is sent");
        postflightAs(base, core, deployer);
        (string memory list,) = _failed();
        assertEq(list, "", "postflight reports the handover as warnings only");
    }

    /// the owner changed the router after the launch (new payee, locked): ROUTER_CHANGED=1 makes it Done and sends nothing
    function test_routerChangedIsDoneWhateverItHolds() public {
        (address core,, address router) = _steps(8);
        address[] memory who = new address[](1);
        who[0] = makeAddr("splitter");
        uint32[] memory ppm = new uint32[](1);
        ppm[0] = 100_000;
        vm.startPrank(owner);
        IFeeRouter(payable(router)).setPayees(who, ppm);
        IFeeRouter(payable(router)).lock();
        vm.stopPrank();
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Setup), "without the flag the payee looks unfinished");
        routerFlag = true;
        assertEq(uint256(this.stageOf(core)), uint256(Stage.Done));
        uint64 nonce = vm.getNonce(deployer);
        Stage from = this.resume(deployer, base, core);
        assertEq(uint256(from), uint256(Stage.Done));
        assertEq(vm.getNonce(deployer), nonce);
        (address[] memory have,) = IFeeRouter(payable(router)).payees();
        assertEq(have[0], who[0], "the owner's payee is not touched");
    }

    function requireDeployerExt(address want, address got) external pure {
        _requireDeployer(want, got);
    }

    /// the core created its own house in its constructor: it is there at the first resume point, owned by the core
    function test_theHouseExistsFromTheCoreOn() public {
        (address core,,) = _steps(4);
        address house = IHouseFactoryR(base.stack.auctionFactory).houseOf(core);
        assertTrue(house != address(0) && house.code.length != 0, "no house");
        assertEq(address(ICore(payable(core)).HOUSE()), house);
        _assertDone(core, Stage.CoreOnly);
    }

    /// resume point 0: only the library is on chain. nothing to resume (no core), rerunning Deploy is safe: the library
    /// is skipped and takes no second nonce, so the addresses of a rerun are the ones preflight predicts now
    function test_libraryOnlyThenRerunDeploy() public {
        _steps(1);
        address someCore = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
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

    /// resume points 0b and 0c: the controller, then the router are on chain, the core is not. both are inert. no
    /// resume, the way on is a rerun of Deploy (new controller, router, core)
    function test_orphanControllerAndRouterAreInert() public {
        (address core,, address router) = _steps(3);
        assertEq(core.code.length, 0, "no core");
        address controller = vm.computeCreateAddress(deployer, vm.getNonce(deployer) - 2);
        assertEq(address(IControllerV1(controller).CORE()), core, "it points at the core that never came");
        assertEq(controller.balance, 0);
        assertEq(IFeeRouter(payable(router)).engine(), address(0), "the router has no engine");
        vm.expectRevert(
            abi.encodeWithSelector(CoreMismatch.selector, "no code at the core address, run Deploy instead")
        );
        this.resume(deployer, base, core);
        // sending the saved core creation at the next nonce gives the predicted core, and Resume goes on from there
        address coinAt = predictCoin(base, deployer, router);
        vm.startPrank(deployer);
        address c2 = address(Prod.newCore(owner, coinAt, controller, base.stack, base.rateStart, base.settings));
        vm.stopPrank();
        assertEq(c2, core, "the saved creation lands on the predicted core");
        _assertDone(core, Stage.CoreOnly);
    }

    /// the owner can call setSettings the moment the core exists: Resume does not finish a core whose settings are not
    /// the signed ones unless the operator says so
    function test_resumeRefusesChangedSettings() public {
        (address core,,) = _steps(5);
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
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, owner, creator));
        this.requireDeployerExt(owner, creator);
        vm.expectRevert(abi.encodeWithSelector(DeployerMismatch.selector, address(0), deployer));
        this.requireDeployerExt(address(0), deployer);
    }

    /// the deploy itself refuses a sender that is not the factory owner and the config owner
    function test_deployRefusesANonFactoryOwner() public {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 5 ether);
        LaunchConfig memory c = base;
        c.owner = stranger;
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotFactoryOwner.selector, deployer, stranger));
        this.deployExt(stranger, c);
        vm.stopPrank();
        // the factory owner with another config owner is refused too
        c = base;
        c.owner = creator;
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(NotFactoryOwner.selector, deployer, deployer));
        this.deployExt(deployer, c);
        vm.stopPrank();
    }

    function deployExt(address who, LaunchConfig memory c) external {
        deploySystem(who, c);
    }
}

interface IArtCoinsFactoryV2Owner {
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
