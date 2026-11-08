#!/usr/bin/env bash
# Short-T end-to-end scenario on a deployed testnet instance (see heirloom-deploy.sh):
#   deposit -> heartbeat (Eth Sepolia) -> zero-value spoof (Circle USDC, Base Sepolia, from a stranger)
#   -> silence -> GRACE -> heartbeat (Base Sepolia) -> CANCEL
#   -> silence -> GRACE -> EXPIRE -> CLAIMABLE -> initiateClaim -> claimDelay -> finalizeClaim -> RC torn down.
# Every action is logged to evidence/<instance>-actions.csv; scripts/heirloom-triples.ts joins them with the logs.
# STRANGER_ENV: env file whose PROBE_PRIVATE_KEY signs the spoof (any wallet that is not the owner).
set -euo pipefail
set -a; source "${HEIRLOOM_ENV:-$HOME/.config/reactive/testnet-deployer.env}"; set +a
cd "$(dirname "$0")/.."
ADDR=${ADDR:?set ADDR=evidence/<instance>-addresses.txt}
set -a; source "$ADDR"; set +a
LOG=evidence/$INSTANCE-actions.csv
[ -f "$LOG" ] || echo "step,chain_id,tx,status,sent_at_ms,note" > "$LOG"

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
say() { echo "$(date -u +%H:%M:%S) $*"; }
act() { # step chain rpc key to sig args...
  local step=$1 chain=$2 rpc=$3 key=$4; shift 4
  local t; t=$(now_ms)
  local r; r=$(cast send "$@" --rpc-url "$rpc" --private-key "$key" --json | jq -r '.transactionHash + "," + .status')
  echo "$step,$chain,$r,$t," >> "$LOG"; say "$step $r"
}
phase() { cast call "$RC" 'phase()(uint8)' --rpc-url "$LASNA_RPC"; }
vstate() { cast call "$VAULT" 'state()(uint8)' --rpc-url "$BASE_SEPOLIA_RPC"; }
wait_for() { # what fn want timeout_s
  local what=$1 fn=$2 want=$3 limit=$4 start=$SECONDS v=""
  while :; do
    v=$($fn 2>/dev/null || echo "?")
    [ "$v" = "$want" ] && { say "$what = $want after $((SECONDS - start)) s"; return 0; }
    [ $((SECONDS - start)) -ge "$limit" ] && { say "TIMEOUT waiting for $what = $want (last $v)"; return 1; }
    sleep 5
  done
}
K=$DEPLOYER_PRIVATE_KEY
B=$BASE_SEPOLIA_RPC
STRANGER_KEY=$(set -a; source "${STRANGER_ENV:-$HOME/.config/dreamdex/probe.env}"; echo "$PROBE_PRIVATE_KEY")
STEP=${STEP:-all}

if [ "$STEP" = all ] || [ "$STEP" = setup ]; then
  act approve 84532 "$B" "$K" "$TOKEN_BASE" 'approve(address,uint256)' "$VAULT" 4000000
  act deposit 84532 "$B" "$K" "$VAULT" 'deposit(address,uint256)' "$TOKEN_BASE" 4000000
  act heartbeat 11155111 "$ETHEREUM_SEPOLIA_RPC" "$K" "$TOKEN_ETH" 'transfer(address,uint256)' "$HEIR" 1000000
  act spoof 84532 "$B" "$STRANGER_KEY" "$USDC_BASE" 'transferFrom(address,address,uint256)' "$OWNER" "$HEIR" 0
fi

if [ "$STEP" = all ] || [ "$STEP" = cancel ]; then
  wait_for "rc phase" phase 1 $((T + 300))
  wait_for "vault state" vstate 1 120
  act heartbeat 84532 "$B" "$K" "$TOKEN_BASE" 'transfer(address,uint256)' "$HEIR" 1000000
  wait_for "rc phase" phase 0 120
  wait_for "vault state" vstate 0 120
fi

if [ "$STEP" = all ] || [ "$STEP" = expire ]; then
  wait_for "rc phase" phase 1 $((T + 300))
  wait_for "rc phase" phase 2 $((GRACE + 300))
  wait_for "vault state" vstate 2 180
  act initiateClaim 84532 "$B" "$K" "$VAULT" 'initiateClaim()'
  sleep $((CLAIM_DELAY + 5))
  act finalizeClaim 84532 "$B" "$K" "$VAULT" 'finalizeClaim()'
  wait_for "vault state" vstate 4 60
  wait_for "rc phase" phase 3 180
  say "heir balance: $(cast call "$TOKEN_BASE" 'balanceOf(address)(uint256)' "$HEIR" --rpc-url "$B")"
fi
say "scenario done"
