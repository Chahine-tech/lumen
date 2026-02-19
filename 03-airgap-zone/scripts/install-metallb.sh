#!/bin/bash
# Bootstrap script — MetalLB v0.15.3 installation (airgap)
#
# MetalLB is a bootstrap component like ArgoCD:
# it must be installed BEFORE GitOps is operational.
# Boot order: MetalLB → Traefik (LB IP) → Ingress → ArgoCD → everything else
#
# Prerequisites:
# - K3s installed with --disable=servicelb flag (no built-in LB)
# - Docker registry running on node-1 at 192.168.2.2:5000
# - MetalLB images already pushed to local registry
#
# Images needed in registry:
#   192.168.2.2:5000/metallb/controller:v0.15.3
#   192.168.2.2:5000/metallb/speaker:v0.15.3
#   192.168.2.2:5000/frrouting/frr:9.1.0

set -e

METALLB_VERSION="0.15.3"
REGISTRY="192.168.2.2:5000"
NAMESPACE="metallb-system"

echo "[1/3] Installing MetalLB via Helm (airgap)..."
multipass exec node-1 -- helm install metallb metallb/metallb \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${METALLB_VERSION}" \
  --set controller.image.repository="${REGISTRY}/metallb/controller" \
  --set controller.image.tag="v${METALLB_VERSION}" \
  --set speaker.image.repository="${REGISTRY}/metallb/speaker" \
  --set speaker.image.tag="v${METALLB_VERSION}" \
  --set speaker.frr.image.repository="${REGISTRY}/frrouting/frr" \
  --set speaker.frr.image.tag="9.1.0" \
  --wait

echo "[2/3] Applying IP pool and L2 advertisement config..."
multipass exec node-1 -- kubectl apply -f /manifests/metallb/01-ipaddresspool.yaml
multipass exec node-1 -- kubectl apply -f /manifests/metallb/02-l2advertisement.yaml

echo "[3/3] Verifying MetalLB..."
multipass exec node-1 -- kubectl get pods -n "${NAMESPACE}"
multipass exec node-1 -- kubectl get ipaddresspool -n "${NAMESPACE}"

echo ""
echo "MetalLB ready. IP pool: 192.168.2.100-192.168.2.200"
echo "Traefik LoadBalancer will get IP: 192.168.2.100"
echo ""
echo "macOS ARP entry needed (lost on reboot):"
echo "  sudo arp -s 192.168.2.100 \$(multipass exec node-1 -- cat /sys/class/net/eth0/address)"
