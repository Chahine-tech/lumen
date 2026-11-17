package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/Chahine-tech/lumen/internal/auth"
	"github.com/Chahine-tech/lumen/internal/handlers"
	"github.com/Chahine-tech/lumen/internal/metrics"
	"github.com/Chahine-tech/lumen/internal/middleware"
	"github.com/Chahine-tech/lumen/internal/store"
)

type App struct {
	store   *store.RedisStore
	pgStore *store.PostgresStore
	metrics *metrics.Metrics
	server  *http.Server
	// adminServer serves /metrics and, when enabled, pprof (admin.go)
	adminServer *http.Server

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
	adminPort       := getEnv("ADMIN_PORT", "9090")
	pprofEnabled    := getEnv("PPROF_ENABLED", "false") == "true"

	authMode, err := auth.ParseMode(getEnv("AUTH_MODE", ""))
	if err != nil {
		return nil, err
	}
	authConfig, err := loadAuthConfig(getEnv("AUTH_CONFIG", ""), authMode)
	if err != nil {
		return nil, err
	}
	rateLimit, err := strconv.ParseInt(getEnv("CALLER_RATE_LIMIT", "50"), 10, 64)
	if err != nil || rateLimit < 0 {
		return nil, fmt.Errorf("invalid CALLER_RATE_LIMIT: must be a number of requests per second, 0 to disable")
	}

	drainDelay, err := time.ParseDuration(getEnv("SHUTDOWN_DRAIN_DELAY", "5s"))
	if err != nil {
		return nil, fmt.Errorf("invalid SHUTDOWN_DRAIN_DELAY: %w", err)
	}
	a := &App{drainDelay: drainDelay}

	pgRWDSN := getEnv("PG_RW_DSN", "")
	pgRODSN := getEnv("PG_RO_DSN", "")

	slog.Info("Connecting to Redis", "addr", redisAddr, "mode", redisMode)
	var redisStore *store.RedisStore
	err = waitFor("redis", startupTimeout, startupRetry, func(context.Context) error {
		// NewRedisStore pings with its own 5s timeout
		s, err := store.NewRedisStore(redisAddr, redisMode, sentinelAddrs, redisMasterName, redisPassword)
		redisStore = s
		return err
	})
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
		// The pools connect lazily: the first query is the connection test
		if err := waitFor("postgresql", startupTimeout, startupRetry, pgStore.Ping); err != nil {
			pgStore.Close()
			_ = redisStore.Close()
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

	authn, err := auth.New(authConfig, authMode, func(result string) {
		m.AuthResultsTotal.WithLabelValues(result, string(authMode)).Inc()
	})
	if err != nil {
		return nil, err
	}
	slog.Info("Authentication configured", "mode", authMode, "issuers", len(authConfig.Issuers),
		"caller_rate_limit", rateLimit)

	mux := a.publicMux(h, authn)

	// Authenticate before the rate limit and the idempotency record, which
	// are kept per caller. The kubelet probes carry no token.
	handler := middleware.Recovery(
		middleware.Tracing("lumen-api")(
			middleware.Logging(
				middleware.Metrics(m)(
					authn.Authenticate("/livez", "/readyz")(
						middleware.CallerRateLimit(redisStore, rateLimit, m.RateLimitedTotal.Inc)(
							middleware.BodyLimit(1<<20)( // 1 MiB: the largest legitimate payload is a small JSON
								middleware.Idempotency(redisStore, http.MethodPost, http.MethodDelete)(mux),
							),
						),
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

	a.adminServer = newAdminServer(":"+adminPort, pprofEnabled)

	a.store = redisStore
	a.pgStore = pgStore
	a.metrics = m
	a.server = server
	return a, nil
}

// publicMux holds the routes served on PORT: the API and the probes. The
// metrics and pprof are on the admin listener, which is neither routed by
// Traefik nor reachable from outside the monitoring namespace. Each API
// route checks the permission of its operation (auth.Config.Permissions);
// /hello needs an authenticated caller only.
func (a *App) publicMux(h *handlers.Handler, authn *auth.Authenticator) *http.ServeMux {
	mux := http.NewServeMux()
	// Kubernetes probes (probes.go), and /health: dependency report for humans
	mux.HandleFunc("GET /livez", a.livez)
	mux.HandleFunc("GET /readyz", a.readyz)
	mux.HandleFunc("/health", h.Health)
	mux.HandleFunc("/hello", h.Hello)

	// Items CRUD routes (require PostgreSQL)
	mux.HandleFunc("GET /items", authn.Require(auth.OpItemsRead, h.GetItems))
	mux.HandleFunc("POST /items", authn.Require(auth.OpItemsCreate, h.CreateItem))
	mux.HandleFunc("GET /items/{id}", authn.Require(auth.OpItemsRead, h.GetItem))
	mux.HandleFunc("DELETE /items/{id}", authn.Require(auth.OpItemsDelete, h.DeleteItem))

	// Event log: audit trail (append-only, read from replica)
	mux.HandleFunc("GET /events", authn.Require(auth.OpEventsRead, h.GetEvents))
	return mux
}

func (a *App) Run() error {

	serverErrors := make(chan error, 2)

	go func() {
		slog.Info("Server starting", "addr", a.server.Addr)
		slog.Info("Endpoints available",
			"probes", "/livez, /readyz",
			"health", "/health",
			"hello", "/hello",
			"items", "/items (POST/GET), /items/{id} (GET/DELETE)",
			"events", "/events (GET), /events?type=ItemCreated&limit=50",
		)

		serverErrors <- a.server.ListenAndServe()
	}()

	go func() {
		slog.Info("Admin server starting", "addr", a.adminServer.Addr)
		serverErrors <- fmt.Errorf("admin: %w", a.adminServer.ListenAndServe())
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
			if closeErr := errors.Join(a.server.Close(), a.adminServer.Close()); closeErr != nil {
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

// loadAuthConfig reads AUTH_CONFIG. Without it, report mode runs with no
// issuer (every request is served without a caller, for a local run);
// enforce mode refuses to start.
func loadAuthConfig(path string, mode auth.Mode) (*auth.Config, error) {
	if path != "" {
		return auth.LoadConfig(path)
	}
	if mode == auth.Report {
		slog.Warn("AUTH_CONFIG not set: no token issuer, every request is served without a caller (report mode)")
		return &auth.Config{}, nil
	}
	return nil, fmt.Errorf("AUTH_CONFIG is not set: required with AUTH_MODE=%s", auth.Enforce)
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
