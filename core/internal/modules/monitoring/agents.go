package monitoring

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"aerhome/core/internal/foundation/ids"
	"aerhome/core/internal/modules/registry"
)

// Agent credentials (ADR-011): one credential per agent, bound to exactly
// one Registry entity. Token format "aer1.<agentId>.<64 hex>"; Core stores
// only SHA-256 of the secret part. The entity comes from the credential, so
// an agent cannot report for another device. Revocation is immediate.

const tokenPrefix = "aer1."

type agentKey struct{}

// AgentFromContext returns the authenticated agent of an agent route.
func AgentFromContext(ctx context.Context) (Agent, bool) {
	a, ok := ctx.Value(agentKey{}).(Agent)
	return a, ok
}

// CreatedAgent carries the token, shown exactly once.
type CreatedAgent struct {
	Agent Agent  `json:"agent"`
	Token string `json:"token"`
}

// CreateAgent registers a reporting identity for an entity (owner action).
func (s *Service) CreateAgent(ctx context.Context, entityID, name, kind string) (CreatedAgent, error) {
	v := &ValidationError{}
	name = strings.TrimSpace(name)
	if name == "" || len([]rune(name)) > 80 {
		v.add("name", "Название: от 1 до 80 символов")
	}
	if kind == "" {
		kind = "host"
	}
	if kind != "host" && kind != "bot" && kind != "remote" && kind != "power" && kind != "gateway" {
		v.add("kind", "host, bot, remote, power или gateway")
	}
	if err := v.orNil(); err != nil {
		return CreatedAgent{}, err
	}
	e, err := s.reg.Get(ctx, entityID)
	if errors.Is(err, registry.ErrNotFound) {
		return CreatedAgent{}, ErrEntityMissing
	}
	if err != nil {
		return CreatedAgent{}, err
	}
	if e.Archived {
		v.add("entityId", "Объект в архиве Registry")
		return CreatedAgent{}, v
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return CreatedAgent{}, err
	}
	sec := hex.EncodeToString(secret)
	sum := sha256.Sum256([]byte(sec))
	a := Agent{ID: ids.New(), EntityID: entityID, Name: name, Kind: kind, CreatedAt: s.now().UTC().Truncate(time.Millisecond)}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO mon_agents (id, entity_id, name, kind, secret_hash, created_at) VALUES (?,?,?,?,?,?)`,
		a.ID, a.EntityID, a.Name, a.Kind, sum[:], ms(a.CreatedAt)); err != nil {
		return CreatedAgent{}, err
	}
	s.event(ctx, &entityID, "agent_registered", SeverityInfo, "Зарегистрирован агент «"+name+"»", nil)
	return CreatedAgent{Agent: a, Token: tokenPrefix + a.ID + "." + sec}, nil
}

// RevokeAgent disables a credential immediately.
func (s *Service) RevokeAgent(ctx context.Context, id string) (Agent, error) {
	res, err := s.db.ExecContext(ctx, `UPDATE mon_agents SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, ms(s.now()), id)
	if err != nil {
		return Agent{}, err
	}
	a, err := s.getAgent(ctx, id)
	if err != nil {
		return Agent{}, err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		s.event(ctx, &a.EntityID, "agent_revoked", SeverityWarning, "Доступ агента «"+a.Name+"» отозван", nil)
	}
	return a, nil
}

// Authenticate resolves a bearer token to an active agent (constant-time).
func (s *Service) Authenticate(ctx context.Context, token string) (Agent, bool) {
	rest, ok := strings.CutPrefix(token, tokenPrefix)
	if !ok {
		return Agent{}, false
	}
	id, sec, ok := strings.Cut(rest, ".")
	if !ok || !ids.Valid(id) || len(sec) != 64 {
		return Agent{}, false
	}
	var hash []byte
	var revoked sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT secret_hash, revoked_at FROM mon_agents WHERE id = ?`, id).Scan(&hash, &revoked)
	if err != nil {
		// Same work on unknown IDs keeps timing uniform.
		sum := sha256.Sum256([]byte(sec))
		subtle.ConstantTimeCompare(sum[:], make([]byte, 32))
		return Agent{}, false
	}
	sum := sha256.Sum256([]byte(sec))
	if subtle.ConstantTimeCompare(sum[:], hash) != 1 || revoked.Valid {
		return Agent{}, false
	}
	a, err := s.getAgent(ctx, id)
	return a, err == nil
}

// AgentAuthorizer plugs agent tokens into the router (agent routes only).
func (s *Service) AgentAuthorizer(r *http.Request) (*http.Request, bool) {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || tok == "" {
		return r, false
	}
	a, ok := s.Authenticate(r.Context(), tok)
	if !ok {
		return r, false
	}
	return r.WithContext(context.WithValue(r.Context(), agentKey{}, a)), true
}

const agentCols = `id, entity_id, name, kind, created_at, revoked_at, last_seen_at, info, bot`

func (s *Service) scanAgent(row interface{ Scan(...any) error }) (Agent, error) {
	var a Agent
	var created int64
	var revoked, seen sql.NullInt64
	var info, bot sql.NullString
	if err := row.Scan(&a.ID, &a.EntityID, &a.Name, &a.Kind, &created, &revoked, &seen, &info, &bot); err != nil {
		return Agent{}, err
	}
	a.CreatedAt = fromMS(created)
	a.RevokedAt = fromNullMS(revoked)
	a.LastSeenAt = fromNullMS(seen)
	if info.Valid {
		a.Info = &AgentInfo{}
		_ = json.Unmarshal([]byte(info.String), a.Info)
	}
	if bot.Valid {
		a.Bot = &BotStatus{}
		_ = json.Unmarshal([]byte(bot.String), a.Bot)
	}
	a.Active = a.RevokedAt == nil && a.LastSeenAt != nil &&
		s.now().Sub(*a.LastSeenAt) <= time.Duration(s.cfg.HeartbeatTimeoutSec)*time.Second
	return a, nil
}

func (s *Service) getAgent(ctx context.Context, id string) (Agent, error) {
	a, err := s.scanAgent(s.db.QueryRowContext(ctx, `SELECT `+agentCols+` FROM mon_agents WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Agent{}, ErrNotFound
	}
	return a, err
}

// ListAgents returns agents, optionally of one entity.
func (s *Service) ListAgents(ctx context.Context, entityID string) ([]Agent, error) {
	q := `SELECT ` + agentCols + ` FROM mon_agents`
	args := []any{}
	if entityID != "" {
		q += ` WHERE entity_id = ?`
		args = append(args, entityID)
	}
	rows, err := s.db.QueryContext(ctx, q+` ORDER BY created_at`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Agent{}
	for rows.Next() {
		a, err := s.scanAgent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}
