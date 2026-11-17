#!/bin/bash
# Initialize and configure the cluster's Vault (issue #3), from the
# operator's workstation. Replaces the vault-init Job.
# docs/runbooks/vault-auto-unseal.md
#
#   vault-bootstrap.sh init        first start: vault operator init, prints the
#                                  recovery keys ONCE (stored nowhere), waits
#                                  for the pods to unseal themselves (transit),
#                                  configures Vault, revokes the root token
#   vault-bootstrap.sh configure   apply vault-configure.sh again; asks for a
#                                  token with the rights to (e.g. from
#                                  `vault operator generate-root`)
#
# Prerequisites: the transit Vault initialized and unsealed
# (vault-transit.sh), the Secret vault/vault-transit-token, Vault's
# certificate (docs/runbooks/vault-tls.md).
#
# vault-configure.sh runs in the vault-0 pod: it is streamed on stdin with
# the token and the values it seeds (CA certificate, PostgreSQL credentials
# from lumen/lumen-db-app). Nothing goes on a command line.
#
# KUBECTL overrides the kubectl command (default: multipass exec node-1 -- kubectl).
set -euo pipefail

KUBECTL=${KUBECTL:-multipass exec node-1 -- kubectl}
HERE=$(cd "$(dirname "$0")" && pwd)
RECOVERY_SHARES=5
RECOVERY_THRESHOLD=3

k() {
  # shellcheck disable=SC2086
  $KUBECTL "$@"
}

# vault status exits 2 when sealed: read its output, not its exit code
status() {
  k exec -n vault vault-0 -- vault status -format=json < /dev/null 2>/dev/null || true
}

# with_token TOKEN CMD...: CMD in vault-0, VAULT_TOKEN read from stdin
with_token() {
  local token=$1
  shift
  printf '%s\n' "$token" | k exec -i -n vault vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec "$@"' sh "$@"
}

# export_line NAME VALUE: a shell line that sets NAME, the value base64
# encoded so that no quoting can break it
export_line() {
  printf "%s=\$(echo '%s' | base64 -d); export %s\n" "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')" "$1"
}

secret_value() {
  k get secret "$1" -n "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true
}

configure() {
  local token=$1 ca pg_user pg_password pg_dbname
  ca=$(k get configmap airgap-ca -n vault -o 'jsonpath={.data.ca\.crt}' 2>/dev/null || true)
  pg_user=$(secret_value lumen-db-app lumen user)
  pg_password=$(secret_value lumen-db-app lumen password)
  pg_dbname=$(secret_value lumen-db-app lumen dbname)
  {
    printf '%s\n' "$token"
    export_line AIRGAP_CA_CERT "$ca"
    export_line PG_USER "$pg_user"
    export_line PG_PASSWORD "$pg_password"
    export_line PG_DBNAME "${pg_dbname:-app}"
    cat "$HERE/vault-configure.sh"
  } | k exec -i -n vault vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh -s'
}

wait_unsealed() {
  echo "Waiting for the Vault pods to unseal themselves (transit)..."
  local ready
  for _ in $(seq 60); do
    ready=$(k get pods -n vault -l component=server -o 'jsonpath={.items[*].status.containerStatuses[0].ready}')
    if [ -n "$ready" ] && ! printf '%s' "$ready" | grep -q false; then
      echo "  all ready: $ready"
      return
    fi
    sleep 5
  done
  echo "The Vault pods are not all ready after 5 min: kubectl get pods -n vault" >&2
  exit 1
}

init() {
  if status | grep -q '"initialized": true'; then
    echo "Vault is already initialized: $0 configure applies the configuration again" >&2
    exit 1
  fi
  local out keys root
  out=$(k exec -n vault vault-0 -- vault operator init \
    -recovery-shares=$RECOVERY_SHARES -recovery-threshold=$RECOVERY_THRESHOLD -format=json)
  keys=$(printf '%s' "$out" | grep -A$RECOVERY_SHARES '"recovery_keys_b64"' | grep -o '"[A-Za-z0-9+/=]\{20,\}"' | tr -d '"')
  root=$(printf '%s' "$out" | grep -o '"root_token": *"[^"]*"' | cut -d'"' -f4)
  [ -n "$keys" ] && [ -n "$root" ] || { echo "vault operator init: unexpected output" >&2; exit 1; }

  echo "Vault recovery keys ($RECOVERY_THRESHOLD of $RECOVERY_SHARES: generate-root, seal migration)."
  echo "Shown once, stored nowhere: give each one to a different holder, offline."
  printf '%s\n' "$keys" | nl -w1 -s': '
  echo

  wait_unsealed
  configure "$root"
  with_token "$root" vault token revoke -self > /dev/null
  echo "Configured; root token revoked. A new one: vault operator generate-root (recovery keys)."
}

case "${1:-}" in
  init) init ;;
  configure)
    read -r -s -p "Vault token (input hidden): " token
    echo
    configure "$token"
    ;;
  *) sed -n '2,22p' "$0"; exit 2 ;;
esac
