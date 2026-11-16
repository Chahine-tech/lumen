package store

import (
	"context"
	"os"
	"testing"
	"time"
)

// Integration tests against a real Redis. Skipped unless LUMEN_TEST_REDIS_ADDR
// points to a server the test may write keys to:
//
//	docker run -d --rm --name redis-test -p 127.0.0.1:56379:6379 redis:7.4.12-alpine
//	LUMEN_TEST_REDIS_ADDR=127.0.0.1:56379 go test ./internal/store/
func newTestRedis(t *testing.T) *RedisStore {
	t.Helper()
	addr := os.Getenv("LUMEN_TEST_REDIS_ADDR")
	if addr == "" {
		t.Skip("LUMEN_TEST_REDIS_ADDR not set")
	}
	s, err := NewRedisStore(addr, "standalone", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// A request that outlived the lock TTL must not release the lock of the
// request that took over.
func TestIdempotencyLockReleaseChecksToken(t *testing.T) {
	s := newTestRedis(t)
	ctx := context.Background()
	key := "test-" + t.Name() + time.Now().Format("150405.000000")
	t.Cleanup(func() { _ = s.client.Del(ctx, "idempotency:lock:"+key).Err() })

	if ok, err := s.AcquireIdempotencyLock(ctx, key, "slow", 200*time.Millisecond); err != nil || !ok {
		t.Fatalf("first acquire: %v, %v", ok, err)
	}
	if ok, _ := s.AcquireIdempotencyLock(ctx, key, "other", time.Minute); ok {
		t.Fatal("lock acquired twice")
	}
	time.Sleep(300 * time.Millisecond) // the slow request's lock expires
	if ok, err := s.AcquireIdempotencyLock(ctx, key, "takeover", time.Minute); err != nil || !ok {
		t.Fatalf("takeover acquire: %v, %v", ok, err)
	}

	// The slow request finishes and releases with its own, expired token
	if err := s.ReleaseIdempotencyLock(ctx, key, "slow"); err != nil {
		t.Fatal(err)
	}
	if ok, _ := s.AcquireIdempotencyLock(ctx, key, "third", time.Minute); ok {
		t.Fatal("the slow request deleted the lock of the request that took over")
	}

	// The owner releases its own lock
	if err := s.ReleaseIdempotencyLock(ctx, key, "takeover"); err != nil {
		t.Fatal(err)
	}
	if ok, err := s.AcquireIdempotencyLock(ctx, key, "third", time.Minute); err != nil || !ok {
		t.Fatalf("after the owner's release: %v, %v", ok, err)
	}
}

// The per-caller counter counts each caller separately, starts again at
// each window and does not keep its keys.
func TestCountRequest(t *testing.T) {
	s := newTestRedis(t)
	ctx := context.Background()
	alice := "test:" + t.Name() + time.Now().Format("150405.000000")
	window := 300 * time.Millisecond
	// Start at the beginning of a window, so the three counts share it
	time.Sleep(window - time.Duration(time.Now().UnixNano()%int64(window)))

	for want := int64(1); want <= 3; want++ {
		n, err := s.CountRequest(ctx, alice, window)
		if err != nil || n != want {
			t.Fatalf("count %d: %d, %v", want, n, err)
		}
	}
	if n, err := s.CountRequest(ctx, alice+"-bob", window); err != nil || n != 1 {
		t.Fatalf("another caller: %d, %v", n, err)
	}
	keys, err := s.client.Keys(ctx, "ratelimit:"+alice+":*").Result()
	if err != nil || len(keys) != 1 {
		t.Fatalf("keys %v, %v", keys, err)
	}
	if ttl, err := s.client.PTTL(ctx, keys[0]).Result(); err != nil || ttl <= 0 || ttl > 2*window {
		t.Fatalf("TTL %s, %v; want in (0, %s]", ttl, err, 2*window)
	}
	time.Sleep(window)
	if n, err := s.CountRequest(ctx, alice, window); err != nil || n != 1 {
		t.Fatalf("next window: %d, %v", n, err)
	}
}
