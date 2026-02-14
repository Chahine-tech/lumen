#!/bin/bash
set -e

ARTIFACTS_DIR="../01-connected-zone/artifacts/gitea"
REGISTRY="localhost:5000"

echo "====================================="
echo "Pushing Gitea image to transit registry"
echo "====================================="

# Load image from tar
echo "Loading Gitea image..."
docker load -i "$ARTIFACTS_DIR/images/gitea.tar"

# Tag and push
while IFS= read -r image; do
    # Remove registry prefix (gitea/gitea → gitea)
    image_name=$(echo "$image" | sed 's|^gitea/||')

    echo "Tagging $image as $REGISTRY/$image_name..."
    docker tag "$image" "$REGISTRY/$image_name"

    echo "Pushing $REGISTRY/$image_name..."
    docker push "$REGISTRY/$image_name"
done < "$ARTIFACTS_DIR/images.txt"

echo ""
echo "✅ Gitea image pushed to transit registry!"
echo ""
echo "Verify with:"
echo "  curl -s http://localhost:5000/v2/_catalog | jq ."
echo "  curl -s http://localhost:5000/v2/gitea/tags/list | jq ."
