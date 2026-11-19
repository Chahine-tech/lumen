#!/bin/bash
# Prometheus rules: promtool check rules on every PrometheusRule that reaches
# the cluster (needs .cache/rendered from manifests.sh), the alert unit tests,
# and the SLO rules regenerated from their Sloth spec without a diff.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/check/images.sh
[ -d .cache/rendered ] || { echo "run scripts/check/manifests.sh first"; exit 1; }

echo "== promtool check rules"
rm -rf .cache/rules
python3 03-airgap-zone/tests/manifests/extract-rules.py .cache/rules .cache/rendered/*.yaml
docker run --rm -v "$PWD/.cache/rules:/r" -w /r --entrypoint sh "$PROMETHEUS_IMAGE" -c 'promtool check rules *.yml'

echo "== every alert of this repository links to a runbook"
python3 - 03-airgap-zone/manifests/kube-prometheus-stack/*-rules.yaml <<'PY'
import sys, yaml
missing = [r["alert"] for f in sys.argv[1:] for d in yaml.safe_load_all(open(f)) if d
           for g in d["spec"]["groups"] for r in g["rules"]
           if "alert" in r and "runbook_url" not in r.get("annotations", {})]
if missing:
    sys.exit(f"alerts without runbook_url: {missing}")
print("ok")
PY

echo "== promtool test rules"
mkdir -p 03-airgap-zone/tests/prometheus/.rules
for r in cnpg-backup-rules postgres-rules redis-rules certificate-rules argocd-rules vault-rules kafka-rules; do
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); yaml.safe_dump({"groups": d["spec"]["groups"]}, open(sys.argv[2], "w"))' \
    "03-airgap-zone/manifests/kube-prometheus-stack/$r.yaml" \
    "03-airgap-zone/tests/prometheus/.rules/$r.yml"
done
docker run --rm -v "$PWD/03-airgap-zone/tests/prometheus:/w" -w /w --entrypoint promtool \
  "$PROMETHEUS_IMAGE" test rules cnpg-backup-rules.test.yml postgres-rules.test.yml redis-rules.test.yml certificate-rules.test.yml argocd-rules.test.yml vault-rules.test.yml kafka-rules.test.yml

echo "== SLO rules up to date with 03-airgap-zone/slo (make slo-generate)"
rm -rf .cache/slo && mkdir -p .cache/slo
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/03-airgap-zone:/work:ro" -v "$PWD/.cache/slo:/out" "$SLOTH_IMAGE" generate \
  -i /work/slo/lumen-api.yaml -o /out/lumen-api-slo-rules.yaml >/dev/null
diff -u 03-airgap-zone/manifests/kube-prometheus-stack/lumen-api-slo-rules.yaml .cache/slo/lumen-api-slo-rules.yaml
echo "SLO rules up to date"
