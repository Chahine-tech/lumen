# lumen-api smoke test

`lumen-api smoke` checks a deployed lumen-api through its public API
(`internal/smoke`):

1. `GET /health` answers 200. Retried for up to 30s: a new pod cannot reach
   the API for its first seconds, until kube-router has programmed its
   NetworkPolicies. A 401 or 403 fails at once.
   With `SMOKE_EXPECT_AUTH=true`: `GET /items` without a token answers 401
   (authentication enforced, issue #18).
2. `POST /items` with an `Idempotency-Key` creates an item (201).
3. The same request again is replayed: 201, `Idempotency-Replayed: true`,
   the same body.
4. `GET /items/{id}` returns it.
5. `DELETE /items/{id}` answers 204, then `GET` answers 404 within 10s
   (reads go to a replica).

Every request but the 401 check carries the bearer token read from
`SMOKE_TOKEN_FILE`; in the cluster, a projected token of the ServiceAccount
`lumen-smoke-test`, audience `lumen-api`
([authentication](lumen-api-authentication.md)).

The test item is deleted even when a later check fails. The idempotency
record stays in Redis for 24h under a random `smoke-...` key. Exit code 0
when every check passes, 1 otherwise, with the failing check in the log.

```bash
# Local stack (01-connected-zone/docker-compose.yml)
docker compose run --rm --no-deps -e SMOKE_URL=http://api:8080 api smoke
```

## In the cluster: a canary analysis step

The Rollout runs it as an analysis step right after the first canary
weight: a Job from the AnalysisTemplate `smoke-test`, against
`lumen-api-canary`, so the new version is tested before it gets more
traffic. A failure aborts the Rollout and traffic goes back to the stable
version.

The Job runs its own pinned image, not the canary's: a rollback to a
version without `smoke` (v1.6.0 and older) must still pass the step.

`network-policies/06-allow-smoke-test.yaml` lets pods labelled
`app: lumen-smoke-test` reach lumen-api on 8080, which otherwise accepts
Traefik only.

## Status: two steps

Step 2 ships with v1.7.0, applied once that release is deployed: [release v1.7.0](release-v1.7.0.md).

- **Step 1 (now)**: the `smoke` subcommand, its tests, and the
  NetworkPolicy (it selects no pod yet).
- **Step 2, after the first release with `smoke`**: add the AnalysisTemplate
  and the Rollout step below, with that release's tag. It can go with step 2
  of the [database migrations](database-migrations.md#step-2-after-the-release)
  and the [admin port](lumen-api-admin-port.md#step-2-after-the-release).

## Step 2, after the release

1. `app/06-smoke-test-analysis.yaml` (replace `<release>` with the tag):

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AnalysisTemplate
   metadata:
     name: smoke-test
     namespace: lumen
   spec:
     metrics:
       - name: smoke-test
         provider:
           job:
             spec:
               backoffLimit: 0
               activeDeadlineSeconds: 120
               template:
                 metadata:
                   labels:
                     app: lumen-smoke-test
                 spec:
                   restartPolicy: Never
                   securityContext:
                     runAsNonRoot: true
                     runAsUser: 1000
                     seccompProfile:
                       type: RuntimeDefault
                   containers:
                     - name: smoke-test
                       image: 192.168.2.2:5000/lumen-api:<release>
                       args: [smoke]
                       env:
                         - name: SMOKE_URL
                           value: http://lumen-api-canary.lumen.svc.cluster.local:8080
                       securityContext:
                         allowPrivilegeEscalation: false
                         readOnlyRootFilesystem: true
                         capabilities:
                           drop: [ALL]
                       resources:
                         requests: {cpu: 10m, memory: 16Mi}
                         limits: {cpu: 100m, memory: 64Mi}
   ```

2. `app/03-lumen-api.yaml`, Rollout `strategy.canary.steps`, right after
   `setWeight: 20`:

   ```yaml
   - analysis:       # smoke test against the canary pods
       templates:
         - templateName: smoke-test
   ```

3. After the sync, the next rollout shows an AnalysisRun `...-smoke-test`:

   ```bash
   kubectl -n lumen get analysisrun
   kubectl -n lumen logs -l app=lumen-smoke-test --tail=20
   ```

The image tag of the AnalysisTemplate does not follow the releases: bump it
when the smoke test itself changes.

## How it was tested

On k3d (15 November 2026), with Argo Rollouts v1.8.0 from
`argo-rollouts-helm` and its airgap values, the namespace `lumen` with its
Pod Security labels, and the NetworkPolicies 01 (lumen part), 02, 04 and 06.
PostgreSQL and Redis ran in another namespace; the Rollout had a
`setWeight: 50` step then the analysis.

| Case | Result |
|---|---|
| New revision, 06 applied | AnalysisRun Successful, Rollout Healthy, no item left |
| New revision, 06 removed | smoke test fails on `/health` after 30s, AnalysisRun Failed, Rollout aborted (Degraded) |
| Pod labelled `app: lumen-smoke-test`, 10s after start | passes |
| Same pod without the label | connection refused |
| First version, without the 30s retry | failed at once (connection refused), although 06 was applied |

Not tested: the Kyverno policies of the real cluster (internal registry and
cosign signature of `lumen-api`, which the release image satisfies), and
the 20% weight with 2 replicas of the real Rollout.
