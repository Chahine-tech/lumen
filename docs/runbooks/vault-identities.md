# Vault identities

Issue #6. Each consumer of Vault logs in as its own ServiceAccount. No
Vault role accepts a `default` ServiceAccount.

| Vault role | ServiceAccount | Used by | Reads |
|---|---|---|---|
| `lumen-api` | `lumen/lumen-vso` | VSO (`vso/02-vault-auth.yaml`) | `lumen/redis`, `lumen/db-runtime` |
| `lumen-db-owner` | `lumen/lumen-db-owner-vso` | VSO | `lumen/db` |
| `cnpg-backup` | `lumen/cnpg-backup-vso` | VSO | `lumen/cnpg-backup` |
| `gitea-runner` | `gitea/gitea-runner-vso` | VSO | `lumen/gitea-runner` |
| `traefik-dashboard` | `traefik/traefik-dashboard-vso` | VSO (`traefik/20-dashboard-auth-vso.yaml`) | `lumen/traefik-dashboard` |
| `grafana-admin` | `monitoring/grafana-admin-vso` | VSO (`kube-prometheus-stack/grafana-admin-vso.yaml`) | `lumen/grafana` |
| `cert-manager` | `cert-manager/cert-manager-vault-auth` | cert-manager (`vault/03-vault-issuer.yaml`) | `pki/sign/airgap-role` |
| `raft-snapshot` | `vault/vault-snapshot` | CronJob `vault-raft-snapshot` | snapshots, `lumen/vault-snapshot` |

Common to every role (`03-airgap-zone/scripts/vault-configure.sh`):
- **Audience `vault`.** VSO requests it (`audiences: [vault]`).
  cert-manager adds it to its own (`serviceAccountRef.audiences`). The
  snapshot CronJob projects it.
- **Tokens of 15 minutes, not one hour.** VSO logs in again when its token
  expires.

Around the roles:
- **No Pod may run as a VSO or cert-manager ServiceAccount**: Kyverno
  policy `lumen-restrict-vault-serviceaccounts`
  (`kyverno-policies/06-restrict-vault-serviceaccounts.yaml`), in every
  namespace the webhook sees. VSO and cert-manager only request tokens for
  them. Without the policy, anyone allowed to create a Pod in `lumen` could
  run it as `lumen-vso` and read what that role reads.
- **cert-manager without a long-lived token**: the `ClusterIssuer` uses
  `serviceAccountRef`. cert-manager requests a token at each login, and a
  `Role` lets its controller do it for `cert-manager-vault-auth` only. The
  Secret `cert-manager-vault-token` is gone.
- **`automountServiceAccountToken: false` on the `default` ServiceAccounts**
  of `lumen`, `gitea`, `traefik`, `vault`, `monitoring`. In these
  namespaces, the workloads that run as `default` are:
  - lumen-api and Redis (`lumen`);
  - Gitea and its runner (`gitea`);
  - the charts' Helm test Pods.

  None of them calls the Kubernetes API (read from the manifests). The
  ServiceAccounts of the VSO roles, cert-manager's and the snapshot's do
  not mount a token either.

lumen-api gets its own ServiceAccount with the authentication work (#18,
PR #37). It does not log in to Vault: VSO gives it its secrets as
environment variables.

## Existing cluster

The roles change in Vault, the ServiceAccounts and `VaultAuth` in git.
Until both are done, VSO cannot log in, but keeps the Secrets it already
synced.

1. Push. ArgoCD syncs the ServiceAccounts, the `VaultAuth` and the Kyverno
   policy.
2. Right after:
   ```bash
   03-airgap-zone/scripts/vault-bootstrap.sh configure    # admin token
   ```
3. cert-manager (not under ArgoCD):
   ```bash
   kubectl apply -f 03-airgap-zone/manifests/vault/03-vault-issuer.yaml
   kubectl delete secret cert-manager-vault-token -n cert-manager
   kubectl get clusterissuer vault-issuer      # Ready, Vault verified
   ```
4. Check:
   ```bash
   kubectl get vaultstaticsecret -A
   kubectl get sa default -n lumen -o jsonpath='{.automountServiceAccountToken}'   # false
   ```
   Pods that were already running keep their mounted token until they
   restart.

On a new namespace, a manifest that holds both the Namespace and its
`default` ServiceAccount fails the first `kubectl apply` with
`AlreadyExists`: Kubernetes creates `default` in between. A second apply
patches it (measured). ArgoCD's retry should do the same; not measured.

## Tested

On 17 November 2026, on k3d (K3s v1.33.6), with the repository's charts
(cert-manager 1.17.1, Vault 1.19.0 HA with TLS and transit auto-unseal,
VSO 1.3.0, Kyverno 1.18.1) and `vault-bootstrap.sh init` of this branch.

| Case | Result | Control |
|---|---|---|
| VSO in `lumen`, `traefik`, `monitoring` with the new ServiceAccounts | the three Secrets synced | |
| Throwaway Pod in `lumen` as `default` | no token mounted | |
| Same, with a projected `default` token (audience `vault`) | `service account name not authorized` | |
| A Pod as `lumen-vso`, without Kyverno | logs in, `lumen-api-policy` | (why the policy is needed) |
| Kyverno: Pods as `lumen-vso`, `grafana-admin-vso`, `cert-manager-vault-auth`, a Deployment as `lumen-vso` (server-side dry run) | denied | a Pod as another ServiceAccount: created |
| `vault-issuer` with `serviceAccountRef` | `Vault verified`, a certificate issued from Vault PKI, no ServiceAccount token Secret in `cert-manager` | RoleBinding removed: `while requesting a token for the service account ... forbidden` |
| Role TTL set to 1 minute, refresh 30s, value changed after 200s | Secret updated, no authentication error in VSO's log | |
| Kyverno CLI tests (`make check-policies`) | 38 pass | condition removed: 4 fail |

Not tested:
- the lumen cluster;
- ArgoCD's first sync of the `default` ServiceAccounts;
- Gitea, the runner, Grafana and Traefik restarted without the `default`
  token (read from their manifests only).
