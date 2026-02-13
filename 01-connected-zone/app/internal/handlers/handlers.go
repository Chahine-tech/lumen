package handlers

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/Chahine-tech/lumen/internal/metrics"
	"github.com/Chahine-tech/lumen/internal/store"
)

type Handler struct {
	store   *store.RedisStore
	metrics *metrics.Metrics
}

func NewHandler(store *store.RedisStore, metrics *metrics.Metrics) *Handler {
	return &Handler{
		store:   store,
		metrics: metrics,
	}
}

type HealthResponse struct {
	Status string            `json:"status"`
	Checks map[string]string `json:"checks"`
}

type InfoResponse struct {
	Message string `json:"message"`
	Counter int64  `json:"counter"`
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("Error encoding JSON: %v", err)
	}
}

func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
	checks := make(map[string]string)
	status := "healthy"

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

func (h *Handler) Hello(w http.ResponseWriter, r *http.Request) {
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
