#!/bin/bash
set -e

echo "================================================"
echo "  Transit Zone - Registry Setup"
echo "================================================"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}[1/4]${NC} Starting transit zone services..."
docker-compose up -d
echo -e "${GREEN}✓ Services started${NC}"

echo -e "${YELLOW}[2/4]${NC} Waiting for registry to be ready..."
sleep 5
until curl -s http://localhost:5000/v2/ > /dev/null; do
    echo "Waiting for registry..."
    sleep 2
done
echo -e "${GREEN}✓ Registry ready${NC}"

echo -e "${YELLOW}[3/4]${NC} Loading images from artifacts..."
if [ -d "../artifacts/images" ]; then
    for img in ../artifacts/images/*.tar; do
        if [ -f "$img" ]; then
            echo "Loading $(basename $img)..."
            docker load -i "$img"
        fi
    done
    echo -e "${GREEN}✓ Images loaded${NC}"
else
    echo "No artifacts found. Run build.sh in connected zone first."
fi

echo -e "${YELLOW}[4/4]${NC} Tagging and pushing to local registry..."
REGISTRY="localhost:5000"

# Re-tag and push lumen-api
if docker images | grep -q "lumen-api"; then
    docker tag lumen-api:v1.0.0 ${REGISTRY}/lumen-api:v1.0.0
    docker push ${REGISTRY}/lumen-api:v1.0.0
    echo -e "${GREEN}✓ Pushed lumen-api${NC}"
fi

# Re-tag and push redis
if docker images | grep -q "redis.*7-alpine"; then
    docker tag redis:7-alpine ${REGISTRY}/redis:7-alpine
    docker push ${REGISTRY}/redis:7-alpine
    echo -e "${GREEN}✓ Pushed redis${NC}"
fi

echo ""
echo -e "${GREEN}================================================"
echo "  Transit Zone Ready!"
echo "================================================${NC}"
echo "Registry UI:  http://localhost:8081"
echo "File Server:  http://localhost:8082"
echo "Registry API: http://localhost:5000"
echo ""
echo "Images in registry:"
curl -s http://localhost:5000/v2/_catalog | jq .
echo ""
echo "Next: Setup airgap zone and configure registry mirrors"
