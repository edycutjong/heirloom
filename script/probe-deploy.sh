#!/usr/bin/env bash
# Day-1 probe deploy: ProbeCallback on Base Sepolia, ProbeReactive on Lasna, subscriptions.
# Keys are read from $HEIRLOOM_ENV (default ~/.config/reactive/testnet-deployer.env); nothing secret lives in the repo.
set -euo pipefail
set -a; source "${HEIRLOOM_ENV:-$HOME/.config/reactive/testnet-deployer.env}"; set +a
cd "$(dirname "$0")/.."
BASE_SEPOLIA_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
USDC_BASE_SEPOLIA=0x036CbD53842c5426634e7929541eC2318f3dCF7e
USDC_ETH_SEPOLIA=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
USDC_UNI_SEPOLIA=0x31d0220469e10c4E71834a79b1f276d740d3768F
CB_FUND=${CB_FUND:-0.00003ether}
RC_FUND=${RC_FUND:-0.5ether}

forge build >/dev/null
CB=${PROBE_CB:-}
[ -n "$CB" ] || CB=$(forge create src/probe/ProbeCallback.sol:ProbeCallback --broadcast --rpc-url "$BASE_SEPOLIA_RPC" \
  --private-key "$DEPLOYER_PRIVATE_KEY" --value "$CB_FUND" --json --constructor-args "$BASE_SEPOLIA_PROXY" | sed -n "/^{/,\$p" | jq -r .deployedTo)
echo "ProbeCallback (84532): $CB"
RC=$(forge create src/probe/ProbeReactive.sol:ProbeReactive --broadcast --rpc-url "$LASNA_RPC" \
  --private-key "$DEPLOYER_PRIVATE_KEY" --value "$RC_FUND" --json --constructor-args 84532 "$CB" "${MAX_CB:-6}" "${MAX_CRON:-4}" | sed -n "/^{/,\$p" | jq -r .deployedTo)
echo "ProbeReactive (5318007): $RC"
send() { cast send "$RC" "$@" --rpc-url "$LASNA_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --json | jq -r '.transactionHash + " " + .status'; }
echo "watch Base Sepolia USDC: $(send 'watchToken(uint256,address)' 84532 $USDC_BASE_SEPOLIA)"
echo "watch Eth Sepolia USDC:  $(send 'watchToken(uint256,address)' 11155111 $USDC_ETH_SEPOLIA)"
echo "watch Uni Sepolia USDC:  $(send 'watchToken(uint256,address)' 1301 $USDC_UNI_SEPOLIA)"
echo "watch Ack (Pinged):      $(send 'watchAck()')"
printf 'PROBE_CB=%s\nPROBE_RC=%s\n' "$CB" "$RC" > "${ADDR_FILE:-evidence/probe-addresses.txt}"
