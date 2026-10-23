// promise: the handler check catches a ponder.on registered twice or for an event absent from its source's ABI, and
// reads both the explicit and the loop registration forms, so a mistyped overloaded treasury name fails the build.
import assert from "node:assert/strict";
import test from "node:test";
import { registrationsIn, validate } from "./check-handlers.mjs";

const abiNames = { Treasury: new Set(["BidFill", "CCRedeemed(address indexed burner, uint256 ccIn)"]) };

test("validate flags duplicates and events missing from the ABI, and passes a correct set", () => {
  assert.deepEqual(validate(["Treasury:BidFill"], abiNames), []);
  assert.deepEqual(
    validate(["Treasury:CCRedeemed(address indexed burner, uint256 ccIn)"], abiNames),
    [],
    "an overloaded event by its full signature is accepted",
  );
  assert.deepEqual(validate(["Treasury:BidFill", "Treasury:BidFill"], abiNames).length, 1);
  assert.match(validate(["Treasury:CCRedeemed"], abiNames)[0], /no matching event/);
  assert.match(validate(["Ghost:X"], abiNames)[0], /unknown source/);
});

test("registrationsIn reads the explicit and the for-loop forms", () => {
  const src = [
    'ponder.on("Treasury:BidFill", async () => {});',
    'for (const name of ["FillSynced", "CcQuoteSet"] as const) {',
    "  ponder.on(`Controller:${name}`, async () => {});",
    "}",
  ].join("\n");
  assert.deepEqual(registrationsIn(src), ["Treasury:BidFill", "Controller:FillSynced", "Controller:CcQuoteSet"]);
});
