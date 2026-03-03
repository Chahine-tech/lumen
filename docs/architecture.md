# Architecture — Full System Overview

Ce document décrit l'architecture complète du projet lumen : comment les composants s'interconnectent, les flux de données, les décisions de design, et pourquoi chaque couche existe.

---

## 1. Vue d'ensemble — Les 3 Zones

Le projet simule une contrainte réelle : **aucun accès internet depuis le cluster**. Tout ce qui tourne en production doit avoir été pré-approuvé, téléchargé, vérifié, et transféré manuellement.

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

**Pourquoi cette architecture ?**
En entreprise (défense, banque, industrie critique), les clusters de production n'ont pas accès à internet. Les images et charts doivent être validés, signés, et transférés via un processus contrôlé. Ce projet reproduit exactement ce workflow.

---

## 2. Flux CI/CD — Du commit au pod

C'est le flux le plus important : comment un changement de code se retrouve en production de manière automatisée et sécurisée.

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
                                          │     (signature OCI .sig)  │
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
                                          │   ❌ rollback auto        │
                                          └───────────────────────────┘
```

**Points clés :**
- `cosign sign` avec clé ECDSA P-256 — signature stockée dans la registry comme tag OCI `sha256-<digest>.sig`
- `--tlog-upload=false` — pas de Rekor (transparency log), impossible en airgap
- Le manifest update se fait via `CI_TOKEN` Gitea — le runner peut pusher sur le repo
- ArgoCD ne pull jamais depuis GitHub — uniquement depuis `http://gitea.gitea.svc.cluster.local:3000`

---

## 3. Stack Sécurité — Défense en Profondeur

5 couches indépendantes. Chacune intercepte à un niveau différent.

```
                    ┌─────────────────────────────────────────┐
                    │         kubectl apply / ArgoCD          │
                    └─────────────────┬───────────────────────┘
                                      │
                    ┌─────────────────▼───────────────────────┐
                    │     COUCHE 1 — OPA Gatekeeper            │
                    │     (Admission Controller)               │
                    │                                          │
                    │  ConstraintTemplate + Constraint:        │
                    │  ✗ image tag :latest → BLOCKED           │
                    │  ✗ image not from 192.168.2.2:5000       │
                    │  ✗ no resource limits → BLOCKED          │
                    │  ✗ missing labels (app, tier) → BLOCKED  │
                    └─────────────────┬───────────────────────┘
                                      │ admitted
                    ┌─────────────────▼───────────────────────┐
                    │     COUCHE 2 — Pod Security Standards    │
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
                    │     COUCHE 3 — NetworkPolicies           │
                    │     (Zero Trust — kube-router enforce)   │
                    │                                          │
                    │  Default deny-all dans chaque namespace  │
                    │                                          │
                    │  lumen-api → redis:6379 ✓               │
                    │  lumen-api → cnpg:5432 ✓                │
                    │  traefik → lumen-api:8080 ✓             │
                    │  prometheus → lumen-api:9090 ✓          │
                    │  lumen-api → 8.8.8.8 ✗ (DROP)          │
                    └─────────────────┬───────────────────────┘
                                      │ running
                    ┌─────────────────▼───────────────────────┐
                    │     COUCHE 4 — Falco 0.43.0              │
                    │     (Runtime Security — modern_ebpf)     │
                    │                                          │
                    │  Surveille les syscalls en temps réel    │
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
                    │     COUCHE 5 — Cosign                    │
                    │     (Supply Chain Security)              │
                    │                                          │
                    │  Chaque image signée après build CI      │
                    │  Clé ECDSA P-256 (cosign.pub dans repo)  │
                    │                                          │
                    │  cosign verify --key cosign.pub \        │
                    │    192.168.2.2:5000/lumen-api:<tag>      │
                    │  → "signatures verified" ✅              │
                    │                                          │
                    │  Signature stockée dans registry:        │
                    │  lumen-api:sha256-<digest>.sig           │
                    └─────────────────────────────────────────┘
```

---

## 4. Secrets & PKI — Vault + cert-manager

Comment les secrets atteignent les pods sans jamais être en clair dans etcd.

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
│  Engines activés:                                                       │
│  ├── KV v2 (secret/)     ← credentials PostgreSQL, Redis               │
│  └── PKI (pki/)          ← CA root + issuer *.airgap.local             │
└─────────┬───────────────────────────────────┬───────────────────────────┘
          │                                   │
          │ Vault Secrets Operator (VSO)       │ cert-manager
          │                                   │
          ▼                                   ▼
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

## 5. Observabilité — Les 3 Piliers

Chaque signal (métriques, logs, traces) a sa propre stack mais tout converge dans Grafana.

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
    │  (scrape)      │  │ (collector) │  │  (sidecar/agent│
    │                │  │            │  │   via Alloy)   │
    │  ServiceMonitor│  │  pipeline: │  │               │
    │  (CRD) defines │  │  parse JSON│  └────┬──────────┘
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

**Corrélation traces ↔ logs :** lumen-api injecte le `traceID` dans chaque log JSON. Dans Grafana Explore, cliquer sur un span Tempo saute directement aux logs Loki correspondants.

---

## 6. Canary Deployment — Argo Rollouts + AnalysisTemplate

Comment un déploiement progressif avec validation automatique fonctionne.

```
                    Nouvelle image pushée par CI
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
              │  ❌ failure → rollback auto     │
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
              │  Déploiement terminé ✅         │
              └────────────────────────────────┘

  Traffic routing via Service selector patch:
  ┌────────────────────────────────────────────┐
  │  Service lumen-api (stable)                │
  │  → 80% vers pods stable (v1.2.0)           │
  │  → 20% vers pods canary (v1.3.0)           │
  │  (weighted via Argo Rollouts TrafficSplit) │
  └────────────────────────────────────────────┘
```

---

## 7. Résilience — Chaos Mesh

Comment les pannes contrôlées valident la robustesse du système.

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
  │  Injecte les fautes directement dans les containers  │
  └──────────────────────────────────────────────────────┘

  Expériences disponibles:

  PodChaos ──────────────────────────────────────────────
  kubectl apply -f 01-podchaos-lumen-api.yaml
  │
  │  kill 50% des pods lumen-api pendant 2 min
  │  ┌──────────┐  kill   ┌──────────┐
  │  │ pod-1 ✅ │────────▶│ pod-1 ❌ │  Rollout détecte
  │  │ pod-2 ✅ │         │ pod-2 ✅ │  → recrée pod-1
  │  └──────────┘         └──────────┘  → Healthy ✅
  │
  │  Valide: Argo Rollouts récupère automatiquement

  NetworkChaos ──────────────────────────────────────────
  kubectl apply -f 02-networkchaos-redis-latency.yaml
  │
  │  +100ms latence sur Redis pendant 5 min
  │  lumen-api ──[+100ms]──► redis:6379
  │
  │  Observer dans Grafana: p99 monte à ~100ms
  │  Valide: lumen-api gère les timeouts sans panic
  │
  kubectl apply -f 03-networkchaos-cnpg-latency.yaml
  │
  │  +100ms latence sur PostgreSQL pendant 5 min
  │  lumen-api ──[+100ms]──► cnpg:5432
  │
  │  Valide: connection pool + query timeout configurés
```

---

## 8. Bases de Données HA

Deux bases avec des stratégies de haute disponibilité différentes.

```
  Redis HA Sentinel
  ┌─────────────────────────────────────────────────────┐
  │  namespace: lumen                                   │
  │                                                     │
  │  ┌──────────────┐    réplication    ┌─────────────┐ │
  │  │  redis-master│ ────────────────► │ redis-slave │ │
  │  │  :6379       │                   │ :6379       │ │
  │  └──────┬───────┘                   └─────────────┘ │
  │         │                                           │
  │         │ monitored by                              │
  │  ┌──────▼──────────────────────────────────┐       │
  │  │  Sentinel x3 (:26379)                   │       │
  │  │  quorum = 2                             │       │
  │  │  Si master down → élection → failover   │       │
  │  └─────────────────────────────────────────┘       │
  │                                                     │
  │  lumen-api → redis-headless:26379 (Sentinel)        │
  │           → redis-master:6379 (découverte auto)    │
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
  │  Credentials via VSO → K8s Secret (jamais en clair)│
  └─────────────────────────────────────────────────────┘
```

---

## 9. GitOps — ArgoCD Sync Waves

L'ordre de déploiement est critique : les CRDs doivent exister avant les ressources qui les utilisent.

```
  Wave 0 (infrastructure fondamentale)
  ├── cert-manager          (CRDs: Certificate, ClusterIssuer)
  ├── OPA Gatekeeper        (CRDs: ConstraintTemplate, Constraint)
  └── MetalLB               (CRDs: IPAddressPool, L2Advertisement)

  Wave 1 (dépendances applicatives)
  ├── Vault HA              (CRDs: VaultConnection, VaultAuth)
  ├── CloudNativePG         (CRDs: Cluster, Backup)
  └── Traefik               (CRDs: IngressRoute, Middleware)

  Wave 2 (controllers + CRDs avancés)
  ├── Argo Rollouts         (CRDs: Rollout, AnalysisTemplate)
  └── Chaos Mesh            (CRDs: PodChaos, NetworkChaos...)

  Wave 3 (application)
  └── lumen-app             (Rollout, Service, HPA, NetworkPolicies)

  Wave 4+ (observabilité)
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

## 10. Réseau — Namespaces et Isolation

Chaque composant dans son namespace avec des NetworkPolicies strictes.

```
  Cluster K3s
  ├── namespace: lumen
  │   ├── lumen-api (Rollout — 2 replicas)
  │   ├── redis-master + redis-slave + sentinel x3
  │   └── NetworkPolicies: default-deny + allows explicites
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
  │   └── gitea (+ PostgreSQL interne)
  │
  ├── namespace: traefik
  │   └── traefik (DaemonSet — node-1 + node-2)
  │       ├── :80  → redirect HTTPS
  │       ├── :443 → TLS termination (cert-manager certs)
  │       └── IngressRoutes → services par Host header
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

## 11. Infrastructure physique — Multipass VMs

```
  MacBook Air (arm64, 16GB RAM)
  ├── Multipass hypervisor
  │
  ├── node-1 (192.168.2.2) — Ubuntu 24.04 arm64
  │   ├── K3s control-plane (API server, etcd, scheduler)
  │   ├── Docker Registry v2 (:5000) — stocke toutes les images
  │   ├── Gitea (:3000 interne) — git server airgap
  │   ├── MetalLB speaker
  │   └── Workloads: Vault, ArgoCD, cert-manager, Traefik...
  │   Resources: 4 vCPU / 6GB RAM
  │
  └── node-2 (192.168.2.3) — Ubuntu 24.04 arm64
      ├── K3s worker
      ├── MetalLB speaker
      └── Workloads: lumen-api, Redis, monitoring...
      Resources: 2 vCPU / 4GB RAM

  Réseau: 192.168.2.0/24 (Multipass bridge)
  MetalLB pool: 192.168.2.100-192.168.2.120
  → LoadBalancer IPs accessibles depuis macOS

  containerd registry mirror (tous les nodes):
  /etc/rancher/k3s/registries.yaml
  mirrors:
    docker.io:    → http://192.168.2.2:5000
    ghcr.io:      → http://192.168.2.2:5000
    gcr.io:       → http://192.168.2.2:5000
    quay.io:      → http://192.168.2.2:5000
```

---

## 12. lumen-api — Architecture interne

L'API est le workload applicatif qui sert de prétexte à toute l'infrastructure. Elle est écrite en Go avec la stdlib uniquement (`net/http`) — pas de framework externe.

```
  HTTP Request
       │
       ▼
  ┌─────────────────────────────────────────────────────┐
  │              Middleware chain (onion)               │
  │                                                     │
  │  Recovery        ← panic → 500, log + continue      │
  │    └── Tracing   ← crée le span OTel parent         │
  │          └── Logging   ← log structuré JSON (slog)  │
  │                └── Metrics  ← incrémente Prometheus  │
  │                      └── Idempotency                │
  │                            └── ServeMux             │
  │                                  │                  │
  └──────────────────────────────────┼──────────────────┘
                                     │
                    ┌────────────────▼────────────────┐
                    │           Handlers               │
                    │                                  │
                    │  GET  /health   → redis.Ping     │
                    │                   + postgres.Ping│
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
                    │  GET  /metrics  → Prometheus     │
                    │  GET  /debug/pprof/              │
                    └──────────────────────────────────┘
```

**Idempotency middleware** — le pattern le plus intéressant de l'API :

```
  POST /items  + header Idempotency-Key: <uuid>
       │
       ▼
  Redis.Get("idem:<uuid>") ──── hit ────► replay stored response
       │                                  + header Idempotency-Replayed: true
       │ miss
       ▼
  Execute handler
       │
       ▼
  Redis.Set("idem:<uuid>", {status, body}, TTL=24h)
       │
       ▼
  Return response
```

Si le client reçoit un timeout réseau et retenvoie la même requête avec le même `Idempotency-Key`, il reçoit exactement la même réponse — sans créer un doublon en base. Pattern critique pour les APIs financières ou les systèmes distribués.

**Observabilité intégrée dans chaque handler :**
- Chaque handler ouvre un span OTel enfant (`tracer.Start`) — les erreurs Redis/PG sont enregistrées dans le span (`span.RecordError`)
- Le `/health` crée des spans séparés pour Redis et PostgreSQL — Grafana Tempo montre exactement lequel est lent
- Les logs sont en JSON structuré (`slog`) avec `traceID` injecté — corrélation directe avec Tempo dans Grafana Explore

**Graceful shutdown :**
```
  SIGTERM reçu (kubectl rolling update)
       │
       ▼
  server.Shutdown(ctx, timeout=30s)  ← attend les requêtes en cours
       │
       ▼
  redis.Close()
  postgres.Close()
       │
       ▼
  exit 0
```
Argo Rollouts envoie SIGTERM avant de couper le trafic — les 30s laissent le temps aux requêtes longues de terminer proprement.

**Read/Write splitting PostgreSQL :**
- `PG_RW_DSN` → primary (INSERT/UPDATE/DELETE)
- `PG_RO_DSN` → replica (SELECT) — `/events` et `/items` GET lisent depuis le replica
- Les credentials viennent d'un K8s Secret injecté par VSO depuis Vault — jamais en clair dans le manifest

---

## Résumé des flux principaux

| Flux | Chemin |
|------|--------|
| **Deploy** | `git push` → Gitea → ArgoCD → K8s API → Argo Rollouts → Pods |
| **Image** | `docker build` → CI sign (Cosign) → Registry → containerd pull |
| **Secret** | Vault KV → VSO → K8s Secret → Pod env |
| **TLS cert** | cert-manager → Vault PKI → K8s Secret → Traefik / Pod |
| **Log** | Pod stdout → Alloy → Loki → Grafana |
| **Metric** | Pod `/metrics` → Prometheus → Grafana |
| **Trace** | OTel SDK → Alloy → Tempo → Grafana |
| **Chaos** | `kubectl apply PodChaos` → chaos-daemon → container kill |
| **Admission** | `kubectl apply` → OPA Gatekeeper → PSS → Accepted/Rejected |
