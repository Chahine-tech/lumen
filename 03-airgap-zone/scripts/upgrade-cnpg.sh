#!/bin/bash
# Upgrade the CloudNativePG operator one minor version at a time (airgap)
#
# CloudNativePG recommends upgrading through each minor in sequence when
# catching up, instead of jumping straight to the latest release. Each step:
#   1. checks that the running Kubernetes version is supported by that step
#   2. applies the operator manifest (images rewritten to the airgap registry)
#   3. waits for the operator, then for lumen-db to finish its rolling update
#
# Each operator upgrade restarts every PostgreSQL instance and ends with a
# switchover (primaryUpdateStrategy: unsupervised): lumen-api reconnects.
#
# Prerequisites:
#   - Manifests downloaded by 01-connected-zone/scripts/12-pull-cnpg.sh
#   - Operator images in the airgap registry (02-transit-zone/push-cnpg.sh)
#   - Kubernetes recent enough for each step: the script stops at the first
#     step the cluster does not support (ranges in lib/cnpg-compat.sh)
#
# Usage:
#   ./upgrade-cnpg.sh            # upgrade up to the last version of the path
#   ./upgrade-cnpg.sh 1.28.4     # stop after this version

set -e

CNPG_UPGRADE_PATH="1.26.3 1.27.4 1.28.4 1.29.3 1.30.1"
TARGET_VERSION="${1:-1.30.1}"
AIRGAP_REGISTRY="192.168.2.2:5000"
CLUSTER_NAME="lumen-db"
CLUSTER_NAMESPACE="lumen"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../../01-connected-zone/artifacts/cnpg/manifests"
KUBECTL="multipass exec node-1 -- kubectl"

# shellcheck source=lib/cnpg-compat.sh
source "${SCRIPT_DIR}/lib/cnpg-compat.sh"

version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

current_version() {
  $KUBECTL get deployment cnpg-controller-manager -n cnpg-system \
    -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's|.*:||'
}

wait_cluster_healthy() {
  local phase
  # The rolling update starts a few seconds after the operator restarts:
  # give it time to leave the healthy phase before polling for it
  sleep 30
  for _ in $(seq 1 60); do
    phase=$($KUBECTL get cluster "$CLUSTER_NAME" -n "$CLUSTER_NAMESPACE" -o jsonpath='{.status.phase}')
    if [ "$phase" = "Cluster in healthy state" ]; then
      echo "  ✅ ${CLUSTER_NAME}: ${phase}"
      return 0
    fi
    echo "  ${CLUSTER_NAME}: ${phase:-unknown}, waiting..."
    sleep 10
  done
  echo "  ❌ ${CLUSTER_NAME} not healthy after 10 minutes, stopping here"
  return 1
}

if ! echo " $CNPG_UPGRADE_PATH " | grep -q " ${TARGET_VERSION} "; then
  echo "❌ ${TARGET_VERSION} is not in the upgrade path: ${CNPG_UPGRADE_PATH}"
  exit 1
fi

CURRENT=$(current_version)
echo "================================================"
echo "CloudNativePG upgrade: ${CURRENT} → ${TARGET_VERSION}"
echo "================================================"

for version in $CNPG_UPGRADE_PATH; do
  version_lt "$CURRENT" "$version" || continue
  version_lt "$TARGET_VERSION" "$version" && break

  echo ""
  echo "── Step: ${CURRENT} → ${version} ─────────────────────────────"
  require_k8s_for_cnpg "$version"

  manifest="${MANIFESTS_DIR}/cnpg-${version}.yaml"
  if [ ! -f "$manifest" ]; then
    echo "  ❌ Missing ${manifest}: run 01-connected-zone/scripts/12-pull-cnpg.sh"
    exit 1
  fi

  patched="/tmp/cnpg-${version}-patched.yaml"
  sed "s|ghcr.io/cloudnative-pg/cloudnative-pg:|${AIRGAP_REGISTRY}/cloudnative-pg:|g" "$manifest" > "$patched"
  multipass transfer "$patched" "node-1:/tmp/cnpg-operator.yaml"
  # --server-side required: poolers CRD has annotations > 262144 bytes (kubectl client-side limit)
  $KUBECTL apply --server-side --force-conflicts -f /tmp/cnpg-operator.yaml

  $KUBECTL rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=180s
  wait_cluster_healthy

  CURRENT="$version"
done

echo ""
echo "================================================"
echo "✅ CloudNativePG operator at $(current_version)"
echo "================================================"
