#!/bin/bash
set -e

# Phase 15: Loki + Alloy + Metrics Server + Tempo
# Loki 3.6.5 (Feb 6, 2026) + Alloy v1.13.1 (Feb 13, 2026) + Metrics Server v0.8.0 + Tempo 2.10.0 (Jan 26, 2026)

LOKI_VERSION="3.6.5"
LOKI_CHART_VERSION="6.53.0"
NGINX_VERSION="1.29-alpine"
K8S_SIDECAR_VERSION="1.30.9"

ALLOY_VERSION="v1.13.1"
ALLOY_CHART_VERSION="1.6.0"
CONFIG_RELOADER_VERSION="v0.81.0"

METRICS_SERVER_VERSION="v0.8.0"
METRICS_SERVER_CHART_VERSION="3.13.0"

TEMPO_VERSION="2.10.0"
TEMPO_CHART_VERSION="1.24.4"

ARTIFACTS_DIR="artifacts/observability"

echo "============================================="
echo "Phase 15: Pulling Observability Stack artifacts"
echo "  - Loki ${LOKI_VERSION} (log aggregation)"
echo "  - Grafana Alloy ${ALLOY_VERSION} (log collector, replaces Promtail EOL)"
echo "  - Metrics Server ${METRICS_SERVER_VERSION} (HPA support)"
echo "  - Grafana Tempo ${TEMPO_VERSION} (distributed tracing)"
echo "============================================="

mkdir -p "$ARTIFACTS_DIR/images"
mkdir -p "$ARTIFACTS_DIR/helm"

# -------------------------------------------------------
# LOKI
# -------------------------------------------------------
echo ""
echo "[1/4] Pulling Loki ${LOKI_VERSION} images..."

echo "  - grafana/loki:${LOKI_VERSION}..."
docker pull "docker.io/grafana/loki:${LOKI_VERSION}"

echo "  - nginxinc/nginx-unprivileged:${NGINX_VERSION} (Loki gateway)..."
docker pull "docker.io/nginxinc/nginx-unprivileged:${NGINX_VERSION}"

echo "  - kiwigrid/k8s-sidecar:${K8S_SIDECAR_VERSION} (config sidecar)..."
docker pull "docker.io/kiwigrid/k8s-sidecar:${K8S_SIDECAR_VERSION}"

echo "  Downloading Loki Helm chart v${LOKI_CHART_VERSION}..."
if ! helm repo list | grep -q "^grafana"; then
    helm repo add grafana https://grafana.github.io/helm-charts
fi
helm repo update grafana
helm pull grafana/loki --version "${LOKI_CHART_VERSION}" -d "$ARTIFACTS_DIR/helm"

echo "  Saving Loki images..."
docker save "docker.io/grafana/loki:${LOKI_VERSION}" \
    -o "$ARTIFACTS_DIR/images/loki-${LOKI_VERSION}.tar"
docker save "docker.io/nginxinc/nginx-unprivileged:${NGINX_VERSION}" \
    -o "$ARTIFACTS_DIR/images/nginx-unprivileged-${NGINX_VERSION}.tar"
docker save "docker.io/kiwigrid/k8s-sidecar:${K8S_SIDECAR_VERSION}" \
    -o "$ARTIFACTS_DIR/images/k8s-sidecar-${K8S_SIDECAR_VERSION}.tar"

# -------------------------------------------------------
# GRAFANA ALLOY (replaces Promtail - EOL March 2026)
# -------------------------------------------------------
echo ""
echo "[2/4] Pulling Grafana Alloy ${ALLOY_VERSION} images..."

echo "  - grafana/alloy:${ALLOY_VERSION}..."
docker pull "docker.io/grafana/alloy:${ALLOY_VERSION}"

echo "  - prometheus-config-reloader:${CONFIG_RELOADER_VERSION}..."
docker pull "quay.io/prometheus-operator/prometheus-config-reloader:${CONFIG_RELOADER_VERSION}"

echo "  Downloading Alloy Helm chart v${ALLOY_CHART_VERSION}..."
helm pull grafana/alloy --version "${ALLOY_CHART_VERSION}" -d "$ARTIFACTS_DIR/helm"

echo "  Saving Alloy images..."
docker save "docker.io/grafana/alloy:${ALLOY_VERSION}" \
    -o "$ARTIFACTS_DIR/images/alloy-${ALLOY_VERSION}.tar"
docker save "quay.io/prometheus-operator/prometheus-config-reloader:${CONFIG_RELOADER_VERSION}" \
    -o "$ARTIFACTS_DIR/images/prometheus-config-reloader-${CONFIG_RELOADER_VERSION}.tar"

# -------------------------------------------------------
# METRICS SERVER (required for HPA)
# -------------------------------------------------------
echo ""
echo "[3/4] Pulling Metrics Server ${METRICS_SERVER_VERSION}..."

echo "  - metrics-server:${METRICS_SERVER_VERSION}..."
docker pull "registry.k8s.io/metrics-server/metrics-server:${METRICS_SERVER_VERSION}"

echo "  Downloading Metrics Server Helm chart v${METRICS_SERVER_CHART_VERSION}..."
if ! helm repo list | grep -q "^metrics-server"; then
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
fi
helm repo update metrics-server
helm pull metrics-server/metrics-server --version "${METRICS_SERVER_CHART_VERSION}" \
    -d "$ARTIFACTS_DIR/helm"

echo "  Saving Metrics Server image..."
docker save "registry.k8s.io/metrics-server/metrics-server:${METRICS_SERVER_VERSION}" \
    -o "$ARTIFACTS_DIR/images/metrics-server-${METRICS_SERVER_VERSION}.tar"

# -------------------------------------------------------
# GRAFANA TEMPO (distributed tracing)
# -------------------------------------------------------
echo ""
echo "[4/4] Pulling Grafana Tempo ${TEMPO_VERSION}..."

echo "  - grafana/tempo:${TEMPO_VERSION}..."
docker pull "docker.io/grafana/tempo:${TEMPO_VERSION}"

echo "  Downloading Tempo Helm chart v${TEMPO_CHART_VERSION}..."
helm pull grafana/tempo --version "${TEMPO_CHART_VERSION}" -d "$ARTIFACTS_DIR/helm"

echo "  Saving Tempo image..."
docker save "docker.io/grafana/tempo:${TEMPO_VERSION}" \
    -o "$ARTIFACTS_DIR/images/tempo-${TEMPO_VERSION}.tar"

# -------------------------------------------------------
# PUSH TO LOCAL REGISTRY
# -------------------------------------------------------
echo ""
echo "Pushing all images to localhost:5000..."

# Loki
docker tag "docker.io/grafana/loki:${LOKI_VERSION}" \
    "localhost:5000/grafana/loki:${LOKI_VERSION}"
docker push "localhost:5000/grafana/loki:${LOKI_VERSION}"

docker tag "docker.io/nginxinc/nginx-unprivileged:${NGINX_VERSION}" \
    "localhost:5000/nginxinc/nginx-unprivileged:${NGINX_VERSION}"
docker push "localhost:5000/nginxinc/nginx-unprivileged:${NGINX_VERSION}"

docker tag "docker.io/kiwigrid/k8s-sidecar:${K8S_SIDECAR_VERSION}" \
    "localhost:5000/kiwigrid/k8s-sidecar:${K8S_SIDECAR_VERSION}"
docker push "localhost:5000/kiwigrid/k8s-sidecar:${K8S_SIDECAR_VERSION}"

# Alloy
docker tag "docker.io/grafana/alloy:${ALLOY_VERSION}" \
    "localhost:5000/grafana/alloy:${ALLOY_VERSION}"
docker push "localhost:5000/grafana/alloy:${ALLOY_VERSION}"

docker tag "quay.io/prometheus-operator/prometheus-config-reloader:${CONFIG_RELOADER_VERSION}" \
    "localhost:5000/prometheus-operator/prometheus-config-reloader:${CONFIG_RELOADER_VERSION}"
docker push "localhost:5000/prometheus-operator/prometheus-config-reloader:${CONFIG_RELOADER_VERSION}"

# Metrics Server
docker tag "registry.k8s.io/metrics-server/metrics-server:${METRICS_SERVER_VERSION}" \
    "localhost:5000/metrics-server/metrics-server:${METRICS_SERVER_VERSION}"
docker push "localhost:5000/metrics-server/metrics-server:${METRICS_SERVER_VERSION}"

# Tempo
docker tag "docker.io/grafana/tempo:${TEMPO_VERSION}" \
    "localhost:5000/grafana/tempo:${TEMPO_VERSION}"
docker push "localhost:5000/grafana/tempo:${TEMPO_VERSION}"

# -------------------------------------------------------
# SUMMARY
# -------------------------------------------------------
echo ""
echo "✅ Observability stack artifacts ready!"
echo ""
echo "Images in localhost:5000:"
echo "  localhost:5000/grafana/loki:${LOKI_VERSION}"
echo "  localhost:5000/nginxinc/nginx-unprivileged:${NGINX_VERSION}"
echo "  localhost:5000/kiwigrid/k8s-sidecar:${K8S_SIDECAR_VERSION}"
echo "  localhost:5000/grafana/alloy:${ALLOY_VERSION}"
echo "  localhost:5000/prometheus-operator/prometheus-config-reloader:${CONFIG_RELOADER_VERSION}"
echo "  localhost:5000/metrics-server/metrics-server:${METRICS_SERVER_VERSION}"
echo "  localhost:5000/grafana/tempo:${TEMPO_VERSION}"
echo ""
echo "Helm charts in $ARTIFACTS_DIR/helm:"
ls -lh "$ARTIFACTS_DIR/helm/"
echo ""
echo "Next: push to Gitea → ArgoCD will deploy automatically"
