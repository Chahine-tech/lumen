#!/bin/bash
# Import the airgap CA into macOS keychain and configure Git
# Re-run when the cert is regenerated (yearly)
#
# Usage: ./trust-ca.sh

set -e

CA_PATH="/tmp/airgap-ca.crt"
REPO_CA_PATH="$(dirname "$0")/../airgap-ca.crt"

echo "[1/3] Fetching CA from cluster..."
multipass exec node-1 -- kubectl get configmap airgap-ca -n traefik -o jsonpath='{.data.ca\.crt}' > "$CA_PATH"
cp "$CA_PATH" "$REPO_CA_PATH"

echo "[2/3] Importing into macOS system keychain (requires sudo)..."
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA_PATH"

echo "[3/3] Configuring Git to trust the CA..."
git config --global http.sslCAInfo "$REPO_CA_PATH"

echo ""
echo "Done. Restart Chrome/Arc for the change to take effect:"
echo "  Chrome : chrome://restart"
echo "  Arc    : Cmd+Q then relaunch"
