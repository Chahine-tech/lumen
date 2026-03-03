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
- **Security**: OPA Gatekeeper + Pod Security Standards (PSS) + Falco runtime security + Cosign image signing
- **Secrets Management**: HashiCorp Vault HA + cert-manager PKI (Vault Secrets Operator, dynamic credentials, automatic TLS renewal)
- **mTLS**: cert-manager + Vault PKI — mutual TLS between services (zero-trust east-west traffic)
- **GitOps**: ArgoCD for declarative continuous deployment
- **CI/CD**: Gitea Actions pipeline (test → build → scan → push → sign) + Argo Rollouts canary deployments with Prometheus-driven auto-promotion
- **Resilience Testing**: Chaos Mesh (PodChaos, NetworkChaos) — fault injection to validate resilience
- **Infrastructure as Code**: Terraform (VM provisioning) + Ansible (full cluster bootstrap)

See [docs/architecture.md](docs/architecture.md) for the full system diagram and component details.

## 🚀 Quick Start

### Prerequisites

- Docker & Docker Compose
- kubectl + Helm
- Make
- Go 1.26+ (for development)
- Terraform 1.5+ + Multipass (for VM provisioning)
- Ansible 2.14+ (for cluster bootstrap)
- sudo access (for K3s + iptables)

### 0. Provision VMs (one-time)

```bash
multipass set local.bridged-network=en0   # once per Mac
cd 05-terraform && terraform init && terraform apply
```

### 1. Build Application

```bash
make build-connected
make test-api-local

curl http://localhost:8080/health
curl http://localhost:8080/hello
```

### 2. Setup Transit Registry

```bash
make setup-transit
make transit-status
# Registry UI: http://localhost:8081
```

### 3. Setup Airgap Environment

```bash
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

```
https://traefik.airgap.local/dashboard/   # Traefik Dashboard (admin/admin)
https://gitea.airgap.local                # Gitea (gitea-admin/gitea-admin)
https://grafana.airgap.local              # Grafana (admin/admin)
https://prometheus.airgap.local           # Prometheus
https://alertmanager.airgap.local         # AlertManager
https://argocd.airgap.local               # ArgoCD (admin/[from secret])
https://tempo.airgap.local                # Grafana Tempo
https://vault.airgap.local                # HashiCorp Vault UI
https://lumen-api.airgap.local            # Lumen API
https://chaos-mesh.airgap.local           # Chaos Mesh Dashboard
```

## 📦 Technology Stack

| Layer | Stack |
|---|---|
| **API** | Go 1.26, graceful shutdown, idempotency middleware |
| **Cluster** | K3s (arm64), Flannel CNI, MetalLB, Traefik v3 |
| **Databases** | Redis 7 HA Sentinel + PostgreSQL 16 via CloudNativePG |
| **Observability** | Prometheus + Grafana + Loki + Alloy + Tempo + OpenTelemetry |
| **Security** | OPA Gatekeeper + PSS + NetworkPolicies + Falco + Cosign |
| **Secrets / TLS** | Vault HA (Raft) + cert-manager + VSO + mTLS |
| **GitOps / CI** | ArgoCD + Gitea Actions + Argo Rollouts (canary) |
| **Resilience** | Chaos Mesh (PodChaos, NetworkChaos) |
| **IaC** | Terraform (Multipass VMs) + Ansible (bootstrap, unseal, start/stop) |

## 🧪 Testing

```bash
make test                      # Run full test suite
make test-network-policies     # Test policy enforcement
make test-opa                  # Test admission control
./scripts/test-airgap-complete.sh
```

## 🛠️ Common Commands

```bash
make help              # Show all commands
make status            # Cluster status
make logs-api          # View API logs
make clean             # Remove everything
```

## 📚 Documentation

- [Architecture](docs/architecture.md) — Full system overview, zone separation, component diagrams
- [Concepts](docs/concepts.md) — Technical synthesis: Linux, K8s networking, TLS, eBPF, GitOps, RBAC
- [Airgap Multipass Setup](docs/AIRGAP-MULTIPASS.md) — VM setup, K3s, MetalLB, registry, ArgoCD
- [Databases](docs/databases.md) — Redis HA Sentinel + CloudNativePG (failover, connection patterns)
- [CI/CD](docs/cicd.md) — Gitea Actions + Argo Rollouts canary + Prometheus auto-promotion
- [Security](docs/security.md) — OPA Gatekeeper, PSS, NetworkPolicies, Falco (5-layer defense-in-depth)
- [Vault & cert-manager](docs/vault-cert-manager.md) — Vault HA, PKI, VSO, automatic TLS renewal
- [Monitoring](docs/monitoring.md) — kube-prometheus-stack, Loki, Tempo, ServiceMonitors

## 📖 Learning Path

1. **Beginner** (1-2 days): Understand 3-zone architecture, local testing
2. **Intermediate** (3-5 days): Registry mirrors, basic NetworkPolicies, monitoring
3. **Advanced** (1-2 weeks): OPA custom rules, full airgap + iptables, Vault PKI

## ✅ Project Status

- 🛡️ **5-Layer Security**: OPA Gatekeeper + PSS + NetworkPolicies + Falco runtime + Cosign image signing
- 🔐 **Secrets Management**: Vault HA (3-replica Raft) + VSO — KV v2, PKI engine (no plaintext K8s secrets)
- 📜 **Automatic TLS + mTLS**: cert-manager → Vault PKI — `*.airgap.local` renewed automatically, mutual TLS east-west
- 📊 **Complete Observability**: Metrics + Logs + Traces (Prometheus, Grafana, Loki, Alloy, Tempo)
- 🔄 **Full GitOps**: ArgoCD syncing from internal Gitea
- 🚀 **Canary CI/CD**: Gitea Actions → Argo Rollouts → AnalysisTemplate Prometheus (auto-promote/rollback)
- 💥 **Resilience Testing**: Chaos Mesh — PodChaos + NetworkChaos validates recovery under fault injection
- 🔒 **Production-Grade**: TLS, RBAC, admission control, zero-trust networking, MetalLB, PodDisruptionBudgets
- 🖥️ **Multi-Node**: 2-node K3s cluster on Multipass VMs (arm64)
- 🗄️ **HA Databases**: Redis Sentinel (automatic failover) + CloudNativePG (quorum-based, read/write splitting)
- ⚙️ **IaC**: Terraform (VM provisioning, cloud-init, static IPs) + Ansible (full bootstrap, unseal, start/stop)
- 🔁 **Idempotency**: Redis-backed middleware deduplication (POST/DELETE, 24h TTL)

**Next:** Migrate CNI to Cilium (eBPF, L7 NetworkPolicies, Hubble) · Renovate Bot for automated dependency updates

## 📝 License

MIT - See [LICENSE](LICENSE) for details.

---

**Built to learn Software Architecture** 🏗️ | [Issues](https://github.com/Chahine-tech/lumen/issues)
