#!/usr/bin/env bash
# regenerates src/interfaces/ICore.sol, IControllerV1.sol and ICoreLib.sol from the production abi.
# tests and scripts use these instead of importing the production sources, so they compile without via_ir.
# usage: script/tools/gen-interfaces.sh [--check]   (--check fails when a committed file differs from the abi)
set -euo pipefail
cd "$(dirname "$0")/../.."
mode="${1:-write}"
tmp="$(mktemp -d)"
forge build --quiet src/Core.sol src/ControllerV1.sol src/lib/CoreLib.sol 2>/dev/null
for pair in Core:ICore ControllerV1:IControllerV1 CoreLib:ICoreLib; do
  c="${pair%%:*}"; i="${pair##*:}"
  python3 -c "import json,sys;print(json.dumps(json.load(open('out/$c.sol/$c.json'))['abi']))" > "$tmp/$c.json"
  cast interface "$tmp/$c.json" -n "$i" -p '^0.8.28' -o "$tmp/$i.raw.sol" >/dev/null
  python3 script/tools/fix-interface.py "$tmp/$i.raw.sol" "$i" > "$tmp/$i.sol"
  if [ "$mode" = "--check" ]; then diff -q "$tmp/$i.sol" "src/interfaces/$i.sol"; else cp "$tmp/$i.sol" "src/interfaces/$i.sol"; fi
done
rm -rf "$tmp"
