# Upgrade path to Kubernetes 1.34

Why: the PostgreSQL backups (issue #2) need CloudNativePG 1.30, which supports
Kubernetes 1.34 to 1.36. This page lists what else has to move with K3s, and
in which order. Upgrading K3s itself is issue #10.

**Status:** a plan derived from the support tables published by each project,
read on 2026-11-12. Nothing here has been run on the lumen cluster.

## First: which version is actually running?

`04-ansible/group_vars/all.yml` pins `k3s_version: v1.28.5+k3s1`, but several
components deployed on the cluster declare a higher minimum (Kyverno 1.18:
1.33, ArgoCD 3.2.0: 1.30, cert-manager 1.17: 1.29). Either the cluster runs a
newer K3s than `group_vars` says, or these components run outside their
tested range. Check before planning anything:

```bash
multipass exec node-1 -- k3s --version
kubectl get nodes -o wide
```

Then fix `k3s_version` in `group_vars` so it matches reality.

## Support matrix

"Range" is what the project supports or tests, from the source cited. Outside
it a component may still work: it is just not tested.

| Component | Deployed | Range of deployed version | Version for 1.34 | Range | Source |
|---|---|---|---|---|---|
| CloudNativePG | 1.25.1 | 1.29 to 1.32 | 1.30.1 | 1.34 to 1.36 | `docs/src/supported_releases.md` (v1.30.1) |
| cert-manager | 1.17.1 | 1.29 to 1.33 | 1.20 (or 1.21) | 1.32 to 1.35 (1.33 to 1.36) | cert-manager website, releases page |
| ArgoCD | 3.2.0 | 1.30 to 1.33 | 3.2.12 | 1.31 to 1.34 | `docs/operator-manual/tested-kubernetes-versions.md` at each tag |
| Argo Rollouts | 1.8.0 | e2e 1.28 to 1.31 | 1.10.2 | e2e 1.32 to 1.35 | `.github/workflows/testing.yaml` at each tag |
| Kyverno | 1.18.1 | 1.33 to 1.35 | 1.18.1 | 1.33 to 1.35 | kyverno website `installation/releases.md` (commit 049be5c9) |
| Vault Secrets Operator | 1.3.0 | CI 1.31 to 1.35 | 1.3.0 | CI 1.31 to 1.35 | `.github/workflows/build.yaml` (v1.3.0) |
| OPA Gatekeeper | 3.18.0 (end of life) | CI 1.29 to 1.31 | removed | | replaced by Kyverno policies ([gatekeeper-to-kyverno.md](gatekeeper-to-kyverno.md)) |
| Chaos Mesh | 2.7.2 | e2e 1.26 to 1.28 | 2.8.8 | not found | `.github/workflows/e2e_test.yml` (v2.7.2) |
| Prometheus Operator | 0.80.0 | "best effort" through client-go | | | `Documentation/getting-started/compatibility.md` |

Not checked yet: Traefik 3.6.8, Falco 0.43.0, Loki 3.6.5, Tempo, Alloy 1.13,
Vault 1.19.0, MetalLB 0.15.3, Gitea 1.21.5.

Gaps at 1.34:

- **Gatekeeper**: no released version is tested on 1.34 (3.23.1 stops at
  1.33). Resolved by moving the four constraints to Kyverno, which is tested
  on 1.34: [gatekeeper-to-kyverno.md](gatekeeper-to-kyverno.md). Gatekeeper
  has to be uninstalled from the cluster before K3s 1.32.
- **Chaos Mesh**: no published matrix found for 2.8.8.

## Order, from K3s 1.28

Kubernetes, and so K3s, is upgraded one minor version at a time. At each step
every component should be inside its range. The table starts from the worst
case, 1.28; skip the rows below the version actually running.

| K3s step | Then upgrade | Why |
|---|---|---|
| 1.28 → 1.29 | | CNPG 1.25 needs 1.29 or later |
| 1.29 → 1.30 | CNPG 1.26.3 | `upgrade-cnpg.sh 1.26.3` |
| 1.30 → 1.31 | CNPG 1.27.4, ArgoCD 3.2.12, Gatekeeper uninstalled | ArgoCD 3.2.12 starts at 1.31; Gatekeeper 3.18 stops at 1.31 |
| 1.31 → 1.32 | CNPG 1.28.4, Argo Rollouts 1.10.2, cert-manager 1.20 | Rollouts 1.8 stops at 1.31, 1.10 starts at 1.32; cert-manager 1.20 covers 1.32 to 1.35 |
| 1.32 → 1.33 | CNPG 1.29.3 | Kyverno 1.18 is in range from here |
| 1.33 → 1.34 | CNPG 1.30.1, then the Barman Cloud plugin | `docs/runbooks/postgres-backup-restore.md` |

Each component upgrade has its own notes to read first (CRD changes, removed
fields). For the upgrades that skip minor versions (Argo Rollouts 1.8 to 1.10,
cert-manager 1.17 to 1.20), check each project's
upgrade guide for intermediate steps.

The images for every new version have to go through the transit zone first
(`01-connected-zone/scripts/`, `02-transit-zone/`).
