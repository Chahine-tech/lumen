#!/bin/bash
set -e

# Target operator version, plus every intermediate minor between the version
# running in the airgap (1.25.1) and the target. CloudNativePG recommends
# upgrading one minor at a time when catching up, so each step needs its own
# manifest and operator image (see 03-airgap-zone/scripts/upgrade-cnpg.sh).
CNPG_VERSION="1.30.1"
CNPG_UPGRADE_PATH="1.26.3 1.27.4 1.28.4 1.29.3 1.30.1"
PG_VERSION="16.6"
# Barman Cloud plugin: v0.16.0 requires CloudNativePG 1.30 or later
BARMAN_PLUGIN_VERSION="v0.16.0"
ARTIFACTS_DIR="artifacts/cnpg"

echo "====================================="
echo "Pulling CloudNativePG artifacts"
echo "====================================="

mkdir -p "$ARTIFACTS_DIR/images" "$ARTIFACTS_DIR/manifests"

# Operator manifests, one per upgrade step (release assets, no v prefix in the file name)
for version in $CNPG_UPGRADE_PATH; do
  echo "Downloading CNPG operator ${version} manifest..."
  curl -sfL "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${version}/cnpg-${version}.yaml" \
    -o "$ARTIFACTS_DIR/manifests/cnpg-${version}.yaml"
done

echo "Downloading Barman Cloud plugin ${BARMAN_PLUGIN_VERSION} manifest..."
curl -sfL "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/${BARMAN_PLUGIN_VERSION}/manifest.yaml" \
  -o "$ARTIFACTS_DIR/manifests/plugin-barman-cloud-${BARMAN_PLUGIN_VERSION}.yaml"

IMAGES="ghcr.io/cloudnative-pg/postgresql:${PG_VERSION}
ghcr.io/cloudnative-pg/plugin-barman-cloud:${BARMAN_PLUGIN_VERSION}
ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:${BARMAN_PLUGIN_VERSION}"
for version in $CNPG_UPGRADE_PATH; do
  IMAGES="${IMAGES}
ghcr.io/cloudnative-pg/cloudnative-pg:${version}"  # no v prefix
done

echo ""
echo "Images to pull:"
echo "$IMAGES" | sed 's/^/  /'
echo ""

# Tar name = image name without the ghcr.io/cloudnative-pg/ prefix, ':' replaced
# by '-' (the naming 02-transit-zone/push-cnpg.sh expects)
: > "$ARTIFACTS_DIR/images.txt"
for image in $IMAGES; do
  tar_name="$(echo "$image" | sed 's|ghcr.io/cloudnative-pg/||' | tr ':' '-').tar"
  echo "Pulling $image..."
  docker pull --platform linux/arm64 "$image"
  echo "Saving to tar: $tar_name"
  docker save "$image" -o "$ARTIFACTS_DIR/images/$tar_name"
  echo "$image" >> "$ARTIFACTS_DIR/images.txt"
done

echo ""
echo "✅ CloudNativePG ${CNPG_VERSION} artifacts downloaded successfully!"
echo ""
echo "Artifacts created:"
echo "Manifests:"
ls -lh "$ARTIFACTS_DIR/manifests/"
echo ""
echo "Images:"
ls -lh "$ARTIFACTS_DIR/images/"
echo ""
echo "Next: run 02-transit-zone/push-cnpg.sh to push images to airgap registry"
