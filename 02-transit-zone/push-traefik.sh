#!/bin/bash
set -e

ARTIFACTS_DIR="../01-connected-zone/artifacts/traefik"
REGISTRY="localhost:5000"

echo "====================================="
echo "Pushing Traefik images to transit registry"
echo "====================================="

# Check if registry is running
if ! curl -s http://localhost:5000/v2/ > /dev/null 2>&1; then
    echo "❌ Transit registry not running on localhost:5000"
    echo "Run: cd 02-transit-zone && ./setup.sh"
    exit 1
fi

# Load images from tar
echo "Loading Traefik images..."
docker load -i "$ARTIFACTS_DIR/images/traefik-v3.6.8.tar"
docker load -i "$ARTIFACTS_DIR/images/kubectl.tar"

# Tag and push
while IFS= read -r image; do
    echo "Processing $image..."

    # Tag for local registry
    # traefik:v3.6.8 → localhost:5000/traefik:v3.6.8
    # bitnami/kubectl:latest → localhost:5000/bitnami/kubectl:latest
    registry_image="$REGISTRY/$image"

    echo "Tagging $image as $registry_image..."
    docker tag "$image" "$registry_image"

    echo "Pushing $registry_image..."
    docker push "$registry_image"
done < "$ARTIFACTS_DIR/images.txt"

echo ""
echo "✅ Traefik images pushed to transit registry!"
echo ""
echo "Verify with:"
echo "  curl -s http://localhost:5000/v2/_catalog | jq ."
echo "  curl -s http://localhost:5000/v2/traefik/tags/list | jq ."
echo "  curl -s http://localhost:5000/v2/bitnami/kubectl/tags/list | jq ."
