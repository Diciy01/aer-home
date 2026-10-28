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

	mu      sync.Mutex
	session *openSession
}

type openSession struct {
	id        string
	expiresAt time.Time
	connected bool
	cancel    context.CancelFunc
}

// New builds the agent for a validated config.
func New(cfg Config, log *slog.Logger) (*Agent, error) {
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	cert, err := EnsureCert(&cfg)
	if err != nil {
		return nil, fmt.Errorf("tls certificate: %w", err)
	}
	a := &Agent{cfg: cfg, log: log, certPEM: cert, http: &http.Client{Timeout: 40 * time.Second}}
	switch cfg.Backend {
	case "windows-rdp":
		a.backend = &windowsBackend{c: cfg}
	default:
		a.backend = &gnomeBackend{c: cfg, run: execRunner, start: startDaemon(cfg.StateDir)}
	}
	if cfg.Files.Enabled {
		a.files = NewFileServer(cfg.Files.Dir, cfg.Files.MaxBytes)
	}
	a.Prompt = a.commandPrompt
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
	host, _ := os.Hostname()
	body := map[string]any{
		"os": runtime.GOOS, "hostname": host, "version": Version, "backend": a.cfg.Backend,
		"address": a.cfg.Address, "port": a.cfg.Port, "certPem": a.certPEM, "monitors": 1,
		"capabilities": map[string]bool{"desktop": true, "input": true, "clipboard": a.cfg.Clipboard,
			"files": a.cfg.Files.Enabled, "apps": false},
		"approval": a.cfg.Approval, "ready": ready, "reason": reason, "username": a.backend.Username(),
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
	if a.cfg.Approval == "prompt" {
		a.event(ctx, c.SessionID, remoteengine.EventAwaitingApproval, "", nil)
		if !a.Prompt(ctx, "Разрешить удалённое подключение AER HOME к этому компьютеру?") {
			a.event(ctx, c.SessionID, remoteengine.EventDenied, "Пользователь компьютера отклонил подключение", nil)
			return
		}
	}
	a.event(ctx, c.SessionID, remoteengine.EventApproved, "", nil)
	pass := newPassword()
	if err := a.backend.Open(ctx, a.backend.Username(), pass); err != nil {
		_ = a.backend.Close(ctx)
		a.event(ctx, c.SessionID, remoteengine.EventFailed, "Не удалось включить RDP: "+err.Error(), nil)
		return
	}
	extra := map[string]string{"password": pass}
	if a.cfg.Backend == "windows-rdp" {
		extra = nil // the OS account is used; nothing to hand over
	}
	if a.files != nil && c.Allowed.Files {
		tok := newToken()
		if err := a.files.Start(net.JoinHostPort("", strconv.Itoa(a.cfg.Files.Port)), a.cfg.TLSCert, a.cfg.TLSKey, tok); err != nil {
			a.log.Warn("file channel", "err", err)
		} else if extra != nil {
			extra["filesToken"] = tok
		}
	}
	sctx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	s := &openSession{id: c.SessionID, expiresAt: c.ExpiresAt, cancel: cancel}
	a.mu.Lock()
	a.session = s
	a.mu.Unlock()
	a.event(ctx, c.SessionID, remoteengine.EventReady, "", extra)
	go a.watch(sctx, s)
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
				a.event(ctx, s.id, remoteengine.EventConnected, fmt.Sprintf("Установлено соединений RDP: %d", n), nil)
			case n == 0 && s.connected:
				s.connected = false
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
	cmds := make(chan Command, 8)
	pollErr := make(chan error, 1)
	go func() {
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
				select { // Core away: retry calmly
				case <-ctx.Done():
				case <-time.After(3 * time.Second):
				}
				continue
			}
			for _, c := range res.Commands {
				cmds <- c
			}
		}
	}()
	if err := a.Hello(ctx); err != nil {
		a.log.Warn("hello", "err", err)
	}
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-pollErr:
			return fmt.Errorf("credential rejected by Core, stopping: %w", err)
		case c := <-cmds:
			a.Handle(ctx, c)
		case <-helloT.C:
			if err := a.Hello(ctx); err != nil {
				var ce *CoreError
				if errors.As(err, &ce) && ce.Revoked() {
					return fmt.Errorf("credential rejected by Core, stopping: %w", err)
				}
				a.log.Warn("hello", "err", err)
			}
		}
	}
}

func (a *Agent) commandPrompt(ctx context.Context, text string) bool {
	argv := append(append([]string{}, a.cfg.PromptCommand...), "--text="+text)
	ctx, cancel := context.WithTimeout(ctx, 110*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, argv[0], argv[1:]...).Run() == nil
}
