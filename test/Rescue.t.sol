// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane} from "../src/interfaces/Interfaces.sol";

/// `rescueNft` of the Core: an ERC721 token leaves only when the Core's books do not hold it. real Credits, Statements,
/// house and a real ERC721 of the fork
contract RescueTest is Fixture {
    /// a live ERC721 collection on the fork (BAYC)
    address internal constant FOREIGN = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
    address internal dest = address(0xD357);
    address internal stranger = address(0x5757);

    event NftRescued(address indexed token, uint256 indexed id, address indexed to);

    function _rescue(address token, uint256 id, address to) internal {
        vm.prank(owner);
        core.rescueNft(token, id, to);
    }

    function _expectRescueRevert(address token, uint256 id, bytes4 sel) internal {
        vm.expectRevert(sel);
        vm.prank(owner);
        core.rescueNft(token, id, dest);
    }

    function test_REVERT_aCreditInAPileStays() public {
        uint256[] memory ids = _fillEthPile(3);
        (bool inPile,,,) = core.creditInfo(ids[1]);
        assertTrue(inPile, "setup: the credit is in the pile");
        _expectRescueRevert(address(CREDITS), ids[1], ICore.InPile.selector);
        assertEq(CREDITS.ownerOf(ids[1]), address(core), "the credit moved");
        assertEq(core.pileSize(Lane.Eth), 3, "the pile changed");
    }

    function test_OK_aCreditSentStraightToTheCoreLeaves() public {
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), ids[0]);
        (bool inPile,,,) = core.creditInfo(ids[0]);
        assertFalse(inPile, "a straight transfer is not in a pile");
        vm.expectEmit(true, true, true, true, address(core));
        emit NftRescued(address(CREDITS), ids[0], dest);
        _rescue(address(CREDITS), ids[0], dest);
        assertEq(CREDITS.ownerOf(ids[0]), dest, "the credit did not reach the destination");
    }

    function test_OK_aCreditThatLeftItsPileByAComposeIsNotInTheCoreAnyMore() public {
        Composed memory c = _composeOnce();
        _expectRescueRevert(address(CREDITS), c.ids[0], ICore.NotHolder.selector);
    }

    function test_REVERT_aHeldStatementStays() public {
        Composed memory c = _composeOnce();
        (bool held,,,) = core.statementInfo(c.sid);
        assertTrue(held, "setup: the statement is held");
        // listed on the house: the house holds it, the books say held
        _expectRescueRevert(address(STATEMENTS), c.sid, ICore.Held.selector);
        assertEq(STATEMENTS.ownerOf(c.sid), address(house), "the statement moved");
    }

    function test_REVERT_anExitLaneStatementHeldByTheCoreStays() public {
        _enterPhase2();
        uint256 sid = _exitLaneStatement();
        (bool held, Lane lane,,) = core.statementInfo(sid);
        assertTrue(held && lane == Lane.Exit, "setup: an exit lane statement is held");
        assertEq(STATEMENTS.ownerOf(sid), address(core), "setup: the core holds it");
        _expectRescueRevert(address(STATEMENTS), sid, ICore.Held.selector);
    }

    function _exitLaneStatement() internal returns (uint256 sid) {
        uint256[] memory ids = _credits(seller, 80);
        // the exit pot pays for the credits: fund it with the exit token the module pays out
        xt.mint(address(core), 1_000_000_000e18);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        assertEq(core.pileSize(Lane.Exit), 80, "setup: eighty credits in the exit pile");
        uint256 supply = STATEMENTS.supply();
        core.composeExit();
        sid = supply + 1;
    }

    function test_OK_aStatementThatCameBackAfterASaleLeaves() public {
        (uint256 sid,) = _sellStatement(address(0xB1D));
        core.syncStatement(sid);
        (bool held,,,) = core.statementInfo(sid);
        assertFalse(held, "setup: the sale is settled");
        vm.prank(address(0xB1D));
        STATEMENTS.transferFrom(address(0xB1D), address(core), sid);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "setup: the statement sits in the core");
        _rescue(address(STATEMENTS), sid, dest);
        assertEq(STATEMENTS.ownerOf(sid), dest, "the statement did not reach the destination");
    }

    function test_REVERT_aSoldStatementWithItsRecordStillStaysEvenIfItIsBack() public {
        (uint256 sid,) = _sellStatement(address(0xB1D));
        // not synced: the books still say held
        vm.prank(address(0xB1D));
        STATEMENTS.transferFrom(address(0xB1D), address(core), sid);
        _expectRescueRevert(address(STATEMENTS), sid, ICore.Held.selector);
    }

    function test_OK_aForeignErc721Leaves() public {
        (bool ok, bytes memory out) = FOREIGN.staticcall(abi.encodeWithSignature("ownerOf(uint256)", uint256(1)));
        assertTrue(ok && out.length == 32, "setup: the collection answers on the fork");
        address holder = abi.decode(out, (address));
        vm.prank(holder);
        (bool sent,) = FOREIGN.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, address(core), 1));
        assertTrue(sent, "setup: the token reached the core");
        _rescue(FOREIGN, 1, dest);
        (, out) = FOREIGN.staticcall(abi.encodeWithSignature("ownerOf(uint256)", uint256(1)));
        assertEq(abi.decode(out, (address)), dest, "the token did not reach the destination");
    }

    function test_REVERT_aTokenTheCoreDoesNotHold() public {
        (bool ok, bytes memory out) = FOREIGN.staticcall(abi.encodeWithSignature("ownerOf(uint256)", uint256(2)));
        assertTrue(ok && abi.decode(out, (address)) != address(core), "setup");
        _expectRescueRevert(FOREIGN, 2, ICore.NotHolder.selector);
    }

    function test_REVERT_noErc20AndNoEoaCanBeNamed() public {
        _enterPhase2();
        xt.mint(address(core), 5e18);
        _fundPot(1 ether);
        _expectRescueRevert(address(coin), 1, ICore.NotHolder.selector);
        _expectRescueRevert(address(xt), 5e18, ICore.NotHolder.selector);
        _expectRescueRevert(Mainnet_WETH, 1, ICore.NotHolder.selector);
        _expectRescueRevert(address(0xABCD), 1, ICore.NotHolder.selector);
        _expectRescueRevert(address(0), 1, ICore.NotHolder.selector);
        assertEq(xt.balanceOf(address(core)), 5e18, "exit token left");
    }

    address internal constant Mainnet_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function test_REVERT_notTheOwner() public {
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), ids[0]);
        vm.expectRevert(ICore.OnlyOwner.selector);
        vm.prank(stranger);
        core.rescueNft(address(CREDITS), ids[0], stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        vm.prank(seller);
        core.rescueNft(address(CREDITS), ids[0], seller);
        assertEq(CREDITS.ownerOf(ids[0]), address(core), "the credit moved");
    }

    function test_REVERT_theZeroDestination() public {
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), ids[0]);
        vm.expectRevert(ICore.ZeroAddress.selector);
        vm.prank(owner);
        core.rescueNft(address(CREDITS), ids[0], address(0));
    }

    function test_OK_theEngineKeepsWorkingAfterARescue() public {
        uint256[] memory ids = _fillEthPile(5);
        uint256[] memory stray = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), stray[0]);
        _rescue(address(CREDITS), stray[0], dest);
        assertEq(core.pileSize(Lane.Eth), 5, "the pile changed");
        assertEq(core.pileHead(Lane.Eth), ids[0], "the pile head changed");
        _fillEthPile(75);
        assertEq(core.pileSize(Lane.Eth), 80, "the pile did not fill");
        _composeOnce();
    }
}
