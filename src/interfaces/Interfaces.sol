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

/// the surface FeeHook and Coin rely on
interface ICoreFees {
    function addFees() external payable; // hook only. eth lands in ethPot
    function addExitFees(uint256 amount) external; // hook only, after it transferred `amount` exit token to the core. lands in xPot
    function exitPoolId() external view returns (bytes32); // 0 until the owner sets the coin/exitToken pool key
    function exitToken() external view returns (address); // 0 until the exit module is set
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

interface ILauncher {
    function launching() external view returns (bool);
}

interface ICoin {
    function increaseTransferAllowance(uint256 amount) external; // hook only
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
}
