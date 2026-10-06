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
    function overprintsOf(uint256 statementId) external view returns (uint256);
    function supply() external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
    function safeTransferFrom(address from, address to, uint256 id) external;
}

interface ICreditStrategy {
    function nftForSale(uint256 tokenId) external view returns (uint256 price);
    function sellTargetNFT(uint256 tokenId) external payable;
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

    /// the default stack: the live artcoins deployment
    function defaultStack() internal pure returns (Stack memory) {
        return Stack({
            poolManager: POOL_MANAGER,
            hook: SKIM_HOOK,
            tickSpacing: TICK_SPACING,
            poolFee: POOL_FEE,
            factory: ARTCOINS_FACTORY,
            locker: LP_LOCKER,
            escrow: FEE_ESCROW
        });
    }
}
