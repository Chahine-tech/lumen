package app

import (
	"context"
	"errors"
	"testing"

	"github.com/Chahine-tech/lumen/internal/migrations"
)

type fakeVersioner struct {
	version int64
	err     error
}

func (f fakeVersioner) SchemaVersion(context.Context) (int64, error) { return f.version, f.err }

func TestCheckSchema(t *testing.T) {
	latest, err := migrations.Latest(migrations.Files())
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name    string
		store   fakeVersioner
		wantErr bool
	}{
		{"up to date", fakeVersioner{version: latest}, false},
		{"newer schema, older build (canary, rollback)", fakeVersioner{version: latest + 1}, false},
		{"older schema", fakeVersioner{version: latest - 1}, true},
		{"never migrated", fakeVersioner{err: migrations.ErrNoSchema}, true},
		{"database unreachable", fakeVersioner{err: errors.New("connection refused")}, true},
		// Schema created at startup by v1.6.0: counts as migration 1
		{"legacy schema", fakeVersioner{err: migrations.ErrUnmanaged}, latest > legacySchemaVersion},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := checkSchema(tc.store)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
		})
	}
}
