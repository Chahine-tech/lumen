#!/bin/bash
set -e

TRAEFIK_VERSION="v3.6.8"
KUBECTL_VERSION="latest"
ARTIFACTS_DIR="artifacts/traefik"
HELM_CHART_VERSION="39.0.1"

echo "====================================="
echo "Phase 9: Pulling Traefik artifacts"
echo "====================================="

mkdir -p "$ARTIFACTS_DIR/images"
mkdir -p "$ARTIFACTS_DIR/helm"

# Pull Traefik image
echo "Pulling traefik:${TRAEFIK_VERSION}..."
docker pull "traefik:${TRAEFIK_VERSION}"

# Pull kubectl image for certificate generation (not openssl)
echo "Pulling bitnami/kubectl:${KUBECTL_VERSION}..."
docker pull "bitnami/kubectl:${KUBECTL_VERSION}"

# Download Helm chart
echo "Downloading Traefik Helm chart v${HELM_CHART_VERSION}..."
if ! helm repo list | grep -q "^traefik"; then
    helm repo add traefik https://traefik.github.io/charts
fi
helm repo update
helm pull traefik/traefik --version ${HELM_CHART_VERSION} -d "$ARTIFACTS_DIR/helm"

# Save to tar archives
echo "Saving images to tar archives..."
docker save "traefik:${TRAEFIK_VERSION}" -o "$ARTIFACTS_DIR/images/traefik-${TRAEFIK_VERSION}.tar"
docker save "bitnami/kubectl:${KUBECTL_VERSION}" -o "$ARTIFACTS_DIR/images/kubectl.tar"

# Create images list
cat > "$ARTIFACTS_DIR/images.txt" <<EOF
traefik:${TRAEFIK_VERSION}
bitnami/kubectl:${KUBECTL_VERSION}
EOF

echo ""
echo "✅ Traefik artifacts downloaded successfully!"
echo ""
echo "Artifacts created:"
echo "Images:"
ls -lh "$ARTIFACTS_DIR/images/"
echo ""
echo "Helm chart:"
ls -lh "$ARTIFACTS_DIR/helm/"
echo ""
echo "Images to push to transit registry:"
cat "$ARTIFACTS_DIR/images.txt"
