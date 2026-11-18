# Vault audit log and Raft snapshots

Issue #4.

| What | Where |
|---|---|
| Audit device `stdout/` | `03-airgap-zone/scripts/vault-configure.sh` (step 5) |
| Snapshot CronJob, its NetworkPolicy | `manifests/vault/07-raft-snapshot.yaml` (applied by the Ansible `vault` role) |
| Snapshot role and policy | `vault-configure.sh`: Kubernetes role `raft-snapshot`, ServiceAccount `vault/vault-snapshot` |
| Bucket `lumen-vault-snapshots`, key `lumen-vault-snapshot` | Garage on backup-1, Ansible `garage` role (`garage_buckets`) |
| The key in Vault (`lumen/vault-snapshot`) | `03-airgap-zone/scripts/seed-vault-snapshot-creds.sh` |
| Metrics, alerts | Vault chart ServiceMonitor, `kube-prometheus-stack/vault-rules.yaml`, tests `03-airgap-zone/tests/prometheus/vault-rules.test.yml` |

## Audit log

Every request and response goes to Vault's output, as one JSON line per
entry. Alloy ships the pods' output to Loki. Secret values are HMAC'd: a
read of `lumen/redis` logs the path, the caller and
`"password": "hmac-sha256:..."`, never the password.

```logql
{namespace="vault"} |= `"type":"response"` | json | request_path = "lumen/data/redis"
```

(Query not run: Loki was not part of the test.)

The active pod writes the entries, including those of requests that a
standby forwarded to it.

Why stdout and not a file on its own volume: Vault does not rotate an
audit file, so it would fill its volume. When no audit device can write,
Vault refuses requests. Retention is Loki's (issue #24: none configured
yet).

```bash
kubectl exec -n vault vault-0 -- sh -c 'VAULT_TOKEN=<token> vault audit list'
# stdout/    file    n/a
```

## Snapshots

`vault-raft-snapshot` runs every day at 02:30 UTC, in two steps:
1. **`snapshot`**, with the Vault image:
   - logs in as `vault-snapshot`;
   - runs `vault operator raft snapshot save` against the active pod;
   - reads the Garage key from `lumen/vault-snapshot`;
   - revokes its token.
2. **`upload`**, with rclone 1.75.2: copies the snapshot to
   `s3://lumen-vault-snapshots/vault-<UTC time>.snap` on Garage
   (192.168.2.4:3900), and deletes the snapshots older than 30 days.

The snapshot and the key only exist in a memory `emptyDir` of the pod.

Once, after Garage and Vault are set up:

```bash
ansible-playbook 04-ansible/site.yml --tags garage    # bucket and key
03-airgap-zone/scripts/seed-vault-snapshot-creds.sh   # the key into Vault
kubectl create job -n vault snapshot-now --from=cronjob/vault-raft-snapshot
kubectl logs -n vault -l job-name=snapshot-now -c upload
```

The snapshot is Vault's storage, encrypted by its barrier. Restoring it
needs this Vault's seal, that is the transit key on backup-1 (issue #3).
Garage keeps one copy, on backup-1: a disk lost there takes the snapshots
and the transit key together (#30, off-site copy).

## Restore

Into a running Vault, or a new one after a total loss. The steps below
were rehearsed on k3d (see Tested).

1. Get the snapshot. The key is read on backup-1, since Vault may be gone:
   ```bash
   multipass exec backup-1 -- sudo docker exec -e RUST_LOG=warn garage /garage key info lumen-vault-snapshot --secret-key
   ```
   ```bash
   docker run --rm --entrypoint sh -v "$PWD:/out" \
     -e RCLONE_CONFIG=/dev/null -e RCLONE_CONFIG_G_TYPE=s3 -e RCLONE_CONFIG_G_PROVIDER=Other \
     -e RCLONE_CONFIG_G_ENDPOINT=http://192.168.2.4:3900 -e RCLONE_CONFIG_G_REGION=garage \
     -e RCLONE_CONFIG_G_FORCE_PATH_STYLE=true \
     -e RCLONE_CONFIG_G_ACCESS_KEY_ID=<key id> -e RCLONE_CONFIG_G_SECRET_ACCESS_KEY=<secret key> \
     192.168.2.2:5000/rclone/rclone:1.75.2 -c \
     'f=$(rclone lsf g:lumen-vault-snapshots | tail -1); rclone copyto "g:lumen-vault-snapshots/$f" /out/vault.snap; echo "$f"'
   ```
2. A new Vault (empty volumes): let the pods start, then
   `kubectl exec -n vault vault-0 -- vault operator init` (any recovery
   shares). Its root token is only for the restore. On a running Vault:
   a token allowed to `update` `sys/storage/raft/snapshot-force` (path
   from the Vault API documentation; the test used a root token).
3. Restore:
   ```bash
   kubectl cp vault.snap vault/vault-0:/tmp/vault.snap
   kubectl exec -it -n vault vault-0 -- sh -c 'VAULT_TOKEN=<token> vault operator raft snapshot restore -force /tmp/vault.snap'
   ```
   `-force`: the snapshot comes from another Raft cluster (the one before
   the loss).
4. Vault is now the one of the snapshot: its secrets, roles, audit device
   and tokens. The token and the recovery keys of step 2 are gone with the
   empty Vault: the recovery keys are those of the snapshot's Vault again
   (measured). The pods unseal themselves through the transit Vault.
5. Check: `kubectl get pods -n vault` (3 ready), a known secret, and
   `vault audit list`.

## Alerts

| Alert | When |
|---|---|
| `VaultAuditLogFailure` (critical) | an audit entry failed in the last 5 minutes (`vault_audit_log_request_failure`, `vault_audit_log_response_failure`) |
| `VaultMetricsAbsent` | no `vault_core_unsealed` for 15 minutes: Vault down or sealed, or not scraped |
| `VaultRaftSnapshotTooOld` | last successful run more than 26 hours ago (`kube_cronjob_status_last_successful_time`) |
| `VaultRaftSnapshotNeverSucceeded` | no successful run at all after 26 hours |

Vault serves `/v1/sys/metrics` without a token
(`unauthenticated_metrics_access`), to whoever reaches 8200. The
ServiceMonitor scrapes the active pod over TLS. It sets `serverName` to
the Service name, because the certificate does not name the pod addresses
Prometheus connects to. Notifications: [alerting](alerting.md).

## Tested

On 17 November 2026, on k3d (K3s v1.33.6), with the repository's Vault
chart and the setup of [vault-auto-unseal](vault-auto-unseal.md):
transit Vault in Docker on the host, Garage in Docker from the role's
configuration, and the NetworkPolicies of the `vault` namespace applied
(default deny included). Addresses adapted to k3d.

| Case | Result | Control |
|---|---|---|
| `vault-bootstrap.sh init`, step 5 | `vault audit list`: `stdout/ file` | |
| A read of `lumen/redis` from a standby | request and response logged by the active pod, password `hmac-sha256:...` | |
| Snapshot Job (`kubectl create job --from`) | 32 KB snapshot in `lumen-vault-snapshots`; first login refused (NetworkPolicies not programmed yet), retried | before the retry: 3 pods failed with `connection refused` |
| Retention (30 days set to 30 seconds) | older snapshot deleted, new one kept | |
| Restore into an empty Vault (StatefulSet and volumes deleted, `operator init` with 1 recovery share, `restore -force`) | 36 s to 3 ready pods; marker secret, audit device and roles back; `generate-root` asks for 3 shares again and completes with the snapshot's recovery keys | the empty Vault's root token: `permission denied` after the restore |
| `/v1/sys/metrics` without a token | `vault_audit_log_request_failure`, `vault_audit_log_response_failure`, `vault_core_unsealed` present | |
| kube-state-metrics v2.14.0 | `kube_cronjob_status_last_successful_time{namespace="vault",cronjob="vault-raft-snapshot"}` present after the Jobs | |
| promtool tests of the four alerts | pass | each alert broken in turn: its test fails |

Not tested:
- the lumen cluster, backup-1 and the Ansible tasks;
- Prometheus scraping Vault through the ServiceMonitor (no Prometheus
  Operator on the test cluster), so `serverName` is unverified;
- the audit lines in Loki (Alloy and Loki were not deployed); only their
  presence in the pods' output was checked;
- `seed-vault-snapshot-creds.sh` itself (the key was written by hand with
  the same document).
