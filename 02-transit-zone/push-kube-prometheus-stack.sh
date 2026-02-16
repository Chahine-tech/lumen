#!/bin/bash
set -e

ARTIFACTS_DIR="../01-connected-zone/artifacts/kube-prometheus-stack"
REGISTRY="localhost:5000"

echo "====================================="
echo "Pushing kube-prometheus-stack images to transit registry"
echo "====================================="

# Check if registry is running
if ! curl -s http://localhost:5000/v2/ > /dev/null 2>&1; then
    echo "❌ Transit registry not running on localhost:5000"
    echo "Run: cd 02-transit-zone && ./setup.sh"
    exit 1
fi

# Check if artifacts exist
if [ ! -d "$ARTIFACTS_DIR/images" ]; then
    echo "❌ kube-prometheus-stack artifacts not found."
    echo "Run: cd 01-connected-zone && ./scripts/08-pull-kube-prometheus-stack.sh"
    exit 1
fi

# Load images from tar
echo "Loading kube-prometheus-stack images..."
docker load -i "$ARTIFACTS_DIR/images/prometheus-v2.45.0.tar"
docker load -i "$ARTIFACTS_DIR/images/alertmanager-v0.26.0.tar"
docker load -i "$ARTIFACTS_DIR/images/grafana-10.2.2.tar"
docker load -i "$ARTIFACTS_DIR/images/k8s-sidecar-1.25.2.tar"
docker load -i "$ARTIFACTS_DIR/images/prometheus-operator-v0.68.0.tar"
docker load -i "$ARTIFACTS_DIR/images/prometheus-config-reloader-v0.68.0.tar"
docker load -i "$ARTIFACTS_DIR/images/node-exporter-v1.7.0.tar"
docker load -i "$ARTIFACTS_DIR/images/kube-state-metrics-v2.10.1.tar"

# Tag and push
echo "Tagging and pushing images to registry..."
while IFS= read -r image; do
    echo "Processing $image..."

    # Tag for local registry
    # quay.io/prometheus/prometheus:v2.45.0 → localhost:5000/prometheus/prometheus:v2.45.0
    # docker.io/grafana/grafana:10.2.0 → localhost:5000/grafana/grafana:10.2.0
    # registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.10.1 → localhost:5000/kube-state-metrics/kube-state-metrics:v2.10.1

    # Remove docker.io/, quay.io/, registry.k8s.io/ prefixes
    image_name=$(echo "$image" | sed -e 's|^docker\.io/||' -e 's|^quay\.io/||' -e 's|^registry\.k8s\.io/||')
    registry_image="$REGISTRY/$image_name"

    echo "Tagging $image as $registry_image..."
    docker tag "$image" "$registry_image"

    echo "Pushing $registry_image..."
    docker push "$registry_image"
done < "$ARTIFACTS_DIR/images.txt"

echo ""
echo "✅ kube-prometheus-stack images pushed to transit registry!"
echo ""
echo "Verify with:"
echo "  curl -s http://localhost:5000/v2/_catalog | jq ."
echo "  curl -s http://localhost:5000/v2/prometheus/prometheus/tags/list | jq ."
echo "  curl -s http://localhost:5000/v2/grafana/grafana/tags/list | jq ."
echo "  curl -s http://localhost:5000/v2/prometheus-operator/prometheus-operator/tags/list | jq ."
