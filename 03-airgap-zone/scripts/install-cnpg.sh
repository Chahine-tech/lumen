#!/bin/bash
# Bootstrap script — CloudNativePG v1.25.1 installation (airgap)
#
# Prerequisites:
# - K3s running with node-1 and node-2
# - Transit registry running at localhost:5000 with CNPG images
# - Docker registry running on node-1 at 192.168.2.2:5000
#
# What this installs:
#   - CloudNativePG operator (cnpg-system namespace)
#   - PostgreSQL Cluster lumen-db (lumen namespace): 1 master + 1 replica + 1 witness
#   - NetworkPolicies for lumen-api → postgres

set -e

CNPG_VERSION="1.25.1"
PG_VERSION="16.6"
TRANSIT_REGISTRY="localhost:5000"
AIRGAP_REGISTRY="192.168.2.2:5000"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/../../01-connected-zone/artifacts/cnpg"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/cnpg"

echo "================================================"
echo "Phase 18: Installing CloudNativePG (airgap)"
echo "================================================"

# ── Step 1: Copy images from tars → airgap registry ────────────────────────
# Docker Desktop on Mac cannot push to HTTP registries directly.
# We transfer the tar files to node-1 (which has 192.168.2.2:5000 as insecure registry)
# and push from there.
echo ""
echo "[1/5] Copying images to airgap registry (via node-1)..."

TARS_DIR="${SCRIPT_DIR}/../../01-connected-zone/artifacts/cnpg/images"

transfer_and_push() {
    local tarfile="$1"
    local src_image="$2"   # original image name (ghcr.io/...)
    local dst_image="$3"   # target image in airgap registry
    local local_tar="${TARS_DIR}/${tarfile}"

    echo "  Transferring ${tarfile} to node-1 (this may take a while)..."
    multipass transfer "$local_tar" "node-1:/tmp/${tarfile}"

    echo "  Loading and pushing ${dst_image}..."
    multipass exec node-1 -- sh -c "
        docker load -i /tmp/${tarfile} > /dev/null
        docker tag ${src_image} ${dst_image}
        docker push ${dst_image}
        rm /tmp/${tarfile}
    "
    echo "  ✅ ${dst_image}"
}

transfer_and_push \
    "cloudnative-pg-${CNPG_VERSION}.tar" \
    "ghcr.io/cloudnative-pg/cloudnative-pg:${CNPG_VERSION}" \
    "${AIRGAP_REGISTRY}/cloudnative-pg:${CNPG_VERSION}"

transfer_and_push \
    "postgresql-${PG_VERSION}.tar" \
    "ghcr.io/cloudnative-pg/postgresql:${PG_VERSION}" \
    "${AIRGAP_REGISTRY}/postgresql:${PG_VERSION}"

echo "  ✅ Images in airgap registry"

# ── Step 2: Patch operator manifest to use airgap registry ─────────────────
echo ""
echo "[2/5] Patching CNPG operator manifest for airgap registry..."

OPERATOR_MANIFEST="${ARTIFACTS_DIR}/cnpg-operator.yaml"
PATCHED_MANIFEST="/tmp/cnpg-operator-patched.yaml"

sed "s|ghcr.io/cloudnative-pg/cloudnative-pg:|${AIRGAP_REGISTRY}/cloudnative-pg:|g" \
    "$OPERATOR_MANIFEST" > "$PATCHED_MANIFEST"

echo "  ✅ Manifest patched"

# ── Step 3: Deploy CNPG operator ───────────────────────────────────────────
echo ""
echo "[3/5] Deploying CNPG operator..."

multipass transfer "$PATCHED_MANIFEST" node-1:/tmp/cnpg-operator.yaml
# --server-side required: poolers CRD has annotations > 262144 bytes (kubectl client-side limit)
multipass exec node-1 -- kubectl apply --server-side --force-conflicts -f /tmp/cnpg-operator.yaml

echo "  Waiting for CNPG operator to be ready..."
multipass exec node-1 -- kubectl wait --for=condition=Available \
    deployment/cnpg-controller-manager \
    -n cnpg-system \
    --timeout=120s

echo "  ✅ CNPG operator ready"

# ── Step 4: Deploy PostgreSQL Cluster + NetworkPolicies ────────────────────
echo ""
echo "[4/5] Deploying PostgreSQL Cluster..."

multipass transfer "${MANIFESTS_DIR}/02-cluster.yaml" node-1:/tmp/cnpg-cluster.yaml
multipass transfer "${MANIFESTS_DIR}/03-network-policy.yaml" node-1:/tmp/cnpg-netpol.yaml

multipass exec node-1 -- kubectl apply -f /tmp/cnpg-cluster.yaml
multipass exec node-1 -- kubectl apply -f /tmp/cnpg-netpol.yaml

echo "  Waiting for PostgreSQL cluster to be ready (may take 2-3 min)..."
multipass exec node-1 -- kubectl wait --for=condition=Ready \
    cluster/lumen-db \
    -n lumen \
    --timeout=300s

echo "  ✅ PostgreSQL cluster ready"

# ── Step 5: Verify ─────────────────────────────────────────────────────────
echo ""
echo "[5/5] Verifying deployment..."
echo ""
echo "CNPG Operator:"
multipass exec node-1 -- kubectl get pods -n cnpg-system

echo ""
echo "PostgreSQL Cluster:"
multipass exec node-1 -- kubectl get cluster -n lumen
multipass exec node-1 -- kubectl get pods -n lumen -l cnpg.io/cluster=lumen-db

echo ""
echo "Services (rw=master, ro=replica):"
multipass exec node-1 -- kubectl get svc -n lumen | grep lumen-db

echo ""
echo "================================================"
echo "✅ CloudNativePG deployed successfully!"
echo "================================================"
echo ""
echo "Next steps:"
echo "  1. Build + push lumen-api v1.4.0: git tag v1.4.0 && git push gitea v1.4.0"
echo "  2. ArgoCD will deploy the new image with PG_RW_DSN + PG_RO_DSN env vars"
echo "  3. Test: curl https://lumen.airgap.local/items"
