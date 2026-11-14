#!/bin/bash
# ansible-lint, production profile (04-ansible/.ansible-lint)
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/check/images.sh
docker run --rm -v "$PWD:/repo:ro" -w /repo/04-ansible "$PYTHON_IMAGE" sh -c \
  "pip install -q --disable-pip-version-check --root-user-action=ignore ansible-lint==$ANSIBLE_LINT_VERSION ansible-core==$ANSIBLE_CORE_VERSION >/dev/null && ansible-lint --nocolor"
