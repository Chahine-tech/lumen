#!/bin/bash
set -e

# Copy TLS secret to all namespaces that need it
# Educational: Kubernetes Secrets are namespace-scoped
# IngressRoute must reference a secret in the same namespace
# Solution: Copy the secret to each namespace

NAMESPACES=("gitea" "monitoring" "argocd")

echo "====================================="
echo "Copying TLS secrets to namespaces"
echo "====================================="

for NS in "${NAMESPACES[@]}"; do
    echo "Copying airgap-tls to namespace: $NS"

    kubectl get secret airgap-tls -n traefik -o yaml \
        | sed "s/namespace: traefik/namespace: $NS/" \
        | kubectl apply -f -

    echo "✅ Secret copied to $NS"
done

echo ""
echo "✅ All TLS secrets copied successfully!"
echo ""
echo "Verify with:"
echo "  kubectl get secrets -n gitea | grep airgap-tls"
echo "  kubectl get secrets -n monitoring | grep airgap-tls"
echo "  kubectl get secrets -n argocd | grep airgap-tls"
