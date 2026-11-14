# Database schema migrations

How the `lumen-db` schema changes, who may change it, and how a change ships
through a canary.

## How it works

```
git push ─▶ ArgoCD sync of lumen-app
              │
              ├─ PreSync hook: Job lumen-db-migrate
              │    lumen-api migrate, as app (owner of the database)
              │    1. advisory lock (one run at a time)
              │    2. pending migrations, each in a transaction
              │    3. grants DML to lumen_runtime
              │    fails ─▶ the sync fails, the Rollout is not touched
              │
              └─ Rollout lumen-api (canary 20% ─▶ 80% ─▶ 100%)
                   runs as lumen_runtime (DML only), checks the schema
                   version at startup
```

- **Migrations**: SQL files embedded in the image,
  `01-connected-zone/app/internal/migrations/sql/NNNNN_name.sql`, applied by
  [goose](https://github.com/pressly/goose) v3.26.0. Applied versions are
  recorded in the table `goose_db_version`.
- **Roles**:

  | Role | Rights | Vault path | Secret | Used by |
  |---|---|---|---|---|
  | `app` | owner of the database (CNPG `initdb.owner`) | `lumen/db` | `lumen-db-vault` | migration Job |
  | `lumen_runtime` | `SELECT, INSERT, UPDATE, DELETE` on the tables, `USAGE, SELECT` on the sequences, read-only on `goose_db_version` | `lumen/db-runtime` | `lumen-db-runtime` | lumen-api |

  `lumen_runtime` is a CNPG managed role (`cnpg/02-cluster.yaml`,
  `spec.managed.roles`). Its password comes from Vault through VSO
  (`vso/03-lumen-db-secret.yaml`). The Secret carries the label
  `cnpg.io/reload`, so CNPG watches it and applies a new password (70s from
  the Secret change to PostgreSQL, measured once on k3d with CNPG 1.30.1).
  `lumen-api migrate` grants the rights after each run, so new tables are
  covered. It also revokes `TEMPORARY` from `PUBLIC`. The owner credentials
  are synced through a dedicated ServiceAccount and Vault role
  (`lumen-db-owner`), so a pod running as `default` in lumen cannot read them.
- **Startup check**: lumen-api reads `goose_db_version` and refuses to start
  when the schema is older than the newest migration in its image. It means
  the Job failed or did not run. A newer schema is accepted: that is the old
  version during a canary, or after a rollback.

## Status: two steps

The deployed image (v1.6.0) creates the schema itself at startup, as the
owner, and has no `migrate` command. It cannot run as `lumen_runtime`
(measured: `permission denied for schema public` on its `CREATE TABLE IF NOT
EXISTS`). So the change ships in two steps:

- **Step 1 (this repository now)**: code, roles, Vault paths, VSO Secrets,
  network policy. lumen-api still runs as `app`.
- **Step 2, after the first release that contains `lumen-api migrate`**: the
  PreSync Job, and lumen-api switches to `lumen_runtime`. See
  [Step 2](#step-2-after-the-release).

## Step 1 on the existing cluster

On a new cluster the `vault-init` Job creates the policies, the role and the
`lumen/db-runtime` password. On a running cluster it does not run again: do
it by hand, with an admin token (the bootstrap root token is revoked:
`vault operator generate-root`, see `docs/vault-cert-manager.md`).

### 1. Vault: owner role, runtime password

Keep `lumen/data/db` in `lumen-api-policy` for now: until the manifests below
are synced, VSO still reads the owner credentials with it.

```bash
kubectl exec -it -n vault vault-0 -- sh
export VAULT_TOKEN=<admin token>

vault policy write lumen-db-owner-policy - <<'EOF'
path "lumen/data/db" {
  capabilities = ["read"]
}
EOF
vault write auth/kubernetes/role/lumen-db-owner \
  bound_service_account_names=lumen-db-owner-vso \
  bound_service_account_namespaces=lumen \
  policies=lumen-db-owner-policy \
  ttl=1h

vault policy write lumen-api-policy - <<'EOF'
path "lumen/data/db" {
  capabilities = ["read"]
}
path "lumen/data/db-runtime" {
  capabilities = ["read"]
}
path "lumen/data/redis" {
  capabilities = ["read"]
}
EOF

# The password is generated in the pod and never leaves it
P=$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-32)
[ ${#P} -eq 32 ] && printf '%s' "$P" | vault kv put lumen/db-runtime username=lumen_runtime password=-
vault kv get -field=password lumen/db-runtime | wc -c   # 32
unset P
```

### 2. Push, and let ArgoCD sync `vso-config`

Then check that VSO syncs both Secrets, the owner one through its new
VaultAuth:

```bash
kubectl get vaultstaticsecret -n lumen lumen-db-credentials lumen-db-runtime-credentials
kubectl get secret -n lumen lumen-db-runtime -o jsonpath='{.type} {.metadata.labels}'; echo
# kubernetes.io/basic-auth {..."cnpg.io/reload":"true"...}
```

### 3. Remove the owner path from `lumen-api-policy`

```bash
vault policy write lumen-api-policy - <<'EOF'
path "lumen/data/db-runtime" {
  capabilities = ["read"]
}
path "lumen/data/redis" {
  capabilities = ["read"]
}
EOF
```

Check that `lumen-db-credentials` keeps syncing (an event `SecretSynced`, no
`permission denied` in `kubectl describe vaultstaticsecret -n lumen
lumen-db-credentials`).

### 4. Apply the CNPG manifests

The Cluster and its network policies are applied by `install-cnpg.sh`, not
by ArgoCD:

```bash
kubectl apply -f 03-airgap-zone/manifests/cnpg/03-network-policy.yaml
kubectl apply -f 03-airgap-zone/manifests/cnpg/02-cluster.yaml
kubectl get cluster lumen-db -n lumen -o jsonpath='{.status.managedRolesStatus}'; echo
# "byStatus":{..."reconciled":["lumen_runtime"]...}
```

Adding a managed role did not restart PostgreSQL on k3d (CNPG 1.30.1, the
lab runs 1.25.1): same `pg_postmaster_start_time`, no container restart. The
role was created 1s after its Secret appeared; before that the Cluster stays
healthy and reports the role under `cannotReconcile`.

## Step 2, after the release

Once a release built from this code is deployed (the CI release step bumps
the image in `03-lumen-api.yaml`):

### 1. Add the Job to `03-airgap-zone/manifests/app/03-lumen-api.yaml`

In this file, not another one: the CI release step rewrites every
`image: 192.168.2.2:5000/lumen-api:` line of this file only, so the Job and
the Rollout stay on the same image.

```yaml
---
# Schema migration, before every sync of lumen-app: ArgoCD runs this PreSync
# hook and applies the Rollout only once it has succeeded.
# docs/runbooks/database-migrations.md
apiVersion: v1
kind: ServiceAccount
metadata:
  name: lumen-db-migrate
  namespace: lumen
automountServiceAccountToken: false

---
apiVersion: batch/v1
kind: Job
metadata:
  name: lumen-db-migrate
  namespace: lumen
  labels:
    app: lumen-db-migrate
    tier: backend
  annotations:
    argocd.argoproj.io/hook: PreSync
    # Keep the last Job (and its logs) until the next sync replaces it
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 0             # a failed migration fails the sync; ArgoCD retries the sync
  activeDeadlineSeconds: 600  # the advisory lock waits up to 5 min for another run
  template:
    metadata:
      labels:
        app: lumen-db-migrate   # not lumen-api: kept out of the Services and the PDB
        tier: backend
    spec:
      serviceAccountName: lumen-db-migrate
      restartPolicy: Never
      containers:
        - name: migrate
          # Same image as the Rollout (see above)
          image: 192.168.2.2:5000/lumen-api:<release>
          args: ["migrate"]
          env:
            # Owner of the database (Vault lumen/db)
            - name: PG_USER
              valueFrom:
                secretKeyRef:
                  name: lumen-db-vault
                  key: username
            - name: PG_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: lumen-db-vault
                  key: password
            - name: PG_DBNAME
              valueFrom:
                secretKeyRef:
                  name: lumen-db-vault
                  key: dbname
            - name: PG_MIGRATE_DSN
              value: "postgresql://$(PG_USER):$(PG_PASSWORD)@lumen-db-rw.lumen.svc.cluster.local:5432/$(PG_DBNAME)"
            - name: PG_RUNTIME_ROLE
              value: lumen_runtime
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 500m
              memory: 128Mi
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
```

### 2. Switch lumen-api to `lumen_runtime`

In the Rollout of the same file, `PG_USER` and `PG_PASSWORD` come from
`lumen-db-runtime`, and `PG_DBNAME` (not a secret) from the ConfigMap:

```yaml
            - name: PG_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: lumen-db-runtime
                  key: password
            - name: PG_USER
              valueFrom:
                secretKeyRef:
                  name: lumen-db-runtime
                  key: username
            - name: PG_DBNAME
              valueFrom:
                configMapKeyRef:
                  name: lumen-api-config
                  key: PG_DBNAME
```

with `PG_DBNAME: "app"` added to `lumen-api-config`. The same commit can
switch the probes to `/livez` and `/readyz` (#16, comment in the file).

### 3. Check

```bash
kubectl logs -n lumen job/lumen-db-migrate
# "Migration applied" version 1, "Schema up to date", "Runtime role granted DML rights"
kubectl logs -n lumen -l app=lumen-api --tail=50 | grep -i schema   # nothing: no warning, no error
kubectl exec -n lumen lumen-db-1 -c postgres -- \
  psql -d app -c "SELECT version_id, tstamp FROM goose_db_version ORDER BY id"
```

## Writing a migration

1. A new file in `internal/migrations/sql/`, numbered after the last one:
   `00002_items_description.sql`.

   ```sql
   -- +goose Up
   ALTER TABLE items ADD COLUMN description TEXT;

   -- +goose Down
   ALTER TABLE items DROP COLUMN description;
   ```

   Each file runs in a transaction. A statement that cannot (`CREATE INDEX
   CONCURRENTLY`) needs `-- +goose NO TRANSACTION` at the top of the file.
2. Run the tests against a real PostgreSQL (below).
3. Release. The Job applies it, then the canary starts.

### Expand and contract

During a canary, and after a rollback, the previous version runs against the
new schema. Every migration must keep the previous version working. A
breaking change is split over several releases:

| Change | Release N (expand) | Release N+1 | Release N+2 (contract) |
|---|---|---|---|
| Add a column | nullable, or with a default | code writes and reads it | `SET NOT NULL` if needed |
| Rename a column | add the new column, code writes both | backfill, code reads the new one | drop the old column |
| Drop a column | code stops reading and writing it | drop the column | |
| Drop a table | code stops using it | drop the table | |

`TestStoreWorksAfterExpandMigration` checks the first row: the store of this
version keeps working after an added nullable column. The same test with a
rename instead fails.

### Locks

`ALTER TABLE` takes an `ACCESS EXCLUSIVE` lock: on a busy table it waits for
running queries, and every new query waits behind it. Prefer the forms that
do not rewrite the table (`ADD COLUMN` without a volatile default, `CREATE
INDEX CONCURRENTLY`), and set a timeout at the top of the migration so that
it fails instead of blocking the API:

```sql
-- +goose Up
SET lock_timeout = '5s';
ALTER TABLE items ADD COLUMN description TEXT;
```

## When the Job fails

A failed PreSync hook stops the sync before the Rollout is applied, so the
running version keeps serving (ArgoCD resource hooks documentation; not
tested here, the k3d test ran the Job without ArgoCD). The Application
retries the sync, up to 5 times with backoff (`retry` in
`argocd/04-application-lumen.yaml`).

```bash
kubectl logs -n lumen job/lumen-db-migrate
kubectl get application lumen-app -n argocd -o jsonpath='{.status.operationState.message}'; echo
```

goose runs each migration in a transaction: a failed migration leaves no
partial change and is not recorded. Fix it with a new commit (fix forward).

The Job never runs Down migrations, and lumen-api has no `down` command.
Reverting a schema change is a manual operation, decided case by case: run
the reverting SQL as `app`, then delete the version's row from
`goose_db_version`.

## Tests

```bash
docker run -d --rm --name pg-test -p 127.0.0.1:55432:5432 \
  -e POSTGRES_PASSWORD=test ghcr.io/cloudnative-pg/postgresql:16.6
cd 01-connected-zone/app
LUMEN_TEST_PG_DSN=postgres://postgres:test@127.0.0.1:55432/postgres?sslmode=disable \
  go test -p 1 ./...
```

They need a superuser (they create roles and databases). The Gitea CI starts
the same container and runs them on every push.

| Test | Checks |
|---|---|
| `TestUpFreshDatabase` | empty database to version 1, a second run applies nothing |
| `TestUpAdoptsLegacySchema` | a database created by v1.6.0 is adopted, rows kept |
| `TestConcurrentUp` | 4 runs at once with a slow migration all succeed, each version recorded once (without the lock, 3 of 4 fail) |
| `TestRuntimeRoleRights` | `lumen_runtime` can read and write rows; `CREATE TABLE`, `CREATE TEMP TABLE`, `CREATE SCHEMA`, `CREATE INDEX`, `ALTER`, `DROP`, `TRUNCATE` and writes to `goose_db_version` are refused with `insufficient_privilege` |
| `TestStoreWorksAfterExpandMigration` | the store works after an expand migration, as the runtime role |
| `TestCheckSchema` (internal/app) | startup refuses an older schema, an empty database or an unreachable one; accepts a newer schema and the v1.6.0 schema |

### Measured on k3d (14 November 2026)

K3s 1.34, CNPG 1.30.1 (the lab runs 1.25.1), PostgreSQL 16.6, image built
from this code. Namespace `lumen` with PSS `restricted`, the default deny and
DNS policies, and `cnpg/03-network-policy.yaml`. No ArgoCD, no Vault: the
Secrets were created as VSO writes them.

- The Cluster was created before the Secret `lumen-db-runtime`: healthy, the
  role reported under `cannotReconcile`. The role existed 1s after the
  Secret was created.
- The Job, from the target manifest above, adopted a database created as
  v1.6.0 does (the existing row kept), recorded version 1 and granted the
  rights.
- As `lumen_runtime`, from a pod labelled `app=lumen-api`: `INSERT` and
  `SELECT` worked; `CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`, `CREATE TEMP
  TABLE`, `TRUNCATE` and `DELETE FROM goose_db_version` were refused.
- Control: the same Job with another `app` label resolved `lumen-db-rw` but
  could not connect (network policy).
- Password rotation through the Secret: 70s to reach PostgreSQL, then the
  old password was refused.
- A new pod in `lumen` could not resolve names for its first seconds
  (`Temporary failure in name resolution`, gone after a 4s delay).
  `lumen-api migrate` retries the first connection for up to 30s, so this
  does not fail the Job: with a database started 8s late, it connected after
  5 retries.
