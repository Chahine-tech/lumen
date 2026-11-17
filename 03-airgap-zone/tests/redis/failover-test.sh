#!/bin/bash
# Failover test of Redis with Sentinel (issue #8, docs/runbooks/redis.md):
#
#   1. the topology is consistent: every Sentinel names the same master,
#      which has 2 replicas linked to it;
#   2. the master's node is cordoned and the master pod deleted: it cannot
#      come back (its local-path volume ties it to that node), as when the
#      node is lost, and the Sentinels elect another master. The node is
#      uncordoned after. (A pod deleted without the cordon comes back within
#      seconds, under the same name, before Sentinel's down-after-milliseconds:
#      it stays master and nothing fails over.)
#   3. every Sentinel is restarted: they still name the new master (their
#      configuration is on the pods' volumes), and the topology is
#      consistent again, the deleted pod back as a replica;
#   4. a key written before the failover is still there.
#
# Disrupts the Redis of the namespace: run it on a test cluster or in a
# maintenance window. KUBECTL overrides the kubectl command, NS the namespace.
set -euo pipefail

K=${KUBECTL:-kubectl}
NS=${NS:-lumen}
PODS="redis-0 redis-1 redis-2"
DOMAIN="redis-headless.$NS.svc.cluster.local"

k() {
  # shellcheck disable=SC2086
  $K -n "$NS" "$@"
}
# r POD CONTAINER ARGS...: redis-cli in a pod, the password from its env
r() {
  local pod=$1 c=$2
  shift 2
  k exec "$pod" -c "$c" -- sh -c 'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" "$@"' sh "$@" 2>/dev/null
}
masters() {
  for p in $PODS; do
    r "$p" sentinel -p 26379 sentinel get-master-addr-by-name mymaster | head -1 || echo "?"
  done
}
fail() { echo "FAIL: $*"; exit 1; }

# consistent: one master named by all 3 Sentinels, role master, 2 replicas
# linked to it. Prints the master's pod name.
consistent() {
  local m n replicas
  m=$(masters | sort -u)
  [ "$(printf '%s\n' "$m" | wc -l)" -eq 1 ] || { echo "Sentinels disagree: $(masters | tr '\n' ' ')" >&2; return 1; }
  case "$m" in redis-[0-9]."$DOMAIN") ;; *) echo "no master: $m" >&2; return 1 ;; esac
  n=${m%%.*}
  r "$n" redis info replication | grep -q '^role:master' || { echo "$n is not a master" >&2; return 1; }
  replicas=$(r "$n" redis info replication | sed -n 's/^connected_slaves:\([0-9]*\).*/\1/p')
  [ "$replicas" = 2 ] || { echo "$n has $replicas replicas" >&2; return 1; }
  for p in $PODS; do
    [ "$p" = "$n" ] && continue
    r "$p" redis info replication | grep -q "^master_host:$m" || { echo "$p does not follow $m" >&2; return 1; }
    r "$p" redis info replication | grep -q '^master_link_status:up' || { echo "$p: link down" >&2; return 1; }
  done
  echo "$n"
}
wait_consistent() { # timeout_s
  local end=$((SECONDS + $1)) n
  while [ $SECONDS -lt "$end" ]; do
    n=$(consistent 2>/dev/null) && { echo "$n"; return 0; }
    sleep 2
  done
  consistent || true
  return 1
}

echo "== 1. Topology"
old=$(wait_consistent 60) || fail "not consistent at the start"
echo "master: $old"
key="failover-test-$(date +%s)"
r "$old" redis set "$key" before >/dev/null
r "$old" redis wait 2 5000 >/dev/null

echo "== 2. Cordon the node of $old, delete the pod"
node=$(k get pod "$old" -o jsonpath='{.spec.nodeName}')
uncordon() {
  # shellcheck disable=SC2086
  $K uncordon "$node" >/dev/null
}
trap uncordon EXIT
# shellcheck disable=SC2086
$K cordon "$node" >/dev/null
start=$SECONDS
k delete pod "$old" --wait=false >/dev/null
new=""
while [ $((SECONDS - start)) -lt 90 ]; do
  m=$(masters | grep -v -e "^$old\." -e '^?$' | sort -u | head -1 || true)
  if [ -n "$m" ] && [ "$(masters | grep -c "^${m}$" || true)" -ge 2 ]; then
    new=${m%%.*}
    break
  fi
  sleep 1
done
[ -n "$new" ] || fail "no new master after 90s: $(masters | tr '\n' ' ')"
echo "new master $new after $((SECONDS - start))s (2 Sentinels or more agree)"
uncordon
sleep 5
k wait --for=condition=ready "pod/$old" --timeout=120s >/dev/null || fail "$old not ready"
n=$(wait_consistent 90) || fail "not consistent after the failover"
[ "$n" = "$new" ] || fail "master $n, expected $new"
echo "consistent, $old is a replica of $new"

echo "== 3. Restart every Sentinel"
for p in $PODS; do
  k exec "$p" -c sentinel -- kill 1 >/dev/null 2>&1 || true
done
sleep 5
for p in $PODS; do
  k wait --for=condition=ready "pod/$p" --timeout=120s >/dev/null || fail "$p not ready"
done
n=$(wait_consistent 90) || fail "not consistent after restarting the Sentinels"
[ "$n" = "$new" ] || fail "the Sentinels now name $n, not $new"
echo "consistent, master still $new"

echo "== 4. Data"
for p in $PODS; do
  v=$(r "$p" redis get "$key")
  [ "$v" = before ] || fail "$p: $key = '$v'"
done
r "$new" redis del "$key" >/dev/null
echo "PASS"
