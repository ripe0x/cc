import { toFunctionSelector } from "viem";

export type ComposeMode = "default" | "chosen";

const SELECTORS = new Map<string, ComposeMode>([
  [toFunctionSelector("compose()"), "default"],
  [toFunctionSelector("compose(uint8)"), "default"],
  [toFunctionSelector("composeChosen(uint256[80],uint8)"), "chosen"],
]);

/**
 * Compose mode from the transaction input. Null when the transaction did not call the Core directly
 * (an internal call from another contract) or the selector is not a compose entrypoint.
 */
export function composeModeOf(to: string | null | undefined, core: string, input: string): ComposeMode | null {
  if (!to || to.toLowerCase() !== core.toLowerCase()) return null;
  return SELECTORS.get(input.slice(0, 10).toLowerCase()) ?? null;
}
