#!/bin/bash
set -e

echo "================================================"
echo "  Airgap Zone - K3s Cluster Setup"
echo "================================================"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
K3S_VERSION="v1.28.5+k3s1"
REGISTRY_HOST="registry.airgap.local"
REGISTRY_PORT="5000"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

echo -e "${YELLOW}[1/7]${NC} Configuring /etc/hosts for registry..."
if ! grep -q "$REGISTRY_HOST" /etc/hosts; then
    echo "192.168.2.2 $REGISTRY_HOST" >> /etc/hosts
    echo -e "${GREEN}✓ Added $REGISTRY_HOST to /etc/hosts${NC}"
else
    echo -e "${GREEN}✓ $REGISTRY_HOST already in /etc/hosts${NC}"
fi

echo -e "${YELLOW}[2/7]${NC} Setting up iptables rules (airgap enforcement)..."
# Allow localhost
iptables -I OUTPUT -o lo -j ACCEPT
iptables -I OUTPUT -d 127.0.0.0/8 -j ACCEPT

# Allow internal networks
iptables -I OUTPUT -d 10.0.0.0/8 -j ACCEPT
iptables -I OUTPUT -d 172.16.0.0/12 -j ACCEPT
iptables -I OUTPUT -d 192.168.0.0/16 -j ACCEPT

# Allow established connections
iptables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Drop everything else (AIRGAP!)
iptables -A OUTPUT -j DROP

echo -e "${GREEN}✓ iptables configured for airgap${NC}"

# Save iptables rules
if command -v iptables-save &> /dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

echo -e "${YELLOW}[3/7]${NC} Testing airgap isolation..."
if timeout 3 curl -s google.com &>/dev/null; then
    echo -e "${RED}✗ WARNING: Internet access still available!${NC}"
else
    echo -e "${GREEN}✓ Airgap verified - no internet access${NC}"
fi

echo -e "${YELLOW}[4/7]${NC} Creating K3s config directory..."
mkdir -p /etc/rancher/k3s
cp ../config/registries.yaml /etc/rancher/k3s/
echo -e "${GREEN}✓ Registry config copied${NC}"

echo -e "${YELLOW}[5/7]${NC} Installing K3s..."
# In a real airgap, you'd have the k3s binary pre-downloaded
# For this demo, we'll download it (simulating a pre-staged binary)
if [ ! -f "/usr/local/bin/k3s" ]; then
    echo "K3s binary not found. In real airgap, this would be pre-staged."
    echo "For demo: curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - --write-kubeconfig-mode 644 --disable traefik"
    echo -e "${YELLOW}Skipping actual install for now...${NC}"
else
    echo -e "${GREEN}✓ K3s already installed${NC}"
fi

echo -e "${YELLOW}[6/7]${NC} Verifying registry configuration..."
cat /etc/rancher/k3s/registries.yaml
echo -e "${GREEN}✓ Registry mirrors configured${NC}"

echo -e "${YELLOW}[7/7]${NC} Creating test script..."
cat > /tmp/test-airgap.sh <<'EOF'
#!/bin/bash
# Test script to verify airgap
echo "Testing internet (should fail):"
timeout 2 curl -s google.com && echo "FAIL: Internet accessible" || echo "PASS: No internet"

echo ""
echo "Testing internal registry (should work):"
timeout 2 curl -s http://registry.airgap.local:5000/v2/ && echo "PASS: Registry accessible" || echo "FAIL: Registry not accessible"
EOF
chmod +x /tmp/test-airgap.sh
echo -e "${GREEN}✓ Test script created at /tmp/test-airgap.sh${NC}"

echo ""
echo -e "${GREEN}================================================"
echo "  Airgap Zone Setup Complete!"
echo "================================================${NC}"
echo ""
echo "Next steps:"
echo "1. Verify airgap: /tmp/test-airgap.sh"
echo "2. Deploy applications: kubectl apply -f manifests/"
echo "3. Apply NetworkPolicies: kubectl apply -f manifests/network-policies/"
echo ""
echo "Note: In production, K3s would be installed from local binary"
