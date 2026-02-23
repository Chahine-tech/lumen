#!/bin/bash
set -e

VAULT_VERSION="1.19.0"
VAULT_K8S_VERSION="1.6.2"
VAULT_CHART_VERSION="0.30.0"
ARTIFACTS_DIR="artifacts/vault"

echo "====================================="
echo "Phase 19: Pulling Vault artifacts"
echo "====================================="

mkdir -p "$ARTIFACTS_DIR/images"
mkdir -p "$ARTIFACTS_DIR/helm"

# Pull images
echo "Pulling Vault images..."

echo "  - Pulling vault:${VAULT_VERSION}..."
docker pull "hashicorp/vault:${VAULT_VERSION}"

echo "  - Pulling vault-k8s:${VAULT_K8S_VERSION} (Agent Injector)..."
docker pull "hashicorp/vault-k8s:${VAULT_K8S_VERSION}"

# Download Helm chart
echo "Downloading Vault Helm chart v${VAULT_CHART_VERSION}..."
if ! helm repo list | grep -q "^hashicorp"; then
    helm repo add hashicorp https://helm.releases.hashicorp.com
fi
helm repo update
helm pull hashicorp/vault --version ${VAULT_CHART_VERSION} -d "$ARTIFACTS_DIR/helm"

# Save images to tar archives
echo "Saving images to tar archives..."
docker save "hashicorp/vault:${VAULT_VERSION}" -o "$ARTIFACTS_DIR/images/vault-${VAULT_VERSION}.tar"
docker save "hashicorp/vault-k8s:${VAULT_K8S_VERSION}" -o "$ARTIFACTS_DIR/images/vault-k8s-${VAULT_K8S_VERSION}.tar"

# Create images list
cat > "$ARTIFACTS_DIR/images.txt" <<EOF
hashicorp/vault:${VAULT_VERSION}
hashicorp/vault-k8s:${VAULT_K8S_VERSION}
EOF

echo ""
echo "✅ Vault artifacts downloaded successfully!"
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
