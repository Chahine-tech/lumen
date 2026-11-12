#!/bin/bash
# Copy the Gitea Actions runner registration token into Vault
#
#   Gitea ──token──▶ Vault KV lumen/gitea-runner ──VSO──▶ Secret gitea/gitea-runner-token ──▶ runner
#
# `gitea actions generate-runner-token` (Gitea 1.21) returns the CURRENT
# active token, it does not create a new one (checked on gitea/gitea:1.21.5,
# 2026-11-12). To rotate, reset the token first in the Gitea UI: Site
# Administration > Actions > Runners > Create new runner > Reset registration
# token. Then run this script.
#
# The token travels through pipes only (never in a command line or the
# terminal). Its trailing newline is removed: `vault kv put key=-` keeps it,
# and the runner would fail to register with it.
# In the Vault pod, stdin is read with `cat` before `vault kv put`: fed through
# `kubectl exec -i`, vault stored an EMPTY value (exit code 0) when the data
# arrived about a second late, as Gitea's output does (k3d test, 2026-11-12).
#
# Prerequisites: Vault unsealed, the gitea-runner policy + role present
# (vault-init Job, or docs/runbooks/rotate-leaked-credentials.md), and a
# Vault token allowed to write lumen/data/gitea-runner in VAULT_TOKEN or typed
# at the prompt.
#
# Usage: ./seed-gitea-runner-token.sh

set -e

VAULT_PATH="lumen/gitea-runner"
KUBECTL="multipass exec node-1 -- kubectl"

if [ -z "$VAULT_TOKEN" ]; then
  read -r -s -p "Vault token (input hidden): " VAULT_TOKEN
  echo ""
fi

echo "[1/3] Reading the active runner registration token from Gitea and writing ${VAULT_PATH}..."
# Kept in a shell variable (not a command line), so that what VSO syncs can be
# compared with it below
TOKEN=$($KUBECTL exec -n gitea deploy/gitea -- \
  su git -c 'gitea --config /data/gitea/conf/app.ini actions generate-runner-token' | tr -d '\r\n')
if [ -z "$TOKEN" ]; then
  echo "  ❌ Gitea returned no token"
  exit 1
fi
WANT=$(printf '%s' "$TOKEN" | shasum -a 256 | cut -d' ' -f1)
printf '%s\n%s' "$VAULT_TOKEN" "$TOKEN" | $KUBECTL exec -i -n vault vault-0 -- sh -c \
  'read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
   V=$(cat); [ -n "$V" ] || { echo "empty token, nothing written" >&2; exit 1; }
   printf "%s" "$V" | vault kv put '"$VAULT_PATH"' token=- > /dev/null'
unset TOKEN
echo "  ✅ Written"

echo "[2/3] Making VSO sync the new token into Secret gitea-runner-token..."
# VSO re-reads Vault only every refreshAfter (1h): a new value is not picked
# up on its own. Deleting the Secret makes VSO recreate it from Vault within
# seconds (k3d test, VSO 1.3.0, 2026-11-12). Then wait until the Secret is
# owned by VSO (label app.kubernetes.io/managed-by=hashicorp-vso, see
# helpers/secrets.go) AND holds the token written above.
$KUBECTL delete secret gitea-runner-token -n gitea --ignore-not-found > /dev/null
synced=0
for _ in $(seq 1 30); do
  owner=$($KUBECTL get secret gitea-runner-token -n gitea \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
  have=$($KUBECTL get secret gitea-runner-token -n gitea -o jsonpath='{.data.token}' 2>/dev/null \
    | base64 -d | shasum -a 256 | cut -d' ' -f1)
  if [ "$owner" = "hashicorp-vso" ] && [ "$have" = "$WANT" ]; then
    synced=1
    echo "  ✅ Secret managed by VSO, holds the new token"
    break
  fi
  sleep 5
done
if [ "$synced" != 1 ]; then
  echo "  ❌ Secret not synced after 150s:"
  echo "     kubectl describe vaultstaticsecret gitea-runner-token -n gitea"
  exit 1
fi

echo "[3/3] Restarting the runner so it registers with the token..."
$KUBECTL rollout restart deployment/gitea-runner -n gitea
$KUBECTL rollout status deployment/gitea-runner -n gitea --timeout=180s
echo ""
echo "Check the runner list in Gitea (Site Administration > Actions > Runners):"
echo "only k8s-runner should be there."
