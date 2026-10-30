export const BPS = 10_000n;

/** Pot share of a statement sale: the payment minus the artist, operator and buyback shares. */
export function statementPot(price: bigint, toArtist: bigint, toOperator: bigint, toBuyback: bigint): bigint {
  return price - toArtist - toOperator - toBuyback;
}

export type CreditSaleSplit = { toPot: bigint; toBuyback: bigint };

/**
 * Pot and buyback shares of a credit sale (Core.sellCreditTo). The pot gets the credit's cost basis times
 * `costToPotBps`, capped at the payment left after the artist and operator cuts. The buyback gets the rest.
 */
export function creditSaleSplit(
  price: bigint,
  costBasis: bigint,
  toArtist: bigint,
  toOperator: bigint,
  costToPotBps: bigint,
): CreditSaleSplit {
  const rest = price - toArtist - toOperator;
  const share = (costBasis * costToPotBps) / BPS;
  const toPot = share < rest ? share : rest;
  return { toPot, toBuyback: rest - toPot };
}
