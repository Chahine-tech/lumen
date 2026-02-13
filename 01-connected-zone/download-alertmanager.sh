#!/bin/bash

echo "================================================"
echo "  Download AlertManager for Airgap"
echo "================================================"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ALERTMANAGER_VERSION="v0.26.0"
ARTIFACTS_DIR="artifacts/alertmanager"

mkdir -p "$ARTIFACTS_DIR/images"

echo -e "${YELLOW}[1/2]${NC} Pulling AlertManager image..."
docker pull prom/alertmanager:${ALERTMANAGER_VERSION}

echo -e "${YELLOW}[2/2]${NC} Saving AlertManager image..."
docker save prom/alertmanager:${ALERTMANAGER_VERSION} -o "$ARTIFACTS_DIR/images/alertmanager.tar"

# Create image list
echo "prom/alertmanager:${ALERTMANAGER_VERSION}" > "$ARTIFACTS_DIR/images.txt"

echo ""
echo -e "${GREEN}================================================"
echo "  AlertManager Downloaded!"
echo "================================================${NC}"
echo "Image: prom/alertmanager:${ALERTMANAGER_VERSION}"
echo ""
echo "Next:"
echo "  1. Transfer artifacts/ to transit zone"
echo "  2. Run push-alertmanager.sh in transit zone"
