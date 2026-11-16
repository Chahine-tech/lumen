#!/bin/sh
# lumen-api image: built once per source, scanned, signed by digest, and
# promoted to a release without a rebuild (issue #12). Called by
# .gitea/workflows/ci.yaml. POSIX sh: the job image is Alpine.
#
#   lumen-api-image.sh build             build-push job (main)
#   lumen-api-image.sh promote <version> release job (tag v*)
#
# Both print image=<registry>/<name>@sha256:<digest> to $GITHUB_OUTPUT.
#
# The image is tagged src-<hash>: a hash of the build inputs (the app/ tree
# and the Dockerfile, the only files the build reads). A release tag on a
# commit that did not change them finds the image built for an earlier one.
#
# build: an image already pushed and signed for this source is reused.
# Otherwise: docker build, Trivy gate, push, cosign sign of the digest.
# promote: the src- image must exist and carry a valid signature. Trivy runs
# again (the database may be newer), then the version tag is pushed for
# people; the manifest gets the digest.
#
# Environment: REGISTRY, IMAGE_NAME, COSIGN_KEY (private key file, empty
# password), TRIVY_IMAGE, GO_BUILDER (build: the Go builder image passed to
# the Dockerfile, default the one it names), TRIVY_CACHE (offline Trivy DB,
# default /var/cache/trivy), COSIGN_FLAGS (default: HTTP registry, no
# transparency log, legacy signature format, see below).
set -eu

CONTEXT=01-connected-zone
: "${REGISTRY:?}" "${IMAGE_NAME:?}" "${COSIGN_KEY:?}" "${TRIVY_IMAGE:?}"
TRIVY_CACHE="${TRIVY_CACHE:-/var/cache/trivy}"
# --new-bundle-format=false: cosign v3 defaults to the OCI bundle format
# (sha256-<digest> referrer tag), which Kyverno's keys-based verifyImages
# cannot read; it needs the legacy sha256-<digest>.sig tag
COSIGN_FLAGS="${COSIGN_FLAGS:---allow-http-registry --allow-insecure-registry --tlog-upload=false --use-signing-config=false --new-bundle-format=false}"
COSIGN_VERIFY_FLAGS="${COSIGN_VERIFY_FLAGS:---allow-http-registry --allow-insecure-registry --insecure-ignore-tlog=true}"
REPO="$REGISTRY/$IMAGE_NAME"

src_tag() {
  h=$(git rev-parse "HEAD:$CONTEXT/app" "HEAD:$CONTEXT/Dockerfile" | sha256sum | cut -c1-12)
  echo "src-$h"
}

# digest_ref <local image>: the registry reference of a pushed or pulled image
digest_ref() {
  docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$1" | grep "^$REPO@sha256:" | head -1
}

# Fixable HIGH and CRITICAL vulnerabilities fail; unfixable ones are
# reported only (no action possible in airgap). There is no waiver file:
# Trivy runs in its own container, which does not see the checkout.
scan() {
  docker run --rm -v "$TRIVY_CACHE:/root/.cache/trivy" -v /var/run/docker.sock:/var/run/docker.sock \
    "$TRIVY_IMAGE" image --skip-db-update --skip-java-db-update --exit-code 0 \
    --severity HIGH,CRITICAL --format table "$1"
  docker run --rm -v "$TRIVY_CACHE:/root/.cache/trivy" -v /var/run/docker.sock:/var/run/docker.sock \
    "$TRIVY_IMAGE" image --skip-db-update --skip-java-db-update --exit-code 1 \
    --severity HIGH,CRITICAL --ignore-unfixed "$1"
}

# verify <ref@digest>: signed with the CI key
verify() {
  pub=$(mktemp)
  COSIGN_PASSWORD="" cosign public-key --key "$COSIGN_KEY" > "$pub"
  # shellcheck disable=SC2086
  cosign verify --key "$pub" $COSIGN_VERIFY_FLAGS "$1" > /dev/null
  rc=$?
  rm -f "$pub"
  return $rc
}

output() {
  echo "image=$1"
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "image=$1" >> "$GITHUB_OUTPUT"
}

src=$(src_tag)
case "${1:-}" in
  build)
    if docker pull -q "$REPO:$src" > /dev/null 2>&1; then
      ref=$(digest_ref "$REPO:$src")
      if verify "$ref"; then
        echo "$REPO:$src already built, scanned and signed: $ref"
        output "$ref"
        exit 0
      fi
      echo "$REPO:$src exists but its signature does not verify: building again"
    fi
    sha=$(git rev-parse --short=7 HEAD)
    docker build ${GO_BUILDER:+--build-arg "GO_BUILDER=$GO_BUILDER"} \
      -t "$REPO:$src" -t "$REPO:$sha" -f "$CONTEXT/Dockerfile" "$CONTEXT"
    scan "$REPO:$src"
    docker push -q "$REPO:$src"
    docker push -q "$REPO:$sha"
    ref=$(digest_ref "$REPO:$src")
    [ -n "$ref" ] || { echo "no digest for $REPO:$src after the push"; exit 1; }
    # shellcheck disable=SC2086
    COSIGN_PASSWORD="" cosign sign --yes --key "$COSIGN_KEY" $COSIGN_FLAGS "$ref"
    output "$ref"
    ;;
  promote)
    version="${2:?usage: $0 promote <version>}"
    docker pull -q "$REPO:$src" > /dev/null 2>&1 || {
      echo "no image $REPO:$src for this source: push main and let the build-push job finish, then tag again"
      exit 1
    }
    ref=$(digest_ref "$REPO:$src")
    verify "$ref" || { echo "$ref is not signed with the CI key"; exit 1; }
    scan "$REPO:$src"
    docker tag "$REPO:$src" "$REPO:$version"
    docker push -q "$REPO:$version"
    output "$ref"
    ;;
  *)
    echo "usage: $0 build | promote <version>"
    exit 2
    ;;
esac
