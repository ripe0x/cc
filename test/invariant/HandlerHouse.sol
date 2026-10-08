// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Lane, Settings} from "../../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../../src/interfaces/AuctionHouse.sol";
import {HandlerBase} from "./HandlerBase.sol";

/// @notice the statement sale actions on the real pnd auction house the core owns: bids from random bidders around
/// the reserve and the five percent rule, settling an ended auction, collecting the proceeds, and the two lazy
/// permissionless calls of the core, `syncStatement` and `repriceStatement`. the ghost keeps, per statement, where
/// it is (listed, held, sold, exited, overprinted), the reserve the core set at the listing or the latest reprice,
/// the top bid, the winner and the winning bid, and the sum of the winning bids against the sum collected.
abstract contract HandlerHouse is HandlerBase {
    /// the gas `endAuction` needs to honor the house's delivery stipend, as the fixture gives it
    uint256 internal constant END_GAS = 2_000_000;

    /// which ever composed statements a picker may return
    uint256 internal constant K_LISTED = 0; // listed on the house, bid or not
    uint256 internal constant K_BIDDED = 1; // listed with a bid
    uint256 internal constant K_SOLD_UNSYNCED = 2; // sold, the core's record not cleared yet
    uint256 internal constant K_ANY = 3;

    function _pickBy(uint256 seed, uint256 kind) internal view returns (uint256 sid, bool found) {
        uint256 n = everHeld.length;
        for (uint256 k; k < n; ++k) {
            sid = everHeld[(seed % n + k) % n];
            SG storage g = _sg[sid];
            if (kind == K_ANY) return (sid, true);
            if (kind == K_LISTED && g.status == S_LISTED) return (sid, true);
            if (kind == K_BIDDED && g.status == S_LISTED && g.bid != 0) return (sid, true);
            if (kind == K_SOLD_UNSYNCED && g.status == S_SOLD && !g.synced) return (sid, true);
        }
        return (0, false);
    }

    /// the least the house accepts as the next bid on this auction, from its own rules: the reserve for the first bid,
    /// five percent above the top bid after
    function _minBid(IAuctionHouse.Auction memory au) internal pure returns (uint256) {
        if (au.firstBidTime == 0) return au.reservePrice;
        uint256 inc = au.amount * 500 / 10_000;
        return au.amount + (inc == 0 ? 1 : inc);
    }

    /*//////////////////////////////////////////////////////////////
                                  BID
    //////////////////////////////////////////////////////////////*/

    struct BidPre {
        uint256 bal;
        uint256 pot;
        uint256 rate;
        uint256 minBid;
        uint256 amount;
        uint256 whoBal;
        uint256 prevBal;
        address prev;
        bool first;
        bool ended;
    }

    /// a random bidder bids on a listed statement, directly on the house. the amount is around the least the house
    /// accepts: one below, exactly it, a little or a lot above. a bid below the least, or after the end, must revert
    function bid(uint256 sIdx, uint256 aSeed, uint256 amtSeed, uint256 mode) external checked {
        uint8 a = A_BID;
        (uint256 sid, bool found) = _pickBy(sIdx, K_LISTED);
        if (!found) return _skip(a);
        SG storage g = _sg[sid];
        IAuctionHouse.Auction memory au = house.getAuction(g.auctionId);
        if (au.reservePrice != g.reserve) _flag(V_SALE_FLOOR, "the house reserve differs from the one the core set");
        BidPre memory p;
        p.first = au.firstBidTime == 0;
        p.ended = !p.first && block.timestamp >= au.endTime;
        // a finished auction is only tried now and then, to see the refusal
        if (p.ended && mode % 5 != 0) return _skip(a);
        p.minBid = _minBid(au);
        uint256 m = mode % 8;
        if (m == 0) p.amount = p.minBid - 1;
        else if (m <= 3) p.amount = p.minBid;
        else if (m == 4) p.amount = p.minBid + _logBound(amtSeed, 1, p.minBid / 10 + 2);
        else if (m == 5) p.amount = 2 * p.minBid;
        else if (m == 6) p.amount = p.minBid + 1;
        else p.amount = _logBound(amtSeed, 1, 3 * p.minBid + 2);
        if (p.amount == 0) p.amount = 1;
        address who = _actor(aSeed);
        p.prev = au.bidder;
        vm.deal(who, who.balance + p.amount);
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.rate = core.ethRate();
        p.whoBal = who.balance;
        p.prevBal = p.prev.balance;
        RS memory rs = _rs();
        _att(a);
        vm.prank(who);
        try house.createBid{value: p.amount}(g.auctionId) {
            _ok(a);
            _afterBid(sid, who, au, p);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "bid");
            bool should = !p.ended && p.amount >= p.minBid;
            if (should) {
                _unexpected(a, why);
            } else {
                bytes4 want = p.ended
                    ? IAuctionHouse.AuctionExpired.selector
                    : (p.amount < au.reservePrice
                            ? IAuctionHouse.BidBelowReserve.selector
                            : IAuctionHouse.BidBelowMinimum.selector);
                if (bytes4(why) != want) _unexpected(a, why);
            }
        }
        _rsCheck(rs, 0);
    }

    function _afterBid(uint256 sid, address who, IAuctionHouse.Auction memory before, BidPre memory p) internal {
        SG storage g = _sg[sid];
        if (p.ended || p.amount < p.minBid) {
            _flag(V_SALE_FLOOR, "a bid below the least, or after the end, was accepted");
        }
        if (p.first && p.amount < g.reserve) {
            _flag(V_SALE_FLOOR, "a first bid below the reserve the core set was accepted");
        }
        IAuctionHouse.Auction memory au = house.getAuction(g.auctionId);
        if (au.amount != p.amount || au.bidder != who) _flag(V_MODEL, "the house did not record the bid");
        uint256 end = p.first ? block.timestamp + before.duration : before.endTime;
        if (end - block.timestamp < 15 minutes) end = block.timestamp + 15 minutes;
        if (au.endTime != end) _flag(V_MODEL, "the end of the auction is not the house rule");
        // the outbid bidder is refunded in the same call, the new one pays the bid. nothing touches the core
        uint256 paid = p.whoBal - who.balance;
        uint256 refund = (p.first || p.prev == address(0)) ? 0 : before.amount;
        if (p.prev == who) {
            if (paid + refund != p.amount) _flag(V_REFUND, "a rebid by the top bidder did not net bid less refund");
        } else {
            if (paid != p.amount) _flag(V_REFUND, "the bidder paid something other than the bid");
            if (p.prev != address(0) && p.prev.balance - p.prevBal != refund) {
                _flag(V_REFUND, "the outbid bidder was not refunded the previous bid");
            }
        }
        _eth(p.bal, 0, 0, "bid");
        if (core.ethPot() != p.pot) _flag(V_POT, "a bid on the house changed the pot");
        g.bid = p.amount;
        g.bidder = who;
    }

    /*//////////////////////////////////////////////////////////////
                               END AUCTION
    //////////////////////////////////////////////////////////////*/

    struct EndPre {
        uint256 bal;
        uint256 pot;
        uint256 toBuyback;
        uint256 rate;
        uint256 owed;
        bool early;
    }

    /// a stranger settles an auction that has a bid. an odd mode tries it before the end and the house must refuse.
    /// an even mode moves time to the end first. the statement goes to the winner, the proceeds are credited to the
    /// core on the house and not to the core's balance
    function endAuction(uint256 sIdx, uint256 mode) external checked {
        uint8 a = A_END_AUCTION;
        (uint256 sid, bool found) = _pickBy(sIdx, K_BIDDED);
        if (!found) return _skip(a);
        SG storage g = _sg[sid];
        IAuctionHouse.Auction memory au = house.getAuction(g.auctionId);
        EndPre memory p;
        p.early = block.timestamp < au.endTime;
        if (p.early && mode % 2 == 0) {
            _advance(au.endTime - block.timestamp, 0);
            p.early = false;
        }
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.toBuyback = core.ethToBuyback();
        p.rate = core.ethRate();
        p.owed = house.pendingRefunds(address(core));
        RS memory rs = _rs();
        _att(a);
        vm.prank(address(0xE4D));
        try house.endAuction{gas: END_GAS}(g.auctionId) {
            _ok(a);
            _afterEnd(sid, au, p);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "endAuction");
            if (!p.early) _unexpected(a, why);
            else if (bytes4(why) != IAuctionHouse.AuctionNotEnded.selector) _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    function _afterEnd(uint256 sid, IAuctionHouse.Auction memory au, EndPre memory p) internal {
        SG storage g = _sg[sid];
        if (p.early) _flag(V_SALE_FLOOR, "an auction was settled before its end");
        // invariant 3: the statement left the core's control by an auction whose winning bid was at or above the
        // reserve the core set for it
        if (au.amount < g.reserve) _flag(V_SALE_FLOOR, "a statement sold below the reserve the core set");
        if (au.amount < g.floorAtSet) _flag(V_SALE_FLOOR, "a statement sold below the hard floor");
        if (au.amount != g.bid || au.bidder != g.bidder) _flag(V_MODEL, "the winning bid differs from the ghost");
        if (_ownerOf(sid) != au.bidder) _flag(V_DEPART, "the winner does not hold the statement");
        if (house.getAuction(g.auctionId).tokenOwner != address(0)) _flag(V_MODEL, "the house kept a settled auction");
        // the proceeds are the house's to pay until collected: the core's eth and pots do not move
        _eth(p.bal, 0, 0, "endAuction");
        if (core.ethPot() != p.pot || core.ethToBuyback() != p.toBuyback) _flag(V_POT, "a settlement moved the pots");
        gWon += au.amount;
        if (house.pendingRefunds(address(core)) != p.owed + au.amount) {
            _flag(V_HOUSE, "the house did not credit the core exactly the winning bid");
        }
        (, uint256 aid,,,) = core.statementStatus(sid);
        if (aid != g.auctionId) _flag(V_MODEL, "the core's record of the auction changed at settlement");
        g.status = S_SOLD;
        g.price = au.amount;
        g.winner = au.bidder;
        g.synced = false;
    }

    /*//////////////////////////////////////////////////////////////
                              COLLECT SALES
    //////////////////////////////////////////////////////////////*/

    /// anyone pulls the proceeds from the house. the core books them, split by the settings in force now: saleToBuybackBps
    /// to the buyback, the rest to the pot. with nothing owed the call is a no op. afterwards the house owes nothing
    function collectSales(uint256 aSeed) external checked {
        uint8 a = A_COLLECT_SALES;
        address who = _actor(aSeed);
        Settings memory st = core.settings();
        uint256 owed = house.pendingRefunds(address(core));
        uint256 toBuyback = owed * st.saleToBuybackBps / 10_000;
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 tb0 = core.ethToBuyback();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(who);
        try core.collectSales() {
            _ok(a);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 events;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter == address(core) && logs[i].topics[0] == ICore.SalesCollected.selector) {
                    (uint256 amt, uint256 tbb) = abi.decode(logs[i].data, (uint256, uint256));
                    if (amt != owed || tbb != toBuyback) {
                        _flag(V_HOUSE, "SalesCollected differs from the owed and the split");
                    }
                    events++;
                }
            }
            if (events != (owed == 0 ? 0 : 1)) {
                _flag(V_HOUSE, "collectSales emitted the wrong number of SalesCollected");
            }
            _eth(b0, 0, owed, "collectSales");
            if (core.ethToBuyback() != tb0 + toBuyback) {
                _flag(V_POT, "collected buyback share is not saleToBuybackBps");
            }
            if (core.ethPot() != pot0 + owed - toBuyback) _flag(V_POT, "collected pot share is not the rest");
            if (house.pendingRefunds(address(core)) != 0) _flag(V_HOUSE, "the house owes the core after collectSales");
            gCollected += owed;
        } catch (bytes memory why) {
            _failed(b0, pot0, rate0, "collectSales");
            _unexpected(a, why);
        }
        _rsCheck(rs, 0);
    }

    /*//////////////////////////////////////////////////////////////
                         SYNC AND REPRICE
    //////////////////////////////////////////////////////////////*/

    /// settles the core's record of a statement against the house. a sold statement clears. a listed one reverts with
    /// AuctionLive, a held exit lane statement and every statement the core no longer records with NotListed
    function syncStatement(uint256 sIdx, uint256 mode) external checked {
        uint8 a = A_SYNC_STATEMENT;
        (uint256 sid, bool found) = _pickBy(sIdx, mode % 3 == 0 ? K_ANY : K_SOLD_UNSYNCED);
        if (!found) (sid, found) = _pickBy(sIdx, K_ANY);
        if (!found) return _skip(a);
        SG storage g = _sg[sid];
        bool should = g.status == S_SOLD && !g.synced;
        bytes4 want = g.status == S_LISTED ? ICore.AuctionLive.selector : ICore.NotListed.selector;
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        vm.recordLogs();
        _att(a);
        vm.prank(_actor(mode));
        try core.syncStatement(sid) {
            _ok(a);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (!should) _flag(V_MODEL, "syncStatement settled a statement the ghost model does not consider sold");
            _afterSync(sid, logs);
            _eth(b0, 0, 0, "syncStatement");
        } catch (bytes memory why) {
            _failed(b0, pot0, rate0, "syncStatement");
            if ((should || bytes4(why) != want) && !(bytes4(why) == ICore.BadPrice.selector && _mayNotPrice())) {
                _unexpected(a, why);
            }
        }
        _rsCheck(rs, 0);
    }

    function _afterSync(uint256 sid, Vm.Log[] memory logs) internal {
        SG storage g = _sg[sid];
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != ICore.StatementSold.selector) continue;
            seen++;
            if (uint256(logs[i].topics[1]) != sid || uint256(logs[i].topics[2]) != g.auctionId) {
                _flag(V_MODEL, "StatementSold names another statement or auction");
            }
            if (address(uint160(uint256(logs[i].topics[3]))) != g.winner) {
                _flag(V_MODEL, "StatementSold names another holder");
            }
        }
        if (seen != 1) _flag(V_MODEL, "syncStatement emitted the wrong number of StatementSold");
        (bool held,,,) = core.statementInfo(sid);
        if (held) _flag(V_MODEL, "a synced statement is still recorded as held");
        if (_ownerOf(sid) != g.winner) _flag(V_DEPART, "a synced statement is not with its winner");
        g.synced = true;
    }

    /// moves the reserve of a listing that has no bid to the controller's price now, floored at the hard floor. a bid makes it
    /// revert with HasBid, anything the core does not list with NotListed
    function repriceStatement(uint256 sIdx, uint256 mode) external checked {
        uint8 a = A_REPRICE;
        (uint256 sid, bool found) = _pickBy(sIdx, mode % 4 == 0 ? K_ANY : K_LISTED);
        if (!found) return _skip(a);
        SG storage g = _sg[sid];
        Settings memory st = core.settings();
        bool should = g.status == S_LISTED && g.bid == 0;
        bytes4 want = g.status == S_LISTED ? ICore.HasBid.selector : ICore.NotListed.selector;
        uint256 b0 = address(core).balance;
        uint256 pot0 = core.ethPot();
        uint256 rate0 = core.ethRate();
        RS memory rs = _rs();
        _att(a);
        vm.prank(_actor(mode));
        try core.repriceStatement(sid) {
            _ok(a);
            if (!should) _flag(V_SALE_FLOOR, "a listing with a bid, or none, was repriced");
            (bool priced, uint256 wantRes) = _wantReserve(sid, g.cost, g.listedAt, st.saleFloorBps);
            IAuctionHouse.Auction memory au = house.getAuction(g.auctionId);
            g.reserve = au.reservePrice;
            g.floorAtSet = g.cost * st.saleFloorBps / 10_000;
            if (g.reserve < g.floorAtSet) _flag(V_SALE_FLOOR, "a repriced reserve below the hard floor");
            if (!priced || au.reservePrice != wantRes) {
                _flag(V_SALE_FLOOR, "the repriced reserve is not the controller price, floored");
            }
            _eth(b0, 0, 0, "repriceStatement");
        } catch (bytes memory why) {
            _failed(b0, pot0, rate0, "repriceStatement");
            if ((should || bytes4(why) != want) && !(bytes4(why) == ICore.BadPrice.selector && _mayNotPrice())) {
                _unexpected(a, why);
            }
        }
        _rsCheck(rs, 0);
    }
}
