package app

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"
)

// Kubernetes probes. They deliberately do NOT check Redis or PostgreSQL:
// those are shared by every replica, so a probe that fails on them fails on
// all pods at once. Liveness would restart every pod during a short database
// blip; readiness would leave the Service with no endpoint at all, turning a
// partial outage (most routes work without Redis) into a total one.
// Dependency state is reported by /health and the metrics instead.

// livez answers 200 as long as the process serves HTTP.
func (a *App) livez(w http.ResponseWriter, _ *http.Request) {
	writeProbe(w, http.StatusOK, "alive")
}

// readyz answers 503 once shutdown has started, so that the pod leaves the
// Service endpoints before its listener closes.
func (a *App) readyz(w http.ResponseWriter, _ *http.Request) {
	if a.draining.Load() {
		writeProbe(w, http.StatusServiceUnavailable, "draining")
		return
	}
	writeProbe(w, http.StatusOK, "ready")
}

func writeProbe(w http.ResponseWriter, status int, state string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": state})
}

// shutdown fails readiness, waits drainDelay for the endpoint removal to reach
// kube-proxy and Traefik (requests keep being served meanwhile), then stops
// accepting connections and waits for in-flight requests until ctx expires.
func (a *App) shutdown(ctx context.Context) error {
	a.draining.Store(true)
	slog.Info("Draining before shutdown", "delay", a.drainDelay.String())
	select {
	case <-time.After(a.drainDelay):
	case <-ctx.Done():
	}
	return a.server.Shutdown(ctx)
}
