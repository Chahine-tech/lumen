package app

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/pprof"
	"os"
	"os/signal"
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
}

func NewApp() (*App, error) {
	redisAddr       := getEnv("REDIS_ADDR", "localhost:6379")
	redisMode       := getEnv("REDIS_MODE", "standalone")
	sentinelAddrs   := getEnv("REDIS_SENTINEL_ADDRS", "")
	redisMasterName := getEnv("REDIS_MASTER_NAME", "mymaster")
	port            := getEnv("PORT", "8080")

	pgRWDSN := getEnv("PG_RW_DSN", "")
	pgRODSN := getEnv("PG_RO_DSN", "")

	slog.Info("Connecting to Redis", "addr", redisAddr, "mode", redisMode)
	redisStore, err := store.NewRedisStore(redisAddr, redisMode, sentinelAddrs, redisMasterName)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize Redis: %w", err)
	}
	slog.Info("Redis connected successfully")

	var pgStore *store.PostgresStore
	if pgRWDSN != "" && pgRODSN != "" {
		slog.Info("Connecting to PostgreSQL")
		pgStore, err = store.NewPostgresStore(context.Background(), pgRWDSN, pgRODSN)
		if err != nil {
			return nil, fmt.Errorf("failed to initialize PostgreSQL: %w", err)
		}
		slog.Info("PostgreSQL connected successfully")
	} else {
		slog.Warn("PostgreSQL not configured (PG_RW_DSN/PG_RO_DSN not set), /items routes unavailable")
	}

	m := metrics.NewMetrics()
	m.RedisConnectionStatus.Set(1)

	h := handlers.NewHandler(redisStore, pgStore, m)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", h.Health)
	mux.HandleFunc("/hello", h.Hello)
	mux.Handle("/metrics", promhttp.Handler())

	// Items CRUD routes (require PostgreSQL)
	mux.HandleFunc("/items", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost:
			h.CreateItem(w, r)
		case http.MethodGet:
			h.GetItems(w, r)
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	})
	mux.HandleFunc("/items/", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			h.GetItem(w, r)
		case http.MethodDelete:
			h.DeleteItem(w, r)
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	})

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
					middleware.Idempotency(redisStore, http.MethodPost, http.MethodDelete)(mux),
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

	return &App{
		store:   redisStore,
		pgStore: pgStore,
		metrics: m,
		server:  server,
	}, nil
}

func (a *App) Run() error {

	serverErrors := make(chan error, 1)

	go func() {
		slog.Info("Server starting", "addr", a.server.Addr)
		slog.Info("Endpoints available",
			"health", "/health",
			"hello", "/hello",
			"items", "/items (POST/GET), /items/{id} (GET/DELETE)",
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

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		if err := a.server.Shutdown(ctx); err != nil {
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
