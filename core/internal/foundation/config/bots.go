package config

import (
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"regexp"
	"slices"

	"aerhome/core/internal/foundation/netx"
)

// Bots configures the M06 Bots module. Everything that can execute or reach
// out (processes, systemd units, Docker containers, n8n instances, Telegram
// tokens) is declared here by the owner; the API can only select these
// entries by ID, so no request can introduce a new command or secret path.
type Bots struct {
	// Controllers are the management adapters (start/stop/restart).
	Controllers []BotController `json:"controllers"`
	// N8N instances (read-only by default).
	N8N []N8NInstance `json:"n8n"`
	// TelegramTokens are token files for optional getMe checks.
	TelegramTokens []TelegramToken `json:"telegramTokens"`
	// TelegramAPIBase is overridden only by tests.
	TelegramAPIBase string `json:"telegramApiBase"`
	// DockerSocket is the local Docker Engine socket used by docker controllers.
	DockerSocket string `json:"dockerSocket"`

	// Limits for a small home server.
	MaxConcurrentOps   int `json:"maxConcurrentOps"`
	OpTimeoutSec       int `json:"opTimeoutSec"`
	SyncIntervalSec    int `json:"syncIntervalSec"`
	ConfirmTTLSec      int `json:"confirmTtlSec"`
	JobRetentionDays   int `json:"jobRetentionDays"`
	JobMaxRows         int `json:"jobMaxRows"`
	AuditRetentionDays int `json:"auditRetentionDays"`
}

// BotController is one explicitly allowed management target.
type BotController struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	// Kind: process (Core supervises a child process), systemd_user
	// (systemctl --user for one unit) or docker (one named container).
	Kind string `json:"kind"`
	// Allow lists the permitted actions: start, stop, restart.
	Allow []string `json:"allow"`
	// process: argv (absolute executable), working dir, extra environment
	// as NAME=value without secrets (a bot reads its token from its own file).
	Command []string `json:"command"`
	WorkDir string   `json:"workDir"`
	Env     []string `json:"env"`
	// StopTimeoutSec: SIGTERM, then SIGKILL after this many seconds.
	StopTimeoutSec int `json:"stopTimeoutSec"`
	// systemd_user
	Unit string `json:"unit"`
	// docker
	Container string `json:"container"`
}

// N8NInstance is an n8n server reachable with an API key from a file.
type N8NInstance struct {
	ID         string `json:"id"`
	Label      string `json:"label"`
	BaseURL    string `json:"baseUrl"`
	APIKeyFile string `json:"apiKeyFile"`
	// AllowRetry permits retrying failed executions (after confirmation).
	AllowRetry bool `json:"allowRetry"`
}

// TelegramToken names a bot token file; the token never leaves Core.
type TelegramToken struct {
	ID   string `json:"id"`
	File string `json:"file"`
}

// DefaultBots returns the M06 defaults: no controllers, nothing enabled.
func DefaultBots() Bots {
	return Bots{
		TelegramAPIBase:    "https://api.telegram.org",
		DockerSocket:       netx.DefaultDockerSocket,
		MaxConcurrentOps:   2,
		OpTimeoutSec:       30,
		SyncIntervalSec:    60,
		ConfirmTTLSec:      120,
		JobRetentionDays:   90,
		JobMaxRows:         200_000,
		AuditRetentionDays: 365,
	}
}

var (
	idPattern   = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,39}$`)
	unitPattern = regexp.MustCompile(`^[A-Za-z0-9@._-]{1,120}\.service$`)
	ctrPattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`)
	envPattern  = regexp.MustCompile(`^[A-Z_][A-Z0-9_]{0,63}=`)
	secretEnv   = regexp.MustCompile(`(?i)(token|secret|password|passwd|api_?key)`)
)

// BotActions are the management actions a controller may allow.
var BotActions = []string{"start", "stop", "restart"}

// Validate rejects unsafe or ambiguous adapter declarations.
func (b Bots) Validate() error {
	var errs []error
	in := func(name string, v, lo, hi int) {
		if v < lo || v > hi {
			errs = append(errs, fmt.Errorf("bots.%s = %d: want %d…%d", name, v, lo, hi))
		}
	}
	in("maxConcurrentOps", b.MaxConcurrentOps, 1, 16)
	in("opTimeoutSec", b.OpTimeoutSec, 5, 600)
	in("syncIntervalSec", b.SyncIntervalSec, 10, 3600)
	in("confirmTtlSec", b.ConfirmTTLSec, 10, 900)
	in("jobRetentionDays", b.JobRetentionDays, 1, 3650)
	in("jobMaxRows", b.JobMaxRows, 1000, 10_000_000)
	in("auditRetentionDays", b.AuditRetentionDays, 30, 3650)
	if u, err := url.Parse(b.TelegramAPIBase); err != nil || (u.Scheme != "https" && u.Scheme != "http") {
		errs = append(errs, fmt.Errorf("bots.telegramApiBase %q: want an http(s) URL", b.TelegramAPIBase))
	}
	if !netx.IsLocalSocket(b.DockerSocket) {
		errs = append(errs, fmt.Errorf("bots.dockerSocket %q: want a local unix socket or named pipe (no TCP)", b.DockerSocket))
	}
	seen := map[string]bool{}
	id := func(kind, v string) {
		if !idPattern.MatchString(v) {
			errs = append(errs, fmt.Errorf("bots.%s id %q: want [a-z0-9_-], up to 40 chars", kind, v))
		}
		if seen[kind+"/"+v] {
			errs = append(errs, fmt.Errorf("bots.%s id %q: duplicate", kind, v))
		}
		seen[kind+"/"+v] = true
	}
	for _, c := range b.Controllers {
		id("controllers", c.ID)
		p := "bots.controllers[" + c.ID + "]"
		for _, a := range c.Allow {
			if !slices.Contains(BotActions, a) {
				errs = append(errs, fmt.Errorf("%s.allow %q: want start, stop or restart", p, a))
			}
		}
		switch c.Kind {
		case "process":
			if len(c.Command) == 0 || !filepath.IsAbs(c.Command[0]) {
				errs = append(errs, fmt.Errorf("%s.command: want an argv with an absolute executable path", p))
			}
			if c.WorkDir != "" && !filepath.IsAbs(c.WorkDir) {
				errs = append(errs, fmt.Errorf("%s.workDir: want an absolute path", p))
			}
			for _, e := range c.Env {
				if !envPattern.MatchString(e) {
					errs = append(errs, fmt.Errorf("%s.env: want NAME=value", p))
				} else if secretEnv.MatchString(envName(e)) {
					errs = append(errs, fmt.Errorf("%s.env %s: secrets do not belong in config; let the bot read its own token file", p, envName(e)))
				}
			}
			in("controllers["+c.ID+"].stopTimeoutSec", c.StopTimeoutSec, 1, 120)
		case "systemd_user":
			if !unitPattern.MatchString(c.Unit) {
				errs = append(errs, fmt.Errorf("%s.unit %q: want a user unit name ending in .service", p, c.Unit))
			}
		case "docker":
			if !ctrPattern.MatchString(c.Container) {
				errs = append(errs, fmt.Errorf("%s.container %q: want a container name", p, c.Container))
			}
		default:
			errs = append(errs, fmt.Errorf("%s.kind %q: want process, systemd_user or docker", p, c.Kind))
		}
	}
	for _, n := range b.N8N {
		id("n8n", n.ID)
		u, err := url.Parse(n.BaseURL)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil {
			errs = append(errs, fmt.Errorf("bots.n8n[%s].baseUrl: want http(s)://host[:port] without credentials", n.ID))
		}
		if !filepath.IsAbs(n.APIKeyFile) {
			errs = append(errs, fmt.Errorf("bots.n8n[%s].apiKeyFile: want an absolute path", n.ID))
		}
	}
	for _, t := range b.TelegramTokens {
		id("telegramTokens", t.ID)
		if !filepath.IsAbs(t.File) {
			errs = append(errs, fmt.Errorf("bots.telegramTokens[%s].file: want an absolute path", t.ID))
		}
	}
	return errors.Join(errs...)
}

func envName(e string) string {
	for i := range e {
		if e[i] == '=' {
			return e[:i]
		}
	}
	return e
}

// Controller returns a declared controller by ID.
func (b Bots) Controller(id string) (BotController, bool) {
	for _, c := range b.Controllers {
		if c.ID == id {
			return c, true
		}
	}
	return BotController{}, false
}

// N8NByID returns a declared n8n instance by ID.
func (b Bots) N8NByID(id string) (N8NInstance, bool) {
	for _, n := range b.N8N {
		if n.ID == id {
			return n, true
		}
	}
	return N8NInstance{}, false
}

// TelegramTokenByID returns a declared token file by ID.
func (b Bots) TelegramTokenByID(id string) (TelegramToken, bool) {
	for _, t := range b.TelegramTokens {
		if t.ID == id {
			return t, true
		}
	}
	return TelegramToken{}, false
}
