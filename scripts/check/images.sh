# shellcheck shell=bash disable=SC2034  # sourced: the variables are used by the other scripts
# Pinned images of the checks (issue #15), sourced by the scripts of this
# directory. Each one by the digest of its index (issue #31): the checks run
# on amd64 (GitHub) and arm64 (a Mac). CHECK_REGISTRY prefixes them, e.g.
# "192.168.2.2:5000/" in the airgap zone once they are mirrored; mirror.py
# keeps one platform, whose digest differs, so that needs the platform
# digest here.
R="${CHECK_REGISTRY:-}"
GO_IMAGE="${R}golang:1.26.11-bookworm@sha256:dc40a13b61304647ed7e5d581d246b86413dfc29d63c6d018310feb93cd98fc0"  # Debian: -race needs cgo
GOLANGCI_IMAGE="${R}golangci/golangci-lint:v2.15.0@sha256:fbfcfd12a6f8d7f1b97b3362ca80fc2a244d46863148c73cb88e7793af96c481"  # built with Go 1.27
POSTGRES_IMAGE="${R}ghcr.io/cloudnative-pg/postgresql:16.6@sha256:53be6d727c7b3cf0df2b147f7ce7cdd31d37fd285314294871a4ccc3837b6872"
REDIS_IMAGE="${R}redis:7.4.12-alpine@sha256:7f7d30b7fdd09467bac58198a1f166dd69789d348d4fe859cccb20e0cf287fbe"
HELM_IMAGE="${R}alpine/helm:3.18.4@sha256:e7ecbf4a200dea73d64bfb8cb0936829164945f2b4d02a0274093073ee8d264f"  # ArgoCD embeds Helm 3
KUBECONFORM_IMAGE="${R}ghcr.io/yannh/kubeconform:v0.7.0-alpine@sha256:8f0eeaaa96ba27ba1500b0e4b1c215acc358d159c62a7ecae58d7a03403287b0"
PROMETHEUS_IMAGE="${R}prom/prometheus:v3.1.0@sha256:6559acbd5d770b15bb3c954629ce190ac3cbbdb2b7f1c30f0385c4e05104e218"  # promtool
SLOTH_IMAGE="${R}ghcr.io/slok/sloth:v0.11.0@sha256:958b372da13aff656532ae9d419b18f1f95717abcd9e58202b3127304c98d7e3"
KYVERNO_CLI_IMAGE="${R}ghcr.io/kyverno/kyverno-cli:v1.18.1@sha256:b7e272572d244ddec0b83469f7200ba883555bf69de4b294cee52a197c8c6590"  # the version deployed (kyverno-helm)
SHELLCHECK_IMAGE="${R}koalaman/shellcheck:v0.10.0@sha256:2097951f02e735b613f4a34de20c40f937a6c8f18ecb170612c88c34517221fb"
TERRAFORM_IMAGE="${R}hashicorp/terraform:1.12.2@sha256:f5ac787eee9d292b6a3b97d40f04019ce08189d356233fc73d5ec7ef8529cce2"
TRIVY_IMAGE="${R}aquasec/trivy:0.59.1@sha256:029e990b328d149bf0a9ffe355919041e1f86192db2df47e217f8a36dd42ceac"  # the version of .gitea/workflows/ci.yaml
PYTHON_IMAGE="${R}python:3.12.16-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b"
ANSIBLE_LINT_VERSION="26.10.1"   # installed with pip from PyPI at each run
ANSIBLE_CORE_VERSION="2.21.6"
CRANE_IMAGE="${R}gcr.io/go-containerregistry/crane:v0.22.1@sha256:1f968817b95790bed063f71175aa6b8ff879fa17064020415f3e18bb6e6a36e1"  # scripts/mirror.py
