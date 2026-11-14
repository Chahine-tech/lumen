# lumen-api admin port

lumen-api listens on two ports:

| Port | Name | Serves | Reachable from |
|---|---|---|---|
| 8080 | `http` | the API (`/hello`, `/health`, `/items`, `/events`) and the probes (`/livez`, `/readyz`) | Traefik pods only (`network-policies/04-allow-api-ingress.yaml`), and the kubelet probes |
| 9090 | `admin` | `/metrics`, and pprof under `/debug/pprof/` when `PPROF_ENABLED=true` | Prometheus pods only (`network-policies/05-allow-monitoring.yaml`) |

The IngressRoute matches the API paths only (`traefik/16-lumen-api-ingressroute.yaml`): any other path, `/metrics` and `/debug/pprof/` included, gets a 404 from Traefik and never reaches a pod. No IngressRoute targets 9090.

pprof exposes heap contents and the command line, and `/debug/pprof/profile` and `/trace` burn CPU on demand. It is off by default.

## Status: two steps

The deployed image (v1.6.0) serves `/metrics` on 8080 and has no admin port.

- **Step 1 (now)**:
  - The IngressRoute is restricted to the API paths.
  - Port 8080 accepts Traefik only.
  - Prometheus may reach 8080 and 9090.
  - The Service has the `admin` port.
  - The ServiceMonitor still scrapes `http` (8080).
- **Step 2, after the first release with the admin port**: see below. It can go in the same commit as step 2 of the [database migrations](database-migrations.md#step-2-after-the-release) and the probes (#16).

## Step 2, after the release

1. `kube-prometheus-stack/servicemonitors/lumen-api.yaml`: `port: admin` instead of `port: http`.
2. `app/03-lumen-api.yaml`, Rollout:
   - add a `containerPort: 9090` named `admin`;
   - change the pod annotation `prometheus.io/port` to `"9090"`;
   - change the same annotation on the `lumen-api` Service to `"9090"`.
3. `network-policies/05-allow-monitoring.yaml`: remove port 8080.
4. Check in Prometheus that the target is up on the new port, and that the SLO series still move. The labels `instance` (it holds the port) and `endpoint` change. The SLO rules and the AnalysisTemplate of this repository select on `app` only.

   ```promql
   up{namespace="lumen", service="lumen-api"}
   ```

## Using pprof

pprof is off unless the pod has `PPROF_ENABLED=true`. Turn it on for an investigation only, then turn it off again:

- Add the variable to the Rollout's env in `app/03-lumen-api.yaml` and push. ArgoCD (`selfHeal`) reverts a change made with kubectl.
- Each change of the env starts a canary.

```bash
kubectl port-forward -n lumen svc/lumen-api 9090:9090
go tool pprof http://localhost:9090/debug/pprof/heap
go tool pprof http://localhost:9090/debug/pprof/profile?seconds=30
```

`kubectl port-forward` is not subject to the NetworkPolicies. This was measured on k3d: `/metrics` returned 200 through a port-forward to 9090.

## Measured on k3d (14 November 2026)

The setup:
- K3s 1.34, with the Traefik chart and values of this repository (39.0.1, Traefik v3.6.8) but without the mTLS option and the middlewares;
- the NetworkPolicies of this repository;
- one pod of v1.6.0, then one pod of the new image.

**Through Traefik**: `/hello` and `/health` returned 200. `/items`, `/items/1` and `/events` reached the pod (503 from the app, no database in the test). `/metrics`, `/debug/pprof/`, `/debug/pprof/cmdline`, `/itemsx`, `/livez` and `/` returned 404 from Traefik (no router in the access log).

**From inside the cluster**:

| From | v1.6.0 | new image |
|---|---|---|
| Prometheus pod (monitoring) to 8080 `/metrics` | 200 | 404 (moved) |
| Prometheus pod (monitoring) to 9090 `/metrics` | no connection (nothing listens) | 200 |
| Another pod in monitoring to 8080 | no connection | no connection |
| A pod in `default` to 8080 or 9090 | no connection | no connection |
| A pod in `default` to 8080, previous policy (control) | 200 | |

**Probes**: the kubelet probes on 8080 (TCP startup and liveness, readiness on `/health`) passed under the restricted policy, and the pods became ready.

**Rule syntax**: a first version of the rule written over several lines was rejected by Traefik (`error while parsing rule`), and every path, the API included, answered 404. The rule is on one line for that reason.
