// Event arguments as viem decodes them, which is what Ponder hands its handlers and what the original stores in
// `log.args`: integers of 48 bits or fewer are numbers, wider ones bigints. Envio decodes every integer as a bigint.
import coreAbi from "../../abis/Core.json" with { type: "json" };
import controllerAbi from "../../abis/Controller.json" with { type: "json" };
import treasuryAbi from "../../abis/Treasury.json" with { type: "json" };

type Param = { name: string; type: string; components?: Param[] };
type AbiItem = { type: string; name?: string; inputs?: Param[] };

const ABIS = { Core: coreAbi, Controller: controllerAbi, Treasury: treasuryAbi } as Record<string, AbiItem[]>;

function convert(p: Param, v: unknown): unknown {
  if (p.type.endsWith("]")) {
    const inner = { ...p, type: p.type.slice(0, p.type.lastIndexOf("[")) };
    return (v as unknown[]).map((x) => convert(inner, x));
  }
  if (p.type === "tuple") {
    const o = v as Record<string, unknown>;
    return Object.fromEntries(p.components!.map((c) => [c.name, convert(c, o[c.name])]));
  }
  const m = /^u?int(\d+)$/.exec(p.type);
  if (m && Number(m[1]) <= 48 && typeof v === "bigint") return Number(v);
  return v;
}

/** `params` of an event of `contract` with viem's integer types. Events of other contracts pass through unchanged. */
export function viemArgs(contract: string, event: string, params: object): Record<string, unknown> {
  const items = ABIS[contract]?.filter((i) => i.type === "event" && i.name === event);
  if (!items?.length) return params as Record<string, unknown>;
  const keys = Object.keys(params);
  // overloaded events (Treasury) are told apart by their parameter names
  const item = items.find((i) => i.inputs!.length === keys.length && i.inputs!.every((p) => keys.includes(p.name))) ?? items[0]!;
  return Object.fromEntries(item.inputs!.map((p) => [p.name, convert(p, (params as Record<string, unknown>)[p.name])]));
}
