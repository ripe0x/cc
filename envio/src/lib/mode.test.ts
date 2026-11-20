import { assert } from "vitest";
import { test } from "vitest";
import { toFunctionSelector } from "viem";
import { composeModeOf } from "./mode";

const core = "0xD06D1a2904B131C995eFF998F97DDef9e38Cccdc";

// promise: compose mode comes from the selector of a direct Core call
test("decodes the three compose entrypoints", () => {
  assert.equal(composeModeOf(core, core, toFunctionSelector("compose()")), "default");
  assert.equal(composeModeOf(core, core, toFunctionSelector("compose(uint8)") + "00"), "default");
  assert.equal(composeModeOf(core.toLowerCase(), core, toFunctionSelector("composeChosen(uint256[80],uint8)")), "chosen");
});

test("internal calls and other selectors have no mode", () => {
  assert.equal(composeModeOf("0x1111111111111111111111111111111111111111", core, toFunctionSelector("compose()")), null);
  assert.equal(composeModeOf(core, core, "0xdeadbeef"), null);
  assert.equal(composeModeOf(null, core, toFunctionSelector("compose()")), null);
});
