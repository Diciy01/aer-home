// Package core wires Foundation services and feature modules into one process.
package core

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"aerhome/core/internal/foundation/auth"
	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/foundation/httpapi"
	"aerhome/core/internal/foundation/ids"
	"aerhome/core/internal/foundation/logging"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
)

// foundationModule is the schema namespace owned by Foundation itself.
const foundationModule = "foundation"

var foundationMigrations = []storage.Migration{
	{Version: 1, Name: "create_core_meta", SQL: `CREATE TABLE core_meta (
		key   TEXT PRIMARY KEY,
		value TEXT NOT NULL
	)`},
}

// Options configure a Core instance.
type Options struct {
	Config  config.Config
	Logger  *slog.Logger
	Modules []module.Named
	Now     func() time.Time
}

// Core is a running AER Core (without the network listener).
type Core struct {
	cfg          config.Config
	db           *sql.DB
	log          *slog.Logger
	router       *httpapi.Router
	now          func() time.Time
	startedAt    time.Time
	instance     instance
	modules      []module.Status
	tokenCreated bool
	runners      []module.Runner
	sink         *logging.Sink
	cancel       context.CancelFunc
	wg           sync.WaitGroup
}

type instance struct {
	ID        string
	CreatedAt string
}

// New opens storage, applies Foundation migrations, loads the API token and
// starts every enabled module. A module that fails is reported, not fatal.
func New(ctx context.Context, opts Options) (*Core, error) {
	if opts.Now == nil {
		opts.Now = time.Now
	}
	sink := logging.NewSink(256)
	c := &Core{cfg: opts.Config, log: logging.WithSink(opts.Logger, sink), sink: sink, now: opts.Now, startedAt: opts.Now().UTC()}

	db, err := storage.Open(ctx, c.cfg.DatabasePath())
	if err != nil {
		return nil, err
	}
	c.db = db
	if _, err := storage.Migrate(ctx, db, foundationModule, foundationMigrations); err != nil {
		db.Close()
		return nil, err
	}
	if c.instance, err = ensureInstance(ctx, db, c.startedAt); err != nil {
		db.Close()
		return nil, err
	}

	token, created, err := auth.LoadOrCreateToken(c.cfg.TokenPath())
	if err != nil {
		db.Close()
		return nil, err
	}
	c.tokenCreated = created
	c.router = httpapi.NewRouter(c.log, func(t string) bool { return auth.Equal(t, token) })
	c.registerFoundationRoutes()

	for _, nf := range opts.Modules {
		c.modules = append(c.modules, c.startModule(ctx, nf))
	}
	// Background work lives as long as the Core, not the startup context.
	runCtx, cancel := context.WithCancel(context.Background())
	c.cancel = cancel
	for _, r := range c.runners {
		c.wg.Add(1)
		go func() {
			defer c.wg.Done()
			r.Run(runCtx)
		}()
	}
	return c, nil
}

func (c *Core) startModule(ctx context.Context, nf module.Named) module.Status {
	st := module.Status{Name: nf.Name, Enabled: c.cfg.ModuleEnabled(nf.Name)}
	if !st.Enabled {
		c.log.Info("module disabled by config", "module", nf.Name)
		return st
	}
	fail := func(err error) module.Status {
		c.log.Error("module failed to start; continuing without it", "module", nf.Name, "err", err)
		st.Error = err.Error()
		return st
	}
	m, err := nf.New(module.Deps{DB: c.db, Logger: logging.Module(c.log, nf.Name), Demo: c.cfg.IsDemo(), Config: c.cfg, LogSink: c.sink})
	if err != nil {
		return fail(err)
	}
	if m.Name() != nf.Name {
		return fail(fmt.Errorf("module reports name %q, registered as %q", m.Name(), nf.Name))
	}
	if _, err := storage.Migrate(ctx, c.db, m.Name(), m.Migrations()); err != nil {
		return fail(err)
	}
	m.RegisterRoutes(c.router)
	if r, ok := m.(module.Runner); ok {
		c.runners = append(c.runners, r)
	}
	return st
}

// Handler is the HTTP entry point.
func (c *Core) Handler() http.Handler { return c.router }

// Routes lists registered endpoints.
func (c *Core) Routes() []httpapi.Route { return c.router.Routes() }

// TokenCreated reports whether this start generated a new API token.
func (c *Core) TokenCreated() bool { return c.tokenCreated }

// InstanceID is the persistent identity of this Core database.
func (c *Core) InstanceID() string { return c.instance.ID }

// Close stops background work and releases the database.
func (c *Core) Close() error {
	if c.cancel != nil {
		c.cancel()
	}
	c.wg.Wait()
	return c.db.Close()
}

func ensureInstance(ctx context.Context, db *sql.DB, now time.Time) (instance, error) {
	if _, err := db.ExecContext(ctx,
		`INSERT OR IGNORE INTO core_meta (key, value) VALUES ('instance_id', ?), ('created_at', ?)`,
		ids.New(), now.Format(time.RFC3339)); err != nil {
		return instance{}, fmt.Errorf("init core_meta: %w", err)
	}
	var in instance
	err := db.QueryRowContext(ctx, `SELECT
		(SELECT value FROM core_meta WHERE key = 'instance_id'),
		(SELECT value FROM core_meta WHERE key = 'created_at')`).Scan(&in.ID, &in.CreatedAt)
	if err != nil {
		return instance{}, fmt.Errorf("read core_meta: %w", err)
	}
	return in, nil
}
