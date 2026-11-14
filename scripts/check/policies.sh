#!/bin/bash
# Kyverno policies: kyverno test on the lumen-* ValidatingPolicies, offline,
# with the CLI of the version deployed (kyverno-helm appVersion).
# 03-airgap-zone/tests/kyverno/cli/kyverno-test.yaml lists the cases.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/check/images.sh
T=03-airgap-zone/tests/kyverno/cli

echo "== kyverno test"
out=$(docker run --rm -v "$PWD:$PWD" -w "$PWD" "$KYVERNO_CLI_IMAGE" test "$T" --remove-color 2>&1) || {
  echo "$out"; exit 1; }
echo "$out" | grep -E '^Test Summary'

# The CLI skips a result whose resource does not exist (a typo in a name):
# every listed resource must have been evaluated
want=$(python3 -c 'import sys,yaml; print(sum(len(r["resources"]) for r in yaml.safe_load(open(sys.argv[1]))["results"]))' "$T/kyverno-test.yaml")
got=$(echo "$out" | sed -n 's/^Test Summary: \([0-9]*\) tests passed and 0 tests failed$/\1/p')
if [ "$got" != "$want" ]; then
  echo "kyverno test evaluated ${got:-?} results, kyverno-test.yaml lists $want: a listed resource is missing from resources.yaml"
  exit 1
fi
