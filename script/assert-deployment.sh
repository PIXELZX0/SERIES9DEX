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
TIMELOCK="$(get treasuryTimelock)"
DEPLOYER="$(get deployer)"
CHAIN_ID_JSON="$(get chainId)"

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

# The timelock owns both the treasury and the registry, never the Safe
# directly: a key compromise should be an observable, cancellable proposal —
# for a withdrawal, an upgrade or a factory change alike — not an instant one.
check "registry.owner()"           "$TIMELOCK"     "$(call "$REGISTRY" 'owner()(address)')"
check "treasury.owner()"           "$TIMELOCK"     "$(call "$TREASURY" 'owner()(address)')"
# The Safe keeps the two powers that are useless behind a delay.
check "registry.emergencyAdmin()"  "$SAFE_ADDRESS" "$(call "$REGISTRY" 'emergencyAdmin()(address)')"
check "registry.treasury()"        "$TREASURY"     "$(call "$REGISTRY" 'treasury()(address)')"
check "registry.spotPoolFactory()" "$SPOT_FACTORY" "$(call "$REGISTRY" 'spotPoolFactory()(address)')"
check "registry.perpPoolFactory()" "$PERP_FACTORY" "$(call "$REGISTRY" 'perpPoolFactory()(address)')"
check "spotPoolFactory.registry()" "$REGISTRY"     "$(call "$SPOT_FACTORY" 'registry()(address)')"
check "perpPoolFactory.registry()" "$REGISTRY"     "$(call "$PERP_FACTORY" 'registry()(address)')"
check "positionManager.registry()" "$REGISTRY"     "$(call "$POSITION_MANAGER" 'registry()(address)')"
check "router.registry()"          "$REGISTRY"     "$(call "$ROUTER" 'registry()(address)')"
check "registry.guardian()"        "$GUARDIAN"     "$(call "$REGISTRY" 'guardian()(address)')"
check "registry.paused()"          "false"         "$(call "$REGISTRY" 'paused()(bool)')"

# Nobody may hold the timelock's admin role but the timelock itself, or the
# delay can be rewritten without waiting for it.
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
has_role() { cast call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' "$1" "$2" --rpc-url "$RPC_URL"; }
check "timelock self-admin"        "true"          "$(has_role "$ADMIN_ROLE" "$TIMELOCK")"
check "safe is not timelock admin" "false"         "$(has_role "$ADMIN_ROLE" "$SAFE_ADDRESS")"
PROPOSER_ROLE="$(cast keccak 'PROPOSER_ROLE')"
check "safe proposes"              "true"          "$(has_role "$PROPOSER_ROLE" "$SAFE_ADDRESS")"
# The deployer wired everything and must have kept nothing.
check "deployer not timelock admin" "false"        "$(has_role "$ADMIN_ROLE" "$DEPLOYER")"
check "deployer not proposer"      "false"         "$(has_role "$PROPOSER_ROLE" "$DEPLOYER")"
CANCELLER_ROLE="$(cast keccak 'CANCELLER_ROLE')"
check "deployer not canceller"     "false"         "$(has_role "$CANCELLER_ROLE" "$DEPLOYER")"

# The delay is the whole defence: a zero-delay timelock makes registry
# upgrades and treasury withdrawals instant and would pass every role check.
DELAY="$(cast call "$TIMELOCK" 'getMinDelay()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')"
check "timelock delay"             "${TREASURY_TIMELOCK_DELAY:-172800}" "$DELAY"
if [[ "$CHAIN_ID_JSON" == "143" && "$DELAY" -lt 86400 ]]; then
  echo "::error title=Deployment check failed::timelock delay ${DELAY}s is under a day on mainnet"
  fail=1
fi
if [[ "$GUARDIAN" != "0x0000000000000000000000000000000000000000" ]]; then
  check "guardian cancels"         "true"          "$(has_role "$CANCELLER_ROLE" "$GUARDIAN")"
fi

exit $fail
