# Pinned images of the checks (issue #15), sourced by the scripts of this
# directory. CHECK_REGISTRY prefixes them, e.g. "192.168.2.2:5000/" in the
# airgap zone once they are mirrored.
R="${CHECK_REGISTRY:-}"
GO_IMAGE="${R}golang:1.26-bookworm"                     # Debian: -race needs cgo
GOLANGCI_IMAGE="${R}golangci/golangci-lint:v2.15.0"     # built with Go 1.27
POSTGRES_IMAGE="${R}ghcr.io/cloudnative-pg/postgresql:16.6"
REDIS_IMAGE="${R}redis:7-alpine"
HELM_IMAGE="${R}alpine/helm:3.18.4"                     # ArgoCD embeds Helm 3
KUBECONFORM_IMAGE="${R}ghcr.io/yannh/kubeconform:v0.7.0-alpine"
PROMETHEUS_IMAGE="${R}prom/prometheus:v3.1.0"           # promtool
SLOTH_IMAGE="${R}ghcr.io/slok/sloth:v0.11.0"
SHELLCHECK_IMAGE="${R}koalaman/shellcheck:v0.10.0"
TERRAFORM_IMAGE="${R}hashicorp/terraform:1.12.2"
PYTHON_IMAGE="${R}python:3.12-slim"
ANSIBLE_LINT_VERSION="26.10.1"   # installed with pip from PyPI at each run
ANSIBLE_CORE_VERSION="2.21.6"
