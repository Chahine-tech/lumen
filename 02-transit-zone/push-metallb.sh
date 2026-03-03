#!/bin/bash
set -e

METALLB_VERSION="v0.15.3"
FRR_VERSION="10.2.1"
ARTIFACTS_DIR="../01-connected-zone/artifacts/metallb"
REGISTRY="localhost:5000"

echo "====================================="
echo "Pushing MetalLB images to transit registry"
echo "====================================="

if ! curl -s http://localhost:5000/v2/ > /dev/null 2>&1; then
    echo "❌ Transit registry not running on localhost:5000"
    echo "Run: cd 02-transit-zone && ./setup.sh"
    exit 1
fi

echo "Loading MetalLB images..."
docker load -i "$ARTIFACTS_DIR/images/metallb-controller-${METALLB_VERSION}.tar"
docker load -i "$ARTIFACTS_DIR/images/metallb-speaker-${METALLB_VERSION}.tar"
docker load -i "$ARTIFACTS_DIR/images/frr-${FRR_VERSION}.tar"

echo "Tagging and pushing..."
docker tag "quay.io/metallb/controller:${METALLB_VERSION}" "${REGISTRY}/metallb/controller:${METALLB_VERSION}"
docker push "${REGISTRY}/metallb/controller:${METALLB_VERSION}"

docker tag "quay.io/metallb/speaker:${METALLB_VERSION}" "${REGISTRY}/metallb/speaker:${METALLB_VERSION}"
docker push "${REGISTRY}/metallb/speaker:${METALLB_VERSION}"

docker tag "quay.io/frrouting/frr:${FRR_VERSION}" "${REGISTRY}/frrouting/frr:${FRR_VERSION}"
docker push "${REGISTRY}/frrouting/frr:${FRR_VERSION}"

echo ""
echo "✅ MetalLB images pushed to ${REGISTRY}"
