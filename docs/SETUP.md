# Complete Setup Guide

This guide walks you through setting up the complete airgap Kubernetes environment from scratch.

## Prerequisites

### Required Software

```bash
# Docker & Docker Compose
docker --version  # >= 24.0
docker-compose --version  # >= 2.0

# Kubernetes tools
kubectl version --client  # >= 1.28

# Go (for development)
go version  # >= 1.26

# Other tools
make --version
jq --version
curl --version
```

### System Requirements

- **OS**: Linux (Ubuntu 22.04+ recommended) or macOS
- **RAM**: 8GB minimum, 16GB recommended
- **Disk**: 20GB free space
- **Network**: Internet access for connected zone

### Install K3s Binary (for airgap)

```bash
# Download K3s binary
curl -Lo /usr/local/bin/k3s https://github.com/k3s-io/k3s/releases/download/v1.28.5+k3s1/k3s
chmod +x /usr/local/bin/k3s

# Download K3s images (optional, for complete airgap)
curl -Lo k3s-airgap-images-amd64.tar.gz https://github.com/k3s-io/k3s/releases/download/v1.28.5+k3s1/k3s-airgap-images-amd64.tar.gz
```

## Phase 1: Connected Zone Setup

### Step 1: Initialize Go Module

```bash
cd 01-connected-zone/app
go mod download
go mod verify
```

### Step 2: Build Application Locally

```bash
# Build binary
go build -o lumen-api main.go

# Test locally
./lumen-api &
curl http://localhost:8080/health
```

### Step 3: Build Docker Images

```bash
cd ..  # back to 01-connected-zone

# Build using docker-compose
docker-compose build

# Or build manually
docker build -t lumen-api:v1.0.0 .
```

### Step 4: Test with Docker Compose

```bash
# Start services
docker-compose up -d

# Wait for services to be ready
sleep 10

# Test endpoints
curl http://localhost:8080/health
curl http://localhost:8080/hello
curl http://localhost:8080/metrics

# Check logs
docker-compose logs -f api

# Stop when done
docker-compose down
```

### Step 5: Package Artifacts

```bash
# Run build script
./build.sh

# Verify artifacts
ls -lh ../artifacts/images/
# Should see:
# - lumen-api.tar
# - redis.tar
# - images-list.txt
```

## Phase 2: Transit Zone Setup

### Step 1: Start Registry Services

```bash
cd ../02-transit-zone

# Start docker-compose services
docker-compose up -d

# Verify services
docker-compose ps
```

### Step 2: Verify Registry

```bash
# Check registry is accessible
curl http://localhost:5000/v2/

# Access Registry UI
open http://localhost:8081

# Access File Server
open http://localhost:8082
```

### Step 3: Load and Push Images

```bash
# Run setup script
./setup.sh

# Verify images in registry
curl http://localhost:5000/v2/_catalog | jq .

# Should show:
# {
#   "repositories": [
#     "lumen-api",
#     "redis"
#   ]
# }
```

### Step 4: Download Additional Images

For complete airgap setup, download these images in connected zone:

```bash
# Prometheus
docker pull prom/prometheus:v2.45.0
docker tag prom/prometheus:v2.45.0 localhost:5000/prometheus:v2.45.0
docker push localhost:5000/prometheus:v2.45.0

# Grafana
docker pull grafana/grafana:10.2.0
docker tag grafana/grafana:10.2.0 localhost:5000/grafana:10.2.0
docker push localhost:5000/grafana:10.2.0

# Verify
curl http://localhost:5000/v2/_catalog | jq .
```

## Phase 3: Airgap Zone Setup

### Step 1: Configure Hosts File

```bash
# Add registry to /etc/hosts
sudo bash -c 'echo "127.0.0.1 registry.airgap.local" >> /etc/hosts'

# Verify
ping -c 1 registry.airgap.local
```

### Step 2: Setup iptables (Airgap Enforcement)

```bash
cd ../03-airgap-zone/scripts

# Review the script first
cat setup-k3s.sh

# Run with sudo
sudo ./setup-k3s.sh
```

**What this does:**
- Configures /etc/hosts
- Sets up iptables rules to block internet
- Copies registry mirror config
- Prepares for K3s installation

### Step 3: Install K3s

```bash
# Install K3s with airgap configuration
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.28.5+k3s1" sh -s - \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --flannel-backend=none \
  --disable-network-policy

# Verify installation
sudo systemctl status k3s

# Configure kubectl
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Test
kubectl get nodes
kubectl get pods -A
```

### Step 4: Install Cilium CNI

```bash
# Download Cilium CLI (in connected zone)
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin

# Install Cilium
cilium install

# Verify
cilium status
kubectl get pods -n kube-system -l k8s-app=cilium
```

### Step 5: Verify Airgap

```bash
# Test internet (should fail)
timeout 2 curl google.com
# Expected: timeout or connection refused

# Test internal registry (should work)
curl http://registry.airgap.local:5000/v2/
# Expected: {}

# Test from inside cluster
kubectl run test --image=alpine --rm -it -- sh
> wget google.com  # Should fail
> nslookup kubernetes.default  # Should work
```

## Phase 4: Deploy Applications

### Step 1: Deploy Application

```bash
# Create namespace and deploy app
kubectl apply -f ../manifests/app/

# Watch deployment
kubectl get pods -n lumen -w

# Check status
kubectl get all -n lumen
```

### Step 2: Verify Deployment

```bash
# Check pods are running
kubectl get pods -n lumen

# Check API health
API_POD=$(kubectl get pod -n lumen -l app=lumen-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n lumen $API_POD -- wget -qO- http://localhost:8080/health

# Check logs
kubectl logs -n lumen -l app=lumen-api -f
```

### Step 3: Test API

```bash
# Port-forward
kubectl port-forward -n lumen svc/lumen-api 8080:8080 &

# Test endpoints
curl http://localhost:8080/health | jq .
curl http://localhost:8080/hello | jq .
curl http://localhost:8080/metrics
```

## Phase 5: Network Policies

### Step 1: Apply Default Deny

```bash
# Apply default deny-all policy
kubectl apply -f ../manifests/network-policies/01-default-deny-all.yaml

# Verify - pods should lose connectivity
kubectl exec -n lumen $API_POD -- wget -qO- http://localhost:8080/health
# Should fail or timeout
```

### Step 2: Allow DNS

```bash
kubectl apply -f ../manifests/network-policies/02-allow-dns.yaml

# Test DNS resolution
kubectl exec -n lumen $API_POD -- nslookup kubernetes.default
# Should work
```

### Step 3: Allow Application Traffic

```bash
# Allow API to Redis
kubectl apply -f ../manifests/network-policies/03-allow-api-to-redis.yaml

# Allow ingress to API
kubectl apply -f ../manifests/network-policies/04-allow-api-ingress.yaml

# Test connectivity
kubectl exec -n lumen $API_POD -- wget -qO- http://redis:6379
# Should connect
```

### Step 4: Cilium Policies (Advanced)

```bash
# Apply Cilium cluster-wide policy
kubectl apply -f ../manifests/network-policies/06-block-internet-cilium.yaml

# Verify with Cilium
cilium connectivity test
```

## Phase 6: OPA Gatekeeper

### Step 1: Install Gatekeeper

```bash
# Download Gatekeeper manifests (in connected zone)
curl -o gatekeeper.yaml https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.15/deploy/gatekeeper.yaml

# Install
kubectl apply -f gatekeeper.yaml

# Wait for pods
kubectl wait --for=condition=Ready --timeout=300s -n gatekeeper-system pods --all
```

### Step 2: Apply Constraint Templates

```bash
# Apply all constraint templates
kubectl apply -f ../manifests/opa/

# Verify
kubectl get constrainttemplates
kubectl get constraints
```

### Step 3: Test OPA Policies

```bash
# Test 1: Try to deploy with :latest tag (should be rejected)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-latest
  namespace: lumen
spec:
  containers:
  - name: test
    image: nginx:latest
EOF
# Expected: denied by "block-latest-tag"

# Test 2: Try to use external registry (should be rejected)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-external
  namespace: lumen
spec:
  containers:
  - name: test
    image: nginx:1.21
EOF
# Expected: denied by "require-internal-registry"

# Test 3: Valid deployment (should work)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-valid
  namespace: lumen
spec:
  containers:
  - name: test
    image: localhost:5000/redis:7-alpine
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi
EOF
# Expected: pod created
```

## Phase 7: Monitoring

### Step 1: Deploy Prometheus

```bash
kubectl apply -f ../manifests/monitoring/01-namespace.yaml
kubectl apply -f ../manifests/monitoring/02-prometheus.yaml

# Wait for ready
kubectl wait --for=condition=Ready --timeout=300s -n monitoring pod -l app=prometheus
```

### Step 2: Deploy Grafana

```bash
kubectl apply -f ../manifests/monitoring/03-grafana.yaml

# Wait for ready
kubectl wait --for=condition=Ready --timeout=300s -n monitoring pod -l app=grafana
```

### Step 3: Access Dashboards

```bash
# Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
open http://localhost:9090

# Grafana
kubectl port-forward -n monitoring svc/grafana 3000:3000 &
open http://localhost:3000
# Login: admin/admin
```

### Step 4: Verify Metrics

```bash
# Check Prometheus targets
# Go to: http://localhost:9090/targets
# Should see: lumen-api, prometheus

# Check metrics are being scraped
# Query: http_requests_total{app="lumen-api"}
```

## Phase 8: Testing

### Complete Test Suite

```bash
cd ../../scripts
./test-airgap-complete.sh
```

### Individual Tests

```bash
# Test API
make test-api-k8s

# Test network policies
make test-network-policies

# Test OPA
make test-opa

# View status
make status
```

## Troubleshooting

### Issue: Images not pulling

```bash
# Check registry mirrors
cat /etc/rancher/k3s/registries.yaml

# Check containerd
crictl info | grep -A 10 registry

# Test registry from node
curl http://registry.airgap.local:5000/v2/_catalog
```

### Issue: NetworkPolicy blocking traffic

```bash
# Describe policy
kubectl describe networkpolicy -n lumen

# Test connectivity
kubectl exec -n lumen $API_POD -- nc -zv redis 6379

# Check Cilium logs
cilium monitor
```

### Issue: OPA denying valid pods

```bash
# Check constraint status
kubectl get constraints -o yaml

# View audit
kubectl get k8srequiredregistry require-internal-registry -o jsonpath='{.status.violations}'
```

## Cleanup

```bash
# Remove everything
make clean

# Or manually:
kubectl delete namespace lumen monitoring gatekeeper-system
docker-compose -f 02-transit-zone/docker-compose.yml down -v
docker-compose -f 01-connected-zone/docker-compose.yml down -v
```

## Next Steps

After completing this setup, try:

1. Adding custom OPA policies
2. Implementing GitOps with ArgoCD
3. Adding Vault for secrets
4. Setting up service mesh (Linkerd)
5. Creating CI/CD pipeline for airgap

## Resources

- [K3s Documentation](https://docs.k3s.io/)
- [Cilium NetworkPolicy Examples](https://docs.cilium.io/en/stable/security/policy/)
- [OPA Gatekeeper Library](https://github.com/open-policy-agent/gatekeeper-library)
