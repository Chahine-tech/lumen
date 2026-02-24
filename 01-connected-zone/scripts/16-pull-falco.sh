#!/bin/bash
# Pull Falco 0.43.0 images and Helm chart for airgap transfer
# Run this in the CONNECTED zone (internet access required)
set -e

FALCO_VERSION="0.43.0"
FALCO_CHART_VERSION="4.21.2"  # falcosecurity/falco chart latest for 0.43.0
ARTIFACTS_DIR="$(cd "$(dirname "$0")/../../artifacts" && pwd)/falco"

echo "=== Falco ${FALCO_VERSION} — Connected Zone Pull ==="
echo ""

mkdir -p "${ARTIFACTS_DIR}/images"
mkdir -p "${ARTIFACTS_DIR}/helm"

echo "[1/3] Pulling Falco image (multi-arch, ARM64 included)..."
docker pull "falcosecurity/falco:${FALCO_VERSION}"
docker save "falcosecurity/falco:${FALCO_VERSION}" \
  -o "${ARTIFACTS_DIR}/images/falco-${FALCO_VERSION}.tar"
echo "  Saved: falco-${FALCO_VERSION}.tar"
echo ""

echo "[2/3] Downloading Falco Helm chart..."
helm repo add falcosecurity https://falcosecurity.github.io/charts 2>/dev/null || true
helm repo update falcosecurity
helm pull falcosecurity/falco \
  --version "${FALCO_CHART_VERSION}" \
  --destination "${ARTIFACTS_DIR}/helm/"
echo "  Saved: falco-${FALCO_CHART_VERSION}.tgz"
echo ""

echo "[3/3] Writing image manifest..."
cat > "${ARTIFACTS_DIR}/images.txt" <<EOF
falcosecurity/falco:${FALCO_VERSION}
EOF
echo ""

echo "=== Done ==="
echo ""
echo "Artifacts saved to: ${ARTIFACTS_DIR}"
echo ""
echo "Next steps:"
echo "  1. Transfer artifacts/ to transit zone (USB key, secure copy)"
echo "  2. Run: 02-transit-zone/push-falco.sh"
