package app

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestWaitFor(t *testing.T) {
	down := errors.New("lookup redis: i/o timeout")

	t.Run("reachable at once", func(t *testing.T) {
		calls := 0
		start := time.Now()
		err := waitFor("redis", time.Second, 100*time.Millisecond, func(context.Context) error { calls++; return nil })
		if err != nil || calls != 1 || time.Since(start) > 50*time.Millisecond {
			t.Fatalf("err = %v, calls = %d, took %s", err, calls, time.Since(start))
		}
	})

	// The first lookups of a new pod fail, then succeed: no exit.
	t.Run("reachable after a few attempts", func(t *testing.T) {
		calls := 0
		err := waitFor("redis", time.Second, 10*time.Millisecond, func(context.Context) error {
			calls++
			if calls < 3 {
				return down
			}
			return nil
		})
		if err != nil || calls != 3 {
			t.Fatalf("err = %v, calls = %d, want nil after 3", err, calls)
		}
	})

	// Still missing after the timeout: the error, wrapped, as before.
	t.Run("gives up after the timeout", func(t *testing.T) {
		calls := 0
		start := time.Now()
		err := waitFor("redis", 200*time.Millisecond, 50*time.Millisecond, func(context.Context) error { calls++; return down })
		took := time.Since(start)
		if !errors.Is(err, down) {
			t.Fatalf("err = %v, want it to wrap %v", err, down)
		}
		if calls < 3 || took > 400*time.Millisecond {
			t.Fatalf("calls = %d, took %s", calls, took)
		}
	})

	// Each attempt gets a bounded context.
	t.Run("attempt context has a deadline", func(t *testing.T) {
		_ = waitFor("postgresql", time.Second, 10*time.Millisecond, func(ctx context.Context) error {
			if _, ok := ctx.Deadline(); !ok {
				t.Error("attempt context without deadline")
			}
			return nil
		})
	})
}
