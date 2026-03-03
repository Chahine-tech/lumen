#!/bin/bash
set -e

METALLB_VERSION="v0.15.3"
FRR_VERSION="10.2.1"
ARTIFACTS_DIR="artifacts/metallb"

echo "====================================="
echo "Pulling MetalLB artifacts"
echo "====================================="

mkdir -p "$ARTIFACTS_DIR/images"

echo "Pulling quay.io/metallb/controller:${METALLB_VERSION}..."
docker pull "quay.io/metallb/controller:${METALLB_VERSION}"
docker save "quay.io/metallb/controller:${METALLB_VERSION}" -o "$ARTIFACTS_DIR/images/metallb-controller-${METALLB_VERSION}.tar"

echo "Pulling quay.io/metallb/speaker:${METALLB_VERSION}..."
docker pull "quay.io/metallb/speaker:${METALLB_VERSION}"
docker save "quay.io/metallb/speaker:${METALLB_VERSION}" -o "$ARTIFACTS_DIR/images/metallb-speaker-${METALLB_VERSION}.tar"

echo "Pulling quay.io/frrouting/frr:${FRR_VERSION}..."
docker pull "quay.io/frrouting/frr:${FRR_VERSION}"
docker save "quay.io/frrouting/frr:${FRR_VERSION}" -o "$ARTIFACTS_DIR/images/frr-${FRR_VERSION}.tar"

echo ""
echo "✅ MetalLB artifacts saved to $ARTIFACTS_DIR"
echo "Next: run 02-transit-zone/push-metallb.sh"
