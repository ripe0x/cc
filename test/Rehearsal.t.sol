// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ProdDeployer} from "./utils/ProdDeployer.sol";
import {Test, console} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Lane, ICredits, Mainnet} from "../src/interfaces/Interfaces.sol";
import {SystemDeployer, Deployed} from "../script/SystemDeployer.sol";
import {V2Stack} from "./utils/V2Stack.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {IArtCoinsFactoryV2, IArtCoinsTokenV2} from "../src/interfaces/ArtCoinsV2.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";

interface IUniversalRouterR {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2R {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice the launch rehearsal. forks mainnet at the LATEST block (read from the rpc, not the pinned one), runs the
/// preflight, the real deploy path as the factory owner, the postflight, and a short smoke: a buy and a sell through the
/// universal router, a flush of the router and a real credit sold into the bid. it skips cleanly unless the env var
/// REHEARSAL is set, so the default suite stays pinned and fast. it reads the config file named by LAUNCH_CONFIG, like the
/// scripts do, so the operator rehearses the exact file they will launch with. while the v2 stack addresses of the file
/// are still zero (v2 is not on mainnet) the vendored v2 artifacts are deployed onto the fork with the config owner as
/// the factory owner, and the rehearsal says so. it measures the gas of every transaction of the deploy and asserts each
/// one fits under the per transaction gas cap
/// `set -a; . ./.env; set +a; REHEARSAL=1 LAUNCH_CONFIG=script/config/local.json forge test --match-path test/Rehearsal.t.sol -vv`
contract RehearsalTest is Test, ProdDeployer {
    LaunchConfig internal c;
    Deployed internal d;
    address internal deployer;
    address internal trader;
    bool internal stackIsRehearsal;

    function _user(string memory label) internal returns (address a) {
        a = makeAddr(string.concat("rehearsal.", label, ".7d3a"));
        assertEq(a.code.length, 0, "account has code on the fork");
    }

    function test_rehearsal() public {
        if (bytes(vm.envOr("REHEARSAL", string(""))).length == 0) vm.skip(true);
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        console.log("rehearsal at block", block.number, "timestamp", block.timestamp);

        // the exact file the operator will launch with: LAUNCH_CONFIG, as the scripts read it. a placeholder the file
        // leaves unset gets a rehearsal value, a placeholder it fills is rehearsed as it is
        string memory file = vm.envOr("LAUNCH_CONFIG", DEFAULT_CONFIG_FILE);
        console.log("rehearsing the config file", file);
        c = loadConfig(file);
        if (c.owner == address(0)) c.owner = _user("owner");
        if (c.creator == address(0)) c.creator = _user("creator");
        if (c.creatorPayee == address(0)) c.creatorPayee = _user("payee");
        if (bytes(c.name).length == 0) c.name = "Rehearsal Coin";
        if (bytes(c.symbol).length == 0) c.symbol = "REH";
        if (c.salt == bytes32(0)) c.salt = keccak256("credits engine rehearsal");
        deployer = c.owner;
        trader = _user("trader");
        _stack();
        console.log("config hash");
        console.logBytes32(configHash(c));
        vm.deal(deployer, 5 ether);
        vm.deal(trader, 20 ether);

        _preflight();
        _deploy();
        postflightAs(c, d.core, deployer);
        _print("postflight after the launch");
        assertEq(_failedNames(), "", "postflight");
        _smoke();
    }

    /// @dev the v2 stack of the config. zero addresses mean v2 is not live: deploy the artifacts onto the fork, owned by
    /// the config owner, who is the factory owner and the deployer
    function _stack() internal {
        if (c.stack.factory != address(0)) {
            console.log("v2 stack from the config file, factory", c.stack.factory);
            return;
        }
        console.log("v2 is not live: the vendored v2 artifacts are deployed onto the fork for the rehearsal");
        stackIsRehearsal = true;
        V2Stack.Stack memory v2 = V2Stack.deploy(V2Stack.mainnetParams(deployer));
        c.stack.hook = v2.hook;
        c.stack.factory = v2.factory;
        c.stack.locker = v2.locker;
        c.stack.escrow = v2.escrow;
        c.mevModule = v2.mev;
    }

    function _failedNames() internal view returns (string memory list) {
        (list,) = _failed();
    }

    function _preflight() internal {
        // before the factory owner sets the minimum lp fee to 0 the preflight names exactly that
        IArtCoinsFactoryV2 f = IArtCoinsFactoryV2(c.stack.factory);
        preflight(c, deployer);
        _print("preflight before the owner commands setMinLpFee(0) and setMinProtocolSkimShareBps(362)");
        string memory before_ = _failedNames();
        if (f.minLpFee() != 0 || f.minProtocolSkimShareBps() > 10_000 - c.bountyBps) {
            assertEq(
                before_,
                "factory: min lp fee is at most the config lp fee, factory: min protocol skim share leaves room for the bounty, factory: deployTokenAsOwner accepts the config (simulated)",
                "preflight before the owner commands"
            );
            vm.startPrank(deployer);
            f.setMinLpFee(0);
            f.setMinProtocolSkimShareBps(uint16(10_000 - c.bountyBps));
            vm.stopPrank();
        } else {
            assertEq(before_, "", "the factory minimums are already open");
        }
        preflight(c, deployer);
        _print("preflight after the owner command");
        assertEq(_failedNames(), "", "preflight after the owner command");
    }

    function _deploy() internal {
        uint256 balBefore = deployer.balance;
        // the linked library is deployed before the controller, once, by the same deployer
        uint256 lg = gasleft();
        address lib = deployCode("CoreLib.sol:CoreLib");
        uint256 libGas = lg - gasleft();
        vm.startPrank(deployer);
        d = deploySystem(deployer, c);
        // the Deploy script ends here. the split start is the first transaction of the Resume run, after the launch is
        // mined: it reads the launch time from the factory record (the rehearsal mines in the same block)
        startSplitAfterLaunch(c, d.router, d.coin);
        vm.stopPrank();
        (, IArtCoinsFactoryV2.DeploymentInfoV2 memory info) = _deployment(c.stack.factory, d.coin);
        assertEq(
            IFeeRouter(payable(d.router)).splitStart(),
            uint256(info.launchedAt) + c.sniperSeconds,
            "split start: the mined launch time plus the window, no margin"
        );
        // each transaction costs its execution gas, 21000 intrinsic and its calldata (4 gas per zero byte, 16 per other byte)
        bytes memory libCode = vm.getCode("CoreLib.sol:CoreLib");
        uint256[10] memory txGas = [
            libGas + 21_000 + _calldataGas(libCode) + 512,
            stepGas[0] + _createGas("ControllerV1.sol:ControllerV1") + 512,
            stepGas[1] + _createGas("FeeRouter.sol:FeeRouter") + 512,
            stepGas[2] + _createGas("Core.sol:Core") + 16_384,
            // sent through the deterministic deployer: the measured call includes the create and the code deposit
            stepGas[8] + 21_000 + _calldataGas(abi.encodePacked(LENS_SALT, vm.getCode("CoreLens.sol:CoreLens"), abi.encode(d.core))) + 512,
            stepGas[3] + 21_000
                + _calldataGas(
                    abi.encodeCall(
                        IArtCoinsFactoryV2.deployTokenAsOwner, (buildConfig(c, c.owner, d.router, d.core), c.protocolBps)
                    )
                ),
            stepGas[4] + 21_000 + 1_024,
            stepGas[5] + 21_000 + 2_048,
            stepGas[6] + 21_000 + 1_024,
            stepGas[7] + 21_000 + 1_024
        ];
        string[10] memory names = [
            "1 library CoreLib (create2 deployer)",
            "2 controller",
            "3 router",
            "4 core (house creation inside)",
            "5 lens (read only)",
            "6 launch through the factory (deployTokenAsOwner)",
            "7 router setEngine",
            "8 router setPayees",
            "9 router setTip (skipped when the router already holds the config tip)",
            "10 router setSplitStart (the Resume run, after the launch is mined)"
        ];
        uint256 total;
        for (uint256 i; i < 10; ++i) {
            total += txGas[i];
            console.log(string.concat("deploy gas, tx ", names[i]), txGas[i]);
            assertLt(txGas[i], TX_GAS_CAP, string.concat("over the per transaction gas cap: ", names[i]));
        }
        uint256 fee = IArtCoinsFactoryV2(c.stack.factory).deployFee();
        // the preflight balance row prices the deploy at this many gas: the measured total must fit under it
        assertLe(total, DEPLOY_GAS_ESTIMATE, "the measured deploy gas is above DEPLOY_GAS_ESTIMATE");
        console.log("DEPLOY_GAS_ESTIMATE", DEPLOY_GAS_ESTIMATE);
        console.log("library at", lib);
        console.log("total deploy gas, ten transactions", total);
        console.log("per transaction gas cap", TX_GAS_CAP);
        console.log("factory deploy fee (wei, sent as value of tx 6)", fee);
        uint256[3] memory gwei_ = [uint256(1), 5, 20];
        for (uint256 i; i < 3; ++i) {
            uint256 cost = total * gwei_[i] * 1 gwei;
            console.log(
                string.concat("deployer needs at ", vm.toString(gwei_[i]), " gwei: gas ", _eth(cost), " eth, plus fee"),
                _eth(cost + fee)
            );
        }
        console.log("deployer paid wei (the fee only, the test gas price is 0)", balBefore - deployer.balance);
        console.log("core", d.core);
        console.log("router", d.router);
        console.log("coin", d.coin);
    }

    /// @dev wei as a decimal eth string with five places
    function _eth(uint256 weiAmount) internal pure returns (string memory) {
        uint256 whole = weiAmount / 1 ether;
        uint256 frac = (weiAmount % 1 ether) / 1e13;
        string memory f = vm.toString(frac);
        while (bytes(f).length < 5) {
            f = string.concat("0", f);
        }
        return string.concat(vm.toString(whole), ".", f);
    }

    /// @dev what a creation transaction costs beyond the measured constructor run: intrinsic 21000, the create 32000,
    /// 200 per byte of runtime code deposit, and the calldata of the creation code. the pranked `deployCode` of the
    /// measured steps does not meter the deposit, so it is added here
    function _createGas(string memory artifact) internal view returns (uint256) {
        return 21_000 + 32_000 + 200 * vm.getDeployedCode(artifact).length + _calldataGas(vm.getCode(artifact));
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    // ------------------------------------------------------------------ smoke

    function _v4Swap(bool zeroForOne, uint256 amountIn) internal view returns (bytes[] memory inputs) {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        PoolKey memory k = d.launchKey;
        Currency cIn = zeroForOne ? k.currency0 : k.currency1;
        Currency cOut = zeroForOne ? k.currency1 : k.currency0;
        bytes[] memory params = new bytes[](3);
        // forge-lint: disable-next-line(unsafe-typecast)
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(k, zeroForOne, uint128(amountIn), 0, ""));
        params[1] = abi.encode(cIn, amountIn);
        params[2] = abi.encode(cOut, uint256(0));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _smoke() internal {
        ICore core = ICore(payable(d.core));
        IArtCoinsTokenV2 coin = IArtCoinsTokenV2(d.coin);
        IFeeRouter router = IFeeRouter(payable(d.router));
        IUniversalRouterR ur = IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER);
        // past the anti sniper window, so the skim is the 6.9 point baseline
        vm.warp(block.timestamp + c.sniperSeconds + 1);

        uint256 pot = core.ethPot();
        uint256 payeeStart = c.creatorPayee.balance;
        vm.prank(trader);
        ur.execute{value: 1 ether}(hex"10", _v4Swap(true, 1 ether), block.timestamp + 1 hours);
        uint256 bought = coin.balanceOf(trader);
        assertGt(bought, 0, "bought coin through the universal router");
        // the baseline skim of the config (hundredths of a basis point of volume) times the bounty share of it
        uint256 want = uint256(1 ether) * c.baselineSkimBps / 100_000 * c.bountyBps / 10_000;
        assertEq(address(router).balance, want, "the bounty share of the baseline skim reached the router");
        assertEq(core.ethPot(), pot, "nothing reaches the pot before the flush");
        address keeper = _user("keeper");
        vm.prank(keeper);
        router.flush(keeper);
        uint256 tip = want * c.tipPpm / 1e6;
        if (tip > c.tipCap) tip = c.tipCap;
        assertEq(keeper.balance, tip, "the flusher is paid the tip");
        assertEq(core.ethPot() - pot, want - tip, "the rest reached the pot (no payee share in the flush that starts the split)");
        assertEq(address(core).balance, core.ethPot(), "pot equals balance");
        // the split start is the end of the window: this first flush after it turns the split on and shares nothing
        assertTrue(router.splitOn(), "the first flush after the window starts the split");
        assertEq(c.creatorPayee.balance, payeeStart, "that flush shared nothing");

        uint256 deadBefore = coin.balanceOf(Mainnet.DEAD);
        uint256 sellIn = bought / 2;
        pot = core.ethPot();
        vm.startPrank(trader);
        coin.approve(Mainnet.PERMIT2, type(uint256).max);
        IPermit2R(Mainnet.PERMIT2).approve(d.coin, address(ur), uint160(sellIn), uint48(block.timestamp + 1 hours));
        uint256 ethBefore = trader.balance;
        ur.execute(hex"10", _v4Swap(false, sellIn), block.timestamp + 1 hours);
        vm.stopPrank();
        assertGt(trader.balance, ethBefore, "sold coin for eth");
        vm.prank(keeper);
        router.flush(keeper);
        assertGt(core.ethPot(), pot, "the sell skim reached the pot too");
        assertEq(coin.balanceOf(Mainnet.DEAD), deadBefore, "no tax and no burn on canonical swaps");

        // from the flush after that the payee is paid its parts per million of the gross amount flushed
        uint256 payee0 = c.creatorPayee.balance;
        vm.deal(trader, 2 ether);
        vm.prank(trader);
        ur.execute{value: 1 ether}(hex"10", _v4Swap(true, 1 ether), block.timestamp + 1 hours);
        uint256 gross = address(router).balance;
        vm.prank(keeper);
        router.flush(keeper);
        assertGt(c.creatorPayee.balance, payee0, "from now on the payee is paid its share");
        assertEq(c.creatorPayee.balance - payee0, gross * c.payeePpm / 1e6, "exactly its share of the inflow");

        _sellRealCredit(core);
    }

    /// finds a real credit held by an account without code and sells it into the bid
    function _sellRealCredit(ICore core) internal {
        assertGt(core.ethPot(), 0, "the pot holds the fees");
        // the price state starts at the config rate. the read is clamped by a thin pot
        assertGe(core.ethPrice(), c.rateStart, "the price state never starts below the config start");
        ICredits credits = ICredits(Mainnet.CREDITS);
        uint256 cap = core.ethPot() * 2000 / 10_000;
        for (uint256 id = 1; id < 2000; ++id) {
            address who;
            try credits.ownerOf(id) returns (address o) {
                who = o;
            } catch {
                continue;
            }
            if (who.code.length != 0 || core.ceilingOf(id) > cap) continue;
            uint256 price = core.ceilingOf(id);
            uint256 pot = core.ethPot();
            uint256 before = who.balance;
            vm.startPrank(who);
            credits.setApprovalForAll(address(core), true);
            uint256[] memory ids = new uint256[](1);
            ids[0] = id;
            core.sellForEth(ids);
            vm.stopPrank();
            assertEq(credits.ownerOf(id), address(core), "the core holds the credit");
            assertEq(who.balance - before, price, "the seller was paid the ceiling");
            assertEq(pot - core.ethPot(), price, "the pot paid it");
            assertEq(core.pileSize(Lane.Eth), 1);
            console.log("sold credit", id, "for wei", price);
            return;
        }
        revert("no sellable real credit found");
    }
}
