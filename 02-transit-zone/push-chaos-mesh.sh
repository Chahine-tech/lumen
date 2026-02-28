#!/bin/bash
# Push Chaos Mesh images from transit zone to airgap registry (node-1:5000)
# Run this script FROM node-1 or with docker pointed at node-1
set -e

CHAOS_VERSION="v2.7.2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/../artifacts/chaos-mesh"
REGISTRY="localhost:5000"

echo "=== Chaos Mesh ${CHAOS_VERSION} — Transit Zone Push ==="
echo ""

echo "[1/3] Checking registry availability..."
if ! curl -sf "http://${REGISTRY}/v2/" > /dev/null; then
  echo "ERROR: Registry not reachable at ${REGISTRY}"
  echo "Make sure the Docker registry is running: docker ps | grep registry"
  exit 1
fi
echo "  Registry OK: ${REGISTRY}"
echo ""

echo "[2/3] Loading and pushing Chaos Mesh images..."
for img in chaos-mesh chaos-daemon chaos-dashboard; do
  echo "  Loading ${img}..."
  docker load -i "${ARTIFACTS_DIR}/images/${img}-${CHAOS_VERSION}.tar"
  docker tag "ghcr.io/chaos-mesh/${img}:${CHAOS_VERSION}" \
    "${REGISTRY}/chaos-mesh/${img}:${CHAOS_VERSION}"
  docker push "${REGISTRY}/chaos-mesh/${img}:${CHAOS_VERSION}"
  echo "  Pushed: ${REGISTRY}/chaos-mesh/${img}:${CHAOS_VERSION}"
done
echo ""

echo "[3/3] Verifying images in registry..."
for img in chaos-mesh chaos-daemon chaos-dashboard; do
  curl -s "http://${REGISTRY}/v2/chaos-mesh/${img}/tags/list"
  echo ""
done

echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  ArgoCD will sync automatically once 18-application-chaos-mesh.yaml is pushed to Gitea"
