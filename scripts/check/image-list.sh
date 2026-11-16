#!/bin/bash
# Image list: every image the rendered manifests reference (needs
# .cache/rendered from manifests.sh) is in mirror.yaml, and every image of
# mirror.yaml is referenced or names the file that uses it (issue #31).
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -f .cache/rendered/.charts ] || { echo "run scripts/check/manifests.sh first"; exit 1; }
python3 03-airgap-zone/tests/manifests/image_list.py mirror.yaml .cache/rendered
