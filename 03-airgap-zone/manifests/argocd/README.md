# ArgoCD Deployment (Airgap Mode)

## Overview

This directory contains manifests to deploy ArgoCD in airgap mode, configured for GitOps-based continuous deployment of the Lumen project.

## Architecture

```
┌─────────────────┐
│  Git Repository │ (Internal/GitHub)
└────────┬────────┘
         │
         │ Git Clone
         ▼
┌─────────────────┐
│  ArgoCD Server  │
│  (argocd ns)    │
└────────┬────────┘
         │
         │ kubectl apply
         ▼
┌─────────────────┐
│ Lumen Resources │
│  (lumen ns)     │
└─────────────────┘
```

## Deployment Steps

### 1. Connected Zone - Download ArgoCD

```bash
cd 01-connected-zone/argocd-airgap
./download-argocd.sh
```

This downloads:
- ArgoCD installation manifest
- All required container images
- Saves images as tar archives

### 2. Transit Zone - Push to Registry

```bash
cd 02-transit-zone
./push-argocd.sh
```

This:
- Loads images from tar archives
- Tags images for internal registry
- Pushes to `localhost:5000`

### 3. Airgap Zone - Prepare Manifest

```bash
cd 03-airgap-zone/scripts
./prepare-argocd-manifest.sh
```

This replaces all external image references with internal registry URLs.

### 4. Deploy ArgoCD

```bash
cd 03-airgap-zone

# Create namespace
kubectl apply -f manifests/argocd/01-namespace.yaml

# Install ArgoCD (with registry overrides)
kubectl apply -f manifests/argocd/02-install-airgap.yaml

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/part-of=argocd -n argocd --timeout=300s

# Apply ConfigMap
kubectl apply -f manifests/argocd/03-argocd-cm.yaml

# Apply NetworkPolicies
kubectl apply -f manifests/network-policies/09-allow-argocd.yaml
```

### 5. Access ArgoCD UI

```bash
# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Port-forward to access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Access: https://localhost:8080
# Username: admin
# Password: (from command above)
```

### 6. Configure Git Repository

**Option A: Public GitHub (with internet access in airgap for Git only)**

Update the `repoURL` in Application manifests:
- `04-application-lumen.yaml`
- `05-application-monitoring.yaml`
- `06-application-network-policies.yaml`

**Option B: Internal Git Server (full airgap)**

Deploy a Git server inside the airgap zone (e.g., Gitea, GitLab) and configure ArgoCD to use it.

### 7. Deploy Applications

```bash
# Deploy Lumen application
kubectl apply -f manifests/argocd/04-application-lumen.yaml

# Deploy Monitoring stack
kubectl apply -f manifests/argocd/05-application-monitoring.yaml

# Deploy NetworkPolicies
kubectl apply -f manifests/argocd/06-application-network-policies.yaml
```

### 8. Verify GitOps Sync

```bash
# Check application status
kubectl get applications -n argocd

# Check sync status
kubectl describe application lumen-app -n argocd

# Watch ArgoCD logs
kubectl logs -f -l app.kubernetes.io/name=argocd-server -n argocd
```

## ArgoCD Features

### Auto-Sync
All applications are configured with `automated` sync:
- **prune**: Removes resources no longer in Git
- **selfHeal**: Reverts manual changes to match Git
- **retry**: Automatically retries failed syncs

### GitOps Workflow

1. **Make changes** to manifests in Git
2. **Commit and push** to repository
3. **ArgoCD detects** changes (default: 3min poll)
4. **Auto-sync** applies changes to cluster
5. **Health check** verifies resources are healthy

## Airgap Configuration

### Registry Mirrors

All ArgoCD images are configured to pull from internal registry:
```
quay.io/argoproj/* → 192.168.107.6:5000/argoproj/*
ghcr.io/dexidp/*   → 192.168.107.6:5000/dexidp/*
```

### Network Isolation

NetworkPolicies ensure:
- ArgoCD can only access Kubernetes API and DNS
- No external internet access
- Communication between ArgoCD components allowed

## CLI Usage

Install ArgoCD CLI (optional):
```bash
# Connected zone
curl -sSL https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 \
  -o argocd
chmod +x argocd
sudo mv argocd /usr/local/bin/

# Login
argocd login localhost:8080 --insecure

# List applications
argocd app list

# Sync application manually
argocd app sync lumen-app

# Get application status
argocd app get lumen-app
```

## Troubleshooting

### ArgoCD pods not starting
```bash
# Check events
kubectl get events -n argocd --sort-by='.lastTimestamp'

# Check image pull issues
kubectl describe pod -n argocd -l app.kubernetes.io/part-of=argocd
```

### Application not syncing
```bash
# Check application status
kubectl describe application lumen-app -n argocd

# Check repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server
```

### DNS issues
```bash
# Verify DNS works in ArgoCD pods
kubectl exec -n argocd -it deployment/argocd-server -- nslookup kubernetes.default.svc
```

## Security Notes

- Default admin password should be changed immediately
- Use RBAC to restrict user permissions
- Disable exec in ArgoCD ConfigMap (already done)
- NetworkPolicies enforce least privilege access
