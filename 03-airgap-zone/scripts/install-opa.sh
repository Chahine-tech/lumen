#!/bin/bash
# Bootstrap script — OPA Gatekeeper v3.18.0 installation (airgap)
#
# OPA Gatekeeper is a bootstrap component like ArgoCD and MetalLB:
# it must be installed BEFORE other workloads to enforce admission policies.
# Boot order: MetalLB → ArgoCD → OPA Gatekeeper → app deployments
#
# Prerequisites:
# - K3s running with node-1 and node-2
# - Docker registry running on node-1 at 192.168.2.2:5000
# - Gatekeeper image already pushed to local registry:
#   192.168.2.2:5000/openpolicyagent/gatekeeper:v3.18.0
#
# What this installs:
#   - Gatekeeper controller + audit deployment (gatekeeper-system namespace)
#   - 4 ConstraintTemplates: registry, labels, resources, no-latest
#   - 4 Constraints enforcing the above templates on lumen/default namespaces

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/opa"

echo "[1/3] Installing OPA Gatekeeper..."
multipass exec node-1 -- kubectl apply -f - < "${MANIFESTS_DIR}/01-gatekeeper-install.yaml"

echo "[2/3] Waiting for Gatekeeper CRDs to be ready..."
multipass exec node-1 -- kubectl wait --for=condition=Ready pods -l control-plane=controller-manager -n gatekeeper-system --timeout=120s

echo "[3/3] Applying constraint templates and constraints..."
multipass exec node-1 -- kubectl apply -f - < "${MANIFESTS_DIR}/02-constraint-template-registry.yaml"
sleep 5
multipass exec node-1 -- kubectl apply -f - < "${MANIFESTS_DIR}/03-constraint-template-labels.yaml"
sleep 5
multipass exec node-1 -- kubectl apply -f - < "${MANIFESTS_DIR}/04-constraint-template-resources.yaml"
sleep 5
multipass exec node-1 -- kubectl apply -f - < "${MANIFESTS_DIR}/05-constraint-template-no-latest.yaml"

echo ""
echo "OPA Gatekeeper ready. Verifying constraints..."
multipass exec node-1 -- kubectl get constraints -A
echo ""
echo "Enforcement active on namespaces: lumen, default"
