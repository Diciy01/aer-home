package bots

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules/monitoring"
)

// processAdapter supervises child processes declared in config
// (bots.controllers[kind=process]). Core starts them, captures their
// output into Monitoring logs, records exits and measures CPU/RAM. A
// process started outside Core is never touched: Core only knows its own
// children, by the PID it started.
type processAdapter struct {
	s     *Service
	mu    sync.Mutex
	procs map[string]*child // by controller ID
}

type child struct {
	cmd       *exec.Cmd
	entityID  string
	startedAt time.Time
	stopping  bool
	done      chan struct{}
	exitErr   error
	cpuPrev   cpuSample
}

func newProcessAdapter(s *Service) *processAdapter {
	return &processAdapter{s: s, procs: map[string]*child{}}
}

func (p *processAdapter) Kind() string { return "process" }

func (p *processAdapter) Info(cfg config.Bots) AdapterInfo {
	inst := controllerInstances(cfg, "process")
	st, reason := instancesStatus(len(inst), "процесса")
	return AdapterInfo{ID: "process", Label: "Процесс под управлением Core", Status: st, Reason: reason,
		Description:  "Core запускает объявленную в конфигурации команду, собирает её вывод, CPU/RAM и коды завершения",
		Capabilities: []string{"control", "logs", "monitor"}, Instances: inst}
}

func (p *processAdapter) running(id string) *child {
	p.mu.Lock()
	defer p.mu.Unlock()
	c := p.procs[id]
	if c == nil {
		return nil
	}
	select {
	case <-c.done:
		return nil
	default:
		return c
	}
}

func (p *processAdapter) State(_ context.Context, ctl config.BotController) RuntimeState {
	c := p.running(ctl.ID)
	if c == nil {
		st := RuntimeState{Adapter: "process", State: "stopped", Reason: "Процесс не запущен Core"}
		p.mu.Lock()
		if old := p.procs[ctl.ID]; old != nil {
			st.Reason = "Завершился: " + exitText(old.exitErr)
		}
		p.mu.Unlock()
		return st
	}
	t := c.startedAt
	return RuntimeState{Adapter: "process", State: "running", PID: c.cmd.Process.Pid, Since: &t,
		Reason: "Процесс запущен Core (это не значит, что бот работает — смотрите heartbeat)"}
}

func (p *processAdapter) Control(ctx context.Context, ctl config.BotController, entityID, action string) (string, error) {
	switch action {
	case "start":
		return p.start(ctl, entityID)
	case "stop":
		return p.stop(ctx, ctl, entityID)
	case "restart":
		if _, err := p.stop(ctx, ctl, entityID); err != nil {
			return "", err
		}
		msg, err := p.start(ctl, entityID)
		if err == nil {
			p.s.mon.RecordEvent(context.WithoutCancel(ctx), entityID, "bot_restarted", monitoring.SeverityInfo, "Перезапущен по команде владельца: "+msg)
		}
		return msg, err
	}
	return "", fmt.Errorf("неизвестное действие %q", action)
}

func (p *processAdapter) start(ctl config.BotController, entityID string) (string, error) {
	if c := p.running(ctl.ID); c != nil {
		return fmt.Sprintf("Уже запущен (PID %d), повторный запуск не нужен", c.cmd.Process.Pid), nil
	}
	if _, err := os.Stat(ctl.Command[0]); err != nil {
		return "", fmt.Errorf("исполняемый файл недоступен: %w", errors.Unwrap(err))
	}
	// Not CommandContext: the child must outlive the request.
	cmd := exec.Command(ctl.Command[0], ctl.Command[1:]...)
	cmd.Dir = ctl.WorkDir
	cmd.Env = append(minimalEnv(), ctl.Env...)
	cmd.SysProcAttr = childAttr()
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return "", err
	}
	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("не удалось запустить: %w", err)
	}
	c := &child{cmd: cmd, entityID: entityID, startedAt: p.s.now().UTC(), done: make(chan struct{})}
	p.mu.Lock()
	p.procs[ctl.ID] = c
	p.mu.Unlock()

	var pipes sync.WaitGroup
	pipes.Add(2)
	go p.pump(&pipes, entityID, "process:"+ctl.ID, stdout, false)
	go p.pump(&pipes, entityID, "process:"+ctl.ID, stderr, true)
	go func() {
		pipes.Wait()
		err := cmd.Wait()
		p.mu.Lock()
		c.exitErr = err
		stopping := c.stopping
		p.mu.Unlock()
		close(c.done)
		p.exited(ctl, c, stopping, err)
	}()
	ctx := context.Background()
	p.s.mon.RecordEvent(ctx, entityID, "bot_started", monitoring.SeverityInfo, fmt.Sprintf("Процесс «%s» запущен (PID %d)", ctl.ID, cmd.Process.Pid))
	p.s.mon.ResolveIncident(ctx, "bot_process:"+entityID, "Процесс снова запущен")
	return fmt.Sprintf("Запущен, PID %d", cmd.Process.Pid), nil
}

// exited records how the process ended: a requested stop is not a crash.
func (p *processAdapter) exited(ctl config.BotController, c *child, stopping bool, err error) {
	ctx := context.Background()
	if stopping {
		p.s.mon.RecordEvent(ctx, c.entityID, "bot_stopped", monitoring.SeverityInfo, "Процесс «"+ctl.ID+"» остановлен по команде: "+exitText(err))
		return
	}
	text := exitText(err)
	p.s.mon.RecordEvent(ctx, c.entityID, "bot_crashed", monitoring.SeverityWarning, "Процесс «"+ctl.ID+"» завершился сам: "+text)
	_ = p.s.mon.AppendLog(ctx, c.entityID, "process:"+ctl.ID, monitoring.LevelError, "Процесс завершился: "+text)
	p.s.mon.RaiseIncident(ctx, "bot_process:"+c.entityID, "Процесс бота завершился", "bots/process", c.entityID,
		monitoring.SeverityWarning, text, "Процесс «"+ctl.ID+"» завершился без команды владельца: "+text)
}

func exitText(err error) string {
	if err == nil {
		return "код 0"
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ee.ExitCode() >= 0 {
			return fmt.Sprintf("код %d", ee.ExitCode())
		}
		return "по сигналу (" + ee.String() + ")"
	}
	return err.Error()
}

func (p *processAdapter) stop(ctx context.Context, ctl config.BotController, entityID string) (string, error) {
	c := p.running(ctl.ID)
	if c == nil {
		return "Не был запущен — останавливать нечего", nil
	}
	p.mu.Lock()
	c.stopping = true
	p.mu.Unlock()
	if err := terminate(c.cmd); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return "", fmt.Errorf("не удалось отправить сигнал завершения: %w", err)
	}
	grace := time.Duration(ctl.StopTimeoutSec) * time.Second
	select {
	case <-c.done:
		return "Остановлен (" + exitText(c.exitErr) + ")", nil
	case <-time.After(grace):
	case <-ctx.Done():
	}
	_ = kill(c.cmd)
	select {
	case <-c.done:
		return fmt.Sprintf("Не завершился за %d с — остановлен принудительно", ctl.StopTimeoutSec), nil
	case <-time.After(5 * time.Second):
		return "", errors.New("процесс не завершился даже после принудительной остановки")
	}
}

// pump forwards output lines to Monitoring logs (redacted, rate limited).
func (p *processAdapter) pump(wg *sync.WaitGroup, entityID, source string, r io.Reader, stderr bool) {
	defer wg.Done()
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 16<<10), 64<<10)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		_ = p.s.mon.AppendLog(context.Background(), entityID, source, lineLevel(line, stderr), line)
	}
	_, _ = io.Copy(io.Discard, r) // a line over the limit: drain, keep the child unblocked
}

// lineLevel guesses a level from common logging formats (Python logging,
// Go slog, tracebacks). Unknown stderr lines are warnings, stdout is info.
func lineLevel(line string, stderr bool) monitoring.LogLevel {
	u := strings.ToUpper(line)
	switch {
	case strings.Contains(u, "CRITICAL"), strings.Contains(u, "FATAL"):
		return monitoring.LevelCritical
	case strings.Contains(u, "ERROR"), strings.HasPrefix(line, "Traceback"), strings.Contains(u, "EXCEPTION"):
		return monitoring.LevelError
	case strings.Contains(u, "WARN"):
		return monitoring.LevelWarning
	case strings.Contains(u, "DEBUG"):
		return monitoring.LevelDebug
	case stderr && !strings.Contains(u, "INFO"):
		return monitoring.LevelWarning
	}
	return monitoring.LevelInfo
}

// minimalEnv passes only what a program needs to run; Core's own
// environment (and anything secret in it) is not inherited.
func minimalEnv() []string {
	var env []string
	for _, k := range []string{"PATH", "HOME", "LANG", "LC_ALL", "TZ", "SYSTEMROOT", "TEMP", "TMP"} {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
		}
	}
	return env
}

// Sync samples CPU/RAM of running children into Monitoring.
func (p *processAdapter) Sync(ctx context.Context) {
	p.mu.Lock()
	list := make([]*child, 0, len(p.procs))
	for _, c := range p.procs {
		list = append(list, c)
	}
	p.mu.Unlock()
	now := p.s.now().UTC()
	for _, c := range list {
		select {
		case <-c.done:
			continue
		default:
		}
		cur, err := readCPU(c.cmd.Process.Pid)
		if err != nil {
			continue
		}
		var samples []monitoring.SampleIn
		p.mu.Lock()
		prev := c.cpuPrev
		c.cpuPrev = cur
		p.mu.Unlock()
		if !prev.at.IsZero() {
			if wall := cur.at.Sub(prev.at).Seconds(); wall > 0 {
				v := (cur.cpuSec - prev.cpuSec) / wall * 100
				samples = append(samples, monitoring.SampleIn{Metric: "process.cpu_percent", Value: &v, At: now, Quality: monitoring.QualityOK})
			}
		}
		if rss, err := readRSS(c.cmd.Process.Pid); err == nil {
			samples = append(samples, monitoring.SampleIn{Metric: "process.rss_bytes", Value: &rss, At: now, Quality: monitoring.QualityOK})
		}
		if len(samples) > 0 {
			_ = p.s.mon.StoreSamples(ctx, c.entityID, "core.bots/process", samples)
		}
	}
}

// StopAll stops every child on Core shutdown (they are Core's children).
func (p *processAdapter) StopAll() {
	p.mu.Lock()
	ids := make([]string, 0, len(p.procs))
	for id := range p.procs {
		ids = append(ids, id)
	}
	p.mu.Unlock()
	for _, id := range ids {
		if ctl, ok := p.s.cfg.Controller(id); ok {
			ctx, cancel := context.WithTimeout(context.Background(), time.Duration(ctl.StopTimeoutSec+6)*time.Second)
			c := p.running(id)
			if c != nil {
				_, _ = p.stop(ctx, ctl, c.entityID)
			}
			cancel()
		}
	}
}
