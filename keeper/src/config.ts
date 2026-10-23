// The keeper's configuration: every value comes from the environment, parsed once at start. The keystore and its
// password file are paths, and the OpenSea key and the alert webhook are read from the shell environment and kept out
// of the logs.

import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress, parseEther, parseGwei, type Address } from "viem";

export type Door = "buyListing" | "buyback" | "compose" | "collectEscrow" | "book" | "redeemStatement" | "refreshReference" | "syncFill" | "refreshCcReference" | "distributeSplit";
export const DOORS: readonly Door[] = ["buyListing", "buyback", "compose", "collectEscrow", "book", "redeemStatement", "refreshReference", "syncFill", "refreshCcReference", "distributeSplit"];

// the owner key never signs a keeper transaction (decision 57)
export const OWNER: Address = "0xCB43078C32423F5348Cab5885911C3B5faE217F9";

// launch default relays (decision 139): MEV Blocker first, Flashbots Protect as the fallback
export const DEFAULT_RELAYS = ["https://rpc.mevblocker.io", "https://rpc.flashbots.net/fast"];
// public mainnet read fallbacks behind RPC_URLS (docs/RUNBOOK.md section 0 and .env.example list archive capable ones)
export const PUBLIC_RPCS = ["https://mainnet.gateway.tenderly.co", "https://eth.drpc.org", "https://ethereum-rpc.publicnode.com"];

export interface Deployment {
  chainId: number;
  core: Address;
  controller: Address;
  seaportAdapter: Address;
  strategyAdapter: Address;
  deployBlock?: number;
}

export interface DoorPolicy {
  // the most base fee the keeper sends at; the transaction's maxFeePerGas is this plus the tip
  maxBaseFee: bigint;
  // the priority fee the keeper pays
  tip: bigint;
}

// the artist and operator split (a Splits v2 push split at the Core's `artist`): the stored configuration the
// `distribute` call must restate, and the balances at which the keeper distributes. the split pays nobody until
// someone calls `distribute`; the keeper does, in ETH at `minEth` and, when `minBalance` is set, in the Core's live
// balance token at `minBalance`
export interface SplitConfig {
  address: Address;
  recipients: Address[];
  allocations: bigint[];
  totalAllocation: bigint;
  distributionIncentive: number;
  minEth: bigint;
  // undefined: the BALANCE leg is off
  minBalance?: bigint;
}

export interface Config {
  rpcUrls: string[];
  relayUrls: string[];
  record: Deployment;
  signer:
    | { kind: "keystore"; path: string; passwordFile: string }
    | { kind: "impersonate"; address: Address }
    | { kind: "address"; address: Address };
  dryRun: boolean;
  doors: Record<Door, DoorPolicy>;
  // the margin every paid door must clear above its own gas cost, wei
  margin: bigint;
  // the gross gas spend allowed per UTC day, wei
  dailyBudget: bigint;
  // a listing must be seen sweepable this long before the keeper sweeps it (decision 137)
  listingDelaySec: number;
  // pending income above this, wei, and a last book older than bookMinSec, make the keeper book a latched Core
  bookMinWei: bigint;
  bookMinSec: number;
  // the refreshReference door, which calls the controller's unpaid refreshReference() directly: the spot-to-reference
  // drift (bps) that counts, how long it must persist, and the ceiling on the keeper's own gas for the call
  refresh: { driftBps: number; persistSec: number; maxCostEth: bigint };
  tickMs: number;
  breakerThreshold: number;
  breakerPauseSec: number;
  receiptTimeoutSec: number;
  stateDir: string;
  alertWebhook?: string;
  // ETH balance under which the keeper alerts
  lowBalance: bigint;
  strategy: { mode: "tokensOf" } | { mode: "ids"; ids: bigint[] } | { mode: "off" };
  strategyRefreshSec: number;
  // every strategy refresh reads the whole inventory (first start, or a node that serves no log queries)
  strategyFullRead: boolean;
  // GraphQL endpoint of the indexer, used to seed the strategy inventory on the first start
  indexerUrl?: string;
  opensea: { key?: string; refreshSec: number; sign: number; file?: string };
  doorsOn: Set<Door>;
  // the read-only market view server (./market-view.ts); off without MARKET_VIEW_PORT
  marketView: { port?: number; host: string; token?: string };
  // the distributeSplit door's split; undefined (SPLIT_ADDRESS unset or zero) leaves the door off
  split?: SplitConfig;
}

type Env = { [k: string]: string | undefined };

const list = (v: string | undefined) => (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);
const num = (env: Env, k: string, d: number) => {
  const v = env[k];
  if (v === undefined || v === "") return d;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) throw new Error(`config: ${k} must be a non negative number`);
  return n;
};
const gwei = (env: Env, k: string, d: string) => parseGwei(env[k] || d);
const ether = (env: Env, k: string, d: string) => parseEther(env[k] || d);

// the nearest ancestor of `from` that holds a .git entry (a directory, or the file of a git worktree)
function repoRoot(from: string): string | undefined {
  for (let d = resolve(from); ; d = dirname(d)) {
    if (existsSync(join(d, ".git"))) return d;
    if (dirname(d) === d) return undefined;
  }
}

// whether a path resolves inside the repository working tree of the process directory or of this package
export function insideRepo(path: string, cwd: string = process.cwd()): boolean {
  const abs = resolve(cwd, path);
  let real = abs;
  try {
    real = realpathSync(abs);
  } catch {}
  return [cwd, dirname(fileURLToPath(import.meta.url))].some((from) => {
    const root = repoRoot(from);
    return root !== undefined && (real === root || real.startsWith(root + sep));
  });
}

const isLocal = (url: string) => /^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:|\/|$)/.test(url);

// INDEXER_URL: the indexer origin, https unless local; the GraphQL path is appended
function indexerUrl(v: string | undefined): string | undefined {
  if (!v) return undefined;
  if (!/^https:\/\//.test(v) && !isLocal(v)) throw new Error("config: INDEXER_URL must be https or a local address");
  return `${v.replace(/\/+$/, "")}/graphql`;
}

// the deployment record of docs/RUNBOOK.md section 7 (`deployments/<chainId>.json`)
export function readRecord(path: string): Deployment {
  const r = JSON.parse(readFileSync(path, "utf8"));
  for (const k of ["core", "controller", "seaportAdapter", "strategyAdapter"]) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(r[k] ?? "")) throw new Error(`config: record ${path} has no ${k}`);
  }
  return {
    chainId: Number(r.chainId),
    core: getAddress(r.core),
    controller: getAddress(r.controller),
    seaportAdapter: getAddress(r.seaportAdapter),
    strategyAdapter: getAddress(r.strategyAdapter),
    deployBlock: r.deployBlock === undefined ? undefined : Number(r.deployBlock),
  };
}

// launch defaults per door: the paid keeper doors at the 5 gwei `keeperMaxBaseFee`, compose and redeem at the 3 gwei
// `callerMaxBaseFee` (decision 138), the unpaid doors at 3 gwei. a door never sends above its ceiling
// the default tips: compose spends about 8.5 million gas, so its 0.0003 eth `callerFee` covers a tip of at most about
// 0.035 gwei; the other doors use under 1.5 million gas
const DOOR_DEFAULT_TIP: { [d in Door]: string } = {
  buyListing: "0.05",
  buyback: "0.05",
  compose: "0.02",
  collectEscrow: "0.05",
  book: "0.05",
  redeemStatement: "0.05",
  refreshReference: "0.05",
  syncFill: "0.05",
  refreshCcReference: "0.05",
  distributeSplit: "0.05",
};

const DOOR_DEFAULT_BASEFEE: { [d in Door]: string } = {
  buyListing: "5",
  buyback: "5",
  compose: "3",
  collectEscrow: "3",
  book: "3",
  redeemStatement: "3",
  refreshReference: "3",
  syncFill: "3",
  refreshCcReference: "3",
  distributeSplit: "3",
};

const isAddress = (v: string) => /^0x[0-9a-fA-F]{40}$/.test(v);
const isUint = (v: string) => /^\d+$/.test(v);

// SPLIT_ADDRESS and its companions (docs/RUNBOOK.md section 8): undefined when the address is unset or zero. every
// other value is checked here, since a mismatch with the split's stored hash reverts every distribute
export function splitConfig(env: Env): SplitConfig | undefined {
  const raw = env.SPLIT_ADDRESS;
  if (!raw || /^0x0{40}$/i.test(raw)) return undefined;
  if (!isAddress(raw)) throw new Error("config: SPLIT_ADDRESS must be an address");
  const recipientsRaw = list(env.SPLIT_RECIPIENTS);
  const allocationsRaw = list(env.SPLIT_ALLOCATIONS);
  if (recipientsRaw.length === 0) throw new Error("config: SPLIT_RECIPIENTS is empty");
  for (const r of recipientsRaw) if (!isAddress(r)) throw new Error(`config: SPLIT_RECIPIENTS holds a non address ${r}`);
  for (const a of allocationsRaw) if (!isUint(a)) throw new Error(`config: SPLIT_ALLOCATIONS holds a non integer ${a}`);
  if (recipientsRaw.length !== allocationsRaw.length) {
    throw new Error(`config: SPLIT_RECIPIENTS has ${recipientsRaw.length} entries, SPLIT_ALLOCATIONS ${allocationsRaw.length}`);
  }
  const allocations = allocationsRaw.map(BigInt);
  const sum = allocations.reduce((a, b) => a + b, 0n);
  if (env.SPLIT_TOTAL_ALLOCATION !== undefined && env.SPLIT_TOTAL_ALLOCATION !== "" && !isUint(env.SPLIT_TOTAL_ALLOCATION)) {
    throw new Error("config: SPLIT_TOTAL_ALLOCATION must be an integer");
  }
  const totalAllocation = env.SPLIT_TOTAL_ALLOCATION ? BigInt(env.SPLIT_TOTAL_ALLOCATION) : sum;
  if (totalAllocation !== sum) throw new Error(`config: SPLIT_ALLOCATIONS sum to ${sum}, SPLIT_TOTAL_ALLOCATION is ${totalAllocation}`);
  if (totalAllocation === 0n) throw new Error("config: SPLIT_TOTAL_ALLOCATION is 0");
  const incentiveRaw = env.SPLIT_DISTRIBUTION_INCENTIVE || "0";
  if (!isUint(incentiveRaw) || Number(incentiveRaw) > 65535) throw new Error("config: SPLIT_DISTRIBUTION_INCENTIVE must be an integer at most 65535");
  const minBalance = env.SPLIT_MIN_BALANCE ? parseEther(env.SPLIT_MIN_BALANCE) : undefined;
  return {
    address: getAddress(raw),
    recipients: recipientsRaw.map((r) => getAddress(r)),
    allocations,
    totalAllocation,
    distributionIncentive: Number(incentiveRaw),
    minEth: ether(env, "SPLIT_MIN_ETH", "0.25"),
    // the balance token has 18 decimals (docs/RUNBOOK.md, phase 2 stage A), so whole tokens parse like ether
    minBalance,
  };
}

export function loadConfig(env: Env, readRec: (p: string) => Deployment = readRecord): Config {
  const recordPath = env.RECORD ?? `deployments/${env.CHAIN_ID ?? "1"}.json`;
  const record = readRec(recordPath);
  const rpcUrls = list(env.RPC_URLS);
  if (record.chainId === 1 && !rpcUrls.every(isLocal)) {
    // mainnet: the listed rpcs first, then the public fallbacks, at least two in all
    for (const u of PUBLIC_RPCS) if (!rpcUrls.includes(u)) rpcUrls.push(u);
  }
  if (rpcUrls.length === 0) throw new Error("config: RPC_URLS is empty");
  const local = rpcUrls.every(isLocal);
  if (!local && rpcUrls.length < 3) throw new Error("config: a live chain needs RPC_URLS plus at least two public fallbacks");

  const relayUrls = env.RELAY_URLS === undefined ? (local ? [] : DEFAULT_RELAYS) : list(env.RELAY_URLS);
  if (!local && relayUrls.length === 0) throw new Error("config: a live chain sends only through a private relay (RELAY_URLS)");

  let signer: Config["signer"];
  if (env.IMPERSONATE) {
    // an anvil node signs for an impersonated account; refused anywhere but a local node
    if (!local) throw new Error("config: IMPERSONATE is for a local anvil node only");
    signer = { kind: "impersonate", address: getAddress(env.IMPERSONATE) };
  } else if (env.KEYSTORE) {
    if (!env.KEYSTORE_PASSWORD_FILE) throw new Error("config: KEYSTORE needs KEYSTORE_PASSWORD_FILE");
    for (const [k, v] of [["KEYSTORE", env.KEYSTORE], ["KEYSTORE_PASSWORD_FILE", env.KEYSTORE_PASSWORD_FILE]]) {
      if (insideRepo(v)) throw new Error(`config: ${k} resolves inside the repository working tree; keep key material outside it`);
    }
    signer = { kind: "keystore", path: env.KEYSTORE, passwordFile: env.KEYSTORE_PASSWORD_FILE };
  } else if (env.KEEPER_ADDRESS && env.DRY_RUN === "1") {
    // a dry run simulates from the keeper address without a key
    signer = { kind: "address", address: getAddress(env.KEEPER_ADDRESS) };
  } else {
    throw new Error("config: set KEYSTORE and KEYSTORE_PASSWORD_FILE (or KEEPER_ADDRESS with DRY_RUN=1)");
  }

  const doors = {} as Config["doors"];
  for (const d of DOORS) {
    const K = d.replace(/[A-Z]/g, (c) => "_" + c).toUpperCase();
    doors[d] = {
      maxBaseFee: gwei(env, `MAX_BASEFEE_GWEI_${K}`, env.MAX_BASEFEE_GWEI || DOOR_DEFAULT_BASEFEE[d]),
      tip: gwei(env, `MAX_PRIORITY_GWEI_${K}`, env.MAX_PRIORITY_GWEI || DOOR_DEFAULT_TIP[d]),
    };
  }

  const strategy: Config["strategy"] =
    env.STRATEGY_IDS === "off"
      ? { mode: "off" }
      : env.STRATEGY_IDS
        ? { mode: "ids", ids: list(env.STRATEGY_IDS).map(BigInt) }
        : { mode: "tokensOf" };

  const doorsOn = new Set<Door>(env.DOORS ? (list(env.DOORS) as Door[]) : DOORS);
  for (const d of doorsOn) if (!DOORS.includes(d)) throw new Error(`config: unknown door ${d}`);
  // the split door needs a split: without SPLIT_ADDRESS the default door set drops it, an explicit DOORS entry refuses
  const split = splitConfig(env);
  if (!split) {
    if (env.DOORS && doorsOn.has("distributeSplit")) throw new Error("config: DOORS names distributeSplit but SPLIT_ADDRESS is unset");
    doorsOn.delete("distributeSplit");
  }

  return {
    rpcUrls,
    relayUrls,
    record,
    signer,
    dryRun: env.DRY_RUN === "1",
    doors,
    margin: ether(env, "MARGIN_ETH", "0.00005"),
    dailyBudget: ether(env, "DAILY_BUDGET_ETH", "0.2"),
    listingDelaySec: num(env, "LISTING_DELAY_SEC", 120),
    bookMinWei: ether(env, "BOOK_MIN_ETH", "0.01"),
    bookMinSec: num(env, "BOOK_MIN_SEC", 600),
    refresh: {
      driftBps: num(env, "REFRESH_DRIFT_BPS", 300),
      persistSec: num(env, "REFRESH_PERSIST_SEC", 600),
      maxCostEth: ether(env, "REFRESH_MAX_COST_ETH", "0.00005"),
    },
    tickMs: num(env, "TICK_MS", 12_000),
    breakerThreshold: num(env, "BREAKER_THRESHOLD", 3),
    breakerPauseSec: num(env, "BREAKER_PAUSE_SEC", 3600),
    receiptTimeoutSec: num(env, "RECEIPT_TIMEOUT_SEC", 300),
    stateDir: env.STATE_DIR ?? "keeper/.state",
    alertWebhook: env.ALERT_WEBHOOK_URL || undefined,
    lowBalance: ether(env, "LOW_BALANCE_ETH", "0.05"),
    strategy,
    strategyRefreshSec: num(env, "STRATEGY_REFRESH_SEC", 600),
    strategyFullRead: env.STRATEGY_FULL_READ === "1",
    indexerUrl: indexerUrl(env.INDEXER_URL),
    opensea: {
      key: env.OPENSEA_API_KEY || undefined,
      refreshSec: num(env, "OPENSEA_REFRESH_SEC", 300),
      sign: num(env, "OPENSEA_SIGN", 40),
      file: env.SEAPORT_ORDERS || undefined,
    },
    doorsOn,
    marketView: {
      port: marketViewPort(env.MARKET_VIEW_PORT),
      host: env.MARKET_VIEW_HOST || "0.0.0.0",
      token: env.MARKET_VIEW_TOKEN || undefined,
    },
    split,
  };
}

// MARKET_VIEW_PORT: a TCP port, or unset for no view server
function marketViewPort(v: string | undefined): number | undefined {
  if (v === undefined || v === "") return undefined;
  if (!/^\d{1,5}$/.test(v) || Number(v) < 1 || Number(v) > 65535) throw new Error("config: MARKET_VIEW_PORT must be a port number");
  return Number(v);
}

// the config as logged at start: secrets and secret paths reduced to whether they are set
export function describe(c: Config) {
  return {
    chainId: c.record.chainId,
    core: c.record.core,
    rpcs: c.rpcUrls.length,
    relays: c.relayUrls.map((u) => new URL(u).host),
    signer: c.signer.kind,
    dryRun: c.dryRun,
    doors: Object.fromEntries(
      Object.entries(c.doors).map(([d, p]) => [d, { maxBaseFeeGwei: Number(p.maxBaseFee) / 1e9, tipGwei: Number(p.tip) / 1e9 }]),
    ),
    doorsOn: [...c.doorsOn],
    marginEth: Number(c.margin) / 1e18,
    dailyBudgetEth: Number(c.dailyBudget) / 1e18,
    listingDelaySec: c.listingDelaySec,
    bookMinEth: Number(c.bookMinWei) / 1e18,
    bookMinSec: c.bookMinSec,
    refresh: { driftBps: c.refresh.driftBps, persistSec: c.refresh.persistSec, maxCostEth: Number(c.refresh.maxCostEth) / 1e18 },
    strategy: c.strategy.mode,
    strategyFullRead: c.strategyFullRead,
    indexer: Boolean(c.indexerUrl),
    opensea: c.opensea.file ? "file" : c.opensea.key ? "api" : "off",
    alerts: Boolean(c.alertWebhook),
    marketView: c.marketView.port ? { host: c.marketView.host, port: c.marketView.port, token: Boolean(c.marketView.token) } : "off",
    split: c.split
      ? {
          address: c.split.address,
          recipients: c.split.recipients.length,
          incentive: c.split.distributionIncentive,
          minEth: Number(c.split.minEth) / 1e18,
          minBalance: c.split.minBalance === undefined ? "off" : Number(c.split.minBalance) / 1e18,
        }
      : "off",
  };
}
