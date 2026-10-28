package powerhost

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Version of the power agent protocol implementation.
const Version = "0.1.0"

// Command mirrors power.Command (agent side).
type Command struct {
	ID        string    `json:"id"`
	JobID     string    `json:"jobId"`
	Action    string    `json:"action"`
	EntryID   string    `json:"entryId"`
	TargetOS  string    `json:"targetOs"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// Agent is the running power agent.
type Agent struct {
	cfg  Config
	host *Host
	http *http.Client
	log  *slog.Logger
	now  func() time.Time
	// quiet: after a suspend the agent stays silent so Core can see it gone.
	Quiet time.Duration

	mu   sync.Mutex
	seen map[string]bool // command ids already handled (replay protection)
	// stopped: a shutdown/reboot/switch is under way; take nothing more.
	stopped bool
}

// New builds the agent for a validated config.
func New(cfg Config, log *slog.Logger) *Agent {
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	return &Agent{cfg: cfg, host: NewHost(cfg), http: &http.Client{Timeout: 40 * time.Second}, log: log, now: time.Now,
		Quiet: 90 * time.Second, seen: map[string]bool{}}
}

// Host exposes the fact/plan layer (tests replace its runner).
func (a *Agent) Host() *Host { return a.host }

// CoreError is an error envelope from Core.
type CoreError struct {
	Status  int
	Code    string
	Message string
}

func (e *CoreError) Error() string { return fmt.Sprintf("core: %d %s %s", e.Status, e.Code, e.Message) }

// Revoked: the credential was revoked or is invalid — stop.
func (e *CoreError) Revoked() bool { return e.Status == http.StatusUnauthorized }

func (a *Agent) call(ctx context.Context, method, path string, body, out any) error {
	b, err := os.ReadFile(a.cfg.TokenFile)
	if err != nil {
		return fmt.Errorf("token file: %w", err)
	}
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(a.cfg.CoreURL, "/")+"/api/v1"+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(b)))
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

// Hello reports fresh facts.
func (a *Agent) Hello(ctx context.Context) error {
	return a.call(ctx, http.MethodPost, "/power/agent/hello", a.host.Inventory(ctx), nil)
}

func (a *Agent) event(ctx context.Context, job, kind, msg string) {
	if err := a.call(ctx, http.MethodPost, "/power/agent/jobs/"+job+"/events", map[string]string{"kind": kind, "message": msg}, nil); err != nil {
		a.log.Warn("job event", "job", job, "kind", kind, "err", err)
	}
}

// Handle runs one command from Core. Returns true when the host is going
// down (the agent stops polling).
func (a *Agent) Handle(ctx context.Context, c Command) bool {
	a.mu.Lock()
	dup, stopped := a.seen[c.ID], a.stopped
	a.seen[c.ID] = true
	a.mu.Unlock()
	if dup {
		return false
	}
	if c.Action == "inventory" {
		if err := a.Hello(ctx); err != nil {
			a.log.Warn("hello", "err", err)
		}
		return false
	}
	if c.JobID == "" {
		return false
	}
	if stopped {
		a.event(ctx, c.JobID, "failed", "Компьютер уже выполняет другую команду питания")
		return false
	}
	if a.now().After(c.ExpiresAt) {
		a.event(ctx, c.JobID, "failed", "Срок команды истёк до получения — ничего не выполнено")
		return false
	}
	a.event(ctx, c.JobID, "accepted", "Агент принял команду")
	inv := a.host.Inventory(ctx) // re-validate against what is true now
	steps, err := a.host.Plan(c, inv)
	if err != nil {
		a.event(ctx, c.JobID, "failed", err.Error())
		return false
	}
	argv := make([]string, len(steps))
	for i, s := range steps {
		argv[i] = strings.Join(s.Argv, " ")
	}
	if !a.cfg.Execute {
		a.log.Info("check mode: not executing", "action", c.Action, "would run", argv)
		a.event(ctx, c.JobID, "simulated", "Выполнил бы: "+strings.Join(argv, " && "))
		return false
	}
	a.mu.Lock()
	a.stopped = true
	a.mu.Unlock()
	a.event(ctx, c.JobID, "executing", "Выполняется: "+strings.Join(argv, " && "))
	for _, s := range steps {
		out, err := a.host.Run(ctx, s.Argv)
		if err == nil && s.Check != nil {
			err = s.Check(string(out))
		}
		if err != nil {
			a.mu.Lock()
			a.stopped = false
			a.mu.Unlock()
			a.event(ctx, c.JobID, "failed", strings.Join(s.Argv, " ")+": "+firstLine(string(out), err))
			return false
		}
	}
	if c.Action == "suspend" { // back from sleep: resume normal work after a quiet pause
		select {
		case <-ctx.Done():
		case <-time.After(a.Quiet):
		}
		a.mu.Lock()
		a.stopped = false
		a.mu.Unlock()
		return false
	}
	return true
}

func (a *Agent) busy() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.stopped
}

// Run is the agent loop until ctx ends, the host goes down or the
// credential is revoked. Commands are polled and handled one at a time;
// while a power action is under way the agent neither polls nor says
// hello, so Core can see the host go silent. Without Core the agent does
// nothing at all: commands only come from Core and expire.
func (a *Agent) Run(ctx context.Context) error {
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	revoked := func(err error) bool {
		var ce *CoreError
		return errors.As(err, &ce) && ce.Revoked()
	}
	if err := a.Hello(ctx); revoked(err) {
		return fmt.Errorf("credential rejected by Core, stopping: %w", err)
	} else if err != nil {
		a.log.Warn("hello", "err", err)
	}
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if a.busy() {
					continue
				}
				if err := a.Hello(ctx); revoked(err) {
					cancel(err)
					return
				} else if err != nil {
					a.log.Warn("hello", "err", err)
				}
			}
		}
	}()
	for ctx.Err() == nil {
		var res struct {
			Commands []Command `json:"commands"`
		}
		if err := a.call(ctx, http.MethodGet, "/power/agent/commands?wait=25", nil, &res); err != nil {
			if revoked(err) {
				return fmt.Errorf("credential rejected by Core, stopping: %w", err)
			}
			select { // Core away: retry calmly
			case <-ctx.Done():
			case <-time.After(3 * time.Second):
			}
			continue
		}
		for _, c := range res.Commands {
			if a.Handle(ctx, c) {
				a.log.Info("power action under way; agent stops", "action", c.Action)
				return nil
			}
		}
	}
	if err := context.Cause(ctx); err != nil && !errors.Is(err, context.Canceled) {
		return fmt.Errorf("credential rejected by Core, stopping: %w", err)
	}
	return nil
}
