package middleware

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Chahine-tech/lumen/internal/auth"
	"github.com/Chahine-tech/lumen/internal/auth/authtest"
)

// authenticated puts h behind Authenticate (enforce mode, any caller of the
// test issuer); as returns a request carrying the token of sub.
func authenticated(t *testing.T, h http.Handler) (http.Handler, func(r *http.Request, sub string) *http.Request) {
	t.Helper()
	iss := authtest.New(t)
	authn, err := auth.New(iss.Config(nil), auth.Enforce, nil)
	if err != nil {
		t.Fatal(err)
	}
	return authn.Authenticate()(h), func(r *http.Request, sub string) *http.Request {
		r.Header.Set("Authorization", "Bearer "+iss.Token(sub))
		return r
	}
}

// Two callers choosing the same key get separate records (issue #33): each
// request runs. The same caller replaying its request gets the record.
func TestIdempotencyKeyScopedByCaller(t *testing.T) {
	var calls atomic.Int32
	store := newFakeStore()
	h, as := authenticated(t, Idempotency(store, http.MethodPost)(countingHandler(&calls)))

	for _, tc := range []struct {
		sub, body string
		want      int
		calls     int32
	}{
		{"alice", `{"name":"a"}`, http.StatusCreated, 1},
		{"bob", `{"name":"b"}`, http.StatusCreated, 2},   // same key, another caller: runs
		{"alice", `{"name":"a"}`, http.StatusCreated, 2}, // replayed (control)
		{"alice", `{"name":"b"}`, http.StatusUnprocessableEntity, 2},
	} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, as(newRequestTo(http.MethodPost, "/items", tc.body, "k1"), tc.sub))
		if rec.Code != tc.want || calls.Load() != tc.calls {
			t.Fatalf("%s %s: code %d, calls %d; want %d, %d", tc.sub, tc.body, rec.Code, calls.Load(), tc.want, tc.calls)
		}
	}
	if _, ok := store.results[authtest.Caller("alice")+" k1"]; !ok {
		t.Fatalf("records %v: none under alice's scope", keys(store.results))
	}
}

func keys(m map[string][]byte) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

// Without a caller (report mode), the key is not scoped: a record written by
// the versions before authentication is still found.
func TestIdempotencyWithoutCallerKeepsUnscopedKey(t *testing.T) {
	var calls atomic.Int32
	store := newFakeStore()
	store.results["k1"] = []byte(`{"status":201,"body":"eyJpZCI6N30="}`) // {"id":7}
	h := Idempotency(store, http.MethodPost)(countingHandler(&calls))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, newRequestTo(http.MethodPost, "/items", `{"name":"x"}`, "k1"))
	if rec.Code != http.StatusCreated || rec.Body.String() != `{"id":7}` || calls.Load() != 0 {
		t.Fatalf("code %d, body %s, calls %d", rec.Code, rec.Body.String(), calls.Load())
	}
}

type fakeCounter struct {
	counts map[string]int64
	err    error
}

func (f *fakeCounter) CountRequest(_ context.Context, caller string, _ time.Duration) (int64, error) {
	if f.err != nil {
		return 0, f.err
	}
	f.counts[caller]++
	return f.counts[caller], nil
}

func TestCallerRateLimit(t *testing.T) {
	counter := &fakeCounter{counts: map[string]int64{}}
	var refused atomic.Int32
	h, as := authenticated(t, CallerRateLimit(counter, 2, func() { refused.Add(1) })(http.HandlerFunc(ok)))

	codes := func(sub string, n int) string {
		var out []string
		for range n {
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, as(httptest.NewRequest(http.MethodGet, "/items", nil), sub))
			out = append(out, http.StatusText(rec.Code))
			if rec.Code == http.StatusTooManyRequests && rec.Header().Get("Retry-After") != "1" {
				t.Errorf("429 without Retry-After")
			}
		}
		return strings.Join(out, ",")
	}
	if got := codes("alice", 3); got != "OK,OK,Too Many Requests" {
		t.Fatalf("alice: %s", got)
	}
	if got := codes("bob", 2); got != "OK,OK" {
		t.Fatalf("bob, after alice was limited: %s", got)
	}
	if refused.Load() != 1 {
		t.Fatalf("refused counted %d times, want 1", refused.Load())
	}

	// Redis down: served
	counter.err = errors.New("redis down")
	if got := codes("alice", 1); got != "OK" {
		t.Fatalf("counter error: %s", got)
	}
}

func TestCallerRateLimitSkips(t *testing.T) {
	counter := &fakeCounter{counts: map[string]int64{}}
	// No caller (report mode): not counted
	h := CallerRateLimit(counter, 1, nil)(http.HandlerFunc(ok))
	for range 3 {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/items", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("anonymous: %d", rec.Code)
		}
	}
	// Limit 0: disabled
	h0, as := authenticated(t, CallerRateLimit(counter, 0, nil)(http.HandlerFunc(ok)))
	for range 3 {
		rec := httptest.NewRecorder()
		h0.ServeHTTP(rec, as(httptest.NewRequest(http.MethodGet, "/items", nil), "alice"))
		if rec.Code != http.StatusOK {
			t.Fatalf("limit 0: %d", rec.Code)
		}
	}
	if len(counter.counts) != 0 {
		t.Fatalf("counted %v, want nothing", counter.counts)
	}
}

func ok(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }

// The request log names the caller, which Authenticate (inside Logging)
// identified.
func TestLoggingRecordsCaller(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(old) })

	inner, as := authenticated(t, http.HandlerFunc(ok))
	Logging(inner).ServeHTTP(httptest.NewRecorder(), as(httptest.NewRequest(http.MethodGet, "/items", nil), "alice"))
	if !strings.Contains(buf.String(), `"caller":"`+authtest.Caller("alice")+`"`) {
		t.Fatalf("log: %s", buf.String())
	}
}
