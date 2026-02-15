# Traefik Ingress Controller - Helm Deployment

## Quick Start

Traefik v3.6.8 is deployed using the official Helm chart (v39.0.1).

**Why Helm?** Initial manual YAML deployment failed (IngressRoutes not loading). Helm chart worked immediately.

For comprehensive documentation, see: **[docs/traefik.md](../../../../docs/traefik.md)**

---

## Deployment Workflow

### 1. Generate TLS Certificates

```bash
kubectl apply -f ../traefik/02-cert-generation-job.yaml
kubectl wait --for=condition=complete --timeout=120s job/cert-generation -n traefik
```

Creates self-signed CA + wildcard cert for `*.airgap.local`.

### 2. Install Traefik via Helm

```bash
helm install traefik ../../01-connected-zone/artifacts/traefik/helm/traefik-39.0.1.tgz \
  --namespace traefik \
  --create-namespace \
  --values values.yaml \
  --wait
```

**Verification:**
```bash
kubectl get pods -n traefik  # Should show 2/2 Running
kubectl get svc traefik -n traefik  # EXTERNAL-IP = 192.168.107.3
```

### 3. Deploy Middlewares

```bash
kubectl apply -f ../traefik/08-middlewares.yaml
```

Creates: https-redirect, security-headers, compression, rate-limit, dashboard-auth.

### 4. Copy TLS Secrets

```bash
../../scripts/copy-tls-secrets.sh
```

Copies `airgap-tls` secret to: gitea, monitoring, argocd namespaces.

### 5. Deploy IngressRoutes

```bash
kubectl apply -f ../traefik/10-gitea-ingressroute.yaml
kubectl apply -f ../traefik/11-grafana-ingressroute.yaml
kubectl apply -f ../traefik/12-prometheus-ingressroute.yaml
kubectl apply -f ../traefik/13-alertmanager-ingressroute.yaml
kubectl apply -f ../traefik/14-argocd-ingressroute.yaml
```

Each service gets 2 IngressRoutes (HTTP + HTTPS).

### 6. Local Machine Setup

```bash
# Extract CA certificate
cd ../../
./scripts/extract-ca-cert.sh

# Install CA (macOS)
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ./airgap-ca.crt

# Setup DNS
./scripts/setup-dns.sh

# Restart browser to apply CA trust
```

---

## Access Services

| Service | URL | Credentials |
|---------|-----|-------------|
| Traefik Dashboard | https://traefik.airgap.local/dashboard/ | admin / admin |
| Gitea | https://gitea.airgap.local | gitea-admin / gitea-admin |
| Grafana | https://grafana.airgap.local | admin / admin |
| Prometheus | https://prometheus.airgap.local | (none) |
| AlertManager | https://alertmanager.airgap.local | (none) |
| ArgoCD | https://argocd.airgap.local | admin / [get from secret] |

**Get ArgoCD password:**
```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Configuration (values.yaml)

**Key settings:**

```yaml
deployment:
  replicas: 2  # HA

service:
  type: LoadBalancer  # K3d exposes on 192.168.107.3

providers:
  kubernetesCRD:
    enabled: true
    allowCrossNamespace: true  # Cross-namespace routing

ingressRoute:
  dashboard:
    enabled: true
    entryPoints: ["websecure"]  # Port 443 (not traefik:8080)
    matchRule: Host(`traefik.airgap.local`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
    middlewares:
      - {name: dashboard-auth, namespace: traefik}

metrics:
  prometheus:
    enabled: true

additionalArguments:
  - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
  - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
```

---

## Verification

```bash
# Quick verification script
../../scripts/verify-traefik.sh

# Manual checks
kubectl get pods -n traefik
kubectl get ingressroute --all-namespaces
curl -k -I https://gitea.airgap.local  # Should return HTTP/2 200
```

---

## Troubleshooting

### Dashboard 404

**Symptom:** https://traefik.airgap.local/dashboard/ returns 404.

**Cause:** Dashboard IngressRoute on wrong entrypoint (traefik:8080 not exposed via LoadBalancer).

**Fix:** Already configured in `values.yaml` to use `websecure` entrypoint.

### ArgoCD Redirect Loop

**Symptom:** `ERR_TOO_MANY_REDIRECTS` on https://argocd.airgap.local

**Fix:**
1. Middleware has `X-Forwarded-Port: "443"` header
2. ArgoCD ConfigMap has `server.insecure: true`

If still failing:
```bash
kubectl patch configmap argocd-cmd-params-cm -n argocd \
  --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
```

### Basic Auth Not Working

**Symptom:** `401 Unauthorized` with admin:admin.

**Fix:** Regenerate htpasswd hash:
```bash
kubectl create secret generic dashboard-auth-secret -n traefik \
  --from-literal="users=$(htpasswd -nb admin admin)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### TLS Certificate Warnings

**Symptom:** Browser shows "Not secure" / certificate error.

**Fix:** Install CA certificate (see step 6 above) and restart browser.

---

## Helm Operations

**Upgrade Traefik:**
```bash
helm upgrade traefik ../../01-connected-zone/artifacts/traefik/helm/traefik-39.0.1.tgz \
  --namespace traefik \
  --values values.yaml
```

**Rollback:**
```bash
helm rollback traefik -n traefik
```

**Get current values:**
```bash
helm get values traefik -n traefik
```

**Status:**
```bash
helm status traefik -n traefik
```

---

## Resources

- **Full documentation:** [docs/traefik.md](../../../../docs/traefik.md)
- **Traefik Docs:** https://doc.traefik.io/traefik/
- **Helm Chart:** https://github.com/traefik/traefik-helm-chart
- **IngressRoute CRD:** https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/
