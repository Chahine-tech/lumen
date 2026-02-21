package handlers

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/Chahine-tech/lumen/internal/store"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
)

type createItemRequest struct {
	Name string `json:"name"`
}

func (h *Handler) CreateItem(w http.ResponseWriter, r *http.Request) {
	ctx, span := tracer.Start(r.Context(), "items.create")
	defer span.End()

	var req createItemRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "field 'name' is required"})
		return
	}

	_, dbSpan := tracer.Start(ctx, "db.insert.item")
	dbSpan.SetAttributes(attribute.String("db.operation", "INSERT"), attribute.String("db.table", "items"))
	item, err := h.pgStore.CreateItem(ctx, req.Name)
	if err != nil {
		dbSpan.RecordError(err)
		dbSpan.SetStatus(codes.Error, err.Error())
		dbSpan.End()
		slog.Error("Failed to create item", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to create item"})
		return
	}
	dbSpan.SetAttributes(attribute.Int("db.item.id", item.ID))
	dbSpan.End()

	span.SetAttributes(attribute.Int("item.id", item.ID))
	writeJSON(w, http.StatusCreated, item)
}

func (h *Handler) GetItems(w http.ResponseWriter, r *http.Request) {
	ctx, span := tracer.Start(r.Context(), "items.list")
	defer span.End()

	_, dbSpan := tracer.Start(ctx, "db.select.items")
	dbSpan.SetAttributes(attribute.String("db.operation", "SELECT"), attribute.String("db.table", "items"))
	items, err := h.pgStore.GetItems(ctx)
	if err != nil {
		dbSpan.RecordError(err)
		dbSpan.SetStatus(codes.Error, err.Error())
		dbSpan.End()
		slog.Error("Failed to get items", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to get items"})
		return
	}
	dbSpan.SetAttributes(attribute.Int("db.result.count", len(items)))
	dbSpan.End()

	if items == nil {
		items = []store.Item{}
	}
	span.SetAttributes(attribute.Int("items.count", len(items)))
	writeJSON(w, http.StatusOK, items)
}

func (h *Handler) GetItem(w http.ResponseWriter, r *http.Request) {
	ctx, span := tracer.Start(r.Context(), "items.get")
	defer span.End()

	id, err := parseID(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid id"})
		return
	}

	_, dbSpan := tracer.Start(ctx, "db.select.item")
	dbSpan.SetAttributes(attribute.String("db.operation", "SELECT"), attribute.Int("db.item.id", id))
	item, err := h.pgStore.GetItem(ctx, id)
	if err != nil {
		dbSpan.RecordError(err)
		dbSpan.SetStatus(codes.Error, err.Error())
		dbSpan.End()
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "item not found"})
		return
	}
	dbSpan.End()

	span.SetAttributes(attribute.Int("item.id", item.ID))
	writeJSON(w, http.StatusOK, item)
}

func (h *Handler) DeleteItem(w http.ResponseWriter, r *http.Request) {
	ctx, span := tracer.Start(r.Context(), "items.delete")
	defer span.End()

	id, err := parseID(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid id"})
		return
	}

	_, dbSpan := tracer.Start(ctx, "db.delete.item")
	dbSpan.SetAttributes(attribute.String("db.operation", "DELETE"), attribute.Int("db.item.id", id))
	if err := h.pgStore.DeleteItem(ctx, id); err != nil {
		dbSpan.RecordError(err)
		dbSpan.SetStatus(codes.Error, err.Error())
		dbSpan.End()
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "item not found"})
		return
	}
	dbSpan.End()

	span.SetAttributes(attribute.Int("item.id", id))
	w.WriteHeader(http.StatusNoContent)
}

func parseID(r *http.Request) (int, error) {
	parts := strings.Split(strings.TrimSuffix(r.URL.Path, "/"), "/")
	return strconv.Atoi(parts[len(parts)-1])
}
