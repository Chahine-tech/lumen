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

			m.HTTPRequestsTotal.WithLabelValues(r.Method, r.URL.Path, status).Inc()
			m.HTTPRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)
		})
	}
}
