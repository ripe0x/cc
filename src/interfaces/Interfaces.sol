// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// shared interfaces. fixed by the project director. do not change signatures without sign off.

enum Lane {
    Eth,
    Exit
}

interface IController {
    function wants(uint256 creditId) external view returns (uint16 bonusBps);
    function nextPage(Lane lane) external view returns (bool ready, uint256[80] memory ids, uint8 format);
    function nextOverprint() external view returns (bool ready, uint256 baseId, uint256 topId);
    /// the asking price in wei of the eth lane statement `sid` (cost basis `cost`, listed at `listedAt`) right now. the
    /// core calls it with a fixed gas cap and floors the answer at the hard floor `cost * saleFloorBps / 10_000`
    function statementPrice(uint256 sid, uint256 cost, uint64 listedAt) external view returns (uint256 priceWei);
}

interface IExitModule {
    function exitToken() external view returns (address);
    /// exit token base units per one unit of 1e4 scaled score
    function unitPerPoint() external view returns (uint256);
    /// called by the core after it transfers the statement to the module
    function exit(uint256 statementId) external returns (uint256 out);
}

/// the surface controllers rely on. piles are insertion ordered linked lists, oldest first
interface ICoreViews {
    function pileSize(Lane lane) external view returns (uint256);
    function pileHead(Lane lane) external view returns (uint256 id); // oldest. 0 if empty
    function pileNext(uint256 id) external view returns (uint256); // 0 at the end
    function pilePage(Lane lane, uint256 startAfter, uint256 n) external view returns (uint256[] memory ids); // startAfter 0 starts at head
    function creditInfo(uint256 id) external view returns (bool inPile, Lane lane, uint256 cost, uint64 acquiredAt);
    function scoreOf(uint256 id) external view returns (uint256); // 1e4 scale
    function statementInfo(uint256 sid) external view returns (bool held, Lane lane, uint256 cost, uint64 clockStart);
    function heldStatements() external view returns (uint256[] memory sids);
}

/// what the controller needs of the core beyond the views: the live owner and the one door that sells a statement
interface ICoreSale {
    function owner() external view returns (address);
    function settings() external view returns (Settings memory);
    function sellTo(uint256 sid, address buyer) external payable;
}

/// the coin calls the core makes. the live token burns from the caller or from an account that approved the caller
interface ICoin {
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

interface ICredits {
    function seedOf(uint256 id) external view returns (bytes21);
    function timestampOf(uint256 id) external view returns (uint64);
    function tokensOf(address owner) external view returns (uint256[] memory);
    function ownerOf(uint256 id) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function getApproved(uint256 id) external view returns (address);
    function approve(address to, uint256 id) external;
    function transferFrom(address from, address to, uint256 id) external;
}

interface ICreditScore {
    function scoreOf(bytes21 seed, uint64 paidAt) external pure returns (uint256);
    function traitsOf(bytes21 seed, uint64 paidAt)
        external
        pure
        returns (uint256 mask, uint256 active, uint256 occupied, uint256 eights, uint256 band);
}

interface IStatements {
    function compose(uint256[80] calldata creditIds, uint8 format) external returns (uint256 statementId);
    function overprint(uint256 baseId, uint256 topId) external;
    function creditScoreOf(uint256 statementId) external view returns (uint256);
    function creditsOf(uint256 statementId) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function overprintsOf(uint256 statementId) external view returns (uint256);
    function supply() external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function transferFrom(address from, address to, uint256 id) external;
    function safeTransferFrom(address from, address to, uint256 id) external;
}

interface ICreditStrategy {
    function nftForSale(uint256 tokenId) external view returns (uint256 price);
    function sellTargetNFT(uint256 tokenId) external payable;
}

// bounds of the Core constructor argument `rateStart`, wei per whole point. one definition for the Core and the scripts
uint256 constant RATE_START_MIN_WEI = 1e11;
uint256 constant RATE_START_MAX_WEI = 1e15;

/// every economic setting of the Core. one struct in Core storage, owner settable at once through `setSettings`, bounds
/// in `src/lib/SettingsBounds.sol`. the types are narrow so the whole struct packs into three storage slots
/// (a hot path reads it with a handful of loads). docs/FLOW.md section 2 has the meaning of every field
struct Settings {
    /// share of a bid priced flat per credit, bps. 10_000 is flat, 0 is per score point
    uint16 flatBps;
    /// the score a flat credit is priced as and the average credit of the clamp, 1e4 scale
    uint32 avgScore;
    /// fall of the eth rate per credit bought, bps of the rate before that credit
    uint16 dropPerCreditBps;
    /// within one minute the rate falls no lower than this share of the rate at the first fill of that minute, bps
    uint16 dropFloorBps;
    /// climb of the eth rate per minute, bps, compounded
    uint16 climbPerMinBps;
    /// the rate stays at or below this share of the ceiling anchor, bps. the anchor is the rate of the last fill
    uint16 ceilBps;
    /// growth of the ceiling anchor per full 10 minutes since the last fill, bps of the anchor
    uint16 idleLoosenBps;
    /// share of the pot that may be spent per hour window, bps
    uint16 spendCapBps;
    uint16 bonusCapBps;
    uint16 tipSavingsBps;
    uint16 tipCapBps;
    /// compose gas reimbursement, bps of gas cost
    uint16 reimburseBps;
    /// cap of the reimbursement, bps of the statement cost
    uint16 reimburseCapBps;
    /// the hard floor of a statement sale, bps of the statement cost. no sale clears below it. the controller prices
    /// above it, the house reserve and `sellTo` are floored at it
    uint16 saleFloorBps;
    /// seconds an auction runs from its first bid
    uint32 auctionDuration;
    /// seconds an eth lane statement must have been listed without a bid before phase 2 may redeem it
    uint32 exitAfter;
    /// share of sale proceeds that goes to the coin buyback, bps
    uint16 saleToBuybackBps;
    /// share of exit token from eth lane exits that goes to the coin buyback, bps
    uint16 exitToBuybackBps;
    uint128 buybackSlice;
    /// blocks between two coin buybacks
    uint16 buybackDelay;
    uint16 keeperTipBps;
    /// exit rate cap and floor, bps of score
    uint16 xRateCap;
    uint16 xRateFloor;
    uint16 xRateClimbPerHour;
    uint16 xRateDropPerCredit;
    /// seconds
    uint32 xAuctionHalfLife;
    /// credits worth of exit token per exit buyback slice
    uint16 exitSliceCredits;
    /// the most the eth rate can be, wei per whole point. the price state and the read stay at or below it, `setRate`
    /// refuses above it, and the rate bounds apply to it
    uint64 rateCap;
    /// share of exit token from EXIT lane exits that goes to the coin buyback, bps, the rest to the exit bid pot
    uint16 exitLaneToBuybackBps;
    /// share of the swap fee eth that the fee router flushes to the core (booked in `receive()`) that goes to the coin buyback,
    /// the rest to the pot, bps. eth booked later by `skim` goes to the pot whole
    uint16 feeToBuybackBps;
}

/// the five sale settings of the controller, its constructor argument and the `sale` block of the launch config.
/// bounds are enforced by the controller (docs/FLOW.md 9.3)
struct Sale {
    /// buy only mode: statements sell at once at the asking price. false is auction mode (the asking price is the house reserve)
    bool buyOnly;
    /// the asking price at listing, bps of the statement cost
    uint16 startBps;
    /// bps the asking price falls per step
    uint16 stepBps;
    /// seconds per step
    uint32 stepEvery;
    /// the asking price never falls below this, bps of the statement cost
    uint16 floorBps;
}

/// the artcoins stack a launch runs on. a deploy input of the Core, so a new artcoins version needs no code change.
/// `feeSource` (the fee router) is the only address whose eth the Core books as fees. the rest feed the pool key and the
/// forbidden targets
struct Stack {
    address poolManager;
    address hook;
    int24 tickSpacing;
    uint24 poolFee;
    address factory;
    address locker;
    address escrow;
    /// the pnd auction house factory. the Core creates its own house through it in the constructor
    address auctionFactory;
    /// the fee router: the pool's bounty recipient. the Core books eth from it as fees and forbids it as a target
    address feeSource;
}

library Mainnet {
    address internal constant CREDITS = 0x97630aA70AB14ed9883B41dAfccBc11349723043;
    address internal constant STATEMENTS = 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b;
    address internal constant CREDIT_SCORE = 0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7;
    address internal constant CREDIT_STRATEGY = 0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6;
    address internal constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    // the artcoins v2 stack is not on mainnet yet (docs/V2-PORT.md). its addresses are config inputs, never constants:
    // `defaultStack` leaves them zero, the Core refuses a zero member and the deploy script refuses a zero config.
    // the tests take them from the stack the fixture deploys on the fork (test/utils/V2Stack.sol)

    /// the dynamic fee flag every artcoins pool uses, and its tick spacing
    uint24 internal constant POOL_FEE = 0x800000;
    int24 internal constant TICK_SPACING = 200;

    /// the pnd auction house factory, live and verified (docs/reference/pnd)
    address internal constant AUCTION_FACTORY = 0x77aB853543286C9Cdd7dd6c01222A7cC4Ac93d63;

    /// the launch values of docs/FLOW.md section 2
    function defaultSettings() internal pure returns (Settings memory) {
        return Settings({
            flatBps: 10_000,
            avgScore: 4_330_000,
            dropPerCreditBps: 50,
            dropFloorBps: 8_000,
            climbPerMinBps: 50,
            ceilBps: 12_500,
            idleLoosenBps: 200,
            spendCapBps: 10_000,
            bonusCapBps: 2_500,
            tipSavingsBps: 1_000,
            tipCapBps: 200,
            // the Core meters gross gas. the EIP-3529 refund cap returns up to 20 percent of it to the caller, and compose
            // and exit clear enough storage to reach the cap, so 80 percent of the metered gas is the net cost
            reimburseBps: 8_000,
            reimburseCapBps: 500,
            saleFloorBps: 7_500,
            auctionDuration: 24 hours,
            exitAfter: 105 hours,
            saleToBuybackBps: 5_000,
            exitToBuybackBps: 5_000,
            buybackSlice: 1 ether,
            buybackDelay: 25,
            keeperTipBps: 50,
            xRateCap: 9_700,
            xRateFloor: 3_000,
            xRateClimbPerHour: 100,
            xRateDropPerCredit: 20,
            xAuctionHalfLife: 6 hours,
            exitSliceCredits: 20,
            rateCap: 205_540_000_000_000,
            exitLaneToBuybackBps: 0,
            feeToBuybackBps: 0
        });
    }

    /// the launch sale: start at 110 percent, one point every 3 hours, down to 75 percent at hour 105, auction mode
    function defaultSale() internal pure returns (Sale memory) {
        return Sale({buyOnly: false, startBps: 11_000, stepBps: 100, stepEvery: 3 hours, floorBps: 7_500});
    }

    /// the default stack: the fixed parts of mainnet. the v2 members (hook, factory, locker, escrow) and the fee router
    /// are zero placeholders that must be filled before a launch
    function defaultStack() internal pure returns (Stack memory) {
        return Stack({
            poolManager: POOL_MANAGER,
            hook: address(0),
            tickSpacing: TICK_SPACING,
            poolFee: POOL_FEE,
            factory: address(0),
            locker: address(0),
            escrow: address(0),
            auctionFactory: AUCTION_FACTORY,
            feeSource: address(0)
        });
    }
}
