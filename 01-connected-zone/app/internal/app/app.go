package app

import (
	"context"
	"fmt"
	"log"
	"net/http"
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
	metrics *metrics.Metrics
	server  *http.Server
}

func NewApp() (*App, error) {
	redisAddr := getEnv("REDIS_ADDR", "localhost:6379")
	port := getEnv("PORT", "8080")

	log.Printf("Connecting to Redis at %s...", redisAddr)
	redisStore, err := store.NewRedisStore(redisAddr)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize Redis: %w", err)
	}
	log.Println("Redis connected successfully")

	m := metrics.NewMetrics()
	m.RedisConnectionStatus.Set(1)

	h := handlers.NewHandler(redisStore, m)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", h.Health)
	mux.HandleFunc("/hello", h.Hello)
	mux.Handle("/metrics", promhttp.Handler())

	handler := middleware.Recovery(
		middleware.Logging(
			middleware.Metrics(m)(mux),
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
		metrics: m,
		server:  server,
	}, nil
}

func (a *App) Run() error {

	serverErrors := make(chan error, 1)

	go func() {
		log.Printf("Server starting on %s", a.server.Addr)
		log.Println("Endpoints:")
		log.Println("  GET /hello   - Main endpoint with counter")
		log.Println("  GET /health  - Health check")
		log.Println("  GET /metrics - Prometheus metrics")

		serverErrors <- a.server.ListenAndServe()
	}()

	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, os.Interrupt, syscall.SIGTERM, syscall.SIGINT)

	select {
	case err := <-serverErrors:
		return fmt.Errorf("server error: %w", err)

	case sig := <-shutdown:
		log.Printf("Received signal: %v. Starting graceful shutdown...", sig)

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		if err := a.server.Shutdown(ctx); err != nil {
			log.Printf("Error during server shutdown: %v", err)
			if closeErr := a.server.Close(); closeErr != nil {
				return fmt.Errorf("could not stop server: %w", closeErr)
			}
		}

		if err := a.store.Close(); err != nil {
			log.Printf("Error closing Redis: %v", err)
		}

		log.Println("Server stopped gracefully")
	}

	return nil
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
