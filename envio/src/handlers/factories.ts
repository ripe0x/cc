// The two factory sources of indexer/ponder.config.ts: every controller named by Core.ControllerSet and every balance
// module named by Core.BalanceModuleSet are indexed from that event's block.
import { indexer } from "envio";
import { ZERO } from "../lib/constants";

indexer.contractRegister({ contract: "Core", event: "ControllerSet" }, async ({ event, context }) => {
  if (event.params.controller !== ZERO) context.chain.Controller.add(event.params.controller);
});

indexer.contractRegister({ contract: "Core", event: "BalanceModuleSet" }, async ({ event, context }) => {
  if (event.params.balanceModule !== ZERO) context.chain.Treasury.add(event.params.balanceModule);
});
