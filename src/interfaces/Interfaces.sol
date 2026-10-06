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
    /// the score a flat credit is priced as and the "average credit" of the funded rule, 1e4 scale
    uint32 avgScore;
    /// eth rate climb per hour at the start of a climb, bps
    uint16 climbBaseBps;
    /// the climb per hour doubles every this many seconds since the last fill
    uint32 climbDoubleEvery;
    uint16 climbMaxBps;
    /// fall of the eth rate when the whole pot is spent, bps
    uint16 dropBps;
    /// share of the pot that may be spent per hour window, bps
    uint16 spendCapBps;
    uint16 bonusCapBps;
    uint16 tipSavingsBps;
    uint16 tipCapBps;
    /// compose gas reimbursement, bps of gas cost
    uint16 reimburseBps;
    /// cap of the reimbursement, bps of the statement cost
    uint16 reimburseCapBps;
    /// auction reserve, bps of the statement cost
    uint16 reserveBps;
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
}

/// the artcoins stack a launch runs on. a deploy input of the Core, so a new artcoins version needs no code change.
/// `hook` is the only address whose eth the Core books as fees. the rest feed the pool key and the forbidden targets
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

    // the live artcoins stack at the pin. this is the DEFAULT config only (script/config/mainnet.json and the tests).
    // nothing in `src/` reads these, the Core takes its stack as a constructor argument
    address internal constant ARTCOINS_FACTORY = 0x49596c375c139E79bb937bcf826068a8F78D4e0e;
    address internal constant ARTCOINS_FACTORY_OWNER = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;
    address internal constant SKIM_HOOK = 0x636c050296B5Cc528D8785169Bf8923716FCa9cc;
    address internal constant LP_LOCKER = 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab;
    address internal constant FEE_ESCROW = 0x7559689765aE86cBB38e68CD1294830CccB125F2;
    address internal constant MEV_LINEAR_SKIM = 0xb038D597365FfD108D63C265Bb0621444a1D8B83;

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
            climbBaseBps: 100,
            climbDoubleEvery: 24 hours,
            climbMaxBps: 800,
            dropBps: 2_000,
            spendCapBps: 2_000,
            bonusCapBps: 2_500,
            tipSavingsBps: 1_000,
            tipCapBps: 200,
            reimburseBps: 11_000,
            reimburseCapBps: 500,
            reserveBps: 9_000,
            auctionDuration: 24 hours,
            exitAfter: 72 hours,
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
            exitSliceCredits: 20
        });
    }

    /// the default stack: the live artcoins deployment
    function defaultStack() internal pure returns (Stack memory) {
        return Stack({
            poolManager: POOL_MANAGER,
            hook: SKIM_HOOK,
            tickSpacing: TICK_SPACING,
            poolFee: POOL_FEE,
            factory: ARTCOINS_FACTORY,
            locker: LP_LOCKER,
            escrow: FEE_ESCROW,
            auctionFactory: AUCTION_FACTORY
        });
    }
}
