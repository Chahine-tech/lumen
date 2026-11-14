package store

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

type RedisStore struct {
	client *redis.Client
}

func NewRedisStore(addr, mode, sentinelAddrs, masterName, password string) (*RedisStore, error) {
	var client *redis.Client

	if mode == "sentinel" {
		addrs := strings.Split(sentinelAddrs, ",")
		client = redis.NewFailoverClient(&redis.FailoverOptions{
			MasterName:    masterName,
			SentinelAddrs: addrs,
			// Password authenticates against the data nodes (requirepass);
			// sentinels themselves are unauthenticated (NetworkPolicy only).
			Password:     password,
			DB:           0,
			DialTimeout:  5 * time.Second,
			ReadTimeout:  3 * time.Second,
			WriteTimeout: 3 * time.Second,
			PoolSize:     10,
		})
	} else {
		client = redis.NewClient(&redis.Options{
			Addr:         addr,
			Password:     password,
			DB:           0,
			DialTimeout:  5 * time.Second,
			ReadTimeout:  3 * time.Second,
			WriteTimeout: 3 * time.Second,
			PoolSize:     10,
		})
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("redis connection failed: %w", err)
	}

	return &RedisStore{client: client}, nil
}

func (s *RedisStore) Ping(ctx context.Context) error {
	return s.client.Ping(ctx).Err()
}

func (s *RedisStore) IncrementCounter(ctx context.Context, key string) (int64, error) {
	return s.client.Incr(ctx, key).Result()
}

func (s *RedisStore) GetIdempotencyResult(ctx context.Context, key string) ([]byte, error) {
	val, err := s.client.Get(ctx, "idempotency:"+key).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	return val, err
}

func (s *RedisStore) SetIdempotencyResult(ctx context.Context, key string, data []byte, ttl time.Duration) error {
	return s.client.Set(ctx, "idempotency:"+key, data, ttl).Err()
}

// AcquireIdempotencyLock atomically claims a key for the duration of one request
// (SET NX with a TTL), so two concurrent requests with the same Idempotency-Key
// cannot both execute the handler. Returns false if another request holds the
// lock. The value is the caller's random token, checked on release.
func (s *RedisStore) AcquireIdempotencyLock(ctx context.Context, key, token string, ttl time.Duration) (bool, error) {
	return s.client.SetNX(ctx, "idempotency:lock:"+key, token, ttl).Result()
}

// releaseLock deletes the lock only if it still holds the caller's token: a
// request that outlived the TTL must not delete the lock of the request that
// took over.
var releaseLock = redis.NewScript(`
if redis.call("GET", KEYS[1]) == ARGV[1] then
  return redis.call("DEL", KEYS[1])
end
return 0
`)

func (s *RedisStore) ReleaseIdempotencyLock(ctx context.Context, key, token string) error {
	return releaseLock.Run(ctx, s.client, []string{"idempotency:lock:" + key}, token).Err()
}

func (s *RedisStore) Close() error {
	return s.client.Close()
}
