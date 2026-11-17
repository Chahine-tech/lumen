# Vault auto-unseal

Issue #3. The cluster's Vault unseals itself at each start: its root key
is encrypted with a transit key held by a second, small Vault on
`backup-1` (192.168.2.4), outside the cluster. No unseal or recovery key
is stored in Kubernetes.

```
backup-1                                    cluster (vault namespace)
  transit Vault (container vault-transit)     vault-0, vault-1, vault-2
    transit key lumen-vault  <── encrypt/decrypt ──  seal "transit"
    Shamir 2 of 3, unsealed by hand                 token: Secret vault-transit-token
                                                     recovery keys: 3 of 5, offline
```

| What | Where |
|---|---|
| Transit Vault | Ansible role `vault_transit` (Docker on backup-1), image from `mirror.yaml` (`vault/images/vault-1.19.0.tar`) |
| Its certificate | `03-airgap-zone/scripts/infra-ca.sh server`, infrastructure CA ([vault-tls](vault-tls.md)) |
| Its setup | `03-airgap-zone/scripts/vault-transit.sh init / unseal / token` |
| Cluster seal | `seal "transit"` in `vault-helm/values-airgap-override.yaml`, egress in `network-policies/16-allow-vault.yaml` |
| Cluster init and configuration | `03-airgap-zone/scripts/vault-bootstrap.sh`, which streams `vault-configure.sh` into `vault-0` |

The `vault-init` Job, the `vault-init-keys` Secret, `vault-keys.json`,
`04-ansible/unseal.yml` and the role's unseal tasks are gone.

## Keys

| Keys | Holders | Used for |
|---|---|---|
| Transit Vault unseal keys, 2 of 3 | three people, offline | after each restart of backup-1 |
| Cluster Vault recovery keys, 3 of 5 | five people, offline | `vault operator generate-root`, a seal migration |
| Transit token (Secret `vault/vault-transit-token`) | the cluster | encrypt and decrypt with `lumen-vault` only, from the node addresses (`CLUSTER_CIDRS`), periodic 768h |

Both scripts print the keys once and store them nowhere. Both revoke their
root token at the end. A new root token: `vault operator generate-root`,
with the unseal keys (transit Vault) or the recovery keys (cluster Vault).

The transit token is renewed by the cluster's Vault while it runs. If the
cluster stays stopped more than 32 days it expires:
`vault-transit.sh token` replaces it (it asks for a transit Vault token
allowed to create tokens of the role `lumen-autounseal`).

## Day to day

After a restart of backup-1 (`ansible-playbook 04-ansible/start.yml` asks
for it):

```bash
03-airgap-zone/scripts/vault-transit.sh unseal     # 2 keys, input hidden
```

The cluster's Vault needs nothing. A pod that starts while the transit
Vault is sealed or unreachable exits (`error parsing Seal configuration`).
The kubelet restarts it, with a backoff of up to 5 minutes, until the
transit Vault answers; then the pod unseals itself.

## New cluster

In this order:

1. Infrastructure CA and Vault's certificate: [vault-tls](vault-tls.md).
2. The transit Vault's certificate, then the role:
   ```bash
   03-airgap-zone/scripts/infra-ca.sh server ~/.lumen-pki vault-transit IP:192.168.2.4 DNS:vault-transit.airgap.local
   ansible-playbook 04-ansible/site.yml --tags vault
   ```
3. ```bash
   03-airgap-zone/scripts/vault-transit.sh init      # transit keys, the cluster's token
   ```
4. The Vault pods start, uninitialized, and stay unready.
   ```bash
   03-airgap-zone/scripts/vault-bootstrap.sh init    # recovery keys, configuration
   ```
   It waits for the three pods to unseal themselves, then configures Vault
   (`vault-configure.sh`: engines, policies, Kubernetes auth roles, seeded
   secrets) and revokes the root token.

`vault-bootstrap.sh configure` applies `vault-configure.sh` again, with an
admin token.

## Existing cluster: from Shamir to transit

HashiCorp's procedure for Vault 1.5.1 and later, read on the Vault
documentation (seal migration) on 16 November 2026. The pods update
`OnDelete`, and the standbys go first so that Raft keeps its quorum.

1. The transit Vault: steps 2 and 3 of the new cluster.
2. Push. The `vault` Application syncs; the running pods keep their seal.
3. For each standby (`vault operator raft list-peers`):
   ```bash
   kubectl delete pod -n vault vault-2
   kubectl exec -n vault vault-2 -- vault status        # Seal Migration in Progress: true
   kubectl exec -it -n vault vault-2 -- vault operator unseal -migrate   # 3 times, the current unseal keys
   ```
4. On the active pod, with a token: `vault operator step-down`. The new
   active pod migrates the seal (log: `unsealing using migration seal`).
5. Delete the former active pod: it comes back unsealed by itself.
6. Check, then delete the old Secret and the local file:
   ```bash
   kubectl exec -n vault vault-0 -- vault status    # Seal Type transit, Recovery Seal Type shamir
   kubectl delete secret vault-init-keys -n vault
   kubectl delete job vault-init -n vault; kubectl delete configmap vault-init-script -n vault
   rm vault-keys.json
   ```
   The former unseal keys are now the recovery keys.

## Tested

On 16 and 17 November 2026, on k3d (K3s v1.33.6), with the repository's
charts (cert-manager 1.17.1, Vault 1.19.0 HA with 3 pods). The transit
Vault ran in Docker on the host, from the role's configuration template
and with a certificate from `infra-ca.sh server`. The seal address was the
host's (`host.k3d.internal`, then its IP), not 192.168.2.4.

| Case | Result | Control |
|---|---|---|
| `vault-transit.sh init` | keys printed, transit Vault unsealed, Secret created, root token revoked | `init` again: refused |
| Transit token used from another address (127.0.0.1) | | `permission denied` |
| `vault-bootstrap.sh init` | recovery keys printed, 3 pods unsealed by transit, configuration applied, root token revoked | |
| Kubernetes auth configured without `token_reviewer_jwt`: login as `lumen/default` | `lumen-api-policy` | a `gitea` token: `namespace not authorized` |
| A pod deleted | unsealed again, 5s | |
| Node restarted (`docker restart` of the k3d node) | 3 pods unsealed 15s later, no action | |
| Transit Vault sealed, a pod deleted | the pod exits and restarts in a loop | |
| `vault-transit.sh unseal` | the pod unsealed itself 130s later, no action on it | |
| Unseal and recovery keys (8) searched in every Secret of the cluster | none found | one placed in a Secret on purpose: found |
| Migration from the Shamir Vault of `vault-tls`, procedure above | seal `transit`, recovery `shamir`, data written before still read; then all 3 pods deleted at once: unsealed by themselves | |

Two things were found and fixed during the test: `vault status` exits 2
when sealed, which `pipefail` read as "not sealed"; and `docker exec -i`
read the keys meant for `unseal` from the script's stdin.

Not tested:
- the lumen cluster and backup-1;
- the Ansible roles;
- `multipass exec` with stdin;
- the source address of the pods' traffic as seen by backup-1. On k3d it
  was the Docker gateway. On lumen the token is bound to the node
  addresses, on the assumption that Flannel masquerades the pods' traffic
  to them. If it does not, unsealing fails with `permission denied`: widen
  `CLUSTER_CIDRS` and run `vault-transit.sh token`.

## Limits

- **backup-1 is needed to start Vault.** While it is down or its Vault
  sealed, a Vault pod that restarts stays down. Pods that keep running
  should not be affected: per the Vault documentation, only seal wrapping
  (Enterprise) needs the seal after unsealing. Not measured.
- After each restart of backup-1, its Vault is unsealed by hand: no KMS or
  HSM in the airgap.
- Right after all pods restart at once, a request to a standby can be
  redirected to the former leader's address and time out while the
  election settles (seen once in the test).
- PKI: `vault-configure.sh` still tries to import the airgap CA without
  its key, which Vault refuses, as the Job did (issue #7).
