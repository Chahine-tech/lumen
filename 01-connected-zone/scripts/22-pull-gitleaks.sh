#!/bin/bash
# Pull gitleaks v8.30.1 for the airgap CI secret scan (.gitea/workflows/secret-scan.yaml)
# Run this in the CONNECTED zone (internet access required)
set -e

GITLEAKS_VERSION="v8.30.1"
ARTIFACTS_DIR="$(cd "$(dirname "$0")/../../artifacts" && pwd)/gitleaks"
IMAGE="ghcr.io/gitleaks/gitleaks:${GITLEAKS_VERSION}"

echo "=== gitleaks ${GITLEAKS_VERSION}: Connected Zone Pull ==="
mkdir -p "${ARTIFACTS_DIR}/images"
docker pull --platform linux/arm64 "${IMAGE}"
docker save "${IMAGE}" -o "${ARTIFACTS_DIR}/images/gitleaks-${GITLEAKS_VERSION}.tar"
echo "${IMAGE}" > "${ARTIFACTS_DIR}/images.txt"
echo "  Saved: gitleaks-${GITLEAKS_VERSION}.tar"
echo ""
echo "Next: 02-transit-zone/push-gitleaks.sh"
