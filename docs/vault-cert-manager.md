# Vault HA + cert-manager — Secrets Management & PKI (Phase 19)

This document covers Phase 19: deploying HashiCorp Vault HA (3-replica Raft cluster) and cert-manager v1.17.1 in the airgap K3s cluster, including all problems encountered and how they were resolved.

**Date**: February 23, 2026

---

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Versions & Components](#versions--components)
- [Phase 19 Step-by-Step](#phase-19-step-by-step)
  - [1. Image & Chart Pull (Connected Zone)](#1-image--chart-pull-connected-zone)
  - [2. Push to Airgap Registry (Transit Zone)](#2-push-to-airgap-registry-transit-zone)
  - [3. Vault Helm Deployment](#3-vault-helm-deployment)
  - [4. cert-manager Helm Deployment](#4-cert-manager-helm-deployment)
  - [5. Vault Bootstrap (Init + Unseal)](#5-vault-bootstrap-init--unseal)
  - [6. Vault Engine Configuration](#6-vault-engine-configuration)
  - [7. cert-manager ClusterIssuer + Certificate](#7-cert-manager-clusterissuer--certificate)
  - [8. Vault UI IngressRoute](#8-vault-ui-ingressroute)
- [Problems Encountered & Fixes](#problems-encountered--fixes)
- [Operational Reference](#operational-reference)
- [Key Files](#key-files)

---

## Overview

### Why Vault + cert-manager?

The previous setup had two critical weaknesses:

1. **TLS certs**: a one-shot OpenSSL Job generated the `*.airgap.local` wildcard cert. Manual renewal once a year, and if ArgoCD recreated the Job (via `ttlSecondsAfterFinished`), a **new CA was generated** → trust store broken on macOS without warning.

2. **PostgreSQL credentials**: stored as a plain K8s Secret (`lumen-db-app`) → readable by anyone with `kubectl get secret`.

**cert-manager** solves the TLS problem:
- CRD `Certificate` → cert-manager watches it and creates/renews the Secret automatically
- Native integration with Vault PKI as issuer
- Renewal configured 30 days before expiry (`renewBefore: 720h`)
- No ArgoCD interaction, no surprise rotation

**Vault** solves the secrets problem:
- Centralized secrets store with audit trail
- PKI Engine: CA managed by Vault, certs issued on demand with short TTL
- KV v2: PostgreSQL credentials stored encrypted at rest
- Agent Injector: sidecar writes `/vault/secrets/db-creds` into the pod at runtime → no Secret object in K8s

---

## Architecture

```
cert-manager → Vault PKI Engine → issues airgap-tls Secret → Traefik serves HTTPS

lumen-api Pod
  ├── lumen-api container  ← reads /vault/secrets/db-creds
  └── vault-agent (sidecar injected by MutatingWebhookConfiguration)
        └── authenticates via K8s ServiceAccount → Vault KV → writes file

Vault HA (Raft consensus, 3 pods)
  ├── vault-0 (node-1) — leader
  ├── vault-1 (node-2) — follower
  └── vault-2 (node-2) — follower

Engines enabled:
  ├── kv/v2  → path "lumen/"   (app credentials)
  └── pki/   → Airgap Local CA (TLS cert issuance)

Auth Methods:
  └── kubernetes/ → pods authenticate via their ServiceAccount JWT
                   → Vault verifies with K8s TokenReview API
                   → returns short-lived Vault token

Policies:
  ├── lumen-api-policy    → read lumen/data/*, read pki/sign/airgap-role
  └── cert-manager-policy → create pki/sign/airgap-role, create pki/issue/airgap-role
```

### IAM Flow (Kubernetes Auth)

```
Pod starts
  │
  ├── vault-agent sidecar reads SA JWT (/var/run/secrets/kubernetes.io/serviceaccount/token)
  │
  └── POST /v1/auth/kubernetes/login {role: "lumen-api", jwt: "<sa-jwt>"}
        │
        └── Vault calls K8s TokenReview API → verifies SA name + namespace
              │
              └── Returns Vault token (TTL 1h, auto-renewed by agent)
                    │
                    └── vault-agent reads KV secret → writes /vault/secrets/db-creds
```

---

## Versions & Components

| Component | Version | Helm Chart |
|-----------|---------|------------|
| HashiCorp Vault | 1.19.0 | hashicorp/vault 0.30.0 |
| Vault Agent Injector (vault-k8s) | 1.6.2 | included in vault chart |
| cert-manager | v1.17.1 | jetstack/cert-manager v1.17.1 |

Images in registry `192.168.2.2:5000`:

| Image | Tag |
|-------|-----|
| `192.168.2.2:5000/hashicorp/vault` | `1.19.0` |
| `192.168.2.2:5000/hashicorp/vault-k8s` | `1.6.2` |
| `192.168.2.2:5000/jetstack/cert-manager-controller` | `v1.17.1` |
| `192.168.2.2:5000/jetstack/cert-manager-webhook` | `v1.17.1` |
| `192.168.2.2:5000/jetstack/cert-manager-cainjector` | `v1.17.1` |
| `192.168.2.2:5000/jetstack/cert-manager-startupapicheck` | `v1.17.1` |

---

## Phase 19 Step-by-Step

### 1. Image & Chart Pull (Connected Zone)

```bash
# Vault
docker pull hashicorp/vault:1.19.0
docker pull hashicorp/vault-k8s:1.6.2
helm repo add hashicorp https://helm.releases.hashicorp.com
helm pull hashicorp/vault --version 0.30.0 -d artifacts/vault/helm/
docker save hashicorp/vault:1.19.0 -o artifacts/vault/images/vault-1.19.0.tar
docker save hashicorp/vault-k8s:1.6.2 -o artifacts/vault/images/vault-k8s-1.6.2.tar

# cert-manager
helm repo add jetstack https://charts.jetstack.io
helm pull jetstack/cert-manager --version v1.17.1 -d artifacts/cert-manager/helm/
for img in controller webhook cainjector startupapicheck; do
  docker pull quay.io/jetstack/cert-manager-${img}:v1.17.1
  docker save quay.io/jetstack/cert-manager-${img}:v1.17.1 \
    -o artifacts/cert-manager/images/cert-manager-${img}-v1.17.1.tar
done
```

### 2. Push to Airgap Registry (Transit Zone)

Images must be pushed **from node-1** (macOS Docker cannot reach `192.168.2.2:5000` directly — it's a non-TLS registry configured only in node-1's containerd):

```bash
# Transfer tars to node-1
multipass transfer artifacts/vault/images/vault-1.19.0.tar node-1:/tmp/
multipass transfer artifacts/vault/images/vault-k8s-1.6.2.tar node-1:/tmp/

# Load + tag + push from node-1
multipass exec node-1 -- bash -c "
  docker load -i /tmp/vault-1.19.0.tar
  docker tag hashicorp/vault:1.19.0 192.168.2.2:5000/hashicorp/vault:1.19.0
  docker push 192.168.2.2:5000/hashicorp/vault:1.19.0

  docker load -i /tmp/vault-k8s-1.6.2.tar
  docker tag hashicorp/vault-k8s:1.6.2 192.168.2.2:5000/hashicorp/vault-k8s:1.6.2
  docker push 192.168.2.2:5000/hashicorp/vault-k8s:1.6.2
"
```

### 3. Vault Helm Deployment

Helm chart extracted into `03-airgap-zone/manifests/vault-helm/` (same pattern as Traefik, kube-prometheus-stack).

Two files: `values.yaml` (original chart defaults, required for Helm rendering) + `values-airgap-override.yaml` (our overrides).

Key overrides in `values-airgap-override.yaml`:
```yaml
global:
  tlsDisable: true  # TLS terminated at Traefik

server:
  image:
    repository: 192.168.2.2:5000/hashicorp/vault
    tag: "1.19.0"
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true  # auto-sets node_id from pod name
      config: |
        cluster_name = "lumen-vault"
        storage "raft" {
          path = "/vault/data"
        }
        listener "tcp" {
          address         = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_disable     = true
        }
        service_registration "kubernetes" {}

networkPolicy:
  enabled: false  # managed externally (16-allow-vault.yaml)
```

ArgoCD Application: `03-airgap-zone/manifests/argocd/13-application-vault.yaml`
- sync-wave: `"7"` (after Gitea wave 5, Alloy wave 6)
- `ServerSideApply=true` (Vault CRDs are large)

### 4. cert-manager Helm Deployment

Key overrides in `values-airgap-override.yaml`:
```yaml
crds:
  enabled: true

image:
  repository: 192.168.2.2:5000/jetstack/cert-manager-controller
  tag: v1.17.1

webhook:
  securePort: 10260  # K3s: port 10250 clashes with kubelet
  image:
    repository: 192.168.2.2:5000/jetstack/cert-manager-webhook
    tag: v1.17.1

cainjector:
  image:
    repository: 192.168.2.2:5000/jetstack/cert-manager-cainjector
    tag: v1.17.1
```

ArgoCD Application: `03-airgap-zone/manifests/argocd/14-application-cert-manager.yaml`
- sync-wave: `"8"` (after Vault wave 7)
- `ServerSideApply=true` (cert-manager CRDs are large)

### 5. Vault Bootstrap (Init + Unseal)

Vault pods start **Sealed** — init and unseal must be done **manually** (no KMS available in airgap).

```bash
# Init (run once — saves to vault-keys.json)
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-keys.json

# ⚠️ vault-keys.json contains unseal keys + root token — store securely!

# Unseal all 3 pods (need 3 keys out of 5 each time)
for pod in vault-0 vault-1 vault-2; do
  for i in 0 1 2; do
    key=$(jq -r ".unseal_keys_b64[$i]" vault-keys.json)
    kubectl exec -n vault $pod -- vault operator unseal $key
  done
done

# Verify cluster state
kubectl exec -n vault vault-0 -- vault status
# → Sealed: false, HA Mode: active, HA Enabled: true
```

**After every cluster restart** (Vault doesn't auto-unseal — no cloud KMS):
```bash
# vault-keys.json is stored locally (not in K8s — that would defeat the purpose)
for pod in vault-0 vault-1 vault-2; do
  for i in 0 1 2; do
    key=$(jq -r ".unseal_keys_b64[$i]" vault-keys.json)
    kubectl exec -n vault $pod -- vault operator unseal $key
  done
done
```

### 6. Vault Engine Configuration

Run after init+unseal. The `02-vault-init-job.yaml` Job automates this, but can also be done manually:

```bash
export VAULT_TOKEN=$(jq -r '.root_token' vault-keys.json)

# ── KV v2 ──────────────────────────────────────────────────────────────
kubectl exec -n vault vault-0 -- sh -c "
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN
vault secrets enable -path=lumen kv-v2
"

# ── PKI Engine ─────────────────────────────────────────────────────────
# Generate CA inside Vault (preferred — no need to import private key)
kubectl exec -n vault vault-0 -- sh -c "
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki   # MUST tune BEFORE generating CA
vault write pki/root/generate/internal \
  common_name='Airgap Local CA' \
  ttl=87600h key_type=rsa key_bits=4096

vault write pki/roles/airgap-role \
  allowed_domains='airgap.local' \
  allow_subdomains=true \
  allow_bare_domains=true \
  allow_wildcard_certificates=true \
  max_ttl=8760h
vault write pki/config/urls \
  issuing_certificates='http://vault.vault.svc.cluster.local:8200/v1/pki/ca' \
  crl_distribution_points='http://vault.vault.svc.cluster.local:8200/v1/pki/crl'
"

# Export CA cert and import into macOS
kubectl exec -n vault vault-0 -- sh -c \
  'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN vault read -field=certificate pki/cert/ca' \
  > 03-airgap-zone/airgap-ca.crt
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain 03-airgap-zone/airgap-ca.crt

# ── Policies ───────────────────────────────────────────────────────────
kubectl exec -n vault vault-0 -- sh -c "
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN
vault policy write lumen-api-policy - <<EOF
path \"lumen/data/*\" { capabilities = [\"read\"] }
path \"pki/sign/airgap-role\" { capabilities = [\"create\", \"update\"] }
EOF
vault policy write cert-manager-policy - <<EOF
path \"pki/sign/airgap-role\" { capabilities = [\"create\", \"update\"] }
path \"pki/issue/airgap-role\" { capabilities = [\"create\", \"update\"] }
EOF
"

# ── Kubernetes Auth ────────────────────────────────────────────────────
kubectl exec -n vault vault-0 -- sh -c "
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc \
  disable_local_ca_jwt=false

# Role for lumen-api pods
vault write auth/kubernetes/role/lumen-api \
  bound_service_account_names=default \
  bound_service_account_namespaces=lumen \
  policies=lumen-api-policy \
  ttl=1h

# Role for cert-manager
vault write auth/kubernetes/role/cert-manager \
  bound_service_account_names=cert-manager,cert-manager-vault-auth \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager-policy \
  ttl=1h
"

# ── Seed PostgreSQL credentials ────────────────────────────────────────
PG_USER=$(kubectl get secret lumen-db-app -n lumen -o jsonpath='{.data.username}' | base64 -d)
PG_PASS=$(kubectl get secret lumen-db-app -n lumen -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n vault vault-0 -- sh -c "
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN
vault kv put lumen/db username='$PG_USER' password='$PG_PASS' dbname=app
"
```

### 7. cert-manager ClusterIssuer + Certificate

```bash
# Apply ClusterIssuer (connects cert-manager to Vault PKI)
kubectl apply -f 03-airgap-zone/manifests/vault/03-vault-issuer.yaml

# Wait for Ready
kubectl get clusterissuer vault-issuer
# → READY: True

# Apply Certificate (triggers cert issuance)
kubectl apply -f 03-airgap-zone/manifests/vault/04-airgap-certificate.yaml

# Monitor issuance
kubectl get certificate -n traefik -w
# → airgap-tls   True   airgap-tls   5m

# Verify cert details
kubectl get secret airgap-tls -n traefik -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -text \
  | grep -E "Issuer|Subject:|Not After|DNS:"
# → Issuer: CN=Airgap Local CA
# → Not After: Feb 21 00:54:09 2027 GMT
# → DNS: *.airgap.local, airgap.local
```

### 8. Vault UI IngressRoute

```bash
# Copy airgap-tls Secret to vault namespace (Traefik needs it there)
kubectl get secret airgap-tls -n traefik -o json \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['metadata']['namespace']='vault'
for k in ['resourceVersion','uid','creationTimestamp','managedFields']:
    d['metadata'].pop(k,None)
print(json.dumps(d))
" | kubectl apply -f -

# Apply IngressRoute
kubectl apply -f 03-airgap-zone/manifests/traefik/18-vault-ingressroute.yaml

# Add to /etc/hosts
sudo sh -c 'echo "192.168.2.100 vault.airgap.local" >> /etc/hosts'

# Test
curl -sk https://vault.airgap.local/ -o /dev/null -w "%{http_code}"
# → 200
```

---

## Problems Encountered & Fixes

### Problem 1 — Vault Helm: `nil pointer` on `networkPolicy.enabled`

**Symptom**:
```
ArgoCD sync error:
template: vault/templates/server-networkpolicy.yaml:
nil pointer evaluating interface {}.enabled
```

**Root Cause**: The Vault Helm chart template checks `.Values.server.networkPolicy.enabled`, but our `values.yaml` was only our overrides — missing all chart defaults.

**Fix**: Restored `values.yaml` to the original chart defaults (extracted from `vault-0.30.0.tgz`). Our airgap customizations go in `values-airgap-override.yaml` only. Same pattern as kube-prometheus-stack.

Also explicitly added to override:
```yaml
networkPolicy:
  enabled: false  # managed externally
```

---

### Problem 2 — Vault Helm: invalid `{{ env "HOSTNAME" }}` in Raft config

**Symptom**:
```
template: vault/templates/server-statefulset.yaml:
function "env" not defined
```

**Root Cause**: Helm templates don't have an `env` function. The Raft config had:
```hcl
node_id = "{{ env "HOSTNAME" }}"
```
This is valid in Vault's HCL config (runtime substitution) but not in Helm Go templates.

**Fix**: Removed the `node_id` line entirely. The Vault Helm chart's `setNodeId: true` option injects `VAULT_RAFT_NODE_ID` env var from the pod name — Vault picks it up automatically.

---

### Problem 3 — Vault storage type `file` instead of `raft`

**Symptom**: vault-0 started with `file` storage (single node, no HA) because the init ran before the correct Raft config was applied.

**Fix**:
```bash
# Delete vault-0 pod AND its PVC (PVC has the wrong storage type baked in)
kubectl delete pvc data-vault-0 -n vault
kubectl delete pod vault-0 -n vault

# ArgoCD recreates vault-0 with correct Raft config
# Re-init from scratch
kubectl exec -n vault vault-0 -- vault operator init -key-shares=5 -key-threshold=3 -format=json
```

---

### Problem 4 — ArgoCD: StatefulSet `replicas` is immutable

**Symptom**:
```
The StatefulSet "vault" is invalid:
spec.replicas: Forbidden: may not be changed when spec.volumeClaimTemplates is set
```

**Fix**: Delete StatefulSet without cascading (preserves existing pods), then let ArgoCD recreate:
```bash
kubectl delete statefulset vault -n vault --cascade=orphan
# ArgoCD resync → recreates with replicas: 3
```

---

### Problem 5 — cert-manager webhook: cross-node `connection refused` (port 10250)

**Symptom**: cert-manager webhook calls failing with 502 when the webhook pod was on node-2 and the API server (on node-1) tried to call it.

**Root Cause**: K3s/K3s uses kube-router for NetworkPolicy. Port 10250 is the kubelet port — kube-router's iptables rules block external TCP connections to port 10250 at the host level, even for pod IPs. When a webhook call goes cross-node (API server on node-1 → webhook pod on node-2, port 10250), kube-router RSTs the connection.

See: https://cert-manager.io/docs/installation/compatibility/

**Fix**: Change webhook to use a non-kubelet port:
```yaml
# values-airgap-override.yaml
webhook:
  securePort: 10260  # was 10250 (clashes with kubelet on K3s)
```

Also update NetworkPolicy (`17-allow-cert-manager.yaml`):
```yaml
ingress:
  - ports:
      - protocol: TCP
        port: 10260  # was 10250
```

---

### Problem 6 — ArgoCD did not apply the `securePort: 10260` change

**Symptom**: ArgoCD showed "Synced" at the correct commit but the webhook Deployment still had `--secure-port=10250`.

**Root Cause**: The Helm template with port 10260 generated a containerPort named `https` with value `10260`. But the existing Deployment already had a port named `https` with value `10250`. Server-Side Apply detected a conflict and silently skipped updating the Deployment (it considered it already "reconciled" by the previous manager).

**Fix**: Manual `kubectl patch` with JSON Patch to update both fields simultaneously:
```bash
kubectl patch deployment cert-manager-webhook -n cert-manager \
  --type=json \
  -p='[
    {"op": "replace", "path": "/spec/template/spec/containers/0/args/1", "value": "--secure-port=10260"},
    {"op": "replace", "path": "/spec/template/spec/containers/0/ports/0/containerPort", "value": 10260}
  ]'
```
ArgoCD's selfHeal then kept the value (because it now matched the desired state).

---

### Problem 7 — Namespace labels missing for NetworkPolicies

**Symptom**: ClusterIssuer got `connection refused` when trying to reach `vault.vault.svc.cluster.local:8200`.

**Root Cause**: NetworkPolicies use `namespaceSelector: matchLabels: name: vault`, but newly created namespaces only get the automatic label `kubernetes.io/metadata.name: vault`. The `name: vault` label must be added explicitly.

**Fix**:
```bash
kubectl label namespace vault name=vault --overwrite
kubectl label namespace cert-manager name=cert-manager --overwrite
# Other namespaces (lumen, traefik, monitoring, gitea) already had this label
```

---

### Problem 8 — Vault Kubernetes auth: `service account name not authorized`

**Symptom**:
```
Failed to initialize Vault client:
POST http://vault.vault.svc.cluster.local:8200/v1/auth/kubernetes/login
Code: 403 — service account name not authorized
```

**Root Cause**: The Vault Kubernetes role `cert-manager` was configured with `bound_service_account_names=cert-manager`, but the ClusterIssuer uses ServiceAccount `cert-manager-vault-auth`.

**Fix**:
```bash
vault write auth/kubernetes/role/cert-manager \
  bound_service_account_names=cert-manager,cert-manager-vault-auth \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager-policy \
  ttl=1h
```

---

### Problem 9 — PKI role: `bare domain airgap.local not allowed`

**Symptom**:
```
Vault failed to sign certificate:
Code: 400 — subject alternate name airgap.local not allowed by this role
```

**Root Cause**: The PKI role was created with `allow_subdomains=true` but `allow_bare_domains` defaulted to `false`. The Certificate requested `airgap.local` (the apex domain) which is not a subdomain.

**Fix**:
```bash
vault write pki/roles/airgap-role \
  allowed_domains='airgap.local' \
  allow_subdomains=true \
  allow_bare_domains=true \
  allow_wildcard_certificates=true \
  max_ttl=8760h
```

---

### Problem 10 — PKI: cert TTL exceeds CA lifetime

**Symptom**:
```
Code: 400 — cannot satisfy request, as TTL would result in notAfter 2027-02-23T12:51
that is beyond the expiration of the CA certificate at 2027-02-23T11:05
```

**Root Cause**: The Certificate requested `duration: 8760h` (exactly 1 year). The imported CA (`Airgap Local CA`) was generated in Feb 2026 with 1-year validity → expires Feb 23, 2027 at 11:05 UTC. The requested cert would expire ~1h46m later.

**Fix**: Reduce Certificate duration to 8700h (~362 days, well within the CA lifetime):
```yaml
# 04-airgap-certificate.yaml
duration: 8700h    # ~362 days (< CA lifetime)
renewBefore: 720h  # Renew 30 days before expiry
```

Also removed the SAN `traefik.traefik.svc.cluster.local` — this internal FQDN is not in the `airgap.local` domain and was rejected by the PKI role.

---

### Problem 11 — cert-manager CRDs not installed by ArgoCD

**Symptom**: ArgoCD synced cert-manager but `Certificate`, `ClusterIssuer` CRDs were missing.

**Root Cause**: With `ServerSideApply=true`, ArgoCD sometimes doesn't install CRDs correctly on first sync when the chart is large.

**Fix**: Apply CRDs manually:
```bash
helm template cert-manager 03-airgap-zone/manifests/cert-manager-helm/ \
  -f 03-airgap-zone/manifests/cert-manager-helm/values.yaml \
  -f 03-airgap-zone/manifests/cert-manager-helm/values-airgap-override.yaml \
  -n cert-manager \
  --include-crds \
  | kubectl apply --server-side -f -
```

---

### Problem 12 — ArgoCD OutOfSync: `persistentVolumeClaimRetentionPolicy: {}`

**Symptom**: Vault ArgoCD Application perpetually OutOfSync with diff:
```
...
persistentVolumeClaimRetentionPolicy:
+  whenDeleted: Retain
+  whenScaled: Retain
```

**Root Cause**: `persistentVolumeClaimRetentionPolicy: {}` is an empty map — in Go templates it is falsy, so Helm doesn't render the field. K3s then defaults it to `{whenDeleted: Retain, whenScaled: Retain}`, creating a permanent drift.

**Fix**: Set explicit values in `values-airgap-override.yaml` (inside `server.statefulSet`):
```yaml
server:
  statefulSet:
    persistentVolumeClaimRetentionPolicy:
      whenDeleted: Retain
      whenScaled: Retain
```

---

### Problem 13 — ArgoCD OutOfSync: StatefulSet `volumeClaimTemplates` immutable fields

**Symptom**: ArgoCD OutOfSync, diff shows K3s adding `apiVersion: v1`, `kind: PersistentVolumeClaim`, `status: {}` to volumeClaimTemplates items. ArgoCD cannot fix these — they are immutable after StatefulSet creation.

**Root Cause**: When K3s creates the StatefulSet, it annotates each `volumeClaimTemplates` item with `apiVersion` and `kind` (making it a full object reference). Helm doesn't render these fields. The diff is permanent and unresolvable by ArgoCD.

**Fix**: Add `ignoreDifferences` in `13-application-vault.yaml`:
```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    name: vault
    jqPathExpressions:
      - '.spec.volumeClaimTemplates[]?.apiVersion'
      - '.spec.volumeClaimTemplates[]?.kind'
      - '.spec.volumeClaimTemplates[]?.status'
```

---

### Problem 14 — cert-manager startupapicheck: wrong image (quay.io) + NetworkPolicy timeout

**Symptom**: Two issues in sequence:

1. `startupapicheck` pod uses `quay.io/jetstack/cert-manager-startupapicheck:v1.17.1` (not the airgap registry) → `ImagePullBackOff` in airgap cluster.

2. After fixing the image: pod exits with code 124 (timeout) → `CrashLoopBackOff`. The `check api` command timed out after 5m.

**Root Cause**:

1. The ArgoCD Application only had `values.yaml` in `helm.valueFiles`, not `values-airgap-override.yaml`. The image override for `startupapicheck` was in the override file.

2. `startupapicheck` is a Helm post-install hook. It runs `cmctl check api`. With `default-deny-all` NetworkPolicy in `cert-manager` namespace, the pod couldn't reach the API server (ports 443/6443) → timeout.

**Fix**:

1. Add both valueFiles to cert-manager ArgoCD Application:
```yaml
helm:
  valueFiles:
    - values.yaml
    - values-airgap-override.yaml
```

2. Add NetworkPolicy for startupapicheck in `17-allow-cert-manager.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cert-manager-startupapicheck-egress
  namespace: cert-manager
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: startupapicheck
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 6443
```

**Note**: ArgoCD waits for all Helm hooks to complete during sync. If the hook is stuck (Terminating with `argocd.argoproj.io/hook-finalizer`), remove the finalizer manually:
```bash
kubectl patch job cert-manager-startupapicheck -n cert-manager \
  -p '{"metadata":{"finalizers":null}}'
```

---

### Problem 15 — vault.airgap.local: Bad Gateway (port 8200 missing from Traefik egress)

**Symptom**: `https://vault.airgap.local` returns 502 Bad Gateway. Traefik logs show `dial tcp: connection refused`.

**Root Cause**: `traefik-egress` NetworkPolicy in `11-allow-traefik.yaml` listed allowed backend ports (3000, 8080, 9090, 9093, 80) but did not include port 8200 (Vault UI).

**Fix**: Add port 8200 to `traefik-egress` NetworkPolicy:
```yaml
egress:
  - to:
      - namespaceSelector: {}
    ports:
      - protocol: TCP
        port: 8200  # Vault UI ← added
```

---

### Problem 16 — Vault UI returns 404 (ui = true missing from HCL config)

**Symptom**: After `vault.airgap.local` Bad Gateway was fixed, the UI returned 404 for all paths.

**Root Cause**: `ui.enabled: true` in Helm `values.yaml` only controls whether the K8s `Service` named `vault-ui` is created. It does NOT enable the actual Vault Web UI server. The Vault HCL config must contain `ui = true` for Vault to serve the web interface.

**Fix**: Add `ui = true` to the HCL config block in `values-airgap-override.yaml`:
```hcl
config: |
  cluster_name = "lumen-vault"
  storage "raft" {
    path = "/vault/data"
  }
  listener "tcp" {
    address         = "[::]:8200"
    cluster_address = "[::]:8201"
    tls_disable     = true
  }
  service_registration "kubernetes" {}
  ui = true
  disable_mlock = true
```

**Important**: Vault uses `updateStrategy: OnDelete` — pods must be **deleted manually** to pick up the ConfigMap change. ArgoCD selfHeal recreates them immediately (sealed). Unseal each pod after restart.

---

### Problem 17 — Full Vault reinit required (unseal keys lost)

**Symptom**: vault-2 pod restarted and was sealed. Unseal keys were not saved from the initial `vault operator init` run.

**Decision**: Full reinit (delete all pods + PVCs) to start fresh.

**Procedure**:
```bash
# Scale down to 0 (ArgoCD selfHeals immediately to 3, but with fresh PVCs)
kubectl scale statefulset vault -n vault --replicas=0
kubectl delete pvc -n vault --all

# Wait for new pods to be Running (Sealed, Initialized: false)
kubectl exec -n vault vault-0 -- vault status | grep Initialized
# → Initialized: false

# Init (ONE TIME — save the output immediately!)
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-keys.json

# ⚠️ vault-keys.json = your master key. Never commit to git. Keep it safe.

# Unseal all 3 pods (3 keys needed out of 5)
for pod in vault-0 vault-1 vault-2; do
  for i in 0 1 2; do
    key=$(python3 -c "import json; d=json.load(open('vault-keys.json')); print(d['unseal_keys_b64'][$i])")
    kubectl exec -n vault $pod -- vault operator unseal "$key"
  done
done
```

---

### Problem 18 — Vault PKI CA: cannot import (no private key available)

**Symptom**: After full reinit, tried to import existing `airgap-ca.crt` into Vault PKI via `vault write pki/config/ca pem_bundle=...`. Vault requires the CA bundle to include the private key.

**Root Cause**: The original CA private key only existed inside the old cluster (in a K8s Secret that was deleted along with the PVCs). The CA cert file (`03-airgap-zone/airgap-ca.crt`) contains only the public certificate.

**Decision**: Generate a new CA entirely inside Vault PKI.

**Procedure**:
```bash
export VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('vault-keys.json'))['root_token'])")

# 1. Enable PKI mount
kubectl exec -n vault vault-0 -- sh -c "
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN \
vault secrets enable pki"

# 2. Tune max-lease-ttl BEFORE generating CA (critical! default=30d cap)
kubectl exec -n vault vault-0 -- sh -c "
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN \
vault secrets tune -max-lease-ttl=87600h pki"

# 3. Generate root CA (10 years)
kubectl exec -n vault vault-0 -- sh -c "
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN \
vault write pki/root/generate/internal \
  common_name='Airgap Local CA' \
  ttl=87600h \
  key_type=rsa \
  key_bits=4096" | grep certificate

# 4. Export new CA cert
kubectl exec -n vault vault-0 -- sh -c "
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN \
vault read -field=certificate pki/cert/ca" > /tmp/new-airgap-ca.crt

# 5. Replace project CA file
cp /tmp/new-airgap-ca.crt 03-airgap-zone/airgap-ca.crt

# 6. Import into macOS System keychain (required for browser trust)
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  03-airgap-zone/airgap-ca.crt
```

**Important**: After generating a new CA:
1. `airgap-ca.crt` must be updated in the git repo
2. All nodes need the new CA (for inter-service TLS verification if any)
3. The old `airgap-tls` Secret is now signed by the old (untrusted) CA — force-renew it:
   ```bash
   kubectl delete certificate airgap-tls -n traefik
   kubectl apply -f 03-airgap-zone/manifests/vault/04-airgap-certificate.yaml
   ```
4. Copy renewed `airgap-tls` to other namespaces:
   ```bash
   for NS in vault monitoring argocd; do
     kubectl get secret airgap-tls -n traefik -o json | python3 -c "
   import json,sys; d=json.load(sys.stdin); d['metadata']['namespace']='$NS'
   [d['metadata'].pop(k,None) for k in ['resourceVersion','uid','creationTimestamp','managedFields']]
   print(json.dumps(d))" | kubectl apply -f -
   done
   ```

---

### Problem 19 — vault-keys.json: what it is and why it matters

`vault-keys.json` is created during `vault operator init`. It contains:
- **5 Shamir unseal keys** (any 3 needed to unseal Vault after each restart)
- **Root token** (admin credential for Vault configuration)

Vault encrypts all data at rest. On pod restart, it starts **Sealed** — it cannot serve any requests until unsealed. The keys are **never stored in the cluster** (that would defeat the purpose).

**Unseal procedure after cluster restart**:
```bash
for pod in vault-0 vault-1 vault-2; do
  for i in 0 1 2; do
    key=$(python3 -c "import json; d=json.load(open('vault-keys.json')); print(d['unseal_keys_b64'][$i])")
    kubectl exec -n vault $pod -- vault operator unseal "$key"
  done
done
```

**Security rules**:
- NEVER commit `vault-keys.json` to git (it's in `.gitignore`)
- Store it securely (password manager, encrypted volume, or printed and stored physically)
- In production: use Vault Auto Unseal (AWS KMS, GCP KMS, etc.) to avoid manual unsealing

---

## Operational Reference

### Check Vault Status

```bash
kubectl exec -n vault vault-0 -- vault status
# Key fields:
# → Sealed: false         (must be false for Vault to work)
# → HA Enabled: true
# → HA Mode: active       (or standby for vault-1, vault-2)
# → Active Since: ...
```

### Check Vault HA Cluster Members

```bash
VAULT_TOKEN="<root-token>"
kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN vault operator raft list-peers"
# → shows vault-0 (leader), vault-1, vault-2 (followers)
```

### List Vault Secrets Engines

```bash
kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN vault secrets list"
# → lumen/   kv       (PostgreSQL creds)
# → pki/     pki      (Airgap CA)
```

### Read Vault PKI CA Expiry

```bash
kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN \
   vault read -format=json pki/cert/ca" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['certificate'])" \
  | openssl x509 -noout -dates
# → notAfter=Feb 23 11:05:51 2027 GMT
```

### Check cert-manager Certificate

```bash
kubectl get certificate -A
# → NAMESPACE  NAME        READY  SECRET      AGE
# → traefik    airgap-tls  True   airgap-tls  5m

# Detailed status
kubectl describe certificate airgap-tls -n traefik
# → Renewal Time: 2027-01-21 (30 days before expiry)
# → Not After: 2027-02-21
```

### Check ClusterIssuer

```bash
kubectl get clusterissuer vault-issuer
# → NAME          READY  AGE
# → vault-issuer  True   20m
```

### Verify cert-manager can reach Vault (debug)

```bash
# Test Kubernetes auth directly
TOKEN=$(kubectl get secret cert-manager-vault-token -n cert-manager \
  -o jsonpath='{.data.token}' | base64 -d)

kubectl exec -n vault vault-0 -- sh -c "
VAULT_ADDR=http://127.0.0.1:8200 vault write auth/kubernetes/login \
  role=cert-manager jwt='$TOKEN'
"
# → token: hvs.xxx  (success)
```

### Force Certificate Renewal (manual)

cert-manager renews automatically 30 days before expiry. For immediate renewal:
```bash
# Delete and recreate the Certificate resource
kubectl delete certificate airgap-tls -n traefik
kubectl apply -f 03-airgap-zone/manifests/vault/04-airgap-certificate.yaml

# Wait for issuance
kubectl get certificate -n traefik -w
```

### Sync airgap-tls to other namespaces

After cert-manager issues a new `airgap-tls` Secret in `traefik` namespace, copy it to other namespaces that need it (vault, monitoring, argocd...):
```bash
./03-airgap-zone/scripts/copy-tls-secrets.sh
```

Or manually:
```bash
for NS in vault monitoring argocd; do
  kubectl get secret airgap-tls -n traefik -o json \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['metadata']['namespace']='$NS'
for k in ['resourceVersion','uid','creationTimestamp','managedFields']:
    d['metadata'].pop(k,None)
print(json.dumps(d))
" | kubectl apply -f -
done
```

---

## Current State Summary

| Component | Status | Notes |
|-----------|--------|-------|
| Vault HA (3 pods Raft) | ✅ Running | vault-0/1/2 unsealed (1/1 Ready) |
| Vault Web UI | ✅ Accessible | `https://vault.airgap.local/ui/` |
| Vault Agent Injector | ✅ Running | MutatingWebhook active |
| cert-manager controller | ✅ Running | Synced/Healthy |
| cert-manager webhook | ✅ Running | port 10260 (K3s compatible) |
| cert-manager cainjector | ✅ Running | — |
| ClusterIssuer `vault-issuer` | ✅ Ready | → Vault PKI `pki/sign/airgap-role` |
| Certificate `airgap-tls` | ✅ Ready | signed by new Vault CA, expires Feb 2027 |
| Vault PKI CA | ✅ Active | generated inside Vault, TTL 10yr (→ Feb 2036) |
| Vault KV `lumen/db` | ✅ Seeded | username, password, dbname |
| Vault K8s auth `cert-manager` | ✅ Ready | SA: cert-manager, cert-manager-vault-auth |
| Vault K8s auth `lumen-api` | ✅ Ready | SA: default (ns: lumen) |
| IngressRoute `vault.airgap.local` | ✅ Active | HTTPS, no `-k` needed |
| macOS trust | ✅ Imported | new CA in System keychain |

### `vault-keys.json` (local file, never committed)

Located at project root. Contains unseal keys + root token. Needed after every pod restart.

### `/etc/hosts` entry

```
192.168.2.100 vault.airgap.local
```

---

## Key Files

| File | Purpose |
|------|---------|
| [03-airgap-zone/manifests/vault-helm/values.yaml](../03-airgap-zone/manifests/vault-helm/values.yaml) | Vault chart defaults (required for Helm rendering) |
| [03-airgap-zone/manifests/vault-helm/values-airgap-override.yaml](../03-airgap-zone/manifests/vault-helm/values-airgap-override.yaml) | Vault airgap overrides (images, HA Raft, no built-in NetworkPolicy) |
| [03-airgap-zone/manifests/cert-manager-helm/values.yaml](../03-airgap-zone/manifests/cert-manager-helm/values.yaml) | cert-manager chart defaults |
| [03-airgap-zone/manifests/cert-manager-helm/values-airgap-override.yaml](../03-airgap-zone/manifests/cert-manager-helm/values-airgap-override.yaml) | cert-manager airgap overrides (images, securePort 10260, CRDs) |
| [03-airgap-zone/manifests/vault/01-namespace.yaml](../03-airgap-zone/manifests/vault/01-namespace.yaml) | Vault namespace |
| [03-airgap-zone/manifests/vault/02-vault-init-job.yaml](../03-airgap-zone/manifests/vault/02-vault-init-job.yaml) | One-shot Job: init → unseal → configure engines (manual) |
| [03-airgap-zone/manifests/vault/03-vault-issuer.yaml](../03-airgap-zone/manifests/vault/03-vault-issuer.yaml) | ServiceAccount + Secret + ClusterIssuer for cert-manager → Vault PKI |
| [03-airgap-zone/manifests/vault/04-airgap-certificate.yaml](../03-airgap-zone/manifests/vault/04-airgap-certificate.yaml) | Certificate resource: `*.airgap.local`, 8700h, renew 30d before |
| [03-airgap-zone/manifests/network-policies/16-allow-vault.yaml](../03-airgap-zone/manifests/network-policies/16-allow-vault.yaml) | NetworkPolicies for vault namespace |
| [03-airgap-zone/manifests/network-policies/17-allow-cert-manager.yaml](../03-airgap-zone/manifests/network-policies/17-allow-cert-manager.yaml) | NetworkPolicies for cert-manager namespace |
| [03-airgap-zone/manifests/argocd/13-application-vault.yaml](../03-airgap-zone/manifests/argocd/13-application-vault.yaml) | ArgoCD Application — Vault (wave 7) |
| [03-airgap-zone/manifests/argocd/14-application-cert-manager.yaml](../03-airgap-zone/manifests/argocd/14-application-cert-manager.yaml) | ArgoCD Application — cert-manager (wave 8) |
| [03-airgap-zone/manifests/traefik/18-vault-ingressroute.yaml](../03-airgap-zone/manifests/traefik/18-vault-ingressroute.yaml) | IngressRoute vault.airgap.local → vault-ui:8200 |
| [01-connected-zone/scripts/13-pull-vault.sh](../01-connected-zone/scripts/13-pull-vault.sh) | Pull Vault images + Helm chart (connected zone) |
| [01-connected-zone/scripts/14-pull-cert-manager.sh](../01-connected-zone/scripts/14-pull-cert-manager.sh) | Pull cert-manager images + Helm chart (connected zone) |
| [02-transit-zone/push-vault.sh](../02-transit-zone/push-vault.sh) | Push Vault images to airgap registry |
| [02-transit-zone/push-cert-manager.sh](../02-transit-zone/push-cert-manager.sh) | Push cert-manager images to airgap registry |
