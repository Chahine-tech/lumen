# The job image of the Gitea CI (runner label ubuntu-latest,
# 03-airgap-zone/manifests/gitea-runner/01-runner.yaml): Go for the tests,
# the docker CLI for the host Docker (build, Trivy, cosign), git for the
# source hash, node for actions/checkout. Built by scripts/mirror.py pull,
# tagged with the Go version (mirror.yaml).
#
# Same Go builder as 01-connected-zone/Dockerfile. The packages come from
# the Alpine branch of that image, at the version current on build day.
ARG GO_BUILDER=golang:1.26.11-alpine@sha256:ecb67f987aa1a57794c91d19ade7ae0209f2f0f5496aaef9e6ae85ddf92d02ab
FROM ${GO_BUILDER}

RUN apk add --no-cache docker-cli git nodejs
