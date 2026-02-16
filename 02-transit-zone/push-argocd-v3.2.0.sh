#!/bin/bash
set -e

ARTIFACTS_DIR="../01-connected-zone/artifacts/argocd-v3.2.0"
REGISTRY="localhost:5000"

echo "========================================="
echo "Pushing ArgoCD v3.2.0 images to transit registry"
echo "========================================="

# Ensure registry is running
if ! curl -s http://localhost:5000/v2/_catalog > /dev/null; then
    echo "❌ Registry not running at localhost:5000"
    echo "Run ./setup.sh first to start the registry"
    exit 1
fi

echo "✅ Registry is running"
echo ""

# Read image list
if [ ! -f "$ARTIFACTS_DIR/images.txt" ]; then
    echo "❌ Images list not found: $ARTIFACTS_DIR/images.txt"
    exit 1
fi

# Load, tag, and push each image
while IFS= read -r full_image || [ -n "$full_image" ]; do
    if [ -z "$full_image" ]; then
        continue
    fi

    echo "Processing: $full_image"

    # Extract image name and tag
    image_with_tag=$(echo "$full_image" | sed -e 's|^docker\.io/||' -e 's|^quay\.io/||' -e 's|^ghcr\.io/||' -e 's|^registry\.k8s\.io/||' -e 's|^library/||')

    # Find corresponding tar file
    # ArgoCD images use simple naming: argocd-v3.2.0.tar, dex-v2.41.1.tar, redis-7.2.6-alpine.tar
    image_basename=$(basename "$image_with_tag" | cut -d':' -f1)
    tag=$(echo "$image_with_tag" | cut -d':' -f2)
    tar_file="$ARTIFACTS_DIR/images/${image_basename}-${tag}.tar"

    if [ ! -f "$tar_file" ]; then
        echo "  ⚠️  Tar file not found: $tar_file"
        continue
    fi

    echo "  📦 Loading image from tar..."
    docker load -i "$tar_file" > /dev/null

    # Tag for local registry
    target_image="$REGISTRY/$image_with_tag"
    echo "  🏷️  Tagging as: $target_image"
    docker tag "$full_image" "$target_image"

    # Push to registry
    echo "  ⬆️  Pushing to registry..."
    docker push "$target_image" 2>&1 | grep -E "(Pushed|Layer already exists|digest:)" || true

    echo "  ✅ Done: $target_image"
    echo ""
done < "$ARTIFACTS_DIR/images.txt"

echo ""
echo "========================================="
echo "✅ All ArgoCD v3.2.0 images pushed successfully!"
echo "========================================="
echo ""
echo "Verify images in registry:"
echo "  curl -s http://localhost:5000/v2/_catalog | jq ."
echo "  curl -s http://localhost:5000/v2/argoproj/argocd/tags/list | jq ."
echo "  curl -s http://localhost:5000/v2/dexidp/dex/tags/list | jq ."
echo "  curl -s http://localhost:5000/v2/redis/tags/list | jq ."
