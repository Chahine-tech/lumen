#!/bin/bash
set -e

# Setup /etc/hosts for airgap DNS
# Educational: In production, you'd use real DNS (CoreDNS, Route53, etc.)
# For learning, /etc/hosts works perfectly

HOSTS_FILE="/etc/hosts"
BACKUP_FILE="/etc/hosts.backup.$(date +%Y%m%d_%H%M%S)"
TRAEFIK_IP="192.168.2.100"  # MetalLB LoadBalancer IP

DOMAINS=(
    "traefik.airgap.local"
    "gitea.airgap.local"
    "grafana.airgap.local"
    "prometheus.airgap.local"
    "alertmanager.airgap.local"
    "argocd.airgap.local"
)

echo "====================================="
echo "Setting up DNS for airgap services"
echo "====================================="

# Backup existing hosts file
echo "Creating backup: $BACKUP_FILE"
sudo cp "$HOSTS_FILE" "$BACKUP_FILE"

# Add entries
echo ""
echo "Adding DNS entries to $HOSTS_FILE:"
for DOMAIN in "${DOMAINS[@]}"; do
    # Check if entry exists
    if grep -q "$DOMAIN" "$HOSTS_FILE"; then
        echo "  ⚠️  $DOMAIN already exists, skipping"
    else
        echo "$TRAEFIK_IP    $DOMAIN" | sudo tee -a "$HOSTS_FILE" > /dev/null
        echo "  ✅ Added: $TRAEFIK_IP → $DOMAIN"
    fi
done

echo ""
echo "✅ DNS setup complete!"
echo ""
echo "Test with:"
echo "  ping gitea.airgap.local"
echo "  curl -k https://gitea.airgap.local"
echo ""
echo "To remove entries:"
echo "  sudo sed -i.bak '/airgap.local/d' $HOSTS_FILE"
