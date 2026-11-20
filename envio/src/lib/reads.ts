// The chain reads of indexer/src/chain.ts as Effects. Each is keyed by what varies (block, ids, addresses), cached in
// the database and batched through Multicall3. Results travel as tagged JSON where a struct would need a long schema.
import { createEffect, S } from "envio";
import { parseAbi, type Hex } from "viem";
import { treasuryAbi } from "../abis/Phase2BalanceTreasury";
import { treasuryV2Abi } from "../abis/BalanceTreasuryV2";
import { controllerAbi } from "../abis/ControllerV1";
import { controllerV2Abi } from "../abis/ControllerV2";
import { coreAbi } from "../abis/Core";
import { creditScoreAbi, creditsAbi, moduleAbi, multicall3Abi, statementsAbi } from "../abis/external";
import { CORE, CREDITS, CREDIT_SCORE, MULTICALL3, STATEMENTS } from "./constants";
import { Batcher, blockTimestampOf, chunks, dec, enc, multicall, type Raw } from "./rpc";

const tokenReadAbi = parseAbi(["function balanceOf(address) view returns (uint256)", "function totalSupply() view returns (uint256)"]);

/** JSON with bigints tagged, so a cached effect result decodes to the same types. */
const pack = (v: unknown): string => JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? { $big: x.toString() } : x));
export const unpack = <T>(s: string): T =>
  JSON.parse(s, (_k, x) => (x && typeof x === "object" && "$big" in x ? BigInt((x as { $big: string }).$big) : x)) as T;

const lc = (a: string) => a.toLowerCase() as Hex;

// ---- Core --------------------------------------------------------------------------------------------------

/** Values the Core constructor sets (they emit no event), read at the block of the first Core event. */
export const coreInitial = createEffect(
  { name: "coreInitial", input: { block: S.number }, output: S.string, cache: true, rateLimit: false },
  async ({ input }) => {
    const fns = ["owner", "payee", "artist", "COIN", "creditCostToPotBps", "chosenComposeOn", "minCcToChoose", "settings"] as const;
    const r = await multicall("coreInitial", fns.map((f) => enc(CORE, coreAbi, f)), BigInt(input.block));
    const v = fns.map((f, i) => {
      const x = dec<unknown>(coreAbi, f, r[i]);
      if (x === undefined) throw new Error(`Core.${f} failed at block ${input.block}`);
      return x;
    });
    return pack({ owner: v[0], payee: v[1], artist: v[2], coin: v[3], costToPot: v[4], chosen: v[5], minCc: v[6], settings: v[7] });
  },
);

export type Snapshot = {
  ethPot: bigint; ethToBuyback: bigint; ethRedeemBurn: bigint; ethRate: bigint; floorRate: bigint; balanceRate: bigint;
  coreEthBalance: bigint; pileSize: bigint; payeeOn: boolean; paused: boolean; balanceAvailable: bigint | null;
  valueBuy: bigint | null; valueSell: bigint | null; referencePrice: bigint | null; spotPrice: bigint | null;
  treasuryBalance: bigint | null; treasuryWorking: bigint | null; claimReserve: bigint | null; ccSupply: bigint | null;
};

/** The pots, rates, balances and flags at one block. Empty strings stand for "no such contract yet". */
export const snapshotReads = createEffect(
  {
    name: "snapshotReads",
    input: { block: S.number, module: S.string, token: S.string, controller: S.string, coin: S.string },
    output: S.string,
    cache: true,
    rateLimit: false,
  },
  async ({ input }) => {
    const mod = input.module ? lc(input.module) : null;
    const token = input.token ? lc(input.token) : null;
    const ctl = input.controller ? lc(input.controller) : null;
    const coin = input.coin ? lc(input.coin) : null;
    const core = (f: string) => enc(CORE, coreAbi, f);
    const fixed = [
      core("ethPot"), core("ethToBuyback"), core("ethRedeemBurn"), core("ethRate"), core("floorRate"), core("balanceRate"),
      enc(MULTICALL3, multicall3Abi, "getEthBalance", [CORE]), core("pileSize"), core("payeeOn"), core("paused"),
    ];
    // phase 2 reads, all allowed to fail; a slot with no contract records null
    const p2 = [
      ctl ? enc(ctl, controllerV2Abi, "valuePerPoint", [false]) : null,
      ctl ? enc(ctl, controllerV2Abi, "valuePerPoint", [true]) : null,
      ctl ? enc(ctl, controllerV2Abi, "referencePrice") : null,
      ctl ? enc(ctl, controllerV2Abi, "spotPrice") : null,
      token && mod ? enc(token, tokenReadAbi, "balanceOf", [mod]) : null,
      mod ? enc(mod, treasuryAbi, "working") : null,
      mod ? enc(mod, treasuryAbi, "claimReserve") : null,
      coin ? enc(coin, tokenReadAbi, "totalSupply") : null,
    ];
    const avail = mod ? enc(mod, moduleAbi, "available") : null;
    const calls = [...fixed, ...(avail ? [avail] : []), ...p2.filter((c) => c !== null)];
    const r = await multicall("snapshot", calls, BigInt(input.block));
    const need = <T>(i: number, abi: typeof coreAbi | typeof multicall3Abi, f: string): T => {
      const x = dec<T>(abi, f, r[i]);
      if (x === undefined) throw new Error(`snapshot call ${f} failed at block ${input.block}`);
      return x;
    };
    let next = fixed.length;
    const availRaw: Raw | undefined = avail ? r[next++] : undefined;
    const opt = (i: number, abi: typeof controllerV2Abi | typeof tokenReadAbi | typeof treasuryAbi, f: string): bigint | null => {
      if (!p2[i]) return null;
      const raw = r[next++];
      const v = dec<bigint | readonly [bigint, boolean]>(abi as never, f, raw);
      if (v === undefined) return null;
      return typeof v === "bigint" ? v : v[1] ? v[0] : null;
    };
    const out: Snapshot = {
      ethPot: need(0, coreAbi, "ethPot"),
      ethToBuyback: need(1, coreAbi, "ethToBuyback"),
      ethRedeemBurn: need(2, coreAbi, "ethRedeemBurn"),
      // An unusable value quote reads as a zero ETH bid; a reverted read records zero without stopping the snapshot.
      ethRate: dec<bigint>(coreAbi, "ethRate", r[3]) ?? 0n,
      floorRate: need(4, coreAbi, "floorRate"),
      balanceRate: need(5, coreAbi, "balanceRate"),
      coreEthBalance: need(6, multicall3Abi, "getEthBalance"),
      pileSize: need(7, coreAbi, "pileSize"),
      payeeOn: need(8, coreAbi, "payeeOn"),
      paused: need(9, coreAbi, "paused"),
      balanceAvailable: mod ? (dec<bigint>(moduleAbi, "available", availRaw) ?? null) : null,
      valueBuy: opt(0, controllerV2Abi, "valuePerPoint"),
      valueSell: opt(1, controllerV2Abi, "valuePerPoint"),
      referencePrice: opt(2, controllerV2Abi, "referencePrice"),
      spotPrice: opt(3, controllerV2Abi, "spotPrice"),
      treasuryBalance: opt(4, tokenReadAbi, "balanceOf"),
      treasuryWorking: opt(5, treasuryAbi, "working"),
      claimReserve: opt(6, treasuryAbi, "claimReserve"),
      ccSupply: opt(7, tokenReadAbi, "totalSupply"),
    };
    return pack(out);
  },
);

// ---- controller and treasury, read at the block they are named ----------------------------------------------

export const controllerParams = createEffect(
  { name: "controllerParams", input: { block: S.number, address: S.string }, output: S.string, cache: true, rateLimit: false },
  async ({ input }) => {
    const address = lc(input.address);
    const block = BigInt(input.block);
    const k = (f: string) => enc(address, controllerAbi, f);
    const v2 = (f: string) => enc(address, controllerV2Abi, f);
    // tolerant reads: ControllerV2 has no anchorHalfLife, anchorMinCost or storedAnchorBps and ControllerV1 has none of
    // the statement sale views, so a failing read leaves its column null
    const r = await multicall(
      "controller",
      [
        k("markupBps"), k("startCapBps"), k("decayHours"), k("anchorHalfLife"), k("anchorMinCost"), k("creditSaleOn"),
        k("creditWindow"), k("creditSpreadBps"), k("creditStartBps"), k("storedAnchorBps"), k("balancePoolKeySet"),
        k("balancePoolKey"), k("ageEligibilityOn"), v2("statementSalesEnabled"), v2("statementSaleMultiplierBps"),
        v2("statementRedeemDelaySeconds"), k("quote"), k("referencePrice"), k("referenceTime"),
      ],
      block,
    );
    const g = <T>(i: number, f: string, abi: typeof controllerAbi | typeof controllerV2Abi = controllerAbi) => dec<T>(abi, f, r[i]);
    const num = (v: bigint | number | undefined) => (v === undefined ? null : Number(v));
    const big = (v: bigint | number | undefined) => (v === undefined ? null : BigInt(v));
    const key = g<readonly [Hex, Hex, number, number, Hex]>(11, "balancePoolKey");
    // a V2 controller without storedAnchorBps answers anchorBps (the derived value) for the same column
    let anchor = g<bigint | number>(9, "storedAnchorBps");
    if (anchor === undefined) {
      const [a] = await multicall("controller.anchorBps", [k("anchorBps")], block);
      anchor = dec<bigint | number>(controllerAbi, "anchorBps", a);
    }
    const q = g<readonly [number, number, number, number, number, bigint]>(16, "quote");
    const refPrice = g<bigint>(17, "referencePrice");
    const refTime = g<number | bigint>(18, "referenceTime");
    return pack({
      markupBps: num(g(0, "markupBps")),
      startCapBps: big(g(1, "startCapBps")),
      decayHours: num(g(2, "decayHours")),
      anchorHalfLife: big(g(3, "anchorHalfLife")),
      anchorMinCost: g<bigint>(4, "anchorMinCost") ?? null,
      saleOn: g<boolean>(5, "creditSaleOn") ?? null,
      ageEligibilityOn: g<boolean>(12, "ageEligibilityOn") ?? null,
      window: big(g(6, "creditWindow")),
      spreadBps: num(g(7, "creditSpreadBps")),
      startBps: big(g(8, "creditStartBps")),
      anchorBps: big(anchor),
      balancePoolSet: g<boolean>(10, "balancePoolKeySet") ?? false,
      balanceCurrency0: key ? lc(key[0]) : null,
      balanceCurrency1: key ? lc(key[1]) : null,
      balanceFee: key ? Number(key[2]) : null,
      balanceTickSpacing: key ? Number(key[3]) : null,
      balanceHooks: key ? lc(key[4]) : null,
      statementSalesEnabled: g<boolean>(13, "statementSalesEnabled", controllerV2Abi) ?? null,
      statementSaleMultiplierBps: big(g(14, "statementSaleMultiplierBps", controllerV2Abi)),
      statementRedeemDelaySeconds: big(g(15, "statementRedeemDelaySeconds", controllerV2Abi)),
      referenceRateBpsPerHour: q ? BigInt(q[0]) : null,
      referenceStepBps: q ? Number(q[1]) : null,
      referenceTolBps: q ? Number(q[2]) : null,
      referenceMaxStale: q ? BigInt(q[3]) : null,
      referenceMinSeconds: q ? BigInt(q[4]) : null,
      referenceMinLiquidity: q ? q[5] : null,
      referencePrice: refPrice ?? null,
      referenceTime: refTime === undefined ? null : BigInt(refTime),
    });
  },
);

/** The balance module's state at its BalanceModuleSet block. "null" when it is neither a phase 2 nor a phase 3 treasury. */
export const treasuryParams = createEffect(
  { name: "treasuryParams", input: { block: S.number, address: S.string }, output: S.string, cache: true, rateLimit: false },
  async ({ input }) => {
    const address = lc(input.address);
    const block = BigInt(input.block);
    const [probe] = await multicall("treasury.probe", [enc(address, treasuryV2Abi, "proRataRedeemer")], block);
    if (probe?.success) {
      const t = (f: string) => enc(address, treasuryV2Abi, f);
      const r = await multicall(
        "treasuryV2",
        [t("proRataRedeemer"), t("cushion"), t("totalShareBps"), t("conversionToClaimBps"), t("conversionEnabled"),
          t("workingPaymentsEnabled"), t("paused"), t("totalOwed"), t("migrated")],
        block,
      );
      const g = <T>(i: number, f: string) => dec<T>(treasuryV2Abi, f, r[i]);
      const num = (v: bigint | number | undefined) => (v === undefined ? null : Number(v));
      const big = (v: bigint | number | undefined) => (v === undefined ? null : BigInt(v));
      const redeemer = g<Hex>(0, "proRataRedeemer");
      return pack({
        version: "v2",
        proRataRedeemer: redeemer ? lc(redeemer) : null,
        cushion: big(g(1, "cushion")),
        bidBudget: null,
        bidShareBps: null,
        totalShareBps: num(g(2, "totalShareBps")),
        conversionToClaimBps: num(g(3, "conversionToClaimBps")),
        conversionEnabled: g<boolean>(4, "conversionEnabled") ?? null,
        workingPaymentsEnabled: g<boolean>(5, "workingPaymentsEnabled") ?? null,
        bidEnabled: null,
        paused: g<boolean>(6, "paused") ?? null,
        totalOwed: big(g(7, "totalOwed")) ?? 0n,
        migrated: g<boolean>(8, "migrated") ?? false,
      });
    }
    const t = (f: string) => enc(address, treasuryAbi, f);
    const r = await multicall(
      "treasuryP2",
      [t("claimReserve"), t("totalOwed"), t("configEpoch"), t("redemptionPolicy"), t("conversionToClaimBps"),
        t("redemptionFeeBps"), t("conversionEnabled"), t("workingPaymentsEnabled"), t("ccRedemptionEnabled"),
        t("minimumWorkingBalance"), t("migrated")],
      block,
    );
    const g = <T>(i: number, f: string) => dec<T>(treasuryAbi, f, r[i]);
    if (!r[0]?.success) return pack(null);
    const num = (v: bigint | number | undefined) => (v === undefined ? null : Number(v));
    const big = (v: bigint | number | undefined) => (v === undefined ? null : BigInt(v));
    const policy = g<Hex>(3, "redemptionPolicy");
    return pack({
      version: "phase2",
      claimReserve: big(g(0, "claimReserve")),
      totalOwed: big(g(1, "totalOwed")) ?? 0n,
      configEpoch: big(g(2, "configEpoch")),
      policy: policy ? lc(policy) : null,
      conversionToClaimBps: num(g(4, "conversionToClaimBps")),
      redemptionFeeBps: num(g(5, "redemptionFeeBps")),
      conversionEnabled: g<boolean>(6, "conversionEnabled") ?? null,
      workingPaymentsEnabled: g<boolean>(7, "workingPaymentsEnabled") ?? null,
      ccRedemptionEnabled: g<boolean>(8, "ccRedemptionEnabled") ?? null,
      minimumWorkingBalance: big(g(9, "minimumWorkingBalance")),
      migrated: g<boolean>(10, "migrated") ?? false,
    });
  },
);

// ---- Credits and Statements ------------------------------------------------------------------------------------

type CreditRead = {
  seed: string; paidAt: bigint; score: bigint; mask: number; active: number; occupied: number; eights: number; band: number;
  tokenUri: string | null; owner: string | null;
};

/** Credits minted at one block are read together: seed, paid time, score and traits, tokenURI and owner. */
const creditBatcher = new Batcher<{ id: bigint; block: number }, CreditRead>(async (keys) => {
  const out = new Map<string, CreditRead>();
  const byBlock = new Map<number, Set<bigint>>();
  for (const k of keys) {
    if (!byBlock.has(k.block)) byBlock.set(k.block, new Set());
    byBlock.get(k.block)!.add(k.id);
  }
  const jobs: Promise<void>[] = [];
  for (const [block, idSet] of byBlock) {
    for (const ids of chunks([...idSet], 40)) {
      jobs.push(
        (async () => {
          const c = (f: string, id: bigint) => enc(CREDITS, creditsAbi, f, [id]);
          const b = BigInt(block);
          // tokenURI runs a lot of code per call, so its failures are re-checked one by one
          const first = await multicall(
            "credits.facts",
            ids.flatMap((id) => [c("seedOf", id), c("timestampOf", id), c("tokenURI", id), c("ownerOf", id)]),
            b,
            true,
          );
          const facts = ids.map((id, i) => {
            const seed = dec<Hex>(creditsAbi, "seedOf", first[4 * i]);
            const paidAt = dec<bigint>(creditsAbi, "timestampOf", first[4 * i + 1]);
            if (seed === undefined || paidAt === undefined) throw new Error(`Credits seedOf/timestampOf(${id}) failed at block ${block}`);
            return { id, seed, paidAt };
          });
          const scored = await multicall(
            "credits.score",
            facts.flatMap((f) => [
              enc(CREDIT_SCORE, creditScoreAbi, "scoreOf", [f.seed, f.paidAt]),
              enc(CREDIT_SCORE, creditScoreAbi, "traitsOf", [f.seed, f.paidAt]),
            ]),
            // pure in (seed, paidAt), and the CreditScore contract is younger than the first Credits: read at latest, as
            // the original does with cache: "immutable"
            undefined,
          );
          facts.forEach((f, i) => {
            const score = dec<bigint>(creditScoreAbi, "scoreOf", scored[2 * i]);
            const traits = dec<readonly bigint[]>(creditScoreAbi, "traitsOf", scored[2 * i + 1]);
            if (score === undefined || traits === undefined) throw new Error(`CreditScore(${f.id}) failed at block ${block}`);
            const owner = dec<Hex>(creditsAbi, "ownerOf", first[4 * i + 3]);
            out.set(`${f.id}@${block}`, {
              seed: f.seed, paidAt: f.paidAt, score,
              mask: Number(traits[0]), active: Number(traits[1]), occupied: Number(traits[2]), eights: Number(traits[3]), band: Number(traits[4]),
              tokenUri: dec<string>(creditsAbi, "tokenURI", first[4 * i + 2]) ?? null,
              owner: owner ? lc(owner) : null,
            });
          });
        })(),
      );
    }
  }
  await Promise.all(jobs);
  return keys.map((k) => out.get(`${k.id}@${k.block}`)!);
});

export const creditRead = createEffect(
  {
    name: "creditRead",
    input: { id: S.bigint, block: S.number },
    output: {
      seed: S.string, paidAt: S.bigint, score: S.bigint, mask: S.number, active: S.number, occupied: S.number,
      eights: S.number, band: S.number, tokenUri: S.union([S.string, null]), owner: S.union([S.string, null]),
    },
    cache: true,
    rateLimit: false,
  },
  async ({ input }) => creditBatcher.get({ id: input.id, block: input.block }),
);

/** A statement's rating, format, tokenURI and owner at one block; null where the read reverts. */
export const statementRead = createEffect(
  {
    name: "statementRead",
    input: { id: S.bigint, block: S.number },
    output: { rating: S.bigint, format: S.union([S.number, null]), tokenUri: S.union([S.string, null]), owner: S.union([S.string, null]) },
    cache: true,
    rateLimit: false,
  },
  async ({ input }) => {
    const s = (f: string) => enc(STATEMENTS, statementsAbi, f, [input.id]);
    // the rating is immutable and read at latest (the original's cache: "immutable"); the rest at the event block
    const [rated] = await multicall("statement.rating", [s("creditScoreOf")], undefined);
    const r = [rated!, ...(await multicall("statement", [s("formatOf"), s("tokenURI"), s("ownerOf")], BigInt(input.block), true))];
    const rating = dec<bigint>(statementsAbi, "creditScoreOf", r[0]);
    if (rating === undefined) throw new Error(`Statements.creditScoreOf(${input.id}) failed at block ${input.block}`);
    const format = dec<number | bigint>(statementsAbi, "formatOf", r[1]);
    const owner = dec<Hex>(statementsAbi, "ownerOf", r[3]);
    return {
      rating,
      format: format === undefined ? null : Number(format),
      tokenUri: dec<string>(statementsAbi, "tokenURI", r[2]) ?? null,
      owner: owner ? lc(owner) : null,
    };
  },
);

/** tokenURI of a statement after HeldFormatSet. A revert here stops the indexer, as readContract does in the original. */
export const statementArt = createEffect(
  { name: "statementArt", input: { id: S.bigint, block: S.number }, output: S.string, cache: true, rateLimit: false },
  async ({ input }) => {
    const [r] = await multicall("statementArt", [enc(STATEMENTS, statementsAbi, "tokenURI", [input.id])], BigInt(input.block), true);
    const uri = dec<string>(statementsAbi, "tokenURI", r);
    if (uri === undefined) throw new Error(`Statements.tokenURI(${input.id}) reverted at block ${input.block}`);
    return uri;
  },
);

/** Block timestamp for the Tick block handler, which receives only the block number. */
export const blockTimestamp = createEffect(
  { name: "blockTimestamp", input: S.number, output: S.bigint, cache: true, rateLimit: false },
  async ({ input }) => blockTimestampOf(BigInt(input)),
);

