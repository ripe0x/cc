// Coin burns, the Credits and Statements collections and the CreditStrategy listings.
import { indexer } from "envio";
import { blank } from "../lib/blank";
import { CORE, STRATEGY, ZERO } from "../lib/constants";
import { ensureCredit, ensureStatement } from "../lib/chain";
import { at, bump, FIELDS, lc, patch, record, type At, type Ctx } from "../lib/shared";
import type { Hex } from "viem";

// Coin burns. A burn by the Core is a buyback burn. Swap fee burns are counted from CreditSwapped.fee.
indexer.onEvent(
  { contract: "Coin", event: "Transfer", fields: FIELDS, where: { params: { to: ZERO } } },
  async ({ event, context }) => {
    const e = at(event);
    record(context, e, event.params, "coin", "Transfer");
    if (lc(event.params.from) === CORE) {
      const cur = await context.TransactionFact.get(e.transaction.hash);
      context.TransactionFact.set({ ...(cur ?? { ...blank.transactionFact, id: e.transaction.hash }), coreBurn: (cur?.coreBurn ?? 0n) + event.params.value });
      await bump(context, e, { ccBurned: event.params.value });
    }
  },
);

// Owner follows every Transfer. A transfer from the Core to the successor moves a held credit out of the pile
// (Core.migrate emits Migrated without the ids).
indexer.onEvent({ contract: "Credits", event: "Transfer", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "credits", "Transfer");
  const { from, to, id } = event.params;
  const c = await ensureCredit(context, e, id, lc(to));
  const p: { owner: Hex; state?: "migrated"; pileOrder?: undefined } = { owner: lc(to) };
  if (c.state === "held" && lc(from) === CORE) {
    const eng = await context.Engine.get(CORE);
    if (eng?.successor && eng.successor !== ZERO && eng.successor === lc(to)) {
      p.state = "migrated";
      p.pileOrder = undefined;
    }
  }
  await patch(context.Credit, id.toString(), p, "credit");
  // a Credits Transfer out of the strategy ends its listing
  if (lc(from) === STRATEGY) await endListing(context, e, id, lc(to));
});

async function endListing(ctx: Ctx, e: At, id: bigint, buyer: Hex) {
  const row = await ctx.StrategyListing.get(id.toString());
  if (!row?.active) return;
  ctx.StrategyListing.set({ ...row, active: false, soldBlock: e.block.number, soldAt: e.block.timestamp, buyer });
}

indexer.onEvent({ contract: "Strategy", event: "NFTBoughtByProtocol", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "strategy", "NFTBoughtByProtocol");
  context.StrategyListing.set({
    ...blank.strategyListing,
    id: event.params.tokenId.toString(),
    listPrice: event.params.listPrice,
    active: true,
    boughtBlock: e.block.number,
    boughtAt: e.block.timestamp,
  });
});

indexer.onEvent({ contract: "Strategy", event: "NFTSoldByProtocol", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "strategy", "NFTSoldByProtocol");
  const { tokenId, buyer } = event.params;
  const row = await context.StrategyListing.get(tokenId.toString());
  if (!row) return;
  context.StrategyListing.set({ ...row, active: false, soldBlock: e.block.number, soldAt: e.block.timestamp, buyer: lc(buyer) });
});

indexer.onEvent({ contract: "Statements", event: "Transfer", fields: FIELDS }, async ({ event, context }) => {
  const e = at(event);
  record(context, e, event.params, "statements", "Transfer");
  const { to, id } = event.params;
  await ensureStatement(context, e, id, lc(to));
  await patch(context.Statement, id.toString(), { owner: lc(to) }, "statement");
});
