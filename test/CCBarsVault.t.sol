// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CCBarsVault, IBars} from "../src/adapters/CCBarsVault.sol";
import {IPhase2BalanceTreasury} from "../src/interfaces/IPhase2BalanceTreasury.sol";
import {BarsVault, IBarsView, IErc20} from "../script/BarsVault.s.sol";

interface IBarsWork {
    struct Work {
        address vault;
        uint96 amount;
        address minter;
        uint64 block;
        bool melted;
        uint256[4] ink;
    }

    function work(uint256 id) external view returns (Work memory);
}

interface ICoreOwnable {
    function transferOwnership(address to) external;
    function acceptOwnership() external;
}

interface IErc20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// a future sale, custody or redemption contract: accepts ERC721 safe transfers
contract BarsReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// the live CC treasury, BALANCE and Bars contracts on a pinned mainnet fork; only the vault is new
contract CCBarsVaultTest is Test {
    uint256 internal constant FORK_BLOCK = 26449767;
    uint256 internal constant MINT_END = 1795104000;

    BarsVault internal script;
    IPhase2BalanceTreasury internal treasury;
    address internal owner;
    address internal constant BALANCE = 0x3620540c994433D7B4a628C46d2ED5F92572eA07;
    address internal constant BARS = 0x7d9EdeA03dD97361c3e21389B95bc327e22752aE;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co")), FORK_BLOCK);
        script = new BarsVault();
        treasury = IPhase2BalanceTreasury(script.TREASURY());
        owner = treasury.owner();
        assertEq(IBarsView(BARS).mintEnd(), MINT_END, "live deadline");
        assertLt(block.timestamp, MINT_END, "pin before close");
    }

    function _bal(address who) internal view returns (uint256) {
        return IErc20(BALANCE).balanceOf(who);
    }

    function _ids(uint256 first, uint256 n) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = first + i;
    }

    function _sumAmounts(uint256 first, uint256 n) internal pure returns (uint256 s) {
        for (uint256 i; i < n; ++i) s += (first + i) * 1 ether;
    }

    // promise: one run funds the vault with exactly the allocation, mints every whole Bar it buys, returns the rest,
    // and every Bar and every wei of the allocation ends either in a Bar vault owned here or back in the treasury
    function test_fullPath() public {
        uint256 custody0 = treasury.custody();
        uint256 allocation = custody0 / 2;
        assertLe(allocation, treasury.freeWorking(), "fits freeWorking");
        uint256 first = IBarsView(BARS).minted() + 1;
        uint256 free0 = treasury.freeWorking();

        uint256 g = gasleft();
        CCBarsVault vault = script.execute(owner, allocation);
        console.log("execute gas (deploy, fund, mints, return)", g - gasleft());

        uint256 n = IBars(BARS).balanceOf(address(vault));
        uint256 spent = _sumAmounts(first, n);
        console.log("Bars minted", n);
        console.log("first Bar", first);
        console.log("spent", spent);
        console.log("returned", allocation - spent);
        assertEq(vault.spent(), spent, "spent is the sum of Bar numbers");
        assertGt(allocation - spent, 0);
        assertLt(allocation - spent, (first + n) * 1 ether, "the next Bar did not fit");
        assertEq(_bal(address(vault)), 0, "remainder returned");
        assertEq(treasury.custody(), custody0 - spent, "treasury lost exactly the Bars' deposits");
        assertEq(treasury.freeWorking(), free0 - spent, "claims and debt untouched");
        for (uint256 i; i < n; ++i) {
            assertEq(IBars(BARS).ownerOf(first + i), address(vault));
            assertEq(_bal(IBarsWork(BARS).work(first + i).vault), (first + i) * 1 ether, "Bar vault holds its number");
        }

        // a retry funds nothing, mints nothing, even with a larger allocation
        uint256 custody1 = treasury.custody();
        script.execute(owner, allocation * 2);
        assertEq(treasury.custody(), custody1, "retry moved no BALANCE");
        assertEq(IBars(BARS).balanceOf(address(vault)), n, "retry minted nothing");

        // three Bars to a separate receiving contract; a contract without a receiver is refused
        BarsReceiver sale = new BarsReceiver();
        vm.prank(owner);
        vault.transferBars(address(sale), _ids(first, 3));
        for (uint256 i; i < 3; ++i) assertEq(IBars(BARS).ownerOf(first + i), address(sale));
        vm.prank(owner);
        vm.expectRevert();
        vault.transferBars(address(treasury), _ids(first + 3, 1));

        // an outsider gives one retained Bar's vault extra BALANCE: melting must recover it too
        uint256 extra = 7 ether;
        address donor = makeAddr("donor");
        vm.prank(owner);
        treasury.withdrawWorking(donor, extra);
        address barVault = IBarsWork(BARS).work(first + 3).vault;
        vm.prank(donor);
        IErc20Transfer(BALANCE).transfer(barVault, extra);

        // melting is closed before the deadline
        vm.prank(owner);
        vm.expectRevert(bytes("Minting has not closed"));
        vault.meltBars(_ids(first + 3, 1));

        vm.warp(MINT_END);
        vm.roll(block.number + 1);
        assertFalse(IBarsView(BARS).isOpen());

        // after close: transfer still works, melting returns every released wei to the treasury
        vm.prank(owner);
        vault.transferBars(address(sale), _ids(first + n - 1, 1));
        uint256 kept = n - 4;
        uint256 next = first + 3;
        uint256 before = treasury.custody();
        uint256 freeBefore = treasury.freeWorking();
        uint256 expected = _sumAmounts(next, kept) + extra;
        while (next < first + 3 + kept) {
            uint256 k = first + 3 + kept - next;
            if (k > 10) k = 10;
            vm.prank(owner);
            g = gasleft();
            uint256 got = vault.meltBars(_ids(next, k));
            if (k == 10) console.log("meltBars gas, 10 Bars", g - gasleft());
            assertEq(got, _sumAmounts(next, k) + (next == first + 3 ? extra : 0), "melt recovered");
            next += k;
        }
        assertEq(treasury.custody(), before + expected, "melted BALANCE reached the treasury");
        assertEq(treasury.freeWorking(), freeBefore + expected, "as working funds the owner can withdraw");
        assertEq(IBars(BARS).balanceOf(address(vault)), 0);
        assertEq(_bal(address(vault)), 0);

        // stray BALANCE after close is returned
        vm.prank(owner);
        treasury.withdrawWorking(address(vault), 1 ether);
        before = treasury.custody();
        vm.prank(owner);
        assertEq(vault.returnBalance(), 1 ether);
        assertEq(treasury.custody(), before + 1 ether);
    }

    // promise: a run that stopped after funding and one mint resumes without a second withdrawal and never spends
    // past the recorded allocation
    function test_resumeAfterPartialRunNeverRefunds() public {
        uint256 custody0 = treasury.custody();
        uint256 allocation = custody0 / 2;
        address predicted = script.vaultAddress();
        bytes memory initcode = abi.encodePacked(
            type(CCBarsVault).creationCode,
            abi.encode(script.CORE(), script.TREASURY(), BALANCE, IBars(BARS))
        );
        (bool ok,) = script.FACTORY().call(abi.encodePacked(script.SALT(), initcode));
        assertTrue(ok);
        CCBarsVault vault = CCBarsVault(predicted);
        vm.startPrank(owner);
        treasury.withdrawWorking(predicted, allocation);
        uint256 g = gasleft();
        (, uint256 q, uint256 total) = vault.mintBars(10, allocation);
        console.log("mintBars gas, 10 Bars", g - gasleft());
        vm.stopPrank();
        assertEq(q, 10);
        assertEq(vault.spent(), total);

        script.execute(owner, allocation);
        assertEq(_bal(predicted), 0);
        uint256 spent = vault.spent();
        assertLe(spent, allocation, "never past the allocation");
        assertEq(treasury.custody(), custody0 - spent, "one withdrawal only");
    }

    // promise: a mint that buys nothing reverts rather than reading as an acquisition
    function test_mintOfNothingReverts() public {
        CCBarsVault vault = script.execute(owner, 1 ether); // the vault, funded below the next Bar's price
        assertEq(IBars(BARS).balanceOf(address(vault)), 0);
        vm.prank(owner);
        treasury.withdrawWorking(address(vault), 1 ether);
        vm.prank(owner);
        vm.expectRevert(CCBarsVault.NothingMinted.selector);
        vault.mintBars(10, 1 ether);

        // promise: after close a rerun funds nothing and returns what the vault holds
        vm.warp(MINT_END);
        uint256 custody = treasury.custody();
        script.execute(owner, custody / 2);
        assertEq(_bal(address(vault)), 0);
        assertEq(treasury.custody(), custody + 1 ether);
    }

    // promise: only the Core's owner moves anything, and the vault accepts no ERC721 but Bars
    function test_outsidersMoveNothing() public {
        CCBarsVault vault = script.execute(owner, treasury.custody() / 2);
        uint256 first = IBarsView(BARS).minted() - IBars(BARS).balanceOf(address(vault)) + 1;
        address eve = makeAddr("eve");
        vm.startPrank(eve);
        vm.expectRevert(CCBarsVault.OnlyOwner.selector);
        vault.mintBars(1, 1e30);
        vm.expectRevert(CCBarsVault.OnlyOwner.selector);
        vault.transferBars(eve, _ids(first, 1));
        vm.expectRevert(CCBarsVault.OnlyOwner.selector);
        vault.meltBars(_ids(first, 1));
        vm.expectRevert(CCBarsVault.OnlyOwner.selector);
        vault.returnBalance();
        vm.expectRevert(CCBarsVault.OnlyBars.selector);
        vault.onERC721Received(eve, eve, 1, "");
        vm.expectRevert();
        IBars(BARS).safeTransferFrom(address(vault), eve, first);
        vm.stopPrank();
        assertEq(IBars(BARS).ownerOf(first), address(vault));

        // promise: control follows a Core ownership handover, so no key change strands the Bars
        address next = makeAddr("nextOwner");
        ICoreOwnable core = ICoreOwnable(script.CORE());
        vm.prank(owner);
        core.transferOwnership(next);
        vm.prank(next);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(CCBarsVault.OnlyOwner.selector);
        vault.transferBars(owner, _ids(first, 1));
        vm.prank(next);
        vault.transferBars(next, _ids(first, 1));
        assertEq(IBars(BARS).ownerOf(first), next);
    }
}
