# Cilium NetworkPolicy Examples

This directory contains Cilium-specific NetworkPolicy examples that require Cilium CNI to be installed.

## Why are these files here?

These manifests use Cilium's advanced features (L7 HTTP filtering, cluster-wide policies) that are **not available** in the standard Kubernetes NetworkPolicy API.

### What Kubernetes standard NetworkPolicy CAN do:
- ✅ **Layer 3** (IP filtering): Block/allow traffic by IP address, CIDR ranges
- ✅ **Layer 4** (Port filtering): Block/allow traffic by TCP/UDP ports
- ✅ **Namespace/Pod selector**: Target specific pods or namespaces

### What Kubernetes standard NetworkPolicy CANNOT do:
- ❌ **Layer 7** (Application-level): Cannot filter by HTTP path, method, headers
- ❌ **Protocol-specific**: Cannot inspect HTTP, gRPC, Kafka, DNS queries
- ❌ **Cluster-wide policies**: Each policy is namespace-scoped
- ❌ **Advanced CIDR exceptions**: Limited `except` clause support

### What Cilium adds (via eBPF):
- ✅ **L7 HTTP filtering**: Allow only specific endpoints (`GET /health`, `POST /api/users`)
- ✅ **DNS-aware policies**: Allow traffic to `*.example.com` by DNS name
- ✅ **gRPC/Kafka inspection**: Filter by gRPC methods or Kafka topics
- ✅ **CiliumClusterwideNetworkPolicy**: Apply policies across all namespaces
- ✅ **Advanced CIDR sets**: Complex IP allow/deny rules with exceptions
- ✅ **Network observability**: Hubble provides flow visibility

## Current Setup

The Lumen project uses **Flannel CNI** (K3s default), which supports standard NetworkPolicy (`networking.k8s.io/v1`) but **not** CiliumNetworkPolicy.

## To use these files

You need to migrate from Flannel to Cilium CNI. See Phase 8 (future) for migration guide.

### Migration steps (summary):
1. Recreate K3s cluster with `--flannel-backend=none`
2. Install Cilium in airgap mode
3. Configure Cilium to use internal registry
4. Move these files back to `03-airgap-zone/manifests/network-policies/`

## Files

- `06-block-internet-cilium.yaml` - Cluster-wide egress blocking + L7 HTTP filtering for lumen-api

## Learn More

- Cilium: https://cilium.io/
- eBPF: https://ebpf.io/
- Cilium NetworkPolicies: https://docs.cilium.io/en/stable/security/policy/
