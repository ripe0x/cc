/** JSON counters retain exact raw committed units separately for every event-time token. */
export function addTokenCommitment(totals: Record<string, string>, token: string, committed: bigint): Record<string, string> {
  const key = token.toLowerCase();
  return { ...totals, [key]: (BigInt(totals[key] ?? "0") + committed).toString() };
}
