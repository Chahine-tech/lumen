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

---

## 11. MetalLB — LoadBalancer sans cloud

Dans un cloud (AWS, GCP...), quand tu crées un Service `type: LoadBalancer`, le cloud provider provisionne automatiquement une IP externe. Dans ce projet, on est sur des VMs locales — pas de cloud provider. MetalLB remplace cette fonctionnalité.

### Comment L2 Advertisement fonctionne

MetalLB utilise le mode **L2 (Layer 2 / ARP)**. Le principe : un des nodes "prend possession" de l'IP virtuelle (`192.168.2.100`) en répondant aux requêtes ARP du réseau local.

```
Mac (192.168.2.1)                    node-1 (192.168.2.2)
      │                                      │
      │  "Qui a 192.168.2.100 ?"  (ARP req) │
      │─────────────────────────────────────▶│
      │                                      │
      │  "C'est moi" (MAC: 52:54:00:aa:73:c6)│  ← MetalLB speaker répond
      │◀─────────────────────────────────────│
      │                                      │
      │  HTTPS → 192.168.2.100:443           │
      │─────────────────────────────────────▶│  → Traefik
```

Le **speaker** MetalLB (DaemonSet sur chaque node) surveille quels Services ont besoin d'une IP externe. Quand un Service `type: LoadBalancer` est créé, le speaker élit un node leader qui annonce l'IP en ARP.

### Pourquoi l'ARP se perd au reboot

Le Mac mémorise les associations IP↔MAC dans sa **table ARP** (cache temporaire). Après un reboot des VMs :
1. MetalLB speaker redémarre et recommence à répondre aux ARP
2. Mais le Mac a déjà une entrée ARP "incomplete" (ou expirée) pour `192.168.2.100`
3. Tant qu'il n'y a pas de trafic qui force un nouvel ARP request, le Mac ne "découvre" pas la nouvelle MAC

D'où l'entrée statique dans `start.yml` :
```bash
arp -s 192.168.2.100 52:54:00:aa:73:c6   # force l'association IP↔MAC
```

Sans ça, `https://argocd.airgap.local` timeout même si tout tourne dans le cluster.

---

## 12. Vault HA — Shamir's Secret Sharing

Vault stocke des secrets sensibles. Le problème : comment protéger la clé de chiffrement de Vault elle-même ? Si elle est sur disque, n'importe qui avec accès au disque peut déchiffrer tous les secrets.

### Le mécanisme d'unsealing

Vault utilise l'algorithme de **Shamir's Secret Sharing** : la clé maître est découpée en `N` fragments (shards), dont `K` sont nécessaires pour reconstituer la clé (threshold). Dans ce projet : 5 shards, threshold 3.

```
Clé maître (256 bits)
       │
       │ Shamir split (5 shards, threshold 3)
       ▼
  shard-1  shard-2  shard-3  shard-4  shard-5
  (dans vault-keys.json)

Au démarrage — Vault est "sealed" (données inaccessibles)
  → fournir 3 shards quelconques
  → Vault reconstitue la clé maître
  → Vault est "unsealed" (opérationnel)
```

Vault ne stocke **jamais** la clé maître en mémoire entre les redémarrages. C'est pour ça qu'à chaque reboot, Vault redémarre en état "sealed" et `unseal.yml` doit être rejoué.

### Vault HA avec Raft

Dans ce projet, Vault tourne en mode HA avec 3 pods (`vault-0`, `vault-1`, `vault-2`) et le backend de stockage **Raft** (consensus distribué intégré, pas besoin de Consul).

```
vault-0 (leader)   vault-1 (standby)   vault-2 (standby)
      │                   │                   │
      └───────────────────┴───────────────────┘
                   Raft consensus
                (réplication des données)

Requête → vault.airgap.local → Traefik → vault-active Service
                                          → toujours le leader Raft
```

Si `vault-0` tombe, Raft élit un nouveau leader parmi `vault-1`/`vault-2`. Mais les trois pods doivent être unsealed — c'est pourquoi `unseal.yml` unseal les 3 pods séquentiellement.

---

## 13. Supply Chain Security — Cosign

**Le problème** : comment savoir que l'image qui tourne dans le cluster est bien celle buildée par le CI, et pas une image substituée (attaque supply chain) ?

### Signature avec Cosign

Cosign permet de **signer cryptographiquement** une image OCI et de stocker la signature dans la même registry, sans infrastructure externe.

Dans le CI (`.gitea/workflows/ci.yaml`) :
```bash
# Après le docker push :
cosign sign \
  --key /tmp/cosign.key \        # clé privée (secret CI)
  --tlog-upload=false \          # pas de Rekor (airgap)
  192.168.2.2:5000/lumen-api:abc1234
```

Cosign calcule le digest SHA256 de l'image et crée un artifact OCI avec un tag spécial :
```
192.168.2.2:5000/lumen-api:abc1234              ← l'image
192.168.2.2:5000/lumen-api:sha256-XYZ....sig    ← la signature (artifact OCI)
```

La signature est stockée **dans le registry airgap** — pas besoin d'accès à Rekor (transparency log public). C'est l'adaptation airgap : `--tlog-upload=false`.

### Vérification

Pour vérifier qu'une image est bien signée :
```bash
cosign verify \
  --key cosign.pub \
  --insecure-ignore-tlog \
  192.168.2.2:5000/lumen-api:abc1234
```

Si la signature ne correspond pas à la clé publique → la vérification échoue → l'image ne doit pas tourner.

---

## 14. Argo Rollouts — Déploiements progressifs

Un `Deployment` K8s standard fait un **rolling update** : remplace progressivement les pods, mais sans contrôle sur le trafic et sans rollback automatique basé sur des métriques.

**Argo Rollouts** remplace le `Deployment` par un `Rollout` — même spec, mais avec une `strategy` avancée.

### Canary dans ce projet

```yaml
strategy:
  canary:
    stableService: lumen-api-stable    # 80% du trafic
    canaryService: lumen-api-canary    # 20% du trafic
    steps:
      - setWeight: 20     # étape 1 : 20% canary
      - analysis: ...     # check prometheus : success rate >= 95% ?
      - setWeight: 80     # étape 2 : 80% canary
      - analysis: ...     # check à nouveau
      - setWeight: 100    # promotion complète
```

Comment le split trafic fonctionne : Traefik pointe vers deux Services K8s (`lumen-api-stable` et `lumen-api-canary`). Argo Rollouts ajuste le nombre de pods dans chaque Service pour respecter les pourcentages.

### AnalysisTemplate — rollback automatique

L'`AnalysisTemplate` `success-rate` interroge Prometheus :
```promql
sum(rate(http_requests_total{app="lumen-api",status!~"5.."}[2m]))
/
sum(rate(http_requests_total{app="lumen-api"}[2m]))
```

Si le taux de succès passe sous 95% pendant 3 checks consécutifs → Argo Rollouts **rollback automatique** vers la version stable, sans intervention humaine.

```
git push → CI build → ArgoCD sync → Rollout démarre
                                          │
                                    20% canary
                                          │
                              ┌─── success rate < 95% ? ──▶ ROLLBACK automatique
                              │
                              └─── OK ──▶ 80% canary ──▶ OK ──▶ 100% (promotion)
```

---

## 15. Chaos Engineering — Chaos Mesh

**Le principe** : injecter des pannes contrôlées en production (ou en staging) pour vérifier que le système se comporte correctement sous stress. "Si tu n'as pas testé la panne, tu ne sais pas si tu peux récupérer."

### Types d'expériences dans ce projet

**PodChaos** (`01-podchaos-lumen-api.yaml`) :
```yaml
action: pod-kill
mode: fixed-percent
value: "50"       # tue 50% des pods lumen-api
duration: "2m"
```
Ce que ça teste : est-ce qu'Argo Rollouts recrée les pods ? Est-ce que le Service reste disponible avec les pods restants ?

**NetworkChaos** (`02-networkchaos-redis-latency.yaml`, `03-networkchaos-cnpg-latency.yaml`) :
```yaml
action: delay
delay:
  latency: "100ms"   # ajoute 100ms de latence réseau vers Redis/CNPG
```
Ce que ça teste : est-ce que lumen-api gère les timeouts correctement ? Est-ce que les circuit breakers fonctionnent ?

### Comment Chaos Mesh injecte les pannes

Chaos Mesh utilise un **DaemonSet** (`chaos-daemon`) sur chaque node qui a les privilèges pour manipuler les namespaces réseau Linux et tuer des processus. Quand tu `kubectl apply` une expérience :

```
ChaosExperiment (CR)
      │
      ▼
chaos-controller-manager
      │  sélectionne les pods cibles (labelSelector)
      ▼
chaos-daemon (sur le node cible)
      │  network: tc qdisc add dev eth0 root netem delay 100ms
      │  pod-kill: SIGKILL sur le PID du container
      ▼
Panne injectée
```

Quand l'expérience expire ou est supprimée, `chaos-daemon` annule les modifications (`tc qdisc del`).

---

## 16. IaC — Terraform + Ansible

Ce projet utilise **deux outils IaC** avec des responsabilités distinctes.

### Terraform — provisioning déclaratif

Terraform gère le **cycle de vie des VMs** Multipass. Son modèle est **déclaratif** : tu décris l'état souhaité, Terraform calcule le diff et applique.

```hcl
resource "multipass_instance" "node1" {
  name   = "node-1"
  cpus   = 4
  memory = "6G"
  disk   = "40G"
  cloudinit_file = "cloud-init/node1-rendered.yaml"
}
```

`terraform apply` → Multipass VM créée avec les bonnes specs + cloud-init (IP statique, Docker, sysctl).
`terraform destroy` → VM supprimée proprement.

**cloud-init** s'exécute au premier boot de la VM et configure : interface réseau statique (`enp0s1` / bridge), installation Docker, paramètres kernel (`fs.inotify.max_user_instances=8192` requis par Falco).

### Ansible — configuration idempotente

Ansible gère la **configuration du cluster** après que les VMs existent. Son modèle est **procédural mais idempotent** : chaque task vérifie si l'état est déjà atteint avant d'agir.

```
Terraform          Ansible
    │                  │
    │  VMs créées      │  K3s installé
    │  IPs configurées │  Registry configurée
    │  Docker installé │  Cluster bootstrapé
    ▼                  ▼
Infrastructure     Applications
```

### Pourquoi deux outils

| | Terraform | Ansible |
|---|---|---|
| Modèle | Déclaratif (state file) | Procédural (playbooks) |
| Idéal pour | Infra (VMs, réseau, cloud) | Config (packages, services, K8s) |
| State | Fichier `.tfstate` | Pas de state (check à chaque run) |
| Parallélisme | Natif (dependency graph) | Manuel (`async`) |

Terraform seul ne sait pas "installer K3s dans une VM". Ansible seul ne sait pas "créer une VM et attendre qu'elle soit prête". Les deux ensemble couvrent tout, du bare metal aux applications.

---

## 17. Opérateurs Kubernetes — Automation intelligente

Un **opérateur Kubernetes** n'est pas un simple script ou outil — c'est un **agent autonome** qui encode l'expertise opérationnelle d'une application complexe et la maintient automatiquement.

### Le pattern Operator

Un opérateur = **CRD** (Custom Resource Definition) + **Controller** (boucle de réconciliation).

```
Custom Resource (état désiré)     Controller (cerveau)
┌──────────────────────┐          ┌───────────────────────┐
│ apiVersion: cnpg/v1  │          │ cnpg-controller-mgr   │
│ kind: Cluster        │──watch──▶│ (pod qui tourne 24/7) │
│ spec:                │          └───────────────────────┘
│   instances: 3       │                    │
└──────────────────────┘                    │
                                  ┌─────────┴─────────┐
                                  ▼                   ▼
                            Crée 3 pods         Configure
                            PostgreSQL          réplication
```

Le controller exécute une **reconciliation loop** en permanence :

```go
// Pseudo-code simplifié du controller CNPG
func ReconcileLoop() {
  for {
    // 1. Lire l'état désiré (ton YAML)
    desired := GetCluster("lumen-db")  // instances: 3

    // 2. Lire l'état actuel (dans K8s)
    actual := GetRunningPods()  // 2 pods (1 est mort!)

    // 3. Comparer
    if actual.Count < desired.Instances {
      // 4. Réparer automatiquement
      CreateNewPod()
      if actual.Primary == nil {
        PromoteReplica()  // Failover automatique!
      }
    }

    // 5. Attendre et recommencer
    sleep(10s)
  }
}
```

Cette boucle tourne **en permanence** dans le pod du controller — c'est un processus vivant, pas un script one-shot.

### Opérateur vs Script/Helper

| Script/Helper | Opérateur |
|--------------|-----------|
| Tu l'appelles quand tu veux | Tourne **24/7** (pod qui watch) |
| Fait 1 action puis s'arrête | **Boucle infinie** de surveillance |
| Tu détectes les problèmes | **Détecte automatiquement** |
| Stateless | **Stateful** (connaît l'état désiré) |
| **Ex:** `kubectl scale` | **Ex:** HorizontalPodAutoscaler |

**Analogie** :
- **Script** = tournevis (tu visses une vis quand tu la vois desserrée, puis tu ranges l'outil)
- **Opérateur** = robot de maintenance (patrouille 24/7, détecte et visse automatiquement toutes les vis desserrées)

### Exemples concrets dans ce projet

#### CloudNativePG (opérateur PostgreSQL)

```yaml
# Tu écris juste ça:
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: lumen-db
spec:
  instances: 3
```

**Le controller CNPG fait automatiquement** :
- Crée 3 pods PostgreSQL avec la bonne config
- Configure la réplication streaming
- Crée les services `-rw` (master) et `-ro` (replicas)
- **Si le master meurt** → élit un nouveau master via Raft, promeut une replica, met à jour le service → **failover en 30s sans intervention humaine**
- Génère les credentials dans un Secret K8s
- Expose les métriques Prometheus
- Renouvelle les certs TLS avant expiry

**Sans opérateur**, tu devrais :
1. Créer un StatefulSet manuellement
2. Configurer Patroni ou Stolon pour le failover
3. Déployer etcd/Consul pour le consensus
4. Écrire des scripts de monitoring
5. Te réveiller à 3h du matin quand le master plante pour lancer `pg_ctl promote` à la main

**Avec CNPG** : tu dors, l'opérateur gère tout.

#### Chaos Mesh (opérateur chaos engineering)

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: redis-latency
spec:
  action: delay
  delay:
    latency: "100ms"
  duration: "5m"
  selector:
    namespaces: ["lumen"]
    labelSelectors:
      app: redis
```

**Le controller Chaos Mesh** :
- Surveille cette CR (Custom Resource)
- Demande au `chaos-daemon` (DaemonSet privilégié) d'injecter 100ms de latency réseau vers les pods Redis via `tc netem`
- Après 5 minutes → nettoie automatiquement (`tc qdisc del`)
- **Si le pod chaos-daemon redémarre pendant l'expérience** → réapplique le chaos automatiquement (reconciliation)

#### ArgoCD (opérateur GitOps)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: lumen
spec:
  source:
    repoURL: https://gitea.airgap.local/lumen/lumen.git
    path: 03-airgap-zone/manifests/app
  destination:
    server: https://kubernetes.default.svc
    namespace: lumen
  syncPolicy:
    automated:
      selfHeal: true
```

**Le controller ArgoCD** :
- Poll le repo Git toutes les 3 minutes
- Compare l'état Git (source of truth) vs l'état cluster
- **Si tu fais un `kubectl edit` manuel** → ArgoCD le détecte et revert (`selfHeal: true`)
- **Si un nouveau commit arrive** → applique automatiquement le diff

### Pourquoi c'est révolutionnaire

Les opérateurs **encodent l'expertise humaine en code** :

```
Expert PostgreSQL DBA sait:
  ✓ Comment faire un failover proprement
  ✓ Quand promouvoir une replica
  ✓ Comment configurer la réplication
  ✓ Comment gérer les backups WAL
  ✓ Quelle config tuner selon la RAM

→ Cette connaissance est encodée dans le controller CNPG
→ Disponible pour tout le monde, gratuitement, 24/7
→ Zéro fatigue, zéro oubli, zéro réveil à 3h du matin
```

**Résultat** : tu délègues l'intelligence opérationnelle à du code au lieu de payer des SRE pour être en astreinte.

---

## 18. Ingress Controllers — Reverse proxy intelligent

### Le problème à résoudre

Tu as 10 applications web dans le cluster :
- `argocd.airgap.local`
- `grafana.airgap.local`
- `vault.airgap.local`
- ...

**Sans Ingress** : tu aurais besoin de 10 IPs LoadBalancer différentes (une par Service) → gaspillage d'IPs.

**Avec Ingress** : une seule IP (`192.168.2.100`) route vers les bonnes applications selon le **hostname** de la requête HTTP.

### Architecture dans ce projet

```
Mac (navigateur)
      │
      │ HTTPS https://grafana.airgap.local (→ 192.168.2.100)
      ▼
  MetalLB (L2 ARP)
      │ "192.168.2.100 c'est sur node-1" (MAC address)
      ▼
  Traefik Ingress Controller (pod sur node-1)
      │
      │ Parse HTTP Host header: "grafana.airgap.local"
      │ Consulte les Ingress resources
      │ Route match trouvé: grafana.airgap.local → grafana:80
      ▼
  Service grafana (ClusterIP 10.96.x.x)
      │
      │ kube-proxy iptables DNAT
      ▼
  Pod Grafana (10.42.0.15:3000)
```

### Comment ça fonctionne

#### 1. Service LoadBalancer pour Traefik

```yaml
apiVersion: v1
kind: Service
metadata:
  name: traefik
spec:
  type: LoadBalancer          # MetalLB assigne 192.168.2.100
  ports:
    - name: web
      port: 80
      targetPort: 8000        # Port du pod Traefik
    - name: websecure
      port: 443
      targetPort: 8443
  selector:
    app.kubernetes.io/name: traefik
```

MetalLB annonce `192.168.2.100` en ARP. **Tout** le trafic HTTP/S du réseau local arrive sur ce pod Traefik.

#### 2. Ingress resources — routing rules

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
spec:
  ingressClassName: traefik
  rules:
    - host: grafana.airgap.local     # Virtual host
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana        # Service K8s cible
                port:
                  number: 80
  tls:
    - hosts:
        - grafana.airgap.local
      secretName: grafana-tls        # Cert TLS (cert-manager)
```

Traefik **watch** toutes les Ingress resources du cluster (via l'API K8s) et construit sa table de routage automatiquement :

```
Host: grafana.airgap.local  → grafana.monitoring.svc.cluster.local:80
Host: argocd.airgap.local   → argocd-server.argocd.svc.cluster.local:443
Host: vault.airgap.local    → vault.vault.svc.cluster.local:8200
```

#### 3. TLS termination

Traefik gère le **TLS handshake** avec le client. Le certificat est stocké dans le Secret `grafana-tls` (généré par cert-manager depuis Vault PKI).

```
Client                Traefik                      Grafana pod
  │                      │                             │
  │──── HTTPS ──────────▶│                             │
  │  (TLS encrypted)     │                             │
  │                      │  TLS decrypt                │
  │                      │  (cert from grafana-tls)    │
  │                      │                             │
  │                      │──── HTTP (plain) ───────────▶│
  │                      │                             │
  │◀──── HTTPS ──────────│◀──── HTTP ──────────────────│
```

**Avantage** : les pods backend (Grafana, ArgoCD...) n'ont pas besoin de gérer TLS eux-mêmes. Traefik centralise ça.

### Virtual Hosting — comment ça marche

Quand tu tapes `https://grafana.airgap.local` dans le navigateur :

1. **DNS** : `/etc/hosts` résout `grafana.airgap.local` → `192.168.2.100` (IP MetalLB)
2. **ARP** : ton Mac demande "qui a 192.168.2.100 ?" → MetalLB répond avec la MAC de node-1
3. **TCP** : connexion établie vers `192.168.2.100:443`
4. **TLS handshake** : Traefik présente le cert `grafana-tls` (signé par Vault PKI)
5. **HTTP request** :
   ```
   GET / HTTP/1.1
   Host: grafana.airgap.local    ← header crucial
   ```
6. **Traefik parse** le header `Host` → consulte sa table de routage → trouve l'Ingress `grafana` → proxy vers `grafana.monitoring.svc.cluster.local:80`
7. **Service K8s** → iptables DNAT → pod Grafana

**Même IP, plusieurs hostnames** : c'est le header HTTP `Host:` qui fait la différence. C'est pour ça que tu peux avoir 10 domaines différents tous pointant vers `192.168.2.100` — Traefik route selon le hostname.

### Ingress vs Service LoadBalancer

| | Service LoadBalancer | Ingress |
|---|---|---|
| **Layer** | L4 (TCP/UDP) | L7 (HTTP/HTTPS) |
| **Routing** | IP:Port → Pod | Hostname + Path → Service |
| **TLS** | Géré par l'app | Géré par Ingress Controller |
| **IPs nécessaires** | 1 par service | 1 pour N services |
| **Use case** | Bases de données, gRPC | Applications web |

**Exemple** :
- PostgreSQL (`lumen-db-rw:5432`) → Service LoadBalancer direct (pas HTTP, pas besoin d'Ingress)
- Grafana web UI → Ingress (routing HTTP + TLS termination)

### Traefik specifics

Dans ce projet, Traefik est déployé via Helm avec ces features :

**Automatic HTTPS redirect** :
```yaml
# traefik values
ports:
  web:
    redirectTo:
      port: websecure    # HTTP → HTTPS automatique
```

**Middleware** (exemple : BasicAuth pour ArgoCD) :
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: auth
spec:
  basicAuth:
    secret: authsecret
---
# Dans l'Ingress:
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: argocd-auth@kubernetescrd
```

Traefik injecte le middleware BasicAuth avant de proxy vers ArgoCD — protection additionnelle sans modifier ArgoCD.

**Dashboard** : Traefik expose son propre dashboard (`/dashboard`) pour voir les routes, middlewares, services actifs en temps réel.

---

## 19. StatefulSets — Apps avec identité stable

### Deployment vs StatefulSet

K8s propose deux façons de déployer des pods :

| Deployment | StatefulSet |
|-----------|-------------|
| Pods **sans état** (stateless) | Pods **avec état** (stateful) |
| Noms aléatoires (`lumen-api-7f8d9c-xk2p9`) | Noms **stables** (`lumen-db-1`, `lumen-db-2`) |
| Ordre de démarrage indéterminé | Démarrage **séquentiel** (0 → 1 → 2) |
| Scaling parallel | Scaling **ordonné** |
| Pas de storage stable | **PVC dédié** par pod (survit au restart) |
| Use case : APIs, workers | Use case : **bases de données, queues** |

### Sticky Identity — pourquoi c'est crucial

**Avec un Deployment** :
```
kubectl get pods -n lumen
lumen-api-7f8d9c-xk2p9    # nom aléatoire
lumen-api-7f8d9c-bh4k1

# Pod redémarre → nouveau nom
lumen-api-7f8d9c-zz9w3    # identité perdue
```

**Avec un StatefulSet** :
```
kubectl get pods -n lumen
lumen-db-1    # nom stable, toujours "1"
lumen-db-2    # nom stable, toujours "2"
lumen-db-3

# Pod lumen-db-1 redémarre → toujours "lumen-db-1"
# Son PVC reste attaché → les données PostgreSQL sont préservées
```

### Exemples dans ce projet

#### CNPG PostgreSQL

```yaml
# 03-airgap-zone/manifests/cnpg/02-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: lumen-db
spec:
  instances: 3
```

L'opérateur CNPG crée un **StatefulSet** en interne :
```
lumen-db-1  → master PostgreSQL (données dans PVC lumen-db-1)
lumen-db-2  → replica (données dans PVC lumen-db-2)
lumen-db-3  → witness (données dans PVC lumen-db-3)
```

**Pourquoi l'identité stable est cruciale** :
- CNPG doit savoir "qui est le master" → utilise le nom stable (`lumen-db-1`)
- Le master change (failover) → `lumen-db-2` devient master, mais garde son nom → les configs DNS restent cohérentes
- Chaque pod a **son propre PVC** → si `lumen-db-1` redémarre, il retrouve exactement ses données PostgreSQL

#### Redis HA

```
redis-master-0   → StatefulSet avec 1 replica
redis-replica-0  → StatefulSet avec 1 replica
```

Le suffixe `-0` indique que c'est un StatefulSet. Redis Sentinel utilise les noms stables pour tracker qui est le master.

#### Vault HA

```
vault-0  → leader Raft
vault-1  → standby
vault-2  → standby
```

Raft nécessite que chaque node ait une identité stable pour le quorum. Si `vault-0` redémarre, il doit rejoindre le cluster Raft avec la même identité.

### Ordered Deployment

Quand tu crées un StatefulSet avec 3 replicas :

```
kubectl apply -f statefulset.yaml

1. Crée pod-0
   → attend que pod-0 soit Ready
2. Crée pod-1
   → attend que pod-1 soit Ready
3. Crée pod-2
   → attend que pod-2 soit Ready
```

**Pourquoi c'est important** : dans un cluster PostgreSQL, le master (`lumen-db-1`) doit démarrer **avant** les replicas, sinon les replicas ne peuvent pas se connecter pour la réplication initiale.

### Scaling ordonné

```bash
# Scale down de 3 → 1
kubectl scale statefulset lumen-db --replicas=1

→ Supprime lumen-db-3 d'abord (attend termination)
→ Puis supprime lumen-db-2
→ Garde lumen-db-1
```

Toujours dans l'ordre inverse (N → 0). Ça évite de supprimer le master en premier dans un cluster de BDD.

### Headless Service

Les StatefulSets utilisent souvent un **Headless Service** (`clusterIP: None`) pour permettre la découverte directe des pods.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis-headless
spec:
  clusterIP: None    # Headless
  selector:
    app: redis
  ports:
  - port: 6379
```

DNS pour un Headless Service :
```
redis-headless.lumen.svc.cluster.local
  → retourne les IPs de TOUS les pods Redis (pas une VIP)

redis-master-0.redis-headless.lumen.svc.cluster.local
  → retourne l'IP exacte de redis-master-0 (FQDN stable)
```

C'est utilisé par Redis Sentinel : les sentinels doivent découvrir tous les pods Redis individuellement pour monitorer le master.

---

## 20. Storage — PersistentVolumes et PVC

### Le problème du storage éphémère

Par défaut, le filesystem d'un container est **éphémère** — quand le pod redémarre, tout est perdu.

```
Pod lumen-db-1 (PostgreSQL)
  ├── /var/lib/postgresql/data/   ← données DB (dans le container)
  └── Pod crash → redémarre
        → /var/lib/postgresql/data/ est VIDE
        → toutes les données perdues ❌
```

C'est catastrophique pour une base de données. Il faut un **storage persistant** qui survit au cycle de vie du pod.

### Architecture K8s Storage

```
StorageClass              PersistentVolume (PV)      PersistentVolumeClaim (PVC)       Pod
┌─────────────┐           ┌──────────────┐           ┌──────────────┐            ┌──────────┐
│ local-path  │──crée────▶│ pvc-abc123   │◀──bound──│ lumen-db-1   │◀──mount───│ lumen-db-1│
│ (provisioner│           │ 1Gi          │           │ 1Gi request  │            │ postgres │
│  K3s)       │           │ /var/lib/... │           └──────────────┘            └──────────┘
└─────────────┘           └──────────────┘
```

**3 objets K8s** :
1. **StorageClass** : définit **comment** provisionner du storage (local disk, NFS, cloud EBS...)
2. **PersistentVolume (PV)** : représente un volume **réel** (ex: `/var/lib/rancher/k3s/storage/pvc-abc123/`)
3. **PersistentVolumeClaim (PVC)** : une **demande** de storage par un pod ("je veux 1Gi")

### Comment ça fonctionne concrètement

#### 1. StorageClass (K3s local-path)

K3s embarque le provisioner `local-path` par défaut :

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer  # crée le PV seulement quand le pod démarre
```

Ce provisioner crée des **volumes locaux sur le node** dans `/var/lib/rancher/k3s/storage/`.

#### 2. PVC — demande de storage

CNPG crée automatiquement des PVC pour chaque pod PostgreSQL :

```yaml
# Créé automatiquement par CNPG
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lumen-db-1    # PVC dédié au pod lumen-db-1
  namespace: lumen
spec:
  accessModes:
    - ReadWriteOnce   # 1 seul pod peut monter ce volume (lecture/écriture)
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
```

**Statut du PVC** :
```bash
kubectl get pvc -n lumen
NAME         STATUS   VOLUME                                     CAPACITY
lumen-db-1   Bound    pvc-abc123-def456-ghi789                  1Gi
lumen-db-2   Bound    pvc-xyz789-uvw456-rst123                  1Gi
```

`Bound` = un PV a été créé et attaché à ce PVC.

#### 3. PV — volume réel

Le provisioner `local-path` crée automatiquement un PV :

```yaml
# Créé automatiquement par le provisioner
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pvc-abc123-def456-ghi789
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete    # supprime le volume si le PVC est supprimé
  storageClassName: local-path
  local:
    path: /var/lib/rancher/k3s/storage/pvc-abc123-def456-ghi789/  # chemin réel sur le node
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - node-1    # ce PV est sur node-1 uniquement
```

Le volume est **physiquement** sur le disque de `node-1` dans `/var/lib/rancher/k3s/storage/pvc-abc123.../`.

#### 4. Pod monte le PVC

```yaml
# StatefulSet lumen-db (créé par CNPG)
spec:
  template:
    spec:
      containers:
      - name: postgres
        volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data   # PostgreSQL écrit ici
  volumeClaimTemplates:
  - metadata:
      name: pgdata
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: local-path
      resources:
        requests:
          storage: 1Gi
```

Kubernetes monte le PV dans le container au path `/var/lib/postgresql/data`. PostgreSQL écrit ses fichiers WAL, tables, index dans ce répertoire → tout est persisté sur le disque du node.

### Lifecycle du storage

```
1. PVC créé (par CNPG StatefulSet)
     ↓
2. Provisioner crée un PV automatiquement
     ↓
3. PVC passe en état "Bound" (lié au PV)
     ↓
4. Pod démarre → kubelet monte le PV dans le container
     ↓
5. PostgreSQL écrit dans /var/lib/postgresql/data → écrit dans le PV
     ↓
6. Pod redémarre (crash, rollout, delete/recreate)
     ↓
7. Kubelet RE-monte le MÊME PV → les données sont intactes ✅
     ↓
8. PVC supprimé (kubectl delete pvc lumen-db-1)
     ↓
9. PV supprimé automatiquement (reclaimPolicy: Delete)
     → les données sont perdues ❌
```

**Important** : tant que le PVC existe, les données survivent aux restarts du pod. C'est pour ça que dans un StatefulSet, chaque pod a son PVC dédié avec un nom stable.

### Exemples dans ce projet

#### CNPG PostgreSQL

```
lumen-db-1  →  PVC lumen-db-1 (1Gi)  →  PV sur node-1
lumen-db-2  →  PVC lumen-db-2 (1Gi)  →  PV sur node-2
lumen-db-3  →  PVC lumen-db-3 (1Gi)  →  PV sur node-1 ou node-2
```

Si `lumen-db-1` (master) crash et redémarre → retrouve exactement son PVC → les données PostgreSQL sont intactes → la base continue de fonctionner.

#### Redis

```yaml
# 03-airgap-zone/manifests/app/02-redis.yaml
volumeClaimTemplates:
- metadata:
    name: data
  spec:
    accessModes: [ReadWriteOnce]
    storageClassName: local-path
    resources:
      requests:
        storage: 1Gi
```

Redis master stocke son RDB snapshot + AOF log dans le PVC → si le pod redis-master-0 redémarre, il recharge les données depuis le disque.

#### Vault

Vault utilise le backend Raft qui stocke les secrets chiffrés dans un répertoire local. Chaque pod Vault a un PVC dédié pour stocker son état Raft.

### Limitations du local-path

⚠️ **Local storage = pas de migration automatique** :
- Le PV est **lié à un node spécifique** (`nodeAffinity`)
- Si `node-1` tombe définitivement → le PV sur node-1 est inaccessible
- Le pod `lumen-db-1` ne peut pas migrer vers node-2 (son PVC est sur node-1)

**En prod cloud**, on utiliserait :
- AWS EBS (volumes réseau, détachables/réattachables)
- Ceph RBD (storage distribué)
- NFS (storage réseau partagé)

**Dans ce homelab**, `local-path` suffit — les VMs sont éphémères de toute façon. Pour une vraie prod, il faudrait un storage distribué ou des backups automatiques (CNPG supporte les backups WAL vers S3/Minio).

---

## 21. Observability Stack — Metrics, Logs, Dashboards

L'observabilité dans ce projet repose sur **3 piliers** complémentaires :

```
Metrics (Prometheus)        Logs (Loki)            Visualisation (Grafana)
┌─────────────────┐         ┌─────────────┐        ┌──────────────────┐
│ Counters        │         │ Structured  │        │ Dashboards       │
│ Gauges          │────┐    │ logs        │────┐   │ Alerts           │
│ Histograms      │    │    │ JSON        │    └──▶│ Unified view     │
│ Time-series DB  │    └───────────────────────────▶│ PromQL + LogQL   │
└─────────────────┘         └─────────────┘        └──────────────────┘
```

### 1. Prometheus — Time-Series Metrics

**Prometheus** est une base de données time-series optimisée pour stocker des **métriques numériques** :
- Nombre de requêtes HTTP (`http_requests_total`)
- Latence P95 (`http_request_duration_seconds`)
- Utilisation mémoire (`container_memory_usage_bytes`)
- Taille de la DB (`cnpg_pg_database_size_bytes`)

#### Comment Prometheus collecte les métriques

**Pull model** : Prometheus **scrape** (poll) les endpoints `/metrics` des applications :

```
Prometheus (pod dans monitoring namespace)
      │
      │ Scrape toutes les 15s
      ├──▶ http://lumen-db-1.lumen.svc:9187/metrics
      ├──▶ http://lumen-db-2.lumen.svc:9187/metrics
      ├──▶ http://falco.falco.svc:8765/metrics
      └──▶ http://redis-master-0.lumen.svc:9121/metrics
```

**Format Prometheus** (exemple CNPG) :
```
# HELP cnpg_pg_database_size_bytes Database size in bytes
# TYPE cnpg_pg_database_size_bytes gauge
cnpg_pg_database_size_bytes{database="app",pod="lumen-db-1"} 45678912
cnpg_pg_database_size_bytes{database="app",pod="lumen-db-2"} 45678912

# HELP cnpg_backends_total Active connections
# TYPE cnpg_backends_total gauge
cnpg_backends_total{pod="lumen-db-1",state="active"} 12
```

Chaque métrique = **nom** + **labels** + **valeur** + **timestamp**.

#### ServiceMonitor / PodMonitor

Au lieu de configurer manuellement les targets Prometheus, on utilise des **CRDs** :

```yaml
# 03-airgap-zone/manifests/cnpg/04-pod-monitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-lumen-db
  namespace: lumen
  labels:
    release: kube-prometheus-stack    # ← label requis pour la découverte
spec:
  selector:
    matchLabels:
      cnpg.io/cluster: lumen-db       # sélectionne les pods CNPG
  podMetricsEndpoints:
  - port: metrics                     # port 9187 (exposé par CNPG)
    path: /metrics
```

Prometheus **watch** tous les PodMonitor/ServiceMonitor du cluster via l'API K8s et configure automatiquement les scrapes. Quand un nouveau pod CNPG apparaît → Prometheus commence à le scraper sans intervention.

#### PromQL — Query Language

**PromQL** permet d'interroger les métriques. Exemples dans ce projet :

```promql
# Taille totale de la DB PostgreSQL
sum(cnpg_pg_database_size_bytes{database="app"})

# Taux de requêtes HTTP par seconde (lumen-api)
rate(http_requests_total{app="lumen-api"}[5m])

# Latence P95 des requêtes
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))

# Replication lag CNPG (alerte si > 10s)
cnpg_pg_replication_lag > 10
```

### 2. Loki — Structured Logs

**Loki** est une base de logs optimisée pour stocker des **logs structurés** (JSON) avec indexation par labels seulement (pas de full-text index comme Elasticsearch).

#### Comment les logs arrivent dans Loki

**Alloy** (anciennement Grafana Agent) collecte les logs et les pousse vers Loki :

```
Falco pod                       Alloy (DaemonSet)              Loki
    │                                 │                          │
    │ stdout: {"priority":"Warning",  │                          │
    │  "rule":"Unexpected outbound",  │                          │
    │  "output_fields":{...}}         │                          │
    │─────────────────────────────────▶│                          │
    │                                  │ Parse JSON               │
    │                                  │ Extrait labels:          │
    │                                  │   app=falco              │
    │                                  │   priority=Warning       │
    │                                  │   namespace=falco        │
    │                                  │                          │
    │                                  │──── Push logs ──────────▶│
    │                                  │  (HTTP POST /loki/api/v1/push)
```

Alloy tourne en **DaemonSet** (1 pod par node) et lit les logs de tous les containers via `/var/log/pods/`.

**Structured logging** : les apps loggent en JSON (pas en texte brut) :
```json
{
  "time": "2025-01-15T10:23:45Z",
  "level": "warning",
  "rule": "Contact K8S API Server From Container",
  "output_fields": {
    "container.id": "abc123",
    "k8s.pod.name": "lumen-api-7f8d9c-xk2p9",
    "k8s.ns.name": "lumen"
  }
}
```

Loki indexe seulement les **labels** (`app`, `namespace`, `priority`), pas le contenu complet → très efficace en storage.

#### LogQL — Query Language

**LogQL** ressemble à PromQL :

```logql
# Tous les logs Falco avec priority Warning
{app="falco", priority="Warning"}

# Logs contenant "Contact K8S API Server" dans les 5 dernières minutes
{app="falco"} |= "Contact K8S API Server" [5m]

# Taux d'erreurs par seconde (logs avec level=error)
rate({app="lumen-api", level="error"} [1m])

# Agrégation : compter les alertes Falco par règle
sum by (rule) (count_over_time({app="falco"}[1h]))
```

### 3. Grafana — Unified Dashboards

**Grafana** unifie Prometheus (metrics) + Loki (logs) dans des **dashboards interactifs**.

#### Datasources

Grafana est configuré avec 2 datasources :

```yaml
# kube-prometheus-stack Helm values
grafana:
  datasources:
    - name: Prometheus
      type: prometheus
      url: http://prometheus-kube-prometheus-stack-prometheus:9090

    - name: Loki
      type: loki
      url: http://loki:3100
```

Un dashboard peut mixer les deux :
- Panel 1 : Graphe PromQL (`rate(http_requests_total[5m])`)
- Panel 2 : Table LogQL (`{app="lumen-api", level="error"}`)

#### Dashboard auto-loading (sidecar)

Les dashboards sont stockés dans des **ConfigMaps** avec un label spécial :

```yaml
# 03-airgap-zone/manifests/cnpg/05-grafana-dashboard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cnpg-grafana-dashboard
  namespace: lumen
  labels:
    grafana_dashboard: "1"    # ← label magique
data:
  cnpg.json: |
    {
      "dashboard": {
        "title": "CloudNativePG",
        "panels": [...]
      }
    }
```

Le **Grafana sidecar** (container dans le pod Grafana) **watch** tous les ConfigMaps avec le label `grafana_dashboard: "1"` et les charge automatiquement dans Grafana. Quand tu `kubectl apply` un nouveau dashboard → il apparaît dans Grafana en quelques secondes.

#### Exemple : Dashboard CNPG

Panels typiques du dashboard CloudNativePG (ID 20417) :
- **Database Size** : `cnpg_pg_database_size_bytes` → graphe croissant
- **Active Connections** : `cnpg_backends_total{state="active"}` → gauge
- **Replication Lag** : `cnpg_pg_replication_lag` → alerte si > 10s
- **Queries/sec** : `rate(cnpg_pg_stat_database_xact_commit[5m])`
- **Slow Queries** : logs Loki `{app="postgresql"} |= "duration:"` filtrés par durée > 1s

### 4. Alloy — Unified Collector

**Grafana Alloy** (successeur de Grafana Agent) collecte **metrics + logs + traces** et les route vers les backends (Prometheus, Loki, Tempo).

Dans ce projet, Alloy est déployé en **DaemonSet** :
- Collecte les **logs** de `/var/log/pods/` → push vers Loki
- Collecte les **metrics** des pods via scraping → push vers Prometheus (ou expose pour que Prometheus scrape)

Configuration Alloy (simplifié) :
```hcl
// Collect logs from /var/log/pods
loki.source.kubernetes "pods" {
  targets    = discovery.kubernetes.pods.targets
  forward_to = [loki.write.default.receiver]
}

// Push to Loki
loki.write "default" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

### Workflow complet : du code à l'alerte

```
1. lumen-api reçoit une requête
     ↓
2. Incrémente métrique : http_requests_total++
     ↓
3. Log structuré : {"level":"info", "method":"GET", "path":"/items", "duration_ms":45}
     ↓
4. Prometheus scrape :9090/metrics toutes les 15s
     → stocke http_requests_total dans TSDB
     ↓
5. Alloy lit stdout du pod via /var/log/pods/
     → parse JSON → push vers Loki
     ↓
6. Grafana dashboard affiche :
     → Graphe PromQL : rate(http_requests_total[5m])
     → Logs LogQL : {app="lumen-api"} [5m]
     ↓
7. Alerte Prometheus : rate(http_requests_total{status=~"5.."}[5m]) > 10
     → Prometheus envoie une alerte à Alertmanager
     → Alertmanager route vers Slack/PagerDuty
```

### Pourquoi cette stack ?

| Tool | Rôle | Alternative |
|------|------|-------------|
| **Prometheus** | Metrics TSDB | InfluxDB, Datadog, VictoriaMetrics |
| **Loki** | Logs (index-free) | Elasticsearch (full-text), Splunk |
| **Grafana** | Visualisation | Kibana, Datadog UI |
| **Alloy** | Collecteur unifié | Fluentd, Logstash, Vector |

**Avantages de cette stack** :
- **Open-source** et **cloud-native** (CNCF)
- **Léger** (Loki < Elasticsearch en RAM/storage)
- **Unified** (1 seul UI pour metrics + logs)
- **Airgap-friendly** (pas de SaaS externe)

---
