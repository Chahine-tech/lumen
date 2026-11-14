#!/bin/bash
# shellcheck on every tracked shell script, warnings and errors (notes are
# reported by `shellcheck` run by hand, not enforced)
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/check/images.sh
git ls-files -z '*.sh' | xargs -0 docker run --rm -v "$PWD:/mnt" -w /mnt "$SHELLCHECK_IMAGE" -S warning
echo "shellcheck: $(git ls-files '*.sh' | wc -l | tr -d ' ') scripts, no warning"
