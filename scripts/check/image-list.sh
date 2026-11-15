#!/bin/bash
# Image list: every image the rendered manifests reference (needs
# .cache/rendered from manifests.sh) is in images.yaml, and every entry of
# images.yaml is referenced (issue #31).
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -f .cache/rendered/.charts ] || { echo "run scripts/check/manifests.sh first"; exit 1; }
python3 03-airgap-zone/tests/manifests/image_list.py images.yaml .cache/rendered
