#!/bin/bash
set -e

echo "================================================"
echo "  Prepare ArgoCD Manifest for Airgap"
echo "================================================"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ARTIFACTS="../../01-connected-zone/artifacts/argocd/install.yaml"
OUTPUT="../manifests/argocd/02-install-airgap.yaml"
REGISTRY_IP="192.168.2.2:5000"

if [ ! -f "$ARTIFACTS" ]; then
  echo -e "${RED}Error: $ARTIFACTS not found${NC}"
  echo "Run download-argocd.sh in connected zone first"
  exit 1
fi

echo -e "${YELLOW}[1/2]${NC} Replacing image references..."
echo "  quay.io/argoproj/* -> $REGISTRY_IP/argoproj/*"
echo "  ghcr.io/dexidp/*   -> $REGISTRY_IP/dexidp/*"

sed -e "s|quay.io/argoproj/|$REGISTRY_IP/argoproj/|g" \
    -e "s|ghcr.io/dexidp/|$REGISTRY_IP/dexidp/|g" \
    "$ARTIFACTS" > "$OUTPUT"

echo -e "${GREEN}✓ Manifest updated${NC}"

echo -e "${YELLOW}[2/2]${NC} Verifying image references..."
echo "Images in manifest:"
grep 'image:' "$OUTPUT" | awk '{print $2}' | sort -u

echo ""
echo -e "${GREEN}================================================"
echo "  ArgoCD Manifest Ready!"
echo "================================================${NC}"
echo "Location: $OUTPUT"
echo ""
echo "Next: kubectl apply -f manifests/argocd/"
