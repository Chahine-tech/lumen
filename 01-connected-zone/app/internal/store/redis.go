package store

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// RedisStore handles Redis operations
type RedisStore struct {
	client *redis.Client
}

// NewRedisStore creates a new Redis store with connection
func NewRedisStore(addr string) (*RedisStore, error) {
	client := redis.NewClient(&redis.Options{
		Addr:         addr,
		Password:     "",
		DB:           0,
		DialTimeout:  5 * time.Second,
		ReadTimeout:  3 * time.Second,
		WriteTimeout: 3 * time.Second,
		PoolSize:     10,
	})

	// Test connection with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := client.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("redis connection failed: %w", err)
	}

	return &RedisStore{client: client}, nil
}

// Ping checks Redis health
func (s *RedisStore) Ping(ctx context.Context) error {
	return s.client.Ping(ctx).Err()
}

// IncrementCounter increments a counter key
func (s *RedisStore) IncrementCounter(ctx context.Context, key string) (int64, error) {
	return s.client.Incr(ctx, key).Result()
}

// Close closes the Redis connection
func (s *RedisStore) Close() error {
	return s.client.Close()
}
