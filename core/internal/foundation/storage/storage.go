// Package storage opens the Core SQLite database and runs per-module migrations.
//
// Every module owns its tables and ships its own ordered migration list.
// Applied versions are tracked per module in schema_migrations.
package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite" // pure-Go SQLite driver, registers "sqlite"
)

// Migration is one forward-only schema step owned by a module.
type Migration struct {
	Version int
	Name    string
	SQL     string
}

// AppliedVersion is the current schema version of one module.
type AppliedVersion struct {
	Module  string `json:"module"`
	Version int    `json:"version"`
}

// ErrSchemaNewer means the database was migrated by a newer Core build.
var ErrSchemaNewer = errors.New("database schema is newer than this Core build")

// Open opens (creating if needed) the SQLite database at path in WAL mode.
func Open(ctx context.Context, path string) (*sql.DB, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	dsn := "file:" + path +
		"?_pragma=journal_mode(WAL)" +
		"&_pragma=busy_timeout(5000)" +
		"&_pragma=foreign_keys(ON)" +
		"&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	// One connection serialises writers; enough for a single-user home Core
	// and avoids SQLITE_BUSY between pooled connections.
	db.SetMaxOpenConns(1)
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}
	if _, err := db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		module     TEXT    NOT NULL,
		version    INTEGER NOT NULL,
		name       TEXT    NOT NULL,
		applied_at TEXT    NOT NULL,
		PRIMARY KEY (module, version)
	)`); err != nil {
		db.Close()
		return nil, fmt.Errorf("create schema_migrations: %w", err)
	}
	return db, nil
}

// Migrate applies the pending migrations of one module, each in its own transaction.
// It returns how many migrations were applied.
func Migrate(ctx context.Context, db *sql.DB, module string, migrations []Migration) (int, error) {
	for i, m := range migrations {
		if m.Version != i+1 || m.Name == "" || m.SQL == "" {
			return 0, fmt.Errorf("%s: migration #%d must have version %d, a name and SQL", module, i, i+1)
		}
	}

	applied := map[int]string{}
	rows, err := db.QueryContext(ctx, `SELECT version, name FROM schema_migrations WHERE module = ?`, module)
	if err != nil {
		return 0, fmt.Errorf("%s: read applied migrations: %w", module, err)
	}
	for rows.Next() {
		var v int
		var name string
		if err := rows.Scan(&v, &name); err != nil {
			rows.Close()
			return 0, err
		}
		applied[v] = name
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	for v, name := range applied {
		if v > len(migrations) {
			return 0, fmt.Errorf("%s: version %d applied, binary knows %d: %w", module, v, len(migrations), ErrSchemaNewer)
		}
		if want := migrations[v-1].Name; want != name {
			return 0, fmt.Errorf("%s: migration %d recorded as %q but binary has %q", module, v, name, want)
		}
	}

	count := 0
	for _, m := range migrations {
		if _, done := applied[m.Version]; done {
			continue
		}
		if err := applyOne(ctx, db, module, m); err != nil {
			return count, err
		}
		count++
	}
	return count, nil
}

func applyOne(ctx context.Context, db *sql.DB, module string, m Migration) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, m.SQL); err != nil {
		return fmt.Errorf("%s: migration %d %q: %w", module, m.Version, m.Name, err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO schema_migrations (module, version, name, applied_at) VALUES (?, ?, ?, ?)`,
		module, m.Version, m.Name, time.Now().UTC().Format(time.RFC3339Nano),
	); err != nil {
		return err
	}
	return tx.Commit()
}

// AppliedVersions lists the highest applied migration per module.
func AppliedVersions(ctx context.Context, db *sql.DB) ([]AppliedVersion, error) {
	rows, err := db.QueryContext(ctx,
		`SELECT module, MAX(version) FROM schema_migrations GROUP BY module ORDER BY module`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AppliedVersion
	for rows.Next() {
		var av AppliedVersion
		if err := rows.Scan(&av.Module, &av.Version); err != nil {
			return nil, err
		}
		out = append(out, av)
	}
	return out, rows.Err()
}
