#!/bin/bash
set -e

echo "====================================="
echo "Traefik Verification Script"
echo "====================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_pass() {
    echo -e "${GREEN}✅ $1${NC}"
}

check_fail() {
    echo -e "${RED}❌ $1${NC}"
}

check_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# 1. Check Traefik pods running
echo ""
echo "1️⃣  Checking Traefik deployment..."
READY_PODS=$(kubectl get pods -n traefik -l app=traefik --no-headers 2>/dev/null | grep -c "Running" || echo "0")
if [ "$READY_PODS" -ge 1 ]; then
    check_pass "Traefik pods running ($READY_PODS/2 replicas)"
else
    check_fail "No Traefik pods running"
    exit 1
fi

# 2. Check LoadBalancer service
echo ""
echo "2️⃣  Checking LoadBalancer service..."
LB_IP=$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -n "$LB_IP" ]; then
    check_pass "LoadBalancer IP assigned: $LB_IP"
else
    check_fail "No LoadBalancer IP assigned"
fi

# 3. Check TLS secret exists
echo ""
echo "3️⃣  Checking TLS certificates..."
for NS in traefik gitea monitoring argocd; do
    if kubectl get secret airgap-tls -n "$NS" &>/dev/null; then
        check_pass "TLS secret exists in $NS namespace"
    else
        check_fail "TLS secret missing in $NS namespace"
    fi
done

# 4. Check IngressRoutes
echo ""
echo "4️⃣  Checking IngressRoutes..."
ROUTES=$(kubectl get ingressroute --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$ROUTES" -gt 0 ]; then
    check_pass "Found $ROUTES IngressRoutes"
    kubectl get ingressroute --all-namespaces
else
    check_fail "No IngressRoutes found"
fi

# 5. Check DNS resolution
echo ""
echo "5️⃣  Checking DNS resolution..."
DOMAINS=("gitea.airgap.local" "grafana.airgap.local" "traefik.airgap.local")
for DOMAIN in "${DOMAINS[@]}"; do
    if ping -c 1 "$DOMAIN" &>/dev/null; then
        check_pass "$DOMAIN resolves"
    else
        check_fail "$DOMAIN does not resolve (check /etc/hosts)"
    fi
done

# 6. Check HTTPS endpoints
echo ""
echo "6️⃣  Checking HTTPS endpoints..."
ENDPOINTS=(
    "https://traefik.airgap.local/dashboard/"
    "https://gitea.airgap.local"
    "https://grafana.airgap.local"
    "https://prometheus.airgap.local"
    "https://alertmanager.airgap.local"
    "https://argocd.airgap.local"
)

for URL in "${ENDPOINTS[@]}"; do
    HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "$URL" || echo "000")
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "401" ]; then
        check_pass "$URL (HTTP $HTTP_CODE)"
    else
        check_fail "$URL (HTTP $HTTP_CODE)"
    fi
done

# 7. Check HTTP → HTTPS redirect
echo ""
echo "7️⃣  Checking HTTP → HTTPS redirect..."
REDIRECT_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://gitea.airgap.local || echo "000")
if [ "$REDIRECT_CODE" = "301" ] || [ "$REDIRECT_CODE" = "308" ]; then
    check_pass "HTTP redirects to HTTPS (HTTP $REDIRECT_CODE)"
else
    check_warn "HTTP redirect not working (HTTP $REDIRECT_CODE)"
fi

# 8. Check Traefik metrics
echo ""
echo "8️⃣  Checking Traefik metrics endpoint..."
METRICS=$(kubectl exec -n traefik deploy/traefik -- wget -qO- http://localhost:8080/metrics 2>/dev/null | head -5 || echo "")
if [ -n "$METRICS" ]; then
    check_pass "Traefik metrics available"
else
    check_fail "Traefik metrics not available"
fi

# 9. Check NetworkPolicies
echo ""
echo "9️⃣  Checking NetworkPolicies..."
TRAEFIK_NP=$(kubectl get netpol -n traefik --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$TRAEFIK_NP" -gt 0 ]; then
    check_pass "Traefik NetworkPolicies configured ($TRAEFIK_NP policies)"
else
    check_warn "No NetworkPolicies found for Traefik"
fi

echo ""
echo "====================================="
echo "Verification complete!"
echo "====================================="
echo ""
echo "📊 Summary:"
echo "  - Traefik pods: $READY_PODS running"
echo "  - LoadBalancer IP: ${LB_IP:-Not assigned}"
echo "  - IngressRoutes: $ROUTES configured"
echo ""
echo "🌐 Access services:"
echo "  - Traefik Dashboard: https://traefik.airgap.local/dashboard/"
echo "  - Gitea: https://gitea.airgap.local"
echo "  - Grafana: https://grafana.airgap.local"
echo "  - Prometheus: https://prometheus.airgap.local"
echo "  - ArgoCD: https://argocd.airgap.local"
