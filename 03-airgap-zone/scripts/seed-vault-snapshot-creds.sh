#!/bin/bash
# Copy the Garage access key used by the Vault Raft snapshots into Vault
# (issue #4)
#
#   Garage (backup-1) --key--> Vault KV lumen/vault-snapshot --> CronJob vault-raft-snapshot
#
# The CronJob (manifests/vault/07-raft-snapshot.yaml) reads it at each run:
# no Kubernetes Secret.
#
# The key is created on Garage by the Ansible garage role. This script reads
# it there and writes it to Vault. Secrets travel through pipes only: they
# never appear in a command line (ps), in the terminal, or in a file.
#
# Prerequisites:
#   - backup-1 running Garage (ansible-playbook 04-ansible/site.yml --tags garage)
#   - Vault unsealed and configured (vault-bootstrap.sh)
#   - A Vault token allowed to write lumen/data/vault-snapshot, in VAULT_TOKEN or
#     typed at the prompt (the bootstrap root token is revoked; see
#     `vault operator generate-root`, docs/runbooks/vault-auto-unseal.md)
#
# Usage: ./seed-vault-snapshot-creds.sh

set -e

GARAGE_VM="backup-1"
GARAGE_CONTAINER="garage"
GARAGE_KEY_NAME="lumen-vault-snapshot"
# Must match s3_region in the Garage config (04-ansible/roles/garage)
S3_REGION="garage"
VAULT_PATH="lumen/vault-snapshot"

garage() {
  # RUST_LOG=warn: the CLI logs its RPC connection at INFO level on stderr
  multipass exec "$GARAGE_VM" -- sudo docker exec -e RUST_LOG=warn "$GARAGE_CONTAINER" /garage "$@"
}

echo "[1/2] Reading access key ${GARAGE_KEY_NAME} from Garage on ${GARAGE_VM}..."
KEY_ID=$(garage key info "$GARAGE_KEY_NAME" --key-id | tr -d '[:space:]')
SECRET_KEY=$(garage key info "$GARAGE_KEY_NAME" --secret-key | tr -d '[:space:]')
if [ -z "$KEY_ID" ] || [ -z "$SECRET_KEY" ]; then
  echo "  error: Could not read the key from Garage"
  exit 1
fi
echo "  ok: Key ${KEY_ID}"

if [ -z "$VAULT_TOKEN" ]; then
  read -r -s -p "Vault token (input hidden): " VAULT_TOKEN
  echo ""
fi

echo "[2/2] Writing ${VAULT_PATH} to Vault..."
# stdin carries the token on its first line, then the JSON document:
# `read` consumes the first line, `cat` the rest (vault reading a slow
# `kubectl exec -i` stdin itself stored empty values, see seed-gitea-runner-token.sh)
{
  printf '%s\n' "$VAULT_TOKEN"
  KEY_ID="$KEY_ID" SECRET_KEY="$SECRET_KEY" REGION="$S3_REGION" python3 -c \
    'import json,os; print(json.dumps({"ACCESS_KEY_ID": os.environ["KEY_ID"], "ACCESS_SECRET_KEY": os.environ["SECRET_KEY"], "REGION": os.environ["REGION"]}))'
} | multipass exec node-1 -- kubectl exec -i -n vault vault-0 -- sh -c \
  'read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=https://127.0.0.1:8200
   V=$(cat); [ -n "$V" ] || { echo "empty document, nothing written" >&2; exit 1; }
   printf "%s" "$V" | vault kv put '"$VAULT_PATH"' - > /dev/null'
echo "  ok: Written"
