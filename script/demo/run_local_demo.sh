#!/usr/bin/env bash
# Runs the full Essentials live demo end-to-end against a fresh local
# anvil chain: deploys everything, queues a real front-run + victim +
# back-run sandwich attempt as three separate transactions, mines the
# real chain forward past the batch window, settles it, and prints the
# attacker's real loss and the victim's real fair fill straight from
# on-chain state.
#
# This is not a dry-run simulation and not a Foundry test log -- every
# step here is a real transaction against a real (local) chain, which is
# what lets you actually watch the batch queue, mine forward, and settle
# rather than just reading an assertion pass/fail.
#
# Usage: ./script/demo/run_local_demo.sh
# Requires: foundry (anvil, forge, cast) on PATH.

set -euo pipefail
cd "$(dirname "$0")/../.."

RPC_URL="http://127.0.0.1:8545"
ANVIL_LOG="$(mktemp)"

echo "=== starting a fresh local anvil chain ==="
# setsid fully detaches anvil from this script's own session so it
# keeps running as a real background chain for the rest of the demo.
setsid anvil --silent > "$ANVIL_LOG" 2>&1 < /dev/null &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT

# wait for anvil to actually accept connections rather than a fixed sleep
for i in $(seq 1 20); do
  if curl -s -X POST -H "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      "$RPC_URL" > /dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

echo "=== phase 1: deploy + queue a real sandwich attempt (front-run, victim, back-run) ==="
PHASE1_OUT="$(mktemp)"
forge script script/demo/DemoPart1_SetupAndQueue.s.sol --rpc-url "$RPC_URL" --broadcast 2>&1 | tee "$PHASE1_OUT"

HOOK=$(grep -oE 'HOOK=0x[0-9a-fA-F]{40}' "$PHASE1_OUT" | head -1 | cut -d= -f2)
TOKEN0=$(grep -oE 'TOKEN0=0x[0-9a-fA-F]{40}' "$PHASE1_OUT" | head -1 | cut -d= -f2)
TOKEN1=$(grep -oE 'TOKEN1=0x[0-9a-fA-F]{40}' "$PHASE1_OUT" | head -1 | cut -d= -f2)

if [[ -z "$HOOK" || -z "$TOKEN0" || -z "$TOKEN1" ]]; then
  echo "Could not parse deployed addresses from Phase 1 output -- see $PHASE1_OUT" >&2
  exit 1
fi

echo ""
echo "=== mining the real chain forward past the batch window ==="
# vm.roll only affects a script's own local simulation pass, not the real
# chain -- confirmed the hard way while building this demo. Advancing the
# real chain requires an actual RPC call.
cast rpc anvil_mine 5 --rpc-url "$RPC_URL" > /dev/null

echo "=== phase 2: settle the batch and report the real result ==="
HOOK="$HOOK" TOKEN0="$TOKEN0" TOKEN1="$TOKEN1" \
  forge script script/demo/DemoPart2_MineAndSettle.s.sol --rpc-url "$RPC_URL" --broadcast

echo ""
echo "=== done. anvil chain will now be torn down. ==="
