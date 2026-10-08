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
import {IArtCoinsFactory, IArtCoinsToken} from "../src/interfaces/ArtCoins.sol";
import {SystemDeployer, Deployed} from "../script/SystemDeployer.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";

interface IUniversalRouterR {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2R {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice the launch rehearsal. forks mainnet at the LATEST block (read from the rpc, not the pinned one), runs the
/// preflight, the real deploy path as the factory owner enables the deployer, the postflight, and a short smoke:
/// a buy and a sell through the universal router and a real credit sold into the bid. it skips cleanly unless the
/// env var REHEARSAL is set, so the default suite stays pinned and fast. it reads the config file named by
/// LAUNCH_CONFIG, like the scripts do, so the operator rehearses the exact file they will launch with.
/// `set -a; . ./.env; set +a; REHEARSAL=1 LAUNCH_CONFIG=script/config/local.json forge test --match-path test/Rehearsal.t.sol -vv`
contract RehearsalTest is Test, ProdDeployer {
    LaunchConfig internal c;
    Deployed internal d;
    address internal deployer;
    address internal trader;

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
        if (bytes(c.name).length == 0) c.name = "Rehearsal Coin";
        if (bytes(c.symbol).length == 0) c.symbol = "REH";
        if (c.salt == bytes32(0)) c.salt = keccak256("credits engine rehearsal");
        console.log("config hash");
        console.logBytes32(configHash(c));
        deployer = _user("deployer");
        trader = _user("trader");
        vm.deal(deployer, 2 ether);
        vm.deal(trader, 20 ether);

        _preflight();
        _deploy();
        postflight(c, d.core);
        _print("postflight after the launch");
        assertEq(_failedNames(), "", "postflight");
        _smoke();
    }

    function _failedNames() internal view returns (string memory list) {
        (list,) = _failed();
    }

    function _preflight() internal {
        // before the factory owner acts the only acceptable failure is the deployer enablement, and only while the
        // factory is deprecated
        preflight(c, deployer);
        _print("preflight before the factory owner enables the deployer");
        string memory before_ = _failedNames();
        bool open = !IArtCoinsFactory(c.stack.factory).deprecated();
        assertEq(before_, open ? "" : "factory: deployer may launch", "preflight before enablement");

        vm.prank(c.factoryOwner);
        IArtCoinsFactory(c.stack.factory).setAdmin(deployer, true);
        preflight(c, deployer);
        _print("preflight after the factory owner enabled the deployer");
        assertEq(_failedNames(), "", "preflight after enablement");
    }

    function _deploy() internal {
        uint256 balBefore = deployer.balance;
        // the linked library is deployed before the core, once, by the same deployer
        uint256 lg = gasleft();
        address lib = deployCode("CoreLib.sol:CoreLib");
        uint256 libGas = lg - gasleft();
        vm.startPrank(deployer);
        d = deploySystem(deployer, c);
        vm.stopPrank();
        // each transaction costs its execution gas, 21000 intrinsic and its calldata (4 gas per zero byte, 16 per other byte)
        bytes memory libCode = vm.getCode("CoreLib.sol:CoreLib");
        uint256[6] memory txGas = [
            libGas + 21_000 + _calldataGas(libCode) + 512,
            stepGas[0] + 21_000 + _calldataGas(vm.getCode("ControllerV1.sol:ControllerV1")) + 512,
            stepGas[1] + 21_000 + _calldataGas(vm.getCode("Core.sol:Core")) + 16_384,
            stepGas[2] + 21_000
                + _calldataGas(
                    abi.encodeCall(
                        IArtCoinsFactory.deployTokenWithProtocolBpsAndTax,
                        (buildConfig(c, deployer, d.core), 0, buildTaxConfig(c, d.core))
                    )
                ),
            stepGas[3] + 21_000 + 2_048,
            stepGas[4] + 21_000 + 1_024
        ];
        string[6] memory names = [
            "1 library CoreLib (create2 deployer)",
            "2 controller",
            "3 core (house creation inside)",
            "4 launch through the factory",
            "5 lock the extension slot",
            "6 hand the token admin to the owner"
        ];
        uint256 total;
        for (uint256 i; i < 6; ++i) {
            total += txGas[i];
            console.log(string.concat("deploy gas, tx ", names[i]), txGas[i]);
        }
        uint256 fee = IArtCoinsFactory(c.stack.factory).deployFee();
        console.log("library at", lib);
        console.log("total deploy gas, six transactions", total);
        console.log("factory deploy fee (wei, sent as value of tx 4)", fee);
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
        IArtCoinsToken coin = IArtCoinsToken(d.coin);
        IUniversalRouterR ur = IUniversalRouterR(Mainnet.UNIVERSAL_ROUTER);
        // past the anti sniper window, so the skim is the 10 point baseline
        vm.warp(block.timestamp + c.sniperSeconds + 1);

        uint256 pot = core.ethPot();
        vm.prank(trader);
        ur.execute{value: 1 ether}(hex"10", _v4Swap(true, 1 ether), block.timestamp + 1 hours);
        uint256 bought = coin.balanceOf(trader);
        assertGt(bought, 0, "bought coin through the universal router");
        // the baseline skim of the config (hundredths of a basis point of volume) times the bounty share of it
        uint256 want = uint256(1 ether) * c.baselineSkimBps / 100_000 * c.bountyBps / 10_000;
        assertEq(core.ethPot() - pot, want, "the bounty share of the baseline skim reached the pot");
        assertEq(address(core).balance, core.ethPot(), "pot equals balance");

        uint256 sellIn = bought / 2;
        pot = core.ethPot();
        vm.startPrank(trader);
        coin.approve(Mainnet.PERMIT2, type(uint256).max);
        IPermit2R(Mainnet.PERMIT2).approve(d.coin, address(ur), uint160(sellIn), uint48(block.timestamp + 1 hours));
        uint256 ethBefore = trader.balance;
        ur.execute(hex"10", _v4Swap(false, sellIn), block.timestamp + 1 hours);
        vm.stopPrank();
        assertGt(trader.balance, ethBefore, "sold coin for eth");
        assertGt(core.ethPot(), pot, "the sell skim reached the pot too");
        assertEq(coin.balanceOf(Mainnet.DEAD), 0, "no tax on canonical swaps");

        _sellRealCredit(core);
    }

    /// finds a real credit held by an account without code and sells it into the bid
    function _sellRealCredit(ICore core) internal {
        assertTrue(core.funded(), "funded after the fees");
        assertEq(core.ethRate(), c.rateStart, "no climb yet");
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
