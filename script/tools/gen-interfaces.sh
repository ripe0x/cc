#!/usr/bin/env bash
# regenerates src/interfaces/ICore.sol, IControllerV1.sol, IControllerV2.sol, ICoreLib.sol, ICoreOpsLib.sol,
# ISeaportBasicAdapter.sol, ICreditStrategyAdapter.sol, IStatementBalanceModule.sol, IPhase2BalanceTreasury.sol,
# IProRataRedemptionPolicy.sol, IControllerV3.sol, IBalanceTreasuryV2.sol, IProRataRedeemer.sol and IMarketRedeemer.sol from the production abi.
# tests and scripts use these instead of importing the production sources, so they compile without via_ir.
# usage: script/tools/gen-interfaces.sh [--check]   (--check fails when a committed file differs from the abi)
set -euo pipefail
cd "$(dirname "$0")/../.."
mode="${1:-write}"
tmp="$(mktemp -d)"
forge build --quiet src/Core.sol src/ControllerV1.sol src/ControllerV2.sol src/lib/CoreLib.sol src/lib/CoreOpsLib.sol src/adapters/SeaportBasicAdapter.sol src/adapters/CreditStrategyAdapter.sol src/adapters/StatementBalanceModule.sol src/adapters/Phase2BalanceTreasury.sol src/adapters/ProRataRedemptionPolicy.sol src/ControllerV3.sol src/adapters/BalanceTreasuryV2.sol src/adapters/ProRataRedeemer.sol src/adapters/MarketRedeemer.sol 2>/dev/null
for pair in Core:ICore ControllerV1:IControllerV1 ControllerV2:IControllerV2 CoreLib:ICoreLib CoreOpsLib:ICoreOpsLib SeaportBasicAdapter:ISeaportBasicAdapter CreditStrategyAdapter:ICreditStrategyAdapter StatementBalanceModule:IStatementBalanceModule Phase2BalanceTreasury:IPhase2BalanceTreasury ProRataRedemptionPolicy:IProRataRedemptionPolicy ControllerV3:IControllerV3 BalanceTreasuryV2:IBalanceTreasuryV2 ProRataRedeemer:IProRataRedeemer MarketRedeemer:IMarketRedeemer; do
  c="${pair%%:*}"; i="${pair##*:}"
  python3 -c "import json,sys;print(json.dumps(json.load(open('out/$c.sol/$c.json'))['abi']))" > "$tmp/$c.json"
  cast interface "$tmp/$c.json" -n "$i" -p '^0.8.28' -o "$tmp/$i.raw.sol" >/dev/null
  python3 script/tools/fix-interface.py "$tmp/$i.raw.sol" "$i" > "$tmp/$i.sol"
  if [ "$mode" = "--check" ]; then diff -q "$tmp/$i.sol" "src/interfaces/$i.sol"; else cp "$tmp/$i.sol" "src/interfaces/$i.sol"; fi
done
rm -rf "$tmp"
