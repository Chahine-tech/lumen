// Package migrations holds the versioned database schema and applies it.
//
// Migrations run from `lumen-api migrate`, as the role that owns the schema,
// before a new version is rolled out. The API itself connects as a role with
// DML rights only and checks at startup that the schema is recent enough.
package migrations

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	_ "github.com/jackc/pgx/v5/stdlib" // database/sql driver "pgx", used by goose
	"github.com/pressly/goose/v3"
	"github.com/pressly/goose/v3/lock"
)

//go:embed sql/*.sql
var embedded embed.FS

// TableName is the goose version table (goose default name).
const TableName = "goose_db_version"

// Files returns the embedded migrations.
func Files() fs.FS {
	sub, err := fs.Sub(embedded, "sql")
	if err != nil {
		panic(err) // the directory is embedded at build time
	}
	return sub
}

// Latest returns the highest version among the migrations in fsys: the
// schema version a binary built with them expects.
func Latest(fsys fs.FS) (int64, error) {
	entries, err := fs.ReadDir(fsys, ".")
	if err != nil {
		return 0, err
	}
	var latest int64
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".sql") {
			continue
		}
		prefix, _, _ := strings.Cut(e.Name(), "_")
		v, err := strconv.ParseInt(prefix, 10, 64)
		if err != nil {
			return 0, fmt.Errorf("migration %s: version prefix: %w", e.Name(), err)
		}
		latest = max(latest, v)
	}
	return latest, nil
}

// Up applies the pending migrations of fsys, then grants the runtime role
// its rights when runtimeRole is set.
//
// A PostgreSQL session advisory lock serializes concurrent runs: a second
// Job (a retried sync, two syncs racing) waits, then finds nothing to apply.
func Up(ctx context.Context, dsn string, fsys fs.FS, runtimeRole string) error {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	if err := waitForDatabase(ctx, db, connectTimeout); err != nil {
		return err
	}

	locker, err := lock.NewPostgresSessionLocker()
	if err != nil {
		return err
	}
	provider, err := goose.NewProvider(goose.DialectPostgres, db, fsys,
		goose.WithSessionLocker(locker),
		goose.WithDisableGlobalRegistry(true),
	)
	if err != nil {
		return err
	}
	defer func() { _ = provider.Close() }()

	results, err := provider.Up(ctx)
	for _, r := range results {
		slog.Info("Migration applied", "version", r.Source.Version, "file", r.Source.Path, "duration", r.Duration)
	}
	if err != nil {
		return err
	}
	version, err := provider.GetDBVersion(ctx)
	if err != nil {
		return err
	}
	slog.Info("Schema up to date", "version", version, "applied", len(results))

	if runtimeRole == "" {
		return nil
	}
	return grantRuntime(ctx, db, runtimeRole)
}

// connectTimeout bounds waitForDatabase. A new pod in lumen has no DNS for
// its first seconds, until its NetworkPolicies are programmed (seen on k3d:
// "Temporary failure in name resolution", gone after 4s).
const connectTimeout = 30 * time.Second

// waitForDatabase retries the first connection, so that a slow start of the
// pod network fails neither the Job nor the sync.
func waitForDatabase(ctx context.Context, db *sql.DB, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	for {
		err := db.PingContext(ctx)
		if err == nil {
			return nil
		}
		slog.Warn("Database not reachable yet, retrying", "error", err)
		select {
		case <-ctx.Done():
			return fmt.Errorf("database not reachable after %s: %w", timeout, err)
		case <-time.After(2 * time.Second):
		}
	}
}

// grantRuntime gives the runtime role DML on every table and sequence, and
// nothing else. Run after each migration, so new tables are covered.
//
// The role must exist (CNPG managed role, cnpg/02-cluster.yaml). It does not
// own the schema, so it cannot create, alter or drop tables. TEMPORARY is
// granted to PUBLIC by default: revoked, so it cannot create temporary
// tables either.
func grantRuntime(ctx context.Context, db *sql.DB, role string) error {
	r := pgx.Identifier{role}.Sanitize()
	var dbName string
	if err := db.QueryRowContext(ctx, "SELECT current_database()").Scan(&dbName); err != nil {
		return err
	}
	d := pgx.Identifier{dbName}.Sanitize()
	statements := []string{
		"REVOKE TEMPORARY ON DATABASE " + d + " FROM PUBLIC",
		"GRANT CONNECT ON DATABASE " + d + " TO " + r,
		"GRANT USAGE ON SCHEMA public TO " + r,
		"GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO " + r,
		"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO " + r,
		// The version table: read by the startup check, written only here
		"REVOKE INSERT, UPDATE, DELETE ON " + TableName + " FROM " + r,
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }() // no-op after Commit
	for _, s := range statements {
		if _, err := tx.ExecContext(ctx, s); err != nil {
			return fmt.Errorf("%s: %w", s, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	slog.Info("Runtime role granted DML rights", "role", role)
	return nil
}

// Querier is the part of pgx used by Version (*pgxpool.Pool, *pgx.Conn).
type Querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ErrUnmanaged means the database has the tables but no migration table: it
// was created by a version of lumen-api that ran its schema at startup (up to
// v1.6.0). `lumen-api migrate` adopts it.
var ErrUnmanaged = errors.New("database has no migration history")

// ErrNoSchema means the database has neither the migration table nor the
// tables: `lumen-api migrate` has never run.
var ErrNoSchema = errors.New("database has no schema")

// Version returns the schema version recorded in the database.
func Version(ctx context.Context, q Querier) (int64, error) {
	var versioned, legacy bool
	err := q.QueryRow(ctx, "SELECT to_regclass($1) IS NOT NULL, to_regclass('items') IS NOT NULL", TableName).Scan(&versioned, &legacy)
	switch {
	case err != nil:
		return 0, err
	case !versioned && legacy:
		return 0, ErrUnmanaged
	case !versioned:
		return 0, ErrNoSchema
	}
	// goose deletes the row of a migration it rolls back: the highest
	// remaining version is the current one (same query as goose)
	var v int64
	err = q.QueryRow(ctx, "SELECT COALESCE(max(version_id), 0) FROM "+TableName).Scan(&v)
	return v, err
}
