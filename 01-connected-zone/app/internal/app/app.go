package app

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/pprof"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/Chahine-tech/lumen/internal/handlers"
	"github.com/Chahine-tech/lumen/internal/metrics"
	"github.com/Chahine-tech/lumen/internal/middleware"
	"github.com/Chahine-tech/lumen/internal/store"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type App struct {
	store   *store.RedisStore
	pgStore *store.PostgresStore
	metrics *metrics.Metrics
	server  *http.Server

	// draining is set at SIGTERM: /readyz then answers 503 (probes.go)
	draining atomic.Bool
	// drainDelay: time between failing readiness and closing the listener
	drainDelay time.Duration
}

func NewApp() (*App, error) {
	redisAddr       := getEnv("REDIS_ADDR", "localhost:6379")
	redisMode       := getEnv("REDIS_MODE", "standalone")
	sentinelAddrs   := getEnv("REDIS_SENTINEL_ADDRS", "")
	redisMasterName := getEnv("REDIS_MASTER_NAME", "mymaster")
	redisPassword   := getEnv("REDIS_PASSWORD", "")
	port            := getEnv("PORT", "8080")

	drainDelay, err := time.ParseDuration(getEnv("SHUTDOWN_DRAIN_DELAY", "5s"))
	if err != nil {
		return nil, fmt.Errorf("invalid SHUTDOWN_DRAIN_DELAY: %w", err)
	}
	a := &App{drainDelay: drainDelay}

	pgRWDSN := getEnv("PG_RW_DSN", "")
	pgRODSN := getEnv("PG_RO_DSN", "")

	slog.Info("Connecting to Redis", "addr", redisAddr, "mode", redisMode)
	redisStore, err := store.NewRedisStore(redisAddr, redisMode, sentinelAddrs, redisMasterName, redisPassword)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize Redis: %w", err)
	}
	slog.Info("Redis connected successfully")

	m := metrics.NewMetrics()
	m.RedisConnectionStatus.Set(1)

	var pgStore *store.PostgresStore
	if pgRWDSN != "" && pgRODSN != "" {
		slog.Info("Connecting to PostgreSQL")
		pgStore, err = store.NewPostgresStore(context.Background(), pgRWDSN, pgRODSN, m.EventsTotal)
		if err != nil {
			return nil, fmt.Errorf("failed to initialize PostgreSQL: %w", err)
		}
		if err := checkSchema(pgStore); err != nil {
			pgStore.Close()
			return nil, err
		}
		slog.Info("PostgreSQL connected successfully")
	} else {
		slog.Warn("PostgreSQL not configured (PG_RW_DSN/PG_RO_DSN not set), /items routes unavailable")
	}

	// A nil *PostgresStore stored in the interface would not compare equal to
	// nil in the handlers: pass a nil interface when PostgreSQL is not configured
	var items handlers.ItemStore
	if pgStore != nil {
		items = pgStore
	}
	h := handlers.NewHandler(redisStore, items, m)

	mux := http.NewServeMux()
	// Kubernetes probes (probes.go), and /health: dependency report for humans
	mux.HandleFunc("GET /livez", a.livez)
	mux.HandleFunc("GET /readyz", a.readyz)
	mux.HandleFunc("/health", h.Health)
	mux.HandleFunc("/hello", h.Hello)
	mux.Handle("/metrics", promhttp.Handler())

	// Items CRUD routes (require PostgreSQL)
	mux.HandleFunc("GET /items", h.GetItems)
	mux.HandleFunc("POST /items", h.CreateItem)
	mux.HandleFunc("GET /items/{id}", h.GetItem)
	mux.HandleFunc("DELETE /items/{id}", h.DeleteItem)

	// Event log — audit trail (append-only, read from replica)
	mux.HandleFunc("GET /events", h.GetEvents)

	// pprof endpoints for profiling (CPU, memory, goroutines)
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)

	handler := middleware.Recovery(
		middleware.Tracing("lumen-api")(
			middleware.Logging(
				middleware.Metrics(m)(
					middleware.BodyLimit(1<<20)( // 1 MiB — largest legitimate payload is a small JSON
						middleware.Idempotency(redisStore, http.MethodPost, http.MethodDelete)(mux),
					),
				),
			),
		),
	)

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      handler,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	a.store = redisStore
	a.pgStore = pgStore
	a.metrics = m
	a.server = server
	return a, nil
}

func (a *App) Run() error {

	serverErrors := make(chan error, 1)

	go func() {
		slog.Info("Server starting", "addr", a.server.Addr)
		slog.Info("Endpoints available",
			"probes", "/livez, /readyz",
			"health", "/health",
			"hello", "/hello",
			"items", "/items (POST/GET), /items/{id} (GET/DELETE)",
			"events", "/events (GET), /events?type=ItemCreated&limit=50",
			"metrics", "/metrics",
			"pprof", "/debug/pprof/",
		)

		serverErrors <- a.server.ListenAndServe()
	}()

	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, os.Interrupt, syscall.SIGTERM, syscall.SIGINT)

	select {
	case err := <-serverErrors:
		return fmt.Errorf("server error: %w", err)

	case sig := <-shutdown:
		slog.Info("Received signal, starting graceful shutdown", "signal", sig.String())

		// Drain delay + in-flight requests must fit in 30s, below the pod's
		// terminationGracePeriodSeconds (45s in 03-lumen-api.yaml)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		if err := a.shutdown(ctx); err != nil {
			slog.Error("Error during server shutdown", "error", err)
			if closeErr := a.server.Close(); closeErr != nil {
				return fmt.Errorf("could not stop server: %w", closeErr)
			}
		}

		if err := a.store.Close(); err != nil {
			slog.Error("Error closing Redis", "error", err)
		}

		if a.pgStore != nil {
			a.pgStore.Close()
		}

		slog.Info("Server stopped gracefully")
	}

	return nil
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
