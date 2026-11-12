#!/bin/bash
# Prepare backup-1 for Garage: directories and secrets.
# Secrets are generated on the VM and never leave it.
# Prints created=1 when a secret was generated (the container must restart).
set -e

mkdir -p /etc/garage/secrets /var/lib/garage/meta /var/lib/garage/data
chmod 700 /etc/garage/secrets

created=0
for f in rpc_secret admin_token; do
  if [ ! -s "/etc/garage/secrets/$f" ]; then
    openssl rand -hex 32 > "/etc/garage/secrets/$f"
    created=1
  fi
  chmod 600 "/etc/garage/secrets/$f"
done

echo "created=$created"
