# Architecture — Full System Overview

This document describes the complete architecture of the lumen project: how components interconnect, data flows, design decisions, and why each layer exists.

---

## 1. Overview — The 3 Zones

The project simulates a real-world constraint: **no internet access from the cluster**. Everything running in production must have been pre-approved, downloaded, verified, and transferred manually.

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                              CONNECTED ZONE                                      │
│                           (Internet access)                                      │
│                                                                                  │
│  Developer Machine (macOS arm64)                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │  git push-all ──────────────────────────────────────────────┐           │    │
│  │                                                             │           │    │
│  │  01-connected-zone/scripts/                                 │           │    │
│  │  ├── 07-pull-traefik.sh          ← docker pull + helm pull  │           │    │
│  │  ├── 08-pull-kube-prometheus.sh                             │           │    │
│  │  ├── ...                                                    │           │    │
│  │  └── 19-pull-chaos-mesh.sh       → artifacts/chaos-mesh/   │           │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────┬───────────────────────────────┬──────────────┘
                                   │ USB / scp                     │ SSH (GitHub)
                                   ▼                               ▼
┌──────────────────────────────────────┐          ┌───────────────────────────────┐
│          TRANSIT ZONE                │          │         GitHub.com             │
│    node-1:5000 (Docker Registry)     │          │   (backup + portfolio)         │
│                                      │          └───────────────────────────────┘
│  02-transit-zone/push-*.sh           │
│  ├── docker load image.tar           │
│  ├── docker tag → localhost:5000/... │
│  └── docker push                     │
│                                      │
│  Registry catalog:                   │
│  ├── chaos-mesh/chaos-mesh:v2.7.2   │
│  ├── falcosecurity/falco:0.43.0     │
│  ├── argoproj/argo-rollouts:v1.8.0  │
│  └── ... (50+ images)               │
└──────────────────────────────────────┘
                    │
                    │ (same machine — node-1 IS the registry)
                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                           AIRGAP ZONE — K3s Cluster                              │
│                        (No internet — iptables DROP)                             │
│                                                                                  │
│   node-1 (192.168.2.2) — control-plane, 4CPU/6G                                 │
│   node-2 (192.168.2.3) — worker, 2CPU/4G                                        │
│                                                                                  │
│   All images pulled from 192.168.2.2:5000 (containerd registry mirror)          │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**Why this architecture?**
In enterprise environments (defense, banking, critical infrastructure), production clusters have no internet access. Images and charts must be validated, signed, and transferred through a controlled process. This project reproduces exactly that workflow.

---

## 2. CI/CD Flow — From Commit to Pod

The most important flow: how a code change reaches production in an automated and secure way.

```
Developer
    │
    │ git push-all
    │
    ├──────────────────────────────────────────► GitHub (backup)
    │
    └──────────────────────────────────────────► Gitea (192.168.2.2)
                                                       │
                                          Gitea Actions Runner (act_runner)
                                                       │
                                          ┌────────────▼─────────────┐
                                          │     Job: build-push       │
                                          │                           │
                                          │  1. go test ./...         │
                                          │  2. docker build          │
                                          │     (multi-stage, arm64)  │
                                          │  3. trivy scan            │
                                          │     (CVE check)           │
                                          │  4. docker push           │
                                          │     → 192.168.2.2:5000/   │
                                          │       lumen-api:<sha>     │
                                          │  5. cosign sign           │
                                          │     --key cosign.key      │
                                          │     --tlog-upload=false   │
                                          │     (OCI .sig artifact)   │
                                          │  6. update-manifest       │
                                          │     sed image tag in      │
                                          │     03-airgap-zone/       │
                                          │     manifests/app/        │
                                          │     git push → Gitea      │
                                          └────────────┬──────────────┘
                                                       │
                                          ArgoCD (polls Gitea every 3min)
                                                       │
                                          ┌────────────▼──────────────┐
                                          │   ArgoCD detects drift    │
                                          │   (manifest SHA changed)  │
                                          │                           │
                                          │   Applies new Rollout     │
                                          │   spec to K8s API         │
                                          └────────────┬──────────────┘
                                                       │
                                          ┌────────────▼──────────────┐
                                          │   Argo Rollouts           │
                                          │                           │
                                          │   canary: 20%             │
                                          │      │                    │
                                          │      ▼                    │
                                          │   AnalysisRun             │
                                          │   (Prometheus query)      │
                                          │   error_rate < 1% ?       │
                                          │      │                    │
                                          │   ✅ promote → 80%        │
                                          │      │                    │
                                          │   AnalysisRun x2         │
                                          │      │                    │
                                          │   ✅ promote → 100%       │
                                          │      │                    │
                                          │   ❌ auto rollback        │
                                          └───────────────────────────┘
```

**Key points:**
- `cosign sign` with ECDSA P-256 key — signature stored in the registry as OCI tag `sha256-<digest>.sig`
- `--tlog-upload=false` — no Rekor (transparency log), not possible in airgap
- Manifest update uses `CI_TOKEN` Gitea — the runner can push to the repo
- ArgoCD never pulls from GitHub — only from `http://gitea.gitea.svc.cluster.local:3000`

---

## 3. Security Stack — Defense in Depth

5 independent layers. Each intercepts at a different level.

```
                    ┌─────────────────────────────────────────┐
                    │         kubectl apply / ArgoCD          │
                    └─────────────────┬───────────────────────┘
                                      │
                    ┌─────────────────▼───────────────────────┐
                    │     LAYER 1: Kyverno                     │
                    │     (Admission Controller)               │
                    │                                          │
                    │  ValidatingPolicy (CEL):                 │
                    │  ✗ image tag :latest → BLOCKED           │
                    │  ✗ image not from 192.168.2.2:5000       │
                    │  ✗ no resource limits → BLOCKED          │
                    │  ✗ missing labels (app, tier) → BLOCKED  │
                    └─────────────────┬───────────────────────┘
                                      │ admitted
                    ┌─────────────────▼───────────────────────┐
                    │     LAYER 2 — Pod Security Standards     │
                    │     (PSS — namespace restricted)         │
                    │                                          │
                    │  ✗ privileged containers → BLOCKED       │
                    │  ✗ runAsRoot → BLOCKED                   │
                    │  ✗ hostPath / hostNetwork → BLOCKED      │
                    │  ✗ capabilities != DROP ALL → BLOCKED    │
                    │  ✓ seccompProfile RuntimeDefault requis  │
                    └─────────────────┬───────────────────────┘
                                      │ admitted
                    ┌─────────────────▼───────────────────────┐
                    │     LAYER 3 — NetworkPolicies            │
                    │     (Zero Trust — kube-router enforce)   │
                    │                                          │
                    │  Default deny-all in each namespace      │
                    │                                          │
                    │  lumen-api → redis:6379 ✓               │
                    │  lumen-api → cnpg:5432 ✓                │
                    │  traefik → lumen-api:8080 ✓             │
                    │  prometheus → lumen-api:9090 ✓          │
                    │  lumen-api → 8.8.8.8 ✗ (DROP)          │
                    └─────────────────┬───────────────────────┘
                                      │ running
                    ┌─────────────────▼───────────────────────┐
                    │     LAYER 4 — Falco 0.43.0               │
                    │     (Runtime Security — modern_ebpf)     │
                    │                                          │
                    │  Monitors syscalls in real time          │
                    │                                          │
                    │  🔔 Contact K8S API from container       │
                    │     → log: pod.name, image, namespace    │
                    │  🔔 Shell spawned in container           │
                    │  🔔 Write to /etc/                       │
                    │  🔔 Unexpected outbound connection       │
                    │                                          │
                    │  Plugins: container (libcontainer.so)    │
                    │           k8smeta (libk8smeta.so)        │
                    │  Driver: modern_ebpf (no kernel module)  │
                    └─────────────────┬───────────────────────┘
                                      │
                    ┌─────────────────▼───────────────────────┐
                    │     LAYER 5 — Cosign                     │
                    │     (Supply Chain Security)              │
                    │                                          │
                    │  Every image signed after CI build       │
                    │  ECDSA P-256 key (cosign.pub in repo)    │
                    │                                          │
                    │  cosign verify --key cosign.pub \        │
                    │    192.168.2.2:5000/lumen-api:<tag>      │
                    │  → "signatures verified" ✅              │
                    │                                          │
                    │  Signature stored in registry:           │
                    │  lumen-api:sha256-<digest>.sig           │
                    └─────────────────────────────────────────┘
```

---

## 4. Secrets & PKI — Vault + cert-manager

How secrets reach pods without ever being stored in plaintext in etcd.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        HashiCorp Vault HA                               │
│                  (3 pods — Raft consensus — namespace: vault)           │
│                                                                         │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐                │
│  │  vault-0     │   │  vault-1     │   │  vault-2     │                │
│  │  (leader)    │◄──│  (follower)  │◄──│  (follower)  │                │
│  └──────┬───────┘   └──────────────┘   └──────────────┘                │
│         │                                                               │
│  Active engines:                                                        │
│  ├── KV v2 (secret/)     ← PostgreSQL, Redis credentials               │
│  └── PKI (pki/)          ← root CA + issuer *.airgap.local             │
└─────────┬───────────────────────────────┬───────────────────────────────┘
          │                               │
          │ Vault Secrets Operator (VSO)  │ cert-manager
          │                               │
          ▼                               ▼
┌─────────────────────────┐    ┌──────────────────────────────┐
│  VaultStaticSecret      │    │  ClusterIssuer               │
│  (K8s CRD)              │    │  (vault-issuer)              │
│                         │    │                              │
│  spec:                  │    │  Certificate CRD:            │
│    mount: secret        │    │  ├── lumen-api-tls           │
│    path: lumen/postgres │    │  ├── argocd-tls              │
│    dest:                │    │  ├── grafana-tls             │
│      name: pg-creds     │    │  └── ...                     │
│      (K8s Secret)       │    │                              │
│                         │    │  Auto-renewal: 30d before    │
│  Sync: every 60s        │    │  expiry via CertificateReq   │
└──────────┬──────────────┘    └──────────────┬───────────────┘
           │                                  │
           ▼                                  ▼
┌──────────────────────────┐   ┌──────────────────────────────┐
│  K8s Secret pg-creds     │   │  K8s Secret *-tls            │
│  (in namespace lumen)    │   │  (TLS cert + key)            │
│                          │   │                              │
│  DB_HOST: lumen-db-rw    │   │  tls.crt: -----BEGIN...      │
│  DB_USER: lumen          │   │  tls.key: -----BEGIN...      │
│  DB_PASS: <rotated>      │   │                              │
└──────────┬───────────────┘   └──────────────┬───────────────┘
           │                                  │
           └──────────────┬───────────────────┘
                          │ mounted as env / volume
                          ▼
                   lumen-api pod
```

---

## 5. Observability — The 3 Pillars

Each signal (metrics, logs, traces) has its own stack but everything converges in Grafana.

```
                         lumen-api (Go)
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              ▼               ▼               ▼
        /metrics          stdout          OTel SDK
     (Prometheus)         (JSON)       (traces + spans)
              │               │               │
              │               │               │
    ┌─────────▼──────┐  ┌─────▼──────┐  ┌────▼──────────┐
    │  Prometheus    │  │   Alloy     │  │  OTel Collector│
    │  (scrape)      │  │ (collector) │  │  (via Alloy)  │
    │                │  │            │  │               │
    │  ServiceMonitor│  │  pipeline: │  └────┬──────────┘
    │  (CRD) defines │  │  parse JSON│       │
    │  scrape target │  │  add labels│       │
    └────────┬───────┘  └─────┬──────┘       │
             │                │              │
             │                ▼              ▼
             │           ┌─────────┐   ┌──────────┐
             │           │  Loki   │   │  Tempo   │
             │           │  (logs) │   │ (traces) │
             │           └─────┬───┘   └────┬─────┘
             │                 │            │
             └─────────────────┼────────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │       Grafana        │
                    │                     │
                    │  Datasources:        │
                    │  ├── Prometheus      │
                    │  ├── Loki           │
                    │  └── Tempo          │
                    │                     │
                    │  Dashboards:         │
                    │  ├── lumen-api       │
                    │  │   (p50/p99/rps/  │
                    │  │    error rate)   │
                    │  ├── K8s cluster    │
                    │  ├── Node Exporter  │
                    │  └── ArgoCD         │
                    │                     │
                    │  Explore:           │
                    │  TraceID → Logs     │
                    │  (correlated)       │
                    └─────────────────────┘
```

**Trace ↔ log correlation:** lumen-api injects the `traceID` into every JSON log line. In Grafana Explore, clicking a Tempo span jumps directly to the corresponding Loki logs.

---

## 6. Canary Deployment — Argo Rollouts + AnalysisTemplate

How progressive deployment with automatic validation works.

```
                    New image pushed by CI
                              │
                    ArgoCD sync → Rollout spec update
                              │
              ┌───────────────▼────────────────┐
              │         Argo Rollouts           │
              │                                │
              │  stable: lumen-api:v1.2.0      │
              │  canary: lumen-api:v1.3.0      │
              │                                │
              │  Step 1: canary weight = 20%   │
              └───────────────┬────────────────┘
                              │
              ┌───────────────▼────────────────┐
              │        AnalysisRun #1           │
              │                                │
              │  Query Prometheus (5min):       │
              │  rate(http_errors[5m])          │
              │    / rate(http_requests[5m])    │
              │  < 0.01 (1%) ?                  │
              │                                │
              │  ✅ success → continue          │
              │  ❌ failure → auto rollback     │
              └───────────────┬────────────────┘
                              │ ✅
              ┌───────────────▼────────────────┐
              │  Step 2: canary weight = 80%   │
              └───────────────┬────────────────┘
                              │
              ┌───────────────▼────────────────┐
              │        AnalysisRun #2           │
              └───────────────┬────────────────┘
                              │ ✅
              ┌───────────────▼────────────────┐
              │  Step 3: weight = 100%          │
              │  stable = lumen-api:v1.3.0     │
              │  Deployment complete ✅         │
              └────────────────────────────────┘

  Traffic routing via Service selector patch:
  ┌────────────────────────────────────────────┐
  │  Service lumen-api (stable)                │
  │  → 80% to stable pods (v1.2.0)             │
  │  → 20% to canary pods (v1.3.0)             │
  │  (weighted via Argo Rollouts TrafficSplit) │
  └────────────────────────────────────────────┘
```

---

## 7. Resilience — Chaos Mesh

How controlled failures validate system robustness.

```
  Chaos Mesh Architecture (namespace: chaos-mesh)
  ┌──────────────────────────────────────────────────────┐
  │                                                      │
  │  chaos-controller-manager    chaos-dashboard         │
  │  (1 replica — control-plane) (UI → Traefik)          │
  │         │                                            │
  │         │ gRPC :31767                                │
  │         ▼                                            │
  │  chaos-daemon (DaemonSet — 1 pod per node)           │
  │  ├── node-1: chaos-daemon-xxxxxx                     │
  │  └── node-2: chaos-daemon-yyyyyy                     │
  │       │                                              │
  │       │ containerd socket                            │
  │       │ /run/k3s/containerd/containerd.sock          │
  │       ▼                                              │
  │  Injects faults directly into containers             │
  └──────────────────────────────────────────────────────┘

  Available experiments:

  PodChaos ──────────────────────────────────────────────
  kubectl apply -f 01-podchaos-lumen-api.yaml
  │
  │  kill 50% of lumen-api pods for 2 min
  │  ┌──────────┐  kill   ┌──────────┐
  │  │ pod-1 ✅ │────────▶│ pod-1 ❌ │  Rollout detects
  │  │ pod-2 ✅ │         │ pod-2 ✅ │  → recreates pod-1
  │  └──────────┘         └──────────┘  → Healthy ✅
  │
  │  Validates: Argo Rollouts recovers automatically

  NetworkChaos ──────────────────────────────────────────
  kubectl apply -f 02-networkchaos-redis-latency.yaml
  │
  │  +100ms latency on Redis for 5 min
  │  lumen-api ──[+100ms]──► redis:6379
  │
  │  Watch in Grafana: p99 rises to ~100ms
  │  Validates: lumen-api handles timeouts without panic
  │
  kubectl apply -f 03-networkchaos-cnpg-latency.yaml
  │
  │  +100ms latency on PostgreSQL for 5 min
  │  lumen-api ──[+100ms]──► cnpg:5432
  │
  │  Validates: connection pool + query timeout configured
```

---

## 8. HA Databases

Two databases with different high-availability strategies.

```
  Redis HA Sentinel
  ┌─────────────────────────────────────────────────────┐
  │  namespace: lumen                                   │
  │                                                     │
  │  ┌──────────────┐    replication    ┌─────────────┐ │
  │  │  redis-master│ ────────────────► │ redis-slave │ │
  │  │  :6379       │                   │ :6379       │ │
  │  └──────┬───────┘                   └─────────────┘ │
  │         │                                           │
  │         │ monitored by                              │
  │  ┌──────▼──────────────────────────────────┐       │
  │  │  Sentinel x3 (:26379)                   │       │
  │  │  quorum = 2                             │       │
  │  │  If master down → election → failover   │       │
  │  └─────────────────────────────────────────┘       │
  │                                                     │
  │  lumen-api → redis-headless:26379 (Sentinel)        │
  │           → redis-master:6379 (auto-discovery)     │
  └─────────────────────────────────────────────────────┘

  CloudNativePG (PostgreSQL)
  ┌─────────────────────────────────────────────────────┐
  │  namespace: cnpg-system                             │
  │                                                     │
  │  ┌──────────────┐    streaming    ┌───────────────┐ │
  │  │  lumen-db-1  │ ──────────────► │  lumen-db-2   │ │
  │  │  (primary)   │   replication   │  (replica)    │ │
  │  │  RW :5432    │                 │  RO :5432     │ │
  │  └──────────────┘                 └───────────────┘ │
  │         │                                           │
  │         │                         ┌───────────────┐ │
  │         └────────────────────────►│  lumen-db-3   │ │
  │                                   │  (witness)    │ │
  │                                   │  quorum only  │ │
  │                                   └───────────────┘ │
  │                                                     │
  │  Services:                                          │
  │  lumen-db-rw:5432   → primary (writes)             │
  │  lumen-db-ro:5432   → replica (reads)              │
  │  lumen-db-r:5432    → any (load balanced)          │
  │                                                     │
  │  Credentials via VSO → K8s Secret (never plaintext)│
  └─────────────────────────────────────────────────────┘
```

---

## 9. GitOps — ArgoCD Sync Waves

Deployment order matters: CRDs must exist before the resources that use them.

```
  Wave 0 (core infrastructure)
  ├── cert-manager          (CRDs: Certificate, ClusterIssuer)
  ├── Kyverno               (CRDs: ValidatingPolicy, ClusterPolicy)
  └── MetalLB               (CRDs: IPAddressPool, L2Advertisement)

  Wave 1 (application dependencies)
  ├── Vault HA              (CRDs: VaultConnection, VaultAuth)
  ├── CloudNativePG         (CRDs: Cluster, Backup)
  └── Traefik               (CRDs: IngressRoute, Middleware)

  Wave 2 (controllers + advanced CRDs)
  ├── Argo Rollouts         (CRDs: Rollout, AnalysisTemplate)
  └── Chaos Mesh            (CRDs: PodChaos, NetworkChaos...)

  Wave 3 (application)
  └── lumen-app             (Rollout, Service, HPA, NetworkPolicies)

  Wave 4+ (observability)
  ├── kube-prometheus-stack
  ├── Loki + Alloy
  └── Tempo

  ArgoCD sync:
  ┌────────────────────────────────────────────────┐
  │  poll Gitea every 3min                         │
  │  OR webhook (Gitea → ArgoCD)                   │
  │                                                │
  │  drift detected → apply diff (ServerSideApply) │
  │  selfHeal: true → revert manual changes        │
  │  prune: true    → delete removed resources     │
  └────────────────────────────────────────────────┘
```

---

## 10. Network — Namespaces and Isolation

Each component in its own namespace with strict NetworkPolicies.

```
  K3s Cluster
  ├── namespace: lumen
  │   ├── lumen-api (Rollout — 2 replicas)
  │   ├── redis-master + redis-slave + sentinel x3
  │   └── NetworkPolicies: default-deny + explicit allows
  │
  ├── namespace: cnpg-system
  │   ├── lumen-db-1 (primary), lumen-db-2 (replica), lumen-db-3 (witness)
  │   └── cnpg-operator
  │
  ├── namespace: vault
  │   ├── vault-0, vault-1, vault-2 (Raft HA)
  │   └── vault-agent-injector
  │
  ├── namespace: cert-manager
  │   └── cert-manager, cainjector, webhook
  │
  ├── namespace: argocd
  │   ├── argocd-server, repo-server, application-controller
  │   └── applicationset-controller
  │
  ├── namespace: gitea
  │   └── gitea (+ internal PostgreSQL)
  │
  ├── namespace: traefik
  │   └── traefik (DaemonSet — node-1 + node-2)
  │       ├── :80  → redirect HTTPS
  │       ├── :443 → TLS termination (cert-manager certs)
  │       └── IngressRoutes → services by Host header
  │
  ├── namespace: monitoring
  │   ├── prometheus, grafana, alertmanager
  │   ├── node-exporter (DaemonSet)
  │   └── kube-state-metrics
  │
  ├── namespace: loki
  │   └── loki (single binary mode)
  │
  ├── namespace: tempo
  │   └── tempo
  │
  ├── namespace: alloy
  │   └── alloy (DaemonSet — log + trace collector)
  │
  ├── namespace: falco
  │   ├── falco (DaemonSet — modern_ebpf)
  │   └── k8s-metacollector
  │
  ├── namespace: argo-rollouts
  │   └── argo-rollouts-controller
  │
  └── namespace: chaos-mesh
      ├── chaos-controller-manager
      ├── chaos-daemon (DaemonSet)
      └── chaos-dashboard
```

---

## 11. Physical Infrastructure — Multipass VMs

```
  MacBook Air (arm64, 16GB RAM)
  ├── Multipass hypervisor
  │
  ├── node-1 (192.168.2.2) — Ubuntu 24.04 arm64
  │   ├── K3s control-plane (API server, etcd, scheduler)
  │   ├── Docker Registry v2 (:5000) — stores all images
  │   ├── Gitea (:3000 internal) — airgap git server
  │   ├── MetalLB speaker
  │   └── Workloads: Vault, ArgoCD, cert-manager, Traefik...
  │   Resources: 4 vCPU / 6GB RAM
  │
  └── node-2 (192.168.2.3) — Ubuntu 24.04 arm64
      ├── K3s worker
      ├── MetalLB speaker
      └── Workloads: lumen-api, Redis, monitoring...
      Resources: 2 vCPU / 4GB RAM

  Network: 192.168.2.0/24 (Multipass bridge)
  MetalLB pool: 192.168.2.100-192.168.2.120
  → LoadBalancer IPs accessible from macOS

  containerd registry mirror (all nodes):
  /etc/rancher/k3s/registries.yaml
  mirrors:
    docker.io:    → http://192.168.2.2:5000
    ghcr.io:      → http://192.168.2.2:5000
    gcr.io:       → http://192.168.2.2:5000
    quay.io:      → http://192.168.2.2:5000
```

---

## 12. lumen-api — Internal Architecture

The API is the application workload that serves as the reason for all this infrastructure. Written in Go using stdlib only (`net/http`) — no external framework.

```
  HTTP Request
       │
       ▼
  ┌─────────────────────────────────────────────────────┐
  │              Middleware chain (onion)               │
  │                                                     │
  │  Recovery        ← panic → 500, log + continue      │
  │    └── Tracing   ← creates parent OTel span         │
  │          └── Logging   ← structured JSON (slog)     │
  │                └── Metrics  ← increments Prometheus  │
  │                      └── Idempotency                │
  │                            └── ServeMux             │
  │                                  │                  │
  └──────────────────────────────────┼──────────────────┘
                                     │
                    ┌────────────────▼────────────────┐
                    │           Handlers               │
                    │                                  │
                    │  GET  /livez    → 200 (process)  │
                    │  GET  /readyz   → 503 on SIGTERM │
                    │                                  │
                    │  GET  /health   → redis.Ping     │
                    │                   + postgres.Ping│
                    │                   (rw and ro)    │
                    │                   → healthy /    │
                    │                     degraded     │
                    │                                  │
                    │  GET  /hello    → redis.Incr     │
                    │                   (counter)      │
                    │                                  │
                    │  GET  /items    → postgres RO    │
                    │  POST /items    → postgres RW    │
                    │  GET  /items/{id}                │
                    │  DELETE /items/{id}              │
                    │                                  │
                    │  GET  /events   → audit log      │
                    │                   (append-only,  │
                    │                    replica read) │
                    │                                  │
                    ├──────────────────────────────────┤
                    │  admin port 9090 (Prometheus     │
                    │  only, not routed by Traefik):   │
                    │  GET  /metrics                   │
                    │  GET  /debug/pprof/ (off unless  │
                    │       PPROF_ENABLED=true)        │
                    └──────────────────────────────────┘
```

**Idempotency middleware** (`POST` and `DELETE`, header `Idempotency-Key`):

```
  POST /items  + Idempotency-Key: <uuid>
       │
       ├─ key not 1 to 128 visible ASCII characters ─────► 400
       │
       ▼
  fingerprint = sha256(method, path, query, body)
       │
  Redis GET idempotency:<key> ── error ──► 503 + Retry-After (not executed)
       │
       ├─ hit, same fingerprint ──► replay status, body, Content-Type,
       │                            Location + Idempotency-Replayed: true
       ├─ hit, other fingerprint ─► 422 (key used for another request)
       │ miss
       ▼
  SET NX idempotency:lock:<key> <random token> 30s
       ├─ error ──────► 503 + Retry-After
       ├─ held ───────► 409 + Retry-After (same key in flight)
       ▼
  re-check the record, execute the handler
       │
       ▼
  SET idempotency:<key> {status, body, headers, fingerprint} 24h  (not for 5xx)
  release the lock only if it still holds our token (Lua compare-and-delete)
```

A client that times out and retries with the same key gets the same
response, without a second row in the database. The guarantees and their
limits:

- **A key belongs to one request**: reusing it with another method, path
  or body is a 422, not a replay of an unrelated response.
- **Redis unavailable**: a request that carries a key gets a 503 and is
  not executed, since running it without the record would break the
  guarantee the client asked for. Requests without a key are not affected.
  The 503 count against the availability SLO.
- **Result not stored** (Redis fails after the handler ran): the client
  gets its response, a retry with the key executes again. Logged as an
  error.
- **Record lost**: Redis evicts under `allkeys-lru`, and a Sentinel
  failover can lose the last writes (asynchronous replication, #8). A
  retry after that executes again.
- **Key scope**: the record is per key, not per caller: the API has no
  caller identity yet (#18). Two clients choosing the same key get a 422
  or a 409, except when their requests are identical (same method, path
  and body): the second then gets the first one's response.

Exactly-once regardless of Redis needs the record in PostgreSQL, written in
the same transaction as the item (unique constraint on the key). Not done.

**Probes and shutdown:**
- `/livez` (liveness) and `/readyz` (readiness) do not check Redis or PostgreSQL. Both are shared by every replica: a probe that depends on them restarts or unreadies all pods at once. On a k3d test with Redis stopped for 130s, probes on `/health` gave 8 restarts and 0/2 pods ready; `/livez` + `/readyz` gave 0 restarts and 2/2 ready.
- Rollout in two steps, because the image deployed today (v1.6.0) has no `/livez` or `/readyz`: `03-lumen-api.yaml` first uses a TCP liveness and startup probe and keeps readiness on `/health` (same k3d test: 0 restarts, pods unready during the outage and back within 30s). The switch to `/livez` and `/readyz` comes after the first release that contains them; the target probes are written in a comment of the manifest.
- `/health` reports the dependencies (Redis, PostgreSQL primary and replica, 2s timeout each) for humans and scripts.
- On SIGTERM, `/readyz` answers 503, the server keeps serving for `SHUTDOWN_DRAIN_DELAY` (default 5s) while the pod leaves the Service endpoints, then stops accepting connections and waits for in-flight requests (30s budget, `terminationGracePeriodSeconds: 45`).
- A dependency missing at startup still makes the process exit: Kubernetes restarts it with backoff, and the `startupProbe` only covers a slow start.

**Observability built into every handler:**
- Each handler opens a child OTel span (`tracer.Start`) — Redis/PG errors are recorded in the span (`span.RecordError`)
- `/health` creates separate spans for Redis and PostgreSQL — Grafana Tempo shows exactly which one is slow
- Logs are structured JSON (`slog`) with `traceID` injected — direct correlation with Tempo in Grafana Explore

**Graceful shutdown:**
```
  SIGTERM received (kubectl rolling update)
       │
       ▼
  server.Shutdown(ctx, timeout=30s)  ← waits for in-flight requests
       │
       ▼
  redis.Close()
  postgres.Close()
       │
       ▼
  exit 0
```
Argo Rollouts sends SIGTERM before cutting traffic — the 30s window lets long-running requests finish cleanly.

**PostgreSQL read/write splitting:**
- `PG_RW_DSN` → primary (INSERT/UPDATE/DELETE)
- `PG_RO_DSN` → replica (SELECT) — `/events` and `/items` GET read from the replica
- Credentials come from a K8s Secret injected by VSO from Vault — never in plaintext in the manifest

---

## 13. IaC — Terraform + Ansible

VM provisioning and cluster configuration are fully automated. Two tools, two distinct responsibilities.

```
  Terraform (05-terraform/)                 Ansible (04-ansible/)
  ─────────────────────────                 ────────────────────
  Responsibility: WHAT exists               Responsibility: HOW it's configured
  State-driven (terraform.tfstate)          Idempotent (guards rc == 0)
  Provider: larstobi/multipass v1.4         SSH into VMs

  resources:                                playbooks:
  ├── local_file.node1_cloudinit            ├── site.yml       ← full bootstrap
  │   (render SSH key + IP → yaml)          ├── start.yml      ← after Mac reboot
  ├── local_file.node2_cloudinit            ├── stop.yml       ← clean shutdown
  ├── multipass_instance.node1             ├── unseal.yml     ← Vault unseal
  │   cpus=4, memory=6G, disk=40G          └── provision.yml  ← Ansible-only fallback
  └── multipass_instance.node2
      cpus=2, memory=4G, disk=30G          roles (11):
                                            ├── multipass   registry   images
  cloud-init (injected at creation):        ├── k3s         metallb    garage
  ├── SSH public key → authorized_keys      ├── argocd      gitea      vault
  ├── eth1 static IP via netplan            ├── dns         verify
  ├── Docker install (node-1 only)
  └── sysctl: inotify=8192 (Falco)
```

**Why two tools instead of just Ansible?**

Ansible can create VMs with `multipass launch` but has no state. Re-running the playbook requires manual guards (`multipass info` rc != 0) to avoid duplicates. Terraform tracks what it created — `terraform destroy` cleans up properly, `terraform plan` shows diffs before acting.

**Cloud portability:** replacing `larstobi/multipass` with `hashicorp/aws` or `hashicorp/google` only changes the provider and resource types. The cloud-init templates, variables, and all of Ansible remain identical.

**From-scratch flow:**

```bash
# 1. One-time prerequisite
multipass set local.bridged-network=en0

# 2. VMs (~3 min)
cd 05-terraform && terraform init && terraform apply

# 3. Full cluster (~20 min)
ansible-playbook 04-ansible/site.yml --ask-become-pass

# Tear everything down
cd 05-terraform && terraform destroy
```

---

## Summary — Main Flows

| Flow | Path |
|------|------|
| **Provision** | `terraform apply` → Multipass VMs + cloud-init (SSH, IP, Docker, sysctl) |
| **Bootstrap** | `ansible-playbook site.yml` → K3s + MetalLB + ArgoCD + Gitea + Vault + Garage |
| **Deploy** | `git push` → Gitea → ArgoCD → K8s API → Argo Rollouts → Pods |
| **Image** | `docker build` → CI sign (Cosign) → Registry → containerd pull |
| **Secret** | Vault KV → VSO → K8s Secret → Pod env |
| **TLS cert** | cert-manager → Vault PKI → K8s Secret → Traefik / Pod |
| **Log** | Pod stdout → Alloy → Loki → Grafana |
| **Metric** | Pod `/metrics` → Prometheus → Grafana |
| **Trace** | OTel SDK → Alloy → Tempo → Grafana |
| **Chaos** | `kubectl apply PodChaos` → chaos-daemon → container kill |
