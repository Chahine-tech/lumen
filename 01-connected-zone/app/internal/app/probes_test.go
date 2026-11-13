package app

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

func get(t *testing.T, url string) int {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

// startTestApp serves the probes plus a /slow route on a random port.
func startTestApp(t *testing.T, drainDelay time.Duration) (*App, string) {
	t.Helper()
	a := &App{drainDelay: drainDelay}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /livez", a.livez)
	mux.HandleFunc("GET /readyz", a.readyz)
	mux.HandleFunc("GET /slow", func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(400 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
	})
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	a.server = &http.Server{Handler: mux}
	go func() { _ = a.server.Serve(ln) }()
	t.Cleanup(func() { _ = a.server.Close() })
	return a, "http://" + ln.Addr().String()
}

func TestProbes(t *testing.T) {
	a, base := startTestApp(t, 0)
	if got := get(t, base+"/livez"); got != http.StatusOK {
		t.Fatalf("livez = %d, want 200", got)
	}
	if got := get(t, base+"/readyz"); got != http.StatusOK {
		t.Fatalf("readyz = %d, want 200", got)
	}
	a.draining.Store(true)
	if got := get(t, base+"/readyz"); got != http.StatusServiceUnavailable {
		t.Fatalf("readyz while draining = %d, want 503", got)
	}
	if got := get(t, base+"/livez"); got != http.StatusOK {
		t.Fatalf("livez while draining = %d, want 200 (draining is not a reason to restart)", got)
	}
}

// During the drain delay the server keeps answering (readyz 503, other
// routes normally), an in-flight request completes, and only then does the
// listener close.
func TestShutdownDrainsBeforeClosing(t *testing.T) {
	a, base := startTestApp(t, 500*time.Millisecond)

	slow := make(chan int, 1)
	go func() {
		resp, err := http.Get(base + "/slow")
		if err != nil {
			slow <- -1
			return
		}
		resp.Body.Close()
		slow <- resp.StatusCode
	}()
	time.Sleep(50 * time.Millisecond) // the slow request is in flight

	done := make(chan error, 1)
	go func() { done <- a.shutdown(context.Background()) }()
	time.Sleep(100 * time.Millisecond) // shutdown started, still in the drain delay

	if got := get(t, base+"/readyz"); got != http.StatusServiceUnavailable {
		t.Fatalf("readyz during drain = %d, want 503", got)
	}
	if got := get(t, base+"/livez"); got != http.StatusOK {
		t.Fatalf("new request during drain = %d, want 200 (listener must still be open)", got)
	}
	if got := <-slow; got != http.StatusOK {
		t.Fatalf("in-flight request = %d, want 200", got)
	}
	if err := <-done; err != nil {
		t.Fatalf("shutdown: %v", err)
	}
	if _, err := http.Get(base + "/livez"); err == nil {
		t.Fatal("listener still open after shutdown")
	}
}

// A shutdown deadline shorter than the drain delay cuts the wait short.
func TestShutdownRespectsDeadline(t *testing.T) {
	a, _ := startTestApp(t, time.Hour)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	err := a.shutdown(ctx)
	if time.Since(start) > 2*time.Second {
		t.Fatalf("shutdown waited %s despite the deadline", time.Since(start))
	}
	if err != nil && !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("shutdown: %v", err)
	}
}
