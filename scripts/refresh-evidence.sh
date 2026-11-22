#!/usr/bin/env bash
# Idempotent evidence refresh: rejoins every instance's on-chain logs into evidence/triples.csv (upsert by instance|stage|seq|reactive_tx; rows are never dropped; a callback leg is only replaced by an earlier one),
# then recomputes evidence/{status,cost,triples}.json (days live, heartbeats, spoofs refused, REACT balance -> REACT/month, funded-through).
# Safe to re-run any time. Long-lived instances rescan Base Sepolia from BASE_FROM in 180-block pages, which grows slow over weeks. RPCs: LASNA_RPC / BASE_SEPOLIA_RPC / ETHEREUM_SEPOLIA_RPC else public defaults.
# Mainnet instances (after scripts/deploy-mainnet.sh --execute): DEPLOYMENTS=deployments/mainnet.json scripts/refresh-evidence.sh
set -euo pipefail
cd "$(dirname "$0")/.."
TSX=node_modules/.bin/tsx
[ -x "$TSX" ] || { echo "run: pnpm install" >&2; exit 1; }
export DEPLOYMENTS=${DEPLOYMENTS:-deployments/testnet.json}
export RC_CHAIN=$(jq -r '.rcChain // 5318007' "$DEPLOYMENTS") BASE_CHAIN=$(jq -r '.baseChain // 84532' "$DEPLOYMENTS")
for f in $(jq -r '.instances[].addresses' "$DEPLOYMENTS"); do
  [ -f "$f" ] || { echo "skip $f (missing)"; continue; }
  echo "== joining $f"
  ADDR=$f $TSX scripts/heirloom-triples.ts
done
$TSX scripts/evidence-status.ts
mkdir -p status/data
case "$DEPLOYMENTS" in
  *mainnet*) cp evidence/status-mainnet.json evidence/cost-mainnet.json evidence/triples.json status/data/ ;;
  *) cp evidence/status.json evidence/cost.json evidence/triples.json status/data/ ;;
esac
echo "status page data refreshed in status/data/"
