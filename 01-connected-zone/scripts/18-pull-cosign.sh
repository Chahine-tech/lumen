#!/bin/bash
# Pull Cosign v3.0.5 image for airgap transfer
# Run this in the CONNECTED zone (internet access required)
set -e

COSIGN_VERSION="v3.0.5"
ARTIFACTS_DIR="$(cd "$(dirname "$0")/../../artifacts" && pwd)/cosign"

echo "=== Cosign ${COSIGN_VERSION} — Connected Zone Pull ==="
echo ""

mkdir -p "${ARTIFACTS_DIR}/images"

echo "[1/2] Pulling Cosign image..."
docker pull "gcr.io/projectsigstore/cosign:${COSIGN_VERSION}"
docker save "gcr.io/projectsigstore/cosign:${COSIGN_VERSION}" \
  -o "${ARTIFACTS_DIR}/images/cosign-${COSIGN_VERSION}.tar"
echo "  Saved: cosign-${COSIGN_VERSION}.tar"
echo ""

echo "[2/2] Writing image manifest..."
cat > "${ARTIFACTS_DIR}/images.txt" <<EOF
gcr.io/projectsigstore/cosign:${COSIGN_VERSION}
EOF
echo ""

echo "=== Done ==="
echo ""
echo "Artifacts saved to: ${ARTIFACTS_DIR}"
echo ""
echo "Next steps:"
echo "  1. Transfer artifacts/ to transit zone (USB key, secure copy)"
echo "  2. Run: 02-transit-zone/push-cosign.sh"
