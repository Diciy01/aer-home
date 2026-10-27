// Package module defines the contract every Core feature module implements.
//
// A module owns its tables (via Migrations), exposes routes only through the
// shared Router, and never touches another module's tables directly.
package module

import (
	"context"
	"database/sql"
	"log/slog"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/foundation/httpapi"
	"aerhome/core/internal/foundation/storage"
)

// Deps are the shared Foundation services handed to a module.
type Deps struct {
	DB     *sql.DB
	Logger *slog.Logger
	Demo   bool
	// Config is the effective Core configuration (no secrets inside).
	Config config.Config
}

// Runner is implemented by modules with background work (checks, retention).
// Core calls Run once after all modules started, in its own goroutine, and
// cancels ctx on shutdown; Run must return promptly after that.
type Runner interface {
	Run(ctx context.Context)
}

// Module is a self-contained feature (Registry, Scene, Monitoring, ...).
type Module interface {
	// Name is the stable identifier used in config and schema_migrations.
	Name() string
	// Migrations are applied in order under this module's namespace.
	Migrations() []storage.Migration
	// RegisterRoutes adds the module's endpoints.
	RegisterRoutes(r *httpapi.Router)
}

// Factory builds a module once its dependencies are ready.
type Factory func(Deps) (Module, error)

// Named registers an optional module under its config name.
type Named struct {
	Name string
	New  Factory
}

// Status describes a known module for /system/info.
type Status struct {
	Name    string `json:"name"`
	Enabled bool   `json:"enabled"`
	// Error is set when an enabled module failed to start; Core keeps running.
	Error string `json:"error,omitempty"`
}
