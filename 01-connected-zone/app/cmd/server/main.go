package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/Chahine-tech/lumen/internal/app"
	"github.com/Chahine-tech/lumen/internal/migrations"
	"github.com/Chahine-tech/lumen/internal/smoke"
	"github.com/Chahine-tech/lumen/internal/tracing"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "migrate":
			if err := migrate(); err != nil {
				slog.Error("Migration failed", "error", err)
				os.Exit(1)
			}
			return
		case "smoke":
			if err := smokeTest(); err != nil {
				slog.Error("Smoke test failed", "error", err)
				os.Exit(1)
			}
			slog.Info("Smoke test passed")
			return
		default:
			fmt.Fprintf(os.Stderr, "unknown command %q (usage: lumen-api [migrate|smoke])\n", os.Args[1])
			os.Exit(2)
		}
	}

	ctx := context.Background()
	shutdown, err := tracing.Init(ctx)
	if err != nil {
		slog.Warn("Tracing initialization failed, continuing without tracing", "error", err)
	} else {
		defer func() { _ = shutdown(ctx) }()
	}

	application, err := app.NewApp()
	if err != nil {
		slog.Error("Failed to initialize app", "error", err)
		os.Exit(1)
	}

	if err := application.Run(); err != nil {
		slog.Error("Server error", "error", err)
		os.Exit(1)
	}
}

// migrate applies the embedded migrations, as the role that owns the schema
// (PG_MIGRATE_DSN), then grants DML to the role the API runs as
// (PG_RUNTIME_ROLE, optional). Run by the PreSync Job before each rollout.
func migrate() error {
	dsn := os.Getenv("PG_MIGRATE_DSN")
	if dsn == "" {
		return fmt.Errorf("PG_MIGRATE_DSN is not set")
	}
	return migrations.Up(context.Background(), dsn, migrations.Files(), os.Getenv("PG_RUNTIME_ROLE"))
}

// smokeTest checks a deployed lumen-api (SMOKE_URL, e.g.
// http://lumen-api-canary.lumen.svc:8080) through its public API, with the
// bearer token in SMOKE_TOKEN_FILE (a projected ServiceAccount token).
// SMOKE_EXPECT_AUTH=true also checks that a request without a token is
// refused. docs/runbooks/lumen-api-smoke-test.md
func smokeTest() error {
	url := os.Getenv("SMOKE_URL")
	if url == "" {
		return fmt.Errorf("SMOKE_URL is not set")
	}
	opts := smoke.Options{ExpectAuth: os.Getenv("SMOKE_EXPECT_AUTH") == "true"}
	if f := os.Getenv("SMOKE_TOKEN_FILE"); f != "" {
		token, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		opts.Token = strings.TrimSpace(string(token))
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	return smoke.Run(ctx, &http.Client{Timeout: 10 * time.Second}, url, opts)
}
