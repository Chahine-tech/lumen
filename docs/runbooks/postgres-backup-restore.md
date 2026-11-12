# PostgreSQL backup and restore (lumen-db)

How `lumen-db` is backed up, how to set it up, how to restore it, and how to
prove the restore works.

## How it works

```
lumen-db (CNPG, namespace lumen)
  ├── plugin-barman-cloud sidecar in each instance pod
  │     ├── WAL segments, continuously (at least every 5 min: archive_timeout)
  │     └── base backups, daily at 02:00 UTC (ScheduledBackup lumen-db-daily)
  ▼
Garage on backup-1 (192.168.2.4:3900), bucket lumen-pg-backups
  └── s3://lumen-pg-backups/lumen-db/{base,wals}/
```

| Piece | Where |
|---|---|
| CNPG operator 1.30.1 + Barman Cloud plugin v0.16.0 | `cnpg-system`, installed by `install-cnpg.sh` / `upgrade-cnpg.sh` + `install-cnpg-plugin.sh` |
| `ObjectStore lumen-backups` (endpoint, retention 30d) | `03-airgap-zone/manifests/cnpg/06-object-store.yaml` |
| `ScheduledBackup lumen-db-daily` | `03-airgap-zone/manifests/cnpg/07-scheduled-backup.yaml` |
| S3 credentials: Vault `lumen/cnpg-backup` → VSO → Secret `lumen-db-backup-s3` | `03-airgap-zone/manifests/vso/05-cnpg-backup-secret.yaml` |
| Garage VM `backup-1` | `05-terraform` (VM) + `04-ansible/roles/garage` (service, bucket, key) |
| Alerts | `03-airgap-zone/manifests/kube-prometheus-stack/cnpg-backup-rules.yaml` |
| Restore drill | `03-airgap-zone/scripts/cnpg-restore-drill.sh` |

**Recovery objectives (design values, not measured yet):**

- RPO: up to 5 minutes of writes when the whole cluster is lost (the last WAL
  segment not yet archived). Losing one instance loses nothing: replicas take
  over.
- Recovery window: any point in time during the last 30 days.
- RTO: not measured on the lumen cluster yet. On the k3d test (1 GiB volumes,
  a few MB of data) a full rebuild of the 3-instance cluster took 82s. Real
  numbers go in the drill log below.

**What this does not protect against:**

- Losing `backup-1` or the Mac disk all VMs live on. Garage runs a single node
  with one copy of each object. An off-site copy is the next step (issue #30).
- Deleting backups with the S3 key: it has write access, which includes delete,
  because Barman applies the retention policy itself. Object lock or a second
  copy with separate credentials would close this.
- Clear-text transport: the S3 endpoint is plain HTTP on the airgap LAN (issue #34).

## First-time setup

Order matters. Steps marked **existing cluster** only apply when Vault and
CNPG are already running.

### 1. Connected zone: download

```bash
# From the repository root
(cd 01-connected-zone && ./scripts/12-pull-cnpg.sh)  # operator 1.26.3 to 1.30.1, plugin, images → 01-connected-zone/artifacts/cnpg
./01-connected-zone/scripts/21-pull-garage.sh         # Garage v2.5.0, pinned digest → artifacts/garage
```

Then push the CNPG images to the airgap registry: `02-transit-zone/push-cnpg.sh`.

### 2. Create backup-1

```bash
cd 05-terraform && terraform plan   # must show only additions: backup VM + its cloud-init
terraform apply
```

### 3. Start Garage, create the bucket and the key

```bash
ansible-playbook 04-ansible/site.yml --tags garage
```

The role is safe to run again: it only creates what is missing, and restarts
the container when `garage.toml` or the secrets change.

### 4. Vault policy and role (existing cluster)

On a new cluster the `vault-init` Job creates them. On a running cluster the
Job does not run again, so create them by hand with an admin token (the
bootstrap root token is revoked: `vault operator generate-root`, see
`docs/vault-cert-manager.md`):

```bash
kubectl exec -it -n vault vault-0 -- sh
export VAULT_TOKEN=<admin token>
vault policy write cnpg-backup-policy - <<'EOF'
path "lumen/data/cnpg-backup" {
  capabilities = ["read"]
}
EOF
vault write auth/kubernetes/role/cnpg-backup \
  bound_service_account_names=cnpg-backup-vso \
  bound_service_account_namespaces=lumen \
  policies=cnpg-backup-policy \
  ttl=1h
```

### 5. Commit and push

ArgoCD then syncs `manifests/vso/05-cnpg-backup-secret.yaml` (Application
`vso-config`) and `manifests/kube-prometheus-stack/cnpg-backup-rules.yaml`
(Application `lumen-monitoring-config`).

### 6. Copy the S3 key into Vault

```bash
./03-airgap-zone/scripts/seed-cnpg-backup-creds.sh
```

It reads the key from Garage and writes `lumen/cnpg-backup` through pipes
only, then waits for VSO to create Secret `lumen-db-backup-s3`.

### 7. CNPG operator and plugin

New cluster: `./03-airgap-zone/scripts/install-cnpg.sh` does everything below
(operator, plugin, ObjectStore, Cluster, ScheduledBackup).

Existing cluster: upgrade the operator first (next section), then:

```bash
./03-airgap-zone/scripts/install-cnpg-plugin.sh
kubectl apply -f 03-airgap-zone/manifests/cnpg/06-object-store.yaml
kubectl apply -f 03-airgap-zone/manifests/cnpg/02-cluster.yaml    # adds .spec.plugins: rolling restart
# Wait for the rolling restart AND for WAL archiving before the next command
kubectl wait --for=condition=Ready cluster/lumen-db -n lumen --timeout=600s
kubectl wait cluster/lumen-db -n lumen --timeout=300s \
  --for=jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'=True
kubectl apply -f 03-airgap-zone/manifests/cnpg/07-scheduled-backup.yaml
```

Do not apply `07-scheduled-backup.yaml` together with `02-cluster.yaml`: its
`immediate: true` backup starts at once, lands on an instance that does not
run the plugin sidecar yet, fails with `requested plugin is not available`,
and is not retried before 02:00 UTC. If that happened, delete and re-apply
the ScheduledBackup to trigger the immediate backup again.

### 8. Check

```bash
# WAL archiving: status must be "True"
kubectl get cluster lumen-db -n lumen \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'
# First base backup (immediate: true): phase must reach "completed"
kubectl get backup -n lumen
```

Then run the restore drill.

## Upgrading from CNPG 1.25.1

The Barman Cloud plugin v0.16.0 needs CNPG 1.30 or later. CNPG recommends
upgrading one minor at a time when catching up, and each minor supports a
different range of Kubernetes versions. No single Kubernetes version is
supported by every step (1.26 stops at Kubernetes 1.33, 1.30 starts at 1.34),
so K3s and CNPG upgrades alternate:

| Kubernetes (K3s) | then CNPG | command |
|---|---|---|
| 1.30 | 1.26.3 | `./upgrade-cnpg.sh 1.26.3` |
| 1.31 | 1.27.4 | `./upgrade-cnpg.sh 1.27.4` |
| 1.32 | 1.28.4 | `./upgrade-cnpg.sh 1.28.4` |
| 1.33 | 1.29.3 | `./upgrade-cnpg.sh 1.29.3` |
| 1.34 | 1.30.1 | `./upgrade-cnpg.sh 1.30.1` |

Ranges come from the CNPG support table (`supported_releases.md`, v1.30.1) and
are encoded in `03-airgap-zone/scripts/lib/cnpg-compat.sh`. Every script
checks the running Kubernetes version and stops before a step it does not
support (`ALLOW_UNSUPPORTED_K8S=1` overrides it, at your own risk).

K3s itself is upgraded one minor at a time too, which is outside the scope of
these scripts (issue #10). Other components have to move along the way
(cert-manager, ArgoCD, Argo Rollouts; Gatekeeper is removed): see
[k3s-upgrade-path.md](k3s-upgrade-path.md) for the full order. `04-ansible/group_vars/all.yml` still pins
`k3s_version: v1.28.5+k3s1`, which no plugin-capable CNPG version supports.

Each operator upgrade restarts every PostgreSQL instance: replicas first, then
the primary in place (`primaryUpdateMethod` defaults to `restart`, with a
switchover only when a restart is not possible). lumen-api loses its
connections while the primary restarts and reconnects. `upgrade-cnpg.sh` waits
for `lumen-db` to be healthy before the next step. Observed on the k3d test
(1.29.3 to 1.30.1, 3 instances): all pods recreated with the new instance
manager, primary unchanged, data intact.

## Restore

### Restore drill (point in time, non-destructive)

```bash
./03-airgap-zone/scripts/cnpg-restore-drill.sh        # KEEP=1 to keep the drill cluster
```

It takes a fresh base backup, writes a `before` marker, notes the time T,
writes an `after` marker, waits until that WAL is archived, then restores a
new cluster `lumen-db-restore-drill` to T. It passes only if `before` is
present and `after` is absent, so a restore that ignores the target time
fails. The drill cluster has no `.spec.plugins` and never writes to the
backups. The markers stay in table `restore_drill_marker` of database `app`.

Run it after every change to the backup chain, and at least once a month.

### Disaster: lumen-db is gone

1. Keep `lumen-api` from writing to a half-restored database: disable
   auto-sync on the ArgoCD Application `lumen-app` (otherwise selfHeal undoes
   the next command), delete the HPA `lumen-api`, then
   `kubectl scale rollout lumen-api -n lumen --replicas=0`. Pausing the
   Rollout is not enough: it stops the rollout steps, not the pods.
2. Delete what is left of `lumen-db` (`kubectl delete cluster lumen-db -n lumen`).
3. Create `lumen-db` again from `02-cluster.yaml` with these changes:
   - add a `bootstrap.recovery` from the backups (same shape as
     `manifests/cnpg/restore-drill/02-cluster.yaml`, without `recoveryTarget`
     to replay up to the last archived WAL, or with `targetTime` for a point
     in time), and remove `bootstrap.initdb`;
   - archive to a **new server name**: CNPG refuses to archive into a path
     that already holds WAL (`WAL archive check failed ... Expected empty
     archive`, CNPG recovery docs), and the old path is the one being read:
     ```yaml
     plugins:
       - name: barman-cloud.cloudnative-pg.io
         isWALArchiver: true
         parameters:
           barmanObjectName: lumen-backups
           serverName: lumen-db-r1   # increment on each disaster restore
     ```
   - set `serverName: lumen-db` in the recovery `externalClusters` entry.
4. Wait for `Cluster in healthy state`, then take a base backup right away
   (`kubectl cnpg backup lumen-db -n lumen --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io`,
   or a `Backup` resource as in the drill script).
5. Give lumen-api the new database password. The recovery bootstrap creates
   a new `lumen-db-app` Secret and resets the password of role `app`: the old
   password, the one in Vault `lumen/db` that lumen-api uses, is refused
   (`password authentication failed`, seen on the k3d test). Copy the new
   one into Vault through a pipe (admin token needed):
   ```bash
   # stdin: token on the first line, then the password (never in a command line)
   { printf '%s\n' "$VAULT_TOKEN"
     kubectl get secret lumen-db-app -n lumen -o jsonpath='{.data.password}' | base64 -d
   } | kubectl exec -i -n vault vault-0 -- sh -c \
     'read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200; vault kv patch lumen/db password=-'
   ```
   `kv patch` keeps `username` and `dbname`. VSO updates Secret
   `lumen-db-vault` within `refreshAfter` (1h): restart lumen-api once it has
   changed (`kubectl argo rollouts restart lumen-api -n lumen`).
6. Update `02-cluster.yaml` in git with the new `serverName` (so the next
   restore reads from the right path), then re-enable auto-sync on `lumen-app`:
   ArgoCD restores the HPA and the replicas.

Tested once on a k3d cluster (Kubernetes 1.34.12, CNPG 1.30.1, plugin
v0.16.0, Garage v2.5.0) on 2026-11-12: steps 2 to 5, nothing lost up to the
last archived segment (the last row was written, its WAL segment switched and
archived before the deletion), 82s to a healthy 3-instance cluster, new
archive under `lumen-db-r1/`, old `lumen-db/` untouched. Not run on the lumen
cluster yet.

## Monitoring

| Alert | Fires when |
|---|---|
| `CNPGBaseBackupTooOld` | no successful base backup for 26h (daily schedule + slack) |
| `CNPGBackupMetricsAbsent` | no backup metric at all for 1h (plugin or scrape broken, or no backup ever) |
| `CNPGLastBackupFailed` | the last base backup failed in the plugin (a backup refused before it reaches the plugin leaves the metric at 0: only `CNPGBaseBackupTooOld` sees it) |
| `CNPGWALArchivingFailing` | the last WAL archive attempt failed and none succeeded since |

Unit tests: `make test-alert-rules` (promtool, `03-airgap-zone/tests/prometheus/`).
No Alertmanager receiver exists yet (issue #23): the alerts are only visible in
the Prometheus and Alertmanager UIs.

The CNPG Grafana dashboard already reads the plugin metrics
(`barman_cloud_cloudnative_pg_io_*`) in its backup panels.

## Drill log

| Date | Run ID | Result | Restore time | Notes |
|---|---|---|---|---|
| 2026-11-12 | 20261112133450 | PASS | 56s | k3d test cluster, not lumen. Two negative controls also run: a target after the `after` marker gives FAIL, a target with no later commit stops through the fail-fast check |
| 2026-11-12 | 20261112135147 | PASS | 57s | k3d test cluster, rerun after adding the fail-fast check |
