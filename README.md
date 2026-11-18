# Lumen — Airgap Kubernetes Lab

A hands-on project to learn distributed systems and Kubernetes by building a production-grade airgap environment on local VMs.

See [docs/architecture.md](docs/architecture.md) for the full system overview.

> **`main` is ahead of the lab.** Vault TLS and auto-unseal, the new Redis, `node-3` and Kafka are merged and tested on k3d, and not deployed on the Multipass cluster yet. The deployment follows the [cutover runbook](docs/runbooks/cutover-november-2026.md).

## Stack

| Layer | Components |
|---|---|
| API | Go 1.26, stdlib net/http, idempotency middleware, bearer JWT authentication |
| Cluster | K3s (arm64, 1 server + 2 agents), Flannel, MetalLB, Traefik v3 |
| Databases | Redis 7 HA Sentinel + PostgreSQL 16 (CloudNativePG) |
| Messaging | Kafka 4.3 (Strimzi, KRaft), transactional outbox, idempotent consumer |
| Observability | Prometheus + Grafana + Loki + Alloy + Tempo + OpenTelemetry |
| Security | Kyverno (registry, tags, resources in `lumen` and `kafka`; labels and Cosign signatures in `lumen`) + PSS + NetworkPolicies + Falco |
| Secrets / TLS | Vault HA (Raft, TLS, transit auto-unseal, audit log, snapshots) + cert-manager + VSO + mTLS at the edge |
| GitOps / CI | ArgoCD + Gitea Actions + Argo Rollouts (canary) |
| Resilience | Chaos Mesh (PodChaos, NetworkChaos) |
| IaC | Terraform (Multipass VMs) + Ansible (bootstrap, start/stop) |

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
The `vault` step needs an infrastructure CA and a transit Vault, and Vault is initialized once by hand: follow [New cluster](docs/runbooks/vault-auto-unseal.md#new-cluster).

**Local API development**
```bash
make build-connected
make test-api-local
```

**After a reboot**
```bash
ansible-playbook 04-ansible/start.yml --ask-become-pass
```
It asks for the transit Vault on `backup-1` to be unsealed (`03-airgap-zone/scripts/vault-transit.sh unseal`).

## Services

| URL | Credentials |
|---|---|
| https://argocd.airgap.local | admin / from secret |
| https://gitea.airgap.local | gitea-admin / from your password manager (`GITEA_ADMIN_PASSWORD`) |
| https://grafana.airgap.local | admin / from Vault (`lumen/grafana`) |
| https://prometheus.airgap.local | — |
| https://vault.airgap.local | — |
| https://traefik.airgap.local/dashboard/ | admin / from Vault (`lumen/traefik-dashboard`) |
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
- [Event log](docs/event-log.md): the `events` table of lumen-api
- [Mirroring](docs/mirroring.md): images and charts into the airgap zone

## Runbooks

| Area | Runbooks |
|---|---|
| Deployment | [Cutover of November 2026](docs/runbooks/cutover-november-2026.md), [release v1.7.0](docs/runbooks/release-v1.7.0.md), [K3s upgrade path](docs/runbooks/k3s-upgrade-path.md) |
| Vault | [TLS](docs/runbooks/vault-tls.md), [auto-unseal](docs/runbooks/vault-auto-unseal.md), [audit and snapshots](docs/runbooks/vault-audit-snapshots.md), [identities](docs/runbooks/vault-identities.md) |
| Data | [Kafka](docs/runbooks/kafka.md), [Redis](docs/runbooks/redis.md), [PostgreSQL backup and restore](docs/runbooks/postgres-backup-restore.md), [database migrations](docs/runbooks/database-migrations.md) |
| lumen-api | [Authentication](docs/runbooks/lumen-api-authentication.md), [admin port](docs/runbooks/lumen-api-admin-port.md), [smoke test](docs/runbooks/lumen-api-smoke-test.md) |
| Security | [Rotating leaked credentials](docs/runbooks/rotate-leaked-credentials.md), [Gatekeeper to Kyverno](docs/runbooks/gatekeeper-to-kyverno.md) |

## Known Limitations

- One K3s control plane, and volumes tied to one node ([#9](https://github.com/Chahine-tech/lumen/issues/9)).
- `group_vars` pins K3s v1.28.5, older than what several components support ([#10](https://github.com/Chahine-tech/lumen/issues/10), [upgrade path](docs/runbooks/k3s-upgrade-path.md)).
- The registry has no TLS or authentication ([#11](https://github.com/Chahine-tech/lumen/issues/11)).
- Alertmanager has no receiver: alerts fire and reach nobody ([#23](https://github.com/Chahine-tech/lumen/issues/23)).
- Admission policies cover part of the namespaces ([#26](https://github.com/Chahine-tech/lumen/issues/26)).
- The administrative UIs have no SSO ([#27](https://github.com/Chahine-tech/lumen/issues/27)).
- Most traffic between services inside the cluster is not encrypted ([#34](https://github.com/Chahine-tech/lumen/issues/34)).

## Common Commands

```bash
make help          # all available targets
make status        # cluster status
make logs-api      # API logs
```
