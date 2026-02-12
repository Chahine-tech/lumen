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

// App represents the application
type App struct {
	store   *store.RedisStore
	metrics *metrics.Metrics
	server  *http.Server
}

// NewApp creates a new application instance
func NewApp() (*App, error) {
	// Get configuration from environment
	redisAddr := getEnv("REDIS_ADDR", "localhost:6379")
	port := getEnv("PORT", "8080")

	// Initialize Redis store
	log.Printf("Connecting to Redis at %s...", redisAddr)
	redisStore, err := store.NewRedisStore(redisAddr)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize Redis: %w", err)
	}
	log.Println("Redis connected successfully")

	// Initialize metrics
	m := metrics.NewMetrics()
	m.RedisConnectionStatus.Set(1) // Redis is connected

	// Initialize handlers
	h := handlers.NewHandler(redisStore, m)

	// Setup routes
	mux := http.NewServeMux()
	mux.HandleFunc("/health", h.Health)
	mux.HandleFunc("/hello", h.Hello)
	mux.Handle("/metrics", promhttp.Handler())

	// Wrap with middleware
	handler := middleware.Recovery(
		middleware.Logging(
			middleware.Metrics(m)(mux),
		),
	)

	// Create HTTP server with timeouts
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

// Run starts the application with graceful shutdown
func (a *App) Run() error {
	// Channel to listen for errors from the server
	serverErrors := make(chan error, 1)

	// Start HTTP server in a goroutine
	go func() {
		log.Printf("Server starting on %s", a.server.Addr)
		log.Println("Endpoints:")
		log.Println("  GET /hello   - Main endpoint with counter")
		log.Println("  GET /health  - Health check")
		log.Println("  GET /metrics - Prometheus metrics")

		serverErrors <- a.server.ListenAndServe()
	}()

	// Channel to listen for interrupt signals
	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, os.Interrupt, syscall.SIGTERM, syscall.SIGINT)

	// Block until we receive a signal or error
	select {
	case err := <-serverErrors:
		return fmt.Errorf("server error: %w", err)

	case sig := <-shutdown:
		log.Printf("Received signal: %v. Starting graceful shutdown...", sig)

		// Give outstanding requests 30 seconds to complete
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		// Shutdown HTTP server
		if err := a.server.Shutdown(ctx); err != nil {
			log.Printf("Error during server shutdown: %v", err)
			// Force close if graceful shutdown fails
			if closeErr := a.server.Close(); closeErr != nil {
				return fmt.Errorf("could not stop server: %w", closeErr)
			}
		}

		// Close Redis connection
		if err := a.store.Close(); err != nil {
			log.Printf("Error closing Redis: %v", err)
		}

		log.Println("Server stopped gracefully")
	}

	return nil
}

// getEnv gets environment variable or returns default
func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
