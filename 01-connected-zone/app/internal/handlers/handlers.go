package handlers

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/Chahine-tech/lumen/internal/metrics"
	"github.com/Chahine-tech/lumen/internal/store"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
)

var tracer = otel.Tracer("lumen-api")

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
		slog.Error("Error encoding JSON", "error", err)
	}
}

func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
	ctx, span := tracer.Start(r.Context(), "health.check")
	defer span.End()

	checks := make(map[string]string)
	status := "healthy"

	_, redisSpan := tracer.Start(ctx, "redis.ping")
	if err := h.store.Ping(ctx); err != nil {
		redisSpan.RecordError(err)
		redisSpan.SetStatus(codes.Error, err.Error())
		checks["redis"] = "unhealthy"
		status = "degraded"
		h.metrics.RedisConnectionStatus.Set(0)
	} else {
		checks["redis"] = "healthy"
		h.metrics.RedisConnectionStatus.Set(1)
	}
	redisSpan.End()

	span.SetAttributes(attribute.String("health.status", status))

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
	ctx, span := tracer.Start(r.Context(), "hello.handler")
	defer span.End()

	_, redisSpan := tracer.Start(ctx, "redis.increment")
	counter, err := h.store.IncrementCounter(ctx, "hello_counter")
	if err != nil {
		redisSpan.RecordError(err)
		redisSpan.SetStatus(codes.Error, err.Error())
		slog.Error("Redis error", "error", err)
		counter = 0
	}
	redisSpan.SetAttributes(attribute.Int64("counter.value", counter))
	redisSpan.End()

	response := InfoResponse{
		Message: "Hello World from Lumen Airgap!",
		Counter: counter,
	}

	writeJSON(w, http.StatusOK, response)
}
