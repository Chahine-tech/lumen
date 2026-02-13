#!/bin/bash
set -e

echo "================================================"
echo "  Transit Zone - Push ArgoCD to Registry"
echo "================================================"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ARTIFACTS_DIR="../01-connected-zone/artifacts/argocd"
REGISTRY="localhost:5000"

if [ ! -d "$ARTIFACTS_DIR/images" ]; then
  echo "Error: ArgoCD artifacts not found. Run download-argocd.sh first."
  exit 1
fi

echo -e "${YELLOW}[1/2]${NC} Loading ArgoCD images..."
for tar_file in "$ARTIFACTS_DIR/images"/*.tar; do
  if [ -f "$tar_file" ]; then
    echo "Loading $(basename $tar_file)..."
    docker load -i "$tar_file"
  fi
done
echo -e "${GREEN}✓ Images loaded${NC}"

echo -e "${YELLOW}[2/2]${NC} Tagging and pushing to internal registry..."
while IFS= read -r image; do
  image_name=$(echo "$image" | cut -d'/' -f2-)

  echo "Processing: $image -> $REGISTRY/$image_name"
  docker tag "$image" "$REGISTRY/$image_name"
  docker push "$REGISTRY/$image_name"
done < "$ARTIFACTS_DIR/images.txt"

echo ""
echo -e "${GREEN}================================================"
echo "  ArgoCD Images in Registry!"
echo "================================================${NC}"
echo ""
echo "Verify with:"
echo "  curl -s http://localhost:5000/v2/_catalog | jq ."
