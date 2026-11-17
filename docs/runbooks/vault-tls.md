# Vault TLS

Issue #5. Vault serves TLS on its listener (8200) and on its Raft joins,
with a certificate that does not depend on Vault being up.

```
offline root (lumen root CA, 10 years)            ~/.lumen-pki/root.key, never in the cluster
  └── intermediate (lumen infra CA, 5 years)      Secret cert-manager/infra-ca
        └── ClusterIssuer infra-ca                 manifests/vault/05-infra-ca.yaml
              ├── vault-server-tls (vault, 1 year)  Vault's listener, mounted by the pods
              └── vault-ca (5 namespaces)           ca.crt = the root, for the clients
```

| Client | Trusts the root through |
|---|---|
| Vault pods (`vault` CLI with `kubectl exec`, Raft `retry_join`) | `VAULT_CACERT`, `leader_ca_cert_file`: `/vault/userconfig/vault-server-tls/ca.crt` |
| `vault-bootstrap.sh` (issue #3: `kubectl exec` in `vault-0`) | the pods' `VAULT_CACERT` |
| VSO (`lumen`, `gitea`, `monitoring`, `traefik`) | `VaultConnection.spec.caCertSecretRef: vault-ca` |
| cert-manager `vault-issuer` | `caBundleSecretRef`: `cert-manager/vault-ca` |
| Traefik, for `vault.airgap.local` | `ServersTransport vault-tls`: it terminates the client's TLS and opens a new one to Vault |

The `vault-ca` certificates exist only for their `ca.crt`, which
cert-manager keeps equal to the root. Their only extended key usage is
email protection, so TLS clients and servers refuse them.

Why a root kept off the cluster: the root signs intermediates only, so an
intermediate can be replaced without touching the clients, which trust the
root. Issue #7 (one PKI for the cluster) can build on the same root.

## New cluster

Before the Vault pods can start (they wait for the Secret
`vault-server-tls`):

```bash
03-airgap-zone/scripts/infra-ca.sh init            # root and intermediate in ~/.lumen-pki
03-airgap-zone/scripts/infra-ca.sh apply           # Secret cert-manager/infra-ca
# then move ~/.lumen-pki/root.key offline (USB key, password manager)
```

The Ansible `vault` role checks for that Secret, applies
`vault/05-infra-ca.yaml` and `vault/06-vault-tls.yaml`, then waits for the
pods (auto-unseal, [vault-auto-unseal](vault-auto-unseal.md)). By hand:

```bash
kubectl apply -f 03-airgap-zone/manifests/vault/05-infra-ca.yaml \
  -f 03-airgap-zone/manifests/vault/06-vault-tls.yaml
kubectl get certificate -A | grep -E 'vault-server-tls|vault-ca'   # all True
```

`infra-ca.sh apply` runs `kubectl` through `multipass exec node-1` by
default (`KUBECTL=kubectl` to use a local one), and sends the Secret on
stdin. Whether `multipass exec` passes stdin through was not tested (the
seed scripts depend on it too).

## Existing cluster: from HTTP to TLS

The StatefulSet updates `OnDelete`: syncing the chart changes nothing
until a pod is deleted. Each pod comes back sealed and is unsealed by hand
(#3). Standbys first, the leader last: quorum holds throughout.

ArgoCD syncs the clients (`vso-config`, `lumen-monitoring-config`,
`traefik`) as soon as the change is pushed: from then on they use
`https://`, which the pods serve only once restarted. Do step 1 before the
push, and step 3 right after it: VSO and cert-manager retry until then.

1. The CA and the certificates, as for a new cluster above.
2. Push. The `vault` Application syncs, the pods keep serving HTTP.
3. For each standby, then the leader:
   ```bash
   kubectl exec -n vault vault-0 -- vault operator raft list-peers   # who leads
   kubectl delete pod -n vault vault-2
   kubectl exec -n vault vault-2 -- printenv VAULT_ADDR              # https://127.0.0.1:8200
   kubectl exec -it -n vault vault-2 -- vault operator unseal         # 3 times, 3 keys
   ```
4. Apply `vault/03-vault-issuer.yaml` (not under ArgoCD).
5. Check:
   ```bash
   kubectl get vaultconnection -A            # Ready
   kubectl get clusterissuer vault-issuer    # Ready
   kubectl get vaultstaticsecret -A          # synced since the switch
   curl -sk https://vault.airgap.local/v1/sys/health
   ```

## Renewal

cert-manager renews `vault-server-tls` 30 days before it expires (1 year).
**Vault does not reload it by itself**: measured, still serving the old
certificate 110s after the file in the pod had changed. A `SIGHUP` to the
`vault` process reloads it. PID 1 of the pod is the chart's `sh`, which
does not pass the signal on: send it to `vault`.

```bash
kubectl get certificate -n vault vault-server-tls -o jsonpath='{.status.renewalTime}'; echo
# after that date, within the 30 days:
for p in vault-0 vault-1 vault-2; do
  kubectl exec -n vault $p -- sh -c 'kill -HUP $(pidof vault)'
done
echo | openssl s_client -connect vault.vault.svc.cluster.local:8200 2>/dev/null | openssl x509 -noout -enddate
```

The intermediate expires after 5 years and the root after 10: `infra-ca.sh`
does not renew them yet.

## Tested

On 16 November 2026, k3d (K3s v1.33.6), with the repository's charts and
manifests (cert-manager 1.17.1, Vault 1.19.0 HA with 3 pods, VSO 1.3.0),
images pulled as `192.168.2.2:5000/...` through a registry mirror:

| Case | Result | Control |
|---|---|---|
| `infra-ca.sh init`, `apply` | root, intermediate, Secret; certificates Ready, `ca.crt` equal to the root, chain verifies | `init` again: refused, the root is kept |
| Raft, 3 pods over TLS | 3 peers, all ready | |
| `vault` CLI in the pods (`kubectl exec`), the seed scripts' `kv put` | works over `https://127.0.0.1:8200` | |
| `vault-init` pod spec (Job removed since, issue #3), `vault status` | OK | without `VAULT_CACERT`: `x509` error |
| Plain HTTP to 8200 | 400 | |
| VSO, `vso/01`, `02` and `04`: `VaultStaticSecret` synced | OK | without `caCertSecretRef`: `x509: certificate signed by unknown authority` |
| `vault-issuer` with `caBundleSecretRef`, a certificate from Vault PKI | Ready, issued | without it: TLS verification error |
| Traefik to the UI through `vault-tls` | Vault answers (`/v1/sys/health`: 429, unsealed standby) | without `rootCAs`: 500 |
| Migration from the chart of `main` (HTTP), standbys then leader | all three on https, unsealed, data written before still read, leader moved | |
| Renewal | new certificate in the Secret and the pod's file; served only after `SIGHUP` to `vault` | `SIGHUP` to PID 1: old certificate still served |

Traefik was the one K3s bundles (3.5.1), not the chart of this repository
(3.6.8). Not tested: the lumen cluster, the Ansible tasks, `multipass
exec` with stdin, Grafana and the Gitea runner's VSO resources (same
`VaultConnection` change as `lumen`), NetworkPolicies (port unchanged).

## Limits

- **Manual reload** once a year (above). Nothing alerts on it yet (#25).
- The `vault-init` Job could not complete on a new cluster (it called
  `kubectl` and `python3`, which the Vault image lacks). Replaced by
  `vault-bootstrap.sh` in issue #3 ([vault-auto-unseal](vault-auto-unseal.md)).
- The pods' `VAULT_API_ADDR` is `https://<pod IP>:8200`, and the
  certificate has no IP but 127.0.0.1: a client that followed a redirect to
  that address would fail verification. Not seen in the tests, not
  measured either.
- lumen-api (branch `api-auth`, #18) fetches Vault's token keys over
  `http://`: to switch to `https://` with the `vault-ca` Secret of `lumen`
  once both are merged.
