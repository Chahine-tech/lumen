package app

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Chahine-tech/lumen/internal/handlers"
)

func status(t *testing.T, h http.Handler, path string) int {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec.Code
}

// The public port (routed by Traefik) serves neither the metrics nor pprof.
func TestPublicMuxHasNoAdminRoutes(t *testing.T) {
	mux := (&App{}).publicMux(handlers.NewHandler(nil, nil, nil))
	for path, want := range map[string]int{
		"/livez":                 http.StatusOK, // control: the mux serves
		"/metrics":               http.StatusNotFound,
		"/debug/pprof/":          http.StatusNotFound,
		"/debug/pprof/cmdline":   http.StatusNotFound,
		"/debug/pprof/goroutine": http.StatusNotFound,
	} {
		if got := status(t, mux, path); got != want {
			t.Errorf("GET %s = %d, want %d", path, got, want)
		}
	}
}

func TestAdminServer(t *testing.T) {
	for _, tc := range []struct {
		pprof bool
		want  map[string]int
	}{
		{false, map[string]int{
			"/metrics":             http.StatusOK,
			"/debug/pprof/":        http.StatusNotFound,
			"/debug/pprof/cmdline": http.StatusNotFound,
			"/items":               http.StatusNotFound, // not the API
		}},
		{true, map[string]int{
			"/metrics":               http.StatusOK,
			"/debug/pprof/":          http.StatusOK,
			"/debug/pprof/cmdline":   http.StatusOK,
			"/debug/pprof/goroutine": http.StatusOK,
		}},
	} {
		h := newAdminServer(":0", tc.pprof).Handler
		for path, want := range tc.want {
			if got := status(t, h, path); got != want {
				t.Errorf("pprof=%v: GET %s = %d, want %d", tc.pprof, path, got, want)
			}
		}
	}
}

// shutdown stops the admin listener too, after the public one.
func TestShutdownStopsAdminServer(t *testing.T) {
	a, _ := startTestApp(t, 0)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	a.adminServer = newAdminServer(ln.Addr().String(), false)
	go func() { _ = a.adminServer.Serve(ln) }()
	url := "http://" + ln.Addr().String() + "/metrics"
	if got := get(t, url); got != http.StatusOK {
		t.Fatalf("admin before shutdown = %d", got)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := a.shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := http.Get(url); err == nil {
		t.Fatal("admin listener still open after shutdown")
	}
}
