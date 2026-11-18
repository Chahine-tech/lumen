#!/bin/bash
# Copy the token Alertmanager publishes to ntfy with into Vault (issue #23)
#
#   ntfy (backup-1) --token--> Vault KV lumen/alertmanager-ntfy --> VSO --> Alertmanager
#
# The token is created on backup-1 by the Ansible ntfy role. It travels through
# pipes only: it never appears in a command line (ps), in the terminal, or in
# a file.
#
# Prerequisites:
#   - backup-1 running ntfy (ansible-playbook 04-ansible/site.yml --tags ntfy)
#   - Vault unsealed and configured (vault-bootstrap.sh)
#   - A Vault token allowed to write lumen/data/alertmanager-ntfy, in
#     VAULT_TOKEN or typed at the prompt
#
# Usage: ./seed-ntfy-token.sh

set -e

NTFY_VM="backup-1"
VAULT_PATH="lumen/alertmanager-ntfy"

echo "[1/2] Reading the Alertmanager token on ${NTFY_VM}..."
# shellcheck disable=SC2016  # expanded on backup-1
TOKEN=$(multipass exec "$NTFY_VM" -- sudo sh -c '. /etc/ntfy/secrets.env; printf %s "$ALERTMANAGER_TOKEN"')
if [ -z "$TOKEN" ]; then
  echo "  error: no token in /etc/ntfy/secrets.env"
  exit 1
fi
echo "  ok: Read"

if [ -z "$VAULT_TOKEN" ]; then
  read -r -s -p "Vault token (input hidden): " VAULT_TOKEN
  echo ""
fi

echo "[2/2] Writing ${VAULT_PATH} to Vault..."
# stdin carries the Vault token on its first line, then the JSON document
{
  printf '%s\n' "$VAULT_TOKEN"
  TOKEN="$TOKEN" python3 -c 'import json,os; print(json.dumps({"token": os.environ["TOKEN"]}))'
} | multipass exec node-1 -- kubectl exec -i -n vault vault-0 -- sh -c \
  'read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=https://127.0.0.1:8200
   V=$(cat); [ -n "$V" ] || { echo "empty document, nothing written" >&2; exit 1; }
   printf "%s" "$V" | vault kv put '"$VAULT_PATH"' - > /dev/null'
echo "  ok: Written"
