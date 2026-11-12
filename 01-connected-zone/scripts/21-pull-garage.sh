#!/bin/bash
# Pull Garage v2.5.0 for airgap transfer
# Run this in the CONNECTED zone (internet access required)
#
# Garage is the S3-compatible object store that receives the PostgreSQL
# backups (Barman Cloud plugin). It runs on its own VM, backup-1, outside the
# K3s cluster: the image is loaded there with `docker load` by the Ansible
# garage role, so it does not depend on the registry on node-1.
set -e

GARAGE_VERSION="v2.5.0"
# Multi-arch index digest of dxflrs/garage:v2.5.0 (Docker Hub, checked 2026-11-12)
GARAGE_DIGEST="sha256:677e5b758e4425a325b811c425c026bf35a4bf42f7ddbaa773de3f4fd779a5a5"
ARTIFACTS_DIR="$(cd "$(dirname "$0")/../../artifacts" && pwd)/garage"

IMAGE="dxflrs/garage:${GARAGE_VERSION}"

echo "=== Garage ${GARAGE_VERSION}: Connected Zone Pull ==="
echo ""

mkdir -p "${ARTIFACTS_DIR}/images"

echo "[1/1] Pulling Garage image (ARM64, pinned by digest)..."
docker pull --platform linux/arm64 "${IMAGE}@${GARAGE_DIGEST}"
# Pulling by digest leaves the image untagged; tag it so the VM can run it by name
docker tag "${IMAGE}@${GARAGE_DIGEST}" "${IMAGE}"
docker save "${IMAGE}" -o "${ARTIFACTS_DIR}/images/garage-${GARAGE_VERSION}.tar"
echo "${IMAGE}@${GARAGE_DIGEST}" > "${ARTIFACTS_DIR}/images.txt"
echo "  Saved: garage-${GARAGE_VERSION}.tar"
echo ""

echo "=== Done ==="
echo ""
echo "Artifacts saved to: ${ARTIFACTS_DIR}"
echo ""
echo "Next steps:"
echo "  1. Transfer artifacts/ to the airgap side (USB key, secure copy)"
echo "  2. Run: ansible-playbook 04-ansible/site.yml --tags garage"
