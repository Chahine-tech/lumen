# Lumen — Airgap Kubernetes Lab

A hands-on project to learn distributed systems and Kubernetes by building a production-grade airgap environment on local VMs.

See [docs/architecture.md](docs/architecture.md) for the full system overview.

## Stack

| Layer | Components |
|---|---|
| API | Go 1.26, stdlib net/http, idempotency middleware |
| Cluster | K3s (arm64), Flannel, MetalLB, Traefik v3 |
| Databases | Redis 7 HA Sentinel + PostgreSQL 16 (CloudNativePG) |
| Observability | Prometheus + Grafana + Loki + Alloy + Tempo + OpenTelemetry |
| Security | OPA Gatekeeper + PSS + NetworkPolicies + Falco + Cosign |
| Secrets / TLS | Vault HA (Raft) + cert-manager + VSO + mTLS |
| GitOps / CI | ArgoCD + Gitea Actions + Argo Rollouts (canary) |
| Resilience | Chaos Mesh (PodChaos, NetworkChaos) |
| IaC | Terraform (Multipass VMs) + Ansible (bootstrap, unseal, start/stop) |

## Prerequisites

- Docker + Docker Compose
- kubectl + Helm
- Go 1.26+
- Terraform 1.5+ + Multipass
- Ansible 2.14+

## Getting Started

**Provision VMs (one-time)**
```bash
multipass set local.bridged-network=en0
cd 05-terraform && terraform init && terraform apply
```

**Bootstrap the cluster**
```bash
ansible-playbook 04-ansible/site.yml --ask-become-pass
```

**Local API development**
```bash
make build-connected
make test-api-local
```

**After a reboot**
```bash
ansible-playbook 04-ansible/start.yml --ask-become-pass
```

## Services

| URL | Credentials |
|---|---|
| https://argocd.airgap.local | admin / from secret |
| https://gitea.airgap.local | gitea-admin / gitea-admin |
| https://grafana.airgap.local | admin / admin |
| https://prometheus.airgap.local | — |
| https://vault.airgap.local | — |
| https://traefik.airgap.local/dashboard/ | admin / admin |
| https://lumen-api.airgap.local | — |
| https://chaos-mesh.airgap.local | — |

## Documentation

- [Architecture](docs/architecture.md) — zones, components, IaC overview
- [Concepts](docs/concepts.md) — how things work: K8s networking, TLS, eBPF, GitOps, Vault, Chaos...
- [Databases](docs/databases.md) — Redis HA Sentinel + CloudNativePG
- [CI/CD](docs/cicd.md) — Gitea Actions + Argo Rollouts canary
- [Security](docs/security.md) — 5-layer defense in depth
- [Vault & cert-manager](docs/vault-cert-manager.md) — Vault HA, PKI, VSO, mTLS
- [Monitoring](docs/monitoring.md) — kube-prometheus-stack, Loki, Tempo

## Common Commands

```bash
make help          # all available targets
make status        # cluster status
make logs-api      # API logs
```
