import { assert } from "vitest";
import { test } from "vitest";
import { creditSaleSplit, statementPot } from "./split";

// promise: the credit sale split matches Core.sellCreditTo
test("credit sale pot share is cost times bps", () => {
  const s = creditSaleSplit(1000n, 800n, 50n, 50n, 5000n);
  assert.deepEqual(s, { toPot: 400n, toBuyback: 500n });
});

test("credit sale pot share is capped at the payment after the cuts", () => {
  const s = creditSaleSplit(1000n, 2000n, 100n, 100n, 10000n);
  assert.deepEqual(s, { toPot: 800n, toBuyback: 0n });
});

test("credit sale with zero bps sends the rest to the buyback", () => {
  assert.deepEqual(creditSaleSplit(1000n, 500n, 0n, 0n, 0n), { toPot: 0n, toBuyback: 1000n });
});

test("statement pot is the payment minus the three shares", () => {
  assert.equal(statementPot(1000n, 100n, 50n, 200n), 650n);
});
