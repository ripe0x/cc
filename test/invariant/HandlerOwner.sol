// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Settings, RATE_START_MIN_WEI, RATE_START_MAX_WEI} from "../../src/interfaces/Interfaces.sol";
import {HandlerHouse} from "./HandlerHouse.sol";
import {BidModel} from "../utils/BidModel.sol";
import {MockExitModule} from "../standins/MockExitModule.sol";
import {MockExitToken} from "../standins/MockExitToken.sol";
import {CountingEngine, RefusingEngine} from "../attackers/FlushEngines.sol";

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
        s.avgScore = uint32(_f(_r(seed, 1), 800_000, 6_000_000, c.avgScore));
        s.dropPerCreditBps = uint16(_f(_r(seed, 2), 1, 1_000, c.dropPerCreditBps));
        s.dropFloorBps = uint16(_f(_r(seed, 3), 5_000, 10_000, c.dropFloorBps));
        s.climbPerMinBps = uint16(_f(_r(seed, 4), 1, 1_000, c.climbPerMinBps));
        s.ceilBps = uint16(_f(_r(seed, 5), 10_000, 30_000, c.ceilBps));
        s.idleLoosenBps = uint16(_f(_r(seed, 29), 0, 2_000, c.idleLoosenBps));
        s.clampCredits = uint16(_f(_r(seed, 30), 1, 1_000, c.clampCredits));
        s.spendCapBps = uint16(_f(_r(seed, 6), 100, 5_000, c.spendCapBps));
        s.bonusCapBps = uint16(_f(_r(seed, 7), 0, 5_000, c.bonusCapBps));
        s.tipSavingsBps = uint16(_f(_r(seed, 8), 0, 2_500, c.tipSavingsBps));
        s.tipCapBps = uint16(_f(_r(seed, 9), 0, 500, c.tipCapBps));
        s.reimburseBps = uint16(_f(_r(seed, 10), 0, 15_000, c.reimburseBps));
        s.reimburseCapBps = uint16(_f(_r(seed, 11), 0, 1_000, c.reimburseCapBps));
        s.saleFloorBps = uint16(_f(_r(seed, 12), 1_000, 40_000, c.saleFloorBps));
        s.auctionDuration = uint32(_f(_r(seed, 13), 6 hours, 30 days, c.auctionDuration));
        s.exitAfter = uint32(_f(_r(seed, 14), 1 hours, 365 days, c.exitAfter));
        s.saleToBuybackBps = uint16(_f(_r(seed, 15), 0, 10_000, c.saleToBuybackBps));
        s.exitToBuybackBps = uint16(_f(_r(seed, 16), 0, 10_000, c.exitToBuybackBps));
        s.buybackSlice = uint128(_f(_r(seed, 17), 0.01 ether, 2 ether, c.buybackSlice));
        s.buybackDelay = uint16(_f(_r(seed, 18), 1, 7_200, c.buybackDelay));
        s.keeperTipBps = uint16(_f(_r(seed, 19), 0, 500, c.keeperTipBps));
        s.xRateCap = uint16(_f(_r(seed, 20), 0, 10_000, c.xRateCap));
        s.xRateFloor = uint16(_f(_r(seed, 21), 0, s.xRateCap, c.xRateFloor));
        s.xRateClimbPerHour = uint16(_f(_r(seed, 22), 0, 1_000, c.xRateClimbPerHour));
        s.xRateDropPerCredit = uint16(_f(_r(seed, 23), 0, 1_000, c.xRateDropPerCredit));
        s.xAuctionHalfLife = uint32(_f(_r(seed, 24), 10 minutes, 30 days, c.xAuctionHalfLife));
        s.exitSliceCredits = uint16(_f(_r(seed, 25), 1, 1_000, c.exitSliceCredits));
        s.rateCap = uint64(_f(_r(seed, 26), 1e11, 1e15, c.rateCap));
        s.exitLaneToBuybackBps = uint16(_f(_r(seed, 27), 0, 10_000, c.exitLaneToBuybackBps));
        s.feeToBuybackBps = uint16(_f(_r(seed, 28), 0, 10_000, c.feeToBuybackBps));
        _corner(s, corner);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// the extreme corners the brief names, forced on top of the random settings
    function _corner(Settings memory s, uint256 k) internal pure {
        // forge-lint: disable-start(unsafe-typecast)
        k = k % 20;
        if (k == 1) {
            s.flatBps = 0;
        } else if (k == 2) {
            s.flatBps = 10_000;
        } else if (k == 3) {
            s.spendCapBps = 5_000;
        } else if (k == 4) {
            s.saleFloorBps = 1_000;
        } else if (k == 5) {
            s.saleFloorBps = 40_000;
        } else if (k == 6) {
            s.saleToBuybackBps = 0;
        } else if (k == 7) {
            s.saleToBuybackBps = 10_000;
        } else if (k == 8) {
            s.idleLoosenBps = 0;
        } else if (k == 9) {
            s.dropPerCreditBps = 1_000;
            s.dropFloorBps = 5_000;
        } else if (k == 10) {
            s.buybackSlice = 0.01 ether;
        } else if (k == 11) {
            s.buybackSlice = 2 ether;
        } else if (k == 12) {
            s.exitAfter = 1 hours;
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
            s.climbPerMinBps = 1_000;
            s.ceilBps = 30_000;
            s.idleLoosenBps = 2_000;
            s.clampCredits = 1;
            s.auctionDuration = 6 hours;
            s.xAuctionHalfLife = 10 minutes;
        } else if (k == 17) {
            // the lowest rate cap: it pulls the eth rate down to it at the checkpoint
            s.rateCap = 1e11;
        } else if (k == 18) {
            // every exit goes to the bid pot, and every exit lane exit goes to the buyback
            s.exitToBuybackBps = 0;
            s.exitLaneToBuybackBps = 10_000;
        } else if (k == 19) {
            s.exitToBuybackBps = 10_000;
            s.exitLaneToBuybackBps = 10_000;
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
        // invariant 6 across a settings call: the call checkpoints the rate it found. the read is that rate bounded by the
        // new rate cap and, while funded, by the clamp and the ceiling of the new settings
        uint256 wantStored = p.rate > ns.rateCap ? ns.rateCap : p.rate;
        uint256 wantRate = wantStored;
        if (core.funded()) {
            (uint256 anchor,,) = _anchorState();
            uint256 clamp = BidModel.clamp(ns, core.ethPot());
            uint256 ceil = BidModel.ceiling(ns, anchor, block.timestamp - core.lastFillTime());
            uint256 limit = clamp < ceil ? clamp : ceil;
            if (wantRate > limit) wantRate = limit;
        }
        if (core.ethRate() != wantRate) _flag(V_RATE_BOUND, "a settings call moved the eth rate");
        if (core.rateAtCheckpoint() != wantStored) _flag(V_RATE_BOUND, "a settings call moved the stored eth rate");
        _fundedCheck();
        if (phase2()) _xFundedCheck();
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
        if (s.avgScore < 800_000 || s.avgScore > 6_000_000) return "avgScore";
        if (s.dropPerCreditBps < 1 || s.dropPerCreditBps > 1_000) return "dropPerCreditBps";
        if (s.dropFloorBps < 5_000 || s.dropFloorBps > 10_000) return "dropFloorBps";
        if (s.climbPerMinBps < 1 || s.climbPerMinBps > 1_000) return "climbPerMinBps";
        if (s.ceilBps < 10_000 || s.ceilBps > 30_000) return "ceilBps";
        if (s.idleLoosenBps > 2_000) return "idleLoosenBps";
        if (s.clampCredits < 1 || s.clampCredits > 1_000) return "clampCredits";
        if (s.spendCapBps < 100 || s.spendCapBps > 5_000) return "spendCapBps";
        if (s.bonusCapBps > 5_000) return "bonusCapBps";
        if (s.tipSavingsBps > 2_500) return "tipSavingsBps";
        if (s.tipCapBps > 500) return "tipCapBps";
        if (s.reimburseBps > 15_000) return "reimburseBps";
        if (s.reimburseCapBps > 1_000) return "reimburseCapBps";
        if (s.saleFloorBps < 1_000 || s.saleFloorBps > 40_000) return "saleFloorBps";
        if (s.auctionDuration < 6 hours || s.auctionDuration > 30 days) return "auctionDuration";
        if (s.exitAfter < 1 hours || s.exitAfter > 365 days) return "exitAfter";
        if (s.saleToBuybackBps > 10_000) return "saleToBuybackBps";
        if (s.exitToBuybackBps > 10_000) return "exitToBuybackBps";
        if (s.buybackSlice < 0.01 ether || s.buybackSlice > 2 ether) return "buybackSlice";
        if (s.buybackDelay < 1 || s.buybackDelay > 7_200) return "buybackDelay";
        if (s.keeperTipBps > 500) return "keeperTipBps";
        if (s.xRateCap > 10_000) return "xRateCap";
        if (s.xRateFloor > s.xRateCap) return "xRateFloor";
        if (s.xRateClimbPerHour > 1_000) return "xRateClimbPerHour";
        if (s.xRateDropPerCredit > 1_000) return "xRateDropPerCredit";
        if (s.xAuctionHalfLife < 10 minutes || s.xAuctionHalfLife > 30 days) return "xAuctionHalfLife";
        if (s.exitSliceCredits < 1 || s.exitSliceCredits > 1_000) return "exitSliceCredits";
        if (s.rateCap < 1e11 || s.rateCap > 1e15) return "rateCap";
        if (s.exitLaneToBuybackBps > 10_000) return "exitLaneToBuybackBps";
        if (s.feeToBuybackBps > 10_000) return "feeToBuybackBps";
        return bytes32(0);
    }

    /*//////////////////////////////////////////////////////////////
                              INVALID SETTINGS
    //////////////////////////////////////////////////////////////*/

    /// breaks exactly one field of valid settings, `which` picks it. returns the name the library must report
    function _break(Settings memory s, uint256 which) internal pure returns (bytes32 name) {
        // forge-lint: disable-start(unsafe-typecast)
        which = which % 46;
        if (which == 0) {
            (s.flatBps, name) = (10_001, "flatBps");
        } else if (which == 1) {
            (s.avgScore, name) = (799_999, "avgScore");
        } else if (which == 2) {
            (s.avgScore, name) = (6_000_001, "avgScore");
        } else if (which == 3) {
            (s.dropPerCreditBps, name) = (1_001, "dropPerCreditBps");
        } else if (which == 4) {
            (s.dropPerCreditBps, name) = (0, "dropPerCreditBps");
        } else if (which == 5) {
            (s.dropFloorBps, name) = (4_999, "dropFloorBps");
        } else if (which == 6) {
            (s.dropFloorBps, name) = (10_001, "dropFloorBps");
        } else if (which == 7) {
            (s.climbPerMinBps, name) = (0, "climbPerMinBps");
        } else if (which == 8) {
            (s.climbPerMinBps, name) = (1_001, "climbPerMinBps");
        } else if (which == 9) {
            (s.spendCapBps, name) = (99, "spendCapBps");
        } else if (which == 10) {
            (s.spendCapBps, name) = (5_001, "spendCapBps");
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
            (s.saleFloorBps, name) = (999, "saleFloorBps");
        } else if (which == 17) {
            (s.saleFloorBps, name) = (40_001, "saleFloorBps");
        } else if (which == 18) {
            (s.auctionDuration, name) = (6 hours - 1, "auctionDuration");
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
            (s.buybackSlice, name) = (2 ether + 1, "buybackSlice");
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
        } else if (which == 35) {
            (s.exitSliceCredits, name) = (1_001, "exitSliceCredits");
        } else if (which == 36) {
            (s.ceilBps, name) = (9_999, "ceilBps");
        } else if (which == 37) {
            (s.exitAfter, name) = (1 hours - 1, "exitAfter");
        } else if (which == 38) {
            (s.rateCap, name) = (1e11 - 1, "rateCap");
        } else if (which == 39) {
            (s.rateCap, name) = (1e15 + 1, "rateCap");
        } else if (which == 40) {
            (s.exitLaneToBuybackBps, name) = (10_001, "exitLaneToBuybackBps");
        } else if (which == 41) {
            (s.feeToBuybackBps, name) = (10_001, "feeToBuybackBps");
        } else if (which == 42) {
            (s.ceilBps, name) = (30_001, "ceilBps");
        } else if (which == 43) {
            (s.idleLoosenBps, name) = (2_001, "idleLoosenBps");
        } else if (which == 44) {
            (s.clampCredits, name) = (0, "clampCredits");
        } else {
            (s.clampCredits, name) = (1_001, "clampCredits");
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
                if (bytes4(why) != ICore.OnlyOwner.selector) _unexpected(a, why);
            } else if (bytes4(why) != ICore.BadSetting.selector || why.length != 36) {
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
        uint256 cap = core.settings().rateCap;
        uint256 rate;
        if (m == 0) rate = RATE_START_MIN_WEI;
        else if (m == 1) rate = cap;
        else if (m == 2) rate = core.ethRate();
        else if (m == 3) rate = RATE_START_MIN_WEI - 1;
        else if (m == 4) rate = RATE_START_MAX_WEI + 1;
        else if (m == 5) rate = seed % 3 == 0 ? 0 : type(uint256).max;
        else if (m == 6) rate = cap + 1;
        else rate = _logBound(seed, RATE_START_MIN_WEI, cap);
        bool stranger = mode % 13 == 5;
        bool good = rate >= RATE_START_MIN_WEI && rate <= RATE_START_MAX_WEI && rate <= cap;
        OPre memory p = _opre();
        _att(a);
        vm.prank(stranger ? _actor(seed) : owner);
        try core.setRate(rate) {
            _ok(a);
            if (stranger || !good) _flag(V_SETTINGS, "setRate accepted a stranger or a rate out of bounds");
            _opost(p, "setRate");
            uint256 want = rate;
            if (core.funded()) {
                uint256 clamp = BidModel.clamp(core.settings(), core.ethPot());
                if (want > clamp) want = clamp;
            }
            (uint256 anchor,,) = _anchorState();
            if (core.ethRate() != want || core.rateAtCheckpoint() != rate || anchor != rate) {
                _flag(V_RATE_BOUND, "setRate did not land on the rate and the anchor");
            }
            _fundedCheck();
            if (core.checkpointTime() != block.timestamp) {
                _flag(V_RATE_BOUND, "setRate did not restart the climb clock");
            }
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "setRate");
            if (good && !stranger) _unexpected(a, why);
            else if (bytes4(why) != (stranger ? ICore.OnlyOwner.selector : ICore.BadRate.selector)) _unexpected(a, why);
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
            else if (bytes4(why) != (stranger ? ICore.OnlyOwner.selector : ICore.BadRate.selector)) _unexpected(a, why);
            else _ok(a);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              THE REST OF THE OWNER
    //////////////////////////////////////////////////////////////*/

    /// the owner's other doors, which only ever touch the allow list and the owner slot, all at once: remove a target,
    /// add one (live at once, and removed again), start a handover and clear it, and a stranger who tries the owner
    /// doors (OnlyOwner). the locks are one way and never fuzzed here. none of it moves an asset
    function ownerMisc(uint256 seed, uint256 mode) external checked {
        uint8 a = A_OWNER_MISC;
        OPre memory p = _opre();
        address t = address(uint160(uint256(keccak256(abi.encode("misc", seed)))));
        uint256 m = mode % 4;
        _att(a);
        if (m == 0) {
            vm.prank(owner);
            core.removeTarget(t);
        } else if (m == 1) {
            vm.startPrank(owner);
            try core.addTarget(t) {
                if (!core.allowedTarget(t)) _flag(V_OWNER, "addTarget did not allow the target at once");
                core.removeTarget(t);
            } catch (bytes memory why) {
                // the stack contracts and the exit side are refused, nothing else is
                bool shut = core.targetsLocked() && bytes4(why) == ICore.Locked.selector;
                if (bytes4(why) != ICore.ForbiddenTarget.selector && !shut) _unexpected(a, why);
            }
            vm.stopPrank();
        } else if (m == 2) {
            vm.startPrank(owner);
            core.transferOwnership(t);
            if (core.pendingOwner() != t || core.owner() != owner) _flag(V_OWNER, "a handover moved the owner early");
            core.transferOwnership(address(0));
            vm.stopPrank();
            if (core.pendingOwner() != address(0)) _flag(V_OWNER, "the handover was not cleared");
        } else {
            vm.startPrank(t);
            try core.addTarget(t) {
                _flag(V_OWNER, "a stranger added a target");
            } catch (bytes memory why) {
                if (bytes4(why) != ICore.OnlyOwner.selector) _unexpected(a, why);
            }
            try core.lockTargets() {
                _flag(V_OWNER, "a stranger locked the targets");
            } catch (bytes memory why) {
                if (bytes4(why) != ICore.OnlyOwner.selector) _unexpected(a, why);
            }
            try core.acceptOwnership() {
                _flag(V_OWNER, "a stranger accepted a handover that was not offered");
            } catch (bytes memory why) {
                if (bytes4(why) != ICore.OnlyPendingOwner.selector) _unexpected(a, why);
            }
            vm.stopPrank();
        }
        if (core.owner() != owner) _flag(V_OWNER, "the owner changed");
        _opost(p, "ownerMisc");
        _ok(a);
    }

    /*//////////////////////////////////////////////////////////////
                              REPLACE THE EXIT MODULE
    //////////////////////////////////////////////////////////////*/

    /// the owner replaces the exit module at once (docs/FLOW.md section 8): a new module with the same
    /// exit token and a new unit, the same address again after its unit changed, the same address and unit, and the
    /// refused ones (another exit token, no unit, a unit the opening price floor refuses, no code). a good set keeps the pots, the balances and the
    /// exit auction price and clock, credits the exit rate under the old unit, resyncs the funded flag, reads the unit again and
    /// switches the handler to the new module. a refused one changes nothing
    function replaceModule(uint256 seed, uint256 mode) external checked {
        uint8 a = A_REPLACE_MODULE;
        if (!phase2()) return _skip(a);
        address token = core.exitToken();
        address oldModule = core.exitModule();
        uint256 oldUnit = core.unitPerPoint();
        (MockExitModule next, bytes4 want) = _nextModule(seed, mode % 8, token);
        // a locked module door refuses every set, whatever the module
        if (core.exitModuleLocked()) want = ICore.Locked.selector;
        _att(a);
        OPre memory p = _opre();
        uint256 start0 = core.xStartPrice();
        uint64 at0 = core.xStartTime();
        vm.prank(owner);
        try core.setExitModule(address(next)) {
            if (want != 0) _flag(V_OWNER, "a refused module set was accepted");
            _afterModuleSet(p, next, token, start0, at0);
            module = next;
            _ok(a);
        } catch (bytes memory why) {
            _failed(p.bal, p.pot, p.rate, "replaceModule");
            _opost(p, "replaceModule");
            if (want == 0 || bytes4(why) != want) _unexpected(a, why);
            else _ok(a);
            if (core.exitModule() != oldModule || core.unitPerPoint() != oldUnit || core.exitToken() != token) {
                _flag(V_OWNER, "a refused module set changed the module, the unit or the token");
            }
        }
    }

    /// the module the owner proposes and the selector the set must revert with, zero when it must go through
    function _nextModule(uint256 seed, uint256 m, address token) internal returns (MockExitModule next, bytes4 want) {
        if (m <= 1) {
            next = new MockExitModule(token, _logBound(seed >> 8, 2e9, 5e10));
        } else if (m <= 3) {
            // the same module again: its unit changed (m 2) or did not (m 3), and it answers the unit read
            module.setRevertUnit(false);
            if (m == 2) module.setUnitPerPoint(_logBound(seed >> 8, 2e9, 5e10));
            next = module;
        } else if (m == 4) {
            next = new MockExitModule(address(new MockExitToken("Other", "OTH")), 1e10);
            want = ICore.ExitTokenChanged.selector;
        } else if (m == 5) {
            next = new MockExitModule(token, seed % 2 == 0 ? 0 : uint256(type(uint128).max) + 1);
            want = ICore.BadModule.selector;
        } else if (m == 6) {
            // the opening price asks the supply for one slice (exitSliceCredits * avgScore * unit, at least 8e5 times the
            // unit): above 1.25e27 per point it falls under 1e12 under any setting
            next = new MockExitModule(token, 1e28);
            want = ICore.BadModule.selector;
        } else {
            next = MockExitModule(address(uint160(uint256(keccak256(abi.encode("nocode", seed))))));
            want = ICore.BadModule.selector;
        }
    }

    function _afterModuleSet(OPre memory p, MockExitModule next, address token, uint256 start0, uint64 at0) internal {
        _opost(p, "replaceModule");
        if (core.exitModule() != address(next)) _flag(V_OWNER, "the module set did not install the module");
        if (core.exitToken() != token) _flag(V_OWNER, "a module set changed the exit token");
        if (core.unitPerPoint() != next.currentUnit()) _flag(V_OWNER, "a module set did not read the unit again");
        // the climb so far was credited under the old unit
        if (core.xRate() != p.xRate) _flag(V_RATE_BOUND, "a module set lost or invented exit rate climb");
        _xFundedCheck();
        // the price is coin per exit token: kept whatever the unit, and the clock too while there is something to sell
        if (core.exitAuctionPrice() < p.xPrice) _flag(V_AUCTION, "a module set made the exit auction cheaper");
        // a later set never touches the start price or the clock, with or without something for sale
        if (core.exitAuctionPrice() != p.xPrice || core.xStartPrice() != start0 || core.xStartTime() != at0) {
            _flag(V_AUCTION, "a module set moved the exit auction");
        }
        if (core.allowedTarget(address(next))) _flag(V_OWNER, "a module set left the allowed target flag of the module");
    }

    /*//////////////////////////////////////////////////////////////
                           REPOINT THE FEE ROUTER
    //////////////////////////////////////////////////////////////*/

    /// the router owner as an adversary: points the engine at the core, at an engine that takes eth, at one that refuses it,
    /// at an address with no code or the zero address (both refused), and now and then locks the router while the core is
    /// the engine. a good set takes effect at once and moves no eth, not the router's and not the core's. after the lock
    /// every set reverts and the engine stays
    function repoint(uint256 seed, uint256 mode) external checked {
        uint8 a = A_REPOINT;
        if (otherEngine == address(0)) {
            otherEngine = address(new CountingEngine());
            refusingEngine = address(new RefusingEngine());
        }
        address ro = feeRouter.owner();
        uint256 m = mode % 6;
        address target = m == 0 ? address(core) : (m == 1 ? otherEngine : (m == 2 ? refusingEngine : (m == 3 ? address(uint160(seed | 0x10000)) : (m == 4 ? address(0) : address(core)))));
        OPre memory pre = _opre();
        uint256 held = address(feeRouter).balance;
        _att(a);
        if (m == 5 && !gRouterLocked && seed % 25 == 0 && gEngine == address(core)) {
            vm.prank(ro);
            try feeRouter.lock() {
                gRouterLocked = true;
            } catch {
                _flag(V_ROUTER, "the router owner could not lock with an engine set");
            }
        }
        vm.prank(ro);
        try feeRouter.setEngine(target) {
            routerRepoints++;
            if (gRouterLocked) _flag(V_ROUTER, "setEngine worked on a locked router");
            else if (target == address(0) || target.code.length == 0) _flag(V_ROUTER, "setEngine took an address with no code");
            else gEngine = target;
        } catch {
            bool bad = !gRouterLocked && target != address(0) && target.code.length != 0;
            if (bad) _flag(V_ROUTER, "setEngine refused a good engine");
        }
        if (feeRouter.engine() != gEngine) _flag(V_ROUTER, "the router engine is not the one set");
        if (feeRouter.locked() != gRouterLocked) _flag(V_LOCK, "the router lock flag differs from the ghost");
        if (address(feeRouter).balance != held) _flag(V_ROUTER, "setting the engine moved router eth");
        _opost(pre, "repoint");
        _ok(a);
    }
}
