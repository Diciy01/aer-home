package agent

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
	"net/url"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"
)

// Config of an agent (JSON file). No secrets inside: the token lives in
// TokenFile (0600), created by the owner from Core's «Агенты» screen.
type Config struct {
	CoreURL     string `json:"coreUrl"`
	TokenFile   string `json:"tokenFile"`
	IntervalSec int    `json:"intervalSec"`
	// Queue limits while Core is unreachable; the oldest entries are dropped.
	QueueSamples int `json:"queueSamples"`
	QueueLogs    int `json:"queueLogs"`
	// LogIntervalSec: how often system logs are read.
	LogIntervalSec int        `json:"logIntervalSec"`
	Collectors     Collectors `json:"collectors"`
}

// Collectors switch individual sources off.
type Collectors struct {
	CPU         bool     `json:"cpu"`
	Memory      bool     `json:"memory"`
	Disk        bool     `json:"disk"`
	Network     bool     `json:"network"`
	Temperature bool     `json:"temperature"`
	GPU         bool     `json:"gpu"`
	Processes   bool     `json:"processes"`
	SystemLogs  bool     `json:"systemLogs"`
	Services    []string `json:"services"`
}

// DefaultConfig: every collector on, 15 s interval.
func DefaultConfig() Config {
	return Config{CoreURL: "http://127.0.0.1:8787", IntervalSec: 15, QueueSamples: 5000, QueueLogs: 1000, LogIntervalSec: 30,
		Collectors: Collectors{CPU: true, Memory: true, Disk: true, Network: true, Temperature: true, GPU: true, Processes: true, SystemLogs: true}}
}

// LoadConfig reads a JSON config over the defaults.
func LoadConfig(path string) (Config, error) {
	cfg := DefaultConfig()
	if path != "" {
		raw, err := os.ReadFile(path)
		if err != nil {
			return cfg, err
		}
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&cfg); err != nil {
			return cfg, fmt.Errorf("parse %s: %w", path, err)
		}
	}
	return cfg, cfg.Validate()
}

// Validate checks limits and that the Core URL is safe to use.
func (c Config) Validate() error {
	var errs []error
	u, err := url.Parse(c.CoreURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		errs = append(errs, fmt.Errorf("coreUrl %q: want http(s)://host:port", c.CoreURL))
	} else if u.User != nil || u.RawQuery != "" {
		errs = append(errs, errors.New("coreUrl must not carry credentials or a query"))
	}
	if c.TokenFile == "" {
		errs = append(errs, errors.New("tokenFile is required"))
	}
	if c.IntervalSec < 5 || c.IntervalSec > 3600 {
		errs = append(errs, fmt.Errorf("intervalSec %d: want 5…3600", c.IntervalSec))
	}
	if c.LogIntervalSec < 5 || c.LogIntervalSec > 3600 {
		errs = append(errs, fmt.Errorf("logIntervalSec %d: want 5…3600", c.LogIntervalSec))
	}
	if c.QueueSamples < 100 || c.QueueSamples > 200_000 || c.QueueLogs < 10 || c.QueueLogs > 50_000 {
		errs = append(errs, errors.New("queue limits: samples 100…200000, logs 10…50000"))
	}
	return errors.Join(errs...)
}

// insecureRemote reports a plain-HTTP Core URL that is not loopback.
func (c Config) insecureRemote() bool {
	u, err := url.Parse(c.CoreURL)
	if err != nil || u.Scheme != "http" {
		return false
	}
	ip := net.ParseIP(u.Hostname())
	return u.Hostname() != "localhost" && (ip == nil || !ip.IsLoopback())
}

// Source produces samples (and optionally logs) on each tick.
type Source interface {
	Name() string
	Collect(now time.Time) ([]Sample, []LogLine)
}

// Agent runs the collect → queue → send loop.
type Agent struct {
	cfg     Config
	sources []Source
	info    func() Info
	client  *http.Client
	log     *slog.Logger
	now     func() time.Time

	mu       sync.Mutex
	samples  []Sample
	logs     []LogLine
	dropS    int
	dropL    int
	lastSent time.Time
	failures int
}

// New builds an agent; sources and info come from the platform.
func New(cfg Config, sources []Source, info func() Info, log *slog.Logger) *Agent {
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	return &Agent{cfg: cfg, sources: sources, info: info, log: log, now: time.Now,
		client: &http.Client{Timeout: 10 * time.Second}}
}

func (a *Agent) token() (string, error) {
	st, err := os.Stat(a.cfg.TokenFile)
	if err != nil {
		return "", fmt.Errorf("token file: %w", err)
	}
	if runtime.GOOS != "windows" && st.Mode().Perm()&0o077 != 0 {
		a.log.Warn("token file is readable by other users; chmod 600 recommended", "file", a.cfg.TokenFile)
	}
	raw, err := os.ReadFile(a.cfg.TokenFile)
	if err != nil {
		return "", err
	}
	t := strings.TrimSpace(string(raw))
	if !strings.HasPrefix(t, "aer1.") {
		return "", errors.New("token file does not contain an AER agent token")
	}
	return t, nil
}

// Collect runs every source once and queues the results.
func (a *Agent) Collect() {
	now := a.now().UTC()
	var ss []Sample
	var ls []LogLine
	for _, src := range a.sources {
		s, l := src.Collect(now)
		ss = append(ss, s...)
		ls = append(ls, l...)
	}
	a.enqueue(ss, ls)
}

func (a *Agent) enqueue(ss []Sample, ls []LogLine) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.samples = append(a.samples, ss...)
	a.logs = append(a.logs, ls...)
	if over := len(a.samples) - a.cfg.QueueSamples; over > 0 {
		a.samples = a.samples[over:]
		a.dropS += over
	}
	if over := len(a.logs) - a.cfg.QueueLogs; over > 0 {
		a.logs = a.logs[over:]
		a.dropL += over
	}
}

// Queued returns the queue sizes and drop counters (tests, diagnostics).
func (a *Agent) Queued() (samples, logs, droppedS, droppedL int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.samples), len(a.logs), a.dropS, a.dropL
}

// errRejected: Core refused the credential — retrying will not help.
var errRejected = errors.New("Core rejected the agent credential (revoked or wrong token)")

// Flush sends the queue in chunks; on failure the rest stays queued.
func (a *Agent) Flush(ctx context.Context) error {
	tok, err := a.token()
	if err != nil {
		return err
	}
	for {
		a.mu.Lock()
		ns, nl := min(len(a.samples), 1000), min(len(a.logs), 400)
		rep := Report{Agent: a.info(), Samples: append([]Sample(nil), a.samples[:ns]...), Logs: append([]LogLine(nil), a.logs[:nl]...)}
		rep.Dropped.Samples, rep.Dropped.Logs = a.dropS, a.dropL
		a.mu.Unlock()
		if err := a.send(ctx, tok, rep); err != nil {
			return err
		}
		a.mu.Lock()
		a.samples, a.logs = a.samples[ns:], a.logs[nl:]
		a.dropS -= rep.Dropped.Samples
		a.dropL -= rep.Dropped.Logs
		more := len(a.samples) > 0 || len(a.logs) > 0
		a.lastSent = a.now()
		a.mu.Unlock()
		if !more {
			return nil
		}
	}
}

func (a *Agent) send(ctx context.Context, token string, rep Report) error {
	body, err := json.Marshal(rep)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(a.cfg.CoreURL, "/")+"/api/v1/monitoring/agent/report", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("User-Agent", "aer-agent/"+Version)
	resp, err := a.client.Do(req)
	if err != nil {
		return fmt.Errorf("Core unreachable: %w", err)
	}
	defer resp.Body.Close()
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	switch {
	case resp.StatusCode == http.StatusUnauthorized:
		return errRejected
	case resp.StatusCode == http.StatusUnprocessableEntity:
		// A bad batch would block the queue forever: drop it and say why.
		a.log.Error("Core rejected a report batch; dropping it", "details", string(msg))
		return nil
	case resp.StatusCode >= 300:
		return fmt.Errorf("Core answered HTTP %d", resp.StatusCode)
	}
	return nil
}

// Run collects and sends until ctx ends, backing off while Core is away.
func (a *Agent) Run(ctx context.Context) error {
	if a.cfg.insecureRemote() {
		a.log.Warn("coreUrl uses plain HTTP to a non-loopback host; use HTTPS or a trusted network (the token is sent in a header)")
	}
	interval := time.Duration(a.cfg.IntervalSec) * time.Second
	a.Collect()
	next := time.Now()
	backoff := interval
	for {
		if !time.Now().Before(next) {
			err := a.Flush(ctx)
			switch {
			case errors.Is(err, errRejected):
				a.log.Error("stopping sends: " + err.Error())
				backoff = 10 * time.Minute
				next = time.Now().Add(backoff)
			case err != nil:
				a.failures++
				backoff = min(backoff*2, 5*time.Minute)
				next = time.Now().Add(backoff)
				s, l, ds, dl := a.Queued()
				a.log.Warn("send failed; will retry", "err", err, "retryIn", backoff.String(), "queuedSamples", s, "queuedLogs", l, "dropped", ds+dl)
			default:
				if a.failures > 0 {
					a.log.Info("Core reachable again; queue flushed", "afterFailures", a.failures)
				}
				a.failures, backoff = 0, interval
				next = time.Now().Add(interval)
			}
		}
		select {
		case <-ctx.Done():
			// Best effort final flush with a short deadline.
			fctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			_ = a.Flush(fctx)
			cancel()
			return nil
		case <-time.After(interval):
			a.Collect()
		}
	}
}
