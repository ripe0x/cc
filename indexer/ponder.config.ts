import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createConfig, factory } from "ponder";
import { getAbiItem, zeroAddress } from "viem";

import { controllerLogAbi } from "./abis/Controller";
import { coreAbi } from "./abis/Core";
import { creditsAbi, erc20Abi, statementsAbi, strategyAbi } from "./abis/external";
import { marketRedeemerAbi } from "./abis/MarketRedeemer";
import { treasuryLogAbi } from "./abis/Treasury";
import { guardedHttp, type Endpoint } from "./src/lib/rpc";
import { localRpc } from "./src/lib/rpc-selection";
import { sanitizedRpc, temporaryFallbackTransport, withFastFallback } from "./rpc-config";

// Every address and start block comes from the deployment record (deployments/<chainId>.json) with an
// environment variable of the same meaning taking precedence. A missing required value stops the start.

const RECORD_PATH = resolve(process.cwd(), process.env.DEPLOYMENT_RECORD ?? "../deployments/31337.json");
const record: Record<string, unknown> = existsSync(RECORD_PATH) ? JSON.parse(readFileSync(RECORD_PATH, "utf8")) : {};

const str = (env: string, key: string): string | undefined => process.env[env] || (record[key] as string | undefined);

function required(env: string, key: string): string {
  const v = str(env, key);
  if (!v) throw new Error(`${env} is not set and ${RECORD_PATH} has no "${key}". Refusing to start.`);
  return v;
}
const address = (env: string, key: string) => required(env, key).toLowerCase() as `0x${string}`;
const block = (env: string, key: string) => Number(required(env, key));

const CHAIN_ID = Number(required("CHAIN_ID", "chainId"));
if (record.chainId !== undefined && Number(record.chainId) !== CHAIN_ID) {
  throw new Error(`CHAIN_ID ${CHAIN_ID} does not match chainId ${String(record.chainId)} in ${RECORD_PATH}. Refusing to start.`);
}
const IS_LOCAL = CHAIN_ID === 31337;

const CORE = address("CORE_ADDRESS", "core");
const COIN = address("COIN_ADDRESS", "coin");
const CREDITS = address("CREDITS_ADDRESS", "credits");
const STATEMENTS = address("STATEMENTS_ADDRESS", "statements");
const DEPLOY_BLOCK = block("DEPLOY_BLOCK", "deployBlock");

// Collections index from their own deploy block on a real chain, so every token has an owner and facts. A local
// fork defaults to the Core deploy block; owners of older tokens are read with ownerOf when first seen.
function collectionStart(env: string): number {
  const v = process.env[env];
  if (v) return Number(v);
  if (CHAIN_ID === 1) throw new Error(`${env} is required on chain 1 (the collection deploy block). Refusing to start.`);
  return DEPLOY_BLOCK;
}
const CREDITS_START = collectionStart("CREDITS_START_BLOCK");
const STATEMENTS_START = collectionStart("STATEMENTS_START_BLOCK");

// CreditStrategy listings. The proxy was deployed at block 26037623 and has emitted about 100k events since, so a local
// fork reads a window of LOCAL_STRATEGY_WINDOW blocks before the Core deploy block (a fork proxies each historical
// getLogs to its upstream at about one request per second). Chain 1 requires the start block.
const LOCAL_STRATEGY_WINDOW = 60_000;
const STRATEGY = (process.env.STRATEGY_ADDRESS || "0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6").toLowerCase() as `0x${string}`;
function strategyStart(): number {
  if (process.env.STRATEGY_START_BLOCK) return Number(process.env.STRATEGY_START_BLOCK);
  if (CHAIN_ID === 1) throw new Error("STRATEGY_START_BLOCK is required on chain 1 (the CreditStrategy deploy block). Refusing to start.");
  return Math.max(0, DEPLOY_BLOCK - LOCAL_STRATEGY_WINDOW);
}
const STRATEGY_START = strategyStart();

// ---- Redeemer 2 (MarketRedeemer) ---------------------------------------------------------------------------
// Redeemer 2 is a static source: it has no Core event that creates it (the factory sources discover the v2 treasury
// and V3 controller, but not an adapter the owner registers), so its address comes from the phase 3 deployment
// record `<chainId>-phase3.json` (a sibling of the main record; DEPLOYMENT_RECORD_PHASE3 overrides the path). The
// record is operator-authored at deployment with `marketRedeemer` (the address), `treasuryV2` (the v2 treasury the
// redeemer is registered on, so its premium lands on the right `treasury:redeemer` row) and `deployBlock` (the start
// block). Env vars of the same meaning take precedence. When the record, the address or the treasury is absent the
// source is not configured: the handler is not registered and the indexer behaves exactly as today.
const PHASE3_PATH = resolve(process.cwd(), process.env.DEPLOYMENT_RECORD_PHASE3 ?? RECORD_PATH.replace(/\.json$/, "-phase3.json"));
const phase3: Record<string, unknown> = existsSync(PHASE3_PATH) ? JSON.parse(readFileSync(PHASE3_PATH, "utf8")) : {};
if (phase3.chainId !== undefined && Number(phase3.chainId) !== CHAIN_ID) {
  throw new Error(`CHAIN_ID ${CHAIN_ID} does not match chainId ${String(phase3.chainId)} in ${PHASE3_PATH}. Refusing to start.`);
}
const lower = (v: string | undefined) => (v ? (v.toLowerCase() as `0x${string}`) : undefined);
const marketAddr = lower(process.env.MARKET_REDEEMER_ADDRESS || (phase3.marketRedeemer as string | undefined));
const marketTreasury = lower(process.env.MARKET_REDEEMER_TREASURY || (phase3.treasuryV2 as string | undefined));
const marketBlock = process.env.MARKET_REDEEMER_START_BLOCK || (phase3.deployBlock as number | string | undefined);
export const MARKET_REDEEMER =
  marketAddr && marketTreasury && marketBlock !== undefined
    ? { address: marketAddr, treasury: marketTreasury, deployBlock: Number(marketBlock) }
    : undefined;

// ---- RPC ---------------------------------------------------------------------------------------------------

// Tenderly is always first; other public endpoints are fallback only. Caps are requests per second, overridable with
// RPC_RPS as a comma separated list in the same order.
const PUBLIC: Endpoint[] = [
  { url: "https://gateway.tenderly.co/public/mainnet", rps: 4 },
  { url: "https://eth-mainnet.public.blastapi.io", rps: 8 },
  { url: "https://1rpc.io/eth", rps: 5 },
  { url: "https://ethereum-rpc.publicnode.com", rps: 10 },
  { url: "https://eth.drpc.org", rps: 5 },
  { url: "https://rpc.mevblocker.io", rps: 5 },
];
const caps = (process.env.RPC_RPS ?? "").split(",").map((s) => Number(s.trim())).filter(Boolean);
const endpoints: Endpoint[] = PUBLIC.map((e, i) => ({ ...e, rps: caps[i] ?? e.rps }));
const reserveUrl = process.env.PONDER_RPC_URL_1?.trim();
const reserve = reserveUrl ? { url: reserveUrl, rps: Number(process.env.RPC_RPS_RESERVE ?? 10) } : undefined;

const localUrl = localRpc(CHAIN_ID, record.rpcUrl as string | undefined, process.env.RPC_URL?.trim());
if (IS_LOCAL && !localUrl) throw new Error("RPC_URL is not set and the record has no rpcUrl. Refusing to start.");
const selected = localUrl ? { endpoints, reserve } : withFastFallback(
  endpoints, reserve, process.env.RPC_FAST_FALLBACK_URL, process.env.RPC_RPS_FAST_FALLBACK,
  process.env.RPC_FAST_FALLBACK_MAX_CALLS, process.env.RPC_FAST_FALLBACK_UNTIL,
);
const rpc = localUrl ? guardedHttp(localUrl) : sanitizedRpc(temporaryFallbackTransport(selected));

// PGlite serves local development only. A real chain needs Postgres so the RPC cache and schemas outlive the machine.
if (!IS_LOCAL && !process.env.DATABASE_URL) throw new Error("DATABASE_URL is required on a real chain. Refusing to start.");
const database = process.env.DATABASE_URL
  ? ({ kind: "postgres", connectionString: process.env.DATABASE_URL } as const)
  : ({ kind: "pglite", directory: process.env.PONDER_DATABASE_DIR ?? ".ponder/pglite" } as const);

export const CORE_ADDRESS = CORE;
export const CORE_DEPLOY_BLOCK = BigInt(DEPLOY_BLOCK);
export const STRATEGY_ADDRESS = STRATEGY;
export const COLLECTIONS = { credits: CREDITS, statements: STATEMENTS } as const;

export default createConfig({
  database,
  chains: {
    chain: {
      id: CHAIN_ID,
      rpc,
      pollingInterval: Number(process.env.PONDER_POLL_INTERVAL_MS ?? (localUrl ? 1_000 : 12_000)),
      ethGetLogsBlockRange: Number(process.env.PONDER_ETH_GETLOGS_BLOCK_RANGE ?? 5_000),
      disableCache: Boolean(localUrl),
    },
  },
  contracts: {
    Core: { abi: coreAbi, chain: "chain", address: CORE, startBlock: DEPLOY_BLOCK },
    // Every controller named by ControllerSet, from the block of that event. The log ABI is the union of
    // ControllerV1 and ControllerV2 (abis/Controller.ts), so either version's events decode.
    Controller: {
      abi: controllerLogAbi,
      chain: "chain",
      address: factory({ address: CORE, event: getAbiItem({ abi: coreAbi, name: "ControllerSet" }), parameter: "controller" }),
      startBlock: DEPLOY_BLOCK,
    },
    // Every balance module named by BalanceModuleSet, from the block of that event, decoded with the union of the
    // phase 2 (Phase2BalanceTreasury) and phase 3 (BalanceTreasuryV2) ABIs, so both decode over the module's history
    // (phase 2 migrates to phase 3 through v1 migrateTo). A StatementBalanceModule emits none of these events, so its
    // registration is inert. No phase 3 deployment record is needed: the module is discovered here by its selection.
    Treasury: {
      abi: treasuryLogAbi,
      chain: "chain",
      address: factory({ address: CORE, event: getAbiItem({ abi: coreAbi, name: "BalanceModuleSet" }), parameter: "balanceModule" }),
      startBlock: DEPLOY_BLOCK,
    },
    Coin: { abi: erc20Abi, chain: "chain", address: COIN, startBlock: DEPLOY_BLOCK, filter: { event: "Transfer", args: { to: zeroAddress } } },
    Credits: { abi: creditsAbi, chain: "chain", address: CREDITS, startBlock: CREDITS_START },
    Statements: { abi: statementsAbi, chain: "chain", address: STATEMENTS, startBlock: STATEMENTS_START },
    Strategy: { abi: strategyAbi, chain: "chain", address: STRATEGY, startBlock: STRATEGY_START },
    // Redeemer 2. The key is always present so the handler name type-checks; when MARKET_REDEEMER is undefined the
    // placeholder address indexes nothing because src/index.ts registers the PremiumSet handler only when configured
    // (a source with no registered handler builds no log filter, so it adds no RPC).
    MarketRedeemer: {
      abi: marketRedeemerAbi,
      chain: "chain",
      address: MARKET_REDEEMER?.address ?? zeroAddress,
      startBlock: MARKET_REDEEMER?.deployBlock ?? DEPLOY_BLOCK,
    },
  },
  blocks: {
    Tick: { chain: "chain", startBlock: DEPLOY_BLOCK, interval: Number(process.env.SNAPSHOT_INTERVAL_BLOCKS ?? 300) },
  },
});
