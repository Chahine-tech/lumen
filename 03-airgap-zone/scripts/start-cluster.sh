#!/bin/bash
# Start the Lumen airgap cluster after a Mac or VM reboot
#
# Run this script every time you restart your Mac or the VMs.
# It handles everything that doesn't survive reboots:
#   1. Start Multipass VMs (backup-1, then node-1 and node-2)
#   2. Restore ARP entry for MetalLB IP (192.168.2.100)

set -e

METALLB_IP="192.168.2.100"

echo "=== Lumen Cluster Startup ==="
echo ""

echo "[1/2] Starting Multipass VMs..."
# backup-1 first: PostgreSQL archives WAL to Garage as soon as it starts
multipass start backup-1
multipass start node-1 node-2
echo "Waiting for nodes to be Ready..."
until multipass exec node-1 -- kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; do
  sleep 3
done
multipass exec node-1 -- kubectl get nodes
echo ""

echo "[2/2] Restoring ARP entry for MetalLB ($METALLB_IP)..."
NODE1_MAC=$(multipass exec node-1 -- cat /sys/class/net/eth0/address)
sudo arp -s "$METALLB_IP" "$NODE1_MAC"
echo "ARP entry: $METALLB_IP -> $NODE1_MAC"
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
