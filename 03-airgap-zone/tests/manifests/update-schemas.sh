#!/bin/bash
# Regenerate schemas/ from the CRDs of the downloaded artifacts, for the kinds
# this repository uses and whose CRDs are not in git. Run after changing one
# of these versions (01-connected-zone/scripts/12-pull-cnpg.sh,
# 07-pull-traefik-images.sh).
set -euo pipefail
cd "$(dirname "$0")"
A=../../../01-connected-zone/artifacts
CNPG=$A/cnpg/manifests/cnpg-1.30.1.yaml
PLUGIN=$A/cnpg/manifests/plugin-barman-cloud-v0.16.0.yaml
TRAEFIK=$A/traefik/helm/traefik-39.0.1.tgz
KINDS="postgresql.cnpg.io/cluster_v1 postgresql.cnpg.io/scheduledbackup_v1
barmancloud.cnpg.io/objectstore_v1 traefik.io/ingressroute_v1alpha1
traefik.io/middleware_v1alpha1 traefik.io/tlsoption_v1alpha1"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$TRAEFIK" -C "$tmp"
python3 crd2schema.py "$tmp/all" "$CNPG" "$PLUGIN" "$tmp"/traefik/crds/*.yaml
rm -rf schemas
for k in $KINDS; do
  mkdir -p "schemas/$(dirname "$k")"
  cp "$tmp/all/$k.json" "schemas/$k.json"
done
echo "schemas/ regenerated:"; find schemas -name '*.json' | sort
