#!/bin/bash
# Misconfigurations: trivy config on what reaches the cluster (needs
# .cache/rendered from manifests.sh), with the checks built into the pinned
# trivy version, without network.
#
# HIGH and CRITICAL findings fail on the sources of this repository (plain
# directories, applied by ArgoCD or by scripts), except the accepted ones of
# 03-airgap-zone/tests/manifests/trivy-ignore.yaml. On the Helm charts
# (.cache/rendered/.charts, upstream content) they are reported only.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/check/images.sh
[ -f .cache/rendered/.charts ] || { echo "run scripts/check/manifests.sh first"; exit 1; }

rm -rf .cache/misconfig && mkdir -p .cache/misconfig/own .cache/misconfig/charts
for f in .cache/rendered/*.yaml; do
  if grep -qxF "$(basename "$f")" .cache/rendered/.charts; then
    cp "$f" .cache/misconfig/charts/
  else
    cp "$f" .cache/misconfig/own/
  fi
done
trivy() {
  docker run --rm --network none -v "$PWD:$PWD:ro" -w "$PWD" "$TRIVY_IMAGE" \
    config --skip-check-update --severity HIGH,CRITICAL --quiet "$@"
}

echo "== trivy config, Helm charts (report only)"
trivy --format json .cache/misconfig/charts | python3 -c '
import collections, json, sys
c = collections.Counter()
for r in json.load(sys.stdin).get("Results", []):
    for m in r.get("Misconfigurations") or []:
        if m["Status"] == "FAIL":
            c[(r["Target"], m["ID"], m["Title"])] += 1
for (t, i, title), n in sorted(c.items()):
    print(f"{n:3} {t} {i} {title}")
print(f"{sum(c.values())} findings, not enforced")'

echo "== trivy config, sources of this repository"
trivy --exit-code 1 --ignorefile 03-airgap-zone/tests/manifests/trivy-ignore.yaml .cache/misconfig/own
echo "no HIGH or CRITICAL finding outside trivy-ignore.yaml"
