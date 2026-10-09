// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {
    IArtCoinsFactoryV2 as F,
    IArtCoinsHookV2,
    IArtCoinsTokenV2,
    IArtCoinsLpLockerV2,
    IArtCoinsFeeEscrowV2,
    IFeeAutoSwapperV2
} from "../src/interfaces/ArtCoinsV2.sol";
import {V2Stack} from "./utils/V2Stack.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";

/// bounty recipient with an empty receive: the hook's 2300 gas push succeeds
contract EmptyRecipient {
    receive() external payable {}
}

/// bounty recipient that writes storage in receive: the 2300 gas push fails and the hook credits the escrow
contract WritingRecipient {
    uint256 public hits;

    receive() external payable {
        hits += 1;
    }
}

/// @notice the real artcoins v2 stack, deployed from the vendored artifacts onto the pinned fork, with a restricted
/// coin launched, traded and drained through the real hook, locker and escrow. gas is logged, run with -vv
contract V2StackTest is Test {
    error TransferRestricted(address from, address to, uint256 amount);

    V2Stack.Params internal p;
    V2Stack.Stack internal s;
    address internal owner;
    address internal creator;
    address internal buyer;
    TestSwapRouter internal swapper;
    uint256 internal stackGas;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        owner = makeAddr("v2 owner");
        creator = makeAddr("creator");
        buyer = makeAddr("buyer");
        vm.deal(owner, 10 ether);
        vm.deal(buyer, 100 ether);
        swapper = new TestSwapRouter();
        p = V2Stack.mainnetParams(owner);
        uint256 g = gasleft();
        s = V2Stack.deploy(p);
        stackGas = g - gasleft();
    }

    /// a launch on the v2 factory at the mainnet factory minimums: bounty 9000 (the 1000 minimum protocol skim share
    /// leaves 9000), lp fee 3000 pips, baseline skim 1000 bps (10 points), sniper 9000 bps falling to 1000 over 30
    /// minutes, restricted, protocol slot at the factory default 2000
    function _config(address bountyRecipient, bytes32 salt) internal view returns (F.DeploymentConfigV2 memory c) {
        c.token = F.TokenConfigV2({
            tokenAdmin: owner,
            name: "Flow",
            symbol: "FLOW",
            salt: salt,
            image: "ipfs://image",
            description: "{}",
            totalSupply: 1e27,
            renderer: address(0)
        });
        c.pool = F.PoolConfigV2({
            hook: s.hook,
            tickIfToken0IsCoin: -175000,
            tickSpacing: 200,
            extension: address(0),
            extensionData: ""
        });
        c.fee = F.FeeConfigV2({
            lpFeePips: 3000,
            baselineSkimBps: 1000,
            bountyBps: 9000,
            maxReferralBpsOfVolume: 0,
            bountyRecipient: payable(bountyRecipient)
        });
        address[] memory rr = new address[](1);
        rr[0] = creator;
        uint16[] memory rb = new uint16[](1);
        rb[0] = 8000;
        int24[] memory lo = new int24[](1);
        lo[0] = -175000;
        int24[] memory hi = new int24[](1);
        hi[0] = 887200;
        uint16[] memory pb = new uint16[](1);
        pb[0] = 10000;
        c.locker = F.LockerConfigV2({
            locker: s.locker,
            rewardRecipients: rr,
            rewardBps: rb,
            tickLower: lo,
            tickUpper: hi,
            positionBps: pb
        });
        c.mev = F.MevConfigV2({module: s.mev, startingSkimBps: 9000, windowSeconds: 1800});
        c.restriction = F.RestrictionConfigV2({restricted: true, allowed: new address[](0)});
    }

    function _launch(address bountyRecipient, bytes32 salt) internal returns (address coin, PoolKey memory key) {
        F.DeploymentConfigV2 memory c = _config(bountyRecipient, salt);
        address predicted = F(s.factory).predictToken(owner, c);
        // the factory stays deprecated: the owner may launch anyway
        vm.prank(owner);
        uint256 g = gasleft();
        coin = F(s.factory).deployTokenAsOwner{value: p.deployFee}(c, p.protocolBps);
        console.log("launch gas", g - gasleft());
        assertEq(coin, predicted, "predictToken");
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: Mainnet.POOL_FEE,
            tickSpacing: Mainnet.TICK_SPACING,
            hooks: IHooks(s.hook)
        });
    }

    function _buy(PoolKey memory key, uint256 ethIn) internal {
        vm.prank(buyer);
        swapper.swap{value: ethIn}(key, true, -int256(ethIn), buyer);
    }

    function _sell(PoolKey memory key, address coin, uint256 coinIn) internal {
        vm.startPrank(buyer);
        IArtCoinsTokenV2(coin).approve(address(swapper), coinIn);
        swapper.swap(key, false, -int256(coinIn), buyer);
        vm.stopPrank();
    }

    function test_stackDeploysAndChecks() public view {
        V2Stack.check(s, p); // the DeployV2Lib post deploy requires, again on the stored stack
        console.log("v2 stack deploy gas (incl. hook salt mining and checks)", stackGas);
        assertEq(F(s.factory).owner(), owner);
        assertTrue(F(s.factory).deprecated());
        assertEq(F(s.factory).deployFee(), 0.069 ether);
        assertEq(uint160(s.hook) & 0x3FFF, 0x28CC);
    }

    function test_launchRestrictedCoinWithEmptyRecipient() public {
        EmptyRecipient r = new EmptyRecipient();
        (address coin, PoolKey memory key) = _launch(address(r), bytes32(uint256(1)));
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin);
        assertTrue(F(s.factory).isCoin(coin));
        assertTrue(t.restricted(), "restricted");
        assertEq(t.admin(), owner);
        assertEq(t.totalSupply(), 1e27);
        assertEq(t.canonicalHook(), s.hook);
        assertEq(IArtCoinsHookV2(s.hook).skimConfig(t.canonicalPoolId()).bountyRecipient, address(r));
        assertEq(IArtCoinsHookV2(s.hook).skimConfig(t.canonicalPoolId()).bountyBps, 9000);
        assertEq(IArtCoinsHookV2(s.hook).skimConfig(t.canonicalPoolId()).lpFeePips, 3000);
        // the engine, router and swapper are not on the allowlist, the locker and escrow are seeded and pinned
        assertFalse(t.isAllowed(address(swapper)));
        assertTrue(t.isAllowed(s.locker) && t.isPinned(s.locker));
        assertTrue(t.isAllowed(s.escrow) && t.isPinned(s.escrow));

        // buy and sell through PoolManager.unlock, the bounty lands on the empty receive recipient at once
        uint256 before = address(r).balance;
        _buy(key, 1 ether);
        uint256 bounty = address(r).balance - before;
        assertGt(bounty, 0, "bounty pushed");
        assertEq(IArtCoinsFeeEscrowV2(s.escrow).balances(address(r), address(0)), 0, "nothing escrowed");
        uint256 got = t.balanceOf(buyer);
        assertGt(got, 0, "bought");
        console.log("bounty on a 1 eth buy", bounty);
        _sell(key, coin, got / 2);
        assertEq(t.balanceOf(buyer), got - got / 2, "sold");
        assertGt(address(r).balance, before + bounty, "sell skim also pushed");
    }

    function test_writingRecipientIsCreditedInEscrowAndClaims() public {
        WritingRecipient r = new WritingRecipient();
        (, PoolKey memory key) = _launch(address(r), bytes32(uint256(2)));
        IArtCoinsFeeEscrowV2 e = IArtCoinsFeeEscrowV2(s.escrow);
        uint256 before = address(r).balance; // a test address can already hold dust on the fork
        _buy(key, 1 ether);
        assertEq(address(r).balance, before, "stipend push failed");
        assertEq(r.hits(), 0);
        uint256 credit = e.balances(address(r), address(0));
        assertGt(credit, 0, "credited in escrow");
        e.claim(address(r), address(0)); // anyone, all gas forwarded
        assertEq(address(r).balance, before + credit, "claim delivered");
        assertEq(r.hits(), 1);
        assertEq(e.balances(address(r), address(0)), 0);
    }

    function test_restrictedTransfersAndBurns() public {
        EmptyRecipient r = new EmptyRecipient();
        (address coin, PoolKey memory key) = _launch(address(r), bytes32(uint256(3)));
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin);
        _buy(key, 1 ether);
        uint256 bal = t.balanceOf(buyer);
        address other = makeAddr("other");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(TransferRestricted.selector, buyer, other, 1));
        t.transfer(other, 1);
        // burn and burnFrom bypass the restriction
        vm.prank(buyer);
        t.burn(1e18);
        assertEq(t.balanceOf(buyer), bal - 1e18);
        address spender = makeAddr("spender");
        vm.prank(buyer);
        t.approve(spender, 2e18);
        vm.prank(spender);
        t.burnFrom(buyer, 2e18);
        assertEq(t.balanceOf(buyer), bal - 3e18);
        assertEq(t.totalSupply(), 1e27 - 3e18);
    }

    function test_lpFeeAccruesAndLockerPaysRecipients() public {
        EmptyRecipient r = new EmptyRecipient();
        (address coin, PoolKey memory key) = _launch(address(r), bytes32(uint256(4)));
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin);
        _buy(key, 5 ether);
        _sell(key, coin, t.balanceOf(buyer) / 2);
        assertEq(creator.balance, 0);
        assertEq(t.balanceOf(creator), 0);
        IArtCoinsLpLockerV2(s.locker).collectRewards(coin);
        uint256 ethPaid = creator.balance + IArtCoinsFeeEscrowV2(s.escrow).balances(creator, address(0));
        uint256 coinPaid = t.balanceOf(creator) + IArtCoinsFeeEscrowV2(s.escrow).balances(creator, coin);
        assertGt(ethPaid, 0, "eth lp fee reached the reward recipient");
        assertGt(coinPaid, 0, "coin lp fee reached the reward recipient");
        console.log("lp fee eth to creator", creator.balance);
        console.log("lp fee coin to creator", t.balanceOf(creator));
    }

    /// the fee swapper of FLOW decision 20: end recipient a plain address here, deployed by this test, bound to the
    /// coin by its deployer, registered by the owner as a non core escrow depositor
    function test_feeSwapperDeploysAndBinds() public {
        EmptyRecipient r = new EmptyRecipient();
        (address coin,) = _launch(address(r), bytes32(uint256(5)));
        address sw = V2Stack.deploySwapper(s, owner, address(r), address(0));
        vm.prank(owner);
        IArtCoinsFeeEscrowV2(s.escrow).addDepositor(sw, false);
        IFeeAutoSwapperV2(sw).setup(coin);
        assertTrue(IFeeAutoSwapperV2(sw).setupFinalized());
        assertEq(IFeeAutoSwapperV2(sw).coin(), coin);
        assertEq(IFeeAutoSwapperV2(sw).endRecipient(), address(r));
        assertEq(IFeeAutoSwapperV2(sw).feeEscrow(), s.escrow);
    }

    /// the v1 launch values do not fit the mainnet env knobs (V2-PORT section 5.1): bounty 9500 reverts, and a launch
    /// with no fee on either leg (lp fee and baseline skim both 0) reverts
    function test_v1LaunchValuesRevert() public {
        EmptyRecipient r = new EmptyRecipient();
        F.DeploymentConfigV2 memory c = _config(address(r), bytes32(uint256(6)));
        c.fee.bountyBps = 9500;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("BountyBpsTooHigh(uint16,uint16)", 9500, 9000));
        F(s.factory).deployTokenAsOwner{value: p.deployFee}(c, p.protocolBps);
        c.fee.bountyBps = 9000;
        c.fee.lpFeePips = 0;
        c.fee.baselineSkimBps = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("ZeroFeeLaunch()"));
        F(s.factory).deployTokenAsOwner{value: p.deployFee}(c, p.protocolBps);
    }

    /// the coin admin repoints the hook bounty recipient until it calls `lockRecipients()`. a caller that is not the
    /// admin is refused, and after the lock the admin is refused too
    function test_coinAdminRepointsTheBountyRecipientUntilLocked() public {
        EmptyRecipient r = new EmptyRecipient();
        EmptyRecipient r2 = new EmptyRecipient();
        (address coin, PoolKey memory key) = _launch(address(r), bytes32(uint256(8)));
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin);
        bytes32 pid = t.canonicalPoolId();
        IArtCoinsHookV2 h = IArtCoinsHookV2(s.hook);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSignature("NotCoinAdmin()"));
        h.setBountyRecipient(pid, payable(address(r2)));
        vm.prank(owner);
        h.setBountyRecipient(pid, payable(address(r2)));
        assertEq(h.skimConfig(pid).bountyRecipient, address(r2));
        uint256 before = address(r2).balance;
        _buy(key, 1 ether);
        assertGt(address(r2).balance, before, "the new recipient is paid");
        assertFalse(t.recipientsLocked());
        vm.prank(owner);
        t.lockRecipients();
        assertTrue(t.recipientsLocked());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("RecipientsLocked()"));
        h.setBountyRecipient(pid, payable(address(r)));
    }

    /// the coin admin repoints a locker reward slot until `lockRecipients()`, and the protocol slot is frozen
    function test_coinAdminRepointsALockerRewardRecipient() public {
        EmptyRecipient r = new EmptyRecipient();
        (address coin,) = _launch(address(r), bytes32(uint256(9)));
        IArtCoinsLpLockerV2 l = IArtCoinsLpLockerV2(s.locker);
        address next = makeAddr("next reward recipient");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSignature("NotCoinAdmin()"));
        l.setRewardRecipient(coin, 0, next);
        vm.prank(owner);
        l.setRewardRecipient(coin, 0, next);
        assertEq(l.rewardRecipients(coin)[0], next);
        (bool hasSlot, uint256 idx) = l.protocolSlotIndex(coin);
        assertTrue(hasSlot, "the factory appended the protocol slot");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("ProtocolSlotFrozen()"));
        l.setRewardRecipient(coin, idx, next);
        vm.prank(owner);
        IArtCoinsTokenV2(coin).lockRecipients();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("RecipientsLocked()"));
        l.setRewardRecipient(coin, 0, address(r));
    }
}
