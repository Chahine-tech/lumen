#!/bin/bash
# Bootstrap script: CloudNativePG v1.30.1 installation (airgap)
#
# For a NEW cluster. To move an existing operator to a newer version, use
# upgrade-cnpg.sh instead (one minor at a time).
#
# Prerequisites:
# - K3s running with node-1 and node-2, Kubernetes 1.34 to 1.36 (CNPG 1.30)
# - cert-manager running (Barman Cloud plugin certificates)
# - Artifacts from 01-connected-zone/scripts/12-pull-cnpg.sh
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

# ── Step 2: Copy images from tars → airgap registry ────────────────────────
# Docker Desktop on Mac cannot push to HTTP registries directly.
# We transfer the tar files to node-1 (which has 192.168.2.2:5000 as insecure registry)
# and push from there.
echo ""
echo "[2/7] Copying images to airgap registry (via node-1)..."

while IFS= read -r src_image || [ -n "$src_image" ]; do
    [ -z "$src_image" ] && continue
    short=$(echo "$src_image" | sed 's|ghcr.io/cloudnative-pg/||')
    tarfile="$(echo "$short" | tr ':' '-').tar"
    dst_image="${AIRGAP_REGISTRY}/${short}"

    echo "  Transferring ${tarfile} to node-1 (this may take a while)..."
    multipass transfer "${ARTIFACTS_DIR}/images/${tarfile}" "node-1:/tmp/${tarfile}"

    echo "  Loading and pushing ${dst_image}..."
    multipass exec node-1 -- sh -c "
        docker load -i /tmp/${tarfile} > /dev/null
        docker tag ${src_image} ${dst_image}
        docker push ${dst_image}
        rm /tmp/${tarfile}
    "
    echo "  ✅ ${dst_image}"
done < "${ARTIFACTS_DIR}/images.txt"

echo "  ✅ Images in airgap registry"

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
for f in 03-network-policy.yaml 06-object-store.yaml 02-cluster.yaml 07-scheduled-backup.yaml; do
    multipass transfer "${MANIFESTS_DIR}/${f}" "node-1:/tmp/cnpg-${f}"
    multipass exec node-1 -- kubectl apply -f "/tmp/cnpg-${f}"
done

echo "  Waiting for PostgreSQL cluster to be ready (may take 2-3 min)..."
multipass exec node-1 -- kubectl wait --for=condition=Ready \
    cluster/lumen-db \
    -n lumen \
    --timeout=300s

echo "  ✅ PostgreSQL cluster ready"

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
