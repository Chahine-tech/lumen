#!/bin/bash
# Pull Argo Rollouts v1.8.0 image and Helm chart for airgap transfer
# Run this in the CONNECTED zone (internet access required)
set -e

ROLLOUTS_VERSION="v1.8.0"
CHART_VERSION="2.39.0"
ARTIFACTS_DIR="$(cd "$(dirname "$0")/../../artifacts" && pwd)/argo-rollouts"

echo "=== Argo Rollouts ${ROLLOUTS_VERSION} — Connected Zone Pull ==="
echo ""

mkdir -p "${ARTIFACTS_DIR}/images"
mkdir -p "${ARTIFACTS_DIR}/helm"

echo "[1/3] Pulling Argo Rollouts image (multi-arch, ARM64 included)..."
docker pull "quay.io/argoproj/argo-rollouts:${ROLLOUTS_VERSION}"
docker save "quay.io/argoproj/argo-rollouts:${ROLLOUTS_VERSION}" \
  -o "${ARTIFACTS_DIR}/images/argo-rollouts-${ROLLOUTS_VERSION}.tar"
echo "  Saved: argo-rollouts-${ROLLOUTS_VERSION}.tar"
echo ""

echo "[2/3] Downloading Argo Rollouts Helm chart..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo
helm pull argo/argo-rollouts \
  --version "${CHART_VERSION}" \
  --destination "${ARTIFACTS_DIR}/helm/"
echo "  Saved: argo-rollouts-${CHART_VERSION}.tgz"
echo ""

echo "[3/3] Writing image manifest..."
cat > "${ARTIFACTS_DIR}/images.txt" <<EOF
quay.io/argoproj/argo-rollouts:${ROLLOUTS_VERSION}
EOF
echo ""

echo "=== Done ==="
echo ""
echo "Artifacts saved to: ${ARTIFACTS_DIR}"
echo ""
echo "Next steps:"
echo "  1. Transfer artifacts/ to transit zone (USB key, secure copy)"
echo "  2. Run: 02-transit-zone/push-argo-rollouts.sh"
