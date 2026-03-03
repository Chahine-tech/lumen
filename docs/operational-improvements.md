# Operational Improvements - Lumen Project

> **Historical reference** — This document tracks incremental fixes applied during early phases of the project. For current architecture and up-to-date operational notes, see [architecture.md](architecture.md).

This document covers operational improvements and production hardening applied to the Lumen airgap Kubernetes project.

## Table of Contents
- [ArgoCD Redis Persistence](#argocd-redis-persistence)
- [ArgoCD NetworkPolicies (Redis Connectivity)](#argocd-networkpolicies-redis-connectivity)
- [AlertManager Integration](#alertmanager-integration)
- [Gitea Internal Git Server](#gitea-internal-git-server)
- [Troubleshooting](#troubleshooting)

---

## ArgoCD Redis Persistence

### Why Redis Persistence?

ArgoCD uses Redis as a cache for:
- Git repository manifests
- Application state
- UI session data

**Without persistence:**
- Every Redis pod restart = cache loss
- ArgoCD must re-fetch all manifests from Git
- Slower application sync times
- Poor user experience (session loss)

**With persistence:**
- Redis data survives pod restarts
- Faster ArgoCD performance
- Better reliability

### Implementation

**File:** `03-airgap-zone/manifests/argocd/03-redis-persistence-patch.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: argocd-redis-pvc
  namespace: argocd
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: local-path
```

**Storage backend:**
- K3s `local-path` provisioner (development/staging)
- For production: Use Longhorn, Rook-Ceph, or cloud storage class

**Redis persistence mechanisms:**
- **RDB (Redis Database)**: Periodic snapshots
- **AOF (Append Only File)**: Log of every write operation

### Deployment Commands

```bash
# Apply the PVC
kubectl apply -f 03-airgap-zone/manifests/argocd/03-redis-persistence-patch.yaml

# Patch the Redis deployment to use the PVC
kubectl get deployment argocd-redis -n argocd -o json | \
  jq '.spec.template.spec.volumes += [{"name":"data","persistentVolumeClaim":{"claimName":"argocd-redis-pvc"}}] |
      .spec.template.spec.containers[0].volumeMounts += [{"name":"data","mountPath":"/data"}]' | \
  kubectl apply -f -

# Verify PVC is bound
kubectl get pvc -n argocd

# Verify Redis pod is using the volume
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-redis -o jsonpath='{.items[0].spec.volumes}'
```

### Verification

Test that data persists across pod restarts:

```bash
# Write test data to Redis
kubectl exec -n argocd deployment/argocd-redis -- redis-cli SET test-key "data-persists"

# Delete the Redis pod (it will be recreated)
kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-redis

# Wait for pod to restart
kubectl wait --for=condition=ready pod -n argocd -l app.kubernetes.io/name=argocd-redis --timeout=60s

# Verify data still exists
kubectl exec -n argocd deployment/argocd-redis -- redis-cli GET test-key
# Expected output: "data-persists"
```

### Production Considerations

**Current Status:**
- ✅ Basic persistence with PVC (dev/staging ready)
- ⚠️ Single pod, no HA (not production-ready)

**For Production:**
- [ ] Deploy Redis with 3 replicas + Sentinel for failover
- [ ] Add anti-affinity rules to spread Redis pods across nodes
- [ ] Configure resource limits (CPU/Memory) to prevent OOM
- [ ] Use proper storage class instead of local-path
- [ ] Implement automated PVC backups to object storage

See [TODO.md](../TODO.md) for Redis HA roadmap.

---

## ArgoCD NetworkPolicies (Redis Connectivity)

### Problem

After deploying Redis persistence, ArgoCD applications showed "Unknown" status with errors:

```
ComparisonError: Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: code = Unknown desc = dial tcp 10.43.131.200:6379: connect: connection refused
```

**Root Cause:** NetworkPolicies were blocking egress from ArgoCD components to Redis on port 6379.

### ArgoCD Components Architecture

ArgoCD has 3 main components, all requiring Redis access:

1. **argocd-server** (UI/API)
   - Serves the web UI and API
   - Uses Redis for session storage and caching UI data (logs, events)

2. **argocd-repo-server** (Git repository manager)
   - Clones Git repositories
   - Generates Kubernetes manifests
   - Uses Redis to cache manifests (avoids repeated Git operations)

3. **argocd-application-controller** (Reconciliation engine)
   - Compares desired state (Git) vs actual state (cluster)
   - Triggers sync operations
   - Uses Redis to cache application state

### Solution

**File:** `03-airgap-zone/manifests/network-policies/09-allow-argocd.yaml`

Added Redis egress rules to all three components:

#### 1. argocd-server → Redis

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-argocd-server
  namespace: argocd
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: argocd-server
  policyTypes:
    - Egress
  egress:
    # Allow Redis cache access
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: argocd-redis
      ports:
        - protocol: TCP
          port: 6379
```

#### 2. argocd-repo-server → Redis

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-argocd-repo-server
  namespace: argocd
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: argocd-repo-server
  policyTypes:
    - Egress
  egress:
    # Allow Redis cache access
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: argocd-redis
      ports:
        - protocol: TCP
          port: 6379
```

#### 3. argocd-application-controller → Redis

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-argocd-application-controller
  namespace: argocd
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: argocd-application-controller
  policyTypes:
    - Egress
  egress:
    # Allow Redis cache access
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: argocd-redis
      ports:
        - protocol: TCP
          port: 6379
```

#### 4. argocd-redis Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-argocd-redis
  namespace: argocd
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: argocd-redis
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: argocd-server
      ports:
        - protocol: TCP
          port: 6379
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: argocd-repo-server
      ports:
        - protocol: TCP
          port: 6379
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: argocd-application-controller
      ports:
        - protocol: TCP
          port: 6379
```

### Deployment

```bash
# Apply the NetworkPolicy fixes
kubectl apply -f 03-airgap-zone/manifests/network-policies/09-allow-argocd.yaml

# Verify ArgoCD pods can reach Redis
kubectl exec -n argocd deployment/argocd-server -- nc -zv argocd-redis 6379
kubectl exec -n argocd deployment/argocd-repo-server -- nc -zv argocd-redis 6379
kubectl exec -n argocd deployment/argocd-application-controller -- nc -zv argocd-redis 6379
```

### Verification

After applying the NetworkPolicies:

1. **Check ArgoCD application status:**
   ```bash
   kubectl get applications -n argocd
   ```
   All applications should show "Healthy" and "Synced" (not "Unknown")

2. **Check ArgoCD UI:**
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8081:443
   ```
   Navigate to https://localhost:8081 - logs and events should load properly

3. **Monitor ArgoCD logs:**
   ```bash
   kubectl logs -n argocd deployment/argocd-server --tail=50
   kubectl logs -n argocd deployment/argocd-repo-server --tail=50
   kubectl logs -n argocd deployment/argocd-application-controller --tail=50
   ```
   No "connection refused" errors should appear

---

## AlertManager Integration

### Overview

AlertManager handles alerts sent by Prometheus. It takes care of:
- **Deduplicating** alerts (multiple identical alerts → single notification)
- **Grouping** related alerts together
- **Routing** alerts to different receivers (Slack, email, PagerDuty, etc.)
- **Silencing** alerts during maintenance windows
- **Inhibition** (suppress alerts based on other active alerts)

### Deployment

**File:** `03-airgap-zone/manifests/monitoring/04-alertmanager.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: alertmanager-config
  namespace: monitoring
data:
  alertmanager.yml: |
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'cluster', 'service']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 12h
      receiver: 'default-receiver'
    receivers:
      - name: 'default-receiver'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: alertmanager
  template:
    metadata:
      labels:
        app: alertmanager
    spec:
      containers:
      - name: alertmanager
        image: registry.transit.local:5000/prom/alertmanager:v0.27.0
        args:
          - '--config.file=/etc/alertmanager/alertmanager.yml'
          - '--storage.path=/alertmanager'
        ports:
        - containerPort: 9093
        volumeMounts:
        - name: config
          mountPath: /etc/alertmanager
      volumes:
      - name: config
        configMap:
          name: alertmanager-config
---
apiVersion: v1
kind: Service
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  selector:
    app: alertmanager
  ports:
    - protocol: TCP
      port: 9093
      targetPort: 9093
```

### Prometheus Configuration

**File:** `03-airgap-zone/manifests/monitoring/02-prometheus.yaml`

Added AlertManager configuration to Prometheus:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    # AlertManager configuration
    alerting:
      alertmanagers:
        - static_configs:
            - targets:
                - alertmanager:9093

    # Load alert rules
    rule_files:
      - '/etc/prometheus/rules/*.yml'

    scrape_configs:
      # ... existing scrape configs ...
```

### Alert Rules

**File:** `03-airgap-zone/manifests/monitoring/05-prometheus-rules.yaml`

Created comprehensive alert rules covering:

**Lumen API Alerts:**
- `LumenAPIDown` - API is not responding
- `LumenAPIHighErrorRate` - More than 5% of requests failing
- `LumenAPIHighLatency` - P95 latency > 500ms

**ArgoCD Alerts:**
- `ArgocdAppUnhealthy` - Application in degraded state
- `ArgocdAppOutOfSync` - Application not synced with Git
- `RedisDown` - Redis pod is down

**Cluster Health Alerts:**
- `KubernetesNodeNotReady` - Node in NotReady state
- `KubernetesPodCrashLooping` - Pod restarting frequently
- `KubernetesDeploymentReplicasMismatch` - Desired ≠ Available replicas

**Prometheus Self-Monitoring:**
- `PrometheusTargetDown` - Scrape target is down
- `PrometheusTooManyRestarts` - Prometheus restarting frequently

Example alert rule:

```yaml
groups:
  - name: lumen-api
    interval: 30s
    rules:
      - alert: LumenAPIDown
        expr: up{job="lumen-api"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Lumen API is down"
          description: "The Lumen API in namespace {{ $labels.namespace }} has been down for more than 1 minute."
```

### NetworkPolicies for AlertManager

**File:** `03-airgap-zone/manifests/network-policies/05-allow-monitoring.yaml`

Added NetworkPolicies to allow Prometheus → AlertManager communication:

```yaml
---
# Allow Prometheus to reach AlertManager
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: prometheus-egress
  namespace: monitoring
spec:
  podSelector:
    matchLabels:
      app: prometheus
  policyTypes:
    - Egress
  egress:
    # Allow communication with AlertManager
    - to:
        - podSelector:
            matchLabels:
              app: alertmanager
      ports:
        - protocol: TCP
          port: 9093
---
# Allow AlertManager to receive from Prometheus
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: alertmanager-ingress
  namespace: monitoring
spec:
  podSelector:
    matchLabels:
      app: alertmanager
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: prometheus
      ports:
        - protocol: TCP
          port: 9093
```

### Deployment Commands

```bash
# Deploy AlertManager
kubectl apply -f 03-airgap-zone/manifests/monitoring/04-alertmanager.yaml

# Update Prometheus configuration with AlertManager
kubectl apply -f 03-airgap-zone/manifests/monitoring/02-prometheus.yaml

# Deploy alert rules
kubectl apply -f 03-airgap-zone/manifests/monitoring/05-prometheus-rules.yaml

# Update NetworkPolicies
kubectl apply -f 03-airgap-zone/manifests/network-policies/05-allow-monitoring.yaml

# Verify AlertManager is running
kubectl get pods -n monitoring -l app=alertmanager

# Verify Prometheus loaded the rules
kubectl logs -n monitoring deployment/prometheus | grep "Loading configuration file"
```

### Accessing AlertManager UI

```bash
# Port-forward to AlertManager
kubectl port-forward -n monitoring svc/alertmanager 9093:9093

# Open in browser
open http://localhost:9093
```

**AlertManager UI features:**
- View active alerts
- Silence alerts temporarily
- See alert history
- Configure notification receivers

### Verification

1. **Check Prometheus targets:**
   ```bash
   kubectl port-forward -n monitoring svc/prometheus 9090:9090
   ```
   Navigate to http://localhost:9090/targets - AlertManager should show as "UP"

2. **Check alert rules loaded:**
   Navigate to http://localhost:9090/rules - All alert rules should be visible

3. **Check AlertManager receives alerts:**
   Navigate to http://localhost:9093 - Active alerts should appear

4. **Trigger a test alert:**
   ```bash
   # Scale down Lumen API to trigger LumenAPIDown alert
   kubectl scale deployment lumen-api -n default --replicas=0

   # Wait 1-2 minutes, then check AlertManager UI
   # Alert should appear as "FIRING"

   # Restore deployment
   kubectl scale deployment lumen-api -n default --replicas=3
   ```

### Future Improvements

Current AlertManager setup uses a default receiver (no notifications). To add real alerting:

1. **Slack Integration:**
   ```yaml
   receivers:
     - name: 'slack-notifications'
       slack_configs:
         - api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
           channel: '#alerts'
           title: 'Lumen Alert'
   ```

2. **Email Notifications:**
   ```yaml
   receivers:
     - name: 'email-notifications'
       email_configs:
         - to: 'ops-team@example.com'
           from: 'alertmanager@lumen.local'
           smarthost: 'smtp.example.com:587'
   ```

3. **PagerDuty Integration:**
   ```yaml
   receivers:
     - name: 'pagerduty-critical'
       pagerduty_configs:
         - service_key: 'YOUR_PAGERDUTY_SERVICE_KEY'
   ```

---

## Gitea Internal Git Server

### Overview

Phase 8 completes the **true airgap architecture** by deploying Gitea as an internal Git server. This eliminates the dependency on GitHub.com for ArgoCD GitOps operations.

**Problem:**
- ArgoCD was pulling manifests from GitHub.com (requires HTTPS/443 egress)
- This breaks true airgap isolation (no external Internet access allowed)
- In production airgap environments (military, government, secure enterprise), external connectivity is prohibited

**Solution:**
- Deploy **Gitea** (lightweight Git server) inside the airgap cluster
- Mirror the lumen repository from GitHub to Gitea
- Configure ArgoCD to pull from Gitea instead of GitHub
- Remove HTTPS/443 egress from ArgoCD NetworkPolicies
- Achieve **100% airgap isolation** ✅

### Architecture

```
GitHub (backup/portfolio)
   ↑
   | git push origin main
   |
[Developer PC]
   |
   | git push gitea main (via port-forward)
   ↓
Gitea (airgap internal)
   ↓
   | ArgoCD polls every 3 minutes
   ↓
ArgoCD auto-sync
   ↓
Applications deployed (lumen, monitoring, network-policies)
```

**Key Points:**
- GitHub: Source of truth, backup, portfolio visibility
- Gitea: Internal mirror for ArgoCD in airgap cluster
- No external Internet access required for deployments ✅

### Deployment

#### 1. Connected Zone - Download Gitea Image

**File:** `01-connected-zone/scripts/06-pull-gitea-images.sh`

```bash
#!/bin/bash
set -e

GITEA_VERSION="1.21.5"
ARTIFACTS_DIR="artifacts/gitea"

mkdir -p "$ARTIFACTS_DIR/images"

# Pull Gitea image
docker pull "gitea/gitea:${GITEA_VERSION}"

# Save to tar archive
docker save "gitea/gitea:${GITEA_VERSION}" -o "$ARTIFACTS_DIR/images/gitea.tar"

echo "gitea/gitea:${GITEA_VERSION}" > "$ARTIFACTS_DIR/images.txt"
```

**Execute:**
```bash
cd 01-connected-zone
chmod +x scripts/06-pull-gitea-images.sh
./scripts/06-pull-gitea-images.sh
```

#### 2. Transit Zone - Push to Registry

**File:** `02-transit-zone/push-gitea.sh`

```bash
#!/bin/bash
set -e

ARTIFACTS_DIR="../01-connected-zone/artifacts/gitea"
REGISTRY="localhost:5000"

# Load and push Gitea image
docker load -i "$ARTIFACTS_DIR/images/gitea.tar"

while IFS= read -r image; do
    image_name=$(echo "$image" | sed 's|^gitea/||')
    docker tag "$image" "$REGISTRY/$image_name"
    docker push "$REGISTRY/$image_name"
done < "$ARTIFACTS_DIR/images.txt"
```

**Execute:**
```bash
cd 02-transit-zone
chmod +x push-gitea.sh
./push-gitea.sh
```

#### 3. Airgap Zone - Deploy Gitea

**Files:**
- `03-airgap-zone/manifests/gitea/01-namespace.yaml`
- `03-airgap-zone/manifests/gitea/02-deployment.yaml`
- `03-airgap-zone/manifests/gitea/03-service.yaml`
- `03-airgap-zone/manifests/gitea/04-pvc.yaml`

**Gitea Deployment:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitea
  namespace: gitea
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gitea
  template:
    metadata:
      labels:
        app: gitea
    spec:
      containers:
      - name: gitea
        image: gitea/gitea:1.21.5  # Uses docker.io mirror
        ports:
        - containerPort: 3000
          name: http
        - containerPort: 22
          name: ssh
        env:
        - name: GITEA__database__DB_TYPE
          value: "sqlite3"
        - name: GITEA__database__PATH
          value: "/data/gitea/gitea.db"
        - name: GITEA__server__DOMAIN
          value: "gitea.gitea.svc.cluster.local"
        - name: GITEA__server__HTTP_PORT
          value: "3000"
        - name: GITEA__server__ROOT_URL
          value: "http://gitea.gitea.svc.cluster.local:3000/"
        - name: GITEA__security__INSTALL_LOCK
          value: "true"
        volumeMounts:
        - name: gitea-data
          mountPath: /data
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: gitea-data
        persistentVolumeClaim:
          claimName: gitea-pvc
```

**Storage:**
- SQLite database (no external PostgreSQL needed)
- 5Gi PersistentVolumeClaim for Git repositories
- Data persists across pod restarts

**Execute:**
```bash
cd 03-airgap-zone

# Deploy Gitea
kubectl apply -f manifests/gitea/01-namespace.yaml
kubectl apply -f manifests/gitea/04-pvc.yaml
kubectl apply -f manifests/gitea/02-deployment.yaml
kubectl apply -f manifests/gitea/03-service.yaml

# Wait for Gitea to start
kubectl wait --for=condition=ready pod -n gitea -l app=gitea --timeout=120s
```

#### 4. NetworkPolicies for Gitea

**File:** `03-airgap-zone/manifests/network-policies/10-allow-gitea.yaml`

```yaml
---
# Allow ArgoCD repo-server to clone from Gitea
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-gitea-ingress
  namespace: gitea
spec:
  podSelector:
    matchLabels:
      app: gitea
  policyTypes:
    - Ingress
  ingress:
    # Allow from ArgoCD repo-server
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: argocd
          podSelector:
            matchLabels:
              app.kubernetes.io/name: argocd-repo-server
      ports:
        - protocol: TCP
          port: 3000  # HTTP Git
        - protocol: TCP
          port: 22    # SSH Git
---
# Allow Gitea DNS access
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: gitea-egress
  namespace: gitea
spec:
  podSelector:
    matchLabels:
      app: gitea
  policyTypes:
    - Egress
  egress:
    # DNS for service discovery
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

**Updated ArgoCD NetworkPolicy:**

**File:** `03-airgap-zone/manifests/network-policies/09-allow-argocd.yaml`

**Changes:**
1. **Removed HTTPS/443 egress to GitHub** (breaks airgap)
2. **Added Gitea egress** for repo-server:

```yaml
# Allow argocd-repo-server to access Gitea
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: gitea
      podSelector:
        matchLabels:
          app: gitea
  ports:
    - protocol: TCP
      port: 3000  # HTTP Git
    - protocol: TCP
      port: 22    # SSH Git
```

**Execute:**
```bash
kubectl apply -f manifests/network-policies/10-allow-gitea.yaml
kubectl apply -f manifests/network-policies/09-allow-argocd.yaml
```

#### 5. Initialize Gitea

**Create admin user via CLI:**

```bash
# Port-forward to Gitea
kubectl port-forward -n gitea svc/gitea 3001:3000 &

# Wait for Gitea to be ready
sleep 5

# Create admin user
kubectl exec -n gitea deploy/gitea -- su git -c "gitea admin user create \
  --username gitea-admin \
  --password gitea-admin \
  --email admin@gitea.local \
  --admin"
```

**Create organization and repository via API:**

**File:** `03-airgap-zone/scripts/create-gitea-repo.sh`

```bash
#!/bin/bash
set -e

GITEA_URL="http://gitea.gitea.svc.cluster.local:3000"
GITEA_USER="gitea-admin"
GITEA_PASS="gitea-admin"

# Create organization 'lumen'
kubectl run gitea-create-org --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -X POST "${GITEA_URL}/api/v1/orgs" \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  -d '{"username":"lumen","full_name":"Lumen Organization"}'

# Create repository 'lumen' in organization
kubectl run gitea-create-repo --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -X POST "${GITEA_URL}/api/v1/orgs/lumen/repos" \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  -d '{"name":"lumen","description":"Lumen airgap Kubernetes project","private":false}'
```

**Execute:**
```bash
cd 03-airgap-zone/scripts
chmod +x create-gitea-repo.sh
./create-gitea-repo.sh
```

#### 6. Push Lumen Repository to Gitea

**Configure git remote:**

```bash
# Add Gitea remote (with credentials embedded)
git remote add gitea http://gitea-admin:gitea-admin@localhost:3001/lumen/lumen.git

# Push repository
git push gitea main --force
```

**Helper script:** `scripts/sync-gitea.sh`

```bash
#!/bin/bash
set -e

# Start port-forward if needed
if ! nc -z localhost 3001 2>/dev/null; then
    kubectl port-forward -n gitea svc/gitea 3001:3000 > /dev/null 2>&1 &
    sleep 3
fi

# Ensure gitea remote exists
if ! git remote get-url gitea > /dev/null 2>&1; then
    git remote add gitea http://gitea-admin:gitea-admin@localhost:3001/lumen/lumen.git
fi

# Push to Gitea
git push gitea main
```

#### 7. Update ArgoCD Applications

Update all 3 application manifests to use Gitea:

**Files to modify:**
- `03-airgap-zone/manifests/argocd/04-application-lumen.yaml`
- `03-airgap-zone/manifests/argocd/05-application-monitoring.yaml`
- `03-airgap-zone/manifests/argocd/06-application-network-policies.yaml`

**Change:**
```yaml
source:
  repoURL: https://github.com/Chahine-tech/lumen.git
```

**To:**
```yaml
source:
  repoURL: http://gitea.gitea.svc.cluster.local:3000/lumen/lumen.git
```

**Execute:**
```bash
# Update all applications
sed -i '' 's|https://github.com/Chahine-tech/lumen.git|http://gitea.gitea.svc.cluster.local:3000/lumen/lumen.git|g' \
  03-airgap-zone/manifests/argocd/04-application-lumen.yaml \
  03-airgap-zone/manifests/argocd/05-application-monitoring.yaml \
  03-airgap-zone/manifests/argocd/06-application-network-policies.yaml

# Apply updated applications
kubectl apply -f 03-airgap-zone/manifests/argocd/04-application-lumen.yaml
kubectl apply -f 03-airgap-zone/manifests/argocd/05-application-monitoring.yaml
kubectl apply -f 03-airgap-zone/manifests/argocd/06-application-network-policies.yaml
```

#### 8. Update ArgoCD Credentials

Create Gitea repository secret for ArgoCD:

```bash
# Create Gitea secret
kubectl create secret generic gitea-repo-secret -n argocd \
  --from-literal=url=http://gitea.gitea.svc.cluster.local:3000/lumen/lumen.git \
  --from-literal=username=gitea-admin \
  --from-literal=password=gitea-admin \
  --from-literal=type=git

# Label it for ArgoCD
kubectl label secret gitea-repo-secret -n argocd \
  argocd.argoproj.io/secret-type=repository

# Delete old GitHub secret (optional)
kubectl delete secret github-repo-secret -n argocd --ignore-not-found
```

#### 9. Deploy ArgoCD

ArgoCD deployment needs image references updated to use registry mirrors:

```bash
# Update ArgoCD manifest to use quay.io/docker.io prefixes (not direct registry IP)
# This allows registries.yaml mirrors to work properly

# Deploy ArgoCD with namespace flag
kubectl apply -n argocd -f 03-airgap-zone/manifests/argocd/02-install-airgap.yaml

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -n argocd -l app.kubernetes.io/name=argocd-server --timeout=120s
```

### GitOps Workflow

#### Daily Development Workflow

**Setup git alias (one-time):**

```bash
# Configure dual-push alias
git config --global alias.push-all '!git push origin main && git push gitea main'
```

**Daily workflow:**

```bash
# 1. Make changes to code/manifests
vim 03-airgap-zone/manifests/app/03-lumen-api.yaml

# 2. Commit changes
git add .
git commit -m "feat: update lumen API configuration"

# 3. Push to both remotes
git push-all
# This pushes to:
#   - origin (GitHub) → backup, portfolio
#   - gitea (internal) → ArgoCD source
```

**ArgoCD auto-sync:**
- ArgoCD polls Gitea every 3 minutes
- Detects changes automatically
- Syncs applications to match Git state
- No manual intervention needed ✅

#### Port-Forward Helper Script

**File:** `scripts/start-port-forwards.sh`

```bash
#!/bin/bash
set -e

# Kill existing port-forwards
pkill -f 'kubectl port-forward' 2>/dev/null || true
sleep 2

# Start all port-forwards
kubectl port-forward -n argocd svc/argocd-server 8081:443 > /dev/null 2>&1 &
kubectl port-forward -n gitea svc/gitea 3001:3000 > /dev/null 2>&1 &
kubectl port-forward -n monitoring svc/grafana 3000:3000 > /dev/null 2>&1 &
kubectl port-forward -n monitoring svc/prometheus 9090:9090 > /dev/null 2>&1 &
kubectl port-forward -n monitoring svc/alertmanager 9093:9093 > /dev/null 2>&1 &

echo "✅ All services accessible!"
echo "ArgoCD:      https://localhost:8081"
echo "Gitea:       http://localhost:3001 (gitea-admin/gitea-admin)"
echo "Grafana:     http://localhost:3000 (admin/admin)"
echo "Prometheus:  http://localhost:9090"
echo "AlertManager: http://localhost:9093"
```

### Verification

#### 1. Verify Gitea is Running

```bash
# Check Gitea pod
kubectl get pods -n gitea

# Expected:
# NAME                    READY   STATUS    RESTARTS   AGE
# gitea-xxxxxxxxxx-xxxxx  1/1     Running   0          5m

# Check Gitea service
kubectl get svc -n gitea

# Check PVC
kubectl get pvc -n gitea
```

#### 2. Verify Repository in Gitea

```bash
# Port-forward to Gitea
kubectl port-forward -n gitea svc/gitea 3001:3000

# Open in browser
open http://localhost:3001/lumen/lumen
```

Should show the lumen repository with all files.

#### 3. Verify ArgoCD Uses Gitea

```bash
# Check ArgoCD applications
kubectl get applications -n argocd

# Expected: All applications "Synced" and "Healthy"

# Check repo-server logs
kubectl logs -n argocd deployment/argocd-repo-server --tail=20 | grep gitea

# Should see: "RepoURL:http://gitea.gitea.svc.cluster.local:3000/lumen/lumen.git"
```

#### 4. Verify No External Access

```bash
# Test that repo-server CANNOT reach GitHub
kubectl exec -n argocd deployment/argocd-repo-server -- timeout 5 curl -I https://github.com 2>&1

# Expected: Timeout or connection refused (NetworkPolicy blocks HTTPS/443)
```

#### 5. Test GitOps Workflow

```bash
# Make a test change
echo "# Test GitOps" >> 03-airgap-zone/manifests/app/01-namespace.yaml

# Commit and push
git add .
git commit -m "test: verify GitOps sync from Gitea"
git push-all

# Wait 3 minutes for ArgoCD to poll
sleep 180

# Check if ArgoCD detected the change
kubectl get applications -n argocd -o wide
```

### Production Considerations

**Current Status:**
- ✅ Gitea deployed with SQLite (dev/staging ready)
- ✅ ArgoCD pulling from internal Gitea
- ✅ 100% airgap isolation achieved
- ⚠️ Single Gitea pod, no HA

**For Production:**

1. **Gitea High Availability:**
   - Deploy PostgreSQL for Gitea database (instead of SQLite)
   - Run Gitea with 3 replicas + load balancer
   - Add anti-affinity rules

2. **Backup Strategy:**
   - Automated PVC snapshots to object storage
   - Regular database backups
   - Disaster recovery plan

3. **Access Method:**
   - Replace port-forward with Ingress Controller
   - Configure internal DNS (gitea.internal.company.com)
   - TLS/SSL with internal CA certificates

4. **Monitoring:**
   - Add Gitea metrics to Prometheus
   - Alert on repository sync failures
   - Monitor disk usage (PVC)

5. **Security Hardening:**
   - Change default credentials
   - Enable 2FA for Gitea admin
   - Implement RBAC for repositories
   - Regular security updates

### Troubleshooting

See main [Troubleshooting](#troubleshooting) section below.

**Common Gitea Issues:**

**ImagePullBackOff for Gitea:**
- Ensure image uses `gitea/gitea:1.21.5` (not `192.168.107.2:5000/...`)
- This allows registries.yaml docker.io mirror to work

**ArgoCD can't clone from Gitea:**
- Check NetworkPolicy allows repo-server → gitea:3000
- Verify Gitea repository URL in application manifest
- Check ArgoCD repository secret exists

**Port-forward dies:**
- Use `scripts/start-port-forwards.sh` to restart all at once
- For production, deploy Ingress Controller instead

---

## Troubleshooting

### ArgoCD Applications Stuck in "Unknown" Status

**Symptom:**
```
Application conditions ComparisonError Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: code = Unknown desc = dial tcp 10.43.131.200:6379: connect: connection refused
```

**Root Cause:** NetworkPolicy blocking ArgoCD components from accessing Redis.

**Solution:**
1. Verify Redis is running:
   ```bash
   kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-redis
   ```

2. Check NetworkPolicy allows egress to Redis:
   ```bash
   kubectl get netpol -n argocd
   kubectl describe netpol allow-argocd-server -n argocd
   kubectl describe netpol allow-argocd-repo-server -n argocd
   kubectl describe netpol allow-argocd-application-controller -n argocd
   ```

3. Apply the fixed NetworkPolicy:
   ```bash
   kubectl apply -f 03-airgap-zone/manifests/network-policies/09-allow-argocd.yaml
   ```

4. Restart ArgoCD components:
   ```bash
   kubectl rollout restart deployment argocd-server -n argocd
   kubectl rollout restart deployment argocd-repo-server -n argocd
   kubectl rollout restart deployment argocd-application-controller -n argocd
   ```

5. Verify connectivity:
   ```bash
   kubectl exec -n argocd deployment/argocd-server -- nc -zv argocd-redis 6379
   ```

### ArgoCD UI Not Loading Logs/Events

**Symptom:** ArgoCD UI shows "Unable to load data: error getting cached app managed resources: dial tcp refused"

**Root Cause:** `argocd-server` pod cannot reach Redis (same as above).

**Solution:** Same as above - ensure `argocd-server` NetworkPolicy allows Redis egress.

### ArgoCD Not Auto-Syncing

**Symptom:** Changes pushed to GitHub don't trigger automatic sync in ArgoCD.

**Possible Causes:**

1. **Application status is "Unknown"**
   - ArgoCD skips auto-sync when application health is unknown
   - Fix Redis connectivity first (see above)

2. **Auto-sync disabled**
   ```bash
   kubectl get application -n argocd lumen-api -o yaml | grep automated
   ```
   Should show:
   ```yaml
   automated:
     prune: true
     selfHeal: true
   ```

3. **ArgoCD polling interval**
   - Default: ArgoCD polls Git every 3 minutes
   - Manual sync: `argocd app sync lumen-api`

4. **GitHub connectivity**
   - Verify ArgoCD can reach GitHub.com (repo-server needs HTTPS egress)
   ```bash
   kubectl exec -n argocd deployment/argocd-repo-server -- curl -I https://github.com
   ```

### Redis Data Not Persisting

**Symptom:** Redis data disappears after pod restart.

**Diagnosis:**
```bash
# Check if PVC exists and is bound
kubectl get pvc -n argocd argocd-redis-pvc

# Check if Redis pod has the volume mounted
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-redis -o jsonpath='{.items[0].spec.volumes}'

# Check volume mounts
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-redis -o jsonpath='{.items[0].spec.containers[0].volumeMounts}'
```

**Solution:**
Ensure the Redis deployment has the PVC mounted at `/data`:
```bash
kubectl get deployment argocd-redis -n argocd -o json | \
  jq '.spec.template.spec.volumes += [{"name":"data","persistentVolumeClaim":{"claimName":"argocd-redis-pvc"}}] |
      .spec.template.spec.containers[0].volumeMounts += [{"name":"data","mountPath":"/data"}]' | \
  kubectl apply -f -
```

### Port-Forward Keeps Dying

**Symptom:** `kubectl port-forward` exits after pod restart or network interruption.

**Explanation:** Port-forward is **not persistent** - it's a temporary tunnel that dies when:
- The pod restarts
- Network connection drops
- You close the terminal

**Workarounds:**

1. **Auto-restart script:**
   ```bash
   while true; do
     kubectl port-forward svc/argocd-server -n argocd 8081:443
     echo "Port-forward died, restarting in 2 seconds..."
     sleep 2
   done
   ```

2. **Use Ingress Controller (recommended for production):**
   Deploy Traefik/Nginx Ingress and create IngressRoutes for persistent access.

3. **Use NodePort service:**
   ```bash
   kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort"}}'
   kubectl get svc argocd-server -n argocd
   # Access via http://<node-ip>:<nodeport>
   ```

### Prometheus Not Scraping Targets

**Symptom:** Prometheus targets show as "DOWN" in UI.

**Diagnosis:**
```bash
# Check Prometheus logs
kubectl logs -n monitoring deployment/prometheus | grep -i error

# Check NetworkPolicy allows egress to scrape targets
kubectl describe netpol prometheus-egress -n monitoring

# Test connectivity from Prometheus pod
kubectl exec -n monitoring deployment/prometheus -- wget -O- http://lumen-api.default.svc.cluster.local:8080/metrics
```

**Solution:**
Ensure `prometheus-egress` NetworkPolicy allows egress to all namespaces:
```yaml
egress:
  - to:
      - namespaceSelector: {}
    ports:
      - protocol: TCP
        port: 8080
```

### AlertManager Not Receiving Alerts

**Symptom:** Alerts firing in Prometheus but not visible in AlertManager.

**Diagnosis:**
```bash
# Check Prometheus can reach AlertManager
kubectl exec -n monitoring deployment/prometheus -- wget -O- http://alertmanager:9093

# Check Prometheus configuration
kubectl get cm prometheus-config -n monitoring -o yaml | grep -A5 alerting

# Check AlertManager logs
kubectl logs -n monitoring deployment/alertmanager
```

**Solution:**
Verify Prometheus ConfigMap has AlertManager targets:
```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093
```

---

## Summary

This document covered four major operational improvements to Lumen:

1. **Redis Persistence** - Ensures ArgoCD cache survives pod restarts
2. **NetworkPolicies** - Fixed Redis connectivity for all ArgoCD components
3. **AlertManager** - Integrated alerting for proactive monitoring
4. **Gitea Internal Git Server** - Achieved true 100% airgap isolation by removing GitHub dependency

These improvements transform the project from a basic GitOps setup to a **production-grade airgap platform**.

**Key Achievements:**
- ✅ ArgoCD pulls from internal Gitea (not external GitHub)
- ✅ No HTTPS/443 egress required (NetworkPolicies enforce airgap)
- ✅ Complete GitOps workflow: `git push-all` → ArgoCD auto-sync → Apps deployed
- ✅ True airgap architecture suitable for secure/classified environments

**Next Steps (see [TODO.md](../TODO.md)):**
- Phase 9: Ingress Controller for persistent service access (Traefik)
- Redis HA for production-grade ArgoCD
- Gitea HA with PostgreSQL backend
- Complete observability with Loki (logs) and Tempo (traces)
- Secrets management with Vault or Sealed Secrets
