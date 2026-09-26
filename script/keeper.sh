#!/usr/bin/env bash
# Runs script/Rebalance.s.sol every KEEPER_INTERVAL seconds (default 30).
# Configuration is the environment Rebalance.s.sol reads, plus RPC_URL.
# A failed tick (reverted simulation, RPC hiccup) is logged and skipped;
# the next tick re-reads prices from scratch, so nothing carries over.
set -uo pipefail

: "${RPC_URL:?RPC_URL required}"
interval="${KEEPER_INTERVAL:-30}"

while true; do
  echo "--- $(date -u +%FT%TZ)"
  forge script script/Rebalance.s.sol:Rebalance --rpc-url "$RPC_URL" --broadcast --slow \
    || echo "tick failed, retrying next interval"
  sleep "$interval"
done
