# Traefik Ingress Controller

## Table des matières

- [Vue d'ensemble](#vue-densemble)
- [Pourquoi Traefik?](#pourquoi-traefik)
- [Architecture](#architecture)
- [Workflow de déploiement](#workflow-de-déploiement)
- [Configuration](#configuration)
- [Accès aux services](#accès-aux-services)
- [Troubleshooting](#troubleshooting)

---

## Vue d'ensemble

Traefik v3.6.8 est déployé comme Ingress Controller pour exposer tous les services via HTTPS avec des URLs DNS propres (ex: `https://gitea.airgap.local`).

**Avant Traefik:**
```bash
# Multiples kubectl port-forward instables
kubectl port-forward -n gitea svc/gitea 3001:3000 &
kubectl port-forward -n monitoring svc/grafana 3000:3000 &
kubectl port-forward -n argocd svc/argocd-server 8081:443 &
# → Connexions qui meurent, ports à mémoriser, pas production-ready
```

**Après Traefik:**
```bash
# URLs DNS simples avec TLS automatique
https://gitea.airgap.local
https://grafana.airgap.local
https://argocd.airgap.local
# → Toujours disponible, load balancing, métriques, logs
```

---

## Pourquoi Traefik?

### Traefik vs kubectl port-forward

| Aspect | port-forward | Traefik |
|--------|--------------|---------|
| **Stabilité** | Meurt régulièrement | Toujours actif |
| **Production** | Dev uniquement | Production-ready |
| **Utilisateurs** | Single user | Multi-users |
| **Load balancing** | ❌ | ✅ (2+ replicas) |
| **TLS** | ❌ | ✅ (centralisé) |
| **Observabilité** | ❌ | ✅ (metrics, logs, dashboard) |

### Traefik vs NGINX Ingress

| Aspect | NGINX Ingress | Traefik |
|--------|---------------|---------|
| **Configuration** | Annotations (verbose) | CRDs (natif K8s) |
| **Dashboard** | ❌ | ✅ (built-in) |
| **API** | Limitée | Complète (REST) |
| **Learning curve** | Plus complexe | Plus moderne |
| **Production** | ✅ | ✅ |

**Choix:** Traefik pour l'expérience d'apprentissage SRE (API moderne, dashboard visuel, CRDs natifs).

### Pourquoi Helm?

**Tentative initiale:** Déploiement manuel avec YAML (namespace, CRDs, RBAC, Deployment, Service, ConfigMap).

**Problème rencontré:** Le provider `kubernetesCRD` démarrait mais ne chargeait **aucune** IngressRoute. Debugging intensif (RBAC, versions, flags) sans succès.

**Solution:** Passage au chart Helm officiel `traefik/traefik` v39.0.1.
- ✅ Fonctionne immédiatement après installation
- ✅ Configuration testée par des milliers d'utilisateurs
- ✅ Mises à jour simplifiées (`helm upgrade`)
- ✅ Rollback facile (`helm rollback`)

**Leçon:** Pour des composants critiques (Ingress, Monitoring), préférer Helm charts officiels plutôt que manifests manuels.

---

## Architecture

### Vue globale

```
Browser (https://gitea.airgap.local)
          ↓
/etc/hosts: gitea.airgap.local → 192.168.107.3
          ↓
K3d LoadBalancer (192.168.107.3:443)
          ↓
Traefik Pod (traefik namespace)
  ├── Entrypoint: websecure (443)
  ├── Router: Host(`gitea.airgap.local`)
  ├── Middleware: security-headers, compression
  ├── TLS Termination: *.airgap.local cert
  └── Service: gitea.gitea:3000
          ↓
Gitea Pod (gitea namespace)
```

### Concepts Traefik

#### 1. Entrypoints
Ports d'écoute de Traefik:
- `web` (80): Redirige automatiquement vers HTTPS
- `websecure` (443): TLS + routing des services
- `traefik` (8080): Dashboard + API + metrics (interne uniquement)

#### 2. Routers (IngressRoute CRD)
Règles de matching HTTP:
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: gitea-https
  namespace: gitea
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`gitea.airgap.local`)
      services:
        - name: gitea
          port: 3000
      middlewares:
        - {name: security-headers, namespace: traefik}
        - {name: compression, namespace: traefik}
  tls:
    secretName: airgap-tls
```

#### 3. Middlewares
Transformations de requêtes/réponses:
- **https-redirect**: Redirige HTTP → HTTPS (301)
- **security-headers**: HSTS, CSP, X-Frame-Options, etc.
- **compression**: Gzip pour réduire la bande passante
- **rate-limit**: Protection anti-abuse (100 req/s avg, 200 burst)
- **dashboard-auth**: Basic Auth pour le dashboard Traefik

#### 4. TLS
Certificat wildcard auto-signé `*.airgap.local`:
- Généré par Job Kubernetes (`02-cert-generation-job.yaml`)
- CA créé en interne (validité 10 ans)
- Server cert signé par CA (validité 1 an)
- Secret copié dans tous les namespaces

---

## Workflow de déploiement

### Phase 1: Connected Zone (images)

```bash
cd 01-connected-zone
chmod +x scripts/07-pull-traefik-images.sh
./scripts/07-pull-traefik-images.sh
```

**Télécharge:**
- `traefik:v3.6.8` (~150MB)
- Chart Helm `traefik-39.0.1.tgz` via `helm pull`

### Phase 2: Transit Zone (registry)

```bash
cd 02-transit-zone
./setup.sh  # Démarre registry si nécessaire
chmod +x push-traefik.sh
./push-traefik.sh
```

**Push vers:**
- `localhost:5000/traefik:v3.6.8`

### Phase 3: Airgap Zone (déploiement)

#### Étape 1: Génération des certificats TLS

```bash
cd 03-airgap-zone
kubectl apply -f manifests/traefik/02-cert-generation-job.yaml
kubectl wait --for=condition=complete --timeout=120s job/cert-generation -n traefik
```

**Ce Job crée:**
- CA privée key + certificat (auto-signé, 10 ans)
- Server key + CSR + certificat (signé par CA, 1 an)
- Secret `airgap-tls` avec `tls.crt` et `tls.key`

#### Étape 2: Installation Helm

```bash
helm install traefik ../../01-connected-zone/artifacts/traefik/helm/traefik-39.0.1.tgz \
  --namespace traefik \
  --create-namespace \
  --values manifests/traefik-helm/values.yaml \
  --wait
```

**Vérifie:**
```bash
kubectl get pods -n traefik
# Expected: 2/2 Running

kubectl get svc traefik -n traefik
# Expected: EXTERNAL-IP = 192.168.107.3
```

#### Étape 3: Middlewares

```bash
kubectl apply -f manifests/traefik/08-middlewares.yaml
```

**Crée:**
- https-redirect, security-headers, compression, rate-limit
- dashboard-auth + Secret avec credentials

#### Étape 4: Copie des secrets TLS

```bash
chmod +x scripts/copy-tls-secrets.sh
./scripts/copy-tls-secrets.sh
```

**Copie `airgap-tls` dans:**
- gitea, monitoring, argocd (pour IngressRoutes)

#### Étape 5: IngressRoutes

```bash
kubectl apply -f manifests/traefik/10-gitea-ingressroute.yaml
kubectl apply -f manifests/traefik/11-grafana-ingressroute.yaml
kubectl apply -f manifests/traefik/12-prometheus-ingressroute.yaml
kubectl apply -f manifests/traefik/13-alertmanager-ingressroute.yaml
kubectl apply -f manifests/traefik/14-argocd-ingressroute.yaml
```

**Pattern pour chaque service:**
- IngressRoute HTTP: Redirect → HTTPS
- IngressRoute HTTPS: TLS + Middlewares + Service backend

#### Étape 6: Configuration locale

```bash
# Extraire le CA certificate
chmod +x scripts/extract-ca-cert.sh
./scripts/extract-ca-cert.sh

# Installer le CA (macOS)
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ./airgap-ca.crt

# Setup DNS
chmod +x scripts/setup-dns.sh
./scripts/setup-dns.sh
```

**Le script DNS ajoute à `/etc/hosts`:**
```
192.168.107.3    traefik.airgap.local
192.168.107.3    gitea.airgap.local
192.168.107.3    grafana.airgap.local
192.168.107.3    prometheus.airgap.local
192.168.107.3    alertmanager.airgap.local
192.168.107.3    argocd.airgap.local
```

---

## Configuration

### values.yaml (Helm)

Configuration personnalisée pour airgap:

```yaml
image:
  registry: docker.io
  repository: library/traefik
  tag: "v3.6.8"
  pullPolicy: IfNotPresent

deployment:
  replicas: 2  # HA

service:
  type: LoadBalancer  # K3d expose sur 192.168.107.3

ports:
  web:
    port: 80
  websecure:
    port: 443
  traefik:
    port: 8080  # Dashboard (non exposé via LB)

ingressRoute:
  dashboard:
    enabled: true
    entryPoints: ["websecure"]
    matchRule: Host(`traefik.airgap.local`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
    middlewares:
      - {name: dashboard-auth, namespace: traefik}
    tls:
      secretName: airgap-tls

providers:
  kubernetesCRD:
    enabled: true
    allowCrossNamespace: true  # Important pour routing cross-ns
  kubernetesIngress:
    enabled: false  # On utilise IngressRoute CRD

logs:
  general:
    level: INFO
  access:
    enabled: true

metrics:
  prometheus:
    enabled: true

additionalArguments:
  - "--global.checknewversion=false"
  - "--global.sendanonymoususage=false"
  - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
  - "--entrypoints.web.http.redirections.entrypoint.scheme=https"

resources:
  requests:
    cpu: "200m"
    memory: "256Mi"
  limits:
    cpu: "1000m"
    memory: "512Mi"

securityContext:
  runAsUser: 65532
  runAsNonRoot: true

rbac:
  enabled: true
```

**Points clés:**
- `allowCrossNamespace: true`: Permet à Traefik (namespace `traefik`) de router vers d'autres namespaces
- HTTP → HTTPS redirect dans `additionalArguments`
- Dashboard sur entrypoint `websecure` (pas `traefik:8080`)
- Sécurité: non-root, resource limits

---

## Accès aux services

| Service | URL | Credentials |
|---------|-----|-------------|
| **Traefik Dashboard** | https://traefik.airgap.local/dashboard/ | `admin` / `admin` |
| **Gitea** | https://gitea.airgap.local | `gitea-admin` / `gitea-admin` |
| **Grafana** | https://grafana.airgap.local | `admin` / `admin` |
| **Prometheus** | https://prometheus.airgap.local | (aucun) |
| **AlertManager** | https://alertmanager.airgap.local | (aucun) |
| **ArgoCD** | https://argocd.airgap.local | `admin` / `aaGKhHCXIiJxgrsA` |

**Note:** Le mot de passe ArgoCD est stocké dans le secret:
```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Troubleshooting

### Problème 1: Dashboard 404

**Symptôme:**
```bash
curl -k https://traefik.airgap.local/dashboard/
# HTTP 404 Not Found
```

**Cause:** L'IngressRoute par défaut du Helm chart utilise l'entrypoint `traefik` (port 8080) qui n'est **pas** exposé via LoadBalancer.

**Solution:** Reconfigurer le dashboard dans `values.yaml`:
```yaml
ingressRoute:
  dashboard:
    enabled: true
    entryPoints: ["websecure"]  # ← Utiliser websecure (443)
    matchRule: Host(`traefik.airgap.local`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
```

Puis:
```bash
helm upgrade traefik ... --values values.yaml
```

---

### Problème 2: ArgoCD ERR_TOO_MANY_REDIRECTS

**Symptôme:**
```bash
curl -I https://argocd.airgap.local
# HTTP/2 307 Temporary Redirect
# Location: https://argocd.airgap.local/
# (boucle infinie)
```

**Cause:** ArgoCD force HTTPS en interne alors que Traefik a déjà terminé le TLS → boucle de redirection.

**Solution:**

1. Ajouter header `X-Forwarded-Port` au middleware:
```yaml
# manifests/traefik/14-argocd-ingressroute.yaml
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-Proto: "https"
      X-Forwarded-Host: "argocd.airgap.local"
      X-Forwarded-Port: "443"  # ← Important!
```

2. Configurer ArgoCD en mode insecure via ConfigMap:
```bash
kubectl patch configmap argocd-cmd-params-cm -n argocd \
  --type merge -p '{"data":{"server.insecure":"true"}}'

kubectl rollout restart deployment argocd-server -n argocd
```

**Vérification:**
```bash
curl -I https://argocd.airgap.local
# HTTP/2 200 OK ✅
```

---

### Problème 3: IngressRoutes pas chargées

**Symptôme:**
```bash
kubectl get ingressroute --all-namespaces
# 12 IngressRoutes existent

# Mais Traefik API ne montre que 5 routers internes
kubectl exec -n traefik deploy/traefik -- \
  wget -qO- http://localhost:8080/api/http/routers | jq 'length'
# 5 (au lieu de ~14)
```

**Cause (si déploiement manuel):** Configuration subtile incorrecte dans les manifests YAML manuels.

**Solution:** Utiliser le Helm chart officiel.

---

### Problème 4: Basic Auth ne fonctionne pas

**Symptôme:**
```bash
curl -u admin:admin https://traefik.airgap.local/dashboard/
# 401 Unauthorized
```

**Cause:** Hash du mot de passe incorrect dans le Secret.

**Solution:** Regénérer le hash avec `htpasswd`:
```bash
# Générer nouveau hash
htpasswd -nb admin admin

# Mettre à jour le Secret
kubectl create secret generic dashboard-auth-secret -n traefik \
  --from-literal="users=$(htpasswd -nb admin admin)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

### Problème 5: TLS Certificate Warnings

**Symptôme:** Navigateur affiche "Your connection is not private" / "NET::ERR_CERT_AUTHORITY_INVALID".

**Cause:** Le CA auto-signé n'est pas dans le trust store du système.

**Solution:**

**macOS:**
```bash
cd 03-airgap-zone
./scripts/extract-ca-cert.sh
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ./airgap-ca.crt

# Redémarrer le navigateur
```

**Linux:**
```bash
sudo cp airgap-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

**Temporaire (dev):**
```bash
curl -k https://gitea.airgap.local  # -k ignore les erreurs TLS
```

---

### Commandes utiles

**Logs Traefik:**
```bash
kubectl logs -n traefik -l app.kubernetes.io/name=traefik -f
```

**API Traefik (routers, services, middlewares):**
```bash
kubectl exec -n traefik deploy/traefik -- \
  wget -qO- http://localhost:8080/api/http/routers | jq

kubectl exec -n traefik deploy/traefik -- \
  wget -qO- http://localhost:8080/api/http/services | jq
```

**Vérifier IngressRoutes:**
```bash
kubectl get ingressroute --all-namespaces
kubectl describe ingressroute gitea-https -n gitea
```

**Tester routing depuis Traefik pod:**
```bash
kubectl exec -n traefik deploy/traefik -- \
  wget -qO- http://gitea.gitea.svc.cluster.local:3000
```

**Vérifier certificat TLS:**
```bash
kubectl get secret airgap-tls -n traefik -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -text | grep -A2 "Subject Alternative Name"
# DNS:*.airgap.local, DNS:airgap.local
```

**Helm status:**
```bash
helm status traefik -n traefik
helm get values traefik -n traefik
```

---

## Métriques et observabilité

### Prometheus Scraping

Traefik expose les métriques sur `http://traefik.traefik:8080/metrics`:

```yaml
# Prometheus ServiceMonitor (si operator installé)
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: traefik
  namespace: traefik
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: traefik
  endpoints:
    - port: traefik
      path: /metrics
```

**Métriques disponibles:**
- `traefik_entrypoint_requests_total` (par code HTTP)
- `traefik_entrypoint_request_duration_seconds`
- `traefik_service_requests_total`
- `traefik_service_request_duration_seconds`

### Dashboard Traefik

Accéder via: https://traefik.airgap.local/dashboard/

**Vue temps réel:**
- Tous les routers (IngressRoutes)
- Services backend avec health status
- Middlewares appliqués
- Métriques de requêtes (success rate, latency)

### Logs

**Access logs** (requêtes HTTP):
```bash
kubectl logs -n traefik -l app.kubernetes.io/name=traefik | grep "access"
```

Format:
```
192.168.1.100 - - [15/Feb/2026:10:30:00 +0000] "GET /dashboard/ HTTP/2.0" 200 1234 "-" "Mozilla/5.0"
```

---

## Évolution future

### Migration vers kube-prometheus-stack

Le monitoring actuel utilise des manifests YAML manuels. Helm serait préférable:

**Avantages:**
- ServiceMonitors automatiques pour Traefik, ArgoCD, etc.
- Dashboards Grafana pré-configurés
- AlertManager rules intégrées
- Mises à jour simplifiées

**TODO:** Migrer vers `prometheus-community/kube-prometheus-stack`.

### ArgoCD Application

Actuellement déployé via `helm install` manuel. Pour GitOps complet:

```yaml
# manifests/argocd/07-application-traefik.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://gitea.airgap.local/lumen/lumen.git
    targetRevision: main
    path: 03-airgap-zone/manifests/traefik-helm
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Note:** Nécessite de commit le chart Helm dans Git (ou référencer le chart via Helm repo).

---

## Ressources

- **Traefik Docs:** https://doc.traefik.io/traefik/
- **Helm Chart:** https://github.com/traefik/traefik-helm-chart
- **CRD Reference:** https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/
- **Middlewares:** https://doc.traefik.io/traefik/middlewares/overview/
