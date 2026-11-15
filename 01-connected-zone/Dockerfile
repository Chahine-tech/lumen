# lumen-api: a static Go binary on scratch. The runtime image holds the
# binary and the CA bundle, nothing else: no shell, no package manager, no
# base image to mirror into the airgap besides the Go builder.

# Stage 1: Build
FROM golang:1.26-alpine AS builder

WORKDIR /build

# Copy go mod files
COPY app/go.mod app/go.sum* ./

# Download dependencies (will be cached if go.mod doesn't change)
RUN go mod download

# Copy source code
COPY app/ ./

# Set by BuildKit for the target platform (docker buildx --platform). Empty
# with the legacy builder: go then builds for the platform it runs on.
ARG TARGETOS
ARG TARGETARCH

# Build static binary
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build \
    -trimpath -ldflags="-w -s" \
    -o /build/lumen-api \
    ./cmd/server

# Stage 2: Runtime
FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /build/lumen-api /app/lumen-api

# Numeric: scratch has no /etc/passwd. The pods set the same (runAsUser: 1000)
USER 1000:1000

# API, and admin (/metrics, pprof)
EXPOSE 8080 9090

# No HEALTHCHECK: Kubernetes ignores it and runs the pod probes
ENTRYPOINT ["/app/lumen-api"]
