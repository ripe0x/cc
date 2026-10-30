// Every chain read the Ponder indexer makes with `context.client` goes through here. Reads are Effects (cached in the
// database, batched in the preload pass) and use Multicall3 on an archive RPC. A transport error is retried and never
// becomes a null: only a verified revert does.
import {
  createPublicClient,
  decodeFunctionResult,
  encodeFunctionData,
  http,
  parseAbi,
  type Abi,
  type Hex,
  type PublicClient,
} from "viem";
import { mainnet } from "viem/chains";
import { MULTICALL3 } from "./constants";

// Archive-capable public endpoints, fastest first. ENVIO_RPC_URL (comma-separated) replaces them. publicnode and 1rpc
// are left out: they refuse archive state.
const DEFAULT_RPC = [
  "https://mainnet.gateway.tenderly.co",
  "https://eth.drpc.org",
  "https://eth-mainnet.public.blastapi.io",
];
const urls = process.env.ENVIO_RPC_URL
  ? process.env.ENVIO_RPC_URL.split(",").map((u) => u.trim()).filter(Boolean)
  : DEFAULT_RPC;

const clients: PublicClient[] = urls.map(
  (url) => createPublicClient({ chain: mainnet, transport: http(url, { retryCount: 0, timeout: 60_000 }) }) as PublicClient,
);

const MAX_IN_FLIGHT = Number(process.env.ENVIO_RPC_CONCURRENCY ?? 6);
let inFlight = 0;
const waiting: (() => void)[] = [];
async function slot<T>(fn: () => Promise<T>): Promise<T> {
  if (inFlight >= MAX_IN_FLIGHT) await new Promise<void>((r) => waiting.push(r));
  inFlight++;
  try {
    return await fn();
  } finally {
    inFlight--;
    waiting.shift()?.();
  }
}

/** Milliseconds spent inside RPC requests, summed over concurrent requests, and the request count. */
export const rpcStats = { requests: 0, failures: 0, busyMs: 0, wallMs: 0 };
const perEndpoint = urls.map((u) => ({ host: new URL(u).hostname, requests: 0, failures: 0 }));
// wall-clock time with at least one request in flight (busyMs sums concurrent requests)
let active = 0;
let activeSince = 0;
const enter = () => { if (active++ === 0) activeSince = Date.now(); };
const leave = () => { if (--active === 0) rpcStats.wallMs += Date.now() - activeSince; };

// Progress line for the run notes: how much of the wall clock the indexer spent inside RPC requests.
if (process.env.ENVIO_RPC_STATS !== "false") {
  setInterval(() => {
    if (rpcStats.requests > 0)
      console.log(
        `[rpc] requests=${rpcStats.requests} failures=${rpcStats.failures} wall_s=${Math.round(rpcStats.wallMs / 1000)} busy_s=${Math.round(rpcStats.busyMs / 1000)} ` +
          perEndpoint.map((e) => `${e.host}=${e.requests}/${e.failures}`).join(" "),
      );
  }, 30_000).unref();
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Runs `fn` against each endpoint in turn; a thrown error moves on to the next one. After a full round it backs off
 * and starts again. Gives up after `attempts` rounds and throws, which stops the indexer instead of writing a wrong
 * value.
 */
export async function withRpc<T>(what: string, fn: (client: PublicClient) => Promise<T>, attempts = 8): Promise<T> {
  let delay = 500;
  let last: unknown;
  for (let round = 1; round <= attempts; round++) {
    for (const [i, client] of clients.entries()) {
      const t0 = Date.now();
      rpcStats.requests++;
      perEndpoint[i]!.requests++;
      try {
        return await slot(async () => {
          enter();
          try {
            return await fn(client);
          } finally {
            leave();
          }
        });
      } catch (e) {
        rpcStats.failures++;
        perEndpoint[i]!.failures++;
        last = e;
      } finally {
        rpcStats.busyMs += Date.now() - t0;
      }
    }
    console.warn(`RPC round ${round}/${attempts} failed for ${what}: ${String(last).split("\n")[0]?.slice(0, 160)}`);
    await sleep(delay);
    delay = Math.min(delay * 2, 20_000);
  }
  throw new Error(`${what} failed after ${attempts} rounds: ${String(last).split("\n")[0]}`);
}

const multicall3Abi = parseAbi([
  "struct Call3 { address target; bool allowFailure; bytes callData; }",
  "struct Result { bool success; bytes returnData; }",
  // Declared view (it is payable on-chain) so viem allows it in eth_call.
  "function aggregate3(Call3[] calls) view returns (Result[] returnData)",
]);

export type Call = { address: Hex; data: Hex };
export type Raw = { success: boolean; data: Hex };

export function enc<A extends Abi>(address: Hex, abi: A, functionName: string, args?: readonly unknown[]): Call {
  return { address, data: encodeFunctionData({ abi, functionName, args } as never) };
}

/** Decoded return value, or undefined when the call failed or its data does not decode. */
export function dec<T>(abi: Abi, functionName: string, r: Raw | undefined): T | undefined {
  if (!r?.success) return undefined;
  try {
    return decodeFunctionResult({ abi, functionName, data: r.data } as never) as T;
  } catch {
    return undefined;
  }
}

/** Revert, as opposed to a transport, rate-limit, gas-cap or non-archive error. */
function isRevert(e: unknown): boolean {
  for (let err = e as { cause?: unknown; name?: string; code?: number; message?: string } | undefined; err; err = err.cause as typeof err) {
    if (err.name === "ExecutionRevertedError" || err.name === "ContractFunctionRevertedError" || err.code === 3) return true;
    if (/execution reverted/i.test(err.message ?? "")) return true;
  }
  return false;
}

/**
 * One Multicall3 aggregate3 eth_call at `block` (latest when undefined). With `confirm`, every sub-call that reports
 * failure is repeated alone: a node's per-call gas cap makes big batches fail where the call itself works, and only an
 * actual revert may become a failure.
 */
export async function multicall(what: string, calls: Call[], block: bigint | undefined, confirm = false): Promise<Raw[]> {
  if (calls.length === 0) return [];
  const res = await withRpc(`${what}@${block ?? "latest"} (${calls.length} calls)`, (c) =>
    c.readContract({
      address: MULTICALL3,
      abi: multicall3Abi,
      functionName: "aggregate3",
      args: [calls.map((x) => ({ target: x.address, allowFailure: true, callData: x.data }))],
      blockNumber: block,
    }),
  );
  const out: Raw[] = res.map((r) => ({ success: r.success, data: r.returnData }));
  if (confirm) {
    for (let i = 0; i < out.length; i++) {
      if (out[i]!.success) continue;
      out[i] = await withRpc(`${what} recheck@${block ?? "latest"}`, async (c) => {
        try {
          const r = await c.call({ to: calls[i]!.address, data: calls[i]!.data, blockNumber: block });
          return { success: r.data !== undefined, data: (r.data ?? "0x") as Hex };
        } catch (e) {
          if (isRevert(e)) return { success: false, data: "0x" as Hex };
          throw e;
        }
      });
    }
  }
  return out;
}

export async function blockTimestampOf(block: bigint): Promise<bigint> {
  const b = await withRpc(`getBlock@${block}`, (c) => c.getBlock({ blockNumber: block }));
  return b.timestamp;
}

/** Collects calls made within `windowMs` and hands them to `run` together; `run` returns one result per key, in order. */
export class Batcher<K, V> {
  private queue: { key: K; resolve: (v: V) => void; reject: (e: unknown) => void }[] = [];
  private timer: ReturnType<typeof setTimeout> | undefined;
  constructor(
    private run: (keys: K[]) => Promise<V[]>,
    private windowMs = 40,
  ) {}
  get(key: K): Promise<V> {
    return new Promise((resolve, reject) => {
      this.queue.push({ key, resolve, reject });
      this.timer ??= setTimeout(() => void this.flush(), this.windowMs);
    });
  }
  private async flush() {
    this.timer = undefined;
    const batch = this.queue.splice(0);
    try {
      const out = await this.run(batch.map((b) => b.key));
      batch.forEach((b, i) => b.resolve(out[i] as V));
    } catch (e) {
      batch.forEach((b) => b.reject(e));
    }
  }
}

export function chunks<T>(xs: readonly T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < xs.length; i += size) out.push(xs.slice(i, i + size));
  return out;
}
