#!/bin/bash
# Push Cosign image from transit zone to airgap registry (node-1:5000)
# Run this script FROM node-1 or with docker pointed at node-1
set -e

COSIGN_VERSION="v3.0.5"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/../artifacts/cosign"
REGISTRY="localhost:5000"

echo "=== Cosign ${COSIGN_VERSION} — Transit Zone Push ==="
echo ""

echo "[1/3] Checking registry availability..."
if ! curl -sf "http://${REGISTRY}/v2/" > /dev/null; then
  echo "ERROR: Registry not reachable at ${REGISTRY}"
  echo "Make sure the Docker registry is running: docker ps | grep registry"
  exit 1
fi
echo "  Registry OK: ${REGISTRY}"
echo ""

echo "[2/3] Loading and pushing Cosign image..."
docker load -i "${ARTIFACTS_DIR}/images/cosign-${COSIGN_VERSION}.tar"
docker tag "gcr.io/projectsigstore/cosign:${COSIGN_VERSION}" \
  "${REGISTRY}/projectsigstore/cosign:${COSIGN_VERSION}"
docker push "${REGISTRY}/projectsigstore/cosign:${COSIGN_VERSION}"
echo ""

echo "[3/3] Verifying image in registry..."
curl -s "http://${REGISTRY}/v2/projectsigstore/cosign/tags/list"
echo ""

echo "=== Done ==="
echo ""
echo "Image available at: ${REGISTRY}/projectsigstore/cosign:${COSIGN_VERSION}"
echo ""
echo "Next steps:"
echo "  CI will use this image to sign lumen-api images after each push"
echo "  Verify a signature: cosign verify --key cosign.pub --allow-insecure-registry --insecure-ignore-tlog <image>"
