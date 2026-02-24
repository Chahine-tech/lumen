# 04-ansible — Lumen airgap cluster automation

Ansible playbooks for the K3s airgap cluster running on Multipass (macOS M2).

## Prerequisites

### 1. Install Ansible

```bash
brew install ansible
# or
pip3 install ansible
ansible --version
```

### 2. Inject SSH key into VMs (one-time)

Direct SSH to the VMs requires your public key in `authorized_keys`.
Run this **once** — VMs retain it across restarts.

```bash
# Inject SSH key into node-1
multipass exec node-1 -- bash -c \
  "mkdir -p ~/.ssh && echo '$(cat ~/.ssh/id_ed25519.pub)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# Inject SSH key into node-2
multipass exec node-2 -- bash -c \
  "mkdir -p ~/.ssh && echo '$(cat ~/.ssh/id_ed25519.pub)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# Verify
ssh ubuntu@192.168.2.2 echo "node-1 OK"
ssh ubuntu@192.168.2.3 echo "node-2 OK"
```

> **Note**: If you don't have an `id_ed25519` key, generate one:
> `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""`

### 3. vault-keys.json

`vault-keys.json` must exist at the project root for playbooks that unseal Vault.
It is generated once during Vault init and must **never** be committed.

---

## Daily usage

### Unseal Vault (after every VM or Mac restart)

```bash
ansible-playbook 04-ansible/unseal.yml
```

Unseals vault-0, vault-1, vault-2 using the keys from `vault-keys.json`.

### Start the cluster

```bash
ansible-playbook 04-ansible/start.yml
# if sudo requires a password:
ansible-playbook 04-ansible/start.yml --ask-become-pass
```

What it does:
1. `multipass start node-1 node-2`
2. Waits for nodes to be Ready
3. Restores the MetalLB ARP entry (`sudo arp -s 192.168.2.100 <MAC>`)
4. Reinstalls OPA Gatekeeper constraint templates
5. Unseals Vault

### Stop the cluster gracefully

```bash
ansible-playbook 04-ansible/stop.yml
```

What it does:
1. Drains node-2 (evicts workloads cleanly)
2. `multipass stop node-2 node-1`

---

## Full bootstrap (from scratch, ~20 min)

```bash
ansible-playbook 04-ansible/site.yml --ask-become-pass
```

> **Prerequisites before running site.yml**:
> 1. SSH key injected into VMs (see above)
> 2. Container images available in `02-transit-zone/registry-data/`
>    (or push manually via `02-transit-zone/push-*.sh` scripts)
> 3. `vault-keys.json` if the cluster was previously initialized (otherwise init manually after)

### Partial run (by tags)

```bash
# Only MetalLB + DNS
ansible-playbook 04-ansible/site.yml --tags "metallb,dns" --ask-become-pass

# Only verification
ansible-playbook 04-ansible/site.yml --tags verify

# Everything except images (images already in registry)
ansible-playbook 04-ansible/site.yml --skip-tags images --ask-become-pass
```

---

## Structure

```
04-ansible/
├── inventory/
│   └── hosts.yml          # node-1 (192.168.2.2), node-2 (192.168.2.3), localhost
├── group_vars/
│   └── all.yml            # all variables (versions, IPs, paths)
├── roles/
│   ├── multipass/         # Create/start VMs
│   ├── k3s/               # Install K3s + kubeconfig
│   ├── registry/          # Docker registry on node-1:5000
│   ├── images/            # Transfer images to registry
│   ├── metallb/           # MetalLB + macOS ARP
│   ├── argocd/            # ArgoCD + Applications
│   ├── gitea/             # Gitea org/repo + git push
│   ├── opa/               # Gatekeeper + constraints
│   ├── vault/             # Wait for pods + unseal
│   ├── dns/               # /etc/hosts + macOS CA trust
│   └── verify/            # Health checks
├── site.yml               # Full bootstrap
├── unseal.yml             # Unseal Vault only
├── start.yml              # Start VMs + ARP + OPA + unseal
└── stop.yml               # Drain + stop VMs
```

---

## Cluster topology

| VM | IP | Role | CPU | RAM | Disk |
|----|----|------|-----|-----|------|
| node-1 | 192.168.2.2 | control-plane + registry | 4 | 6G | 40G |
| node-2 | 192.168.2.3 | worker | 2 | 4G | 30G |

**MetalLB VIP**: 192.168.2.100 (Traefik LoadBalancer)

---

## Vault init (one-time, manual)

Vault bootstrap is intentionally manual — unseal keys cannot be stored in plaintext in a playbook.

```bash
# 1. Wait for Vault to be deployed by ArgoCD
kubectl get pods -n vault -w

# 2. Initialize Vault (generates vault-keys.json)
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-keys.json

# Keep vault-keys.json safe — never commit it

# 3. Unseal
ansible-playbook 04-ansible/unseal.yml

# 4. Configure secrets (KV, PKI, K8s auth)
# See: docs/vault-cert-manager.md
```

---

## Troubleshooting

### SSH refused to node-1/node-2

```bash
multipass exec node-1 -- bash -c \
  "echo '$(cat ~/.ssh/id_ed25519.pub)' >> ~/.ssh/authorized_keys"
```

### Vault still sealed after unseal.yml

```bash
kubectl exec -n vault vault-0 -- vault status
# If Sealed: true, re-run:
ansible-playbook 04-ansible/unseal.yml
```

### ArgoCD Applications OutOfSync

```bash
kubectl get applications -n argocd
argocd app sync <app-name> --server argocd.airgap.local
```

### ARP entry lost (MetalLB unreachable)

```bash
NODE1_MAC=$(multipass exec node-1 -- cat /sys/class/net/eth0/address)
sudo arp -s 192.168.2.100 $NODE1_MAC
```
