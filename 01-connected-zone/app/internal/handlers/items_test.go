package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/Chahine-tech/lumen/internal/store"
)

// fakeItemStore is an in-memory ItemStore. err, when set, is returned by
// every call, to simulate PostgreSQL being down.
type fakeItemStore struct {
	items map[int]store.Item
	err   error
	// replicaErr is returned by PingReplica only
	replicaErr error
	// arguments of the last GetItems call
	lastLimit, lastBefore int
}

func newFakeItemStore() *fakeItemStore {
	return &fakeItemStore{items: map[int]store.Item{1: {ID: 1, Name: "alpha"}}}
}

func (f *fakeItemStore) Ping(context.Context) error { return f.err }

func (f *fakeItemStore) PingReplica(context.Context) error { return f.replicaErr }

func (f *fakeItemStore) CreateItem(_ context.Context, name string) (store.Item, error) {
	if f.err != nil {
		return store.Item{}, f.err
	}
	it := store.Item{ID: len(f.items) + 1, Name: name}
	f.items[it.ID] = it
	return it, nil
}

// GetItems mimics the SQL: newest first, ids below beforeID, at most limit.
func (f *fakeItemStore) GetItems(_ context.Context, limit, beforeID int) ([]store.Item, error) {
	if f.err != nil {
		return nil, f.err
	}
	f.lastLimit, f.lastBefore = limit, beforeID
	var out []store.Item
	for id := len(f.items) + 1000; id > 0 && len(out) < limit; id-- {
		if it, ok := f.items[id]; ok && (beforeID == 0 || id < beforeID) {
			out = append(out, it)
		}
	}
	return out, nil
}

func (f *fakeItemStore) GetItem(_ context.Context, id int) (store.Item, error) {
	if f.err != nil {
		return store.Item{}, f.err
	}
	it, ok := f.items[id]
	if !ok {
		return store.Item{}, store.ErrNotFound
	}
	return it, nil
}

func (f *fakeItemStore) DeleteItem(_ context.Context, id int) error {
	if f.err != nil {
		return f.err
	}
	if _, ok := f.items[id]; !ok {
		return store.ErrNotFound
	}
	delete(f.items, id)
	return nil
}

func (f *fakeItemStore) GetEvents(context.Context, string, int) ([]store.Event, error) {
	return nil, f.err
}

var errDBDown = errors.New("dial tcp 10.43.0.10:5432: connect: connection refused")

// serve routes the request through a mux with the same patterns as app.go,
// and turns a panic into a test failure instead of crashing the test binary.
func serve(t *testing.T, h *Handler, req *http.Request) *httptest.ResponseRecorder {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /items", h.GetItems)
	mux.HandleFunc("POST /items", h.CreateItem)
	mux.HandleFunc("GET /items/{id}", h.GetItem)
	mux.HandleFunc("DELETE /items/{id}", h.DeleteItem)
	mux.HandleFunc("GET /events", h.GetEvents)
	rec := httptest.NewRecorder()
	defer func() {
		if p := recover(); p != nil {
			t.Fatalf("%s %s panicked: %v", req.Method, req.URL, p)
		}
	}()
	mux.ServeHTTP(rec, req)
	return rec
}

func TestGetItemStatusCodes(t *testing.T) {
	cases := []struct {
		name string
		err  error
		id   string
		want int
	}{
		{"existing item", nil, "1", http.StatusOK},
		{"missing item", nil, "999", http.StatusNotFound},
		{"invalid id", nil, "abc", http.StatusBadRequest},
		// A database outage is a server error: it must count against the
		// availability SLO and the canary analysis (5xx), not look like a 404
		{"database down", errDBDown, "1", http.StatusInternalServerError},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newFakeItemStore()
			s.err = tc.err
			rec := serve(t, NewHandler(nil, s, nil), httptest.NewRequest(http.MethodGet, "/items/"+tc.id, nil))
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d (body %s)", rec.Code, tc.want, rec.Body)
			}
		})
	}
}

func TestDeleteItemStatusCodes(t *testing.T) {
	cases := []struct {
		name string
		err  error
		id   string
		want int
	}{
		{"existing item", nil, "1", http.StatusNoContent},
		{"missing item", nil, "999", http.StatusNotFound},
		{"database down", errDBDown, "1", http.StatusInternalServerError},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newFakeItemStore()
			s.err = tc.err
			rec := serve(t, NewHandler(nil, s, nil), httptest.NewRequest(http.MethodDelete, "/items/"+tc.id, nil))
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d (body %s)", rec.Code, tc.want, rec.Body)
			}
		})
	}
}

func TestCreateItemValidation(t *testing.T) {
	cases := []struct {
		name string
		body string
		want int
	}{
		{"valid", `{"name":"alpha"}`, http.StatusCreated},
		{"missing name", `{}`, http.StatusBadRequest},
		{"blank name", `{"name":"   "}`, http.StatusBadRequest},
		{"name too long", `{"name":"` + strings.Repeat("x", maxItemNameLength+1) + `"}`, http.StatusBadRequest},
		{"name at the limit", `{"name":"` + strings.Repeat("x", maxItemNameLength) + `"}`, http.StatusCreated},
		{"control character", `{"name":"a\u0000b"}`, http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/items", strings.NewReader(tc.body))
			rec := serve(t, NewHandler(nil, newFakeItemStore(), nil), req)
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d (body %s)", rec.Code, tc.want, rec.Body)
			}
		})
	}
}

func TestCreateItemDatabaseDown(t *testing.T) {
	s := newFakeItemStore()
	s.err = errDBDown
	rec := serve(t, NewHandler(nil, s, nil), httptest.NewRequest(http.MethodPost, "/items", strings.NewReader(`{"name":"alpha"}`)))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
}

// Without PostgreSQL configured, the routes must answer 503, not panic on a
// nil store.
func TestRoutesWithoutPostgres(t *testing.T) {
	h := NewHandler(nil, nil, nil)
	for _, r := range []struct{ method, path, body string }{
		{http.MethodGet, "/items", ""},
		{http.MethodPost, "/items", `{"name":"alpha"}`},
		{http.MethodGet, "/items/1", ""},
		{http.MethodDelete, "/items/1", ""},
		{http.MethodGet, "/events", ""},
	} {
		t.Run(r.method+" "+r.path, func(t *testing.T) {
			rec := serve(t, h, httptest.NewRequest(r.method, r.path, strings.NewReader(r.body)))
			if rec.Code != http.StatusServiceUnavailable {
				t.Fatalf("status = %d, want 503", rec.Code)
			}
		})
	}
}

func TestGetItemsPagination(t *testing.T) {
	s := newFakeItemStore()
	for i := 2; i <= 5; i++ {
		s.items[i] = store.Item{ID: i, Name: "item"}
	}
	cases := []struct {
		name       string
		query      string
		want       int
		wantLimit  int
		wantBefore int
		wantIDs    string
		wantNext   string
	}{
		{"defaults", "", http.StatusOK, defaultItemsLimit, 0, "5,4,3,2,1", ""},
		{"first page full", "?limit=2", http.StatusOK, 2, 0, "5,4", "4"},
		{"next page", "?limit=2&before=4", http.StatusOK, 2, 4, "3,2", "2"},
		{"last page", "?limit=2&before=2", http.StatusOK, 2, 2, "1", ""},
		{"limit at maximum", "?limit=1000", http.StatusOK, maxItemsLimit, 0, "5,4,3,2,1", ""},
		{"limit too high", "?limit=1001", http.StatusBadRequest, 0, 0, "", ""},
		{"limit zero", "?limit=0", http.StatusBadRequest, 0, 0, "", ""},
		{"limit not a number", "?limit=ten", http.StatusBadRequest, 0, 0, "", ""},
		{"before not positive", "?before=0", http.StatusBadRequest, 0, 0, "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s.lastLimit, s.lastBefore = 0, 0
			rec := serve(t, NewHandler(nil, s, nil), httptest.NewRequest(http.MethodGet, "/items"+tc.query, nil))
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d (body %s)", rec.Code, tc.want, rec.Body)
			}
			if tc.want != http.StatusOK {
				if s.lastLimit != 0 {
					t.Fatalf("store queried despite the invalid parameters")
				}
				return
			}
			if s.lastLimit != tc.wantLimit || s.lastBefore != tc.wantBefore {
				t.Fatalf("store called with limit=%d before=%d, want %d %d", s.lastLimit, s.lastBefore, tc.wantLimit, tc.wantBefore)
			}
			var items []store.Item
			if err := json.NewDecoder(rec.Body).Decode(&items); err != nil {
				t.Fatal(err)
			}
			ids := make([]string, len(items))
			for i, it := range items {
				ids[i] = strconv.Itoa(it.ID)
			}
			if got := strings.Join(ids, ","); got != tc.wantIDs {
				t.Fatalf("ids = %s, want %s", got, tc.wantIDs)
			}
			if got := rec.Header().Get("X-Next-Before"); got != tc.wantNext {
				t.Fatalf("X-Next-Before = %q, want %q", got, tc.wantNext)
			}
		})
	}
}

func TestGetItemsDatabaseDown(t *testing.T) {
	s := newFakeItemStore()
	s.err = errDBDown
	rec := serve(t, NewHandler(nil, s, nil), httptest.NewRequest(http.MethodGet, "/items", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
}
