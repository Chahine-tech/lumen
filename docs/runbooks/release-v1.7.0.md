# Release v1.7.0

v1.7.0 is the first release with the changes made since v1.6.0 for issues
#15, #16, #17, #19 and #33. Several of them need the new image before the
manifests can use it, so the release goes in two phases:

1. **Tag v1.7.0**: CI builds, signs and deploys the image with the current
   manifests (step 1 of each change).
2. **Merge the branch `release-v1.7.0-step2`**: the manifests that need
   v1.7.0. Merging it before v1.7.0 runs would break the deployment: v1.6.0
   has no `/livez` or `/readyz`, no `migrate` or `smoke`, no admin port, and
   cannot run as `lumen_runtime`.

| Issue | Phase 1: v1.7.0 with the current manifests | Phase 2: branch merged |
|---|---|---|
| #19 migrations | the app no longer creates the schema; on the existing database it logs `Database has no migration history` and takes it as version 1 | PreSync Job `lumen-db-migrate`, app as `lumen_runtime` |
| #16 probes | TCP startup and liveness, readiness on `/health` | `/livez`, `/readyz` |
| #17 admin port | `/metrics` moves to 9090, the ServiceMonitor still scrapes 8080: **no lumen-api metrics until phase 2** | ServiceMonitor on `admin` (9090), 8080 closed to Prometheus |
| #15 smoke test | not run | analysis step after the 20% canary weight |
| #33 idempotency, startup retry | active | |

## Before: prerequisites

The cluster is up and ArgoCD has synced `main`.

```bash
kubectl get applications -n argocd   # Synced, Healthy
kubectl argo rollouts get rollout lumen-api -n lumen   # Healthy, v1.6.0
```

**Step 1 of the database migrations** must be done on the existing cluster
(Vault policies and role, `lumen/db-runtime` password, CNPG manifests):
[database-migrations.md, Step 1 on the existing cluster](database-migrations.md#step-1-on-the-existing-cluster).
Phase 2 fails without it. Check:

```bash
kubectl get secret -n lumen lumen-db-runtime -o jsonpath='{.type}'; echo
# kubernetes.io/basic-auth
kubectl get cluster lumen-db -n lumen -o jsonpath='{.status.managedRolesStatus}'; echo
# "reconciled":["lumen_runtime"]
```

## Phase 1: tag v1.7.0

```bash
git checkout main
git push gitea main
git tag v1.7.0
git push gitea v1.7.0
git push origin v1.7.0
```

The Gitea CI (`.gitea/workflows/ci.yaml`) runs the tests, then the
`release` job: build, push, cosign signature, and a commit
`chore: update lumen-api image to v1.7.0 [skip ci]` pushed to Gitea `main`.
Bring it to the local `main` and GitHub:

```bash
git pull gitea main
git push origin main
```

ArgoCD syncs `lumen-app` and Argo Rollouts starts the canary (20%, success
rate analysis, 80%, analysis, 100%).

```bash
kubectl argo rollouts get rollout lumen-api -n lumen --watch
# Healthy, image 192.168.2.2:5000/lumen-api:v1.7.0
kubectl logs -n lumen -l app=lumen-api --tail=100 | grep -i "migration history"
# expected once per pod: the database predates the migrations
curl -sk https://lumen-api.airgap.local/health
```

Do not wait long between phase 1 and phase 2: lumen-api metrics are not
scraped in between (the `lumen-api` target is down in Prometheus).

## Phase 2: merge the step 2 branch

```bash
git checkout main
git merge --no-ff release-v1.7.0-step2
git push-all
```

The branch sets the same `v1.7.0` image as the release commit, so the merge
does not conflict on it.

ArgoCD runs the PreSync Job `lumen-db-migrate`, then applies the manifests.
The Rollout's pod template changed (role, probes, ports), so a new canary
starts, and the smoke test runs as its first analysis.

```bash
kubectl logs -n lumen job/lumen-db-migrate
# "Migration applied" version 1, "Schema up to date", "Runtime role granted DML rights"
kubectl argo rollouts get rollout lumen-api -n lumen --watch
kubectl get analysisrun -n lumen
kubectl logs -n lumen -l app=lumen-smoke-test --tail=20
# "Smoke test passed"
kubectl logs -n lumen -l app=lumen-api --tail=50 | grep -i schema
# nothing
```

In Prometheus, the target is up on the admin port:

```promql
up{namespace="lumen", service="lumen-api"}
```

## Rollback

- **During phase 1**, the canary is aborted by its analysis, or by hand
  (`kubectl argo rollouts abort lumen-api -n lumen`). To leave v1.7.0,
  revert the release commit (`git revert <chore: update lumen-api image>`),
  which brings back v1.6.0.
- **After phase 2**, v1.6.0 cannot run with the merged manifests. To go back
  to v1.6.0, revert the merge and the release commit in the same push. Not
  tested: v1.6.0 against a database that has the `goose_db_version` table
  (it only runs `CREATE TABLE IF NOT EXISTS` on its own tables).
- A failed phase 2 sync (migration Job failed) leaves the running pods
  untouched: ArgoCD applies nothing after a failed PreSync hook. The Job's
  logs say why: `kubectl logs -n lumen job/lumen-db-migrate`.
