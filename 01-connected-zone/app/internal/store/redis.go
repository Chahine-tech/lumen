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

func NewRedisStore(addr, mode, sentinelAddrs, masterName string) (*RedisStore, error) {
	var client *redis.Client

	if mode == "sentinel" {
		addrs := strings.Split(sentinelAddrs, ",")
		client = redis.NewFailoverClient(&redis.FailoverOptions{
			MasterName:    masterName,
			SentinelAddrs: addrs,
			DB:            0,
			DialTimeout:   5 * time.Second,
			ReadTimeout:   3 * time.Second,
			WriteTimeout:  3 * time.Second,
			PoolSize:      10,
		})
	} else {
		client = redis.NewClient(&redis.Options{
			Addr:         addr,
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

func (s *RedisStore) Close() error {
	return s.client.Close()
}
