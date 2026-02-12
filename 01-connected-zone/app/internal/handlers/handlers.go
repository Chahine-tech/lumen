package handlers

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/Chahine-tech/lumen/internal/metrics"
	"github.com/Chahine-tech/lumen/internal/store"
)

// Handler holds dependencies for HTTP handlers
type Handler struct {
	store   *store.RedisStore
	metrics *metrics.Metrics
}

// NewHandler creates a new handler with dependencies
func NewHandler(store *store.RedisStore, metrics *metrics.Metrics) *Handler {
	return &Handler{
		store:   store,
		metrics: metrics,
	}
}

// HealthResponse represents health check response
type HealthResponse struct {
	Status string            `json:"status"`
	Checks map[string]string `json:"checks"`
}

// InfoResponse represents info endpoint response
type InfoResponse struct {
	Message string `json:"message"`
	Counter int64  `json:"counter"`
}

// writeJSON writes JSON response with error handling
func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("Error encoding JSON: %v", err)
	}
}

// Health handles health check endpoint
func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
	checks := make(map[string]string)
	status := "healthy"

	// Check Redis using request context
	if err := h.store.Ping(r.Context()); err != nil {
		checks["redis"] = "unhealthy"
		status = "degraded"
		h.metrics.RedisConnectionStatus.Set(0)
	} else {
		checks["redis"] = "healthy"
		h.metrics.RedisConnectionStatus.Set(1)
	}

	response := HealthResponse{
		Status: status,
		Checks: checks,
	}

	if status != "healthy" {
		writeJSON(w, http.StatusServiceUnavailable, response)
	} else {
		writeJSON(w, http.StatusOK, response)
	}
}

// Hello handles main application endpoint
func (h *Handler) Hello(w http.ResponseWriter, r *http.Request) {
	// Increment counter using request context
	counter, err := h.store.IncrementCounter(r.Context(), "hello_counter")
	if err != nil {
		log.Printf("Redis error: %v", err)
		counter = 0 // fallback
	}

	response := InfoResponse{
		Message: "Hello World from Lumen Airgap!",
		Counter: counter,
	}

	writeJSON(w, http.StatusOK, response)
}
