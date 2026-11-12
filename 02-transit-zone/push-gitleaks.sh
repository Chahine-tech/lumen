#!/bin/bash
# Push the gitleaks image from the transit zone to the airgap registry
# Run this script FROM node-1 or with docker pointed at node-1
set -e

GITLEAKS_VERSION="v8.30.1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="${SCRIPT_DIR}/../artifacts/gitleaks"
REGISTRY="localhost:5000"

echo "=== gitleaks ${GITLEAKS_VERSION}: Transit Zone Push ==="
if ! curl -sf "http://${REGISTRY}/v2/" > /dev/null; then
  echo "ERROR: Registry not reachable at ${REGISTRY}"
  exit 1
fi
docker load -i "${ARTIFACTS_DIR}/images/gitleaks-${GITLEAKS_VERSION}.tar"
docker tag "ghcr.io/gitleaks/gitleaks:${GITLEAKS_VERSION}" "${REGISTRY}/gitleaks/gitleaks:${GITLEAKS_VERSION}"
docker push "${REGISTRY}/gitleaks/gitleaks:${GITLEAKS_VERSION}"
curl -s "http://${REGISTRY}/v2/gitleaks/gitleaks/tags/list"
echo ""
echo "=== Done: used by .gitea/workflows/secret-scan.yaml ==="
