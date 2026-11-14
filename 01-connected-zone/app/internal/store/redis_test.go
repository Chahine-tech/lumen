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
//	docker run -d --rm --name redis-test -p 127.0.0.1:56379:6379 redis:7-alpine
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
