#!/bin/bash
# Real failures of Redis and of certificates, and the alerts they must raise
# (issue #25, docs/runbooks/alerting.md):
#
#   1. nothing fires on a healthy platform, and the metrics are there;
#   2. a Redis replica lost: RedisPodNotReady, RedisReplicaMissing;
#   3. the master lost: RedisMasterChanged;
#   4. Redis nearly full: RedisMemoryHigh;
#   5. keys evicted under another policy: RedisKeysEvicted;
#   6. a certificate close to its end, another one that cannot be issued:
#      CertificateExpiringSoon, CertificateNotReady;
#   7. every alert clears once the platform is healthy again.
#
# Takes Redis down on purpose and fills it: run it on a test cluster.
# KUBECTL overrides the kubectl command.
set -euo pipefail

K=${KUBECTL:-kubectl}
NS=lumen
PROM=pod/prometheus-kube-prometheus-stack-prometheus-0
ALERTS="RedisPodNotReady RedisNoMaster RedisReplicaMissing RedisMasterChanged RedisMemoryHigh RedisKeysEvicted CertificateExpiringSoon CertificateNotReady CertManagerMetricsAbsent"

kc() {
  # shellcheck disable=SC2086
  $K "$@"
}
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "  ok: $*"; }

CORDONED=""
kc -n monitoring port-forward "$PROM" 19090:9090 >/dev/null 2>&1 &
PF=$!
cleanup() {
  [ -z "$CORDONED" ] || kc uncordon "$CORDONED" >/dev/null 2>&1 || true
  kc -n "$NS" delete certificate alert-test-expiring alert-test-broken --ignore-not-found >/dev/null 2>&1 || true
  kc delete clusterissuer alert-test-selfsigned --ignore-not-found >/dev/null 2>&1 || true
  kill "$PF" 2>/dev/null || true
}
trap cleanup EXIT
for _ in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:19090/-/ready >/dev/null 2>&1 && break
  sleep 1
done

firing() {
  curl -fsS --max-time 10 http://127.0.0.1:19090/api/v1/alerts \
    | python3 -c 'import json,sys; print(" ".join(sorted({a["labels"]["alertname"] for a in json.load(sys.stdin)["data"]["alerts"] if a["state"]=="firing"})))'
}
# series QUERY: how many series the query returns
series() {
  curl -fsS --max-time 10 -G http://127.0.0.1:19090/api/v1/query --data-urlencode "query=$1" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["result"]))'
}
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
# r POD ARGS...: redis-cli in a pod, with its password
r() {
  local pod=$1
  shift
  kc -n "$NS" exec "$pod" -c redis -- sh -c 'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" "$@"' sh "$@"
}
# master: the master named by the first Sentinel that answers
master() {
  local p m
  for p in redis-0 redis-1 redis-2; do
    m=$(kc -n "$NS" exec "$p" -c sentinel -- sh -c \
      'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" -p 26379 sentinel get-master-addr-by-name mymaster' 2>/dev/null | head -n 1 | cut -d. -f1) || continue
    [ -n "$m" ] && { echo "$m"; return 0; }
  done
  return 1
}
# fill POD FIRST COUNT: COUNT batches of 2 MB. One large script would hold the
# whole payload in the memory of the container, beyond its limit
fill() {
  local i
  for i in $(seq "$2" $(($2 + $3 - 1))); do
    r "$1" eval "for k=1,20 do redis.call('SET','alert-test:$i:'..k,string.rep('x',102400)) end return 1" 0 >/dev/null 2>&1 || true
  done
}
# memory_percent POD: used_memory, as a percentage of maxmemory
memory_percent() {
  r "$1" info memory | tr -d '\r' | awk -F: '/^used_memory:/ {u=$2} /^maxmemory:/ {m=$2} END {print int(u * 100 / m)}'
}
redis_healthy() {
  kc -n "$NS" wait pod redis-0 redis-1 redis-2 --for=condition=Ready --timeout=300s >/dev/null
  for _ in $(seq 1 40); do
    [ "$(r "$(master)" info replication | tr -d '\r' | sed -n 's/^connected_slaves://p')" = 2 ] && return 0
    sleep 3
  done
  fail "the Redis master does not have 2 replicas"
}
# lose POD: the pod cannot come back, its node being cordoned
lose() {
  CORDONED=$(kc -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}')
  kc cordon "$CORDONED" >/dev/null
  kc -n "$NS" delete pod "$1" >/dev/null
}
restore() {
  kc uncordon "$CORDONED" >/dev/null
  CORDONED=""
  redis_healthy
}

echo "== 1. A healthy platform"
for _ in $(seq 1 36); do
  [ "$(series 'redis_up == 1')" = 3 ] && [ "$(series 'certmanager_clock_time_seconds')" -ge 1 ] && break
  sleep 5
done
[ "$(series 'redis_up == 1')" = 3 ] || fail "redis_up reported by $(series 'redis_up == 1') pods, want 3"
[ "$(series 'certmanager_clock_time_seconds')" -ge 1 ] || fail "no cert-manager metrics"
ok "the 3 Redis exporters and cert-manager are scraped"
wait_clear 480
ok "none of the alerts fires"

echo "== 2. A Redis replica lost"
m=$(master)
replica=$(for p in redis-0 redis-1 redis-2; do [ "$p" != "$m" ] && echo "$p"; done | head -n 1)
lose "$replica"
wait_firing 420 RedisPodNotReady RedisReplicaMissing
ok "RedisPodNotReady and RedisReplicaMissing fire for $replica"
restore

echo "== 3. The Redis master lost"
m=$(master)
lose "$m"
wait_firing 300 RedisMasterChanged
ok "RedisMasterChanged fires (master was $m, now $(master))"
restore

echo "== 4. Redis nearly full"
m=$(master)
batch=1
while [ "$(memory_percent "$m")" -lt 92 ]; do
  fill "$m" "$batch" 5
  batch=$((batch + 5))
  [ "$batch" -lt 200 ] || fail "Redis stays at $(memory_percent "$m")% of maxmemory"
done
ok "Redis filled to $(memory_percent "$m")% of maxmemory"
wait_firing 540 RedisMemoryHigh
ok "RedisMemoryHigh fires"

echo "== 5. Keys evicted"
r "$m" config set maxmemory-policy allkeys-lru >/dev/null
fill "$m" 1000 15
wait_firing 240 RedisKeysEvicted
ok "RedisKeysEvicted fires"
r "$m" config set maxmemory-policy noeviction >/dev/null
r "$m" flushall >/dev/null

echo "== 6. Certificates"
kc apply -f - >/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: alert-test-selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: alert-test-expiring
  namespace: $NS
spec:
  secretName: alert-test-expiring
  commonName: alert-test.airgap.local
  duration: 48h
  renewBefore: 1h
  issuerRef: {name: alert-test-selfsigned, kind: ClusterIssuer}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: alert-test-broken
  namespace: $NS
spec:
  secretName: alert-test-broken
  commonName: alert-test-broken.airgap.local
  issuerRef: {name: alert-test-missing, kind: ClusterIssuer}
EOF
wait_firing 840 CertificateExpiringSoon CertificateNotReady
ok "CertificateExpiringSoon and CertificateNotReady fire"
kc -n "$NS" delete certificate alert-test-expiring alert-test-broken >/dev/null
kc -n "$NS" delete secret alert-test-expiring --ignore-not-found >/dev/null

echo "== 7. Back to healthy"
wait_clear 900
ok "the alerts have cleared"

echo "PASS"
