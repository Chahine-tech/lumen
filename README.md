# Lumen - Airgap Kubernetes Learning Project

> Learn software architecture by building a production-ready airgap Kubernetes environment

A hands-on project to master distributed systems, network security, and Kubernetes in air-gapped environments.

## 🎯 What You'll Learn

- **Multi-zone architecture**: Connected → Transit → Airgap separation
- **Network security**: NetworkPolicies, iptables, CNI configuration
- **Advanced Kubernetes**: K3s, containerd registry mirrors, admission controllers
- **Observability**: Monitoring without external access (Prometheus + Grafana)
- **Policy enforcement**: OPA Gatekeeper
- **DevOps**: Build pipelines, artifact management, air-gap deployment

## 🏗️ Architecture

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│  Connected Zone     │────▶│  Transit Zone       │────▶│  Airgap Zone        │
│  (Internet access)  │     │  (Registry/Bridge)  │     │  (No Internet)      │
├─────────────────────┤     ├─────────────────────┤     ├─────────────────────┤
│ • Build images      │     │ • Docker Registry   │     │ • K3s cluster       │
│ • Download deps     │     │ • File server       │     │ • Lumen API + Redis │
│ • Run tests         │     │ • Image storage     │     │ • Cilium CNI        │
└─────────────────────┘     └─────────────────────┘     │ • OPA Gatekeeper    │
                                                        │ • Prometheus+Grafana│
                                                        └─────────────────────┘
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
```

### 5. Access Services

```bash
make forward-api         # API: localhost:8080
make forward-grafana     # Grafana: localhost:3000 (admin/admin)
make forward-prometheus  # Prometheus: localhost:9090
```

## 📦 Technology Stack

- **API**: Go 1.26 (production-grade with graceful shutdown)
- **Cache**: Redis 7 Alpine
- **Cluster**: K3s (lightweight, airgap-optimized)
- **CNI**: Cilium (L3/L4/L7 NetworkPolicies)
- **Registry**: Docker Registry v2
- **Policy**: OPA Gatekeeper
- **Monitoring**: Prometheus + Grafana (no remote_write)
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

## 🚧 Extend This Project

- [ ] Add Helm charts
- [ ] Implement GitOps with ArgoCD (airgap mode)
- [ ] Add Vault for secrets management
- [ ] Implement service mesh (Linkerd/Istio)
- [ ] Add Falco for runtime security

## 📖 Resources

### Kubernetes & K3s
- [K3s Airgap Installation](https://docs.k3s.io/installation/airgap)
- [Kubernetes NetworkPolicies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

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
