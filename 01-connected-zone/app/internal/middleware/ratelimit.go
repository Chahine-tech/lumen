package middleware

import (
	"context"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/Chahine-tech/lumen/internal/auth"
)

type requestCounter interface {
	CountRequest(ctx context.Context, caller string, window time.Duration) (int64, error)
}

// CallerRateLimit returns a middleware that allows each caller at most
// limit requests per second, counted in Redis so that the limit holds
// across replicas (issue #18). Over the limit, the request gets 429. A
// request without a caller (report mode) is not counted: Traefik's global
// limit still applies to it. When Redis cannot count, the request is served:
// the limit protects capacity, it is not a correctness guarantee.
// refused, when not nil, is called for each 429.
func CallerRateLimit(store requestCounter, limit int64, refused func()) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			caller := auth.Caller(r.Context())
			if caller == "" || limit <= 0 {
				next.ServeHTTP(w, r)
				return
			}
			n, err := store.CountRequest(r.Context(), caller, time.Second)
			if err != nil {
				slog.Warn("Rate limit not checked, request served", "error", err)
				next.ServeHTTP(w, r)
				return
			}
			if n > limit {
				if refused != nil {
					refused()
				}
				w.Header().Set("Retry-After", "1")
				writeJSONError(w, http.StatusTooManyRequests,
					"rate limit of "+strconv.FormatInt(limit, 10)+" requests per second exceeded")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
