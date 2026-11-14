package app

import (
	"log/slog"
	"net/http"
	"net/http/pprof"
	"time"

	"github.com/Chahine-tech/lumen/internal/middleware"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// newAdminServer serves the operational endpoints on their own port
// (ADMIN_PORT, default 9090), apart from the API: the IngressRoute does not
// route to it and the NetworkPolicy only lets Prometheus in.
//
// pprof exposes heap contents and the command line, and /profile and /trace
// burn CPU on demand: off unless PPROF_ENABLED=true.
func newAdminServer(addr string, pprofEnabled bool) *http.Server {
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.Handler())
	if pprofEnabled {
		mux.HandleFunc("/debug/pprof/", pprof.Index)
		mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
		mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
		mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
		mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	}
	slog.Info("Admin endpoints", "addr", addr, "metrics", "/metrics", "pprof_enabled", pprofEnabled)
	return &http.Server{
		Addr:        addr,
		Handler:     middleware.Recovery(mux),
		ReadTimeout: 5 * time.Second,
		// pprof extends the write deadline by the profile duration itself
		// (configureWriteDeadline in net/http/pprof)
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}
}
