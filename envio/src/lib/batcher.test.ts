import { assert, test } from "vitest";
import { Batcher, chunks } from "./rpc";

// promise: reads asked for in the same preload window leave as one Multicall3, and each caller gets its own answer
test("calls made within the window run together and resolve in order", async () => {
  const seen: number[][] = [];
  const b = new Batcher<number, number>(async (keys) => {
    seen.push(keys);
    return keys.map((k) => k * 2);
  }, 10);
  const out = await Promise.all([1, 2, 3, 4].map((k) => b.get(k)));
  assert.deepEqual(out, [2, 4, 6, 8]);
  assert.deepEqual(seen, [[1, 2, 3, 4]]);
});

test("a failed batch rejects every caller instead of returning empty values", async () => {
  const b = new Batcher<number, number>(async () => {
    throw new Error("rpc down");
  }, 5);
  const results = await Promise.allSettled([b.get(1), b.get(2)]);
  assert.deepEqual(results.map((r) => r.status), ["rejected", "rejected"]);
});

test("chunks splits without dropping the tail", () => {
  assert.deepEqual(chunks([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
});
