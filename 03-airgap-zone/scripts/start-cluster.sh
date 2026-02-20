#!/bin/bash
# Start the Lumen airgap cluster after a Mac or VM reboot
#
# Run this script every time you restart your Mac or the VMs.
# It handles everything that doesn't survive reboots:
#   1. Start Multipass VMs
#   2. Restore ARP entry for MetalLB IP (192.168.2.100)
#   3. Reinstall OPA Gatekeeper (bootstrap component, not in ArgoCD)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/opa"
METALLB_IP="192.168.2.100"

echo "=== Lumen Cluster Startup ==="
echo ""

echo "[1/3] Starting Multipass VMs..."
multipass start node-1 node-2
echo "Waiting for nodes to be Ready..."
until multipass exec node-1 -- kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; do
  sleep 3
done
multipass exec node-1 -- kubectl get nodes
echo ""

echo "[2/3] Restoring ARP entry for MetalLB ($METALLB_IP)..."
NODE1_MAC=$(multipass exec node-1 -- cat /sys/class/net/eth0/address)
sudo arp -s "$METALLB_IP" "$NODE1_MAC"
echo "ARP entry: $METALLB_IP -> $NODE1_MAC"
echo ""

echo "[3/3] Reinstalling OPA Gatekeeper..."
multipass exec node-1 -- kubectl apply -f - < "${MANIFESTS_DIR}/01-gatekeeper-install.yaml" 2>&1 | tail -3
echo "Waiting for Gatekeeper pods..."
multipass exec node-1 -- kubectl wait --for=condition=Ready pods \
  -l control-plane=controller-manager \
  -n gatekeeper-system \
  --timeout=120s
sleep 15
for f in 02-constraint-template-registry.yaml 03-constraint-template-labels.yaml 04-constraint-template-resources.yaml 05-constraint-template-no-latest.yaml; do
  multipass exec node-1 -- kubectl apply -f - < "${MANIFESTS_DIR}/$f" 2>&1 | grep -v "unchanged" || true
done
echo ""

echo "=== Cluster ready ==="
echo ""
multipass exec node-1 -- kubectl get nodes
echo ""
multipass exec node-1 -- kubectl get applications -n argocd --no-headers 2>/dev/null | awk '{print $1, $2, $3}' || true
echo ""
echo "Services:"
echo "  https://argocd.airgap.local"
echo "  https://grafana.airgap.local"
echo "  https://gitea.airgap.local"
echo "  https://traefik.airgap.local/dashboard/"
