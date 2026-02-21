#!/bin/bash
set -e

ARTIFACTS_DIR="../01-connected-zone/artifacts/cnpg"
REGISTRY="localhost:5000"

echo "========================================="
echo "Pushing CloudNativePG images to transit registry"
echo "========================================="

# Ensure registry is running
if ! curl -s http://localhost:5000/v2/_catalog > /dev/null; then
    echo "❌ Registry not running at localhost:5000"
    echo "Run ./setup.sh first to start the registry"
    exit 1
fi

echo "✅ Registry is running"
echo ""

if [ ! -f "$ARTIFACTS_DIR/images.txt" ]; then
    echo "❌ Images list not found: $ARTIFACTS_DIR/images.txt"
    echo "Run 01-connected-zone/scripts/12-pull-cnpg.sh first"
    exit 1
fi

while IFS= read -r full_image || [ -n "$full_image" ]; do
    if [ -z "$full_image" ]; then
        continue
    fi

    echo "Processing: $full_image"

    # Extract image name+tag (strip ghcr.io/cloudnative-pg/ prefix)
    image_with_tag=$(echo "$full_image" | sed 's|ghcr.io/cloudnative-pg/||')
    image_name=$(echo "$image_with_tag" | tr ':' '-')
    tar_file="$ARTIFACTS_DIR/images/${image_name}.tar"

    if [ ! -f "$tar_file" ]; then
        echo "  ⚠️  Tar file not found: $tar_file"
        continue
    fi

    echo "  📦 Loading image from tar..."
    docker load -i "$tar_file" > /dev/null

    # Tag for local registry (keep short name, no ghcr.io prefix)
    target_image="$REGISTRY/$(echo "$full_image" | sed 's|ghcr.io/cloudnative-pg/||')"
    echo "  🏷️  Tagging as: $target_image"
    docker tag "$full_image" "$target_image"

    echo "  ⬆️  Pushing to registry..."
    docker push "$target_image" 2>&1 | grep -E "(Pushed|Layer already exists|digest:)" || true

    echo "  ✅ Done: $target_image"
    echo ""
done < "$ARTIFACTS_DIR/images.txt"

echo ""
echo "========================================="
echo "✅ CloudNativePG images pushed successfully!"
echo "========================================="
echo ""
echo "Verify images in registry:"
echo "  curl -s http://localhost:5000/v2/_catalog | jq ."
echo "  curl -s http://localhost:5000/v2/cloudnative-pg/tags/list | jq ."
echo "  curl -s http://localhost:5000/v2/postgresql/tags/list | jq ."
