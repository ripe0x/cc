// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CCBarsSale, ICoreForBarsSale, IBarsForSale} from "../src/adapters/CCBarsSale.sol";
import {CCBarsVault} from "../src/adapters/CCBarsVault.sol";

/// @notice the owner's Bars sale, one command that resumes from chain state: the sale by CREATE2 at a fixed address
/// (skipped when its code exists), every Bar the CC Bars vault holds moved into it (skipped when none are left) and
/// sales switched on (skipped when on). the BALANCE left in the vault goes back to the v1 treasury first (skipped when
/// none is left), and only while v1 is still the Core's balance module: run this before phase 3. after it the vault
/// holds nothing, which the run checks, and melting runs from the sale, which pays the Core's balance module of the
/// moment. the multipliers are this script's constants, set at creation; a later
/// change is the owner's `setSale`. the constants are part of the CREATE2 initcode: editing one after the first send
/// predicts a new, empty sale and would leave the Bars in the first one, so price edits go through `setSale` only
interface IErc20Balance {
    function balanceOf(address who) external view returns (uint256);
}

contract BarsSale is Script {
    address public constant CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;
    address public constant BALANCE = 0x3620540c994433D7B4a628C46d2ED5F92572eA07;
    address public constant BARS = 0x7d9EdeA03dD97361c3e21389B95bc327e22752aE;
    address public constant VAULT = 0x2A518DC6776788f4969c8131CF134a31DE3c0d11;
    address public constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant SALT = keccak256("cc.bars-sale.1");

    /// decision 302: each Bar asks 4x its BALANCE value at arrival, falling to 1.5x over 14 days
    uint32 public constant START_BPS = 40_000;
    uint32 public constant FLOOR_BPS = 15_000;
    uint32 public constant WINDOW = 14 days;

    /// the vault minted Bars 2942 to 3007 (decision 301); the scan covers every Bar minted after its first mint
    uint256 public constant FIRST_ID = 2935;
    uint256 public constant LAST_ID = 3034;

    function run() external {
        execute(ICoreForBarsSale(CORE).owner());
        readback();
    }

    function saleAddress() public pure returns (address) {
        return vm.computeCreate2Address(SALT, keccak256(_initcode()), FACTORY);
    }

    /// the Bars `holder` owns in the vault's mint range, skipping melted (burned) Bars
    function barsOf(address holder) public view returns (uint256[] memory ids) {
        uint256[] memory all = new uint256[](LAST_ID - FIRST_ID + 1);
        uint256 n;
        for (uint256 id = FIRST_ID; id <= LAST_ID; ++id) {
            // a melted Bar is burned and `ownerOf` reverts for it
            try IBarsForSale(BARS).ownerOf(id) returns (address o) {
                if (o == holder) all[n++] = id;
            } catch {}
        }
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = all[i];
    }

    function execute(address owner) public returns (CCBarsSale sale) {
        require(owner == ICoreForBarsSale(CORE).owner(), "not the owner");
        require(ICoreForBarsSale(CORE).balanceToken() == BALANCE, "the Core's balance token is not BALANCE");
        CCBarsVault vault = CCBarsVault(VAULT);
        // the vault returns only to the immutable v1 treasury. once phase 3 has switched the module, a return would
        // land in migrated v1: stop before any send. recovery: `returnBalance`, then v1 `withdrawWorking` to the module
        uint256 leftover = IErc20Balance(BALANCE).balanceOf(VAULT);
        require(
            leftover == 0 || ICoreForBarsSale(CORE).balanceModule() == vault.treasury(),
            "the module is no longer v1: return the vault's BALANCE by hand first"
        );
        sale = CCBarsSale(saleAddress());
        uint256[] memory ids = barsOf(VAULT);
        vm.startBroadcast(owner);
        if (leftover != 0) vault.returnBalance();
        if (address(sale).code.length == 0) {
            (bool ok,) = FACTORY.call(abi.encodePacked(SALT, _initcode()));
            require(ok && address(sale).code.length != 0, "sale creation failed");
        }
        if (ids.length != 0) vault.transferBars(address(sale), ids);
        if (!sale.on()) sale.setOn(true);
        vm.stopBroadcast();
        require(IErc20Balance(BALANCE).balanceOf(VAULT) == 0, "BALANCE left in the vault");
        require(barsOf(VAULT).length == 0, "Bars left in the vault");
    }

    function readback() public view {
        CCBarsSale sale = CCBarsSale(saleAddress());
        console.log("sale", address(sale));
        if (address(sale).code.length == 0) {
            console.log("sale not deployed: nothing sent");
            return;
        }
        uint256[] memory held = barsOf(address(sale));
        console.log("sale on", sale.on());
        console.log("Bars in sale", held.length);
        console.log("Bars left in vault", barsOf(VAULT).length);
        console.log("BALANCE left in vault", IErc20Balance(BALANCE).balanceOf(VAULT));
        if (held.length != 0) {
            console.log("first Bar", held[0]);
            console.log("its backing wei", sale.backingOf(held[0]));
            console.log("its multiplier bps", sale.multiplierOf(held[0]));
            console.log("its ask wei", sale.priceOf(held[0]));
        }
    }

    function _initcode() internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(CCBarsSale).creationCode,
            abi.encode(CORE, BALANCE, BARS, START_BPS, FLOOR_BPS, WINDOW)
        );
    }
}
