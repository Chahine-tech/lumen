#!/bin/bash
set -e

VSO_VERSION="1.3.0"
ARTIFACTS_DIR="artifacts/vso"

echo "====================================="
echo "Pulling Vault Secrets Operator artifacts"
echo "====================================="

mkdir -p "$ARTIFACTS_DIR/images"
mkdir -p "$ARTIFACTS_DIR/helm"

# Pull image
echo "Pulling vault-secrets-operator:${VSO_VERSION}..."
docker pull "hashicorp/vault-secrets-operator:${VSO_VERSION}"

# Download Helm chart
echo "Downloading VSO Helm chart ${VSO_VERSION}..."
if ! helm repo list | grep -q "^hashicorp"; then
    helm repo add hashicorp https://helm.releases.hashicorp.com
fi
helm repo update hashicorp
helm pull hashicorp/vault-secrets-operator --version ${VSO_VERSION} -d "$ARTIFACTS_DIR/helm"

# Save image to tar
echo "Saving image to tar archive..."
docker save "hashicorp/vault-secrets-operator:${VSO_VERSION}" \
    -o "$ARTIFACTS_DIR/images/vault-secrets-operator-${VSO_VERSION}.tar"

# Create images list
cat > "$ARTIFACTS_DIR/images.txt" <<EOF
hashicorp/vault-secrets-operator:${VSO_VERSION}
EOF

echo ""
echo "✅ VSO artifacts downloaded successfully!"
echo ""
echo "Artifacts created:"
echo "Images:"
ls -lh "$ARTIFACTS_DIR/images/"
echo ""
echo "Helm chart:"
ls -lh "$ARTIFACTS_DIR/helm/"
