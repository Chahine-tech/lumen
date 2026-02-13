#!/bin/bash
set -e

echo "================================================"
echo "  ArgoCD Airgap - Download Artifacts"
echo "================================================"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ARGOCD_VERSION="v2.12.3"
ARTIFACTS_DIR="../artifacts/argocd"

mkdir -p "$ARTIFACTS_DIR"

echo -e "${YELLOW}[1/3]${NC} Downloading ArgoCD installation manifest..."
curl -sL https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml \
  -o "$ARTIFACTS_DIR/install.yaml"
echo -e "${GREEN}✓ Manifest downloaded${NC}"

echo -e "${YELLOW}[2/3]${NC} Extracting image list from manifest..."
grep 'image:' "$ARTIFACTS_DIR/install.yaml" | \
  awk '{print $2}' | \
  sort -u > "$ARTIFACTS_DIR/images.txt"

echo "ArgoCD images to pull:"
cat "$ARTIFACTS_DIR/images.txt"
echo ""

echo -e "${YELLOW}[3/3]${NC} Pulling ArgoCD images..."
while IFS= read -r image; do
  echo "Pulling $image..."
  docker pull "$image"
done < "$ARTIFACTS_DIR/images.txt"
echo -e "${GREEN}✓ All images pulled${NC}"

echo ""
echo -e "${GREEN}Saving images to tar archives...${NC}"
mkdir -p "$ARTIFACTS_DIR/images"

while IFS= read -r image; do
  filename=$(echo "$image" | sed 's/[\/:]/-/g')
  echo "Saving $image -> $filename.tar"
  docker save "$image" -o "$ARTIFACTS_DIR/images/$filename.tar"
done < "$ARTIFACTS_DIR/images.txt"

echo ""
echo -e "${GREEN}================================================"
echo "  ArgoCD Artifacts Ready!"
echo "================================================${NC}"
echo "Location: $ARTIFACTS_DIR/"
echo ""
ls -lh "$ARTIFACTS_DIR/images/"
