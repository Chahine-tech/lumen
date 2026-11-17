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

### 3. Infrastructure CA

`~/.lumen-pki` (`03-airgap-zone/scripts/infra-ca.sh init`), with the
certificate of the transit Vault (`infra-ca.sh server`): the `vault` and
`vault_transit` roles need them. `docs/runbooks/vault-tls.md`,
`docs/runbooks/vault-auto-unseal.md`.

### 4. Gitea admin password

The `gitea` role reads it from the environment, never from a file in the
repository (issue #1). Export it from your password manager before running
`site.yml`:

```bash
read -rs GITEA_ADMIN_PASSWORD && export GITEA_ADMIN_PASSWORD
```

---

## Daily usage

### Vault after a restart

The cluster's Vault unseals itself through the transit Vault on backup-1
(issue #3). Only the transit Vault is unsealed by hand, after a restart of
backup-1: `start.yml` asks for it.

```bash
03-airgap-zone/scripts/vault-transit.sh unseal
```

### Start the cluster

```bash
ansible-playbook 04-ansible/start.yml
# if sudo requires a password:
ansible-playbook 04-ansible/start.yml --ask-become-pass
```

What it does:
1. `multipass start backup-1`, then `multipass start node-1 node-2`
2. Waits for nodes to be Ready
3. Restores the MetalLB ARP entry (`sudo arp -s 192.168.2.100 <MAC>`)
4. Asks for the transit Vault to be unsealed if it is sealed, then waits for
   the Vault pods to unseal themselves

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
> 3. The infrastructure CA and the transit Vault's certificate (above)

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
│   ├── garage/            # Garage (S3) on backup-1, PostgreSQL backups
│   ├── vault_transit/     # Transit Vault on backup-1 (auto-unseal)
│   ├── vault/             # Vault certificates, wait for the pods to unseal
│   ├── dns/               # /etc/hosts + macOS CA trust
│   └── verify/            # Health checks
├── site.yml               # Full bootstrap
├── start.yml              # Start VMs + ARP + transit Vault, wait for Vault
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

## Vault init (one-time)

```bash
03-airgap-zone/scripts/vault-transit.sh init     # transit Vault: its keys, the cluster's token
03-airgap-zone/scripts/vault-bootstrap.sh init   # cluster Vault: recovery keys, configuration
```

Both print their keys once and store them nowhere: hand them to their
holders, offline. `docs/runbooks/vault-auto-unseal.md`.

---

## Troubleshooting

### SSH refused to node-1/node-2

```bash
multipass exec node-1 -- bash -c \
  "echo '$(cat ~/.ssh/id_ed25519.pub)' >> ~/.ssh/authorized_keys"
```

### Vault pods not ready after a restart

```bash
kubectl logs -n vault vault-0 | grep -i seal
# "error parsing Seal configuration ... Vault is sealed": unseal the transit Vault
03-airgap-zone/scripts/vault-transit.sh unseal
# "permission denied": the transit token expired or is bound to other
# addresses: vault-transit.sh token (docs/runbooks/vault-auto-unseal.md)
```

The pods retry with the kubelet's backoff (up to 5 min).

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
