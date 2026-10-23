# Pricing: two references, one rule per door

Status: proposal, 2026-10-23, for the owner's acceptance before any contract changes. Evidence and the live numbers are in `docs/reviews/PRICING-REVIEW-2026-10-23.md`; the fork replay is `test/pricing/PricingReplay.t.sol`.

## 1. The rule

The engine buys points and sells pictures. Its edge is that it can turn Credits into $BALANCE at par (1 point = 1 $BALANCE) through a Statement, which no single Credit holder can. The market's edge is that it pays a flat NFT floor for any Credit. So:

- **Buying** is priced by points at or under par, in either currency, and only ever wins Credits whose points are worth more than the NFT floor. That is the engine's business and it is already correctly shaped; it needs the right band and funding.
- **Selling** a Credit is priced at the better of the points value and the NFT floor. The engine never asks less than the market pays for the picture.
- **Selling** a Statement is priced a little over par, since ETH is the scarce asset and par is what conversion yields; the sale gets real time before conversion.

Two references feed every price. Both are bounded, both fail closed on the side that would cost the engine:

| reference | what | source | failure |
|---|---|---|---|
| **P**, the $BALANCE price (ETH per token) | par per point: `P_buy` for bids, `P_sell` for asks | the Uniswap v4 pool through ControllerV2's protected reference (unchanged: prior block sample, rate and step bound, liquidity gate) | unusable quote closes the ETH bid and every value mode ask |
| **F**, the Credit floor (ETH per Credit) | the price the market pays for any Credit, whatever its points | posted by the keeper from the top OpenSea collection offer, inside an owner band, step and interval bound | no post or a stale post keeps the last value: asks can only be too high; no buy door reads it |

Nothing else is an oracle. The per point multipliers of the market (about 1.21 times par on the ask side, 0.85 on the bid side today) stay owner parameters, read off `/market-compare`, because they move slowly and a wrong value costs at most a spread, never a giveaway.

## 2. Every door

Notation: `pts` the Credit's score in points, `P_buy`/`P_sell` the protected buy and sell price per point (`valuePerPoint(false)` / `(true)`), `F` the posted floor, all owner settings in bps.

| door | price | parameters (proposed) | why |
|---|---|---|---|
| ETH bid (`sellForEth`, `buyListing`) | `shared * P_buy * pts`, `shared` in `[10,000 - balanceBidMarginBps, balanceBidCapBps]`, clamped to the funded room; unchanged mechanics | `balanceBidCapBps` 10,000 (PR 190), `balanceBidMarginBps` 1,000 (floor 0.9 par), `callerFee` 0, `reserveWei` 0.02 ETH | at most par: an ETH point never costs more than the $BALANCE point it becomes. 0.9 par beats the market's bid side (0.85) for every big Credit. `callerFee` 0 stops the refresh door drain (gas refund only, no bounty, so a searcher earns nothing); a 0.02 ETH reserve lets a small pot bid while still refunding compose gas at today's base fees (section 3) |
| $BALANCE bid (treasury v2 `sellCredit`) | `bidBps * pts` $BALANCE, `bidBps` in `[floorBps, capBps]`, climbs while idle, drops per 100 points filled, capped by the ETH bid value plus `overEthBps`; unchanged mechanics | `floorBps` 8,000, `capBps` **9,700**, climb 50 bps per 600 s, drop 29 bps per 100 points, `overEthBps` 500, per call 20,000, per day 60,000 | 9,700 is break-even: `0.97 * 1.03 = 0.999` of par leaves the treasury with at least the $BALANCE the Credit brings back on conversion. Above 503 points the bid beats the market's flat offer; below it the market should keep the Credit (section 4, the /exchange comparison) |
| Credit sale (`buyCredit`) | start `creditStartBps` of the floor, straight line over `creditWindow` to the floor; **floor = max(cost * saleFloorBps, F * (1 + floorSpreadBps), P_sell * pts * floorMultBps)** | `floorSpreadBps` 300; `creditSpreadBps` **2,000** so `floorMultBps = 1.2 * 10,000 = 12,000` after the cap drops; window and start unchanged | the ask is never under the picture's price nor under the points' price. With `F` 0.0087 the three example Credits ask 0.008858 each (fork replay), the round trip through OpenSea stops paying, and a buyer pays the engine 3.3 times the recorded sale. Big Credits keep asking 1.2 par, at the market's ask side |
| Statement sale (`buy`) | `max(cost * saleFloorBps, ceil(P_sell * rating * floorMultBps * statementSaleMultiplierBps))` unchanged | `statementSaleMultiplierBps` **10,000** (ask 1.2 par on the 1.2 reference), `statementRedeemDelaySeconds` **604,800** (7 days) | 1.2 par sits inside today's Statement fills (1.0 to 1.5 par bid side, 2 to 5 par on listings before the token opened). ETH is the scarce asset: a Statement sold at 1.2 par brings 20 percent more than conversion, so the sale gets a week before the conversion takes it at par |
| Statement conversion | `rating * unitPerPoint`, 10 percent earmarked, unchanged | | the par anchor |
| CC redemption (PR 190 `MarketRedeemer`) | `ccIn * min(CC ref, prior sample, spot) / max(BAL ref, prior sample, spot) * (1 + premiumBps)` unchanged | `premiumBps` **0 to 200** (was 500); caps unchanged; stays off until the ETH side is funded | a premium is a standing arbitrage that sells $BALANCE into the pool through the arbitrageur; at 0 to 200 bps it still pays burners more than the market with no free round trip |
| keeper listing buys | unchanged: at most the ETH bid; the keeper keeps buying only listings under the bid | | with the bid at par and listings at 1.21 par nothing fills until the market comes to par; the keeper should also stop paying for discovery while the bid reads 0 |

Booked cost of a $BALANCE bought Credit stays the Core's `ethFloorNow * pts` (immutable); the floor term makes the ask independent of it for small Credits, which is the point.

## 3. Contract changes (smallest set)

All in ControllerV3 on the PR 190 branch. Treasury v2, the Core and ControllerV2 are untouched.

1. **Credit floor reference** (about 60 lines, the exact code is `test/pricing/ControllerV2Floor.sol`, the evidence copy):
   - storage `creditFloorWei` (uint128), `creditFloorTime` (uint40), `floorPoster` (address), `floorBounds { minWei, maxWei, stepBps, minSeconds, spreadBps }`;
   - `setFloorBounds`, `setFloorPoster` (owner); `postCreditFloor(uint256)` by the poster (clamped into the band, at most `stepBps` from the previous post, at least `minSeconds` apart) or the owner (clamped into the band only);
   - view `creditFloorAsk() = creditFloorWei * (10,000 + spreadBps) / 10,000`;
   - `_creditPrice` raises its floor to `creditFloorAsk()` after the Core cost floor and before the start multiplier. No other function reads it.
   - events `CreditFloorPosted(poster, wei)`, `FloorBoundsSet`, `FloorPosterSet`.
2. **Loop closure** stays as PR 190 has it (`_checkLoopClosure` with the idle cap). The floor term only raises asks, so it cannot open a loop.
3. **Constructor** gains the floor bounds and poster so the deploy sets them in one step; `Phase3.params()` carries them.
4. **Build identity**: ControllerV3 is 19,791 bytes at PR 190's head; the addition fits under EIP-170 with about 4 KB of room. Re-pin `script/Checks.sol` and `test/BuildIdentity.t.sol`.

Owner settings send (the `SetSettings` send PR 190 already plans, extended with the two pot fields), from the main checkout, the no-keystore dry run with its gas estimate first:

```bash
cd /Users/dd/CascadeProjects/cc/cc && CORE=0xcdb1889ae12074d750CD9B8531B692015465e0dD SET_balanceBidCapBps=10000 SET_callerFee=0 SET_reserveWei=20000000000000000 forge script script/SetSettings.s.sol --rpc-url https://mainnet.gateway.tenderly.co --sender 0xCB43078C32423F5348Cab5885911C3B5faE217F9 -vvvv
```

then the same command with `SEND=1 --account ripe0x --broadcast --slow` in place of `--sender …`. The script prints the before and after table and the calldata; the three fields change nothing else. Controller settings (`setCredit` spread 2,000, `setStatementSaleMultiplierBps` 10,000, `setStatementRedeemDelaySeconds` 604,800, `setFloorBounds`, `setFloorPoster`, the first `postCreditFloor`) go into `Phase3.s.sol`'s migrate step, which already sets the Statement values.

On `reserveWei`: with `callerFee` 0 the only caller payment left is the gas refund of compose and redemption at up to `callerMaxBaseFee` (3 gwei); 0.02 ETH refunds about 6.7M gas at that ceiling, so a compose at a 3 gwei base fee is refunded in part and in full at today's base fees under 1 gwei. The owner and users call compose (decision 273), so a partial refund stalls nothing; the reserve's other job, keeping the ETH bid from spending the last wei, is served at 0.02 ETH.

Proposed floor bounds at deployment: `minWei` 0.004 ETH, `maxWei` 0.03 ETH, `stepBps` 1,000, `minSeconds` 600, `spreadBps` 300; poster the keeper (0x6b94…). The owner seeds the first post from the top collection offer in the migrate run.

## 4. Off chain

- **Keeper**: one door, `postCreditFloor`, from the top executable collection offer (the keeper already has the OpenSea key and the discovery loop): post when the value moved more than 300 bps since the last post and `minSeconds` passed; unpaid; cost bounded like the reference refresh. Skip discovery and listing signing while `ethRate()` reads 0.
- **Web /exchange**: beside the $BALANCE payout show "OpenSea offer for any Credit: 0.0087 ETH (489 $BALANCE at spot)" from the keeper's market view, and mark Credits whose payout is under it. `/market-compare` adds the floor row and the bid side multiplier so the owner can tune `creditSpreadBps`.
- **Indexer**: the three events.

## 5. Interaction with PR 190

| PR 190 item | this design |
|---|---|
| treasury v2 buckets, cushion, sweep, redeemers, caps, epochs | keep |
| `sellCredit` bid 8,000 to 10,000, climb, drop, eth bound, per call and per day caps, loop guard | keep; cap 9,700 |
| `setBid` refuses a cap above 10,000 | keep (9,700 is inside) |
| ControllerV3 idle loosening shipped at cap 0 | keep at 0; the ETH bid never exceeds par |
| ControllerV3 Statement 11,000 over the 1.1 reference, delay 3,600 | 10,000 over the 1.2 reference, delay 604,800 (owner decision 280 restored) |
| quote step 900, band check | keep |
| `balanceBidCapBps` to 10,000 by SetSettings | keep, add `callerFee` 0 and `reserveWei` 0.02 ETH to the same send; raise `creditSpreadBps` to 2,000 in the same migrate run so the sale floor does not drop to 1.1 par |
| MarketRedeemer premium 500, sweep 7,500 to it | premium 0 to 200; shares unchanged; stays off |
| CC reference, prior samples | keep |
| `creditSoldAt` record | keep |
| new | Credit floor reference on ControllerV3; keeper post door; /exchange comparison |

It fits in PR 190 as one more ControllerV3 feature and one keeper door. If the owner prefers PR 190 to land first, the floor reference is its own small follow-up PR with a second `setController`; the cap must then not drop to 10,000 before `creditSpreadBps` rises to 2,000.

## 6. What the design answers

- **Each door's reference**: bids follow P (on chain, protected); the Credit ask follows max(P, F); the Statement ask follows P; conversion is par; redemption follows the two pool references. F is keeper-posted inside an owner band because no on-chain source for the NFT floor exists; a wrong F can only raise an ask, never lower a bid.
- **Never below the market, never above it**: asks ≥ max(cost, F, 1.2 par); bids ≤ par (0.97 in $BALANCE with the royalty). For small Credits the engine does not bid above the floor and does not ask under it; for big Credits it bids 0.9 to 1.0 par against a 0.85 market and asks 1.2 against a 1.21 market.
- **Where the arbitrage goes**: today to the bot (69 percent of value). With F in the ask the engine keeps it; a bot still earns the 3 percent spread for carrying the Credit to a listing, which is the service it provides.
- **Can the bids buy at live prices without losing**: yes, for Credits over about 500 points, in the band 0.85 to 0.97 par; the ETH bid additionally needs a funded pot, which means closing the refresh drain and pricing the Statement sale where it clears. No bid can win a Credit under 490 points without paying the NFT floor, which converts to a loss of up to 80 percent on conversion, so none should.
- **Owner parameters and bounds**: `balanceBidCapBps` ≤ 10,000; treasury `capBps` ≤ 9,700 (or the owner accepts a 3 percent $BALANCE loss per point at 10,000); `creditSpreadBps` ≥ loop closure, tuned to the ask side multiplier; `statementSaleMultiplierBps` ≥ 10,000; floor band `[minWei, maxWei]` set from the observed floor with a step and interval; `callerFee` 0 while the pot is small.
- **Smallest contract change**: the floor term in ControllerV3 and nothing in the treasury or the Core.

## 7. Decisions for the owner, with recommendations

1. Accept the Credit floor reference (keeper-posted, owner-bounded) in ControllerV3. Recommended.
2. Treasury bid cap 9,700 instead of 10,000. Recommended (break-even with the royalty).
3. `creditSpreadBps` 2,000 when the Core cap goes to 10,000. Recommended (keeps the sale floor at 1.2 par).
4. Statement ask 1.2 par and a 7 day delay. Recommended (ETH is scarce; the sale needs time).
5. `callerFee` 0 and `reserveWei` 0.02 ETH. Recommended (stops the drain, reopens the ETH bid).
6. MarketRedeemer premium 0 to 200 bps. Recommended 100.
7. Whether to adopt the four launch era pile Credits (cost up to 9.6 par) into a page rather than hold them for sale; they will not sell at cost. Not urgent; the $BALANCE bid fills the page.
