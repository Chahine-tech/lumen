#!/bin/bash
set -e

GATEKEEPER_VERSION="v3.18.0"  # Latest stable (Feb 2026)
ARTIFACTS_DIR="artifacts/gatekeeper"

echo "====================================="
echo "Pulling OPA Gatekeeper artifacts"
echo "====================================="

mkdir -p "$ARTIFACTS_DIR/images"

# Download Gatekeeper manifest
echo "Downloading Gatekeeper ${GATEKEEPER_VERSION} manifest..."
curl -sL "https://raw.githubusercontent.com/open-policy-agent/gatekeeper/${GATEKEEPER_VERSION}/deploy/gatekeeper.yaml" \
  -o "$ARTIFACTS_DIR/gatekeeper.yaml"

# Extract image references from manifest
echo "Extracting image references..."
grep "image:" "$ARTIFACTS_DIR/gatekeeper.yaml" | sed 's/.*image: //' | sort -u > "$ARTIFACTS_DIR/images.txt"

echo ""
echo "Images to pull:"
cat "$ARTIFACTS_DIR/images.txt"
echo ""

# Pull Gatekeeper images
while IFS= read -r image || [ -n "$image" ]; do
    if [ -z "$image" ]; then
        continue
    fi

    echo "Pulling $image..."
    docker pull "$image"

    # Extract filename for tar
    image_name=$(echo "$image" | sed 's|.*/||' | tr ':' '-')

    echo "Saving to tar: $image_name.tar"
    docker save "$image" -o "$ARTIFACTS_DIR/images/${image_name}.tar"
done < "$ARTIFACTS_DIR/images.txt"

echo ""
echo "✅ Gatekeeper ${GATEKEEPER_VERSION} artifacts downloaded successfully!"
echo ""
echo "Artifacts created:"
echo "Manifest:"
ls -lh "$ARTIFACTS_DIR/gatekeeper.yaml"
echo ""
echo "Images:"
ls -lh "$ARTIFACTS_DIR/images/"
echo ""
echo "Images to push to transit registry:"
cat "$ARTIFACTS_DIR/images.txt"
