#!/bin/bash
# PostgreSQL restore drill: point-in-time recovery of lumen-db from Garage
#
# Proves that the backups can be restored, and to the right point in time:
#   1. take a fresh base backup of lumen-db
#   2. write marker BEFORE, note the time T, write marker AFTER
#   3. force a WAL switch and wait until that segment is archived
#   4. restore a new cluster, lumen-db-restore-drill, to time T
#   5. PASS only if BEFORE is present AND AFTER is absent
# A restore that ignored the target time, or replayed nothing, fails step 5.
#
# The drill cluster does not archive WAL (no .spec.plugins), so it cannot
# write into the lumen-db backups. It is deleted at the end unless KEEP=1.
#
# Writes to production: a row in table restore_drill_marker (database app),
# created by this script. The table doubles as a log of past drills.
#
# Usage: ./cnpg-restore-drill.sh        (KEEP=1 to keep the drill cluster)

set -e

NAMESPACE="lumen"
SOURCE_CLUSTER="lumen-db"
DRILL_CLUSTER="lumen-db-restore-drill"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRILL_DIR="${SCRIPT_DIR}/../manifests/cnpg/restore-drill"
KUBECTL="multipass exec node-1 -- kubectl"
RUN_ID="$(date -u +%Y%m%d%H%M%S)"

apply_file() {  # apply a local manifest through node-1
  multipass transfer "$1" "node-1:/tmp/drill-$(basename "$1")"
  $KUBECTL apply -f "/tmp/drill-$(basename "$1")"
}

psql_on() {  # psql_on <pod> <sql>: single value, no headers
  $KUBECTL exec -n "$NAMESPACE" "$1" -c postgres -- psql -d app -tAqc "$2"
}

wait_for() {  # wait_for <description> <timeout seconds> <command...>
  local what="$1" timeout="$2" start=$SECONDS
  shift 2
  until "$@"; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      echo "  ❌ Timed out waiting for: ${what}"
      return 1
    fi
    sleep 5
  done
}

cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    echo "KEEP=1: leaving ${DRILL_CLUSTER} in place. Delete it with:"
    echo "  kubectl delete cluster ${DRILL_CLUSTER} -n ${NAMESPACE} && kubectl delete -f ${DRILL_DIR}/01-network-policy.yaml"
    return
  fi
  echo "Cleaning up ${DRILL_CLUSTER}..."
  $KUBECTL delete cluster "$DRILL_CLUSTER" -n "$NAMESPACE" --ignore-not-found --wait=true || true
  $KUBECTL delete networkpolicy restore-drill-from-cnpg-operator restore-drill-egress \
    -n "$NAMESPACE" --ignore-not-found || true
}

echo "================================================"
echo "Restore drill ${RUN_ID}: ${SOURCE_CLUSTER} → ${DRILL_CLUSTER}"
echo "================================================"

# ── 0. Preconditions ───────────────────────────────────────────────────────
echo ""
echo "[0/6] Preconditions..."
if $KUBECTL get cluster "$DRILL_CLUSTER" -n "$NAMESPACE" > /dev/null 2>&1; then
  echo "  ❌ ${DRILL_CLUSTER} already exists (previous drill with KEEP=1?). Delete it first."
  exit 1
fi
ARCHIVING=$($KUBECTL get cluster "$SOURCE_CLUSTER" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}')
if [ "$ARCHIVING" != "True" ]; then
  echo "  ❌ ContinuousArchiving is '${ARCHIVING:-absent}' on ${SOURCE_CLUSTER}: WAL archiving is not working"
  exit 1
fi
PRIMARY=$($KUBECTL get cluster "$SOURCE_CLUSTER" -n "$NAMESPACE" -o jsonpath='{.status.currentPrimary}')
echo "  ✅ WAL archiving OK, primary is ${PRIMARY}"

trap cleanup EXIT

# ── 1. Fresh base backup ───────────────────────────────────────────────────
echo ""
echo "[1/6] Taking a base backup..."
BACKUP_NAME="${SOURCE_CLUSTER}-drill-${RUN_ID}"
cat > "/tmp/drill-backup-${RUN_ID}.yaml" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: ${NAMESPACE}
spec:
  cluster:
    name: ${SOURCE_CLUSTER}
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
apply_file "/tmp/drill-backup-${RUN_ID}.yaml"
backup_done() {
  local phase
  phase=$($KUBECTL get backup "$BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
  [ "$phase" = "failed" ] && { echo "  ❌ Backup failed"; exit 1; }
  [ "$phase" = "completed" ]
}
wait_for "backup ${BACKUP_NAME}" 900 backup_done
echo "  ✅ Backup ${BACKUP_NAME} completed"

# ── 2. Markers around the target time ──────────────────────────────────────
echo ""
echo "[2/6] Writing markers..."
# The 'after' marker is also what lets the recovery finish: PostgreSQL stops a
# time-targeted recovery at the first commit past the target. Without a commit
# after T in the archive, it fails with "recovery ended before configured
# recovery target was reached" (seen on the k3d test, 2026-11-12).
psql_on "$PRIMARY" "CREATE TABLE IF NOT EXISTS restore_drill_marker (
  run_id text NOT NULL, marker text NOT NULL, created_at timestamptz NOT NULL DEFAULT now())" > /dev/null
psql_on "$PRIMARY" "INSERT INTO restore_drill_marker (run_id, marker) VALUES ('${RUN_ID}', 'before')" > /dev/null
sleep 2
TARGET_TIME=$(psql_on "$PRIMARY" "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00'")
sleep 2
psql_on "$PRIMARY" "INSERT INTO restore_drill_marker (run_id, marker) VALUES ('${RUN_ID}', 'after')" > /dev/null
echo "  ✅ Target time ${TARGET_TIME} (marker 'before' just before, 'after' 2s later)"

# ── 3. Make sure the WAL containing both markers is archived ───────────────
echo ""
echo "[3/6] Forcing a WAL switch and waiting for the archive..."
SWITCHED=$(psql_on "$PRIMARY" "SELECT pg_walfile_name(pg_switch_wal())")
archived() {
  local last
  last=$(psql_on "$PRIMARY" "SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver")
  # Same timeline: WAL file names sort in LSN order
  [ -n "$last" ] && [ ! "$last" \< "$SWITCHED" ]
}
wait_for "archive of ${SWITCHED}" 300 archived
echo "  ✅ ${SWITCHED} archived"

# ── 4. Restore ─────────────────────────────────────────────────────────────
echo ""
echo "[4/6] Restoring ${DRILL_CLUSTER} to ${TARGET_TIME}..."
sed "s|__TARGET_TIME__|${TARGET_TIME}|" "${DRILL_DIR}/02-cluster.yaml" > "/tmp/drill-cluster-${RUN_ID}.yaml"
apply_file "${DRILL_DIR}/01-network-policy.yaml"
RESTORE_START=$SECONDS
apply_file "/tmp/drill-cluster-${RUN_ID}.yaml"
drill_ready() {
  # A recovery that cannot complete makes CNPG retry the job forever: stop
  # after 3 failed pods instead of waiting for the 30 minute timeout
  local failed
  failed=$($KUBECTL get pods -n "$NAMESPACE" --field-selector=status.phase=Failed -o name \
    | grep -c "${DRILL_CLUSTER}-.*-full-recovery" || true)
  if [ "$failed" -ge 3 ]; then
    echo "  ❌ Recovery job failed ${failed} times. Logs:"
    echo "     kubectl logs -n ${NAMESPACE} <${DRILL_CLUSTER}-1-full-recovery-…> -c full-recovery"
    echo "     'recovery ended before configured recovery target was reached' means no"
    echo "     transaction after the target time was archived"
    exit 1
  fi
  [ "$($KUBECTL get cluster "$DRILL_CLUSTER" -n "$NAMESPACE" -o jsonpath='{.status.phase}')" = "Cluster in healthy state" ]
}
wait_for "${DRILL_CLUSTER} healthy" 1800 drill_ready
RESTORE_SECONDS=$((SECONDS - RESTORE_START))
DRILL_POD=$($KUBECTL get cluster "$DRILL_CLUSTER" -n "$NAMESPACE" -o jsonpath='{.status.currentPrimary}')
echo "  ✅ Restored in ${RESTORE_SECONDS}s (pod ${DRILL_POD})"

# ── 5. Verify point in time ────────────────────────────────────────────────
echo ""
echo "[5/6] Verifying the restored data..."
BEFORE=$(psql_on "$DRILL_POD" "SELECT count(*) FROM restore_drill_marker WHERE run_id='${RUN_ID}' AND marker='before'")
AFTER=$(psql_on "$DRILL_POD" "SELECT count(*) FROM restore_drill_marker WHERE run_id='${RUN_ID}' AND marker='after'")
# items exists only once lumen-api has started against this database
ITEMS_SRC=$(psql_on "$PRIMARY" "SELECT count(*) FROM items" 2>/dev/null || echo "n/a")
ITEMS_DRILL=$(psql_on "$DRILL_POD" "SELECT count(*) FROM items" 2>/dev/null || echo "n/a")
echo "  marker 'before': ${BEFORE} (expected 1)"
echo "  marker 'after':  ${AFTER} (expected 0)"
echo "  items rows: ${ITEMS_DRILL} restored, ${ITEMS_SRC} in ${SOURCE_CLUSTER} now (informative only)"

# ── 6. Verdict ─────────────────────────────────────────────────────────────
echo ""
echo "[6/6] Result"
if [ "$BEFORE" = "1" ] && [ "$AFTER" = "0" ]; then
  echo "  ✅ PASS: point-in-time recovery to ${TARGET_TIME} in ${RESTORE_SECONDS}s (backup ${BACKUP_NAME})"
  echo ""
  echo "Record it in docs/runbooks/postgres-backup-restore.md (drill log):"
  echo "| $(date -u +%Y-%m-%d) | ${RUN_ID} | PASS | ${RESTORE_SECONDS}s | ${ITEMS_DRILL} items rows |"
else
  echo "  ❌ FAIL: the restored cluster does not match the target time"
  exit 1
fi
