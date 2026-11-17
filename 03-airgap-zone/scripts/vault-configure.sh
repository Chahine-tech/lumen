#!/bin/sh
# Vault configuration: engines, PKI, policies, Kubernetes auth roles, seeded
# secrets. Runs IN a Vault pod, streamed by vault-bootstrap.sh on stdin (the
# image has no kubectl), with VAULT_TOKEN, VAULT_ADDR and VAULT_CACERT set
# and, when they exist, AIRGAP_CA_CERT, PG_USER, PG_PASSWORD, PG_DBNAME.
# Idempotent: run again to apply a change (vault-bootstrap.sh configure).
# Formerly the vault-init Job (issue #3).
set -e

# ---------------------------------------------
# Enable KV v2 secrets engine
# ---------------------------------------------
echo "[1/6] Enabling KV v2 engine at path 'lumen/'..."
vault secrets enable -path=lumen kv-v2 || echo "  (already enabled)"
echo "  ok: KV v2 engine ready at lumen/"

# ---------------------------------------------
# Enable and configure PKI engine
# ---------------------------------------------
echo "[2/6] Configuring PKI engine..."
vault secrets enable pki || echo "  (already enabled)"
vault secrets tune -max-lease-ttl=87600h pki

# Import existing airgap CA (ConfigMap vault/airgap-ca, passed by
# vault-bootstrap.sh). Without its key, Vault refuses it: issue #7
echo "  Importing airgap CA into Vault PKI..."
CA_CERT=${AIRGAP_CA_CERT:-}
# If we only have the cert (no key), we configure as external CA
# Vault will act as an intermediate that issues certs signed by airgap CA
vault write pki/config/ca pem_bundle="$CA_CERT" || \
  echo "  WARNING: CA import requires both cert and key: configuring PKI in self-signed mode"

# Configure PKI URLs
vault write pki/config/urls \
  issuing_certificates="https://vault.vault.svc.cluster.local:8200/v1/pki/ca" \
  crl_distribution_points="https://vault.vault.svc.cluster.local:8200/v1/pki/crl"

# Create role for *.airgap.local
vault write pki/roles/airgap-role \
  allowed_domains="airgap.local" \
  allow_subdomains=true \
  allow_bare_domains=true \
  max_ttl="8760h" \
  key_type="rsa" \
  key_bits=2048
echo "  ok: PKI engine configured"

# ---------------------------------------------
# Create policies
# ---------------------------------------------
echo "[3/6] Creating policies..."

# lumen-api policy: read app secrets. PostgreSQL: the runtime role only
# (DML), not the owner credentials of lumen/db
vault policy write lumen-api-policy - <<'POLICY'
path "lumen/data/db-runtime" {
  capabilities = ["read"]
}
path "lumen/data/redis" {
  capabilities = ["read"]
}
POLICY

# lumen-db-owner policy: VSO reads the credentials of the database owner,
# used by the migration Job (manifests/vso/03-lumen-db-secret.yaml)
vault policy write lumen-db-owner-policy - <<'POLICY'
path "lumen/data/db" {
  capabilities = ["read"]
}
POLICY

# cert-manager policy: issue PKI certs
vault policy write cert-manager-policy - <<'POLICY'
path "pki/sign/airgap-role" {
  capabilities = ["create", "update"]
}
path "pki/issue/airgap-role" {
  capabilities = ["create", "update"]
}
POLICY

# traefik-dashboard policy: VSO reads the dashboard htpasswd
# (seeded manually: htpasswd -nbB admin '<pw>' | vault kv put lumen/traefik-dashboard users=-)
vault policy write traefik-dashboard-policy - <<'POLICY'
path "lumen/data/traefik-dashboard" {
  capabilities = ["read"]
}
POLICY

# grafana-admin policy: VSO reads the Grafana admin credentials
vault policy write grafana-admin-policy - <<'POLICY'
path "lumen/data/grafana" {
  capabilities = ["read"]
}
POLICY

# cnpg-backup policy: VSO reads the S3 credentials of the PostgreSQL backups
# (seeded from Garage by scripts/seed-cnpg-backup-creds.sh)
vault policy write cnpg-backup-policy - <<'POLICY'
path "lumen/data/cnpg-backup" {
  capabilities = ["read"]
}
POLICY

# gitea-runner policy: VSO reads the Actions runner registration token
# (seeded from Gitea by scripts/seed-gitea-runner-token.sh)
vault policy write gitea-runner-policy - <<'POLICY'
path "lumen/data/gitea-runner" {
  capabilities = ["read"]
}
POLICY

echo "  ok: Policies created"

# ---------------------------------------------
# Enable Kubernetes auth method
# ---------------------------------------------
echo "[4/6] Configuring Kubernetes auth..."
vault auth enable kubernetes || echo "  (already enabled)"

# Configure Kubernetes auth with in-cluster credentials
# No token_reviewer_jwt: Vault reviews tokens with its own pod's
# ServiceAccount token (mounted, renewed by the kubelet; the chart binds it
# to system:auth-delegator)
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443"

# Every role is bound to one dedicated ServiceAccount, never `default`, and
# to the audience vault (issue #6). Tokens live 15 minutes: VSO logs in
# again when its token expires.

# Role for VSO syncing the Redis password and the PostgreSQL runtime
# credentials in lumen (ServiceAccount lumen-vso, vso/02-vault-auth.yaml)
vault write auth/kubernetes/role/lumen-api \
  bound_service_account_names=lumen-vso \
  bound_service_account_namespaces=lumen \
  audience=vault \
  policies=lumen-api-policy \
  ttl=15m

# Role for cert-manager (cert-manager-vault-auth SA in cert-manager
# namespace), short-lived tokens requested by cert-manager
# (vault/03-vault-issuer.yaml)
vault write auth/kubernetes/role/cert-manager \
  bound_service_account_names=cert-manager-vault-auth \
  bound_service_account_namespaces=cert-manager \
  audience=vault \
  policies=cert-manager-policy \
  ttl=15m

# Role for VSO syncing the Traefik dashboard credentials (traefik namespace)
vault write auth/kubernetes/role/traefik-dashboard \
  bound_service_account_names=traefik-dashboard-vso \
  bound_service_account_namespaces=traefik \
  audience=vault \
  policies=traefik-dashboard-policy \
  ttl=15m

# Role for VSO syncing the Grafana admin credentials (monitoring namespace)
vault write auth/kubernetes/role/grafana-admin \
  bound_service_account_names=grafana-admin-vso \
  bound_service_account_namespaces=monitoring \
  audience=vault \
  policies=grafana-admin-policy \
  ttl=15m

# Role for VSO syncing the PostgreSQL owner credentials (lumen namespace).
# Dedicated ServiceAccount (manifests/vso/03-lumen-db-secret.yaml)
vault write auth/kubernetes/role/lumen-db-owner \
  bound_service_account_names=lumen-db-owner-vso \
  bound_service_account_namespaces=lumen \
  audience=vault \
  policies=lumen-db-owner-policy \
  ttl=15m

# Role for VSO syncing the PostgreSQL backup S3 credentials (lumen namespace).
# Bound to a dedicated ServiceAccount, not `default`
# (manifests/vso/05-cnpg-backup-secret.yaml)
vault write auth/kubernetes/role/cnpg-backup \
  bound_service_account_names=cnpg-backup-vso \
  bound_service_account_namespaces=lumen \
  audience=vault \
  policies=cnpg-backup-policy \
  ttl=15m

# Role for VSO syncing the Gitea Actions runner token (gitea namespace).
# Dedicated ServiceAccount (manifests/vso/06-gitea-runner-secret.yaml)
vault write auth/kubernetes/role/gitea-runner \
  bound_service_account_names=gitea-runner-vso \
  bound_service_account_namespaces=gitea \
  audience=vault \
  policies=gitea-runner-policy \
  ttl=15m

echo "  ok: Kubernetes auth configured"

# ---------------------------------------------
# Audit device and Raft snapshots (issue #4)
# ---------------------------------------------
echo "[5/6] Audit device and Raft snapshot role..."
# Audit log on stdout: Alloy ships the pods' output to Loki, so every
# request (secret reads included, values HMAC'd) is in Loki with
# {namespace="vault"}. Vault refuses requests when no audit device can
# write: stdout does not fill up like a file. docs/runbooks/vault-audit-snapshots.md
if vault audit list 2>/dev/null | grep -q '^stdout/'; then
  echo "  ok: audit device stdout/ already enabled"
else
  vault audit enable -path=stdout file file_path=stdout
fi

# The vault-raft-snapshot CronJob (manifests/vault/07-raft-snapshot.yaml):
# takes the snapshot and reads the Garage key it uploads it with
vault policy write raft-snapshot-policy - <<'POLICY'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
path "lumen/data/vault-snapshot" {
  capabilities = ["read"]
}
POLICY
vault write auth/kubernetes/role/raft-snapshot \
  bound_service_account_names=vault-snapshot \
  bound_service_account_namespaces=vault \
  audience=vault \
  policies=raft-snapshot-policy \
  ttl=15m
echo "  ok: raft-snapshot role (S3 key: 03-airgap-zone/scripts/seed-vault-snapshot-creds.sh)"

# ---------------------------------------------
# Seed PostgreSQL credentials from lumen-db-app
# ---------------------------------------------
echo "[6/6] Seeding PostgreSQL credentials into Vault KV..."
# From the Secret lumen/lumen-db-app, passed by vault-bootstrap.sh
PG_USER=${PG_USER:-}
PG_PASSWORD=${PG_PASSWORD:-}
PG_DBNAME=${PG_DBNAME:-app}

if [ -n "$PG_USER" ] && [ -n "$PG_PASSWORD" ]; then
  vault kv put lumen/db \
    username="$PG_USER" \
    password="$PG_PASSWORD" \
    dbname="$PG_DBNAME"
  echo "  ok: PostgreSQL credentials stored in lumen/db"
else
  echo "  WARNING: lumen-db-app Secret not found or empty: seed manually:"
  echo "       vault kv put lumen/db username=app password=<password> dbname=app"
fi

# Password of lumen_runtime, the DML-only role lumen-api runs as (CNPG
# managed role, cnpg/02-cluster.yaml). Generated only if not already
# seeded; synced by VSO to the Secret lumen-db-runtime, which CNPG applies
echo "  Seeding PostgreSQL runtime role credentials into Vault KV..."
if vault kv get lumen/db-runtime > /dev/null 2>&1; then
  echo "  ok: lumen/db-runtime already seeded, keeping the existing password"
else
  PG_RUNTIME_PASSWORD=$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-32)
  vault kv put lumen/db-runtime username=lumen_runtime password="$PG_RUNTIME_PASSWORD"
  echo "  ok: PostgreSQL runtime credentials stored in lumen/db-runtime"
fi

# Generate the Redis password (only if not already seeded: keeps re-init
# from rotating it under a running cluster). Synced to K8s by VSO
# (lumen-redis-vault Secret), consumed by Redis and lumen-api.
echo "  Seeding Redis password into Vault KV..."
if vault kv get lumen/redis > /dev/null 2>&1; then
  echo "  ok: lumen/redis already seeded: keeping existing password"
else
  REDIS_PASSWORD=$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-32)
  vault kv put lumen/redis password="$REDIS_PASSWORD"
  echo "  ok: Redis password stored in lumen/redis"
fi

# Grafana admin credentials (kube-prometheus-stack reads them via
# grafana.admin.existingSecret -> Secret grafana-admin-vault, synced by VSO)
echo "  Seeding Grafana admin credentials into Vault KV..."
if vault kv get lumen/grafana > /dev/null 2>&1; then
  echo "  ok: lumen/grafana already seeded: keeping existing password"
else
  GRAFANA_PASSWORD=$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-32)
  vault kv put lumen/grafana admin-user="admin" admin-password="$GRAFANA_PASSWORD"
  echo "  ok: Grafana admin credentials stored in lumen/grafana"
fi

