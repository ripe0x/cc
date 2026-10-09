// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {Lane, Settings} from "../../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../../src/interfaces/AuctionHouse.sol";
import {HandlerOwner} from "./HandlerOwner.sol";
import {MockExitModule} from "../standins/MockExitModule.sol";
import {SellingController} from "../attackers/SaleAttackers.sol";

/// @notice the sale controller and the owner as an adversary, on the real house. actions: `buy` in buy only mode, the
/// controller's own `sellTo` through a selling controller the owner installs, reprice then bid then outbid, the
/// controller's sale settings and mode flips, the owner swapping the controller and the exit module in one go, the three
/// one way locks and the two step handover. every call is checked against a model written from docs/FLOW.md: who may
/// sell, at what least price, what is booked where, who holds the statement after. a refusal must carry the selector
/// the model names. nothing here reverts, a violation goes to `viol`.
abstract contract HandlerSale is HandlerOwner {
    /// the controller that sells statements for the owner, and its buyers
    SellingController public selling;
    /// every owner the run has had, in order, and the next heirs
    address[] public formerOwners;
    address[] public heirs;
    uint256 public heirNext;
    /// every exit module the owner ever installed: none may have called the core successfully from inside an exit
    MockExitModule[] public modulesEver;
    /// the one way locks seen by the handler. they must never come undone
    bool public gLockedC;
    bool public gLockedE;
    bool public gLockedT;
    /// sales through `sellTo` and the eth they brought
    uint256 public gSoldTo;
    uint256 public gSoldToEth;

    /// the fixture hands over what only it can build (from artifacts, so the contract stays small)
    function setSaleParts(address selling_, address[] calldata heirs_) external {
        selling = SellingController(payable(selling_));
        controllers.push(selling_);
        watched.push(selling_);
        _snapBase(selling_);
        for (uint256 i; i < heirs_.length; ++i) {
            heirs.push(heirs_[i]);
            watched.push(heirs_[i]);
            _snapBase(heirs_[i]);
        }
        if (address(module) != address(0)) modulesEver.push(module);
    }

    function formerOwnerCount() external view returns (uint256) {
        return formerOwners.length;
    }

    function moduleEverCount() external view returns (uint256) {
        return modulesEver.length;
    }

    function _bps() internal view returns (uint256) {
        return core.settings().saleToBuybackBps;
    }

    function _hardFloor(uint256 sid) internal view returns (uint256) {
        (,, uint256 cost,) = core.statementInfo(sid);
        return cost * core.settings().saleFloorBps / 10_000;
    }

    /*//////////////////////////////////////////////////////////////
                         THE MODEL OF A SALE THROUGH sellTo
    //////////////////////////////////////////////////////////////*/

    struct SalePre {
        uint256 bal;
        uint256 pot;
        uint256 tb;
        uint256 rate;
        uint256 payerBal;
        uint256 held;
        uint256 bps;
        uint256 floor;
        uint256 price;
        uint256 value;
        bool priced;
        address buyer;
        address payer;
        bytes4 want;
    }

    /// the refusal the core's own order of checks gives for a statement in ghost state `g` once the caller is the
    /// controller (`sellTo`): the hard floor, then the record, then a live bid. zero when the sale must go through
    function _sellToRefusal(SG storage g, uint256 value, uint256 floor) internal view returns (bytes4) {
        if (value < floor) return ICore.BelowFloor.selector;
        if (g.status == S_LISTED) return g.bid != 0 ? ICore.HasBid.selector : bytes4(0);
        return ICore.NotListed.selector;
    }

    /// reads the books before a sale
    function _salePre(uint256 sid, address payer, address buyer, uint256 value) internal view returns (SalePre memory p) {
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.tb = core.ethToBuyback();
        p.rate = core.ethRate();
        p.payerBal = payer.balance;
        p.held = core.heldStatements().length;
        p.bps = _bps();
        p.floor = _hardFloor(sid);
        p.value = value;
        p.buyer = buyer;
        p.payer = payer;
    }

    /// a sale went through: the whole payment is booked, split by saleToBuybackBps, the statement is with the buyer, the
    /// record is gone and the house has no auction for it. the payment is at least the hard floor
    function _saleDone(uint256 sid, SalePre memory p, uint256 paid) internal {
        SG storage g = _sg[sid];
        if (p.want != 0) _flag(V_SALE_PATH, "a sale the model refuses went through");
        if (paid < p.floor) _flag(V_SALE_PATH, "a statement was sold below the hard floor");
        _eth(p.bal, 0, paid, "sellTo");
        uint256 toBb = paid * p.bps / 10_000;
        if (core.ethToBuyback() != p.tb + toBb || core.ethPot() != p.pot + paid - toBb) {
            _flag(V_SALE_PATH, "the sale payment was not booked exactly, split by saleToBuybackBps");
        }
        _potIn(paid - toBb);
        if (_ownerOf(sid) != p.buyer) _flag(V_SALE_PATH, "the buyer does not hold the statement");
        (bool held,,,) = core.statementInfo(sid);
        if (held || core.heldStatements().length != p.held - 1) _flag(V_SALE_PATH, "the core record was not cleared");
        (bool exists,) = house.getAuctionFor(address(STATEMENTS), sid);
        if (exists) _flag(V_SALE_PATH, "the house still has an auction for a statement sold at once");
        if (house.pendingRefunds(address(core)) != gWon - gCollected) _flag(V_HOUSE, "a sellTo sale touched the house debt");
        g.status = S_SOLD_TO;
        g.price = paid;
        g.winner = p.buyer;
        g.synced = true;
        g.reserve = p.floor;
        g.floorAtSet = p.floor;
        gSoldTo++;
        gSoldToEth += paid;
    }

    /// a refused sale changes nothing: books, holder, record, house
    function _saleRefused(uint256 sid, SalePre memory p, bytes memory why, uint8 a) internal {
        _failed(p.bal, p.pot, p.rate, "sale");
        if (core.ethToBuyback() != p.tb) _flag(V_REVERT_CHANGED, "a refused sale moved the buyback pot");
        SG storage g = _sg[sid];
        if (g.status == S_LISTED && _ownerOf(sid) != address(house)) _flag(V_SALE_PATH, "a refused sale moved a listing");
        if (p.want == 0 || bytes4(why) != p.want) _unexpected(a, why);
    }

    /*//////////////////////////////////////////////////////////////
                         buy, buy only mode (the first controller)
    //////////////////////////////////////////////////////////////*/

    /// the refusal of `ControllerV1.buy` in the order of its checks: the mode, the record `priceOf` reads, the payment, the
    /// controller in force (the core takes `sellTo` from the controller only), then what `sellTo` checks
    function _buyRefusal(uint256 sid, SalePre memory p, bool short_) internal view returns (bytes4) {
        if (!IControllerV1(v1).buyOnly()) return IControllerV1.NotBuyOnly.selector;
        (bool held, Lane lane,, uint64 at) = core.statementInfo(sid);
        if (!held || lane != Lane.Eth || at == 0) return IControllerV1.NotForSale.selector;
        if (short_) return IControllerV1.Underpaid.selector;
        if (core.controller() != v1) return ICore.OnlyController.selector;
        return _sellToRefusal(_sg[sid], p.price, p.floor);
    }

    /// a buyer pays the asking price of the first controller, with an excess now and then and a short payment now and
    /// then. in auction mode, with a bid, with another controller in force, on a sold or exited statement it must
    /// refuse with the model's selector. a sale pays the ask exactly, the excess comes back
    function buyOnlyBuy(uint256 sIdx, uint256 aSeed, uint256 xSeed, uint256 mode) external checked {
        uint8 a = A_BUY;
        (uint256 sid, bool found) = _pickBy(sIdx, mode % 4 == 0 ? K_ANY : K_LISTED);
        if (!found) return _skip(a);
        // the owner, now and then, puts the first controller back in force in buy only mode: a legal owner move that
        // keeps the buy path busy under the fuzzer. a locked controller door is left alone
        if (mode % 3 == 1) {
            vm.startPrank(owner);
            if (core.controller() != v1 && !core.controllerLocked()) core.setController(v1);
            if (core.controller() == v1 && !IControllerV1(v1).buyOnly()) IControllerV1(v1).setBuyOnly(true);
            vm.stopPrank();
        }
        address who = _actor(aSeed);
        uint256 price;
        bool priced;
        try IControllerV1(v1).priceOf(sid) returns (uint256 pr) {
            price = pr;
            priced = true;
        } catch {}
        bool short_ = priced && price != 0 && xSeed % 7 == 0;
        uint256 value = !priced ? 1 ether : (short_ ? price - 1 : price + (xSeed % 3 == 0 ? 0 : _logBound(xSeed, 1, 1 ether)));
        SalePre memory p = _salePre(sid, who, who, value);
        p.price = price;
        p.priced = priced;
        p.want = _buyRefusal(sid, p, short_);
        vm.deal(who, who.balance + value);
        p.payerBal = who.balance;
        RS memory rs = _rs();
        _att(a);
        vm.prank(who);
        try IControllerV1(v1).buy{value: value}(sid) {
            _ok(a);
            if (p.payerBal - who.balance != price) {
                _flag(V_SALE_PATH, "the buyer did not pay exactly the ask, or the excess was not refunded");
            }
            if (address(v1).balance != baseOf[v1].eth) _flag(V_SALE_PATH, "the controller kept eth after a buy");
            _saleDone(sid, p, price);
        } catch (bytes memory why) {
            _saleRefused(sid, p, why, a);
        }
        _rsCheck(rs, 0);
    }

    /// the owner's controller, when the owner has installed the selling one, sells at the payment the caller sends: below
    /// the hard floor it refuses, at or above it sells to a buyer the owner chose (an actor or a fresh address). the whole
    /// payment is booked. with another controller in force the call is refused for OnlyController
    function ownerSell(uint256 sIdx, uint256 aSeed, uint256 vSeed, uint256 mode) external checked {
        uint8 a = A_OWNER_SELL;
        (uint256 sid, bool found) = _pickBy(sIdx, mode % 3 == 0 ? K_ANY : K_LISTED);
        if (!found) return _skip(a);
        if (mode % 2 == 0 && core.controller() != address(selling) && !core.controllerLocked()) {
            vm.prank(owner);
            core.setController(address(selling));
        }
        if (core.controller() != address(selling) && aSeed % 4 != 0) return _skip(a);
        address who = _actor(aSeed);
        address buyer = mode % 5 == 0 ? _actor(vSeed) : address(uint160(uint256(keccak256(abi.encode("buyer", vSeed)))));
        uint256 floor = _hardFloor(sid);
        uint256 m = (mode >> 4) % 5;
        uint256 value = m == 0 ? (floor == 0 ? 0 : floor - 1) : m == 1
            ? floor
            : m == 2 ? floor + _logBound(vSeed, 1, 1 ether) : m == 3 ? floor * 2 : 0;
        SalePre memory p = _salePre(sid, who, buyer, value);
        p.want = core.controller() != address(selling) ? ICore.OnlyController.selector : _sellToRefusal(_sg[sid], value, floor);
        vm.deal(who, who.balance + value);
        RS memory rs = _rs();
        _att(a);
        vm.prank(who);
        try selling.sell{value: value}(sid, buyer) {
            _ok(a);
            _saleDone(sid, p, value);
        } catch (bytes memory why) {
            _saleRefused(sid, p, why, a);
        }
        _rsCheck(rs, 0);
    }

    /// a first bidder's sequence: reprice the listing to the ask, bid the least the house takes, and now and then outbid it
    /// by five percent. the model is the one of `repriceStatement` and `bid`, which this calls
    function repriceBid(uint256 sIdx, uint256 aSeed, uint256 amtSeed, uint256 mode) external checked {
        uint8 a = A_REPRICE_BID;
        (uint256 sid, bool found) = _pickBy(sIdx, K_LISTED);
        if (!found || _sg[sid].bid != 0) return _skip(a);
        _att(a);
        uint256 before = successes[A_BID];
        try this.repriceStatement(sIdx, 1) {} catch {}
        try this.bid(sIdx, aSeed, amtSeed, 1) {} catch {}
        if (mode % 2 == 0) {
            try this.bid(sIdx, aSeed ^ 1, amtSeed, 6) {} catch {}
        }
        if (successes[A_BID] > before) _ok(a);
    }

    /*//////////////////////////////////////////////////////////////
                  the controller's sale settings and its mode
    //////////////////////////////////////////////////////////////*/

    /// @dev the sale setting the handler tries: its selector, the value, and whether the model says it is inside the bounds
    /// (a helper so the locals of `saleSettings` fit the stack)
    function _saleCase(IControllerV1 c, uint256 seed, uint256 which, bool bad, uint256 start, uint256 floor_)
        internal
        view
        returns (bytes4 sel, uint256 v, bool valid)
    {
        if (which == 0) {
            sel = IControllerV1.setStartBps.selector;
            v = bad ? (seed % 2 == 0 ? floor_ - 1 : 40_001) : _f(seed, floor_, 40_000, start);
            valid = v >= 1_000 && v <= 40_000 && v >= floor_;
        } else if (which == 1) {
            sel = IControllerV1.setStepBps.selector;
            v = bad ? 5_001 + seed % 1000 : _f(seed, 0, 5_000, c.stepBps());
            valid = v <= 5_000;
        } else if (which == 2) {
            sel = IControllerV1.setStepEvery.selector;
            v = bad ? (seed % 2 == 0 ? 59 : 30 days + 1) : _f(seed, 60, 30 days, c.stepEvery());
            valid = v >= 60 && v <= 30 days;
        } else {
            sel = IControllerV1.setFloorBps.selector;
            v = bad ? (seed % 2 == 0 ? 999 : start + 1) : _f(seed, 1_000, start, floor_);
            valid = v >= 1_000 && v <= start;
        }
    }

    /// the owner sets one of the four sale numbers of the first controller to a value inside or outside the bounds of
    /// docs/FLOW.md 9.3 (written out again here), or a stranger tries. inside: it goes through and reads back. outside:
    /// BadSetting with the field. a stranger: OnlyOwner. no asset, pot or house debt moves
    function saleSettings(uint256 seed, uint256 mode) external checked {
        uint8 a = A_SALE_SETTINGS;
        IControllerV1 c = IControllerV1(v1);
        uint256 which = mode % 4;
        bool stranger = (mode >> 8) % 6 == 0;
        bool bad = (mode >> 12) % 4 == 0;
        uint256 start = c.startBps();
        uint256 floor_ = c.floorBps();
        (bytes4 sel, uint256 v, bool valid) = _saleCase(c, seed, which, bad, start, floor_);
        address caller = stranger ? address(uint160(uint256(keccak256(abi.encode("stranger", seed))))) : owner;
        OPre memory pre = _opre();
        _att(a);
        vm.prank(caller);
        (bool ok, bytes memory out) = address(c).call(abi.encodeWithSelector(sel, v));
        bytes4 want = stranger ? IControllerV1.OnlyOwner.selector : (valid ? bytes4(0) : IControllerV1.BadSetting.selector);
        if (ok) {
            if (want != 0) _flag(V_OWNER, "a sale setting the model refuses was accepted");
            uint256 got = which == 0 ? c.startBps() : which == 1 ? c.stepBps() : which == 2 ? c.stepEvery() : c.floorBps();
            if (got != v) _flag(V_OWNER, "a sale setting did not read back");
            gOwnerCalls++;
        } else {
            if (want == 0 || bytes4(out) != want) _unexpected(a, out);
            if (c.startBps() != start || c.floorBps() != floor_) _flag(V_OWNER, "a refused sale setting changed a value");
            gOwnerRefused++;
        }
        _opost(pre, "saleSettings");
        _ok(a);
    }

    /// the owner flips the first controller between auction mode and buy only mode, or a stranger tries
    function flipMode(uint256 seed, uint256 mode) external checked {
        uint8 a = A_FLIP_MODE;
        IControllerV1 c = IControllerV1(v1);
        bool on = mode % 2 == 0;
        bool stranger = mode % 5 == 0;
        address caller = stranger ? address(uint160(uint256(keccak256(abi.encode("flip", seed))))) : owner;
        bool was = c.buyOnly();
        OPre memory pre = _opre();
        _att(a);
        vm.prank(caller);
        try c.setBuyOnly(on) {
            if (stranger) _flag(V_OWNER, "a stranger flipped the sale mode");
            if (c.buyOnly() != on) _flag(V_OWNER, "the sale mode did not flip at once");
        } catch (bytes memory why) {
            if (!stranger || bytes4(why) != IControllerV1.OnlyOwner.selector) _unexpected(a, why);
            if (c.buyOnly() != was) _flag(V_OWNER, "a refused flip changed the mode");
        }
        _opost(pre, "flipMode");
        _ok(a);
    }

    /*//////////////////////////////////////////////////////////////
                    the owner swapping the controller and the module
    //////////////////////////////////////////////////////////////*/

    /// the call a hostile module makes from inside an exit: nothing, or one door of the core, or the selling controller
    function _callout(uint256 k, uint256 seed, MockExitModule next) internal {
        if (k == 0) return;
        address target = address(core);
        bytes memory data;
        uint256 n = everHeld.length;
        uint256 sid = n == 0 ? 1 : everHeld[seed % n];
        if (k == 1) data = abi.encodeCall(ICore.compose, ());
        else if (k == 2) data = abi.encodeCall(ICore.skim, ());
        else if (k == 3) data = abi.encodeCall(ICore.collectSales, ());
        else if (k == 4) data = abi.encodeCall(ICore.buyback, ());
        else if (k == 5) data = abi.encodeCall(ICore.exitStatement, (sid));
        else if (k == 6) data = abi.encodeCall(ICore.repriceStatement, (sid));
        else {
            target = address(selling);
            data = abi.encodeCall(SellingController.sell, (sid, address(next)));
        }
        next.setCall(target, data);
    }

    /// the owner replaces the controller and, in phase 2, the exit module in one go. the controller is any of the three
    /// the run knows, the module a new one with the same exit token, a new unit, and now and then a gas burning body and a
    /// call into the core from inside the exit. both take effect at once unless the owner locked the door. the call must
    /// not move an asset, a pot or the house debt, and no call from inside an exit may ever go through
    function hostileOwner(uint256 seed, uint256 mode) external checked {
        uint8 a = A_HOSTILE_OWNER;
        address c = seed % 3 == 0 ? v1 : (seed % 3 == 1 && canSwapController ? address(fuzz) : address(selling));
        bool swapMod = phase2() && mode % 2 == 0;
        MockExitModule next;
        if (swapMod) {
            next = new MockExitModule(core.exitToken(), _logBound(seed >> 8, 2e9, 5e10));
            uint256 burn = (mode >> 4) % 4;
            if (burn == 1) next.setBurn(300_000);
            else if (burn == 2) next.setBurn(2_000_000);
            _callout((mode >> 8) % 9, seed >> 16, next);
        }
        bool lockedC = core.controllerLocked();
        bool lockedE = core.exitModuleLocked();
        address oldC = core.controller();
        address oldM = core.exitModule();
        OPre memory pre = _opre();
        _att(a);
        vm.startPrank(owner);
        (bool okC,) = address(core).call(abi.encodeCall(ICore.setController, (c)));
        bool okM = true;
        if (swapMod) (okM,) = address(core).call(abi.encodeCall(ICore.setExitModule, (address(next))));
        vm.stopPrank();
        if (okC == lockedC) _flag(V_LOCK, "the controller door and its lock disagree");
        if (core.controller() != (okC ? c : oldC)) _flag(V_OWNER, "the controller is not what the owner set at once");
        if (swapMod) {
            if (okM == lockedE) _flag(V_LOCK, "the exit module door and its lock disagree");
            if (core.exitModule() != (okM ? address(next) : oldM)) _flag(V_OWNER, "the exit module is not what the owner set");
            if (okM) {
                module = next;
                modulesEver.push(next);
                if (core.unitPerPoint() != next.currentUnit()) _flag(V_OWNER, "the unit was not read from the new module");
            }
        }
        _opost(pre, "hostileOwner");
        _ok(a);
    }

    /*//////////////////////////////////////////////////////////////
                                 LOCKS
    //////////////////////////////////////////////////////////////*/

    /// the owner closes a door for good, or a stranger tries. rare: the lock stays for the rest of the run. afterwards the
    /// setter of that door reverts with Locked, and the other doors stay open
    function lockDoor(uint256 seed, uint256 mode) external checked {
        uint8 a = A_LOCK;
        if (seed % 5 != 0) return _skip(a);
        uint256 which = mode % 3;
        address stranger = address(uint160(uint256(keccak256(abi.encode("locker", seed)))));
        OPre memory pre = _opre();
        _att(a);
        bytes memory data = abi.encodeWithSelector(
            which == 0 ? ICore.lockController.selector : (which == 1 ? ICore.lockExitModule.selector : ICore.lockTargets.selector)
        );
        vm.prank(stranger);
        (bool ok, bytes memory out) = address(core).call(data);
        if (ok || bytes4(out) != ICore.OnlyOwner.selector) _flag(V_LOCK, "a stranger locked a door");
        bool noModule = which == 1 && core.exitModule() == address(0);
        vm.prank(owner);
        (ok, out) = address(core).call(data);
        if (noModule) {
            if (ok || bytes4(out) != ICore.NoExitModule.selector) _flag(V_LOCK, "the module lock worked with no module");
        } else {
            if (!ok) _flag(V_LOCK, "the owner could not lock a door");
            bool nowLocked = which == 0 ? core.controllerLocked() : (which == 1 ? core.exitModuleLocked() : core.targetsLocked());
            if (!nowLocked) _flag(V_LOCK, "a lock did not set its flag");
            if (which == 0) gLockedC = true;
            else if (which == 1) gLockedE = true;
            else gLockedT = true;
            _setterShut(which);
        }
        _opost(pre, "lockDoor");
        _ok(a);
    }

    /// the setter of a locked door reverts with Locked, whatever it is asked
    function _setterShut(uint256 which) internal {
        bytes memory data = which == 0
            ? abi.encodeCall(ICore.setController, (v1))
            : (which == 1
                    ? abi.encodeCall(ICore.setExitModule, (core.exitModule()))
                    : abi.encodeCall(ICore.addTarget, (address(0xA110C))));
        vm.prank(owner);
        (bool ok, bytes memory out) = address(core).call(data);
        if (ok || bytes4(out) != ICore.Locked.selector) _flag(V_LOCK, "a locked door's setter did not revert Locked");
    }

    /// the flags the handler has seen set must still be set, and the setters must still refuse
    function lockCheck() external {
        if (gLockedC) {
            if (!core.controllerLocked()) _flag(V_LOCK, "the controller lock came undone");
            _setterShut(0);
        }
        if (gLockedE) {
            if (!core.exitModuleLocked()) _flag(V_LOCK, "the exit module lock came undone");
            _setterShut(1);
        }
        if (gLockedT) {
            if (!core.targetsLocked()) _flag(V_LOCK, "the targets lock came undone");
            _setterShut(2);
        }
        if (gLockedS) {
            if (!core.successorLocked()) _flag(V_LOCK, "the successor lock came undone");
            if (core.successor() != gSuccessorAtLock) _flag(V_LOCK, "the locked successor changed");
            _successorShut();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HANDOVER
    //////////////////////////////////////////////////////////////*/

    /// the owner hands over to the next heir in one of three ways: transfer and accept, transfer then clear (the heir can no
    /// longer accept) then transfer and accept, or name one heir then another (only the second can accept). the old owner
    /// keeps every power until the accept and has none after, the heir has none before and every one after, the controller's
    /// sale settings follow the live owner. no asset moves
    function handover(uint256 seed, uint256 mode) external checked {
        uint8 a = A_HANDOVER;
        if (heirNext + 1 >= heirs.length || seed % 6 != 0) return _skip(a);
        address old = owner;
        address heir = heirs[heirNext];
        address other = heirs[heirNext + 1];
        uint256 m = mode % 3;
        OPre memory pre = _opre();
        _att(a);
        address target = address(0xD1CE);
        vm.prank(old);
        (bool ok0,) = address(core).call(abi.encodeCall(ICore.transferOwnership, (m == 2 ? other : heir)));
        if (!ok0) _flag(V_LOCK, "the owner could not start a handover");
        if (core.owner() != old || core.pendingOwner() != (m == 2 ? other : heir)) _flag(V_LOCK, "the first step moved the owner");
        // the old owner still holds every power, the pending owner none
        vm.prank(old);
        (bool ok,) = address(core).call(abi.encodeCall(ICore.removeTarget, (target)));
        if (!ok) _flag(V_LOCK, "the owner lost a power before the handover was accepted");
        vm.prank(m == 2 ? other : heir);
        (ok,) = address(core).call(abi.encodeCall(ICore.removeTarget, (target)));
        if (ok) _flag(V_LOCK, "a pending owner had a power before accepting");
        address next = heir;
        if (m == 1) {
            vm.prank(old);
            (ok,) = address(core).call(abi.encodeCall(ICore.transferOwnership, (address(0))));
            vm.prank(heir);
            (ok,) = address(core).call(abi.encodeCall(ICore.acceptOwnership, ()));
            if (ok) _flag(V_LOCK, "a cleared handover was accepted");
            vm.prank(old);
            (ok,) = address(core).call(abi.encodeCall(ICore.transferOwnership, (heir)));
        } else if (m == 2) {
            vm.prank(old);
            (ok,) = address(core).call(abi.encodeCall(ICore.transferOwnership, (heir)));
            vm.prank(other);
            (ok,) = address(core).call(abi.encodeCall(ICore.acceptOwnership, ()));
            if (ok) _flag(V_LOCK, "a replaced pending owner accepted");
            next = heir;
        }
        vm.prank(address(uint160(uint256(keccak256(abi.encode("accepter", seed))))));
        (ok,) = address(core).call(abi.encodeCall(ICore.acceptOwnership, ()));
        if (ok) _flag(V_LOCK, "a stranger accepted a handover");
        vm.prank(next);
        (ok,) = address(core).call(abi.encodeCall(ICore.acceptOwnership, ()));
        if (!ok) _flag(V_LOCK, "the pending owner could not accept");
        if (core.owner() != next || core.pendingOwner() != address(0)) _flag(V_LOCK, "the accept did not complete the handover");
        formerOwners.push(old);
        owner = next;
        heirNext += 1;
        // the old owner has no power: the core and the controller's settings
        vm.prank(old);
        (ok,) = address(core).call(abi.encodeCall(ICore.removeTarget, (target)));
        if (ok) _flag(V_LOCK, "the old owner kept a power after the handover");
        // the argument is read before the prank: a call in the argument list would use it up
        bool mode0 = IControllerV1(v1).buyOnly();
        vm.prank(old);
        (ok,) = address(v1).call(abi.encodeCall(IControllerV1.setBuyOnly, (!mode0)));
        if (ok) _flag(V_LOCK, "the old owner kept the sale settings");
        vm.prank(next);
        (ok,) = address(v1).call(abi.encodeCall(IControllerV1.setBuyOnly, (mode0)));
        if (!ok) _flag(V_LOCK, "the new owner has no say over the sale settings");
        _opost(pre, "handover");
        _ok(a);
    }

    /// every former owner has no power, for the core and for the controller's settings
    function formerOwnersCheck() external {
        for (uint256 i; i < formerOwners.length; ++i) {
            vm.prank(formerOwners[i]);
            (bool ok,) = address(core).call(abi.encodeCall(ICore.lockTargets, ()));
            if (ok) _flag(V_LOCK, "a former owner locked a door");
            vm.prank(formerOwners[i]);
            (ok,) = address(core).call(abi.encodeCall(ICore.transferOwnership, (formerOwners[i])));
            if (ok) _flag(V_LOCK, "a former owner started a handover");
            vm.prank(formerOwners[i]);
            (ok,) = address(v1).call(abi.encodeCall(IControllerV1.setStepBps, (1)));
            if (ok) _flag(V_LOCK, "a former owner set a sale setting");
        }
        if (core.owner() != owner) _flag(V_LOCK, "the core owner is not the handler's owner");
    }
}
