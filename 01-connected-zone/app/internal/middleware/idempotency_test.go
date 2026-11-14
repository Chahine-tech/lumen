package middleware

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeStore is an in-memory idempotencyStore for tests. getErr, lockErr and
// setErr simulate Redis failures.
type fakeStore struct {
	mu      sync.Mutex
	results map[string][]byte
	locks   map[string]string // key -> token
	getErr  error
	lockErr error
	setErr  error
}

func newFakeStore() *fakeStore {
	return &fakeStore{results: map[string][]byte{}, locks: map[string]string{}}
}

func (f *fakeStore) GetIdempotencyResult(_ context.Context, key string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.getErr != nil {
		return nil, f.getErr
	}
	return f.results[key], nil
}

func (f *fakeStore) SetIdempotencyResult(_ context.Context, key string, data []byte, _ time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.setErr != nil {
		return f.setErr
	}
	f.results[key] = data
	return nil
}

func (f *fakeStore) AcquireIdempotencyLock(_ context.Context, key, token string, _ time.Duration) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.lockErr != nil {
		return false, f.lockErr
	}
	if _, held := f.locks[key]; held {
		return false, nil
	}
	f.locks[key] = token
	return true, nil
}

func (f *fakeStore) ReleaseIdempotencyLock(_ context.Context, key, token string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.locks[key] == token {
		delete(f.locks, key)
	}
	return nil
}

func newRequest(key string) *http.Request {
	return newRequestTo(http.MethodPost, "/api/items", `{"name":"x"}`, key)
}

func newRequestTo(method, path, body, key string) *http.Request {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	return req
}

func TestIdempotencyReplaysCachedResponse(t *testing.T) {
	var calls atomic.Int32
	handler := Idempotency(newFakeStore(), http.MethodPost)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"id":1}`))
	}))

	first := httptest.NewRecorder()
	handler.ServeHTTP(first, newRequest("k1"))
	second := httptest.NewRecorder()
	handler.ServeHTTP(second, newRequest("k1"))

	if calls.Load() != 1 {
		t.Fatalf("handler called %d times, want 1", calls.Load())
	}
	if second.Code != http.StatusCreated || second.Body.String() != `{"id":1}` {
		t.Fatalf("replay mismatch: code=%d body=%q", second.Code, second.Body.String())
	}
	if second.Header().Get("Idempotency-Replayed") != "true" {
		t.Fatal("missing Idempotency-Replayed header on replay")
	}
}

func TestIdempotencyDoesNotCache5xx(t *testing.T) {
	var calls atomic.Int32
	handler := Idempotency(newFakeStore(), http.MethodPost)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 1 {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusCreated)
	}))

	first := httptest.NewRecorder()
	handler.ServeHTTP(first, newRequest("k1"))
	second := httptest.NewRecorder()
	handler.ServeHTTP(second, newRequest("k1"))

	if first.Code != http.StatusInternalServerError {
		t.Fatalf("first request: code=%d, want 500", first.Code)
	}
	if second.Code != http.StatusCreated {
		t.Fatalf("retry after 500: code=%d, want 201 (5xx must not be cached)", second.Code)
	}
	if calls.Load() != 2 {
		t.Fatalf("handler called %d times, want 2", calls.Load())
	}
}

func TestIdempotencyConcurrentDuplicateGetsConflict(t *testing.T) {
	var calls atomic.Int32
	entered := make(chan struct{})
	release := make(chan struct{})
	handler := Idempotency(newFakeStore(), http.MethodPost)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		close(entered)
		<-release
		w.WriteHeader(http.StatusCreated)
	}))

	first := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		handler.ServeHTTP(first, newRequest("k1"))
		close(done)
	}()
	<-entered // first request is inside the handler and holds the lock

	second := httptest.NewRecorder()
	handler.ServeHTTP(second, newRequest("k1"))
	if second.Code != http.StatusConflict {
		t.Fatalf("concurrent duplicate: code=%d, want 409", second.Code)
	}

	close(release)
	<-done
	if first.Code != http.StatusCreated {
		t.Fatalf("first request: code=%d, want 201", first.Code)
	}
	if calls.Load() != 1 {
		t.Fatalf("handler called %d times, want 1", calls.Load())
	}
}

func TestIdempotencyWithoutKeyIsPassthrough(t *testing.T) {
	var calls atomic.Int32
	handler := Idempotency(newFakeStore(), http.MethodPost)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusCreated)
	}))

	for i := 0; i < 2; i++ {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, newRequest(""))
		if rec.Code != http.StatusCreated {
			t.Fatalf("code=%d, want 201", rec.Code)
		}
	}
	if calls.Load() != 2 {
		t.Fatalf("handler called %d times, want 2 (no key = no dedup)", calls.Load())
	}
}

// countingHandler answers 201 with a Location header and counts its calls.
func countingHandler(calls *atomic.Int32) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Location", "/items/1")
		w.Header().Set("X-Not-Replayed", "1")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"id":1}`))
	})
}

// A key belongs to one request: another body, path or method is a 422 and
// the handler does not run again.
func TestIdempotencyKeyReusedForAnotherRequest(t *testing.T) {
	for _, tc := range []struct {
		name               string
		method, path, body string
		want               int
	}{
		{"same request (control)", http.MethodPost, "/items", `{"name":"a"}`, http.StatusCreated},
		{"different body", http.MethodPost, "/items", `{"name":"b"}`, http.StatusUnprocessableEntity},
		{"different path", http.MethodPost, "/items?x=1", `{"name":"a"}`, http.StatusUnprocessableEntity},
		{"different method and path", http.MethodDelete, "/items/5", "", http.StatusUnprocessableEntity},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Int32
			h := Idempotency(newFakeStore(), http.MethodPost, http.MethodDelete)(countingHandler(&calls))
			first := httptest.NewRecorder()
			h.ServeHTTP(first, newRequestTo(http.MethodPost, "/items", `{"name":"a"}`, "k1"))
			second := httptest.NewRecorder()
			h.ServeHTTP(second, newRequestTo(tc.method, tc.path, tc.body, "k1"))
			if second.Code != tc.want {
				t.Fatalf("code = %d, want %d (body %s)", second.Code, tc.want, second.Body.String())
			}
			if calls.Load() != 1 {
				t.Fatalf("handler called %d times, want 1", calls.Load())
			}
		})
	}
}

func TestIdempotencyKeyValidation(t *testing.T) {
	for _, tc := range []struct {
		name string
		key  string
		want int
	}{
		{"uuid", "3f1c2b9e-8a7d-4c6b-9e1f-2a3b4c5d6e7f", http.StatusCreated},
		{"at the length limit", strings.Repeat("k", maxIdempotencyKeyLength), http.StatusCreated},
		{"too long", strings.Repeat("k", maxIdempotencyKeyLength+1), http.StatusBadRequest},
		{"space", "a b", http.StatusBadRequest},
		{"control character", "a\tb", http.StatusBadRequest},
		{"non-ASCII", "clé", http.StatusBadRequest},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Int32
			h := Idempotency(newFakeStore(), http.MethodPost)(countingHandler(&calls))
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, newRequest(tc.key))
			if rec.Code != tc.want {
				t.Fatalf("code = %d, want %d", rec.Code, tc.want)
			}
			wantCalls := int32(0)
			if tc.want == http.StatusCreated {
				wantCalls = 1
			}
			if calls.Load() != wantCalls {
				t.Fatalf("handler called %d times, want %d", calls.Load(), wantCalls)
			}
		})
	}
}

// Documented behaviour while Redis is down: a request with a key gets a 503
// and is not executed; a request without a key is served.
func TestIdempotencyRedisUnavailable(t *testing.T) {
	down := errors.New("dial tcp: connection refused")
	for _, tc := range []struct {
		name  string
		setup func(*fakeStore)
	}{
		{"read fails", func(f *fakeStore) { f.getErr = down }},
		{"lock fails", func(f *fakeStore) { f.lockErr = down }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Int32
			store := newFakeStore()
			tc.setup(store)
			h := Idempotency(store, http.MethodPost)(countingHandler(&calls))

			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, newRequest("k1"))
			if rec.Code != http.StatusServiceUnavailable || rec.Header().Get("Retry-After") == "" {
				t.Fatalf("with a key: code = %d, Retry-After %q, want 503 with Retry-After", rec.Code, rec.Header().Get("Retry-After"))
			}
			if calls.Load() != 0 {
				t.Fatalf("handler ran %d times without deduplication", calls.Load())
			}

			rec = httptest.NewRecorder()
			h.ServeHTTP(rec, newRequest(""))
			if rec.Code != http.StatusCreated {
				t.Fatalf("without a key: code = %d, want 201", rec.Code)
			}
		})
	}
}

// Storing the result fails after the handler ran: the client still gets its
// response; the record is missing, so a retry executes again (documented).
func TestIdempotencyStoreFailureAfterExecution(t *testing.T) {
	var calls atomic.Int32
	store := newFakeStore()
	store.setErr = errors.New("OOM command not allowed")
	h := Idempotency(store, http.MethodPost)(countingHandler(&calls))
	for i := 0; i < 2; i++ {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, newRequest("k1"))
		if rec.Code != http.StatusCreated {
			t.Fatalf("request %d: code = %d, want 201", i, rec.Code)
		}
	}
	if calls.Load() != 2 {
		t.Fatalf("handler called %d times, want 2", calls.Load())
	}
	if len(store.locks) != 0 {
		t.Fatalf("lock not released: %v", store.locks)
	}
}

func TestIdempotencyReplaysHeaders(t *testing.T) {
	var calls atomic.Int32
	h := Idempotency(newFakeStore(), http.MethodPost)(countingHandler(&calls))
	h.ServeHTTP(httptest.NewRecorder(), newRequest("k1"))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, newRequest("k1"))
	if got := rec.Header().Get("Location"); got != "/items/1" {
		t.Fatalf("Location = %q, want /items/1", got)
	}
	if got := rec.Header().Get("X-Not-Replayed"); got != "" {
		t.Fatalf("X-Not-Replayed = %q, want it not replayed", got)
	}
}

// Records written up to v1.6.0 have no fingerprint: replayed as before.
func TestIdempotencyReplaysLegacyRecord(t *testing.T) {
	var calls atomic.Int32
	store := newFakeStore()
	store.results["k1"] = []byte(`{"status":201,"body":"eyJpZCI6N30="}`) // {"id":7}
	h := Idempotency(store, http.MethodPost)(countingHandler(&calls))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, newRequestTo(http.MethodPost, "/items", `{"name":"other"}`, "k1"))
	if rec.Code != http.StatusCreated || rec.Body.String() != `{"id":7}` || calls.Load() != 0 {
		t.Fatalf("code = %d, body %s, calls %d", rec.Code, rec.Body.String(), calls.Load())
	}
}

// The middleware reads the body for the fingerprint: the handler must still
// get it, and the body limit still applies.
func TestIdempotencyBody(t *testing.T) {
	var got string
	h := BodyLimit(16)(Idempotency(newFakeStore(), http.MethodPost)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got = string(b)
		w.WriteHeader(http.StatusCreated)
	})))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, newRequestTo(http.MethodPost, "/items", `{"name":"a"}`, "k1"))
	if rec.Code != http.StatusCreated || got != `{"name":"a"}` {
		t.Fatalf("code = %d, handler read %q", rec.Code, got)
	}
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, newRequestTo(http.MethodPost, "/items", `{"name":"far too long"}`, "k2"))
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("over the limit: code = %d, want 413", rec.Code)
	}
}
