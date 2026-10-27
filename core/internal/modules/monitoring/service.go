package monitoring

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"sync"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/foundation/logging"
	"aerhome/core/internal/modules/registry"
)

// Errors mapped to API responses.
var (
	ErrNotFound      = errors.New("not found")
	ErrEntityMissing = errors.New("registry entity not found")
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

// Service is the Monitoring core: storage, state evaluation, incidents.
type Service struct {
	db  *sql.DB
	reg registry.Reader
	cfg config.Monitoring
	log *slog.Logger
	now func() time.Time

	notifier *Notifier
	sink     *logging.Sink
	docker   *DockerWatcher

	stateMu sync.Mutex // state transitions
	incMu   sync.Mutex // incident open/resolve
	mu      sync.Mutex // maps below
	// Debounce counters for threshold rules: key → consecutive breaches.
	breaches map[string]int
	// Per-source log intake windows for rate limiting.
	logWindows map[string]*rateWindow
	// Integration status (docker, telegram, core) for the overview.
	integrations map[string]IntegrationStatus
}

// NewService builds the service; now may be nil (time.Now).
func NewService(db *sql.DB, reg registry.Reader, cfg config.Monitoring, log *slog.Logger, now func() time.Time) *Service {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	s := &Service{
		db: db, reg: reg, cfg: cfg, log: log, now: now,
		breaches:     map[string]int{},
		logWindows:   map[string]*rateWindow{},
		integrations: map[string]IntegrationStatus{},
	}
	s.notifier = newNotifier(s)
	s.docker = newDockerWatcher(s)
	return s
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

func nullStr(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}

func strPtr(s string) *string { return &s }

func (s *Service) setIntegration(st IntegrationStatus) {
	t := s.now().UTC()
	st.CheckedAt = &t
	s.mu.Lock()
	s.integrations[st.ID] = st
	s.mu.Unlock()
}

func (s *Service) integrationList() []IntegrationStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []IntegrationStatus{}
	for _, id := range []string{"checks", "docker", "telegram"} {
		if st, ok := s.integrations[id]; ok {
			out = append(out, st)
		}
	}
	return out
}

// Run is the background loop: availability checks, Docker polling,
// retention and notification dispatch. It continues while Core runs,
// independently of any client being connected.
func (s *Service) Run(ctx context.Context) {
	check := time.NewTicker(time.Duration(s.cfg.CheckIntervalSec) * time.Second)
	defer check.Stop()
	retention := time.NewTicker(time.Duration(s.cfg.RetentionIntervalMin) * time.Minute)
	defer retention.Stop()
	dispatch := time.NewTicker(30 * time.Second)
	defer dispatch.Stop()
	var sinkC <-chan logging.Record
	if s.sink != nil {
		sinkC = s.sink.Records()
	}
	var dockerC <-chan time.Time
	if s.cfg.Docker.Enabled {
		t := time.NewTicker(time.Duration(s.cfg.Docker.IntervalSec) * time.Second)
		defer t.Stop()
		dockerC = t.C
	} else {
		s.setIntegration(IntegrationStatus{ID: "docker", Label: "Docker", Status: "disabled", Reason: "Выключено в конфигурации"})
	}
	s.notifier.describe()

	s.logSystem(ctx, LevelInfo, "Мониторинг запущен", nil)
	s.CheckAll(ctx)
	if s.cfg.Docker.Enabled {
		s.docker.Poll(ctx)
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-check.C:
			s.CheckAll(ctx)
		case <-dockerC:
			s.docker.Poll(ctx)
		case <-retention.C:
			if _, err := s.Prune(ctx); err != nil {
				s.log.Warn("retention failed", "err", err)
			}
		case <-dispatch.C:
			s.notifier.Dispatch(ctx)
		case rec := <-sinkC:
			// Errors while storing Core logs must not be forwarded again.
			qctx := logging.Quiet(ctx)
			lvl := LevelWarning
			if rec.Level >= slog.LevelError {
				lvl = LevelError
			}
			if err := s.IngestSystemLog(qctx, rec.At, lvl, rec.Source, rec.Message, rec.Fields); err != nil {
				s.log.WarnContext(qctx, "store core log", "err", err)
			}
		}
	}
}

// logSystem writes a Core-originated log line.
func (s *Service) logSystem(ctx context.Context, lvl LogLevel, msg string, entityID *string) {
	_, _ = s.db.ExecContext(ctx, `INSERT INTO mon_logs (ts, entity_id, source, level, message) VALUES (?,?,?,?,?)`,
		ms(s.now()), nullStr(entityID), "core.monitoring", levelNum[lvl], cleanMessage(msg))
}
