package remotehost

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"aerhome/core/internal/remoteengine"
)

// Version of the host agent protocol implementation.
const Version = "0.1.0"

// Command is the shared Core → agent command (ADR-017).
type Command = remoteengine.Command

// Agent is the running host agent. One session at a time (RDP sharing of
// the user's session is single-user).
type Agent struct {
	cfg     Config
	backend Backend
	files   *FileServer
	http    *http.Client
	log     *slog.Logger
	certPEM string
	// Prompt asks the local user to allow a session (approval=prompt).
	Prompt func(ctx context.Context, text string) bool
	// Connections counts established RDP connections (-1: unknown).
	Connections func() int
	// Device mode (AER Connect, ADR-018): every session must carry a sealed
	// password that Auth checks before the local prompt; the credential is
	// held in memory (Token) instead of a token file.
	Auth     Authenticator
	Token    string
	Instance string
	// OnStatus reports connection and session changes (may be nil).
	OnStatus func(Status)

	mu      sync.Mutex
	session *openSession
	status  Status
}

type openSession struct {
	id        string
	viewer    string
	expiresAt time.Time
	connected bool
	cancel    context.CancelFunc
}

// Authenticator checks a device password attempt (ok, or a failure code).
type Authenticator interface {
	Verify(a remoteengine.ConnectAuth) (ok bool, code string)
}

// Gateway link states reported in Status.
const (
	LinkConnecting   = "connecting"
	LinkOnline       = "online"
	LinkReconnecting = "reconnecting"
	LinkRevoked      = "revoked"
	LinkStopped      = "stopped"
)

// Status is what the host shows its user.
type Status struct {
	Link    string         `json:"link"`
	Error   string         `json:"error,omitempty"`
	Session *SessionStatus `json:"session"`
}

// SessionStatus describes the incoming session (one at a time).
type SessionStatus struct {
	ID     string    `json:"id"`
	Viewer string    `json:"viewer"`
	State  string    `json:"state"` // verifying | prompt | active | connected
	Since  time.Time `json:"since"`
}

func (a *Agent) setStatus(fn func(*Status)) {
	a.mu.Lock()
	before := a.status
	if before.Session != nil {
		cp := *before.Session
		before.Session = &cp
	}
	fn(&a.status)
	st := a.status
	if st.Session != nil {
		cp := *st.Session
		st.Session = &cp
	}
	cb := a.OnStatus
	a.mu.Unlock()
	if cb != nil && (before.Link != st.Link || before.Error != st.Error || !sameSession(before.Session, st.Session)) {
		cb(st)
	}
}

func sameSession(a, b *SessionStatus) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

func (a *Agent) sessionState(id, state, viewer string) {
	a.setStatus(func(s *Status) {
		if state == "" {
			if s.Session != nil && s.Session.ID == id {
				s.Session = nil
			}
			return
		}
		if s.Session == nil || s.Session.ID != id {
			s.Session = &SessionStatus{ID: id, Viewer: viewer, Since: time.Now().UTC()}
		} else {
			cp := *s.Session
			s.Session = &cp
		}
		s.Session.State = state
	})
}

// CurrentStatus returns the last status.
func (a *Agent) CurrentStatus() Status {
	a.mu.Lock()
	defer a.mu.Unlock()
	st := a.status
	if st.Session != nil {
		cp := *st.Session
		st.Session = &cp
	}
	return st
}

// StopSession ends the current incoming session at the host user's request.
func (a *Agent) StopSession(ctx context.Context) bool {
	a.mu.Lock()
	s := a.session
	a.mu.Unlock()
	if s == nil {
		return false
	}
	a.closeSession(ctx, s.id, "Сеанс остановлен пользователем компьютера")
	return true
}

// New builds the agent for a validated config.
func New(cfg Config, log *slog.Logger) (*Agent, error) {
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	var cert string
	var err error
	if cfg.Backend == "windows-shadow" {
		cert, err = shadowPresenceCert(cfg)
	} else {
		cert, err = EnsureCert(&cfg)
	}
	if err != nil {
		return nil, fmt.Errorf("tls certificate: %w", err)
	}
	cfg.GatewayURL = strings.TrimRight(cfg.GatewayURL, "/")
	a := &Agent{cfg: cfg, log: log, certPEM: cert, http: &http.Client{Timeout: 40 * time.Second}}
	if cfg.CoreCertSHA256 != "" {
		tr := http.DefaultTransport.(*http.Transport).Clone()
		tr.TLSClientConfig = remoteengine.PinnedTLS(cfg.CoreCertSHA256)
		a.http.Transport = tr
	}
	switch cfg.Backend {
	case "windows-shadow":
		a.backend, err = newShadowBackend(cfg)
		if err != nil {
			return nil, err
		}
	case "windows-rdp":
		a.backend = &windowsBackend{c: cfg}
	default:
		a.backend = &gnomeBackend{c: cfg, run: execRunner, start: startDaemon(cfg.StateDir)}
	}
	if cfg.Files.Enabled {
		a.files = NewFileServer(cfg.Files.Dir, cfg.Files.MaxBytes)
	}
	a.Prompt = a.commandPrompt
	if prompt, ok := a.backend.(interface {
		Prompt(context.Context, string) bool
	}); ok {
		a.Prompt = prompt.Prompt
	}
	a.Connections = func() int { return established(cfg.Port) }
	return a, nil
}

// SetRunner replaces the command runner and the daemon starter of the
// GNOME backend (tests).
func (a *Agent) SetRunner(r Runner, start func([]string) (func(), error)) {
	if g, ok := a.backend.(*gnomeBackend); ok {
		g.run, g.start = r, start
	}
}

func (a *Agent) token() (string, error) {
	if a.Token != "" {
		return a.Token, nil
	}
	b, err := os.ReadFile(a.cfg.TokenFile)
	return strings.TrimSpace(string(b)), err
}

func (a *Agent) call(ctx context.Context, method, path string, body, out any) error {
	tok, err := a.token()
	if err != nil {
		return fmt.Errorf("token file: %w", err)
	}
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(a.cfg.CoreURL, "/")+"/api/v1"+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")
	res, err := a.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	var env struct {
		Data  json.RawMessage `json:"data"`
		Error *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&env); err != nil {
		return fmt.Errorf("core %s: HTTP %d", path, res.StatusCode)
	}
	if env.Error != nil {
		return &CoreError{Status: res.StatusCode, Code: env.Error.Code, Message: env.Error.Message}
	}
	if out != nil {
		return json.Unmarshal(env.Data, out)
	}
	return nil
}

// CoreError is an error envelope from Core.
type CoreError struct {
	Status  int
	Code    string
	Message string
}

func (e *CoreError) Error() string { return fmt.Sprintf("core: %d %s %s", e.Status, e.Code, e.Message) }

// Revoked: the credential was revoked or is invalid — stop.
func (e *CoreError) Revoked() bool { return e.Status == http.StatusUnauthorized }

// Hello reports host facts; it also closes any local session Core no
// longer considers active (e.g. ended while the agent was away).
func (a *Agent) Hello(ctx context.Context) error {
	ready, reason := a.backend.Ready(ctx)
	managed := a.cfg.Backend != "windows-rdp"
	host, _ := os.Hostname()
	a.mu.Lock()
	certPEM := a.certPEM
	a.mu.Unlock()
	body := map[string]any{
		"os": runtime.GOOS, "hostname": host, "version": Version, "backend": a.cfg.Backend,
		"address": a.cfg.Address, "port": a.cfg.Port, "certPem": certPEM, "monitors": 1,
		"capabilities": map[string]bool{"desktop": managed, "input": managed && !(a.cfg.Backend == "windows-shadow" && a.cfg.ShadowViewOnly), "clipboard": managed && a.cfg.Clipboard,
			"files": managed && a.cfg.Files.Enabled, "apps": false},
		"approval": a.cfg.Approval, "ready": ready, "reason": reason, "username": a.backend.Username(),
	}
	if a.Auth != nil {
		body["features"] = []string{remoteengine.FeatureConnectAuth}
	}
	if a.Instance != "" {
		body["instance"] = a.Instance
	}
	if a.cfg.Files.Enabled {
		body["filesPort"] = a.cfg.Files.Port
	}
	var res struct {
		ActiveSessions []string `json:"activeSessions"`
	}
	if err := a.call(ctx, http.MethodPost, "/remote/agent/hello", body, &res); err != nil {
		return err
	}
	// Minimal Monitoring heartbeat with the same device credential.
	_ = a.call(ctx, http.MethodPost, "/monitoring/agent/report", map[string]any{
		"agent": map[string]any{"version": "remote-" + Version, "os": runtime.GOOS, "hostname": host}}, nil)
	a.mu.Lock()
	s := a.session
	a.mu.Unlock()
	if s != nil && !slices.Contains(res.ActiveSessions, s.id) {
		a.closeSession(ctx, s.id, "Core считает сеанс завершённым")
	}
	return nil
}

func (a *Agent) event(ctx context.Context, id, ev, msg string, extra map[string]string) {
	body := map[string]string{"event": ev, "message": msg}
	for k, v := range extra {
		body[k] = v
	}
	if err := a.call(ctx, http.MethodPost, "/remote/agent/sessions/"+id+"/events", body, nil); err != nil {
		a.log.Warn("report event", "event", ev, "err", err)
	}
}

// Handle executes one command from Core.
func (a *Agent) Handle(ctx context.Context, c Command) {
	switch c.Type {
	case "open":
		a.openSession(ctx, c)
	case "close":
		a.closeSession(ctx, c.SessionID, or(c.Reason, "Закрыто по команде Core"))
	}
}

func or(a, b string) string {
	if a == "" {
		return b
	}
	return a
}

func (a *Agent) openSession(ctx context.Context, c Command) {
	a.mu.Lock()
	busy := a.session != nil
	a.mu.Unlock()
	if busy {
		a.event(ctx, c.SessionID, remoteengine.EventFailed, "На хосте уже идёт другой сеанс", nil)
		return
	}
	if time.Until(c.ExpiresAt) <= 0 {
		a.event(ctx, c.SessionID, remoteengine.EventFailed, "Срок сеанса истёк до открытия", nil)
		return
	}
	if c.Relay && a.cfg.GatewayURL == "" {
		a.event(ctx, c.SessionID, remoteengine.EventFailed, "Сеанс через Gateway, но gatewayUrl агента не настроен", nil)
		return
	}
	viewer := ""
	if a.Auth != nil || c.Auth != nil {
		// Device mode: no password, no session. The verdict goes to Core
		// before anything is shown or opened on this computer.
		if c.Auth == nil || a.Auth == nil {
			a.event(ctx, c.SessionID, remoteengine.EventFailed, "Этот компьютер принимает подключения только по ID и паролю", nil)
			return
		}
		viewer = c.Auth.ViewerName
		a.sessionState(c.SessionID, "verifying", viewer)
		ok, code := a.Auth.Verify(*c.Auth)
		if !ok {
			a.sessionState(c.SessionID, "", "")
			a.authEvent(ctx, c.SessionID, remoteengine.EventAuthFailed, code)
			return
		}
		if !a.authEvent(ctx, c.SessionID, remoteengine.EventAuthOK, "") {
			a.sessionState(c.SessionID, "", "")
			return
		}
	}
	if a.cfg.Approval == "prompt" {
		a.event(ctx, c.SessionID, remoteengine.EventAwaitingApproval, "", nil)
		a.sessionState(c.SessionID, "prompt", viewer)
		prompt := "Разрешить удалённое подключение AER HOME к этому компьютеру?"
		if viewer != "" {
			prompt = "Подключение через AER Connect от: " + viewer + ". Разрешайте, только если знаете, кто подключается."
		}
		if a.cfg.Backend == "windows-shadow" {
			prompt = fmt.Sprintf("%s\n\nПросмотр экрана: да\nМышь и клавиатура: %s\nТекстовый буфер: %s\nПапка обмена файлами: %s\n\nПостоянный доступ не предоставляется. Закройте окно активного доступа, чтобы немедленно завершить сеанс. Блокировка Windows и защищённый экран UAC завершают доступ.", shadowHeader(viewer), permissionLabel(c.Allowed.Input), permissionLabel(c.Allowed.Clipboard && a.cfg.Clipboard), permissionLabel(c.Allowed.Files && a.cfg.Files.Enabled))
		}
		if !a.Prompt(ctx, prompt) {
			a.sessionState(c.SessionID, "", "")
			a.event(ctx, c.SessionID, remoteengine.EventDenied, "Пользователь компьютера отклонил подключение", nil)
			return
		}
	}
	if a.cfg.Backend == "windows-shadow" {
		// Approval may have taken up to 90 seconds: do not start capture for
		// a session that was cancelled/revoked while the user was deciding.
		var current struct {
			State remoteengine.State `json:"state"`
		}
		err := a.call(ctx, http.MethodPost, "/remote/agent/sessions/"+c.SessionID+"/events", map[string]string{"event": remoteengine.EventApproved}, &current)
		if err != nil || (current.State != remoteengine.StatePending && current.State != remoteengine.StateAwaitingApproval) {
			a.sessionState(c.SessionID, "", "")
			return
		}
	} else {
		a.event(ctx, c.SessionID, remoteengine.EventApproved, "", nil)
	}
	pass := newPassword()
	var openErr error
	if backend, ok := a.backend.(interface {
		OpenSession(context.Context, string, string, Command) error
	}); ok {
		openErr = backend.OpenSession(ctx, a.backend.Username(), pass, c)
	} else {
		openErr = a.backend.Open(ctx, a.backend.Username(), pass)
	}
	if openErr != nil {
		_ = a.backend.Close(ctx)
		a.sessionState(c.SessionID, "", "")
		a.event(ctx, c.SessionID, remoteengine.EventFailed, "Не удалось включить RDP: "+openErr.Error(), nil)
		return
	}
	cert, key := a.cfg.TLSCert, a.cfg.TLSKey
	if backend, ok := a.backend.(interface {
		SessionTLS() (string, string, string)
	}); ok {
		var pem string
		cert, key, pem = backend.SessionTLS()
		a.mu.Lock()
		a.certPEM = pem
		a.mu.Unlock()
		if err := a.Hello(ctx); err != nil {
			_ = a.backend.Close(ctx)
			a.sessionState(c.SessionID, "", "")
			a.event(ctx, c.SessionID, remoteengine.EventFailed, "Не удалось закрепить сертификат нового сеанса", nil)
			return
		}
	}
	extra := map[string]string{"password": pass}
	if a.cfg.Backend == "windows-rdp" {
		extra = nil // the OS account is used; nothing to hand over
	}
	if a.files != nil && c.Allowed.Files {
		tok := newToken()
		bind := "" // direct route: clients in the LAN connect to this port
		if c.Relay {
			bind = "127.0.0.1" // relay: only the agent's own legs reach it
		}
		if err := a.files.Start(net.JoinHostPort(bind, strconv.Itoa(a.cfg.Files.Port)), cert, key, tok); err != nil {
			a.log.Warn("file channel", "err", err)
		} else if extra != nil {
			extra["filesToken"] = tok
		}
	}
	sctx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	s := &openSession{id: c.SessionID, viewer: viewer, expiresAt: c.ExpiresAt, cancel: cancel}
	a.mu.Lock()
	a.session = s
	a.mu.Unlock()
	a.sessionState(c.SessionID, "active", viewer)
	a.event(ctx, c.SessionID, remoteengine.EventReady, "", extra)
	go a.watch(sctx, s)
	if c.Relay {
		go a.relay(sctx, c.SessionID, remoteengine.ChannelRDP, a.cfg.Port)
		if a.files != nil && c.Allowed.Files {
			go a.relay(sctx, c.SessionID, remoteengine.ChannelFiles, a.cfg.Files.Port)
		}
	}
}

func permissionLabel(allowed bool) string {
	if allowed {
		return "да"
	}
	return "нет"
}

// watch reports real connects/disconnects and ends the session at its
// expiry — also when Core is unreachable (agent-side enforcement).
func (a *Agent) watch(ctx context.Context, s *openSession) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			if backend, ok := a.backend.(interface{ Alive() bool }); ok && !backend.Alive() {
				a.closeSession(context.Background(), s.id, "Удалённый доступ остановлен локально, защищённым экраном или ошибкой захвата")
				return
			}
			if now.After(s.expiresAt) {
				a.closeSession(context.Background(), s.id, "Истёк срок сеанса (агент хоста)")
				return
			}
			n := a.Connections()
			if n < 0 {
				continue
			}
			switch {
			case n > 0 && !s.connected:
				s.connected = true
				a.sessionState(s.id, "connected", s.viewer)
				a.event(ctx, s.id, remoteengine.EventConnected, fmt.Sprintf("Установлено соединений RDP: %d", n), nil)
			case n == 0 && s.connected:
				s.connected = false
				a.sessionState(s.id, "active", s.viewer)
				a.event(ctx, s.id, remoteengine.EventDisconnected, "Соединение RDP закрыто или прервано", nil)
			}
		}
	}
}

func (a *Agent) closeSession(ctx context.Context, id, reason string) {
	a.mu.Lock()
	s := a.session
	if s == nil || s.id != id {
		a.mu.Unlock()
		return
	}
	a.session = nil
	a.mu.Unlock()
	a.sessionState(id, "", "")
	s.cancel()
	if a.files != nil {
		a.files.Stop()
	}
	err := a.backend.Close(ctx)
	if err != nil {
		a.log.Error("could not disable RDP", "err", err)
		reason += "; ошибка выключения RDP: " + err.Error()
	}
	a.event(ctx, id, remoteengine.EventClosed, reason, nil)
}

// Run is the agent loop until ctx ends or the credential is revoked.
func (a *Agent) Run(ctx context.Context) error {
	if err := a.backend.Prepare(ctx); err != nil {
		return fmt.Errorf("prepare RDP backend: %w", err)
	}
	defer func() { // never leave the RDP server open behind us
		a.mu.Lock()
		s := a.session
		a.mu.Unlock()
		if s != nil {
			a.closeSession(context.Background(), s.id, "Агент хоста остановлен")
		}
		_ = a.backend.Close(context.Background())
	}()
	helloT := time.NewTicker(20 * time.Second)
	defer helloT.Stop()
	defer a.setStatus(func(s *Status) {
		if s.Link != LinkRevoked {
			s.Link = LinkStopped
		}
	})
	a.setStatus(func(s *Status) { s.Link = LinkConnecting })
	cmds := make(chan Command, 8)
	pollErr := make(chan error, 1)
	go func() {
		retry := NewBackoff(time.Second, time.Minute)
		for ctx.Err() == nil {
			var res struct {
				Commands []Command `json:"commands"`
			}
			if err := a.call(ctx, http.MethodGet, "/remote/agent/commands?wait=25", nil, &res); err != nil {
				var ce *CoreError
				if errors.As(err, &ce) && ce.Revoked() {
					pollErr <- err
					return
				}
				if ctx.Err() != nil {
					return
				}
				a.setStatus(func(s *Status) {
					if s.Link == LinkOnline || s.Link == LinkReconnecting {
						s.Link = LinkReconnecting
					} else {
						s.Link = LinkConnecting
					}
					s.Error = linkError(err)
				})
				select { // Core or the network away: exponential backoff with jitter
				case <-ctx.Done():
				case <-time.After(retry.Next()):
				}
				continue
			}
			retry.Reset()
			a.setStatus(func(s *Status) { s.Link, s.Error = LinkOnline, "" })
			for _, c := range res.Commands {
				select {
				case cmds <- c:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	if err := a.Hello(ctx); err != nil {
		var ce *CoreError
		if errors.As(err, &ce) && ce.Revoked() {
			a.setStatus(func(s *Status) { s.Link, s.Error = LinkRevoked, "Устройство отозвано" })
			return fmt.Errorf("credential rejected by Core, stopping: %w", err)
		}
		a.log.Warn("hello", "err", err)
	} else {
		a.setStatus(func(s *Status) { s.Link, s.Error = LinkOnline, "" })
	}
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-pollErr:
			a.setStatus(func(s *Status) { s.Link, s.Error = LinkRevoked, "Устройство отозвано" })
			return fmt.Errorf("credential rejected by Core, stopping: %w", err)
		case c := <-cmds:
			a.Handle(ctx, c)
		case <-helloT.C:
			if err := a.Hello(ctx); err != nil {
				var ce *CoreError
				if errors.As(err, &ce) && ce.Revoked() {
					a.setStatus(func(s *Status) { s.Link, s.Error = LinkRevoked, "Устройство отозвано" })
					return fmt.Errorf("credential rejected by Core, stopping: %w", err)
				}
				a.log.Warn("hello", "err", err)
			}
		}
	}
}

// authEvent reports a password verdict; true when Core accepted it and the
// session may continue to the local prompt.
func (a *Agent) authEvent(ctx context.Context, id, ev, code string) bool {
	var res struct {
		State remoteengine.State `json:"state"`
	}
	err := a.call(ctx, http.MethodPost, "/remote/agent/sessions/"+id+"/events", map[string]string{"event": ev, "code": code}, &res)
	if err != nil {
		a.log.Warn("report auth verdict", "err", err)
		return false
	}
	return ev == remoteengine.EventAuthOK && !res.State.Terminal()
}

func linkError(err error) string {
	var ce *CoreError
	if errors.As(err, &ce) {
		if ce.Status == http.StatusBadGateway || ce.Status == http.StatusServiceUnavailable {
			return "Сервер AER недоступен"
		}
		return "Ошибка сервера: " + ce.Message
	}
	if strings.Contains(err.Error(), "certificate") || strings.Contains(err.Error(), "pinned") {
		return "Сертификат сервера не совпадает с закреплённым"
	}
	return "Нет связи с сервером"
}

func (a *Agent) commandPrompt(ctx context.Context, text string) bool {
	argv := append(append([]string{}, a.cfg.PromptCommand...), "--text="+text)
	ctx, cancel := context.WithTimeout(ctx, 110*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, argv[0], argv[1:]...).Run() == nil
}

func shadowHeader(viewer string) string {
	if viewer == "" {
		return "Разрешить один сеанс AER HOME?"
	}
	return "Разрешить подключение AER Connect?\nКто подключается: " + viewer + "\nРазрешайте, только если знаете этого человека."
}
