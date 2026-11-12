package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/Chahine-tech/lumen/internal/store"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
)

type createItemRequest struct {
	Name string `json:"name"`
}

// requireStore answers 503 when PostgreSQL is not configured. Returns false
// when the handler must stop.
func (h *Handler) requireStore(w http.ResponseWriter) bool {
	if h.pgStore == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "database not configured"})
		return false
	}
	return true
}

// dbContext bounds a store call: the server's WriteTimeout does not cancel the
// request context, so a hung query would otherwise hold its connection.
func dbContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(ctx, dbTimeout)
}

// writeStoreError maps store errors to status codes: ErrNotFound is the only
// 404. Anything else means the database could not answer, a 5xx that counts
// against the availability SLO and the canary analysis.
func writeStoreError(w http.ResponseWriter, err error, notFoundMsg, failureMsg string) {
	if errors.Is(err, store.ErrNotFound) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": notFoundMsg})
		return
	}
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": failureMsg})
}

// validateItemName returns the trimmed name, or an error message.
func validateItemName(name string) (string, string) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", "field 'name' is required"
	}
	if utf8.RuneCountInString(name) > maxItemNameLength {
		return "", "field 'name' must be at most " + strconv.Itoa(maxItemNameLength) + " characters"
	}
	if strings.IndexFunc(name, unicode.IsControl) >= 0 {
		return "", "field 'name' must not contain control characters"
	}
	return name, ""
}

func (h *Handler) CreateItem(w http.ResponseWriter, r *http.Request) {
	if !h.requireStore(w) {
		return
	}
	ctx, span := tracer.Start(r.Context(), "items.create")
	defer span.End()

	var req createItemRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "request body too large"})
			return
		}
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}
	name, problem := validateItemName(req.Name)
	if problem != "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": problem})
		return
	}

	dbCtx, cancel := dbContext(ctx)
	defer cancel()
	_, dbSpan := tracer.Start(dbCtx, "db.insert.item")
	dbSpan.SetAttributes(attribute.String("db.operation", "INSERT"), attribute.String("db.table", "items"))
	item, err := h.pgStore.CreateItem(dbCtx, name)
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

// GetItems returns the newest items first. Query parameters: limit (1 to
// maxItemsLimit, default defaultItemsLimit) and before (an item id: returns
// the older ones). When the page is full, X-Next-Before holds the cursor for
// the next page.
func (h *Handler) GetItems(w http.ResponseWriter, r *http.Request) {
	if !h.requireStore(w) {
		return
	}
	ctx, span := tracer.Start(r.Context(), "items.list")
	defer span.End()

	limit := defaultItemsLimit
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > maxItemsLimit {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "limit must be between 1 and " + strconv.Itoa(maxItemsLimit)})
			return
		}
		limit = n
	}
	before := 0
	if v := r.URL.Query().Get("before"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "before must be a positive item id"})
			return
		}
		before = n
	}

	dbCtx, cancel := dbContext(ctx)
	defer cancel()
	_, dbSpan := tracer.Start(dbCtx, "db.select.items")
	dbSpan.SetAttributes(attribute.String("db.operation", "SELECT"), attribute.String("db.table", "items"))
	items, err := h.pgStore.GetItems(dbCtx, limit, before)
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
	if len(items) == limit {
		w.Header().Set("X-Next-Before", strconv.Itoa(items[len(items)-1].ID))
	}
	span.SetAttributes(attribute.Int("items.count", len(items)))
	writeJSON(w, http.StatusOK, items)
}

func (h *Handler) GetItem(w http.ResponseWriter, r *http.Request) {
	if !h.requireStore(w) {
		return
	}
	ctx, span := tracer.Start(r.Context(), "items.get")
	defer span.End()

	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid id"})
		return
	}

	dbCtx, cancel := dbContext(ctx)
	defer cancel()
	_, dbSpan := tracer.Start(dbCtx, "db.select.item")
	dbSpan.SetAttributes(attribute.String("db.operation", "SELECT"), attribute.Int("db.item.id", id))
	item, err := h.pgStore.GetItem(dbCtx, id)
	if err != nil {
		if !errors.Is(err, store.ErrNotFound) {
			dbSpan.RecordError(err)
			dbSpan.SetStatus(codes.Error, err.Error())
			slog.Error("Failed to get item", "id", id, "error", err)
		}
		dbSpan.End()
		writeStoreError(w, err, "item not found", "failed to get item")
		return
	}
	dbSpan.End()

	span.SetAttributes(attribute.Int("item.id", item.ID))
	writeJSON(w, http.StatusOK, item)
}

func (h *Handler) DeleteItem(w http.ResponseWriter, r *http.Request) {
	if !h.requireStore(w) {
		return
	}
	ctx, span := tracer.Start(r.Context(), "items.delete")
	defer span.End()

	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid id"})
		return
	}

	dbCtx, cancel := dbContext(ctx)
	defer cancel()
	_, dbSpan := tracer.Start(dbCtx, "db.delete.item")
	dbSpan.SetAttributes(attribute.String("db.operation", "DELETE"), attribute.Int("db.item.id", id))
	if err := h.pgStore.DeleteItem(dbCtx, id); err != nil {
		if !errors.Is(err, store.ErrNotFound) {
			dbSpan.RecordError(err)
			dbSpan.SetStatus(codes.Error, err.Error())
			slog.Error("Failed to delete item", "id", id, "error", err)
		}
		dbSpan.End()
		writeStoreError(w, err, "item not found", "failed to delete item")
		return
	}
	dbSpan.End()

	span.SetAttributes(attribute.Int("item.id", id))
	w.WriteHeader(http.StatusNoContent)
}
