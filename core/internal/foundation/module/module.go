// Package module defines the contract every Core feature module implements.
//
// A module owns its tables (via Migrations), exposes routes only through the
// shared Router, and never touches another module's tables directly.
package module

import (
	"database/sql"
	"log/slog"

	"aerhome/core/internal/foundation/httpapi"
	"aerhome/core/internal/foundation/storage"
)

// Deps are the shared Foundation services handed to a module.
type Deps struct {
	DB     *sql.DB
	Logger *slog.Logger
	Demo   bool
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
