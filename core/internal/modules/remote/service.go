package remote

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

// Errors mapped to API responses.
var (
	ErrNotFound = errors.New("not found")
)

// ValidationError lists field problems (422).
type ValidationError struct{ Fields map[string]string }

func (e *ValidationError) Error() string { return "validation failed" }

// RefusedError is a refused operation with a stable reason code.
type RefusedError struct {
	Status  int
	Code    string // CONFLICT | UNSUPPORTED | UNAVAILABLE | PERMISSION_REQUIRED
	Reason  string // machine reason (not_ready, already_granted, busy, limit, …)
	Message string
}

func (e *RefusedError) Error() string { return e.Message }

// Service is the Remote control plane.
type Service struct {
	db  *sql.DB
	reg registry.Reader
	mon *monitoring.Service
	cfg config.Remote
	log *slog.Logger
	now func() time.Time

	createMu sync.Mutex
	mu       sync.Mutex
	secrets  map[string]*secret     // sessionID → one-time connection secrets
	queues   map[string]*agentQueue // entityID → commands for the host agent
}

type secret struct {
	password   string
	filesToken string
}

type agentQueue struct {
	cmds []Command
	wake chan struct{}
}

// NewService builds the service; now may be nil.
func NewService(db *sql.DB, reg registry.Reader, mon *monitoring.Service, cfg config.Remote, log *slog.Logger, now func() time.Time) *Service {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	return &Service{db: db, reg: reg, mon: mon, cfg: cfg, log: log, now: now,
		secrets: map[string]*secret{}, queues: map[string]*agentQueue{}}
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

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// CertFingerprint returns the SHA-256 of the first certificate in PEM.
func CertFingerprint(pemText string) (string, error) {
	b, _ := pem.Decode([]byte(pemText))
	if b == nil || b.Type != "CERTIFICATE" {
		return "", errors.New("not a PEM certificate")
	}
	if _, err := x509.ParseCertificate(b.Bytes); err != nil {
		return "", err
	}
	sum := sha256.Sum256(b.Bytes)
	parts := make([]string, len(sum))
	for i, c := range sum {
		parts[i] = hex.EncodeToString([]byte{c})
	}
	return strings.Join(parts, ":"), nil
}

// ---- hosts ----

var remoteCaps = []string{"remote.desktop", "remote.application", "remote.terminal", "files.transfer"}

type hostRow struct {
	agentID   string
	info      HostInfo
	certFP    string
	lastHello time.Time
}

func (s *Service) hostRow(ctx context.Context, entityID string) (*hostRow, error) {
	var r hostRow
	var info string
	var last int64
	err := s.db.QueryRowContext(ctx, `SELECT agent_id, info, cert_fp, last_hello FROM remote_hosts WHERE entity_id = ?`, entityID).
		Scan(&r.agentID, &info, &r.certFP, &last)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	_ = json.Unmarshal([]byte(info), &r.info)
	r.lastHello = fromMS(last)
	return &r, nil
}

// Policy returns the owner's policy for a host (defaults when unset).
func (s *Service) Policy(ctx context.Context, entityID string) (Policy, error) {
	p := DefaultPolicy()
	var en, d, c, f int
	err := s.db.QueryRowContext(ctx, `SELECT enabled, desktop, clipboard, files, max_minutes, revision FROM remote_policies WHERE entity_id = ?`, entityID).
		Scan(&en, &d, &c, &f, &p.MaxMinutes, &p.Revision)
	if errors.Is(err, sql.ErrNoRows) {
		return p, nil
	}
	p.Enabled, p.Desktop, p.Clipboard, p.Files = en == 1, d == 1, c == 1, f == 1
	return p, err
}

// SetPolicy stores the owner's policy (optimistic revision when given).
func (s *Service) SetPolicy(ctx context.Context, entityID string, p Policy) (Host, error) {
	if _, err := s.reg.Get(ctx, entityID); err != nil {
		if errors.Is(err, registry.ErrNotFound) {
			return Host{}, ErrNotFound
		}
		return Host{}, err
	}
	if p.MaxMinutes < 5 || p.MaxMinutes > s.cfg.MaxMinutes {
		return Host{}, &ValidationError{Fields: map[string]string{"maxMinutes": "От 5 минут до максимума Core"}}
	}
	cur, err := s.Policy(ctx, entityID)
	if err != nil {
		return Host{}, err
	}
	if p.Revision != 0 && cur.Revision != 0 && p.Revision != cur.Revision {
		return Host{}, &RefusedError{Status: 409, Code: "CONFLICT", Reason: "revision_mismatch", Message: "Политика изменена в другом окне"}
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO remote_policies (entity_id, enabled, desktop, clipboard, files, max_minutes, revision, updated_at)
		VALUES (?,?,?,?,?,?,1,?) ON CONFLICT (entity_id) DO UPDATE SET enabled = excluded.enabled, desktop = excluded.desktop,
		clipboard = excluded.clipboard, files = excluded.files, max_minutes = excluded.max_minutes,
		revision = remote_policies.revision + 1, updated_at = excluded.updated_at`,
		entityID, boolInt(p.Enabled), boolInt(p.Desktop), boolInt(p.Clipboard), boolInt(p.Files), p.MaxMinutes, ms(s.now())); err != nil {
		return Host{}, err
	}
	s.mon.RecordEvent(ctx, entityID, "remote_policy", monitoring.SeverityInfo, "Изменена политика удалённого доступа")
	if !p.Enabled {
		s.revokeHostSessions(ctx, entityID, "Удалённый доступ выключен владельцем")
	}
	return s.Host(ctx, entityID)
}

// Hosts lists entities that declare remote capabilities or have an agent.
func (s *Service) Hosts(ctx context.Context) ([]Host, error) {
	seen := map[string]bool{}
	var ids []string
	for offset := 0; ; offset += 200 {
		p, err := s.reg.List(ctx, registry.ListFilter{Capability: "remote.desktop", Limit: 200, Offset: offset})
		if err != nil {
			return nil, err
		}
		for _, e := range p.Items {
			if !seen[e.ID] {
				seen[e.ID] = true
				ids = append(ids, e.ID)
			}
		}
		if len(p.Items) < 200 {
			break
		}
	}
	rows, err := s.db.QueryContext(ctx, `SELECT entity_id FROM remote_hosts ORDER BY entity_id`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil && !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	rows.Close()
	out := []Host{}
	for _, id := range ids {
		h, err := s.Host(ctx, id)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if h.Archived {
			continue
		}
		out = append(out, h)
	}
	return out, nil
}

// Host builds the view of one host and decides whether it can connect now.
func (s *Service) Host(ctx context.Context, entityID string) (Host, error) {
	e, err := s.reg.Get(ctx, entityID)
	if errors.Is(err, registry.ErrNotFound) {
		return Host{}, ErrNotFound
	}
	if err != nil {
		return Host{}, err
	}
	h := Host{EntityID: e.ID, Name: e.Name, Type: e.Type, Archived: e.Archived, Declared: []string{}, Status: string(monitoring.StatusUnknown)}
	for _, c := range e.Capabilities {
		if slices.Contains(remoteCaps, c) {
			h.Declared = append(h.Declared, c)
		}
	}
	if h.Policy, err = s.Policy(ctx, entityID); err != nil {
		return h, err
	}
	row, err := s.hostRow(ctx, entityID)
	if err != nil {
		return h, err
	}
	if row != nil {
		info := row.info
		h.Agent, h.CertSHA256 = &info, row.certFP
		t := row.lastHello
		h.LastHelloAt = &t
		h.AgentActive = s.now().Sub(row.lastHello) <= time.Duration(s.cfg.AgentTimeoutSec)*time.Second && s.agentLive(ctx, entityID, row.agentID)
		h.Effective = info.Caps.and(Caps{Desktop: h.Policy.Desktop, Input: true, Clipboard: h.Policy.Clipboard, Files: h.Policy.Files})
		if !h.Policy.Enabled {
			h.Effective = Caps{}
		}
	}
	if st, err := s.mon.State(ctx, entityID); err == nil {
		h.Status, h.StatusReason, h.LastContactAt = string(st.Status), st.Reason, st.LastContactAt
	}
	if a, err := s.sessions(ctx, `entity_id = ? AND state NOT IN ('disconnected','failed','expired','revoked')`, 1, entityID); err == nil && len(a) > 0 {
		h.ActiveSession = &a[0]
	}
	if l, err := s.sessions(ctx, `entity_id = ?`, 1, entityID); err == nil && len(l) > 0 {
		h.LastSession = &l[0]
	}
	h.CanConnect, h.Reason = s.readiness(h)
	return h, nil
}

// agentLive: the hello came from a credential that is not revoked.
func (s *Service) agentLive(ctx context.Context, entityID, agentID string) bool {
	agents, err := s.mon.ListAgents(ctx, entityID)
	if err != nil {
		return false
	}
	for _, a := range agents {
		if a.ID == agentID {
			return a.RevokedAt == nil
		}
	}
	return false
}

// readiness checks the real state before offering «Подключиться». A Registry
// capability is a claim, not a guarantee.
func (s *Service) readiness(h Host) (bool, string) {
	switch {
	case h.Archived:
		return false, "Объект в архиве Registry"
	case !slices.Contains(h.Declared, "remote.desktop"):
		return false, "В Registry у объекта нет возможности «Удалённый рабочий стол»"
	case h.Agent == nil:
		return false, "На компьютере не установлен агент удалённого доступа (aer-remote-host)"
	case !h.AgentActive:
		return false, "Агент удалённого доступа не на связи — компьютер выключен или агент не запущен"
	case !h.Agent.Ready:
		return false, "Хост не готов: " + h.Agent.Reason
	case h.Status == string(monitoring.StatusOffline):
		return false, "Компьютер недоступен по данным мониторинга"
	case !h.Policy.Enabled:
		return false, "Удалённый доступ к этому компьютеру выключен владельцем"
	case !h.Effective.Desktop:
		return false, "Рабочий стол не разрешён политикой или не поддерживается хостом"
	case h.ActiveSession != nil:
		return false, "Уже идёт удалённый сеанс — к компьютеру подключён один клиент за раз"
	}
	return true, ""
}

// Apps answers the mobile Remote Apps question without pretending.
func (s *Service) Apps(ctx context.Context, entityID string) (AppsInfo, error) {
	h, err := s.Host(ctx, entityID)
	if err != nil {
		return AppsInfo{}, err
	}
	info := AppsInfo{Status: "unsupported", Apps: []AppRef{}}
	switch {
	case h.Agent == nil:
		info.Reason = "Агент удалённого доступа не установлен"
	case !h.Agent.Caps.Apps:
		info.Reason = "Транспорт RDP этого хоста передаёт весь рабочий стол: изоляции отдельного приложения нет " +
			"(GNOME Wayland — нет RemoteApp и ограничения ввода окном; Windows — RemoteApp только в серверных редакциях). " +
			"Используйте полный рабочий стол с компьютера"
	default:
		info.Status, info.Reason = "available", ""
	}
	return info, nil
}
