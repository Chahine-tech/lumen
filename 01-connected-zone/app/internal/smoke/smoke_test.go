package smoke

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeAPI mimics the lumen-api routes the smoke test uses. Its fields inject
// the defects each test expects the smoke test to catch.
type fakeAPI struct {
	mu          sync.Mutex
	items       map[int]string
	nextID      int
	replays     map[string][]byte
	health      int  // status of /health
	healthFails int  // /health calls answered 503 before health
	noReplay    bool // ignore Idempotency-Key: a replay creates a new item
	deleteNoop  bool // DELETE answers 204 but keeps the item
	staleReads  int  // GETs after a delete that still return the item (replica lag)
	afterDelete map[int]int
	token       string // when set, every route needs "Bearer <token>"
}

func newFakeAPI() *fakeAPI {
	return &fakeAPI{items: map[int]string{}, replays: map[string][]byte{}, health: http.StatusOK, afterDelete: map[int]int{}}
}

func (f *fakeAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.token != "" && r.Header.Get("Authorization") != "Bearer "+f.token {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	switch {
	case r.URL.Path == "/health":
		if f.healthFails > 0 {
			f.healthFails--
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(f.health)
	case r.Method == http.MethodGet && r.URL.Path == "/items":
		_, _ = w.Write([]byte("[]"))
	case r.Method == http.MethodPost && r.URL.Path == "/items":
		key := r.Header.Get("Idempotency-Key")
		if b, ok := f.replays[key]; ok && !f.noReplay {
			w.Header().Set("Idempotency-Replayed", "true")
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write(b)
			return
		}
		var req struct{ Name string }
		_ = json.NewDecoder(r.Body).Decode(&req)
		f.nextID++
		f.items[f.nextID] = req.Name
		b, _ := json.Marshal(map[string]any{"id": f.nextID, "name": req.Name})
		f.replays[key] = b
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write(b)
	case strings.HasPrefix(r.URL.Path, "/items/"):
		id, _ := strconv.Atoi(strings.TrimPrefix(r.URL.Path, "/items/"))
		name, ok := f.items[id]
		switch r.Method {
		case http.MethodGet:
			if !ok && f.afterDelete[id] < f.staleReads {
				f.afterDelete[id]++
				ok = true
			}
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"id": id, "name": name})
		case http.MethodDelete:
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			if !f.deleteNoop {
				delete(f.items, id)
			}
			w.WriteHeader(http.StatusNoContent)
		}
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func run(t *testing.T, f *fakeAPI) error {
	t.Helper()
	return runWith(t, f, Options{})
}

func runWith(t *testing.T, f *fakeAPI, opts Options) error {
	t.Helper()
	srv := httptest.NewServer(f)
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return Run(ctx, srv.Client(), srv.URL+"/", opts)
}

func TestRunPasses(t *testing.T) {
	f := newFakeAPI()
	if err := run(t, f); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(f.items) != 0 {
		t.Errorf("items left behind: %v", f.items)
	}
}

func TestRunToleratesReplicaLag(t *testing.T) {
	f := newFakeAPI()
	f.staleReads = 3
	if err := run(t, f); err != nil {
		t.Fatalf("Run: %v", err)
	}
}

// shortTimeouts makes the failing cases fail in about a second
func shortTimeouts(t *testing.T) {
	oldLag, oldHealth := replicaLagTimeout, healthTimeout
	replicaLagTimeout, healthTimeout = time.Second, time.Second
	t.Cleanup(func() { replicaLagTimeout, healthTimeout = oldLag, oldHealth })
}

// The API not answering at first (NetworkPolicies of the new pod not
// programmed yet, canary starting) is waited for.
func TestRunWaitsForHealth(t *testing.T) {
	f := newFakeAPI()
	f.healthFails = 2
	if err := run(t, f); err != nil {
		t.Fatalf("Run: %v", err)
	}
}

func TestRunFails(t *testing.T) {
	shortTimeouts(t)

	for _, tc := range []struct {
		name   string
		defect func(*fakeAPI)
		want   string
	}{
		{"health degraded", func(f *fakeAPI) { f.health = http.StatusServiceUnavailable }, "health: status 503"},
		{"replay executes again", func(f *fakeAPI) { f.noReplay = true }, "replay:"},
		{"delete keeps the item", func(f *fakeAPI) { f.deleteNoop = true }, "read after delete: status 200"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFakeAPI()
			tc.defect(f)
			err := run(t, f)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Run: %v, want an error containing %q", err, tc.want)
			}
		})
	}
}

// A check that fails after the create still deletes the test item.
func TestRunCleansUpOnFailure(t *testing.T) {
	f := newFakeAPI()
	f.noReplay = true
	if err := run(t, f); err == nil {
		t.Fatal("Run: no error")
	}
	// The replay created a second item, which the smoke test does not know
	// about; the first one must be gone.
	if _, ok := f.items[1]; ok {
		t.Errorf("test item 1 not deleted: %v", f.items)
	}
}

func TestRunUnreachable(t *testing.T) {
	shortTimeouts(t)
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close()
	if err := Run(context.Background(), &http.Client{Timeout: time.Second}, url, Options{}); err == nil || !strings.Contains(err.Error(), "health:") {
		t.Fatalf("Run: %v, want a health error", err)
	}
}

func TestRunWithToken(t *testing.T) {
	f := newFakeAPI()
	f.token = "t0ken"
	if err := runWith(t, f, Options{Token: "t0ken", ExpectAuth: true}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(f.items) != 0 {
		t.Errorf("items left behind: %v", f.items)
	}
	// Control: without the token, the API refuses /health, and the smoke
	// test fails at once instead of waiting for it
	start := time.Now()
	if err := runWith(t, f, Options{}); err == nil || !strings.Contains(err.Error(), "health: status 401") {
		t.Fatalf("Run without the token: %v", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatalf("a 401 on /health was retried for %s", time.Since(start))
	}
}

// ExpectAuth fails against an API that serves requests without a token
// (AUTH_MODE=report, or no authentication).
func TestRunExpectAuthFailsWhenNotEnforced(t *testing.T) {
	err := runWith(t, newFakeAPI(), Options{Token: "t0ken", ExpectAuth: true})
	if err == nil || !strings.Contains(err.Error(), "auth: GET /items without a token: status 200") {
		t.Fatalf("Run: %v", err)
	}
}
