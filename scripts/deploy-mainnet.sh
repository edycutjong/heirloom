#!/usr/bin/env bash
# One-command Heirloom production deploy: Instance A (T = 90 d, weekly ATTEST) + Instance B (T = 48 h, ~$5 vault).
#   HeirloomReactive on Reactive (1597) -> HeirloomVault on Base (8453) -> setVault, per instance.
#
#   scripts/deploy-mainnet.sh                    # DRY RUN on mainnet RPCs: read-only preflight + unsent simulations
#   NET=testnet scripts/deploy-mainnet.sh        # DRY RUN against the Lasna / Base Sepolia pair
#   scripts/deploy-mainnet.sh --execute          # spends real funds; refuses unless ../specs/mainnet-authorized exists
#
# Keys: $DEPLOY_ENV (default ~/.config/reactive/mainnet-deployer.env, testnet: testnet-deployer.env). Never in the repo.
# Safety: --execute needs ../specs/mainnet-authorized (the human's go-ahead), only runs with NET=mainnet,
# stops if planned funding exceeds MAX_REACT, keeps a Base ETH reserve, and logs every sent tx to evidence/mainnet-txs.csv
# (ts,chain,tx,purpose,cost_native). Tunables below are env vars; a bad tick/ack/claim combination aborts before anything is sent.
# Resume: rerun the same command after a failure. An instance whose evidence/mainnet-<name>-addresses.txt already names an RC
# reuses it (and its vault, if recorded) after checking code, owner and T on chain; a funded RC is never deployed twice.
set -euo pipefail
cd "$(dirname "$0")/.."

EXECUTE=0; [ "${1:-}" = "--execute" ] && EXECUTE=1
NET=${NET:-mainnet}
case "$NET" in
  mainnet)
    DEPLOY_ENV=${DEPLOY_ENV:-$HOME/.config/reactive/mainnet-deployer.env}
    RC_CHAIN=1597; BASE_CHAIN=8453; EXTRA_CHAIN=1
    RC_RPC_VAR=REACTIVE_MAINNET_RPC; BASE_RPC_VAR=BASE_MAINNET_RPC
    PROXY=0xCc780DdE33f56f55dE778D42c930959374a4a068            # Base mainnet callback proxy
    WATCH_A=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913          # USDC Base
    WATCH_B=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48          # USDC Ethereum
    CANARY=0x05c84a58FE042275b37db038bAAcD15F410c7bB0           # Chainlink ETH/USD aggregator on Base (AnswerUpdated emitter)
    CANARY_GAP=${CANARY_GAP:-3603}
    # Second canary on the other watched chain (an Ethereum ingestion stall must also be able to spend the freeze).
    CANARY_X=0x7d4E742018fb52E48b08BE73d041C18B21de6Fb5         # Chainlink ETH/USD aggregator on Ethereum (evidence/canary-gaps.json)
    CANARY_X_GAP=${CANARY_X_GAP:-7224}; X_RPC=${ETHEREUM_RPC:-https://ethereum-rpc.publicnode.com}
    ;;
  testnet)
    DEPLOY_ENV=${DEPLOY_ENV:-$HOME/.config/reactive/testnet-deployer.env}
    RC_CHAIN=5318007; BASE_CHAIN=84532; EXTRA_CHAIN=11155111
    RC_RPC_VAR=LASNA_RPC; BASE_RPC_VAR=BASE_SEPOLIA_RPC
    PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
    WATCH_A=0x036CbD53842c5426634e7929541eC2318f3dCF7e          # Circle USDC Base Sepolia
    WATCH_B=0x90721E018E2246a6555755D63418686a1A04FD9f          # tHTD Ethereum Sepolia (testnet-only heartbeat token)
    CANARY=0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3
    CANARY_GAP=${CANARY_GAP:-3633}
    CANARY_X=0x719E22E3D4b690E5d96cCb40619180B5427F14AE         # Chainlink ETH/USD aggregator on Ethereum Sepolia
    CANARY_X_GAP=${CANARY_X_GAP:-7272}; X_RPC=${ETHEREUM_SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
    ;;
  *) echo "NET must be mainnet or testnet" >&2; exit 2 ;;
esac
if [ "$EXECUTE" = 1 ]; then
  [ "$NET" = mainnet ] || { echo "--execute is mainnet-only; the testnet pair is dry-run here (use script/heirloom-deploy.sh for live testnet instances)" >&2; exit 2; }
  AUTH_FILE=../specs/mainnet-authorized   # fixed path on purpose: not overridable from the environment
  [ -f "$AUTH_FILE" ] || { echo "refusing to spend: $AUTH_FILE does not exist (the human's go-ahead)" >&2; exit 3; }
fi
set -a; source "$DEPLOY_ENV"; set +a
RC_RPC=${!RC_RPC_VAR:?set $RC_RPC_VAR in $DEPLOY_ENV}; BASE_RPC=${!BASE_RPC_VAR:?set $BASE_RPC_VAR in $DEPLOY_ENV}

OWNER=${OWNER:-$DEPLOYER_ADDRESS}                      # the watched wallet; an everyday wallet if the human sets it
HEIR=${HEIR:?set HEIR (address that receives the estate)}
MAX_REACT=${MAX_REACT:-100}                            # total REACT this run may fund RCs with
MIN_BASE_ETH_WEI=${MIN_BASE_ETH_WEI:-1000000000000000} # keep 0.001 ETH on Base for callback gas
CRON1000=0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4
CRON10000=0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56
BRAKE_WINDOW=${BRAKE_WINDOW:-86400}; MAX_REFUSED=${MAX_REFUSED:-20}
# Callbacks are billed to the VAULT in Base ETH (never REACT); an unfunded vault goes into debt and receives nothing.
# Default = the testnet instances' funding (script/heirloom-deploy.sh); top up later with a transfer + coverDebt().
VAULT_FUND=${VAULT_FUND:-0.0002}

# name:T:grace:freeze:attest:ack:tick:claimDelay:cron:cap:fundREACT   (A: Cron10000 ~ 7.9 ks on mainnet; B: Cron1000 ~ 790 s)
if [ "$NET" = mainnet ]; then DEF_A=40; DEF_B=30; else DEF_A=0.05; DEF_B=0.05; fi   # testnet dry run: token amounts only
A=${A:-A:7776000:604800:604800:604800:3600:8000:604800:$CRON10000:5000000:${A_FUND:-$DEF_A}}
B=${B:-B:172800:21600:21600:86400:1800:800:43200:$CRON1000:5000000:${B_FUND:-$DEF_B}}

LOG=evidence/mainnet-txs.csv
[ "$EXECUTE" = 0 ] || [ -f "$LOG" ] || echo "ts,chain,tx,purpose,cost_native" > "$LOG"
say() { echo "[$NET$([ "$EXECUTE" = 1 ] || echo ' DRY-RUN')] $*"; }
logtx() { # chain txhash purpose rpc   -> logs ts,chain,tx,purpose,cost_native; aborts if the tx did not succeed
  [ "$EXECUTE" = 1 ] || return 0
  local r st gu gp cost; r=$(cast receipt "$2" --rpc-url "$4" --json)
  st=$(jq -r .status <<<"$r"); gu=$(cast to-dec "$(jq -r .gasUsed <<<"$r")"); gp=$(cast to-dec "$(jq -r .effectiveGasPrice <<<"$r")")
  cost=$(awk -v g="$gu" -v p="$gp" 'BEGIN{printf "%.12f", g*p/1e18}')
  echo "$(date -u +%FT%TZ),$1,$2,$3,$cost" >> "$LOG"
  [ "$st" = 0x1 ] || [ "$st" = 1 ] || { echo "TX FAILED (status $st): $2 ($3); see $LOG. Rerunning resumes: recorded contracts are checked on chain and reused" >&2; exit 8; }
}

# ---- preflight (read-only on every mode)
[ "$(cast chain-id --rpc-url "$RC_RPC")" = "$RC_CHAIN" ] || { echo "RC rpc is not chain $RC_CHAIN" >&2; exit 4; }
[ "$(cast chain-id --rpc-url "$BASE_RPC")" = "$BASE_CHAIN" ] || { echo "Base rpc is not chain $BASE_CHAIN" >&2; exit 4; }
for a in "$PROXY" "$WATCH_A" "$CANARY"; do
  [ "$(cast code "$a" --rpc-url "$BASE_RPC" | wc -c)" -gt 4 ] || { echo "no contract code at $a on Base ($BASE_CHAIN)" >&2; exit 4; }
done
say "proxy $PROXY, token A $WATCH_A, canary $CANARY present on Base"
[ "$(cast chain-id --rpc-url "$X_RPC")" = "$EXTRA_CHAIN" ] || { echo "Ethereum rpc is not chain $EXTRA_CHAIN" >&2; exit 4; }
for a in "$WATCH_B" "$CANARY_X"; do
  [ "$(cast code "$a" --rpc-url "$X_RPC" | wc -c)" -gt 4 ] || { echo "no contract code at $a on chain $EXTRA_CHAIN" >&2; exit 4; }
done
say "token B $WATCH_B, canary $CANARY_X present on chain $EXTRA_CHAIN"
RC_BAL=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RC_RPC"); BASE_BAL=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$BASE_RPC")
say "deployer $DEPLOYER_ADDRESS: RC chain $(cast from-wei "$RC_BAL"), Base $(cast from-wei "$BASE_BAL") ETH"

TOTAL_FUND=0; VAULTS_TO_DEPLOY=0
for spec in "$A" "$B"; do
  IFS=: read -r NAME T GRACE FREEZE ATTEST ACK TICK CLAIM CRON CAP FUND <<<"$spec"
  # claimDelay must cover the resend bound: 3 x ceil(ack/tick) x tick + one tick (enforced again on resume: same spec)
  BOUND=$(( 3 * ((ACK + TICK - 1) / TICK) * TICK + TICK ))
  [ "$CLAIM" -ge "$BOUND" ] || { echo "instance $NAME: claimDelay $CLAIM < resend bound $BOUND" >&2; exit 5; }
  [ "$ATTEST" -ge "$ACK" ] || { echo "instance $NAME: attestEvery < ackTimeout" >&2; exit 5; }
  grep -qs '^VAULT=0x' "evidence/mainnet-$NAME-addresses.txt" || VAULTS_TO_DEPLOY=$((VAULTS_TO_DEPLOY + 1))
  if [ "$EXECUTE" = 1 ] && grep -qs '^RC=' "evidence/mainnet-$NAME-addresses.txt"; then
    say "instance $NAME: RC already recorded (resume); its $FUND REACT is not planned again"; continue
  fi
  TOTAL_FUND=$(awk -v a="$TOTAL_FUND" -v b="$FUND" 'BEGIN{print a+b}')
done
if [ "$EXECUTE" = 1 ]; then
  awk -v v="$VAULT_FUND" 'BEGIN{exit !(v>0)}' || { echo "VAULT_FUND must be > 0: callbacks are billed to the vault" >&2; exit 5; }
fi
awk -v t="$TOTAL_FUND" -v m="$MAX_REACT" 'BEGIN{exit !(t<=m)}' || { echo "planned funding $TOTAL_FUND exceeds MAX_REACT $MAX_REACT" >&2; exit 6; }
if [ "$EXECUTE" = 1 ]; then
  RC_GAS_MARGIN=${RC_GAS_MARGIN:-2}   # REACT kept back for two RC deploys + setVault gas
  awk -v b="$(cast from-wei "$RC_BAL")" -v t="$TOTAL_FUND" -v m="$RC_GAS_MARGIN" 'BEGIN{exit !(b>=t+m)}' || { echo "deployer holds less than planned $TOTAL_FUND REACT + $RC_GAS_MARGIN gas margin" >&2; exit 6; }
  NEED_BASE=$(( MIN_BASE_ETH_WEI + VAULTS_TO_DEPLOY * $(cast to-wei "$VAULT_FUND" ether) + ${BASE_GAS_MARGIN_WEI:-2000000000000000} ))
  [ "$BASE_BAL" -ge "$NEED_BASE" ] || { echo "deployer Base ETH $BASE_BAL below reserve + vault funds + gas margin ($NEED_BASE wei)" >&2; exit 6; }
fi

RC_CTOR="constructor(address,(uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint32,uint256,uint256,uint256,address))"
VAULT_CTOR="constructor(address,address,address,address,uint64,uint256,uint256[],address[])"
create() { # rpc contract value ctor-signature args...  -> "address txhash"  (dry run: simulated with eth_call, prints "simulated -")
  local rpc=$1 c=$2 v=$3 sig=$4; shift 4
  local gas=(); [ "$rpc" = "$RC_RPC" ] && [ -n "${RC_GAS_LIMIT:-}" ] && gas=(--gas-limit "$RC_GAS_LIMIT" --gas-price "${RC_GAS_PRICE:-100gwei}")
  if [ "$EXECUTE" = 1 ]; then
    local raw; raw=$(forge create "$c" --broadcast --rpc-url "$rpc" --private-key "$DEPLOYER_PRIVATE_KEY" --value "$v" --json \
      ${gas[@]+"${gas[@]}"} --constructor-args "$@" 2>&1) || { echo "forge create failed: $raw" >&2; echo "$raw" >> evidence/mainnet-deploy.log; return 1; }
    echo "$raw" >> evidence/mainnet-deploy.log
    echo "$raw" | sed -n "/^{/,\$p" | jq -r '.deployedTo + " " + .transactionHash'
  else
    local code; code=$(forge inspect "$c" bytecode 2>/dev/null)
    local init="$code$(cast abi-encode "$sig" "$@" | sed 's/^0x//')"
    local wei=$v
    local sim=(cast call --rpc-url "$rpc" --from "$DEPLOYER_ADDRESS" --gas-limit "${SIM_GAS:-8000000}")
    if "${sim[@]}" --value "$wei" --create "$init" >/dev/null 2>/tmp/heirloom-sim.err; then
      echo "simulated-OK -"
    elif grep -qiE "insufficient funds|OutOfFunds" /tmp/heirloom-sim.err && "${sim[@]}" --value 0 --create "$init" >/dev/null 2>/tmp/heirloom-sim.err; then
      echo "simulated-OK-with-value-0(deployer-unfunded) -"
    else
      echo "SIMULATION FAILED: $(head -c 300 /tmp/heirloom-sim.err)" >&2; echo "FAILED -"; : > "$FAIL_MARK"
    fi
  fi
}

FAIL_MARK=$(mktemp); rm -f "$FAIL_MARK"
IDX=0
forge build >/dev/null 2>&1
for spec in "$A" "$B"; do
  IFS=: read -r NAME T GRACE FREEZE ATTEST ACK TICK CLAIM CRON CAP FUND <<<"$spec"
  say "instance $NAME: T=$T grace=$GRACE freeze=$FREEZE attest=$ATTEST ack=$ACK tick=$TICK claimDelay=$CLAIM cap=$CAP fund=$FUND REACT"
  FUND_WEI=$(cast to-wei "$FUND" ether); VFUND_WEI=$(cast to-wei "$VAULT_FUND" ether); ADDRS=evidence/mainnet-$NAME-addresses.txt
  CFG="($T,$GRACE,$FREEZE,$ATTEST,$ACK,$TICK,$BRAKE_WINDOW,$MAX_REFUSED,$CRON,0,$BASE_CHAIN,$PROXY)"
  RC=; VAULT=; RCTX=; VTX=
  if [ "$EXECUTE" = 1 ] && [ -f "$ADDRS" ]; then   # resume: reuse what this instance already deployed
    lc() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
    RC=$(sed -n 's/^RC=//p' "$ADDRS" | tail -1); VAULT=$(sed -n 's/^VAULT=//p' "$ADDRS" | tail -1)
    # Never advise moving $ADDRS aside while it names a live RC: a fresh run would fund a second RC.
    stop9() { echo "instance $NAME: $1 — the recorded RC does not match this invocation: rerun with the OWNER/spec it was deployed with (see $ADDRS), or wire and retire it first (reclaim() works only on a torn-down RC); never move $ADDRS aside while it names a funded RC; inspect evidence/mainnet-deploy.log" >&2; exit 9; }
    stopv() { echo "instance $NAME: $1 — delete ONLY the VAULT= line in $ADDRS (keep RC=) and rerun to deploy a fresh vault for RC $RC" >&2; exit 9; }
    [ -n "$RC" ] && [ "$(cast code "$RC" --rpc-url "$RC_RPC" | wc -c)" -gt 4 ] || stop9 "$ADDRS names RC '$RC' with no code on $RC_CHAIN"
    [ "$(lc "$(cast call "$RC" 'owner()(address)' --rpc-url "$RC_RPC")")" = "$(lc "$OWNER")" ] || stop9 "recorded RC watches another owner"
    # Bind the WHOLE constructor config (the preflight validated THIS spec, so the reused RC must be this spec), then the deployer.
    for kv in "T()(uint64)=$T" "grace()(uint64)=$GRACE" "freezeCap()(uint64)=$FREEZE" "attestEvery()(uint64)=$ATTEST" \
              "ackTimeout()(uint64)=$ACK" "tickPeriod()(uint64)=$TICK" "brakeWindow()(uint64)=$BRAKE_WINDOW" \
              "maxRefusedPerWindow()(uint32)=$MAX_REFUSED" "cronTopic()(bytes32)=$CRON" "graceCronTopic()(uint256)=0" \
              "destChainId()(uint256)=$BASE_CHAIN" "callbackProxy()(address)=$PROXY" "deployer()(address)=$DEPLOYER_ADDRESS"; do
      got=$(cast call "$RC" "${kv%%=*}" --rpc-url "$RC_RPC" | awk '{print $1}') || stop9 "cannot read ${kv%%=*} on the recorded RC"
      [ "$(lc "$got")" = "$(lc "${kv#*=}")" ] || stop9 "recorded RC ${kv%%(*} is $got, this spec says ${kv#*=}"
    done
    [ -z "$VAULT" ] || [ "$(cast code "$VAULT" --rpc-url "$BASE_RPC" | wc -c)" -gt 4 ] || stopv "recorded vault $VAULT has no code on $BASE_CHAIN"
    if [ -n "$VAULT" ]; then   # the recorded vault must match THIS invocation, or setVault would wire the wrong estate
      [ "$(lc "$(cast call "$VAULT" 'rc()(address)' --rpc-url "$BASE_RPC")")" = "$(lc "$RC")" ] || stopv "recorded vault $VAULT trusts another RC"
      [ "$(lc "$(cast call "$VAULT" 'owner()(address)' --rpc-url "$BASE_RPC")")" = "$(lc "$OWNER")" ] || stopv "recorded vault $VAULT has another owner"
      [ "$(lc "$(cast call "$VAULT" 'heir()(address)' --rpc-url "$BASE_RPC")")" = "$(lc "$HEIR")" ] || stopv "recorded vault $VAULT names another heir than HEIR"
      [ "$(cast call "$VAULT" 'claimDelay()(uint64)' --rpc-url "$BASE_RPC" | awk '{print $1}')" = "$CLAIM" ] || stopv "recorded vault $VAULT has claimDelay != $CLAIM"
      [ "$(cast call "$VAULT" 'depositCap()(uint256)' --rpc-url "$BASE_RPC" | awk '{print $1}')" = "$CAP" ] || stopv "recorded vault $VAULT has depositCap != $CAP"
    fi
    WIRED=$(lc "$(cast call "$RC" 'vault()(address)' --rpc-url "$RC_RPC")")
    if [ -n "$VAULT" ] && [ "$WIRED" = "$(lc "$VAULT")" ]; then say "instance $NAME: already deployed and wired ($ADDRS); skipped"; IDX=$((IDX + 1)); continue; fi
    [ "$WIRED" = 0x0000000000000000000000000000000000000000 ] || stop9 "recorded RC is wired to another vault ($WIRED)"
    say "instance $NAME: resuming from $ADDRS (RC $RC${VAULT:+, vault $VAULT})"
  fi
  if [ "$EXECUTE" = 1 ] && [ -n "$RC" ]; then
    :   # RC reused (resume)
  elif [ "$EXECUTE" = 1 ]; then
    RC_FROM=$(cast block-number --rpc-url "$RC_RPC"); BASE_FROM=$(cast block-number --rpc-url "$BASE_RPC")
    CREATED=$(create "$RC_RPC" src/HeirloomReactive.sol:HeirloomReactive "$FUND_WEI" "$RC_CTOR" "$OWNER" "$CFG") || { echo "RC deploy failed; check evidence/mainnet-deploy.log" >&2; exit 8; }
    read -r RC RCTX <<<"$CREATED"; [ -n "${RC:-}" ] && [ "$RC" != null ] || { echo "no RC address parsed from: $CREATED" >&2; exit 8; }
    printf 'INSTANCE=mainnet-%s\nRC=%s\nOWNER=%s\nHEIR=%s\nLASNA_FROM=%s\nBASE_FROM=%s\nT=%s\nGRACE=%s\nATTEST=%s\nCLAIM_DELAY=%s\n' "$NAME" "$RC" "$OWNER" "$HEIR" "$RC_FROM" "$BASE_FROM" "$T" "$GRACE" "$ATTEST" "$CLAIM" > "$ADDRS"   # persisted at once: a later failure must not orphan funded contracts
    logtx "$RC_CHAIN" "$RCTX" "deploy RC $NAME (+$FUND REACT)" "$RC_RPC"
  else
    read -r RCSTAT RCTX < <(create "$RC_RPC" src/HeirloomReactive.sol:HeirloomReactive "$FUND_WEI" "$RC_CTOR" "$OWNER" "$CFG")
    RC=$(cast compute-address "$DEPLOYER_ADDRESS" --nonce "$(( $(cast nonce "$DEPLOYER_ADDRESS" --rpc-url "$RC_RPC") + 2 * IDX ))" | awk '{print $NF}')  # each instance spends two RC-chain nonces: create + setVault
  fi
  [ "$EXECUTE" = 1 ] && say "  RC ($RC_CHAIN): $RC" || say "  RC creation $RCSTAT ($RC_CHAIN), predicted address $RC"
  VARGS=("$PROXY" "$RC" "$OWNER" "$HEIR" "$CLAIM" "$CAP" "[$BASE_CHAIN,$EXTRA_CHAIN]" "[$WATCH_A,$WATCH_B]")
  if [ "$EXECUTE" = 1 ]; then
    if [ -z "$VAULT" ]; then
      CREATED=$(create "$BASE_RPC" src/HeirloomVault.sol:HeirloomVault "$VFUND_WEI" "$VAULT_CTOR" "${VARGS[@]}") || { echo "vault deploy failed; RC $RC is funded and recorded in $ADDRS — rerun to resume" >&2; exit 8; }
      read -r VAULT VTX <<<"$CREATED"
      [[ "${VAULT:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "no vault address parsed from: $CREATED; RC $RC stays recorded in $ADDRS (no VAULT= line written) — rerun to resume" >&2; exit 8; }
      echo "VAULT=$VAULT" >> "$ADDRS"
      logtx "$BASE_CHAIN" "$VTX" "deploy vault $NAME" "$BASE_RPC"
    fi
  else
    read -r VAULT VTX < <(create "$BASE_RPC" src/HeirloomVault.sol:HeirloomVault "$VFUND_WEI" "$VAULT_CTOR" "${VARGS[@]}")
  fi
  VSTAT=$VAULT; [ "$EXECUTE" = 1 ] || VAULT=$(cast compute-address "$DEPLOYER_ADDRESS" --nonce "$(( $(cast nonce "$DEPLOYER_ADDRESS" --rpc-url "$BASE_RPC") + IDX ))" | awk '{print $NF}')
  IDX=$((IDX + 1))
  [ "$EXECUTE" = 1 ] && say "  vault ($BASE_CHAIN): $VAULT" || say "  vault creation $VSTAT against predicted RC $RC"
  SETV=(setVault 'setVault(address,(uint256,address)[],(uint256,address,uint64)[])' "$VAULT" \
    "[($BASE_CHAIN,$WATCH_A),($EXTRA_CHAIN,$WATCH_B)]" "[($BASE_CHAIN,$CANARY,$CANARY_GAP),($EXTRA_CHAIN,$CANARY_X,$CANARY_X_GAP)]")
  if [ "$EXECUTE" = 1 ]; then
    SGAS=(); [ -n "${RC_GAS_LIMIT:-}" ] && SGAS=(--gas-limit "$RC_GAS_LIMIT" --gas-price "${RC_GAS_PRICE:-100gwei}")
    STX=$(cast send "$RC" "${SETV[@]:1}" --rpc-url "$RC_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --json ${SGAS[@]+"${SGAS[@]}"} | jq -r .transactionHash) || { echo "setVault failed: RC $RC / vault $VAULT are recorded in $ADDRS" >&2; exit 8; }
    logtx "$RC_CHAIN" "$STX" "setVault $NAME" "$RC_RPC"
    say "  setVault: $STX"
    say "  wrote $ADDRS"
  else
    # simulate calldata encoding only (the RC does not exist yet in a dry run)
    say "  setVault calldata ok: $(cast calldata "${SETV[@]:1}" | cut -c1-18)… "
  fi
done
if [ "$EXECUTE" = 1 ]; then say "done; first ATTEST lands after one attestEvery; add the instances to deployments/mainnet.json, then DEPLOYMENTS=deployments/mainnet.json scripts/refresh-evidence.sh"
else
  [ ! -e "$FAIL_MARK" ] || { say "dry run FAILED: a simulated deploy reverted"; exit 7; }
  say "dry run complete: every creation simulated OK; nothing was sent"
fi
