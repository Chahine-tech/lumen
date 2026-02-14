#!/bin/bash
set -e

GITEA_VERSION="1.21.5"
ARTIFACTS_DIR="artifacts/gitea"

echo "====================================="
echo "Phase 8: Pulling Gitea image"
echo "====================================="

mkdir -p "$ARTIFACTS_DIR/images"

# Pull Gitea image
echo "Pulling gitea/gitea:${GITEA_VERSION}..."
docker pull "gitea/gitea:${GITEA_VERSION}"

# Save to tar
echo "Saving image to tar archive..."
docker save "gitea/gitea:${GITEA_VERSION}" -o "$ARTIFACTS_DIR/images/gitea.tar"

# Create images list
echo "gitea/gitea:${GITEA_VERSION}" > "$ARTIFACTS_DIR/images.txt"

echo ""
echo "✅ Gitea image downloaded successfully!"
echo ""
echo "Artifacts created:"
ls -lh "$ARTIFACTS_DIR/images/"
