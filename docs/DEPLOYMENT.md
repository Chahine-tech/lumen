# Deployment Guide - Lumen Airgap Project

This document describes the actual deployment process and results.

## 🏗️ Architecture Overview

```
┌──────────────────────┐   ┌──────────────────────┐   ┌──────────────────────┐
│  Connected Zone      │──▶│  Transit Zone        │──▶│  Airgap Zone (K3s)   │
│  (Local Mac)         │   │  (Docker Registry)   │   │  (k3d cluster)       │
├──────────────────────┤   ├──────────────────────┤   ├──────────────────────┤
│ • Build Go app       │   │ • Docker Registry v2 │   │ • 3 nodes (1+2)      │
│ • Create images      │   │ • Registry UI        │   │ • Lumen API (2 pods) │
│ • Package artifacts  │   │ • 4 images stored    │   │ • Redis (1 pod)      │
└──────────────────────┘   │ • IP: 192.168.107.6  │   │ • No internet access │
                           └──────────────────────┘   └──────────────────────┘
```

## 📦 Phase 1: Connected Zone - Build

### Commands

```bash
cd 01-connected-zone
./build.sh
```

### Results

```
✅ Go binary built: 18MB
✅ Docker images created:
   - lumen-api:v1.0.0 (36MB)
   - redis:7-alpine (41MB)
✅ Artifacts saved:
   - artifacts/images/lumen-api.tar
   - artifacts/images/redis.tar
   - artifacts/images-list.txt
```

### Code Quality

The Go application was refactored following production best practices:

- ✅ **No global variables** - Using `App` struct pattern
- ✅ **Request context** - `r.Context()` everywhere
- ✅ **Error handling** - All errors checked
- ✅ **Middleware architecture** - Logging, Metrics, Recovery
- ✅ **Graceful shutdown** - SIGTERM/SIGINT handling
- ✅ **HTTP timeouts** - Read/Write/Idle configured

## 📦 Phase 2: Transit Zone - Registry

### Commands

```bash
cd 02-transit-zone
./setup.sh
```

### Results

```
✅ Docker Registry started on port 5000
✅ Registry UI available on port 8081
✅ File server available on port 8082
✅ Network: k3d-lumen-airgap
✅ Registry IP: 192.168.107.6
```

### Images in Registry

```bash
$ docker exec transit-registry wget -qO- http://localhost:5000/v2/_catalog
{
  "repositories": [
    "grafana",
    "lumen-api",
    "prometheus",
    "redis"
  ]
}
```

**4 images stored:**
- `lumen-api:v1.0.0` (36MB)
- `redis:7-alpine` (41MB)
- `prometheus:v2.45.0` (213MB)
- `grafana:10.2.0` (384MB)

**Total size:** ~674MB

## 📦 Phase 3: Airgap Zone - K3s Deployment

### Prerequisites

```bash
# Install k3d (K3s in Docker)
brew install k3d

# Verify kubectl
kubectl version --client
```

### Registry Configuration

Created `/tmp/registries.yaml` for K3s:

```yaml
mirrors:
  "192.168.107.6:5000":
    endpoint:
      - http://192.168.107.6:5000
configs:
  "192.168.107.6:5000":
    tls:
      insecure_skip_verify: true
```

### Cluster Creation

```bash
k3d cluster create lumen-airgap \
  --servers 1 \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --volume "/tmp/registries.yaml:/etc/rancher/k3s/registries.yaml" \
  --wait
```

### Results

```
✅ Cluster created: lumen-airgap
✅ K3s version: v1.33.6+k3s1
✅ Nodes: 3 (1 server + 2 agents)

$ kubectl get nodes
NAME                        STATUS   ROLES                  AGE   VERSION
k3d-lumen-airgap-agent-0    Ready    <none>                 2m    v1.33.6+k3s1
k3d-lumen-airgap-agent-1    Ready    <none>                 2m    v1.33.6+k3s1
k3d-lumen-airgap-server-0   Ready    control-plane,master   2m    v1.33.6+k3s1
```

### Registry Network Connection

```bash
# Connect transit registry to k3d network
docker network connect k3d-lumen-airgap transit-registry

# Verify IP
docker inspect transit-registry | jq '.[0].NetworkSettings.Networks."k3d-lumen-airgap".IPAddress'
# Output: "192.168.107.6"
```

## 🚀 Application Deployment

### Deploy Commands

```bash
# Create namespace
kubectl create namespace lumen

# Deploy Redis
sed 's/localhost:5000/192.168.107.6:5000/g' \
  03-airgap-zone/manifests/app/02-redis.yaml | kubectl apply -f -

# Deploy API
sed 's/localhost:5000/192.168.107.6:5000/g' \
  03-airgap-zone/manifests/app/03-lumen-api.yaml | kubectl apply -f -
```

### Deployment Status

```bash
$ kubectl get pods -n lumen
NAME                        READY   STATUS    RESTARTS      AGE
lumen-api-87d8dd468-84kxm   1/1     Running   1 (13s ago)   19s
lumen-api-87d8dd468-9hgkp   1/1     Running   1 (13s ago)   19s
redis-5789586959-q2bb7      1/1     Running   0             20s
```

**Deployment specs:**
- **lumen-api**: 2 replicas, 100m CPU request, 64Mi memory
- **redis**: 1 replica, 100m CPU request, 128Mi memory

### Services

```bash
$ kubectl get svc -n lumen
NAME        TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
lumen-api   ClusterIP   10.43.184.229   <none>        8080/TCP   2m
redis       ClusterIP   10.43.97.156    <none>        6379/TCP   2m
```

## 🧪 Testing & Verification

### API Health Check

```bash
$ kubectl port-forward -n lumen svc/lumen-api 8888:8080
$ curl http://localhost:8888/health

{
  "status": "healthy",
  "checks": {
    "redis": "healthy"
  }
}
```

✅ **Result:** API healthy, Redis connected

### API Endpoint Test

```bash
$ curl http://localhost:8888/hello

{
  "message": "Hello World from Lumen Airgap!",
  "counter": 1
}
```

✅ **Result:** API responding, Redis counter incrementing

### Pod Logs

```bash
$ kubectl logs -n lumen lumen-api-87d8dd468-84kxm

2026/02/12 16:30:15 Connecting to Redis at redis:6379...
2026/02/12 16:30:15 Redis connected successfully
2026/02/12 16:30:15 Server starting on :8080
2026/02/12 16:30:15 Endpoints:
2026/02/12 16:30:15   GET /hello   - Main endpoint with counter
2026/02/12 16:30:15   GET /health  - Health check
2026/02/12 16:30:15   GET /metrics - Prometheus metrics
```

✅ **Result:** Clean startup, no errors

## 📊 Resource Usage

### Cluster Resources

```bash
$ kubectl top nodes
NAME                        CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
k3d-lumen-airgap-agent-0    45m          1%     512Mi           25%
k3d-lumen-airgap-agent-1    42m          1%     489Mi           24%
k3d-lumen-airgap-server-0   98m          2%     687Mi           34%
```

### Pod Resources

```bash
$ kubectl top pods -n lumen
NAME                        CPU(cores)   MEMORY(bytes)
lumen-api-87d8dd468-84kxm   2m          45Mi
lumen-api-87d8dd468-9hgkp   2m          44Mi
redis-5789586959-q2bb7      3m          8Mi
```

## ✅ Success Criteria

| Criterion | Status | Notes |
|-----------|--------|-------|
| Images built | ✅ | Go 1.26, production-ready code |
| Registry operational | ✅ | 4 images, HTTP accessible |
| K3s cluster created | ✅ | 3 nodes, registry configured |
| Pods running | ✅ | 3/3 pods healthy |
| API accessible | ✅ | Health + Hello endpoints working |
| Redis connected | ✅ | Counter incrementing |
| No internet required | ✅ | All images from local registry |

## 🔄 Next Steps

1. **NetworkPolicies** - Implement Zero Trust networking
2. **Monitoring** - Deploy Prometheus + Grafana
3. **OPA Gatekeeper** - Add admission control policies
4. **Scaling** - Test horizontal pod autoscaling
5. **Persistence** - Add PersistentVolumes for Redis

## 🐛 Troubleshooting

### Issue: ImagePullBackOff

**Symptom:** Pods fail to pull images with "HTTP response to HTTPS client"

**Solution:** Configure K3s to accept insecure registry:

```yaml
# /etc/rancher/k3s/registries.yaml
configs:
  "192.168.107.6:5000":
    tls:
      insecure_skip_verify: true
```

### Issue: Registry not accessible

**Symptom:** Cannot reach registry from pods

**Solution:** Connect registry to k3d network:

```bash
docker network connect k3d-lumen-airgap transit-registry
```

## 🎯 Key Learnings

1. **Registry mirrors** are essential for airgap - K3s needs explicit configuration
2. **HTTP registries** require `insecure_skip_verify` in production environments
3. **Network connectivity** between Docker containers requires explicit network connections
4. **k3d** provides excellent local K3s testing with registry integration
5. **Production Go patterns** (App struct, context propagation, graceful shutdown) are critical

## 📝 Cleanup

```bash
# Delete cluster
k3d cluster delete lumen-airgap

# Stop transit zone
cd 02-transit-zone
docker-compose down -v

# Clean artifacts
rm -rf artifacts/
```

---

**Deployment Date:** February 12, 2026
**Environment:** macOS (Darwin 25.2.0), Docker via OrbStack
**Go Version:** 1.26.0
**K3s Version:** v1.33.6+k3s1

## 🔒 Phase 4: NetworkPolicies - Zero Trust Security

### Strategy

Implemented **Zero Trust** networking:
1. **Default Deny All** - Block all traffic by default
2. **Explicit Allow** - Only permit required communication paths

### Policies Applied

```bash
$ kubectl get networkpolicies -n lumen
NAME                  POD-SELECTOR    AGE
allow-api-ingress     app=lumen-api   2m
allow-api-to-redis    app=redis       2m
allow-dns-access      <none>          2m
api-egress-to-redis   app=lumen-api   2m
default-deny-all      <none>          3m
redis-egress          app=redis       2m
```

### Policy Details

#### 1. Default Deny All
- **Scope:** All pods in `lumen` and `kube-system` namespaces
- **Effect:** Blocks all ingress and egress traffic
- **Purpose:** Establish Zero Trust baseline

```yaml
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

#### 2. Allow DNS Access
- **Scope:** All pods in `lumen` namespace
- **Effect:** Allows DNS queries to CoreDNS (UDP/TCP port 53)
- **Purpose:** Enable service discovery

```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
      - podSelector:
          matchLabels:
            k8s-app: kube-dns
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
```

#### 3. API to Redis Communication
- **Scope:** `app=redis` pods (ingress), `app=lumen-api` pods (egress)
- **Effect:** Allows lumen-api to connect to Redis on port 6379
- **Purpose:** Enable application data access

```yaml
# Ingress to Redis
spec:
  podSelector:
    matchLabels:
      app: redis
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: lumen-api
      ports:
        - protocol: TCP
          port: 6379
```

#### 4. External Access to API
- **Scope:** `app=lumen-api` pods
- **Effect:** Allows external traffic to API on port 8080
- **Purpose:** Enable user access to application

### Testing NetworkPolicy Enforcement

#### Test 1: API Functionality After Policies

```bash
$ kubectl port-forward -n lumen svc/lumen-api 8888:8080
$ curl http://localhost:8888/health

{
  "status": "healthy",
  "checks": {
    "redis": "healthy"
  }
}

$ curl http://localhost:8888/hello
{
  "message": "Hello World from Lumen Airgap!",
  "counter": 2
}
```

✅ **Result:** API accessible, Redis connection working

#### Test 2: Unauthorized Access Blocked

```bash
$ kubectl run test-pod --image=alpine --rm -i -n lumen -- sh -c "nc -zv redis 6379"
# Connection times out
```

✅ **Result:** Random pods CANNOT access Redis (only lumen-api can)

#### Test 3: Policy Description

```bash
$ kubectl describe networkpolicy -n lumen allow-api-to-redis

Spec:
  PodSelector:     app=redis
  Allowing ingress traffic:
    To Port: 6379/TCP
    From:
      PodSelector: app=lumen-api
  Not affecting egress traffic
  Policy Types: Ingress
```

✅ **Result:** Policy correctly restricts access to authorized pods only

### Security Benefits

| Threat | Without NetworkPolicy | With NetworkPolicy |
|--------|----------------------|-------------------|
| Lateral movement | ✗ Any pod can access Redis | ✅ Only API pods can access Redis |
| DNS exfiltration | ✗ Pods can query any DNS | ✅ Only kube-dns allowed |
| Unauthorized ingress | ✗ Any traffic accepted | ✅ Only port 8080 to API |
| Service discovery abuse | ✗ Open access | ✅ Explicit allow required |

### Verification Commands

```bash
# View all policies
kubectl get networkpolicies -n lumen

# Describe specific policy
kubectl describe networkpolicy allow-api-to-redis -n lumen

# Test API access (should work)
kubectl port-forward -n lumen svc/lumen-api 8888:8080
curl http://localhost:8888/health

# Test unauthorized access (should fail)
kubectl run test --image=alpine --rm -i -n lumen -- nc -zv redis 6379
```

### NetworkPolicy Flow

```
External Request
       │
       ▼
[allow-api-ingress] ──▶ lumen-api:8080
       │                     │
       │                     │ DNS lookup
       │                     ▼
       │              [allow-dns-access] ──▶ CoreDNS
       │                     │
       │                     │ Redis query
       │                     ▼
       │         [api-egress-to-redis]
       │                     │
       │                     ▼
       └────────────▶ [allow-api-to-redis] ──▶ redis:6379
```

### Key Learnings

1. **Default Deny** is critical - Start secure, then open selectively
2. **DNS must be allowed** - Without it, service names won't resolve
3. **Bidirectional policies** - Need both ingress AND egress rules
4. **Label selectors** are powerful - `app=lumen-api` creates explicit trust boundaries
5. **Test coverage** - Verify both allowed and blocked scenarios

---

**NetworkPolicies Status:** ✅ Implemented and Tested

## 📊 Phase 5: Monitoring Stack - Prometheus + Grafana

### Deployment Commands

```bash
# Create monitoring namespace
kubectl create namespace monitoring

# Deploy Prometheus (with correct registry IP)
sed 's/localhost:5000/192.168.107.6:5000/g' \
  03-airgap-zone/manifests/monitoring/02-prometheus.yaml | kubectl apply -f -

# Deploy Grafana
sed 's/localhost:5000/192.168.107.6:5000/g' \
  03-airgap-zone/manifests/monitoring/03-grafana.yaml | kubectl apply -f -

# Apply monitoring NetworkPolicies
kubectl apply -f 03-airgap-zone/manifests/network-policies/05-allow-monitoring.yaml
```

### Deployment Status

```bash
$ kubectl get pods,svc -n monitoring

NAME                              READY   STATUS    RESTARTS   AGE
pod/grafana-6646d79dbb-tnf6r      1/1     Running   0          5m28s
pod/prometheus-559685f8d9-r9lfd   1/1     Running   0          5m35s

NAME                 TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/grafana      ClusterIP   10.43.160.155   <none>        3000/TCP   5m28s
service/prometheus   ClusterIP   10.43.6.17      <none>        9090/TCP   5m35s
```

✅ **Result:** Both pods running successfully

### Prometheus Configuration

**Scrape Targets:**
- `prometheus` - Self-monitoring (localhost:9090)
- `kubernetes-apiservers` - K8s API server metrics
- `kubernetes-nodes` - Node metrics
- `kubernetes-pods` - Auto-discovery via annotations
- `lumen-api` - Static config as backup

**Service Discovery:**
Prometheus automatically discovers pods with these annotations:
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
```

### Prometheus Testing

```bash
$ kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Health check
$ curl http://localhost:9090/-/healthy
Prometheus Server is Healthy.

# Check targets
$ curl -s http://localhost:9090/api/v1/targets | \
  jq '.data.activeTargets[] | select(.labels.app == "lumen-api") |
  {pod: .labels.kubernetes_pod_name, health: .health}'

{
  "pod": "lumen-api-87d8dd468-84kxm",
  "health": "up"
}
{
  "pod": "lumen-api-87d8dd468-9hgkp",
  "health": "up"
}
```

✅ **Result:** Prometheus successfully scraping both lumen-api pods

### Metrics Collection

```bash
# Query total HTTP requests
$ curl -s 'http://localhost:9090/api/v1/query?query=http_requests_total' | \
  jq -r '.data.result[0]'

{
  "metric": {
    "__name__": "http_requests_total",
    "app": "lumen-api",
    "endpoint": "/health",
    "instance": "10.42.0.6:8080",
    "job": "kubernetes-pods",
    "kubernetes_namespace": "lumen",
    "kubernetes_pod_name": "lumen-api-87d8dd468-84kxm",
    "method": "GET",
    "status": "200",
    "tier": "backend",
    "version": "v1.0.0"
  },
  "value": [1770916012.121, "352"]
}

# Query total requests (all pods)
$ curl -s 'http://localhost:9090/api/v1/query?query=sum(http_requests_total)' | \
  jq -r '.data.result[0].value[1]'
744
```

✅ **Result:** Metrics successfully collected from application

### Grafana Configuration

**Default Credentials:** `admin/admin`

**Datasource:** Prometheus (auto-provisioned)
```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
```

**Pre-configured Dashboard:** Lumen API Dashboard
- HTTP Requests Total (rate per 5m)
- HTTP Request Duration (p95)
- Redis Connection Status

### Grafana Testing

```bash
$ kubectl port-forward -n monitoring svc/grafana 3000:3000

# Health check
$ curl -s http://localhost:3000/api/health | jq
{
  "commit": "895fbafb7a",
  "database": "ok",
  "version": "10.2.0"
}

# Check datasources
$ curl -s -u admin:admin http://localhost:3000/api/datasources | jq
[
  {
    "id": 1,
    "name": "Prometheus",
    "type": "prometheus",
    "url": "http://prometheus:9090",
    "isDefault": true,
    "readOnly": true
  }
]
```

✅ **Result:** Grafana operational, datasource configured

### NetworkPolicies for Monitoring

```bash
$ kubectl get networkpolicies -n monitoring
NAME                POD-SELECTOR     AGE
grafana-egress      app=grafana      4m
grafana-ingress     app=grafana      4m
prometheus-egress   app=prometheus   8m

$ kubectl get networkpolicies -n kube-system | grep dns
allow-dns-ingress   k8s-app=kube-dns   2m
```

**Applied Policies:**

1. **prometheus-egress** (monitoring namespace)
   - Allows Prometheus to scrape targets on port 8080/9090
   - Allows DNS queries to CoreDNS

2. **grafana-egress** (monitoring namespace)
   - Allows Grafana to query DNS (CoreDNS)
   - Allows Grafana to query Prometheus on port 9090

3. **grafana-ingress** (monitoring namespace)
   - Allows external access to Grafana on port 3000

4. **allow-dns-ingress** (kube-system namespace)
   - Allows all pods from any namespace to query CoreDNS
   - Critical for service discovery in Zero Trust environment

5. **allow-prometheus-scraping** (lumen namespace)
   - Allows ingress from monitoring namespace
   - Allows Prometheus to scrape lumen-api on port 8080

### Resource Usage

```bash
$ kubectl top pods -n monitoring
NAME                          CPU(cores)   MEMORY(bytes)
grafana-6646d79dbb-tnf6r      5m           145Mi
prometheus-559685f8d9-r9lfd   7m           201Mi
```

**Resource Specs:**
- **Prometheus**: 200m CPU request, 512Mi memory request, 15d retention
- **Grafana**: 100m CPU request, 256Mi memory request

### Grafana DNS Resolution Fix

**Initial Issue:** Grafana could not resolve "prometheus" hostname

```bash
# Grafana logs showed:
logger=data-proxy-log level=error msg="Proxy request timed out"
  err="dial tcp: lookup prometheus: i/o timeout"
```

**Root Cause:**
- `default-deny-all` NetworkPolicy in `kube-system` blocks **ingress** to CoreDNS
- Grafana egress NetworkPolicy existed, but CoreDNS couldn't accept connections

**Solution Applied:**

Two NetworkPolicies were required:

1. **Grafana Egress** (`07-allow-grafana.yaml` in monitoring namespace):
```yaml
# Allow Grafana to query DNS and Prometheus
egress:
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
  - to:
      - podSelector:
          matchLabels:
            app: prometheus
    ports:
      - protocol: TCP
        port: 9090
```

2. **CoreDNS Ingress** (`08-allow-dns-ingress.yaml` in kube-system):
```yaml
# Allow all pods to query CoreDNS
spec:
  podSelector:
    matchLabels:
      k8s-app: kube-dns
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector: {}
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

**Test Results:**

```bash
# DNS resolution test
$ kubectl exec -n monitoring deployment/grafana -- nslookup prometheus
Server:		10.43.0.10
Name:	prometheus.monitoring.svc.cluster.local
Address: 10.43.6.17
```

✅ **DNS Resolved Successfully**

```bash
# Prometheus query via Grafana
$ curl -s -u admin:admin \
  'http://localhost:3000/api/datasources/proxy/1/api/v1/label/__name__/values' | \
  jq -r '.status, (.data[:5] // [])'

"success"
[
  "aggregator_discovery_aggregation_count_total",
  "aggregator_unavailable_apiservice",
  "apiextensions_apiserver_validation_ratcheting_seconds_bucket",
  "apiextensions_apiserver_validation_ratcheting_seconds_count",
  "apiextensions_apiserver_validation_ratcheting_seconds_sum"
]
```

✅ **Grafana → Prometheus Connectivity Working**

```bash
# Check dashboard
$ curl -s -u admin:admin 'http://localhost:3000/api/dashboards/uid/lumen-api' | \
  jq -r '.dashboard.title'

Lumen API Dashboard
```

✅ **Dashboard Accessible**

### Monitoring Architecture

```
┌──────────────────────────────────────────────────────┐
│                  Prometheus                          │
│  ┌────────────────────────────────────────────┐     │
│  │ Service Discovery (kubernetes-pods)        │     │
│  │ - Auto-discovers pods with annotations     │     │
│  └────────────────────────────────────────────┘     │
│                       │                              │
│                       ▼                              │
│  ┌─────────────────────────────────────────────┐    │
│  │ Scrape Targets:                             │    │
│  │ • lumen-api (10.42.0.6:8080) - health: up   │    │
│  │ • lumen-api (10.42.1.5:8080) - health: up   │    │
│  │ • kubernetes-apiservers - health: up        │    │
│  └─────────────────────────────────────────────┘    │
│                       │                              │
│                       ▼                              │
│  ┌─────────────────────────────────────────────┐    │
│  │ Metrics Storage (TSDB, 15d retention)       │    │
│  │ • http_requests_total                       │    │
│  │ • http_request_duration_seconds             │    │
│  │ • redis_connection_status                   │    │
│  └─────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────┘
                       │
                       │ (DNS + NetworkPolicy fixed!)
                       ▼
┌──────────────────────────────────────────────────────┐
│                   Grafana                            │
│  - Dashboard: Lumen API Dashboard                   │
│  - Datasource: Prometheus (http://prometheus:9090)  │
│  - Status: Fully operational ✅                      │
└──────────────────────────────────────────────────────┘
```

### Success Criteria

| Criterion | Status | Notes |
|-----------|--------|-------|
| Prometheus deployed | ✅ | 1 pod running, 201Mi memory |
| Grafana deployed | ✅ | 1 pod running, 145Mi memory |
| Service discovery working | ✅ | Auto-discovers lumen-api pods |
| Metrics collection | ✅ | 744 total HTTP requests tracked |
| Prometheus scraping | ✅ | Both API pods health: up |
| Grafana datasource | ✅ | Prometheus configured |
| Grafana dashboards | ✅ | Lumen API dashboard provisioned |
| Grafana connectivity | ✅ | DNS + Prometheus queries working |
| NetworkPolicies applied | ✅ | Grafana, Prometheus, CoreDNS ingress |
| No internet required | ✅ | All images from 192.168.107.6:5000 |

### Key Learnings

1. **Service Discovery** - Prometheus kubernetes_sd_configs automatically discovers pods with prometheus.io annotations
2. **NetworkPolicy Bidirectional Rules** - Both egress (from client) AND ingress (to server) policies are required in Zero Trust
3. **DNS is Critical** - CoreDNS needs explicit ingress NetworkPolicy when default-deny-all is applied to kube-system
4. **Namespace Isolation** - default-deny-all in kube-system affects ALL namespaces, not just kube-system
5. **RBAC Required** - Prometheus needs ClusterRole to list pods/nodes/endpoints for service discovery
6. **Airgap Monitoring** - Works perfectly without remote_write, local TSDB storage sufficient
7. **NetworkPolicy Syntax** - `namespaceSelector` + `podSelector` in same block = AND (both must match)

### Access Monitoring

```bash
# Prometheus UI
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Open: http://localhost:9090

# Grafana UI
kubectl port-forward -n monitoring svc/grafana 3000:3000
# Open: http://localhost:3000 (admin/admin)
```

---

**Monitoring Status:** ✅ Prometheus Operational | ✅ Grafana Fully Functional

## 🔐 Phase 6: OPA Gatekeeper - Admission Control

### What is OPA Gatekeeper?

Open Policy Agent (OPA) Gatekeeper is a **policy controller** for Kubernetes that enforces policies using admission webhooks. It validates, mutates, and audits resources before they're admitted to the cluster.

### Deployment Commands

```bash
# Install Gatekeeper
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/v3.15.0/deploy/gatekeeper.yaml

# Wait for Gatekeeper pods
kubectl wait --for=condition=ready pod -l control-plane=controller-manager \
  -n gatekeeper-system --timeout=90s

# Apply constraint templates (with correct registry IP)
sed 's/localhost:5000/192.168.107.6:5000/g' \
  03-airgap-zone/manifests/opa/02-constraint-template-registry.yaml | kubectl apply -f -

kubectl apply -f 03-airgap-zone/manifests/opa/05-constraint-template-no-latest.yaml
kubectl apply -f 03-airgap-zone/manifests/opa/03-constraint-template-labels.yaml
kubectl apply -f 03-airgap-zone/manifests/opa/04-constraint-template-resources.yaml
```

### Deployment Status

```bash
$ kubectl get pods -n gatekeeper-system
NAME                                            READY   STATUS    RESTARTS   AGE
gatekeeper-audit-8ccd97cc5-rld59                1/1     Running   1          5m
gatekeeper-controller-manager-84fd8dbff-87jxc   1/1     Running   0          5m
gatekeeper-controller-manager-84fd8dbff-dhdx7   1/1     Running   0          5m
gatekeeper-controller-manager-84fd8dbff-stzf2   1/1     Running   0          5m
```

✅ **Result:** 1 audit pod + 3 controller replicas running

### Policies Implemented

#### 1. K8sRequiredRegistry - Enforce Internal Registry

**Purpose:** Prevent pods from pulling images from external registries (critical for airgap)

**Policy:**
```yaml
parameters:
  registries:
    - "192.168.107.6:5000/"
    - "registry.airgap.local:5000/"
```

**Test:**
```bash
$ kubectl apply -n lumen -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test
spec:
  containers:
  - name: test
    image: docker.io/nginx:1.21
EOF

Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request:
[require-internal-registry] Container <test> has invalid image <docker.io/nginx:1.21>.
Images must come from approved registries: ["192.168.107.6:5000/", "registry.airgap.local:5000/"]
```

✅ **Result:** External images blocked

#### 2. K8sBlockLatestTag - Block :latest Tag

**Purpose:** Enforce specific version tags for reproducibility and security

**Test:**
```bash
$ kubectl apply -n lumen -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test
spec:
  containers:
  - name: test
    image: nginx:latest
EOF

Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request:
[block-latest-tag] Container <test> uses :latest tag in image <nginx:latest>.
Specific version tags are required.
```

✅ **Result:** :latest tag blocked

**Edge Case - No Tag:**
```bash
$ kubectl apply -n lumen -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test
spec:
  containers:
  - name: test
    image: nginx
EOF

Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request:
[block-latest-tag] Container <test> has no tag specified in image <nginx> (implies :latest).
Specific version tags are required.
```

✅ **Result:** Images without tags also blocked

#### 3. K8sRequiredLabels - Enforce Required Labels

**Purpose:** Ensure resources have mandatory labels for organization and governance

**Required Labels:**
- `app`
- `tier`

**Test:**
```bash
$ kubectl apply -n lumen -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test
  labels:
    app: test
spec:
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - name: test
        image: 192.168.107.6:5000/lumen-api:v1.0.0
EOF

Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request:
[require-app-labels] Resource is missing required labels: {"tier"}
```

✅ **Result:** Missing labels detected

#### 4. K8sRequiredResources - Enforce Resource Limits

**Purpose:** Prevent resource exhaustion by requiring CPU/memory requests and limits

**Applies to:** Deployments, StatefulSets, DaemonSets

**Policy:** Requires all containers to specify:
- `resources.requests.cpu`
- `resources.requests.memory`
- `resources.limits.cpu`
- `resources.limits.memory`

### Constraint Templates and Constraints

```bash
$ kubectl get constrainttemplates
NAME                   AGE
k8sblocklatesttag      4m
k8srequiredlabels      3m
k8srequiredregistry    4m
k8srequiredresources   3m

$ kubectl get constraints --all-namespaces
NAME                                                           ENFORCEMENT-ACTION   TOTAL-VIOLATIONS
k8sblocklatesttag.constraints.gatekeeper.sh/block-latest-tag                        0
k8srequiredlabels.constraints.gatekeeper.sh/require-app-labels                      0
k8srequiredregistry.constraints.gatekeeper.sh/require-internal-registry            0
k8srequiredresources.constraints.gatekeeper.sh/require-resources                    0
```

✅ **Result:** 4 ConstraintTemplates + 4 Constraints active, 0 violations

### Valid Pod Example

```bash
$ kubectl apply -n lumen -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-valid
  labels:
    app: test
    tier: backend
spec:
  containers:
  - name: test
    image: 192.168.107.6:5000/lumen-api:v1.0.0
    resources:
      requests:
        cpu: "10m"
        memory: "32Mi"
      limits:
        cpu: "50m"
        memory: "64Mi"
EOF

pod/test-valid created
```

✅ **Result:** Compliant pods are admitted successfully

### Gatekeeper Architecture

```
┌────────────────────────────────────────────────────┐
│          Kubernetes API Server                     │
│                                                     │
│  ┌──────────────────────────────────────────┐     │
│  │   ValidatingWebhookConfiguration         │     │
│  │   - Intercepts CREATE/UPDATE requests    │     │
│  └───────────────┬──────────────────────────┘     │
└──────────────────┼─────────────────────────────────┘
                   │
                   ▼
┌────────────────────────────────────────────────────┐
│        Gatekeeper Controller Manager (3 replicas)  │
│                                                     │
│  ┌──────────────────────────────────────────┐     │
│  │  Policy Enforcement                      │     │
│  │  - Load ConstraintTemplates (Rego)       │     │
│  │  - Apply Constraints to resources        │     │
│  │  - Return allow/deny decision            │     │
│  └──────────────────────────────────────────┘     │
└────────────────────────────────────────────────────┘
                   │
                   ▼
┌────────────────────────────────────────────────────┐
│           Gatekeeper Audit Controller              │
│                                                     │
│  - Periodically scans existing resources          │
│  - Reports constraint violations                   │
│  - Updates constraint status                       │
└────────────────────────────────────────────────────┘
```

### Policy Enforcement Flow

```
User creates Pod
       │
       ▼
API Server intercepts
       │
       ▼
Webhook calls Gatekeeper
       │
       ▼
┌──────────────────────┐
│  Check Constraints:  │
│  1. Registry ✅      │
│  2. No :latest ✅    │
│  3. Labels ✅        │
│  4. Resources ✅     │
└──────────┬───────────┘
           │
     ┌─────┴──────┐
     │            │
  ALLOW         DENY
     │            │
     ▼            ▼
  Pod created   Error returned
```

### Success Criteria

| Criterion | Status | Notes |
|-----------|--------|-------|
| Gatekeeper installed | ✅ | v3.15.0, 4 pods running |
| ConstraintTemplates created | ✅ | 4 templates (registry, latest, labels, resources) |
| Constraints applied | ✅ | 4 constraints enforcing policies |
| Registry policy working | ✅ | Blocks external images |
| Latest tag policy working | ✅ | Blocks :latest and untagged images |
| Labels policy working | ✅ | Requires app + tier labels |
| Resources policy working | ✅ | Requires CPU/memory limits on Deployments |
| Valid pods admitted | ✅ | Compliant resources pass validation |
| No violations | ✅ | 0 total violations across all constraints |

### Key Learnings

1. **Admission Control Timing** - Gatekeeper validates resources BEFORE they're created, preventing policy violations proactively
2. **Rego Language** - OPA uses Rego for policy logic, allowing complex conditional rules
3. **Template vs Constraint** - ConstraintTemplates define policy logic (reusable), Constraints apply them to specific resources
4. **Audit Mode** - Gatekeeper continuously audits existing resources for violations (not just new ones)
5. **Webhook Dependencies** - Gatekeeper uses ValidatingWebhookConfiguration, so it must be healthy before creating resources
6. **Namespace Targeting** - Constraints can target specific namespaces (we target `lumen` namespace)
7. **Multiple Violations** - A single resource can trigger multiple constraint violations simultaneously

### Airgap Considerations

For true airgap deployment:
1. **Pre-download Gatekeeper manifest** - Save `https://raw.githubusercontent.com/open-policy-agent/gatekeeper/v3.15.0/deploy/gatekeeper.yaml` in connected zone
2. **Push Gatekeeper images to registry** - Extract images from manifest and upload to `192.168.107.6:5000`
3. **Update image references** - Modify manifest to use internal registry before applying

### Verification Commands

```bash
# Check Gatekeeper health
kubectl get pods -n gatekeeper-system

# List all constraint templates
kubectl get constrainttemplates

# List all constraints
kubectl get constraints --all-namespaces

# View constraint details
kubectl describe k8srequiredregistry require-internal-registry

# Test policy enforcement (should fail)
kubectl run test --image=nginx:latest -n lumen
```

---

**OPA Gatekeeper Status:** ✅ Fully Operational - 4 Policies Enforced
