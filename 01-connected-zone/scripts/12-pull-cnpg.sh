#!/bin/bash
set -e

CNPG_VERSION="1.25.1"  # Latest stable (Feb 2026) — no v prefix for ghcr.io tags
PG_VERSION="16.6"
ARTIFACTS_DIR="artifacts/cnpg"

echo "====================================="
echo "Pulling CloudNativePG artifacts"
echo "====================================="

mkdir -p "$ARTIFACTS_DIR/images"

# Download CNPG operator manifest
echo "Downloading CNPG operator ${CNPG_VERSION} manifest..."
curl -sL "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION}.yaml" \
  -o "$ARTIFACTS_DIR/cnpg-operator.yaml"

echo "Downloading CNPG ${CNPG_VERSION} manifest..."

# Pull CNPG operator image
CNPG_IMAGE="ghcr.io/cloudnative-pg/cloudnative-pg:${CNPG_VERSION}"  # no v prefix
PG_IMAGE="ghcr.io/cloudnative-pg/postgresql:${PG_VERSION}"

echo ""
echo "Images to pull:"
echo "  $CNPG_IMAGE"
echo "  $PG_IMAGE"
echo ""

# Pull and save CNPG operator image
echo "Pulling $CNPG_IMAGE..."
docker pull --platform linux/arm64 "$CNPG_IMAGE"
echo "Saving to tar: cloudnative-pg-${CNPG_VERSION}.tar"
docker save "$CNPG_IMAGE" -o "$ARTIFACTS_DIR/images/cloudnative-pg-${CNPG_VERSION}.tar"

# Pull and save PostgreSQL image
echo "Pulling $PG_IMAGE..."
docker pull --platform linux/arm64 "$PG_IMAGE"
echo "Saving to tar: postgresql-${PG_VERSION}.tar"
docker save "$PG_IMAGE" -o "$ARTIFACTS_DIR/images/postgresql-${PG_VERSION}.tar"

# Write images list for push script
cat > "$ARTIFACTS_DIR/images.txt" <<EOF
ghcr.io/cloudnative-pg/cloudnative-pg:${CNPG_VERSION}
ghcr.io/cloudnative-pg/postgresql:${PG_VERSION}
EOF

echo ""
echo "✅ CloudNativePG ${CNPG_VERSION} artifacts downloaded successfully!"
echo ""
echo "Artifacts created:"
echo "Manifest:"
ls -lh "$ARTIFACTS_DIR/cnpg-operator.yaml"
echo ""
echo "Images:"
ls -lh "$ARTIFACTS_DIR/images/"
echo ""
echo "Next: run 02-transit-zone/push-cnpg.sh to push images to airgap registry"
