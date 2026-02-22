package middleware

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
)

const idempotencyTTL = 24 * time.Hour

var idempotencyTracer = otel.Tracer("lumen-api/idempotency")

type idempotencyStore interface {
	GetIdempotencyResult(ctx context.Context, key string) ([]byte, error)
	SetIdempotencyResult(ctx context.Context, key string, data []byte, ttl time.Duration) error
}

type cachedResponse struct {
	Status int    `json:"status"`
	Body   []byte `json:"body"`
}

// capturingWriter records the status code and body written by the handler.
type capturingWriter struct {
	http.ResponseWriter
	statusCode int
	buf        bytes.Buffer
}

func (cw *capturingWriter) WriteHeader(code int) {
	cw.statusCode = code
	cw.ResponseWriter.WriteHeader(code)
}

func (cw *capturingWriter) Write(b []byte) (int, error) {
	cw.buf.Write(b)
	return cw.ResponseWriter.Write(b)
}

// Idempotency returns a middleware that deduplicates non-idempotent requests using
// an Idempotency-Key header. Results are cached in Redis for 24 hours.
// Only applied to methods passed in applyTo (typically POST and DELETE).
func Idempotency(store idempotencyStore, applyTo ...string) func(http.Handler) http.Handler {
	methods := make(map[string]bool, len(applyTo))
	for _, m := range applyTo {
		methods[strings.ToUpper(m)] = true
	}

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !methods[r.Method] {
				next.ServeHTTP(w, r)
				return
			}

			key := r.Header.Get("Idempotency-Key")
			if key == "" {
				next.ServeHTTP(w, r)
				return
			}

			ctx, span := idempotencyTracer.Start(r.Context(), "idempotency.check")
			defer span.End()
			span.SetAttributes(attribute.String("idempotency.key", key))

			// Cache hit — return the stored response.
			cached, err := store.GetIdempotencyResult(ctx, key)
			if err == nil && cached != nil {
				span.SetAttributes(attribute.Bool("idempotency.cache_hit", true))
				var resp cachedResponse
				if json.Unmarshal(cached, &resp) == nil {
					w.Header().Set("Content-Type", "application/json")
					w.Header().Set("Idempotency-Replayed", "true")
					w.WriteHeader(resp.Status)
					w.Write(resp.Body)
					return
				}
			}

			span.SetAttributes(attribute.Bool("idempotency.cache_hit", false))

			// Cache miss — execute the handler and store the result.
			cw := &capturingWriter{ResponseWriter: w, statusCode: http.StatusOK}
			next.ServeHTTP(cw, r.WithContext(ctx))

			resp := cachedResponse{Status: cw.statusCode, Body: cw.buf.Bytes()}
			if data, err := json.Marshal(resp); err == nil {
				store.SetIdempotencyResult(ctx, key, data, idempotencyTTL)
			}
		})
	}
}
