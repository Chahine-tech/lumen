# lumen-api authentication

Issue #18. lumen-api identifies the caller of every request from a bearer
JWT and checks the permission of the operation. How it works:
[architecture.md, lumen-api](../architecture.md#12-lumen-api--internal-architecture).

| | |
|---|---|
| Code | `01-connected-zone/app/internal/auth` |
| Issuers and permissions | `03-airgap-zone/manifests/app/07-api-auth.yaml` (ConfigMap `lumen-api-auth`) |
| Mode, rate limit | `AUTH_MODE`, `CALLER_RATE_LIMIT` in the Rollout (`app/03-lumen-api.yaml`) |
| Network | `network-policies/07-allow-api-token-keys.yaml` |
| Vault | `03-airgap-zone/scripts/vault-configure.sh`: AppRole and identity tokens `lumen-client` |

Without a token, every route but the kubelet probes (`/livez`, `/readyz`)
gets 401 in enforce mode, `/health` included. With a token but without the
permission: 403. When the keys of the token's issuer cannot be fetched:
503.

## Callers and permissions

A caller is `<issuer name>:<caller claim>`:

| Issuer | Token | Caller |
|---|---|---|
| `kubernetes` | projected ServiceAccount token, audience `lumen-api` | `kubernetes:system:serviceaccount:<namespace>:<name>` |
| `vault` | Vault identity token of the role `lumen-client` | `vault:<entity name>` |

| Operation | Routes | Callers |
|---|---|---|
| `items:read` | `GET /items`, `GET /items/{id}` | `*` (any authenticated caller) |
| `items:create` | `POST /items` | the smoke test, `vault:lumen-client` |
| `items:delete` | `DELETE /items/{id}` | the smoke test, `vault:lumen-client` |
| `events:read` | `GET /events` | `vault:lumen-client` |

`/hello` and `/health` need a caller, no permission.

Any pod of the cluster can get a token of its own ServiceAccount with the
audience `lumen-api`, so `*` means any workload of the cluster too. An
operation that is not listed is allowed to nobody.

lumen-api reads the file at startup: after a change of
`07-api-auth.yaml`, once ArgoCD has synced it,
`kubectl argo rollouts restart lumen-api -n lumen`.

## Getting a token

### In the cluster

A projected token of the pod's ServiceAccount, audience `lumen-api`:

```yaml
spec:
  serviceAccountName: <name>
  automountServiceAccountToken: false
  volumes:
    - name: lumen-api-token
      projected:
        sources:
          - serviceAccountToken:
              path: token
              audience: lumen-api
              expirationSeconds: 600
  containers:
    - volumeMounts:
        - name: lumen-api-token
          mountPath: /var/run/secrets/lumen-api
          readOnly: true
```

Read the file for each request rather than once
(`Authorization: Bearer <content>`): the kubelet rotates projected tokens
(Kubernetes documentation, not measured here). Then
add `kubernetes:system:serviceaccount:<namespace>:<name>` to the operations
it needs in `07-api-auth.yaml`. The pod also needs a NetworkPolicy to
reach lumen-api on 8080 (`06-allow-smoke-test.yaml` for the smoke test).

### Outside the cluster: Vault

The AppRole `lumen-client` logs in as the entity `lumen-client`. Its token
reads an identity token valid 1 hour (role `lumen-client`, audience
`lumen-api`, claim `entity_name`).

An administrator issues a secret ID and gives it, with the role ID, to the
client:

```bash
kubectl exec -it -n vault vault-0 -- sh
export VAULT_TOKEN=<admin token>
vault read -field=role_id auth/approle/role/lumen-client/role-id
vault write -f -field=secret_id auth/approle/role/lumen-client/secret-id   # valid 30 days
```

The client:

```bash
export VAULT_ADDR=https://vault.airgap.local VAULT_CACERT=03-airgap-zone/airgap-ca.crt
VAULT_TOKEN=$(vault write -field=token auth/approle/login role_id=<role id> secret_id=<secret id>)
TOKEN=$(VAULT_TOKEN=$VAULT_TOKEN vault read -field=token identity/oidc/token/lumen-client)

# The mTLS edge stays: the client certificate and the token
curl --cacert 03-airgap-zone/airgap-ca.crt --cert client.crt --key client.key \
  -H "Authorization: Bearer $TOKEN" https://lumen-api.airgap.local/items
```

Another external caller gets its own entity and AppRole, then
`vault:<entity name>` in `07-api-auth.yaml`. The block "Identity tokens
for lumen-api callers" of `vault-configure.sh` is the model: entity,
AppRole, entity alias with the role ID.

### For a test, from an administrator's workstation

```bash
TOKEN=$(kubectl create token lumen-smoke-test -n lumen --audience lumen-api --duration 10m)
```

This acts as the smoke test, which can create and delete items: whoever
may create tokens for that ServiceAccount (`serviceaccounts/token`, verb
`create`, in `lumen`) has that access.

## Rollout

The code needs migration 2 (`events.actor`), run by the PreSync Job of
[v1.7.0 step 2](release-v1.7.0.md), and a smoke test image that sends a
token. Both are in `main` since 17 November 2026, with this code: phase 1
is the release of v1.7.0, step 6 of
[cutover-november-2026](cutover-november-2026.md).

### Before: Vault on the existing cluster

`vault-configure.sh` holds the block "Identity tokens for lumen-api
callers": `vault-bootstrap.sh init` runs it on a new cluster, and
`vault-bootstrap.sh configure` on a running one, with an admin token
(`vault operator generate-root`, docs/runbooks/vault-auto-unseal.md).

```bash
03-airgap-zone/scripts/vault-bootstrap.sh configure
kubectl exec -n vault vault-0 -- sh -c 'VAULT_TOKEN=<admin token> vault read -format=json identity/oidc/role/lumen-client' | grep -E '"client_id"|"key"'
# "client_id": "lumen-api", "key": "lumen-api"
```

### Phase 1: v1.7.0 with `AUTH_MODE=report`

The release commit rewrites every `lumen-api` image line of
`03-lumen-api.yaml`, the migration Job's included, so the Job applies
migration 2 before the canary. The smoke test, pinned to v1.7.0 by hand,
sends its token; it does not check for a 401 yet.

```bash
kubectl logs -n lumen job/lumen-db-migrate | grep 00002_events_actor
kubectl logs -n lumen -l app=lumen-api --tail=200 | grep "Authentication configured"
# "mode":"report","issuers":2
```

In Prometheus, over the following hours:

```promql
sum by (result) (increase(lumen_auth_results_total[1h]))
```

- `unavailable` must stay at 0: lumen-api cannot fetch the keys (Vault not
  configured, NetworkPolicy). In enforce mode those requests get 503.
- `missing`, `invalid`, `forbidden`: requests enforce would refuse. Move
  their callers to tokens, or add them to the permissions, until they stay
  at 0. The smoke test sends its token; that it adds nothing to these
  counts in report mode was not measured.
  The log line `Auth: request served without a caller (report mode)`
  names the route.

### Phase 2: `AUTH_MODE=enforce`

1. `app/06-smoke-test-analysis.yaml`, which already runs the v1.7.0 image:
   ```yaml
   - name: SMOKE_EXPECT_AUTH
     value: "true"
   ```
   The smoke test then checks that `GET /items` without a token gets 401.
2. `app/03-lumen-api.yaml`: `AUTH_MODE` `enforce`.

The pod template changes, so a canary starts and the smoke test runs
against it, with the token and the 401 check.

### Rollback

- Phase 2: revert the commit, both files: a canary goes back to report
  mode. Reverting `AUTH_MODE` alone would fail the smoke test, which
  expects a 401.
- Phase 1 is the release of v1.7.0:
  [cutover-november-2026, Going back](cutover-november-2026.md#going-back).

## Tested

On 16 November 2026.

Unit tests (`internal/auth`, `internal/app/routes_test.go`, middleware,
handlers, smoke), with `-race`, and each checked to fail when the code it
covers is broken: refused tokens (audience, expiry, no `exp`, `nbf`,
issuer, key, `alg: none`, HMAC with the public key, caller claim), key
rotation, fetch throttling, keys kept while the issuer is down, report
mode, each route's permission, idempotency key per caller, rate limit,
caller in the log and in `events`.

Real tokens, outside the cluster: a Vault 1.19.0 identity token (role and
AppRole above) and a K3s v1.33.6 ServiceAccount token are accepted; with
another audience, or the JWKS fetched without a token, refused.

k3d (K3s v1.33.6), with the repository's NetworkPolicies for `lumen`
(default deny included), `07-api-auth.yaml`, the pod template of the
Rollout and of the smoke test, PostgreSQL and Redis containers, and Vault
in dev mode configured by the identity block, then in the init Job, now in
`vault-configure.sh` (that block, run twice on another dev Vault: no error,
one entity alias):

| Case | Result |
|---|---|
| smoke test with its token, `SMOKE_EXPECT_AUTH=true` | passes |
| smoke test without a token | `health: status 401` |
| `lumen-client` Vault token, `POST /items` | 201 |
| another ServiceAccount: `POST /items`, `GET /events` | 403, 403 |
| another ServiceAccount: `GET /items` | 200 |
| no token, `GET /items`, `GET /health` | 401, 401 |
| no token, `GET /readyz` | 200 |
| `GET /events` | actors `vault:lumen-client` and `kubernetes:system:serviceaccount:lumen:lumen-smoke-test` |
| `07-allow-api-token-keys.yaml` removed | 503, keys unavailable |
| its Vault rule removed | 503 for a Vault token |
| its API server rule on 6443 only | passes: 443 was not needed there |
| report mode, smoke test without a token | passes; `missing` 5, `forbidden` 4 in the metric |

The last four cases (NetworkPolicy, report mode) ran on a first build that
did not require a token on `/health`; the others ran again on the final
build.

Not tested: the lumen cluster itself, the Rollout and its canary (a
Deployment ran the same pod template), Vault in HA mode with its
NetworkPolicies, the client flow through Traefik and the mTLS edge.

## Limits

- Vault's keys are fetched over TLS since #5, checked against the root of
  the infrastructure CA (Secret `vault-ca` of `lumen`). That setup was not
  run with lumen-api: the tests above used Vault in dev mode over HTTP.
- **Dedicated client CA** (proposed in #18): not done. A certificate from
  the cluster CA still passes the mTLS edge, but no longer gives access
  without a token.
- **Rate limit**: a fixed 1 second window, so up to twice the limit across
  a window boundary. Requests without a caller (report mode) are not
  counted.
- **Permissions** are read at startup only.
