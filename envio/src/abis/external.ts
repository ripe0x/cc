// Pinned ABIs of contracts outside this repo. Confirmed against the deployed contracts on a mainnet fork
// (README.md lists what was checked). Only the members the indexer uses.
import { parseAbi } from "viem";

/** Credits ERC721 `0x97630aA70AB14ed9883B41dAfccBc11349723043`. */
export const creditsAbi = parseAbi([
  "event Transfer(address indexed from, address indexed to, uint256 indexed id)",
  "function ownerOf(uint256 id) view returns (address)",
  "function seedOf(uint256 id) view returns (bytes21)",
  "function timestampOf(uint256 id) view returns (uint64)",
  "function tokenURI(uint256 id) view returns (string)",
]);

/** CreditStrategy proxy `0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6`. Listings are `nftForSale(id)`; no event ends one. */
export const strategyAbi = parseAbi([
  "event NFTBoughtByProtocol(uint256 indexed tokenId, uint256 purchasePrice, uint256 listPrice)",
  "event NFTSoldByProtocol(uint256 indexed tokenId, uint256 price, address buyer)",
  "function nftForSale(uint256 id) view returns (uint256)",
]);

/** Statements ERC721 `0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b`. */
export const statementsAbi = parseAbi([
  "event Transfer(address indexed from, address indexed to, uint256 indexed id)",
  "function ownerOf(uint256 id) view returns (address)",
  "function creditScoreOf(uint256 statementId) view returns (uint256)",
  "function formatOf(uint256 statementId) view returns (uint8)",
  "function tokenURI(uint256 id) view returns (string)",
  "function supply() view returns (uint256)",
]);

/** CreditScore `0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7`. Pure in (seed, paidAt). */
export const creditScoreAbi = parseAbi([
  "function scoreOf(bytes21 seed, uint64 paidAt) view returns (uint256)",
  "function traitsOf(bytes21 seed, uint64 paidAt) view returns (uint256 mask, uint256 active, uint256 occupied, uint256 eights, uint256 band)",
]);

/** ERC20 events of the coin and the balance token. */
export const erc20Abi = parseAbi(["event Transfer(address indexed from, address indexed to, uint256 value)"]);

/** Balance module read used by the snapshot. */
export const moduleAbi = parseAbi(["function available() view returns (uint256)"]);

export const multicall3Abi = parseAbi(["function getEthBalance(address a) view returns (uint256)"]);

export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;
export const CREDIT_SCORE = "0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7" as const;
