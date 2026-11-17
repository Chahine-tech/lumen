#!/bin/bash
# Memory test of Redis (issue #8, docs/runbooks/redis.md): fills the master
# past maxmemory while it saves and rewrites its AOF (both fork, and the
# copy-on-write pages count against the container's limit), then checks:
#
#   - writes are refused (noeviction: "OOM command not allowed"), nothing
#     was evicted;
#   - no Redis container went past its memory limit: peak from the cgroup
#     (memory.peak), no restart, no OOMKilled.
#
# Leaves the data in place: flush it after (FLUSHALL on the master). Run it
# on a test cluster. KUBECTL overrides the kubectl command, NS the namespace.
set -euo pipefail

K=${KUBECTL:-kubectl}
NS=${NS:-lumen}
PODS="redis-0 redis-1 redis-2"

k() {
  # shellcheck disable=SC2086
  $K -n "$NS" "$@"
}
r() {
  local pod=$1
  shift
  k exec "$pod" -c redis -- sh -c 'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" "$@"' sh "$@" 2>/dev/null
}
fail() { echo "FAIL: $*"; exit 1; }

m=$(r redis-0 info replication | sed -n 's/^master_host:\([^.]*\)\..*/\1/p' | tr -d '\r')
[ -n "$m" ] || m=redis-0
echo "master: $m"
maxmemory=$(r "$m" config get maxmemory | sed -n 2p)
echo "maxmemory: $maxmemory bytes"
restarts_before=$(k get pods $PODS -o jsonpath='{range .items[*]}{.status.containerStatuses[?(@.name=="redis")].restartCount}{" "}{end}')

echo "== Fill with 1 KB values, saving and rewriting the AOF meanwhile"
for round in 1 2 3 4; do
  # 60000 keys of 1 KB per round: 4 rounds go well past 128 MB
  k exec "$m" -c redis -- sh -c '
    awk -v r='"$round"' "BEGIN { v = sprintf(\"%1024s\", \"\"); gsub(/ /, \"x\", v); for (i = 0; i < 60000; i++) printf \"SET k:%d:%d %s\r\n\", r, i, v }" |
      redis-cli --no-auth-warning -a "$REDIS_PASSWORD" --pipe' 2>&1 | tail -1 || true
  r "$m" bgrewriteaof >/dev/null || true
  r "$m" bgsave >/dev/null || true
  for p in $PODS; do [ "$p" = "$m" ] || r "$p" bgsave >/dev/null || true; done
  sleep 3
done

echo "== Checks"
used=$(r "$m" info memory | sed -n 's/^used_memory:\([0-9]*\).*/\1/p')
evicted=$(r "$m" info stats | sed -n 's/^evicted_keys:\([0-9]*\).*/\1/p')
refused=$(r "$m" set probe-after-full x 2>&1 || true)
echo "used_memory $used, evicted_keys $evicted, a new write: $refused"
case "$refused" in *OOM*) ;; *) fail "the write was not refused" ;; esac
[ "$evicted" = 0 ] || fail "$evicted keys evicted"

limit=$((256 * 1024 * 1024))
for p in $PODS; do
  peak=$(k exec "$p" -c redis -- cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo "?")
  echo "$p: peak $peak bytes, limit $limit ($(awk -v p="$peak" -v l="$limit" 'BEGIN { printf "%d%%", 100 * p / l }'))"
  [ "$peak" != "?" ] && [ "$peak" -lt "$limit" ] || fail "$p reached its limit"
done
restarts_after=$(k get pods $PODS -o jsonpath='{range .items[*]}{.status.containerStatuses[?(@.name=="redis")].restartCount}{" "}{end}')
[ "$restarts_before" = "$restarts_after" ] || fail "restarts: $restarts_before -> $restarts_after"
k get pods $PODS -o jsonpath='{range .items[*]}{.status.containerStatuses[*].lastState.terminated.reason}{end}' | grep -q OOMKilled && fail "OOMKilled"
echo "PASS"
