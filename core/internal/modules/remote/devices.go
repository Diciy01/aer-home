package remote

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"aerhome/core/internal/foundation/ids"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
	"aerhome/core/internal/remoteengine"
)

// AER Connect Anywhere devices (ADR-018). One AER Connect installation is
// one device: a Registry computer with a host agent credential (kind
// remote) and a remote client credential for its viewer, joined under a
// public 9-digit number. A device registers itself once with an
// enrollment code the owner issued. Viewers reach a device by number and a
// password that only the device checks: Core relays a sealed attempt and
// enforces single use, rate limits and the usual session rules.

const (
	attemptTTL        = 60 * time.Second
	authVerdictWait   = 20 * time.Second
	maxAttemptsOpen   = 4
	challengeLimit    = 30 // per viewer per failWindow
	pairFailLimit     = 5  // viewer → device wrong passwords per failWindow
	targetFailLimit   = 20 // all viewers → one device per failWindow
	maxEnrollmentUses = 100
)

// Device is an AER Connect installation as the owner sees it (no secrets).
type Device struct {
	ID         string     `json:"id"`
	Number     string     `json:"number"`
	Name       string     `json:"name"`
	EntityID   string     `json:"entityId"`
	ClientID   string     `json:"clientId"`
	CreatedAt  time.Time  `json:"createdAt"`
	LastSeenAt *time.Time `json:"lastSeenAt"`
	ConflictAt *time.Time `json:"conflictAt"`
	RevokedAt  *time.Time `json:"revokedAt"`
	Online     bool       `json:"online"`
	// Status: online | offline | revoked | conflict.
	Status string `json:"status"`
}

// Enrollment lets new devices register themselves (owner action).
type Enrollment struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	MaxUses   int        `json:"maxUses"`
	Uses      int        `json:"uses"`
	ExpiresAt time.Time  `json:"expiresAt"`
	CreatedAt time.Time  `json:"createdAt"`
	RevokedAt *time.Time `json:"revokedAt"`
	Active    bool       `json:"active"`
}

// EnrollmentCode is shown to the owner exactly once.
type EnrollmentCode struct {
	Enrollment Enrollment `json:"enrollment"`
	Code       string     `json:"code"`
}

// EnrollmentInput is the owner's request.
type EnrollmentInput struct {
	Name    string `json:"name"`
	MaxUses int    `json:"maxUses"`
	Hours   int    `json:"hours"`
}

// EnrollInput is what a new installation sends (through the Gateway).
type EnrollInput struct {
	Code       string `json:"code"`
	DeviceName string `json:"deviceName"`
	BoxPub     string `json:"boxPub"`
	Instance   string `json:"instance"`
}

// Enrolled is handed to the device once; it keeps both credentials in the
// OS secret store. Core keeps only their SHA-256.
type Enrolled struct {
	DeviceID         string `json:"deviceId"`
	Number           string `json:"number"`
	Name             string `json:"name"`
	EntityID         string `json:"entityId"`
	AgentToken       string `json:"agentToken"`
	ClientCredential string `json:"clientCredential"`
}

// Challenge opens one password attempt to a device.
type Challenge struct {
	AttemptID    string    `json:"attemptId"`
	Number       string    `json:"number"`
	Name         string    `json:"name"`
	BoxPub       string    `json:"boxPub"`
	ViewerNumber string    `json:"viewerNumber"`
	ExpiresAt    time.Time `json:"expiresAt"`
}

// ConnectInput carries the sealed password of an attempt.
type ConnectInput struct {
	AttemptID  string `json:"attemptId"`
	EphPub     string `json:"ephPub"`
	Ciphertext string `json:"ciphertext"`
	Clipboard  *bool  `json:"clipboard"`
	Files      *bool  `json:"files"`
	Minutes    int    `json:"minutes"`
}

type attempt struct {
	viewer, viewerNumber, deviceID, number string
	expires                                time.Time
}

type authVerdict struct {
	ok   bool
	code string
}

// entityWriter is the part of Registry an enrollment needs. The Registry
// service handed to Remote implements it; a read-only fake does not.
type entityWriter interface {
	Create(ctx context.Context, in registry.NewEntity) (registry.Entity, error)
	Archive(ctx context.Context, id string, revision int) (registry.Entity, error)
}

func refuse(status int, code, reason, msg string) *RefusedError {
	return &RefusedError{Status: status, Code: code, Reason: reason, Message: msg}
}

// ---- enrollments (owner) ----

const enrollCols = `id, name, max_uses, uses, expires_at, created_at, revoked_at`

func (s *Service) scanEnrollment(row interface{ Scan(...any) error }) (Enrollment, error) {
	var e Enrollment
	var exp, created int64
	var rev sql.NullInt64
	if err := row.Scan(&e.ID, &e.Name, &e.MaxUses, &e.Uses, &exp, &created, &rev); err != nil {
		return e, err
	}
	e.ExpiresAt, e.CreatedAt, e.RevokedAt = fromMS(exp), fromMS(created), fromNullMS(rev)
	e.Active = e.RevokedAt == nil && e.Uses < e.MaxUses && s.now().Before(e.ExpiresAt)
	return e, nil
}

// CreateEnrollment issues a code for up to maxUses new devices.
func (s *Service) CreateEnrollment(ctx context.Context, in EnrollmentInput) (EnrollmentCode, error) {
	v := map[string]string{}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" || len([]rune(in.Name)) > 80 {
		v["name"] = "Название от 1 до 80 символов"
	}
	if in.MaxUses == 0 {
		in.MaxUses = 1
	}
	if in.MaxUses < 1 || in.MaxUses > maxEnrollmentUses {
		v["maxUses"] = fmt.Sprintf("От 1 до %d устройств", maxEnrollmentUses)
	}
	if in.Hours == 0 {
		in.Hours = 24
	}
	if in.Hours < 1 || in.Hours > 24*30 {
		v["hours"] = "От 1 часа до 30 суток"
	}
	if len(v) > 0 {
		return EnrollmentCode{}, &ValidationError{Fields: v}
	}
	id, code := ids.New(), newPairCode()
	now := s.now().UTC().Truncate(time.Millisecond)
	h := remoteengine.HashSecret("enroll:" + normPairCode(code))
	if _, err := s.db.ExecContext(ctx, `INSERT INTO remote_enrollments (id, name, code_hash, max_uses, expires_at, created_at) VALUES (?,?,?,?,?,?)`,
		id, in.Name, h[:], in.MaxUses, ms(now.Add(time.Duration(in.Hours)*time.Hour)), ms(now)); err != nil {
		return EnrollmentCode{}, err
	}
	e, err := s.scanEnrollment(s.db.QueryRowContext(ctx, `SELECT `+enrollCols+` FROM remote_enrollments WHERE id = ?`, id))
	s.mon.RecordEvent(ctx, "", "remote_enrollment", monitoring.SeverityInfo, fmt.Sprintf("Выдан код регистрации AER Connect «%s» на %d устр.", in.Name, in.MaxUses))
	return EnrollmentCode{Enrollment: e, Code: code}, err
}

// Enrollments lists codes, newest first (never the codes themselves).
func (s *Service) Enrollments(ctx context.Context) ([]Enrollment, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+enrollCols+` FROM remote_enrollments ORDER BY created_at DESC, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Enrollment{}
	for rows.Next() {
		e, err := s.scanEnrollment(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// RevokeEnrollment stops a code from registering further devices.
func (s *Service) RevokeEnrollment(ctx context.Context, id string) (Enrollment, error) {
	if _, err := s.db.ExecContext(ctx, `UPDATE remote_enrollments SET revoked_at = COALESCE(revoked_at, ?), code_hash = NULL WHERE id = ?`, ms(s.now()), id); err != nil {
		return Enrollment{}, err
	}
	e, err := s.scanEnrollment(s.db.QueryRowContext(ctx, `SELECT `+enrollCols+` FROM remote_enrollments WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return e, ErrNotFound
	}
	return e, err
}

// ---- devices ----

const deviceCols = `id, number, name, entity_id, client_id, created_at, last_seen_at, conflict_at, revoked_at`

func (s *Service) scanDevice(row interface{ Scan(...any) error }) (Device, error) {
	var d Device
	var created int64
	var seen, conflict, revoked sql.NullInt64
	if err := row.Scan(&d.ID, &d.Number, &d.Name, &d.EntityID, &d.ClientID, &created, &seen, &conflict, &revoked); err != nil {
		return d, err
	}
	d.CreatedAt, d.LastSeenAt, d.ConflictAt, d.RevokedAt = fromMS(created), fromNullMS(seen), fromNullMS(conflict), fromNullMS(revoked)
	return d, nil
}

func (s *Service) withStatus(ctx context.Context, d Device) Device {
	switch {
	case d.RevokedAt != nil:
		d.Status = "revoked"
	case d.ConflictAt != nil:
		d.Status = "conflict"
	default:
		if h, err := s.Host(ctx, d.EntityID); err == nil {
			d.Online = h.AgentActive
		}
		d.Status = map[bool]string{true: "online", false: "offline"}[d.Online]
	}
	return d
}

func (s *Service) device(ctx context.Context, where string, arg any) (Device, error) {
	d, err := s.scanDevice(s.db.QueryRowContext(ctx, `SELECT `+deviceCols+` FROM remote_devices WHERE `+where, arg))
	if errors.Is(err, sql.ErrNoRows) {
		return d, ErrNotFound
	}
	return d, err
}

// Devices lists every registered device for the owner.
func (s *Service) Devices(ctx context.Context) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+deviceCols+` FROM remote_devices ORDER BY created_at DESC, id`)
	if err != nil {
		return nil, err
	}
	var list []Device
	for rows.Next() {
		d, err := s.scanDevice(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		list = append(list, d)
	}
	rows.Close()
	out := []Device{}
	for _, d := range list {
		out = append(out, s.withStatus(ctx, d))
	}
	return out, nil
}

// RevokeDevice disables both credentials of a device and ends its sessions
// (as host and as viewer). Its number is never reused.
func (s *Service) RevokeDevice(ctx context.Context, id string) (Device, error) {
	d, err := s.device(ctx, `id = ?`, id)
	if err != nil {
		return d, err
	}
	if d.RevokedAt == nil {
		var agentID string
		if err := s.db.QueryRowContext(ctx, `SELECT agent_id FROM remote_devices WHERE id = ?`, id).Scan(&agentID); err != nil {
			return d, err
		}
		if _, err := s.db.ExecContext(ctx, `UPDATE remote_devices SET revoked_at = ? WHERE id = ?`, ms(s.now()), id); err != nil {
			return d, err
		}
		_, _ = s.mon.RevokeAgent(ctx, agentID)
		_, _ = s.RevokeClient(ctx, d.ClientID)
		s.revokeHostSessions(ctx, d.EntityID, "Устройство AER Connect отозвано владельцем")
		s.mon.RecordEvent(ctx, d.EntityID, "remote_device_revoked", monitoring.SeverityWarning, "Устройство AER Connect "+d.Number+" отозвано")
	}
	d, err = s.device(ctx, `id = ?`, id)
	return s.withStatus(ctx, d), err
}

// deviceByEntity returns the device registered for a host entity.
func (s *Service) deviceByEntity(ctx context.Context, entityID string) (Device, bool) {
	d, err := s.device(ctx, `entity_id = ?`, entityID)
	return d, err == nil
}

// Enroll registers a new installation with an owner's enrollment code.
// Wrong, used up, revoked and expired codes look the same.
func (s *Service) Enroll(ctx context.Context, in EnrollInput, addr string) (Enrolled, error) {
	bad := refuse(401, "UNAUTHORIZED", "bad_code", "Код регистрации неверен, истёк или исчерпан")
	v := map[string]string{}
	in.DeviceName = strings.TrimSpace(in.DeviceName)
	if in.DeviceName == "" || len([]rune(in.DeviceName)) > 80 {
		v["deviceName"] = "Имя устройства от 1 до 80 символов"
	}
	if !remoteengine.ValidBoxKey(in.BoxPub) {
		v["boxPub"] = "Открытый ключ X25519 устройства (32 байта base64url)"
	}
	if l := len(in.Instance); l < 16 || l > 128 || strings.Trim(in.Instance, "0123456789abcdef") != "" {
		v["instance"] = "Отпечаток установки (hex)"
	}
	if len(v) > 0 {
		return Enrolled{}, &ValidationError{Fields: v}
	}
	norm := normPairCode(in.Code)
	if len(norm) != 12 {
		return Enrolled{}, bad
	}
	w, canWrite := s.reg.(entityWriter)
	if !canWrite {
		return Enrolled{}, refuse(503, "UNAVAILABLE", "registry_readonly", "Регистрация устройств недоступна в этой конфигурации Core")
	}
	h := remoteengine.HashSecret("enroll:" + norm)
	s.createMu.Lock()
	defer s.createMu.Unlock()
	var enrollID string
	res, err := s.db.ExecContext(ctx, `UPDATE remote_enrollments SET uses = uses + 1 WHERE code_hash = ? AND revoked_at IS NULL AND uses < max_uses AND expires_at > ?`,
		h[:], ms(s.now()))
	if err != nil {
		return Enrolled{}, err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return Enrolled{}, bad
	}
	_ = s.db.QueryRowContext(ctx, `SELECT id FROM remote_enrollments WHERE code_hash = ?`, h[:]).Scan(&enrollID)
	release := func() { // give the use back when registration fails half-way
		_, _ = s.db.ExecContext(context.WithoutCancel(ctx), `UPDATE remote_enrollments SET uses = uses - 1 WHERE id = ? AND uses > 0`, enrollID)
	}
	caps := []string{"remote.desktop", "files.transfer", "monitoring.metrics"}
	ent, err := w.Create(ctx, registry.NewEntity{Name: in.DeviceName, Type: "computer", Description: "AER Connect", Discovery: registry.DiscoveryManual,
		Tags: []string{"aer-connect"}, Capabilities: &caps})
	if err != nil {
		release()
		return Enrolled{}, fmt.Errorf("registry: %w", err)
	}
	fail := func(err error) (Enrolled, error) {
		release()
		_, _ = w.Archive(context.WithoutCancel(ctx), ent.ID, ent.Revision)
		return Enrolled{}, err
	}
	agent, err := s.mon.CreateAgent(ctx, ent.ID, "AER Connect host", "remote")
	if err != nil {
		return fail(err)
	}
	clientID, sec := ids.New(), remoteengine.NewSecret()
	sh := remoteengine.HashSecret(sec)
	now := ms(s.now())
	if _, err := s.db.ExecContext(ctx, `INSERT INTO remote_clients (id, name, hosts, clipboard, files, secret_hash, device_name, created_at, paired_at, last_addr)
		VALUES (?,?,?,?,?,?,?,?,?,?)`, clientID, in.DeviceName, "[]", 1, 1, sh[:], "AER Connect", now, now, addr); err != nil {
		_, _ = s.mon.RevokeAgent(context.WithoutCancel(ctx), agent.Agent.ID)
		return fail(err)
	}
	pol := DefaultPolicy()
	pol.Files, pol.MaxMinutes = true, min(240, s.cfg.MaxMinutes)
	_, _ = s.db.ExecContext(ctx, `INSERT INTO remote_policies (entity_id, enabled, desktop, clipboard, files, max_minutes, revision, updated_at) VALUES (?,?,?,?,?,?,1,?)`,
		ent.ID, 1, 1, 1, 1, pol.MaxMinutes, now)
	devID, number := ids.New(), ""
	for range 8 { // 9 digits: a collision is rare; UNIQUE decides
		number = remoteengine.NewDeviceNumber()
		_, err = s.db.ExecContext(ctx, `INSERT INTO remote_devices (id, number, name, entity_id, agent_id, client_id, box_pub, instance, enrollment_id, created_at)
			VALUES (?,?,?,?,?,?,?,?,?,?)`, devID, number, in.DeviceName, ent.ID, agent.Agent.ID, clientID, in.BoxPub, in.Instance, enrollID, now)
		if err == nil || !strings.Contains(err.Error(), "remote_devices.number") {
			break
		}
	}
	if err != nil {
		_, _ = s.mon.RevokeAgent(context.WithoutCancel(ctx), agent.Agent.ID)
		_, _ = s.db.ExecContext(context.WithoutCancel(ctx), `UPDATE remote_clients SET revoked_at = ?, secret_hash = NULL WHERE id = ?`, now, clientID)
		return fail(err)
	}
	s.mon.RecordEvent(ctx, ent.ID, "remote_device_enrolled", monitoring.SeverityInfo, "Зарегистрировано устройство AER Connect "+number+" «"+in.DeviceName+"»")
	return Enrolled{DeviceID: devID, Number: number, Name: in.DeviceName, EntityID: ent.ID,
		AgentToken: agent.Token, ClientCredential: ClientPrefix + clientID + "." + sec}, nil
}

// DeviceOf returns the device that owns a remote client credential.
func (s *Service) DeviceOf(ctx context.Context, c Client) (Device, error) {
	d, err := s.device(ctx, `client_id = ?`, c.ID)
	if err != nil {
		return d, err
	}
	return s.withStatus(ctx, d), nil
}

// noteHello records a device's hello and detects cloned installations: the
// same credential from a different instance marks the device as conflicting
// until the owner revokes it and the user registers again.
func (s *Service) noteHello(ctx context.Context, a monitoring.Agent, info HostInfo) {
	var id, instance string
	var conflict sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT id, instance, conflict_at FROM remote_devices WHERE agent_id = ?`, a.ID).Scan(&id, &instance, &conflict)
	if err != nil {
		return
	}
	_, _ = s.db.ExecContext(ctx, `UPDATE remote_devices SET last_seen_at = ? WHERE id = ?`, ms(s.now()), id)
	if info.Instance != instance && !conflict.Valid {
		_, _ = s.db.ExecContext(ctx, `UPDATE remote_devices SET conflict_at = ? WHERE id = ?`, ms(s.now()), id)
		s.revokeHostSessions(ctx, a.EntityID, "Обнаружена копия установки AER Connect")
		s.mon.RecordEvent(ctx, a.EntityID, "remote_device_conflict", monitoring.SeverityWarning,
			"Учётные данные устройства AER Connect используются другой установкой: входящие подключения заблокированы")
	}
}

// ---- connect by number and password ----

// limited counts one event for key; true when the key is over limit now.
func (s *Service) limited(key string, limit int, count bool) bool {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	f := s.fails[key]
	if f == nil {
		if !count {
			return false
		}
		f = &failures{}
		s.fails[key] = f
	}
	if now.Before(f.locked) {
		return true
	}
	if !count {
		return false
	}
	f.times = append(slices.DeleteFunc(f.times, func(t time.Time) bool { return now.Sub(t) > failWindow }), now)
	if len(f.times) >= limit {
		f.locked, f.times = now.Add(lockFor), nil
		return true
	}
	return false
}

func (s *Service) viewerNumber(ctx context.Context, c Client) (string, error) {
	d, err := s.device(ctx, `client_id = ?`, c.ID)
	if errors.Is(err, ErrNotFound) {
		return "", nil // an owner-paired client without a device number
	}
	if err != nil {
		return "", err
	}
	if d.RevokedAt != nil || d.ConflictAt != nil {
		return "", ErrClientAuth
	}
	return d.Number, nil
}

// Challenge opens a password attempt from viewer c to the device number.
func (s *Service) Challenge(ctx context.Context, c Client, number string) (Challenge, error) {
	number = remoteengine.NormalizeDeviceNumber(number)
	if !remoteengine.ValidDeviceNumber(number) {
		return Challenge{}, &ValidationError{Fields: map[string]string{"number": "ID устройства — 9 цифр"}}
	}
	if s.limited("chal:"+c.ID, challengeLimit, true) {
		return Challenge{}, refuse(429, "UNAVAILABLE", "rate_limited", "Слишком много попыток — повторите позже")
	}
	vn, err := s.viewerNumber(ctx, c)
	if err != nil {
		return Challenge{}, err
	}
	if vn == number {
		return Challenge{}, refuse(422, "VALIDATION_FAILED", "self", "Это ID этого компьютера")
	}
	var d Device
	var boxPub string
	d, err = s.scanDevice(s.db.QueryRowContext(ctx, `SELECT `+deviceCols+` FROM remote_devices WHERE number = ?`, number))
	if errors.Is(err, sql.ErrNoRows) {
		return Challenge{}, refuse(404, "NOT_FOUND", "unknown_device", "Устройство с таким ID не найдено")
	}
	if err != nil {
		return Challenge{}, err
	}
	_ = s.db.QueryRowContext(ctx, `SELECT box_pub FROM remote_devices WHERE id = ?`, d.ID).Scan(&boxPub)
	switch {
	case d.RevokedAt != nil:
		return Challenge{}, refuse(410, "CONFLICT", "device_revoked", "Это устройство отключено владельцем сервера")
	case d.ConflictAt != nil:
		return Challenge{}, refuse(409, "CONFLICT", "device_conflict", "Учётные данные устройства используются другой установкой — подключение запрещено")
	case s.limited("pair:"+c.ID+"|"+d.ID, pairFailLimit, false) || s.limited("target:"+d.ID, targetFailLimit, false):
		return Challenge{}, refuse(429, "UNAVAILABLE", "locked", "Слишком много неверных паролей — устройство временно недоступно для входа")
	}
	h, err := s.Host(ctx, d.EntityID)
	if err != nil {
		return Challenge{}, err
	}
	if !h.CanConnect {
		if h.ActiveSession != nil {
			return Challenge{}, refuse(409, "CONFLICT", "busy", "К этому компьютеру уже подключаются или он занят другим сеансом")
		}
		return Challenge{}, refuse(503, "UNAVAILABLE", "offline", "Компьютер не в сети или AER Connect на нём не запущен")
	}
	if h.Agent == nil || !slices.Contains(h.Agent.Features, remoteengine.FeatureConnectAuth) {
		return Challenge{}, refuse(503, "UNAVAILABLE", "offline", "На компьютере устаревший AER Connect — обновите его")
	}
	now := s.now()
	a := &attempt{viewer: c.ID, viewerNumber: vn, deviceID: d.ID, number: number, expires: now.Add(attemptTTL)}
	id := remoteengine.NewAttemptID()
	s.mu.Lock()
	open := 0
	for k, x := range s.attempts {
		if now.After(x.expires) {
			delete(s.attempts, k)
		} else if x.viewer == c.ID {
			open++
		}
	}
	if open >= maxAttemptsOpen {
		s.mu.Unlock()
		return Challenge{}, refuse(429, "UNAVAILABLE", "rate_limited", "Слишком много незавершённых попыток")
	}
	s.attempts[id] = a
	s.mu.Unlock()
	return Challenge{AttemptID: id, Number: number, Name: d.Name, BoxPub: boxPub, ViewerNumber: vn, ExpiresAt: a.expires.UTC()}, nil
}

// ConnectDevice redeems an attempt: one session request whose sealed
// password the host checks before its local prompt. It returns after the
// host's verdict, so a wrong password is a clear error, not a failed state.
func (s *Service) ConnectDevice(ctx context.Context, c Client, in ConnectInput) (Session, error) {
	s.mu.Lock()
	a := s.attempts[in.AttemptID]
	delete(s.attempts, in.AttemptID) // one use, also when refused below
	s.mu.Unlock()
	if a == nil || a.viewer != c.ID || s.now().After(a.expires) {
		return Session{}, refuse(403, "FORBIDDEN", "bad_attempt", "Попытка входа истекла или уже использована — повторите")
	}
	if _, err := remoteengine.DecodeKey(in.EphPub); err != nil || in.Ciphertext == "" || len(in.Ciphertext) > 4096 {
		return Session{}, &ValidationError{Fields: map[string]string{"ciphertext": "Зашифрованный пароль"}}
	}
	d, err := s.device(ctx, `id = ?`, a.deviceID)
	if err != nil {
		return Session{}, err
	}
	viewerName := c.Name
	if a.viewerNumber != "" {
		viewerName = c.Name + " (ID " + a.viewerNumber + ")"
	}
	ns := NewSession{EntityID: d.EntityID, Kind: "desktop", SourceName: viewerName, ClientID: c.ID, Minutes: in.Minutes,
		Clipboard: in.Clipboard, Files: in.Files,
		auth: &remoteengine.ConnectAuth{AttemptID: in.AttemptID, EphPub: in.EphPub, Ciphertext: in.Ciphertext,
			ViewerNumber: a.viewerNumber, ViewerName: viewerName, TargetNumber: a.number}}
	wait := make(chan authVerdict, 1)
	x, err := s.create(ctx, ns, "", remoteengine.RouteRelay, Caps{Desktop: true, Input: true, Clipboard: true, Files: true}, func(id string) {
		s.mu.Lock()
		s.authWait[id] = wait
		s.mu.Unlock()
	})
	if err != nil {
		return x, err
	}
	defer func() {
		s.mu.Lock()
		delete(s.authWait, x.ID)
		s.mu.Unlock()
	}()
	t := time.NewTimer(authVerdictWait)
	defer t.Stop()
	select {
	case v := <-wait:
		if !v.ok {
			return Session{}, s.authRefusal(ctx, c.ID, d, v.code)
		}
	case <-t.C:
		_, _ = s.stop(ctx, x.ID, StateFailed, "Компьютер не проверил пароль вовремя")
		return Session{}, refuse(504, "UNAVAILABLE", "timeout", "Компьютер не ответил вовремя")
	case <-ctx.Done():
		_, _ = s.stop(context.WithoutCancel(ctx), x.ID, StateFailed, "Запрос отменён клиентом")
		return Session{}, ctx.Err()
	}
	return s.Session(ctx, x.ID)
}

func (s *Service) authRefusal(ctx context.Context, viewer string, d Device, code string) error {
	switch code {
	case remoteengine.AuthDisabled:
		return refuse(403, "FORBIDDEN", "incoming_disabled", "На этом компьютере входящие подключения выключены")
	case remoteengine.AuthLocked:
		return refuse(429, "UNAVAILABLE", "host_locked", "Компьютер временно не принимает пароль после неверных попыток")
	}
	// bad_password, malformed and replay count as a wrong password.
	pair := s.limited("pair:"+viewer+"|"+d.ID, pairFailLimit, true)
	if s.limited("target:"+d.ID, targetFailLimit, true) && !pair {
		s.mon.RecordEvent(ctx, d.EntityID, "remote_device_locked", monitoring.SeverityWarning,
			fmt.Sprintf("Слишком много неверных паролей к устройству %s: вход закрыт на %d мин", d.Number, int(lockFor.Minutes())))
	}
	return refuse(403, "FORBIDDEN", "bad_password", "Неверный пароль")
}

// authEvent applies a host's password verdict (auth_ok / auth_failed).
func (s *Service) authEvent(ctx context.Context, x Session, ev AgentEvent) (Session, error) {
	var state string
	_ = s.db.QueryRowContext(ctx, `SELECT auth_state FROM remote_sessions WHERE id = ?`, x.ID).Scan(&state)
	if state != "required" {
		return x, refuse(409, "CONFLICT", "auth_not_pending", "Проверка пароля для этого сеанса не ожидается")
	}
	v := authVerdict{ok: ev.Event == remoteengine.EventAuthOK, code: ev.Code}
	if v.ok {
		_, _ = s.db.ExecContext(ctx, `UPDATE remote_sessions SET auth_state = 'ok' WHERE id = ?`, x.ID)
		s.audit(ctx, x.ID, "auth_ok", "Пароль проверен компьютером")
	} else {
		_, _ = s.db.ExecContext(ctx, `UPDATE remote_sessions SET auth_state = 'failed' WHERE id = ?`, x.ID)
		msg := map[string]string{remoteengine.AuthDisabled: "Входящие подключения выключены на компьютере",
			remoteengine.AuthLocked: "Компьютер временно не принимает пароль"}[ev.Code]
		x, _, _ = s.transition(ctx, x.ID, StateFailed, or(msg, "Неверный пароль"), "auth_failed", or(msg, "Компьютер отклонил пароль"))
	}
	s.mu.Lock()
	w := s.authWait[x.ID]
	s.mu.Unlock()
	if w != nil {
		select {
		case w <- v:
		default:
		}
	} else if !v.ok {
		// Verdict after the viewer stopped waiting still counts.
		if d, ok := s.deviceByEntity(ctx, x.EntityID); ok {
			_ = s.authRefusal(ctx, x.ClientID, d, ev.Code)
		}
	}
	return s.Session(ctx, x.ID)
}

// authPending: the host has not yet accepted the session's password.
func (s *Service) authPending(ctx context.Context, id string) bool {
	var state string
	_ = s.db.QueryRowContext(ctx, `SELECT auth_state FROM remote_sessions WHERE id = ?`, id).Scan(&state)
	return state == "required" || state == "failed"
}
