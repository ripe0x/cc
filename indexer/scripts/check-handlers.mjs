// Static handler check (docs/INDEXER.md section 6): every `ponder.on` in src/index.ts registers an event that exists
// in that source's ABI, by the exact name Ponder expects (the plain name, or the full signature for an overloaded
// name), and no event is registered twice. A factory source's union ABI makes overloaded names (same name, different
// signature) easy to mis-type, and a duplicate registration silently drops one handler; both fail the build here.
// Runs no chain or database; parses the source text and the generated abis/*.ts. Usage: node scripts/check-handlers.mjs
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { formatAbiItem, parseAbiItem } from "abitype";

const here = dirname(fileURLToPath(import.meta.url));
const read = (p) => readFileSync(join(here, "..", p), "utf8");

// The ABI backing each contract source in ponder.config.ts, as the const in its generated abis/*.ts file.
const SOURCE_ABI = {
  Core: ["abis/Core.ts", "coreAbi"],
  Controller: ["abis/Controller.ts", "controllerLogAbi"],
  Treasury: ["abis/Treasury.ts", "treasuryLogAbi"],
  MarketRedeemer: ["abis/MarketRedeemer.ts", "marketRedeemerAbi"],
  Coin: ["abis/external.ts", "erc20Abi"],
  Credits: ["abis/external.ts", "creditsAbi"],
  Statements: ["abis/external.ts", "statementsAbi"],
  Strategy: ["abis/external.ts", "strategyAbi"],
};

/**
 * The ABI of `export const <name> = ...` in an abis file: a generated JSON array (`[ ... ] as const`) or a
 * hand-written `parseAbi([ "event ...", ... ])`. Returns the array of ABI items.
 */
const abiConst = (file, name) => {
  const text = read(file);
  const start = text.indexOf(`export const ${name} = `);
  if (start < 0) throw new Error(`${name} not found in ${file}`);
  const open = text.indexOf("[", start);
  let depth = 0;
  let close = -1;
  for (let i = open; i < text.length; i++) {
    if (text[i] === "[") depth++;
    else if (text[i] === "]" && --depth === 0) { close = i; break; }
  }
  if (close < 0) throw new Error(`could not parse ${name} in ${file}`);
  const arrayText = text.slice(open, close + 1);
  if (text.slice(start, open).includes("parseAbi(")) {
    return [...arrayText.matchAll(/"([^"]+)"/g)].map((m) => parseAbiItem(m[1]));
  }
  return JSON.parse(arrayText);
};

/** The names Ponder accepts for a source: the plain name, or the full signature for an overloaded event (toSafeName). */
export const safeNames = (abi) => {
  const events = abi.filter((e) => e.type === "event" && !e.anonymous);
  const counts = {};
  for (const e of events) counts[e.name] = (counts[e.name] ?? 0) + 1;
  const names = new Set();
  for (const e of events) names.add(counts[e.name] > 1 ? formatAbiItem(e).split("event ")[1] : e.name);
  return names;
};

/** The "Source:Event" registrations in index.ts: the explicit string form and the `for (const name of [...])` loops. */
export const registrationsIn = (src) => {
  const out = [];
  for (const m of src.matchAll(/ponder\.on\(\s*"([^"]+)"/g)) out.push(m[1]);
  for (const m of src.matchAll(/for \(const name of \[([^\]]+)\] as const\)[\s\S]*?ponder\.on\(\s*`([^:]+):\$\{name\}`/g)) {
    for (const lit of m[1].matchAll(/"([^"]+)"/g)) out.push(`${m[2]}:${lit[1]}`);
  }
  return out;
};

/** The reasons the registrations are invalid: a duplicate, an unknown source, or an event missing from the ABI. */
export const validate = (registered, abiNames) => {
  const problems = [];
  const seen = new Set();
  for (const reg of registered) {
    if (seen.has(reg)) problems.push(`duplicate ponder.on("${reg}")`);
    seen.add(reg);
    const sep = reg.indexOf(":");
    const source = reg.slice(0, sep);
    const event = reg.slice(sep + 1);
    if (!abiNames[source]) problems.push(`unknown source in ponder.on("${reg}")`);
    else if (!abiNames[source].has(event)) problems.push(`ponder.on("${reg}") has no matching event in that source's ABI`);
  }
  return problems;
};

const main = () => {
  const abiNames = Object.fromEntries(Object.entries(SOURCE_ABI).map(([s, [f, n]]) => [s, safeNames(abiConst(f, n))]));
  const registered = registrationsIn(read("src/index.ts"));
  const problems = validate(registered, abiNames);
  if (problems.length) {
    console.error("handler check failed:\n  " + problems.join("\n  "));
    process.exit(1);
  }
  console.log(`handler check: ${registered.length} registrations across ${Object.keys(abiNames).length} sources, no duplicates, all present in their ABI`);
};

if (process.argv[1] && process.argv[1].endsWith("check-handlers.mjs")) main();
