# CI/CD — Gitea Actions + Argo Rollouts

This document covers the full CI/CD pipeline: automated build/push via Gitea Actions, and progressive canary delivery via Argo Rollouts.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Gitea Actions CI Pipeline](#gitea-actions-ci-pipeline)
3. [Argo Rollouts — Canary Deployments](#argo-rollouts--canary-deployments)
4. [Full Deploy Workflow (end-to-end)](#full-deploy-workflow-end-to-end)
5. [Operational Commands](#operational-commands)
6. [ArgoCD + Argo Rollouts Integration](#argocd--argo-rollouts-integration)
7. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Developer
  └── git tag v1.x.x && git push gitea v1.x.x
        │
        ▼
  Gitea Actions (act_runner v0.2.11, node-1)
        ├── go test ./...
        ├── docker build → 192.168.2.2:5000/lumen-api:v1.x.x
        ├── trivy scan (HIGH/CRITICAL, offline)
        ├── docker push (:semver + :sha + :latest)
        └── sed manifest + git push → Gitea
              │
              ▼
        ArgoCD (detects diff in manifest)
              │
              ▼
        Argo Rollouts (canary strategy)
              ├── Step 1: 20% → new version  ← pause (manual promote)
              ├── Step 2: 80% → new version  ← pause (manual promote)
              └── Step 3: 100% → full promotion
```

**Key principle**: Git is the single source of truth. ArgoCD watches the repo, Argo Rollouts controls traffic.

---

## Gitea Actions CI Pipeline

### Trigger conditions

| Event | Job triggered |
|-------|---------------|
| Push to `main` (app/Dockerfile paths) | `test` + `build-push` |
| Pull request to `main` | `test` only |
| Git tag `v*` | `test` + `release` |
| Manual dispatch | all |

### Pipeline file

[.gitea/workflows/ci.yaml](../.gitea/workflows/ci.yaml)

### Jobs

#### `test`
```yaml
- go test ./... -v -count=1
```
Runs against `01-connected-zone/app/`, fails the pipeline on any test failure.

#### `build-push` (on push to main)
1. Compute `SHORT_SHA` (7 chars) from `github.sha`
2. `docker build` → tags `:$SHORT_SHA` + `:latest`
3. Trivy scan (offline DB from `/var/cache/trivy`, exit-code 0 — non-blocking)
4. `docker push` both tags to `192.168.2.2:5000`

#### `release` (on tag `v*`)
1. Build → tags `:$SEMVER` + `:$SHORT_SHA` + `:latest`
2. Push all 3 tags
3. **Update manifest**: `sed` replaces the image tag in `03-airgap-zone/manifests/app/03-lumen-api.yaml`
4. `git commit + git push` back to Gitea → triggers ArgoCD sync

### CI infrastructure

| Component | Details |
|-----------|---------|
| Runner | `act_runner v0.2.11`, K8s Deployment in `gitea` namespace, pinned to node-1 |
| Job container | Custom image `192.168.2.2:5000/lumen-api:builder` (golang:1.26-alpine + docker-cli + git) |
| Docker socket | `/var/run/docker.sock` mounted (builds directly on node-1) |
| Trivy DB | Offline at `/var/cache/trivy` (pre-populated in connected zone) |
| Registry | `192.168.2.2:5000` (node-1 Docker registry, port 5000) |
| Gitea token | `CI_TOKEN` secret in Gitea repo settings |

### Important: runner must be registered with NodePort URL

The runner was registered with `--instance http://192.168.2.2:30300` (Gitea NodePort), not the K8s internal DNS. This URL becomes `GITHUB_SERVER_URL` in job containers. Checkout steps use `with: github-server-url: http://192.168.2.2:30300` as explicit override.

---

## Argo Rollouts — Canary Deployments

### Why Argo Rollouts?

Standard `Deployment` does a rolling update: all pods switched at once, no traffic control. Argo Rollouts adds:
- **Canary**: send X% traffic to new version, pause, validate, continue
- **Blue/Green**: switch instantly between two full environments
- **Analysis**: auto-promote/rollback based on Prometheus metrics

### Architecture

```
lumen namespace
  ├── Rollout lumen-api          ← replaces Deployment
  │     ├── ReplicaSet stable    ← current version (e.g. v1.5.3)
  │     └── ReplicaSet canary    ← new version during rollout
  ├── Service lumen-api          ← used by Traefik IngressRoute + Prometheus (unchanged)
  ├── Service lumen-api-stable   ← receives main traffic (managed by Argo Rollouts)
  └── Service lumen-api-canary   ← receives canary traffic (managed by Argo Rollouts)

argo-rollouts namespace
  ├── controller Deployment      ← patches Services + watches Rollouts
  └── dashboard Deployment       ← UI at localhost:3100 (port-forward)
```

### Canary steps

```yaml
strategy:
  canary:
    stableService: lumen-api-stable
    canaryService: lumen-api-canary
    steps:
      - setWeight: 20   # 20% canary, 80% stable
      - analysis:       # auto-rollback if success rate < 95% for 3 consecutive checks
          templates:
            - templateName: success-rate
      - setWeight: 80   # 80% canary, 20% stable
      - analysis:       # second check before full promotion
          templates:
            - templateName: success-rate
      - setWeight: 100  # full promotion
```

The `AnalysisTemplate` `success-rate` ([05-analysis-template.yaml](../03-airgap-zone/manifests/app/05-analysis-template.yaml)) queries Prometheus every minute. If the HTTP success rate drops below 95% for 3 consecutive checks, the Rollout is automatically aborted and traffic falls back to the stable version.

Argo Rollouts achieves traffic weighting by scaling the ReplicaSets proportionally:
- At 20%: 1 canary pod / 2 stable pods = ~33% actual (rounded up)
- At 80%: 2 canary pods / 1 stable pod = ~67% actual
- At 100%: 2 canary pods / 0 stable pods, stable ReplicaSet scaled to 0

### ArgoCD sync-wave ordering

Argo Rollouts CRDs must exist before lumen-app tries to create a `Rollout` resource:

```
Wave 2: argo-rollouts Application (installs CRDs + controller)
Wave 3: lumen-app Application (creates Rollout resource)
```

`lumen-app` also has `SkipDryRunOnMissingResource=true` as a safety net in case wave ordering isn't respected.

---

## Full Deploy Workflow (end-to-end)

### Triggering a new canary via git tag (recommended)

```bash
# 1. Make code changes in 01-connected-zone/app/
# 2. Commit and push to Gitea
git add .
git commit -m "feat: my change"
git push gitea main        # or: git push-all

# 3. Create and push a semver tag
git tag v1.5.4
git push gitea v1.5.4

# → CI triggers: test → build → push image → update manifest → git push
# → ArgoCD detects manifest diff → syncs → Argo Rollouts starts canary at 20%
```

### Monitoring the rollout

```bash
# Static view
kubectl argo rollouts get rollout lumen-api -n lumen

# Live watch
kubectl argo rollouts get rollout lumen-api -n lumen --watch
```

Example output at 20% during analysis:
```
Name:       lumen-api
Status:     ◌ Progressing
Message:    AnalysisRunRunning
Strategy:   Canary
  Step:     2/5
  SetWeight: 20
  ActualWeight: 33
Images:     192.168.2.2:5000/lumen-api:v1.5.3 (stable)
            192.168.2.2:5000/lumen-api:v1.5.4 (canary)
Replicas:
  Desired:  2   Current: 3   Updated: 1   Ready: 3
```

If the analysis passes, the Rollout automatically continues to 80% then 100% — no manual action needed.

### Manual promotion (override analysis)

```bash
# Skip the current analysis step and force-promote
kubectl argo rollouts promote lumen-api -n lumen
```

### Aborting (rollback)

```bash
kubectl argo rollouts abort lumen-api -n lumen
# → traffic immediately back to 100% stable
# → canary ReplicaSet scaled down
```

---

## Operational Commands

### Status and monitoring

```bash
# Current rollout state
kubectl argo rollouts get rollout lumen-api -n lumen

# Watch in real time
kubectl argo rollouts get rollout lumen-api -n lumen --watch

# List all rollouts
kubectl argo rollouts list rollouts -n lumen

# Dashboard UI (port-forward)
kubectl argo rollouts dashboard
# → http://localhost:3100
```

### Promotion and rollback

```bash
# Promote one step (20% → 80%, or 80% → 100%)
kubectl argo rollouts promote lumen-api -n lumen

# Skip all pauses and go straight to 100%
kubectl argo rollouts promote lumen-api -n lumen --full

# Abort → immediate rollback to stable
kubectl argo rollouts abort lumen-api -n lumen

# Retry after abort
kubectl argo rollouts retry rollout lumen-api -n lumen
```

### Triggering a canary manually (without CI)

> **Warning**: do NOT use `kubectl argo rollouts set image` — ArgoCD `selfHeal: true` will immediately revert the change back to Git state.

Instead, edit the manifest in Git and push:

```bash
# Edit 03-airgap-zone/manifests/app/03-lumen-api.yaml
# Change: image: 192.168.2.2:5000/lumen-api:v1.5.3
# To:     image: 192.168.2.2:5000/lumen-api:v1.5.4

git add 03-airgap-zone/manifests/app/03-lumen-api.yaml
git commit -m "chore: bump lumen-api to v1.5.4"
git push gitea main
# → ArgoCD syncs → Argo Rollouts starts canary
```

### Checking Services during canary

```bash
# Stable service endpoints (should point to stable pods)
kubectl get endpoints lumen-api-stable -n lumen

# Canary service endpoints (should point to canary pods)
kubectl get endpoints lumen-api-canary -n lumen

# Check which pods are in which ReplicaSet
kubectl get pods -n lumen -l app=lumen-api -o wide
```

---

## ArgoCD + Argo Rollouts Integration

### Applications and waves

| Application | Wave | Namespace | Source path |
|-------------|------|-----------|-------------|
| `argo-rollouts` | 2 | `argo-rollouts` | `manifests/argo-rollouts-helm` |
| `lumen-app` | 3 | `lumen` | `manifests/app` |

### Applying the argo-rollouts Application

The `manifests/argocd/` folder is not watched by any ArgoCD Application — these files must be applied manually:

```bash
kubectl apply -f 03-airgap-zone/manifests/argocd/17-application-argo-rollouts.yaml
```

### ignoreDifferences for CRDs

Argo Rollouts installs CRDs that K8s auto-populates with fields (`/status`, `/spec/preserveUnknownFields`). Without `ignoreDifferences`, ArgoCD shows the app as OutOfSync permanently:

```yaml
# 17-application-argo-rollouts.yaml
ignoreDifferences:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jsonPointers:
      - /spec/preserveUnknownFields
      - /status
syncOptions:
  - RespectIgnoreDifferences=true
```

### selfHeal behavior

`lumen-app` has `selfHeal: true`. This means:
- Any `kubectl` change to a Rollout spec is reverted within ~30s
- The only way to trigger a real canary is by changing the manifest in Git
- This is the correct GitOps behavior — Git is the source of truth

### ArgoCD shows lumen-app as "Paused"

This is expected and correct: ArgoCD reflects the Rollout's state. When a canary is in progress and waiting at a `pause: {}` step, ArgoCD shows the app as "Paused". It becomes "Healthy" once the Rollout fully promotes to 100%.

---

## Troubleshooting

### Rollout stuck in Paused — nothing happening

Check if ArgoCD reverted a manual image change:
```bash
kubectl argo rollouts get rollout lumen-api -n lumen
# If images show only one version → no canary in progress, just paused at step
# → promote to complete
kubectl argo rollouts promote lumen-api -n lumen
```

### ErrImagePull on canary pod

The image doesn't exist in the airgap registry:
```bash
# Check the image exists
ssh ubuntu@192.168.2.2 "curl -s http://localhost:5000/v2/lumen-api/tags/list"

# If missing: the push script must run FROM node-1, not from macOS
# The registry at 192.168.2.2:5000 is node-1's local Docker registry
# From macOS, localhost:5000 is OrbStack → different registry!
ssh ubuntu@192.168.2.2 "docker push 192.168.2.2:5000/lumen-api:<tag>"
```

### CI not triggering on git tag

```bash
# Check runner is registered and online
kubectl get pods -n gitea -l app=act-runner
kubectl logs -n gitea -l app=act-runner --tail=50

# Check Gitea received the tag
# → https://gitea.airgap.local/lumen/lumen/releases

# Re-push the tag (delete + recreate)
git tag -d v1.x.x
git push gitea :refs/tags/v1.x.x
git tag v1.x.x
git push gitea v1.x.x
```

### argo-rollouts Application OutOfSync after deploy

Expected — caused by K8s auto-populating CRD fields. Verify `ignoreDifferences` is present:
```bash
kubectl get application argo-rollouts -n argocd -o yaml | grep -A 10 ignoreDifferences
```

If missing, re-apply the Application manifest:
```bash
kubectl apply -f 03-airgap-zone/manifests/argocd/17-application-argo-rollouts.yaml
```

### Rollout won't start (lumen-app sync error)

If `SkipDryRunOnMissingResource=true` is not set and Argo Rollouts CRDs don't exist yet:
```bash
kubectl get application lumen-app -n argocd -o yaml | grep -A5 syncOptions
# Should include: SkipDryRunOnMissingResource=true
```

### AnalysisRun failed — unexpected rollback

```bash
# See why the analysis failed
kubectl get analysisrun -n lumen
kubectl describe analysisrun <name> -n lumen
# Look for: "Message: Metric 'success-rate' assessed Failed"

# Check the Prometheus query manually
kubectl exec -n argo-rollouts deploy/argo-rollouts -- \
  wget -qO- "http://kube-prometheus-stack-prometheus.monitoring:9090/api/v1/query?query=sum(rate(http_requests_total{app=\"lumen-api\"}[2m]))"
# If empty result → no traffic yet (avoid triggering canary with zero requests)
```

If the canary pod gets no traffic yet (0 requests), the query returns `NaN` which Argo Rollouts treats as failure. Generate some traffic first:
```bash
for i in $(seq 1 20); do curl -sk https://lumen-api.airgap.local/health > /dev/null; done
```

### Abort doesn't work — pods still split

After abort, the Rollout goes to `Degraded` state. Run retry to restore stable:
```bash
kubectl argo rollouts abort lumen-api -n lumen
kubectl argo rollouts retry rollout lumen-api -n lumen
```

---

## Promotion Strategies

### Option 1: Manual pause
```yaml
steps:
  - setWeight: 20
  - pause: {}       # waits forever until `promote` command
  - setWeight: 100
```
Promotes manually. Best for learning and validation.

### Option 2: Timed pause
```yaml
steps:
  - setWeight: 20
  - pause: {duration: 10m}   # auto-promotes after 10 minutes
  - setWeight: 100
```
Promotes automatically after the timeout. Can still abort during the wait.

### Option 3: Analysis — current config ✅
```yaml
steps:
  - setWeight: 20
  - analysis:
      templates:
        - templateName: success-rate
  - setWeight: 80
  - analysis:
      templates:
        - templateName: success-rate
  - setWeight: 100
```
`AnalysisTemplate` (`05-analysis-template.yaml`) queries Prometheus every minute:
```yaml
successCondition: result[0] >= 0.95   # 95% HTTP success rate
failureLimit: 3                        # 3 consecutive failures → auto rollback
query: |
  sum(rate(http_requests_total{app="lumen-api",status!~"5.."}[2m]))
  /
  sum(rate(http_requests_total{app="lumen-api"}[2m]))
```
If success rate drops below 95% for 3 checks in a row → automatic rollback to stable. No human intervention needed.
