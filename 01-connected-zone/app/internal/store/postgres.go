package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
)

type Item struct {
	ID        int       `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

type Event struct {
	ID        int64           `json:"id"`
	Type      string          `json:"type"`
	Aggregate string          `json:"aggregate"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt time.Time       `json:"created_at"`
}

type PostgresStore struct {
	rw          *pgxpool.Pool // writes → lumen-db-rw (master)
	ro          *pgxpool.Pool // reads  → lumen-db-ro (replica)
	eventsTotal *prometheus.CounterVec
}

// newPool opens a pool with explicit limits instead of the pgx defaults:
// connections are recycled regularly (they follow a CNPG switchover to the
// new primary) and checked in the background.
func newPool(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns = 10
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.HealthCheckPeriod = 30 * time.Second
	return pgxpool.NewWithConfig(ctx, cfg)
}

func NewPostgresStore(ctx context.Context, rwDSN, roDSN string, eventsTotal *prometheus.CounterVec) (*PostgresStore, error) {
	rw, err := newPool(ctx, rwDSN)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to postgres rw: %w", err)
	}

	ro, err := newPool(ctx, roDSN)
	if err != nil {
		rw.Close()
		return nil, fmt.Errorf("failed to connect to postgres ro: %w", err)
	}

	s := &PostgresStore{rw: rw, ro: ro, eventsTotal: eventsTotal}
	if err := s.migrate(ctx); err != nil {
		rw.Close()
		ro.Close()
		return nil, fmt.Errorf("migration failed: %w", err)
	}

	return s, nil
}

func (s *PostgresStore) migrate(ctx context.Context) error {
	_, err := s.rw.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS items (
			id         SERIAL PRIMARY KEY,
			name       TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
		CREATE TABLE IF NOT EXISTS events (
			id         BIGSERIAL PRIMARY KEY,
			type       TEXT NOT NULL,
			aggregate  TEXT NOT NULL,
			payload    JSONB NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
		CREATE INDEX IF NOT EXISTS events_type_idx ON events (type);
		CREATE INDEX IF NOT EXISTS events_created_at_idx ON events (created_at DESC);
	`)
	return err
}

func (s *PostgresStore) Ping(ctx context.Context) error {
	if err := s.rw.Ping(ctx); err != nil {
		return fmt.Errorf("rw ping failed: %w", err)
	}
	return nil
}

// PingReplica checks the read-only pool, which serves every GET route.
func (s *PostgresStore) PingReplica(ctx context.Context) error {
	if err := s.ro.Ping(ctx); err != nil {
		return fmt.Errorf("ro ping failed: %w", err)
	}
	return nil
}

func (s *PostgresStore) CreateItem(ctx context.Context, name string) (Item, error) {
	tx, err := s.rw.Begin(ctx)
	if err != nil {
		return Item{}, fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var item Item
	err = tx.QueryRow(ctx,
		`INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at`,
		name,
	).Scan(&item.ID, &item.Name, &item.CreatedAt)
	if err != nil {
		return Item{}, err
	}

	payload, err := json.Marshal(map[string]any{"id": item.ID, "name": item.Name})
	if err != nil {
		return Item{}, fmt.Errorf("encode event: %w", err)
	}
	_, err = tx.Exec(ctx,
		`INSERT INTO events (type, aggregate, payload) VALUES ($1, $2, $3)`,
		"ItemCreated", "item", payload,
	)
	if err != nil {
		return Item{}, fmt.Errorf("insert event: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return Item{}, err
	}
	s.eventsTotal.WithLabelValues("ItemCreated").Inc()
	return item, nil
}

// GetItems returns at most limit items, newest first. beforeID > 0 returns
// the items older than that id (keyset pagination: stable while rows are
// added, no OFFSET scan).
func (s *PostgresStore) GetItems(ctx context.Context, limit, beforeID int) ([]Item, error) {
	var rows pgx.Rows
	var err error
	if beforeID > 0 {
		rows, err = s.ro.Query(ctx,
			`SELECT id, name, created_at FROM items WHERE id < $1 ORDER BY id DESC LIMIT $2`,
			beforeID, limit)
	} else {
		rows, err = s.ro.Query(ctx,
			`SELECT id, name, created_at FROM items ORDER BY id DESC LIMIT $1`, limit)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []Item
	for rows.Next() {
		var item Item
		if err := rows.Scan(&item.ID, &item.Name, &item.CreatedAt); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

// GetItem reads from a replica. A row missing there may not be replicated
// yet (read right after the POST that created it): the primary is asked
// before answering ErrNotFound.
func (s *PostgresStore) GetItem(ctx context.Context, id int) (Item, error) {
	item, err := getItem(ctx, s.ro, id)
	if errors.Is(err, ErrNotFound) {
		return getItem(ctx, s.rw, id)
	}
	return item, err
}

func getItem(ctx context.Context, pool *pgxpool.Pool, id int) (Item, error) {
	var item Item
	err := pool.QueryRow(ctx,
		`SELECT id, name, created_at FROM items WHERE id = $1`,
		id,
	).Scan(&item.ID, &item.Name, &item.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Item{}, ErrNotFound
	}
	return item, err
}

func (s *PostgresStore) DeleteItem(ctx context.Context, id int) error {
	tx, err := s.rw.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	result, err := tx.Exec(ctx, `DELETE FROM items WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if result.RowsAffected() == 0 {
		return ErrNotFound
	}

	payload, err := json.Marshal(map[string]any{"id": id})
	if err != nil {
		return fmt.Errorf("encode event: %w", err)
	}
	_, err = tx.Exec(ctx,
		`INSERT INTO events (type, aggregate, payload) VALUES ($1, $2, $3)`,
		"ItemDeleted", "item", payload,
	)
	if err != nil {
		return fmt.Errorf("insert event: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return err
	}
	s.eventsTotal.WithLabelValues("ItemDeleted").Inc()
	return nil
}

func (s *PostgresStore) GetEvents(ctx context.Context, eventType string, limit int) ([]Event, error) {
	if limit <= 0 {
		limit = 100
	}

	var query string
	var args []any
	if eventType != "" {
		query = `SELECT id, type, aggregate, payload, created_at FROM events WHERE type = $1 ORDER BY id DESC LIMIT $2`
		args = []any{eventType, limit}
	} else {
		query = `SELECT id, type, aggregate, payload, created_at FROM events ORDER BY id DESC LIMIT $1`
		args = []any{limit}
	}

	rows, err := s.ro.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(&e.ID, &e.Type, &e.Aggregate, &e.Payload, &e.CreatedAt); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, rows.Err()
}

func (s *PostgresStore) Close() {
	s.rw.Close()
	s.ro.Close()
}
