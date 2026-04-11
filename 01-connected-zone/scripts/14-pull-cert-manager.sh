#!/bin/bash
set -e

CERT_MANAGER_VERSION="v1.17.1"
ARTIFACTS_DIR="artifacts/cert-manager"

echo "====================================="
echo "Pulling cert-manager artifacts"
echo "====================================="

mkdir -p "$ARTIFACTS_DIR/images"
mkdir -p "$ARTIFACTS_DIR/helm"

# Pull images
echo "Pulling cert-manager images..."

for img in controller webhook cainjector; do
    echo "  - Pulling cert-manager-${img}:${CERT_MANAGER_VERSION}..."
    docker pull "quay.io/jetstack/cert-manager-${img}:${CERT_MANAGER_VERSION}"
done

# ctl image (startupapicheck)
echo "  - Pulling cert-manager-startupapicheck:${CERT_MANAGER_VERSION}..."
docker pull "quay.io/jetstack/cert-manager-startupapicheck:${CERT_MANAGER_VERSION}"

# Download Helm chart
echo "Downloading cert-manager Helm chart ${CERT_MANAGER_VERSION}..."
if ! helm repo list | grep -q "^jetstack"; then
    helm repo add jetstack https://charts.jetstack.io
fi
helm repo update
helm pull jetstack/cert-manager --version ${CERT_MANAGER_VERSION} -d "$ARTIFACTS_DIR/helm"

# Save images to tar archives
echo "Saving images to tar archives..."
for img in controller webhook cainjector; do
    docker save "quay.io/jetstack/cert-manager-${img}:${CERT_MANAGER_VERSION}" \
        -o "$ARTIFACTS_DIR/images/cert-manager-${img}-${CERT_MANAGER_VERSION}.tar"
done
docker save "quay.io/jetstack/cert-manager-startupapicheck:${CERT_MANAGER_VERSION}" \
    -o "$ARTIFACTS_DIR/images/cert-manager-startupapicheck-${CERT_MANAGER_VERSION}.tar"

# Create images list
cat > "$ARTIFACTS_DIR/images.txt" <<EOF
quay.io/jetstack/cert-manager-controller:${CERT_MANAGER_VERSION}
quay.io/jetstack/cert-manager-webhook:${CERT_MANAGER_VERSION}
quay.io/jetstack/cert-manager-cainjector:${CERT_MANAGER_VERSION}
quay.io/jetstack/cert-manager-startupapicheck:${CERT_MANAGER_VERSION}
EOF

echo ""
echo "✅ cert-manager artifacts downloaded successfully!"
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
