.PHONY: help all build-connected setup-transit setup-airgap deploy test clean

# Colors for output
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
NC     := \033[0m # No Color

help: ## Show this help message
	@echo "$(GREEN)Lumen Airgap Kubernetes Project$(NC)"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'

all: build-connected setup-transit setup-airgap deploy test ## Run complete setup (all zones)
	@echo "$(GREEN)✓ Complete setup finished!$(NC)"

# Connected Zone
build-connected: ## Build images and package artifacts in connected zone
	@echo "$(YELLOW)[Connected Zone]$(NC) Building..."
	cd 01-connected-zone && ./build.sh

test-api-local: ## Test API locally with docker-compose
	@echo "$(YELLOW)[Connected Zone]$(NC) Testing API locally..."
	cd 01-connected-zone && docker-compose up -d
	@sleep 5
	@echo "Testing endpoints..."
	@curl -s http://localhost:8080/health | jq .
	@curl -s http://localhost:8080/hello | jq .
	@echo "Metrics available at: http://localhost:8080/metrics"

stop-local: ## Stop local docker-compose
	cd 01-connected-zone && docker-compose down

# Transit Zone
setup-transit: ## Setup transit zone (registry + file server)
	@echo "$(YELLOW)[Transit Zone]$(NC) Setting up..."
	cd 02-transit-zone && ./setup.sh

transit-status: ## Check transit zone status
	@echo "$(YELLOW)[Transit Zone]$(NC) Status:"
	@docker-compose -f 02-transit-zone/docker-compose.yml ps
	@echo ""
	@echo "Registry catalog:"
	@curl -s http://localhost:5000/v2/_catalog | jq .

stop-transit: ## Stop transit zone
	cd 02-transit-zone && docker-compose down

# Airgap Zone
setup-airgap: ## Setup airgap zone (K3s + containerd config)
	@echo "$(YELLOW)[Airgap Zone]$(NC) Setting up..."
	@echo "$(RED)Note: Requires sudo for iptables and K3s setup$(NC)"
	cd 03-airgap-zone/scripts && sudo ./setup-k3s.sh

test-airgap: ## Verify airgap isolation
	@echo "$(YELLOW)[Airgap Zone]$(NC) Testing isolation..."
	@echo "Testing internet (should fail):"
	@timeout 2 curl -s google.com && echo "$(RED)FAIL: Internet accessible$(NC)" || echo "$(GREEN)PASS: No internet$(NC)"
	@echo ""
	@echo "Testing internal registry (should work):"
	@curl -s http://localhost:5000/v2/ && echo "$(GREEN)PASS: Registry accessible$(NC)" || echo "$(RED)FAIL: Registry not accessible$(NC)"

# Kubernetes Deployments
deploy: deploy-app deploy-monitoring ## Deploy everything to Kubernetes
	@echo "$(GREEN)✓ All deployments complete!$(NC)"

deploy-app: ## Deploy application (API + Redis)
	@echo "$(YELLOW)[K8s]$(NC) Deploying application..."
	kubectl apply -f 03-airgap-zone/manifests/app/

deploy-network-policies: ## Apply NetworkPolicies
	@echo "$(YELLOW)[K8s]$(NC) Applying NetworkPolicies..."
	kubectl apply -f 03-airgap-zone/manifests/network-policies/

deploy-opa: ## Deploy OPA Gatekeeper policies
	@echo "$(YELLOW)[K8s]$(NC) Deploying OPA policies..."
	kubectl apply -f 03-airgap-zone/manifests/opa/

deploy-monitoring: ## Deploy monitoring stack (Prometheus + Grafana)
	@echo "$(YELLOW)[K8s]$(NC) Deploying monitoring..."
	kubectl apply -f 03-airgap-zone/manifests/monitoring/

# Testing
test: test-k8s-connectivity test-api-k8s test-network-policies ## Run all tests
	@echo "$(GREEN)✓ All tests passed!$(NC)"

test-k8s-connectivity: ## Test Kubernetes connectivity
	@echo "$(YELLOW)[Test]$(NC) Kubernetes connectivity..."
	kubectl get nodes
	kubectl get pods -A

test-api-k8s: ## Test API endpoints in Kubernetes
	@echo "$(YELLOW)[Test]$(NC) API endpoints..."
	@POD=$$(kubectl get pod -n lumen -l app=lumen-api -o jsonpath='{.items[0].metadata.name}'); \
	kubectl exec -n lumen $$POD -- wget -qO- http://localhost:8080/health

test-network-policies: ## Test NetworkPolicy enforcement
	@echo "$(YELLOW)[Test]$(NC) NetworkPolicy enforcement..."
	@echo "Testing allowed: lumen-api -> redis (should work)"
	@POD=$$(kubectl get pod -n lumen -l app=lumen-api -o jsonpath='{.items[0].metadata.name}'); \
	kubectl exec -n lumen $$POD -- timeout 2 nc -zv redis 6379 && echo "$(GREEN)PASS$(NC)" || echo "$(RED)FAIL$(NC)"

test-opa: ## Test OPA policies
	@echo "$(YELLOW)[Test]$(NC) OPA Gatekeeper policies..."
	@echo "Testing: Deploying pod with :latest tag (should be rejected)"
	@kubectl apply -f - <<EOF | grep -q "denied" && echo "$(GREEN)PASS: Latest tag blocked$(NC)" || echo "$(RED)FAIL$(NC)"
	apiVersion: v1
	kind: Pod
	metadata:
	  name: test-latest
	  namespace: lumen
	spec:
	  containers:
	  - name: test
	    image: nginx:latest
	EOF

# Port forwarding
forward-api: ## Port-forward to API (localhost:8080)
	@echo "$(GREEN)Forwarding API to localhost:8080$(NC)"
	kubectl port-forward -n lumen svc/lumen-api 8080:8080

forward-grafana: ## Port-forward to Grafana (localhost:3000)
	@echo "$(GREEN)Forwarding Grafana to localhost:3000$(NC)"
	@echo "Login: admin/admin"
	kubectl port-forward -n monitoring svc/grafana 3000:3000

forward-prometheus: ## Port-forward to Prometheus (localhost:9090)
	@echo "$(GREEN)Forwarding Prometheus to localhost:9090$(NC)"
	kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Observability
logs-api: ## Tail API logs
	kubectl logs -n lumen -l app=lumen-api -f

logs-redis: ## Tail Redis logs
	kubectl logs -n lumen -l app=redis -f

status: ## Show status of all components
	@echo "$(YELLOW)=== Kubernetes Status ===$(NC)"
	kubectl get nodes
	@echo ""
	@echo "$(YELLOW)=== Lumen Namespace ===$(NC)"
	kubectl get all -n lumen
	@echo ""
	@echo "$(YELLOW)=== Monitoring Namespace ===$(NC)"
	kubectl get all -n monitoring
	@echo ""
	@echo "$(YELLOW)=== NetworkPolicies ===$(NC)"
	kubectl get networkpolicies -n lumen

# Cleanup
clean-k8s: ## Delete all Kubernetes resources
	@echo "$(RED)Cleaning Kubernetes resources...$(NC)"
	kubectl delete namespace lumen --ignore-not-found=true
	kubectl delete namespace monitoring --ignore-not-found=true
	kubectl delete namespace gatekeeper-system --ignore-not-found=true

clean-docker: ## Clean Docker images and containers
	@echo "$(RED)Cleaning Docker resources...$(NC)"
	cd 01-connected-zone && docker-compose down -v || true
	cd 02-transit-zone && docker-compose down -v || true
	docker system prune -f

clean: clean-k8s clean-docker ## Clean everything
	@echo "$(RED)Cleaning artifacts...$(NC)"
	rm -rf artifacts/
	@echo "$(GREEN)✓ Cleanup complete$(NC)"

# Documentation
docs: ## Generate documentation
	@echo "$(YELLOW)Documentation available:$(NC)"
	@echo "  README.md - Project overview"
	@echo "  docs/SETUP.md - Detailed setup guide"
	@echo "  docs/ARCHITECTURE.md - Architecture details"

# Quick commands
quick-start: build-connected setup-transit ## Quick start (skip airgap setup)
	@echo "$(GREEN)Quick start complete!$(NC)"
	@echo "Next: Run 'make setup-airgap' (requires sudo)"
