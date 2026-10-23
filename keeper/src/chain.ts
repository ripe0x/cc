// The keeper's chain access: the read client over the rpc list (logging when a fallback answers), and the state of one
// block for the decisions: the shared snapshot plus the keeper's own reads, all pinned to the snapshot's block.

import { createPublicClient, fallback, http, zeroAddress, type Address, type PublicClient } from "viem";
import { readSnapshot, mc, type Snapshot } from "@cc/engine/snapshot";
import { controllerAbi, controllerV3Abi, coreAbi, erc20Abi, escrowAbi, factoryAbi, treasuryAbi } from "@cc/engine/abis";
import type { Config, SplitConfig } from "./config.ts";
import type { State } from "./decide.ts";
import { log } from "./log.ts";

// RPC_TIMEOUT_MS: per request read timeout, default 20 s; a local fork with a cold upstream needs more
function rpcTimeoutMs(): number {
  const v = Number(process.env.RPC_TIMEOUT_MS ?? 20_000);
  return Number.isFinite(v) && v > 0 ? v : 20_000;
}

export function readClient(cfg: Config): PublicClient {
  const transport = fallback(
    cfg.rpcUrls.map((u) => http(u, { timeout: rpcTimeoutMs(), retryCount: 1 })),
    { retryCount: 1 },
  );
  // cacheTime 0: every tick reads the head afresh. viem caches the block number for its polling interval by default,
  // and a tick right after a receipt would decide on the block before it and repeat the call it just made
  const client = createPublicClient({ transport, batch: { multicall: false }, cacheTime: 0 });
  const primary = cfg.rpcUrls[0];
  let lastNote = 0;
  (client.transport as any).onResponse?.(({ transport, status, method }: any) => {
    const url: string | undefined = transport?.value?.url ?? transport?.config?.url;
    if (status === "success" && url && url !== primary && Date.now() - lastNote > 60_000) {
      lastNote = Date.now();
      log("warn", "rpc fallback answered", { host: new URL(url).host, method });
    }
  });
  return client as PublicClient;
}

export interface Fixed {
  factory: Address;
  escrow: Address;
  owner: Address;
}

// the immutables and the owner, read once at start
export async function readFixed(client: PublicClient, core: Address): Promise<Fixed> {
  const c = { address: core, abi: coreAbi } as const;
  const [factory, escrow, owner] = await client.multicall({
    ...mc,
    allowFailure: false,
    contracts: [
      { ...c, functionName: "FACTORY" },
      { ...c, functionName: "ESCROW" },
      { ...c, functionName: "owner" },
    ] as const,
  });
  return { factory, escrow, owner };
}

export interface Read {
  state: State;
  snap: Snapshot;
}

// the module's conversionReady() at the block: true or false from a phase 2 treasury, undefined when no module is
// bound or the module does not answer the view (an older module). exported for the test of the fallback
export async function readConversionReady(
  client: Pick<PublicClient, "multicall">,
  balanceModule: Address,
  blockNumber?: bigint,
): Promise<boolean | undefined> {
  if (balanceModule === zeroAddress) return undefined;
  const [res] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: true,
    contracts: [{ address: balanceModule, abi: treasuryAbi, functionName: "conversionReady" }] as const,
  });
  return res.status === "success" ? (res.result as boolean) : undefined;
}

// the artist and operator split's holdings at the block, for the distributeSplit door: its ETH balance, and its balance
// of the Core's balance token when the BALANCE leg is on (minBalance set) and a token is bound. read tolerant: a failed
// read leaves the value undefined, which the decision skips with a reason, so a node fault never stalls the other
// doors. exported for the test of the fallback
export async function readSplitBalances(
  client: Pick<PublicClient, "getBalance" | "multicall">,
  split: Pick<SplitConfig, "address" | "minBalance">,
  balanceToken: Address,
  blockNumber?: bigint,
): Promise<{ eth?: bigint; balance?: bigint }> {
  const ethRead = client.getBalance({ address: split.address, blockNumber }).catch(() => undefined);
  const balanceRead =
    split.minBalance !== undefined && balanceToken !== zeroAddress
      ? client
          .multicall({
            ...mc,
            blockNumber,
            allowFailure: true,
            contracts: [{ address: balanceToken, abi: erc20Abi, functionName: "balanceOf", args: [split.address] }] as const,
          })
          .then(([r]) => (r.status === "success" ? (r.result as bigint) : undefined))
          .catch(() => undefined)
      : Promise.resolve(undefined);
  const [eth, balance] = await Promise.all([ethRead, balanceRead]);
  return { eth, balance };
}

// the ControllerV3 state the keeper's two new doors read, all from the controller at the block, read tolerantly: a
// ControllerV2 or V1 controller answers none of these, so `isV3` is false and both doors stay inert. `isV3` is probed
// through idleSince(), as the slice instructions require. exported for the test of the fallback
export interface ControllerV3State {
  isV3: boolean;
  idleKnown: boolean;
  ccPoolKeySet: boolean;
  ccReferencePrice: bigint;
  ccReferenceTime: bigint;
  ccMaxStale: bigint;
  ccMinSeconds: bigint;
  ccRateBpsPerHour: bigint;
  ccStepBps: bigint;
}

export async function readControllerV3(
  client: Pick<PublicClient, "multicall">,
  controller: Address,
  blockNumber?: bigint,
): Promise<ControllerV3State> {
  const k = { address: controller, abi: controllerV3Abi } as const;
  const [idle, poolKeySet, refPrice, refTime, quote] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: true,
    contracts: [
      { ...k, functionName: "idleSince" },
      { ...k, functionName: "ccPoolKeySet" },
      { ...k, functionName: "ccReferencePrice" },
      { ...k, functionName: "ccReferenceTime" },
      { ...k, functionName: "ccQuote" },
    ] as const,
  });
  // idleSince() answering is the V3 probe. known defaults false, but isV3 gates the door, so the loosening is never
  // overstated against a non-V3 controller
  const isV3 = idle.status === "success";
  const known = idle.status === "success" ? (idle.result as readonly [bigint, boolean])[1] : false;
  // ccQuote(): rateBpsPerHour, stepBps, maxStale, minSeconds, avgSeconds, minLiquidity (src/interfaces/Interfaces.sol)
  const q = quote.status === "success" ? (quote.result as readonly [number, number, number, number, number, bigint]) : undefined;
  return {
    isV3,
    idleKnown: known,
    ccPoolKeySet: poolKeySet.status === "success" ? (poolKeySet.result as boolean) : false,
    ccReferencePrice: refPrice.status === "success" ? (refPrice.result as bigint) : 0n,
    ccReferenceTime: refTime.status === "success" ? BigInt(refTime.result as bigint | number) : 0n,
    ccMaxStale: q ? BigInt(q[2]) : 0n,
    ccMinSeconds: q ? BigInt(q[3]) : 0n,
    ccRateBpsPerHour: q ? BigInt(q[0]) : 0n,
    ccStepBps: q ? BigInt(q[1]) : 0n,
  };
}

export async function readState(client: PublicClient, core: Address, fixed: Fixed, split?: SplitConfig): Promise<Read> {
  const snap = await readSnapshot(client, core);
  if (!snap.pinned || snap.blockNumber === undefined) throw new Error("the node refused a pinned read");
  const blockNumber = snap.blockNumber;
  // the factory reverts NotFound for a coin it has not launched: launchedAt is 0 until the launch is recorded
  const infoRead = client
    .readContract({ address: fixed.factory, abi: factoryAbi, functionName: "deploymentInfo", args: [snap.coin], blockNumber })
    .catch(() => undefined);
  const [block, extra, info] = await Promise.all([
    client.getBlock({ blockNumber }),
    client.multicall({
      ...mc,
      blockNumber,
      allowFailure: false,
      contracts: [
        { address: core, abi: coreAbi, functionName: "lastBuybackBlock" },
        { address: fixed.escrow, abi: escrowAbi, functionName: "balances", args: [core, zeroAddress] },
        { address: core, abi: coreAbi, functionName: "spendState" },
      ] as const,
    }),
    infoRead,
  ]);
  const [lastBuybackBlock, escrowBalance, spendState] = extra;
  // controller.atFloor per held statement, read only when a redemption could be decided
  const held = snap.held.map(BigInt);
  const floors = held.length
    ? await client.multicall({
        ...mc,
        blockNumber,
        allowFailure: true,
        contracts: held.map((sid) => ({ address: snap.controller, abi: controllerAbi, functionName: "atFloor", args: [sid] }) as const),
      })
    : [];
  // the phase 2 treasury's conversionReady(), read tolerant: a module without the view (StatementBalanceModule) leaves
  // it undefined, which the decision treats as ready
  const [conversionReady, splitBalances, v3] = await Promise.all([
    readConversionReady(client, snap.balanceModule, blockNumber),
    split ? readSplitBalances(client, split, snap.balanceToken, blockNumber) : Promise.resolve(undefined),
    readControllerV3(client, snap.controller, blockNumber),
  ]);
  const st = snap.settings;
  const state: State = {
    core,
    blockNumber,
    timestamp: block.timestamp,
    baseFee: block.baseFeePerGas ?? 0n,
    settings: {
      buybackSlice: st.buybackSlice,
      buybackDelay: st.buybackDelay,
      keeperFee: st.keeperFee,
      keeperMaxBaseFee: BigInt(st.keeperMaxBaseFee),
      callerFee: st.callerFee,
      callerMaxBaseFee: BigInt(st.callerMaxBaseFee),
      redeemOn: st.redeemOn,
      spendCapBps: st.spendCapBps,
      bucketSeconds: st.bucketSeconds,
      buyToArtistBps: st.buyToArtistBps,
    },
    spend: { bucket: spendState[0], budget: spendState[1], spent: spendState[2] },
    ethPot: snap.ethPot,
    potWithPending: snap.potWithPending,
    reserve: snap.reserve,
    potRoom: snap.potRoom,
    pendingIncome: snap.pendingIncome,
    lastBookAt: 0n,
    ethToBuyback: snap.ethToBuyback,
    payeeOn: snap.payeeOn,
    paused: snap.paused,
    retired: snap.retired,
    lastBuybackBlock,
    sniperSeconds: BigInt(st.sniperSeconds),
    launchedAt: BigInt(info?.launchedAt ?? 0),
    escrowBalance,
    pageReady: snap.page.ready,
    balanceModule: snap.balanceModule,
    conversionReady,
    statementRedeemDelaySeconds: snap.statementRedeemDelaySeconds,
    atFloor: held.filter((_, i) => floors[i]?.status === "success" && floors[i].result === true),
    controller: snap.controller,
    valueModeOn: snap.value.on,
    noQuote: snap.noQuote,
    referencePrice: snap.value.referencePrice ?? 0n,
    referenceTime: BigInt(snap.value.referenceTime ?? 0),
    referenceMaxStale: BigInt(snap.value.quote?.referenceMaxStale ?? 0),
    referenceMinSeconds: BigInt(snap.value.quote?.referenceMinSeconds ?? 0),
    referenceRateBpsPerHour: BigInt(snap.value.quote?.referenceRateBpsPerHour ?? 0),
    referenceStepBps: BigInt(snap.value.quote?.referenceStepBps ?? 0),
    spot: snap.value.spot ?? 0n,
    // ControllerV3 reads; lastSyncFillBlock is carried by the Keeper, defaulted here and set in main.tick
    isV3: v3.isV3,
    idleKnown: v3.idleKnown,
    lastSyncFillBlock: 0n,
    ccPoolKeySet: v3.ccPoolKeySet,
    ccReferencePrice: v3.ccReferencePrice,
    ccReferenceTime: v3.ccReferenceTime,
    ccMaxStale: v3.ccMaxStale,
    ccMinSeconds: v3.ccMinSeconds,
    ccRateBpsPerHour: v3.ccRateBpsPerHour,
    ccStepBps: v3.ccStepBps,
    balanceToken: snap.balanceToken,
    splitEth: splitBalances?.eth,
    splitBalance: splitBalances?.balance,
  };
  return { state, snap };
}
