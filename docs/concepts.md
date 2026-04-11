# Concepts — Technical Reference

This document explains the core concepts used in the project: Linux, networking, Kubernetes, security. Not a list of definitions — an explanation of how each concept works **concretely in this project**.

---

## 1. Linux — The Foundations

### Linux Namespaces

Everything Kubernetes does is built on Linux namespaces (not K8s namespaces — those are different). A Linux namespace isolates a system resource for a group of processes.

There are 7 types. The most important for K8s:

| Namespace | Isolates | Used for |
|-----------|----------|----------|
| `net` | Network interfaces, routing tables, ports | Each pod has its own network |
| `pid` | Process tree | PID 1 in the container ≠ PID 1 on the host |
| `mnt` | Mount points | Container filesystem is isolated |
| `uts` | Hostname | Container has its own hostname |
| `ipc` | IPC (shared memory, semaphores) | Shared memory isolation |
| `user` | UIDs/GIDs | Rootless containers |

When you run `kubectl exec -it pod -- sh`, you enter the namespaces of that pod — its network, its filesystem, its processes.

### cgroups (control groups)

Namespaces isolate **visibility**. cgroups control **resource consumption**.

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

When a container exceeds its `memory.limit` → OOMKilled by the kernel. That's why all pods in this project have `requests` and `limits` (enforced by OPA Gatekeeper).

### iptables

`iptables` is the Linux firewall used for packet routing and filtering. It works with **chains** (INPUT, OUTPUT, FORWARD) and **rules** applied in order.

In this project, iptables is used to **simulate the airgap**:

```bash
# Block all outbound traffic
iptables -A OUTPUT -d 0.0.0.0/0 -j DROP

# Allow internal network (cluster + registry)
iptables -I OUTPUT -d 10.0.0.0/8 -j ACCEPT     # K3s Pod CIDR
iptables -I OUTPUT -d 192.168.2.0/24 -j ACCEPT  # Multipass network
```

K3s itself uses iptables for Service load balancing (kube-proxy iptables mode) — when a pod calls `redis-headless:6379`, iptables redirects to the real IP of the Redis pod.

### systemd & signals

When `kubectl rollout` updates a deployment, K8s sends `SIGTERM` to the container's main process (PID 1). The application has `terminationGracePeriodSeconds` (30s by default) to shut down cleanly.

That's why lumen-api listens for `SIGTERM`:

```go
signal.Notify(shutdown, syscall.SIGTERM, syscall.SIGINT)
// → server.Shutdown(ctx, 30s timeout)
// → redis.Close() + postgres.Close()
```

If the app ignores SIGTERM, K8s sends SIGKILL after the timeout — in-flight requests are cut abruptly.

---

## 2. Kubernetes Networking

### How a pod gets its IP

1. kubelet asks the runtime (containerd) to create the container
2. containerd calls the **CNI plugin** (Flannel in this project)
3. Flannel creates a Linux network namespace (`ip netns add`)
4. Flannel creates a virtual interface (`veth pair`):
   - one end in the pod's namespace → `eth0`
   - the other end in the host's namespace → `vethXXXXX`
5. Flannel assigns an IP from the Pod CIDR (`10.42.0.0/16`)
6. Flannel configures routes so pods on node-1 can talk to pods on node-2

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

**VXLAN**: encapsulation protocol — packets between nodes are wrapped in UDP packets. Flannel handles this automatically.

### K8s Services — how they actually work

A `Service` is not a running process. It's an **iptables rule** (or an eBPF entry with Cilium).

```
kubectl apply -f service-redis.yaml
→ kube-proxy adds iptables rules on each node:

-A KUBE-SERVICES -d 10.96.45.23/32 -p tcp --dport 6379
  -j KUBE-SVC-REDIS

-A KUBE-SVC-REDIS
  -m statistic --mode random --probability 0.5 -j KUBE-SEP-REDIS-1
  -j KUBE-SEP-REDIS-2

-A KUBE-SEP-REDIS-1 -j DNAT --to-destination 10.42.0.8:6379
-A KUBE-SEP-REDIS-2 -j DNAT --to-destination 10.42.1.4:6379
```

When lumen-api calls `redis-headless:6379`:
1. DNS resolves `redis-headless.lumen.svc.cluster.local` → `10.96.45.23`
2. The packet leaves the pod with dst `10.96.45.23:6379`
3. iptables intercepts → DNAT → redirects to `10.42.0.8:6379` (real Redis pod IP)
4. Flannel routes the packet to node-1 or node-2 depending on where the Redis pod is

### Cluster DNS — CoreDNS

Every pod has `nameserver 10.96.0.10` in its `/etc/resolv.conf` — that's CoreDNS.

```
lumen-api → redis-headless:6379
         → CoreDNS resolves:
           redis-headless.lumen.svc.cluster.local
           → returns pod IPs directly (Headless Service)
              (for Redis Sentinel — the client must know all IPs)

lumen-api → lumen-db-rw:5432
         → CoreDNS resolves:
           lumen-db-rw.cnpg-system.svc.cluster.local
           → returns the Service IP (ClusterIP)
              (CNPG handles failover — Service IP stays stable)
```

**Headless Service** (`clusterIP: None`): CoreDNS returns pod IPs directly. Used for Redis Sentinel — the client must discover the master itself via sentinels.

**ClusterIP Service**: CoreDNS returns a virtual IP. kube-proxy/iptables does the DNAT. Used for PostgreSQL — CNPG manages which pod is the primary.

### NetworkPolicies — Zero Trust

By default, **all pods can talk to each other**. NetworkPolicies change that.

In this project, the pattern is:

```yaml
# 1. Block everything (namespace lumen)
kind: NetworkPolicy
spec:
  podSelector: {}        # applies to all pods
  policyTypes: [Ingress, Egress]
  # no rules = everything blocked

# 2. Explicitly allow what's needed
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

NetworkPolicies are **additive** — multiple policies on the same pod = union of rules. One blocking policy is enough, but one allowing policy is not enough if another blocks.

**Important**: NetworkPolicies are implemented by the **CNI**, not kube-proxy. Flannel alone doesn't support them — that's why this project uses `kube-router` as a NetworkPolicy controller alongside Flannel.

---

## 3. Containerd and Images

### How containerd pulls an image

Without registry mirror:
```
containerd → docker.io/falcosecurity/falco:0.43.0
           → DNS: index.docker.io
           → HTTPS pull → image layers
```

With registry mirror (this project):
```
/etc/rancher/k3s/registries.yaml:
  mirrors:
    docker.io:
      endpoint: ["http://192.168.2.2:5000"]

containerd → docker.io/falcosecurity/falco:0.43.0
           → mirror: http://192.168.2.2:5000/falcosecurity/falco:0.43.0
           → HTTP pull from internal registry
           → if absent → error (no internet fallback — airgap)
```

### OCI — Open Container Initiative

Docker and Kubernetes images follow the OCI standard. An OCI image is:
- a **manifest** JSON: list of layers + config
- **layers**: compressed tar archives (filesystem diffs)
- a **config** JSON: entrypoint, env, labels...

All stored in an OCI registry (Docker Registry v2 in this project).

Cosign leverages this standard: a signature is stored as an **OCI artifact** with a tag `sha256-<digest>.sig` in the same registry. No external storage needed.

```
192.168.2.2:5000/lumen-api:abc1234          ← the image
192.168.2.2:5000/lumen-api:sha256-XYZ.sig   ← the Cosign signature
```

### Multi-stage build

The lumen-api Dockerfile uses a multi-stage build:

```dockerfile
# Stage 1: builder (with Go toolchain ~500MB)
FROM golang:1.26 AS builder
COPY . .
RUN go build -o /app ./cmd/server

# Stage 2: final image (distroless ~5MB)
FROM gcr.io/distroless/static
COPY --from=builder /app /app
ENTRYPOINT ["/app"]
```

The final image contains **only the binary** — no shell, no package manager, no libc. If Falco detects an `execve` in this container, it's definitely suspicious (there's nothing to execute).

---

## 4. TLS and PKI

### How TLS works (simplified handshake)

```
Client (browser)             Server (Traefik)
     │                              │
     │──── ClientHello ────────────▶│
     │     (TLS version, ciphers)   │
     │                              │
     │◀─── ServerHello ─────────────│
     │     + Certificate            │  ← cert signed by Vault PKI CA
     │                              │
     │  Verifies: cert signed by    │
     │  a trusted CA?               │
     │  → airgap-ca.crt imported    │
     │    into macOS trust store    │
     │                              │
     │──── ClientKeyExchange ──────▶│
     │     (encrypted session key)  │
     │                              │
     │◀══════ encrypted data ═══════│
```

In this project, the root CA is generated by Vault PKI. It's imported into macOS via `03-airgap-zone/scripts/trust-ca.sh` — that's why `https://grafana.airgap.local` opens without a browser warning.

### cert-manager — lifecycle automation

Without cert-manager, you have to:
1. Generate a CSR (Certificate Signing Request)
2. Get it signed by Vault
3. Store the cert in a K8s Secret
4. Renew before expiry (manually)

With cert-manager:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-tls
spec:
  secretName: grafana-tls        # K8s Secret created automatically
  issuerRef:
    name: vault-issuer           # ClusterIssuer → Vault PKI
  dnsNames:
    - grafana.airgap.local
  duration: 720h                 # 30 days
  renewBefore: 168h              # renewed 7d before expiry
```

cert-manager watches expiry, contacts Vault, gets a new cert, updates the Secret — **without human intervention**.

### mTLS — Mutual TLS

Standard TLS: only the **server** presents a certificate (the client verifies the server's identity).

mTLS: **both sides** present a certificate. The server also verifies the client's identity.

```
lumen-api (client cert)    ←──mTLS──→    Redis (server cert)
     │ "I am lumen-api"                  "I am redis"
     │  cert signed by Vault PKI          cert signed by Vault PKI
```

In this project, cert-manager generates certs for each service. Only services with a valid cert signed by the same CA can communicate — even if an attacker bypasses NetworkPolicies, they can't establish the TLS connection.

---

## 5. eBPF — Modern Kernel Observability

**eBPF** (extended Berkeley Packet Filter) allows running sandboxed programs directly in the Linux kernel, without modifying the kernel or loading a module.

Falco uses eBPF (`modern_ebpf` driver) to monitor **syscalls**:

```
lumen-api process
    │
    │ syscall: connect(fd, "8.8.8.8:443")   ← attempted external connection
    │
    ▼
Linux Kernel
    │
    │ eBPF hook on sys_connect
    │ → runs the Falco eBPF program
    │ → compares against Falco rules
    │ → "Unexpected outbound connection" → alert
    │
    ▼
Falco daemon (userspace)
    → structured log → Alloy → Loki → Grafana
```

**Advantages vs kernel module**:
- No need to recompile for each kernel version
- Sandboxed: a bug in the eBPF program can't crash the kernel
- Performance: the hook is in the kernel path, no userspace context switch

**kube-router** also uses eBPF to enforce NetworkPolicies — more efficient than O(n) iptables rules because eBPF uses O(1) hash maps.

---

## 6. GitOps — Why It's Different from Classic CI/CD

**Classic CI/CD (push model)**:
```
git push → CI build → CI deploy (kubectl apply)
```
The CI has direct access to the cluster. If the CI is compromised → cluster is compromised.

**GitOps (pull model)**:
```
git push → CI build → CI push image + update manifest
                                    ↑
                     ArgoCD polls Gitea (pull)
                     ArgoCD applies diff
```

The cluster **pulls** config from Git. The CI **never** has access to the cluster. Git becomes the source of truth — manual `kubectl apply` is overwritten by ArgoCD (`selfHeal: true`).

Advantages:
- **Audit trail**: every production change = a Git commit
- **Rollback** = `git revert` → ArgoCD re-syncs
- **Drift detection**: if someone does `kubectl edit` manually, ArgoCD reverts it
- **Security**: only ArgoCD (inside the cluster) holds the K8s credentials

---

## 7. Helm — K8s Templating

Helm is a package manager for K8s. A **chart** is:
- YAML templates with variables (`{{ .Values.image.tag }}`)
- a `values.yaml` with default values
- a `Chart.yaml` with metadata

In this project, each component has a **wrapper chart**:

```
03-airgap-zone/manifests/chaos-mesh-helm/
├── Chart.yaml          ← dependency on the official chart
├── values-airgap-override.yaml  ← override registry + resources
└── charts/
    └── chaos-mesh-2.7.2.tgz    ← official chart (bundled, airgap)
```

The official chart is downloaded in the connected zone and bundled in `charts/`. ArgoCD runs `helm template` locally without internet access.

`helm dependency update` downloads dependency charts into `charts/`. This is what enables airgap installation.

---

## 8. Kubernetes RBAC

**RBAC** (Role-Based Access Control) controls who can do what on which K8s resources.

```
ServiceAccount (pod identity)
    │
    │ RoleBinding / ClusterRoleBinding
    │ (binds a SA to a Role)
    ▼
Role / ClusterRole (list of permissions)
    rules:
    - apiGroups: [""]
      resources: ["pods"]
      verbs: ["get", "list", "watch"]
```

Concrete example — ArgoCD:
- `argocd-application-controller` has a `ClusterRole` that can `get/list/watch/apply` on all resources
- `argocd-server` (UI) has a more restricted `Role` — just read Applications

Falco with k8smeta:
- The `k8s-metacollector` has a `ClusterRole` to `watch` pods, nodes, namespaces
- It exposes this metadata to Falco via gRPC — this is what allows Falco to enrich its alerts with `k8s.pod.name`, `k8s.ns.name`

---

## 9. Admission Controllers

An **admission controller** is a webhook that intercepts all requests to the K8s API before they're persisted in etcd.

```
kubectl apply -f pod.yaml
       │
       ▼
  K8s API Server
       │
       ├── Authentication (valid token/cert?)
       ├── Authorization (RBAC: right to create a Pod?)
       │
       ├── Mutating Admission Webhooks    ← modifies the request
       │   (e.g.: inject a sidecar)
       │
       ├── Validating Admission Webhooks  ← accepts or rejects
       │   ├── OPA Gatekeeper             ← no :latest, resource limits...
       │   └── PSS (Pod Security Standards) ← no root, no privileged...
       │
       └── Persisted in etcd → kubelet creates the pod
```

**OPA Gatekeeper** uses `ConstraintTemplate` (Rego policy) + `Constraint` (configuration):

```
ConstraintTemplate: BlockLatestTag
  → Rego code that checks if image tag == "latest"

Constraint: block-latest-tag
  → applied to all namespaces
  → violation → request rejected + error message
```

**Pod Security Standards** are built into K8s (since 1.25) — no external webhook. Configured by namespace label:
```
namespace lumen:
  pod-security.kubernetes.io/enforce: restricted
```

---

## 10. etcd — The Cluster Brain

`etcd` is the distributed database where K8s stores **all its state**: pods, services, secrets, configmaps, CRDs...

In this project, K3s embeds etcd in single-node mode (no multi-node etcd cluster). All cluster data is in `/var/lib/rancher/k3s/server/db/`.

**Why this matters for security:**
- K8s Secrets are stored in etcd in **base64** (not encrypted by default)
- That's why this project uses Vault — real secrets are never in etcd
- VSO generates K8s Secrets on the fly from Vault, but they're ephemeral and rotatable

```
etcd contains:
  ✅ Manifests (Deployments, Services...)
  ✅ ConfigMaps (non-sensitive config)
  ⚠️  K8s Secrets (base64 only — avoided as much as possible)
  ✅ CRDs and their instances
  ✅ Lease state (leader election)
```

---

## 11. MetalLB — LoadBalancer Without a Cloud

In a cloud (AWS, GCP...), when you create a `type: LoadBalancer` Service, the cloud provider automatically provisions an external IP. In this project, we're on local VMs — no cloud provider. MetalLB replaces that functionality.

### How L2 Advertisement works

MetalLB uses **L2 (Layer 2 / ARP)** mode. The principle: one of the nodes "claims" the virtual IP (`192.168.2.100`) by responding to ARP requests on the local network.

```
Mac (192.168.2.1)                    node-1 (192.168.2.2)
      │                                      │
      │  "Who has 192.168.2.100?" (ARP req)  │
      │─────────────────────────────────────▶│
      │                                      │
      │  "That's me" (MAC: 52:54:00:aa:73:c6)│  ← MetalLB speaker replies
      │◀─────────────────────────────────────│
      │                                      │
      │  HTTPS → 192.168.2.100:443           │
      │─────────────────────────────────────▶│  → Traefik
```

The MetalLB **speaker** (DaemonSet on each node) watches which Services need an external IP. When a `type: LoadBalancer` Service is created, the speaker elects a leader node that announces the IP via ARP.

### Why the ARP entry is lost on reboot

The Mac stores IP↔MAC mappings in its **ARP table** (temporary cache). After a VM reboot:
1. MetalLB speaker restarts and starts responding to ARP again
2. But the Mac already has an "incomplete" (or expired) ARP entry for `192.168.2.100`
3. Until there's traffic that forces a new ARP request, the Mac doesn't "discover" the new MAC

Hence the static entry in `start.yml`:
```bash
arp -s 192.168.2.100 52:54:00:aa:73:c6   # force IP↔MAC mapping
```

Without this, `https://argocd.airgap.local` times out even if everything is running in the cluster.

---

## 12. Vault HA — Shamir's Secret Sharing

Vault stores sensitive secrets. The problem: how do you protect Vault's own encryption key? If it's on disk, anyone with disk access can decrypt all secrets.

### The unsealing mechanism

Vault uses **Shamir's Secret Sharing**: the master key is split into `N` shards, of which `K` are needed to reconstruct the key (threshold). In this project: 5 shards, threshold 3.

```
Master key (256 bits)
       │
       │ Shamir split (5 shards, threshold 3)
       ▼
  shard-1  shard-2  shard-3  shard-4  shard-5
  (in vault-keys.json)

On startup — Vault is "sealed" (data inaccessible)
  → provide any 3 shards
  → Vault reconstructs the master key
  → Vault is "unsealed" (operational)
```

Vault **never** stores the master key in memory between restarts. That's why after every reboot, Vault starts in "sealed" state and `unseal.yml` must be replayed.

### Vault HA with Raft

In this project, Vault runs in HA mode with 3 pods (`vault-0`, `vault-1`, `vault-2`) and the **Raft** storage backend (built-in distributed consensus, no Consul needed).

```
vault-0 (leader)   vault-1 (standby)   vault-2 (standby)
      │                   │                   │
      └───────────────────┴───────────────────┘
                   Raft consensus
                (data replication)

Request → vault.airgap.local → Traefik → vault-active Service
                                          → always the Raft leader
```

If `vault-0` goes down, Raft elects a new leader from `vault-1`/`vault-2`. But all three pods must be unsealed — that's why `unseal.yml` unseals the 3 pods sequentially.

---

## 13. Supply Chain Security — Cosign

**The problem**: how do you know the image running in the cluster is the one built by CI, and not a substituted image (supply chain attack)?

### Signing with Cosign

Cosign allows **cryptographically signing** an OCI image and storing the signature in the same registry, without external infrastructure.

In CI (`.gitea/workflows/ci.yaml`):
```bash
# After docker push:
cosign sign \
  --key /tmp/cosign.key \        # private key (CI secret)
  --tlog-upload=false \          # no Rekor (airgap)
  192.168.2.2:5000/lumen-api:abc1234
```

Cosign computes the SHA256 digest of the image and creates an OCI artifact with a special tag:
```
192.168.2.2:5000/lumen-api:abc1234              ← the image
192.168.2.2:5000/lumen-api:sha256-XYZ....sig    ← the signature (OCI artifact)
```

The signature is stored **in the airgap registry** — no access to Rekor (public transparency log) needed. This is the airgap adaptation: `--tlog-upload=false`.

### Verification

To verify that an image is properly signed:
```bash
cosign verify \
  --key cosign.pub \
  --insecure-ignore-tlog \
  192.168.2.2:5000/lumen-api:abc1234
```

If the signature doesn't match the public key → verification fails → the image should not run.

---

## 14. Argo Rollouts — Progressive Deployments

A standard K8s `Deployment` does a **rolling update**: progressively replaces pods, but with no traffic control and no automatic rollback based on metrics.

**Argo Rollouts** replaces the `Deployment` with a `Rollout` — same spec, but with an advanced `strategy`.

### Canary in this project

```yaml
strategy:
  canary:
    stableService: lumen-api-stable    # 80% of traffic
    canaryService: lumen-api-canary    # 20% of traffic
    steps:
      - setWeight: 20     # step 1: 20% canary
      - analysis: ...     # check prometheus: success rate >= 95%?
      - setWeight: 80     # step 2: 80% canary
      - analysis: ...     # check again
      - setWeight: 100    # full promotion
```

How traffic splitting works: Traefik points to two K8s Services (`lumen-api-stable` and `lumen-api-canary`). Argo Rollouts adjusts the number of pods in each Service to match the percentages.

### AnalysisTemplate — automatic rollback

The `success-rate` `AnalysisTemplate` queries Prometheus:
```promql
sum(rate(http_requests_total{app="lumen-api",status!~"5.."}[2m]))
/
sum(rate(http_requests_total{app="lumen-api"}[2m]))
```

If the success rate drops below 95% for 3 consecutive checks → Argo Rollouts **automatic rollback** to the stable version, without human intervention.

```
git push → CI build → ArgoCD sync → Rollout starts
                                          │
                                    20% canary
                                          │
                              ┌─── success rate < 95%? ──▶ automatic ROLLBACK
                              │
                              └─── OK ──▶ 80% canary ──▶ OK ──▶ 100% (promotion)
```

---

## 15. Chaos Engineering — Chaos Mesh

**The principle**: inject controlled failures in production (or staging) to verify the system behaves correctly under stress. "If you haven't tested the failure, you don't know if you can recover."

### Types of experiments in this project

**PodChaos** (`01-podchaos-lumen-api.yaml`):
```yaml
action: pod-kill
mode: fixed-percent
value: "50"       # kills 50% of lumen-api pods
duration: "2m"
```
What it tests: does Argo Rollouts recreate the pods? Does the Service stay available with the remaining pods?

**NetworkChaos** (`02-networkchaos-redis-latency.yaml`, `03-networkchaos-cnpg-latency.yaml`):
```yaml
action: delay
delay:
  latency: "100ms"   # adds 100ms network latency to Redis/CNPG
```
What it tests: does lumen-api handle timeouts correctly? Do circuit breakers work?

### How Chaos Mesh injects failures

Chaos Mesh uses a **DaemonSet** (`chaos-daemon`) on each node with privileges to manipulate Linux network namespaces and kill processes. When you `kubectl apply` an experiment:

```
ChaosExperiment (CR)
      │
      ▼
chaos-controller-manager
      │  selects target pods (labelSelector)
      ▼
chaos-daemon (on the target node)
      │  network: tc qdisc add dev eth0 root netem delay 100ms
      │  pod-kill: SIGKILL on the container PID
      ▼
Fault injected
```

When the experiment expires or is deleted, `chaos-daemon` undoes the changes (`tc qdisc del`).

---

## 16. IaC — Terraform + Ansible

This project uses **two IaC tools** with distinct responsibilities.

### Terraform — declarative provisioning

Terraform manages the **VM lifecycle** for Multipass. Its model is **declarative**: you describe the desired state, Terraform computes the diff and applies it.

```hcl
resource "multipass_instance" "node1" {
  name   = "node-1"
  cpus   = 4
  memory = "6G"
  disk   = "40G"
  cloudinit_file = "cloud-init/node1-rendered.yaml"
}
```

`terraform apply` → Multipass VM created with the right specs + cloud-init (static IP, Docker, sysctl).
`terraform destroy` → VM cleanly deleted.

**cloud-init** runs on the VM's first boot and configures: static network interface (`enp0s1` / bridge), Docker installation, kernel parameters (`fs.inotify.max_user_instances=8192` required by Falco).

### Ansible — idempotent configuration

Ansible manages **cluster configuration** after the VMs exist. Its model is **procedural but idempotent**: each task checks if the desired state is already reached before acting.

```
Terraform          Ansible
    │                  │
    │  VMs created     │  K3s installed
    │  IPs configured  │  Registry configured
    │  Docker installed│  Cluster bootstrapped
    ▼                  ▼
Infrastructure     Applications
```

### Why two tools

| | Terraform | Ansible |
|---|---|---|
| Model | Declarative (state file) | Procedural (playbooks) |
| Best for | Infra (VMs, network, cloud) | Config (packages, services, K8s) |
| State | `.tfstate` file | No state (checks on every run) |
| Parallelism | Native (dependency graph) | Manual (`async`) |

Terraform alone can't "install K3s inside a VM". Ansible alone can't "create a VM and wait for it to be ready". Together they cover everything, from bare metal to applications.

---

## 17. Kubernetes Operators — Intelligent Automation

A **Kubernetes operator** is not a simple script or tool — it's an **autonomous agent** that encodes the operational expertise of a complex application and maintains it automatically.

### The Operator Pattern

An operator = **CRD** (Custom Resource Definition) + **Controller** (reconciliation loop).

```
Custom Resource (desired state)   Controller (the brain)
┌──────────────────────┐          ┌───────────────────────┐
│ apiVersion: cnpg/v1  │          │ cnpg-controller-mgr   │
│ kind: Cluster        │──watch──▶│ (pod running 24/7)    │
│ spec:                │          └───────────────────────┘
│   instances: 3       │                    │
└──────────────────────┘                    │
                                  ┌─────────┴─────────┐
                                  ▼                   ▼
                            Creates 3 pods      Configures
                            PostgreSQL          replication
```

The controller runs a **reconciliation loop** continuously:

```go
// Simplified pseudo-code of the CNPG controller
func ReconcileLoop() {
  for {
    // 1. Read desired state (your YAML)
    desired := GetCluster("lumen-db")  // instances: 3

    // 2. Read current state (in K8s)
    actual := GetRunningPods()  // 2 pods (1 is dead!)

    // 3. Compare
    if actual.Count < desired.Instances {
      // 4. Repair automatically
      CreateNewPod()
      if actual.Primary == nil {
        PromoteReplica()  // Automatic failover!
      }
    }

    // 5. Wait and repeat
    sleep(10s)
  }
}
```

This loop runs **continuously** in the controller pod — it's a living process, not a one-shot script.

### Operator vs Script/Helper

| Script/Helper | Operator |
|--------------|----------|
| You call it when you want | Runs **24/7** (watching pod) |
| Does 1 action then stops | **Infinite loop** of surveillance |
| You detect problems | **Detects automatically** |
| Stateless | **Stateful** (knows desired state) |
| **Ex:** `kubectl scale` | **Ex:** HorizontalPodAutoscaler |

**Analogy**:
- **Script** = screwdriver (you tighten a screw when you see it loose, then put the tool away)
- **Operator** = maintenance robot (patrols 24/7, automatically detects and tightens all loose screws)

### Concrete examples in this project

#### CloudNativePG (PostgreSQL operator)

```yaml
# You just write this:
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: lumen-db
spec:
  instances: 3
```

**The CNPG controller automatically**:
- Creates 3 PostgreSQL pods with the right config
- Configures streaming replication
- Creates `-rw` (master) and `-ro` (replicas) services
- **If the master dies** → elects a new master via Raft, promotes a replica, updates the service → **failover in 30s without human intervention**
- Generates credentials in a K8s Secret
- Exposes Prometheus metrics
- Renews TLS certs before expiry

**Without the operator**, you would:
1. Create a StatefulSet manually
2. Configure Patroni or Stolon for failover
3. Deploy etcd/Consul for consensus
4. Write monitoring scripts
5. Wake up at 3am when the master crashes to run `pg_ctl promote` by hand

**With CNPG**: you sleep, the operator handles everything.

#### Chaos Mesh (chaos engineering operator)

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

**The Chaos Mesh controller**:
- Watches this CR (Custom Resource)
- Asks the `chaos-daemon` (privileged DaemonSet) to inject 100ms network latency toward Redis pods via `tc netem`
- After 5 minutes → automatically cleans up (`tc qdisc del`)
- **If the chaos-daemon pod restarts during the experiment** → reapplies the chaos automatically (reconciliation)

#### ArgoCD (GitOps operator)

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

**The ArgoCD controller**:
- Polls the Git repo every 3 minutes
- Compares Git state (source of truth) vs cluster state
- **If you do a manual `kubectl edit`** → ArgoCD detects it and reverts (`selfHeal: true`)
- **If a new commit arrives** → automatically applies the diff

### Why this is revolutionary

Operators **encode human expertise into code**:

```
Expert PostgreSQL DBA knows:
  ✓ How to do a clean failover
  ✓ When to promote a replica
  ✓ How to configure replication
  ✓ How to manage WAL backups
  ✓ Which config to tune based on RAM

→ This knowledge is encoded in the CNPG controller
→ Available to everyone, for free, 24/7
→ Zero fatigue, zero oversight, zero 3am wakeups
```

**Result**: you delegate operational intelligence to code instead of paying SREs to be on-call.

---

## 18. Ingress Controllers — Smart Reverse Proxy

### The problem to solve

You have 10 web applications in the cluster:
- `argocd.airgap.local`
- `grafana.airgap.local`
- `vault.airgap.local`
- ...

**Without Ingress**: you'd need 10 different LoadBalancer IPs (one per Service) → wasteful.

**With Ingress**: a single IP (`192.168.2.100`) routes to the right application based on the HTTP request **hostname**.

### Architecture in this project

```
Mac (browser)
      │
      │ HTTPS https://grafana.airgap.local (→ 192.168.2.100)
      ▼
  MetalLB (L2 ARP)
      │ "192.168.2.100 is on node-1" (MAC address)
      ▼
  Traefik Ingress Controller (pod on node-1)
      │
      │ Parses HTTP Host header: "grafana.airgap.local"
      │ Looks up Ingress resources
      │ Route match found: grafana.airgap.local → grafana:80
      ▼
  Service grafana (ClusterIP 10.96.x.x)
      │
      │ kube-proxy iptables DNAT
      ▼
  Grafana pod (10.42.0.15:3000)
```

### How it works

#### 1. LoadBalancer Service for Traefik

```yaml
apiVersion: v1
kind: Service
metadata:
  name: traefik
spec:
  type: LoadBalancer          # MetalLB assigns 192.168.2.100
  ports:
    - name: web
      port: 80
      targetPort: 8000        # Traefik pod port
    - name: websecure
      port: 443
      targetPort: 8443
  selector:
    app.kubernetes.io/name: traefik
```

MetalLB announces `192.168.2.100` via ARP. **All** HTTP/S traffic from the local network arrives at this Traefik pod.

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
                name: grafana        # Target K8s Service
                port:
                  number: 80
  tls:
    - hosts:
        - grafana.airgap.local
      secretName: grafana-tls        # TLS cert (cert-manager)
```

Traefik **watches** all Ingress resources in the cluster (via the K8s API) and builds its routing table automatically:

```
Host: grafana.airgap.local  → grafana.monitoring.svc.cluster.local:80
Host: argocd.airgap.local   → argocd-server.argocd.svc.cluster.local:443
Host: vault.airgap.local    → vault.vault.svc.cluster.local:8200
```

#### 3. TLS termination

Traefik handles the **TLS handshake** with the client. The certificate is stored in the Secret `grafana-tls` (generated by cert-manager from Vault PKI).

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

**Advantage**: backend pods (Grafana, ArgoCD...) don't need to manage TLS themselves. Traefik centralizes that.

### Virtual Hosting — how it works

When you type `https://grafana.airgap.local` in the browser:

1. **DNS**: `/etc/hosts` resolves `grafana.airgap.local` → `192.168.2.100` (MetalLB IP)
2. **ARP**: your Mac asks "who has 192.168.2.100?" → MetalLB replies with node-1's MAC
3. **TCP**: connection established to `192.168.2.100:443`
4. **TLS handshake**: Traefik presents the `grafana-tls` cert (signed by Vault PKI)
5. **HTTP request**:
   ```
   GET / HTTP/1.1
   Host: grafana.airgap.local    ← the critical header
   ```
6. **Traefik parses** the `Host` header → looks up its routing table → finds the `grafana` Ingress → proxies to `grafana.monitoring.svc.cluster.local:80`
7. **K8s Service** → iptables DNAT → Grafana pod

**Same IP, multiple hostnames**: it's the HTTP `Host:` header that makes the difference. That's why you can have 10 different domains all pointing to `192.168.2.100` — Traefik routes based on the hostname.

### Ingress vs Service LoadBalancer

| | Service LoadBalancer | Ingress |
|---|---|---|
| **Layer** | L4 (TCP/UDP) | L7 (HTTP/HTTPS) |
| **Routing** | IP:Port → Pod | Hostname + Path → Service |
| **TLS** | Managed by the app | Managed by Ingress Controller |
| **IPs needed** | 1 per service | 1 for N services |
| **Use case** | Databases, gRPC | Web applications |

**Example**:
- PostgreSQL (`lumen-db-rw:5432`) → direct Service LoadBalancer (not HTTP, no Ingress needed)
- Grafana web UI → Ingress (HTTP routing + TLS termination)

### Traefik specifics

In this project, Traefik is deployed via Helm with these features:

**Automatic HTTPS redirect**:
```yaml
# traefik values
ports:
  web:
    redirectTo:
      port: websecure    # HTTP → HTTPS automatic
```

**Middleware** (example: BasicAuth for ArgoCD):
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: auth
spec:
  basicAuth:
    secret: authsecret
---
# In the Ingress:
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: argocd-auth@kubernetescrd
```

Traefik injects the BasicAuth middleware before proxying to ArgoCD — additional protection without modifying ArgoCD.

**Dashboard**: Traefik exposes its own dashboard (`/dashboard`) to see routes, middlewares, and active services in real time.

---

## 19. StatefulSets — Apps with Stable Identity

### Deployment vs StatefulSet

K8s offers two ways to deploy pods:

| Deployment | StatefulSet |
|-----------|-------------|
| **Stateless** pods | **Stateful** pods |
| Random names (`lumen-api-7f8d9c-xk2p9`) | **Stable** names (`lumen-db-1`, `lumen-db-2`) |
| Non-deterministic startup order | **Sequential** startup (0 → 1 → 2) |
| Parallel scaling | **Ordered** scaling |
| No stable storage | **Dedicated PVC** per pod (survives restart) |
| Use case: APIs, workers | Use case: **databases, queues** |

### Sticky Identity — why it matters

**With a Deployment**:
```
kubectl get pods -n lumen
lumen-api-7f8d9c-xk2p9    # random name
lumen-api-7f8d9c-bh4k1

# Pod restarts → new name
lumen-api-7f8d9c-zz9w3    # identity lost
```

**With a StatefulSet**:
```
kubectl get pods -n lumen
lumen-db-1    # stable name, always "1"
lumen-db-2    # stable name, always "2"
lumen-db-3

# Pod lumen-db-1 restarts → still "lumen-db-1"
# Its PVC stays attached → PostgreSQL data is preserved
```

### Examples in this project

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

The CNPG operator creates a **StatefulSet** internally:
```
lumen-db-1  → PostgreSQL master (data in PVC lumen-db-1)
lumen-db-2  → replica (data in PVC lumen-db-2)
lumen-db-3  → witness (data in PVC lumen-db-3)
```

**Why stable identity is critical**:
- CNPG must know "who is the master" → uses the stable name (`lumen-db-1`)
- The master changes (failover) → `lumen-db-2` becomes master, but keeps its name → DNS configs stay consistent
- Each pod has **its own PVC** → if `lumen-db-1` restarts, it finds its exact PostgreSQL data

#### Redis HA

```
redis-master-0   → StatefulSet with 1 replica
redis-replica-0  → StatefulSet with 1 replica
```

The `-0` suffix indicates it's a StatefulSet. Redis Sentinel uses stable names to track who is the master.

#### Vault HA

```
vault-0  → Raft leader
vault-1  → standby
vault-2  → standby
```

Raft requires each node to have a stable identity for quorum. If `vault-0` restarts, it must rejoin the Raft cluster with the same identity.

### Ordered Deployment

When you create a StatefulSet with 3 replicas:

```
kubectl apply -f statefulset.yaml

1. Creates pod-0
   → waits for pod-0 to be Ready
2. Creates pod-1
   → waits for pod-1 to be Ready
3. Creates pod-2
   → waits for pod-2 to be Ready
```

**Why this matters**: in a PostgreSQL cluster, the master (`lumen-db-1`) must start **before** the replicas, otherwise the replicas can't connect for initial replication.
