#!/bin/bash
# Push Kyverno images from transit zone to airgap registry (node-1:5000)
# Run this script FROM node-1 or with docker pointed at node-1
set -e

KYVERNO_VERSION="v1.18.1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/../artifacts/kyverno"
REGISTRY="localhost:5000"

IMAGES=(
  "kyverno/kyverno"
  "kyverno/kyvernopre"
)

echo "=== Kyverno ${KYVERNO_VERSION} — Transit Zone Push ==="
echo ""

echo "[1/3] Checking registry availability..."
if ! curl -sf "http://${REGISTRY}/v2/" > /dev/null; then
  echo "ERROR: Registry not reachable at ${REGISTRY}"
  echo "Make sure the Docker registry is running: docker ps | grep registry"
  exit 1
fi
echo "  Registry OK: ${REGISTRY}"
echo ""

echo "[2/3] Loading and pushing Kyverno images..."
for repo in "${IMAGES[@]}"; do
  name=$(basename "${repo}")
  docker load -i "${ARTIFACTS_DIR}/images/${name}-${KYVERNO_VERSION}.tar"
  docker tag "ghcr.io/${repo}:${KYVERNO_VERSION}" \
    "${REGISTRY}/${repo}:${KYVERNO_VERSION}"
  docker push "${REGISTRY}/${repo}:${KYVERNO_VERSION}"
done
echo ""

echo "[3/3] Verifying images in registry..."
for repo in "${IMAGES[@]}"; do
  curl -s "http://${REGISTRY}/v2/${repo}/tags/list"
  echo ""
done

echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  ArgoCD will sync automatically once 19-application-kyverno.yaml is pushed to Gitea"
