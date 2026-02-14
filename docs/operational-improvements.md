# Operational Improvements - Lumen Project

This document covers operational improvements and production hardening applied to the Lumen airgap Kubernetes project.

## Table of Contents
- [ArgoCD Redis Persistence](#argocd-redis-persistence)
- [ArgoCD NetworkPolicies (Redis Connectivity)](#argocd-networkpolicies-redis-connectivity)
- [AlertManager Integration](#alertmanager-integration)
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

This document covered three major operational improvements to Lumen:

1. **Redis Persistence** - Ensures ArgoCD cache survives pod restarts
2. **NetworkPolicies** - Fixed Redis connectivity for all ArgoCD components
3. **AlertManager** - Integrated alerting for proactive monitoring

These improvements move the project from a basic GitOps setup toward a production-ready airgap platform.

**Next Steps (see [TODO.md](../TODO.md)):**
- Phase 8: Full Airgap with Gitea (remove GitHub dependency)
- Redis HA for production-grade ArgoCD
- Ingress Controller for persistent service access
- Complete observability with Loki (logs) and Tempo (traces)
