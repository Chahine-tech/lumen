package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Item struct {
	ID        int       `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

type PostgresStore struct {
	rw *pgxpool.Pool // writes → lumen-db-rw (master)
	ro *pgxpool.Pool // reads  → lumen-db-ro (replica)
}

func NewPostgresStore(ctx context.Context, rwDSN, roDSN string) (*PostgresStore, error) {
	rw, err := pgxpool.New(ctx, rwDSN)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to postgres rw: %w", err)
	}

	ro, err := pgxpool.New(ctx, roDSN)
	if err != nil {
		rw.Close()
		return nil, fmt.Errorf("failed to connect to postgres ro: %w", err)
	}

	s := &PostgresStore{rw: rw, ro: ro}
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
		)
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
	var item Item
	err := s.rw.QueryRow(ctx,
		`INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at`,
		name,
	).Scan(&item.ID, &item.Name, &item.CreatedAt)
	return item, err
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
	result, err := s.rw.Exec(ctx, `DELETE FROM items WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if result.RowsAffected() == 0 {
		return fmt.Errorf("item %d not found", id)
	}
	return nil
}

func (s *PostgresStore) Close() {
	s.rw.Close()
	s.ro.Close()
}
