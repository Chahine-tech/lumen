#!/bin/bash
set -e

echo "============================================="
echo "Deploying kube-prometheus-stack"
echo "============================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRGAP_DIR="$(dirname "$SCRIPT_DIR")"
HELM_CHART_DIR="$AIRGAP_DIR/manifests/kube-prometheus-stack-helm"
SERVICEMONITORS_DIR="$AIRGAP_DIR/manifests/kube-prometheus-stack/servicemonitors"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo_success() {
    echo -e "${GREEN}✓${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

echo_error() {
    echo -e "${RED}✗${NC} $1"
}

# Step 1: Check prerequisites
echo ""
echo "Step 1: Checking prerequisites..."
if ! command -v helm &> /dev/null; then
    echo_error "Helm not installed"
    exit 1
fi
echo_success "Helm installed"

if ! kubectl cluster-info &> /dev/null; then
    echo_error "Cannot connect to Kubernetes cluster"
    exit 1
fi
echo_success "Kubernetes cluster accessible"

# Step 2: Check if Helm chart is extracted
echo ""
echo "Step 2: Checking Helm chart..."
if [ ! -f "$HELM_CHART_DIR/Chart.yaml" ]; then
    echo_warning "Helm chart not extracted yet"
    echo "Extracting Helm chart from tarball..."

    TARBALL="$(dirname "$AIRGAP_DIR")/01-connected-zone/artifacts/kube-prometheus-stack/helm/kube-prometheus-stack-55.0.0.tgz"

    if [ ! -f "$TARBALL" ]; then
        echo_error "Helm chart tarball not found at: $TARBALL"
        echo "Run: cd 01-connected-zone && ./scripts/08-pull-kube-prometheus-stack.sh"
        exit 1
    fi

    cd "$HELM_CHART_DIR"
    tar -xzf "$TARBALL"
    mv kube-prometheus-stack/* .
    rmdir kube-prometheus-stack

    echo_success "Helm chart extracted"
else
    echo_success "Helm chart already extracted"
fi

# Step 3: Delete old monitoring stack
echo ""
echo "Step 3: Deleting old monitoring stack..."
read -p "This will delete the existing monitoring namespace resources. Continue? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Delete old ArgoCD application if exists
    if kubectl get application monitoring -n argocd &> /dev/null; then
        echo "Deleting old ArgoCD application..."
        kubectl delete application monitoring -n argocd
        echo_success "Old ArgoCD application deleted"
    fi

    # Delete old monitoring resources
    echo "Deleting old monitoring resources..."
    kubectl delete deployment,service,configmap,secret,serviceaccount -n monitoring -l app=prometheus --ignore-not-found=true
    kubectl delete deployment,service,configmap,secret -n monitoring -l app=grafana --ignore-not-found=true
    kubectl delete deployment,service,configmap,secret -n monitoring -l app=alertmanager --ignore-not-found=true

    # Wait for resources to be deleted
    echo "Waiting for resources to be deleted..."
    sleep 5

    echo_success "Old monitoring stack deleted"
else
    echo_warning "Skipping deletion of old monitoring stack"
fi

# Step 4: Ensure namespace exists and is labeled
echo ""
echo "Step 4: Preparing monitoring namespace..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace monitoring name=monitoring environment=airgap --overwrite
echo_success "Namespace ready"

# Step 5: Deploy Helm chart
echo ""
echo "Step 5: Deploying kube-prometheus-stack via Helm..."
helm install kube-prometheus-stack "$HELM_CHART_DIR" \
  -n monitoring \
  -f "$HELM_CHART_DIR/values.yaml" \
  --wait \
  --timeout 5m

echo_success "Helm chart deployed"

# Step 6: Wait for pods to be ready
echo ""
echo "Step 6: Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-operator -n monitoring --timeout=120s || true
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kube-state-metrics -n monitoring --timeout=120s || true
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=120s || true

echo_success "Pods are ready"

# Step 7: Apply ServiceMonitors
echo ""
echo "Step 7: Applying custom ServiceMonitors..."
kubectl apply -f "$SERVICEMONITORS_DIR/lumen-api.yaml"
kubectl apply -f "$SERVICEMONITORS_DIR/traefik.yaml"
kubectl apply -f "$SERVICEMONITORS_DIR/gitea.yaml"
kubectl apply -f "$SERVICEMONITORS_DIR/argocd.yaml"

echo_success "ServiceMonitors applied"

# Step 8: Apply NetworkPolicies
echo ""
echo "Step 8: Applying NetworkPolicies..."
kubectl apply -f "$AIRGAP_DIR/manifests/network-policies/13-allow-kube-prometheus.yaml"
kubectl apply -f "$AIRGAP_DIR/manifests/network-policies/05-allow-monitoring.yaml"

echo_success "NetworkPolicies applied"

# Step 9: Apply Traefik IngressRoutes
echo ""
echo "Step 9: Applying Traefik IngressRoutes..."
kubectl apply -f "$AIRGAP_DIR/manifests/traefik/15-kube-prometheus-ingressroutes.yaml"

echo_success "IngressRoutes applied"

# Step 10: Verify deployment
echo ""
echo "Step 10: Verifying deployment..."

echo ""
echo "Helm releases:"
helm list -n monitoring

echo ""
echo "Pods in monitoring namespace:"
kubectl get pods -n monitoring

echo ""
echo "ServiceMonitors:"
kubectl get servicemonitor --all-namespaces | grep -E "lumen-api|traefik|gitea|argocd"

echo ""
echo "============================================="
echo_success "Deployment complete!"
echo "============================================="
echo ""
echo "Access services:"
echo "  Prometheus:    https://prometheus.airgap.local"
echo "  Grafana:       https://grafana.airgap.local (admin/admin)"
echo "  AlertManager:  https://alertmanager.airgap.local"
echo ""
echo "Next steps:"
echo "  1. Access Grafana and explore the 40+ pre-configured dashboards"
echo "  2. Access Prometheus UI → Status → Targets to verify all targets are UP"
echo "  3. Create ArgoCD application: kubectl apply -f manifests/argocd/08-application-kube-prometheus.yaml"
echo ""
