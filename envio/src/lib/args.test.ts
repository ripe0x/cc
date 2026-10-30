import { assert, test } from "vitest";
import { viemArgs } from "./args";

// promise: log.args hold integers the way viem decodes them (48 bits or fewer as numbers), which is what Ponder stores
test("narrow integers become numbers, wide ones stay bigints", () => {
  const a = viemArgs("Treasury", "StatementConverted", { statementId: 7n, received: 2n, toProRata: 3n, contributionBps: 500n });
  assert.deepEqual(a, { statementId: 7n, received: 2n, toProRata: 3n, contributionBps: 500 });
});

test("overloaded events are told apart by their parameter names", () => {
  const phase2 = viemArgs("Treasury", "StatementConverted", { statementId: 1n, received: 2n, allocated: 3n, contributionBps: 4n, claimReserve: 5n });
  assert.deepEqual(Object.keys(phase2), ["statementId", "received", "allocated", "contributionBps", "claimReserve"]);
  const sw = viemArgs("Treasury", "SwitchesSet", { conversionEnabled: true, workingPaymentsEnabled: false });
  assert.deepEqual(sw, { conversionEnabled: true, workingPaymentsEnabled: false });
});

test("tuples and fixed arrays are converted member by member", () => {
  const ids = Array.from({ length: 80 }, (_, i) => BigInt(i));
  const composed = viemArgs("Core", "Composed", { sid: 1n, ids, format: 3n, cost: 9n, price: 10n, caller: "0x0000000000000000000000000000000000000001" });
  assert.strictEqual(composed.format, 3);
  assert.deepEqual(composed.ids, ids);
  const set = viemArgs("Core", "SettingsSet", { settings: { dropFloorBps: 100n, peakHalfLife: 7n, keeperFee: 5n, swapFeeCc: 2n } }).settings as Record<string, unknown>;
  assert.strictEqual(set.dropFloorBps, 100); // uint16
  assert.strictEqual(set.peakHalfLife, 7); // uint32
  assert.strictEqual(set.keeperFee, 5n); // uint64 is wider than 48 bits
  assert.strictEqual(set.swapFeeCc, 2n); // uint96
});

test("events of contracts without a decoder table pass through", () => {
  const p = { from: "0x1", to: "0x2", id: 5n };
  assert.equal(viemArgs("Credits", "Transfer", p), p);
});
