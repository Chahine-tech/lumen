#!/bin/bash
set -e

ARGOCD_VERSION="v3.2.0"  # Latest stable (Feb 2026)
DEX_VERSION="v2.41.1"     # Latest Dex version compatible with ArgoCD v3.2
REDIS_VERSION="7.2.6-alpine"  # Latest Redis 7.2 LTS

ARTIFACTS_DIR="artifacts/argocd-v3.2.0"

echo "====================================="
echo "Pulling ArgoCD v3.2.0 artifacts"
echo "====================================="

mkdir -p "$ARTIFACTS_DIR/images"

# Pull ArgoCD images
echo "Pulling ArgoCD ${ARGOCD_VERSION} images..."

echo "  - Pulling argocd:${ARGOCD_VERSION}..."
docker pull "quay.io/argoproj/argocd:${ARGOCD_VERSION}"

echo "  - Pulling dex:${DEX_VERSION}..."
docker pull "ghcr.io/dexidp/dex:${DEX_VERSION}"

echo "  - Pulling redis:${REDIS_VERSION}..."
docker pull "docker.io/library/redis:${REDIS_VERSION}"

# Save images to tar archives
echo "Saving images to tar archives..."
docker save "quay.io/argoproj/argocd:${ARGOCD_VERSION}" -o "$ARTIFACTS_DIR/images/argocd-${ARGOCD_VERSION}.tar"
docker save "ghcr.io/dexidp/dex:${DEX_VERSION}" -o "$ARTIFACTS_DIR/images/dex-${DEX_VERSION}.tar"
docker save "docker.io/library/redis:${REDIS_VERSION}" -o "$ARTIFACTS_DIR/images/redis-${REDIS_VERSION}.tar"

# Create images list with full registry paths (for transit zone parsing)
cat > "$ARTIFACTS_DIR/images.txt" <<EOF
quay.io/argoproj/argocd:${ARGOCD_VERSION}
ghcr.io/dexidp/dex:${DEX_VERSION}
docker.io/library/redis:${REDIS_VERSION}
EOF

echo ""
echo "✅ ArgoCD v3.2.0 artifacts downloaded successfully!"
echo ""
echo "Artifacts created:"
echo "Images:"
ls -lh "$ARTIFACTS_DIR/images/"
echo ""
echo "Images to push to transit registry:"
cat "$ARTIFACTS_DIR/images.txt"
