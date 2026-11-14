# Lumen - Security Architecture Documentation

> Defense-in-Depth: 5-Layer Security for Airgap Kubernetes

This document covers the complete security implementation in the Lumen airgap Kubernetes project, including Kyverno admission policies (with Cosign signature verification), Pod Security Standards (PSS), NetworkPolicies and Falco runtime security.

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Layer 1: Kyverno admission policies](#layer-1-kyverno-admission-policies)
- [Layer 2: Pod Security Standards](#layer-2-pod-security-standards)
- [Layer 3: NetworkPolicies](#layer-3-networkpolicies)
- [Layer 4: Falco Runtime Security](#layer-4-falco-runtime-security)
- [How Layers Work Together](#how-layers-work-together)
- [Deployment Guide](#deployment-guide)
- [Testing & Verification](#testing--verification)
- [Troubleshooting](#troubleshooting)

---

## Overview

The Lumen project implements **defense-in-depth security** using three complementary layers:

| Layer | Technology | Purpose | Enforcement Point |
|-------|------------|---------|-------------------|
| **1** | Kyverno | Registry, tags, labels, resources, image signatures | Admission webhook |
| **2** | Pod Security Standards (PSS) | System security baselines | Built-in admission |
| **3** | NetworkPolicies | Zero-trust networking | CNI (Flannel) |
| **4** | Falco | Runtime threat detection | Kernel syscalls (eBPF) |

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
│  Layer 1: Kyverno (Admission Policies)                          │
│  ├─ Block :latest tags                                          │
│  ├─ Require internal registry (192.168.2.2:5000)                │
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
1. **Admission time** (pre-creation): Kyverno + PSS validate manifest
2. **Runtime** (post-creation): NetworkPolicies control network traffic

---

## Layer 1: Kyverno admission policies

Kyverno 1.18.1 (admission controller only, `manifests/kyverno-helm/`) runs
the policies in `manifests/kyverno-policies/`, synced by the ArgoCD
Application `kyverno-policies`.

| Policy | File | Kind | Scope | What it rejects |
|---|---|---|---|---|
| `verify-lumen-api-signature` | `01-verify-lumen-api-signature.yaml` | ClusterPolicy (verifyImages) | Pods in `lumen`, image `lumen-api` | lumen-api images without a valid Cosign signature |
| `lumen-require-internal-registry` | `02-require-internal-registry.yaml` | ValidatingPolicy | Pods in `lumen` and `default` (+ autogen) | images outside `192.168.2.2:5000/`, containers and init containers |
| `lumen-block-latest-tag` | `03-block-latest-tag.yaml` | ValidatingPolicy | Pods in `lumen` (+ autogen) | `:latest`, or no tag; a digest is accepted |
| `lumen-require-app-labels` | `04-require-app-labels.yaml` | ValidatingPolicy | Deployments, StatefulSets, DaemonSets in `lumen` | missing `app` or `tier` label |
| `lumen-require-resources` | `05-require-resources.yaml` | ValidatingPolicy | Deployments, StatefulSets, DaemonSets in `lumen` | a container without CPU and memory requests and limits |

"autogen" means the Pod rule is also applied to Deployments, StatefulSets and
DaemonSets, so a bad image is rejected when the workload is created (an
ArgoCD sync error) instead of later, silently, by the ReplicaSet controller.
Argo Rollouts (lumen-api) are not matched by the workload rules; their Pods
are checked by the Pod rules.

### Why ValidatingPolicy

The four `lumen-*` policies replaced the OPA Gatekeeper constraints of the same
names in November 2026 (Gatekeeper 3.18 was end of life, and no Gatekeeper
release is tested on Kubernetes 1.34, see
[k3s-upgrade-path.md](runbooks/k3s-upgrade-path.md)). They use
`ValidatingPolicy` (`policies.kyverno.io/v1`, CEL) because `ClusterPolicy` is
deprecated since Kyverno 1.18. The signature policy is still a
`ClusterPolicy` and should move to `ImageValidatingPolicy`.

Two defects of the Gatekeeper version were fixed on the way:
- the latest-tag rule read `spec.containers` on Deployments, StatefulSets and
  DaemonSets, where containers live under `spec.template.spec`: only Pods were
  really checked;
- "no tag" was detected as "no `:` in the image", but `192.168.2.2:5000`
  contains one: `192.168.2.2:5000/redis` (implicit latest) was accepted.

### Design choices

- **`failurePolicy: Ignore`** on the four `lumen-*` policies, as Gatekeeper
  had: with a single Kyverno replica, `Fail` would block every Pod in `lumen`
  whenever Kyverno is down. The cost: while Kyverno is down nothing is checked
  (verified on k3d). The signature policy keeps `Fail`.
- **Namespace scope through `matchConditions` on `request.namespace`, not
  `namespaceSelector`**, because of two Kyverno 1.18.1 behaviors seen on the
  k3d test: ValidatingPolicies sharing a webhook ended up with a single
  namespace selector (Pods in `default` were never sent to Kyverno), and
  autogen is skipped as soon as a `namespaceSelector` is set (`CanAutoGen`,
  `pkg/cel/autogen/support.go`). With `matchConditions`, Kyverno creates one
  webhook per policy.

### Verification

```bash
# Policies compiled and ready
kubectl get validatingpolicies.policies.kyverno.io \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditionStatus.ready'
# Autogen generated for the two Pod policies (expect a non-empty map)
kubectl get validatingpolicy lumen-require-internal-registry -o jsonpath='{.status.autogen}'
# Admission test matrix (server-side dry run, creates nothing)
make test-policies
```

`make test-policies` runs `03-airgap-zone/tests/kyverno/admission-tests.sh`
against the current kubectl context: 23 cases, each with its expected verdict
(allow or deny), including the out-of-scope namespaces.


## Layer 2: Pod Security Standards (PSS)

**What is PSS?**
- Built-in Kubernetes security enforcement (since v1.23)
- Replaces deprecated PodSecurityPolicy (PSP)
- Three levels: `privileged`, `baseline`, `restricted`
- Applied at namespace level via labels

**Why PSS?**
- **No operator needed**: Built into Kubernetes
- **Industry standard**: Based on CIS Kubernetes Benchmark
- **Defense in depth**: Complements Kyverno (system security vs project policies)

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

### PSS vs Kyverno

| Aspect | PSS | Kyverno |
|--------|-----|---------|
| **Focus** | System security | Project policies |
| **Examples** | No privileged, must be non-root | Image registry, labels, tags, signatures |
| **Deployment** | Namespace labels | Policy resources (ValidatingPolicy, ClusterPolicy) |
| **Customization** | 3 fixed levels | CEL expressions |
| **Performance** | Built-in (fast) | Webhook (slight latency) |
| **Audit** | Audit logs | Admission denials (reports controller disabled) |

**Why both?**
- PSS: System-level security (privilege, capabilities, host access)
- Kyverno: Project-level policies (registry, tags, labels, resources, signatures)
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
├── allow-api-ingress (traefik pods → lumen-api:8080, nothing else)
└── allow-prometheus-scraping (prometheus pods → lumen-api:8080, 9090)

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
  wget -qO- http://lumen-api.lumen.svc.cluster.local:9090/metrics  # 8080 up to v1.6.0
# Expected: HTTP 200 with metrics
```

**Test 4: Traefik can route to lumen-api**
```bash
curl -k https://traefik.airgap.local/api/http/routers
# Check if lumen-api route exists and is active
```

---

## Layer 4: Falco Runtime Security

**What is Falco?**
- Runtime security tool that monitors kernel syscalls via eBPF
- Detects suspicious behavior **after** a pod is running (OPA/PSS guard admission; Falco guards runtime)
- Sends alerts as JSON to stdout → collected by Alloy → stored in Loki → visible in Grafana

**Why Falco completes the stack?**
- Kyverno + PSS prevent bad *deployments*; Falco detects bad *behavior at runtime*
- Example: a container that passes all admission checks but then opens a shell, reads `/etc/shadow`, or makes an unexpected network connection

### Driver: modern_ebpf

Falco 0.43.0 ships three driver options. We use `modern_ebpf`:

| Driver | Airgap | ARM64 | Kernel req | Notes |
|--------|--------|-------|------------|-------|
| `kmod` | ❌ | ❌ | any | Downloads + compiles kernel module |
| `ebpf` | ❌ | ✅ | ≥4.14 | Downloads pre-compiled probe |
| `modern_ebpf` | ✅ | ✅ | ≥5.8 | CO-RE, self-contained in binary |

`modern_ebpf` is the only option that works airgap out-of-the-box (no runtime downloads).

### Architecture

```
Falco DaemonSet (1 pod / node)
  ├── modern_ebpf probe (CO-RE, kernel ≥5.8)
  ├── container plugin (libcontainer.so v0.6.1, bundled in image)
  │     └── CRI socket: /host/run/k3s/containerd/containerd.sock
  │         → enriches: container.id, container.name, container.image.repository
  └── k8smeta plugin (libk8smeta.so v0.4.1, copied by init container)
        └── gRPC → k8s-metacollector:45000
            → enriches: k8s.pod.name, k8s.ns.name, k8s.deployment.name

k8s-metacollector Deployment (1 replica)
  └── watches K8s API for pod/namespace events
      └── streams metadata to all Falco pods via gRPC

Falco stdout (JSON)
  └── Alloy (scrapes falco pod logs)
      └── Loki
          └── Grafana → query: {namespace="falco"} | json
```

### Plugin: container (metadata enrichment)

**What it provides:** `container.id`, `container.name`, `container.image.repository`, `container.start_ts`

**Why it matters:** Without this plugin, Falco can't tell which container triggered a syscall. Rules with condition `container` (macro = `container.id != host`) would never fire.

### Plugin: k8smeta (Kubernetes metadata enrichment)

**What it provides:** `k8s.pod.name`, `k8s.ns.name`, `k8s.deployment.name`, `k8s.node.name`

**Why it's needed:** Falco 0.43.0 removed the internal Kubernetes client. K8s metadata is now provided by the k8smeta plugin, which connects to k8s-metacollector via gRPC.

**Components:**
- `libk8smeta.so` v0.4.1 — the Falco plugin (must match event schema version ≥4.0.0 for Falco 0.43.0)
- `k8s-metacollector` v0.1.1 — a Deployment that watches the K8s API and streams pod metadata

**Custom image for airgap:** `libk8smeta.so` is distributed as an OCI artifact. In airgap we wrap it:
```bash
oras pull ghcr.io/falcosecurity/plugins/plugin/k8smeta:0.4.1 --platform linux/arm64
# Extract libk8smeta.so from the tar, build image based on alpine:3.19
docker build -t 192.168.2.2:5000/falcosecurity/k8smeta-plugin:0.4.1 .
```

---

### Deployment: Full Debugging Journey

Getting Falco to work correctly on K3s ARM64 in airgap required solving 9 distinct problems. Documented here to avoid repeating them.

---

#### Problem 1 — `container.id = <NA>` (wrong CRI engine)

**Symptom:** All Falco events show `container.id=<NA>`. The rule condition `container` (macro = `container.id != host`) never fires.

**Root cause:** K3s uses cgroup path format `cri-containerd-HASH.scope`. Only the `cri` engine can parse this. The `containerd` engine (native gRPC) cannot match K3s cgroup paths, resulting in all containers appearing as "host".

**Fix:** Use CRI engine via the chart's `collectors` mechanism:
```yaml
collectors:
  containerd:
    enabled: true
    socket: /run/k3s/containerd/containerd.sock
```
This auto-mounts `/run/k3s/containerd/` → `/host/run/k3s/containerd/` and sets `container_engines.cri.enabled: true` in `falco.yaml`.

---

#### Problem 2 — `k8s.pod.name = <NA>` (k8smeta plugin missing)

**Symptom:** Even after fixing `container.id`, `k8s.pod.name`, `k8s.ns.name` etc. are still `<NA>`.

**Root cause:** Falco 0.43.0 removed the internal Kubernetes client that previously populated these fields. You must now deploy the k8smeta plugin + k8s-metacollector explicitly.

**Fix:**
1. Build custom image with `libk8smeta.so` v0.4.1 (see above)
2. Deploy `k8s-metacollector` v0.1.1 as a separate Deployment
3. Configure k8smeta plugin to connect to it via gRPC

---

#### Problem 3 — k8smeta plugin version incompatibility

**Symptom:**
```
plugin k8smeta required event schema version '3.0.0' not compatible
with the event schema version in use '4.1.0'
```

**Root cause:** k8smeta v0.2.1 requires event schema 3.0.0. Falco 0.43.0 uses schema 4.1.0. They are incompatible.

**Fix:** Upgrade to k8smeta v0.4.1 (requires schema 4.0.0 — compatible with 4.1.0 via minor-version rule):
```bash
oras pull ghcr.io/falcosecurity/plugins/plugin/k8smeta:0.4.1 --platform linux/arm64
```

---

#### Problem 4 — k8s-metacollector CrashLoopBackOff (wrong base image + missing subcommand)

**Symptom:** `exec: "cp": executable file not found in $PATH` on the init container, then the metacollector itself keeps crashing.

**Two root causes:**
- Init container image was built `FROM scratch` — no shell, no `cp`. Rebuild `FROM alpine:3.19`.
- Metacollector binary requires `run` subcommand: `args: ["run"]`

---

#### Problem 5 — k8s-metacollector RBAC missing endpoints/endpointslices

**Symptom:**
```
endpointslices.discovery.k8s.io is forbidden: User "system:serviceaccount:falco:k8s-metacollector" cannot list resource
endpoints is forbidden
```

**Fix:** Add to ClusterRole:
```yaml
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "list", "watch"]
```

---

#### Problem 6 — k8s-metacollector health probe 404 (wrong port)

**Symptom:** `Liveness probe failed: HTTP probe failed with statuscode: 404`

**Root cause:** Port 8080 = metrics, port 8081 = health probes. The initial config probed 8080 for `/healthz`.

**Evidence from logs:**
```
"starting server","kind":"health probe","addr":"[::]:8081"
```

**Fix:**
```yaml
ports:
  - name: metrics
    containerPort: 8080
  - name: healthz
    containerPort: 8081   # was 8080
livenessProbe:
  httpGet:
    path: /healthz
    port: healthz         # resolves to 8081
```

---

#### Problem 7 — NetworkPolicies not applied (ArgoCD Helm mode)

**Symptom:** Falco pods can't reach k8s-metacollector. NetworkPolicies were defined but not deployed.

**Root cause:** The `19-allow-falco.yaml` file was in the `falco-helm/` directory root. ArgoCD in Helm mode **only processes files inside `templates/`**. Files at the chart root are ignored.

**Fix:** Move/copy NetworkPolicies into `templates/network-policies.yaml`.

---

#### Problem 8 — `collectors.enabled: false` silently disables container plugin

**Symptom:** Falco starts, loads plugins (`container@0.6.1` and `k8smeta@0.4.1`), but `falcosecurity_plugins_container_n_containers_total = 0`. Container plugin detects nothing.

**Root cause:** `collectors.enabled: false` causes the Helm chart to generate `container_engines.cri.enabled: false` in `falco.yaml`. The plugin is loaded but never connects to any socket.

**Debugging path:**
```bash
# Metric revealed the problem:
kubectl exec -n falco <pod> -- curl -s http://localhost:8765/metrics | grep container_n_containers
# → falcosecurity_plugins_container_n_containers_total 0

# ConfigMap confirmed it:
kubectl get configmap falco -n falco -o jsonpath='{.data.falco\.yaml}' | grep -A5 container_engines
# → cri.enabled: false  ← root cause
```

**Fix:** Use `collectors.containerd` instead of disabling collectors entirely:
```yaml
collectors:
  enabled: true
  docker:
    enabled: false
  containerd:
    enabled: true
    socket: /run/k3s/containerd/containerd.sock   # K3s-specific path
  crio:
    enabled: false
```

---

#### Problem 9 — `Cannot load plugin 'container': plugin config not found`

**Symptom:** Falco crashes immediately after the collectors fix with:
```
Error: Cannot load plugin 'container': plugin config not found for given name
```

**Root cause:** The Falco 0.43.0 image ships a builtin `config.d/falco.container_plugin.yaml` containing only:
```yaml
load_plugins: [container]
```
This fires `load_plugins: [container]` but there is no `plugins: [{name: container}]` entry in `falco.yaml` to resolve the name. When `collectors.enabled: false` was set, our custom override ConfigMap provided the plugin registration. Removing that ConfigMap broke the resolution.

**The trap:** If you add `plugins: [{name: container}]` AND also have `load_plugins: [container]` in the values, Falco crashes with:
```
Runtime error: cannot register plugin: found another plugin with name container. Aborting.
```
Because the image's builtin config.d file also loads it → double registration.

**Final fix:** Register the plugin in values (so the name resolves), but do NOT add it to `load_plugins` (the builtin config.d handles that), and use `init_config: ~` (null, not `{}` — empty object fails JSON schema validation):
```yaml
falco:
  plugins:
    - name: container
      library_path: libcontainer.so
      init_config: ~          # null, not {} — schema requires null or structured object
  load_plugins: []            # image's config.d already does load_plugins: [container]
```

---

#### Problem 10 — `container.id` and `k8s.pod.name` absent from `output_fields`

**Symptom:** Everything works (113 containers detected, gRPC connected), but the JSON events have no `container.id` or `k8s.pod.name` in `output_fields`.

**Root cause:** This is **expected behavior**. Falco only puts fields in `output_fields` that are explicitly referenced in the rule's `output:` format string. Default rules like "Contact K8S API Server From Container" don't include `%container.id` in their output.

**Proof that the plugins work:** The rule condition `container` = `container.id != host` fires successfully → the plugin resolves `container.id` correctly. The field just isn't emitted in the JSON output.

**Fix:** Override default rules via `falco_rules.local.yaml` to add the fields:
```yaml
# templates/falco-local-rules-cm.yaml
- rule: Contact K8S API Server From Container
  # ... same condition ...
  output: >
    Unexpected connection to K8s API Server from container |
    ... (existing fields) ...
    container_id=%container.id container_name=%container.name
    image=%container.image.repository
    k8s_pod=%k8s.pod.name k8s_ns=%k8s.ns.name
  priority: NOTICE
```

Mount it as `/etc/falco/falco_rules.local.yaml` via a volume mount.

---

### Working Configuration Summary

**Key files:**

| File | Purpose |
|------|---------|
| `values-airgap-override.yaml` | Helm values: collectors, plugin registration, mounts |
| `templates/k8smeta-plugin-cm.yaml` | k8smeta plugin config (gRPC endpoint) |
| `templates/k8s-metacollector.yaml` | k8s-metacollector Deployment + RBAC + Service |
| `templates/network-policies.yaml` | NetworkPolicies for Falco ↔ metacollector ↔ API server |
| `templates/falco-local-rules-cm.yaml` | Rule overrides adding container/k8s fields to output |

**Critical values:**
```yaml
# values-airgap-override.yaml (relevant excerpt)
falco:
  collectors:
    enabled: true
    docker:
      enabled: false
    containerd:
      enabled: true
      socket: /run/k3s/containerd/containerd.sock   # K3s socket (not /run/containerd/)
    crio:
      enabled: false

  falco:
    plugins:
      - name: container
        library_path: libcontainer.so
        init_config: ~    # Must be null, not {} — JSON schema constraint
    load_plugins: []      # Image builtin config.d handles container; k8smeta.yaml handles k8smeta
```

**Plugin versions:**

| Plugin | Version | Compatibility |
|--------|---------|---------------|
| `libcontainer.so` | 0.6.1 | Bundled in Falco 0.43.0 image |
| `libk8smeta.so` | 0.4.1 | Event schema 4.0.0 → compatible with Falco 0.43.0 (schema 4.1.0) |
| `k8s-metacollector` | 0.1.1 | Works with k8smeta 0.4.1 |

### Verification

```bash
# Both pods running (1 per node)
kubectl get pods -n falco -o wide
# → falco-xxxx  1/1 Running  node-1
# → falco-xxxx  1/1 Running  node-2

# Container plugin is discovering containers
kubectl exec -n falco <pod> -- curl -s http://localhost:8765/metrics | grep n_containers
# → falcosecurity_plugins_container_n_containers_total 113

# k8smeta plugin is connected to metacollector
kubectl logs -n falco <pod> | grep k8smeta
# → Wed Feb 25 09:36:54 2026: [info] [k8smeta] gRPC connected...

# Events include container.id and k8s.pod.name
kubectl logs -n falco <pod> | grep '"rule"' | python3 -c "
import sys, json
for l in sys.stdin:
    try:
        d = json.loads(l.strip())
        f = d.get('output_fields', {})
        if 'container.id' in f:
            print('container.id:', f['container.id'])
            print('k8s.pod.name:', f.get('k8s.pod.name'))
            print('image:', f.get('container.image.repository'))
            break
    except: pass
"
# → container.id: c6775a2bfbd8
# → k8s.pod.name: kube-prometheus-stack-grafana-64f7698d6c-xtss5
# → image: quay.io/kiwigrid/k8s-sidecar

# In Grafana / Loki
# Query: {namespace="falco"} | json
# Fields available: rule, container_id, k8s_pod, k8s_ns, image
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

**Layer 1 (Kyverno) - BLOCKED:**
```
❌ lumen-require-internal-registry: rejected: docker.io/alpine:latest
❌ lumen-block-latest-tag: rejected: docker.io/alpine:latest
❌ lumen-require-app-labels: Deployment malicious-app is missing labels: tier
❌ lumen-require-resources: incomplete: hacker
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
         │  Layer 1: Kyverno    │ ❌ BLOCKED (admission policies)
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
- Kyverno deployed (ArgoCD Application `kyverno`, wave 10)
- ArgoCD (optional, for GitOps)

### Step 1: Admission policies (Kyverno)

Kyverno and its policies are ArgoCD Applications (`kyverno`, wave 10, then
`kyverno-policies`, wave 11): nothing to apply by hand.

```bash
kubectl get pods -n kyverno
kubectl get validatingpolicies.policies.kyverno.io,clusterpolicies.kyverno.io
make test-policies
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
git commit -m "feat: implement 3-layer security (Kyverno + PSS + NetworkPolicies)"
git push-all

# ArgoCD will automatically sync within 3 minutes
kubectl get application -n argocd
```

---

## Testing & Verification

### Test Suite 1: Kyverno policies

`make test-policies` covers the four `lumen-*` policies with server-side dry
runs (nothing is created). One example by hand:

```bash
kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-latest-tag
  namespace: lumen
spec:
  containers:
    - name: redis
      image: 192.168.2.2:5000/redis   # no tag: implicit latest
EOF
# Expected: ❌ denied: Images need an explicit tag other than latest, or a
# digest, rejected: 192.168.2.2:5000/redis
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
  wget -qO- http://lumen-api.lumen.svc.cluster.local:9090/metrics  # 8080 up to v1.6.0

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

### Issue 1: A Kyverno policy does not reject what it should

**Diagnosis:**
```bash
# Ready, and compiled? A CEL error shows up here
kubectl get validatingpolicy <name> -o jsonpath='{.status.conditionStatus}'
# Pod policies: autogen must not be empty for Deployments to be checked
kubectl get validatingpolicy <name> -o jsonpath='{.status.autogen}'
# Is the namespace sent to Kyverno at all?
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.namespaceSelector}{"\n"}{end}'
# Kyverno down? failurePolicy Ignore lets everything through
kubectl get pods -n kyverno
```

**Known causes:** a `namespaceSelector` in a ValidatingPolicy disables autogen
and can be merged with other policies' selectors: scope namespaces with
`matchConditions` instead (see Layer 1).

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
  wget -qO- http://lumen-api.lumen.svc.cluster.local:9090/metrics  # 8080 up to v1.6.0
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

✅ **Layer 1: Kyverno**
- 4 ValidatingPolicies (tags, registry, labels, resources) + Cosign signature verification
- Admission webhook enforcement, tested with `make test-policies`

✅ **Layer 2: Pod Security Standards**
- Restricted mode on lumen namespace
- System security (privileges, capabilities, host access)
- Built-in Kubernetes enforcement

✅ **Layer 3: NetworkPolicies**
- Default deny-all ingress/egress
- Explicit allow rules per service
- Zero-trust networking

✅ **Layer 4: Falco Runtime Security**
- DaemonSet on node-1 + node-2 (modern_ebpf driver)
- Container plugin enriches alerts with K8s metadata
- JSON alerts → Alloy → Loki → Grafana

### Security Posture

**Before:**
- ❌ Any image (external registries, :latest tags)
- ❌ Privileged containers allowed
- ❌ No network segmentation

**After:**
- ✅ Only 192.168.2.2:5000 images with explicit tags (lumen, default)
- ✅ No privileged containers, must run as non-root
- ✅ Zero-trust networking with explicit allow rules
- ✅ Resource limits enforced
- ✅ Required labels for observability

### Production Readiness

| Requirement | Status | Implementation |
|-------------|--------|----------------|
| **Admission control** | ✅ | Kyverno + PSS |
| **Runtime security** | ✅ | NetworkPolicies + securityContext |
| **Audit logging** | Partial | PSS audit; Kyverno reports controller disabled |
| **Compliance** | ✅ | CIS Kubernetes Benchmark |
| **Defense in depth** | ✅ | 4 independent layers |
| **Runtime detection** | ✅ | Falco (syscall monitoring) |

---

## Next Steps

**Optional Enhancements:**

1. **Cilium CNI Migration** (Phase 15)
   - Upgrade from Flannel to Cilium
   - Enable L7 HTTP NetworkPolicies
   - Add eBPF performance benefits

2. ~~**Runtime Security** (Falco)~~ ✅ Implemented (Phase 22)

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
