package middleware

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeStore is an in-memory idempotencyStore for tests.
type fakeStore struct {
	mu      sync.Mutex
	results map[string][]byte
	locks   map[string]bool
}

func newFakeStore() *fakeStore {
	return &fakeStore{results: map[string][]byte{}, locks: map[string]bool{}}
}

func (f *fakeStore) GetIdempotencyResult(_ context.Context, key string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.results[key], nil
}

func (f *fakeStore) SetIdempotencyResult(_ context.Context, key string, data []byte, _ time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.results[key] = data
	return nil
}

func (f *fakeStore) AcquireIdempotencyLock(_ context.Context, key string, _ time.Duration) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.locks[key] {
		return false, nil
	}
	f.locks[key] = true
	return true, nil
}

func (f *fakeStore) ReleaseIdempotencyLock(_ context.Context, key string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.locks, key)
	return nil
}

func newRequest(key string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/api/items", strings.NewReader(`{"name":"x"}`))
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
		w.Write([]byte(`{"id":1}`))
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
