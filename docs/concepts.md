# Concepts — Synthèse technique

Ce document explique les concepts fondamentaux utilisés dans le projet : Linux, réseau, Kubernetes, sécurité. Pas une liste de définitions — une explication de comment chaque concept fonctionne **concrètement dans ce projet**.

---

## 1. Linux — Les fondations

### Namespaces Linux

Tout ce que fait Kubernetes repose sur les namespaces Linux (pas les namespaces K8s — c'est différent). Un namespace Linux isole une ressource système pour un groupe de processus.

Il en existe 7 types. Les plus importants pour K8s :

| Namespace | Isole | Utilisé pour |
|-----------|-------|-------------|
| `net` | Interfaces réseau, tables de routage, ports | Chaque pod a son propre réseau |
| `pid` | Arbre des processus | PID 1 dans le container ≠ PID 1 du host |
| `mnt` | Points de montage | Le filesystem du container est isolé |
| `uts` | Hostname | Le container a son propre hostname |
| `ipc` | IPC (shared memory, sémaphores) | Isolation mémoire partagée |
| `user` | UIDs/GIDs | Rootless containers |

Quand tu fais `kubectl exec -it pod -- sh`, tu entres dans les namespaces de ce pod — son réseau, son filesystem, ses processus.

### cgroups (control groups)

Les namespaces isolent la **visibilité**. Les cgroups contrôlent la **consommation** de ressources.

```
Pod spec:
  resources:
    requests:
      memory: 128Mi   ← cgroup.memory.soft_limit
      cpu: 100m
    limits:
      memory: 256Mi   ← cgroup.memory.limit_in_bytes
      cpu: 500m       ← cgroup.cpu.cfs_quota_us
```

Quand un container dépasse sa `memory.limit` → OOMKilled par le kernel. C'est pourquoi dans le projet tous les pods ont des `requests` et `limits` (OPA Gatekeeper le force).

### iptables

`iptables` est le firewall Linux utilisé pour le routage et le filtrage de paquets. Il fonctionne avec des **chains** (INPUT, OUTPUT, FORWARD) et des **rules** appliquées dans l'ordre.

Dans ce projet, iptables sert à **simuler l'airgap** :

```bash
# Bloque tout le trafic sortant
iptables -A OUTPUT -d 0.0.0.0/0 -j DROP

# Autorise le réseau interne (cluster + registry)
iptables -I OUTPUT -d 10.0.0.0/8 -j ACCEPT     # Pod CIDR K3s
iptables -I OUTPUT -d 192.168.2.0/24 -j ACCEPT  # Multipass network
```

K3s lui-même utilise iptables pour le load balancing des Services (kube-proxy mode iptables) — quand un pod appelle `redis-headless:6379`, iptables redirige vers l'IP réelle du pod Redis.

### systemd & signals

Quand `kubectl rollout` met à jour un déploiement, K8s envoie `SIGTERM` au processus principal du container (PID 1). L'application a `terminationGracePeriodSeconds` (30s par défaut) pour s'arrêter proprement.

C'est pour ça que lumen-api écoute `SIGTERM` :

```go
signal.Notify(shutdown, syscall.SIGTERM, syscall.SIGINT)
// → server.Shutdown(ctx, 30s timeout)
// → redis.Close() + postgres.Close()
```

Si l'app ignore SIGTERM, K8s envoie SIGKILL après le timeout — les requêtes en cours sont coupées brutalement.

---

## 2. Réseau Kubernetes

### Comment un pod obtient son IP

1. kubelet demande au runtime (containerd) de créer le container
2. containerd appelle le **CNI plugin** (Flannel dans ce projet)
3. Flannel crée un namespace réseau Linux (`ip netns add`)
4. Flannel crée une interface virtuelle (`veth pair`) :
   - un côté dans le namespace du pod → `eth0`
   - l'autre côté dans le namespace du host → `vethXXXXX`
5. Flannel assigne une IP depuis le Pod CIDR (`10.42.0.0/16`)
6. Flannel configure les routes pour que les pods de node-1 puissent parler aux pods de node-2

```
node-1 (192.168.2.2)              node-2 (192.168.2.3)
┌─────────────────────┐           ┌─────────────────────┐
│ pod: 10.42.0.5      │           │ pod: 10.42.1.3       │
│  eth0 ←→ veth0      │           │  eth0 ←→ veth0       │
│         │           │           │         │            │
│    cni0 bridge      │           │    cni0 bridge       │
│         │           │           │         │            │
│    flannel.1 ───────┼─── VXLAN ─┼─── flannel.1        │
│    (overlay tunnel) │           │    (overlay tunnel)  │
└─────────────────────┘           └─────────────────────┘
```

**VXLAN** : protocole d'encapsulation — les paquets entre nodes sont encapsulés dans des paquets UDP. Flannel gère ça automatiquement.

### Services K8s — comment ça marche vraiment

Un `Service` n'est pas un processus qui tourne. C'est une **règle iptables** (ou une entrée eBPF avec Cilium).

```
kubectl apply -f service-redis.yaml
→ kube-proxy ajoute des règles iptables sur chaque node :

-A KUBE-SERVICES -d 10.96.45.23/32 -p tcp --dport 6379
  -j KUBE-SVC-REDIS

-A KUBE-SVC-REDIS
  -m statistic --mode random --probability 0.5 -j KUBE-SEP-REDIS-1
  -j KUBE-SEP-REDIS-2

-A KUBE-SEP-REDIS-1 -j DNAT --to-destination 10.42.0.8:6379
-A KUBE-SEP-REDIS-2 -j DNAT --to-destination 10.42.1.4:6379
```

Quand lumen-api fait `redis-headless:6379` :
1. DNS résout `redis-headless.lumen.svc.cluster.local` → `10.96.45.23`
2. Le paquet sort du pod avec dst `10.96.45.23:6379`
3. iptables intercepte → DNAT → redirige vers `10.42.0.8:6379` (IP réelle du pod Redis)
4. Flannel route le paquet vers node-1 ou node-2 selon où est le pod Redis

### DNS cluster — CoreDNS

Chaque pod a `nameserver 10.96.0.10` dans son `/etc/resolv.conf` — c'est CoreDNS.

```
lumen-api → redis-headless:6379
         → CoreDNS résout:
           redis-headless.lumen.svc.cluster.local
           → retourne les IPs des pods directement (Headless Service)
              (pour Redis Sentinel — le client doit connaître toutes les IPs)

lumen-api → lumen-db-rw:5432
         → CoreDNS résout:
           lumen-db-rw.cnpg-system.svc.cluster.local
           → retourne l'IP du Service (ClusterIP)
              (CNPG gère le failover — l'IP du Service reste stable)
```

**Headless Service** (`clusterIP: None`) : CoreDNS retourne directement les IPs des pods. Utilisé pour Redis Sentinel — le client doit découvrir le master lui-même via les sentinels.

**ClusterIP Service** : CoreDNS retourne une IP virtuelle. kube-proxy/iptables fait le DNAT. Utilisé pour PostgreSQL — CNPG gère quel pod est le primary.

### NetworkPolicies — Zero Trust

Par défaut, **tous les pods peuvent se parler**. Les NetworkPolicies changent ça.

Dans ce projet, le pattern est :

```yaml
# 1. Bloquer tout (namespace lumen)
kind: NetworkPolicy
spec:
  podSelector: {}        # s'applique à tous les pods
  policyTypes: [Ingress, Egress]
  # pas de règles = tout bloqué

# 2. Autoriser explicitement ce qui est nécessaire
kind: NetworkPolicy
spec:
  podSelector:
    matchLabels:
      app: lumen-api
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: redis
      ports:
        - port: 6379
```

Les NetworkPolicies sont **additives** — plusieurs policies sur le même pod = union des règles. Une seule policy qui bloque suffit, mais une seule qui autorise ne suffit pas si une autre bloque.

**Important** : les NetworkPolicies sont implémentées par le **CNI**, pas par kube-proxy. Flannel seul ne les supporte pas — c'est pour ça que ce projet utilise `kube-router` comme controller de NetworkPolicy en parallèle de Flannel.

---

## 3. Containerd et les images

### Comment containerd pull une image

Sans registry mirror :
```
containerd → docker.io/falcosecurity/falco:0.43.0
           → DNS : index.docker.io
           → HTTPS pull → image layers
```

Avec registry mirror (ce projet) :
```
/etc/rancher/k3s/registries.yaml:
  mirrors:
    docker.io:
      endpoint: ["http://192.168.2.2:5000"]

containerd → docker.io/falcosecurity/falco:0.43.0
           → mirror : http://192.168.2.2:5000/falcosecurity/falco:0.43.0
           → HTTP pull depuis la registry interne
           → si absent → erreur (pas de fallback internet — airgap)
```

### OCI — Open Container Initiative

Les images Docker et Kubernetes suivent le standard OCI. Une image OCI c'est :
- un **manifest** JSON : liste des layers + config
- des **layers** : archives tar compressées (les diffs du filesystem)
- une **config** JSON : entrypoint, env, labels...

Le tout stocké dans une registry OCI (le Docker Registry v2 dans ce projet).

Cosign exploite ce standard : une signature est stockée comme un **artifact OCI** avec un tag `sha256-<digest>.sig` dans la même registry. Pas de stockage externe nécessaire.

```
192.168.2.2:5000/lumen-api:abc1234      ← l'image
192.168.2.2:5000/lumen-api:sha256-XYZ.sig  ← la signature Cosign
```

### Multi-stage build

Le Dockerfile de lumen-api utilise un multi-stage build :

```dockerfile
# Stage 1 : builder (avec Go toolchain ~500MB)
FROM golang:1.26 AS builder
COPY . .
RUN go build -o /app ./cmd/server

# Stage 2 : image finale (distroless ~5MB)
FROM gcr.io/distroless/static
COPY --from=builder /app /app
ENTRYPOINT ["/app"]
```

L'image finale ne contient **que le binaire** — pas de shell, pas de package manager, pas de libc. Si Falco détecte un `execve` dans ce container, c'est forcément suspect (il n'y a rien à exécuter).

---

## 4. TLS et PKI

### Comment TLS fonctionne (handshake simplifié)

```
Client (navigateur)          Serveur (Traefik)
     │                              │
     │──── ClientHello ────────────▶│
     │     (TLS version, ciphers)   │
     │                              │
     │◀─── ServerHello ─────────────│
     │     + Certificate            │  ← cert signé par Vault PKI CA
     │                              │
     │  Vérifie : cert signé par    │
     │  une CA de confiance ?       │
     │  → airgap-ca.crt importée    │
     │    dans le trust store macOS │
     │                              │
     │──── ClientKeyExchange ──────▶│
     │     (session key chiffré)    │
     │                              │
     │◀══════ données chiffrées ════│
```

Dans ce projet, la CA racine est générée par Vault PKI. Elle est importée dans macOS via `03-airgap-zone/scripts/trust-ca.sh` — c'est pourquoi `https://grafana.airgap.local` s'ouvre sans warning dans le navigateur.

### cert-manager — automatisation du cycle de vie

Sans cert-manager, tu dois :
1. Générer une CSR (Certificate Signing Request)
2. La faire signer par Vault
3. Stocker le cert dans un K8s Secret
4. Renouveler avant expiry (manuellement)

Avec cert-manager :

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-tls
spec:
  secretName: grafana-tls        # K8s Secret créé automatiquement
  issuerRef:
    name: vault-issuer           # ClusterIssuer → Vault PKI
  dnsNames:
    - grafana.airgap.local
  duration: 720h                 # 30 jours
  renewBefore: 168h              # renouvelé 7j avant expiry
```

cert-manager surveille l'expiry, contacte Vault, obtient un nouveau cert, met à jour le Secret — **sans intervention humaine**.

### mTLS — Mutual TLS

TLS standard : seul le **serveur** présente un certificat (le client vérifie l'identité du serveur).

mTLS : **les deux côtés** présentent un certificat. Le serveur vérifie aussi l'identité du client.

```
lumen-api (client cert)    ←──mTLS──→    Redis (server cert)
     │ "je suis lumen-api"              "je suis redis"
     │  cert signé par Vault PKI         cert signé par Vault PKI
```

Dans ce projet, cert-manager génère des certs pour chaque service. Seuls les services avec un cert valide signé par la même CA peuvent communiquer — même si un attaquant bypass les NetworkPolicies, il ne peut pas établir la connexion TLS.

---

## 5. eBPF — Modern Kernel Observability

**eBPF** (extended Berkeley Packet Filter) permet d'exécuter des programmes sandboxés directement dans le kernel Linux, sans modifier le kernel ni charger de module.

Falco utilise eBPF (`modern_ebpf` driver) pour surveiller les **syscalls** :

```
lumen-api process
    │
    │ syscall: connect(fd, "8.8.8.8:443")   ← tentative connexion externe
    │
    ▼
Linux Kernel
    │
    │ eBPF hook sur sys_connect
    │ → exécute le programme Falco eBPF
    │ → compare avec les règles Falco
    │ → "Unexpected outbound connection" → alert
    │
    ▼
Falco daemon (userspace)
    → log structuré → Alloy → Loki → Grafana
```

**Avantages vs kernel module** :
- Pas besoin de recompiler pour chaque version kernel
- Sandbox : un bug dans le programme eBPF ne peut pas crasher le kernel
- Performances : le hook est dans le kernel path, pas de context switch userspace

**kube-router** utilise aussi eBPF pour enforcer les NetworkPolicies — plus efficace que les règles iptables O(n) car eBPF utilise des hash maps O(1).

---

## 6. GitOps — Pourquoi c'est différent du CI/CD classique

**CI/CD classique (push model)** :
```
git push → CI build → CI deploy (kubectl apply)
```
Le CI a accès direct au cluster. Si le CI est compromis → cluster compromis.

**GitOps (pull model)** :
```
git push → CI build → CI push image + update manifest
                                    ↑
                     ArgoCD poll Gitea (pull)
                     ArgoCD apply diff
```

Le cluster **tire** la config depuis Git. Le CI n'a **jamais** accès au cluster. Git devient la source de vérité — `kubectl apply` manuel est écrasé par ArgoCD (`selfHeal: true`).

Avantages :
- **Audit trail** : chaque changement en prod = un commit Git
- **Rollback** = `git revert` → ArgoCD re-sync
- **Drift detection** : si quelqu'un fait un `kubectl edit` à la main, ArgoCD le revert
- **Sécurité** : seul ArgoCD (dans le cluster) a les credentials K8s

---

## 7. Helm — Templating K8s

Helm est un gestionnaire de packages pour K8s. Un **chart** Helm c'est :
- des templates YAML avec des variables (`{{ .Values.image.tag }}`)
- un `values.yaml` avec les valeurs par défaut
- un `Chart.yaml` avec les métadonnées

Dans ce projet, chaque composant a un **wrapper chart** :

```
03-airgap-zone/manifests/chaos-mesh-helm/
├── Chart.yaml          ← dépendance vers le chart officiel
├── values-airgap-override.yaml  ← override registry + ressources
└── charts/
    └── chaos-mesh-2.7.2.tgz    ← chart officiel (bundled, airgap)
```

Le chart officiel est téléchargé en connected zone et bundlé dans `charts/`. ArgoCD fait `helm template` localement sans accès internet.

`helm dependency update` télécharge les charts des dépendances dans `charts/`. C'est ce qui permet l'installation en airgap.

---

## 8. RBAC Kubernetes

**RBAC** (Role-Based Access Control) contrôle qui peut faire quoi sur quelles ressources K8s.

```
ServiceAccount (identité du pod)
    │
    │ RoleBinding / ClusterRoleBinding
    │ (lie un SA à un Role)
    ▼
Role / ClusterRole (liste de permissions)
    rules:
    - apiGroups: [""]
      resources: ["pods"]
      verbs: ["get", "list", "watch"]
```

Exemple concret — ArgoCD :
- `argocd-application-controller` a un `ClusterRole` qui peut `get/list/watch/apply` sur toutes les ressources
- `argocd-server` (UI) a un `Role` plus restrictif — juste lire les Applications

Falco avec k8smeta :
- Le `k8s-metacollector` a un `ClusterRole` pour `watch` les pods, nodes, namespaces
- Il expose ces métadonnées à Falco via gRPC — c'est ce qui permet à Falco d'enrichir ses alertes avec `k8s.pod.name`, `k8s.ns.name`

---

## 9. Admission Controllers

Un **admission controller** est un webhook qui intercepte toutes les requêtes à l'API K8s avant qu'elles soient persistées dans etcd.

```
kubectl apply -f pod.yaml
       │
       ▼
  K8s API Server
       │
       ├── Authentication (token/cert valide ?)
       ├── Authorization (RBAC : droit de créer un Pod ?)
       │
       ├── Mutating Admission Webhooks    ← modifie la requête
       │   (ex: injecter un sidecar)
       │
       ├── Validating Admission Webhooks  ← accepte ou rejette
       │   ├── OPA Gatekeeper             ← pas de :latest, resource limits...
       │   └── PSS (Pod Security Standards) ← pas de root, pas de privileged...
       │
       └── Persisté dans etcd → kubelet crée le pod
```

**OPA Gatekeeper** utilise des `ConstraintTemplate` (Rego policy) + `Constraint` (configuration) :

```
ConstraintTemplate: BlockLatestTag
  → code Rego qui vérifie si image tag == "latest"

Constraint: block-latest-tag
  → appliqué à tous les namespaces
  → violation → requête rejetée + message d'erreur
```

**Pod Security Standards** sont intégrés dans K8s (depuis 1.25) — pas de webhook externe. Configurés par label de namespace :
```
namespace lumen:
  pod-security.kubernetes.io/enforce: restricted
```

---

## 10. etcd — Le cerveau du cluster

`etcd` est la base de données distribuée où K8s stocke **tout son état** : pods, services, secrets, configmaps, CRDs...

Dans ce projet, K3s embarque etcd en mode single-node (pas de cluster etcd multi-node). Toutes les données du cluster sont dans `/var/lib/rancher/k3s/server/db/`.

**Pourquoi c'est important pour la sécurité :**
- Les K8s Secrets sont stockés dans etcd en **base64** (pas chiffré par défaut)
- C'est pour ça que ce projet utilise Vault — les vrais secrets ne sont jamais dans etcd
- VSO génère des K8s Secrets à la volée depuis Vault, mais ils sont éphémères et rotatables

```
etcd contient:
  ✅ Manifests (Deployments, Services...)
  ✅ ConfigMaps (config non-sensible)
  ⚠️  K8s Secrets (base64 seulement — évité au maximum)
  ✅ CRDs et leurs instances
  ✅ État des Leases (leader election)
```
