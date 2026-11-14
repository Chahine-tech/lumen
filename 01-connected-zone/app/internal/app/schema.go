package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/Chahine-tech/lumen/internal/migrations"
)

// legacySchemaVersion is the migration matching the schema that lumen-api
// created at startup up to v1.6.0.
const legacySchemaVersion = 1

// schemaVersioner is the part of the PostgreSQL store checkSchema needs.
type schemaVersioner interface {
	SchemaVersion(ctx context.Context) (int64, error)
}

// checkSchema refuses to start when the database is older than this build:
// `lumen-api migrate` runs before the rollout (ArgoCD PreSync Job), so a
// missing migration means that step failed or was skipped. A newer schema is
// expected while an older version is still running during a canary, or after
// a rollback; migrations are written for it (docs/databases.md, expand and
// contract).
//
// It is also the startup connectivity check: the pools connect lazily.
func checkSchema(s schemaVersioner) error {
	latest, err := migrations.Latest(migrations.Files())
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	current, err := s.SchemaVersion(ctx)
	if errors.Is(err, migrations.ErrUnmanaged) {
		// A database created by lumen-api up to v1.6.0, which ran its schema
		// at startup: that schema is migration 1 (00001_initial_schema.sql)
		slog.Warn("Database has no migration history, run lumen-api migrate", "build_version", latest)
		current, err = legacySchemaVersion, nil
	}
	switch {
	case err != nil:
		return fmt.Errorf("failed to read the schema version: %w", err)
	case current < latest:
		return fmt.Errorf("database schema is at version %d, this build needs %d: run lumen-api migrate first", current, latest)
	case current > latest:
		slog.Info("Database schema is newer than this build", "schema_version", current, "build_version", latest)
	}
	return nil
}
