#!/bin/bash
# Install the Barman Cloud plugin for CloudNativePG (airgap)
#
# Prerequisites:
#   - CloudNativePG operator 1.30 or later (upgrade-cnpg.sh)
#   - cert-manager running (the plugin issues its own mTLS certificates)
#   - Plugin manifest downloaded by 01-connected-zone/scripts/12-pull-cnpg.sh
#   - Plugin + sidecar images in the airgap registry (02-transit-zone/push-cnpg.sh)
#
# The upstream manifest is rendered locally with kubectl kustomize and the
# overlay in manifests/cnpg-plugin/ (airgap images, SIDECAR_IMAGE, resources).

set -e

BARMAN_PLUGIN_VERSION="v0.16.0"
MIN_CNPG_VERSION="1.30.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${SCRIPT_DIR}/../../01-connected-zone/artifacts/cnpg/manifests/plugin-barman-cloud-${BARMAN_PLUGIN_VERSION}.yaml"
OVERLAY_DIR="${SCRIPT_DIR}/../manifests/cnpg-plugin"
KUBECTL="multipass exec node-1 -- kubectl"

echo "================================================"
echo "Installing Barman Cloud plugin ${BARMAN_PLUGIN_VERSION}"
echo "================================================"

echo ""
echo "[1/4] Checking requirements..."
CNPG_VERSION=$($KUBECTL get deployment cnpg-controller-manager -n cnpg-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's|.*:||')
if [ "$(printf '%s\n%s\n' "$MIN_CNPG_VERSION" "$CNPG_VERSION" | sort -V | head -1)" != "$MIN_CNPG_VERSION" ]; then
  echo "  ❌ CloudNativePG ${CNPG_VERSION} is too old, the plugin needs ${MIN_CNPG_VERSION} or later"
  echo "     Run: ./upgrade-cnpg.sh"
  exit 1
fi
echo "  ✅ CloudNativePG ${CNPG_VERSION}"
$KUBECTL get crd certificates.cert-manager.io > /dev/null
echo "  ✅ cert-manager CRDs present"
if [ ! -f "$MANIFEST" ]; then
  echo "  ❌ Missing ${MANIFEST}: run 01-connected-zone/scripts/12-pull-cnpg.sh"
  exit 1
fi

echo ""
echo "[2/4] Rendering manifest for the airgap registry..."
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
cp "$OVERLAY_DIR"/*.yaml "$WORK_DIR/"
cp "$MANIFEST" "$WORK_DIR/plugin-barman-cloud.yaml"
kubectl kustomize "$WORK_DIR" > "$WORK_DIR/rendered.yaml"
if grep -q 'image: ghcr.io' "$WORK_DIR/rendered.yaml"; then
  echo "  ❌ Rendered manifest still pulls from ghcr.io, check the overlay"
  exit 1
fi
echo "  ✅ Rendered"

echo ""
echo "[3/4] Applying plugin to cnpg-system..."
multipass transfer "$WORK_DIR/rendered.yaml" node-1:/tmp/plugin-barman-cloud.yaml
$KUBECTL apply --server-side --force-conflicts -f /tmp/plugin-barman-cloud.yaml

echo ""
echo "[4/4] Waiting for the plugin to be ready..."
$KUBECTL rollout status deployment/barman-cloud -n cnpg-system --timeout=180s

echo ""
echo "================================================"
echo "✅ Barman Cloud plugin ${BARMAN_PLUGIN_VERSION} installed"
echo "================================================"
echo ""
echo "Next: apply the ObjectStore and ScheduledBackup (manifests/cnpg/06-*, 07-*)"
echo "      see docs/runbooks/postgres-backup-restore.md"
