#!/usr/bin/env bash
# Post-deploy on-chain checks. Reads the labeled address record written by
# DeployDex.s.sol and compares it against what the chain actually says.
#
# Pools and pairs are immutable once deployed and the registry only ever
# points at one pair of factories, so a mis-wired stack can only be fixed by
# redeploying it. Fail loudly, before anyone publishes the addresses.
#
# Usage: RPC_URL=... SAFE_ADDRESS=0x... ./script/assert-deployment.sh deployments/143.json
set -euo pipefail

ADDRESSES="${1:-${ADDRESSES:?path to deployments/<chainid>.json required}}"
: "${RPC_URL:?RPC_URL required}"
: "${SAFE_ADDRESS:?SAFE_ADDRESS required}"

get() { jq -r ".$1" "$ADDRESSES"; }
TREASURY="$(get protocolTreasuryProxy)"
REGISTRY="$(get dexRegistryProxy)"
SPOT_FACTORY="$(get spotPoolFactory)"
PERP_FACTORY="$(get perpPoolFactory)"
POSITION_MANAGER="$(get dexPositionManager)"
ROUTER="$(get dexRouter)"
GUARDIAN="$(get guardian)"

fail=0
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
check() { # label expected actual
  if [[ "$(lc "$2")" != "$(lc "$3")" ]]; then
    echo "::error title=Deployment check failed::$1 expected $2, got $3"
    fail=1
  else
    echo "OK  $1 = $3"
  fi
}
call() { cast call "$1" "$2" --rpc-url "$RPC_URL"; }

check "registry.owner()"           "$SAFE_ADDRESS" "$(call "$REGISTRY" 'owner()(address)')"
check "treasury.owner()"           "$SAFE_ADDRESS" "$(call "$TREASURY" 'owner()(address)')"
check "registry.treasury()"        "$TREASURY"     "$(call "$REGISTRY" 'treasury()(address)')"
check "registry.spotPoolFactory()" "$SPOT_FACTORY" "$(call "$REGISTRY" 'spotPoolFactory()(address)')"
check "registry.perpPoolFactory()" "$PERP_FACTORY" "$(call "$REGISTRY" 'perpPoolFactory()(address)')"
check "spotPoolFactory.registry()" "$REGISTRY"     "$(call "$SPOT_FACTORY" 'registry()(address)')"
check "perpPoolFactory.registry()" "$REGISTRY"     "$(call "$PERP_FACTORY" 'registry()(address)')"
check "positionManager.registry()" "$REGISTRY"     "$(call "$POSITION_MANAGER" 'registry()(address)')"
check "router.registry()"          "$REGISTRY"     "$(call "$ROUTER" 'registry()(address)')"
check "registry.guardian()"        "$GUARDIAN"     "$(call "$REGISTRY" 'guardian()(address)')"
check "registry.paused()"          "false"         "$(call "$REGISTRY" 'paused()(bool)')"

exit $fail
