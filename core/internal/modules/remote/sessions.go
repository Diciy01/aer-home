package remote

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"

	"aerhome/core/internal/foundation/ids"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/remoteengine"
)

const sessionCols = `id, entity_id, kind, source_name, source_entity, client_id, transport, state, reason, allowed,
	created_at, approved_at, ready_at, granted_at, connected_at, ended_at, expires_at, route`

func scanSession(row interface{ Scan(...any) error }) (Session, error) {
	var x Session
	var st, allowed string
	var created, expires int64
	var appr, ready, granted, conn, ended sql.NullInt64
	if err := row.Scan(&x.ID, &x.EntityID, &x.Kind, &x.SourceName, &x.SourceEntity, &x.ClientID, &x.Transport, &st, &x.Reason, &allowed,
		&created, &appr, &ready, &granted, &conn, &ended, &expires, &x.Route); err != nil {
		return x, err
	}
	x.State = State(st)
	_ = json.Unmarshal([]byte(allowed), &x.Allowed)
	x.CreatedAt, x.ExpiresAt = fromMS(created), fromMS(expires)
	x.ApprovedAt, x.ReadyAt, x.GrantedAt, x.ConnectedAt, x.EndedAt = fromNullMS(appr), fromNullMS(ready), fromNullMS(granted), fromNullMS(conn), fromNullMS(ended)
	return x, nil
}

// sessions runs a fixed WHERE from this package (newest first).
func (s *Service) sessions(ctx context.Context, where string, limit int, args ...any) ([]Session, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+sessionCols+` FROM remote_sessions WHERE `+where+
		` ORDER BY created_at DESC, id DESC LIMIT ?`, append(args, limit)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Session{}
	for rows.Next() {
		x, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, x)
	}
	return out, rows.Err()
}

// Sessions lists the history (optionally of one host).
func (s *Service) Sessions(ctx context.Context, entityID string, limit int) ([]Session, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	var out []Session
	var err error
	if entityID != "" {
		out, err = s.sessions(ctx, `entity_id = ?`, limit, entityID)
	} else {
		out, err = s.sessions(ctx, `1=1`, limit)
	}
	for i := range out {
		out[i].HostName = s.name(ctx, out[i].EntityID)
	}
	return out, err
}

func (s *Service) name(ctx context.Context, id string) string {
	if e, err := s.reg.Get(ctx, id); err == nil {
		return e.Name
	}
	return ""
}

// Session returns one session with its audit trail.
func (s *Service) Session(ctx context.Context, id string) (Session, error) {
	x, err := scanSession(s.db.QueryRowContext(ctx, `SELECT `+sessionCols+` FROM remote_sessions WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return x, ErrNotFound
	}
	if err != nil {
		return x, err
	}
	x.HostName = s.name(ctx, x.EntityID)
	rows, err := s.db.QueryContext(ctx, `SELECT ts, kind, message FROM remote_events WHERE session_id = ? ORDER BY id`, id)
	if err != nil {
		return x, err
	}
	defer rows.Close()
	x.Events = []Event{}
	for rows.Next() {
		var ev Event
		var ts int64
		if err := rows.Scan(&ts, &ev.Kind, &ev.Message); err != nil {
			return x, err
		}
		ev.At = fromMS(ts)
		x.Events = append(x.Events, ev)
	}
	return x, rows.Err()
}

func (s *Service) audit(ctx context.Context, id, kind, msg string) {
	_, _ = s.db.ExecContext(ctx, `INSERT INTO remote_events (session_id, ts, kind, message) VALUES (?,?,?,?)`, id, ms(s.now()), kind, msg)
}

// NewSession is a client's request.
type NewSession struct {
	EntityID     string `json:"entityId"`
	Kind         string `json:"kind"` // desktop | app
	SourceName   string `json:"sourceName"`
	SourceEntity string `json:"sourceEntityId"`
	ClientID     string `json:"clientId"`
	Minutes      int    `json:"minutes"`
	Clipboard    *bool  `json:"clipboard"`
	Files        *bool  `json:"files"`
	// auth: the sealed device password (ConnectDevice only, never JSON).
	auth *remoteengine.ConnectAuth
}

// Create starts a session: checks real readiness, policy and limits, then
// asks the host agent to open it. One Idempotency-Key = one session.
func (s *Service) Create(ctx context.Context, in NewSession, key string) (Session, error) {
	return s.create(ctx, in, key, remoteengine.RouteDirect, Caps{Desktop: true, Input: true, Clipboard: true, Files: true, Apps: true}, nil)
}

// create is Create for a route; mask narrows the host's effective rights
// (a remote client's own permissions on the relay route). created runs
// before the host agent learns about the session (ConnectDevice waits).
func (s *Service) create(ctx context.Context, in NewSession, key, route string, mask Caps, created func(id string)) (Session, error) {
	if key != "" {
		var id, entity string
		err := s.db.QueryRowContext(ctx, `SELECT id, entity_id FROM remote_sessions WHERE idempotency_key = ?`, key).Scan(&id, &entity)
		if err == nil {
			if entity != in.EntityID {
				return Session{}, &RefusedError{Status: 409, Code: "CONFLICT", Reason: "key_reused", Message: "Idempotency-Key уже использован для другого компьютера"}
			}
			return s.Session(ctx, id)
		}
	}
	v := map[string]string{}
	if in.Kind == "" {
		in.Kind = "desktop"
	}
	if len([]rune(in.SourceName)) > 120 || len(in.ClientID) > 80 {
		v["sourceName"] = "Имя источника до 120 символов, clientId до 80"
	}
	if in.Minutes < 0 {
		v["minutes"] = "Положительное число минут"
	}
	if len(v) > 0 {
		return Session{}, &ValidationError{Fields: v}
	}
	if in.Kind == "app" {
		return Session{}, &RefusedError{Status: 422, Code: "UNSUPPORTED", Reason: "apps_unsupported",
			Message: "Сеанс отдельного приложения не поддерживается транспортом этого хоста (см. /remote/hosts/{id}/apps)"}
	}
	if in.Kind != "desktop" {
		return Session{}, &ValidationError{Fields: map[string]string{"kind": "desktop или app"}}
	}
	s.createMu.Lock()
	defer s.createMu.Unlock() // one create at a time: «one session per host» and limits stay exact
	h, err := s.Host(ctx, in.EntityID)
	if err != nil {
		return Session{}, err
	}
	if h.Agent != nil && h.Agent.Backend == "windows-shadow" && route != remoteengine.RouteRelay {
		return Session{}, &RefusedError{Status: 422, Code: "UNSUPPORTED", Reason: "relay_required", Message: "AER Windows Host доступен через собственный Gateway"}
	}
	if _, isDevice := s.deviceByEntity(ctx, in.EntityID); isDevice != (in.auth != nil) {
		// A device accepts sessions only with its own password, and a password
		// attempt is meaningful only for a device.
		return Session{}, &RefusedError{Status: 403, Code: "PERMISSION_REQUIRED", Reason: "device_password",
			Message: "К компьютеру AER Connect подключаются по его ID и паролю"}
	}
	if in.auth != nil && (h.Agent == nil || !slices.Contains(h.Agent.Features, remoteengine.FeatureConnectAuth)) {
		return Session{}, &RefusedError{Status: 503, Code: "UNAVAILABLE", Reason: "offline", Message: "На компьютере устаревший AER Connect — обновите его"}
	}
	if !h.CanConnect {
		code, reason := "UNAVAILABLE", "not_ready"
		if h.ActiveSession != nil {
			code, reason = "CONFLICT", "busy"
		}
		return Session{}, &RefusedError{Status: map[string]int{"UNAVAILABLE": 503, "CONFLICT": 409}[code], Code: code, Reason: reason, Message: h.Reason}
	}
	var active int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM remote_sessions WHERE state NOT IN ('disconnected','failed','expired','revoked')`).Scan(&active); err != nil {
		return Session{}, err
	}
	if active >= s.cfg.MaxActiveSessions {
		return Session{}, &RefusedError{Status: 409, Code: "CONFLICT", Reason: "limit", Message: fmt.Sprintf("Достигнут предел одновременных сеансов (%d)", s.cfg.MaxActiveSessions)}
	}
	allowed := h.Effective.And(mask)
	if in.Clipboard != nil && !*in.Clipboard {
		allowed.Clipboard = false
	}
	if in.Files != nil && !*in.Files {
		allowed.Files = false
	}
	minutes := s.cfg.DefaultMinutes
	if in.Minutes > 0 {
		minutes = in.Minutes
	}
	minutes = min(minutes, h.Policy.MaxMinutes, s.cfg.MaxMinutes)
	now := s.now().UTC().Truncate(time.Millisecond)
	x := Session{ID: ids.New(), EntityID: in.EntityID, HostName: h.Name, Kind: in.Kind, SourceName: strings.TrimSpace(in.SourceName),
		SourceEntity: in.SourceEntity, ClientID: in.ClientID, Transport: h.Agent.Transport, Route: route, State: StatePending, Allowed: allowed,
		CreatedAt: now, ExpiresAt: now.Add(time.Duration(minutes) * time.Minute)}
	al, _ := json.Marshal(allowed)
	var idem any
	if key != "" {
		idem = key
	}
	authState := ""
	if in.auth != nil {
		authState = "required"
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO remote_sessions (id, entity_id, kind, source_name, source_entity, client_id, transport, state,
		allowed, idempotency_key, created_at, expires_at, route, auth_state) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		x.ID, x.EntityID, x.Kind, x.SourceName, x.SourceEntity, x.ClientID, x.Transport, string(x.State), string(al), idem, ms(now), ms(x.ExpiresAt), route, authState); err != nil {
		return Session{}, err
	}
	if created != nil {
		created(x.ID)
	}
	s.audit(ctx, x.ID, "created", fmt.Sprintf("Запрошен сеанс рабочего стола с «%s» на %d мин", or(x.SourceName, "неизвестного клиента"), minutes))
	s.mon.RecordEvent(ctx, x.EntityID, "remote_session", monitoring.SeverityInfo, "Запрошен удалённый сеанс с «"+or(x.SourceName, "клиента")+"»")
	s.enqueue(x.EntityID, Command{ID: ids.New(), Type: "open", SessionID: x.ID, ExpiresAt: x.ExpiresAt, Allowed: allowed, Relay: route == remoteengine.RouteRelay, Auth: in.auth})
	return s.Session(ctx, x.ID)
}

func or(a, b string) string {
	if strings.TrimSpace(a) == "" {
		return b
	}
	return a
}

// transition moves a non-terminal session to a new state (no-op otherwise).
func (s *Service) transition(ctx context.Context, id string, to State, reason, kind, msg string, extra ...string) (Session, bool, error) {
	x, err := s.Session(ctx, id)
	if err != nil {
		return x, false, err
	}
	if x.State.Terminal() {
		return x, false, nil
	}
	now := ms(s.now())
	set := []string{"state = ?", "reason = ?"}
	args := []any{string(to), reason}
	for _, col := range extra {
		set = append(set, col+" = COALESCE("+col+", ?)")
		args = append(args, now)
	}
	if to.Terminal() {
		set = append(set, "ended_at = ?")
		args = append(args, now)
	}
	if to == StateReconnecting {
		set = append(set, "lost_at = ?")
		args = append(args, now)
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE remote_sessions SET `+strings.Join(set, ", ")+` WHERE id = ?`, append(args, id)...); err != nil {
		return x, false, err
	}
	s.audit(ctx, id, kind, msg)
	if to.Terminal() {
		s.mu.Lock()
		delete(s.secrets, id)
		s.dropTicketsLocked(id)
		s.mu.Unlock()
		sev := monitoring.SeverityInfo
		if to == StateFailed {
			sev = monitoring.SeverityWarning
		}
		s.mon.RecordEvent(ctx, x.EntityID, "remote_session", sev, "Удалённый сеанс завершён ("+string(to)+"): "+msg)
	}
	x, err = s.Session(ctx, id)
	return x, true, err
}

// End is the client's or owner's normal end of a session.
func (s *Service) End(ctx context.Context, id string) (Session, error) {
	return s.stop(ctx, id, StateDisconnected, "Сеанс завершён пользователем")
}

// Revoke ends a session immediately as a security action.
func (s *Service) Revoke(ctx context.Context, id string) (Session, error) {
	return s.stop(ctx, id, StateRevoked, "Доступ отозван владельцем")
}

func (s *Service) stop(ctx context.Context, id string, to State, msg string) (Session, error) {
	x, changed, err := s.transition(ctx, id, to, msg, string(to), msg)
	if err != nil {
		return x, err
	}
	if changed {
		s.enqueue(x.EntityID, Command{ID: ids.New(), Type: "close", SessionID: id, Reason: msg})
	}
	return x, nil
}

func (s *Service) revokeHostSessions(ctx context.Context, entityID, msg string) {
	act, _ := s.sessions(ctx, `entity_id = ? AND state NOT IN ('disconnected','failed','expired','revoked')`, 50, entityID)
	for _, x := range act {
		_, _ = s.stop(ctx, x.ID, StateRevoked, msg)
	}
}

// RevokeHost ends every active session of a host.
func (s *Service) RevokeHost(ctx context.Context, entityID string) (Host, error) {
	s.revokeHostSessions(ctx, entityID, "Все сеансы хоста отозваны владельцем")
	return s.Host(ctx, entityID)
}

// Grant hands the connection data to the client exactly once.
func (s *Service) Grant(ctx context.Context, id string) (Grant, error) {
	x, err := s.Session(ctx, id)
	if err != nil {
		return Grant{}, err
	}
	if x.Route == remoteengine.RouteRelay {
		return Grant{}, &RefusedError{Status: 409, Code: "CONFLICT", Reason: "relay",
			Message: "Сеанс через Gateway: данные подключения выдаются только его клиенту"}
	}
	return s.grant(ctx, x)
}

func (s *Service) grant(ctx context.Context, x Session) (Grant, error) {
	id := x.ID
	switch {
	case x.State.Terminal():
		return Grant{}, &RefusedError{Status: 410, Code: "CONFLICT", Reason: "ended", Message: "Сеанс уже завершён"}
	case x.GrantedAt != nil:
		return Grant{}, &RefusedError{Status: 410, Code: "CONFLICT", Reason: "already_granted", Message: "Данные подключения уже выданы — они одноразовые"}
	case x.State != StateConnecting:
		return Grant{}, &RefusedError{Status: 409, Code: "CONFLICT", Reason: "not_ready", Message: "Хост ещё не готов (" + string(x.State) + ")"}
	}
	s.mu.Lock()
	sec := s.secrets[id]
	delete(s.secrets, id)
	s.mu.Unlock()
	if sec == nil {
		return Grant{}, &RefusedError{Status: 410, Code: "CONFLICT", Reason: "lost", Message: "Данные подключения недоступны (Core перезапускался) — начните новый сеанс"}
	}
	row, err := s.hostRow(ctx, x.EntityID)
	if err != nil || row == nil {
		return Grant{}, errors.Join(err, ErrNotFound)
	}
	res, err := s.db.ExecContext(ctx, `UPDATE remote_sessions SET granted_at = ? WHERE id = ? AND granted_at IS NULL`, ms(s.now()), id)
	if err != nil {
		return Grant{}, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return Grant{}, &RefusedError{Status: 410, Code: "CONFLICT", Reason: "already_granted", Message: "Данные подключения уже выданы"}
	}
	s.audit(ctx, id, "granted", "Данные подключения выданы клиенту (один раз)")
	g := Grant{SessionID: id, Transport: x.Transport, Route: remoteengine.RouteDirect, Host: row.info.Address, Port: row.info.Port, Username: row.info.Username,
		Password: sec.password, CertPEM: row.info.CertPEM, CertSHA256: row.certFP, Clipboard: x.Allowed.Clipboard, ExpiresAt: x.ExpiresAt,
		ExternalClient: "rdp"}
	if x.Allowed.Files && sec.filesToken != "" && row.info.FilesPort > 0 {
		g.Files = &FilesInfo{URL: fmt.Sprintf("https://%s:%d", row.info.Address, row.info.FilesPort), Token: sec.filesToken, MaxBytes: 2 << 30}
	}
	if x.Route == remoteengine.RouteRelay { // the client never learns LAN addresses
		g.Route, g.Host, g.Port = remoteengine.RouteRelay, "", 0
		g.Tunnel = &remoteengine.TunnelInfo{Path: TunnelPath, Tickets: map[string]string{
			remoteengine.ChannelRDP: s.issueTicket(x, remoteengine.ChannelRDP)}, TTLSec: s.cfg.GrantTTLSec}
		if g.Files != nil {
			g.Files.URL = ""
			g.Tunnel.Tickets[remoteengine.ChannelFiles] = s.issueTicket(x, remoteengine.ChannelFiles)
		}
	}
	return g, nil
}

// ---- agent side ----

// Hello records the host agent's facts; the answer lists the sessions Core
// still considers active, so an agent closes anything else it holds.
func (s *Service) Hello(ctx context.Context, a monitoring.Agent, info HostInfo) (map[string]any, error) {
	v := map[string]string{}
	if info.Backend != "gnome-rdp" && info.Backend != "windows-rdp" && info.Backend != "windows-shadow" {
		v["backend"] = "gnome-rdp, windows-rdp или windows-shadow"
	}
	if info.Port < 1 || info.Port > 65535 || strings.TrimSpace(info.Address) == "" || len(info.Address) > 253 {
		v["address"] = "Адрес и порт RDP, по которым клиент подключается"
	}
	if info.Approval != "auto" && info.Approval != "prompt" {
		v["approval"] = "auto или prompt"
	}
	if info.Backend == "windows-shadow" && (info.Approval != "prompt" || info.Address != "127.0.0.1") {
		v["backend"] = "windows-shadow: только loopback и локальное подтверждение каждого сеанса"
	}
	fp := ""
	if info.CertPEM != "" {
		var err error
		if fp, err = CertFingerprint(info.CertPEM); err != nil {
			v["certPem"] = "Сертификат TLS в PEM"
		}
	} else if info.Backend == "gnome-rdp" || info.Backend == "windows-shadow" {
		v["certPem"] = "Хост GNOME обязан сообщить сертификат для закрепления"
	}
	if len(info.Reason) > 300 || len(info.Username) > 64 || len(info.CertPEM) > 16<<10 || len(info.Features) > 16 || len(info.Instance) > 128 {
		v["reason"] = "Слишком длинные поля"
	}
	for _, f := range info.Features {
		if len(f) > 40 {
			v["features"] = "Названия возможностей до 40 символов"
		}
	}
	if len(v) > 0 {
		return nil, &ValidationError{Fields: v}
	}
	info.Transport = "rdp"
	b, _ := json.Marshal(info)
	prev, _ := s.hostRow(ctx, a.EntityID)
	if _, err := s.db.ExecContext(ctx, `INSERT INTO remote_hosts (entity_id, agent_id, info, cert_fp, last_hello) VALUES (?,?,?,?,?)
		ON CONFLICT (entity_id) DO UPDATE SET agent_id = excluded.agent_id, info = excluded.info, cert_fp = excluded.cert_fp, last_hello = excluded.last_hello`,
		a.EntityID, a.ID, string(b), fp, ms(s.now())); err != nil {
		return nil, err
	}
	s.noteHello(ctx, a, info)
	if prev != nil && prev.certFP != "" && prev.certFP != fp {
		s.mon.RecordEvent(ctx, a.EntityID, "remote_cert_changed", monitoring.SeverityWarning,
			"Сертификат удалённого доступа хоста изменился: новые подключения закрепят новый отпечаток")
	}
	act, err := s.sessions(ctx, `entity_id = ? AND state NOT IN ('disconnected','failed','expired','revoked')`, 50, a.EntityID)
	if err != nil {
		return nil, err
	}
	active := []string{}
	for _, x := range act {
		active = append(active, x.ID)
	}
	return map[string]any{"serverTime": s.now().UTC(), "activeSessions": active, "pollSec": 25}, nil
}

func (s *Service) enqueue(entityID string, c Command) {
	s.mu.Lock()
	q := s.queues[entityID]
	if q == nil {
		q = &agentQueue{wake: make(chan struct{}, 1)}
		s.queues[entityID] = q
	}
	q.cmds = append(q.cmds, c)
	select {
	case q.wake <- struct{}{}:
	default:
	}
	s.mu.Unlock()
}

// Commands long-polls the host agent's queue (at most wait).
func (s *Service) Commands(ctx context.Context, a monitoring.Agent, wait time.Duration) []Command {
	deadline := time.NewTimer(wait)
	defer deadline.Stop()
	for {
		s.mu.Lock()
		q := s.queues[a.EntityID]
		if q == nil {
			q = &agentQueue{wake: make(chan struct{}, 1)}
			s.queues[a.EntityID] = q
		}
		if len(q.cmds) > 0 {
			out := q.cmds
			q.cmds = nil
			s.mu.Unlock()
			return out
		}
		wake := q.wake
		s.mu.Unlock()
		select {
		case <-wake:
		case <-deadline.C:
			return []Command{}
		case <-ctx.Done():
			return []Command{}
		}
	}
}

// OnAgentEvent applies a host agent's report to a session of its own host.
func (s *Service) OnAgentEvent(ctx context.Context, a monitoring.Agent, id string, ev AgentEvent) (Session, error) {
	x, err := s.Session(ctx, id)
	if err != nil {
		return x, err
	}
	if x.EntityID != a.EntityID {
		return x, &RefusedError{Status: http.StatusForbidden, Code: "FORBIDDEN", Reason: "foreign", Message: "Сеанс другого хоста"}
	}
	msg := monitoring.Redact(strings.TrimSpace(ev.Message))
	if len(msg) > 300 {
		msg = msg[:300]
	}
	switch ev.Event {
	case remoteengine.EventAuthOK, remoteengine.EventAuthFailed:
		return s.authEvent(ctx, x, ev)
	case "awaiting_approval", "approved", "ready":
		if s.authPending(ctx, id) {
			return x, &RefusedError{Status: 409, Code: "CONFLICT", Reason: "auth_required", Message: "Сначала компьютер должен проверить пароль"}
		}
	}
	switch ev.Event {
	case "awaiting_approval":
		if x.State == StatePending {
			x, _, err = s.transition(ctx, id, StateAwaitingApproval, "Ждём подтверждения на компьютере", "awaiting_approval", "Хост запросил подтверждение у пользователя")
		}
	case "approved":
		_, _, err = s.transition(ctx, id, x.State, x.Reason, "approved", or(msg, "Сеанс разрешён на хосте"), "approved_at")
		x, _ = s.Session(ctx, id)
	case "denied":
		x, _, err = s.transition(ctx, id, StateFailed, "Отклонено на компьютере", "denied", or(msg, "Пользователь хоста отклонил подключение"))
	case "ready":
		if x.State != StatePending && x.State != StateAwaitingApproval {
			return x, nil
		}
		if ev.Password == "" && x.Transport == "rdp" {
			if row, _ := s.hostRow(ctx, a.EntityID); row != nil && (row.info.Backend == "gnome-rdp" || row.info.Backend == "windows-shadow") {
				return x, &ValidationError{Fields: map[string]string{"password": "Нужен пароль сеанса"}}
			}
		}
		s.mu.Lock()
		s.secrets[id] = &secret{password: ev.Password, filesToken: ev.FilesToken}
		s.mu.Unlock()
		x, _, err = s.transition(ctx, id, StateConnecting, "Хост готов, ждём подключения клиента", "ready", "RDP включён на время сеанса", "approved_at", "ready_at")
	case "connected":
		if x.State == StateConnecting || x.State == StateReconnecting {
			x, _, err = s.transition(ctx, id, StateConnected, "", "connected", or(msg, "Клиент подключился"), "connected_at")
		}
	case "disconnected":
		if x.State == StateConnected {
			x, _, err = s.transition(ctx, id, StateReconnecting, "Соединение прервано, ждём переподключения", "connection_lost", or(msg, "Соединение RDP прервано"))
		}
	case "closed":
		x, _, err = s.transition(ctx, id, StateDisconnected, or(msg, "Сеанс закрыт хостом"), "closed", or(msg, "Хост закрыл сеанс"))
	case "failed":
		x, _, err = s.transition(ctx, id, StateFailed, or(msg, "Ошибка на хосте"), "failed", or(msg, "Ошибка на хосте"))
	default:
		return x, &ValidationError{Fields: map[string]string{"event": "Неизвестное событие"}}
	}
	return x, err
}

// Sweep enforces timeouts; called every couple of seconds by Run.
func (s *Service) Sweep(ctx context.Context) {
	now := s.now()
	cutoff := func(sec int) int64 { return ms(now.Add(-time.Duration(sec) * time.Second)) }
	type rule struct {
		where string
		args  []any
		to    State
		msg   string
	}
	for _, r := range []rule{
		{`state NOT IN ('disconnected','failed','expired','revoked') AND expires_at < ?`, []any{ms(now)}, StateExpired, "Истёк срок сеанса"},
		{`state = 'pending' AND approved_at IS NULL AND created_at < ?`, []any{cutoff(s.cfg.PickupTimeoutSec)}, StateFailed, "Хост не ответил на запрос сеанса"},
		{`state = 'awaiting_approval' AND created_at < ?`, []any{cutoff(s.cfg.ApprovalTimeoutSec)}, StateFailed, "Нет подтверждения на компьютере"},
		{`state = 'connecting' AND granted_at IS NULL AND ready_at < ?`, []any{cutoff(s.cfg.GrantTTLSec)}, StateExpired, "Данные подключения не забраны вовремя"},
		{`state = 'connecting' AND granted_at IS NOT NULL AND granted_at < ?`, []any{cutoff(2 * s.cfg.GrantTTLSec)}, StateFailed, "Клиент не подключился к хосту"},
		{`state = 'reconnecting' AND lost_at < ?`, []any{cutoff(s.cfg.ReconnectGraceSec)}, StateDisconnected, "Связь потеряна и не восстановилась"},
	} {
		list, err := s.sessions(ctx, r.where, 100, r.args...)
		if err != nil {
			continue
		}
		for _, x := range list {
			_, _ = s.stop(ctx, x.ID, r.to, r.msg)
		}
	}
}

// Prune drops old session history.
func (s *Service) Prune(ctx context.Context) error {
	cut := ms(s.now().Add(-time.Duration(s.cfg.RetentionDays) * 24 * time.Hour))
	if _, err := s.db.ExecContext(ctx, `DELETE FROM remote_events WHERE session_id IN (SELECT id FROM remote_sessions WHERE created_at < ? AND ended_at IS NOT NULL)`, cut); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM remote_sessions WHERE created_at < ? AND ended_at IS NOT NULL`, cut)
	return err
}

// Run is the background loop: timeouts and retention.
func (s *Service) Run(ctx context.Context) {
	sweep := time.NewTicker(2 * time.Second)
	defer sweep.Stop()
	prune := time.NewTicker(time.Hour)
	defer prune.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-sweep.C:
			s.Sweep(ctx)
		case <-prune.C:
			if err := s.Prune(ctx); err != nil {
				s.log.Warn("remote retention", "err", err)
			}
		}
	}
}
