package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

type Metrics struct {
	HTTPRequestsTotal     *prometheus.CounterVec
	HTTPRequestDuration   *prometheus.HistogramVec
	RedisConnectionStatus prometheus.Gauge
	EventsTotal           *prometheus.CounterVec
	// AuthResultsTotal counts authentication and permission results
	// (internal/auth): in report mode, the requests enforce would refuse
	AuthResultsTotal *prometheus.CounterVec
	// RateLimitedTotal counts the requests refused by the per-caller limit
	RateLimitedTotal prometheus.Counter
}

func NewMetrics() *Metrics {
	return &Metrics{
		HTTPRequestsTotal: promauto.NewCounterVec(
			prometheus.CounterOpts{
				Name: "http_requests_total",
				Help: "Total number of HTTP requests",
			},
			[]string{"method", "endpoint", "status"},
		),
		HTTPRequestDuration: promauto.NewHistogramVec(
			prometheus.HistogramOpts{
				Name:    "http_request_duration_seconds",
				Help:    "HTTP request latency in seconds",
				Buckets: prometheus.DefBuckets,
			},
			[]string{"method", "endpoint"},
		),
		RedisConnectionStatus: promauto.NewGauge(
			prometheus.GaugeOpts{
				Name: "redis_connection_status",
				Help: "Redis connection status (1 = connected, 0 = disconnected)",
			},
		),
		EventsTotal: promauto.NewCounterVec(
			prometheus.CounterOpts{
				Name: "lumen_events_total",
				Help: "Total number of domain events produced, by type",
			},
			[]string{"type"},
		),
		AuthResultsTotal: promauto.NewCounterVec(
			prometheus.CounterOpts{
				Name: "lumen_auth_results_total",
				Help: "Authentication and permission results, by result (ok, missing, invalid, unavailable, forbidden) and mode",
			},
			[]string{"result", "mode"},
		),
		RateLimitedTotal: promauto.NewCounter(
			prometheus.CounterOpts{
				Name: "lumen_rate_limited_total",
				Help: "Requests refused by the per-caller rate limit",
			},
		),
	}
}
