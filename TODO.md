# Lumen Project - TODO & Future Improvements

This file tracks planned improvements and future phases for the Lumen airgap Kubernetes project.

## 🎯 Current Status

✅ **Phase 1-15 Complete**
- Phase 1: Build & Push (Connected Zone)
- Phase 2: Registry Setup (Transit Zone)
- Phase 3: K3s Cluster (Airgap Zone)
- Phase 4: Application Deployment
- Phase 5: NetworkPolicies (Zero Trust)
- Phase 6: Basic Monitoring (Manual Prometheus + Grafana)
- Phase 7: ArgoCD GitOps
- Phase 8: Gitea Internal Git Server (Full Airgap ✅)
- Phase 9: Traefik Ingress Controller (Helm + TLS)
- Phase 10: Production-Grade Observability (kube-prometheus-stack)
- Phase 11/12: Upgrade to Latest Versions (Prometheus 3.x, Grafana 12.x, ArgoCD 3.x)
- Phase 13: OPA Gatekeeper Policy Enforcement
- Phase 14: Pod Security Standards (PSS)
- Phase 15: Complete Observability Stack (Loki + Alloy + Tempo + OpenTelemetry)

---

## 📋 Phase 8: Full Airgap with Internal Git Server ✅ COMPLETE

**Goal**: Remove dependency on GitHub.com and achieve true airgap isolation.

### Tasks:
- [x] Download Gitea in connected zone
- [x] Push Gitea images to transit registry
- [x] Deploy Gitea in airgap cluster
- [x] Configure Gitea with internal registry
- [x] Create mirror: GitHub → Gitea
- [x] Reconfigure ArgoCD to use Gitea instead of GitHub
- [x] Remove HTTPS/443 egress from ArgoCD NetworkPolicy
- [x] Test GitOps workflow with internal Git
- [x] Document the migration process

**Status**: ✅ Complete (February 14, 2026)

---

## 📋 Phase 9: Traefik Ingress Controller ✅ COMPLETE

**Goal**: Replace unstable kubectl port-forward with production-grade Ingress Controller.

### Tasks:
- [x] Download Traefik v3.6.8 + Helm chart in connected zone
- [x] Push Traefik images to transit registry
- [x] Generate self-signed CA + wildcard TLS certificate
- [x] Deploy Traefik via Helm chart (airgap mode)
- [x] Create IngressRoutes for all services (Gitea, Grafana, Prometheus, ArgoCD, AlertManager)
- [x] Configure middlewares (security headers, compression, rate limiting, basic auth)
- [x] Setup DNS entries in /etc/hosts
- [x] Install CA certificate on local machine
- [x] Fix ArgoCD redirect loop issue
- [x] Fix Traefik dashboard 404 issue
- [x] Document deployment and troubleshooting
- [x] Update ArgoCD Application for Traefik

**Status**: ✅ Complete (February 15, 2026)

**Access:**
- Traefik Dashboard: https://traefik.airgap.local/dashboard/
- Gitea: https://gitea.airgap.local
- Grafana: https://grafana.airgap.local
- ArgoCD: https://argocd.airgap.local
- Prometheus: https://prometheus.airgap.local
- AlertManager: https://alertmanager.airgap.local

---

## 📋 Phase 10: Production-Grade Observability Stack ✅ COMPLETE

**Goal**: Migrate from manual Prometheus/Grafana to kube-prometheus-stack Helm chart for production-ready monitoring.

### Tasks:
- [x] Download kube-prometheus-stack Helm chart v55.0.0 in connected zone
- [x] Download 8 container images (Prometheus, Grafana, AlertManager, Operator, etc.)
- [x] Push all images to transit registry
- [x] Configure Helm values for airgap mode (localhost:5000 registry)
- [x] Deploy via Helm in monitoring namespace
- [x] Add Node Exporter for hardware metrics (CPU, RAM, disk, network)
- [x] Add kube-state-metrics for Kubernetes object metrics
- [x] Create ServiceMonitors for custom services (Lumen API, Traefik, Gitea, ArgoCD)
- [x] Configure NetworkPolicies for zero-trust monitoring
- [x] Update Traefik IngressRoutes for new service names
- [x] Test HTTPS access to all monitoring services
- [x] Remove old manual monitoring manifests

**Status**: ✅ Complete (February 16, 2026)

**Components Deployed:**
- Prometheus v2.48.0 (metrics storage + PromQL)
- Grafana v10.2.2 (visualization with 40+ pre-configured dashboards)
- AlertManager v0.26.0 (alert routing)
- Prometheus Operator v0.70.0 (CRD management)
- Node Exporter v1.7.0 (hardware metrics)
- kube-state-metrics v2.10.1 (K8s object metrics)
- Grafana Sidecar v1.25.2 (auto-reload dashboards)

**Access:**
- Prometheus: https://prometheus.airgap.local
- Grafana: https://grafana.airgap.local (admin/admin)
- AlertManager: https://alertmanager.airgap.local

---

## 📋 Phase 11/12: Upgrade to Latest Versions ✅ COMPLETE

**Goal**: Upgrade all monitoring and ArgoCD components to latest stable versions (February 2026).

### Tasks:
- [x] Upgrade Prometheus v2.48.0 → v3.5.1 (LTS)
- [x] Upgrade Grafana v10.2.2 → v12.4.0
- [x] Upgrade AlertManager v0.26.0 → v0.31.1
- [x] Upgrade Prometheus Operator v0.70.0 → v0.78.2
- [x] Upgrade Node Exporter v1.7.0 → v1.8.2
- [x] Upgrade kube-state-metrics v2.10.1 → v2.15.0
- [x] Upgrade Grafana Sidecar v1.25.2 → v1.30.1
- [x] Upgrade ArgoCD v2.12.3 → v3.2.0
- [x] Fix ArgoCD insecure mode for TLS termination
- [x] Apply CRD updates for Prometheus 3.x compatibility
- [x] Create comprehensive monitoring documentation

**Status**: ✅ Complete (February 16, 2026)

**Breaking Changes Fixed:**
- Prometheus 3.x requires CRD schema updates (applied with --server-side)
- ArgoCD v3.x requires explicit insecure mode when behind TLS proxy

**Documentation:** `docs/monitoring.md` (58KB - covers Phase 10, 11, 12)

---

## 📋 Phase 13: OPA Gatekeeper Policy Enforcement ✅ COMPLETE

**Goal**: Deploy OPA Gatekeeper for admission control and policy enforcement in airgap cluster.

### Tasks:
- [x] Download OPA Gatekeeper v3.18.0 in connected zone
- [x] Push Gatekeeper image to transit registry
- [x] Deploy Gatekeeper to airgap cluster (4 pods)
- [x] Fix missing `--operation=generate` flag (v3.18.0 breaking change)
- [x] Apply ConstraintTemplates for 4 security policies
- [x] Test policy enforcement with violations
- [x] Fix resource policy Rego to support Deployments

**Status**: ✅ Complete (February 16, 2026)

**Active Policies (4/4 working):**
1. ✅ **require-internal-registry**: Only allow images from `localhost:5000/`
2. ✅ **block-latest-tag**: Deny containers using `:latest` or no tag
3. ✅ **require-app-labels**: Enforce `app` and `tier` labels on workloads
4. ✅ **require-resources**: Enforce CPU/memory requests and limits

**Critical Fix Applied:**
- Added `get_containers` helper function to support both Pod and Deployment resource paths
- Gatekeeper v3.18.0 requires `--operation=generate` flag on audit pod for CRD creation

**Components:**
- gatekeeper-controller-manager (3 replicas) - Admission webhook
- gatekeeper-audit (1 replica) - Audit + CRD generation

---

## 📋 Phase 14: Pod Security Standards (PSS) ✅ COMPLETE

**Goal**: Implement Kubernetes Pod Security Standards for defense-in-depth security.

### Tasks:
- [x] Enable PSS on lumen namespace (restricted mode)
- [x] Configure pod security contexts for lumen-api and redis
- [x] Test policy enforcement with violations
- [x] Verify PSS and OPA Gatekeeper work together
- [x] Create namespace YAML with PSS labels for GitOps

**Status**: ✅ Complete (February 16, 2026)

**PSS Restrictions Enforced (Restricted Mode):**
- ❌ No privileged containers
- ✅ Must run as non-root (runAsNonRoot=true)
- ❌ No host access (hostPath, hostNetwork, hostPID)
- ✅ Capabilities must drop ALL
- ✅ allowPrivilegeEscalation=false required
- ✅ seccompProfile required (RuntimeDefault)

**Defense in Depth - 3 Security Layers:**
1. **OPA Gatekeeper**: Custom policies (registry, tags, labels, resources)
2. **Pod Security Standards**: System security (privileges, capabilities, host access)
3. **NetworkPolicies**: Zero-trust networking

**Files Modified:**
- `03-airgap-zone/manifests/app/01-namespace.yaml` - Added PSS labels
- `03-airgap-zone/manifests/app/02-redis.yaml` - Added full securityContext
- `03-airgap-zone/manifests/app/03-lumen-api.yaml` - Added seccompProfile

### Estimated time: 1 hour

---

## 📋 Phase 17 (Optional): Cilium CNI Migration

**Goal**: Migrate from Flannel to Cilium for advanced L7 NetworkPolicies and eBPF performance.

### Tasks:
- [ ] Download Cilium charts and images in connected zone
- [ ] Push Cilium images to transit registry
- [ ] Delete current K3s cluster
- [ ] Recreate K3s with `--flannel-backend=none`
- [ ] Install Cilium CNI in airgap mode
- [ ] Test cluster networking
- [ ] Move `examples/cilium/*.yaml` to `manifests/network-policies/`
- [ ] Deploy Cilium NetworkPolicies (L7 HTTP filtering)
- [ ] Install Hubble for network observability
- [ ] Document Cilium features and benefits

### Files to modify:
- Move `examples/cilium/06-block-internet-cilium.yaml` back to `manifests/network-policies/`

### Estimated time: 3-4 hours

---

## 📋 Phase 15: Complete Observability Stack (Logs + Traces) ✅ COMPLETE

**Goal**: Add logs and traces to complement existing metrics (kube-prometheus-stack).

### Tasks:
- [x] Deploy Loki 3.6.5 for log aggregation (SingleBinary + filesystem, no MinIO)
- [x] Deploy Grafana Alloy v1.13.1 to collect pod logs (replaces deprecated Promtail)
- [x] Configure Loki datasource in Grafana
- [x] Add Go pprof endpoints to lumen-api (/debug/pprof/*)
- [x] Migrate lumen-api logging to structured JSON (slog) for Loki indexing
- [x] Rebuild lumen-api v1.1.0 with pprof + slog
- [x] Deploy Grafana Tempo 2.10.0 for distributed tracing (Helm monolithic + filesystem)
- [x] Instrument lumen-api v1.2.0 with OpenTelemetry Go SDK v1.37.0 (OTLP HTTP → Tempo)
- [x] Configure Grafana datasource Tempo + Loki↔Tempo correlation
- [x] Add Traefik IngressRoute for tempo.airgap.local
- [x] Add NetworkPolicies (lumen → monitoring:4318 OTLP)

### 3 Pillars of Observability:
- ✅ **Metrics**: kube-prometheus-stack (Prometheus 3.5.1 + Grafana 12.4.0)
- ✅ **Logs**: Loki 3.6.5 + Grafana Alloy v1.13.1 (Promtail is EOL March 2026)
- ✅ **Traces**: Grafana Tempo 2.10.0 + OpenTelemetry Go SDK v1.37.0

**Status**: ✅ Complete (February 18, 2026)

**Key decisions:**
- loki-stack deprecated → using grafana/loki chart v6.53.0
- Promtail EOL March 2026 → replaced by Grafana Alloy v1.13.1
- Storage: filesystem (no S3/MinIO) for single-node airgap
- OTel middleware wraps all HTTP handlers → automatic span per request
- trace_id injected in slog logs → Loki log → click → open Tempo trace
- lumen-api v1.2.0: Health + Hello handlers have child spans for Redis calls

**Access:**
- Tempo: https://tempo.airgap.local (add to /etc/hosts after push)

### Estimated time: 2-3 hours

---

## 📋 Other Future Improvements

### ArgoCD Production Hardening
- [ ] **Redis HA (High Availability)** ⚠️ Requires multi-node cluster
  - Deploy 3 Redis replicas with Sentinel for failover
  - Add anti-affinity rules to spread Redis pods across nodes (node-1, node-2, node-3)
  - Configure resource limits (CPU/Memory) to prevent OOM
  - Use proper storage class instead of local-path (e.g., Longhorn, Rook-Ceph)
  - Implement automated PVC backups to object storage
  - Current status: Basic persistence with PVC (dev/staging ready) ✅
  - Production status: Single pod, no HA ⚠️
  - **Note**: True HA requires multi-node — on single-node K3s, if the node crashes everything crashes regardless. OrbStack supports multi-node K3s clusters when needed.

### Security
- [ ] Add Falco for runtime security monitoring
- [x] Implement Pod Security Standards (PSS) ✅ Phase 14
- [ ] Add HashiCorp Vault for secrets management
- [ ] Enable mTLS between services

### Platform
- [x] Add Helm charts for easier deployment (✅ Traefik via Helm)
- [x] Migrate monitoring to kube-prometheus-stack Helm chart (✅ Phase 10 Complete)
- [ ] Implement blue/green deployments
- [x] Add horizontal pod autoscaling (HPA) — manifest deployed ✅, but HPA shows `<unknown>` metrics
  - **Root cause**: OrbStack K3s (macOS) kubelet `/stats/summary` does not expose per-pod stats, only node-level metrics
  - Metrics Server runs fine (node metrics work), but pod-level CPU/memory unavailable
  - **This is an OrbStack dev environment limitation** — on real Linux K3s (bare metal/VM), HPA works correctly
  - HPA manifest ([04-hpa.yaml](03-airgap-zone/manifests/app/04-hpa.yaml)) is correct for production
  - OrbStack IS a real Kubernetes cluster (K3s v1.33.x), just with cgroup stats limitations on macOS
- [ ] Deploy Istio service mesh

### CI/CD
- [ ] Add GitHub Actions workflows
- [ ] Implement automated testing pipeline
- [ ] Add container scanning (Trivy)
- [ ] Implement image signing (Sigstore/Cosign)

---

## 📝 Notes

- **Priority**: Phase 10 (Cilium) is optional and can be done anytime
- **Documentation**: Update `docs/DEPLOYMENT.md` after each phase ✅
- **Testing**: Always test in airgap environment before committing ✅
- **Git**: Commit after each phase completion for clean history ✅

---

---

## 📋 Phase 16: Migration vers VM Linux (Multipass)

**Goal**: Quitter OrbStack K3s pour une vraie VM Linux afin de valider le comportement production (HPA, métriques par pod, cgroups réels).

**Pourquoi ?**
- OrbStack K3s tourne dans une VM macOS légère : le kubelet n'expose pas les stats cgroups par pod
- HPA (`<unknown>` metrics), comportement réseau et storage différent du vrai Linux
- Une VM Multipass = même comportement que bare metal / cloud server

### Tasks:
- [ ] Installer Multipass sur macOS (`brew install multipass`)
- [ ] Créer VM Ubuntu 24.04 (4 CPU, 8G RAM, 40G disk)
- [ ] Installer K3s en mode airgap sur la VM (sans accès internet)
- [ ] Reconfigurer le registre local (localhost:5000) accessible depuis la VM
- [ ] Re-déployer la stack complète (ArgoCD, Gitea, Traefik, monitoring, lumen-api)
- [ ] Valider HPA avec métriques réelles (CPU/memory par pod)
- [ ] Valider Redis HA possible (multi-node si besoin)
- [ ] Documenter la migration OrbStack → Multipass

### Architecture cible (2 nodes, M2 16GB) :
```
macOS (zone connectée + transit)
  ├── Docker (OrbStack sans K8s) — registry localhost:5000
  └── Multipass VMs (zone airgap)
        ├── node-1 : 6 CPU, 6G RAM, 40G — control plane + workloads
        └── node-2 : 2 CPU, 4G RAM, 30G — worker
              ├── lumen-api (HPA fonctionnel ✅)
              ├── Redis + PostgreSQL CNPG (Phase 18)
              ├── Loki + Alloy + Tempo + kube-prometheus-stack
              └── Traefik + ArgoCD + Gitea
```

### Estimated time: 3-4 hours

---

---

## 📋 Phase 18: CloudNativePG + PostgreSQL Master/Replica

**Goal**: Déployer un cluster PostgreSQL production-grade avec CloudNativePG operator, et enrichir lumen-api avec des routes CRUD réelles (lecture sur replica, écriture sur master).

**Pourquoi CloudNativePG ?**
- Operator K8s natif (même pattern que Prometheus Operator)
- Master/replica automatique avec failover et promotion automatique
- Deux services distincts : `-rw` (master) et `-ro` (replicas) → read/write splitting
- Métriques Prometheus intégrées (ServiceMonitor compatible)
- PgBouncer connection pooling intégré
- WAL archiving pour les backups
- Très utilisé en production (CNCF sandbox project)

**Ce que ça apporte au projet :**
- Operator pattern avancé via CRD `Cluster`
- Gestion de PVC pour la persistance des données
- Read/write splitting : lumen-api route les SELECT sur `-ro`, les INSERT sur `-rw`
- Failover test : tuer le master → observer la promotion du replica
- Traces distribuées OTel : lumen-api → PostgreSQL (spans de requêtes SQL)
- Métriques PostgreSQL dans Grafana (connections, query time, replication lag)

**Nouvelles routes lumen-api v1.3.0 :**
```
POST /items        → INSERT dans PostgreSQL (via service -rw)
GET  /items        → SELECT depuis replica (via service -ro)
GET  /items/:id    → SELECT by ID
DELETE /items/:id  → DELETE (via service -rw)
```

**Architecture cible :**
```
lumen namespace
  ├── lumen-api (v1.3.0)
  │     ├── Redis (counter existant)
  │     └── PostgreSQL CNPG cluster
  │           ├── lumen-db-rw (master)   ← writes
  │           ├── lumen-db-ro (replica)  ← reads
  │           └── lumen-db-w  (witness)  ← vote uniquement (pas de données)
  └── CloudNativePG Operator (namespace: cnpg-system)
```

**Quorum et élection du leader :**

PostgreSQL HA nécessite un nombre impair de votes pour éviter le split-brain :
```
Quorum = (N / 2) + 1

2 nodes (master + replica)          → quorum = 2 → 0 panne tolérée ⚠️
3 nodes (master + replica + replica) → quorum = 2 → 1 panne tolérée ✅
3 nodes (master + replica + witness) → quorum = 2 → 1 panne tolérée ✅
```

**Pourquoi 1 master + 1 replica + 1 witness (et pas 3 nodes complets) ?**
- Avec 2 nodes (master + replica) : si le master tombe, la replica ne sait pas si le master est vraiment mort ou juste injoignable → risque de **split-brain** (les deux se proclament master → corruption)
- Le **witness** est un 3ème votant sans données — très léger en RAM (~50MB) — qui départage en cas de doute
- CNPG supporte nativement les witness nodes via `instances: 3` + `replicationSlots`

**Comportement en cas de panne :**
```
master tombe
  → replica + witness votent (quorum = 2 ✅)
  → replica promue master automatiquement
  → lumen-api reconnecte via service -rw (CNPG met à jour les endpoints)
  → downtime < 30 secondes
```

### Tasks:
- [ ] Télécharger CNPG operator + image PostgreSQL en connected zone
- [ ] Pousser les images dans le registry transit
- [ ] Déployer CNPG operator en airgap (manifests ou Helm)
- [ ] Créer un `Cluster` CNPG (1 master + 1 replica, PVC local-path)
- [ ] Configurer NetworkPolicies lumen → cnpg (port 5432)
- [ ] Ajouter driver `pgx` à lumen-api (`github.com/jackc/pgx/v5`)
- [ ] Implémenter les routes POST/GET /items avec read/write splitting
- [ ] Ajouter spans OTel pour les requêtes SQL
- [ ] Créer ServiceMonitor pour les métriques CNPG
- [ ] Ajouter dashboard Grafana PostgreSQL
- [ ] Tester le failover (tuer le master, observer la promotion)
- [ ] Documenter l'architecture CNPG

### Dépendances :
- Phase 16 (Multipass) recommandée avant — les PVC persistent mieux sur vrai Linux
- Phase 19 (Vault) après — pour stocker les credentials PostgreSQL proprement

### Estimated time: 4-5 hours

---

**Last Updated**: February 18, 2026
**Current Phase**: 15 (Observability Stack - COMPLETE ✅)
**Next Phase**: Phase 16 (Multipass VM) → Phase 18 (CNPG PostgreSQL) → Phase 19 (Vault)
