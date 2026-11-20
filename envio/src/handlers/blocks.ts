import { indexer } from "envio";
import { CORE, CORE_DEPLOY_BLOCK, SNAPSHOT_INTERVAL } from "../lib/constants";
import { snapshot } from "../lib/chain";
import { blockTimestamp } from "../lib/reads";

// Every 300 blocks from the Core deploy block: snapshot the engine state. The original also compares the projections
// with the Core views here and writes a `parity` row; that check is not ported (see README.md).
indexer.onBlock(
  {
    name: "Tick",
    where: ({ chain }) => {
      switch (chain.id) {
        case 1:
          return { block: { number: { _gte: Number(CORE_DEPLOY_BLOCK), _every: SNAPSHOT_INTERVAL } } };
        default: {
          const _exhaustive: never = chain.id;
          return false;
        }
      }
    },
  },
  async ({ block, context }) => {
    const engine = await context.Engine.get(CORE);
    if (!engine) return;
    const timestamp = await context.effect(blockTimestamp, block.number);
    await snapshot(context, { number: BigInt(block.number), timestamp });
  },
);
