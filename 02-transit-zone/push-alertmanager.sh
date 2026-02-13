#!/bin/bash

echo "================================================"
echo "  Transit Zone - Push AlertManager to Registry"
echo "================================================"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ARTIFACTS_DIR="../01-connected-zone/artifacts/alertmanager"
REGISTRY="localhost:5000"

if [ ! -d "$ARTIFACTS_DIR/images" ]; then
  echo "Error: AlertManager artifacts not found. Run download-alertmanager.sh first."
  exit 1
fi

echo -e "${YELLOW}[1/2]${NC} Loading AlertManager image..."
docker load -i "$ARTIFACTS_DIR/images/alertmanager.tar"

echo -e "${YELLOW}[2/2]${NC} Pushing AlertManager to registry..."
while IFS= read -r image; do
  echo "Processing: $image"

  # Extract image name without registry
  image_name=$(echo "$image" | sed 's|^[^/]*/||')

  # Tag for local registry
  docker tag "$image" "$REGISTRY/$image_name"

  # Push to registry
  docker push "$REGISTRY/$image_name"

  echo "✓ Pushed: $REGISTRY/$image_name"
done < "$ARTIFACTS_DIR/images.txt"

echo ""
echo -e "${GREEN}================================================"
echo "  AlertManager Image in Registry!"
echo "================================================${NC}"
echo ""
echo "Verify with:"
echo "  curl -s http://localhost:5000/v2/_catalog | jq ."
