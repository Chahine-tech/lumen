#!/bin/bash
# Complete test suite for airgap validation

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

test_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((PASS_COUNT++))
}

test_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((FAIL_COUNT++))
}

echo "================================================"
echo "  Airgap Validation Test Suite"
echo "================================================"
echo ""

# Test 1: Internet should be blocked
echo -e "${YELLOW}[Test 1/8]${NC} Verifying internet is blocked..."
if timeout 2 curl -s google.com >/dev/null 2>&1; then
    test_fail "Internet is accessible (airgap not enforced)"
else
    test_pass "Internet blocked correctly"
fi

# Test 2: Internal registry should be accessible
echo -e "${YELLOW}[Test 2/8]${NC} Verifying internal registry is accessible..."
if curl -s http://localhost:5000/v2/ >/dev/null 2>&1; then
    test_pass "Internal registry accessible"
else
    test_fail "Internal registry not accessible"
fi

# Test 3: Kubernetes cluster should be running
echo -e "${YELLOW}[Test 3/8]${NC} Verifying Kubernetes cluster..."
if kubectl cluster-info >/dev/null 2>&1; then
    test_pass "Kubernetes cluster running"
else
    test_fail "Kubernetes cluster not accessible"
fi

# Test 4: Lumen namespace and pods
echo -e "${YELLOW}[Test 4/8]${NC} Checking lumen namespace..."
if kubectl get namespace lumen >/dev/null 2>&1; then
    test_pass "Lumen namespace exists"

    # Check pods
    READY_PODS=$(kubectl get pods -n lumen --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [ "$READY_PODS" -gt 0 ]; then
        test_pass "Lumen pods running ($READY_PODS pods)"
    else
        test_fail "No lumen pods running"
    fi
else
    test_fail "Lumen namespace not found"
fi

# Test 5: API health check
echo -e "${YELLOW}[Test 5/8]${NC} Testing API health endpoint..."
API_POD=$(kubectl get pod -n lumen -l app=lumen-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$API_POD" ]; then
    HEALTH=$(kubectl exec -n lumen "$API_POD" -- wget -qO- http://localhost:8080/health 2>/dev/null || echo "")
    if echo "$HEALTH" | grep -q "healthy"; then
        test_pass "API health check successful"
    else
        test_fail "API health check failed"
    fi
else
    test_fail "API pod not found"
fi

# Test 6: Redis connectivity from API
echo -e "${YELLOW}[Test 6/8]${NC} Testing API -> Redis connectivity..."
if [ -n "$API_POD" ]; then
    if kubectl exec -n lumen "$API_POD" -- timeout 2 sh -c "echo > /dev/tcp/redis/6379" 2>/dev/null; then
        test_pass "API can reach Redis"
    else
        test_fail "API cannot reach Redis"
    fi
else
    test_fail "API pod not found"
fi

# Test 7: NetworkPolicy enforcement
echo -e "${YELLOW}[Test 7/8]${NC} Testing NetworkPolicy enforcement..."
NP_COUNT=$(kubectl get networkpolicies -n lumen --no-headers 2>/dev/null | wc -l)
if [ "$NP_COUNT" -gt 0 ]; then
    test_pass "NetworkPolicies deployed ($NP_COUNT policies)"
else
    test_fail "No NetworkPolicies found"
fi

# Test 8: Monitoring stack
echo -e "${YELLOW}[Test 8/8]${NC} Checking monitoring stack..."
if kubectl get namespace monitoring >/dev/null 2>&1; then
    PROM_RUNNING=$(kubectl get pods -n monitoring -l app=prometheus --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    GRAF_RUNNING=$(kubectl get pods -n monitoring -l app=grafana --no-headers 2>/dev/null | grep -c "Running" || echo "0")

    if [ "$PROM_RUNNING" -gt 0 ] && [ "$GRAF_RUNNING" -gt 0 ]; then
        test_pass "Monitoring stack running (Prometheus + Grafana)"
    else
        test_fail "Monitoring stack incomplete"
    fi
else
    test_fail "Monitoring namespace not found"
fi

# Summary
echo ""
echo "================================================"
echo "  Test Summary"
echo "================================================"
echo -e "Passed: ${GREEN}$PASS_COUNT${NC}"
echo -e "Failed: ${RED}$FAIL_COUNT${NC}"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed! Airgap environment is working correctly.${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed. Please review the output above.${NC}"
    exit 1
fi
