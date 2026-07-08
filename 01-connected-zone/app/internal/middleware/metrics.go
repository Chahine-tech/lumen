package middleware

import (
	"net/http"
	"strconv"
	"time"

	"github.com/Chahine-tech/lumen/internal/metrics"
)

func Metrics(m *metrics.Metrics) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()

			wrapped := &responseWriter{
				ResponseWriter: w,
				statusCode:     http.StatusOK,
			}

			next.ServeHTTP(wrapped, r)

			duration := time.Since(start).Seconds()
			status := strconv.Itoa(wrapped.statusCode)

			// r.Pattern (set by ServeMux after routing) gives the registered
			// route ("GET /items/{id}"), not the raw path — otherwise every
			// /items/42 creates a new Prometheus series and unknown paths
			// probed by scanners explode cardinality.
			endpoint := r.Pattern
			if endpoint == "" {
				endpoint = "unmatched"
			}

			m.HTTPRequestsTotal.WithLabelValues(r.Method, endpoint, status).Inc()
			m.HTTPRequestDuration.WithLabelValues(r.Method, endpoint).Observe(duration)
		})
	}
}
