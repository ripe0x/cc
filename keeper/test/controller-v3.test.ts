// promise: the keeper probes ControllerV3 through idleSince(), tolerantly, so a ControllerV2 or V1 controller reads as
// not V3 with every field defaulted (the two V3 doors stay inert), while a V3 controller's idle and CC reference state
// is mapped from the controller's own getters at the pinned block.
import assert from "node:assert/strict";
import test from "node:test";
import { type Address, type PublicClient } from "viem";
import { readControllerV3 } from "../src/chain.ts";

const controller = "0x00000000000000000000000000000000000000c3" as Address;

type Result = { status: "success"; result: unknown } | { status: "failure"; error: Error };

// a multicall mock keyed by function name, so a V2 controller can fail only the V3-only reads it does not expose
function client(answers: Record<string, Result>) {
  const calls: { functionName: string; address: Address; blockNumber?: bigint }[] = [];
  const c = {
    multicall: async ({ contracts, allowFailure, blockNumber }: { contracts: readonly { functionName: string; address: Address }[]; allowFailure?: boolean; blockNumber?: bigint }) => {
      assert.equal(allowFailure, true, "the V3 probe always tolerates failure");
      for (const call of contracts) calls.push({ functionName: call.functionName, address: call.address, blockNumber });
      return contracts.map((call) => answers[call.functionName] ?? { status: "failure", error: new Error(`no mock for ${call.functionName}`) });
    },
  } as unknown as Pick<PublicClient, "multicall">;
  return { c, calls };
}

const fail: Result = { status: "failure", error: new Error("function selector not recognized") };

test("readControllerV3: a non-V3 controller reads as inert, pinned to the block", async () => {
  // idleSince() reverts on V2/V1, so every read fails
  const { c, calls } = client({ idleSince: fail, ccPoolKeySet: fail, ccReferencePrice: fail, ccReferenceTime: fail, ccQuote: fail });
  const v3 = await readControllerV3(c, controller, 42n);
  assert.deepEqual(v3, {
    isV3: false,
    idleKnown: false,
    ccPoolKeySet: false,
    ccReferencePrice: 0n,
    ccReferenceTime: 0n,
    ccMaxStale: 0n,
    ccMinSeconds: 0n,
    ccRateBpsPerHour: 0n,
    ccStepBps: 0n,
  });
  assert.ok(calls.every((x) => x.address === controller && x.blockNumber === 42n), "every read hits the controller at the pinned block");
  assert.ok(calls.some((x) => x.functionName === "idleSince"), "the V3 probe is idleSince");
});

test("readControllerV3: a V3 controller maps idle known and the CC reference and quote", async () => {
  const { c } = client({
    idleSince: { status: "success", result: [1_700_000_000n, false] },
    ccPoolKeySet: { status: "success", result: true },
    ccReferencePrice: { status: "success", result: 400_000_000_000_000n },
    ccReferenceTime: { status: "success", result: 1_700_000_500 },
    // ccQuote(): rateBpsPerHour, stepBps, maxStale, minSeconds, avgSeconds, minLiquidity
    ccQuote: { status: "success", result: [1_200, 200, 600, 300, 1_800, 5_000_000_000_000_000_000n] },
  });
  const v3 = await readControllerV3(c, controller, 7n);
  assert.deepEqual(v3, {
    isV3: true,
    idleKnown: false,
    ccPoolKeySet: true,
    ccReferencePrice: 400_000_000_000_000n,
    ccReferenceTime: 1_700_000_500n,
    ccMaxStale: 600n,
    ccMinSeconds: 300n,
    ccRateBpsPerHour: 1_200n,
    ccStepBps: 200n,
  });
});

test("readControllerV3: a V3 controller with a known hint and no CC pool key reads idleKnown true", async () => {
  const { c } = client({
    idleSince: { status: "success", result: [1_700_000_000n, true] },
    ccPoolKeySet: { status: "success", result: false },
    ccReferencePrice: { status: "success", result: 0n },
    ccReferenceTime: { status: "success", result: 0 },
    ccQuote: { status: "success", result: [0, 0, 0, 0, 1, 0n] },
  });
  const v3 = await readControllerV3(c, controller, 7n);
  assert.equal(v3.isV3, true);
  assert.equal(v3.idleKnown, true);
  assert.equal(v3.ccPoolKeySet, false);
});
