#!/bin/bash
# Push Argo Rollouts images from transit zone to airgap registry (node-1:5000)
# Run this script FROM node-1 or with docker pointed at node-1
set -e

ROLLOUTS_VERSION="v1.8.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/../artifacts/argo-rollouts"
REGISTRY="localhost:5000"

echo "=== Argo Rollouts ${ROLLOUTS_VERSION} — Transit Zone Push ==="
echo ""

echo "[1/3] Checking registry availability..."
if ! curl -sf "http://${REGISTRY}/v2/" > /dev/null; then
  echo "ERROR: Registry not reachable at ${REGISTRY}"
  echo "Make sure the Docker registry is running: docker ps | grep registry"
  exit 1
fi
echo "  Registry OK: ${REGISTRY}"
echo ""

echo "[2/3] Loading and pushing Argo Rollouts image..."
docker load -i "${ARTIFACTS_DIR}/images/argo-rollouts-${ROLLOUTS_VERSION}.tar"
docker tag "quay.io/argoproj/argo-rollouts:${ROLLOUTS_VERSION}" \
  "${REGISTRY}/argoproj/argo-rollouts:${ROLLOUTS_VERSION}"
docker push "${REGISTRY}/argoproj/argo-rollouts:${ROLLOUTS_VERSION}"
echo ""

echo "[3/3] Verifying image in registry..."
curl -s "http://${REGISTRY}/v2/argoproj/argo-rollouts/tags/list"
echo ""

echo "=== Done ==="
echo ""
echo "Image available at: ${REGISTRY}/argoproj/argo-rollouts:${ROLLOUTS_VERSION}"
echo ""
echo "Next steps:"
echo "  ArgoCD will sync automatically once 17-application-argo-rollouts.yaml is pushed to Gitea"
