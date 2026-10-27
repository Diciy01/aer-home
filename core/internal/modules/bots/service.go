package bots

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"strconv"
	"sync"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

// RegistryWriter is what Bots needs from Registry: the reader plus the
// owner-level writes used when a bot is added, edited or archived from the
// Bots UI. Registry keeps validating everything; Bots never touches its tables.
type RegistryWriter interface {
	registry.Reader
	Create(ctx context.Context, in registry.NewEntity) (registry.Entity, error)
	Update(ctx context.Context, id string, p registry.EntityPatch) (registry.Entity, error)
	Archive(ctx context.Context, id string, revision int) (registry.Entity, error)
	Restore(ctx context.Context, id string, revision int) (registry.Entity, error)
	AddRelation(ctx context.Context, fromID, kind, toID, label string) (registry.Relation, error)
	DeleteRelation(ctx context.Context, id string) error
}

// Errors mapped to API responses.
var (
	ErrNotFound = errors.New("bot not found")
	ErrNotABot  = errors.New("entity is not configured as a bot")
)

// ValidationError lists field problems (422).
type ValidationError struct{ Fields map[string]string }

func (e *ValidationError) Error() string { return "validation failed" }

func (e *ValidationError) add(field, msg string) {
	if e.Fields == nil {
		e.Fields = map[string]string{}
	}
	if _, ok := e.Fields[field]; !ok {
		e.Fields[field] = msg
	}
}

func (e *ValidationError) orNil() error {
	if len(e.Fields) == 0 {
		return nil
	}
	return e
}

// ConflictError is an optimistic-lock or state conflict (409).
type ConflictError struct {
	Reason          string
	Message         string
	CurrentRevision int
}

func (e *ConflictError) Error() string { return e.Message }

// ActionError is a refused action (403/400/409).
type ActionError struct {
	Status  int
	Code    string // PERMISSION_REQUIRED | UNSUPPORTED | CONFLICT | UNAVAILABLE
	Message string
}

func (e *ActionError) Error() string { return e.Message }

// Service implements Bots on top of Registry and Monitoring.
type Service struct {
	db  *sql.DB
	reg RegistryWriter
	mon *monitoring.Service
	cfg config.Bots
	log *slog.Logger
	now func() time.Time

	adapters    []Adapter
	controllers map[string]Controller
	checkers    []Checker
	syncers     []Syncer
	retrier     Retrier
	process     *processAdapter
	n8n         *n8nAdapter
	ops         chan struct{} // bounded concurrency of management operations

	mu       sync.Mutex
	busy     map[string]string // entityID → running action
	confirms map[string]Confirmation
	rtCache  map[string]cachedRuntime
	lists    map[string]*listEntry // by archive mode
}

type cachedRuntime struct {
	st RuntimeState
	at time.Time
}

// NewService builds the service and registers the built-in adapters.
func NewService(db *sql.DB, reg RegistryWriter, mon *monitoring.Service, cfg config.Bots, log *slog.Logger, now func() time.Time) *Service {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	s := &Service{db: db, reg: reg, mon: mon, cfg: cfg, log: log, now: now,
		controllers: map[string]Controller{}, ops: make(chan struct{}, cfg.MaxConcurrentOps),
		busy: map[string]string{}, confirms: map[string]Confirmation{}, rtCache: map[string]cachedRuntime{},
		lists: map[string]*listEntry{}}
	s.process = newProcessAdapter(s)
	s.n8n = newN8NAdapter(s)
	s.Register(heartbeatAdapter{})
	s.Register(newTelegramAdapter(s))
	s.Register(s.process)
	s.Register(newSystemdAdapter(s))
	s.Register(newDockerAdapter(s))
	s.Register(s.n8n)
	return s
}

// Register adds an adapter; optional interfaces are detected here.
func (s *Service) Register(a Adapter) {
	s.adapters = append(s.adapters, a)
	if c, ok := a.(Controller); ok {
		s.controllers[c.Kind()] = c
	}
	if c, ok := a.(Checker); ok {
		s.checkers = append(s.checkers, c)
	}
	if c, ok := a.(Syncer); ok {
		s.syncers = append(s.syncers, c)
	}
	if c, ok := a.(Retrier); ok {
		s.retrier = c
	}
}

// Adapters describes every registered adapter and its configured instances.
func (s *Service) Adapters(ctx context.Context) []AdapterInfo {
	used := map[string]string{}
	if cs, err := s.configs(ctx, "controller_id != ''"); err == nil {
		for _, c := range cs {
			if e, err := s.reg.Get(ctx, c.EntityID); err == nil && !e.Archived {
				used[c.ControllerID] = e.Name
			}
		}
	}
	out := make([]AdapterInfo, 0, len(s.adapters))
	for _, a := range s.adapters {
		info := a.Info(s.cfg)
		for i := range info.Instances {
			if _, isCtl := a.(Controller); isCtl {
				info.Instances[i].UsedBy = used[info.Instances[i].ID]
			}
		}
		out = append(out, info)
	}
	return out
}

// Run is the background loop: adapter sync, process metrics, retention.
func (s *Service) Run(ctx context.Context) {
	defer s.process.StopAll()
	sync := time.NewTicker(time.Duration(s.cfg.SyncIntervalSec) * time.Second)
	defer sync.Stop()
	metrics := time.NewTicker(15 * time.Second)
	defer metrics.Stop()
	prune := time.NewTicker(time.Hour)
	defer prune.Stop()
	s.publishStatus()
	s.syncAll(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-sync.C:
			s.syncAll(ctx)
		case <-metrics.C:
			s.process.Sync(ctx)
		case <-prune.C:
			if _, err := s.Prune(ctx); err != nil {
				s.log.Warn("bots retention", "err", err)
			}
		}
	}
}

func (s *Service) syncAll(ctx context.Context) {
	for _, sy := range s.syncers {
		if sy == Syncer(s.process) {
			continue // has its own faster tick
		}
		sctx, cancel := context.WithTimeout(ctx, 2*time.Duration(s.cfg.OpTimeoutSec)*time.Second)
		sy.Sync(sctx)
		cancel()
	}
	s.gcConfirmations()
}

func (s *Service) publishStatus() {
	n := len(s.cfg.Controllers)
	if n == 0 {
		s.mon.SetIntegrationStatus("bots", "Управление ботами", "disabled",
			"Нет управляющих адаптеров в конфигурации Core: доступен только мониторинг")
		return
	}
	s.mon.SetIntegrationStatus("bots", "Управление ботами", "ok", "Объявлено управляющих адаптеров: "+strconv.Itoa(n))
}

func ms(t time.Time) int64 { return t.UTC().UnixMilli() }

func fromMS(v int64) time.Time { return time.UnixMilli(v).UTC() }

func fromNullMS(v sql.NullInt64) *time.Time {
	if !v.Valid {
		return nil
	}
	t := fromMS(v.Int64)
	return &t
}
