# Cutover to the main of November 2026

On 17 November 2026, `main` received, while the cluster was down:

| PR | Issue | Changes on the cluster |
|---|---|---|
| #38 | #5 | Vault serves TLS, certificate from an infrastructure CA ([vault-tls](vault-tls.md)) |
| #39 | #3 | Vault auto-unseals through a transit Vault on backup-1 ([vault-auto-unseal](vault-auto-unseal.md)) |
| #40 | #4 | audit log, Raft snapshots to Garage, Vault alerts ([vault-audit-snapshots](vault-audit-snapshots.md)) |
| #41 | #6 | one ServiceAccount per Vault consumer ([vault-identities](vault-identities.md)) |
| #42 | #8 | Redis: one StatefulSet, any pod master ([redis](redis.md)) |
| #37 | #15 to #19, #33 | v1.7.0 step 2 ([release-v1.7.0](release-v1.7.0.md)) and authentication in report mode ([lumen-api-authentication](lumen-api-authentication.md)) |
| branch `kafka` | #44 | `node-3`, three CoreDNS replicas, Kafka and the event stream ([kafka](kafka.md)) |

Each runbook describes its own move from the former state, on its own.
Together they do not fit one ArgoCD sync:

- The Vault pods only change when deleted (`OnDelete`). Its clients (VSO,
  cert-manager, Traefik) switch to `https://` as soon as they sync.
- The new pods need the CA, then the transit Vault, then their egress to
  backup-1.
- The new Redis requires a password on its Sentinels: lumen-api v1.6.0
  gets `NOAUTH` from them. lumen-api v1.7.0 has to run before Redis
  changes, but `main` holds both.
- The step 2 manifests need the v1.7.0 image, which does not exist yet.

So: auto-sync off, then each Application synced by hand, in the order
below. ArgoCD follows Gitea, not GitHub: **nothing goes to Gitea before
step 2**, and `git push-all` (both remotes) is not used until the end.

None of this runbook was run as a whole. Each part was measured on k3d on
16 and 17 November 2026, as its own runbook says. What was not measured is
listed under [Not tested](#not-tested).

## Before, in the connected zone

```bash
python3 scripts/mirror.py pull
```

New in `mirror.yaml` for this cutover: `rclone/rclone:1.75.2`, and
`hashicorp/vault:1.19.0` as a docker archive for backup-1. Bring the
artifacts directory over to the transit host as usual.

Have at hand: the unseal keys of the current Vault (`vault-keys.json`),
and three people for the transit Vault's three unseal keys (2 needed).

## 1. Start the cluster on its former state

The `start.yml` of `main` waits for the transit Vault, which does not
exist yet. Start with the playbook of the commit before #38, which still
unseals with `vault-keys.json`:

```bash
git worktree add ../lumen-before f1d3f00
ln -s "$PWD/vault-keys.json" ../lumen-before/vault-keys.json
ansible-playbook ../lumen-before/04-ansible/start.yml
rm ../lumen-before/vault-keys.json; git worktree remove ../lumen-before
```

Then:

```bash
kubectl get applications -n argocd     # Synced, Healthy
kubectl exec -n vault vault-0 -- vault status | grep -E 'Sealed|Seal Type'   # false, shamir
git fetch gitea && git log --oneline gitea/main..main
```

The last command lists what the cluster has not seen. If it holds commits
older than #38 (`f1d3f00` and before), they go with step 8.

## 2. Freeze ArgoCD, then push to Gitea

```bash
for a in $(kubectl get applications -n argocd -o name); do
  kubectl patch "$a" -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
done
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,AUTO:.spec.syncPolicy.automated
# <none> on every line
```

From here on, an Application changes only when synced by hand:

```bash
# sync APP: as the automated policy did (prune), then its state
sync() {
  kubectl patch application "$1" -n argocd --type merge -p \
    '{"operation":{"initiatedBy":{"username":"cutover"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'
  sleep 20
  kubectl get application "$1" -n argocd \
    -o jsonpath='{.status.operationState.phase} {.status.sync.status} {.status.health.status}{"\n"}'
}
```

(`operation` from the ArgoCD documentation, "Sync Applications with
Kubectl", read on 17 November 2026. The lab has no `argocd` CLI.)

```bash
git push gitea main
```

The `main` pipeline builds and signs the lumen-api image of this source.
The Applications turn OutOfSync and nothing is applied.

## 3. Images

On the transit host:

```bash
python3 scripts/mirror.py push
python3 scripts/mirror.py verify
```

## 4. Vault

An admin token is needed for steps 4.6 and 4.7. The bootstrap root token
was revoked: generate one now, while the unseal keys still are unseal keys
(`vault operator generate-root -init`, then 3 keys, then `-decode`; Vault
documentation). Revoke it at step 4.10.

**4.1 The CA.** [vault-tls, New cluster](vault-tls.md#new-cluster):

```bash
03-airgap-zone/scripts/infra-ca.sh init
03-airgap-zone/scripts/infra-ca.sh apply
03-airgap-zone/scripts/infra-ca.sh server ~/.lumen-pki vault-transit IP:192.168.2.4 DNS:vault-transit.airgap.local
```

**4.2 The transit Vault and the certificates.** The `vault` tag runs the
role `vault_transit` on backup-1, then the role `vault`, which applies
`vault/05-infra-ca.yaml`, `06-vault-tls.yaml` and `07-raft-snapshot.yaml`
and waits for the pods to be unsealed (they are, by step 1).

```bash
ansible-playbook 04-ansible/site.yml --tags vault
kubectl get certificate -A | grep -E 'vault-server-tls|vault-ca'   # all True
03-airgap-zone/scripts/vault-transit.sh init      # transit keys, printed once
kubectl get secret -n vault vault-transit-token
```

**4.3 NetworkPolicies.** The Vault pods' egress to backup-1 must exist
before they restart.

```bash
sync lumen-network-policies
```

This also closes 8080 to Prometheus: lumen-api v1.6.0 metrics stop until
step 6 (issue #17).

**4.4 The chart.** The StatefulSet changes, the running pods do not.

```bash
sync vault
```

**4.5 The pods**, from HTTP and Shamir to TLS and transit, one at a time,
standbys first. Each part was measured on its own
([vault-tls](vault-tls.md#existing-cluster-from-http-to-tls),
[vault-auto-unseal](vault-auto-unseal.md#existing-cluster-from-shamir-to-transit)).
Both in one restart, as here, were not.

```bash
kubectl exec -n vault vault-0 -- vault operator raft list-peers   # who leads
# for each standby:
kubectl delete pod -n vault vault-2
kubectl exec -n vault vault-2 -- vault status        # https, Seal Migration in Progress: true
kubectl exec -it -n vault vault-2 -- vault operator unseal -migrate   # 3 times, the current unseal keys
```

Then the leader:

```bash
kubectl exec -n vault vault-0 -- sh -c 'VAULT_TOKEN=<admin token> vault operator step-down'
kubectl delete pod -n vault vault-0                  # comes back unsealed by itself
kubectl exec -n vault vault-0 -- vault status        # Seal Type transit, Recovery Seal Type shamir
kubectl exec -n vault vault-0 -- vault operator raft list-peers   # 3 peers
```

The former unseal keys are now the recovery keys.

**4.6 The configuration.** Roles with their dedicated ServiceAccounts
(#6), audit device (#4), snapshot role, identity tokens for lumen-api
callers (#18), the runtime database password and the final
`lumen-api-policy` (database migrations, step 1). It asks for the admin
token.

```bash
03-airgap-zone/scripts/vault-bootstrap.sh configure
```

From here until 4.8, VSO cannot log in in the namespaces whose
`VaultAuth` has not synced yet. It keeps the Secrets it already synced.

**4.7 The clients.**

```bash
kubectl apply -f 03-airgap-zone/manifests/vault/03-vault-issuer.yaml
kubectl delete secret cert-manager-vault-token -n cert-manager
kubectl get clusterissuer vault-issuer              # Ready
kubectl apply -f 03-airgap-zone/manifests/vault/01-namespace.yaml \
  -f 03-airgap-zone/manifests/gitea/01-namespace.yaml   # default ServiceAccounts, not under ArgoCD
```

**4.8 VSO and its consumers.**

```bash
sync vault-secrets-operator
sync vso-config
sync traefik
sync lumen-monitoring-config
sync kyverno-policies
kubectl get vaultconnection,vaultauth -A
kubectl get vaultstaticsecret -A                    # synced, after the switch
curl -sk https://vault.airgap.local/v1/sys/health
```

**4.9 Snapshots.**

```bash
ansible-playbook 04-ansible/site.yml --tags garage
03-airgap-zone/scripts/seed-vault-snapshot-creds.sh
kubectl create job -n vault snapshot-now --from=cronjob/vault-raft-snapshot
kubectl logs -n vault -l job-name=snapshot-now -c upload
```

**4.10 Cleanup.** Store the recovery keys (the content of
`vault-keys.json`) offline first.

```bash
kubectl exec -n vault vault-0 -- sh -c 'VAULT_TOKEN=<admin token> vault token revoke -self'
kubectl delete secret vault-init-keys -n vault
kubectl delete job vault-init -n vault; kubectl delete configmap vault-init-script -n vault
rm vault-keys.json
```

## 5. Database, step 1

`vault-configure.sh` (4.6) and `vso-config` (4.8) did steps 1 to 3 of
[database-migrations, Step 1](database-migrations.md#step-1-on-the-existing-cluster).
Step 4, unless done before the cluster went down:

```bash
kubectl apply -f 03-airgap-zone/manifests/cnpg/03-network-policy.yaml
kubectl apply -f 03-airgap-zone/manifests/cnpg/02-cluster.yaml
kubectl get secret -n lumen lumen-db-runtime -o jsonpath='{.type}'; echo
# kubernetes.io/basic-auth
kubectl get cluster lumen-db -n lumen -o jsonpath='{.status.managedRolesStatus}'; echo
# "reconciled":["lumen_runtime"]
```

## 6. lumen-api v1.7.0, with the former Redis

v1.7.0 is the image of `main`: step 2 of the release and the
authentication, in report mode. It runs against the former Redis first: its
client sends the Sentinel password, which the former Sentinels ignore
(measured, [redis, Tested](redis.md#tested)).

A commit puts the former Redis back for this step; step 7 reverts it.

```bash
git checkout f1d3f00 -- 03-airgap-zone/manifests/app/02-redis.yaml
git commit -m "chore(redis): keep the former Redis until lumen-api v1.7.0 runs"
git push gitea main
```

Wait for the `main` pipeline (`build-push`), then the release
([release-v1.7.0, Phase 1](release-v1.7.0.md#phase-1-tag-v170)):

```bash
git tag v1.7.0
git push gitea v1.7.0
git push origin v1.7.0
```

The release commit rewrites the `lumen-api` image lines of
`03-lumen-api.yaml` (Rollout and migration Job) and of
`kafka/05-event-workers.yaml` to `v1.7.0@sha256:<digest>`. The smoke test, in
another file, is pinned by hand:

```bash
git pull gitea main
REF=$(grep -m1 'image: 192.168.2.2:5000/lumen-api:' 03-airgap-zone/manifests/app/03-lumen-api.yaml | awk '{print $2}')
echo "$REF"   # 192.168.2.2:5000/lumen-api:v1.7.0@sha256:...
sed -i '' "s|image: 192.168.2.2:5000/lumen-api:v1.7.0\$|image: $REF|" 03-airgap-zone/manifests/app/06-smoke-test-analysis.yaml
grep -n 'image: 192.168.2.2:5000/lumen-api' 03-airgap-zone/manifests/app/0[36]-*.yaml   # 3 lines, all with the digest
git commit -am "chore: pin the smoke test to the v1.7.0 digest"
git push gitea main
```

```bash
sync lumen-app
kubectl logs -n lumen job/lumen-db-migrate
# the lines of release-v1.7.0 phase 2, and 00002_events_actor
kubectl argo rollouts get rollout lumen-api -n lumen --watch
# Healthy, v1.7.0, smoke test passed
kubectl logs -n lumen -l app=lumen-api --tail=200 | grep "Authentication configured"
# "mode":"report","issuers":2
```

The `sync` call returns while the canary runs: wait for the Rollout.

## 7. Redis

```bash
git revert --no-edit "$(git log -1 --format=%H --grep='keep the former Redis until')"
git push gitea main
sync lumen-app
```

ArgoCD creates the StatefulSet `redis`, points `redis-sentinel` at its
pods and prunes the three former StatefulSets. Then
[redis, Moving from the former topology](redis.md#moving-from-the-former-topology):
the former data is not copied (idempotency records, counters), and its
volume is deleted by hand once the new Redis runs.

```bash
kubectl get pods -n lumen -l app=redis             # redis-0..2, 2/2
kubectl exec -n lumen redis-0 -c sentinel -- sh -c \
  'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" -p 26379 sentinel get-master-addr-by-name mymaster'
curl -sk https://lumen-api.airgap.local/health      # 200 from v1.7.0 in report mode
kubectl delete pvc -n lumen redis-data-redis-master-0
```

## 7b. Kafka

Needs Kubernetes 1.32 or later ([k3s-upgrade-path](k3s-upgrade-path.md)):
check `kubectl get nodes` first. The migration of step 6 has created the
outbox, and `vso-config` (4.8) the credentials of the workers.

```bash
ansible-playbook 04-ansible/provision.yml        # node-3
ansible-playbook 04-ansible/site.yml --tags k3s  # joins node-3, 3 CoreDNS replicas
kubectl get nodes                                 # 3 nodes, Ready
kubectl apply -f 03-airgap-zone/manifests/cnpg/03-network-policy.yaml
kubectl apply -f 03-airgap-zone/manifests/argocd/22-application-strimzi.yaml \
  -f 03-airgap-zone/manifests/argocd/23-application-kafka.yaml
sync strimzi
kubectl rollout status deployment strimzi-cluster-operator -n kafka
sync kafka
kubectl wait kafka/lumen -n kafka --for=condition=Ready --timeout=600s
kubectl get pods -n kafka
kubectl exec -n lumen lumen-db-1 -c postgres -- psql -U postgres -d app -tAc "SELECT count(*) FROM outbox"   # goes to 0
```

The two new Applications come with auto-sync on: patch them as in step 2 if
step 8 is not reached right away.

## 8. The rest, then auto-sync back

```bash
kubectl get applications -n argocd   # every one Synced, Healthy
```

Sync any Application still OutOfSync (commits older than #38, step 1).
Then put the Applications back as in git: auto-sync, and the sync waves
of `vault` and `cert-manager` (#5), which only the Application objects
carry:

```bash
for f in 03-airgap-zone/manifests/argocd/[0-9]*-application-*.yaml; do kubectl apply -f "$f"; done
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,AUTO:.spec.syncPolicy.automated
git push origin main
```

## 9. Checks

| What | How |
|---|---|
| Vault unseals itself | `kubectl delete pod -n vault vault-1`: back ready without a key |
| Snapshots | the Job of 4.9 in `lumen-vault-snapshots` |
| VSO | `kubectl get vaultstaticsecret -A`: all synced |
| lumen-api metrics | `up{namespace="lumen", service="lumen-api"}` is 1 (admin port) |
| Authentication | `sum by (result) (increase(lumen_auth_results_total[1h]))`, `unavailable` at 0 (Vault keys over TLS) |
| Redis failover | `03-airgap-zone/tests/redis/failover-test.sh` (disruptive) |
| Alerts | `VaultMetricsAbsent` not firing |

Then the issues: #3, #4, #5, #6, #8 measured on lumen can be closed.
#18 stays open until `AUTH_MODE=enforce`
([lumen-api-authentication, Phase 2](lumen-api-authentication.md#phase-2-auth_modeenforce)).

## Going back

Until step 8, auto-sync stays off. Re-enabling it would sync `main`, not
go back. Going back is a sync of an earlier revision: the `sync` function
with `"revision":"<commit>"` in `operation.sync`.

- **Before 4.5**: the pods have not changed. A sync of `vault` and
  `lumen-network-policies` at `f1d3f00` restores the former chart and
  rules. The CA, the transit Vault and their Secrets can stay.
- **From 4.5 on**: the seal has moved to transit. Going back to Shamir is
  another seal migration (Vault documentation), not written or tested
  here.
- **Step 6**: [release-v1.7.0, Rollback](release-v1.7.0.md#rollback).
- **Step 7**: revert the revert (former Redis back) and sync `lumen-app`.
  v1.7.0 works with both.

## Not tested

- This runbook as a whole, and the lumen cluster: everything was measured
  on k3d.
- HTTP to TLS and Shamir to transit in the same pod restart (4.5).
- The `start.yml` of `f1d3f00` run from a worktree (step 1).
- The `sync` function: the `operation` comes from the ArgoCD documentation,
  not from a run.
- lumen-api v1.7.0 as a whole against the former Redis (step 6). The
  client against unauthenticated Sentinels was measured, the release was
  not.
- `node-3` joining a running cluster, and step 7b as a whole
  ([kafka, Tested](kafka.md#tested)).
- The source address of the Vault pods' traffic as seen by backup-1: if
  unsealing fails with `permission denied`, see
  [vault-auto-unseal, Not tested](vault-auto-unseal.md#tested).
