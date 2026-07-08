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

const (
	idempotencyTTL = 24 * time.Hour
	// lockTTL bounds how long a crashed request can block retries with the same key.
	lockTTL = 30 * time.Second
)

var idempotencyTracer = otel.Tracer("lumen-api/idempotency")

type idempotencyStore interface {
	GetIdempotencyResult(ctx context.Context, key string) ([]byte, error)
	SetIdempotencyResult(ctx context.Context, key string, data []byte, ttl time.Duration) error
	AcquireIdempotencyLock(ctx context.Context, key string, ttl time.Duration) (bool, error)
	ReleaseIdempotencyLock(ctx context.Context, key string) error
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
			if replayCached(ctx, w, store, key) {
				span.SetAttributes(attribute.Bool("idempotency.cache_hit", true))
				return
			}

			span.SetAttributes(attribute.Bool("idempotency.cache_hit", false))

			// Claim the key before executing, so two in-flight requests with the
			// same key cannot both run the handler.
			locked, err := store.AcquireIdempotencyLock(ctx, key, lockTTL)
			if err == nil && !locked {
				span.SetAttributes(attribute.Bool("idempotency.conflict", true))
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("Retry-After", "1")
				w.WriteHeader(http.StatusConflict)
				json.NewEncoder(w).Encode(map[string]string{
					"error": "a request with this Idempotency-Key is already in progress",
				})
				return
			}
			if locked {
				defer store.ReleaseIdempotencyLock(ctx, key)
				// The other request may have stored its result between our cache
				// check and the lock acquisition — re-check before executing.
				if replayCached(ctx, w, store, key) {
					span.SetAttributes(attribute.Bool("idempotency.cache_hit", true))
					return
				}
			}

			// Execute the handler and store the result.
			cw := &capturingWriter{ResponseWriter: w, statusCode: http.StatusOK}
			next.ServeHTTP(cw, r.WithContext(ctx))

			// Never cache 5xx: a transient server error must not be replayed
			// for 24h to every retry of the same key.
			if cw.statusCode >= http.StatusInternalServerError {
				return
			}
			resp := cachedResponse{Status: cw.statusCode, Body: cw.buf.Bytes()}
			if data, err := json.Marshal(resp); err == nil {
				store.SetIdempotencyResult(ctx, key, data, idempotencyTTL)
			}
		})
	}
}

// replayCached writes the stored response for key, if any. Returns true on replay.
func replayCached(ctx context.Context, w http.ResponseWriter, store idempotencyStore, key string) bool {
	cached, err := store.GetIdempotencyResult(ctx, key)
	if err != nil || cached == nil {
		return false
	}
	var resp cachedResponse
	if json.Unmarshal(cached, &resp) != nil {
		return false
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Idempotency-Replayed", "true")
	w.WriteHeader(resp.Status)
	w.Write(resp.Body)
	return true
}
