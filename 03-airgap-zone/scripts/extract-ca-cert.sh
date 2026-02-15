#!/bin/bash
set -e

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
CA_OUTPUT_FILE="${CA_OUTPUT_FILE:-./airgap-ca.crt}"

echo "====================================="
echo "Extracting CA certificate from cluster"
echo "====================================="

# Wait for job to complete
echo "Waiting for cert-generation job to complete..."
kubectl wait --for=condition=complete --timeout=120s job/cert-generation -n traefik

# Extract CA certificate
echo "Extracting CA certificate..."
kubectl get configmap airgap-ca -n traefik -o jsonpath='{.data.ca\.crt}' > "$CA_OUTPUT_FILE"

echo ""
echo "✅ CA certificate extracted to: $CA_OUTPUT_FILE"
echo ""
echo "📋 Installation instructions:"
echo ""
echo "macOS:"
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CA_OUTPUT_FILE"
echo ""
echo "Linux (Ubuntu/Debian):"
echo "  sudo cp $CA_OUTPUT_FILE /usr/local/share/ca-certificates/airgap-ca.crt"
echo "  sudo update-ca-certificates"
echo ""
echo "Firefox (all platforms):"
echo "  1. Open Preferences → Privacy & Security → Certificates → View Certificates"
echo "  2. Authorities tab → Import"
echo "  3. Select $CA_OUTPUT_FILE"
echo "  4. Check 'Trust this CA to identify websites'"
echo ""
echo "Chrome/Edge (uses OS trust store):"
echo "  Chrome://settings → Privacy and security → Security → Manage certificates"
echo ""
echo "Verify certificate:"
echo "  openssl x509 -in $CA_OUTPUT_FILE -text -noout"
