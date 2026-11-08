#!/usr/bin/env bash
# Deploy one Heirloom instance on testnet: HeirloomReactive (Lasna) -> HeirloomVault (Base Sepolia) -> setVault.
# Keys come from $HEIRLOOM_ENV (default ~/.config/reactive/testnet-deployer.env); nothing secret lives in the repo.
# Every tunable is an env var; defaults = the short-T end-to-end instance (T 4 min, grace 2 min).
set -euo pipefail
set -a; source "${HEIRLOOM_ENV:-$HOME/.config/reactive/testnet-deployer.env}"; set +a
cd "$(dirname "$0")/.."

INSTANCE=${INSTANCE:-p1b-e2e}
OUT=${OUT:-evidence/$INSTANCE-addresses.txt}
OWNER=${OWNER:-$DEPLOYER_ADDRESS}          # the watched wallet (scripted heartbeats on testnet)
HEIR=${HEIR:?set HEIR (address that receives the estate)}

BASE_SEPOLIA_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
USDC_BASE_SEPOLIA=0x036CbD53842c5426634e7929541eC2318f3dCF7e
CANARY_BASE_SEPOLIA=0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3   # Chainlink ETH/USD aggregator (AnswerUpdated emitter)
CRON10=0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687

T=${T:-240}; GRACE=${GRACE:-120}; FREEZE=${FREEZE:-120}; ATTEST=${ATTEST:-180}; ACK=${ACK:-30}; TICK=${TICK:-11}
BRAKE_WINDOW=${BRAKE_WINDOW:-600}; MAX_REFUSED=${MAX_REFUSED:-20}; CRON=${CRON:-$CRON10}; GRACE_CRON=${GRACE_CRON:-0}
CANARY_GAP=${CANARY_GAP:-3633}; CLAIM_DELAY=${CLAIM_DELAY:-120}; CAP=${CAP:-5000000}
RC_FUND=${RC_FUND:-1.2ether}; VAULT_FUND=${VAULT_FUND:-0.0002ether}; DEPOSIT=${DEPOSIT:-4000000}

# claimDelay must cover the resend bound: 3 x ceil(ack/tick) x tick + one tick (architecture.md)
BOUND=$(( 3 * ((ACK + TICK - 1) / TICK) * TICK + TICK ))
[ "$CLAIM_DELAY" -ge "$BOUND" ] || { echo "CLAIM_DELAY $CLAIM_DELAY < resend bound $BOUND" >&2; exit 1; }

forge build >/dev/null
create() { # rpc contract value args...
  local rpc=$1 c=$2 v=$3; shift 3
  local extra=(); [ $# -gt 0 ] && extra=(--constructor-args "$@")   # must stay last (variadic)
  forge create "$c" --broadcast --rpc-url "$rpc" --private-key "$DEPLOYER_PRIVATE_KEY" --value "$v" --json \
    ${extra[@]+"${extra[@]}"} | sed -n "/^{/,\$p" | jq -r .deployedTo
}
send() { # rpc to sig args... -> "hash status"
  local rpc=$1; shift
  cast send "$@" --rpc-url "$rpc" --private-key "$DEPLOYER_PRIVATE_KEY" --json | jq -r '.transactionHash + " " + .status'
}

TOKEN_BASE=${TOKEN_BASE:-$(create "$BASE_SEPOLIA_RPC" src/testnet/TestDollar.sol:TestDollar 0)}
TOKEN_ETH=${TOKEN_ETH:-$(create "$ETHEREUM_SEPOLIA_RPC" src/testnet/TestDollar.sol:TestDollar 0)}
echo "tHTD Base Sepolia: $TOKEN_BASE  Eth Sepolia: $TOKEN_ETH"
[ "$(cast call "$TOKEN_BASE" 'balanceOf(address)(uint256)' "$OWNER" --rpc-url "$BASE_SEPOLIA_RPC" | cut -d' ' -f1)" != 0 ] ||
  echo "mint base: $(send "$BASE_SEPOLIA_RPC" "$TOKEN_BASE" 'mint(address,uint256)' "$OWNER" 100000000)"
[ "$(cast call "$TOKEN_ETH" 'balanceOf(address)(uint256)' "$OWNER" --rpc-url "$ETHEREUM_SEPOLIA_RPC" | cut -d' ' -f1)" != 0 ] ||
  echo "mint eth:  $(send "$ETHEREUM_SEPOLIA_RPC" "$TOKEN_ETH" 'mint(address,uint256)' "$OWNER" 100000000)"

LASNA_FROM=$(cast block-number --rpc-url "$LASNA_RPC")
BASE_FROM=$(cast block-number --rpc-url "$BASE_SEPOLIA_RPC")
CFG="($T,$GRACE,$FREEZE,$ATTEST,$ACK,$TICK,$BRAKE_WINDOW,$MAX_REFUSED,$CRON,$GRACE_CRON,84532,$BASE_SEPOLIA_PROXY)"
RC=$(create "$LASNA_RPC" src/HeirloomReactive.sol:HeirloomReactive "$RC_FUND" "$OWNER" "$CFG")
echo "HeirloomReactive (5318007): $RC"

VAULT=$(create "$BASE_SEPOLIA_RPC" src/HeirloomVault.sol:HeirloomVault "$VAULT_FUND" \
  "$BASE_SEPOLIA_PROXY" "$RC" "$OWNER" "$HEIR" "$CLAIM_DELAY" "$CAP" \
  "[84532,11155111,84532]" "[$TOKEN_BASE,$TOKEN_ETH,$USDC_BASE_SEPOLIA]")
echo "HeirloomVault (84532): $VAULT"

echo "setVault: $(send "$LASNA_RPC" "$RC" 'setVault(address,(uint256,address)[],(uint256,address,uint64)[])' "$VAULT" \
  "[(84532,$TOKEN_BASE),(11155111,$TOKEN_ETH),(84532,$USDC_BASE_SEPOLIA)]" "[(84532,$CANARY_BASE_SEPOLIA,$CANARY_GAP)]")"

cat > "$OUT" <<EOF
INSTANCE=$INSTANCE
RC=$RC
VAULT=$VAULT
OWNER=$OWNER
HEIR=$HEIR
TOKEN_BASE=$TOKEN_BASE
TOKEN_ETH=$TOKEN_ETH
USDC_BASE=$USDC_BASE_SEPOLIA
CANARY_BASE=$CANARY_BASE_SEPOLIA
LASNA_FROM=$LASNA_FROM
BASE_FROM=$BASE_FROM
T=$T
GRACE=$GRACE
ATTEST=$ATTEST
CLAIM_DELAY=$CLAIM_DELAY
EOF
echo "wrote $OUT"
