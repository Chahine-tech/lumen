#!/bin/bash
# Kubernetes compatibility check for CloudNativePG operator versions.
# Sourced by install-cnpg.sh and upgrade-cnpg.sh.
#
# Ranges are the "Supported Kubernetes versions" column of
# docs/src/supported_releases.md in the CloudNativePG repository (v1.30.1).
# Outside the range the operator is not tested by its maintainers: CRDs can
# fail to apply, and the Barman Cloud sidecar is a native sidecar container
# (initContainer with restartPolicy: Always), which K3s 1.28 does not enable.

# Prints "<min> <max>" (Kubernetes minor versions) for a CNPG version
cnpg_k8s_range() {
  case "$1" in
    1.25.*) echo "29 32" ;;
    1.26.*) echo "30 33" ;;
    1.27.*) echo "31 33" ;;
    1.28.*) echo "32 35" ;;
    1.29.*) echo "33 35" ;;
    1.30.*) echo "34 36" ;;
    *) return 1 ;;
  esac
}

# Prints the minor version of the API server (e.g. "34" for v1.34.2+k3s1)
k8s_server_minor() {
  $KUBECTL version -o json | python3 -c \
    'import json,sys; print(int(json.load(sys.stdin)["serverVersion"]["minor"].rstrip("+")))'
}

# Fails unless the cluster runs a Kubernetes version supported by the given
# CNPG version. ALLOW_UNSUPPORTED_K8S=1 downgrades the failure to a warning.
require_k8s_for_cnpg() {
  local cnpg_version="$1" range min max minor
  if ! range=$(cnpg_k8s_range "$cnpg_version"); then
    echo "  ❌ No Kubernetes range known for CNPG ${cnpg_version}: update lib/cnpg-compat.sh"
    return 1
  fi
  read -r min max <<< "$range"
  minor=$(k8s_server_minor)
  if [ "$minor" -ge "$min" ] && [ "$minor" -le "$max" ]; then
    echo "  ✅ Kubernetes 1.${minor} is supported by CNPG ${cnpg_version} (1.${min} to 1.${max})"
    return 0
  fi
  echo "  ❌ Kubernetes 1.${minor} is outside the range supported by CNPG ${cnpg_version} (1.${min} to 1.${max})"
  if [ "${ALLOW_UNSUPPORTED_K8S:-0}" = "1" ]; then
    echo "  ⚠️  ALLOW_UNSUPPORTED_K8S=1: continuing anyway"
    return 0
  fi
  echo "     Upgrade K3s first (see docs/runbooks/postgres-backup-restore.md), or set ALLOW_UNSUPPORTED_K8S=1"
  return 1
}
