#!/usr/bin/env bash
# Day-1 probe origins: zero-value USDC Transfer(from = owner) on three Sepolia chains + one spoof transferFrom.
# Appends chain,kind,tx,block,sent_at_ms,mined_at_ms to evidence/probe-origins.csv.
set -euo pipefail
set -a; source "${HEIRLOOM_ENV:-$HOME/.config/reactive/testnet-deployer.env}"; source "${SPOOFER_ENV:-$HOME/.config/dreamdex/probe.env}"; set +a
cd "$(dirname "$0")/.."
OUT=evidence/probe-origins.csv
[ -f $OUT ] || echo "chain_id,kind,origin_tx,block,sent_at_ms,mined_at_ms" > $OUT
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
fire() { # chain rpc token kind key args...
  local chain=$1 rpc=$2 token=$3 kind=$4 key=$5; shift 5
  local t0=$(ms); local j=$(cast send "$token" "$@" --rpc-url "$rpc" --private-key "$key" --json); local t1=$(ms)
  local tx=$(echo "$j" | jq -r .transactionHash) blk=$(echo "$j" | jq -r .blockNumber) st=$(echo "$j" | jq -r .status)
  [ "$st" = "0x1" ] || { echo "FAILED $kind $tx"; return 1; }
  echo "$chain,$kind,$tx,$((blk)),$t0,$t1" | tee -a $OUT
}
case "${1:-all}" in
  base|fail|all) fire 84532 "$BASE_SEPOLIA_RPC" 0x036CbD53842c5426634e7929541eC2318f3dCF7e "owner-transfer${KIND_SUFFIX:-}" "$DEPLOYER_PRIVATE_KEY" 'transfer(address,uint256)' "$PROBE_ADDRESS" 0 ;;&
  eth|all) fire 11155111 "$ETHEREUM_SEPOLIA_RPC" 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 owner-transfer "$DEPLOYER_PRIVATE_KEY" 'transfer(address,uint256)' "$PROBE_ADDRESS" 0 ;;&
  uni|all) fire 1301 "$UNICHAIN_SEPOLIA_RPC" 0x31d0220469e10c4E71834a79b1f276d740d3768F owner-transfer "$DEPLOYER_PRIVATE_KEY" 'transfer(address,uint256)' "$PROBE_ADDRESS" 0 ;;&
  spoof|all) fire 84532 "$BASE_SEPOLIA_RPC" 0x036CbD53842c5426634e7929541eC2318f3dCF7e spoof-transferFrom-0 "$PROBE_PRIVATE_KEY" 'transferFrom(address,address,uint256)' "$DEPLOYER_ADDRESS" "$PROBE_ADDRESS" 0 ;;
esac
