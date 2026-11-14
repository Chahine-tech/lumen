package migrations_test

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"sync"
	"testing"
	"testing/fstest"

	"github.com/Chahine-tech/lumen/internal/migrations"
	"github.com/Chahine-tech/lumen/internal/store"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/prometheus/client_golang/prometheus"
)

func TestLatest(t *testing.T) {
	v, err := migrations.Latest(migrations.Files())
	if err != nil {
		t.Fatal(err)
	}
	if v != 1 {
		t.Fatalf("Latest = %d, want 1", v)
	}
	if _, err := migrations.Latest(fstest.MapFS{"initial.sql": {}}); err == nil {
		t.Fatal("a file without a version prefix must be an error")
	}
}

// Integration tests against a real PostgreSQL, as a superuser: they create
// the roles lumen_test_owner and lumen_test_runtime and the database
// lumen_test_migrations. Skipped unless LUMEN_TEST_PG_DSN is set (see
// internal/store/postgres_test.go for a container to run them against).

const (
	ownerRole   = "lumen_test_owner"
	runtimeRole = "lumen_test_runtime"
	testDB      = "lumen_test_migrations"
)

// testDatabase recreates the test database, owned by ownerRole as in the
// CNPG cluster (initdb owner app), and returns the DSN for a role.
func testDatabase(t *testing.T) (dsnAs func(role string) string) {
	t.Helper()
	dsn := os.Getenv("LUMEN_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("LUMEN_TEST_PG_DSN not set")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close(ctx)
	for _, s := range []string{
		"DROP DATABASE IF EXISTS " + testDB + " WITH (FORCE)",
		"DROP ROLE IF EXISTS " + runtimeRole,
		"DROP ROLE IF EXISTS " + ownerRole,
		"CREATE ROLE " + ownerRole + " LOGIN PASSWORD 'owner'",
		"CREATE ROLE " + runtimeRole + " LOGIN PASSWORD 'runtime'",
		"CREATE DATABASE " + testDB + " OWNER " + ownerRole,
	} {
		if _, err := admin.Exec(ctx, s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
	cfg, err := pgconn.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	// Each role's password is its name without the prefix
	return func(role string) string {
		return fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=disable",
			role, strings.TrimPrefix(role, "lumen_test_"), cfg.Host, cfg.Port, testDB)
	}
}

func connect(t *testing.T, dsn string) *pgx.Conn {
	t.Helper()
	conn, err := pgx.Connect(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close(context.Background()) })
	return conn
}

func exec(t *testing.T, conn *pgx.Conn, sql string) {
	t.Helper()
	if _, err := conn.Exec(context.Background(), sql); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

func appliedVersions(t *testing.T, conn *pgx.Conn) []int64 {
	t.Helper()
	rows, err := conn.Query(context.Background(), "SELECT version_id FROM "+migrations.TableName+" WHERE version_id > 0 ORDER BY id")
	if err != nil {
		t.Fatal(err)
	}
	versions, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		t.Fatal(err)
	}
	return versions
}

func TestUpFreshDatabase(t *testing.T) {
	dsnAs := testDatabase(t)
	ctx := context.Background()
	owner := connect(t, dsnAs(ownerRole))

	if _, err := migrations.Version(ctx, owner); !errors.Is(err, migrations.ErrNoSchema) {
		t.Fatalf("Version before migrating: err = %v, want ErrNoSchema", err)
	}
	for range 2 {
		if err := migrations.Up(ctx, dsnAs(ownerRole), migrations.Files(), ""); err != nil {
			t.Fatal(err)
		}
	}
	if v, err := migrations.Version(ctx, owner); err != nil || v != 1 {
		t.Fatalf("Version = %d, %v, want 1", v, err)
	}
	// The second run applied nothing
	if got := appliedVersions(t, owner); len(got) != 1 {
		t.Fatalf("applied versions = %v, want [1]", got)
	}
}

// A database created by lumen-api v1.6.0 at startup: migration 1 adopts it
// and keeps its rows.
func TestUpAdoptsLegacySchema(t *testing.T) {
	dsnAs := testDatabase(t)
	ctx := context.Background()
	owner := connect(t, dsnAs(ownerRole))
	legacy, err := fs.ReadFile(migrations.Files(), "00001_initial_schema.sql")
	if err != nil {
		t.Fatal(err)
	}
	up, _, _ := strings.Cut(string(legacy), "-- +goose Down")
	exec(t, owner, up)
	exec(t, owner, "INSERT INTO items (name) VALUES ('kept')")

	if _, err := migrations.Version(ctx, owner); !errors.Is(err, migrations.ErrUnmanaged) {
		t.Fatalf("Version before migrating: err = %v, want ErrUnmanaged", err)
	}
	if err := migrations.Up(ctx, dsnAs(ownerRole), migrations.Files(), ""); err != nil {
		t.Fatal(err)
	}
	if v, err := migrations.Version(ctx, owner); err != nil || v != 1 {
		t.Fatalf("Version = %d, %v, want 1", v, err)
	}
	var name string
	if err := owner.QueryRow(ctx, "SELECT name FROM items").Scan(&name); err != nil || name != "kept" {
		t.Fatalf("row after adoption: %q, %v", name, err)
	}
}

// Several Jobs starting at once (a retried sync, two syncs racing): the
// advisory lock makes them run one after the other. Migration 2 is slow and
// not idempotent, so without the lock a second run fails or records it twice.
func TestConcurrentUp(t *testing.T) {
	dsnAs := testDatabase(t)
	fsys := fstest.MapFS{
		"00001_initial_schema.sql": mustFile(t, "00001_initial_schema.sql"),
		"00002_slow.sql": {Data: []byte("-- +goose Up\nSELECT pg_sleep(1);\nCREATE TABLE slow (id int);\n" +
			"-- +goose Down\nDROP TABLE slow;\n")},
	}
	var wg sync.WaitGroup
	errs := make([]error, 4)
	for i := range errs {
		wg.Go(func() { errs[i] = migrations.Up(context.Background(), dsnAs(ownerRole), fsys, "") })
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("run %d: %v", i, err)
		}
	}
	if got := appliedVersions(t, connect(t, dsnAs(ownerRole))); len(got) != 2 {
		t.Fatalf("applied versions = %v, want [1 2]", got)
	}
}

func mustFile(t *testing.T, name string) *fstest.MapFile {
	t.Helper()
	b, err := fs.ReadFile(migrations.Files(), name)
	if err != nil {
		t.Fatal(err)
	}
	return &fstest.MapFile{Data: b}
}

// The acceptance criterion of the role split: the runtime role reads and
// writes rows, and every DDL statement is refused.
func TestRuntimeRoleRights(t *testing.T) {
	dsnAs := testDatabase(t)
	ctx := context.Background()
	if err := migrations.Up(ctx, dsnAs(ownerRole), migrations.Files(), runtimeRole); err != nil {
		t.Fatal(err)
	}
	rt := connect(t, dsnAs(runtimeRole))

	for _, s := range []string{
		"INSERT INTO items (name) VALUES ('a')",
		"UPDATE items SET name = 'b'",
		"SELECT count(*) FROM items",
		"DELETE FROM items",
		`INSERT INTO events (type, aggregate, payload) VALUES ('t', 'a', '{}')`,
		"SELECT count(*) FROM events",
	} {
		if _, err := rt.Exec(ctx, s); err != nil {
			t.Errorf("runtime role, DML refused: %s: %v", s, err)
		}
	}
	if v, err := migrations.Version(ctx, rt); err != nil || v != 1 {
		t.Errorf("runtime role, Version = %d, %v, want 1", v, err)
	}

	for _, s := range []string{
		"CREATE TABLE t (id int)",
		"CREATE TEMP TABLE t (id int)",
		"CREATE SCHEMA s",
		"CREATE INDEX items_name_idx ON items (name)",
		"ALTER TABLE items ADD COLUMN c int",
		"DROP TABLE events",
		"TRUNCATE items",
		"INSERT INTO " + migrations.TableName + " (version_id, is_applied) VALUES (99, true)",
		"DELETE FROM " + migrations.TableName,
	} {
		_, err := rt.Exec(ctx, s)
		var pgErr *pgconn.PgError
		// 42501 insufficient_privilege: refused for rights, not for another reason
		if !errors.As(err, &pgErr) || pgErr.Code != "42501" {
			t.Errorf("runtime role, %s: err = %v, want insufficient_privilege", s, err)
		}
	}
}

// Expand and contract: after an expand migration (a nullable column), the
// store of the previous version keeps working, which is what runs during a
// canary once the PreSync Job has migrated.
func TestStoreWorksAfterExpandMigration(t *testing.T) {
	dsnAs := testDatabase(t)
	ctx := context.Background()
	fsys := fstest.MapFS{
		"00001_initial_schema.sql": mustFile(t, "00001_initial_schema.sql"),
		"00002_items_description.sql": {Data: []byte("-- +goose Up\nALTER TABLE items ADD COLUMN description TEXT;\n" +
			"-- +goose Down\nALTER TABLE items DROP COLUMN description;\n")},
	}
	if err := migrations.Up(ctx, dsnAs(ownerRole), fsys, runtimeRole); err != nil {
		t.Fatal(err)
	}
	counter := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "test_events_total"}, []string{"type"})
	s, err := store.NewPostgresStore(ctx, dsnAs(runtimeRole), dsnAs(runtimeRole), counter)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	created, err := s.CreateItem(ctx, "during canary")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetItem(ctx, created.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetItems(ctx, 10, 0); err != nil {
		t.Fatal(err)
	}
	if err := s.DeleteItem(ctx, created.ID); err != nil {
		t.Fatal(err)
	}
	if v, err := s.SchemaVersion(ctx); err != nil || v != 2 {
		t.Fatalf("SchemaVersion = %d, %v, want 2", v, err)
	}
}
