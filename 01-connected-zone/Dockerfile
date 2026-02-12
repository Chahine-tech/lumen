# Multi-stage build for minimal image size
# Perfect for airgap: small binaries, fewer dependencies

# Stage 1: Build
FROM golang:1.26-alpine AS builder

WORKDIR /build

# Copy go mod files
COPY app/go.mod app/go.sum* ./

# Download dependencies (will be cached if go.mod doesn't change)
RUN go mod download

# Copy source code
COPY app/ ./

# Build static binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s" \
    -o /build/lumen-api \
    ./cmd/server

# Stage 2: Runtime (minimal size)
FROM alpine:3.21

# Add ca-certificates for HTTPS (if needed)
RUN apk --no-cache add ca-certificates tzdata

# Create non-root user
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser

WORKDIR /app

# Copy binary from builder
COPY --from=builder /build/lumen-api /app/lumen-api

# Change ownership
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

# Run
ENTRYPOINT ["/app/lumen-api"]
