package store

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
)

// Integration tests against a real PostgreSQL. Skipped unless
// LUMEN_TEST_PG_DSN points to a server where the test may create and drop
// the databases lumen_test_primary and lumen_test_replica:
//
//	docker run -d --rm --name pg-test -p 127.0.0.1:55432:5432 \
//	  -e POSTGRES_PASSWORD=test ghcr.io/cloudnative-pg/postgresql:16.6
//	LUMEN_TEST_PG_DSN=postgres://postgres:test@127.0.0.1:55432/postgres?sslmode=disable \
//	  go test ./internal/store/
//
// The "replica" is a second, independent database: it never receives the
// primary's writes, which is how a lagging replica looks to the store.
func newTestStore(t *testing.T) (*PostgresStore, *pgxpool.Pool) {
	t.Helper()
	dsn := os.Getenv("LUMEN_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("LUMEN_TEST_PG_DSN not set")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Close)
	dbDSN := func(db string) string {
		i := strings.LastIndex(dsn, "/")
		j := strings.Index(dsn[i:], "?")
		if j < 0 {
			return dsn[:i+1] + db
		}
		return dsn[:i+1] + db + dsn[i+j:]
	}
	for _, db := range []string{"lumen_test_primary", "lumen_test_replica"} {
		if _, err := admin.Exec(ctx, "DROP DATABASE IF EXISTS "+db+" WITH (FORCE)"); err != nil {
			t.Fatal(err)
		}
		if _, err := admin.Exec(ctx, "CREATE DATABASE "+db); err != nil {
			t.Fatal(err)
		}
	}
	counter := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "test_events_total"}, []string{"type"})
	s, err := NewPostgresStore(ctx, dbDSN("lumen_test_primary"), dbDSN("lumen_test_replica"), counter)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	// The schema exists on a real replica; create it on the fake one
	replica, err := pgxpool.New(ctx, dbDSN("lumen_test_replica"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(replica.Close)
	if err := (&PostgresStore{rw: replica}).migrate(ctx); err != nil {
		t.Fatal(err)
	}
	return s, replica
}

func TestGetItemNotFound(t *testing.T) {
	s, _ := newTestStore(t)
	_, err := s.GetItem(context.Background(), 12345)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

func TestDeleteItemNotFound(t *testing.T) {
	s, _ := newTestStore(t)
	if err := s.DeleteItem(context.Background(), 12345); !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

// Read right after write: the item is on the primary only, GetItem must
// still find it.
func TestGetItemFallsBackToPrimary(t *testing.T) {
	s, _ := newTestStore(t)
	ctx := context.Background()
	created, err := s.CreateItem(ctx, "fresh")
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.GetItem(ctx, created.ID)
	if err != nil {
		t.Fatalf("GetItem after CreateItem: %v", err)
	}
	if got.Name != "fresh" {
		t.Fatalf("name = %q, want fresh", got.Name)
	}
}

// A database error must not be reported as ErrNotFound.
func TestGetItemDatabaseError(t *testing.T) {
	s, _ := newTestStore(t)
	s.ro.Close()
	s.rw.Close()
	_, err := s.GetItem(context.Background(), 1)
	if err == nil || errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want a database error that is not ErrNotFound", err)
	}
}

func TestGetItemsPagination(t *testing.T) {
	s, replica := newTestStore(t)
	ctx := context.Background()
	// GetItems reads the replica: seed it directly
	for _, n := range []string{"a", "b", "c", "d", "e"} {
		if _, err := replica.Exec(ctx, "INSERT INTO items (name) VALUES ($1)", n); err != nil {
			t.Fatal(err)
		}
	}
	page := func(limit, before int) string {
		t.Helper()
		items, err := s.GetItems(ctx, limit, before)
		if err != nil {
			t.Fatal(err)
		}
		names := make([]string, len(items))
		for i, it := range items {
			names[i] = it.Name
		}
		return strings.Join(names, ",")
	}
	if got := page(2, 0); got != "e,d" {
		t.Fatalf("first page = %s, want e,d", got)
	}
	if got := page(2, 4); got != "c,b" {
		t.Fatalf("page before id 4 = %s, want c,b", got)
	}
	if got := page(10, 2); got != "a" {
		t.Fatalf("page before id 2 = %s, want a", got)
	}
}
