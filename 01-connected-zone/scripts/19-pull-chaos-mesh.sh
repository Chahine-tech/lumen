#!/bin/bash
# Pull Chaos Mesh v2.7.2 images and Helm chart for airgap transfer
# Run this in the CONNECTED zone (internet access required)
set -e

CHAOS_VERSION="v2.7.2"
CHART_VERSION="2.7.2"
ARTIFACTS_DIR="$(cd "$(dirname "$0")/../../artifacts" && pwd)/chaos-mesh"

echo "=== Chaos Mesh ${CHAOS_VERSION} — Connected Zone Pull ==="
echo ""

mkdir -p "${ARTIFACTS_DIR}/images" "${ARTIFACTS_DIR}/helm"

echo "[1/3] Pulling Chaos Mesh images (multi-arch, ARM64 included)..."
for img in chaos-mesh chaos-daemon chaos-dashboard; do
  echo "  Pulling ${img}..."
  docker pull "ghcr.io/chaos-mesh/${img}:${CHAOS_VERSION}"
  docker save "ghcr.io/chaos-mesh/${img}:${CHAOS_VERSION}" \
    -o "${ARTIFACTS_DIR}/images/${img}-${CHAOS_VERSION}.tar"
  echo "  Saved: ${img}-${CHAOS_VERSION}.tar"
done
echo ""

echo "[2/3] Downloading Chaos Mesh Helm chart..."
helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
helm repo update chaos-mesh
helm pull chaos-mesh/chaos-mesh \
  --version "${CHART_VERSION}" \
  --destination "${ARTIFACTS_DIR}/helm/"
echo "  Saved: chaos-mesh-${CHART_VERSION}.tgz"
echo ""

echo "[3/3] Writing image manifest..."
cat > "${ARTIFACTS_DIR}/images.txt" <<EOF
ghcr.io/chaos-mesh/chaos-mesh:${CHAOS_VERSION}
ghcr.io/chaos-mesh/chaos-daemon:${CHAOS_VERSION}
ghcr.io/chaos-mesh/chaos-dashboard:${CHAOS_VERSION}
EOF
echo ""

echo "=== Done ==="
echo ""
echo "Artifacts saved to: ${ARTIFACTS_DIR}"
echo ""
echo "Next steps:"
echo "  1. Transfer artifacts/ to transit zone (USB key, secure copy)"
echo "  2. Run: 02-transit-zone/push-chaos-mesh.sh"
