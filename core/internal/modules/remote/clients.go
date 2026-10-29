package remote

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"slices"
	"strings"
	"time"

	"aerhome/core/internal/foundation/ids"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/remoteengine"
)

// Remote access clients (ADR-017): AER Connect or another AER HOME outside
// the home, each with its own credential, allowed hosts and rights.

// ClientPrefix starts a client credential: aerc1.<clientId>.<64 hex>.
const ClientPrefix = "aerc1."

// TunnelPath is where clients open relay legs on the Gateway.
const TunnelPath = "/gw/v1/tunnel"

const (
	pairTTL          = 15 * time.Minute
	maxFails         = 5
	failWindow       = 10 * time.Minute
	lockFor          = 15 * time.Minute
	maxTicketsPerSes = 40
)

// Client is a remote access client as the owner sees it (no secrets).
type Client struct {
	ID          string     `json:"id"`
	Name        string     `json:"name"`
	Hosts       []string   `json:"hosts"`
	Clipboard   bool       `json:"clipboard"`
	Files       bool       `json:"files"`
	DeviceName  string     `json:"deviceName"`
	Paired      bool       `json:"paired"`
	PairPending bool       `json:"pairPending"`
	CreatedAt   time.Time  `json:"createdAt"`
	PairedAt    *time.Time `json:"pairedAt"`
	LastSeenAt  *time.Time `json:"lastSeenAt"`
	LastAddr    string     `json:"lastAddr"`
	RevokedAt   *time.Time `json:"revokedAt"`
}

// ClientInput creates or edits a client.
type ClientInput struct {
	Name      string   `json:"name"`
	Hosts     []string `json:"hosts"`
	Clipboard bool     `json:"clipboard"`
	Files     bool     `json:"files"`
}

// Pairing is the one-time code the owner passes to the new client.
type Pairing struct {
	Client    Client    `json:"client"`
	Code      string    `json:"code"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// Paired is what the Gateway hands to a client after pairing (once).
type Paired struct {
	ClientID   string `json:"clientId"`
	Name       string `json:"name"`
	Credential string `json:"credential"`
}

type ticket struct {
	sessionID, clientID, channel string
	expires                      time.Time
}

type failures struct {
	times  []time.Time
	locked time.Time
}

// Claim is a redeemed ticket: the leg the Gateway may splice.
type Claim struct {
	SessionID string `json:"sessionId"`
	EntityID  string `json:"entityId"`
	Channel   string `json:"channel"`
}

const clientCols = `id, name, hosts, clipboard, files, device_name, secret_hash IS NOT NULL, pair_hash IS NOT NULL AND pair_expires > ?,
	created_at, paired_at, last_seen_at, last_addr, revoked_at`

func (s *Service) scanClient(row interface{ Scan(...any) error }) (Client, error) {
	var c Client
	var hosts string
	var created int64
	var paired, seen, revoked sql.NullInt64
	var clip, files int
	if err := row.Scan(&c.ID, &c.Name, &hosts, &clip, &files, &c.DeviceName, &c.Paired, &c.PairPending, &created, &paired, &seen, &c.LastAddr, &revoked); err != nil {
		return c, err
	}
	_ = json.Unmarshal([]byte(hosts), &c.Hosts)
	if c.Hosts == nil {
		c.Hosts = []string{}
	}
	c.Clipboard, c.Files = clip == 1, files == 1
	c.CreatedAt, c.PairedAt, c.LastSeenAt, c.RevokedAt = fromMS(created), fromNullMS(paired), fromNullMS(seen), fromNullMS(revoked)
	return c, nil
}

// Clients lists every client, newest first.
func (s *Service) Clients(ctx context.Context) ([]Client, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+clientCols+` FROM remote_clients ORDER BY created_at DESC, id`, ms(s.now()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Client{}
	for rows.Next() {
		c, err := s.scanClient(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// Client returns one client.
func (s *Service) Client(ctx context.Context, id string) (Client, error) {
	c, err := s.scanClient(s.db.QueryRowContext(ctx, `SELECT `+clientCols+` FROM remote_clients WHERE id = ?`, ms(s.now()), id))
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

func (s *Service) validateClient(ctx context.Context, in *ClientInput) error {
	v := map[string]string{}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" || len([]rune(in.Name)) > 80 {
		v["name"] = "Имя клиента от 1 до 80 символов"
	}
	if len(in.Hosts) > 64 {
		v["hosts"] = "Не больше 64 компьютеров"
	}
	seen := map[string]bool{}
	clean := []string{}
	for _, h := range in.Hosts {
		if seen[h] {
			continue
		}
		seen[h] = true
		if _, err := s.reg.Get(ctx, h); err != nil {
			v["hosts"] = "Неизвестный компьютер: " + h
			break
		}
		clean = append(clean, h)
	}
	in.Hosts = clean
	if len(v) > 0 {
		return &ValidationError{Fields: v}
	}
	return nil
}

// pairAlphabet: Crockford-like, no 0/O/1/I/L/U. 12 symbols ≈ 60 bits.
const pairAlphabet = "ABCDEFGHJKMNPQRSTVWXYZ23456789"

func newPairCode() string {
	var b strings.Builder
	n := big.NewInt(int64(len(pairAlphabet)))
	for i := range 12 {
		if i > 0 && i%4 == 0 {
			b.WriteByte('-')
		}
		k, _ := rand.Int(rand.Reader, n)
		b.WriteByte(pairAlphabet[k.Int64()])
	}
	return b.String()
}

func normPairCode(c string) string {
	return strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(strings.TrimSpace(c)))
}

// CreateClient registers a client and returns its one-time pairing code.
func (s *Service) CreateClient(ctx context.Context, in ClientInput) (Pairing, error) {
	if err := s.validateClient(ctx, &in); err != nil {
		return Pairing{}, err
	}
	hosts, _ := json.Marshal(in.Hosts)
	id, code := ids.New(), newPairCode()
	now := s.now().UTC().Truncate(time.Millisecond)
	h := remoteengine.HashSecret(normPairCode(code))
	if _, err := s.db.ExecContext(ctx, `INSERT INTO remote_clients (id, name, hosts, clipboard, files, pair_hash, pair_expires, created_at)
		VALUES (?,?,?,?,?,?,?,?)`, id, in.Name, string(hosts), boolInt(in.Clipboard), boolInt(in.Files), h[:], ms(now.Add(pairTTL)), ms(now)); err != nil {
		return Pairing{}, err
	}
	c, err := s.Client(ctx, id)
	return Pairing{Client: c, Code: code, ExpiresAt: now.Add(pairTTL)}, err
}

// UpdateClient changes a client's name, hosts and rights. Narrowing does
// not cut running sessions; revoke them for that.
func (s *Service) UpdateClient(ctx context.Context, id string, in ClientInput) (Client, error) {
	c, err := s.Client(ctx, id)
	if err != nil {
		return c, err
	}
	if c.RevokedAt != nil {
		return c, &RefusedError{Status: 409, Code: "CONFLICT", Reason: "revoked", Message: "Клиент отозван"}
	}
	if err := s.validateClient(ctx, &in); err != nil {
		return c, err
	}
	hosts, _ := json.Marshal(in.Hosts)
	if _, err := s.db.ExecContext(ctx, `UPDATE remote_clients SET name = ?, hosts = ?, clipboard = ?, files = ? WHERE id = ?`,
		in.Name, string(hosts), boolInt(in.Clipboard), boolInt(in.Files), id); err != nil {
		return c, err
	}
	return s.Client(ctx, id)
}

// RepairClient issues a new pairing code; a successful pairing replaces the
// client's credential (the old device stops working).
func (s *Service) RepairClient(ctx context.Context, id string) (Pairing, error) {
	c, err := s.Client(ctx, id)
	if err != nil {
		return Pairing{}, err
	}
	if c.RevokedAt != nil {
		return Pairing{}, &RefusedError{Status: 409, Code: "CONFLICT", Reason: "revoked", Message: "Клиент отозван — создайте нового"}
	}
	code := newPairCode()
	now := s.now().UTC().Truncate(time.Millisecond)
	h := remoteengine.HashSecret(normPairCode(code))
	if _, err := s.db.ExecContext(ctx, `UPDATE remote_clients SET pair_hash = ?, pair_expires = ? WHERE id = ?`, h[:], ms(now.Add(pairTTL)), id); err != nil {
		return Pairing{}, err
	}
	c, err = s.Client(ctx, id)
	return Pairing{Client: c, Code: code, ExpiresAt: now.Add(pairTTL)}, err
}

// RevokeClient disables a client for good and revokes its sessions.
func (s *Service) RevokeClient(ctx context.Context, id string) (Client, error) {
	c, err := s.Client(ctx, id)
	if err != nil {
		return c, err
	}
	if c.RevokedAt == nil {
		if _, err := s.db.ExecContext(ctx, `UPDATE remote_clients SET revoked_at = ?, secret_hash = NULL, pair_hash = NULL WHERE id = ?`, ms(s.now()), id); err != nil {
			return c, err
		}
	}
	act, _ := s.sessions(ctx, `client_id = ? AND route = 'relay' AND state NOT IN ('disconnected','failed','expired','revoked')`, 100, id)
	for _, x := range act {
		_, _ = s.stop(ctx, x.ID, StateRevoked, "Доступ клиента «"+c.Name+"» отозван владельцем")
	}
	return s.Client(ctx, id)
}

// Pair redeems a pairing code (once, before it expires) and returns the
// client's new credential. Wrong, used and expired codes look the same.
func (s *Service) Pair(ctx context.Context, code, deviceName, addr string) (Paired, error) {
	refused := &RefusedError{Status: 401, Code: "UNAUTHORIZED", Reason: "bad_code", Message: "Код сопряжения неверен или истёк"}
	norm := normPairCode(code)
	if len(norm) != 12 {
		return Paired{}, refused
	}
	h := remoteengine.HashSecret(norm)
	var id, name string
	err := s.db.QueryRowContext(ctx, `SELECT id, name FROM remote_clients WHERE pair_hash = ? AND pair_expires > ? AND revoked_at IS NULL`,
		h[:], ms(s.now())).Scan(&id, &name)
	if err != nil {
		return Paired{}, refused
	}
	sec := remoteengine.NewSecret()
	sh := remoteengine.HashSecret(sec)
	deviceName = strings.TrimSpace(deviceName)
	if len([]rune(deviceName)) > 80 {
		deviceName = string([]rune(deviceName)[:80])
	}
	res, err := s.db.ExecContext(ctx, `UPDATE remote_clients SET secret_hash = ?, pair_hash = NULL, pair_expires = NULL, paired_at = ?,
		device_name = ?, last_addr = ? WHERE id = ? AND pair_hash = ?`, sh[:], ms(s.now()), deviceName, addr, id, h[:])
	if err != nil {
		return Paired{}, err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return Paired{}, refused
	}
	s.mu.Lock()
	delete(s.fails, id)
	s.mu.Unlock()
	s.mon.RecordEvent(ctx, "", "remote_client_paired", monitoring.SeverityInfo, "Клиент удалённого доступа «"+name+"» сопряжён")
	return Paired{ClientID: id, Name: name, Credential: ClientPrefix + id + "." + sec}, nil
}

// ErrClientAuth: missing, malformed, wrong, revoked or locked credential.
var ErrClientAuth = &RefusedError{Status: http.StatusUnauthorized, Code: "UNAUTHORIZED", Reason: "client_auth",
	Message: "Учётные данные клиента не приняты"}

// AuthenticateClient checks a client credential. After maxFails wrong
// secrets for a known client within failWindow the client is locked for
// lockFor, even for the right secret (a guesser cannot tell).
func (s *Service) AuthenticateClient(ctx context.Context, cred, addr string) (Client, error) {
	rest, ok := strings.CutPrefix(cred, ClientPrefix)
	id, sec, ok2 := strings.Cut(rest, ".")
	if !ok || !ok2 || !ids.Valid(id) || len(sec) != 64 {
		return Client{}, ErrClientAuth
	}
	now := s.now()
	s.mu.Lock()
	f := s.fails[id]
	locked := f != nil && now.Before(f.locked)
	s.mu.Unlock()
	var hash []byte
	err := s.db.QueryRowContext(ctx, `SELECT secret_hash FROM remote_clients WHERE id = ? AND revoked_at IS NULL`, id).Scan(&hash)
	sum := remoteengine.HashSecret(sec)
	if err != nil || len(hash) != 32 {
		subtle.ConstantTimeCompare(sum[:], make([]byte, 32))
		return Client{}, ErrClientAuth
	}
	if subtle.ConstantTimeCompare(sum[:], hash) != 1 {
		s.mu.Lock()
		if s.fails[id] == nil {
			s.fails[id] = &failures{}
		}
		f := s.fails[id]
		f.times = append(slices.DeleteFunc(f.times, func(t time.Time) bool { return now.Sub(t) > failWindow }), now)
		if len(f.times) >= maxFails && !now.Before(f.locked) {
			f.locked = now.Add(lockFor)
			f.times = nil
			s.mu.Unlock()
			s.mon.RecordEvent(ctx, "", "remote_client_locked", monitoring.SeverityWarning,
				fmt.Sprintf("Клиент удалённого доступа заблокирован на %d мин после неверных попыток входа", int(lockFor.Minutes())))
			return Client{}, ErrClientAuth
		}
		s.mu.Unlock()
		return Client{}, ErrClientAuth
	}
	if locked {
		return Client{}, ErrClientAuth
	}
	_, _ = s.db.ExecContext(ctx, `UPDATE remote_clients SET last_seen_at = ?, last_addr = ? WHERE id = ?`, ms(now), addr, id)
	return s.Client(ctx, id)
}

// clientSession returns a relay session of this client (others: not found).
func (s *Service) clientSession(ctx context.Context, c Client, id string) (Session, error) {
	x, err := s.Session(ctx, id)
	if err != nil {
		return x, err
	}
	if x.Route != remoteengine.RouteRelay || x.ClientID != c.ID {
		return Session{}, ErrNotFound
	}
	if err := s.sessionTrust(ctx, x); err != nil {
		return Session{}, err
	}
	return x, nil
}

// ClientHosts lists the hosts this client may use (rights already narrowed).
func (s *Service) ClientHosts(ctx context.Context, c Client) ([]Host, error) {
	out := []Host{}
	for _, id := range c.Hosts {
		h, err := s.Host(ctx, id)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		out = append(out, s.forClient(h, c))
	}
	return out, nil
}

// forClient hides what a remote client does not need: LAN address, other
// clients' sessions, the owner's policy details.
func (s *Service) forClient(h Host, c Client) Host {
	h.Effective = h.Effective.And(Caps{Desktop: true, Input: true, Clipboard: c.Clipboard, Files: c.Files})
	if h.Agent != nil {
		a := *h.Agent
		a.Address, a.Port, a.FilesPort, a.CertPEM, a.Username, a.Instance = "", 0, 0, "", "", ""
		h.Agent = &a
	}
	if h.ActiveSession != nil && h.ActiveSession.ClientID != c.ID {
		h.ActiveSession = &Session{ID: "", State: h.ActiveSession.State, EntityID: h.EntityID}
	}
	h.LastSession = nil
	h.Policy = Policy{Enabled: h.Policy.Enabled}
	return h
}

// ClientCreate starts a relay session for a client.
func (s *Service) ClientCreate(ctx context.Context, c Client, in NewSession, key string) (Session, error) {
	if !slices.Contains(c.Hosts, in.EntityID) {
		return Session{}, ErrNotFound
	}
	in.SourceName, in.ClientID, in.SourceEntity = c.Name, c.ID, ""
	if key != "" {
		key = "gw:" + c.ID + ":" + key
	}
	return s.create(ctx, in, key, remoteengine.RouteRelay, Caps{Desktop: true, Input: true, Clipboard: c.Clipboard, Files: c.Files}, nil)
}

// ClientSession, ClientGrant and ClientEnd act on the client's own session.
func (s *Service) ClientSession(ctx context.Context, c Client, id string) (Session, error) {
	return s.clientSession(ctx, c, id)
}

func (s *Service) ClientGrant(ctx context.Context, c Client, id string) (Grant, error) {
	x, err := s.clientSession(ctx, c, id)
	if err != nil {
		return Grant{}, err
	}
	return s.grant(ctx, x)
}

func (s *Service) ClientEnd(ctx context.Context, c Client, id string) (Session, error) {
	if _, err := s.clientSession(ctx, c, id); err != nil {
		return Session{}, err
	}
	return s.End(ctx, id)
}

// ClientTicket issues a fresh one-time ticket for a reconnect (the grant's
// tickets are single-use). Only after the grant, only for allowed channels.
func (s *Service) ClientTicket(ctx context.Context, c Client, id, channel string) (string, error) {
	x, err := s.clientSession(ctx, c, id)
	if err != nil {
		return "", err
	}
	switch {
	case !remoteengine.ValidChannel(channel):
		return "", &ValidationError{Fields: map[string]string{"channel": "rdp или files"}}
	case channel == remoteengine.ChannelFiles && !x.Allowed.Files:
		return "", &RefusedError{Status: 403, Code: "PERMISSION_REQUIRED", Reason: "files_denied", Message: "Передача файлов в этом сеансе не разрешена"}
	case x.State.Terminal():
		return "", &RefusedError{Status: 410, Code: "CONFLICT", Reason: "ended", Message: "Сеанс уже завершён"}
	case x.GrantedAt == nil:
		return "", &RefusedError{Status: 409, Code: "CONFLICT", Reason: "not_granted", Message: "Сначала получите данные подключения"}
	}
	s.mu.Lock()
	n := s.issued[id]
	s.mu.Unlock()
	if n >= maxTicketsPerSes {
		return "", &RefusedError{Status: 429, Code: "CONFLICT", Reason: "ticket_limit", Message: "Слишком много переподключений — начните новый сеанс"}
	}
	return s.issueTicket(x, channel), nil
}

func (s *Service) issueTicket(x Session, channel string) string {
	t := remoteengine.NewSecret()
	s.mu.Lock()
	s.tickets[remoteengine.HashSecret(t)] = &ticket{sessionID: x.ID, clientID: x.ClientID, channel: channel,
		expires: s.now().Add(time.Duration(s.cfg.GrantTTLSec) * time.Second)}
	s.issued[x.ID]++
	s.mu.Unlock()
	return t
}

// dropTicketsLocked forgets a session's tickets (s.mu held).
func (s *Service) dropTicketsLocked(sessionID string) {
	for k, t := range s.tickets {
		if t.sessionID == sessionID {
			delete(s.tickets, k)
		}
	}
	delete(s.issued, sessionID)
}

// ClaimTicket redeems a client leg's ticket: once, in time, by the client
// it was issued to, for a live session.
func (s *Service) ClaimTicket(ctx context.Context, c Client, tk string) (Claim, error) {
	refused := &RefusedError{Status: 403, Code: "FORBIDDEN", Reason: "bad_ticket", Message: "Билет туннеля неверен, использован или истёк"}
	h := remoteengine.HashSecret(tk)
	s.mu.Lock()
	t := s.tickets[h]
	delete(s.tickets, h) // one use, even when refused below
	s.mu.Unlock()
	if t == nil || s.now().After(t.expires) || t.clientID != c.ID {
		return Claim{}, refused
	}
	x, err := s.Session(ctx, t.sessionID)
	if err != nil || x.State.Terminal() || s.sessionTrust(ctx, x) != nil {
		return Claim{}, refused
	}
	s.audit(ctx, x.ID, "tunnel_claimed", "Клиент открыл туннель «"+t.channel+"» через Gateway")
	return Claim{SessionID: x.ID, EntityID: x.EntityID, Channel: t.channel}, nil
}

// HostLeg checks a host agent's relay leg: its own host, a relay session
// that is ready, a channel the session allows.
func (s *Service) HostLeg(ctx context.Context, entityID, sessionID, channel string) (Claim, error) {
	x, err := s.Session(ctx, sessionID)
	if err != nil {
		return Claim{}, err
	}
	if err := s.sessionTrust(ctx, x); err != nil {
		return Claim{}, err
	}
	switch {
	case x.EntityID != entityID:
		return Claim{}, &RefusedError{Status: 403, Code: "FORBIDDEN", Reason: "foreign", Message: "Сеанс другого хоста"}
	case x.Route != remoteengine.RouteRelay || !remoteengine.ValidChannel(channel):
		return Claim{}, &RefusedError{Status: 409, Code: "CONFLICT", Reason: "not_relay", Message: "Сеанс не идёт через Gateway"}
	case channel == remoteengine.ChannelFiles && !x.Allowed.Files:
		return Claim{}, &RefusedError{Status: 403, Code: "PERMISSION_REQUIRED", Reason: "files_denied", Message: "Передача файлов не разрешена"}
	case x.State != StateConnecting && x.State != StateConnected && x.State != StateReconnecting:
		return Claim{}, &RefusedError{Status: 409, Code: "CONFLICT", Reason: "not_ready", Message: "Сеанс не готов или завершён (" + string(x.State) + ")"}
	}
	return Claim{SessionID: x.ID, EntityID: x.EntityID, Channel: channel}, nil
}

// Alive returns which of these sessions are still running.
func (s *Service) Alive(ctx context.Context, sessionIDs []string) []string {
	out := []string{}
	for _, id := range sessionIDs {
		if x, err := s.Session(ctx, id); err == nil && !x.State.Terminal() && s.sessionTrust(ctx, x) == nil {
			out = append(out, id)
		}
	}
	return out
}

// TunnelEvent records what the Gateway saw (audit; metadata only).
func (s *Service) TunnelEvent(ctx context.Context, sessionID, kind, msg string) error {
	if _, err := s.Session(ctx, sessionID); err != nil {
		return err
	}
	if kind != "tunnel_opened" && kind != "tunnel_closed" && kind != "tunnel_refused" {
		return &ValidationError{Fields: map[string]string{"kind": "tunnel_opened, tunnel_closed или tunnel_refused"}}
	}
	if len(msg) > 300 {
		msg = msg[:300]
	}
	s.audit(ctx, sessionID, kind, msg)
	return nil
}
