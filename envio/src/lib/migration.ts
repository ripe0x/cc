// The treasury migration's state transitions (src/adapters/Phase2BalanceTreasury.sol migrateTo and
// receiveMigration), as pure patches the handlers apply and a replay a test can drive without Ponder. The source's
// TreasuryMigrated empties its reserve, marks it migrated, names the successor and turns every switch off; the
// destination's MigrationReceived sets its reserve to the event's figure (its own reserve plus the import) and its
// epoch. A destination must already hold a row (its BalanceModuleSet at selection, decisions 252 and 253): a receipt
// before that throws, as the handler does.

export type Hex = `0x${string}`;

export type MigrationState = {
  claimReserve: bigint;
  configEpoch: bigint;
  migrated: boolean;
  successor: Hex | null;
  conversionEnabled: boolean;
  workingPaymentsEnabled: boolean;
  ccRedemptionEnabled: boolean;
};

export function migratedOutPatch(successor: string, configEpoch: bigint): Partial<MigrationState> {
  return {
    claimReserve: 0n,
    configEpoch,
    migrated: true,
    successor: successor.toLowerCase() as Hex,
    conversionEnabled: false,
    workingPaymentsEnabled: false,
    ccRedemptionEnabled: false,
  };
}

export function migrationReceivedPatch(claimReserve: bigint, configEpoch: bigint): Partial<MigrationState> {
  return { claimReserve, configEpoch };
}

export type MigrationEvent =
  | { name: "BalanceModuleSet"; treasury: string; claimReserve?: bigint }
  | { name: "TreasuryMigrated"; treasury: string; successor: string; moved: bigint; claimsImported: bigint; configEpoch: bigint }
  | { name: "MigrationReceived"; treasury: string; predecessor: string; claimsImported: bigint; claimReserve: bigint; configEpoch: bigint };

export function emptyState(claimReserve = 0n): MigrationState {
  return {
    claimReserve, configEpoch: 0n, migrated: false, successor: null,
    conversionEnabled: false, workingPaymentsEnabled: false, ccRedemptionEnabled: false,
  };
}

/** Replays the events in order over the rows, in the handlers' own semantics. Returns the rows after the replay. */
export function replayMigration(rows: Map<string, MigrationState>, events: MigrationEvent[]): Map<string, MigrationState> {
  const out = new Map(Array.from(rows, ([k, v]) => [k.toLowerCase(), { ...v }]));
  for (const e of events) {
    const id = e.treasury.toLowerCase();
    if (e.name === "BalanceModuleSet") {
      if (!out.has(id)) out.set(id, emptyState(e.claimReserve ?? 0n));
      continue;
    }
    const cur = out.get(id);
    if (!cur) throw new Error(`${e.name} from treasury ${id} before its BalanceModuleSet`);
    if (e.name === "TreasuryMigrated") {
      if (e.claimsImported > cur.claimReserve) throw new Error(`${e.name} imports more than the reserve held`);
      out.set(id, { ...cur, ...migratedOutPatch(e.successor, e.configEpoch) });
    } else {
      out.set(id, { ...cur, ...migrationReceivedPatch(e.claimReserve, e.configEpoch) });
    }
  }
  return out;
}
