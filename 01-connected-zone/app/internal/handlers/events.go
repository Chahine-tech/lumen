package handlers

import (
	"log/slog"
	"net/http"
	"strconv"

	"github.com/Chahine-tech/lumen/internal/store"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
)

func (h *Handler) GetEvents(w http.ResponseWriter, r *http.Request) {
	ctx, span := tracer.Start(r.Context(), "events.list")
	defer span.End()

	eventType := r.URL.Query().Get("type")
	limit := 100
	if l := r.URL.Query().Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 && n <= 1000 {
			limit = n
		}
	}

	span.SetAttributes(
		attribute.String("events.filter.type", eventType),
		attribute.Int("events.limit", limit),
	)

	_, dbSpan := tracer.Start(ctx, "db.select.events")
	dbSpan.SetAttributes(attribute.String("db.operation", "SELECT"), attribute.String("db.table", "events"))
	events, err := h.pgStore.GetEvents(ctx, eventType, limit)
	if err != nil {
		dbSpan.RecordError(err)
		dbSpan.SetStatus(codes.Error, err.Error())
		dbSpan.End()
		slog.Error("Failed to get events", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to get events"})
		return
	}
	dbSpan.SetAttributes(attribute.Int("db.result.count", len(events)))
	dbSpan.End()

	if events == nil {
		events = []store.Event{}
	}
	span.SetAttributes(attribute.Int("events.count", len(events)))
	writeJSON(w, http.StatusOK, events)
}
