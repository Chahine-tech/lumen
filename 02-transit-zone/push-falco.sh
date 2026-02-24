#!/bin/bash
# Push Falco images from transit zone to airgap registry (node-1:5000)
# Run this script FROM node-1 or with docker pointed at node-1
set -e

FALCO_VERSION="0.43.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/../artifacts/falco"
REGISTRY="localhost:5000"

echo "=== Falco ${FALCO_VERSION} — Transit Zone Push ==="
echo ""

echo "[1/3] Checking registry availability..."
if ! curl -sf "http://${REGISTRY}/v2/" > /dev/null; then
  echo "ERROR: Registry not reachable at ${REGISTRY}"
  echo "Make sure the Docker registry is running: docker ps | grep registry"
  exit 1
fi
echo "  Registry OK: ${REGISTRY}"
echo ""

echo "[2/3] Loading and pushing Falco image..."
docker load -i "${ARTIFACTS_DIR}/images/falco-${FALCO_VERSION}.tar"
docker tag "falcosecurity/falco:${FALCO_VERSION}" \
  "${REGISTRY}/falcosecurity/falco:${FALCO_VERSION}"
docker push "${REGISTRY}/falcosecurity/falco:${FALCO_VERSION}"
echo ""

echo "[3/3] Verifying image in registry..."
curl -s "http://${REGISTRY}/v2/falcosecurity/falco/tags/list"
echo ""

echo "=== Done ==="
echo ""
echo "Image available at: ${REGISTRY}/falcosecurity/falco:${FALCO_VERSION}"
echo ""
echo "Next steps:"
echo "  ArgoCD will sync automatically once 16-application-falco.yaml is pushed to Gitea"
