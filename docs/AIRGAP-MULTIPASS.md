# Airgap Zone — Multipass K3s Cluster (Phase 16)

Production-like airgap environment running on Multipass VMs with a real multi-node K3s cluster and MetalLB LoadBalancer.

## Architecture

```
Mac (host)
├── OrbStack Docker (transit zone registry: localhost:5000)
├── Multipass node-1 (192.168.2.2) — control plane + worker
│   ├── K3s v1.34.4
│   ├── Docker registry (192.168.2.2:5000) — airgap registry
│   └── All workloads (ArgoCD, Traefik, monitoring, lumen-api...)
└── Multipass node-2 (192.168.2.3) — worker
    └── K3s v1.34.4

MetalLB IP pool: 192.168.2.100-192.168.2.200
Traefik LoadBalancer IP: 192.168.2.100
```

## VMs

| Node | CPUs | RAM | Disk | Role |
|------|------|-----|------|------|
| node-1 | 4 | 6GB | 40G | control-plane + worker |
| node-2 | 2 | 4GB | 30G | worker |

## Bootstrap Order

Components must be installed in this order — each depends on the previous:

```
1. Multipass VMs
2. K3s cluster (node-1 control plane, node-2 worker)
3. Docker registry on node-1 (192.168.2.2:5000)
4. Push all images to registry
5. MetalLB (LoadBalancer)
6. ArgoCD (GitOps controller)
7. Everything else via ArgoCD
```

## Prerequisites

```bash
brew install multipass
brew install kubectl
brew install helm
```

## Step 1 — Create VMs

```bash
multipass launch --name node-1 --cpus 4 --memory 6G --disk 40G 24.04
multipass launch --name node-2 --cpus 2 --memory 4G --disk 30G 24.04
```

## Step 2 — Install K3s

**node-1 (control plane):**
```bash
multipass exec node-1 -- bash -c "
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.34.4+k3s1 sh -s - \
    --disable=traefik \
    --disable=servicelb \
    --write-kubeconfig-mode=644
"
```

**Get join token:**
```bash
TOKEN=$(multipass exec node-1 -- sudo cat /var/lib/rancher/k3s/server/node-token)
NODE1_IP=$(multipass info node-1 | grep IPv4 | awk '{print $2}' | head -1)
```

**node-2 (worker):**
```bash
multipass exec node-2 -- bash -c "
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.34.4+k3s1 \
    K3S_URL=https://${NODE1_IP}:6443 \
    K3S_TOKEN=${TOKEN} sh -
"
```

## Step 3 — Configure containerd registry mirrors

On both nodes, create `/etc/rancher/k3s/registries.yaml`:
```bash
multipass transfer 03-airgap-zone/config/registries.yaml node-1:/tmp/registries.yaml
multipass exec node-1 -- sudo cp /tmp/registries.yaml /etc/rancher/k3s/registries.yaml
multipass exec node-1 -- sudo systemctl restart k3s

multipass transfer 03-airgap-zone/config/registries.yaml node-2:/tmp/registries.yaml
multipass exec node-2 -- sudo cp /tmp/registries.yaml /etc/rancher/k3s/registries.yaml
multipass exec node-2 -- sudo systemctl restart k3s-agent
```

## Step 4 — Docker registry on node-1

```bash
multipass exec node-1 -- bash -c "
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker ubuntu
  mkdir -p /home/ubuntu/registry-data
  docker run -d --name registry --restart=always \
    -p 5000:5000 \
    -v /home/ubuntu/registry-data:/var/lib/registry \
    registry:2
"
```

**Push all images from transit registry to airgap registry:**
```bash
# From Mac, transfer transit registry data to node-1
docker run --rm -v 02-transit-zone_registry-data:/data alpine \
  tar -czf - /data | multipass transfer - node-1:/tmp/registry-backup.tar.gz

multipass exec node-1 -- bash -c "
  tar -xzf /tmp/registry-backup.tar.gz -C /tmp/
  mkdir -p /home/ubuntu/registry-data/docker/registry/v2
  cp -r /tmp/data/docker/registry/v2/* /home/ubuntu/registry-data/docker/registry/v2/
  docker restart registry
"
```

## Step 5 — MetalLB (bootstrap)

See `scripts/install-metallb.sh` for details.

```bash
# Pull MetalLB images on Mac, transfer to node-1
docker pull --platform linux/arm64 quay.io/metallb/controller:v0.15.3
docker pull --platform linux/arm64 quay.io/metallb/speaker:v0.15.3
docker pull --platform linux/arm64 quay.io/frrouting/frr:9.1.0

# Tag and push to airgap registry
for img in metallb/controller:v0.15.3 metallb/speaker:v0.15.3; do
  docker tag quay.io/$img 192.168.2.2:5000/$img
  docker push 192.168.2.2:5000/$img
done

# Install via Helm
multipass exec node-1 -- helm install metallb metallb/metallb \
  --namespace metallb-system --create-namespace \
  --version 0.15.3 \
  --set controller.image.repository=192.168.2.2:5000/metallb/controller \
  --set controller.image.tag=v0.15.3 \
  --set speaker.image.repository=192.168.2.2:5000/metallb/speaker \
  --set speaker.image.tag=v0.15.3 \
  --set speaker.frr.image.repository=192.168.2.2:5000/frrouting/frr \
  --set speaker.frr.image.tag=9.1.0 \
  --wait

# Apply IP pool config
multipass exec node-1 -- kubectl apply -f manifests/metallb/
```

**macOS ARP entry (permanent via LaunchDaemon):**
```bash
sudo cp 03-airgap-zone/scripts/com.lumen.arp.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.lumen.arp.plist
sudo chmod 644 /Library/LaunchDaemons/com.lumen.arp.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.lumen.arp.plist
```

## Step 6 — ArgoCD

```bash
multipass exec node-1 -- kubectl create namespace argocd
multipass exec node-1 -- kubectl apply -n argocd \
  -f manifests/argocd/02-install-airgap.yaml
```

Wait for ArgoCD to be ready, then apply all Application manifests:
```bash
multipass exec node-1 -- kubectl apply -f manifests/argocd/
```

## Step 7 — Trust the CA on macOS

```bash
./03-airgap-zone/scripts/trust-ca.sh
```

This fetches the CA from the cluster, imports it into the macOS keychain, and configures Git to trust it.

## DNS (macOS /etc/hosts)

```
192.168.2.100 traefik.airgap.local
192.168.2.100 argocd.airgap.local
192.168.2.100 gitea.airgap.local
192.168.2.100 grafana.airgap.local
192.168.2.100 prometheus.airgap.local
192.168.2.100 alertmanager.airgap.local
192.168.2.100 lumen-api.airgap.local
192.168.2.100 tempo.airgap.local
```

## Stack

| Service | URL | Credentials |
|---------|-----|-------------|
| ArgoCD | https://argocd.airgap.local | admin / (kubectl get secret argocd-initial-admin-secret) |
| Gitea | https://gitea.airgap.local | gitea-admin / gitea-admin123 |
| Grafana | https://grafana.airgap.local | admin / prom-operator |
| Prometheus | https://prometheus.airgap.local | — |
| AlertManager | https://alertmanager.airgap.local | — |
| Tempo | https://tempo.airgap.local | — |
| Lumen API | https://lumen-api.airgap.local | — |

## Git remote

The Gitea remote uses the public HTTPS URL (no port-forward needed):
```bash
git remote set-url gitea https://gitea-admin:gitea-admin123@gitea.airgap.local/lumen/lumen.git
```

## Key design decisions

- **MetalLB as bootstrap**: installed before ArgoCD, not managed by GitOps
- **Registry on node-1**: Docker container with persistent volume at `/home/ubuntu/registry-data`
- **TLS secret in all namespaces**: cert-generation Job creates `airgap-tls` in traefik, monitoring, argocd, gitea, lumen
- **Traefik namespace label**: `name=traefik` required for network policy namespace selectors
- **ArgoCD insecure mode**: `--insecure` flag required when behind TLS-terminating Traefik
