package eventstream

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics of the relay and the consumer.
type Metrics struct {
	OutboxPending   prometheus.Gauge
	OutboxOldestAge prometheus.Gauge
	RelayActive     prometheus.Gauge
	Published       prometheus.Counter
	PublishErrors   prometheus.Counter
	Consumed        *prometheus.CounterVec
	ConsumeErrors   prometheus.Counter
}

// NewMetrics registers the metrics on reg.
func NewMetrics(reg prometheus.Registerer) *Metrics {
	f := promauto.With(reg)
	return &Metrics{
		OutboxPending: f.NewGauge(prometheus.GaugeOpts{
			Name: "lumen_outbox_pending",
			Help: "Events in the outbox, not acknowledged by Kafka yet",
		}),
		OutboxOldestAge: f.NewGauge(prometheus.GaugeOpts{
			Name: "lumen_outbox_oldest_age_seconds",
			Help: "Age of the oldest event in the outbox (0 when it is empty)",
		}),
		RelayActive: f.NewGauge(prometheus.GaugeOpts{
			Name: "lumen_outbox_relay_active",
			Help: "1 for the replica that publishes, 0 for a standby",
		}),
		Published: f.NewCounter(prometheus.CounterOpts{
			Name: "lumen_outbox_published_total",
			Help: "Events acknowledged by Kafka",
		}),
		PublishErrors: f.NewCounter(prometheus.CounterOpts{
			Name: "lumen_outbox_publish_errors_total",
			Help: "Batches that failed and will be published again",
		}),
		Consumed: f.NewCounterVec(prometheus.CounterOpts{
			Name: "lumen_events_consumed_total",
			Help: "Messages consumed, by result (applied, duplicate, dead_lettered)",
		}, []string{"result"}),
		ConsumeErrors: f.NewCounter(prometheus.CounterOpts{
			Name: "lumen_events_consume_errors_total",
			Help: "Attempts that failed and will be retried",
		}),
	}
}

// ServeAdmin serves /metrics and /livez on addr until ctx is done.
func ServeAdmin(ctx context.Context, addr string, gatherer prometheus.Gatherer) error {
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.HandlerFor(gatherer, promhttp.HandlerOpts{}))
	mux.HandleFunc("GET /livez", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	srv := &http.Server{Addr: addr, Handler: mux, ReadTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdown); err != nil {
			slog.Warn("Admin server shutdown", "error", err)
		}
	}()
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
