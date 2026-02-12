package main

import (
	"log"

	"github.com/Chahine-tech/lumen/internal/app"
)

func main() {
	// Create application
	application, err := app.NewApp()
	if err != nil {
		log.Fatalf("Failed to initialize app: %v", err)
	}

	// Run with graceful shutdown
	if err := application.Run(); err != nil {
		log.Fatalf("Server error: %v", err)
	}
}
