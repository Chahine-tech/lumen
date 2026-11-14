#!/bin/bash
# terraform fmt and validate (providers downloaded into a copy, the working
# directory is left untouched)
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/check/images.sh
docker run --rm -v "$PWD/05-terraform:/tf:ro" -w /tf "$TERRAFORM_IMAGE" fmt -check -recursive -diff
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git ls-files -z 05-terraform | xargs -0 tar -cf - | tar -xf - -C "$tmp"
docker run --rm -v "$tmp/05-terraform:/tf" -w /tf --entrypoint sh "$TERRAFORM_IMAGE" -c \
  'terraform init -backend=false -input=false -no-color >/dev/null && terraform validate -no-color'
