#!/bin/bash
# Transit Vault on backup-1 (issue #3): its transit key unseals the cluster's
# Vault at each start. docs/runbooks/vault-auto-unseal.md
#
#   vault-transit.sh init     first time: initialize it, print its unseal
#                             keys and root token ONCE, unseal it, create the
#                             transit key and the cluster's token (Secret
#                             vault/vault-transit-token), revoke the root token
#   vault-transit.sh unseal   after a restart of backup-1: asks for the keys
#   vault-transit.sh token    a new token for the cluster (the current one
#                             expires after 32 days without renewal, e.g. a
#                             cluster stopped that long); asks for a token
#                             with the policy below, e.g. from
#                             `vault operator generate-root`
#
# Keys and tokens go through stdin, never on a command line.
#
# TRANSIT_EXEC   runs a command in the transit Vault container, stdin attached
#                (default: multipass exec backup-1 -- sudo docker exec -i vault-transit)
# KUBECTL        default: multipass exec node-1 -- kubectl
# CLUSTER_CIDRS  addresses the cluster's token is valid from: the nodes, which
#                the pods' traffic leaves from (default 192.168.2.2/32,192.168.2.3/32)
set -euo pipefail

TRANSIT_EXEC=${TRANSIT_EXEC:-multipass exec backup-1 -- sudo docker exec -i vault-transit}
KUBECTL=${KUBECTL:-multipass exec node-1 -- kubectl}
CLUSTER_CIDRS=${CLUSTER_CIDRS:-192.168.2.2/32,192.168.2.3/32}
KEY_SHARES=3
KEY_THRESHOLD=2

# vault CLI in the container, against its own listener
tv() {
  # shellcheck disable=SC2086
  $TRANSIT_EXEC env VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/config/ca.crt "$@"
}

# tv_token TOKEN CMD...: CMD with VAULT_TOKEN read from stdin
tv_token() {
  local token=$1
  shift
  printf '%s\n' "$token" | tv sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec "$@"' sh "$@"
}

# vault status exits 2 when sealed: read its output, not its exit code.
# Stdin from /dev/null: docker exec -i would otherwise read the input of the caller
status() {
  tv vault status -format=json < /dev/null 2>/dev/null || true
}

sealed() {
  status | grep -q '"sealed": true'
}

unseal_key() {
  printf '{"key":"%s"}' "$1" | tv vault write -format=json sys/unseal - > /dev/null
}

# store_token TOKEN: Secret vault/vault-transit-token, read by the Vault pods
# (vault-helm/values-airgap-override.yaml, seal "transit")
store_token() {
  local b64
  b64=$(printf '%s' "$1" | base64 | tr -d '\n')
  # shellcheck disable=SC2086
  $KUBECTL apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-transit-token
  namespace: vault
type: Opaque
data:
  token: $b64
EOF
}

# cluster_token ADMIN_TOKEN: a token of the role lumen-autounseal (init):
# periodic, limited to the transit key, usable from the cluster nodes only
cluster_token() {
  tv_token "$1" vault token create -role=lumen-autounseal -display-name=lumen-vault -field=token
}

init() {
  if status | grep -q '"initialized": true'; then
    echo "The transit Vault is already initialized" >&2
    exit 1
  fi
  local out keys root
  out=$(tv vault operator init -key-shares=$KEY_SHARES -key-threshold=$KEY_THRESHOLD -format=json < /dev/null)
  keys=$(printf '%s' "$out" | grep -A$KEY_SHARES '"unseal_keys_b64"' | grep -o '"[A-Za-z0-9+/=]\{20,\}"' | tr -d '"')
  root=$(printf '%s' "$out" | grep -o '"root_token": *"[^"]*"' | cut -d'"' -f4)
  [ -n "$keys" ] && [ -n "$root" ] || { echo "vault operator init: unexpected output" >&2; exit 1; }

  echo "Transit Vault unseal keys ($KEY_THRESHOLD of $KEY_SHARES unseal it). Shown once,"
  echo "stored nowhere: give each one to a different holder, offline."
  printf '%s\n' "$keys" | nl -w1 -s': '
  echo
  local n=0
  for k in $keys; do
    [ $n -lt $KEY_THRESHOLD ] || break
    unseal_key "$k"
    n=$((n + 1))
  done

  tv_token "$root" vault secrets enable transit > /dev/null
  tv_token "$root" vault write -f transit/keys/lumen-vault > /dev/null
  printf '%s\n' "$root" | tv sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault policy write lumen-autounseal - > /dev/null <<P
path "transit/encrypt/lumen-vault" { capabilities = ["update"] }
path "transit/decrypt/lumen-vault" { capabilities = ["update"] }
P'
  tv_token "$root" vault write auth/token/roles/lumen-autounseal \
    allowed_policies=lumen-autounseal orphan=true token_period=768h \
    token_bound_cidrs="$CLUSTER_CIDRS" > /dev/null
  store_token "$(cluster_token "$root")"
  tv_token "$root" vault token revoke -self > /dev/null
  echo "Transit key lumen-vault and the cluster's token ready; root token revoked."
}

unseal() {
  if ! sealed; then
    echo "The transit Vault is not sealed"
    return
  fi
  local key
  while sealed; do
    read -r -s -p "Transit Vault unseal key (input hidden): " key
    echo
    unseal_key "$key"
  done
  echo "Unsealed. The cluster's Vault pods unseal themselves at their next restart (up to 5 min)."
}

token() {
  local admin
  read -r -s -p "Transit Vault token allowed to create tokens of the role lumen-autounseal (input hidden): " admin
  echo
  store_token "$(cluster_token "$admin")"
  echo "Secret vault/vault-transit-token replaced. Restart the Vault pods one at a time to use it."
}

case "${1:-}" in
  init) init ;;
  unseal) unseal ;;
  token) token ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
