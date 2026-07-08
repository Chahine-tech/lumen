#!/bin/bash
# Pull Kyverno v1.18.1 images for airgap transfer
# Run this in the CONNECTED zone (internet access required)
# The Helm chart (3.8.1) is already vendored in 03-airgap-zone/manifests/kyverno-helm/
set -e

KYVERNO_VERSION="v1.18.1"
ARTIFACTS_DIR="$(cd "$(dirname "$0")/../../artifacts" && pwd)/kyverno"

# Only the images required by the airgap values override:
# admission controller + its init container (background/cleanup/reports
# controllers and helm hooks are disabled in values-airgap-override.yaml)
IMAGES=(
  "ghcr.io/kyverno/kyverno:${KYVERNO_VERSION}"
  "ghcr.io/kyverno/kyvernopre:${KYVERNO_VERSION}"
)

echo "=== Kyverno ${KYVERNO_VERSION} — Connected Zone Pull ==="
echo ""

mkdir -p "${ARTIFACTS_DIR}/images"

echo "[1/2] Pulling Kyverno images (ARM64)..."
: > "${ARTIFACTS_DIR}/images.txt"
for image in "${IMAGES[@]}"; do
  name=$(basename "${image%%:*}")
  docker pull "${image}"
  docker save "${image}" -o "${ARTIFACTS_DIR}/images/${name}-${KYVERNO_VERSION}.tar"
  echo "${image}" >> "${ARTIFACTS_DIR}/images.txt"
  echo "  Saved: ${name}-${KYVERNO_VERSION}.tar"
done
echo ""

echo "[2/2] Helm chart already vendored (03-airgap-zone/manifests/kyverno-helm/) — nothing to download"
echo ""

echo "=== Done ==="
echo ""
echo "Artifacts saved to: ${ARTIFACTS_DIR}"
echo ""
echo "Next steps:"
echo "  1. Transfer artifacts/ to transit zone (USB key, secure copy)"
echo "  2. Run: 02-transit-zone/push-kyverno.sh"
