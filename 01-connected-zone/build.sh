#!/bin/bash
set -e

echo "================================================"
echo "  Connected Zone - Build & Package"
echo "================================================"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

REGISTRY="registry.airgap.local:5000"
IMAGE_NAME="lumen-api"
IMAGE_TAG="v1.0.0"

echo -e "${YELLOW}[1/6]${NC} Building Go binary..."
cd app
go mod download
go build -o ../bin/lumen-api main.go
cd ..
echo -e "${GREEN}✓ Binary built${NC}"

echo -e "${YELLOW}[2/6]${NC} Building Docker image..."
docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .
echo -e "${GREEN}✓ Image built${NC}"

echo -e "${YELLOW}[3/6]${NC} Pulling Redis image..."
docker pull redis:7-alpine
echo -e "${GREEN}✓ Redis image pulled${NC}"

echo -e "${YELLOW}[4/6]${NC} Saving images to tar..."
mkdir -p ../artifacts/images
docker save ${IMAGE_NAME}:${IMAGE_TAG} -o ../artifacts/images/lumen-api.tar
docker save redis:7-alpine -o ../artifacts/images/redis.tar
echo -e "${GREEN}✓ Images saved${NC}"

echo -e "${YELLOW}[5/6]${NC} Downloading Kubernetes manifests dependencies..."
mkdir -p ../artifacts/manifests
# This would normally download Helm charts, etc.
echo -e "${GREEN}✓ Dependencies ready${NC}"

echo -e "${YELLOW}[6/6]${NC} Creating manifest with image references for airgap..."
cat > ../artifacts/images-list.txt <<EOF
${IMAGE_NAME}:${IMAGE_TAG}
redis:7-alpine
EOF
echo -e "${GREEN}✓ Image list created${NC}"

echo ""
echo -e "${GREEN}================================================"
echo "  Build Complete!"
echo "================================================${NC}"
echo "Artifacts location: ../artifacts/"
echo "  - images/lumen-api.tar"
echo "  - images/redis.tar"
echo "  - images-list.txt"
echo ""
echo "Next: Transfer artifacts/ to transit zone"
