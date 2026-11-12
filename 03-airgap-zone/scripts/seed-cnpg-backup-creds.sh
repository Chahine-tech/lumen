#!/bin/bash
# Copy the Garage access key used by the PostgreSQL backups into Vault
#
#   Garage (backup-1) ──key──▶ Vault KV lumen/cnpg-backup ──VSO──▶ Secret lumen-db-backup-s3
#
# The key is created on Garage by the Ansible garage role. This script reads
# it there and writes it to Vault. Secrets travel through pipes only: they
# never appear in a command line (ps), in the terminal, or in a file.
#
# Prerequisites:
#   - backup-1 running Garage (ansible-playbook 04-ansible/site.yml --tags garage)
#   - Vault unsealed, and the cnpg-backup policy + role present (vault-init Job,
#     or the manual commands in docs/runbooks/postgres-backup-restore.md)
#   - A Vault token allowed to write lumen/data/cnpg-backup, in VAULT_TOKEN or
#     typed at the prompt (the bootstrap root token is revoked; see
#     `vault operator generate-root` in docs/vault-cert-manager.md)
#
# Usage: ./seed-cnpg-backup-creds.sh

set -e

GARAGE_VM="backup-1"
GARAGE_CONTAINER="garage"
GARAGE_KEY_NAME="lumen-cnpg-backup"
# Must match s3_region in the Garage config (04-ansible/roles/garage)
S3_REGION="garage"
VAULT_PATH="lumen/cnpg-backup"

garage() {
  multipass exec "$GARAGE_VM" -- sudo docker exec "$GARAGE_CONTAINER" /garage "$@"
}

echo "[1/3] Reading access key ${GARAGE_KEY_NAME} from Garage on ${GARAGE_VM}..."
KEY_ID=$(garage key info "$GARAGE_KEY_NAME" --key-id | tr -d '[:space:]')
SECRET_KEY=$(garage key info "$GARAGE_KEY_NAME" --secret-key | tr -d '[:space:]')
if [ -z "$KEY_ID" ] || [ -z "$SECRET_KEY" ]; then
  echo "  ❌ Could not read the key from Garage"
  exit 1
fi
echo "  ✅ Key ${KEY_ID}"

if [ -z "$VAULT_TOKEN" ]; then
  read -r -s -p "Vault token (input hidden): " VAULT_TOKEN
  echo ""
fi

echo "[2/3] Writing ${VAULT_PATH} to Vault..."
# stdin carries the token on its first line, then the JSON document:
# `read` consumes the first line, `vault kv put ... -` reads the rest
{
  printf '%s\n' "$VAULT_TOKEN"
  KEY_ID="$KEY_ID" SECRET_KEY="$SECRET_KEY" REGION="$S3_REGION" python3 -c \
    'import json,os; print(json.dumps({"ACCESS_KEY_ID": os.environ["KEY_ID"], "ACCESS_SECRET_KEY": os.environ["SECRET_KEY"], "REGION": os.environ["REGION"]}))'
} | multipass exec node-1 -- kubectl exec -i -n vault vault-0 -- sh -c \
  'read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200; vault kv put '"$VAULT_PATH"' - > /dev/null'
echo "  ✅ Written"

echo "[3/3] Waiting for VSO to sync Secret lumen-db-backup-s3..."
for _ in $(seq 1 30); do
  if multipass exec node-1 -- kubectl get secret lumen-db-backup-s3 -n lumen > /dev/null 2>&1; then
    echo "  ✅ Secret lumen-db-backup-s3 present in lumen"
    exit 0
  fi
  sleep 5
done
echo "  ❌ Secret not synced after 150s: kubectl describe vaultstaticsecret lumen-db-backup-credentials -n lumen"
exit 1
