import { assert } from "vitest";
import { test } from "vitest";
import { parseTokenUri } from "./tokenuri";

const json = JSON.stringify({ name: "Statement #1", attributes: [{ trait_type: "Format", value: "Ledger" }, { trait_type: "Credits", value: 80 }] });

// promise: the statement format name is read from the Format trait of both URI encodings
test("parses utf8 and base64 data URIs", () => {
  const a = parseTokenUri(`data:application/json;utf8,${json}`);
  const b = parseTokenUri(`data:application/json;base64,${Buffer.from(json).toString("base64")}`);
  assert.equal(a?.attributes.Format, "Ledger");
  assert.deepEqual(a, b);
  assert.equal(a?.attributes.Credits, "80");
});

test("returns null for other schemes and bad json", () => {
  assert.equal(parseTokenUri("https://x"), null);
  assert.equal(parseTokenUri("data:application/json;utf8,{oops"), null);
});
