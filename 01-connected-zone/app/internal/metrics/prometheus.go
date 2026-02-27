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
	}
}
