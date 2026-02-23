#!/bin/bash
set -e

ARTIFACTS_DIR="../01-connected-zone/artifacts/vso"
REGISTRY="localhost:5000"

echo "====================================="
echo "Pushing Vault Secrets Operator images to transit registry"
echo "====================================="

# Check if registry is running
if ! curl -s http://localhost:5000/v2/ > /dev/null 2>&1; then
    echo "❌ Transit registry not running on localhost:5000"
    echo "Run: cd 02-transit-zone && ./setup.sh"
    exit 1
fi

# Check if artifacts exist
if [ ! -d "$ARTIFACTS_DIR/images" ]; then
    echo "❌ VSO artifacts not found."
    echo "Run: cd 01-connected-zone && ./scripts/15-pull-vso.sh"
    exit 1
fi

# Load images from tar
echo "Loading VSO images..."
for tar in "$ARTIFACTS_DIR/images/"*.tar; do
    echo "  Loading $(basename $tar)..."
    docker load -i "$tar"
done

# Tag and push
echo "Tagging and pushing images to registry..."
while IFS= read -r image; do
    echo "Processing $image..."

    # hashicorp/vault-secrets-operator:1.3.0 → localhost:5000/hashicorp/vault-secrets-operator:1.3.0
    registry_image="$REGISTRY/$image"

    echo "  Tagging $image as $registry_image..."
    docker tag "$image" "$registry_image"

    echo "  Pushing $registry_image..."
    docker push "$registry_image"
done < "$ARTIFACTS_DIR/images.txt"

echo ""
echo "✅ VSO images pushed to transit registry!"
echo ""
echo "Verify with:"
echo "  curl -s http://localhost:5000/v2/hashicorp/vault-secrets-operator/tags/list | jq ."
