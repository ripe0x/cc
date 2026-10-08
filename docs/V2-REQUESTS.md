# requests for the artcoins v2 work session

collected while porting the credits engine to v2 (v2 commit 87a7522). to be turned into one prompt for the v2 session once the engine side is settled. nothing here is done in this repo.

| # | request | why |
|---|---|---|
| 1 | a pool's fee recipient (the bounty recipient) must be changeable after launch. decide who may change it (the coin admin, or the current recipient handing over) and whether it can be locked | the owner expects this and v2 has no setter: the hook stores the recipient at launch (`ArtCoinsHookV2` reads `cfg.bountyRecipient`, no write path), and the v1 locker's `updateRewardRecipient` is gone too. the engine works around it with its own router |
| 2 | rethink the minimum lp fee (D53). allow 0 without a global owner toggle, or drop the rule | the engine launches with lp fee 0 and a pure skim. the minimum exists only to keep the protocol's locker slot from being worthless; the protocol already has a floor on the skim (D52), which pays in eth with no collect and no conversion |
| 3 | docs/v2/STATUS.md quotes contract sizes that do not match the commit (hook 15,741 built against 16,716 quoted, deployer 15,536 against 21,166, factory 19,771 against 20,424, ci profile) | a deploy check that compares sizes would compare against stale numbers |
| 4 | D73 says permit2, the universal router, the fee swapper and the burn router are seeded into a restricted coin's allowlist. the source seeds none of them | doc and code disagree |
| 5 | the hook exposes a push gas tunable (`PUSH_GAS_DEFAULT` 50,000, `setDeliveryParams`) but pushes the bounty leg with `_PUSH_GAS = 0` | the setting does nothing for that leg |
| 6 | docs/v2/CREDITS-ENGINE-INTERFACE.md is stale: tax sink, tax exemption and venue text (gone with D73), "skim refund rides the return delta" (the source credits the escrow), and the interface files lack `minLpFee`, `setMinLpFee`, `setTokenDeployer` | integrators read it first |
| 7 | document that the anti sniper excess above the baseline skim goes entirely to the bounty recipient (a 1 eth buy in the window paid 0.89 eth to it in the fork test) | not stated anywhere a launcher would look |
