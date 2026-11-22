#!/usr/bin/env bash
# Short-T end-to-end scenario on a deployed testnet instance (see heirloom-deploy.sh):
#   deposit -> heartbeat (Eth Sepolia) -> zero-value spoof (Circle USDC, Base Sepolia, from a stranger)
#   -> silence -> GRACE -> heartbeat (Base Sepolia) -> CANCEL
#   -> silence -> GRACE -> EXPIRE -> CLAIMABLE -> initiateClaim -> claimDelay -> finalizeClaim -> RC torn down.
# STEP=revive (run between setup and expire; not part of "all"): silence -> GRACE -> EXPIRE -> CLAIMABLE, nobody claims
#   -> heartbeat (Eth Sepolia) -> REVIVE -> RC ARMED, vault ARMED.  Full run: STEP=setup, STEP=revive, STEP=expire.
# Every action is logged to evidence/<instance>-actions.csv; scripts/heirloom-triples.ts joins them with the logs.
# STRANGER_ENV: env file whose PROBE_PRIVATE_KEY signs the spoof and finalizeClaim (any wallet that is not the owner).
# THIRD_ENV: env file whose PRIVATE_KEY presses initiateClaim (neither owner nor heir: the claim is permissionless, it pays only the heir).
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
THIRD_KEY=$(set -a; source "${THIRD_ENV:-$HOME/.config/heirloom/stranger.env}"; echo "$PRIVATE_KEY")
STEP=${STEP:-all}
# The Foundry harness fabricates LogRecord.opCode (= topic count); only the live network can prove a real Transfer
# passes the MALFORMED / ZERO_VALUE filters, so the run fails if a heartbeat is not Seen by the reactive contract.
assert_seen() { # lasna_from_block origin_tx
  local from=$1 want; want=$(echo "${2#0x}" | tr 'A-F' 'a-f'); local start=$SECONDS t0; t0=$(cast keccak 'Seen(uint256,address,uint256)')
  while [ $((SECONDS - start)) -lt 180 ]; do
    if cast logs --rpc-url "$LASNA_RPC" --from-block "$from" --address "$RC" "$t0" 2>/dev/null | tr 'A-F' 'a-f' | grep -q "$want"; then
      say "heartbeat 0x$want Seen by the reactive contract"; return 0
    fi
    sleep 5
  done
  say "FAIL: heartbeat 0x$want not Seen within 180 s"; return 1
}

if [ "$STEP" = all ] || [ "$STEP" = setup ]; then
  act approve 84532 "$B" "$K" "$THTD_BASE" 'approve(address,uint256)' "$VAULT" 4000000
  act deposit 84532 "$B" "$K" "$VAULT" 'deposit(address,uint256)' "$THTD_BASE" 4000000
  SEEN_FROM=$(cast block-number --rpc-url "$LASNA_RPC")
  act heartbeat 11155111 "$ETHEREUM_SEPOLIA_RPC" "$K" "$THTD_ETH" 'transfer(address,uint256)' "$HEIR" 1000000
  assert_seen "$SEEN_FROM" "$(tail -1 "$LOG" | cut -d, -f3)"
  act spoof 84532 "$B" "$STRANGER_KEY" "$USDC_BASE" 'transferFrom(address,address,uint256)' "$OWNER" "$HEIR" 0
fi

if [ "$STEP" = all ] || [ "$STEP" = cancel ]; then
  wait_for "rc phase" phase 1 $((T + 300))
  wait_for "vault state" vstate 1 120
  act heartbeat 84532 "$B" "$K" "$THTD_BASE" 'transfer(address,uint256)' "$HEIR" 1000000
  wait_for "rc phase" phase 0 120
  wait_for "vault state" vstate 0 120
fi

# The owner comes back after the expiry, before anyone presses initiateClaim: the RC sends REVIVE, the vault re-arms.
if [ "$STEP" = revive ]; then
  wait_for "rc phase" phase 1 $((T + 300))
  wait_for "rc phase" phase 2 $((GRACE + 300))
  wait_for "vault state" vstate 2 180   # CLAIMABLE: the heir could start a claim now; nobody does
  SEEN_FROM=$(cast block-number --rpc-url "$LASNA_RPC")
  act heartbeat 11155111 "$ETHEREUM_SEPOLIA_RPC" "$K" "$THTD_ETH" 'transfer(address,uint256)' "$HEIR" 1000000
  assert_seen "$SEEN_FROM" "$(tail -1 "$LOG" | cut -d, -f3)"
  wait_for "rc phase" phase 0 180       # REVIVE sent
  wait_for "vault state" vstate 0 180   # REVIVE applied on Base
fi

if [ "$STEP" = all ] || [ "$STEP" = expire ]; then
  wait_for "rc phase" phase 1 $((T + 300))
  wait_for "rc phase" phase 2 $((GRACE + 300))
  wait_for "vault state" vstate 2 180
  act initiateClaim 84532 "$B" "$THIRD_KEY" "$VAULT" 'initiateClaim()'   # a third wallet: neither owner nor heir
  sleep $((CLAIM_DELAY + 5))
  act finalizeClaim 84532 "$B" "$STRANGER_KEY" "$VAULT" 'finalizeClaim()'   # the heir's wallet (the probe key)
  wait_for "vault state" vstate 4 60
  wait_for "rc phase" phase 3 180
  say "heir balance: $(cast call "$THTD_BASE" 'balanceOf(address)(uint256)' "$HEIR" --rpc-url "$B")"
fi
say "scenario done"
