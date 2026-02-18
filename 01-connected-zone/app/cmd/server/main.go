package main

import (
	"context"
	"log/slog"
	"os"

	"github.com/Chahine-tech/lumen/internal/app"
	"github.com/Chahine-tech/lumen/internal/tracing"
)

func main() {
	// Configure structured JSON logging (for Loki)
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	// Initialize OpenTelemetry TracerProvider (sends traces to Tempo)
	ctx := context.Background()
	shutdown, err := tracing.Init(ctx)
	if err != nil {
		slog.Warn("Tracing initialization failed, continuing without tracing", "error", err)
	} else {
		defer shutdown(ctx)
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
