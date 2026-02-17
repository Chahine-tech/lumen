# Lumen - Airgap Kubernetes Learning Project

> Learn software architecture by building a production-ready airgap Kubernetes environment

A hands-on project to master distributed systems, network security, and Kubernetes in air-gapped environments.

## 🎯 What You'll Learn

- **Multi-zone architecture**: Connected → Transit → Airgap separation
- **Network security**: NetworkPolicies, iptables, CNI configuration
- **Advanced Kubernetes**: K3s, containerd registry mirrors, admission controllers
- **Ingress Controllers**: Traefik v3 with CRDs, TLS termination, HTTP/2, middlewares
- **Helm Package Management**: Production-ready chart deployment and configuration
- **Observability**: Production monitoring with kube-prometheus-stack (Prometheus v3.5, Grafana v12.4, AlertManager v0.31)
- **Security**: OPA Gatekeeper + Pod Security Standards (PSS) for admission control and runtime security
- **GitOps**: ArgoCD for declarative continuous deployment
- **DevOps**: Build pipelines, artifact management, air-gap deployment

## 🏗️ Architecture

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────────────┐
│  Connected Zone     │────▶│  Transit Zone       │────▶│  Airgap Zone (K3s)          │
│  (Internet access)  │     │  (Registry/Bridge)  │     │  (No Internet)              │
├─────────────────────┤     ├─────────────────────┤     ├─────────────────────────────┤
│ • Build images      │     │ • Docker Registry   │     │ • Lumen API + Redis         │
│ • Download Helm     │     │ • File server       │     │ • Gitea (Git server)        │
│ • Run tests         │     │ • Image storage     │     │ • ArgoCD (GitOps)           │
└─────────────────────┘     └─────────────────────┘     │ • Traefik Ingress (Helm)    │
                                                        │ • OPA Gatekeeper            │
                                    ┌──────────────────▶│ • kube-prometheus-stack     │
                                    │                   └─────────────────────────────┘
                              git push-all                          ▲
                           (GitHub + Gitea)             https://traefik.airgap.local
                                                        https://gitea.airgap.local
                                                        https://argocd.airgap.local
                                                        https://grafana.airgap.local
                                                        https://prometheus.airgap.local
```

## 🚀 Quick Start

### Prerequisites

- Docker & Docker Compose
- kubectl
- Make
- Go 1.26+ (for development)
- sudo access (for K3s + iptables)

### 1. Build Application

```bash
# Build and test locally
make build-connected
make test-api-local

# Test endpoints
curl http://localhost:8080/health
curl http://localhost:8080/hello
```

### 2. Setup Transit Registry

```bash
make setup-transit
make transit-status

# Access registry UI: http://localhost:8081
```

### 3. Setup Airgap Environment

```bash
# Requires sudo for iptables and K3s
sudo make setup-airgap
make test-airgap
```

### 4. Deploy to Kubernetes

```bash
make deploy                     # Deploy everything
make deploy-network-policies    # Apply security policies
make deploy-opa                 # Enable admission control
make deploy-monitoring          # Setup observability
make deploy-argocd              # Setup GitOps (optional)
```

### 5. Access Services

**With Traefik Ingress (Recommended):**
```bash
# Services accessible via DNS-based HTTPS URLs:
https://traefik.airgap.local/dashboard/   # Traefik Dashboard (admin/admin)
https://gitea.airgap.local                # Gitea (gitea-admin/gitea-admin)
https://grafana.airgap.local              # Grafana (admin/admin)
https://prometheus.airgap.local           # Prometheus
https://alertmanager.airgap.local         # AlertManager
https://argocd.airgap.local               # ArgoCD (admin/[from secret])
```

**Legacy port-forward (for troubleshooting only):**
```bash
./scripts/start-port-forwards.sh          # Legacy fallback
```

## 📦 Technology Stack

- **API**: Go 1.26 (production-grade with graceful shutdown)
- **Cache**: Redis 7 Alpine
- **Cluster**: K3s (lightweight, airgap-optimized)
- **CNI**: Flannel (default K3s CNI, upgrade path to Cilium available)
- **Registry**: Docker Registry v2
- **Ingress**: Traefik v3.6.8 (Helm chart, TLS termination, HTTP/2)
- **Git Server**: Gitea (internal Git repository for airgap)
- **GitOps**: ArgoCD v3.2.0 (pulls from internal Gitea, not GitHub)
- **Security**: OPA Gatekeeper v3.18.0 + Pod Security Standards (PSS restricted mode)
- **Monitoring**: kube-prometheus-stack v69 (Prometheus v3.5.1, Grafana v12.4.0, Node Exporter v1.8.2, kube-state-metrics v2.15.0)
- **Package Management**: Helm 3 (for Traefik)
- **Isolation**: iptables + containerd mirrors

## 🔑 Key Implementations

### Airgap Enforcement
```bash
iptables -A OUTPUT -d 0.0.0.0/0 -j DROP
iptables -I OUTPUT -d 10.0.0.0/8 -j ACCEPT
```

### Registry Mirrors
```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  docker.io:
    endpoint: ["http://registry.airgap.local:5000"]
```

### Zero Trust Networking
- Default deny-all NetworkPolicies
- Explicit allow rules for required communication
- Cilium L7 HTTP filtering

### Security (Defense in Depth)

**Layer 1: OPA Gatekeeper** (Custom Policies)
- Block `:latest` tags
- Enforce internal registry (`localhost:5000/` only)
- Require resource limits (CPU/memory requests and limits)
- Validate required labels (`app`, `tier`)

**Layer 2: Pod Security Standards** (System Security)
- No privileged containers
- Must run as non-root (`runAsNonRoot=true`)
- No host access (hostPath, hostNetwork, hostPID)
- Capabilities must drop ALL
- `seccompProfile` required (RuntimeDefault)

**Layer 3: NetworkPolicies** (Zero-Trust Networking)
- Default deny-all
- Explicit allow rules only

### GitOps Workflow with Gitea
```bash
# Configure git alias for dual push
git config --global alias.push-all '!git push origin main && git push gitea main'

# Daily workflow
git add .
git commit -m "feat: add new feature"
git push-all  # Pushes to GitHub (backup) + Gitea (ArgoCD source)

# ArgoCD automatically syncs from Gitea within 3 minutes
```

**Architecture:**
- GitHub: Source of truth, backup, portfolio
- Gitea (internal): Mirror for ArgoCD in airgap cluster
- ArgoCD: Pulls from `http://gitea.gitea.svc.cluster.local:3000`
- No external Internet access required for deployments ✅

## 🧪 Testing

```bash
make test                      # Run full test suite
make test-network-policies     # Test policy enforcement
make test-opa                  # Test admission control
./scripts/test-airgap-complete.sh
```

## 📚 Documentation

- [Complete Setup Guide](docs/SETUP.md) - Detailed step-by-step instructions
- [Deployment Guide](docs/DEPLOYMENT.md) - Real deployment results and troubleshooting
- [Traefik Ingress](docs/traefik.md) - Production-grade ingress with Helm, TLS, and troubleshooting
- [Monitoring Stack](docs/monitoring.md) - kube-prometheus-stack deployment and upgrades (58KB)
- [Architecture Deep Dive](docs/ARCHITECTURE.md) - Technical details

## 🛠️ Common Commands

```bash
make help              # Show all commands
make status            # Cluster status
make logs-api          # View API logs
make clean             # Remove everything
```

## 📖 Learning Path

1. **Beginner** (1-2 days): Understand 3-zone architecture, local testing
2. **Intermediate** (3-5 days): Registry mirrors, basic NetworkPolicies, monitoring
3. **Advanced** (1-2 weeks): Cilium L7 policies, OPA custom rules, full airgap + iptables

## ✅ Project Status

**Completed Phases:**
- ✅ Phase 1-4: Build, Transit, K3s, Application Deployment
- ✅ Phase 5: NetworkPolicies - Zero Trust Security (13+ policies)
- ✅ Phase 6-7: Basic Monitoring + ArgoCD GitOps with Redis Persistence
- ✅ Phase 8: Gitea - Internal Git Server for True Airgap GitOps
- ✅ Phase 9: Traefik Ingress Controller - Production-Grade Service Exposure (Helm)
- ✅ Phase 10: Production Observability - kube-prometheus-stack with 40+ Dashboards
- ✅ Phase 11/12: Version Upgrades - Prometheus v3.5.1, Grafana v12.4.0, ArgoCD v3.2.0
- ✅ Phase 13: OPA Gatekeeper v3.18.0 - Admission Control (4 custom policies)
- ✅ Phase 14: Pod Security Standards (PSS) - Restricted Mode Security

**Current State:**
- 🛡️ **3-Layer Security**: OPA Gatekeeper + PSS + NetworkPolicies
- 📊 **Complete Observability**: Metrics (Prometheus/Grafana) with 40+ dashboards
- 🔄 **Full GitOps**: ArgoCD syncing from internal Gitea
- 🔒 **Production-Grade**: TLS, RBAC, admission control, zero-trust networking

## 🚧 Extend This Project

**Optional Future Enhancements:**
- [x] Add Helm charts (✅ Traefik + kube-prometheus-stack via Helm)
- [x] Migrate monitoring to `kube-prometheus-stack` Helm chart
- [ ] Add Vault for secrets management
- [ ] Implement service mesh (Linkerd/Istio)
- [ ] Add Falco for runtime security
- [ ] Add Loki for centralized logging
- [ ] Implement Chaos Mesh for resilience testing

## 📖 Resources

### Kubernetes & K3s
- [K3s Airgap Installation](https://docs.k3s.io/installation/airgap)
- [Kubernetes NetworkPolicies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

### Traefik & Ingress
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Traefik Helm Chart](https://github.com/traefik/traefik-helm-chart)
- [IngressRoute CRD Reference](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/)

### Helm
- [Helm Documentation](https://helm.sh/docs/)
- [Helm Best Practices](https://helm.sh/docs/chart_best_practices/)

### Cilium
- [Cilium NetworkPolicy Guide](https://docs.cilium.io/en/stable/security/policy/)
- [Cilium L7 HTTP Policies](https://docs.cilium.io/en/stable/security/policy/language/#layer-7-examples)

### OPA Gatekeeper
- [OPA Gatekeeper Docs](https://open-policy-agent.github.io/gatekeeper/)
- [Policy Library](https://github.com/open-policy-agent/gatekeeper-library)

### Monitoring
- [Prometheus Operator](https://prometheus-operator.dev/)
- [Prometheus Go Client](https://github.com/prometheus/client_golang)

### Go Best Practices
- [Go Project Layout](https://github.com/golang-standards/project-layout)
- [Effective Go](https://go.dev/doc/effective_go)

## 📝 License

MIT - See [LICENSE](LICENSE) for details.

---

**Built to learn Software Architecture** 🏗️ | [Issues](https://github.com/Chahine-tech/lumen/issues)
