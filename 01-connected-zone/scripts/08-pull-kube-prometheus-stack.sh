#!/bin/bash
set -e

PROMETHEUS_VERSION="v3.5.1"  # Updated to latest LTS (Feb 2026)
ALERTMANAGER_VERSION="v0.31.1"  # Updated to latest (Feb 2026)
GRAFANA_VERSION="12.4.0-22046043985"  # Updated to latest (Feb 2026)
GRAFANA_SIDECAR_VERSION="1.30.1"  # Updated to latest sidecar version
PROMETHEUS_OPERATOR_VERSION="v0.78.2"  # Updated to latest (supports Prometheus 3.x)
PROMETHEUS_CONFIG_RELOADER_VERSION="v0.78.2"  # Match operator version
NODE_EXPORTER_VERSION="v1.8.2"  # Updated to latest
KUBE_STATE_METRICS_VERSION="v2.14.0"  # Updated to latest

HELM_CHART_VERSION="69.0.0"  # Updated to latest chart version (Feb 2026)
ARTIFACTS_DIR="artifacts/kube-prometheus-stack"

echo "====================================="
echo "Pulling kube-prometheus-stack artifacts"
echo "====================================="

mkdir -p "$ARTIFACTS_DIR/images"
mkdir -p "$ARTIFACTS_DIR/helm"

# Pull individual component images
echo "Pulling kube-prometheus-stack component images..."

echo "  - Pulling prometheus:${PROMETHEUS_VERSION}..."
docker pull "quay.io/prometheus/prometheus:${PROMETHEUS_VERSION}"

echo "  - Pulling alertmanager:${ALERTMANAGER_VERSION}..."
docker pull "quay.io/prometheus/alertmanager:${ALERTMANAGER_VERSION}"

echo "  - Pulling grafana:${GRAFANA_VERSION}..."
docker pull "docker.io/grafana/grafana:${GRAFANA_VERSION}"

echo "  - Pulling grafana sidecar (k8s-sidecar):${GRAFANA_SIDECAR_VERSION}..."
docker pull "quay.io/kiwigrid/k8s-sidecar:${GRAFANA_SIDECAR_VERSION}"

echo "  - Pulling prometheus-operator:${PROMETHEUS_OPERATOR_VERSION}..."
docker pull "quay.io/prometheus-operator/prometheus-operator:${PROMETHEUS_OPERATOR_VERSION}"

echo "  - Pulling prometheus-config-reloader:${PROMETHEUS_CONFIG_RELOADER_VERSION}..."
docker pull "quay.io/prometheus-operator/prometheus-config-reloader:${PROMETHEUS_CONFIG_RELOADER_VERSION}"

echo "  - Pulling node-exporter:${NODE_EXPORTER_VERSION}..."
docker pull "quay.io/prometheus/node-exporter:${NODE_EXPORTER_VERSION}"

echo "  - Pulling kube-state-metrics:${KUBE_STATE_METRICS_VERSION}..."
docker pull "registry.k8s.io/kube-state-metrics/kube-state-metrics:${KUBE_STATE_METRICS_VERSION}"

# Download Helm chart
echo "Downloading kube-prometheus-stack Helm chart v${HELM_CHART_VERSION}..."
if ! helm repo list | grep -q "^prometheus-community"; then
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
fi
helm repo update
helm pull prometheus-community/kube-prometheus-stack --version ${HELM_CHART_VERSION} -d "$ARTIFACTS_DIR/helm"

# Save images to tar archives
echo "Saving images to tar archives..."
docker save "quay.io/prometheus/prometheus:${PROMETHEUS_VERSION}" -o "$ARTIFACTS_DIR/images/prometheus-${PROMETHEUS_VERSION}.tar"
docker save "quay.io/prometheus/alertmanager:${ALERTMANAGER_VERSION}" -o "$ARTIFACTS_DIR/images/alertmanager-${ALERTMANAGER_VERSION}.tar"
docker save "docker.io/grafana/grafana:${GRAFANA_VERSION}" -o "$ARTIFACTS_DIR/images/grafana-${GRAFANA_VERSION}.tar"
docker save "quay.io/kiwigrid/k8s-sidecar:${GRAFANA_SIDECAR_VERSION}" -o "$ARTIFACTS_DIR/images/k8s-sidecar-${GRAFANA_SIDECAR_VERSION}.tar"
docker save "quay.io/prometheus-operator/prometheus-operator:${PROMETHEUS_OPERATOR_VERSION}" -o "$ARTIFACTS_DIR/images/prometheus-operator-${PROMETHEUS_OPERATOR_VERSION}.tar"
docker save "quay.io/prometheus-operator/prometheus-config-reloader:${PROMETHEUS_CONFIG_RELOADER_VERSION}" -o "$ARTIFACTS_DIR/images/prometheus-config-reloader-${PROMETHEUS_CONFIG_RELOADER_VERSION}.tar"
docker save "quay.io/prometheus/node-exporter:${NODE_EXPORTER_VERSION}" -o "$ARTIFACTS_DIR/images/node-exporter-${NODE_EXPORTER_VERSION}.tar"
docker save "registry.k8s.io/kube-state-metrics/kube-state-metrics:${KUBE_STATE_METRICS_VERSION}" -o "$ARTIFACTS_DIR/images/kube-state-metrics-${KUBE_STATE_METRICS_VERSION}.tar"

# Create images list with full registry paths (for transit zone parsing)
cat > "$ARTIFACTS_DIR/images.txt" <<EOF
quay.io/prometheus/prometheus:${PROMETHEUS_VERSION}
quay.io/prometheus/alertmanager:${ALERTMANAGER_VERSION}
docker.io/grafana/grafana:${GRAFANA_VERSION}
quay.io/kiwigrid/k8s-sidecar:${GRAFANA_SIDECAR_VERSION}
quay.io/prometheus-operator/prometheus-operator:${PROMETHEUS_OPERATOR_VERSION}
quay.io/prometheus-operator/prometheus-config-reloader:${PROMETHEUS_CONFIG_RELOADER_VERSION}
quay.io/prometheus/node-exporter:${NODE_EXPORTER_VERSION}
registry.k8s.io/kube-state-metrics/kube-state-metrics:${KUBE_STATE_METRICS_VERSION}
EOF

echo ""
echo "✅ kube-prometheus-stack artifacts downloaded successfully!"
echo ""
echo "Artifacts created:"
echo "Images:"
ls -lh "$ARTIFACTS_DIR/images/"
echo ""
echo "Helm chart:"
ls -lh "$ARTIFACTS_DIR/helm/"
echo ""
echo "Images to push to transit registry:"
cat "$ARTIFACTS_DIR/images.txt"
