#!/bin/bash
# Real failures, and the alerts they must raise (issue #25,
# docs/runbooks/alerting.md):
#
#   1. nothing fires on a healthy platform;
#   2. a Vault pod sealed: VaultPodNotReady, VaultRaftFailureToleranceLost;
#   3. a second one sealed: VaultQuorumLost;
#   4. a PostgreSQL replica stopped: PostgresInstanceNotReady,
#      PostgresReplicaMissing;
#   5. connections close to the limit: PostgresConnectionsHigh;
#   6. the primary deleted: PostgresFailover;
#   7. every alert clears once the platform is healthy again.
#
# For a test cluster whose Vault uses a Shamir key (VAULT_UNSEAL_KEY): a pod
# restarts sealed. It fails Vault and PostgreSQL on purpose.
# KUBECTL overrides the kubectl command.
set -euo pipefail

K=${KUBECTL:-kubectl}
: "${VAULT_UNSEAL_KEY:?the Shamir key of the test Vault}"
PROM=pod/prometheus-kube-prometheus-stack-prometheus-0
ALERTS="VaultPodNotReady VaultRaftFailureToleranceLost VaultQuorumLost PostgresInstanceNotReady PostgresReplicaMissing PostgresNoPrimary PostgresConnectionsHigh"

kc() {
  # shellcheck disable=SC2086
  $K "$@"
}
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "  ok: $*"; }

kc -n monitoring port-forward "$PROM" 19090:9090 >/dev/null 2>&1 &
PF=$!
HOLD=""
cleanup() {
  [ -n "$HOLD" ] && kill "$HOLD" 2>/dev/null
  kc -n lumen annotate cluster lumen-db cnpg.io/fencedInstances- >/dev/null 2>&1 || true
  kill "$PF" 2>/dev/null || true
}
trap cleanup EXIT
for _ in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:19090/-/ready >/dev/null 2>&1 && break
  sleep 1
done

# firing: the names of the alerts firing now
firing() {
  curl -fsS --max-time 10 http://127.0.0.1:19090/api/v1/alerts \
    | python3 -c 'import json,sys; print(" ".join(sorted({a["labels"]["alertname"] for a in json.load(sys.stdin)["data"]["alerts"] if a["state"]=="firing"})))'
}
# wait_firing SECONDS ALERT...
wait_firing() {
  local seconds=$1 now missing a
  shift
  for _ in $(seq 1 $((seconds / 5))); do
    now=" $(firing) "
    missing=""
    for a in "$@"; do [[ "$now" == *" $a "* ]] || missing="$missing $a"; done
    [ -z "$missing" ] && return 0
    sleep 5
  done
  fail "not firing after ${seconds}s:$missing (firing:$now)"
}
# wait_clear SECONDS: none of the alerts of this test fires
wait_clear() {
  local now a busy
  for _ in $(seq 1 $(($1 / 5))); do
    now=" $(firing) "
    busy=""
    for a in $ALERTS; do [[ "$now" == *" $a "* ]] && busy="$busy $a"; done
    [ -z "$busy" ] && return 0
    sleep 5
  done
  fail "still firing after ${1}s:$busy"
}
unseal() {
  for _ in $(seq 1 40); do
    kc -n vault exec "$1" -- vault operator unseal "$VAULT_UNSEAL_KEY" >/dev/null 2>&1 && return 0
    sleep 3
  done
  fail "$1 cannot be unsealed"
}
vault_ready() {
  kc -n vault wait pod vault-0 vault-1 vault-2 --for=condition=Ready --timeout=300s >/dev/null
}
# standbys: the Vault pods that are not active
standbys() {
  kc -n vault get pods -l component=server,vault-active=false -o jsonpath='{.items[*].metadata.name}'
}
db() {
  kc -n lumen exec "$1" -c postgres -- psql -U postgres -d app -tAc "$2"
}

echo "== 1. A healthy platform"
wait_clear 300
ok "none of the alerts fires"

echo "== 2. One Vault pod sealed"
read -r first second _ <<<"$(standbys)"
kc -n vault delete pod "$first" >/dev/null
wait_firing 480 VaultPodNotReady VaultRaftFailureToleranceLost
ok "VaultPodNotReady and VaultRaftFailureToleranceLost fire"
[[ " $(firing) " != *" VaultQuorumLost "* ]] || fail "VaultQuorumLost fires with 2 pods ready"
ok "VaultQuorumLost does not fire with 2 pods ready"

echo "== 3. A second Vault pod sealed"
kc -n vault delete pod "$second" >/dev/null
wait_firing 300 VaultQuorumLost
ok "VaultQuorumLost fires"
sleep 15
unseal "$first"
unseal "$second"
vault_ready
ok "Vault unsealed"

echo "== 4. A PostgreSQL replica stopped"
replica=$(kc -n lumen get pods -l cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}')
kc -n lumen annotate cluster lumen-db "cnpg.io/fencedInstances=[\"$replica\"]" --overwrite >/dev/null
wait_firing 420 PostgresInstanceNotReady PostgresReplicaMissing
ok "PostgresInstanceNotReady and PostgresReplicaMissing fire for $replica"
kc -n lumen annotate cluster lumen-db cnpg.io/fencedInstances- >/dev/null
kc -n lumen wait cluster/lumen-db --for=condition=Ready --timeout=300s >/dev/null

echo "== 5. Connections close to the limit"
primary=$(kc -n lumen get pods -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kc -n lumen exec "$primary" -c postgres -- bash -c \
  'for i in $(seq 1 85); do psql -U postgres -d app -qAtc "SELECT pg_sleep(600)" >/dev/null 2>&1 & done; wait' >/dev/null 2>&1 &
HOLD=$!
wait_firing 540 PostgresConnectionsHigh
ok "PostgresConnectionsHigh fires"
kill "$HOLD" 2>/dev/null || true
HOLD=""
db "$primary" "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE query LIKE 'SELECT pg_sleep%' AND pid <> pg_backend_pid()" >/dev/null

echo "== 6. The primary deleted"
kc -n lumen delete pod "$primary" >/dev/null
wait_firing 420 PostgresFailover
ok "PostgresFailover fires"
kc -n lumen wait cluster/lumen-db --for=condition=Ready --timeout=420s >/dev/null

echo "== 7. Back to healthy"
wait_clear 600
ok "the alerts have cleared"

echo "PASS"
