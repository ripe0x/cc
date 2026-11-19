// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CCBarsVault, IBars} from "../src/adapters/CCBarsVault.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";

interface IBarsView {
    function minted() external view returns (uint256);
    function isOpen() external view returns (bool);
    function mintEnd() external view returns (uint64);
    function priceOf(uint256 quantity) external view returns (uint256);
}

interface IErc20 {
    function balanceOf(address who) external view returns (uint256);
}

/// @notice the owner's Bars acquisition, one command that resumes from chain state: every step reads what is already
/// done, so a run that stops partway is finished by running the same command again.
///
/// - without `ALLOCATION`: the snapshot alone, no sends. prints half of the treasury's BALANCE custody at this block
///   and the Bars it buys now. record it in deployments/1-bars.json; the send passes that recorded value
/// - with `ALLOCATION` (wei): the vault by CREATE2 at a fixed address (skipped when its code exists), one
///   `withdrawWorking(vault, ALLOCATION)` (skipped once the vault holds BALANCE or Bars or has spent any), mints of at
///   most 10 Bars each while whole Bars fit in the vault's BALANCE, then `returnBalance` of the remainder. after the
///   mint window closes a run creates, funds and mints nothing and only returns BALANCE left in the vault
///
/// the script never computes the allocation it sends: a retry cannot withdraw a recalculated half
contract BarsVault is Script {
    address public constant CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;
    address public constant TREASURY = 0xB85CF439Ca57b4bfC28fA1Cb8a97Ee85555B0496;
    address public constant BALANCE = 0x3620540c994433D7B4a628C46d2ED5F92572eA07;
    address public constant BARS = 0x7d9EdeA03dD97361c3e21389B95bc327e22752aE;
    address public constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant SALT = keccak256("cc.bars-vault.1");
    /// the CREATE2 address of this commit's vault build, recorded in deployments/1-bars.json
    address public constant VAULT = 0x2A518DC6776788f4969c8131CF134a31DE3c0d11;
    uint256 public constant MAX_BATCH = 10;
    uint256 public constant MAX_BARS = 10_000;

    function run() external {
        uint256 allocation = vm.envOr("ALLOCATION", uint256(0));
        if (allocation == 0) {
            snapshot();
            return;
        }
        execute(IPhase2BalanceTreasury(TREASURY).owner(), allocation);
        readback();
    }

    function vaultAddress() public pure returns (address) {
        return vm.computeCreate2Address(SALT, keccak256(_initcode()), FACTORY);
    }

    /// funded once: any BALANCE or Bar here, or any spend, means the withdrawal already happened
    function funded(address vault) public view returns (bool) {
        return CCBarsVault(vault).spent() != 0 || IErc20(BALANCE).balanceOf(vault) != 0
            || IBars(BARS).balanceOf(vault) != 0;
    }

    /// the most whole Bars, at most 10, the next numbers cost within `budget`
    function fit(uint256 budget) public view returns (uint256 q) {
        uint256 minted = IBarsView(BARS).minted();
        q = MAX_BATCH;
        while (q != 0 && (minted + q > MAX_BARS || IBarsView(BARS).priceOf(q) > budget)) --q;
    }

    function snapshot() public view {
        IPhase2BalanceTreasury t = IPhase2BalanceTreasury(TREASURY);
        uint256 custody = t.custody();
        uint256 half = custody / 2;
        console.log("block", block.number);
        console.log("timestamp", block.timestamp);
        console.log("mintEnd", IBarsView(BARS).mintEnd());
        console.log("custody", custody);
        console.log("allocation (half)", half);
        console.log("freeWorking", t.freeWorking());
        console.log("fits freeWorking", half <= t.freeWorking());
        console.log("Bars minted", IBarsView(BARS).minted());
        (uint256 n, uint256 cost) = _count(half);
        console.log("Bars it buys now", n);
        console.log("their cost", cost);
        console.log("vault", vaultAddress());
    }

    function execute(address owner, uint256 allocation) public returns (CCBarsVault vault) {
        require(owner == IPhase2BalanceTreasury(TREASURY).owner(), "not the owner");
        // a different build would predict a different, empty vault and fund it again
        require(vaultAddress() == VAULT, "vault build differs from the recorded vault");
        vault = CCBarsVault(VAULT);
        bool open = IBarsView(BARS).isOpen();
        vm.startBroadcast(owner);
        if (open && address(vault).code.length == 0) {
            (bool ok,) = FACTORY.call(abi.encodePacked(SALT, _initcode()));
            require(ok && address(vault).code.length != 0, "vault creation failed");
        }
        if (open && !funded(address(vault))) {
            IPhase2BalanceTreasury t = IPhase2BalanceTreasury(TREASURY);
            require(allocation * 2 <= t.custody(), "allocation above half of custody: re-snapshot");
            require(allocation <= t.freeWorking(), "allocation above freeWorking");
            t.withdrawWorking(address(vault), allocation);
            require(IErc20(BALANCE).balanceOf(address(vault)) == allocation, "funding mismatch");
        }
        while (open) {
            uint256 held = IErc20(BALANCE).balanceOf(address(vault));
            uint256 q = fit(held);
            if (q == 0) break;
            vault.mintBars(q, held);
        }
        if (address(vault).code.length != 0 && IErc20(BALANCE).balanceOf(address(vault)) != 0) vault.returnBalance();
        vm.stopBroadcast();
    }

    function readback() public view {
        address vault = vaultAddress();
        console.log("vault", vault);
        if (vault.code.length == 0) {
            console.log("vault not deployed: nothing sent");
            return;
        }
        console.log("vault spent", CCBarsVault(vault).spent());
        console.log("vault Bars", IBars(BARS).balanceOf(vault));
        console.log("vault BALANCE", IErc20(BALANCE).balanceOf(vault));
        console.log("treasury custody", IPhase2BalanceTreasury(TREASURY).custody());
        console.log("Bars minted", IBarsView(BARS).minted());
    }

    function _count(uint256 budget) internal view returns (uint256 n, uint256 cost) {
        uint256 id = IBarsView(BARS).minted() + 1;
        while (id <= MAX_BARS && cost + id * 1 ether <= budget) {
            cost += id * 1 ether;
            ++id;
            ++n;
        }
    }

    function _initcode() internal pure returns (bytes memory) {
        return abi.encodePacked(type(CCBarsVault).creationCode, abi.encode(CORE, TREASURY, BALANCE, IBars(BARS)));
    }
}
