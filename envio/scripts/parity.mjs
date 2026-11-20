// Row-by-row, field-by-field comparison of this port's Postgres against the original Ponder indexer's public
// read-only SQL endpoint (@ponder/client protocol: GET <url>/sql/db?sql=<superjson query>).
//
//   node scripts/parity.mjs --original https://cc-indexer-mainnet.fly.dev \
//        --pg postgres://postgres:testing@localhost:5476/envio-dev [--max-block N] [--uri-every 50] [--delay-ms 500]
//
// --max-block limits the append-only tables (those with a blockNumber column) on both sides, so a port pinned at a block
// can be compared with an original that has moved on. Tables that hold current state (credit, engine, stats, ...) are
// compared as they stand, so compare them when both indexers are at the same block.
// Credit.tokenUri and Statement.tokenUri are about 6 KB each, so they are compared for every --uri-every-th id (and for
// every statement) rather than for all 122k credits.
import { readFileSync } from "node:fs";
import pg from "pg";

const arg = (name, dflt) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : dflt;
};
const original = arg("original");
const pgUrl = arg("pg");
const maxBlock = arg("max-block");
const uriEvery = Number(arg("uri-every", "50"));
// pause before every request to the original, so running this against a production deployment is gentle by default
const delayMs = Number(arg("delay-ms", "500"));
if (!original || !pgUrl) {
  console.error("usage: node scripts/parity.mjs --original <ponder url> --pg <postgres url> [--max-block N] [--uri-every N]");
  process.exit(2);
}

const tables = JSON.parse(readFileSync(new URL("./tables.json", import.meta.url), "utf8"));
const snake = (s) => s.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);
const BIG = ["tokenUri"];

async function theirs(sql) {
  const url = new URL("/sql/db", original);
  url.searchParams.set("sql", JSON.stringify({ json: { sql, params: [], typings: [] } }));
  for (let attempt = 1; ; attempt++) {
    await new Promise((r) => setTimeout(r, delayMs));
    const res = await fetch(url);
    if (res.ok) {
      const body = await res.json();
      body.rows.fields = body.fields.map((f) => f.name);
      return body.rows;
    }
    if (attempt >= 5) throw new Error(`${res.status} ${await res.text()} for ${sql.slice(0, 120)}`);
    await new Promise((r) => setTimeout(r, 1000 * attempt));
  }
}

const norm = (v) => {
  if (v === null || v === undefined) return null;
  if (typeof v === "object") return JSON.stringify(sortKeys(v));
  return String(v);
};
const sortKeys = (v) =>
  Array.isArray(v) ? v.map(sortKeys) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])])) : v;

const client = new pg.Client({ connectionString: pgUrl });
await client.connect();

const PAGE = 2000;
let totalDiffs = 0;
const summary = [];

for (const t of tables) {
  // columns the deployed original has: its schema can trail the repo's main branch
  let theirFields;
  try {
    theirFields = new Set((await theirs(`select * from ${t.table} limit 1`)).fields);
  } catch {
    console.log(`SKIP ${t.entity}: the original's database has no table ${t.table}`);
    summary.push({ table: t.entity, skipped: true });
    continue;
  }
  const missingCols = t.fields.filter((f) => !theirFields.has(f === t.pk ? snake(f) : snake(f)) && !(f === "id" && t.pk !== "id"));
  if (missingCols.length) console.log(`NOTE ${t.entity}: not compared, absent from the original's deployed schema: ${missingCols.join(", ")}`);
  const cols = t.fields.filter((f) => !BIG.includes(f) && !missingCols.includes(f));
  const colList = (names, camel) => names.map((f) => `"${camel ? f : snake(f)}"`).join(", ");
  const where = maxBlock && t.blockLimited ? ` where block_number <= ${BigInt(maxBlock)}` : "";
  const whereMine = maxBlock && t.blockLimited ? ` where "blockNumber" <= ${BigInt(maxBlock)}` : "";
  const theirCols = cols.filter((f) => !(t.pk !== "id" && f === "id"));
  const mineRows = (await client.query(`select ${colList(cols.filter((f) => f !== "id" || t.pk === "id"), true)} from "public"."${t.entity}"${whereMine}`)).rows;
  const mine = new Map(mineRows.map((r) => [String(r[t.pk]), r]));

  const seen = new Set();
  let compared = 0;
  let missingInMine = 0;
  const fieldDiffs = {};
  const examples = [];
  for (let offset = 0; ; offset += PAGE) {
    const rows = await theirs(
      `select ${colList(theirCols.filter((f) => f !== "id" || t.pk === "id"))} from ${t.table}${where} order by "${snake(t.pk)}" limit ${PAGE} offset ${offset}`,
    );
    for (const row of rows) {
      const key = String(row[snake(t.pk)]);
      seen.add(key);
      const m = mine.get(key);
      if (!m) {
        missingInMine++;
        if (examples.length < 5) examples.push(`missing in port: ${key}`);
        continue;
      }
      compared++;
      for (const f of theirCols) {
        if (f === "id" && t.pk !== "id") continue;
        const a = norm(row[snake(f)]);
        const b = norm(m[f]);
        if (a !== b) {
          fieldDiffs[f] = (fieldDiffs[f] ?? 0) + 1;
          if (examples.length < 8) examples.push(`${key}.${f}: original=${String(a).slice(0, 80)} port=${String(b).slice(0, 80)}`);
        }
      }
    }
    if (rows.length < PAGE) break;
  }
  const extras = [...mine.keys()].filter((k) => !seen.has(k));
  const extraInMine = extras.length;
  for (const k of extras.slice(0, 3)) examples.push(`extra in port: ${k}`);
  const diffs = Object.values(fieldDiffs).reduce((a, b) => a + b, 0) + missingInMine + extraInMine;
  totalDiffs += diffs;
  summary.push({ table: t.entity, original: seen.size, port: mine.size, compared, fields: cols.length, missingInMine, extraInMine, fieldDiffs: JSON.stringify(fieldDiffs) });
  console.log(`${diffs === 0 ? "OK  " : "DIFF"} ${t.entity}: original ${seen.size}, port ${mine.size}, ${compared} rows x ${cols.length} fields compared${diffs ? `; field differences ${JSON.stringify(fieldDiffs)}, missing in port ${missingInMine}, extra in port ${extraInMine}` : ""}`);
  for (const e of examples) console.log(`       ${e}`);
}

// tokenUri: every uriEvery-th Credit id, plus every Statement, plus a null-count check on both sides.
for (const [entity, table] of [["Credit", "credit"], ["Statement", "statement"]]) {
  const every = entity === "Credit" ? uriEvery : 1;
  const ids = (await client.query(`select id from "public"."${entity}" where (id::numeric % ${every}) = 0 order by id::numeric`)).rows.map((r) => r.id);
  const nullsMine = Number((await client.query(`select count(*) from "public"."${entity}" where "tokenUri" is null`)).rows[0].count);
  const nullsTheirs = Number((await theirs(`select count(*) as n from ${table} where token_uri is null`))[0].n);
  let diffs = Math.abs(nullsMine - nullsTheirs);
  let checked = 0;
  for (let i = 0; i < ids.length; i += 100) {
    const batch = ids.slice(i, i + 100);
    const rows = await theirs(`select id, token_uri from ${table} where id in (${batch.join(",")})`);
    const mineUris = new Map((await client.query(`select id, "tokenUri" from "public"."${entity}" where id = any($1)`, [batch])).rows.map((r) => [r.id, r.tokenUri]));
    for (const r of rows) {
      checked++;
      if ((r.token_uri ?? null) !== (mineUris.get(String(r.id)) ?? null)) {
        diffs++;
        if (diffs < 5) console.log(`       ${entity} ${r.id}.tokenUri differs`);
      }
    }
  }
  totalDiffs += diffs;
  console.log(`${diffs === 0 ? "OK  " : "DIFF"} ${entity}.tokenUri: ${checked} full values compared; null count original ${nullsTheirs}, port ${nullsMine}`);
}

console.log(`\n${totalDiffs === 0 ? "No differences." : `${totalDiffs} differences.`}`);
await client.end();
process.exit(totalDiffs === 0 ? 0 : 1);
