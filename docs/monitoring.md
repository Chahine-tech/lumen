# Monitoring Stack — Complete Observability (Metrics + Logs + Traces)

This document covers Phase 10 (kube-prometheus-stack), Phase 11/12 (upgrades), and Phase 15 (Loki + Alloy + Tempo + OpenTelemetry).

---

## 📋 Table of Contents

- [Overview](#overview)
- [Phase 10: kube-prometheus-stack Deployment](#phase-10-kube-prometheus-stack-deployment)
- [Phase 11/12: Upgrade to Latest Versions](#phase-1112-upgrade-to-latest-versions)
- [Phase 15: Logs — Loki + Alloy](#phase-15-logs--pprof-february-17-2026)
- [Phase 15 (suite): Traces — Tempo + OpenTelemetry](#phase-15-suite-traces--grafana-tempo--opentelemetry-february-18-2026)
- [Architecture](#architecture)
- [Components](#components)
- [Deployment Workflow](#deployment-workflow)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)

---

## Overview

The Lumen project uses **kube-prometheus-stack** Helm chart for production-grade observability in the airgap environment. This replaces the previous manual Prometheus/Grafana deployment with a complete, operator-managed monitoring solution.

### Why kube-prometheus-stack?

- **Industry standard**: Used by most production Kubernetes deployments
- **Batteries included**: 40+ pre-configured Grafana dashboards
- **Operator pattern**: ServiceMonitor/PrometheusRule CRDs vs manual ConfigMaps
- **Complete metrics**: Node Exporter + kube-state-metrics included
- **Production-ready alerts**: 100+ alert rules out of the box
- **Helm management**: Easy upgrades and rollbacks

---

## Phase 10: kube-prometheus-stack Deployment

### Initial Deployment (February 2024)

**Component Versions:**
- Helm Chart: v55.0.0
- Prometheus: v2.48.0
- Grafana: 10.2.2
- AlertManager: v0.26.0
- Prometheus Operator: v0.68.0
- Node Exporter: v1.7.0
- kube-state-metrics: v2.10.1

### Step 1: Download Images and Helm Chart (Connected Zone)

Script: `01-connected-zone/scripts/08-pull-kube-prometheus-stack.sh`

```bash
#!/bin/bash
set -e

PROMETHEUS_VERSION="v2.48.0"
ALERTMANAGER_VERSION="v0.26.0"
GRAFANA_VERSION="10.2.2"
PROMETHEUS_OPERATOR_VERSION="v0.68.0"
NODE_EXPORTER_VERSION="v1.7.0"
KUBE_STATE_METRICS_VERSION="v2.10.1"
HELM_CHART_VERSION="55.0.0"

# Download Helm chart
helm pull prometheus-community/kube-prometheus-stack --version ${HELM_CHART_VERSION}

# Pull all component images
docker pull quay.io/prometheus/prometheus:${PROMETHEUS_VERSION}
docker pull quay.io/prometheus/alertmanager:${ALERTMANAGER_VERSION}
docker pull docker.io/grafana/grafana:${GRAFANA_VERSION}
# ... (see script for full list)

# Save images to tar archives
docker save quay.io/prometheus/prometheus:${PROMETHEUS_VERSION} -o artifacts/prometheus.tar
# ... (see script for full list)
```

**Output:**
- `artifacts/kube-prometheus-stack/images/` - 8 tar files (one per component)
- `artifacts/kube-prometheus-stack/helm/` - Helm chart tarball
- `artifacts/kube-prometheus-stack/images.txt` - List of images with registry paths

### Step 2: Push to Transit Registry

Script: `02-transit-zone/push-kube-prometheus-stack.sh`

Pushes all images to `localhost:5000` registry for airgap deployment.

### Step 3: Configure Helm Chart for Airgap

File: `03-airgap-zone/manifests/kube-prometheus-stack-helm/values-airgap-override.yaml`

**Key configurations:**

```yaml
# Global settings
global:
  imageRegistry: localhost:5000

# Prometheus
prometheus:
  prometheusSpec:
    image:
      registry: localhost:5000
      repository: prometheus/prometheus
      tag: v2.48.0

    # Match ALL ServiceMonitors
    serviceMonitorSelector: {}
    podMonitorSelector: {}

    retention: 15d
    resources:
      requests: {cpu: 200m, memory: 512Mi}
      limits: {cpu: 1000m, memory: 2Gi}

# Grafana
grafana:
  image:
    registry: localhost:5000
    repository: grafana/grafana
    tag: "10.2.2"

  adminPassword: admin

  # Sidecar for auto-reload of dashboards
  sidecar:
    dashboards:
      enabled: true
    datasources:
      enabled: true

# Node Exporter (hardware metrics)
nodeExporter:
  enabled: true
  image:
    registry: localhost:5000

# kube-state-metrics (K8s object metrics)
kubeStateMetrics:
  enabled: true
  image:
    registry: localhost:5000
```

### Step 4: Deploy via Helm

```bash
cd 03-airgap-zone

# Deploy Helm chart
helm install kube-prometheus-stack ./manifests/kube-prometheus-stack-helm \
  -n monitoring \
  --create-namespace \
  -f manifests/kube-prometheus-stack-helm/values-airgap-override.yaml \
  --wait
```

### Step 5: Custom ServiceMonitors

Created custom ServiceMonitors for:

1. **Lumen API** (`manifests/kube-prometheus-stack/servicemonitors/lumen-api.yaml`)
2. **Traefik** (`manifests/kube-prometheus-stack/servicemonitors/traefik.yaml`)
3. **Gitea** (`manifests/kube-prometheus-stack/servicemonitors/gitea.yaml`)
4. **ArgoCD** (`manifests/kube-prometheus-stack/servicemonitors/argocd.yaml`)

**Example (Lumen API):**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: lumen-api
  namespace: lumen
  labels:
    release: kube-prometheus-stack  # Critical for discovery
spec:
  selector:
    matchLabels:
      app: lumen-api
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

### Step 6: Custom Grafana Dashboard

File: `manifests/kube-prometheus-stack/dashboards/lumen-api-dashboard.yaml`

**Dashboard as ConfigMap with auto-discovery:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-lumen-api
  namespace: monitoring
  labels:
    grafana_dashboard: "1"  # Critical: tells Grafana to auto-load
data:
  lumen-api-dashboard.json: |
    {
      "title": "Lumen API - Airgap Monitoring",
      "panels": [
        {
          "title": "HTTP Requests Total",
          "targets": [{
            "expr": "http_requests_total{job=\"lumen-api\"}",
            "legendFormat": "{{exported_endpoint}} - {{method}} - {{status}}"
          }]
        },
        ...
      ]
    }
```

**Key metrics tracked:**
- HTTP Requests Total
- Request Rate (per second)
- Total /hello Requests (gauge)
- Go Runtime Metrics (goroutines, threads)

### Step 7: ArgoCD Integration

File: `03-airgap-zone/manifests/argocd/08-application-kube-prometheus.yaml`

**ArgoCD Application for Helm Chart:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
spec:
  project: default

  source:
    repoURL: http://gitea.gitea.svc.cluster.local:3000/lumen/lumen.git
    targetRevision: HEAD
    path: 03-airgap-zone/manifests/kube-prometheus-stack-helm

    helm:
      releaseName: kube-prometheus-stack
      valueFiles:
        - values-airgap-override.yaml

  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
```

---

## Phase 11/12: Upgrade to Latest Versions

### Upgrade Overview (February 2026)

**Motivation:** Upgrade all components to latest stable versions for security patches, performance improvements, and new features.

### Version Comparison

| Component | Old Version | New Version | Status |
|-----------|-------------|-------------|--------|
| **Helm Chart** | v55.0.0 | v69.0.0 | ⬆️ Major upgrade |
| **Prometheus** | v2.48.0 | v3.5.1 | ⬆️ Major version (2→3) |
| **Grafana** | 10.2.2 | 12.4.0 | ⬆️ 2 major versions |
| **AlertManager** | v0.26.0 | v0.31.1 | ⬆️ 5 versions |
| **Prometheus Operator** | v0.68.0 | v0.78.2 | ⬆️ 10 versions |
| **Node Exporter** | v1.7.0 | v1.8.2 | ⬆️ Minor |
| **kube-state-metrics** | v2.10.1 | v2.14.0 | ⬆️ Patch |
| **Grafana Sidecar** | 1.25.2 | 1.30.1 | ⬆️ Minor |

**Full comparison:** See `docs/VERSION-COMPARISON.md`

### Step 1: Update Download Script

Updated `01-connected-zone/scripts/08-pull-kube-prometheus-stack.sh`:

```bash
PROMETHEUS_VERSION="v3.5.1"          # Was: v2.48.0
GRAFANA_VERSION="12.4.0-22046043985" # Was: 10.2.2 (includes build number)
ALERTMANAGER_VERSION="v0.31.1"       # Was: v0.26.0
PROMETHEUS_OPERATOR_VERSION="v0.78.2" # Was: v0.68.0
HELM_CHART_VERSION="69.0.0"          # Was: 55.0.0
```

### Step 2: Download and Push New Images

```bash
# Connected Zone
cd 01-connected-zone
./scripts/08-pull-kube-prometheus-stack.sh

# Transit Zone
cd ../02-transit-zone
./push-kube-prometheus-stack.sh
```

### Step 3: Update Helm Values

Updated `values-airgap-override.yaml` with new image tags.

### Step 4: Apply CRD Updates

**Critical:** Prometheus 3.x requires updated CRDs before Helm upgrade.

```bash
# Apply CRDs with server-side flag
kubectl apply --server-side \
  -f 03-airgap-zone/manifests/kube-prometheus-stack-helm/charts/crds/crds/ \
  --force-conflicts
```

### Step 5: Upgrade Helm Release

```bash
helm upgrade kube-prometheus-stack ./manifests/kube-prometheus-stack-helm \
  -n monitoring \
  -f manifests/kube-prometheus-stack-helm/values-airgap-override.yaml \
  --wait
```

### Step 6: Verify Upgrade

```bash
# Check pod images
kubectl get pods -n monitoring -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Expected output:
# prometheus-xxx    localhost:5000/prometheus/prometheus:v3.5.1
# grafana-xxx       localhost:5000/grafana/grafana:12.4.0-22046043985
# alertmanager-xxx  localhost:5000/prometheus/alertmanager:v0.31.1
```

### Breaking Changes - Prometheus 2 → 3

**Key changes:**
- TSDB format changes (automatic migration on first startup)
- Some deprecated flags removed
- PromQL behavior improvements

**Documentation:** [Prometheus 3.0 Announcement](https://prometheus.io/blog/2024/11/14/prometheus-3-0/)

### Breaking Changes - Grafana 10 → 12

**Key changes:**
- Dashboard JSON schema updates (auto-migrated)
- Enhanced dashboards UI
- Improved query performance
- Better RBAC

**Documentation:** [Grafana v12.0 Release Notes](https://grafana.com/docs/grafana/latest/whatsnew/whats-new-in-v12-0/)

---

## Phase 12: ArgoCD v3.2.0 Upgrade

### Version Upgrade

| Component | Old Version | New Version |
|-----------|-------------|-------------|
| **ArgoCD** | v2.12.3 | v3.2.0 |
| **Dex** | v2.38.0 | v2.41.1 |
| **Redis** | 7.0.15-alpine | 7.2.6-alpine |

### Step 1: Download ArgoCD v3.2.0

Script: `01-connected-zone/scripts/09-pull-argocd.sh`

```bash
ARGOCD_VERSION="v3.2.0"
DEX_VERSION="v2.41.1"
REDIS_VERSION="7.2.6-alpine"

docker pull quay.io/argoproj/argocd:${ARGOCD_VERSION}
docker pull ghcr.io/dexidp/dex:${DEX_VERSION}
docker pull docker.io/library/redis:${REDIS_VERSION}
```

### Step 2: Push to Transit Registry

Script: `02-transit-zone/push-argocd.sh`

### Step 3: Download Official Manifest

```bash
curl -sL https://raw.githubusercontent.com/argoproj/argo-cd/v3.2.0/manifests/install.yaml \
  -o /tmp/argocd-v3.2.0.yaml
```

### Step 4: Customize for Airgap

```bash
sed -e 's|quay.io/argoproj/argocd:v3.2.0|localhost:5000/argoproj/argocd:v3.2.0|g' \
    -e 's|ghcr.io/dexidp/dex:v2.41.1|localhost:5000/dexidp/dex:v2.41.1|g' \
    -e 's|redis:7.2.6-alpine|localhost:5000/redis:7.2.6-alpine|g' \
    /tmp/argocd-v3.2.0.yaml > 03-airgap-zone/manifests/argocd/02-install-airgap.yaml
```

### Step 5: Apply Upgrade

```bash
# Apply to argocd namespace (important: use -n flag)
kubectl apply -n argocd -f 03-airgap-zone/manifests/argocd/02-install-airgap.yaml
```

### Step 6: Configure Insecure Mode

**Critical:** ArgoCD v3.2.0 requires explicit insecure mode when behind TLS termination (Traefik).

```bash
kubectl patch configmap argocd-cmd-params-cm -n argocd \
  --type merge \
  -p '{"data":{"server.insecure":"true"}}'

kubectl rollout restart deployment argocd-server -n argocd
```

**Why needed:** ArgoCD v3+ enforces TLS by default. When Traefik handles TLS termination, ArgoCD must run in insecure mode to avoid redirect loops.

### Step 7: Restore ArgoCD Applications

```bash
kubectl apply -f 03-airgap-zone/manifests/argocd/04-application-lumen.yaml
kubectl apply -f 03-airgap-zone/manifests/argocd/06-application-network-policies.yaml
kubectl apply -f 03-airgap-zone/manifests/argocd/07-application-traefik.yaml
kubectl apply -f 03-airgap-zone/manifests/argocd/08-application-kube-prometheus.yaml
```

### ArgoCD v3.0 Breaking Changes

**Major changes:**
- TLS enforcement by default
- New UI improvements
- Enhanced RBAC features
- Better performance for large repos

**End of Life:** ArgoCD v3.0 reached EOL on February 2, 2026.

---

## Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────┐
│                  kube-prometheus-stack                   │
│                      (Helm Chart)                        │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │  Prometheus  │  │   Grafana    │  │ AlertManager │  │
│  │   Operator   │  │              │  │              │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│         │                  │                  │         │
│         │                  │                  │         │
│  ┌──────▼──────────────────▼──────────────────▼──────┐  │
│  │           Prometheus Server (v3.5.1)             │  │
│  │  - Scrapes metrics from ServiceMonitors          │  │
│  │  - Stores TSDB (15 days retention)               │  │
│  │  - Evaluates PrometheusRules                     │  │
│  └──────────────────────────────────────────────────┘  │
│         │                                                │
│         │                                                │
│  ┌──────▼──────────────────────────────────────────┐   │
│  │        Metrics Sources (ServiceMonitors)        │   │
│  ├──────────────────────────────────────────────────┤   │
│  │ • Node Exporter (hardware metrics)              │   │
│  │ • kube-state-metrics (K8s object metrics)       │   │
│  │ • Lumen API (/metrics endpoint)                 │   │
│  │ • Traefik (proxy metrics)                       │   │
│  │ • Gitea (Git server metrics)                    │   │
│  │ • ArgoCD (GitOps metrics)                       │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### Key Differences vs Manual Deployment

| Feature | Manual Deployment | kube-prometheus-stack |
|---------|-------------------|----------------------|
| **Deployment** | Static YAML manifests | Helm chart |
| **Configuration** | ConfigMap scrape_configs | ServiceMonitor CRDs |
| **Dashboards** | 1 custom | 40+ pre-configured |
| **Node Metrics** | ❌ None | ✅ Node Exporter |
| **K8s Metrics** | ❌ None | ✅ kube-state-metrics |
| **Alert Rules** | 3 basic | 100+ production-ready |
| **HA** | Single replica | Multi-replica ready |
| **Operator** | ❌ None | ✅ Prometheus Operator |
| **Upgrades** | Manual kubectl apply | `helm upgrade` |

---

## Components

### 1. Prometheus Operator

**Purpose:** Manages Prometheus instances via CRDs.

**CRDs:**
- `Prometheus` - Defines Prometheus server instances
- `ServiceMonitor` - Defines targets to scrape
- `PrometheusRule` - Defines alert/recording rules
- `Alertmanager` - Defines AlertManager instances

**Benefits:**
- Declarative configuration via CRDs
- Automatic config reload
- Namespace isolation
- Dynamic discovery

### 2. Prometheus Server (v3.5.1)

**Features:**
- Long-Term Support (LTS) release
- Improved cardinality management
- Better performance
- TSDB v3 format

**Configuration:**
- Retention: 15 days
- Storage: emptyDir (ephemeral)
- Resources: 512Mi RAM request, 2Gi limit

### 3. Grafana (v12.4.0)

**Features:**
- 40+ pre-configured dashboards
- Auto-discovery of dashboards via sidecar
- Enhanced UI
- Better RBAC

**Access:**
- URL: https://grafana.airgap.local
- Username: `admin`
- Password: `admin`

**Dashboards:**
- Kubernetes / Compute Resources / Cluster
- Kubernetes / Compute Resources / Namespace
- Node Exporter / Nodes
- Prometheus / Overview
- **Custom:** Lumen API Dashboard

### 4. Node Exporter (v1.8.2)

**Purpose:** Hardware and OS-level metrics.

**Metrics:**
- CPU usage per core
- Memory usage
- Disk I/O
- Network traffic
- Filesystem usage

**Deployment:** DaemonSet (one pod per node)

### 5. kube-state-metrics (v2.14.0)

**Purpose:** Kubernetes object state metrics.

**Metrics:**
- Pod count/status
- Deployment status
- Node status
- PersistentVolumeClaim usage
- ConfigMap/Secret count

### 6. AlertManager (v0.31.1)

**Purpose:** Alert routing and notification.

**Configuration:**
- No external receivers (airgap)
- Internal routing only
- De-duplication
- Grouping

**Access:** https://alertmanager.airgap.local

---

## Deployment Workflow

### End-to-End Deployment

```bash
# 1. Connected Zone - Download all artifacts
cd 01-connected-zone
./scripts/08-pull-kube-prometheus-stack.sh
./scripts/09-pull-argocd.sh

# 2. Transit Zone - Push to registry
cd ../02-transit-zone
./setup.sh  # Ensure registry running
./push-kube-prometheus-stack.sh
./push-argocd.sh

# 3. Airgap Zone - Deploy monitoring
cd ../03-airgap-zone

# Deploy kube-prometheus-stack
helm install kube-prometheus-stack ./manifests/kube-prometheus-stack-helm \
  -n monitoring \
  --create-namespace \
  -f manifests/kube-prometheus-stack-helm/values-airgap-override.yaml

# Deploy custom ServiceMonitors
kubectl apply -f manifests/kube-prometheus-stack/servicemonitors/

# Deploy custom Grafana dashboards
kubectl apply -f manifests/kube-prometheus-stack/dashboards/

# Deploy ArgoCD
kubectl apply -n argocd -f manifests/argocd/02-install-airgap.yaml
kubectl patch configmap argocd-cmd-params-cm -n argocd \
  --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd

# Deploy ArgoCD Applications
kubectl apply -f manifests/argocd/04-application-lumen.yaml
kubectl apply -f manifests/argocd/06-application-network-policies.yaml
kubectl apply -f manifests/argocd/07-application-traefik.yaml
kubectl apply -f manifests/argocd/08-application-kube-prometheus.yaml
```

---

## Verification

### 1. Check Helm Release

```bash
helm list -n monitoring

# Expected output:
# NAME                    NAMESPACE   REVISION   STATUS     CHART                          APP VERSION
# kube-prometheus-stack   monitoring  1          deployed   kube-prometheus-stack-69.0.0   v0.78.2
```

### 2. Check All Pods Running

```bash
kubectl get pods -n monitoring

# Expected pods (all Running):
# - alertmanager-xxx (2/2)
# - grafana-xxx (3/3)
# - prometheus-operator-xxx (1/1)
# - prometheus-kube-prometheus-stack-prometheus-0 (2/2)
# - kube-state-metrics-xxx (1/1)
# - node-exporter-xxx (1/1 per node)
```

### 3. Verify ServiceMonitor Discovery

```bash
# Access Prometheus UI
open https://prometheus.airgap.local

# Navigate to: Status → Service Discovery
# Should see ServiceMonitors for:
# - lumen-api (namespace: lumen)
# - traefik (namespace: traefik)
# - gitea (namespace: gitea)
# - argocd (namespace: argocd)
# - node-exporter (namespace: monitoring)
# - kube-state-metrics (namespace: monitoring)
```

### 4. Check Prometheus Targets

```bash
# Navigate to: Status → Targets
# All targets should be "UP" (green)
```

### 5. Verify Grafana Dashboards

```bash
open https://grafana.airgap.local
# Login: admin/admin

# Check dashboards available:
# - Kubernetes / Compute Resources / Cluster
# - Lumen API - Airgap Monitoring (custom)
# - Node Exporter / Nodes
# - ... 40+ total
```

### 6. Test Metrics Collection

```bash
# Generate traffic to Lumen API
for i in {1..100}; do
  curl -k https://lumen-api.airgap.local/hello
  sleep 0.1
done

# Check in Grafana → Lumen API Dashboard
# - HTTP Requests Total should increment
# - Request Rate should show spike
# - Total /hello Requests should increase
```

### 7. Verify ArgoCD Applications

```bash
kubectl get applications -n argocd

# Expected:
# NAME                     SYNC STATUS   HEALTH STATUS
# kube-prometheus-stack    Synced        Healthy
# lumen-app               Synced        Healthy
# lumen-network-policies  Synced        Healthy
# traefik                 Synced        Healthy
```

---

## Troubleshooting

### Issue: Pods in ImagePullBackOff

**Symptom:**
```bash
kubectl get pods -n monitoring
# prometheus-xxx   0/2   ImagePullBackOff
```

**Diagnosis:**
```bash
kubectl describe pod <pod-name> -n monitoring | grep "Failed to pull image"
# Error: Failed to pull image "quay.io/prometheus/prometheus:v3.5.1"
```

**Solution:**
Values file not properly overriding image registry.

```yaml
# Fix values-airgap-override.yaml
prometheus:
  prometheusSpec:
    image:
      registry: localhost:5000  # ADD THIS
      repository: prometheus/prometheus
      tag: v3.5.1
```

Re-deploy:
```bash
helm upgrade kube-prometheus-stack ./manifests/kube-prometheus-stack-helm \
  -n monitoring \
  -f manifests/kube-prometheus-stack-helm/values-airgap-override.yaml
```

---

### Issue: ServiceMonitor Not Discovered

**Symptom:**
Prometheus UI → Service Discovery shows 0 ServiceMonitors.

**Diagnosis:**
```bash
kubectl get servicemonitor -n lumen -o yaml
# Check if label "release: kube-prometheus-stack" exists
```

**Solution:**
Add label to ServiceMonitor:

```yaml
metadata:
  labels:
    release: kube-prometheus-stack  # CRITICAL
```

Also check Prometheus selector:
```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelector: {}  # Empty = match ALL
```

---

### Issue: Grafana Shows "No Data"

**Symptom:**
Dashboard panels show "No data" despite metrics existing.

**Diagnosis:**
```bash
# Check Grafana can reach Prometheus
kubectl exec -n monitoring -it deploy/kube-prometheus-stack-grafana -- \
  wget -qO- http://kube-prometheus-stack-prometheus:9090/api/v1/query?query=up
```

**Solution:**
Check NetworkPolicy allows Grafana → Prometheus:

```yaml
# In monitoring namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-grafana-to-prometheus
  namespace: monitoring
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: prometheus
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: grafana
      ports:
        - protocol: TCP
          port: 9090
```

---

### Issue: ArgoCD Redirect Loop (ERR_TOO_MANY_REDIRECTS)

**Symptom:**
Browser shows "ERR_TOO_MANY_REDIRECTS" when accessing https://argocd.airgap.local

**Root Cause:**
ArgoCD v3+ enforces TLS by default. When Traefik terminates TLS, ArgoCD tries to redirect to HTTPS, causing a loop.

**Solution:**
Enable insecure mode:

```bash
kubectl patch configmap argocd-cmd-params-cm -n argocd \
  --type merge \
  -p '{"data":{"server.insecure":"true"}}'

kubectl rollout restart deployment argocd-server -n argocd
```

---

### Issue: CRD Schema Mismatch During Upgrade

**Symptom:**
```
Error: failed to create typed patch object: field not declared in schema
```

**Root Cause:**
Helm chart v69 requires updated CRDs for Prometheus 3.x.

**Solution:**
Apply CRDs before Helm upgrade:

```bash
kubectl apply --server-side \
  -f manifests/kube-prometheus-stack-helm/charts/crds/crds/ \
  --force-conflicts

# Then run helm upgrade
helm upgrade kube-prometheus-stack ./manifests/kube-prometheus-stack-helm \
  -n monitoring \
  -f manifests/kube-prometheus-stack-helm/values-airgap-override.yaml
```

---

## Access URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| **Prometheus** | https://prometheus.airgap.local | None |
| **Grafana** | https://grafana.airgap.local | admin/admin |
| **AlertManager** | https://alertmanager.airgap.local | None |
| **ArgoCD** | https://argocd.airgap.local | admin/[see secret] |

Get ArgoCD password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

---

## Files Summary

### Connected Zone
- `scripts/08-pull-kube-prometheus-stack.sh` - Download monitoring images + Helm chart
- `scripts/09-pull-argocd.sh` - Download ArgoCD v3.2.0 images

### Transit Zone
- `push-kube-prometheus-stack.sh` - Push monitoring images to registry
- `push-argocd.sh` - Push ArgoCD images to registry

### Airgap Zone - Helm Chart
- `manifests/kube-prometheus-stack-helm/values-airgap-override.yaml` - Airgap configuration

### Airgap Zone - Custom Resources
- `manifests/kube-prometheus-stack/servicemonitors/` - Custom ServiceMonitors (4 files)
- `manifests/kube-prometheus-stack/dashboards/` - Custom Grafana dashboards (1 file)

### Airgap Zone - ArgoCD
- `manifests/argocd/02-install-airgap.yaml` - ArgoCD v3.2.0 installation
- `manifests/argocd/08-application-kube-prometheus.yaml` - ArgoCD Application for Helm chart

---

## Learning Outcomes

### 1. Helm Package Management in Airgap
✅ Downloading Helm charts in connected zone
✅ Extracting and customizing charts
✅ Overriding image registries for airgap deployment
✅ Helm release management (install, upgrade, rollback)

### 2. Prometheus Operator Pattern
✅ **Declarative monitoring**: ServiceMonitor/PrometheusRule CRDs vs manual ConfigMaps
✅ **Dynamic discovery**: Add ServiceMonitor → auto-scraped by Prometheus
✅ **Operator reconciliation loop**: Operator watches CRDs, updates Prometheus config
✅ **Production pattern**: Separation of concerns (Operator manages Prometheus instances)

### 3. Complete Observability Stack
✅ **Node Exporter**: Hardware metrics (CPU, RAM, disk, network per node)
✅ **kube-state-metrics**: K8s object metrics (pod count, deployment status, PVC usage)
✅ **Pre-built dashboards**: 40+ Grafana dashboards for K8s monitoring
✅ **Production alerts**: 100+ alert rules (pod crash loops, high memory, etc.)

### 4. Major Version Upgrades
✅ **Prometheus 2.x → 3.x**: Breaking changes, TSDB migration, new features
✅ **Grafana 10 → 12**: Dashboard schema updates, UI improvements
✅ **ArgoCD 2.x → 3.x**: TLS enforcement, insecure mode configuration
✅ **CRD management**: Server-side apply, force-conflicts resolution

### 5. GitOps with Helm
✅ ArgoCD managing Helm charts from Git repository
✅ Auto-sync and self-heal capabilities
✅ Declarative application management
✅ Version control for infrastructure

---

## Phase 15: Logs + pprof (February 17, 2026)

### What Changed

Completed the **Logs** pillar of observability and added Go profiling to lumen-api.

### Loki 3.6.5 — Log Aggregation

**Why not loki-stack?** The `grafana/loki-stack` chart is officially deprecated (no more updates). The standalone `grafana/loki` chart v6.53.0 is the replacement.

**Why not S3/MinIO?** Single-node airgap setup — filesystem storage is simpler, sufficient, and avoids the deprecated MinIO subchart.

**Deployment mode: SingleBinary** — all Loki components (ingester, querier, compactor, etc.) run in one pod. Correct for single-node K3s.

**Key config:**
```yaml
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb          # TSDB replaces deprecated boltdb-shipper
        object_store: filesystem
        schema: v13          # Current schema version
```

**Images used:**
| Image | Tag | Role |
|-------|-----|------|
| `localhost:5000/grafana/loki` | `3.6.5` | Log storage + query engine |
| `localhost:5000/nginxinc/nginx-unprivileged` | `1.29-alpine` | Loki gateway |
| `localhost:5000/kiwigrid/k8s-sidecar` | `1.30.9` | Config sidecar |

### Grafana Alloy v1.13.1 — Log Collector

**Why not Promtail?** Promtail is **EOL March 2026** — no more updates or security patches. Grafana Alloy is the official replacement.

Alloy runs as a **DaemonSet** (one pod per node) and:
1. Discovers all pods via Kubernetes API
2. Tails pod logs from node filesystem
3. Parses JSON logs from lumen-api (via `stage.json`)
4. Extracts `level` label for filtering in Grafana
5. Ships to Loki gateway

**Images used:**
| Image | Tag | Role |
|-------|-----|------|
| `localhost:5000/grafana/alloy` | `v1.13.1` | Log collector DaemonSet |
| `localhost:5000/prometheus-operator/prometheus-config-reloader` | `v0.81.0` | Config reloader sidecar |

### lumen-api v1.1.0 — pprof + Structured Logging

**pprof endpoints** added to `app.go`:
```
/debug/pprof/          — index
/debug/pprof/profile   — CPU profiling (30s)
/debug/pprof/trace     — goroutine trace
/debug/pprof/symbol    — symbol lookup
/debug/pprof/cmdline   — command line args
```

**Structured JSON logging** via `log/slog` (stdlib, no external deps):
```json
{"time":"2026-02-17T10:00:00Z","level":"INFO","msg":"request","method":"GET","path":"/hello","status":200,"duration_ms":1,"remote_addr":"10.0.0.1:12345"}
```
Alloy parses these JSON fields and indexes `level` as a Loki label — enables filtering by `{level="ERROR"}` in Grafana Explore.

### Loki Datasource in Grafana

Added to `kube-prometheus-stack` values (`additionalDataSources`):
```yaml
additionalDataSources:
  - name: Loki
    type: loki
    uid: loki
    url: http://loki-gateway.monitoring.svc.cluster.local
    access: proxy
    jsonData:
      maxLines: 1000
```

### Querying Logs in Grafana

**Grafana → Explore → Loki**

```logql
# All lumen namespace logs
{namespace="lumen"}

# Only lumen-api errors
{namespace="lumen", app="lumen-api", level="ERROR"}

# Search for specific text
{namespace="lumen"} |= "Redis"

# Parse JSON and filter by HTTP status
{namespace="lumen", app="lumen-api"} | json | status >= 500
```

### 3 Pillars Status (after Phase 15 part 1)

| Pillar | Status | Stack |
|--------|--------|-------|
| **Metrics** | ✅ Complete | Prometheus 3.5.1 + Grafana 12.4.0 |
| **Logs** | ✅ Complete | Loki 3.6.5 + Alloy v1.13.1 |
| **Traces** | ⏳ Pending | Tempo (next) |

---

## Phase 15 (suite): Traces — Grafana Tempo + OpenTelemetry (February 18, 2026)

### What Changed

Completed the **Traces** pillar of observability. lumen-api v1.2.0 now emits OpenTelemetry spans to Grafana Tempo, and `trace_id` appears in every structured log — enabling one-click navigation from a Loki log line to the corresponding Tempo trace in Grafana.

### Grafana Tempo 2.10.0 — Distributed Tracing Backend

**Mode:** Monolithic (single binary, all components in one pod).
**Storage:** Local filesystem — no S3/MinIO needed for single-node airgap.
**Deployment:** Helm chart `grafana/tempo:1.24.4`, extracted to `03-airgap-zone/manifests/tempo/`.

**Key config (`values-airgap.yaml`):**
```yaml
tempo:
  registry: localhost:5000
  repository: grafana/tempo
  tag: "2.10.0"
  storage:
    trace:
      backend: local
      local:
        path: /var/tempo/traces
      wal:
        path: /var/tempo/wal
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: "0.0.0.0:4317"
        http:
          endpoint: "0.0.0.0:4318"   # lumen-api sends traces here
  retention: 336h  # 14 days
persistence:
  enabled: true
  storageClassName: local-path
  size: 5Gi
```

**ArgoCD Application:** `03-airgap-zone/manifests/argocd/12-application-tempo.yaml`
- sync-wave: `"6"` (after Loki wave 4, Alloy wave 5)
- namespace: `monitoring`
- Helm releaseName: `tempo`

**Access:** https://tempo.airgap.local (Traefik IngressRoute `17-tempo-ingressroute.yaml`)

### OpenTelemetry — lumen-api v1.2.0

**Go SDK versions used:**

| Package | Version | Note |
|---------|---------|-------|
| `go.opentelemetry.io/otel` | `v1.37.0` | Core SDK |
| `go.opentelemetry.io/otel/sdk` | `v1.37.0` | TracerProvider |
| `go.opentelemetry.io/otel/trace` | `v1.37.0` | Span API |
| `go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp` | `v1.37.0` | OTLP HTTP exporter |
| `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp` | `v0.62.0` | HTTP middleware |

> **Version note:** otelhttp `v0.65.0` requires `otel@v1.40.0` — incompatible with `v1.37.0`. Use `v0.62.0` which is fully compatible.

**New files:**

`internal/tracing/tracing.go` — TracerProvider initialization:
```go
func Init(ctx context.Context) (func(context.Context) error, error) {
    endpoint := os.Getenv("TEMPO_ENDPOINT")
    // default: http://tempo.monitoring.svc.cluster.local:4318

    exporter, _ := otlptracehttp.New(ctx,
        otlptracehttp.WithEndpointURL(endpoint),
        otlptracehttp.WithInsecure(),
    )
    res := resource.NewWithAttributes(semconv.SchemaURL,
        semconv.ServiceName("lumen-api"),
        semconv.ServiceVersion("v1.2.0"),
    )
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(res),
        sdktrace.WithSampler(sdktrace.AlwaysSample()),
    )
    otel.SetTracerProvider(tp)
    return tp.Shutdown, nil
}
```

`internal/middleware/tracing.go` — OTel HTTP middleware:
```go
func Tracing(serviceName string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return otelhttp.NewHandler(next, serviceName,
            otelhttp.WithMessageEvents(otelhttp.ReadEvents, otelhttp.WriteEvents),
        )
    }
}
```

**Middleware chain in `app.go`:**
```go
handler := middleware.Recovery(
    middleware.Tracing("lumen-api")(   // OTel: creates root span per request
        middleware.Logging(             // slog: injects trace_id from context
            middleware.Metrics(m)(mux), // Prometheus: records HTTP metrics
        ),
    ),
)
```

**Child spans in handlers (`handlers.go`):**
```go
var tracer = otel.Tracer("lumen-api")

func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
    ctx, span := tracer.Start(r.Context(), "health.check")
    defer span.End()

    _, redisSpan := tracer.Start(ctx, "redis.ping")
    // ... redis ping
    redisSpan.End()
    span.SetAttributes(attribute.String("health.status", status))
}

func (h *Handler) Hello(w http.ResponseWriter, r *http.Request) {
    ctx, span := tracer.Start(r.Context(), "hello.handler")
    defer span.End()

    _, redisSpan := tracer.Start(ctx, "redis.increment")
    // ... redis incr
    redisSpan.SetAttributes(attribute.Int64("counter.value", counter))
    redisSpan.End()
}
```

**trace_id in logs (`middleware/logging.go`):**
```go
span := trace.SpanFromContext(r.Context())
slog.Info("request",
    "method", r.Method,
    "path", r.URL.Path,
    "status", wrapped.statusCode,
    "duration_ms", time.Since(start).Milliseconds(),
    "trace_id", span.SpanContext().TraceID().String(),  // NEW
)
```

Every request log now contains `trace_id`, e.g.:
```json
{"time":"2026-02-18T10:00:00Z","level":"INFO","msg":"request","method":"GET","path":"/hello","status":200,"duration_ms":1,"trace_id":"173db01794a77852a12..."}
```

### Grafana Datasources — Loki↔Tempo Correlation

Updated `kube-prometheus-stack-helm/values.yaml` (`additionalDataSources`):

```yaml
additionalDataSources:
  - name: Loki
    type: loki
    uid: loki
    url: http://loki-gateway.monitoring.svc.cluster.local
    jsonData:
      maxLines: 1000
      derivedFields:
        - name: TraceID
          matcherRegex: '"trace_id":"(\w+)"'  # parse trace_id from JSON log
          url: '${__value.raw}'
          datasourceUid: tempo                 # → open in Tempo

  - name: Tempo
    type: tempo
    uid: tempo
    url: http://tempo.monitoring.svc.cluster.local:3200
    jsonData:
      httpMethod: GET
      tracesToLogsV2:                          # Tempo → Loki drilldown
        datasourceUid: loki
        spanStartTimeShift: '-1m'
        spanEndTimeShift: '1m'
        tags:
          - key: app
```

### NetworkPolicies for Tempo

File: `03-airgap-zone/manifests/network-policies/14-allow-tempo.yaml`

Three policies:
1. **`allow-tempo-otlp-egress`** (lumen ns): lumen-api → monitoring port 4318 (OTLP HTTP)
2. **`tempo-otlp-ingress`** (monitoring ns): accept from lumen:4318/4317, from grafana:3200, from traefik:3200
3. **`grafana-tempo-egress`** (monitoring ns): grafana → tempo:3200, grafana → loki:3100

### Deployment manifest (`03-lumen-api.yaml`)

```yaml
image: localhost:5000/lumen-api:v1.2.0
env:
  - name: TEMPO_ENDPOINT
    value: "http://tempo.monitoring.svc.cluster.local:4318"
```

### Verifying Traces in Grafana

**Grafana → Explore → Tempo → Search → Service Name: `lumen-api`**

Shows all traces with:
- Trace ID (e.g., `173db01794a77852...`)
- Root span name (`/hello`, `/health`)
- Duration
- Child spans: `hello.handler` → `redis.increment`

**Grafana → Explore → Loki → query `{namespace="lumen"}` → click `trace_id` value → opens Tempo**

### 3 Pillars Status — COMPLETE ✅

| Pillar | Status | Stack |
|--------|--------|-------|
| **Metrics** | ✅ Complete | Prometheus 3.5.1 + Grafana 12.4.0 |
| **Logs** | ✅ Complete | Loki 3.6.5 + Alloy v1.13.1 |
| **Traces** | ✅ Complete | Grafana Tempo 2.10.0 + OpenTelemetry Go SDK v1.37.0 |

---

## References

- [kube-prometheus-stack Helm Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus 3.0 Announcement](https://prometheus.io/blog/2024/11/14/prometheus-3-0/)
- [Grafana v12 Release Notes](https://grafana.com/docs/grafana/latest/whatsnew/whats-new-in-v12-0/)
- [ArgoCD v3.0 Release](https://github.com/argoproj/argo-cd/releases/tag/v3.0.0)
- [Prometheus Operator Documentation](https://prometheus-operator.dev/)
- [Loki Deployment Modes](https://grafana.com/docs/loki/latest/get-started/deployment-modes/)
- [Grafana Alloy — Promtail Migration](https://grafana.com/docs/alloy/latest/set-up/migrate/from-promtail/)
- [Promtail EOL Announcement](https://community.grafana.com/t/promtail-end-of-life-eol-march-2026/159636)
- [VERSION-COMPARISON.md](./VERSION-COMPARISON.md) - Detailed version comparison
- [TESTING-MONITORING.md](./TESTING-MONITORING.md) - Testing procedures
- [Grafana Tempo Documentation](https://grafana.com/docs/tempo/latest/)
- [OpenTelemetry Go SDK](https://opentelemetry.io/docs/languages/go/)
- [OTel contrib otelhttp](https://pkg.go.dev/go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp)

---

**Last Updated:** February 18, 2026
**Project:** Lumen Airgap Kubernetes
**Phases Covered:** Phase 10 (kube-prometheus-stack), Phase 11/12 (Upgrades), Phase 15 (Loki + Alloy + Tempo + OpenTelemetry)
