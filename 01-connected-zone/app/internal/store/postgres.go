package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

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

func NewPostgresStore(ctx context.Context, rwDSN, roDSN string, eventsTotal *prometheus.CounterVec) (*PostgresStore, error) {
	rw, err := pgxpool.New(ctx, rwDSN)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to postgres rw: %w", err)
	}

	ro, err := pgxpool.New(ctx, roDSN)
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

	payload, _ := json.Marshal(map[string]any{"id": item.ID, "name": item.Name})
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

func (s *PostgresStore) GetItems(ctx context.Context) ([]Item, error) {
	rows, err := s.ro.Query(ctx, `SELECT id, name, created_at FROM items ORDER BY id DESC`)
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

func (s *PostgresStore) GetItem(ctx context.Context, id int) (Item, error) {
	var item Item
	err := s.ro.QueryRow(ctx,
		`SELECT id, name, created_at FROM items WHERE id = $1`,
		id,
	).Scan(&item.ID, &item.Name, &item.CreatedAt)
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
		return fmt.Errorf("item %d not found", id)
	}

	payload, _ := json.Marshal(map[string]any{"id": id})
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
