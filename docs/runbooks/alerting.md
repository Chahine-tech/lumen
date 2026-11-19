# Alerting

Issue #23. Alertmanager sends its notifications to ntfy on `backup-1`, outside
the cluster. A dead man's switch there raises the alarm when the alerting chain
itself stops.

```
Prometheus ── alerts ──> Alertmanager (2 replicas, gossip)
                              │  webhook, TLS, bearer token
                              ▼
backup-1                    ntfy :2586
                              ├── lumen-alerts     critical, warning: read by people
                              └── lumen-watchdog   Watchdog, every minute
                                        ▲
                     ntfy-deadman.timer │ every minute: silent for 5 minutes?
                                        └── alarm on lumen-alerts
```

| What | Where |
|---|---|
| Routing, receivers, replicas, storage | `kube-prometheus-stack-helm/values-airgap-override.yaml` |
| ntfy and the dead man's switch | Ansible role `ntfy` |
| Publish token | Vault `lumen/alertmanager-ntfy`, `kube-prometheus-stack/alertmanager-ntfy-vso.yaml` |
| Network | `network-policies/13-allow-kube-prometheus.yaml` |
| Test | `03-airgap-zone/tests/alerting/alerting-test.sh` |

## Routing

| Alert | Receiver | Priority | Repeats |
|---|---|---|---|
| `severity=critical` | `ntfy-critical` | 5 | every hour |
| `severity=warning`, and anything else | `ntfy-warning` | 3 | every 12 hours |
| `severity=info`, `InfoInhibitor` | none | | |
| `Watchdog` | `ntfy-watchdog` | 1 | every minute |

Inhibition:
- a critical alert hides the warning with the same `alertname`, `namespace` and
  `service`;
- `KafkaOfflinePartitions` hides `KafkaUnderReplicatedPartitions`.

Every alert of this repository has a `runbook_url`: `scripts/check/rules.sh`
fails otherwise.

## Access

ntfy refuses anonymous access. Each identity reaches its topics only:

| Identity | `lumen-alerts` | `lumen-watchdog` |
|---|---|---|
| `alertmanager` (token) | write | write |
| `deadman` (token) | write | read |
| `reader` (password) | read | none |

The tokens and passwords are generated once, in `/etc/ntfy/secrets.env` on
`backup-1` (mode 0600).

## Setting it up

After the [infrastructure CA](vault-tls.md#new-cluster) and
`vault-bootstrap.sh`:

```bash
03-airgap-zone/scripts/infra-ca.sh server ~/.lumen-pki ntfy IP:192.168.2.4 DNS:ntfy.airgap.local
ansible-playbook 04-ansible/site.yml --tags ntfy
03-airgap-zone/scripts/seed-ntfy-token.sh
```

The Alertmanager pods wait for the Secret `alertmanager-ntfy`: seed the token
before they start.

## Reading the alerts

The password of `reader`:

```bash
multipass exec backup-1 -- sudo sh -c '. /etc/ntfy/secrets.env; echo "$READER_PASSWORD"'
```

Open `https://192.168.2.4:2586/lumen-alerts` in a browser that trusts the root
of the infrastructure CA, and log in as `reader`. From a terminal:

```bash
curl -s --cacert ~/.lumen-pki/root.crt -u reader:<password> \
  'https://192.168.2.4:2586/lumen-alerts/json?poll=1&since=1h'
```

## Operations

```bash
# What Alertmanager knows
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093 &
curl -s localhost:9093/api/v2/alerts | python3 -m json.tool

# The dead man's switch
multipass exec backup-1 -- systemctl list-timers ntfy-deadman.timer
multipass exec backup-1 -- sudo journalctl -u ntfy-deadman.service -n 20
```

Silence an alert during planned work: `POST /api/v2/silences` on port 9093, or
the Alertmanager UI. Silences are kept on the volumes of the replicas.

**Stopping the lab** with `stop.yml` stops `backup-1` a few seconds after the
cluster, so nothing fires. If `backup-1` stays up while the cluster is down,
the alarm `Lumen alerting is down` is correct, and repeats every hour.

## lumen-api SLO alerts

`LumenAPIAvailability` and `LumenAPILatency` mean that lumen-api burns its
error budget too fast (`03-airgap-zone/slo/lumen-api.yaml`). `critical` burns it
within hours or days, `warning` more slowly.

```bash
kubectl argo rollouts get rollout lumen-api -n lumen   # a rollout in progress?
kubectl logs -n lumen -l app=lumen-api --tail=100
kubectl get pods -n lumen
```

A bad release: `kubectl argo rollouts abort lumen-api -n lumen`, then
[release-v1.7.0, Rollback](release-v1.7.0.md#rollback).

## Vault availability

| Alert | Means | Do |
|---|---|---|
| `VaultPodNotReady` | a pod is sealed or not ready for 2 minutes | `kubectl exec -n vault <pod> -- vault status`. A pod that stays sealed usually cannot reach the transit Vault: [vault-auto-unseal](vault-auto-unseal.md#day-to-day) |
| `VaultRaftFailureToleranceLost` | Raft cannot lose another node | bring the missing pod back first: `vault operator raft list-peers` |
| `VaultQuorumLost` | fewer than 2 pods are ready: Vault serves nothing | check `backup-1` and the transit Vault, then the pods |

## PostgreSQL availability

| Alert | Means | Do |
|---|---|---|
| `PostgresInstanceNotReady` | an instance is not ready for 2 minutes | `kubectl describe pod -n lumen <pod>` |
| `PostgresReplicaMissing` | the primary streams to fewer than 2 replicas | `kubectl get cluster lumen-db -n lumen`, then the logs of the missing instance |
| `PostgresNoPrimary` | no instance, or several, accept writes | `kubectl get pods -n lumen -L cnpg.io/instanceRole`, then the logs of `cnpg-controller-manager` in `cnpg-system` |
| `PostgresFailover` | an instance changed role in the last 10 minutes | find out why the former primary stopped |
| `PostgresReplicationLagHigh` | a replica is more than 5 minutes behind for 5 minutes | check its disk and network |
| `PostgresConnectionsHigh` | above 80% of `max_connections` for 5 minutes | `SELECT usename, state, count(*) FROM pg_stat_activity GROUP BY 1, 2` |

## Redis

| Alert | Means | Do |
|---|---|---|
| `RedisPodNotReady` | a pod is not ready or cannot be scheduled for 2 minutes | `kubectl describe pod -n lumen <pod>` |
| `RedisNoMaster` | no pod, or several, report the master role | [redis](redis.md#operations): ask the Sentinels who the master is |
| `RedisReplicaMissing` | the master has fewer than 2 replicas for 3 minutes | check the missing pod |
| `RedisMasterChanged` | another pod became master in the last 5 minutes | writes not yet replicated were lost: find out why the former master stopped |
| `RedisMemoryHigh` | above 90% of `maxmemory` for 5 minutes | when full, writes are refused and lumen-api answers 503: `redis-cli --bigkeys` |
| `RedisKeysEvicted` | keys were dropped | `maxmemory-policy` must be `noeviction` |

## Certificates

| Alert | Means | Do |
|---|---|---|
| `CertificateExpiringSoon` | less than 14 days left | the renewal fails: `kubectl describe certificate -n <namespace> <name>`, then its `CertificateRequest` |
| `CertificateNotReady` | not ready for 10 minutes | same, and check its issuer: `kubectl get clusterissuer` |
| `CertManagerMetricsAbsent` | no cert-manager metric for 15 minutes | `kubectl get pods -n cert-manager` |

The certificates of hosts outside the cluster (`infra-ca.sh server`: the transit Vault, ntfy) are not issued by cert-manager, and these alerts do not see them.

## ArgoCD and Rollouts

| Alert | Means | Do |
|---|---|---|
| `ArgoCDAppOutOfSync` | what runs differs from git for 15 minutes | a change by hand, or a sync that cannot finish: `kubectl get application -n argocd <name>` |
| `ArgoCDAppUnhealthy` | not `Healthy` or `Progressing` for 10 minutes | the unhealthy resource is in `.status.resources` |
| `ArgoCDSyncFailed` | a sync failed in the last 15 minutes | `.status.operationState.message` |
| `RolloutFailed` | a rollout is in phase `Abort`, `Error` or `Timeout` | `kubectl argo rollouts get rollout -n <namespace> <name>`. An aborted canary leaves the stable version serving: fix and release again, or [release-v1.7.0, Rollback](release-v1.7.0.md#rollback) |
| `ArgoCDMetricsAbsent`, `RolloutMetricsAbsent` | no metrics for 15 minutes | the controller is down, or not scraped |

## Tested

On 18 November 2026, on k3d (K3s v1.33.6, 3 nodes), with the chart and values of
this repository and `13-allow-kube-prometheus.yaml`. An Ubuntu 24.04 machine with
systemd and Docker played `backup-1`, with the templates of the `ntfy` role and a
certificate from `infra-ca.sh server`.

`tests/alerting/alerting-test.sh`:

| Case | Result | Control |
|---|---|---|
| Watchdog | reaches `lumen-watchdog` | |
| Critical and warning alerts | priority 5 and 3 | |
| Two replicas | one notification | |
| Info alert | not notified | the critical alert of the same rule group arrived |
| Warning with a critical twin | not notified | the critical twin arrived |
| Alert resolved | notified | |
| Silence, both replicas restarted | still active | |
| Prometheus stopped | `Lumen alerting is down` from `backup-1` | |
| Prometheus back | `Lumen alerting is back` | |

`tests/alerting/platform-failures-test.sh`, on 18 November 2026, on k3d with a 3-node Vault (Raft, Shamir, no TLS), CloudNativePG 1.30.1 and PostgreSQL 16.6:

| Real failure | Alerts that fired |
|---|---|
| One Vault pod sealed | `VaultPodNotReady`, `VaultRaftFailureToleranceLost`, and not `VaultQuorumLost` |
| Two Vault pods sealed | `VaultQuorumLost` |
| One PostgreSQL replica fenced | `PostgresInstanceNotReady`, `PostgresReplicaMissing` |
| 85 connections held open | `PostgresConnectionsHigh` |
| Primary deleted | `PostgresFailover` |
| Platform healthy, before and after | none of them |

`PostgresNoPrimary` and `PostgresReplicationLagHigh` are covered by promtool tests only.

`tests/alerting/redis-certificates-test.sh`, on 19 November 2026, on the same k3d cluster, with `app/02-redis.yaml`, cert-manager 1.17.1 and the NetworkPolicies of `lumen`, `monitoring` and `cert-manager`:

| Real failure | Alerts that fired |
|---|---|
| A replica lost, its node cordoned | `RedisPodNotReady`, `RedisReplicaMissing` |
| The master lost | `RedisMasterChanged`, with a new master |
| Redis filled to 99% of `maxmemory` | `RedisMemoryHigh` |
| `allkeys-lru`, then more writes | `RedisKeysEvicted` |
| A certificate valid for 48 hours | `CertificateExpiringSoon` |
| A certificate with a missing issuer | `CertificateNotReady` |
| Platform healthy, before and after | none of them |

`RedisNoMaster` and `CertManagerMetricsAbsent` are covered by promtool tests only, and so is a Vault or PostgreSQL pod stuck in `Pending`.

`tests/alerting/argocd-rollouts-test.sh`, on 19 November 2026, on k3d with `argocd/02-install-airgap.yaml`, the Argo Rollouts chart of this repository and the NetworkPolicies of `argocd` and `monitoring`. The test application came from GitHub (`argocd-example-apps`), not from Gitea:

| Real failure | Alerts that fired |
|---|---|
| A broken image set by hand on a synced Deployment | `ArgoCDAppOutOfSync`, `ArgoCDAppUnhealthy` |
| An application whose namespace does not exist | `ArgoCDSyncFailed` |
| A canary whose analysis fails | `RolloutFailed` |
| Healthy, before and after | none of them |

`ArgoCDSyncFailed` for the very first failure of an application, whose counter appears at 1, and the absent metrics alerts are covered by promtool tests only.

Found while testing, in the NetworkPolicies of `main`: Prometheus could reach neither the ArgoCD application controller (8082) nor the kubelets (10250). The application metrics were missing, and so were the container and volume metrics, while `KubeletDown` fired all the time.


Found while testing: a pod that cannot be scheduled has no `Ready` condition, so the "not ready" alerts of Redis, Vault and PostgreSQL also look at the `Pending` phase.


Access to ntfy, by hand: anonymous requests, a wrong token, a topic outside an
identity's rights and plain HTTP are refused; each identity reaches its own.

Found while testing: Prometheus could not scrape the `config-reloader` of
Alertmanager, because of the NetworkPolicy. `TargetDown` and
`AlertmanagerClusterDown` fired all the time. Port 8080 is now open to Prometheus.

Not tested:
- the lumen cluster, `backup-1`, the Ansible role and `seed-ntfy-token.sh`;
- VSO and Vault for the token: the Secret was created by hand;
- a real error budget burn: the test alerts come from test rules;
- the Vault and PostgreSQL alerts with the TLS and transit auto-unseal of lumen: there, a restarted pod unseals itself;
- the switch staying silent until a first Watchdog has arrived;
- the memory of `backup-1` (1 GB) with Garage, the transit Vault and ntfy.

## Limits

- **`backup-1` is a single point of failure for notifications.** While it is
  down, alerts reach nobody and no alarm is raised.
- **Both replicas restarted at once** can lose a pending notification: in the
  test, the resolved notification of a warning alert did not arrive when both
  restarted within seconds of it.
- **Phones** must trust the root of the infrastructure CA to use the ntfy app.
