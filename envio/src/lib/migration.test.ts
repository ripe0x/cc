import { assert } from "vitest";
import { test } from "vitest";
import { emptyState, migratedOutPatch, migrationReceivedPatch, replayMigration } from "./migration";

const A = "0x00000000000000000000000000000000000000aa";
const B = "0x00000000000000000000000000000000000000bb";

// promise: decision 253 a replay of a treasury migration leaves the source migrated with an empty reserve, every switch off and the successor named, and the destination at the event's reserve and epoch, with no claim counted twice
test("a migration replays into both rows", () => {
  const rows = new Map([[A, { ...emptyState(60n), configEpoch: 3n, conversionEnabled: true, workingPaymentsEnabled: true, ccRedemptionEnabled: false }]]);
  const after = replayMigration(rows, [
    { name: "BalanceModuleSet", treasury: B, claimReserve: 5n },
    { name: "TreasuryMigrated", treasury: A, successor: B, moved: 100n, claimsImported: 60n, configEpoch: 4n },
    { name: "MigrationReceived", treasury: B, predecessor: A, claimsImported: 60n, claimReserve: 65n, configEpoch: 1n },
  ]);
  assert.deepEqual(after.get(A), {
    claimReserve: 0n, configEpoch: 4n, migrated: true, successor: B,
    conversionEnabled: false, workingPaymentsEnabled: false, ccRedemptionEnabled: false,
  });
  assert.deepEqual(after.get(B), { ...emptyState(65n), configEpoch: 1n });
  assert.equal(after.get(A)!.claimReserve + after.get(B)!.claimReserve, 65n, "the claims moved once");
  assert.equal(rows.get(A)!.claimReserve, 60n, "the input rows are untouched");
});

// promise: decision 253 a receipt by a destination without its selection row, or a migration importing more than the source holds, fails loudly instead of inventing state
test("a receipt before selection and an over import throw", () => {
  const rows = new Map([[A, emptyState(60n)]]);
  assert.throws(
    () => replayMigration(rows, [{ name: "MigrationReceived", treasury: B, predecessor: A, claimsImported: 60n, claimReserve: 60n, configEpoch: 1n }]),
    /before its BalanceModuleSet/,
  );
  assert.throws(
    () => replayMigration(rows, [
      { name: "BalanceModuleSet", treasury: B },
      { name: "TreasuryMigrated", treasury: A, successor: B, moved: 100n, claimsImported: 61n, configEpoch: 4n },
    ]),
    /more than the reserve/,
  );
});

// promise: the handler patches are the replay's patches: the source patch empties and closes, the destination patch sets the reserve and the epoch only
test("the patches are what the handlers apply", () => {
  assert.deepEqual(migratedOutPatch(B.toUpperCase(), 9n), {
    claimReserve: 0n, configEpoch: 9n, migrated: true, successor: B,
    conversionEnabled: false, workingPaymentsEnabled: false, ccRedemptionEnabled: false,
  });
  assert.deepEqual(migrationReceivedPatch(65n, 1n), { claimReserve: 65n, configEpoch: 1n });
});
