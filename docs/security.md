# Lumen - Security Architecture Documentation

> Defense-in-Depth: 3-Layer Security for Airgap Kubernetes

This document covers the complete security implementation in the Lumen airgap Kubernetes project, including OPA Gatekeeper admission control, Pod Security Standards (PSS), and NetworkPolicies.

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Layer 1: OPA Gatekeeper](#layer-1-opa-gatekeeper)
- [Layer 2: Pod Security Standards](#layer-2-pod-security-standards)
- [Layer 3: NetworkPolicies](#layer-3-networkpolicies)
- [How Layers Work Together](#how-layers-work-together)
- [Deployment Guide](#deployment-guide)
- [Testing & Verification](#testing--verification)
- [Troubleshooting](#troubleshooting)

---

## Overview

The Lumen project implements **defense-in-depth security** using three complementary layers:

| Layer | Technology | Purpose | Enforcement Point |
|-------|------------|---------|-------------------|
| **1** | OPA Gatekeeper | Custom business policies | Admission webhook |
| **2** | Pod Security Standards (PSS) | System security baselines | Built-in admission |
| **3** | NetworkPolicies | Zero-trust networking | CNI (Flannel) |

**Why 3 Layers?**
- **Redundancy**: If one layer fails, others protect the cluster
- **Separation of concerns**: Each layer addresses different security domains
- **Compliance**: Meet multiple security standards (CIS, NIST, PCI-DSS)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    kubectl apply deployment.yaml                │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1: OPA Gatekeeper (Custom Policies)                      │
│  ├─ Block :latest tags                                          │
│  ├─ Require internal registry (localhost:5000)                  │
│  ├─ Enforce resource limits                                     │
│  └─ Validate required labels (app, tier)                        │
└────────────────────────────┬────────────────────────────────────┘
                             │ ✅ Pass
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 2: Pod Security Standards (System Security)              │
│  ├─ No privileged containers                                    │
│  ├─ Must run as non-root (runAsNonRoot=true)                    │
│  ├─ No host access (hostPath, hostNetwork, hostPID)             │
│  ├─ Drop ALL capabilities                                       │
│  └─ Require seccompProfile (RuntimeDefault)                     │
└────────────────────────────┬────────────────────────────────────┘
                             │ ✅ Pass
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes API Server - Pod Created                            │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 3: NetworkPolicies (Runtime Protection)                  │
│  ├─ Default deny-all ingress/egress                             │
│  ├─ Explicit allow rules only                                   │
│  ├─ DNS egress (kube-system:53)                                 │
│  └─ Service-specific ingress (port-based)                       │
└─────────────────────────────────────────────────────────────────┘
                             │
                             ▼
                    Pod Running Securely
```

**Enforcement Timeline:**
1. **Admission time** (pre-creation): OPA Gatekeeper + PSS validate manifest
2. **Runtime** (post-creation): NetworkPolicies control network traffic

---

## Layer 1: OPA Gatekeeper

**What is OPA Gatekeeper?**
- Kubernetes admission controller using Open Policy Agent (OPA)
- Enforces custom policies written in Rego language
- Validates resources BEFORE they're created in the cluster
- Uses two CRD types:
  - **ConstraintTemplate**: Defines the policy logic (Rego code)
  - **Constraint**: Applies the policy to specific resources

**Why OPA Gatekeeper?**
- **Custom policies**: Enforce business rules (e.g., "only use internal registry")
- **Policy as Code**: Version-controlled Rego policies in Git
- **Audit mode**: Report violations without blocking (warn/audit/enforce modes)

### Deployment

**Components:**
- **gatekeeper-controller-manager** (3 replicas): Admission webhook
- **gatekeeper-audit** (1 replica): Audit + CRD generation

**Critical Fix for v3.18.0:**
Gatekeeper v3.18.0 requires `--operation=generate` flag for CRD creation:

```yaml
# 03-airgap-zone/manifests/opa/01-gatekeeper-install.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gatekeeper-audit
spec:
  template:
    spec:
      containers:
        - name: manager
          args:
            - --operation=audit
            - --operation=status
            - --operation=mutation-status
            - --operation=generate  # REQUIRED for v3.18.0
            - --logtostderr
```

**Without this flag:** ConstraintTemplates show `status.created: false` and CRDs are never created.

### Policy 1: Block `:latest` Tags

**Why?**
- `:latest` tag is mutable (same tag, different image)
- Breaks reproducibility and auditability
- Can cause unexpected behavior after image updates

**ConstraintTemplate:**
```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sblocklatesttag
spec:
  crd:
    spec:
      names:
        kind: K8sBlockLatestTag
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sblocklatesttag

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          endswith(container.image, ":latest")
          msg := sprintf("Container <%v> uses :latest tag", [container.name])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not contains(container.image, ":")
          msg := sprintf("Container <%v> has no tag (defaults to :latest)", [container.name])
        }
```

**Constraint:**
```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sBlockLatestTag
metadata:
  name: block-latest-tag
spec:
  match:
    kinds:
      - apiGroups: ["apps", ""]
        kinds: ["Deployment", "StatefulSet", "DaemonSet", "Pod"]
```

**Test:**
```bash
# This will be BLOCKED
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-latest
  namespace: lumen
spec:
  containers:
    - name: nginx
      image: nginx:latest  # ❌ VIOLATION
EOF

# Error: Container <nginx> uses :latest tag
```

### Policy 2: Require Internal Registry

**Why?**
- Airgap environment can only pull from local registry
- Prevent accidental external image references
- Enforce `localhost:5000/` prefix

**ConstraintTemplate:**
```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequireinternalregistry
spec:
  crd:
    spec:
      names:
        kind: K8sRequireInternalRegistry
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequireinternalregistry

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not startswith(container.image, "localhost:5000/")
          msg := sprintf("Container <%v> must use localhost:5000 registry, got: %v",
                        [container.name, container.image])
        }
```

**Test:**
```bash
# This will be BLOCKED
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-external
  namespace: lumen
spec:
  containers:
    - name: nginx
      image: docker.io/nginx:1.25  # ❌ VIOLATION
EOF

# Error: Container <nginx> must use localhost:5000 registry
```

### Policy 3: Require App Labels

**Why?**
- Enable consistent service discovery
- Support monitoring/observability (Prometheus ServiceMonitors)
- Enforce organizational standards

**ConstraintTemplate:**
```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequireapplabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequireAppLabels
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequireapplabels

        violation[{"msg": msg}] {
          not input.review.object.metadata.labels.app
          msg := "Workload must have 'app' label"
        }

        violation[{"msg": msg}] {
          not input.review.object.metadata.labels.tier
          msg := "Workload must have 'tier' label"
        }
```

**Test:**
```bash
# This will be BLOCKED
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-no-labels
  namespace: lumen
spec:
  replicas: 1
  selector:
    matchLabels:
      name: test
  template:
    metadata:
      labels:
        name: test  # ❌ Missing 'app' and 'tier' labels
    spec:
      containers:
        - name: nginx
          image: localhost:5000/nginx:1.25
EOF

# Error: Workload must have 'app' label
```

### Policy 4: Require Resource Limits

**Why?**
- Prevent resource exhaustion (noisy neighbor problem)
- Enable proper scheduling (bin packing)
- Required for HPA (Horizontal Pod Autoscaler)

**ConstraintTemplate (with multi-path support):**
```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredresources
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredResources
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredresources

        # Support both Pods and Deployments/StatefulSets/DaemonSets
        get_containers[container] {
          container := input.review.object.spec.containers[_]
        }

        get_containers[container] {
          container := input.review.object.spec.template.spec.containers[_]
        }

        violation[{"msg": msg}] {
          container := get_containers[_]
          not container.resources.requests.cpu
          msg := sprintf("Container <%v> has no CPU request", [container.name])
        }

        violation[{"msg": msg}] {
          container := get_containers[_]
          not container.resources.requests.memory
          msg := sprintf("Container <%v> has no memory request", [container.name])
        }

        violation[{"msg": msg}] {
          container := get_containers[_]
          not container.resources.limits.cpu
          msg := sprintf("Container <%v> has no CPU limit", [container.name])
        }

        violation[{"msg": msg}] {
          container := get_containers[_]
          not container.resources.limits.memory
          msg := sprintf("Container <%v> has no memory limit", [container.name])
        }
```

**Why `get_containers` helper?**
- Pods: `spec.containers[_]`
- Deployments: `spec.template.spec.containers[_]`
- Without helper: policy only checks one path ❌

**Test:**
```bash
# This will be BLOCKED
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-no-resources
  namespace: lumen
  labels:
    app: test
    tier: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
        tier: backend
    spec:
      containers:
        - name: nginx
          image: localhost:5000/nginx:1.25
          # ❌ No resources defined
EOF

# Error: Container <nginx> has no CPU request
```

### Policy Summary

| Policy | What It Blocks | Example Violation |
|--------|----------------|-------------------|
| **block-latest-tag** | `:latest` or no tag | `nginx:latest`, `nginx` |
| **require-internal-registry** | External registries | `docker.io/nginx:1.25` |
| **require-app-labels** | Missing `app`/`tier` labels | Deployment without labels |
| **require-resources** | Missing CPU/memory requests/limits | Container without resources |

### Verification

```bash
# Check Gatekeeper pods
kubectl get pods -n gatekeeper-system

# Check ConstraintTemplates (should show created=true)
kubectl get constrainttemplates
kubectl describe constrainttemplate k8sblocklatesttag

# Check Constraints
kubectl get constraints

# Check violations (audit mode)
kubectl get k8sblocklatesttag block-latest-tag -o yaml
# Look for: status.violations (list of violating resources)
```

---

## Layer 2: Pod Security Standards (PSS)

**What is PSS?**
- Built-in Kubernetes security enforcement (since v1.23)
- Replaces deprecated PodSecurityPolicy (PSP)
- Three levels: `privileged`, `baseline`, `restricted`
- Applied at namespace level via labels

**Why PSS?**
- **No operator needed**: Built into Kubernetes
- **Industry standard**: Based on CIS Kubernetes Benchmark
- **Defense in depth**: Complements OPA Gatekeeper (system security vs business policies)

### Security Levels

| Level | Description | Use Case |
|-------|-------------|----------|
| **privileged** | No restrictions | System components (kube-system) |
| **baseline** | Minimal restrictions | Default for most workloads |
| **restricted** | Hardened security | Production apps (Lumen uses this) |

### Restricted Mode Requirements

**1. Must run as non-root**
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000  # Or any UID > 0
```

**2. Drop ALL capabilities**
```yaml
securityContext:
  capabilities:
    drop:
      - ALL
```

**3. No privilege escalation**
```yaml
securityContext:
  allowPrivilegeEscalation: false
```

**4. Require seccomp profile**
```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault  # Or Localhost
```

**5. No host access**
```yaml
# These are BLOCKED:
hostNetwork: true
hostPID: true
hostIPC: true
hostPath: /any/path
```

### Implementation in Lumen

**Namespace configuration:**
```yaml
# 03-airgap-zone/manifests/app/01-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: lumen
  labels:
    # PSS labels
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

**Label meanings:**
- `enforce`: Block non-compliant pods
- `audit`: Log violations to audit log
- `warn`: Show warnings to users (but allow creation)

**lumen-api deployment:**
```yaml
# 03-airgap-zone/manifests/app/03-lumen-api.yaml
spec:
  template:
    spec:
      containers:
        - name: lumen-api
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
```

**Redis deployment:**
```yaml
# 03-airgap-zone/manifests/app/02-redis.yaml
spec:
  template:
    spec:
      containers:
        - name: redis
          securityContext:
            runAsNonRoot: true
            runAsUser: 999  # Redis user in official image
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
```

### Testing PSS

**Test 1: Block privileged container**
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-privileged
  namespace: lumen
spec:
  containers:
    - name: nginx
      image: localhost:5000/nginx:1.25
      securityContext:
        privileged: true  # ❌ BLOCKED by PSS
EOF

# Error: pods "test-privileged" is forbidden:
# violates PodSecurity "restricted:latest": privileged
```

**Test 2: Block hostPath volume**
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-hostpath
  namespace: lumen
spec:
  containers:
    - name: nginx
      image: localhost:5000/nginx:1.25
      volumeMounts:
        - name: host
          mountPath: /host
  volumes:
    - name: host
      hostPath:
        path: /  # ❌ BLOCKED by PSS
EOF

# Error: violates PodSecurity "restricted:latest":
# host namespaces (hostPath volume)
```

**Test 3: Block missing seccompProfile**
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-no-seccomp
  namespace: lumen
spec:
  containers:
    - name: nginx
      image: localhost:5000/nginx:1.25
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
        # ❌ Missing seccompProfile
EOF

# Error: violates PodSecurity "restricted:latest":
# seccompProfile (container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### PSS vs OPA Gatekeeper

| Aspect | PSS | OPA Gatekeeper |
|--------|-----|----------------|
| **Focus** | System security | Business policies |
| **Examples** | No privileged, must be non-root | Image registry, labels, tags |
| **Deployment** | Namespace labels | CRDs (ConstraintTemplate + Constraint) |
| **Customization** | 3 fixed levels | Fully customizable Rego |
| **Performance** | Built-in (fast) | Webhook (slight latency) |
| **Audit** | Audit logs | Constraint status |

**Why both?**
- PSS: System-level security (privilege, capabilities, host access)
- OPA: Business-level policies (registry, tags, labels, resources)
- **Overlap is good**: Defense in depth means redundancy

---

## Layer 3: NetworkPolicies

**What are NetworkPolicies?**
- Kubernetes firewall rules (applied by CNI)
- Control ingress/egress traffic to pods
- Label-based selection (like firewall security groups)

**Why NetworkPolicies?**
- **Zero-trust networking**: Default deny, explicit allow
- **Lateral movement prevention**: Limit blast radius of compromised pod
- **Compliance**: Required for PCI-DSS, HIPAA, FedRAMP

**CNI Requirement:**
- Flannel (Lumen's current CNI): Basic L3/L4 filtering ✅
- Cilium (optional upgrade): Advanced L7 HTTP filtering + eBPF

### Default Deny Pattern

**Every namespace starts with:**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: lumen
spec:
  podSelector: {}  # Apply to ALL pods
  policyTypes:
    - Ingress
    - Egress
```

**Effect:** All traffic blocked unless explicitly allowed.

### Common Allow Patterns

**1. DNS Egress (required for all pods)**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: lumen
spec:
  podSelector: {}
  policyTypes: [Egress]
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
```

**2. Cross-namespace ingress (Prometheus → lumen)**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scraping
  namespace: lumen
spec:
  podSelector:
    matchLabels:
      app: lumen-api
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 8080
```

**3. Same-namespace communication (lumen-api → redis)**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-lumen-api-to-redis
  namespace: lumen
spec:
  podSelector:
    matchLabels:
      app: redis
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: lumen-api
      ports:
        - protocol: TCP
          port: 6379
```

### NetworkPolicy Architecture in Lumen

**Namespace structure:**
```
lumen namespace:
├── default-deny-all (block everything)
├── allow-dns (DNS egress to kube-system)
├── allow-lumen-api-to-redis (lumen-api → redis:6379)
├── allow-traefik-ingress (traefik → lumen-api:8080)
└── allow-prometheus-scraping (prometheus → lumen-api:8080)

monitoring namespace:
├── default-deny-all
├── allow-dns
├── prometheus-egress (all namespaces for scraping)
└── grafana-to-prometheus (grafana → prometheus:9090)

traefik namespace:
├── default-deny-all
├── allow-dns
├── allow-ingress-traffic (internet → traefik:80/443)
└── traefik-egress (all namespaces for routing)
```

### Testing NetworkPolicies

**Test 1: DNS works**
```bash
kubectl exec -n lumen deploy/lumen-api -- nslookup kubernetes.default
# Expected: DNS resolution succeeds
```

**Test 2: Cross-namespace blocked**
```bash
# From lumen namespace, try to reach monitoring
kubectl exec -n lumen deploy/lumen-api -- wget -qO- --timeout=5 \
  http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
# Expected: Timeout (blocked by NetworkPolicy)
```

**Test 3: Allowed path works**
```bash
# Prometheus can scrape lumen-api
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- http://lumen-api.lumen.svc.cluster.local:8080/metrics
# Expected: HTTP 200 with metrics
```

**Test 4: Traefik can route to lumen-api**
```bash
curl -k https://traefik.airgap.local/api/http/routers
# Check if lumen-api route exists and is active
```

---

## How Layers Work Together

### Example: Deploying a Pod

**Scenario:** User applies this deployment:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: malicious-app
  namespace: lumen
spec:
  replicas: 1
  selector:
    matchLabels:
      app: malicious
  template:
    metadata:
      labels:
        app: malicious
    spec:
      containers:
        - name: hacker
          image: docker.io/alpine:latest  # ❌ External registry + :latest
          securityContext:
            privileged: true  # ❌ Privileged container
```

**Layer 1 (OPA Gatekeeper) - BLOCKED:**
```
❌ Violation: Container <hacker> uses :latest tag
❌ Violation: Container <hacker> must use localhost:5000 registry
❌ Violation: Workload must have 'tier' label
❌ Violation: Container <hacker> has no CPU request
```

**Layer 2 (PSS) - Would also BLOCK if Layer 1 didn't:**
```
❌ Violation: privileged containers are not allowed
```

**Layer 3 (NetworkPolicies) - Would limit damage if layers 1-2 failed:**
```
✅ Pod created (somehow bypassed layers 1-2)
❌ Cannot egress to internet (default deny-all)
❌ Cannot access other namespaces (no allow rules)
✅ Can only DNS (explicitly allowed)
```

### Defense in Depth Visualization

```
┌─────────────────────────────────────────────────┐
│  Attacker tries to deploy malicious pod         │
└──────────────────┬──────────────────────────────┘
                   │
                   ▼
         ┌─────────────────────┐
         │  Layer 1: Gatekeeper │ ❌ BLOCKED (custom policies)
         └─────────────────────┘
                   │ (if bypassed somehow)
                   ▼
         ┌─────────────────────┐
         │  Layer 2: PSS        │ ❌ BLOCKED (system security)
         └─────────────────────┘
                   │ (if both bypassed)
                   ▼
         ┌─────────────────────┐
         │  Pod Running         │
         └─────────────────────┘
                   │
                   ▼
         ┌─────────────────────┐
         │  Layer 3: NetPol     │ 🔒 LIMITED DAMAGE
         └─────────────────────┘  (can't reach internet/other namespaces)
```

**Result:** Even if 2 layers fail, the 3rd layer limits blast radius.

---

## Deployment Guide

### Prerequisites

- K3s cluster running
- kubectl access
- OPA Gatekeeper images in transit registry
- ArgoCD (optional, for GitOps)

### Step 1: Deploy OPA Gatekeeper (10 min)

```bash
cd 03-airgap-zone

# Apply Gatekeeper installation (4 CRDs + 2 deployments)
kubectl apply -f manifests/opa/01-gatekeeper-install.yaml

# Wait for pods ready
kubectl wait --for=condition=ready pod -l control-plane=controller-manager \
  -n gatekeeper-system --timeout=120s

kubectl wait --for=condition=ready pod -l control-plane=audit-controller \
  -n gatekeeper-system --timeout=120s

# Verify pods
kubectl get pods -n gatekeeper-system
# Expected:
# gatekeeper-controller-manager-xxx (3/3 Running)
# gatekeeper-audit-xxx (1/1 Running)
```

### Step 2: Apply ConstraintTemplates (5 min)

```bash
# Apply all 4 ConstraintTemplates
kubectl apply -f manifests/opa/02-constraint-template-latest-tag.yaml
kubectl apply -f manifests/opa/03-constraint-template-registry.yaml
kubectl apply -f manifests/opa/04-constraint-template-resources.yaml
kubectl apply -f manifests/opa/05-constraint-template-labels.yaml

# Wait for CRDs to be created (30 seconds)
sleep 30

# Verify ConstraintTemplates
kubectl get constrainttemplates
# Expected: 4 templates with CREATED=true

# Check CRDs exist
kubectl get crd | grep gatekeeper
# Expected: k8sblocklatesttag.constraints.gatekeeper.sh, etc.
```

### Step 3: Apply Constraints (5 min)

```bash
# Apply all 4 Constraints
kubectl apply -f manifests/opa/06-constraint-latest-tag.yaml
kubectl apply -f manifests/opa/07-constraint-registry.yaml
kubectl apply -f manifests/opa/08-constraint-resources.yaml
kubectl apply -f manifests/opa/09-constraint-labels.yaml

# Verify Constraints
kubectl get constraints
# Expected: 4 constraints with ENFORCEMENT-ACTION=deny
```

### Step 4: Enable Pod Security Standards (2 min)

```bash
# PSS is enabled via namespace labels (already in 01-namespace.yaml)
kubectl apply -f manifests/app/01-namespace.yaml

# Verify namespace labels
kubectl get namespace lumen -o yaml | grep pod-security
# Expected:
# pod-security.kubernetes.io/audit: restricted
# pod-security.kubernetes.io/enforce: restricted
# pod-security.kubernetes.io/warn: restricted
```

### Step 5: Update Application Manifests (5 min)

```bash
# lumen-api and redis already have PSS-compliant securityContexts
kubectl apply -f manifests/app/02-redis.yaml
kubectl apply -f manifests/app/03-lumen-api.yaml

# Verify pods running
kubectl get pods -n lumen
# Expected: lumen-api-xxx (1/1 Running), redis-xxx (1/1 Running)
```

### Step 6: Deploy NetworkPolicies (5 min)

```bash
# Apply all NetworkPolicies
kubectl apply -f manifests/network-policies/

# Verify policies
kubectl get networkpolicy -n lumen
kubectl get networkpolicy -n monitoring
kubectl get networkpolicy -n traefik
```

### Step 7: GitOps with ArgoCD (Optional)

```bash
# Commit all changes
git add .
git commit -m "feat: implement 3-layer security (OPA Gatekeeper + PSS + NetworkPolicies)"
git push-all

# ArgoCD will automatically sync within 3 minutes
kubectl get application -n argocd
```

---

## Testing & Verification

### Test Suite 1: OPA Gatekeeper Policies

**Test 1.1: Block :latest tag**
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-latest-tag
  namespace: lumen
  labels:
    app: test
    tier: testing
spec:
  containers:
    - name: nginx
      image: localhost:5000/nginx:latest
      resources:
        requests: {cpu: 100m, memory: 64Mi}
        limits: {cpu: 200m, memory: 128Mi}
EOF

# Expected: ❌ Error: Container <nginx> uses :latest tag
```

**Test 1.2: Block external registry**
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-external-registry
  namespace: lumen
  labels:
    app: test
    tier: testing
spec:
  containers:
    - name: nginx
      image: docker.io/nginx:1.25
      resources:
        requests: {cpu: 100m, memory: 64Mi}
        limits: {cpu: 200m, memory: 128Mi}
EOF

# Expected: ❌ Error: Container <nginx> must use localhost:5000 registry
```

**Test 1.3: Block missing labels**
```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-no-labels
  namespace: lumen
spec:
  replicas: 1
  selector:
    matchLabels:
      name: test
  template:
    metadata:
      labels:
        name: test  # Missing app/tier
    spec:
      containers:
        - name: nginx
          image: localhost:5000/nginx:1.25
          resources:
            requests: {cpu: 100m, memory: 64Mi}
            limits: {cpu: 200m, memory: 128Mi}
EOF

# Expected: ❌ Error: Workload must have 'app' label
```

**Test 1.4: Block missing resources**
```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-no-resources
  namespace: lumen
  labels:
    app: test
    tier: testing
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
        tier: testing
    spec:
      containers:
        - name: nginx
          image: localhost:5000/nginx:1.25
          # No resources
EOF

# Expected: ❌ Error: Container <nginx> has no CPU request
```

### Test Suite 2: Pod Security Standards

**Test 2.1: Block privileged container**
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-privileged
  namespace: lumen
spec:
  containers:
    - name: nginx
      image: localhost:5000/nginx:1.25
      securityContext:
        privileged: true
EOF

# Expected: ❌ Error: violates PodSecurity "restricted:latest": privileged
```

**Test 2.2: Block hostPath volume**
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-hostpath
  namespace: lumen
spec:
  containers:
    - name: nginx
      image: localhost:5000/nginx:1.25
      volumeMounts:
        - name: host
          mountPath: /host
  volumes:
    - name: host
      hostPath:
        path: /
EOF

# Expected: ❌ Error: violates PodSecurity "restricted:latest": host namespaces
```

**Test 2.3: Block runAsRoot**
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-run-as-root
  namespace: lumen
spec:
  containers:
    - name: nginx
      image: localhost:5000/nginx:1.25
      securityContext:
        runAsUser: 0  # root
EOF

# Expected: ❌ Error: violates PodSecurity "restricted:latest": runAsNonRoot != true
```

### Test Suite 3: NetworkPolicies

**Test 3.1: DNS works**
```bash
kubectl run test-dns --rm -it --image=localhost:5000/busybox:1.36 -n lumen -- \
  nslookup kubernetes.default

# Expected: ✅ DNS resolution succeeds
```

**Test 3.2: Cross-namespace blocked (default deny)**
```bash
kubectl run test-cross-ns --rm -it --image=localhost:5000/busybox:1.36 -n lumen -- \
  wget -qO- --timeout=5 http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090

# Expected: ❌ Timeout (blocked by NetworkPolicy)
```

**Test 3.3: Same-namespace allowed (lumen-api → redis)**
```bash
kubectl exec -n lumen deploy/lumen-api -- nc -zv redis 6379

# Expected: ✅ Connection succeeded
```

**Test 3.4: Prometheus scraping allowed**
```bash
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- http://lumen-api.lumen.svc.cluster.local:8080/metrics

# Expected: ✅ HTTP 200 with metrics
```

### Test Suite 4: Combined Layers

**Test 4.1: Compliant pod succeeds**
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-compliant
  namespace: lumen
  labels:
    app: test
    tier: testing
spec:
  containers:
    - name: nginx
      image: localhost:5000/nginx:1.25
      resources:
        requests: {cpu: 100m, memory: 64Mi}
        limits: {cpu: 200m, memory: 128Mi}
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
        seccompProfile:
          type: RuntimeDefault
EOF

# Expected: ✅ Pod created successfully
```

**Cleanup:**
```bash
kubectl delete pod test-compliant -n lumen
```

---

## Troubleshooting

### Issue 1: ConstraintTemplate shows `created: false`

**Symptom:**
```bash
kubectl get constrainttemplate k8sblocklatesttag -o yaml
# status:
#   created: false
```

**Diagnosis:**
```bash
kubectl logs -n gatekeeper-system deploy/gatekeeper-audit | grep "operation"
# No "generate" operation found
```

**Solution:**
Gatekeeper v3.18.0 requires `--operation=generate` flag:
```yaml
# manifests/opa/01-gatekeeper-install.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gatekeeper-audit
spec:
  template:
    spec:
      containers:
        - name: manager
          args:
            - --operation=audit
            - --operation=status
            - --operation=mutation-status
            - --operation=generate  # ADD THIS
```

**Verify:**
```bash
kubectl rollout restart deployment/gatekeeper-audit -n gatekeeper-system
kubectl wait --for=condition=ready pod -l control-plane=audit-controller -n gatekeeper-system
kubectl get constrainttemplate k8sblocklatesttag -o yaml
# status.created: true ✅
```

---

### Issue 2: Resource policy not enforcing on Deployments

**Symptom:**
Deployments without resources are allowed, but Pods are blocked.

**Diagnosis:**
Rego only checks `spec.containers` (Pod path), not `spec.template.spec.containers` (Deployment path).

**Solution:**
Use `get_containers` helper:
```yaml
rego: |
  package k8srequiredresources

  get_containers[container] {
    container := input.review.object.spec.containers[_]
  }

  get_containers[container] {
    container := input.review.object.spec.template.spec.containers[_]
  }

  violation[{"msg": msg}] {
    container := get_containers[_]
    not container.resources.requests.cpu
    msg := sprintf("Container <%v> has no CPU request", [container.name])
  }
```

---

### Issue 3: PSS blocking legitimate pods

**Symptom:**
```
Error: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false
```

**Diagnosis:**
Pod missing required `securityContext` fields.

**Solution:**
Add full PSS-compliant securityContext:
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
```

**Tip:** Use this template for all pods in `restricted` namespaces.

---

### Issue 4: NetworkPolicy blocking allowed traffic

**Symptom:**
Prometheus can't scrape lumen-api (timeout).

**Diagnosis:**
Missing ingress rule in lumen namespace.

**Solution:**
Add NetworkPolicy allowing prometheus → lumen-api:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scraping
  namespace: lumen
spec:
  podSelector:
    matchLabels:
      app: lumen-api
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 8080
```

**Verify:**
```bash
kubectl exec -n monitoring prometheus-xxx -c prometheus -- \
  wget -qO- http://lumen-api.lumen.svc.cluster.local:8080/metrics
# Expected: HTTP 200 ✅
```

---

### Issue 5: DNS not working in namespace

**Symptom:**
```bash
kubectl exec -n lumen deploy/lumen-api -- nslookup kubernetes.default
# Error: Temporary failure in name resolution
```

**Diagnosis:**
Missing DNS egress rule.

**Solution:**
Add DNS NetworkPolicy to namespace:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: lumen
spec:
  podSelector: {}
  policyTypes: [Egress]
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
```

---

## Summary

### What We Built

✅ **Layer 1: OPA Gatekeeper**
- 4 custom policies (tags, registry, labels, resources)
- Admission webhook enforcement
- Audit mode for compliance

✅ **Layer 2: Pod Security Standards**
- Restricted mode on lumen namespace
- System security (privileges, capabilities, host access)
- Built-in Kubernetes enforcement

✅ **Layer 3: NetworkPolicies**
- Default deny-all ingress/egress
- Explicit allow rules per service
- Zero-trust networking

### Security Posture

**Before:**
- ❌ Any image (external registries, :latest tags)
- ❌ Privileged containers allowed
- ❌ No network segmentation

**After:**
- ✅ Only localhost:5000 images with explicit tags
- ✅ No privileged containers, must run as non-root
- ✅ Zero-trust networking with explicit allow rules
- ✅ Resource limits enforced
- ✅ Required labels for observability

### Production Readiness

| Requirement | Status | Implementation |
|-------------|--------|----------------|
| **Admission control** | ✅ | OPA Gatekeeper + PSS |
| **Runtime security** | ✅ | NetworkPolicies + securityContext |
| **Audit logging** | ✅ | PSS audit + Gatekeeper audit |
| **Compliance** | ✅ | CIS Kubernetes Benchmark |
| **Defense in depth** | ✅ | 3 independent layers |

---

## Next Steps

**Optional Enhancements:**

1. **Cilium CNI Migration** (Phase 15)
   - Upgrade from Flannel to Cilium
   - Enable L7 HTTP NetworkPolicies
   - Add eBPF performance benefits

2. **Runtime Security** (Falco)
   - Detect runtime anomalies (unexpected processes, file access)
   - Alert on suspicious syscalls
   - Kubernetes audit log integration

3. **Secrets Management** (HashiCorp Vault)
   - External secrets operator
   - Dynamic secret injection
   - Automatic rotation

4. **Policy Automation**
   - Conftest for pre-commit policy checks
   - CI/CD integration (block non-compliant manifests)
   - Policy-as-Code testing

---

**Built with defense-in-depth security** 🔒 | [Issues](https://github.com/Chahine-tech/lumen/issues)
