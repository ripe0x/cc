// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {Core} from "../../src/Core.sol";
import {Settings, RATE_START_MIN_WEI, RATE_START_MAX_WEI} from "../../src/interfaces/Interfaces.sol";
import {HandlerHouse} from "./HandlerHouse.sol";

/// @notice the owner as an adversarial actor. the owner calls `setSettings` with random valid settings across the
/// whole allowed bounds, extreme corners included, `setRate` and `setXRate` anywhere in their bounds, and invalid
/// settings, rates and callers that must revert. the bounds are written out again here, independently of the
/// library under test. after every owner call the settings are what was set, the rate is what it should be, and the
/// core's eth, pots and exit token did not move: the owner has no path to the assets.
abstract contract HandlerOwner is HandlerHouse {
    /// owner calls that went through, and the ones the model expected to revert and did
    uint256 public gOwnerCalls;
    uint256 public gOwnerRefused;
    /// settings changes while a spend window was open that moved its cap
    uint256 public gCapChanges;

    /*//////////////////////////////////////////////////////////////
                              GENERATOR
    //////////////////////////////////////////////////////////////*/

    /// a value in [lo, hi]: one of the two edges, the current value, uniform, or log uniform from the low edge
    function _f(uint256 seed, uint256 lo, uint256 hi, uint256 cur) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        uint256 k = seed % 6;
        if (k == 0) return lo;
        if (k == 1) return hi;
        if (k == 2) return cur < lo ? lo : (cur > hi ? hi : cur);
        if (k == 3) return lo + (seed >> 8) % (hi - lo + 1);
        return lo + _logBound(seed >> 8, 1, hi - lo + 1) - 1;
    }

    function _r(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// random valid settings over the whole bounds, from `seed`. `corner` picks an extreme to force on top
    function _genSettings(uint256 seed, uint256 corner, Settings memory c) internal pure returns (Settings memory s) {
        // forge-lint: disable-start(unsafe-typecast)
        s.flatBps = uint16(_f(_r(seed, 0), 0, 10_000, c.flatBps));
        s.avgScore = uint32(_f(_r(seed, 1), 800_000, 8_000_000, c.avgScore));
        s.climbBaseBps = uint16(_f(_r(seed, 2), 0, 1_000, c.climbBaseBps));
        s.climbDoubleEvery = uint32(_f(_r(seed, 3), 1 hours, 30 days, c.climbDoubleEvery));
        s.climbMaxBps = uint16(_f(_r(seed, 4), s.climbBaseBps, 2_000, c.climbMaxBps));
        s.dropBps = uint16(_f(_r(seed, 5), 0, 5_000, c.dropBps));
        s.spendCapBps = uint16(_f(_r(seed, 6), 100, 10_000, c.spendCapBps));
        s.bonusCapBps = uint16(_f(_r(seed, 7), 0, 5_000, c.bonusCapBps));
        s.tipSavingsBps = uint16(_f(_r(seed, 8), 0, 2_500, c.tipSavingsBps));
        s.tipCapBps = uint16(_f(_r(seed, 9), 0, 500, c.tipCapBps));
        s.reimburseBps = uint16(_f(_r(seed, 10), 0, 15_000, c.reimburseBps));
        s.reimburseCapBps = uint16(_f(_r(seed, 11), 0, 1_000, c.reimburseCapBps));
        s.reserveBps = uint16(_f(_r(seed, 12), 1_000, 40_000, c.reserveBps));
        s.auctionDuration = uint32(_f(_r(seed, 13), 1 hours, 30 days, c.auctionDuration));
        s.exitAfter = uint32(_f(_r(seed, 14), 0, 365 days, c.exitAfter));
        s.saleToBuybackBps = uint16(_f(_r(seed, 15), 0, 10_000, c.saleToBuybackBps));
        s.exitToBuybackBps = uint16(_f(_r(seed, 16), 0, 10_000, c.exitToBuybackBps));
        s.buybackSlice = uint128(_f(_r(seed, 17), 0.01 ether, 100 ether, c.buybackSlice));
        s.buybackDelay = uint16(_f(_r(seed, 18), 1, 7_200, c.buybackDelay));
        s.keeperTipBps = uint16(_f(_r(seed, 19), 0, 500, c.keeperTipBps));
        s.xRateCap = uint16(_f(_r(seed, 20), 0, 10_000, c.xRateCap));
        s.xRateFloor = uint16(_f(_r(seed, 21), 0, s.xRateCap, c.xRateFloor));
        s.xRateClimbPerHour = uint16(_f(_r(seed, 22), 0, 1_000, c.xRateClimbPerHour));
        s.xRateDropPerCredit = uint16(_f(_r(seed, 23), 0, 1_000, c.xRateDropPerCredit));
        s.xAuctionHalfLife = uint32(_f(_r(seed, 24), 10 minutes, 30 days, c.xAuctionHalfLife));
        s.exitSliceCredits = uint16(_f(_r(seed, 25), 1, 1_000, c.exitSliceCredits));
        _corner(s, corner);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// the extreme corners the brief names, forced on top of the random settings
    function _corner(Settings memory s, uint256 k) internal pure {
        // forge-lint: disable-start(unsafe-typecast)
        k = k % 18;
        if (k == 1) {
            s.flatBps = 0;
        } else if (k == 2) {
            s.flatBps = 10_000;
        } else if (k == 3) {
            s.spendCapBps = 10_000;
        } else if (k == 4) {
            s.reserveBps = 1_000;
        } else if (k == 5) {
            s.reserveBps = 40_000;
        } else if (k == 6) {
            s.saleToBuybackBps = 0;
        } else if (k == 7) {
            s.saleToBuybackBps = 10_000;
        } else if (k == 8) {
            s.climbBaseBps = 0;
        } else if (k == 9) {
            s.dropBps = 5_000;
        } else if (k == 10) {
            s.buybackSlice = 0.01 ether;
        } else if (k == 11) {
            s.buybackSlice = 100 ether;
        } else if (k == 12) {
            s.exitAfter = 0;
        } else if (k == 13) {
            s.spendCapBps = 100;
        } else if (k == 14) {
            // every tip, reimbursement and keeper reward at zero
            s.tipSavingsBps = 0;
            s.tipCapBps = 0;
            s.reimburseBps = 0;
            s.reimburseCapBps = 0;
            s.keeperTipBps = 0;
            s.bonusCapBps = 0;
        } else if (k == 15) {
            // every tip, reimbursement and keeper reward at its ceiling
            s.tipSavingsBps = 2_500;
            s.tipCapBps = 500;
            s.reimburseBps = 15_000;
            s.reimburseCapBps = 1_000;
            s.keeperTipBps = 500;
            s.bonusCapBps = 5_000;
        } else if (k == 16) {
            // the shortest clocks and the most aggressive climb
            s.climbBaseBps = 1_000;
            s.climbMaxBps = 2_000;
            s.climbDoubleEvery = 1 hours;
            s.auctionDuration = 1 hours;
            s.xAuctionHalfLife = 10 minutes;
        }
        // forge-lint: disable-end(unsafe-typecast)
    }

    /*//////////////////////////////////////////////////////////////
                              SET SETTINGS
    //////////////////////////////////////////////////////////////*/

    struct OPre {
        uint256 bal;
        uint256 pot;
        uint256 toBuyback;
        uint256 rate;
        uint256 xRate;
        uint256 xPrice;
        uint256 xPot;
        uint256 xToBuyback;
        uint256 xBal;
        uint256 owed;
    }

    function _opre() internal view returns (OPre memory p) {
        p.bal = address(core).balance;
        p.pot = core.ethPot();
        p.toBuyback = core.ethToBuyback();
        p.rate = core.ethRate();
        p.xRate = core.xRate();
        p.xPrice = core.exitAuctionPrice();
        p.xPot = core.xPot();
        p.xToBuyback = core.xToBuyback();
        p.xBal = _xBal(address(core));
        p.owed = house.pendingRefunds(address(core));
    }

    /// what no owner call may touch: the core's eth, its pots, its exit token and what the house owes it
    function _opost(OPre memory p, string memory what) internal {
        _eth(p.bal, 0, 0, what);
        _x(p.xBal, 0, 0, what);
        if (core.ethPot() != p.pot || core.ethToBuyback() != p.toBuyback) _flag(V_OWNER, "an owner call moved a pot");
        if (core.xPot() != p.xPot || core.xToBuyback() != p.xToBuyback) {
            _flag(V_OWNER, "an owner call moved an exit pot");
        }
        if (house.pendingRefunds(address(core)) != p.owed) _flag(V_OWNER, "an owner call moved what the house owes");
        gOwnerCalls++;
    }

    /// the owner changes the settings to random valid ones, effective at once. nothing may revert. afterwards the
    /// settings are what was set, the stored eth rate is exactly what it was (the call checkpoints it, it never jumps),
    /// the exit rate is only held inside the new band, the exit auction price is continuous, and the pots, balances
    /// and the house's debt did not move
    function setSettings(uint256 seed, uint256 corner) external checked {
        uint8 a = A_SET_SETTINGS;
        Settings memory cur = core.settings();
        Settings memory ns = _genSettings(seed, corner, cur);
        if (_firstViolation(ns) != 0) {
            _flag(V_SETTINGS, "the handler generated invalid settings");
            return _skip(a);
        }
        OPre memory p = _opre();
        _att(a);
        vm.prank(owner);
        try core.setSettings(ns) {
            _ok(a);
            gSettingsHash = keccak256(abi.encode(ns));
            if (keccak256(abi.encode(core.settings())) != gSettingsHash) {
                _flag(V_SETTINGS, "the settings read back differ from the ones set");
            }
            _afterSettings(ns, cur, p);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "setSettings");
            _unexpected(a, why);
        }
    }

    function _afterSettings(Settings memory ns, Settings memory cur, OPre memory p) internal {
        _opost(p, "setSettings");
        // invariant 6 across a settings call: the stored rate does not jump, the call only checkpoints it
        if (core.ethRate() != p.rate) _flag(V_RATE_BOUND, "a settings call moved the eth rate");
        if (core.rateAtCheckpoint() != p.rate) _flag(V_RATE_BOUND, "a settings call moved the stored eth rate");
        _fundedCheck();
        // the exit rate is held inside the new band and nothing else
        uint256 want = p.xRate > ns.xRateCap ? ns.xRateCap : p.xRate;
        if (want < ns.xRateFloor) want = ns.xRateFloor;
        if (core.xRate() != want) _flag(V_SETTINGS, "the exit rate is not held inside the new band");
        // the exit auction keeps its price whatever happens to the half life. a price that decayed to zero is
        // re anchored at one when the half life changes (the core keeps the start price at one at least)
        uint256 price = core.exitAuctionPrice();
        if (price != p.xPrice && !(p.xPrice == 0 && price == 1)) {
            _flag(V_AUCTION, "a settings call moved the exit auction price");
        }
        // a change of the spend cap while a window is open is applied to the window's pot from the next spend on
        if (block.timestamp < gWinStart + 1 hours && ns.spendCapBps != gWinCap) {
            if (ns.spendCapBps != cur.spendCapBps) gCapChanges++;
            gWinCapChanged = true;
            if (gWinSpent * 10_000 > gWinPot * ns.spendCapBps) gOverNowCap++;
        }
    }

    /// the bounds of docs/FLOW.md section 2, written out again. the name of the first field out of bounds, or zero
    function _firstViolation(Settings memory s) internal pure returns (bytes32) {
        if (s.flatBps > 10_000) return "flatBps";
        if (s.avgScore < 800_000 || s.avgScore > 8_000_000) return "avgScore";
        if (s.climbBaseBps > 1_000) return "climbBaseBps";
        if (s.climbDoubleEvery < 1 hours || s.climbDoubleEvery > 30 days) return "climbDoubleEvery";
        if (s.climbMaxBps < s.climbBaseBps || s.climbMaxBps > 2_000) return "climbMaxBps";
        if (s.dropBps > 5_000) return "dropBps";
        if (s.spendCapBps < 100 || s.spendCapBps > 10_000) return "spendCapBps";
        if (s.bonusCapBps > 5_000) return "bonusCapBps";
        if (s.tipSavingsBps > 2_500) return "tipSavingsBps";
        if (s.tipCapBps > 500) return "tipCapBps";
        if (s.reimburseBps > 15_000) return "reimburseBps";
        if (s.reimburseCapBps > 1_000) return "reimburseCapBps";
        if (s.reserveBps < 1_000 || s.reserveBps > 40_000) return "reserveBps";
        if (s.auctionDuration < 1 hours || s.auctionDuration > 30 days) return "auctionDuration";
        if (s.exitAfter > 365 days) return "exitAfter";
        if (s.saleToBuybackBps > 10_000) return "saleToBuybackBps";
        if (s.exitToBuybackBps > 10_000) return "exitToBuybackBps";
        if (s.buybackSlice < 0.01 ether || s.buybackSlice > 100 ether) return "buybackSlice";
        if (s.buybackDelay < 1 || s.buybackDelay > 7_200) return "buybackDelay";
        if (s.keeperTipBps > 500) return "keeperTipBps";
        if (s.xRateCap > 10_000) return "xRateCap";
        if (s.xRateFloor > s.xRateCap) return "xRateFloor";
        if (s.xRateClimbPerHour > 1_000) return "xRateClimbPerHour";
        if (s.xRateDropPerCredit > 1_000) return "xRateDropPerCredit";
        if (s.xAuctionHalfLife < 10 minutes || s.xAuctionHalfLife > 30 days) return "xAuctionHalfLife";
        if (s.exitSliceCredits < 1 || s.exitSliceCredits > 1_000) return "exitSliceCredits";
        return bytes32(0);
    }

    /*//////////////////////////////////////////////////////////////
                              INVALID SETTINGS
    //////////////////////////////////////////////////////////////*/

    /// breaks exactly one field of valid settings, `which` picks it. returns the name the library must report
    function _break(Settings memory s, uint256 which) internal pure returns (bytes32 name) {
        // forge-lint: disable-start(unsafe-typecast)
        which = which % 36;
        if (which == 0) {
            (s.flatBps, name) = (10_001, "flatBps");
        } else if (which == 1) {
            (s.avgScore, name) = (799_999, "avgScore");
        } else if (which == 2) {
            (s.avgScore, name) = (8_000_001, "avgScore");
        } else if (which == 3) {
            (s.climbBaseBps, name) = (1_001, "climbBaseBps");
        } else if (which == 4) {
            (s.climbDoubleEvery, name) = (1 hours - 1, "climbDoubleEvery");
        } else if (which == 5) {
            (s.climbDoubleEvery, name) = (uint32(30 days) + 1, "climbDoubleEvery");
        } else if (which == 6) {
            (s.climbMaxBps, name) = (2_001, "climbMaxBps");
        } else if (which == 7) {
            (s.climbBaseBps, s.climbMaxBps, name) = (500, 499, "climbMaxBps");
        } else if (which == 8) {
            (s.dropBps, name) = (5_001, "dropBps");
        } else if (which == 9) {
            (s.spendCapBps, name) = (99, "spendCapBps");
        } else if (which == 10) {
            (s.spendCapBps, name) = (10_001, "spendCapBps");
        } else if (which == 11) {
            (s.bonusCapBps, name) = (5_001, "bonusCapBps");
        } else if (which == 12) {
            (s.tipSavingsBps, name) = (2_501, "tipSavingsBps");
        } else if (which == 13) {
            (s.tipCapBps, name) = (501, "tipCapBps");
        } else if (which == 14) {
            (s.reimburseBps, name) = (15_001, "reimburseBps");
        } else if (which == 15) {
            (s.reimburseCapBps, name) = (1_001, "reimburseCapBps");
        } else if (which == 16) {
            (s.reserveBps, name) = (999, "reserveBps");
        } else if (which == 17) {
            (s.reserveBps, name) = (40_001, "reserveBps");
        } else if (which == 18) {
            (s.auctionDuration, name) = (1 hours - 1, "auctionDuration");
        } else if (which == 19) {
            (s.auctionDuration, name) = (uint32(30 days) + 1, "auctionDuration");
        } else if (which == 20) {
            (s.exitAfter, name) = (uint32(365 days) + 1, "exitAfter");
        } else if (which == 21) {
            (s.saleToBuybackBps, name) = (10_001, "saleToBuybackBps");
        } else if (which == 22) {
            (s.exitToBuybackBps, name) = (10_001, "exitToBuybackBps");
        } else if (which == 23) {
            (s.buybackSlice, name) = (0.01 ether - 1, "buybackSlice");
        } else if (which == 24) {
            (s.buybackSlice, name) = (100 ether + 1, "buybackSlice");
        } else if (which == 25) {
            (s.buybackDelay, name) = (0, "buybackDelay");
        } else if (which == 26) {
            (s.buybackDelay, name) = (7_201, "buybackDelay");
        } else if (which == 27) {
            (s.keeperTipBps, name) = (501, "keeperTipBps");
        } else if (which == 28) {
            (s.xRateCap, name) = (10_001, "xRateCap");
        } else if (which == 29) {
            (s.xRateCap, s.xRateFloor, name) = (5_000, 5_001, "xRateFloor");
        } else if (which == 30) {
            (s.xRateClimbPerHour, name) = (1_001, "xRateClimbPerHour");
        } else if (which == 31) {
            (s.xRateDropPerCredit, name) = (1_001, "xRateDropPerCredit");
        } else if (which == 32) {
            (s.xAuctionHalfLife, name) = (10 minutes - 1, "xAuctionHalfLife");
        } else if (which == 33) {
            (s.xAuctionHalfLife, name) = (uint32(30 days) + 1, "xAuctionHalfLife");
        } else if (which == 34) {
            (s.exitSliceCredits, name) = (0, "exitSliceCredits");
        } else {
            (s.exitSliceCredits, name) = (1_001, "exitSliceCredits");
        }
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// invalid settings from the owner must revert with BadSetting naming the field, and a valid or invalid set from
    /// anyone else with OnlyOwner. whichever, nothing at all changes
    function setSettingsInvalid(uint256 seed, uint256 which) external checked {
        uint8 a = A_SET_INVALID;
        Settings memory ns = core.settings();
        bytes32 name = _break(ns, which);
        if (_firstViolation(ns) != name) {
            _flag(V_SETTINGS, "the handler's invalid settings are not invalid in the named field");
            return _skip(a);
        }
        bool stranger = seed % 5 == 0;
        // some of the strangers send valid settings, which must be refused just the same
        if (stranger && seed % 2 == 0) ns = core.settings();
        address who = stranger ? _actor(seed >> 8) : owner;
        OPre memory p = _opre();
        _att(a);
        vm.prank(who);
        try core.setSettings(ns) {
            _ok(a);
            _flag(V_SETTINGS, stranger ? "a stranger changed the settings" : "invalid settings were accepted");
            gSettingsHash = keccak256(abi.encode(core.settings()));
        } catch (bytes memory why) {
            _ok(a);
            gOwnerRefused++;
            _failed(p.bal, p.pot, p.rate, "setSettingsInvalid");
            _opost(p, "setSettingsInvalid");
            if (stranger) {
                if (bytes4(why) != Core.OnlyOwner.selector) _unexpected(a, why);
            } else if (bytes4(why) != Core.BadSetting.selector || why.length != 36) {
                _unexpected(a, why);
            } else {
                bytes32 field;
                assembly {
                    field := mload(add(why, 36))
                }
                if (field != name) _unexpected(a, why);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              SET RATE, SET XRATE
    //////////////////////////////////////////////////////////////*/

    /// the owner resets the eth rate anywhere in its bounds, edges included, or tries one outside them (BadRate), or a
    /// stranger tries (OnlyOwner). a good call is the one way the stored rate may jump: it lands on exactly the rate
    /// asked for, with no climb credited, the funded flag recomputed, and the pots and balances untouched
    function setRate(uint256 seed, uint256 mode) external checked {
        uint8 a = A_SET_RATE;
        uint256 m = mode % 10;
        uint256 rate;
        if (m == 0) rate = RATE_START_MIN_WEI;
        else if (m == 1) rate = RATE_START_MAX_WEI;
        else if (m == 2) rate = core.ethRate();
        else if (m == 3) rate = RATE_START_MIN_WEI - 1;
        else if (m == 4) rate = RATE_START_MAX_WEI + 1;
        else if (m == 5) rate = seed % 3 == 0 ? 0 : type(uint256).max;
        else rate = _logBound(seed, RATE_START_MIN_WEI, RATE_START_MAX_WEI);
        bool stranger = mode % 13 == 5;
        bool good = rate >= RATE_START_MIN_WEI && rate <= RATE_START_MAX_WEI;
        OPre memory p = _opre();
        _att(a);
        vm.prank(stranger ? _actor(seed) : owner);
        try core.setRate(rate) {
            _ok(a);
            if (stranger || !good) _flag(V_SETTINGS, "setRate accepted a stranger or a rate out of bounds");
            _opost(p, "setRate");
            if (core.ethRate() != rate || core.rateAtCheckpoint() != rate) {
                _flag(V_RATE_BOUND, "setRate did not land on the rate");
            }
            _fundedCheck();
            if (core.checkpointTime() != block.timestamp) {
                _flag(V_RATE_BOUND, "setRate did not restart the climb clock");
            }
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "setRate");
            if (good && !stranger) _unexpected(a, why);
            else if (bytes4(why) != (stranger ? Core.OnlyOwner.selector : Core.BadRate.selector)) _unexpected(a, why);
            else _ok(a);
        }
    }

    /// the owner resets the exit rate within the floor and the cap of the settings, edges included, or outside them
    /// (BadRate), or a stranger tries (OnlyOwner)
    function setXRate(uint256 seed, uint256 mode) external checked {
        uint8 a = A_SET_XRATE;
        Settings memory st = core.settings();
        uint256 m = mode % 8;
        uint256 rate;
        if (m == 0) rate = st.xRateFloor;
        else if (m == 1) rate = st.xRateCap;
        else if (m == 2) rate = core.xRate();
        else if (m == 3) rate = st.xRateFloor > 0 ? st.xRateFloor - 1 : uint256(st.xRateCap) + 1;
        else if (m == 4) rate = uint256(st.xRateCap) + 1;
        else rate = uint256(st.xRateFloor) + seed % (uint256(st.xRateCap) - st.xRateFloor + 1);
        bool stranger = mode % 11 == 3;
        bool good = rate >= st.xRateFloor && rate <= st.xRateCap;
        OPre memory p = _opre();
        _att(a);
        vm.prank(stranger ? _actor(seed) : owner);
        try core.setXRate(rate) {
            _ok(a);
            if (stranger || !good) _flag(V_SETTINGS, "setXRate accepted a stranger or a rate out of the band");
            _opost(p, "setXRate");
            if (core.xRate() != rate) _flag(V_RATE_BOUND, "setXRate did not land on the rate");
            if (core.exitAuctionPrice() != p.xPrice) _flag(V_AUCTION, "setXRate moved the exit auction price");
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "setXRate");
            if (good && !stranger) _unexpected(a, why);
            else if (bytes4(why) != (stranger ? Core.OnlyOwner.selector : Core.BadRate.selector)) _unexpected(a, why);
            else _ok(a);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              THE REST OF THE OWNER
    //////////////////////////////////////////////////////////////*/

    /// the owner's other doors, which only ever touch the allow list and the timelock queue: remove a target, queue an
    /// action and try to execute it early (TooEarly), cancel one that was never queued (NotQueued), queue twice
    /// (AlreadyQueued). none of it moves an asset
    function ownerMisc(uint256 seed, uint256 mode) external checked {
        uint8 a = A_OWNER_MISC;
        OPre memory p = _opre();
        address t = address(uint160(uint256(keccak256(abi.encode("misc", seed)))));
        bytes memory data = abi.encode(t);
        uint256 m = mode % 4;
        _att(a);
        vm.startPrank(owner);
        if (m == 0) {
            core.removeTarget(t);
        } else if (m == 1) {
            core.queue(Core.Action.AddTarget, data);
            try core.execute(Core.Action.AddTarget, data) {
                _flag(V_OWNER, "a queued action executed before its timelock");
            } catch (bytes memory why) {
                if (bytes4(why) != Core.TooEarly.selector) _unexpected(a, why);
            }
            core.cancel(Core.Action.AddTarget, data);
        } else if (m == 2) {
            try core.cancel(Core.Action.AddTarget, data) {
                _flag(V_OWNER, "cancelled an action that was never queued");
            } catch (bytes memory why) {
                if (bytes4(why) != Core.NotQueued.selector) _unexpected(a, why);
            }
        } else {
            core.queue(Core.Action.AddTarget, data);
            try core.queue(Core.Action.AddTarget, data) {
                _flag(V_OWNER, "queued the same action twice");
            } catch (bytes memory why) {
                if (bytes4(why) != Core.AlreadyQueued.selector) _unexpected(a, why);
            }
            core.cancel(Core.Action.AddTarget, data);
        }
        vm.stopPrank();
        if (core.allowedTarget(t)) _flag(V_OWNER, "an owner door allowed a target at once");
        _opost(p, "ownerMisc");
        _ok(a);
    }
}
