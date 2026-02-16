# Lumen - Airgap Kubernetes Learning Project

> Learn software architecture by building a production-ready airgap Kubernetes environment

A hands-on project to master distributed systems, network security, and Kubernetes in air-gapped environments.

## 🎯 What You'll Learn

- **Multi-zone architecture**: Connected → Transit → Airgap separation
- **Network security**: NetworkPolicies, iptables, CNI configuration
- **Advanced Kubernetes**: K3s, containerd registry mirrors, admission controllers
- **Ingress Controllers**: Traefik v3 with CRDs, TLS termination, HTTP/2, middlewares
- **Helm Package Management**: Production-ready chart deployment and configuration
- **Observability**: Production monitoring with kube-prometheus-stack (Prometheus, Grafana, AlertManager)
- **Policy enforcement**: OPA Gatekeeper for admission control
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
- **CNI**: Cilium (L3/L4/L7 NetworkPolicies)
- **Registry**: Docker Registry v2
- **Ingress**: Traefik v3.6.8 (Helm chart, TLS termination, HTTP/2)
- **Git Server**: Gitea (internal Git repository for airgap)
- **GitOps**: ArgoCD (pulls from internal Gitea, not GitHub)
- **Policy**: OPA Gatekeeper
- **Monitoring**: kube-prometheus-stack v55 (Prometheus v2.48, Grafana v10.2.2, Node Exporter, kube-state-metrics)
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

### Admission Control
- Block `:latest` tags
- Enforce internal registry usage
- Require resource limits
- Validate required labels

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
- ✅ Phase 1-3: Build, Transit, K3s, Application Deployment
- ✅ Phase 4: NetworkPolicies - Zero Trust Security (13+ policies)
- ✅ Phase 5: Basic Monitoring Stack - Manual Prometheus + Grafana
- ✅ Phase 6: OPA Gatekeeper - Admission Control (4 policies)
- ✅ Phase 7: ArgoCD - GitOps Continuous Deployment with Redis Persistence
- ✅ Phase 8: Gitea - Internal Git Server for True Airgap GitOps
- ✅ Phase 9: Traefik Ingress Controller - Production-Grade Service Exposure (Helm)
- ✅ Phase 10: Production Observability - kube-prometheus-stack with 40+ Dashboards

## 🚧 Extend This Project

**Optional Future Enhancements:**
- [x] Add Helm charts (✅ Traefik + kube-prometheus-stack via Helm)
- [x] Migrate monitoring to `kube-prometheus-stack` Helm chart (✅ Phase 10)
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
