import { assert } from "vitest";
import { test } from "vitest";
import { addTokenCommitment } from "./balance-history";

// promise: token replacement never adds different currencies or decimal scales together.
test("BALANCE commitments retain A18 and B6 separately when A is selected again", () => {
  const a = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
  const b = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  const first = addTokenCommitment({}, a, 10n ** 18n);
  const switched = addTokenCommitment(first, b, 10n ** 6n);
  const returned = addTokenCommitment(switched, a.toLowerCase(), 2n * 10n ** 18n);
  assert.deepEqual(returned, { [a.toLowerCase()]: "3000000000000000000", [b]: "1000000" });
  assert.deepEqual(first, { [a.toLowerCase()]: "1000000000000000000" });
});

// promise: commitment counters stay exact beyond JavaScript's numeric range.
test("raw commitment totals preserve every base unit", () => {
  const a = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  assert.equal(addTokenCommitment({ [a]: "100000000000000000000000001" }, a, 1n)[a], "100000000000000000000000002");
});
