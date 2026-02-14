# Port Mapping - Lumen Project

Central reference for all ports used in the Lumen airgap architecture.

---

## 📋 Table of Contents
- [Cluster Internal Ports](#cluster-internal-ports)
- [Port-Forward Mappings](#port-forward-mappings)
- [Registry Ports](#registry-ports)
- [K3d Cluster Ports](#k3d-cluster-ports)
- [Reserved Ports](#reserved-ports)

---

## 🔌 Cluster Internal Ports (Inside Airgap)

Services running inside the K3s airgap cluster.

### Application Services

| Service | Namespace | Port | Protocol | Description | Manifest |
|---------|-----------|------|----------|-------------|----------|
| lumen-api | default | 8080 | HTTP | Lumen FastAPI application | `manifests/app/02-deployment.yaml` |
| redis | lumen | 6379 | TCP | Redis cache for Lumen API | `manifests/app/03-redis.yaml` |

### ArgoCD Services

| Service | Namespace | Port | Protocol | Description | Manifest |
|---------|-----------|------|----------|-------------|----------|
| argocd-server | argocd | 443 | HTTPS | ArgoCD Web UI and API | `manifests/argocd/02-install-airgap.yaml` |
| argocd-server | argocd | 8080 | HTTP | ArgoCD metrics | `manifests/argocd/02-install-airgap.yaml` |
| argocd-repo-server | argocd | 8081 | gRPC | Git repository operations | `manifests/argocd/02-install-airgap.yaml` |
| argocd-redis | argocd | 6379 | TCP | ArgoCD cache storage | `manifests/argocd/02-install-airgap.yaml` |
| argocd-dex-server | argocd | 5556 | HTTP | SSO/OIDC authentication | `manifests/argocd/02-install-airgap.yaml` |
| argocd-metrics | argocd | 8082 | HTTP | Metrics exporter | `manifests/argocd/02-install-airgap.yaml` |

### Monitoring Services

| Service | Namespace | Port | Protocol | Description | Manifest |
|---------|-----------|------|----------|-------------|----------|
| prometheus | monitoring | 9090 | HTTP | Prometheus metrics server | `manifests/monitoring/02-prometheus.yaml` |
| grafana | monitoring | 3000 | HTTP | Grafana dashboards | `manifests/monitoring/03-grafana.yaml` |
| alertmanager | monitoring | 9093 | HTTP | Alert routing and notifications | `manifests/monitoring/04-alertmanager.yaml` |

### Gitea Services

| Service | Namespace | Port | Protocol | Description | Manifest |
|---------|-----------|------|----------|-------------|----------|
| gitea | gitea | 3000 | HTTP | Gitea Web UI and Git HTTP | `manifests/gitea/03-service.yaml` |
| gitea | gitea | 22 | SSH | Git SSH operations | `manifests/gitea/03-service.yaml` |

### Kubernetes System Services

| Service | Namespace | Port | Protocol | Description |
|---------|-----------|------|----------|-------------|
| kube-dns | kube-system | 53 | UDP/TCP | CoreDNS for service discovery |
| kubernetes | default | 443 | HTTPS | Kubernetes API server (ClusterIP) |
| kubernetes | default | 6443 | HTTPS | Kubernetes API server (actual) |

---

## 🌐 Port-Forward Mappings (localhost → cluster)

Port-forwards for local development access to cluster services.

| Service | Local Port | Cluster Port | Namespace | Command | Notes |
|---------|------------|--------------|-----------|---------|-------|
| **ArgoCD** | `8081` | `443` | argocd | `kubectl port-forward svc/argocd-server -n argocd 8081:443` | Access: https://localhost:8081 |
| **Grafana** | `3000` | `3000` | monitoring | `kubectl port-forward svc/grafana -n monitoring 3000:3000` | Access: http://localhost:3000 |
| **Gitea** | `3001` | `3000` | gitea | `kubectl port-forward svc/gitea -n gitea 3001:3000` | Access: http://localhost:3001 |
| **Prometheus** | `9090` | `9090` | monitoring | `kubectl port-forward svc/prometheus -n monitoring 9090:9090` | Access: http://localhost:9090 |
| **AlertManager** | `9093` | `9093` | monitoring | `kubectl port-forward svc/alertmanager -n monitoring 9093:9093` | Access: http://localhost:9093 |
| **Lumen API** | `8080` | `8080` | default | `kubectl port-forward svc/lumen-api 8080:8080` | Access: http://localhost:8080 |

**Port Allocation Strategy:**
- `3000-3099`: Monitoring/Dashboards (Grafana=3000, Gitea=3001)
- `8080-8099`: Application APIs (Lumen=8080, ArgoCD=8081)
- `9090-9099`: Observability backends (Prometheus=9090, AlertManager=9093)

---

## 🏪 Registry Ports

Docker/container registries for image distribution.

| Registry | Zone | Host | Port | Protocol | Access | Description |
|----------|------|------|------|----------|--------|-------------|
| **Transit Registry** | Transit | localhost | 5000 | HTTP | Internal | Docker Registry v2 for image transit |
| **Transit Registry UI** | Transit | localhost | 8081 | HTTP | Browser | Joxit web UI for registry browsing |
| **Transit File Server** | Transit | localhost | 8082 | HTTP | Browser | Nginx file server for artifacts |
| **Airgap Registry (hostname)** | Airgap | registry.airgap.local | 5000 | HTTP | Cluster | Internal registry mirror |
| **Airgap Registry (IP)** | Airgap | 192.168.107.2 | 5000 | HTTP | Cluster | Direct IP access to registry |

**Registry Configuration:**
- TLS: Disabled (insecure_skip_verify: true)
- Delete: Enabled
- CORS: Allowed from all origins

---

## 🖥️ K3d Cluster Ports

External access ports for K3d clusters (NodePort/LoadBalancer mappings).

### Transit Zone Cluster (k3d-lumen-transit)

| Service | Host Port | Cluster Port | Description |
|---------|-----------|--------------|-------------|
| LoadBalancer | 8080 | 80 | HTTP ingress |
| LoadBalancer | 8443 | 443 | HTTPS ingress |
| API Server | (random) | 6443 | Kubernetes API |

### Airgap Zone Cluster (k3d-lumen-airgap)

| Service | Host Port | Cluster Port | Description |
|---------|-----------|--------------|-------------|
| LoadBalancer | 8080 | 80 | HTTP ingress |
| LoadBalancer | 8443 | 443 | HTTPS ingress |
| API Server | 6443 | 6443 | Kubernetes API |

---

## 🚫 Reserved Ports (Do Not Use)

Ports already in use by system services or reserved for future use.

| Port | Service | Reason |
|------|---------|--------|
| 22 | SSH | System SSH (also used by Gitea internally) |
| 53 | DNS | CoreDNS in kube-system |
| 80 | HTTP | K3d LoadBalancer |
| 443 | HTTPS | K3d LoadBalancer, ArgoCD, Kubernetes API |
| 3000 | Grafana | Monitoring dashboard (port-forward) |
| 3001 | Gitea | Internal Git server (port-forward) |
| 5000 | Registry | Docker registry (transit + airgap) |
| 5556 | Dex | ArgoCD SSO |
| 6379 | Redis | Cache services (Lumen, ArgoCD) |
| 6443 | API Server | Kubernetes API |
| 8080 | Lumen API | Application + K3d LB |
| 8081 | ArgoCD | ArgoCD Web UI (port-forward) + Registry UI (transit) |
| 8082 | Metrics | ArgoCD metrics + File server (transit) |
| 9090 | Prometheus | Metrics server |
| 9093 | AlertManager | Alert routing |

---

## 📝 Port Assignment Guidelines

When adding new services to the Lumen project:

1. **Check this document first** to avoid conflicts
2. **Choose ports by category:**
   - `3000-3099`: User-facing dashboards/UIs
   - `5000-5999`: Infrastructure (registries, databases)
   - `8000-8999`: Application APIs and management UIs
   - `9000-9999`: Observability (metrics, logs, traces)
3. **Update this document** immediately after assignment
4. **Use consistent port-forward mappings** (localhost port = cluster port when possible)
5. **Document in manifest comments** for clarity

---

## 🔄 Future Ports (Planned)

Ports reserved for planned features.

| Port | Service | Phase | Description |
|------|---------|-------|-------------|
| 3100 | Loki | Phase 10 | Log aggregation |
| 4317 | Tempo/OTLP | Phase 10 | Trace ingestion (gRPC) |
| 4318 | Tempo/OTLP | Phase 10 | Trace ingestion (HTTP) |
| 3002 | Jaeger UI | Phase 10 | Distributed tracing UI |
| 5432 | PostgreSQL | Future | Database (if Gitea HA implemented) |

---

## 📚 Quick Reference Commands

### View all services and ports
```bash
# All services in all namespaces
kubectl get svc --all-namespaces -o wide

# Specific namespace
kubectl get svc -n argocd
kubectl get svc -n monitoring
kubectl get svc -n gitea
```

### Check port-forward processes
```bash
# List active port-forwards
ps aux | grep "port-forward"

# Kill all port-forwards
pkill -f "port-forward"
```

### Test connectivity
```bash
# From local machine
curl http://localhost:3000  # Grafana
curl http://localhost:3001  # Gitea
curl http://localhost:9090  # Prometheus

# From inside cluster
kubectl run test-curl --image=curlimages/curl:latest --rm -it --restart=Never -- curl http://grafana.monitoring.svc.cluster.local:3000
```

---

**Last Updated:** February 14, 2026 (Phase 8 - Gitea Implementation)
