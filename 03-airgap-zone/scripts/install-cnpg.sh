#!/bin/bash
# Bootstrap script: CloudNativePG v1.30.1 installation (airgap)
#
# For a NEW cluster. To move an existing operator to a newer version, use
# upgrade-cnpg.sh instead (one minor at a time).
#
# Prerequisites:
# - K3s running with node-1 and node-2, Kubernetes 1.34 to 1.36 (CNPG 1.30)
# - cert-manager running (Barman Cloud plugin certificates)
# - Artifacts from scripts/mirror.py pull, images pushed by scripts/mirror.py push
# - Docker registry running on node-1 at 192.168.2.2:5000
#
# What this installs:
#   - CloudNativePG operator (cnpg-system namespace)
#   - Barman Cloud plugin (cnpg-system namespace)
#   - PostgreSQL Cluster lumen-db (lumen namespace): 1 primary + 2 replicas
#   - NetworkPolicies for lumen-api → postgres
#   - ObjectStore + ScheduledBackup (backups to Garage on backup-1)

set -e

CNPG_VERSION="1.30.1"
AIRGAP_REGISTRY="192.168.2.2:5000"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/../../01-connected-zone/artifacts/cnpg"
PG_VERSION="16.6"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/cnpg"
# shellcheck disable=SC2034  # read by require_k8s_for_cnpg (lib/cnpg-compat.sh)
KUBECTL="multipass exec node-1 -- kubectl"

# shellcheck source=lib/cnpg-compat.sh
source "${SCRIPT_DIR}/lib/cnpg-compat.sh"

echo "================================================"
echo "Installing CloudNativePG ${CNPG_VERSION} (airgap)"
echo "================================================"

# ── Step 1: Kubernetes compatibility ───────────────────────────────────────
echo ""
echo "[1/7] Checking Kubernetes version..."
require_k8s_for_cnpg "$CNPG_VERSION"

# ── Step 2: Images in the airgap registry ──────────────────────────────────
# Pushed by scripts/mirror.py push (mirror.yaml). Checked from node-1, which
# reaches the registry. The registry answers 404 without an Accept header.
echo ""
echo "[2/7] Checking the images in the airgap registry (from node-1)..."
ACCEPT="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
for image in "cloudnative-pg:${CNPG_VERSION}" "postgresql:${PG_VERSION}"; do
    if ! multipass exec node-1 -- curl -sf -o /dev/null -H "Accept: ${ACCEPT}" \
        "http://${AIRGAP_REGISTRY}/v2/${image%%:*}/manifests/${image#*:}"; then
        echo "  ❌ ${AIRGAP_REGISTRY}/${image} missing: run scripts/mirror.py push"
        exit 1
    fi
    echo "  ✅ ${AIRGAP_REGISTRY}/${image}"
done

# ── Step 3: Patch operator manifest to use airgap registry ─────────────────
echo ""
echo "[3/7] Patching CNPG operator manifest for airgap registry..."

OPERATOR_MANIFEST="${ARTIFACTS_DIR}/manifests/cnpg-${CNPG_VERSION}.yaml"
PATCHED_MANIFEST="/tmp/cnpg-operator-patched.yaml"

sed "s|ghcr.io/cloudnative-pg/cloudnative-pg:|${AIRGAP_REGISTRY}/cloudnative-pg:|g" \
    "$OPERATOR_MANIFEST" > "$PATCHED_MANIFEST"

echo "  ✅ Manifest patched"

# ── Step 4: Deploy CNPG operator ───────────────────────────────────────────
echo ""
echo "[4/7] Deploying CNPG operator..."

multipass transfer "$PATCHED_MANIFEST" node-1:/tmp/cnpg-operator.yaml
# --server-side required: poolers CRD has annotations > 262144 bytes (kubectl client-side limit)
multipass exec node-1 -- kubectl apply --server-side --force-conflicts -f /tmp/cnpg-operator.yaml

echo "  Waiting for CNPG operator to be ready..."
multipass exec node-1 -- kubectl wait --for=condition=Available \
    deployment/cnpg-controller-manager \
    -n cnpg-system \
    --timeout=120s

echo "  ✅ CNPG operator ready"

# ── Step 5: Barman Cloud plugin ────────────────────────────────────────────
echo ""
echo "[5/7] Installing Barman Cloud plugin..."
"${SCRIPT_DIR}/install-cnpg-plugin.sh"

# ── Step 6: Deploy PostgreSQL Cluster + NetworkPolicies + backups ──────────
echo ""
echo "[6/7] Deploying PostgreSQL Cluster..."

# ObjectStore before the Cluster: the Cluster references it for WAL archiving.
# Its credentials (Secret lumen-db-backup-s3) are synced by VSO from Vault
# lumen/cnpg-backup, seeded by seed-cnpg-backup-creds.sh.
apply_manifest() {
    multipass transfer "${MANIFESTS_DIR}/$1" "node-1:/tmp/cnpg-$1"
    multipass exec node-1 -- kubectl apply -f "/tmp/cnpg-$1"
}
for f in 03-network-policy.yaml 06-object-store.yaml 02-cluster.yaml; do
    apply_manifest "$f"
done

echo "  Waiting for PostgreSQL cluster to be ready (may take 2-3 min)..."
multipass exec node-1 -- kubectl wait --for=condition=Ready \
    cluster/lumen-db \
    -n lumen \
    --timeout=300s
multipass exec node-1 -- kubectl wait \
    --for=jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'=True \
    cluster/lumen-db \
    -n lumen \
    --timeout=300s

echo "  ✅ PostgreSQL cluster ready, WAL archiving working"

# Only now: `immediate: true` takes a backup the moment the ScheduledBackup is
# created. Created before every instance runs the plugin sidecar, that first
# backup fails ("requested plugin is not available") and is not retried
# before the next scheduled run (seen on the k3d test, 2026-11-12).
apply_manifest 07-scheduled-backup.yaml

# ── Step 7: Verify ─────────────────────────────────────────────────────────
echo ""
echo "[7/7] Verifying deployment..."
echo ""
echo "CNPG Operator + plugin:"
multipass exec node-1 -- kubectl get pods -n cnpg-system

echo ""
echo "PostgreSQL Cluster:"
multipass exec node-1 -- kubectl get cluster -n lumen
multipass exec node-1 -- kubectl get pods -n lumen -l cnpg.io/cluster=lumen-db

echo ""
echo "Services (rw=primary, ro=replicas):"
multipass exec node-1 -- kubectl get svc -n lumen | grep lumen-db

echo ""
echo "Backups:"
multipass exec node-1 -- kubectl get objectstore,scheduledbackup,backup -n lumen

echo ""
echo "================================================"
echo "✅ CloudNativePG deployed successfully!"
echo "================================================"
echo ""
echo "Next steps:"
echo "  1. Check WAL archiving: kubectl get cluster lumen-db -n lumen -o jsonpath='{.status.conditions[?(@.type==\"ContinuousArchiving\")]}'"
echo "  2. Run a restore drill: 03-airgap-zone/scripts/cnpg-restore-drill.sh"
