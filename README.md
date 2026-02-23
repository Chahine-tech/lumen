# Lumen - Airgap Kubernetes Learning Project

> Learn software architecture by building a production-ready airgap Kubernetes environment

A hands-on project to master distributed systems, network security, and Kubernetes in air-gapped environments.

## 🎯 What You'll Learn

- **Multi-zone architecture**: Connected → Transit → Airgap separation
- **Network security**: NetworkPolicies, iptables, CNI configuration
- **Advanced Kubernetes**: K3s, containerd registry mirrors, admission controllers
- **Ingress Controllers**: Traefik v3 with CRDs, TLS termination, HTTP/2, middlewares
- **Helm Package Management**: Production-ready chart deployment and configuration
- **Observability**: Full 3-pillar stack — Metrics (kube-prometheus-stack), Logs (Loki + Alloy), Traces (Tempo + OpenTelemetry)
- **Security**: OPA Gatekeeper + Pod Security Standards (PSS) for admission control and runtime security
- **Secrets Management**: HashiCorp Vault HA + cert-manager PKI (Vault Agent Injector, dynamic credentials, automatic TLS renewal)
- **GitOps**: ArgoCD for declarative continuous deployment
- **DevOps**: Build pipelines, artifact management, air-gap deployment

## 🏗️ Architecture

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────────────┐
│  Connected Zone     │────▶│  Transit Zone       │────▶│  Airgap Zone (K3s)          │
│  (Internet access)  │     │  (Registry/Bridge)  │     │  (No Internet)              │
├─────────────────────┤     ├─────────────────────┤     ├─────────────────────────────┤
│ • Build images      │     │ • Docker Registry   │     │ • Lumen API                 │
│ • Download Helm     │     │ • File server       │     │ • Redis HA Sentinel         │
│ • Run tests         │     │ • Image storage     │     │ • PostgreSQL (CloudNativePG)│
└─────────────────────┘     └─────────────────────┘     │ • Gitea (Git server)        │
                                                        │ • ArgoCD (GitOps)           │
                                    ┌──────────────────▶│ • Traefik Ingress (Helm)    │
                                    │                   │ • OPA Gatekeeper            │
                                    │                   │ • kube-prometheus-stack     │
                                    │                   │ • Loki + Alloy + Tempo      │
                                    │                   │ • Vault HA + cert-manager   │
                                    │                   └─────────────────────────────┘
                              git push-all                          ▲
                           (GitHub + Gitea)             https://traefik.airgap.local
                                                        https://gitea.airgap.local
                                                        https://argocd.airgap.local
                                                        https://grafana.airgap.local
                                                        https://prometheus.airgap.local
                                                        https://tempo.airgap.local
                                                        https://vault.airgap.local
                                                        https://lumen-api.airgap.local
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
make deploy-monitoring          # Setup observability (managed by ArgoCD)
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
https://tempo.airgap.local                # Grafana Tempo (distributed traces)
https://vault.airgap.local               # HashiCorp Vault UI (root token from vault-init-job)
https://lumen-api.airgap.local           # Lumen API
```

**Legacy port-forward (for troubleshooting only):**
```bash
./scripts/start-port-forwards.sh          # Legacy fallback
```

## 📦 Technology Stack

- **API**: Go 1.26 (production-grade with graceful shutdown)
- **Cache**: Redis 7 Alpine (HA Sentinel — 1 master + 1 replica + 3 sentinels)
- **Database**: PostgreSQL 16.6 via CloudNativePG (1 master + 1 replica + 1 witness, read/write splitting)
- **Cluster**: K3s (lightweight, airgap-optimized)
- **CNI**: Flannel (default K3s overlay CNI) + kube-router (NetworkPolicy controller, upgrade path to Cilium available)
- **Registry**: Docker Registry v2
- **Ingress**: Traefik v3.6.8 (Helm chart, TLS termination, HTTP/2)
- **Git Server**: Gitea (internal Git repository for airgap)
- **GitOps**: ArgoCD v3.2.0 (pulls from internal Gitea, not GitHub)
- **Security**: OPA Gatekeeper v3.18.0 + Pod Security Standards (PSS restricted mode)
- **Secrets**: HashiCorp Vault 1.19.0 HA (3-replica Raft, KV v2, PKI Engine, Agent Injector)
- **TLS PKI**: cert-manager v1.17.1 (ClusterIssuer → Vault PKI, automatic renewal)
- **Monitoring**: kube-prometheus-stack v69 (Prometheus v3.5.1, Grafana v12.4.0, AlertManager v0.31, Node Exporter v1.8.2, kube-state-metrics v2.15.0)
- **Logging**: Loki 3.6.5 + Alloy v1.13.1 (log aggregation + collection)
- **Tracing**: Grafana Tempo 2.10.0 + OpenTelemetry SDK (distributed traces)
- **Package Management**: Helm 3 (Traefik, kube-prometheus-stack, Loki, Alloy, Tempo, Vault, cert-manager)
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
- Per-namespace isolation (lumen, monitoring, traefik, argocd, gitea, cnpg-system)

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

- [Airgap Multipass Setup](docs/AIRGAP-MULTIPASS.md) - Phase 16 setup guide (VMs, K3s, MetalLB, registry, ArgoCD)
- [Databases](docs/databases.md) - Redis HA Sentinel + CloudNativePG PostgreSQL (architecture, failover, connection patterns)

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
- ✅ Phase 5: NetworkPolicies - Zero Trust Security
- ✅ Phase 6-7: Basic Monitoring + ArgoCD GitOps with Redis Persistence
- ✅ Phase 8: Gitea - Internal Git Server for True Airgap GitOps
- ✅ Phase 9: Traefik Ingress Controller - Production-Grade Service Exposure (Helm)
- ✅ Phase 10: Production Observability - kube-prometheus-stack (Prometheus, Grafana, AlertManager)
- ✅ Phase 11/12: Version Upgrades
- ✅ Phase 13: OPA Gatekeeper v3.18.0 - Admission Control (4 custom policies)
- ✅ Phase 14: Pod Security Standards (PSS) - Restricted Mode Security
- ✅ Phase 15: Complete Observability Stack - Loki + Alloy + Tempo (logs + traces)
- ✅ Phase 16: Multipass Migration - 2-node K3s cluster, MetalLB, arm64, full airgap on real Linux VMs
- ✅ Phase 16.5: Gitea Actions CI — automated test → build → Trivy scan → push pipeline (fully airgapped)
- ✅ Phase 17: Redis HA Sentinel — 1 master + 1 replica + 3 sentinels, automatic failover, PVC persistence
- ✅ Phase 18: CloudNativePG — PostgreSQL 16 cluster (1 master + 1 replica + 1 witness), read/write splitting, CNPG operator
- ✅ v1.5.0: Idempotency middleware (Redis-backed, 24h TTL, `Idempotency-Key` header)
- ✅ SRE hardening: PodDisruptionBudgets (lumen-api + redis-sentinel), NetworkPolicy fixes (CoreDNS + Grafana egress → API server)
- ✅ Phase 19: Vault HA + cert-manager — PKI engine, Vault Agent Injector, automatic TLS renewal, lumen-api v1.6.0

**Current State:**
- 🛡️ **3-Layer Security**: OPA Gatekeeper + PSS + NetworkPolicies
- 🔐 **Secrets Management**: Vault HA (3-replica Raft) — KV v2, PKI engine, Agent Injector (no plaintext K8s secrets)
- 📜 **Automatic TLS**: cert-manager → Vault PKI — `*.airgap.local` renewed automatically 30 days before expiry
- 📊 **Complete Observability**: Metrics + Logs + Traces (Prometheus, Grafana, Loki, Alloy, Tempo)
- 🔄 **Full GitOps**: ArgoCD syncing from internal Gitea
- 🔒 **Production-Grade**: TLS, RBAC, admission control, zero-trust networking, MetalLB LoadBalancer, PodDisruptionBudgets
- 🖥️ **Multi-Node**: 2-node K3s cluster on Multipass VMs (arm64)
- ⚙️ **CI Pipeline**: Gitea Actions — test → build → Trivy scan → push (100% airgapped)
- 🗄️ **HA Databases**: Redis Sentinel (automatic failover) + CloudNativePG PostgreSQL (quorum-based, read/write splitting)
- 🔁 **Idempotency**: Redis-backed middleware deduplication (POST/DELETE, 24h TTL)

## 🚧 Extend This Project

**Optional Future Enhancements:**
- [x] Add Helm charts (✅ Traefik + kube-prometheus-stack via Helm)
- [x] Migrate monitoring to `kube-prometheus-stack` Helm chart
- [x] Add Loki for centralized logging (✅ Loki 3.6.5 + Alloy + Tempo via Helm)
- [x] Add Vault for secrets management + cert-manager PKI (✅ Phase 19 — Vault HA + cert-manager v1.17.1)
- [ ] Infrastructure as Code with Ansible (Phase 20)
- [ ] Migrate CNI to Cilium (eBPF, L7 NetworkPolicies, Hubble observability)
- [ ] Renovate Bot for automated dependency updates (Helm charts, images, Go deps)
- [ ] Add Falco for runtime security
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
