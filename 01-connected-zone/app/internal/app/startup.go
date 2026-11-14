package app

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

const (
	// startupTimeout bounds the wait for Redis and PostgreSQL at startup,
	// below the startupProbe budget (60s, 03-lumen-api.yaml). A new pod has
	// no DNS for its first seconds, until its NetworkPolicies are programmed:
	// on k3d, the first lookup of redis timed out and every new pod
	// restarted once.
	startupTimeout = 30 * time.Second
	startupRetry   = 2 * time.Second
	// attemptTimeout bounds one attempt
	attemptTimeout = 5 * time.Second
)

// waitFor calls try until it succeeds or timeout has passed, every interval.
// A dependency still missing after that makes NewApp fail, as before.
func waitFor(name string, timeout, interval time.Duration, try func(ctx context.Context) error) error {
	deadline := time.Now().Add(timeout)
	for attempt := 1; ; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), attemptTimeout)
		err := try(ctx)
		cancel()
		if err == nil {
			if attempt > 1 {
				slog.Info("Dependency reachable", "dependency", name, "attempts", attempt)
			}
			return nil
		}
		if time.Now().Add(interval).After(deadline) {
			return fmt.Errorf("%s not reachable after %s: %w", name, timeout, err)
		}
		slog.Warn("Dependency not reachable yet, retrying", "dependency", name, "attempt", attempt, "error", err)
		time.Sleep(interval)
	}
}
