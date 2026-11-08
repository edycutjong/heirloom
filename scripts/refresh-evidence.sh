#!/usr/bin/env bash
# Idempotent evidence refresh: rejoins every instance's on-chain logs into evidence/triples.csv (append-only, first row per key wins),
# then recomputes evidence/{status,cost,triples}.json (days live, heartbeats, spoofs refused, REACT balance -> REACT/month, funded-through).
# Safe to re-run any time; Ledgerlock P7 reruns it. RPCs: LASNA_RPC / BASE_SEPOLIA_RPC / ETHEREUM_SEPOLIA_RPC else public defaults.
set -euo pipefail
cd "$(dirname "$0")/.."
TSX=node_modules/.bin/tsx
[ -x "$TSX" ] || { echo "run: pnpm install" >&2; exit 1; }
for f in $(jq -r '.instances[].addresses' deployments/testnet.json); do
  [ -f "$f" ] || { echo "skip $f (missing)"; continue; }
  echo "== joining $f"
  ADDR=$f $TSX scripts/heirloom-triples.ts
done
$TSX scripts/evidence-status.ts
